#include "include/linux_capture/linux_capture_plugin.h"

#include <alsa/asoundlib.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <csignal>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {

int Xioctl(int Fd, unsigned long Request, void* Arg) {
  int Result = 0;
  do {
    Result = ioctl(Fd, Request, Arg);
  } while (Result == -1 && errno == EINTR);
  return Result;
}

struct MapBuffer {
  void* Start = nullptr;
  size_t Length = 0;
};

struct EventPayload {
  FlEventChannel* Channel;
  FlValue* Value;
};

gboolean DeliverEvent(gpointer Data) {
  auto* Item = static_cast<EventPayload*>(Data);
  if (Item->Channel != nullptr) {
    fl_event_channel_send(Item->Channel, Item->Value, nullptr, nullptr);
  }
  fl_value_unref(Item->Value);
  delete Item;
  return G_SOURCE_REMOVE;
}

class CaptureHost {
 public:
  CaptureHost() = default;
  ~CaptureHost() { Stop(true); }

  void SetEventChannel(FlEventChannel* Channel) { Events = Channel; }

  FlValue* Enumerate();
  FlValue* Modes(const std::string& Path);
  bool Prepare(const std::string& Path, int Width, int Height, int Fps, const std::string& AudioName, const std::string& AudioFifoPath, FlValue** Info, std::string* Error);
  bool Start(const std::string& Exe, const std::vector<std::string>& Args, std::string* Error);
  void Stop(bool Fast);

 private:
  void FrameLoop();
  void AudioLoop();
  void Convert(const uint8_t* Source);
  bool WriteFrame();
  void SendState(const char* Value);
  void SendError(const std::string& Text);
  void SendStats();
  void Release();

  FlEventChannel* Events = nullptr;
  int Fd = -1;
  int PipeFd = -1;
  pid_t Child = -1;
  uint32_t PixelFormat = 0;
  int Width = 0;
  int Height = 0;
  int Stride = 0;
  std::vector<MapBuffer> Buffers;
  std::vector<uint8_t> Frame;
  std::atomic<bool> Running{false};
  std::thread Worker;
  std::atomic<int> Frames{0};
  std::string AudioDevice;
  std::string AudioFifo;
  std::atomic<bool> AudioRunning{false};
  std::thread AudioWorker;
  std::chrono::steady_clock::time_point LastTick;
};

std::string ValueString(FlValue* Args, const char* Key) {
  if (Args == nullptr || fl_value_get_type(Args) != FL_VALUE_TYPE_MAP) return std::string();
  FlValue* Value = fl_value_lookup_string(Args, Key);
  if (Value == nullptr || fl_value_get_type(Value) != FL_VALUE_TYPE_STRING) return std::string();
  return std::string(fl_value_get_string(Value));
}

int ValueInt(FlValue* Args, const char* Key, int Fallback) {
  if (Args == nullptr || fl_value_get_type(Args) != FL_VALUE_TYPE_MAP) return Fallback;
  FlValue* Value = fl_value_lookup_string(Args, Key);
  if (Value == nullptr || fl_value_get_type(Value) != FL_VALUE_TYPE_INT) return Fallback;
  return static_cast<int>(fl_value_get_int(Value));
}


