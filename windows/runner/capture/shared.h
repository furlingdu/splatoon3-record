#ifndef RUNNER_CAPTURE_CAPTURE_SHARED_H_
#define RUNNER_CAPTURE_CAPTURE_SHARED_H_

#include "types.h"

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

namespace Capture {

class Shared {
 public:
  Shared();
  ~Shared();

  Shared(const Shared&) = delete;
  Shared& operator=(const Shared&) = delete;

  bool Open();
  void Close();

  bool BeginWrite(int& Index, uint8_t** Data);
  void EndWrite(int Index, int Width, int Height, LONGLONG Timestamp);
  bool AcquireLatest(const uint8_t** Data, int& Width, int& Height, int& Index);
  void Release(int Index);

  void SetActive(bool Value);
  bool IsActive() const;
  bool IsRecent(int Milliseconds) const;
  LONG PublishCount() const;
  int LatestSequence() const;
  int Width() const;
  int Height() const;

 private:
  struct Header;
  struct SlotHeader;

  Header* HeaderRef() const;
  SlotHeader* SlotRef(int Index) const;
  uint8_t* SlotData(int Index) const;

  HANDLE Mapping = nullptr;
  void* View = nullptr;
  LONG NextSlot = 0;
};

}

#endif
