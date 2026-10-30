#ifndef LINUX_CAPTURE_CONVERT_H_
#define LINUX_CAPTURE_CONVERT_H_

#include <cstddef>
#include <cstdint>
#include <thread>
#include <vector>

#if defined(__SSE2__)
#include <emmintrin.h>
#define LINUX_CAPTURE_SSE2 1
#endif

namespace Capture {

namespace ConvertDetail {

inline uint8_t ClampByte(int Value) {
  if (Value < 0) return 0;
  if (Value > 255) return 255;
  return static_cast<uint8_t>(Value);
}

inline void WritePixel(uint8_t* Target, int Y, int U, int V) {
  const int C = Y - 16;
  const int D = U - 128;
  const int E = V - 128;
  Target[0] = ClampByte((298 * C + 409 * E + 128) >> 8);
  Target[1] = ClampByte((298 * C - 100 * D - 208 * E + 128) >> 8);
  Target[2] = ClampByte((298 * C + 516 * D + 128) >> 8);
  Target[3] = 255;
}

#ifdef LINUX_CAPTURE_SSE2

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
  const __m128i R16 = _mm_packs_epi32(
      _mm_srai_epi32(_mm_add_epi32(_mm_madd_epi16(CElo, CoeffRE), Half), 8),
      _mm_srai_epi32(_mm_add_epi32(_mm_madd_epi16(CEhi, CoeffRE), Half), 8));
  const __m128i G16 = _mm_packs_epi32(
      _mm_srai_epi32(_mm_add_epi32(_mm_add_epi32(_mm_madd_epi16(CDlo, CoeffGD), _mm_madd_epi16(Elo, CoeffE)), Half), 8),
      _mm_srai_epi32(_mm_add_epi32(_mm_add_epi32(_mm_madd_epi16(CDhi, CoeffGD), _mm_madd_epi16(Ehi, CoeffE)), Half), 8));
  const __m128i B16 = _mm_packs_epi32(
      _mm_srai_epi32(_mm_add_epi32(_mm_madd_epi16(CDlo, CoeffBD), Half), 8),
      _mm_srai_epi32(_mm_add_epi32(_mm_madd_epi16(CDhi, CoeffBD), Half), 8));
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

inline void ConvertRows(const uint8_t* Source, int Width, int Height, uint8_t* Target, int StartRow, int EndRow) {
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

}

inline void Nv12ToRgba(const uint8_t* Source, int Width, int Height, uint8_t* Target) {
  const int ThreadCount = Width * Height >= 1920 * 1080 ? 4 : 1;
  if (ThreadCount == 1) {
    ConvertDetail::ConvertRows(Source, Width, Height, Target, 0, Height);
    return;
  }
  std::vector<std::thread> Workers;
  Workers.reserve(ThreadCount - 1);
  for (int Index = 1; Index < ThreadCount; Index++) {
    const int StartRow = Height * Index / ThreadCount;
    const int EndRow = Height * (Index + 1) / ThreadCount;
    Workers.emplace_back([&, StartRow, EndRow]() { ConvertDetail::ConvertRows(Source, Width, Height, Target, StartRow, EndRow); });
  }
  ConvertDetail::ConvertRows(Source, Width, Height, Target, 0, Height / ThreadCount);
  for (std::thread& Worker : Workers) Worker.join();
}

}

#endif
