#include "audio.h"

#include <functiondiscoverykeys_devpkey.h>
#include <propvarutil.h>

#include <algorithm>
#include <cstring>

namespace Capture {

namespace {

WAVEFORMATEX DesiredFormat() {
  WAVEFORMATEX Format{};
  Format.wFormatTag = WAVE_FORMAT_PCM;
  Format.nChannels = AudioChannels;
  Format.nSamplesPerSec = AudioSampleRate;
  Format.wBitsPerSample = AudioBits;
  Format.nBlockAlign = AudioBlockAlign;
  Format.nAvgBytesPerSec = AudioSampleRate * AudioBlockAlign;
  Format.cbSize = 0;
  return Format;
}

std::wstring FriendlyName(IMMDevice* Device) {
  if (Device == nullptr) return std::wstring();
  IPropertyStore* Store = nullptr;
  if (FAILED(Device->OpenPropertyStore(STGM_READ, &Store)) || Store == nullptr) return std::wstring();
  PROPVARIANT Value;
  PropVariantInit(&Value);
  std::wstring Result;
  if (SUCCEEDED(Store->GetValue(PKEY_Device_FriendlyName, &Value))) {
    if (Value.vt == VT_LPWSTR && Value.pwszVal != nullptr) Result = Value.pwszVal;
  }
  PropVariantClear(&Value);
  Store->Release();
  return Result;
}

IMMDevice* PickDevice(IMMDeviceEnumerator* Enumerator, EDataFlow Flow, const std::wstring& Name) {
  if (Enumerator == nullptr) return nullptr;
  IMMDeviceCollection* Collection = nullptr;
  if (FAILED(Enumerator->EnumAudioEndpoints(Flow, DEVICE_STATE_ACTIVE, &Collection)) || Collection == nullptr) return nullptr;
  UINT32 Count = 0;
  Collection->GetCount(&Count);
  IMMDevice* Exact = nullptr;
  IMMDevice* Partial = nullptr;
  IMMDevice* First = nullptr;
  for (UINT32 Index = 0; Index < Count; Index++) {
    IMMDevice* Current = nullptr;
    if (FAILED(Collection->Item(Index, &Current)) || Current == nullptr) continue;
    if (First == nullptr) First = Current;
    const std::wstring Friendly = FriendlyName(Current);
    if (Exact == nullptr && Friendly == Name) Exact = Current;
    if (Partial == nullptr && !Name.empty() && (Friendly.find(Name) != std::wstring::npos || Name.find(Friendly) != std::wstring::npos)) Partial = Current;
    if (Current != Exact && Current != Partial) Current->Release();
  }
  Collection->Release();
  IMMDevice* Picked = Exact != nullptr ? Exact : Partial != nullptr ? Partial : First;
  if (Picked != First && First != nullptr) First->Release();
  return Picked;
}

}

AudioCapture::AudioCapture() = default;

AudioCapture::~AudioCapture() {
  Stop();
}

bool AudioCapture::Start(const std::wstring& DeviceName, DataCallback OnData, std::string* Error) {
  Stop();
  Data = std::move(OnData);
  Signal = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  Ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (Signal == nullptr || Ready == nullptr) {
    if (Signal != nullptr) CloseHandle(Signal);
    if (Ready != nullptr) CloseHandle(Ready);
    Signal = nullptr;
    Ready = nullptr;
    if (Error != nullptr) *Error = "无法创建音频采集事件";
    return false;
  }
  {
    std::lock_guard<std::mutex> Lock(ErrorMutex);
    ErrorMessage.clear();
  }
  Active = true;
  Worker = std::thread(&AudioCapture::WorkerMain, this, DeviceName);
  WaitForSingleObject(Ready, 5000);
  bool Ok = false;
  {
    std::lock_guard<std::mutex> Lock(ErrorMutex);
    Ok = Active.load() && ErrorMessage.empty();
    if (!Ok && Error != nullptr) *Error = ErrorMessage.empty() ? "无法打开音频采集设备" : ErrorMessage;
  }
  if (!Ok) Stop();
  return Ok;
}

void AudioCapture::Stop() {
  Active = false;
  if (Signal != nullptr) SetEvent(Signal);
  if (Worker.joinable()) Worker.join();
  if (Ready != nullptr) {
    CloseHandle(Ready);
    Ready = nullptr;
  }
  if (Signal != nullptr) {
    CloseHandle(Signal);
    Signal = nullptr;
  }
}

bool AudioCapture::Running() const {
  return Active.load();
}

void AudioCapture::WorkerMain(const std::wstring& DeviceName) {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  std::string Error;
  const bool Ok = Open(DeviceName, &Error);
  if (!Ok) {
    std::lock_guard<std::mutex> Lock(ErrorMutex);
    ErrorMessage = Error.empty() ? "无法打开音频采集设备" : Error;
    Active = false;
  }
  if (Ok) {
    if (SUCCEEDED(Client->Start())) {
      if (Ready != nullptr) SetEvent(Ready);
      while (Active) {
        if (WaitForSingleObject(Signal, 200) == WAIT_OBJECT_0) {
          if (!Active) break;
          Drain();
        }
      }
      Client->Stop();
    } else {
      std::lock_guard<std::mutex> Lock(ErrorMutex);
      ErrorMessage = "无法启动音频采集流";
      Active = false;
    }
  }
  if (Ready != nullptr) SetEvent(Ready);
  Close();
  CoUninitialize();
}

bool AudioCapture::Open(const std::wstring& DeviceName, std::string* Error) {
  HRESULT Result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&Enumerator));
  if (FAILED(Result) || Enumerator == nullptr) {
    if (Error != nullptr) *Error = "无法创建音频设备枚举器";
    return false;
  }
  Device = PickDevice(Enumerator, eCapture, DeviceName);
  if (Device == nullptr) {
    if (Error != nullptr) *Error = "找不到所选音频输入设备";
    return false;
  }
  Result = Device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(&Client));
  if (FAILED(Result) || Client == nullptr) {
    if (Error != nullptr) *Error = "无法打开音频输入设备";
    return false;
  }
  WAVEFORMATEX Format = DesiredFormat();
  const DWORD Flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
  Result = Client->Initialize(AUDCLNT_SHAREMODE_SHARED, Flags, 0, 0, &Format, nullptr);
  if (FAILED(Result)) {
    if (Error != nullptr) *Error = "音频设备不支持低延迟 48kHz 立体声采集";
    return false;
  }
  Result = Client->GetBufferSize(&BufferFrames);
  if (FAILED(Result) || BufferFrames == 0) {
    if (Error != nullptr) *Error = "无法获取音频缓冲大小";
    return false;
  }
  Result = Client->GetService(IID_PPV_ARGS(&Capture));
  if (FAILED(Result) || Capture == nullptr) {
    if (Error != nullptr) *Error = "无法获取音频采集接口";
    return false;
  }
  Result = Client->SetEventHandle(Signal);
  if (FAILED(Result)) {
    if (Error != nullptr) *Error = "无法绑定音频采集事件";
    return false;
  }
  return true;
}

