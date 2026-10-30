#ifndef RUNNER_CAPTURE_CAPTURE_TYPES_H_
#define RUNNER_CAPTURE_CAPTURE_TYPES_H_

#include <windows.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace Capture {

constexpr int MaxPreviewWidth = 4096;
constexpr int MaxPreviewHeight = 2160;
constexpr int PreviewSlotCount = 3;
constexpr int MaskWidth = 480;
constexpr int MaskHeight = 270;
constexpr int MaskFps = 5;
constexpr int MaxWriterQueue = 8;

struct DeviceInfo {
  std::wstring Id;
  std::wstring Name;
  std::wstring Link;
  bool Audio = false;
};

struct ModeInfo {
  int Width = 0;
  int Height = 0;
  int Fps = 0;
  int FpsNumerator = 0;
  int FpsDenominator = 1;
  std::string Format;
};

struct Config {
  std::wstring Device;
  int Width = 1920;
  int Height = 1080;
  int Fps = 60;
  std::string Format = "nv12";
};

struct Frame {
  std::vector<uint8_t> Data;
  int Width = 0;
  int Height = 0;
  LONGLONG Timestamp = 0;
  LONGLONG ArrivalTick = 0;
  LONGLONG Qpc = 0;
};

std::string ToUtf8(const std::wstring& Text);
std::wstring FromUtf8(const std::string& Text);
std::string FormatError(HRESULT Result);
LONGLONG QpcNow();

}

#endif
