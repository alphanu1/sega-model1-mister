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
// Palette decode, exhaustive over all 65536 entry values.
//
// The reference is MAME's model1_paletteram_w line for line, including
// pal5bit's exact expansion and the order of operations around the intensity
// bit: MAME halves the EXPANDED 8-bit channel, not the 5-bit field. Halving
// first and expanding after gives a different answer for most inputs, and it
// is the kind of reordering that looks equivalent written down.

#include "Vm1_palette.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static inline int pal5bit(int v) { v &= 0x1f; return (v << 3) | (v >> 2); }

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vm1_palette;
  long checks = 0, fails = 0, dim = 0, bright = 0;

  for (uint32_t v = 0; v < 0x10000; v++) {
    d->entry = v;
    d->eval();

    int r = pal5bit((v >> 0) & 0x1f);
    int g = pal5bit((v >> 5) & 0x1f);
    int b = pal5bit((v >> 10) & 0x1f);
    if (!((v >> 15) & 1)) { r >>= 1; g >>= 1; b >>= 1; dim++; } else bright++;

    checks++;
    if (d->r != r || d->g != g || d->b != b) {
      if (fails < 10)
        printf("  FAIL %04x got %02x/%02x/%02x want %02x/%02x/%02x\n",
               v, (unsigned)d->r, (unsigned)d->g, (unsigned)d->b, r, g, b);
      fails++;
    }
  }

  // Named anchors, so a failure says which property broke rather than just
  // that some value differs.
  struct { uint16_t e; int r, g, b; const char* what; } spot[] = {
    {0x8000, 0x00, 0x00, 0x00, "black, full intensity"},
    {0xFFFF, 0xff, 0xff, 0xff, "white, full intensity"},
    {0x7FFF, 0x7f, 0x7f, 0x7f, "white, dimmed"},
    {0x801f, 0xff, 0x00, 0x00, "red channel is bits 4:0"},
    {0x83e0, 0x00, 0xff, 0x00, "green channel is bits 9:5"},
    {0xfc00, 0x00, 0x00, 0xff, "blue channel is bits 14:10"},
    // r=0x17->0xBD, g=0x1B->0xDE, b=0x1D->0xEF, all halved because bit 15 is
    // clear. Worked out rather than guessed: the first version of this anchor
    // carried invented numbers and failed against a correct DUT.
    {0x7777, 0x5e, 0x6f, 0x77, "Star Wars grey backdrop, the pen that found this"},
  };
  for (auto& s : spot) {
    d->entry = s.e; d->eval();
    checks++;
    if (d->r != s.r || d->g != s.g || d->b != s.b) {
      printf("  FAIL %s: %04x got %02x/%02x/%02x want %02x/%02x/%02x\n",
             s.what, s.e, (unsigned)d->r, (unsigned)d->g, (unsigned)d->b,
             s.r, s.g, s.b);
      fails++;
    }
  }

  int uncovered = 0;
  if (!dim)    { printf("  NO COVERAGE for dimmed entries\n"); uncovered++; }
  if (!bright) { printf("  NO COVERAGE for full-intensity entries\n"); uncovered++; }

  printf("m1_palette: checks=%ld fails=%ld uncovered=%d (exhaustive, %ld dim)\n",
         checks, fails, uncovered, dim);
  delete d;
  return (fails || uncovered) ? 1 : 0;
}
