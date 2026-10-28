#include "devices.h"

#include <mfapi.h>
#include <mferror.h>
#include <mfobjects.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cwchar>
#include <set>
#include <wchar.h>

namespace Capture {

namespace {

std::wstring ReadString(IMFActivate* Activate, const GUID& Key) {
  wchar_t* Value = nullptr;
  UINT32 Length = 0;
  if (FAILED(Activate->GetAllocatedString(Key, &Value, &Length)) || Value == nullptr) return std::wstring();
  std::wstring Result(Value, std::wcslen(Value));
  CoTaskMemFree(Value);
  return Result;
}

bool EnumerateKind(const GUID& Kind, bool Audio, std::vector<DeviceInfo>& Out) {
  IMFAttributes* Attributes = nullptr;
  if (FAILED(MFCreateAttributes(&Attributes, 2))) return false;
  Attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, Kind);
  IMFActivate** Devices = nullptr;
  UINT32 Count = 0;
  HRESULT Result = MFEnumDeviceSources(Attributes, &Devices, &Count);
  Attributes->Release();
  if (FAILED(Result)) return false;
  std::set<std::wstring> Seen;
  bool Added = false;
  for (UINT32 Index = 0; Index < Count; Index++) {
    IMFActivate* Activate = Devices[Index];
    std::wstring Name = ReadString(Activate, MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME);
    std::wstring Link = ReadString(Activate, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK);
    if (Audio) Link.clear();
    if (!Name.empty() && Seen.insert(Name).second) {
      DeviceInfo Info;
      Info.Id = Name;
      Info.Name = Name;
      Info.Link = Link;
      Info.Audio = Audio;
      Out.push_back(std::move(Info));
      Added = true;
    }
  }
  for (UINT32 Index = 0; Index < Count; Index++) Devices[Index]->Release();
  CoTaskMemFree(Devices);
  return Added;
}

std::string FormatName(const GUID& Subtype) {
  if (Subtype == MFVideoFormat_NV12) return "nv12";
  if (Subtype == MFVideoFormat_YUY2) return "yuy2";
  if (Subtype == MFVideoFormat_MJPG) return "mjpeg";
  return std::string();
}

bool ReadSize(IMFMediaType* Type, UINT32& Width, UINT32& Height) {
  return SUCCEEDED(MFGetAttributeSize(Type, MF_MT_FRAME_SIZE, &Width, &Height)) && Width > 0 && Height > 0;
}

bool ReadRate(IMFMediaType* Type, UINT32& Numerator, UINT32& Denominator) {
  if (FAILED(MFGetAttributeRatio(Type, MF_MT_FRAME_RATE, &Numerator, &Denominator))) return false;
  return Numerator > 0 && Denominator > 0;
}

bool IsProgressive(IMFMediaType* Type) {
  UINT32 Interlace = MFVideoInterlace_Progressive;
  if (FAILED(Type->GetUINT32(MF_MT_INTERLACE_MODE, &Interlace))) return true;
  return Interlace == MFVideoInterlace_Progressive || Interlace == MFVideoInterlace_Unknown;
}

bool Activate(const std::wstring& Device, IMFActivate** Out) {
  if (Out == nullptr) return false;
  *Out = nullptr;
  IMFAttributes* Attributes = nullptr;
  if (FAILED(MFCreateAttributes(&Attributes, 2))) return false;
  Attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  IMFActivate** SourceDevices = nullptr;
  UINT32 Count = 0;
  HRESULT Result = MFEnumDeviceSources(Attributes, &SourceDevices, &Count);
  Attributes->Release();
  if (FAILED(Result)) return false;
  IMFActivate* Exact = nullptr;
  IMFActivate* Folded = nullptr;
  IMFActivate* Partial = nullptr;
  for (UINT32 Index = 0; Index < Count; Index++) {
    IMFActivate* Current = SourceDevices[Index];
    std::wstring Name = ReadString(Current, MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME);
    if (Exact == nullptr && Name == Device) Exact = Current;
    if (Folded == nullptr && _wcsicmp(Name.c_str(), Device.c_str()) == 0) Folded = Current;
    if (Partial == nullptr && !Device.empty() && Name.find(Device) != std::wstring::npos) Partial = Current;
  }
  IMFActivate* Picked = Exact != nullptr ? Exact : Folded != nullptr ? Folded : Partial;
  if (Picked == nullptr && Count > 0) Picked = SourceDevices[0];
  if (Picked != nullptr) {
    Picked->AddRef();
    *Out = Picked;
  }
  for (UINT32 Index = 0; Index < Count; Index++) SourceDevices[Index]->Release();
  CoTaskMemFree(SourceDevices);
  return *Out != nullptr;
}

}

bool Devices::Enumerate(std::vector<DeviceInfo>& Out) {
  Out.clear();
  EnumerateKind(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID, false, Out);
  EnumerateKind(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_GUID, true, Out);
  return !Out.empty();
}

bool Devices::Find(const std::wstring& Device, IMFActivate** Out) {
  return Activate(Device, Out);
}

