#include "CapturePreview.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

namespace Capture {

namespace {

inline uint8_t ClampByte(int Value) {
  if (Value < 0) return 0;
  if (Value > 255) return 255;
  return static_cast<uint8_t>(Value);
}

inline uint8_t LerpByte(int Left, int Right, int Fraction) {
  return static_cast<uint8_t>(Left + (((Right - Left) * Fraction) >> 8));
}

void BuildTable(int SourceSize, int DestSize, std::vector<int>& Low, std::vector<int>& High, std::vector<uint8_t>& Fraction) {
  Low.resize(static_cast<size_t>(DestSize));
  High.resize(static_cast<size_t>(DestSize));
  Fraction.resize(static_cast<size_t>(DestSize));
  const double Scale = static_cast<double>(SourceSize) / static_cast<double>(DestSize);
  for (int Index = 0; Index < DestSize; Index++) {
    double Position = (Index + 0.5) * Scale - 0.5;
    if (Position < 0.0) Position = 0.0;
    if (Position > SourceSize - 1) Position = SourceSize - 1;
    int Base = static_cast<int>(std::floor(Position));
    if (Base < 0) Base = 0;
    if (Base > SourceSize - 1) Base = SourceSize - 1;
    int Next = Base + 1;
    if (Next > SourceSize - 1) Next = SourceSize - 1;
    int Frac = static_cast<int>(std::lround((Position - Base) * 256.0));
    if (Frac < 0) Frac = 0;
    if (Frac > 255) Frac = 255;
    Low[static_cast<size_t>(Index)] = Base;
    High[static_cast<size_t>(Index)] = Next;
    Fraction[static_cast<size_t>(Index)] = static_cast<uint8_t>(Frac);
  }
}

inline void WritePixel(uint8_t* Target, int Y, int U, int V) {
  int C = Y - 16;
  if (C < 0) C = 0;
  const int D = U - 128;
  const int E = V - 128;
  const int R = (298 * C + 459 * E + 128) >> 8;
  const int G = (298 * C - 55 * D - 136 * E + 128) >> 8;
  const int B = (298 * C + 541 * D + 128) >> 8;
  Target[0] = ClampByte(R);
  Target[1] = ClampByte(G);
  Target[2] = ClampByte(B);
  Target[3] = 255;
}

}

CapturePreview::CapturePreview(std::shared_ptr<Shared> SharedValue) : SharedRef(std::move(SharedValue)) {
  RgbaBuffer.assign(static_cast<size_t>(PreviewWidth) * PreviewHeight * 4, static_cast<uint8_t>(0));
  for (size_t Index = 3; Index < RgbaBuffer.size(); Index += 4) RgbaBuffer[Index] = 255;
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
  std::lock_guard<std::mutex> Lock(InputMutex);
  Pending = std::move(FrameValue);
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

bool CapturePreview::Snapshot(std::vector<uint8_t>& Out, uint32_t& Sequence) {
  std::lock_guard<std::mutex> Lock(MaskMutex);
  if (MaskSequence == MaskServed) return false;
  Out = MaskBuffer;
  Sequence = MaskSequence;
  MaskServed = MaskSequence;
  return true;
}

void CapturePreview::Run() {
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
  NextPreviewAt = std::chrono::steady_clock::now();
  while (!Stopping) {
    std::shared_ptr<Frame> Current;
    {
      std::unique_lock<std::mutex> Lock(InputMutex);
      InputSignal.wait_for(Lock, std::chrono::milliseconds(50), [this]() { return Stopping.load() || Pending != nullptr; });
      if (Stopping) break;
      if (Pending == nullptr) {
        const LONGLONG Now = static_cast<LONGLONG>(GetTickCount64());
        if (LastRateTick != 0 && Now - LastRateTick > 1500 && FrameRateValue.load() != 0) FrameRateValue.store(0);
        continue;
      }
      const auto Now = std::chrono::steady_clock::now();
      if (Now < NextPreviewAt) {
        InputSignal.wait_until(Lock, NextPreviewAt, [this]() { return Stopping.load(); });
        if (Stopping) break;
      }
      Current = std::move(Pending);
      Pending.reset();
    }
    if (!Current) continue;
    const auto ConvertStart = std::chrono::steady_clock::now();
    Convert(*Current);
    const auto ConvertEnd = std::chrono::steady_clock::now();
    NextPreviewAt = ConvertStart + std::chrono::milliseconds(1000 / PreviewFps);
    LastConvertMs.store(static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(ConvertEnd - ConvertStart).count()));
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
  if (Value.Width <= 0 || Value.Height <= 0) return;
  const int SourceWidth = Value.Width;
  const int SourceHeight = Value.Height;
  const double Scale = std::min(static_cast<double>(PreviewWidth) / SourceWidth, static_cast<double>(PreviewHeight) / SourceHeight);
  int DestWidth = static_cast<int>(std::lround(SourceWidth * Scale));
  int DestHeight = static_cast<int>(std::lround(SourceHeight * Scale));
  DestWidth = (DestWidth / 2) * 2;
  DestHeight = (DestHeight / 2) * 2;
  if (DestWidth < 2) DestWidth = 2;
  if (DestHeight < 2) DestHeight = 2;
  if (DestWidth > PreviewWidth) DestWidth = PreviewWidth;
  if (DestHeight > PreviewHeight) DestHeight = PreviewHeight;
  const int OffsetX = (PreviewWidth - DestWidth) / 2;
  const int OffsetY = (PreviewHeight - DestHeight) / 2;
  if (SourceWidth != LastSourceWidth || SourceHeight != LastSourceHeight || DestWidth != LastDestWidth || DestHeight != LastDestHeight) {
    BuildRgbaTable(SourceWidth, SourceHeight, DestWidth, DestHeight);
    std::memset(RgbaBuffer.data(), 0, RgbaBuffer.size());
    for (size_t Index = 3; Index < RgbaBuffer.size(); Index += 4) RgbaBuffer[Index] = 255;
    LastSourceWidth = SourceWidth;
    LastSourceHeight = SourceHeight;
    LastDestWidth = DestWidth;
    LastDestHeight = DestHeight;
    LastOffsetX = OffsetX;
    LastOffsetY = OffsetY;
  }
  const uint8_t* YPlane = Value.Data.data();
  const uint8_t* UvPlane = YPlane + static_cast<size_t>(SourceWidth) * SourceHeight;
  for (int Y = 0; Y < DestHeight; Y++) {
    uint8_t* Row = RgbaBuffer.data() + (static_cast<size_t>(OffsetY + Y) * PreviewWidth + OffsetX) * 4;
    const int Y0 = RgbaY0[static_cast<size_t>(Y)];
    const int Y1 = RgbaY1[static_cast<size_t>(Y)];
    const int YF = RgbaYF[static_cast<size_t>(Y)];
    const uint8_t* Line0 = YPlane + static_cast<size_t>(Y0) * SourceWidth;
    const uint8_t* Line1 = YPlane + static_cast<size_t>(Y1) * SourceWidth;
    const uint8_t* UvLine = UvPlane + static_cast<size_t>(Y0 >> 1) * SourceWidth;
    for (int X = 0; X < DestWidth; X++) {
      const int X0 = RgbaX0[static_cast<size_t>(X)];
      const int X1 = RgbaX1[static_cast<size_t>(X)];
      const int XF = RgbaXF[static_cast<size_t>(X)];
      const int Top = LerpByte(Line0[X0], Line0[X1], XF);
      const int Bottom = LerpByte(Line1[X0], Line1[X1], XF);
      const int Luma = LerpByte(Top, Bottom, YF);
      const int UvIndex = (X0 & ~1);
      const int U = UvLine[UvIndex];
      const int V = UvLine[UvIndex + 1];
      WritePixel(Row + static_cast<size_t>(X) * 4, Luma, U, V);
    }
  }
  SharedRef->Publish(RgbaBuffer.data(), PreviewWidth, PreviewHeight, Value.Timestamp);
  const LONGLONG Now = static_cast<LONGLONG>(GetTickCount64());
  if (LastMaskTick == 0 || Now - LastMaskTick >= 1000 / MaskFps) {
    LastMaskTick = Now;
    ConvertMask(Value);
  }
}

void CapturePreview::ConvertMask(const Frame& Value) {
  if (Value.Width <= 0 || Value.Height <= 0) return;
  if (Value.Width != LastMaskSourceWidth || Value.Height != LastMaskSourceHeight) {
    BuildMaskTable(Value.Width, Value.Height);
    LastMaskSourceWidth = Value.Width;
    LastMaskSourceHeight = Value.Height;
  }
  const uint8_t* YPlane = Value.Data.data();
  const uint8_t* UvPlane = YPlane + static_cast<size_t>(Value.Width) * Value.Height;
  std::vector<uint8_t> FrameData(static_cast<size_t>(MaskWidth) * MaskHeight * 4, static_cast<uint8_t>(255));
  for (int Y = 0; Y < MaskHeight; Y++) {
    uint8_t* Row = FrameData.data() + static_cast<size_t>(Y) * MaskWidth * 4;
    const int Y0 = MaskY0[static_cast<size_t>(Y)];
    const int Y1 = MaskY1[static_cast<size_t>(Y)];
    const int YF = MaskYF[static_cast<size_t>(Y)];
    const uint8_t* Line0 = YPlane + static_cast<size_t>(Y0) * Value.Width;
    const uint8_t* Line1 = YPlane + static_cast<size_t>(Y1) * Value.Width;
    const uint8_t* UvLine = UvPlane + static_cast<size_t>(Y0 >> 1) * Value.Width;
    for (int X = 0; X < MaskWidth; X++) {
      const int X0 = MaskX0[static_cast<size_t>(X)];
      const int X1 = MaskX1[static_cast<size_t>(X)];
      const int XF = MaskXF[static_cast<size_t>(X)];
      const int Top = LerpByte(Line0[X0], Line0[X1], XF);
      const int Bottom = LerpByte(Line1[X0], Line1[X1], XF);
      const int Luma = LerpByte(Top, Bottom, YF);
      const int UvIndex = (X0 & ~1);
      const int U = UvLine[UvIndex];
      const int V = UvLine[UvIndex + 1];
      WritePixel(Row + static_cast<size_t>(X) * 4, Luma, U, V);
    }
  }
  std::lock_guard<std::mutex> Lock(MaskMutex);
  MaskBuffer.swap(FrameData);
  MaskSequence++;
}

void CapturePreview::BuildRgbaTable(int SourceWidth, int SourceHeight, int DestWidth, int DestHeight) {
  BuildTable(SourceWidth, DestWidth, RgbaX0, RgbaX1, RgbaXF);
  BuildTable(SourceHeight, DestHeight, RgbaY0, RgbaY1, RgbaYF);
}

void CapturePreview::BuildMaskTable(int SourceWidth, int SourceHeight) {
  BuildTable(SourceWidth, MaskWidth, MaskX0, MaskX1, MaskXF);
  BuildTable(SourceHeight, MaskHeight, MaskY0, MaskY1, MaskYF);
}

}
