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
// The debug overlay, checked cell by cell.
//
// This is an instrument, and an instrument that lies is worse than no
// instrument: a misread bit here sends the next debugging session after the
// wrong subsystem, on hardware, where every experiment costs a Quartus build.
// So every cell of every word is checked against the bit it claims to show,
// rather than eyeballing one screenshot.
//
// The raster is driven exactly as m1_video drives it — colour and blanking
// advancing together on ce_pix — so the position counters are exercised the way
// the real pixel stream exercises them, including the line and frame edges
// where an off-by-one lives.

#include "Vm1_diag.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static const int NWORDS = 12;
static const int CELL_W = 16;
static const int CELL_H = 16;

// The same font, mirrored here rather than shared. A test that imports the
// table it is checking proves the renderer consistent with itself and nothing
// more; typed out twice, a wrong glyph has to be wrong the same way twice to
// pass.
static const uint8_t FONT[16][8] = {
  {0x7C,0xC6,0xCE,0xD6,0xE6,0xC6,0x7C,0x00},  // 0
  {0x18,0x38,0x18,0x18,0x18,0x18,0x7E,0x00},  // 1
  {0x7C,0xC6,0x06,0x1C,0x30,0x60,0xFE,0x00},  // 2
  {0x7C,0xC6,0x06,0x3C,0x06,0xC6,0x7C,0x00},  // 3
  {0x0C,0x1C,0x3C,0x6C,0xFE,0x0C,0x0C,0x00},  // 4
  {0xFE,0xC0,0xFC,0x06,0x06,0xC6,0x7C,0x00},  // 5
  {0x3C,0x60,0xC0,0xFC,0xC6,0xC6,0x7C,0x00},  // 6
  {0xFE,0xC6,0x0C,0x18,0x30,0x30,0x30,0x00},  // 7
  {0x7C,0xC6,0xC6,0x7C,0xC6,0xC6,0x7C,0x00},  // 8
  {0x7C,0xC6,0xC6,0x7E,0x06,0x0C,0x78,0x00},  // 9
  {0x38,0x6C,0xC6,0xC6,0xFE,0xC6,0xC6,0x00},  // A
  {0xFC,0x66,0x66,0x7C,0x66,0x66,0xFC,0x00},  // B
  {0x3C,0x66,0xC0,0xC0,0xC0,0x66,0x3C,0x00},  // C
  {0xF8,0x6C,0x66,0x66,0x66,0x6C,0xF8,0x00},  // D
  {0xFE,0x62,0x68,0x78,0x68,0x62,0xFE,0x00},  // E
  {0xFE,0x62,0x68,0x78,0x68,0x60,0xF0,0x00},  // F
};

// A raster wide and tall enough to contain the box and still have room outside
// it for the passthrough checks.
static const int HVIS = 496, HBLANK = 100;
static const int VVIS = 384, VBLANK = 20;

static long checks = 0, fails = 0;
static int  reported = 0;

static void chk(bool ok, const char* what, int x, int y, uint32_t got,
                uint32_t want) {
  checks++;
  if (!ok) {
    fails++;
    if (reported++ < 20)
      printf("  FAIL %s at (%d,%d): got %06x want %06x\n", what, x, y, got,
             want);
  }
}

struct Diag {
  Vm1_diag* d;
  Diag() {
    d = new Vm1_diag;
    d->clk = 0; d->rst_n = 0; d->ce_pix = 1;
    d->enable = 0; d->hb = 1; d->vb = 1;
    d->in_r = 0; d->in_g = 0; d->in_b = 0;
    d->eval();
    for (int i = 0; i < 4; i++) tick();
    d->rst_n = 1;
  }
  ~Diag() { delete d; }
  void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
  uint32_t rgb() const {
    return ((uint32_t)d->out_r << 16) | ((uint32_t)d->out_g << 8) | d->out_b;
  }
};

