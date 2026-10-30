#include "recorder.h"

#include <mfapi.h>
#include <mferror.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

namespace Capture {

namespace {

constexpr LONGLONG TicksPerSecond = 10000000LL;
constexpr size_t MaxQueuedBytes = 192ULL * 1024ULL * 1024ULL;
constexpr size_t MaxQueuedItems = 240;

HRESULT CreateVideoOutput(const CaptureRecorder::Options& Config, long long Bitrate, IMFMediaType** Out) {
  IMFMediaType* Type = nullptr;
  HRESULT Result = MFCreateMediaType(&Type);
  if (FAILED(Result)) return Result;
  Type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  Type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  Type->SetUINT32(MF_MT_AVG_BITRATE, static_cast<UINT32>(Bitrate));
  Type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  Type->SetUINT32(MF_MT_MAX_KEYFRAME_SPACING, static_cast<UINT32>(std::max<long long>(1, std::lround(Config.Fps * 2.0))));
  MFSetAttributeSize(Type, MF_MT_FRAME_SIZE, static_cast<UINT32>(Config.Width), static_cast<UINT32>(Config.Height));
  MFSetAttributeRatio(Type, MF_MT_FRAME_RATE, static_cast<UINT32>(std::max(1, Config.FpsNumerator)), static_cast<UINT32>(std::max(1, Config.FpsDenominator)));
  MFSetAttributeRatio(Type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  *Out = Type;
  return S_OK;
}

HRESULT CreateVideoInput(const CaptureRecorder::Options& Config, IMFMediaType** Out) {
  IMFMediaType* Type = nullptr;
  HRESULT Result = MFCreateMediaType(&Type);
  if (FAILED(Result)) return Result;
  Type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  Type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  Type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  Type->SetUINT32(MF_MT_DEFAULT_STRIDE, static_cast<UINT32>(Config.Width));
  MFSetAttributeSize(Type, MF_MT_FRAME_SIZE, static_cast<UINT32>(Config.Width), static_cast<UINT32>(Config.Height));
  MFSetAttributeRatio(Type, MF_MT_FRAME_RATE, static_cast<UINT32>(std::max(1, Config.FpsNumerator)), static_cast<UINT32>(std::max(1, Config.FpsDenominator)));
  MFSetAttributeRatio(Type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  *Out = Type;
  return S_OK;
}

HRESULT CreateAudioOutput(const CaptureRecorder::Options& Config, IMFMediaType** Out) {
  IMFMediaType* Type = nullptr;
  HRESULT Result = MFCreateMediaType(&Type);
  if (FAILED(Result)) return Result;
  Type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  Type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
  Type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, static_cast<UINT32>(Config.AudioRate));
  Type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, static_cast<UINT32>(Config.AudioChannels));
  Type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  Type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, static_cast<UINT32>(Config.AudioBitrate / 8));
  Type->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);
  Type->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);
  *Out = Type;
  return S_OK;
}

HRESULT CreateAudioInput(const CaptureRecorder::Options& Config, IMFMediaType** Out) {
  IMFMediaType* Type = nullptr;
  HRESULT Result = MFCreateMediaType(&Type);
  if (FAILED(Result)) return Result;
  Type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  Type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  Type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, static_cast<UINT32>(Config.AudioRate));
  Type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, static_cast<UINT32>(Config.AudioChannels));
  Type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  Type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, static_cast<UINT32>(Config.AudioChannels * 2));
  Type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, static_cast<UINT32>(Config.AudioRate * Config.AudioChannels * 2));
  Type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
  *Out = Type;
  return S_OK;
}

}

CaptureRecorder::Segment::~Segment() {
  Close(false);
}

CaptureRecorder::Segment::Segment(Segment&& Other) noexcept
    : ByteStream(Other.ByteStream),
      Sink(Other.Sink),
      Writer(Other.Writer),
      Path(std::move(Other.Path)),
      BaseQpc(Other.BaseQpc),
      Written(Other.Written) {
  Other.ByteStream = nullptr;
  Other.Sink = nullptr;
  Other.Writer = nullptr;
}

