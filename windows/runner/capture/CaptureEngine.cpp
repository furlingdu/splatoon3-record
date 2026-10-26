#include "CaptureEngine.h"

#include "CaptureDevices.h"

#include <mfapi.h>
#include <mferror.h>
#include <mfobjects.h>

#include <algorithm>
#include <cstring>

namespace Capture {

CaptureEngine::CaptureEngine(std::shared_ptr<Shared> SharedValue, StateCallback OnState, ErrorCallback OnError, LogCallback OnLog, StatsCallback OnStats)
    : SharedRef(std::move(SharedValue)), State(std::move(OnState)), Error(std::move(OnError)), Log(std::move(OnLog)), Stats(std::move(OnStats)) {}

CaptureEngine::~CaptureEngine() {
  Stop(true);
}

bool CaptureEngine::Prepare(const Config& Value) {
  if (Running) return false;
  std::vector<ModeInfo> Available;
  if (!Devices::Modes(Value.Device, Available) || Available.empty()) {
    ErrorText = "无法读取采集设备的输出格式，请确认设备已连接且未被其他程序占用";
    return false;
  }
  ModeInfo Selected;
  if (!Devices::Pick(Value, Available, Selected)) {
    ErrorText = "采集设备没有可用的视频格式";
    return false;
  }
  PreparedConfig = Value;
  PreparedMode = Selected;
  ErrorText.clear();
  return true;
}

bool CaptureEngine::Start(const std::wstring& Exe, const std::vector<std::string>& Args, double FpsValue, bool UseWriter) {
  if (Running) return false;
  if (PreparedMode.Width <= 0 || PreparedMode.Height <= 0) {
    if (!Prepare(PreparedConfig)) return false;
  }
  Stopping = false;
  Running = true;
  FirstFrame = false;
  FirstWrite = false;
  RecordingSent = false;
  WriterEnabled = UseWriter;
  LastStatsTick = static_cast<LONGLONG>(GetTickCount64());
  CapturedFrames = 0;
  if (State) State("starting");
  SharedRef->SetActive(true);
  Preview = std::make_unique<CapturePreview>(SharedRef);
  Preview->Start();
  if (WriterEnabled) {
    Writer = std::make_unique<CaptureWriter>(
        [this](const std::string& Text) {
          if (Log) Log(Text);
        },
        [this](int Code) {
          if (!Stopping) ReportError("录制编码进程意外退出，错误码 " + std::to_string(Code));
        },
        [this]() {
          FirstWrite = true;
          EvaluateState();
        });
  }
  ReaderThread = std::thread(&CaptureEngine::ReaderLoop, this);
  if (WriterEnabled && Writer) {
    if (!Writer->Start(Exe, Args, FpsValue)) {
      ReportError("无法启动录制编码进程");
      Stopping = true;
      if (ReaderThread.joinable()) ReaderThread.join();
      Preview->Stop();
      Preview.reset();
      SharedRef->SetActive(false);
      Running = false;
      Writer.reset();
      return false;
    }
  }
  return true;
}

void CaptureEngine::Stop(bool Fast) {
  Running = false;
  Stopping = true;
  if (ReaderThread.joinable()) ReaderThread.join();
  if (Preview) {
    Preview->Stop();
    Preview.reset();
  }
  if (Writer) {
    Writer->Stop(Fast);
    Writer.reset();
  }
  SharedRef->SetActive(false);
}

void CaptureEngine::SetMaskWriter(CaptureMaskWriter* WriterValue) {
  std::lock_guard<std::mutex> Lock(MaskMutex);
  MaskWriter = WriterValue;
}

void CaptureEngine::PushMask(const uint8_t* Data, size_t Size) {
  std::lock_guard<std::mutex> Lock(MaskMutex);
  if (MaskWriter != nullptr) MaskWriter->Push(Data, Size);
}

bool CaptureEngine::Snapshot(std::vector<uint8_t>& Out, uint32_t& Sequence) {
  if (!Preview) return false;
  return Preview->Snapshot(Out, Sequence);
}

bool CaptureEngine::IsRunning() const {
  return Running;
}

const std::string& CaptureEngine::LastError() const {
  return ErrorText;
}

const ModeInfo& CaptureEngine::Actual() const {
  return PreparedMode;
}

void CaptureEngine::ReaderLoop() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
  if (!OpenReader()) {
    CloseReader();
    CoUninitialize();
    return;
  }
  while (!Stopping) {
    DWORD StreamIndex = 0;
    DWORD Flags = 0;
    LONGLONG Timestamp = 0;
    IMFSample* Sample = nullptr;
    const HRESULT Result = Reader->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, &StreamIndex, &Flags, &Timestamp, &Sample);
    if (FAILED(Result)) {
      if (!Stopping) ReportError("读取采集画面失败：" + FormatError(Result));
      if (Sample != nullptr) Sample->Release();
      break;
    }
    if ((Flags & MF_SOURCE_READERF_ERROR) != 0) {
      if (Sample != nullptr) Sample->Release();
      if (!Stopping) ReportError("采集设备报告了视频流错误");
      break;
    }
    if ((Flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
      if (Sample != nullptr) Sample->Release();
      if (!Stopping) ReportError("采集设备停止输出视频");
      break;
    }
    if (Sample != nullptr) {
      std::shared_ptr<Frame> Value;
      if (CopySample(Sample, Value) && Value) {
        Value->Timestamp = Timestamp;
        Value->ArrivalTick = static_cast<LONGLONG>(GetTickCount64());
        Preview->Submit(Value);
        if (WriterEnabled && Writer) Writer->Push(Value);
        CapturedFrames++;
        if (!FirstFrame.exchange(true)) EvaluateState();
      }
      Sample->Release();
    }
    if (!Stopping) ReportStats();
  }
  CloseReader();
  CoUninitialize();
}

