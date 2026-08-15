// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// Tilemap decode, fuzzed against MAME's own layout description.
//
// The RTL extracts pixels a 16-bit word at a time, having reasoned that the
// gfx_element xormask cancels the host byte order and leaves a tidy mapping.
// That reasoning is exactly the kind that is convincing and wrong, so the
// reference here does NOT reuse it. It walks MAME's decode literally: four
// planes per pixel, bit addresses from
//
//   xoffset {STEP8(0,4)}, yoffset {STEP8(0,32)}, planeoffset {0,1,2,3}
//
// each XORed with the endianness mask and read MSB-first out of a byte view of
// char_ram, which is what gfx_element does. If the tidy word-level version in
// the RTL is wrong, these disagree.

#include "Vm1_tile_decode.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <vector>

static const int TILE_WORDS = 0x8000;    // 64 KB tile RAM
static const int CHAR_WORDS = 0x40000;   // 512 KB character RAM
static const uint16_t TILE_MASK = 0x3fff;

static std::vector<uint16_t> tile_ram(TILE_WORDS);
static std::vector<uint16_t> char_ram(CHAR_WORDS);

// gfx_element's byte view of char_ram on a little-endian host.
static inline uint8_t char_byte(uint32_t idx) {
  uint16_t w = char_ram[idx >> 1];
  return (idx & 1) ? (uint8_t)(w >> 8) : (uint8_t)(w & 0xff);
}

