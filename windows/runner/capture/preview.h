#ifndef RUNNER_CAPTURE_CAPTURE_PREVIEW_H_
#define RUNNER_CAPTURE_CAPTURE_PREVIEW_H_

#include "shared.h"
#include "types.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace Capture {

class CapturePreview {
 public:
  using PublishCallback = std::function<void()>;

  CapturePreview(std::shared_ptr<Shared> SharedRef, PublishCallback OnPublish);
  ~CapturePreview();

  CapturePreview(const CapturePreview&) = delete;
  CapturePreview& operator=(const CapturePreview&) = delete;

  void Start();
  void Stop();
  void Submit(std::shared_ptr<Frame> FrameValue);
  bool Snapshot(std::vector<uint8_t>& Out, uint32_t& Sequence);
  void SetVision(bool Value);
  bool VisionSnapshot(std::vector<uint8_t>& Out, int& OutWidth, int& OutHeight, uint32_t& Sequence);

  int FrameRate() const;
  int Latency() const;
  int ConvertMs() const;
  int Width() const;
  int Height() const;

 private:
  void Run();
  void Convert(const Frame& Value);
  void ConvertMask(const Frame& Value);
  void ConvertVision(const Frame& Value);

  std::shared_ptr<Shared> SharedRef;
  PublishCallback OnPublish;
  std::atomic<bool> Stopping{false};
  std::thread Worker;
  std::mutex InputMutex;
  std::condition_variable InputSignal;
  std::shared_ptr<Frame> Pending;
  std::mutex MaskMutex;
  std::vector<uint8_t> MaskBuffer;
  uint32_t MaskSequence = 0;
  uint32_t MaskServed = 0;
  LONGLONG LastMaskTick = 0;
  std::atomic<bool> VisionEnabled{false};
  std::mutex VisionMutex;
  std::vector<uint8_t> VisionBuffer;
  uint32_t VisionSequence = 0;
  uint32_t VisionServed = 0;
  LONGLONG LastVisionTick = 0;
  int VisionWidth = 0;
  int VisionHeight = 0;
  LONGLONG LastRateTick = 0;
  int RateFrames = 0;
  std::atomic<int> FrameRateValue{0};
  std::atomic<int> LatencyValue{0};
  std::atomic<int> LastConvertMs{0};
  std::atomic<int> FrameWidth{0};
  std::atomic<int> FrameHeight{0};
  std::atomic<long long> DroppedFrames{0};
};

}

#endif