bool CaptureEngine::OpenReader() {
  IMFActivate* ActivateRef = nullptr;
  if (!Devices::Find(PreparedConfig.Device, &ActivateRef)) {
    ReportError("找不到采集设备，请确认设备已连接");
    return false;
  }
  IMFMediaSource* Source = nullptr;
  HRESULT Result = ActivateRef->ActivateObject(IID_PPV_ARGS(&Source));
  ActivateRef->Release();
  if (FAILED(Result) || Source == nullptr) {
    ReportError("无法打开采集设备：" + FormatError(Result));
    return false;
  }
  IMFAttributes* Attributes = nullptr;
  Result = MFCreateAttributes(&Attributes, 8);
  if (FAILED(Result)) {
    Source->Release();
    ReportError("无法创建采集配置：" + FormatError(Result));
    return false;
  }
  Attributes->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
  Attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
  Attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
  Result = MFCreateSourceReaderFromMediaSource(Source, Attributes, &Reader);
  Attributes->Release();
  Source->Release();
  if (FAILED(Result) || Reader == nullptr) {
    ReportError("无法创建低延迟采集通道：" + FormatError(Result));
    return false;
  }
  Reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  Reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), TRUE);
  IMFMediaType* Output = nullptr;
  Result = MFCreateMediaType(&Output);
  if (FAILED(Result) || Output == nullptr) {
    ReportError("无法创建视频输出格式：" + FormatError(Result));
    return false;
  }
  Output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  Output->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  MFSetAttributeSize(Output, MF_MT_FRAME_SIZE, static_cast<UINT32>(PreparedMode.Width), static_cast<UINT32>(PreparedMode.Height));
  MFSetAttributeRatio(Output, MF_MT_FRAME_RATE, static_cast<UINT32>(PreparedMode.FpsNumerator), static_cast<UINT32>(PreparedMode.FpsDenominator));
  MFSetAttributeRatio(Output, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  Result = Reader->SetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr, Output);
  Output->Release();
  if (FAILED(Result)) {
    ReportError("采集设备不支持所选画面格式：" + FormatError(Result));
    return false;
  }
  if (Log) Log("capture opened " + std::to_string(PreparedMode.Width) + "x" + std::to_string(PreparedMode.Height) + " @" + std::to_string(PreparedMode.Fps));
  return true;
}