FlValue* CaptureHost::Enumerate() {
  FlValue* List = fl_value_new_list();
  for (int Index = 0; Index < 32; Index++) {
    std::string Path = "/dev/video" + std::to_string(Index);
    int Handle = open(Path.c_str(), O_RDWR | O_NONBLOCK);
    if (Handle < 0) continue;
    v4l2_capability Cap{};
    bool Ok = Xioctl(Handle, VIDIOC_QUERYCAP, &Cap) == 0;
    close(Handle);
    if (!Ok) continue;
    if ((Cap.device_caps & V4L2_CAP_VIDEO_CAPTURE) == 0) continue;
    if ((Cap.device_caps & V4L2_CAP_STREAMING) == 0) continue;
    FlValue* Item = fl_value_new_map();
    fl_value_set_string_take(Item, "id", fl_value_new_string(Path.c_str()));
    fl_value_set_string_take(Item, "name", fl_value_new_string(reinterpret_cast<const char*>(Cap.card)));
    fl_value_set_string_take(Item, "kind", fl_value_new_string("video"));
    fl_value_append_take(List, Item);
  }
  void** Hints = nullptr;
  if (snd_device_name_hint(-1, "pcm", &Hints) == 0) {
    FlValue* Default = fl_value_new_map();
    fl_value_set_string_take(Default, "id", fl_value_new_string("default"));
    fl_value_set_string_take(Default, "name", fl_value_new_string("默认音频输入"));
    fl_value_set_string_take(Default, "kind", fl_value_new_string("audio"));
    fl_value_append_take(List, Default);
    for (void** Cursor = Hints; *Cursor != nullptr; Cursor++) {
      char* Name = snd_device_name_get_hint(*Cursor, "NAME");
      char* Ioid = snd_device_name_get_hint(*Cursor, "IOID");
      bool Input = Ioid == nullptr || strcmp(Ioid, "Input") == 0;
      if (Input && Name != nullptr && strcmp(Name, "null") != 0 && strcmp(Name, "default") != 0) {
        FlValue* Audio = fl_value_new_map();
        fl_value_set_string_take(Audio, "id", fl_value_new_string(Name));
        fl_value_set_string_take(Audio, "name", fl_value_new_string(Name));
        fl_value_set_string_take(Audio, "kind", fl_value_new_string("audio"));
        fl_value_append_take(List, Audio);
      }
      free(Name);
      free(Ioid);
    }
    snd_device_name_free_hint(Hints);
  }
  return List;
}

FlValue* CaptureHost::Modes(const std::string& Path) {
  FlValue* List = fl_value_new_list();
  int Handle = open(Path.c_str(), O_RDWR | O_NONBLOCK);
  if (Handle < 0) return List;
  for (int FormatIndex = 0; FormatIndex < 16; FormatIndex++) {
    v4l2_fmtdesc Format{};
    Format.index = FormatIndex;
    Format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (Xioctl(Handle, VIDIOC_ENUM_FMT, &Format) < 0) break;
    const char* Name = reinterpret_cast<const char*>(Format.description);
    if (Format.pixelformat != V4L2_PIX_FMT_YUYV && Format.pixelformat != V4L2_PIX_FMT_NV12 && Format.pixelformat != V4L2_PIX_FMT_UYVY) continue;
    for (int SizeIndex = 0; SizeIndex < 64; SizeIndex++) {
      v4l2_frmsizeenum Size{};
      Size.index = SizeIndex;
      Size.pixel_format = Format.pixelformat;
      if (Xioctl(Handle, VIDIOC_ENUM_FRAMESIZES, &Size) < 0) break;
      int Width = 0;
      int Height = 0;
      if (Size.type == V4L2_FRMSIZE_TYPE_DISCRETE) {
        Width = static_cast<int>(Size.discrete.width);
        Height = static_cast<int>(Size.discrete.height);
      } else {
        Width = static_cast<int>(Size.stepwise.max_width);
        Height = static_cast<int>(Size.stepwise.max_height);
      }
      if (Width <= 0 || Height <= 0) continue;
      int Fps = 30;
      v4l2_frmivalenum Interval{};
      Interval.index = 0;
      Interval.pixel_format = Format.pixelformat;
      Interval.width = static_cast<uint32_t>(Width);
      Interval.height = static_cast<uint32_t>(Height);
      if (Xioctl(Handle, VIDIOC_ENUM_FRAMEINTERVALS, &Interval) == 0) {
        if (Interval.type == V4L2_FRMIVAL_TYPE_DISCRETE && Interval.discrete.numerator > 0) {
          Fps = static_cast<int>(Interval.discrete.denominator / Interval.discrete.numerator);
        } else if (Interval.type == V4L2_FRMIVAL_TYPE_STEPWISE && Interval.stepwise.min.numerator > 0) {
          Fps = static_cast<int>(Interval.stepwise.min.denominator / Interval.stepwise.min.numerator);
        }
      }
      if (Fps <= 0) Fps = 30;
      FlValue* Item = fl_value_new_map();
      fl_value_set_string_take(Item, "format", fl_value_new_string(Name));
      fl_value_set_string_take(Item, "width", fl_value_new_int(Width));
      fl_value_set_string_take(Item, "height", fl_value_new_int(Height));
      fl_value_set_string_take(Item, "fps", fl_value_new_int(Fps));
      fl_value_append_take(List, Item);
    }
  }
  close(Handle);
  return List;
}

