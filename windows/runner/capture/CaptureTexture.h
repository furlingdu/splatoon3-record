#ifndef RUNNER_CAPTURE_CAPTURE_TEXTURE_H_
#define RUNNER_CAPTURE_CAPTURE_TEXTURE_H_

#include "CaptureShared.h"

#include <flutter_texture_registrar.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace Capture {

class PreviewTexture {
 public:
  PreviewTexture(FlutterDesktopTextureRegistrarRef Registrar, std::shared_ptr<Shared> SharedRef);
  ~PreviewTexture();

  PreviewTexture(const PreviewTexture&) = delete;
  PreviewTexture& operator=(const PreviewTexture&) = delete;

  bool Start();
  void Stop();
  int64_t Id() const;

 private:
  static const FlutterDesktopPixelBuffer* CopyPixel(size_t Width, size_t Height, void* Context);
  static void Unregistered(void* Context);
  void Pump();

  FlutterDesktopTextureRegistrarRef RegistrarRef = nullptr;
  std::shared_ptr<Shared> SharedRef;
  std::atomic<bool> Stopping{false};
  std::thread PumpThread;
  std::mutex BufferMutex;
  std::vector<uint8_t> Buffer;
  std::vector<uint8_t> Incoming;
  FlutterDesktopPixelBuffer PixelBuffer{};
  FlutterDesktopTextureInfo TextureInfo{};
  int64_t TextureId = -1;
  LONG MarkedPublish = 0;
};

}

#endif
