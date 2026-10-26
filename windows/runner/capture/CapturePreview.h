#ifndef RUNNER_CAPTURE_CAPTURE_PREVIEW_H_
#define RUNNER_CAPTURE_CAPTURE_PREVIEW_H_

#include "CaptureShared.h"
#include "CaptureTypes.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace Capture {

class CapturePreview {
 public:
  explicit CapturePreview(std::shared_ptr<Shared> SharedRef);
  ~CapturePreview();

  CapturePreview(const CapturePreview&) = delete;
  CapturePreview& operator=(const CapturePreview&) = delete;

  void Start();
  void Stop();
  void Submit(std::shared_ptr<Frame> FrameValue);
  bool Snapshot(std::vector<uint8_t>& Out, uint32_t& Sequence);

  int FrameRate() const;
  int Latency() const;
  int ConvertMs() const;

 private:
  void Run();
  void Convert(const Frame& Value);
  void ConvertMask(const Frame& Value);
  void BuildRgbaTable(int SourceWidth, int SourceHeight, int DestWidth, int DestHeight);
  void BuildMaskTable(int SourceWidth, int SourceHeight);

  std::shared_ptr<Shared> SharedRef;
  std::atomic<bool> Stopping{false};
  std::thread Worker;
  std::mutex InputMutex;
  std::condition_variable InputSignal;
  std::shared_ptr<Frame> Pending;
  std::mutex MaskMutex;
  std::vector<uint8_t> MaskBuffer;
  uint32_t MaskSequence = 0;
  uint32_t MaskServed = 0;
  std::vector<uint8_t> RgbaBuffer;
  std::vector<int> RgbaX0;
  std::vector<int> RgbaX1;
  std::vector<uint8_t> RgbaXF;
  std::vector<int> RgbaY0;
  std::vector<int> RgbaY1;
  std::vector<uint8_t> RgbaYF;
  int LastSourceWidth = 0;
  int LastSourceHeight = 0;
  int LastDestWidth = 0;
  int LastDestHeight = 0;
  int LastOffsetX = 0;
  int LastOffsetY = 0;
  std::vector<int> MaskX0;
  std::vector<int> MaskX1;
  std::vector<uint8_t> MaskXF;
  std::vector<int> MaskY0;
  std::vector<int> MaskY1;
  std::vector<uint8_t> MaskYF;
  int LastMaskSourceWidth = 0;
  int LastMaskSourceHeight = 0;
  LONGLONG LastMaskTick = 0;
  LONGLONG LastRateTick = 0;
  std::chrono::steady_clock::time_point NextPreviewAt;
  int RateFrames = 0;
  std::atomic<int> FrameRateValue{0};
  std::atomic<int> LatencyValue{0};
  std::atomic<int> LastConvertMs{0};
};

}

#endif
