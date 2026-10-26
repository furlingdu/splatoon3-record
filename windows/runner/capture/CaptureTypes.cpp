#include "CaptureTypes.h"

#include <string>

std::string Capture::ToUtf8(const std::wstring& Text) {
  if (Text.empty()) return std::string();
  int Size = WideCharToMultiByte(CP_UTF8, 0, Text.c_str(), static_cast<int>(Text.size()), nullptr, 0, nullptr, nullptr);
  if (Size <= 0) return std::string();
  std::string Result(static_cast<size_t>(Size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, Text.c_str(), static_cast<int>(Text.size()), Result.data(), Size, nullptr, nullptr);
  return Result;
}

std::wstring Capture::FromUtf8(const std::string& Text) {
  if (Text.empty()) return std::wstring();
  int Size = MultiByteToWideChar(CP_UTF8, 0, Text.c_str(), static_cast<int>(Text.size()), nullptr, 0);
  if (Size <= 0) return std::wstring();
  std::wstring Result(static_cast<size_t>(Size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, Text.c_str(), static_cast<int>(Text.size()), Result.data(), Size);
  return Result;
}

std::string Capture::FormatError(HRESULT Result) {
  char Buffer[48];
  sprintf_s(Buffer, "0x%08X", static_cast<unsigned int>(Result));
  return Buffer;
}
