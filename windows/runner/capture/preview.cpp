#include "preview.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

#if defined(_M_X64) || defined(__SSE2__)
#include <emmintrin.h>
#define CAPTURE_SSE2 1
#endif

namespace Capture {

namespace {

inline uint8_t ClampByte(int Value) {
  if (Value < 0) return 0;
  if (Value > 255) return 255;
  return static_cast<uint8_t>(Value);
}

inline void WritePixel(uint8_t* Target, int Y, int U, int V) {
  const int C = Y - 16;
  const int D = U - 128;
  const int E = V - 128;
  const int R = (298 * C + 409 * E + 128) >> 8;
  const int G = (298 * C - 100 * D - 208 * E + 128) >> 8;
  const int B = (298 * C + 516 * D + 128) >> 8;
  Target[0] = ClampByte(R);
  Target[1] = ClampByte(G);
  Target[2] = ClampByte(B);
  Target[3] = 255;
}

#ifdef CAPTURE_SSE2

inline void ConvertBlock8(const uint8_t* Y, const uint8_t* Uv, uint8_t* Target) {
  const __m128i Zero = _mm_setzero_si128();
  const __m128i Y8 = _mm_loadl_epi64(reinterpret_cast<const __m128i*>(Y));
  const __m128i Y16 = _mm_unpacklo_epi8(Y8, Zero);
  const __m128i C = _mm_sub_epi16(Y16, _mm_set1_epi16(16));
  const __m128i Uv8 = _mm_loadl_epi64(reinterpret_cast<const __m128i*>(Uv));
  const __m128i U16 = _mm_and_si128(Uv8, _mm_set1_epi16(0x00FF));
  const __m128i V16 = _mm_srli_epi16(Uv8, 8);
  const __m128i U = _mm_unpacklo_epi16(U16, U16);
  const __m128i V = _mm_unpacklo_epi16(V16, V16);
  const __m128i D = _mm_sub_epi16(U, _mm_set1_epi16(128));
  const __m128i E = _mm_sub_epi16(V, _mm_set1_epi16(128));
  const __m128i CoeffRE = _mm_set1_epi32((409 << 16) | 298);
  const __m128i CoeffGD = _mm_set1_epi32(-100 * 65536 + 298);
  const __m128i CoeffE = _mm_set1_epi32(static_cast<int>(static_cast<uint16_t>(-208)));
  const __m128i CoeffBD = _mm_set1_epi32((516 << 16) | 298);
  const __m128i Half = _mm_set1_epi32(128);
  const __m128i CElo = _mm_unpacklo_epi16(C, E);
  const __m128i CEhi = _mm_unpackhi_epi16(C, E);
  const __m128i CDlo = _mm_unpacklo_epi16(C, D);
  const __m128i CDhi = _mm_unpackhi_epi16(C, D);
  const __m128i Elo = _mm_unpacklo_epi16(E, Zero);
  const __m128i Ehi = _mm_unpackhi_epi16(E, Zero);
  __m128i Rlo = _mm_madd_epi16(CElo, CoeffRE);
  __m128i Rhi = _mm_madd_epi16(CEhi, CoeffRE);
  __m128i G = _mm_madd_epi16(CDlo, CoeffGD);
  __m128i Ghi = _mm_madd_epi16(CDhi, CoeffGD);
  __m128i Glo = _mm_madd_epi16(Elo, CoeffE);
  __m128i Gehi = _mm_madd_epi16(Ehi, CoeffE);
  __m128i B = _mm_madd_epi16(CDlo, CoeffBD);
  __m128i Bhi = _mm_madd_epi16(CDhi, CoeffBD);
  Rlo = _mm_srai_epi32(_mm_add_epi32(Rlo, Half), 8);
  Rhi = _mm_srai_epi32(_mm_add_epi32(Rhi, Half), 8);
  G = _mm_srai_epi32(_mm_add_epi32(_mm_add_epi32(G, Glo), Half), 8);
  Ghi = _mm_srai_epi32(_mm_add_epi32(_mm_add_epi32(Ghi, Gehi), Half), 8);
  B = _mm_srai_epi32(_mm_add_epi32(B, Half), 8);
  Bhi = _mm_srai_epi32(_mm_add_epi32(Bhi, Half), 8);
  const __m128i R16 = _mm_packs_epi32(Rlo, Rhi);
  const __m128i G16 = _mm_packs_epi32(G, Ghi);
  const __m128i B16 = _mm_packs_epi32(B, Bhi);
  const __m128i R8 = _mm_packus_epi16(R16, R16);
  const __m128i G8 = _mm_packus_epi16(G16, G16);
  const __m128i B8 = _mm_packus_epi16(B16, B16);
  const __m128i A8 = _mm_set1_epi8(static_cast<char>(0xFF));
  const __m128i RG = _mm_unpacklo_epi8(R8, G8);
  const __m128i BA = _mm_unpacklo_epi8(B8, A8);
  _mm_storeu_si128(reinterpret_cast<__m128i*>(Target), _mm_unpacklo_epi16(RG, BA));
  _mm_storeu_si128(reinterpret_cast<__m128i*>(Target + 16), _mm_unpackhi_epi16(RG, BA));
}

#else

inline void ConvertBlock8(const uint8_t* Y, const uint8_t* Uv, uint8_t* Target) {
  for (int Index = 0; Index < 8; Index++) {
    const int UvIndex = (Index >> 1) * 2;
    WritePixel(Target + static_cast<size_t>(Index) * 4, Y[Index], Uv[UvIndex], Uv[UvIndex + 1]);
  }
}

#endif

void ConvertNv12Rows(const uint8_t* Source, int Width, int Height, uint8_t* Target, int StartRow, int EndRow) {
  const uint8_t* YPlane = Source;
  const uint8_t* UvPlane = Source + static_cast<size_t>(Width) * Height;
  const int BlockWidth = Width & ~7;
  for (int Row = StartRow; Row < EndRow; Row++) {
    uint8_t* Line = Target + static_cast<size_t>(Row) * Width * 4;
    const uint8_t* YLine = YPlane + static_cast<size_t>(Row) * Width;
    const uint8_t* UvLine = UvPlane + static_cast<size_t>(Row >> 1) * Width;
    for (int Column = 0; Column < BlockWidth; Column += 8) {
      ConvertBlock8(YLine + Column, UvLine + Column, Line + static_cast<size_t>(Column) * 4);
    }
    for (int Column = BlockWidth; Column < Width; Column++) {
      const int UvIndex = (Column >> 1) * 2;
      WritePixel(Line + static_cast<size_t>(Column) * 4, YLine[Column], UvLine[UvIndex], UvLine[UvIndex + 1]);
    }
  }
}

void ConvertNv12(const uint8_t* Source, int Width, int Height, uint8_t* Target) {
  const int ThreadCount = Width * Height >= 1920 * 1080 ? 4 : 1;
  if (ThreadCount == 1) {
    ConvertNv12Rows(Source, Width, Height, Target, 0, Height);
    return;
  }
  std::vector<std::thread> Workers;
  Workers.reserve(ThreadCount - 1);
  for (int Index = 1; Index < ThreadCount; Index++) {
    const int StartRow = Height * Index / ThreadCount;
    const int EndRow = Height * (Index + 1) / ThreadCount;
    Workers.emplace_back([&, StartRow, EndRow]() { ConvertNv12Rows(Source, Width, Height, Target, StartRow, EndRow); });
  }
  ConvertNv12Rows(Source, Width, Height, Target, 0, Height / ThreadCount);
  for (std::thread& Worker : Workers) Worker.join();
}

void ConvertNv12Scaled(const uint8_t* Source, int SourceWidth, int SourceHeight, uint8_t* Target, int TargetWidth, int TargetHeight) {
  const uint8_t* YPlane = Source;
  const uint8_t* UvPlane = Source + static_cast<size_t>(SourceWidth) * SourceHeight;
  for (int Y = 0; Y < TargetHeight; Y++) {
    uint8_t* Row = Target + static_cast<size_t>(Y) * TargetWidth * 4;
    const int SourceY = std::min(SourceHeight - 1, Y * SourceHeight / TargetHeight);
    const int SourceUvY = std::min((SourceHeight >> 1) - 1, SourceY >> 1);
    const uint8_t* Line = YPlane + static_cast<size_t>(SourceY) * SourceWidth;
    const uint8_t* UvLine = UvPlane + static_cast<size_t>(SourceUvY) * SourceWidth;
    for (int X = 0; X < TargetWidth; X++) {
      const int SourceX = std::min(SourceWidth - 1, X * SourceWidth / TargetWidth);
      const int UvIndex = (SourceX & ~1);
      WritePixel(Row + static_cast<size_t>(X) * 4, Line[SourceX], UvLine[UvIndex], UvLine[UvIndex + 1]);
    }
  }
}

constexpr int VisionFrameWidth = 1280;
constexpr int VisionFrameHeight = 720;

}

CapturePreview::CapturePreview(std::shared_ptr<Shared> SharedValue, PublishCallback OnPublishValue)
    : SharedRef(std::move(SharedValue)), OnPublish(std::move(OnPublishValue)) {
  MaskBuffer.assign(static_cast<size_t>(MaskWidth) * MaskHeight * 4, static_cast<uint8_t>(0));
}

CapturePreview::~CapturePreview() {
  Stop();
}

void CapturePreview::Start() {
  if (Worker.joinable()) return;
  Stopping = false;
  Worker = std::thread(&CapturePreview::Run, this);
}

void CapturePreview::Stop() {
  Stopping = true;
  InputSignal.notify_all();
  if (Worker.joinable()) Worker.join();
}

void CapturePreview::Submit(std::shared_ptr<Frame> FrameValue) {
  if (!FrameValue || Stopping) return;
  {
    std::lock_guard<std::mutex> Lock(InputMutex);
    Pending = std::move(FrameValue);
  }
  InputSignal.notify_one();
}

int CapturePreview::FrameRate() const {
  return FrameRateValue.load();
}

int CapturePreview::Latency() const {
  return LatencyValue.load();
}

int CapturePreview::ConvertMs() const {
  return LastConvertMs.load();
}

int CapturePreview::Width() const {
  return FrameWidth.load();
}

int CapturePreview::Height() const {
  return FrameHeight.load();
}

bool CapturePreview::Snapshot(std::vector<uint8_t>& Out, uint32_t& Sequence) {
  std::lock_guard<std::mutex> Lock(MaskMutex);
  if (MaskSequence == MaskServed) return false;
  Out = MaskBuffer;
  Sequence = MaskSequence;
  MaskServed = MaskSequence;
  return true;
}

void CapturePreview::SetVision(bool Value) {
  VisionEnabled.store(Value);
  if (!Value) {
    std::lock_guard<std::mutex> Lock(VisionMutex);
    VisionBuffer.clear();
    VisionSequence++;
  }
}

bool CapturePreview::VisionSnapshot(std::vector<uint8_t>& Out, int& OutWidth, int& OutHeight, uint32_t& Sequence) {
  std::lock_guard<std::mutex> Lock(VisionMutex);
  if (VisionSequence == VisionServed || VisionBuffer.empty()) return false;
  Out = VisionBuffer;
  OutWidth = VisionWidth;
  OutHeight = VisionHeight;
  Sequence = VisionSequence;
  VisionServed = VisionSequence;
  return true;
}

void CapturePreview::Run() {
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
  while (!Stopping) {
    std::shared_ptr<Frame> Current;
    {
      std::unique_lock<std::mutex> Lock(InputMutex);
      InputSignal.wait(Lock, [this]() { return Stopping.load() || Pending != nullptr; });
      if (Stopping) break;
      Current = std::move(Pending);
      Pending.reset();
    }
    if (!Current) continue;
    const auto ConvertStart = std::chrono::steady_clock::now();
    Convert(*Current);
    const auto ConvertEnd = std::chrono::steady_clock::now();
    LastConvertMs.store(static_cast<int>(std::chrono::duration_cast<std::chrono::microseconds>(ConvertEnd - ConvertStart).count() / 1000));
    const LONGLONG Now = static_cast<LONGLONG>(GetTickCount64());
    if (LastRateTick == 0) LastRateTick = Now;
    RateFrames++;
    const LONGLONG Span = Now - LastRateTick;
    if (Span >= 1000) {
      FrameRateValue.store(static_cast<int>(RateFrames * 1000 / Span));
      RateFrames = 0;
      LastRateTick = Now;
    }
    LatencyValue.store(static_cast<int>(Now - Current->ArrivalTick));
  }
}

void CapturePreview::Convert(const Frame& Value) {
  if (Value.Width <= 1 || Value.Height <= 1) return;
  const int Width = Value.Width & ~1;
  const int Height = Value.Height & ~1;
  int Index = -1;
  uint8_t* Target = nullptr;
  if (!SharedRef->BeginWrite(Index, &Target) || Target == nullptr) {
    DroppedFrames++;
    return;
  }
  ConvertNv12(Value.Data.data(), Width, Height, Target);
  SharedRef->EndWrite(Index, Width, Height, Value.Timestamp);
  FrameWidth.store(Width);
  FrameHeight.store(Height);
  if (OnPublish) OnPublish();
  const LONGLONG Now = static_cast<LONGLONG>(GetTickCount64());
  if (LastMaskTick == 0 || Now - LastMaskTick >= 1000 / MaskFps) {
    LastMaskTick = Now;
    ConvertMask(Value);
  }
  if (VisionEnabled.load() && (LastVisionTick == 0 || Now - LastVisionTick >= 500)) {
    LastVisionTick = Now;
    ConvertVision(Value);
  }
}

void CapturePreview::ConvertVision(const Frame& Value) {
  if (Value.Width <= 1 || Value.Height <= 1) return;
  const int SourceWidth = Value.Width & ~1;
  const int SourceHeight = Value.Height & ~1;
  std::vector<uint8_t> FrameData(static_cast<size_t>(VisionFrameWidth) * VisionFrameHeight * 4, static_cast<uint8_t>(255));
  ConvertNv12Scaled(Value.Data.data(), SourceWidth, SourceHeight, FrameData.data(), VisionFrameWidth, VisionFrameHeight);
  std::lock_guard<std::mutex> Lock(VisionMutex);
  VisionBuffer.swap(FrameData);
  VisionWidth = VisionFrameWidth;
  VisionHeight = VisionFrameHeight;
  VisionSequence++;
}

void CapturePreview::ConvertMask(const Frame& Value) {
  if (Value.Width <= 1 || Value.Height <= 1) return;
  const int SourceWidth = Value.Width & ~1;
  const int SourceHeight = Value.Height & ~1;
  const uint8_t* YPlane = Value.Data.data();
  const uint8_t* UvPlane = YPlane + static_cast<size_t>(SourceWidth) * SourceHeight;
  std::vector<uint8_t> FrameData(static_cast<size_t>(MaskWidth) * MaskHeight * 4, static_cast<uint8_t>(255));
  for (int Y = 0; Y < MaskHeight; Y++) {
    uint8_t* Row = FrameData.data() + static_cast<size_t>(Y) * MaskWidth * 4;
    const int SourceY = std::min(SourceHeight - 1, Y * SourceHeight / MaskHeight);
    const int SourceUvY = std::min((SourceHeight >> 1) - 1, SourceY >> 1);
    const uint8_t* Line = YPlane + static_cast<size_t>(SourceY) * SourceWidth;
    const uint8_t* UvLine = UvPlane + static_cast<size_t>(SourceUvY) * SourceWidth;
    for (int X = 0; X < MaskWidth; X++) {
      const int SourceX = std::min(SourceWidth - 1, X * SourceWidth / MaskWidth);
      const int UvIndex = (SourceX & ~1);
      WritePixel(Row + static_cast<size_t>(X) * 4, Line[SourceX], UvLine[UvIndex], UvLine[UvIndex + 1]);
    }
  }
  std::lock_guard<std::mutex> Lock(MaskMutex);
  MaskBuffer.swap(FrameData);
  MaskSequence++;
}

}
