#ifndef RUNNER_CAPTURE_CAPTURE_ENGINE_H_
#define RUNNER_CAPTURE_CAPTURE_ENGINE_H_

#include "audio.h"
#include "mask.h"
#include "preview.h"
#include "recorder.h"
#include "shared.h"
#include "types.h"
#include "writer.h"

#include <windows.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace Capture {

class CaptureEngine {
 public:
  using StateCallback = std::function<void(const std::string&)>;
  using ErrorCallback = std::function<void(const std::string&)>;
  using LogCallback = std::function<void(const std::string&)>;
  using StatsCallback = std::function<void(int CaptureRate, int PreviewRate, int Latency, int ConvertMs, int PreviewWidth, int PreviewHeight, long long Dropped, long long Written, long long Duplicated, int WriteMs, int Queue)>;
  using PreviewCallback = std::function<void()>;

  struct NativeConfig {
    std::wstring Directory;
    std::wstring AudioDevice;
    int Quality = 28;
    int SegmentSeconds = 600;
    bool Audio = false;
    bool Monitor = false;
    int MonitorDelayMs = 30;
  };

  CaptureEngine(std::shared_ptr<Shared> SharedValue, StateCallback OnState, ErrorCallback OnError, LogCallback OnLog, PreviewCallback OnPreview, StatsCallback OnStats);
  ~CaptureEngine();

  CaptureEngine(const CaptureEngine&) = delete;
  CaptureEngine& operator=(const CaptureEngine&) = delete;

  bool Prepare(const Config& Value);
  bool Start(const std::wstring& Exe, const std::vector<std::string>& Args, double FpsValue, bool UseWriter);
  bool StartNative(const NativeConfig& Value);
  void SetMonitor(bool Value);
  void Stop(bool Fast = false);

  void SetMaskWriter(CaptureMaskWriter* Writer);
  void PushMask(const uint8_t* Data, size_t Size);
  bool Snapshot(std::vector<uint8_t>& Out, uint32_t& Sequence);
  void SetVision(bool Enabled);
  bool VisionSnapshot(std::vector<uint8_t>& Out, int& Width, int& Height, uint32_t& Sequence);

  bool IsRunning() const;
  const std::string& LastError() const;
  const ModeInfo& Actual() const;

 private:
  void ReaderLoop();
  bool OpenReader();
  void CloseReader();
  bool CopySample(IMFSample* Sample, std::shared_ptr<Frame>& Out);
  void EvaluateState();
  void ReportError(const std::string& Text);
  void ReportStats();

  std::shared_ptr<Shared> SharedRef;
  StateCallback State;
  ErrorCallback Error;
  LogCallback Log;
  PreviewCallback OnPreview;
  StatsCallback Stats;
  Config PreparedConfig;
  ModeInfo PreparedMode;
  std::string ErrorText;
  std::atomic<bool> Running{false};
  std::atomic<bool> Stopping{false};
  std::atomic<bool> FirstFrame{false};
  std::atomic<bool> FirstWrite{false};
  std::atomic<bool> RecordingSent{false};
  bool WriterEnabled = false;
  bool NativeEnabled = false;
  NativeConfig NativeOptions;
  std::unique_ptr<CapturePreview> Preview;
  std::unique_ptr<CaptureWriter> Writer;
  std::unique_ptr<CaptureRecorder> Recorder;
  std::unique_ptr<AudioCapture> Audio;
  std::shared_ptr<AudioMonitor> Monitor;
  std::mutex MonitorMutex;
  std::mutex MaskMutex;
  CaptureMaskWriter* MaskWriter = nullptr;
  IMFSourceReader* Reader = nullptr;
  std::thread ReaderThread;
  LONGLONG LastStatsTick = 0;
  int CapturedFrames = 0;
};

}

#endif
