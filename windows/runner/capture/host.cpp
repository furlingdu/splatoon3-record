#include "host.h"

#include "devices.h"
#include "binary_messenger_impl.h"

#include <mfapi.h>

#include <algorithm>
#include <cstring>

namespace Capture {

namespace {

const flutter::EncodableValue* FindValue(const flutter::EncodableMap& Map, const char* Key) {
  const auto Iterator = Map.find(flutter::EncodableValue(Key));
  return Iterator == Map.end() ? nullptr : &Iterator->second;
}

std::string StringValue(const flutter::EncodableMap& Map, const char* Key, const std::string& Default = std::string()) {
  const flutter::EncodableValue* Value = FindValue(Map, Key);
  if (Value == nullptr) return Default;
  const auto* Text = std::get_if<std::string>(Value);
  return Text == nullptr ? Default : *Text;
}

int IntValue(const flutter::EncodableMap& Map, const char* Key, int Default = 0) {
  const flutter::EncodableValue* Value = FindValue(Map, Key);
  if (Value == nullptr) return Default;
  const auto Number = Value->TryGetLongValue();
  return Number.has_value() ? static_cast<int>(*Number) : Default;
}

double DoubleValue(const flutter::EncodableMap& Map, const char* Key, double Default = 0.0) {
  const flutter::EncodableValue* Value = FindValue(Map, Key);
  if (Value == nullptr) return Default;
  if (const auto* Number = std::get_if<double>(Value)) return *Number;
  const auto Integer = Value->TryGetLongValue();
  return Integer.has_value() ? static_cast<double>(*Integer) : Default;
}

bool BoolValue(const flutter::EncodableMap& Map, const char* Key, bool Default = false) {
  const flutter::EncodableValue* Value = FindValue(Map, Key);
  if (Value == nullptr) return Default;
  const auto* Flag = std::get_if<bool>(Value);
  return Flag == nullptr ? Default : *Flag;
}

flutter::EncodableValue DeviceMap(const DeviceInfo& Info) {
  flutter::EncodableMap Value;
  Value[flutter::EncodableValue("id")] = flutter::EncodableValue(ToUtf8(Info.Id));
  Value[flutter::EncodableValue("name")] = flutter::EncodableValue(ToUtf8(Info.Name));
  Value[flutter::EncodableValue("kind")] = flutter::EncodableValue(Info.Audio ? "audio" : "video");
  Value[flutter::EncodableValue("link")] = flutter::EncodableValue(ToUtf8(Info.Link));
  return flutter::EncodableValue(Value);
}

flutter::EncodableValue ModeMap(const ModeInfo& Info) {
  flutter::EncodableMap Value;
  Value[flutter::EncodableValue("format")] = flutter::EncodableValue(Info.Format);
  Value[flutter::EncodableValue("width")] = flutter::EncodableValue(Info.Width);
  Value[flutter::EncodableValue("height")] = flutter::EncodableValue(Info.Height);
  Value[flutter::EncodableValue("fps")] = flutter::EncodableValue(Info.Fps);
  Value[flutter::EncodableValue("fpsNum")] = flutter::EncodableValue(Info.FpsNumerator);
  Value[flutter::EncodableValue("fpsDen")] = flutter::EncodableValue(Info.FpsDenominator);
  return flutter::EncodableValue(Value);
}

}

class CaptureHost::EventStreamHandler : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  explicit EventStreamHandler(CaptureHost* HostValue) : Host(HostValue) {}

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnListenInternal(
      const flutter::EncodableValue* Arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& Sink) override {
    (void)Arguments;
    Host->AttachSink(std::move(Sink));
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnCancelInternal(const flutter::EncodableValue* Arguments) override {
    (void)Arguments;
    Host->DetachSink();
    return nullptr;
  }

 private:
  CaptureHost* Host = nullptr;
};

CaptureHost::CaptureHost(FlutterDesktopPluginRegistrarRef Registrar) {
  RegistrarRef = Registrar;
  TextureRegistrarRef = FlutterDesktopRegistrarGetTextureRegistrar(Registrar);
  Messenger = std::make_unique<flutter::BinaryMessengerImpl>(FlutterDesktopPluginRegistrarGetMessenger(Registrar));
  MfStarted = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE));
  SharedFrames = std::make_shared<Shared>();
  SharedFrames->Open();
  Texture = std::make_unique<PreviewTexture>(TextureRegistrarRef, SharedFrames);
  Texture->Start();
  Engine = std::make_unique<CaptureEngine>(
      SharedFrames,
      [this](const std::string& Value) {
        SendState(Value);
      },
      [this](const std::string& Text) {
        SendError(Text);
        SendState("error");
      },
      [this](const std::string& Text) {
        SendLog(Text);
      },
      [this](int CaptureRate, int PreviewRate, int Latency, int ConvertMs, long long Dropped, long long Written, long long Duplicated, int WriteMs, int Queue) {
        flutter::EncodableMap Value;
        Value[flutter::EncodableValue("type")] = flutter::EncodableValue("stats");
        Value[flutter::EncodableValue("captureFps")] = flutter::EncodableValue(CaptureRate);
        Value[flutter::EncodableValue("previewFps")] = flutter::EncodableValue(PreviewRate);
        Value[flutter::EncodableValue("latency")] = flutter::EncodableValue(Latency);
        Value[flutter::EncodableValue("convertMs")] = flutter::EncodableValue(ConvertMs);
        Value[flutter::EncodableValue("dropped")] = flutter::EncodableValue(Dropped);
        Value[flutter::EncodableValue("written")] = flutter::EncodableValue(Written);
        Value[flutter::EncodableValue("duplicated")] = flutter::EncodableValue(Duplicated);
        Value[flutter::EncodableValue("writeMs")] = flutter::EncodableValue(WriteMs);
        Value[flutter::EncodableValue("queue")] = flutter::EncodableValue(Queue);
        SendEvent(std::move(Value));
      });
  Channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(Messenger.get(), "splatoon3record/capture", &flutter::StandardMethodCodec::GetInstance());
  Channel->SetMethodCallHandler([this](const flutter::MethodCall<flutter::EncodableValue>& Call, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> Result) {
    HandleMethod(Call, std::move(Result));
  });
  Events = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(Messenger.get(), "splatoon3record/capture/events", &flutter::StandardMethodCodec::GetInstance());
  Events->SetStreamHandler(std::make_unique<EventStreamHandler>(this));
  LifecycleThread = std::thread(&CaptureHost::LifecycleLoop, this);
}