bool Devices::Modes(const std::wstring& Device, std::vector<ModeInfo>& Out) {
  Out.clear();
  IMFActivate* ActivateRef = nullptr;
  if (!Activate(Device, &ActivateRef)) return false;
  IMFMediaSource* Source = nullptr;
  HRESULT Result = ActivateRef->ActivateObject(IID_PPV_ARGS(&Source));
  ActivateRef->Release();
  if (FAILED(Result) || Source == nullptr) return false;
  IMFPresentationDescriptor* Descriptor = nullptr;
  Result = Source->CreatePresentationDescriptor(&Descriptor);
  if (FAILED(Result) || Descriptor == nullptr) {
    Source->Release();
    return false;
  }
  IMFStreamDescriptor* Stream = nullptr;
  BOOL Selected = FALSE;
  Result = Descriptor->GetStreamDescriptorByIndex(0, &Selected, &Stream);
  if (FAILED(Result) || Stream == nullptr) {
    Descriptor->Release();
    Source->Release();
    return false;
  }
  IMFMediaTypeHandler* Handler = nullptr;
  Result = Stream->GetMediaTypeHandler(&Handler);
  if (FAILED(Result) || Handler == nullptr) {
    Stream->Release();
    Descriptor->Release();
    Source->Release();
    return false;
  }
  DWORD Count = 0;
  Handler->GetMediaTypeCount(&Count);
  std::set<std::string> Seen;
  for (DWORD Index = 0; Index < Count; Index++) {
    IMFMediaType* Type = nullptr;
    if (FAILED(Handler->GetMediaTypeByIndex(Index, &Type)) || Type == nullptr) continue;
    GUID Major = GUID_NULL;
    GUID Subtype = GUID_NULL;
    UINT32 Width = 0;
    UINT32 Height = 0;
    UINT32 Numerator = 0;
    UINT32 Denominator = 1;
    bool Valid = SUCCEEDED(Type->GetGUID(MF_MT_MAJOR_TYPE, &Major)) && Major == MFMediaType_Video &&
                 SUCCEEDED(Type->GetGUID(MF_MT_SUBTYPE, &Subtype)) && ReadSize(Type, Width, Height) &&
                 ReadRate(Type, Numerator, Denominator) && IsProgressive(Type);
    std::string Format = Valid ? FormatName(Subtype) : std::string();
    if (Valid && !Format.empty()) {
      const int Rounded = static_cast<int>(std::lround(static_cast<double>(Numerator) / Denominator));
      char Key[96];
      sprintf_s(Key, "%s|%u|%u|%d", Format.c_str(), Width, Height, Rounded);
      if (Seen.insert(Key).second && Rounded > 0) {
        ModeInfo Info;
        Info.Width = static_cast<int>(Width);
        Info.Height = static_cast<int>(Height);
        Info.Fps = Rounded;
        Info.FpsNumerator = static_cast<int>(Numerator);
        Info.FpsDenominator = static_cast<int>(Denominator);
        Info.Format = Format;
        Out.push_back(Info);
      }
    }
    Type->Release();
  }
  Handler->Release();
  Stream->Release();
  Descriptor->Release();
  Source->Release();
  return !Out.empty();
}

bool Devices::Pick(const Config& Value, const std::vector<ModeInfo>& Available, ModeInfo& Selected) {
  if (Available.empty()) return false;
  std::vector<ModeInfo> Pool;
  for (const ModeInfo& Item : Available) {
    if (!Value.Format.empty() && Item.Format == Value.Format) Pool.push_back(Item);
  }
  if (Pool.empty()) Pool = Available;
  std::vector<ModeInfo> Exact;
  for (const ModeInfo& Item : Pool) {
    if (Item.Width == Value.Width && Item.Height == Value.Height) Exact.push_back(Item);
  }
  if (!Exact.empty()) Pool = Exact;
  if (Pool.empty()) return false;
  if (Exact.empty()) {
    const long long Target = static_cast<long long>(Value.Width) * Value.Height;
    std::sort(Pool.begin(), Pool.end(), [Target](const ModeInfo& Left, const ModeInfo& Right) {
      const long long LeftArea = static_cast<long long>(Left.Width) * Left.Height;
      const long long RightArea = static_cast<long long>(Right.Width) * Right.Height;
      return std::llabs(LeftArea - Target) < std::llabs(RightArea - Target);
    });
    const int BestWidth = Pool.front().Width;
    const int BestHeight = Pool.front().Height;
    Pool.erase(std::remove_if(Pool.begin(), Pool.end(), [BestWidth, BestHeight](const ModeInfo& Item) {
      return Item.Width != BestWidth || Item.Height != BestHeight;
    }), Pool.end());
  }
  std::sort(Pool.begin(), Pool.end(), [Value](const ModeInfo& Left, const ModeInfo& Right) {
    const int LeftDelta = std::abs(Left.Fps - Value.Fps);
    const int RightDelta = std::abs(Right.Fps - Value.Fps);
    if (LeftDelta != RightDelta) return LeftDelta < RightDelta;
    return Left.Fps > Right.Fps;
  });
  Selected = Pool.front();
  return true;
}

}
