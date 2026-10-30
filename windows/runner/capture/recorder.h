#ifndef RUNNER_CAPTURE_CAPTURE_RECORDER_H_
#define RUNNER_CAPTURE_CAPTURE_RECORDER_H_

#include "types.h"

#include <windows.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace Capture {

class CaptureRecorder {
 public:
  using LogCallback = std::function<void(const std::string&)>;
  using ErrorCallback = std::function<void(const std::string&)>;
  using FirstFrameCallback = std::function<void()>;

  struct Options {
    std::wstring Directory;
    int Width = 1920;
    int Height = 1080;
    int Fps = 60;
    int FpsNumerator = 60;
    int FpsDenominator = 1;
    int Quality = 28;
    int SegmentSeconds = 600;
    bool Audio = false;
    int AudioRate = 48000;
    int AudioChannels = 2;
    int AudioBitrate = 192000;
  };

  CaptureRecorder(LogCallback OnLog, ErrorCallback OnError, FirstFrameCallback OnFirstFrame);
  ~CaptureRecorder();

  CaptureRecorder(const CaptureRecorder&) = delete;
  CaptureRecorder& operator=(const CaptureRecorder&) = delete;

  bool Start(const Options& Value, std::string* Error);
  void Stop(bool Fast = false);
  void PushVideo(std::shared_ptr<Frame> FrameValue);
  void PushAudio(const uint8_t* Data, size_t Size, LONGLONG Qpc);

  bool IsRunning() const;
  long long Dropped() const;
  long long Written() const;
  long long Duplicated() const;
  int LastWriteMs() const;
  int QueueSize() const;

 private:
  struct Segment {
    IMFByteStream* ByteStream = nullptr;
    IMFMediaSink* Sink = nullptr;
    IMFSinkWriter* Writer = nullptr;
    std::wstring Path;
    LONGLONG BaseQpc = 0;
    bool Written = false;

    Segment() = default;
    ~Segment();
    Segment(const Segment&) = delete;
    Segment& operator=(const Segment&) = delete;
    Segment(Segment&& Other) noexcept;
    Segment& operator=(Segment&& Other) noexcept;
    void Close(bool Remove);
  };

  struct SegmentResult {
    bool Ok = false;
    std::string Error;
    Segment Value;
  };

  struct Item {
    bool Audio = false;
    std::shared_ptr<Frame> Video;
    std::vector<uint8_t> AudioData;
    LONGLONG Qpc = 0;
  };

  void WorkerLoop();
  bool CreateSegment(LONGLONG BaseQpc, LONGLONG DelayTicks, Segment& Out, std::string* Error);
  bool OpenSegment(LONGLONG BaseQpc, std::string* Error);
  void CloseSegment();
  void RetireSegment(Segment Value);
  void CollectRetired();
  bool Process(Item& Value, std::string* Error);
  bool WriteVideo(const std::shared_ptr<Frame>& Value, LONGLONG Time, std::string* Error);
  bool WriteAudio(const std::vector<uint8_t>& Value, LONGLONG Time, std::string* Error);
  void DropOldest();
  LONGLONG FrameIndex(LONGLONG Elapsed) const;
  LONGLONG FrameTime(LONGLONG Index) const;
  std::wstring BuildPath(LONGLONG DelayTicks) const;
  long long Bitrate() const;

  LogCallback Log;
  ErrorCallback Error;
  FirstFrameCallback FirstFrame;
  Options Config;
  std::thread Worker;
  std::atomic<bool> Running{false};
  std::atomic<bool> Stopping{false};
  std::atomic<bool> FastStop{false};
  mutable std::mutex QueueMutex;
  std::condition_variable Signal;
  std::deque<Item> Queue;
  size_t QueueBytes = 0;
  std::atomic<long long> DroppedFrames{0};
  std::atomic<long long> WrittenFrames{0};
  std::atomic<int> LastWriteDuration{0};
  std::atomic<bool> FirstFrameSent{false};
  std::unique_ptr<Segment> Current;
  std::unique_ptr<Segment> Pending;
  std::future<SegmentResult> Next;
  std::vector<std::future<void>> Retiring;
  bool PreopenFailed = false;
  LONGLONG SegmentTicks = 0;
  LONGLONG PreopenTicks = 0;
  LONGLONG LastVideoIndex = -1;
  LONGLONG LastAudioTime = 0;
  LONGLONG FpsNumerator = 60;
  LONGLONG FpsDenominator = 1;
};

}

#endif