CaptureRecorder::Segment& CaptureRecorder::Segment::operator=(Segment&& Other) noexcept {
  if (this != &Other) {
    Close(false);
    ByteStream = Other.ByteStream;
    Sink = Other.Sink;
    Writer = Other.Writer;
    Path = std::move(Other.Path);
    BaseQpc = Other.BaseQpc;
    Written = Other.Written;
    Other.ByteStream = nullptr;
    Other.Sink = nullptr;
    Other.Writer = nullptr;
  }
  return *this;
}

void CaptureRecorder::Segment::Close(bool Remove) {
  if (Writer != nullptr) {
    Writer->Finalize();
    Writer->Release();
    Writer = nullptr;
  }
  if (Sink != nullptr) {
    Sink->Shutdown();
    Sink->Release();
    Sink = nullptr;
  }
  if (ByteStream != nullptr) {
    ByteStream->Close();
    ByteStream->Release();
    ByteStream = nullptr;
  }
  if (Remove || !Written) {
    if (!Path.empty()) DeleteFileW(Path.c_str());
  }
}

CaptureRecorder::CaptureRecorder(LogCallback OnLog, ErrorCallback OnError, FirstFrameCallback OnFirstFrame)
    : Log(std::move(OnLog)), Error(std::move(OnError)), FirstFrame(std::move(OnFirstFrame)) {}

CaptureRecorder::~CaptureRecorder() {
  Stop(true);
}

bool CaptureRecorder::Start(const Options& Value, std::string* ErrorText) {
  Stop(true);
  Config = Value;
  if (Config.Width < 2 || Config.Height < 2 || Config.Fps < 1) {
    if (ErrorText != nullptr) *ErrorText = "录制参数无效";
    return false;
  }
  if (Config.Directory.empty()) {
    if (ErrorText != nullptr) *ErrorText = "录制目录无效";
    return false;
  }
  SegmentTicks = static_cast<LONGLONG>(std::max(1, Config.SegmentSeconds)) * TicksPerSecond;
  PreopenTicks = std::max<LONGLONG>(SegmentTicks - 5 * TicksPerSecond, TicksPerSecond);
  FpsNumerator = std::max(1, Config.FpsNumerator);
  FpsDenominator = std::max(1, Config.FpsDenominator);
  DroppedFrames = 0;
  WrittenFrames = 0;
  FirstFrameSent = false;
  LastWriteDuration = 0;
  PreopenFailed = false;
  LastVideoIndex = -1;
  LastAudioTime = -1;
  QueueBytes = 0;
  Retiring.clear();
  {
    std::lock_guard<std::mutex> Lock(QueueMutex);
    Queue.clear();
  }
  if (!OpenSegment(QpcNow(), ErrorText)) return false;
  Stopping = false;
  FastStop = false;
  Running = true;
  Worker = std::thread(&CaptureRecorder::WorkerLoop, this);
  return true;
}

void CaptureRecorder::Stop(bool Fast) {
  if (!Running && !Worker.joinable()) {
    {
      std::lock_guard<std::mutex> Lock(QueueMutex);
      Queue.clear();
      QueueBytes = 0;
    }
    if (Next.valid()) {
      SegmentResult Result = Next.get();
      if (Result.Ok) Result.Value.Close(true);
    }
    if (Pending != nullptr) {
      Pending->Close(true);
      Pending.reset();
    }
    CloseSegment();
    CollectRetired();
    return;
  }
  FastStop = Fast;
  {
    std::lock_guard<std::mutex> Lock(QueueMutex);
    if (Fast) {
      Queue.clear();
      QueueBytes = 0;
    }
  }
  Stopping = true;
  Signal.notify_all();
  if (Worker.joinable()) Worker.join();
  Running = false;
  if (Next.valid()) {
    SegmentResult Result = Next.get();
    if (Result.Ok) Result.Value.Close(true);
  }
  if (Pending != nullptr) {
    Pending->Close(true);
    Pending.reset();
  }
  CloseSegment();
  CollectRetired();
}

void CaptureRecorder::PushVideo(std::shared_ptr<Frame> FrameValue) {
  if (!FrameValue || !Running || Stopping) return;
  Item Value;
  Value.Video = std::move(FrameValue);
  Value.Qpc = Value.Video->Qpc;
  const size_t Bytes = Value.Video->Data.size();
  std::lock_guard<std::mutex> Lock(QueueMutex);
  while (!Queue.empty() && (Queue.size() >= MaxQueuedItems || QueueBytes + Bytes > MaxQueuedBytes)) DropOldest();
  QueueBytes += Bytes;
  Queue.push_back(std::move(Value));
  Signal.notify_one();
}