bool CaptureHost::Prepare(const std::string& Path, int RequestedWidth, int RequestedHeight, int RequestedFps, const std::string& AudioName, const std::string& AudioFifoPath, FlValue** Info, std::string* Error) {
  Release();
  Fd = open(Path.c_str(), O_RDWR | O_NONBLOCK);
  if (Fd < 0) {
    *Error = "无法打开采集设备：" + Path;
    return false;
  }
  v4l2_format Format{};
  Format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  Format.fmt.pix.width = static_cast<uint32_t>(RequestedWidth);
  Format.fmt.pix.height = static_cast<uint32_t>(RequestedHeight);
  Format.fmt.pix.pixelformat = V4L2_PIX_FMT_NV12;
  Format.fmt.pix.field = V4L2_FIELD_ANY;
  if (Xioctl(Fd, VIDIOC_S_FMT, &Format) < 0) {
    Format = v4l2_format{};
    Format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    Format.fmt.pix.width = static_cast<uint32_t>(RequestedWidth);
    Format.fmt.pix.height = static_cast<uint32_t>(RequestedHeight);
    Format.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    Format.fmt.pix.field = V4L2_FIELD_ANY;
    if (Xioctl(Fd, VIDIOC_S_FMT, &Format) < 0) {
      *Error = "设备不支持 NV12 或 YUYV 采集格式";
      Release();
      return false;
    }
  }
  Width = static_cast<int>(Format.fmt.pix.width);
  Height = static_cast<int>(Format.fmt.pix.height);
  Stride = static_cast<int>(Format.fmt.pix.bytesperline);
  PixelFormat = Format.fmt.pix.pixelformat;
  if (Stride <= 0) Stride = Width;
  int Fps = RequestedFps > 0 ? RequestedFps : 30;
  v4l2_streamparm Params{};
  Params.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  Params.parm.capture.timeperframe.numerator = 1;
  Params.parm.capture.timeperframe.denominator = static_cast<uint32_t>(Fps);
  Xioctl(Fd, VIDIOC_S_PARM, &Params);
  v4l2_requestbuffers Request{};
  Request.count = 4;
  Request.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  Request.memory = V4L2_MEMORY_MMAP;
  if (Xioctl(Fd, VIDIOC_REQBUFS, &Request) < 0 || Request.count < 1) {
    *Error = "无法申请采集缓冲区";
    Release();
    return false;
  }
  Buffers.resize(Request.count);
  for (uint32_t Index = 0; Index < Request.count; Index++) {
    v4l2_buffer Buffer{};
    Buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    Buffer.memory = V4L2_MEMORY_MMAP;
    Buffer.index = Index;
    if (Xioctl(Fd, VIDIOC_QUERYBUF, &Buffer) < 0) {
      *Error = "无法查询采集缓冲区";
      Release();
      return false;
    }
    void* Mapped = mmap(nullptr, Buffer.length, PROT_READ | PROT_WRITE, MAP_SHARED, Fd, Buffer.m.offset);
    if (Mapped == MAP_FAILED) {
      *Error = "无法映射采集缓冲区";
      Release();
      return false;
    }
    Buffers[Index].Start = Mapped;
    Buffers[Index].Length = Buffer.length;
  }
  Frame.resize(static_cast<size_t>(Width) * Height * 3 / 2);
  AudioDevice = AudioName;
  AudioFifo.clear();
  if (!AudioName.empty() && !AudioFifoPath.empty()) {
    unlink(AudioFifoPath.c_str());
    if (mkfifo(AudioFifoPath.c_str(), 0666) == 0) {
      AudioFifo = AudioFifoPath;
    }
  }
  FlValue* Map = fl_value_new_map();
  fl_value_set_string_take(Map, "width", fl_value_new_int(Width));
  fl_value_set_string_take(Map, "height", fl_value_new_int(Height));
  fl_value_set_string_take(Map, "fps", fl_value_new_int(Fps));
  fl_value_set_string_take(Map, "fpsNum", fl_value_new_int(Fps));
  fl_value_set_string_take(Map, "fpsDen", fl_value_new_int(1));
  fl_value_set_string_take(Map, "format", fl_value_new_string(PixelFormat == V4L2_PIX_FMT_NV12 ? "nv12" : "yuy2"));
  fl_value_set_string_take(Map, "audioFifo", fl_value_new_string(AudioFifo.c_str()));
  *Info = Map;
  return true;
}

