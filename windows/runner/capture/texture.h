#ifndef RUNNER_CAPTURE_CAPTURE_TEXTURE_H_
#define RUNNER_CAPTURE_CAPTURE_TEXTURE_H_

#include "shared.h"

#include <flutter_texture_registrar.h>

#include <atomic>
#include <cstdint>
#include <memory>

namespace Capture {

class PreviewTexture {
 public:
  PreviewTexture(FlutterDesktopTextureRegistrarRef Registrar, std::shared_ptr<Shared> SharedRef);
  ~PreviewTexture();

  PreviewTexture(const PreviewTexture&) = delete;
  PreviewTexture& operator=(const PreviewTexture&) = delete;

  bool Start();
  void Stop();
  void Notify();
  int64_t Id() const;

 private:
  static const FlutterDesktopPixelBuffer* CopyPixel(size_t Width, size_t Height, void* Context);
  static void ReleasePixel(void* Context);
  static void Unregistered(void* Context);

  FlutterDesktopTextureRegistrarRef RegistrarRef = nullptr;
  std::shared_ptr<Shared> SharedRef;
  FlutterDesktopPixelBuffer PixelBuffer{};
  FlutterDesktopTextureInfo TextureInfo{};
  int64_t TextureId = -1;
  std::atomic<LONG> MarkedPublish{0};
};

}

#endif