void CaptureRecorder::PushAudio(const uint8_t* Data, size_t Size, LONGLONG Qpc) {
  if (Data == nullptr || Size == 0 || !Running || Stopping) return;
  Item Value;
  Value.Audio = true;
  Value.AudioData.assign(Data, Data + Size);
  Value.Qpc = Qpc > 0 ? Qpc : QpcNow();
  std::lock_guard<std::mutex> Lock(QueueMutex);
  while (!Queue.empty() && (Queue.size() >= MaxQueuedItems || QueueBytes + Size > MaxQueuedBytes)) DropOldest();
  QueueBytes += Size;
  Queue.push_back(std::move(Value));
  Signal.notify_one();
}

void CaptureRecorder::DropOldest() {
  if (Queue.empty()) return;
  auto Picked = Queue.begin();
  for (auto Iterator = Queue.begin(); Iterator != Queue.end(); ++Iterator) {
    if (!Iterator->Audio) {
      Picked = Iterator;
      break;
    }
  }
  if (Picked->Audio) {
    QueueBytes -= Picked->AudioData.size();
  } else if (Picked->Video) {
    QueueBytes -= Picked->Video->Data.size();
  }
  Queue.erase(Picked);
  DroppedFrames++;
}

bool CaptureRecorder::IsRunning() const {
  return Running.load() && !Stopping.load();
}

long long CaptureRecorder::Dropped() const {
  return DroppedFrames.load();
}

long long CaptureRecorder::Written() const {
  return WrittenFrames.load();
}

long long CaptureRecorder::Duplicated() const {
  return 0;
}

int CaptureRecorder::LastWriteMs() const {
  return LastWriteDuration.load();
}

int CaptureRecorder::QueueSize() const {
  std::lock_guard<std::mutex> Lock(QueueMutex);
  return static_cast<int>(Queue.size());
}

void CaptureRecorder::WorkerLoop() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
  while (true) {
    Item Value;
    {
      std::unique_lock<std::mutex> Lock(QueueMutex);
      Signal.wait_for(Lock, std::chrono::milliseconds(50), [this]() { return Stopping.load() || !Queue.empty(); });
      if (Queue.empty()) {
        if (Stopping) break;
        continue;
      }
      if (FastStop) break;
      Value = std::move(Queue.front());
      Queue.pop_front();
      QueueBytes -= Value.Audio ? Value.AudioData.size() : (Value.Video ? Value.Video->Data.size() : 0);
    }
    std::string ErrorText;
    if (!Process(Value, &ErrorText)) {
      if (Error) Error(ErrorText.empty() ? "录制编码失败" : ErrorText);
      Stopping = true;
      break;
    }
  }
  CloseSegment();
  Running = false;
  CoUninitialize();
}

void CaptureRecorder::RetireSegment(Segment Value) {
  Retiring.push_back(std::async(std::launch::async, [Value = std::move(Value)]() mutable {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    Value.Close(false);
    CoUninitialize();
  }));
}

void CaptureRecorder::CollectRetired() {
  for (std::future<void>& Task : Retiring) {
    if (Task.valid()) Task.wait();
  }
  Retiring.clear();
}