bool CaptureHost::Start(const std::string& Exe, const std::vector<std::string>& Args, std::string* Error) {
  if (Fd < 0) {
    *Error = "采集设备未准备";
    return false;
  }
  int Pipe[2];
  if (pipe(Pipe) != 0) {
    *Error = "无法创建编码管道";
    return false;
  }
  pid_t Pid = fork();
  if (Pid == 0) {
    dup2(Pipe[0], STDIN_FILENO);
    close(Pipe[0]);
    close(Pipe[1]);
    std::vector<char*> Argv;
    Argv.push_back(const_cast<char*>(Exe.c_str()));
    for (const std::string& Item : Args) Argv.push_back(const_cast<char*>(Item.c_str()));
    Argv.push_back(nullptr);
    execv(Exe.c_str(), Argv.data());
    _exit(127);
  }
  if (Pid < 0) {
    close(Pipe[0]);
    close(Pipe[1]);
    *Error = "无法启动编码进程";
    return false;
  }
  close(Pipe[0]);
  PipeFd = Pipe[1];
  Child = Pid;
  for (size_t Index = 0; Index < Buffers.size(); Index++) {
    v4l2_buffer Buffer{};
    Buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    Buffer.memory = V4L2_MEMORY_MMAP;
    Buffer.index = static_cast<uint32_t>(Index);
    Xioctl(Fd, VIDIOC_QBUF, &Buffer);
  }
  v4l2_buf_type Type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  if (Xioctl(Fd, VIDIOC_STREAMON, &Type) < 0) {
    *Error = "无法启动采集流";
    Release();
    return false;
  }
  Running = true;
  Frames = 0;
  LastTick = std::chrono::steady_clock::now();
  Worker = std::thread(&CaptureHost::FrameLoop, this);
  if (!AudioFifo.empty()) {
    AudioRunning = true;
    AudioWorker = std::thread(&CaptureHost::AudioLoop, this);
  }
  SendState("recording");
  return true;
}

void CaptureHost::FrameLoop() {
  while (Running) {
    pollfd Poll{};
    Poll.fd = Fd;
    Poll.events = POLLIN;
    int Ready = poll(&Poll, 1, 500);
    if (Ready <= 0) continue;
    v4l2_buffer Buffer{};
    Buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    Buffer.memory = V4L2_MEMORY_MMAP;
    if (Xioctl(Fd, VIDIOC_DQBUF, &Buffer) < 0) continue;
    if (Buffer.index < Buffers.size()) {
      Convert(static_cast<const uint8_t*>(Buffers[Buffer.index].Start));
      if (!WriteFrame()) {
        Xioctl(Fd, VIDIOC_QBUF, &Buffer);
        SendError("写入编码进程失败");
        break;
      }
      Frames++;
    }
    Xioctl(Fd, VIDIOC_QBUF, &Buffer);
    auto Now = std::chrono::steady_clock::now();
    if (std::chrono::duration_cast<std::chrono::seconds>(Now - LastTick).count() >= 1) {
      SendStats();
      LastTick = Now;
    }
  }
}