// MAME's decode for one pixel, done the long way.
static uint8_t ref_pixel(uint32_t tile, int row, int col) {
  uint8_t val = 0;
  for (int plane = 0; plane < 4; plane++) {
    // yoffset STEP8(0,32), xoffset STEP8(0,4), planeoffset {0,1,2,3}
    int bit = row * 32 + col * 4 + plane;
    // set_gfx(..., NATIVE_ENDIAN_VALUE_LE_BE(8,0), ...) — 8 on little endian.
    bit ^= 8;
    uint32_t byte_idx = tile * 32 + (bit >> 3);
    uint8_t b = char_byte(byte_idx);
    int v = (b >> (7 - (bit & 7))) & 1;
    // Plane 0 is the most significant bit of the pen.
    val |= (uint8_t)(v << (3 - plane));
  }
  return val;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vm1_tile_decode;
  std::mt19937 rng(20260815u);

  for (auto& w : tile_ram) w = (uint16_t)rng();
  for (auto& w : char_ram) w = (uint16_t)rng();

  long checks = 0, fails = 0;
  long n_disabled = 0, n_transparent = 0, n_prio = 0, n_wrapx = 0, n_wrapy = 0;
  long layer_seen[4] = {0, 0, 0, 0};

  auto probe = [&](uint32_t x, uint32_t y, uint32_t layer,
                   uint16_t hscr, uint16_t vscr) {
    d->x = x & 0x1ff;
    d->y = y & 0x1ff;
    d->layer = layer & 3;
    d->hscr = hscr;
    d->vscr = vscr;
    d->tile_mask = TILE_MASK;

    // Reference addressing, straight from segaic24.cpp.
    uint32_t map_x = ((x & 0x1ff) - (hscr & 0x1ff)) & 0x1ff;   // scrollx is negated
    uint32_t map_y = ((y & 0x1ff) + (vscr & 0x1ff)) & 0x1ff;   // scrolly is not
    uint32_t tindex = (map_y >> 3) * 64 + (map_x >> 3);
    uint32_t taddr = (layer & 3) * 0x1000 + tindex;

    uint16_t tw = tile_ram[taddr];
    d->tile_word = tw;

    uint32_t tile_num = tw & TILE_MASK;
    uint32_t colour = (tw >> 7) & 0xff;
    uint32_t prio = (tw >> 15) & 1;
    uint32_t row = map_y & 7, col = map_x & 7;

    uint32_t caddr = tile_num * 16 + row * 2;
    d->char_w0 = char_ram[caddr];
    d->char_w1 = char_ram[caddr + 1];
    d->eval();

    uint8_t want_pixel = ref_pixel(tile_num, row, col);
    uint32_t want_pal = (colour << 4) | want_pixel;

    if (map_x < (x & 0x1ff)) n_wrapx++;
    if (map_y < (y & 0x1ff)) n_wrapy++;
    layer_seen[layer & 3]++;
    if (vscr & 0x8000) n_disabled++;
    if (want_pixel == 0) n_transparent++;
    if (prio) n_prio++;

    checks++;
    if (d->tile_addr != taddr) {
      if (fails < 12)
        printf("  FAIL tile_addr x=%u y=%u L=%u hs=%04x vs=%04x got=%05x want=%05x\n",
               x, y, layer, hscr, vscr, (unsigned)d->tile_addr, taddr);
      fails++; return;
    }
    checks++;
    if (d->char_addr != caddr) {
      if (fails < 12)
        printf("  FAIL char_addr tile=%05x row=%u got=%06x want=%06x\n",
               tile_num, row, (unsigned)d->char_addr, caddr);
      fails++; return;
    }
    checks++;
    if (d->pixel != want_pixel) {
      if (fails < 12)
        printf("  FAIL pixel tile=%05x row=%u col=%u got=%x want=%x "
               "(w0=%04x w1=%04x)\n", tile_num, row, col,
               (unsigned)d->pixel, want_pixel,
               char_ram[caddr], char_ram[caddr + 1]);
      fails++; return;
    }
    checks++;
    if (d->pal_index != want_pal) {
      if (fails < 12)
        printf("  FAIL pal_index got=%03x want=%03x\n",
               (unsigned)d->pal_index, want_pal);
      fails++; return;
    }
    checks++;
    if (d->prio != prio) { printf("  FAIL prio\n"); fails++; return; }
    checks++;
    if (d->transparent != (want_pixel == 0)) {
      printf("  FAIL transparent\n"); fails++; return;
    }
    checks++;
    if (d->disabled != ((vscr >> 15) & 1)) {
      printf("  FAIL disabled\n"); fails++; return;
    }
  };

  printf("test: every pixel of a tile, unscrolled\n");
  // Exhaustive over one 8x8 tile's worth of positions in every layer, which
  // covers all 64 (row, col) combinations of the character decode.
  for (uint32_t layer = 0; layer < 4; layer++)
    for (uint32_t y = 0; y < 8; y++)
      for (uint32_t x = 0; x < 8; x++)
        probe(x, y, layer, 0, 0);

  printf("test: exhaustive over a full 512x512 map, one layer\n");
  for (uint32_t y = 0; y < 512; y++)
    for (uint32_t x = 0; x < 512; x++)
      probe(x, y, 1, 0, 0);

  printf("test: scroll, including the wrap at 512\n");
  {
    // Scroll values chosen to straddle the 9-bit wrap in both directions,
    // since that is where a sign or width mistake shows up.
    const uint16_t scrolls[] = {0, 1, 7, 8, 255, 256, 257, 511,
                                0x1ff, 0x200, 0x3ff, 0xffff};
    for (uint16_t hs : scrolls)
      for (uint16_t vs : scrolls)
        for (uint32_t layer = 0; layer < 4; layer++)
          for (int k = 0; k < 64; k++)
            probe(rng() & 0x1ff, rng() & 0x1ff, layer, hs, vs);
  }

  printf("test: layer disable bit\n");
  for (int k = 0; k < 2000; k++)
    probe(rng() & 0x1ff, rng() & 0x1ff, rng() & 3,
          (uint16_t)rng(), (uint16_t)(rng() | 0x8000));

  printf("test: fuzz\n");
  for (long n = 0; n < 600000; n++)
    probe(rng() & 0x1ff, rng() & 0x1ff, rng() & 3,
          (uint16_t)rng(), (uint16_t)rng());

  int uncovered = 0;
  if (!n_disabled)    { printf("  NO COVERAGE for layer disable\n"); uncovered++; }
  if (!n_transparent) { printf("  NO COVERAGE for pen 0\n"); uncovered++; }
  if (!n_prio)        { printf("  NO COVERAGE for priority\n"); uncovered++; }
  if (!n_wrapx)       { printf("  NO COVERAGE for horizontal wrap\n"); uncovered++; }
  if (!n_wrapy)       { printf("  NO COVERAGE for vertical wrap\n"); uncovered++; }
  for (int l = 0; l < 4; l++)
    if (!layer_seen[l]) { printf("  NO COVERAGE for layer %d\n", l); uncovered++; }

  printf("m1_tile_decode: checks=%ld fails=%ld uncovered=%d\n",
         checks, fails, uncovered);
  delete d;
  return (fails || uncovered) ? 1 : 0;
}
