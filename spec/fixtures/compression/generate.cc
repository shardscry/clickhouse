// Generates independent compression fixtures using the pinned upstream CityHash
// implementation and liblz4 (1.10.0). Not needed when running the Crystal specs.
//
// Download city.cc, city.h and config.h for ClickHouse's cityhash102 at
// abf12b3b072bc93aadeb8c5d15f42fc20f9ee82a, then compile with:
// c++ -std=c++20 -I/path/to/cityhash/include generate.cc city.cc -llz4 -o generate
#include "city.h"
#include <lz4.h>
#include <cstdio>
#include <string>
#include <vector>

static void print_hex(const std::string &value) {
  for (unsigned char byte : value) std::printf("%02x", byte);
  std::printf("\n");
}

static void write_u32(std::string &target, unsigned value) {
  for (int shift = 0; shift < 32; shift += 8) target += char(value >> shift);
}

static void write_u64(std::string &target, unsigned long long value) {
  for (int shift = 0; shift < 64; shift += 8) target += char(value >> shift);
}

int main() {
  for (int length : {0, 1, 4, 7, 8, 9, 15, 16, 17, 31, 32, 64, 127, 128,
                     129, 143, 144, 145, 255, 256, 1024, 65537}) {
    std::string input(length, '\0');
    for (int i = 0; i < length; ++i) input[i] = (i * 37 + 11) & 255;
    auto result = CityHash_v1_0_2::CityHash128(input.data(), input.size());
    std::printf("{%d, 0x%016llx_u64, 0x%016llx_u64},\n", length,
                (unsigned long long)result.low64, (unsigned long long)result.high64);
  }

  std::string input;
  for (int i = 0; i < 32; ++i) input += "ClickHouse native compression ";
  std::string compressed(LZ4_compressBound(input.size()), '\0');
  compressed.resize(LZ4_compress_default(input.data(), compressed.data(), input.size(), compressed.size()));
  print_hex(compressed);
  std::string header(1, char(0x82));
  write_u32(header, compressed.size() + 9);
  write_u32(header, input.size());
  header += compressed;
  auto hash = CityHash_v1_0_2::CityHash128(header.data(), header.size());
  std::string frame;
  write_u64(frame, hash.low64);
  write_u64(frame, hash.high64);
  frame += header;
  print_hex(frame);
}