void CaptureHost::Convert(const uint8_t* Source) {
  if (PixelFormat == V4L2_PIX_FMT_NV12) {
    for (int Row = 0; Row < Height; Row++) {
      memcpy(Frame.data() + static_cast<size_t>(Row) * Width, Source + static_cast<size_t>(Row) * Stride, Width);
    }
    const uint8_t* UV = Source + static_cast<size_t>(Stride) * Height;
    uint8_t* Target = Frame.data() + static_cast<size_t>(Width) * Height;
    for (int Row = 0; Row < Height / 2; Row++) {
      memcpy(Target + static_cast<size_t>(Row) * Width, UV + static_cast<size_t>(Row) * Stride, Width);
    }
    return;
  }
  uint8_t* YPlane = Frame.data();
  uint8_t* UVPlane = Frame.data() + static_cast<size_t>(Width) * Height;
  for (int Row = 0; Row + 1 < Height; Row += 2) {
    const uint8_t* Top = Source + static_cast<size_t>(Row) * Stride;
    const uint8_t* Bottom = Source + static_cast<size_t>(Row + 1) * Stride;
    uint8_t* YTop = YPlane + static_cast<size_t>(Row) * Width;
    uint8_t* YBottom = YTop + Width;
    uint8_t* UV = UVPlane + static_cast<size_t>(Row / 2) * Width;
    for (int Column = 0; Column + 3 < Stride && Column + 3 < Width * 2; Column += 4) {
      int Index = Column / 2;
      YTop[Index] = Top[Column];
      YTop[Index + 1] = Top[Column + 2];
      YBottom[Index] = Bottom[Column];
      YBottom[Index + 1] = Bottom[Column + 2];
      UV[Index] = static_cast<uint8_t>((Top[Column + 1] + Bottom[Column + 1]) / 2);
      UV[Index + 1] = static_cast<uint8_t>((Top[Column + 3] + Bottom[Column + 3]) / 2);
    }
  }
}

bool CaptureHost::WriteFrame() {
  if (PipeFd < 0) return false;
  size_t Total = Frame.size();
  size_t Offset = 0;
  while (Offset < Total) {
    ssize_t Count = write(PipeFd, Frame.data() + Offset, Total - Offset);
    if (Count > 0) {
      Offset += static_cast<size_t>(Count);
      continue;
    }
    if (errno == EINTR) continue;
    return false;
  }
  return true;
}

void CaptureHost::SendState(const char* Value) {
  if (Events == nullptr) return;
  FlValue* Map = fl_value_new_map();
  fl_value_set_string_take(Map, "type", fl_value_new_string("state"));
  fl_value_set_string_take(Map, "value", fl_value_new_string(Value));
  auto* Item = new EventPayload{Events, Map};
  g_main_context_invoke(nullptr, DeliverEvent, Item);
}

void CaptureHost::SendError(const std::string& Text) {
  if (Events == nullptr) return;
  FlValue* Map = fl_value_new_map();
  fl_value_set_string_take(Map, "type", fl_value_new_string("error"));
  fl_value_set_string_take(Map, "text", fl_value_new_string(Text.c_str()));
  auto* Item = new EventPayload{Events, Map};
  g_main_context_invoke(nullptr, DeliverEvent, Item);
}

void CaptureHost::SendStats() {
  if (Events == nullptr) return;
  int Count = Frames.exchange(0);
  FlValue* Map = fl_value_new_map();
  fl_value_set_string_take(Map, "type", fl_value_new_string("stats"));
  fl_value_set_string_take(Map, "captureFps", fl_value_new_int(Count));
  fl_value_set_string_take(Map, "previewFps", fl_value_new_int(0));
  fl_value_set_string_take(Map, "latency", fl_value_new_int(0));
  fl_value_set_string_take(Map, "dropped", fl_value_new_int(0));
  fl_value_set_string_take(Map, "written", fl_value_new_int(Count));
  fl_value_set_string_take(Map, "queue", fl_value_new_int(0));
  fl_value_set_string_take(Map, "convertMs", fl_value_new_int(0));
  auto* Item = new EventPayload{Events, Map};
  g_main_context_invoke(nullptr, DeliverEvent, Item);
}