bool CaptureRecorder::Process(Item& Value, std::string* ErrorText) {
  if (Current == nullptr) {
    if (!OpenSegment(Value.Qpc, ErrorText)) return false;
  }
  if (!Current->Written && LastVideoIndex < 0 && LastAudioTime < 0) {
    Current->BaseQpc = Value.Qpc;
  }
  const LONGLONG Elapsed = Value.Qpc > Current->BaseQpc ? Value.Qpc - Current->BaseQpc : 0;
  if (Elapsed >= SegmentTicks && PreopenFailed) {
    PreopenFailed = false;
    CloseSegment();
    if (!OpenSegment(Value.Qpc, ErrorText)) return false;
  }
  if (!PreopenFailed && Elapsed >= PreopenTicks && !Next.valid() && Pending == nullptr) {
    const LONGLONG Remaining = std::max<LONGLONG>(SegmentTicks - (QpcNow() - Current->BaseQpc), 0);
    Next = std::async(std::launch::async, [this, Remaining]() {
      SegmentResult Result;
      Result.Ok = CreateSegment(QpcNow(), Remaining, Result.Value, &Result.Error);
      return Result;
    });
  }
  if (Next.valid() && Next.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready) {
    SegmentResult Result = Next.get();
    if (Result.Ok) {
      if (Elapsed >= SegmentTicks) {
        Result.Value.BaseQpc = Value.Qpc;
        RetireSegment(std::move(*Current));
        Current = std::make_unique<Segment>(std::move(Result.Value));
        LastVideoIndex = -1;
        LastAudioTime = -1;
        if (Log) Log("recorder rotate");
      } else {
        Pending = std::make_unique<Segment>(std::move(Result.Value));
      }
    } else {
      PreopenFailed = true;
      if (Error) Error(Result.Error.empty() ? "无法创建新的录制分段" : Result.Error);
    }
  }
  if (Pending != nullptr && Elapsed >= SegmentTicks) {
    Pending->BaseQpc = Value.Qpc;
    RetireSegment(std::move(*Current));
    Current = std::move(Pending);
    LastVideoIndex = -1;
    LastAudioTime = -1;
    if (Log) Log("recorder rotate");
  }
  const LONGLONG Time = Value.Qpc > Current->BaseQpc ? Value.Qpc - Current->BaseQpc : 0;
  if (!Value.Audio) return WriteVideo(Value.Video, Time, ErrorText);
  return WriteAudio(Value.AudioData, Time, ErrorText);
}

bool CaptureRecorder::WriteVideo(const std::shared_ptr<Frame>& Value, LONGLONG Time, std::string* ErrorText) {
  if (!Value || Value->Data.empty()) return true;
  if (Current == nullptr || Current->Writer == nullptr) return false;
  const size_t Size = static_cast<size_t>(Config.Width) * Config.Height * 3 / 2;
  if (Value->Data.size() < Size) return true;
  LONGLONG Index = FrameIndex(Time);
  if (Index <= LastVideoIndex) Index = LastVideoIndex + 1;
  LastVideoIndex = Index;
  const LONGLONG SampleTime = FrameTime(Index);
  const LONGLONG SampleDuration = FrameTime(Index + 1) - SampleTime;
  const auto Start = std::chrono::steady_clock::now();
  IMFMediaBuffer* Buffer = nullptr;
  IMFSample* Sample = nullptr;
  HRESULT Result = MFCreateMemoryBuffer(static_cast<DWORD>(Size), &Buffer);
  if (SUCCEEDED(Result) && Buffer != nullptr) {
    BYTE* Target = nullptr;
    Result = Buffer->Lock(&Target, nullptr, nullptr);
    if (SUCCEEDED(Result) && Target != nullptr) {
      std::memcpy(Target, Value->Data.data(), Size);
      Buffer->Unlock();
      Buffer->SetCurrentLength(static_cast<DWORD>(Size));
      Result = MFCreateSample(&Sample);
      if (SUCCEEDED(Result) && Sample != nullptr) {
        Sample->AddBuffer(Buffer);
        Sample->SetSampleTime(SampleTime);
        Sample->SetSampleDuration(SampleDuration);
        Result = Current->Writer->WriteSample(0, Sample);
      }
    } else {
      Buffer->Unlock();
    }
  }
  if (Sample != nullptr) Sample->Release();
  if (Buffer != nullptr) Buffer->Release();
  const auto End = std::chrono::steady_clock::now();
  LastWriteDuration.store(static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(End - Start).count()));
  if (FAILED(Result)) {
    if (ErrorText != nullptr) *ErrorText = "写入视频帧失败：" + FormatError(Result);
    return false;
  }
  Current->Written = true;
  WrittenFrames++;
  if (!FirstFrameSent.exchange(true) && FirstFrame) FirstFrame();
  return true;
}

