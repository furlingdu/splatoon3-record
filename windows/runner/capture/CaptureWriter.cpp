#include "CaptureWriter.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <vector>

namespace Capture {

namespace {

std::wstring QuoteArgument(const std::wstring& Value) {
  if (Value.empty()) return L"\"\"";
  const bool NeedsQuote = Value.find_first_of(L" \t\n\v\"") != std::wstring::npos;
  if (!NeedsQuote) return Value;
  std::wstring Result;
  Result.push_back(L'"');
  int Backslashes = 0;
  for (const wchar_t Character : Value) {
    if (Character == L'\\') {
      Backslashes++;
      continue;
    }
    if (Character == L'"') {
      Result.append(static_cast<size_t>(Backslashes * 2 + 1), L'\\');
      Result.push_back(L'"');
      Backslashes = 0;
      continue;
    }
    if (Backslashes > 0) {
      Result.append(static_cast<size_t>(Backslashes), L'\\');
      Backslashes = 0;
    }
    Result.push_back(Character);
  }
  if (Backslashes > 0) Result.append(static_cast<size_t>(Backslashes * 2), L'\\');
  Result.push_back(L'"');
  return Result;
}

std::wstring BuildCommandLine(const std::wstring& Exe, const std::vector<std::string>& Args) {
  std::wstring Result = QuoteArgument(Exe);
  for (const std::string& Item : Args) {
    Result.push_back(L' ');
    Result += QuoteArgument(FromUtf8(Item));
  }
  return Result;
}

}

CaptureWriter::CaptureWriter(LogCallback OnLog, ExitCallback OnExit, FirstFrameCallback OnFirstFrame)
    : Log(std::move(OnLog)), Exit(std::move(OnExit)), FirstFrame(std::move(OnFirstFrame)) {}

CaptureWriter::~CaptureWriter() {
  Stop();
}

bool CaptureWriter::Start(const std::wstring& Exe, const std::vector<std::string>& Args, double FpsValue) {
  Stop(true);
  Fps = FpsValue > 1.0 ? FpsValue : 60.0;
  SECURITY_ATTRIBUTES Security{};
  Security.nLength = sizeof(Security);
  Security.bInheritHandle = TRUE;
  HANDLE StdinRead = nullptr;
  HANDLE StderrWrite = nullptr;
  if (!CreatePipe(&StdinRead, &StdinWrite, &Security, 16 * 1024 * 1024)) return false;
  if (!CreatePipe(&StderrRead, &StderrWrite, &Security, 64 * 1024)) {
    CloseHandle(StdinRead);
    CloseHandle(StdinWrite);
    StdinWrite = nullptr;
    return false;
  }
  SetHandleInformation(StdinWrite, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(StderrRead, HANDLE_FLAG_INHERIT, 0);
  HANDLE NullOutput = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &Security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (NullOutput == INVALID_HANDLE_VALUE) NullOutput = nullptr;
  HANDLE InheritHandles[3] = {StdinRead, StderrWrite, NullOutput};
  const DWORD InheritCount = NullOutput != nullptr ? 3 : 2;
  SIZE_T AttributeSize = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &AttributeSize);
  std::vector<uint8_t> AttributeBuffer(AttributeSize);
  LPPROC_THREAD_ATTRIBUTE_LIST AttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(AttributeBuffer.data());
  const bool AttributeInitialized = AttributeSize > 0 && InitializeProcThreadAttributeList(AttributeList, 1, 0, &AttributeSize);
  bool AttributeReady = AttributeInitialized;
  if (AttributeReady) {
    AttributeReady = UpdateProcThreadAttribute(AttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, InheritHandles, sizeof(HANDLE) * InheritCount, nullptr, nullptr) != FALSE;
  }
  STARTUPINFOEXW Startup{};
  Startup.StartupInfo.cb = sizeof(STARTUPINFOEXW);
  Startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  Startup.StartupInfo.hStdInput = StdinRead;
  Startup.StartupInfo.hStdOutput = NullOutput;
  Startup.StartupInfo.hStdError = StderrWrite;
  Startup.lpAttributeList = AttributeList;
  PROCESS_INFORMATION Info{};
  std::wstring CommandLine = BuildCommandLine(Exe, Args);
  BOOL Created = FALSE;
  if (AttributeReady) {
    Created = CreateProcessW(Exe.c_str(), CommandLine.data(), nullptr, nullptr, TRUE, EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW, nullptr, nullptr, &Startup.StartupInfo, &Info);
  }
  if (AttributeInitialized) DeleteProcThreadAttributeList(AttributeList);
  CloseHandle(StdinRead);
  CloseHandle(StderrWrite);
  if (NullOutput != nullptr) CloseHandle(NullOutput);
  if (!Created) {
    CloseHandle(StdinWrite);
    CloseHandle(StderrRead);
    StdinWrite = nullptr;
    StderrRead = nullptr;
    return false;
  }
  ProcessHandle = Info.hProcess;
  ProcessId = Info.dwProcessId;
  SetPriorityClass(ProcessHandle, ABOVE_NORMAL_PRIORITY_CLASS);
  CloseHandle(Info.hThread);
  Stopping = false;
  Running = true;
  FirstTimestamp = 0;
  WrittenFrames = 0;
  LastFrame.reset();
  FirstWriteSent = false;
  WriterThread = std::thread(&CaptureWriter::WriterLoop, this);
  StderrThread = std::thread(&CaptureWriter::StderrLoop, this);
  ExitThread = std::thread(&CaptureWriter::ExitLoop, this);
  return true;
}

void CaptureWriter::Stop(bool Fast) {
  if (!Running.exchange(false) && ProcessHandle == nullptr) return;
  Stopping = true;
  QueueSignal.notify_all();
  if (Fast && ProcessHandle != nullptr) TerminateProcess(ProcessHandle, 1);
  if (WriterThread.joinable()) {
    if (WaitForSingleObject(WriterThread.native_handle(), 500) == WAIT_TIMEOUT && ProcessHandle != nullptr) {
      TerminateProcess(ProcessHandle, 1);
      WaitForSingleObject(WriterThread.native_handle(), 1500);
    }
  }
  if (StdinWrite != nullptr) {
    CloseHandle(StdinWrite);
    StdinWrite = nullptr;
  }
  if (ProcessHandle != nullptr) {
    const DWORD Timeout = Fast ? 1000 : 5000;
    if (WaitForSingleObject(ProcessHandle, Timeout) == WAIT_TIMEOUT) {
      TerminateProcess(ProcessHandle, 1);
      WaitForSingleObject(ProcessHandle, 1000);
    }
  }
  if (WriterThread.joinable()) WriterThread.join();
  if (ExitThread.joinable()) ExitThread.join();
  if (StderrThread.joinable()) StderrThread.join();
  if (StderrRead != nullptr) {
    CloseHandle(StderrRead);
    StderrRead = nullptr;
  }
  if (ProcessHandle != nullptr) {
    CloseHandle(ProcessHandle);
    ProcessHandle = nullptr;
  }
  ProcessId = 0;
  std::lock_guard<std::mutex> Lock(QueueMutex);
  Queue.clear();
}

void CaptureWriter::Push(std::shared_ptr<Frame> FrameValue) {
  if (!FrameValue || Stopping || !Running) return;
  std::lock_guard<std::mutex> Lock(QueueMutex);
  if (Queue.size() >= static_cast<size_t>(MaxWriterQueue)) {
    Queue.pop_front();
    DroppedFrames++;
  }
  Queue.push_back(std::move(FrameValue));
  QueueSignal.notify_one();
}

bool CaptureWriter::IsRunning() const {
  return Running && !Stopping;
}

long long CaptureWriter::Dropped() const {
  return DroppedFrames.load();
}

long long CaptureWriter::Written() const {
  return TotalWritten.load();
}

long long CaptureWriter::Duplicated() const {
  return DuplicateFrames.load();
}

int CaptureWriter::LastWriteMs() const {
  return LastWriteDuration.load();
}

int CaptureWriter::QueueSize() const {
  std::lock_guard<std::mutex> Lock(QueueMutex);
  return static_cast<int>(Queue.size());
}

void CaptureWriter::WriterLoop() {
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
  using Clock = std::chrono::steady_clock;
  const auto Interval = std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(1.0 / Fps));
  auto Next = Clock::now();
  bool Primed = false;
  while (!Stopping) {
    std::shared_ptr<Frame> Current;
    if (!Primed) {
      std::unique_lock<std::mutex> Lock(QueueMutex);
      QueueSignal.wait_for(Lock, std::chrono::milliseconds(100), [this]() { return Stopping || !Queue.empty(); });
      if (Stopping) break;
      if (Queue.empty()) continue;
      Current = std::move(Queue.front());
      Queue.pop_front();
      Next = Clock::now();
      Primed = true;
    } else {
      while (!Stopping && Clock::now() < Next) {
        std::unique_lock<std::mutex> Lock(QueueMutex);
        if (Queue.empty()) {
          QueueSignal.wait_until(Lock, Next, [this]() { return Stopping || !Queue.empty(); });
        } else {
          Lock.unlock();
          std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
      }
      if (Stopping) break;
      std::lock_guard<std::mutex> Lock(QueueMutex);
      if (!Queue.empty()) {
        while (Queue.size() > 2) {
          Queue.pop_front();
          DroppedFrames++;
        }
        Current = std::move(Queue.front());
        Queue.pop_front();
      }
    }
    if (!Current) Current = LastFrame;
    if (!Current) continue;
    if (!WriteFrame(Current)) break;
    Next += Interval;
    if (Next < Clock::now() - Interval * 2) Next = Clock::now() + Interval;
  }
}

void CaptureWriter::StderrLoop() {
  if (StderrRead == nullptr) return;
  std::string Pending;
  char Buffer[4096];
  while (true) {
    DWORD Read = 0;
    if (!ReadFile(StderrRead, Buffer, sizeof(Buffer), &Read, nullptr) || Read == 0) break;
    for (DWORD Index = 0; Index < Read; Index++) {
      const char Character = Buffer[Index];
      if (Character == '\r' || Character == '\n') {
        if (!Pending.empty()) {
          if (Log) Log(Pending);
          Pending.clear();
        }
        continue;
      }
      if (Pending.size() < 8192) Pending.push_back(Character);
    }
  }
  if (!Pending.empty() && Log) Log(Pending);
}

void CaptureWriter::ExitLoop() {
  if (ProcessHandle == nullptr) return;
  WaitForSingleObject(ProcessHandle, INFINITE);
  DWORD Code = 0;
  GetExitCodeProcess(ProcessHandle, &Code);
  const bool WasStopping = Stopping.load();
  Running = false;
  QueueSignal.notify_all();
  if (!WasStopping && Exit) Exit(static_cast<int>(Code));
}

bool CaptureWriter::WriteFrame(const std::shared_ptr<Frame>& Value) {
  if (!Value || Value->Data.empty()) return true;
  const auto Start = std::chrono::steady_clock::now();
  if (LastFrame != nullptr && Value == LastFrame) DuplicateFrames++;
  if (!WriteAll(Value->Data.data(), Value->Data.size())) return false;
  TotalWritten++;
  LastFrame = Value;
  const auto End = std::chrono::steady_clock::now();
  LastWriteDuration.store(static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(End - Start).count()));
  if (!FirstWriteSent.exchange(true) && FirstFrame) FirstFrame();
  return true;
}

bool CaptureWriter::WriteAll(const uint8_t* Data, size_t Size) {
  if (StdinWrite == nullptr || Data == nullptr) return false;
  size_t Offset = 0;
  while (Offset < Size) {
    const DWORD Chunk = static_cast<DWORD>(std::min<size_t>(Size - Offset, 64 * 1024 * 1024));
    DWORD Written = 0;
    if (!WriteFile(StdinWrite, Data + Offset, Chunk, &Written, nullptr) || Written == 0) return false;
    Offset += Written;
  }
  return true;
}

}
