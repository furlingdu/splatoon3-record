#ifndef RUNNER_CAPTURE_CAPTURE_DEVICES_H_
#define RUNNER_CAPTURE_CAPTURE_DEVICES_H_

#include "types.h"

#include <mfidl.h>

#include <string>
#include <vector>

namespace Capture {

class Devices {
 public:
  static bool Enumerate(std::vector<DeviceInfo>& Out);
  static bool Modes(const std::wstring& Device, std::vector<ModeInfo>& Out);
  static bool Pick(const Config& Value, const std::vector<ModeInfo>& Available, ModeInfo& Selected);
  static bool Find(const std::wstring& Device, IMFActivate** Out);
};

}

#endif