void CaptureEngine::CloseReader() {
  if (Reader != nullptr) {
    Reader->Release();
    Reader = nullptr;
  }
}

bool CaptureEngine::CopySample(IMFSample* Sample, std::shared_ptr<Frame>& Out) {
  if (Sample == nullptr) return false;
  IMFMediaBuffer* Buffer = nullptr;
  if (FAILED(Sample->ConvertToContiguousBuffer(&Buffer)) || Buffer == nullptr) return false;
  const int Width = PreparedMode.Width;
  const int Height = PreparedMode.Height;
  const size_t YSize = static_cast<size_t>(Width) * Height;
  const size_t Total = YSize * 3 / 2;
  auto Value = std::make_shared<Frame>();
  Value->Width = Width;
  Value->Height = Height;
  Value->Data.resize(Total);
  bool Copied = false;
  IMF2DBuffer* Buffer2D = nullptr;
  if (SUCCEEDED(Buffer->QueryInterface(IID_PPV_ARGS(&Buffer2D))) && Buffer2D != nullptr) {
    BYTE* Scanline = nullptr;
    LONG Pitch = 0;
    if (SUCCEEDED(Buffer2D->Lock2D(&Scanline, &Pitch))) {
      if (Scanline != nullptr && Pitch > 0 && static_cast<size_t>(Pitch) >= static_cast<size_t>(Width)) {
        uint8_t* Target = Value->Data.data();
        if (Pitch == Width) {
          std::memcpy(Target, Scanline, Total);
        } else {
          for (int Row = 0; Row < Height; Row++) {
            std::memcpy(Target + static_cast<size_t>(Row) * Width, Scanline + static_cast<size_t>(Row) * Pitch, static_cast<size_t>(Width));
          }
          const uint8_t* UvPlane = Scanline + static_cast<size_t>(Pitch) * Height;
          for (int Row = 0; Row < Height / 2; Row++) {
            std::memcpy(Target + YSize + static_cast<size_t>(Row) * Width, UvPlane + static_cast<size_t>(Row) * Pitch, static_cast<size_t>(Width));
          }
        }
        Copied = true;
      }
      Buffer2D->Unlock2D();
    }
    Buffer2D->Release();
  }
  if (!Copied) {
    BYTE* Data = nullptr;
    DWORD Length = 0;
    if (SUCCEEDED(Buffer->Lock(&Data, nullptr, &Length))) {
      if (Data != nullptr && Length >= Total) {
        std::memcpy(Value->Data.data(), Data, Total);
        Copied = true;
      }
      Buffer->Unlock();
    }
  }
  Buffer->Release();
  if (!Copied) return false;
  Out = std::move(Value);
  return true;
}

void CaptureEngine::EvaluateState() {
  if (Stopping || RecordingSent) return;
  if (!FirstFrame.load()) return;
  if (WriterEnabled && !FirstWrite.load()) return;
  if (RecordingSent.exchange(true)) return;
  if (State) State("recording");
}

void CaptureEngine::ReportError(const std::string& Text) {
  ErrorText = Text;
  if (Error) Error(Text);
}

void CaptureEngine::ReportStats() {
  const LONGLONG Now = static_cast<LONGLONG>(GetTickCount64());
  if (LastStatsTick == 0) LastStatsTick = Now;
  const LONGLONG Span = Now - LastStatsTick;
  if (Span < 1000) return;
  const int CaptureRate = static_cast<int>(CapturedFrames * 1000 / Span);
  CapturedFrames = 0;
  LastStatsTick = Now;
  if (Preview && Stats) {
    const long long Dropped = Writer ? Writer->Dropped() : 0;
    const long long Written = Writer ? Writer->Written() : 0;
    const long long Duplicated = Writer ? Writer->Duplicated() : 0;
    const int WriteMs = Writer ? Writer->LastWriteMs() : 0;
    const int Queue = Writer ? Writer->QueueSize() : 0;
    Stats(CaptureRate, Preview->FrameRate(), Preview->Latency(), Preview->ConvertMs(), Dropped, Written, Duplicated, WriteMs, Queue);
  }
}

}
