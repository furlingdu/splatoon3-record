#include "CaptureShared.h"

#include <cstring>

namespace Capture {

namespace {

constexpr wchar_t SharedName[] = L"Local\\Splatoon3RecordPreviewFramesV1";
constexpr LONG SharedMagic = 0x53335250;
constexpr LONG SharedVersion = 1;
constexpr size_t SharedHeaderSize = 64;
constexpr size_t SharedSlotHeaderSize = 64;
constexpr size_t SharedSlotDataSize = static_cast<size_t>(PreviewWidth) * static_cast<size_t>(PreviewHeight) * 4;
constexpr size_t SharedSlotStride = SharedSlotHeaderSize + SharedSlotDataSize;
constexpr size_t SharedTotalSize = SharedHeaderSize + SharedSlotStride * PreviewSlotCount;

}

struct Shared::Header {
  volatile LONG Magic;
  volatile LONG Version;
  volatile LONG Width;
  volatile LONG Height;
  volatile LONG SlotCount;
  volatile LONG Active;
  volatile LONG Publish;
  volatile LONG Latest;
  volatile LONG LastSequence;
  volatile LONG Reserved;
  volatile LONGLONG LastTick;
  volatile LONGLONG Reserved2;
};

struct Shared::SlotHeader {
  volatile LONG Sequence;
  volatile LONG Width;
  volatile LONG Height;
  volatile LONG Reserved;
  volatile LONGLONG Timestamp;
  volatile LONGLONG Tick;
};

Shared::Shared() = default;

Shared::~Shared() {
  Close();
}

bool Shared::Open() {
  if (View != nullptr) return true;
  Mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, static_cast<DWORD>(SharedTotalSize), SharedName);
  if (Mapping == nullptr) return false;
  View = MapViewOfFile(Mapping, FILE_MAP_ALL_ACCESS, 0, 0, SharedTotalSize);
  if (View == nullptr) {
    CloseHandle(Mapping);
    Mapping = nullptr;
    return false;
  }
  Header* Value = HeaderRef();
  if (Value->Magic != SharedMagic || Value->Version != SharedVersion) {
    Value->Magic = 0;
    Value->Version = SharedVersion;
    Value->Width = PreviewWidth;
    Value->Height = PreviewHeight;
    Value->SlotCount = PreviewSlotCount;
    Value->Active = 0;
    Value->Publish = 0;
    Value->Latest = -1;
    Value->LastSequence = 0;
    Value->Reserved = 0;
    Value->LastTick = 0;
    Value->Reserved2 = 0;
    for (int Index = 0; Index < PreviewSlotCount; Index++) {
      SlotHeader* Slot = SlotRef(Index);
      Slot->Sequence = 0;
      Slot->Width = 0;
      Slot->Height = 0;
      Slot->Reserved = 0;
      Slot->Timestamp = 0;
      Slot->Tick = 0;
    }
    MemoryBarrier();
    Value->Magic = SharedMagic;
  }
  return true;
}

void Shared::Close() {
  if (View != nullptr) {
    UnmapViewOfFile(View);
    View = nullptr;
  }
  if (Mapping != nullptr) {
    CloseHandle(Mapping);
    Mapping = nullptr;
  }
}

bool Shared::Publish(const uint8_t* Pixels, int Width, int Height, LONGLONG Timestamp) {
  if (View == nullptr || Pixels == nullptr || Width != PreviewWidth || Height != PreviewHeight) return false;
  Header* Value = HeaderRef();
  LONG Latest = Value->Latest;
  LONG Index = (Latest + 1) % PreviewSlotCount;
  SlotHeader* Slot = SlotRef(Index);
  InterlockedIncrement(&Slot->Sequence);
  Slot->Width = Width;
  Slot->Height = Height;
  Slot->Timestamp = Timestamp;
  Slot->Tick = static_cast<LONGLONG>(GetTickCount64());
  std::memcpy(SlotData(Index), Pixels, SharedSlotDataSize);
  InterlockedIncrement(&Slot->Sequence);
  InterlockedExchange(&Value->Latest, Index);
  InterlockedIncrement(&Value->LastSequence);
  InterlockedExchange(&Value->Active, 1);
  InterlockedIncrement(&Value->Publish);
  Value->LastTick = static_cast<LONGLONG>(GetTickCount64());
  return true;
}

bool Shared::CopyLatest(std::vector<uint8_t>& Out, int& Width, int& Height) {
  if (View == nullptr) return false;
  Header* Value = HeaderRef();
  LONG Index = Value->Latest;
  if (Index < 0 || Index >= PreviewSlotCount) return false;
  Out.resize(SharedSlotDataSize);
  for (int Attempt = 0; Attempt < PreviewSlotCount; Attempt++) {
    SlotHeader* Slot = SlotRef(Index);
    LONG Before = Slot->Sequence;
    if ((Before & 1) == 0 && Before != 0) {
      std::memcpy(Out.data(), SlotData(Index), SharedSlotDataSize);
      LONG After = Slot->Sequence;
      if (Before == After) {
        Width = Slot->Width;
        Height = Slot->Height;
        return Width > 0 && Height > 0;
      }
    }
    Index = (Index - 1 + PreviewSlotCount) % PreviewSlotCount;
  }
  return false;
}

void Shared::SetActive(bool Value) {
  if (View == nullptr) return;
  InterlockedExchange(&HeaderRef()->Active, Value ? 1 : 0);
}

bool Shared::IsActive() const {
  if (View == nullptr) return false;
  return HeaderRef()->Active != 0;
}

bool Shared::IsRecent(int Milliseconds) const {
  if (View == nullptr) return false;
  LONGLONG Tick = HeaderRef()->LastTick;
  if (Tick <= 0) return false;
  return static_cast<LONGLONG>(GetTickCount64()) - Tick <= Milliseconds;
}

LONG Shared::PublishCount() const {
  if (View == nullptr) return 0;
  return HeaderRef()->Publish;
}

int Shared::LatestSequence() const {
  if (View == nullptr) return 0;
  return HeaderRef()->LastSequence;
}

int Shared::Width() const {
  if (View == nullptr) return PreviewWidth;
  return HeaderRef()->Width;
}

int Shared::Height() const {
  if (View == nullptr) return PreviewHeight;
  return HeaderRef()->Height;
}

Shared::Header* Shared::HeaderRef() const {
  return static_cast<Header*>(View);
}

Shared::SlotHeader* Shared::SlotRef(int Index) const {
  return reinterpret_cast<SlotHeader*>(static_cast<uint8_t*>(View) + SharedHeaderSize + static_cast<size_t>(Index) * SharedSlotStride);
}

uint8_t* Shared::SlotData(int Index) const {
  return static_cast<uint8_t*>(View) + SharedHeaderSize + static_cast<size_t>(Index) * SharedSlotStride + SharedSlotHeaderSize;
}

}
