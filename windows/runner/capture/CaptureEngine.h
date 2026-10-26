#ifndef RUNNER_CAPTURE_CAPTURE_ENGINE_H_
#define RUNNER_CAPTURE_CAPTURE_ENGINE_H_

#include "CaptureMask.h"
#include "CapturePreview.h"
#include "CaptureShared.h"
#include "CaptureTypes.h"
#include "CaptureWriter.h"

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
  using StatsCallback = std::function<void(int CaptureRate, int PreviewRate, int Latency, int ConvertMs, long long Dropped, long long Written, long long Duplicated, int WriteMs, int Queue)>;

  CaptureEngine(std::shared_ptr<Shared> SharedValue, StateCallback OnState, ErrorCallback OnError, LogCallback OnLog, StatsCallback OnStats);
  ~CaptureEngine();

  CaptureEngine(const CaptureEngine&) = delete;
  CaptureEngine& operator=(const CaptureEngine&) = delete;

  bool Prepare(const Config& Value);
  bool Start(const std::wstring& Exe, const std::vector<std::string>& Args, double FpsValue, bool UseWriter);
  void Stop(bool Fast = false);

  void SetMaskWriter(CaptureMaskWriter* Writer);
  void PushMask(const uint8_t* Data, size_t Size);
  bool Snapshot(std::vector<uint8_t>& Out, uint32_t& Sequence);

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
  std::unique_ptr<CapturePreview> Preview;
  std::unique_ptr<CaptureWriter> Writer;
  std::mutex MaskMutex;
  CaptureMaskWriter* MaskWriter = nullptr;
  IMFSourceReader* Reader = nullptr;
  std::thread ReaderThread;
  LONGLONG LastStatsTick = 0;
  int CapturedFrames = 0;
};

}

#endif