bool CaptureRecorder::WriteAudio(const std::vector<uint8_t>& Value, LONGLONG Time, std::string* ErrorText) {
  if (Value.empty()) return true;
  if (Current == nullptr || Current->Writer == nullptr) return false;
  const size_t BlockAlign = static_cast<size_t>(Config.AudioChannels) * 2;
  if (Value.size() % BlockAlign != 0) return true;
  LONGLONG SampleTime = Time;
  const LONGLONG Duration = static_cast<LONGLONG>(Value.size() / BlockAlign) * TicksPerSecond / Config.AudioRate;
  if (SampleTime <= LastAudioTime) SampleTime = LastAudioTime + Duration;
  LastAudioTime = SampleTime;
  const auto Start = std::chrono::steady_clock::now();
  IMFMediaBuffer* Buffer = nullptr;
  IMFSample* Sample = nullptr;
  HRESULT Result = MFCreateMemoryBuffer(static_cast<DWORD>(Value.size()), &Buffer);
  if (SUCCEEDED(Result) && Buffer != nullptr) {
    BYTE* Target = nullptr;
    Result = Buffer->Lock(&Target, nullptr, nullptr);
    if (SUCCEEDED(Result) && Target != nullptr) {
      std::memcpy(Target, Value.data(), Value.size());
      Buffer->Unlock();
      Buffer->SetCurrentLength(static_cast<DWORD>(Value.size()));
      Result = MFCreateSample(&Sample);
      if (SUCCEEDED(Result) && Sample != nullptr) {
        Sample->AddBuffer(Buffer);
        Sample->SetSampleTime(SampleTime);
        Sample->SetSampleDuration(Duration);
        Result = Current->Writer->WriteSample(1, Sample);
      }
    } else {
      Buffer->Unlock();
    }
  }
  if (Sample != nullptr) Sample->Release();
  if (Buffer != nullptr) Buffer->Release();
  const auto End = std::chrono::steady_clock::now();
  LastWriteDuration.store(static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(End - Start).count()));
  if (FAILED(Result)) {
    if (ErrorText != nullptr) *ErrorText = "写入音频数据失败：" + FormatError(Result);
    return false;
  }
  Current->Written = true;
  return true;
}

bool CaptureRecorder::OpenSegment(LONGLONG BaseQpc, std::string* ErrorText) {
  Segment Value;
  if (!CreateSegment(BaseQpc, 0, Value, ErrorText)) return false;
  Current = std::make_unique<Segment>(std::move(Value));
  LastVideoIndex = -1;
  LastAudioTime = -1;
  return true;
}

LONGLONG CaptureRecorder::FrameIndex(LONGLONG Elapsed) const {
  if (Elapsed <= 0) return 0;
  const long double Value = static_cast<long double>(Elapsed) * FpsNumerator / (static_cast<long double>(TicksPerSecond) * FpsDenominator);
  return static_cast<LONGLONG>(std::llround(Value));
}

LONGLONG CaptureRecorder::FrameTime(LONGLONG Index) const {
  if (Index <= 0) return 0;
  const long double Value = static_cast<long double>(Index) * TicksPerSecond * FpsDenominator / FpsNumerator;
  return static_cast<LONGLONG>(std::llround(Value));
}

