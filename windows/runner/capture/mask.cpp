#include "mask.h"

#include <chrono>
#include <cstdio>
#include <cstring>

namespace Capture {

CaptureMaskWriter::CaptureMaskWriter() {
  Latest.assign(static_cast<size_t>(MaskWidth) * MaskHeight, static_cast<uint8_t>(0));
}

CaptureMaskWriter::~CaptureMaskWriter() {
  Close();
}

bool CaptureMaskWriter::Open() {
  Close();
  wchar_t Name[96];
  swprintf_s(Name, L"\\\\.\\pipe\\Splatoon3RecordMask-%lu", static_cast<unsigned long>(GetCurrentProcessId()));
  PipeName = Name;
  StopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (StopEvent == nullptr) return false;
  ConnectOverlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  WriteOverlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (ConnectOverlapped.hEvent == nullptr || WriteOverlapped.hEvent == nullptr) {
    Close();
    return false;
  }
  Running = true;
  WorkerThread = std::thread(&CaptureMaskWriter::Worker, this);
  return true;
}

void CaptureMaskWriter::Close() {
  Running = false;
  if (StopEvent != nullptr) SetEvent(StopEvent);
  if (Pipe != nullptr) CancelIoEx(Pipe, nullptr);
  if (WorkerThread.joinable()) WorkerThread.join();
  if (Pipe != nullptr) {
    CloseHandle(Pipe);
    Pipe = nullptr;
  }
  if (StopEvent != nullptr) {
    CloseHandle(StopEvent);
    StopEvent = nullptr;
  }
  if (ConnectOverlapped.hEvent != nullptr) {
    CloseHandle(ConnectOverlapped.hEvent);
    ConnectOverlapped.hEvent = nullptr;
  }
  if (WriteOverlapped.hEvent != nullptr) {
    CloseHandle(WriteOverlapped.hEvent);
    WriteOverlapped.hEvent = nullptr;
  }
  PipeName.clear();
}

std::wstring CaptureMaskWriter::Name() const {
  return PipeName;
}

void CaptureMaskWriter::Push(const uint8_t* Data, size_t Size) {
  if (Data == nullptr || Size != static_cast<size_t>(MaskWidth) * MaskHeight) return;
  std::lock_guard<std::mutex> Lock(FrameMutex);
  std::memcpy(Latest.data(), Data, Size);
  FrameSequence++;
}

void CaptureMaskWriter::Worker() {
  while (Running) {
    Pipe = CreateNamedPipeW(PipeName.c_str(), PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED, PIPE_TYPE_BYTE | PIPE_WAIT, 1, 256 * 1024, 256 * 1024, 0, nullptr);
    if (Pipe == INVALID_HANDLE_VALUE) {
      Pipe = nullptr;
      Sleep(100);
      continue;
    }
    ResetEvent(ConnectOverlapped.hEvent);
    ConnectOverlapped.Offset = 0;
    ConnectOverlapped.OffsetHigh = 0;
    const BOOL Connected = ConnectNamedPipe(Pipe, &ConnectOverlapped);
    bool Ready = Connected == TRUE;
    if (Connected == FALSE) {
      const DWORD Error = GetLastError();
      if (Error == ERROR_PIPE_CONNECTED) {
        Ready = true;
      } else if (Error == ERROR_IO_PENDING) {
        Ready = WaitForIo(ConnectOverlapped.hEvent, INFINITE);
        if (!Ready) CancelIoEx(Pipe, &ConnectOverlapped);
      }
    }
    if (!Running) {
      CloseHandle(Pipe);
      Pipe = nullptr;
      break;
    }
    if (!Ready) {
      CloseHandle(Pipe);
      Pipe = nullptr;
      Sleep(50);
      continue;
    }
    if (Pipe != nullptr) {
      while (Running) {
        if (WaitForSingleObject(StopEvent, 1000 / MaskFps) == WAIT_OBJECT_0) break;
        if (!WriteLatest()) break;
      }
      if (Pipe != nullptr) {
        DisconnectNamedPipe(Pipe);
        CloseHandle(Pipe);
        Pipe = nullptr;
      }
    }
  }
}

bool CaptureMaskWriter::WriteLatest() {
  std::vector<uint8_t> Frame;
  {
    std::lock_guard<std::mutex> Lock(FrameMutex);
    Frame = Latest;
    SentSequence = FrameSequence;
  }
  (void)SentSequence;
  ResetEvent(WriteOverlapped.hEvent);
  WriteOverlapped.Offset = 0;
  WriteOverlapped.OffsetHigh = 0;
  DWORD Written = 0;
  if (WriteFile(Pipe, Frame.data(), static_cast<DWORD>(Frame.size()), &Written, &WriteOverlapped)) return Written == Frame.size();
  if (GetLastError() != ERROR_IO_PENDING) return false;
  if (!WaitForIo(WriteOverlapped.hEvent, 5000)) {
    CancelIoEx(Pipe, &WriteOverlapped);
    return false;
  }
  if (!GetOverlappedResult(Pipe, &WriteOverlapped, &Written, FALSE)) return false;
  return Written == static_cast<DWORD>(Frame.size());
}

bool CaptureMaskWriter::WaitForIo(HANDLE Event, DWORD Timeout) {
  HANDLE Handles[2] = {Event, StopEvent};
  const DWORD Result = WaitForMultipleObjects(2, Handles, FALSE, Timeout);
  if (Result == WAIT_OBJECT_0) return true;
  return false;
}

}
