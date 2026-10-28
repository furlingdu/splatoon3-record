#ifndef RUNNER_CAPTURE_CAPTURE_MASK_H_
#define RUNNER_CAPTURE_CAPTURE_MASK_H_

#include "types.h"

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace Capture {

class CaptureMaskWriter {
 public:
  CaptureMaskWriter();
  ~CaptureMaskWriter();

  CaptureMaskWriter(const CaptureMaskWriter&) = delete;
  CaptureMaskWriter& operator=(const CaptureMaskWriter&) = delete;

  bool Open();
  void Close();
  std::wstring Name() const;
  void Push(const uint8_t* Data, size_t Size);

 private:
  void Worker();
  bool WriteLatest();
  bool WaitForIo(HANDLE Event, DWORD Timeout);

  std::wstring PipeName;
  HANDLE StopEvent = nullptr;
  HANDLE Pipe = nullptr;
  OVERLAPPED ConnectOverlapped{};
  OVERLAPPED WriteOverlapped{};
  std::thread WorkerThread;
  std::atomic<bool> Running{false};
  std::mutex FrameMutex;
  std::vector<uint8_t> Latest;
  uint64_t FrameSequence = 0;
  uint64_t SentSequence = 0;
};

}

#endif
