#include "texture.h"

namespace Capture {

namespace {

struct ReleaseToken {
  Shared* Frames;
  int Index;
};

}

PreviewTexture::PreviewTexture(FlutterDesktopTextureRegistrarRef Registrar, std::shared_ptr<Shared> SharedValue)
    : RegistrarRef(Registrar), SharedRef(std::move(SharedValue)) {}

PreviewTexture::~PreviewTexture() {
  Stop();
}

bool PreviewTexture::Start() {
  if (TextureId >= 0) return true;
  if (RegistrarRef == nullptr || SharedRef == nullptr) return false;
  TextureInfo.type = kFlutterDesktopPixelBufferTexture;
  TextureInfo.pixel_buffer_config.callback = &PreviewTexture::CopyPixel;
  TextureInfo.pixel_buffer_config.user_data = this;
  TextureId = FlutterDesktopTextureRegistrarRegisterExternalTexture(RegistrarRef, &TextureInfo);
  if (TextureId < 0) {
    TextureId = -1;
    return false;
  }
  MarkedPublish = 0;
  return true;
}

void PreviewTexture::Stop() {
  if (TextureId < 0) return;
  HANDLE Done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  FlutterDesktopTextureRegistrarUnregisterExternalTexture(RegistrarRef, TextureId, &PreviewTexture::Unregistered, Done);
  if (Done != nullptr) {
    WaitForSingleObject(Done, 3000);
    CloseHandle(Done);
  }
  TextureId = -1;
}

void PreviewTexture::Notify() {
  if (TextureId < 0 || RegistrarRef == nullptr || SharedRef == nullptr) return;
  const LONG Current = SharedRef->PublishCount();
  if (Current == 0 || Current == MarkedPublish.load()) return;
  MarkedPublish.store(Current);
  FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(RegistrarRef, TextureId);
}

int64_t PreviewTexture::Id() const {
  return TextureId;
}

const FlutterDesktopPixelBuffer* PreviewTexture::CopyPixel(size_t Width, size_t Height, void* Context) {
  (void)Width;
  (void)Height;
  auto* Self = static_cast<PreviewTexture*>(Context);
  const uint8_t* Data = nullptr;
  int FrameWidth = 0;
  int FrameHeight = 0;
  int Index = -1;
  if (!Self->SharedRef->AcquireLatest(&Data, FrameWidth, FrameHeight, Index)) return nullptr;
  Self->PixelBuffer.buffer = Data;
  Self->PixelBuffer.width = static_cast<size_t>(FrameWidth);
  Self->PixelBuffer.height = static_cast<size_t>(FrameHeight);
  Self->PixelBuffer.release_callback = &PreviewTexture::ReleasePixel;
  Self->PixelBuffer.release_context = new ReleaseToken{Self->SharedRef.get(), Index};
  return &Self->PixelBuffer;
}

void PreviewTexture::ReleasePixel(void* Context) {
  auto* Token = static_cast<ReleaseToken*>(Context);
  if (Token == nullptr) return;
  if (Token->Frames != nullptr) Token->Frames->Release(Token->Index);
  delete Token;
}

void PreviewTexture::Unregistered(void* Context) {
  HANDLE Event = static_cast<HANDLE>(Context);
  if (Event != nullptr) SetEvent(Event);
}

}