CaptureHost::~CaptureHost() {
  if (Channel) Channel->SetMethodCallHandler(nullptr);
  if (Events) Events->SetStreamHandler(nullptr);
  DetachSink();
  {
    std::lock_guard<std::mutex> Lock(TaskMutex);
    ShuttingDown = true;
  }
  TaskSignal.notify_all();
  if (LifecycleThread.joinable()) LifecycleThread.join();
  {
    std::lock_guard<std::mutex> Lock(EngineMutex);
    if (Engine) Engine->Stop(true);
  }
  if (Engine) Engine->SetMaskWriter(nullptr);
  MaskWriter.reset();
  if (Texture) Texture->Stop();
  Engine.reset();
  if (SharedFrames) SharedFrames->Close();
  SharedFrames.reset();
  Texture.reset();
  Events.reset();
  Channel.reset();
  Messenger.reset();
  if (MfStarted) MFShutdown();
}

void CaptureHost::HandleMethod(const flutter::MethodCall<flutter::EncodableValue>& Call, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> Result) {
  const std::string& Method = Call.method_name();
  const auto* Arguments = Call.arguments();
  if (Method == "Enumerate") {
    std::vector<DeviceInfo> Devices;
    Devices::Enumerate(Devices);
    flutter::EncodableList List;
    for (const DeviceInfo& Info : Devices) List.push_back(DeviceMap(Info));
    Result->Success(flutter::EncodableValue(List));
    return;
  }
  if (Method == "Modes") {
    const auto* Map = Arguments == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(Arguments);
    std::vector<ModeInfo> Modes;
    if (Map != nullptr) Devices::Modes(FromUtf8(StringValue(*Map, "device")), Modes);
    flutter::EncodableList List;
    for (const ModeInfo& Info : Modes) List.push_back(ModeMap(Info));
    Result->Success(flutter::EncodableValue(List));
    return;
  }
  if (Method == "Prepare") {
    const auto* Map = Arguments == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(Arguments);
    if (Map == nullptr) {
      Result->Error("prepare", "缺少采集配置");
      return;
    }
    Config Value;
    Value.Device = FromUtf8(StringValue(*Map, "device"));
    Value.Width = IntValue(*Map, "width", 1920);
    Value.Height = IntValue(*Map, "height", 1080);
    Value.Fps = IntValue(*Map, "fps", 60);
    Value.Format = StringValue(*Map, "format", "nv12");
    bool Ok = false;
    std::string ErrorText;
    {
      std::lock_guard<std::mutex> Lock(EngineMutex);
      Ok = Engine->Prepare(Value);
      ErrorText = Engine->LastError();
    }
    if (!Ok) {
      Result->Error("prepare", ErrorText);
      return;
    }
    const ModeInfo& Actual = Engine->Actual();
    flutter::EncodableMap Response;
    Response[flutter::EncodableValue("width")] = flutter::EncodableValue(Actual.Width);
    Response[flutter::EncodableValue("height")] = flutter::EncodableValue(Actual.Height);
    Response[flutter::EncodableValue("fps")] = flutter::EncodableValue(Actual.Fps);
    Response[flutter::EncodableValue("fpsNum")] = flutter::EncodableValue(Actual.FpsNumerator);
    Response[flutter::EncodableValue("fpsDen")] = flutter::EncodableValue(Actual.FpsDenominator);
    Response[flutter::EncodableValue("format")] = flutter::EncodableValue(Actual.Format);
    Result->Success(flutter::EncodableValue(Response));
    return;
  }
  if (Method == "Start") {
    const auto* Map = Arguments == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(Arguments);
    if (Map == nullptr) {
      Result->Error("start", "缺少启动参数");
      return;
    }
    const std::wstring Exe = FromUtf8(StringValue(*Map, "exe"));
    std::vector<std::string> Args;
    const flutter::EncodableValue* ListValue = FindValue(*Map, "args");
    if (ListValue != nullptr) {
      const auto* List = std::get_if<flutter::EncodableList>(ListValue);
      if (List != nullptr) {
        for (const flutter::EncodableValue& Item : *List) {
          const auto* Text = std::get_if<std::string>(&Item);
          if (Text != nullptr) Args.push_back(*Text);
        }
      }
    }
    const double Fps = DoubleValue(*Map, "fps", 60.0);
    const bool UseWriter = BoolValue(*Map, "writer", true);
    PostTask([this, Exe, Args, Fps, UseWriter]() {
      std::lock_guard<std::mutex> Lock(EngineMutex);
      if (!Engine->Start(Exe, Args, Fps, UseWriter)) {
        SendError(Engine->LastError());
        SendState("error");
      }
    });
    Result->Success(flutter::EncodableValue(true));
    return;
  }
  if (Method == "Stop") {
    const auto* Map = Arguments == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(Arguments);
    const bool Fast = Map != nullptr && BoolValue(*Map, "fast", false);
    PostTask([this, Fast]() {
      {
        std::lock_guard<std::mutex> Lock(EngineMutex);
        Engine->Stop(Fast);
      }
      SendState("idle");
    });
    Result->Success(flutter::EncodableValue(true));
    return;
  }
  if (Method == "PreviewTexture") {
    Result->Success(flutter::EncodableValue(Texture ? Texture->Id() : static_cast<int64_t>(-1)));
    return;
  }
  if (Method == "PreviewState") {
    flutter::EncodableMap Value;
    Value[flutter::EncodableValue("active")] = flutter::EncodableValue(SharedFrames && SharedFrames->IsActive() && SharedFrames->IsRecent(3000));
    Value[flutter::EncodableValue("publish")] = flutter::EncodableValue(SharedFrames ? static_cast<int>(SharedFrames->PublishCount()) : 0);
    Value[flutter::EncodableValue("sequence")] = flutter::EncodableValue(SharedFrames ? SharedFrames->LatestSequence() : 0);
    Value[flutter::EncodableValue("width")] = flutter::EncodableValue(PreviewWidth);
    Value[flutter::EncodableValue("height")] = flutter::EncodableValue(PreviewHeight);
    Result->Success(flutter::EncodableValue(Value));
    return;
  }
  if (Method == "Snapshot") {
    std::vector<uint8_t> Frame;
    uint32_t Sequence = 0;
    bool Ok = false;
    {
      std::lock_guard<std::mutex> Lock(EngineMutex);
      Ok = Engine->Snapshot(Frame, Sequence);
    }
    if (!Ok) {
      Result->Success(flutter::EncodableValue());
      return;
    }
    Result->Success(flutter::EncodableValue(Frame));
    return;
  }
  if (Method == "Mask") {
    const auto* Bytes = Arguments == nullptr ? nullptr : std::get_if<std::vector<uint8_t>>(Arguments);
    if (Bytes == nullptr) {
      Result->Error("mask", "缺少打码数据");
      return;
    }
    Engine->PushMask(Bytes->data(), Bytes->size());
    Result->Success();
    return;
  }
  if (Method == "OpenMaskPipe") {
    if (!MaskWriter) {
      MaskWriter = std::make_unique<CaptureMaskWriter>();
      if (!MaskWriter->Open()) {
        MaskWriter.reset();
        Result->Error("mask", "无法创建打码通道");
        return;
      }
      Engine->SetMaskWriter(MaskWriter.get());
    }
    Result->Success(flutter::EncodableValue(ToUtf8(MaskWriter->Name())));
    return;
  }
  if (Method == "CloseMaskPipe") {
    Engine->SetMaskWriter(nullptr);
    MaskWriter.reset();
    Result->Success();
    return;
  }
  Result->NotImplemented();
}