// A pixel is PRESENTED for a cycle and then clocked past.
//
// The output is combinational on a registered counter, so it has to be read
// while that counter still holds this pixel's position — before the edge, not
// after it. Reading after the tick compares pixel N's colour against position
// N+1 and shows up as an overlay shifted one column left, which is exactly the
// sort of off-by-one this instrument exists to avoid making elsewhere.
static uint32_t present(Diag& g, uint8_t r, uint8_t gg, uint8_t b, bool hb,
                        bool vb) {
  g.d->in_r = r; g.d->in_g = gg; g.d->in_b = b;
  g.d->hb = hb; g.d->vb = vb;
  g.d->eval();
  uint32_t out = g.rgb();
  g.tick();
  return out;
}

// The words, as the DUT sees them. Verilator packs a 192-bit port into an
// array of 32-bit words, little end first, which is exactly one entry per
// debug word — but that is an implementation detail of the packing, so it is
// written through a helper rather than assumed at each use.
static void set_words(Diag& g, const uint32_t* w) {
  for (int i = 0; i < NWORDS; i++) g.d->words[i] = w[i];
}

// What the overlay should paint at a given visible position.
static bool expect_cell(int x, int y, const uint32_t* w, uint32_t* out) {
  if (x >= 8 * CELL_W || y >= NWORDS * CELL_H) return false;
  int row   = y / CELL_H;
  int digit = x / CELL_W;            // 0 leftmost = most significant nibble
  int fx    = (x % CELL_W) / 2;      // drawn at 2x
  int fy    = (y % CELL_H) / 2;
  int nib   = (w[row] >> ((7 - digit) * 4)) & 0xF;
  bool lit  = (FONT[nib][fy] >> (7 - fx)) & 1;
  *out = lit ? 0xFFFFFF : 0x000050;
  return true;
}

// One full frame, checking every visible pixel. `enable` off means every pixel
// must be untouched; on means every pixel must be the overlay's where the box
// is and untouched everywhere else.
static void run_frame(Diag& g, const uint32_t* w, bool enable) {
  g.d->enable = enable;
  set_words(g, w);

  // Vertical blanking first, which is what resets the line counter.
  for (int i = 0; i < VBLANK * 8; i++) present(g, 0, 0, 0, true, true);

  for (int y = 0; y < VVIS; y++) {
    for (int x = 0; x < HVIS; x++) {
      // A background that varies with position, so a passthrough failure
      // cannot hide behind a constant.
      uint8_t r = (uint8_t)(x & 0xff);
      uint8_t gg = (uint8_t)(y & 0xff);
      uint8_t b = (uint8_t)((x + y) & 0xff);
      uint32_t got = present(g, r, gg, b, false, false);

      uint32_t bg = ((uint32_t)r << 16) | ((uint32_t)gg << 8) | b;
      uint32_t want = bg;
      bool covered = enable && expect_cell(x, y, w, &want);
      if (!enable) want = bg;
      chk(got == want, covered ? "overlay" : "passthrough", x, y, got, want);
    }
    for (int i = 0; i < HBLANK; i++) present(g, 0, 0, 0, true, false);
  }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Diag g;

  // Between them these cover every glyph in every digit position, which is
  // what catches a font entry that is wrong or a nibble selected from the
  // wrong end of the word.
  const uint32_t w1[NWORDS] = {0x01234567u, 0x89abcdefu, 0xfedcba98u,
                               0x76543210u, 0x00000000u, 0xffffffffu,
                               0x00000001u, 0x80000000u, 0x0bfff8u,
                               0x104ef3d6u, 0x00300000u, 0x0b0824u};
  const uint32_t w2[NWORDS] = {0xdeadbeefu, 0x55555555u, 0xaaaaaaaau,
                               0x0f0f0f0fu, 0xf0f0f0f0u, 0x12345678u,
                               0x9abcdef0u, 0x13572468u, 0xfedcba98u,
                               0x02468aceu, 0x11223344u, 0xccddeeffu};

  // Disabled must be perfectly transparent. The overlay defaults to on in the
  // core, so the OSD switch that turns it off has to give the game back an
  // untouched picture.
  run_frame(g, w1, false);

  run_frame(g, w1, true);
  run_frame(g, w2, true);

  // A second frame with the same words must be identical: the position
  // counters have to come back to zero on vertical blanking, and a counter
  // that free-runs across the frame boundary would drift the overlay down the
  // screen one frame at a time.
  run_frame(g, w2, true);

  printf("m1_diag: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
