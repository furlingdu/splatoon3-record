#include "shared.h"

#include <cstring>

namespace Capture {

namespace {

constexpr wchar_t SharedName[] = L"Local\\Splatoon3RecordPreviewFramesV2";
constexpr LONG SharedMagic = 0x53335232;
constexpr LONG SharedVersion = 2;
constexpr size_t SharedHeaderSize = 128;
constexpr size_t SharedSlotHeaderSize = 64;
constexpr size_t SharedSlotDataSize = static_cast<size_t>(MaxPreviewWidth) * static_cast<size_t>(MaxPreviewHeight) * 4;
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
  volatile LONG Readers;
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
    InterlockedExchange(&Value->Magic, 0);
    Value->Version = SharedVersion;
    Value->Width = 0;
    Value->Height = 0;
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
      Slot->Readers = 0;
      Slot->Width = 0;
      Slot->Height = 0;
      Slot->Reserved = 0;
      Slot->Timestamp = 0;
      Slot->Tick = 0;
    }
    MemoryBarrier();
    InterlockedExchange(&Value->Magic, SharedMagic);
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

bool Shared::BeginWrite(int& Index, uint8_t** Data) {
  if (View == nullptr || Data == nullptr) return false;
  Header* Value = HeaderRef();
  for (int Attempt = 0; Attempt < PreviewSlotCount; Attempt++) {
    const LONG SlotIndex = InterlockedIncrement(&NextSlot) % PreviewSlotCount;
    if (SlotIndex == Value->Latest) continue;
    SlotHeader* Slot = SlotRef(static_cast<int>(SlotIndex));
    if (InterlockedCompareExchange(&Slot->Readers, -1, 0) != 0) continue;
    Index = static_cast<int>(SlotIndex);
    *Data = SlotData(Index);
    return true;
  }
  return false;
}

void Shared::EndWrite(int Index, int Width, int Height, LONGLONG Timestamp) {
  if (View == nullptr || Index < 0 || Index >= PreviewSlotCount) return;
  Header* Value = HeaderRef();
  SlotHeader* Slot = SlotRef(Index);
  Slot->Width = Width;
  Slot->Height = Height;
  Slot->Timestamp = Timestamp;
  Slot->Tick = static_cast<LONGLONG>(GetTickCount64());
  MemoryBarrier();
  InterlockedExchange(&Value->Latest, Index);
  InterlockedExchange(&Value->Width, Width);
  InterlockedExchange(&Value->Height, Height);
  InterlockedExchange64(&Value->LastTick, Slot->Tick);
  InterlockedIncrement(&Value->LastSequence);
  InterlockedIncrement(&Value->Publish);
  InterlockedExchange(&Value->Active, 1);
  InterlockedExchange(&Slot->Readers, 0);
}

bool Shared::AcquireLatest(const uint8_t** Data, int& Width, int& Height, int& Index) {
  if (View == nullptr || Data == nullptr) return false;
  Header* Value = HeaderRef();
  if (Value->Magic != SharedMagic || Value->Publish == 0) return false;
  for (int Attempt = 0; Attempt < PreviewSlotCount * 2; Attempt++) {
    const LONG Latest = Value->Latest;
    if (Latest < 0 || Latest >= PreviewSlotCount) return false;
    SlotHeader* Slot = SlotRef(static_cast<int>(Latest));
    const LONG Readers = Slot->Readers;
    if (Readers < 0) continue;
    if (InterlockedCompareExchange(&Slot->Readers, Readers + 1, Readers) != Readers) continue;
    const int FrameWidth = Slot->Width;
    const int FrameHeight = Slot->Height;
    if (FrameWidth <= 0 || FrameHeight <= 0 || FrameWidth > MaxPreviewWidth || FrameHeight > MaxPreviewHeight) {
      InterlockedDecrement(&Slot->Readers);
      return false;
    }
    Width = FrameWidth;
    Height = FrameHeight;
    Index = static_cast<int>(Latest);
    *Data = SlotData(Index);
    return true;
  }
  return false;
}

void Shared::Release(int Index) {
  if (View == nullptr || Index < 0 || Index >= PreviewSlotCount) return;
  InterlockedDecrement(&SlotRef(Index)->Readers);
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
  const LONGLONG Tick = HeaderRef()->LastTick;
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
  if (View == nullptr) return 0;
  return HeaderRef()->Width;
}

int Shared::Height() const {
  if (View == nullptr) return 0;
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