void CaptureHost::AttachSink(std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& Sink) {
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> Shared(std::move(Sink));
  std::lock_guard<std::mutex> Lock(EventMutex);
  EventSink = std::move(Shared);
}

void CaptureHost::DetachSink() {
  std::lock_guard<std::mutex> Lock(EventMutex);
  EventSink.reset();
}

void CaptureHost::SendEvent(flutter::EncodableMap Value) {
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> Sink;
  {
    std::lock_guard<std::mutex> Lock(EventMutex);
    Sink = EventSink;
  }
  if (Sink) Sink->Success(flutter::EncodableValue(Value));
}

void CaptureHost::SendState(const std::string& Value) {
  flutter::EncodableMap Event;
  Event[flutter::EncodableValue("type")] = flutter::EncodableValue("state");
  Event[flutter::EncodableValue("value")] = flutter::EncodableValue(Value);
  SendEvent(std::move(Event));
}

void CaptureHost::SendError(const std::string& Text) {
  flutter::EncodableMap Event;
  Event[flutter::EncodableValue("type")] = flutter::EncodableValue("error");
  Event[flutter::EncodableValue("text")] = flutter::EncodableValue(Text);
  SendEvent(std::move(Event));
}

void CaptureHost::SendLog(const std::string& Text) {
  flutter::EncodableMap Event;
  Event[flutter::EncodableValue("type")] = flutter::EncodableValue("log");
  Event[flutter::EncodableValue("text")] = flutter::EncodableValue(Text);
  SendEvent(std::move(Event));
}

void CaptureHost::PostTask(std::function<void()> Task) {
  {
    std::lock_guard<std::mutex> Lock(TaskMutex);
    if (ShuttingDown) return;
    Tasks.push_back(std::move(Task));
  }
  TaskSignal.notify_one();
}

void CaptureHost::LifecycleLoop() {
  while (true) {
    std::function<void()> Task;
    {
      std::unique_lock<std::mutex> Lock(TaskMutex);
      TaskSignal.wait(Lock, [this]() { return ShuttingDown || !Tasks.empty(); });
      if (Tasks.empty()) {
        if (ShuttingDown) break;
        continue;
      }
      Task = std::move(Tasks.front());
      Tasks.pop_front();
    }
    Task();
  }
}

}
