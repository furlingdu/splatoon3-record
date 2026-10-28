#include "texture.h"

#include <chrono>
#include <cstring>

namespace Capture {

PreviewTexture::PreviewTexture(FlutterDesktopTextureRegistrarRef Registrar, std::shared_ptr<Shared> SharedValue)
    : RegistrarRef(Registrar), SharedRef(std::move(SharedValue)) {}

PreviewTexture::~PreviewTexture() {
  Stop();
}

bool PreviewTexture::Start() {
  if (TextureId >= 0) return true;
  if (RegistrarRef == nullptr || SharedRef == nullptr) return false;
  const size_t Size = static_cast<size_t>(PreviewWidth) * static_cast<size_t>(PreviewHeight) * 4;
  Buffer.assign(Size, static_cast<uint8_t>(0));
  for (size_t Index = 3; Index < Size; Index += 4) Buffer[Index] = 255;
  Incoming.assign(Size, static_cast<uint8_t>(0));
  PixelBuffer.buffer = Buffer.data();
  PixelBuffer.width = PreviewWidth;
  PixelBuffer.height = PreviewHeight;
  PixelBuffer.release_callback = nullptr;
  PixelBuffer.release_context = nullptr;
  TextureInfo.type = kFlutterDesktopPixelBufferTexture;
  TextureInfo.pixel_buffer_config.callback = &PreviewTexture::CopyPixel;
  TextureInfo.pixel_buffer_config.user_data = this;
  TextureId = FlutterDesktopTextureRegistrarRegisterExternalTexture(RegistrarRef, &TextureInfo);
  if (TextureId < 0) {
    TextureId = -1;
    return false;
  }
  MarkedPublish = 0;
  Stopping = false;
  PumpThread = std::thread(&PreviewTexture::Pump, this);
  return true;
}

void PreviewTexture::Stop() {
  if (TextureId < 0) return;
  Stopping = true;
  if (PumpThread.joinable()) PumpThread.join();
  HANDLE Done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  FlutterDesktopTextureRegistrarUnregisterExternalTexture(RegistrarRef, TextureId, &PreviewTexture::Unregistered, Done);
  if (Done != nullptr) {
    WaitForSingleObject(Done, 3000);
    CloseHandle(Done);
  }
  TextureId = -1;
}

int64_t PreviewTexture::Id() const {
  return TextureId;
}

void PreviewTexture::Pump() {
  while (!Stopping) {
    const LONG Current = SharedRef->PublishCount();
    if (Current != MarkedPublish) {
      MarkedPublish = Current;
      if (Current > 0) FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(RegistrarRef, TextureId);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(4));
  }
}

const FlutterDesktopPixelBuffer* PreviewTexture::CopyPixel(size_t Width, size_t Height, void* Context) {
  auto* Self = static_cast<PreviewTexture*>(Context);
  (void)Width;
  (void)Height;
  std::lock_guard<std::mutex> Lock(Self->BufferMutex);
  int SourceWidth = 0;
  int SourceHeight = 0;
  if (Self->SharedRef->CopyLatest(Self->Incoming, SourceWidth, SourceHeight) && SourceWidth == PreviewWidth && SourceHeight == PreviewHeight) {
    Self->Buffer.swap(Self->Incoming);
  }
  Self->PixelBuffer.buffer = Self->Buffer.data();
  Self->PixelBuffer.width = PreviewWidth;
  Self->PixelBuffer.height = PreviewHeight;
  Self->PixelBuffer.release_callback = nullptr;
  Self->PixelBuffer.release_context = nullptr;
  return &Self->PixelBuffer;
}

void PreviewTexture::Unregistered(void* Context) {
  HANDLE Event = static_cast<HANDLE>(Context);
  if (Event != nullptr) SetEvent(Event);
}

}
