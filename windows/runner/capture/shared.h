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

  bool Publish(const uint8_t* Pixels, int Width, int Height, LONGLONG Timestamp);
  bool CopyLatest(std::vector<uint8_t>& Out, int& Width, int& Height);

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
  mutable LONG LastSequence = 0;
};

}

#endif