void CaptureHost::AudioLoop() {
  int Fd = -1;
  for (int Attempt = 0; Attempt < 100 && AudioRunning; Attempt++) {
    Fd = open(AudioFifo.c_str(), O_WRONLY | O_NONBLOCK);
    if (Fd >= 0) break;
    usleep(100000);
  }
  if (Fd < 0) return;
  int Flags = fcntl(Fd, F_GETFL, 0);
  fcntl(Fd, F_SETFL, Flags & ~O_NONBLOCK);
  snd_pcm_t* Pcm = nullptr;
  if (snd_pcm_open(&Pcm, AudioDevice.c_str(), SND_PCM_STREAM_CAPTURE, SND_PCM_NONBLOCK) < 0) {
    close(Fd);
    return;
  }
  snd_pcm_hw_params_t* Params = nullptr;
  snd_pcm_hw_params_alloca(&Params);
  bool Ready = snd_pcm_hw_params_any(Pcm, Params) >= 0;
  Ready = Ready && snd_pcm_hw_params_set_access(Pcm, Params, SND_PCM_ACCESS_RW_INTERLEAVED) >= 0;
  Ready = Ready && snd_pcm_hw_params_set_format(Pcm, Params, SND_PCM_FORMAT_S16_LE) >= 0;
  Ready = Ready && snd_pcm_hw_params_set_channels(Pcm, Params, 2) >= 0;
  unsigned Rate = 48000;
  Ready = Ready && snd_pcm_hw_params_set_rate_near(Pcm, Params, &Rate, nullptr) >= 0;
  Ready = Ready && snd_pcm_hw_params(Pcm, Params) >= 0;
  if (!Ready) {
    snd_pcm_close(Pcm);
    close(Fd);
    return;
  }
  short Buffer[1024 * 2];
  while (AudioRunning) {
    snd_pcm_sframes_t Frames = snd_pcm_readi(Pcm, Buffer, 1024);
    if (Frames == -EPIPE) {
      snd_pcm_prepare(Pcm);
      continue;
    }
    if (Frames == -EAGAIN) {
      usleep(5000);
      continue;
    }
    if (Frames <= 0) continue;
    size_t Total = static_cast<size_t>(Frames) * 4;
    size_t Offset = 0;
    const char* Data = reinterpret_cast<const char*>(Buffer);
    while (Offset < Total) {
      ssize_t Count = write(Fd, Data + Offset, Total - Offset);
      if (Count > 0) {
        Offset += static_cast<size_t>(Count);
        continue;
      }
      if (errno == EINTR) continue;
      Offset = Total;
      AudioRunning = false;
    }
  }
  snd_pcm_close(Pcm);
  close(Fd);
}
void CaptureHost::Stop(bool Fast) {
  if (Running.exchange(false)) {
    if (Worker.joinable()) Worker.join();
  }
  Release();
  SendState("idle");
}

void CaptureHost::Release() {
  Running = false;
  AudioRunning = false;
  if (AudioWorker.joinable()) AudioWorker.join();
  if (!AudioFifo.empty()) {
    unlink(AudioFifo.c_str());
    AudioFifo.clear();
  }
  if (Worker.joinable()) Worker.join();
  if (Fd >= 0) {
    v4l2_buf_type Type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    Xioctl(Fd, VIDIOC_STREAMOFF, &Type);
    for (MapBuffer& Buffer : Buffers) {
      if (Buffer.Start != nullptr) munmap(Buffer.Start, Buffer.Length);
    }
    Buffers.clear();
    close(Fd);
    Fd = -1;
  }
  if (PipeFd >= 0) {
    close(PipeFd);
    PipeFd = -1;
  }
  if (Child > 0) {
    int Status = 0;
    kill(Child, SIGTERM);
    waitpid(Child, &Status, 0);
    Child = -1;
  }
  Frame.clear();
}

