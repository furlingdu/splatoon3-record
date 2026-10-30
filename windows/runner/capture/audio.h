#ifndef RUNNER_CAPTURE_CAPTURE_AUDIO_H_
#define RUNNER_CAPTURE_CAPTURE_AUDIO_H_

#include "types.h"

#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace Capture {

constexpr int AudioSampleRate = 48000;
constexpr int AudioChannels = 2;
constexpr int AudioBits = 16;
constexpr int AudioBlockAlign = AudioChannels * AudioBits / 8;

class AudioCapture {
 public:
  using DataCallback = std::function<void(const uint8_t* Data, size_t Size, LONGLONG Qpc)>;

  AudioCapture();
  ~AudioCapture();

  AudioCapture(const AudioCapture&) = delete;
  AudioCapture& operator=(const AudioCapture&) = delete;

  bool Start(const std::wstring& DeviceName, DataCallback OnData, std::string* Error);
  void Stop();
  bool Running() const;

 private:
  void WorkerMain(const std::wstring& DeviceName);
  bool Open(const std::wstring& DeviceName, std::string* Error);
  void Drain();
  void Close();

  DataCallback Data;
  std::thread Worker;
  std::atomic<bool> Active{false};
  HANDLE Signal = nullptr;
  HANDLE Ready = nullptr;
  IMMDeviceEnumerator* Enumerator = nullptr;
  IMMDevice* Device = nullptr;
  IAudioClient* Client = nullptr;
  IAudioCaptureClient* Capture = nullptr;
  UINT32 BufferFrames = 0;
  std::string ErrorMessage;
  mutable std::mutex ErrorMutex;
};

class AudioMonitor {
 public:
  AudioMonitor();
  ~AudioMonitor();

  AudioMonitor(const AudioMonitor&) = delete;
  AudioMonitor& operator=(const AudioMonitor&) = delete;

  bool Start(std::string* Error);
  void Stop();
  void Push(const uint8_t* Data, size_t Size);
  void SetDelayMs(int Value);
  bool Running() const;

 private:
  void WorkerMain();
  bool Open(std::string* Error);
  void Close();

  std::thread Worker;
  std::atomic<bool> Stopping{false};
  HANDLE Signal = nullptr;
  HANDLE Ready = nullptr;
  IMMDeviceEnumerator* Enumerator = nullptr;
  IMMDevice* Device = nullptr;
  IAudioClient* Client = nullptr;
  IAudioRenderClient* Render = nullptr;
  UINT32 BufferFrames = 0;
  std::atomic<int> DelayMs{30};
  std::mutex QueueMutex;
  std::vector<uint8_t> Queue;
};

}

#endif