bool CaptureRecorder::CreateSegment(LONGLONG BaseQpc, LONGLONG DelayTicks, Segment& Out, std::string* ErrorText) {
  Segment Value;
  Value.BaseQpc = BaseQpc;
  Value.Path = BuildPath(DelayTicks);
  HRESULT Result = MFCreateFile(MF_ACCESSMODE_WRITE, MF_OPENMODE_DELETE_IF_EXIST, MF_FILEFLAGS_NONE, Value.Path.c_str(), &Value.ByteStream);
  if (FAILED(Result) || Value.ByteStream == nullptr) {
    if (ErrorText != nullptr) *ErrorText = "无法创建录制文件：" + FormatError(Result);
    Value.Close(true);
    return false;
  }
  IMFMediaType* VideoOut = nullptr;
  IMFMediaType* AudioOut = nullptr;
  if (FAILED(CreateVideoOutput(Config, Bitrate(), &VideoOut))) {
    if (ErrorText != nullptr) *ErrorText = "无法创建视频输出格式";
    Value.Close(true);
    return false;
  }
  if (Config.Audio && FAILED(CreateAudioOutput(Config, &AudioOut))) {
    if (ErrorText != nullptr) *ErrorText = "无法创建音频输出格式";
    VideoOut->Release();
    Value.Close(true);
    return false;
  }
  Result = MFCreateFMPEG4MediaSink(Value.ByteStream, VideoOut, AudioOut, &Value.Sink);
  VideoOut->Release();
  if (AudioOut != nullptr) AudioOut->Release();
  if (FAILED(Result) || Value.Sink == nullptr) {
    if (ErrorText != nullptr) *ErrorText = "无法创建 MP4 封装：" + FormatError(Result);
    Value.Close(true);
    return false;
  }
  IMFAttributes* Attributes = nullptr;
  Result = MFCreateAttributes(&Attributes, 4);
  if (SUCCEEDED(Result) && Attributes != nullptr) {
    Attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
    Attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
  }
  Result = MFCreateSinkWriterFromMediaSink(Value.Sink, Attributes, &Value.Writer);
  if (Attributes != nullptr) Attributes->Release();
  if (FAILED(Result) || Value.Writer == nullptr) {
    if (ErrorText != nullptr) *ErrorText = "无法创建录制编码器：" + FormatError(Result);
    Value.Close(true);
    return false;
  }
  IMFMediaType* VideoIn = nullptr;
  if (FAILED(CreateVideoInput(Config, &VideoIn))) {
    if (ErrorText != nullptr) *ErrorText = "无法创建视频输入格式";
    Value.Close(true);
    return false;
  }
  Result = Value.Writer->SetInputMediaType(0, VideoIn, nullptr);
  VideoIn->Release();
  if (FAILED(Result)) {
    if (ErrorText != nullptr) *ErrorText = "无法配置视频编码输入：" + FormatError(Result);
    Value.Close(true);
    return false;
  }
  if (Config.Audio) {
    IMFMediaType* AudioIn = nullptr;
    if (FAILED(CreateAudioInput(Config, &AudioIn))) {
      if (ErrorText != nullptr) *ErrorText = "无法创建音频输入格式";
      Value.Close(true);
      return false;
    }
    Result = Value.Writer->SetInputMediaType(1, AudioIn, nullptr);
    AudioIn->Release();
    if (FAILED(Result)) {
      if (ErrorText != nullptr) *ErrorText = "无法配置音频编码输入：" + FormatError(Result);
      Value.Close(true);
      return false;
    }
  }
  Result = Value.Writer->BeginWriting();
  if (FAILED(Result)) {
    if (ErrorText != nullptr) *ErrorText = "无法开始录制编码：" + FormatError(Result);
    Value.Close(true);
    return false;
  }
  Out = std::move(Value);
  if (Log) Log("recorder segment " + ToUtf8(Out.Path));
  return true;
}

void CaptureRecorder::CloseSegment() {
  if (Current != nullptr) {
    Current->Close(false);
    Current.reset();
  }
}

std::wstring CaptureRecorder::BuildPath(LONGLONG DelayTicks) const {
  FILETIME Now{};
  GetSystemTimeAsFileTime(&Now);
  ULARGE_INTEGER Value{};
  Value.LowPart = Now.dwLowDateTime;
  Value.HighPart = Now.dwHighDateTime;
  Value.QuadPart += static_cast<ULONGLONG>(std::max<LONGLONG>(DelayTicks, 0));
  FILETIME Future{};
  Future.dwLowDateTime = Value.LowPart;
  Future.dwHighDateTime = Value.HighPart;
  FILETIME Local{};
  FileTimeToLocalFileTime(&Future, &Local);
  SYSTEMTIME Time{};
  FileTimeToSystemTime(&Local, &Time);
  wchar_t Name[64];
  swprintf_s(Name, L"Cache-%04u%02u%02u-%02u%02u%02u.mp4", Time.wYear, Time.wMonth, Time.wDay, Time.wHour, Time.wMinute, Time.wSecond);
  std::wstring Directory = Config.Directory;
  if (!Directory.empty() && Directory.back() != L'\\' && Directory.back() != L'/') Directory.push_back(L'\\');
  return Directory + Name;
}

long long CaptureRecorder::Bitrate() const {
  const double Pixels = static_cast<double>(Config.Width) * Config.Height;
  double Ratio = 0.20 - Config.Quality * 0.0045;
  if (Ratio < 0.05) Ratio = 0.05;
  if (Ratio > 0.18) Ratio = 0.18;
  long long Value = static_cast<long long>(Pixels * Config.Fps * Ratio);
  if (Value < 6000000LL) Value = 6000000LL;
  if (Value > 80000000LL) Value = 80000000LL;
  return Value;
}

}