CaptureHost* Host = nullptr;
FlEventChannel* EventChannelRef = nullptr;

FlMethodErrorResponse* ListenCallback(FlEventChannel* Channel, FlValue* Arguments, gpointer UserData) {
  return nullptr;
}

FlMethodErrorResponse* CancelCallback(FlEventChannel* Channel, FlValue* Arguments, gpointer UserData) {
  return nullptr;
}

void MethodCallCallback(FlMethodChannel* Channel, FlMethodCall* Call, gpointer UserData) {
  auto* HostRef = static_cast<CaptureHost*>(UserData);
  const gchar* Method = fl_method_call_get_name(Call);
  FlValue* Args = fl_method_call_get_args(Call);
  g_autoptr(FlMethodResponse) Response = nullptr;
  std::string Name = Method == nullptr ? std::string() : std::string(Method);
  if (Name == "Enumerate") {
    Response = FL_METHOD_RESPONSE(fl_method_success_response_new(HostRef->Enumerate()));
  } else if (Name == "Modes") {
    Response = FL_METHOD_RESPONSE(fl_method_success_response_new(HostRef->Modes(ValueString(Args, "device"))));
  } else if (Name == "Prepare") {
    FlValue* Info = nullptr;
    std::string Error;
    if (HostRef->Prepare(ValueString(Args, "device"), ValueInt(Args, "width", 1920), ValueInt(Args, "height", 1080), ValueInt(Args, "fps", 30), ValueString(Args, "audioDevice"), ValueString(Args, "audioFifo"), &Info, &Error)) {
      Response = FL_METHOD_RESPONSE(fl_method_success_response_new(Info));
    } else {
      Response = FL_METHOD_RESPONSE(fl_method_error_response_new("capture", Error.c_str(), nullptr));
    }
  } else if (Name == "Start") {
    std::vector<std::string> Items;
    FlValue* List = Args == nullptr ? nullptr : fl_value_lookup_string(Args, "args");
    if (List != nullptr && fl_value_get_type(List) == FL_VALUE_TYPE_LIST) {
      for (size_t Index = 0; Index < fl_value_get_length(List); Index++) {
        FlValue* Item = fl_value_get_list_value(List, Index);
        if (Item != nullptr && fl_value_get_type(Item) == FL_VALUE_TYPE_STRING) {
          Items.push_back(std::string(fl_value_get_string(Item)));
        }
      }
    }
    std::string Error;
    if (HostRef->Start(ValueString(Args, "exe"), Items, &Error)) {
      Response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else {
      Response = FL_METHOD_RESPONSE(fl_method_error_response_new("capture", Error.c_str(), nullptr));
    }
  } else if (Name == "Stop") {
    HostRef->Stop(true);
    Response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (Name == "PreviewTexture") {
    Response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_int(-1)));
  } else if (Name == "PreviewState") {
    Response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_map()));
  } else if (Name == "Snapshot" || Name == "Mask" || Name == "OpenMaskPipe" || Name == "CloseMaskPipe") {
    Response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    Response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(Call, Response, nullptr);
}

}

void linux_capture_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  Host = new CaptureHost();
  g_autoptr(FlStandardMethodCodec) Codec = fl_standard_method_codec_new();
  FlMethodChannel* Channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), "splatoon3record/capture", FL_METHOD_CODEC(Codec));
  fl_method_channel_set_method_call_handler(Channel, MethodCallCallback, Host, nullptr);
  EventChannelRef = fl_event_channel_new(fl_plugin_registrar_get_messenger(registrar), "splatoon3record/capture/events", FL_METHOD_CODEC(Codec));
  fl_event_channel_set_stream_handlers(EventChannelRef, ListenCallback, CancelCallback, nullptr, nullptr);
  Host->SetEventChannel(EventChannelRef);
}
