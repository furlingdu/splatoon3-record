#ifndef RUNNER_CAPTURE_CAPTURE_WRITER_H_
#define RUNNER_CAPTURE_CAPTURE_WRITER_H_

#include "types.h"

#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace Capture {

class CaptureWriter {
 public:
  using LogCallback = std::function<void(const std::string&)>;
  using ExitCallback = std::function<void(int)>;
  using FirstFrameCallback = std::function<void()>;

  CaptureWriter(LogCallback OnLog, ExitCallback OnExit, FirstFrameCallback OnFirstFrame);
  ~CaptureWriter();

  CaptureWriter(const CaptureWriter&) = delete;
  CaptureWriter& operator=(const CaptureWriter&) = delete;

  bool Start(const std::wstring& Exe, const std::vector<std::string>& Args, double FpsValue);
  void Stop(bool Fast = false);
  void Push(std::shared_ptr<Frame> FrameValue);

  bool IsRunning() const;
  long long Dropped() const;
  long long Written() const;
  long long Duplicated() const;
  int LastWriteMs() const;
  int QueueSize() const;

 private:
  void WriterLoop();
  void StderrLoop();
  void ExitLoop();
  bool WriteFrame(const std::shared_ptr<Frame>& Value);
  bool WriteAll(const uint8_t* Data, size_t Size);

  LogCallback Log;
  ExitCallback Exit;
  FirstFrameCallback FirstFrame;
  double Fps = 60.0;
  HANDLE ProcessHandle = nullptr;
  HANDLE StdinWrite = nullptr;
  HANDLE StderrRead = nullptr;
  DWORD ProcessId = 0;
  std::atomic<bool> Running{false};
  std::atomic<bool> Stopping{false};
  std::thread WriterThread;
  std::thread StderrThread;
  std::thread ExitThread;
  mutable std::mutex QueueMutex;
  std::condition_variable QueueSignal;
  std::deque<std::shared_ptr<Frame>> Queue;
  std::atomic<long long> DroppedFrames{0};
  std::atomic<long long> TotalWritten{0};
  std::atomic<long long> DuplicateFrames{0};
  std::atomic<int> LastWriteDuration{0};
  LONGLONG FirstTimestamp = 0;
  long long WrittenFrames = 0;
  std::shared_ptr<Frame> LastFrame;
  std::atomic<bool> FirstWriteSent{false};
};

}

#endif