void AudioCapture::Drain() {
  if (Capture == nullptr || !Data) return;
  UINT32 Packet = 0;
  while (SUCCEEDED(Capture->GetNextPacketSize(&Packet)) && Packet > 0) {
    BYTE* Buffer = nullptr;
    UINT32 Frames = 0;
    DWORD Flags = 0;
    UINT64 Qpc = 0;
    if (FAILED(Capture->GetBuffer(&Buffer, &Frames, &Flags, nullptr, &Qpc))) break;
    if (Frames > 0) {
      const size_t Size = static_cast<size_t>(Frames) * AudioBlockAlign;
      if ((Flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || Buffer == nullptr) {
        const std::vector<uint8_t> Silence(Size, 0);
        Data(Silence.data(), Silence.size(), Qpc > 0 ? static_cast<LONGLONG>(Qpc) : QpcNow());
      } else {
        Data(Buffer, Size, Qpc > 0 ? static_cast<LONGLONG>(Qpc) : QpcNow());
      }
    }
    Capture->ReleaseBuffer(Frames);
  }
}

void AudioCapture::Close() {
  if (Client != nullptr) {
    Client->Release();
    Client = nullptr;
  }
  if (Capture != nullptr) {
    Capture->Release();
    Capture = nullptr;
  }
  if (Device != nullptr) {
    Device->Release();
    Device = nullptr;
  }
  if (Enumerator != nullptr) {
    Enumerator->Release();
    Enumerator = nullptr;
  }
  BufferFrames = 0;
}

AudioMonitor::AudioMonitor() = default;

AudioMonitor::~AudioMonitor() {
  Stop();
}

bool AudioMonitor::Start(std::string* Error) {
  Stop();
  Signal = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  Ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (Signal == nullptr || Ready == nullptr) {
    if (Signal != nullptr) CloseHandle(Signal);
    if (Ready != nullptr) CloseHandle(Ready);
    Signal = nullptr;
    Ready = nullptr;
    if (Error != nullptr) *Error = "无法创建声音返听事件";
    return false;
  }
  Stopping = false;
  Worker = std::thread(&AudioMonitor::WorkerMain, this);
  WaitForSingleObject(Ready, 5000);
  if (Stopping) {
    if (Error != nullptr && Error->empty()) *Error = "无法打开声音输出设备";
    Stop();
    return false;
  }
  return true;
}

void AudioMonitor::Stop() {
  Stopping = true;
  if (Signal != nullptr) SetEvent(Signal);
  if (Worker.joinable()) Worker.join();
  {
    std::lock_guard<std::mutex> Lock(QueueMutex);
    Queue.clear();
  }
  if (Ready != nullptr) {
    CloseHandle(Ready);
    Ready = nullptr;
  }
  if (Signal != nullptr) {
    CloseHandle(Signal);
    Signal = nullptr;
  }
}

void AudioMonitor::Push(const uint8_t* Data, size_t Size) {
  if (Data == nullptr || Size == 0 || Stopping) return;
  std::lock_guard<std::mutex> Lock(QueueMutex);
  Queue.insert(Queue.end(), Data, Data + Size);
  const size_t MaxBytes = static_cast<size_t>(AudioSampleRate) * AudioBlockAlign / 2;
  if (Queue.size() > MaxBytes) Queue.erase(Queue.begin(), Queue.begin() + static_cast<ptrdiff_t>(Queue.size() - MaxBytes));
}

void AudioMonitor::SetDelayMs(int Value) {
  if (Value < 0) Value = 0;
  if (Value > 200) Value = 200;
  DelayMs.store(Value);
}

bool AudioMonitor::Running() const {
  return Worker.joinable() && !Stopping.load();
}

void AudioMonitor::WorkerMain() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  std::string Error;
  const bool Ok = Open(&Error);
  if (Ready != nullptr) SetEvent(Ready);
  if (Ok) {
    while (!Stopping) {
      if (WaitForSingleObject(Signal, 200) != WAIT_OBJECT_0) continue;
      if (Stopping) break;
      UINT32 Padding = 0;
      if (FAILED(Client->GetCurrentPadding(&Padding))) continue;
      const UINT32 Available = BufferFrames > Padding ? BufferFrames - Padding : 0;
      if (Available == 0) continue;
      BYTE* Buffer = nullptr;
      if (FAILED(Render->GetBuffer(Available, &Buffer)) || Buffer == nullptr) continue;
      const size_t Need = static_cast<size_t>(Available) * AudioBlockAlign;
      const size_t TargetBytes = static_cast<size_t>(DelayMs.load()) * AudioSampleRate / 1000 * AudioBlockAlign;
      size_t Copied = 0;
      {
        std::lock_guard<std::mutex> Lock(QueueMutex);
        if (Queue.size() >= TargetBytes + Need) {
          Copied = std::min(Need, Queue.size());
          std::memcpy(Buffer, Queue.data(), Copied);
          Queue.erase(Queue.begin(), Queue.begin() + static_cast<ptrdiff_t>(Copied));
        }
      }
      if (Copied < Need) std::memset(Buffer + Copied, 0, Need - Copied);
      Render->ReleaseBuffer(Available, 0);
    }
  }
  Close();
  CoUninitialize();
}

