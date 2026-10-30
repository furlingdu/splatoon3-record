#ifndef RUNNER_CAPTURE_CAPTURE_HOST_H_
#define RUNNER_CAPTURE_CAPTURE_HOST_H_

#include "engine.h"
#include "mask.h"
#include "shared.h"
#include "texture.h"

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_plugin_registrar.h>
#include <flutter_texture_registrar.h>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace flutter {
class BinaryMessengerImpl;
}

namespace Capture {

class CaptureHost {
 public:
  CaptureHost(FlutterDesktopPluginRegistrarRef Registrar, HWND Window);
  ~CaptureHost();

  CaptureHost(const CaptureHost&) = delete;
  CaptureHost& operator=(const CaptureHost&) = delete;

 private:
  class EventStreamHandler;

  void HandleMethod(const flutter::MethodCall<flutter::EncodableValue>& Call, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> Result);
  void AttachSink(std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& Sink);
  void DetachSink();
  void SendEvent(flutter::EncodableMap Value);
  void SendState(const std::string& Value);
  void SendError(const std::string& Text);
  void SendLog(const std::string& Text);
  void PostTask(std::function<void()> Task);
  void LifecycleLoop();
  void ApplyTheme(int Color);

  FlutterDesktopPluginRegistrarRef RegistrarRef = nullptr;
  HWND WindowRef = nullptr;
  FlutterDesktopTextureRegistrarRef TextureRegistrarRef = nullptr;
  std::unique_ptr<flutter::BinaryMessengerImpl> Messenger;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> Channel;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> Events;
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> EventSink;
  std::mutex EventMutex;
  std::shared_ptr<Shared> SharedFrames;
  std::unique_ptr<PreviewTexture> Texture;
  std::unique_ptr<CaptureEngine> Engine;
  std::unique_ptr<CaptureMaskWriter> MaskWriter;
  std::mutex EngineMutex;
  std::thread LifecycleThread;
  std::mutex TaskMutex;
  std::condition_variable TaskSignal;
  std::deque<std::function<void()>> Tasks;
  bool ShuttingDown = false;
  bool MfStarted = false;
};

}

#endif