bool AudioMonitor::Open(std::string* Error) {
  HRESULT Result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&Enumerator));
  if (FAILED(Result) || Enumerator == nullptr) {
    if (Error != nullptr) *Error = "无法创建声音输出设备枚举器";
    Stopping = true;
    return false;
  }
  Result = Enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &Device);
  if (FAILED(Result) || Device == nullptr) {
    if (Error != nullptr) *Error = "找不到默认声音输出设备";
    Stopping = true;
    return false;
  }
  Result = Device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(&Client));
  if (FAILED(Result) || Client == nullptr) {
    if (Error != nullptr) *Error = "无法打开默认声音输出设备";
    Stopping = true;
    return false;
  }
  WAVEFORMATEX Format = DesiredFormat();
  const DWORD Flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
  Result = Client->Initialize(AUDCLNT_SHAREMODE_SHARED, Flags, 0, 0, &Format, nullptr);
  if (FAILED(Result)) {
    if (Error != nullptr) *Error = "声音输出设备不支持低延迟 48kHz 立体声返听";
    Stopping = true;
    return false;
  }
  Result = Client->GetBufferSize(&BufferFrames);
  if (FAILED(Result) || BufferFrames == 0) {
    if (Error != nullptr) *Error = "无法获取声音输出缓冲大小";
    Stopping = true;
    return false;
  }
  Result = Client->GetService(IID_PPV_ARGS(&Render));
  if (FAILED(Result) || Render == nullptr) {
    if (Error != nullptr) *Error = "无法获取声音输出接口";
    Stopping = true;
    return false;
  }
  Result = Client->SetEventHandle(Signal);
  if (FAILED(Result) || FAILED(Client->Start())) {
    if (Error != nullptr) *Error = "无法启动声音返听";
    Stopping = true;
    return false;
  }
  return true;
}

void AudioMonitor::Close() {
  if (Client != nullptr) {
    Client->Stop();
    Client->Release();
    Client = nullptr;
  }
  if (Render != nullptr) {
    Render->Release();
    Render = nullptr;
  }
  if (Device != nullptr) {
    Device->Release();
    Device = nullptr;
  }
  if (Enumerator != nullptr) {
    Enumerator->Release();
    Enumerator = nullptr;
  }
  BufferFrames = 0;
}

}
