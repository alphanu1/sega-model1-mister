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

static const int NWORDS = 6;
static const int CELL_W = 8;
static const int CELL_H = 16;

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
  if (x >= 32 * CELL_W || y >= NWORDS * CELL_H) return false;
  int row = y / CELL_H;
  int col = x / CELL_W;
  if ((y % CELL_H) == CELL_H - 1) { *out = 0x000000; return true; }
  if ((col % 4) == 0 && (x % CELL_W) == 0) { *out = 0x00C000; return true; }
  bool set = (w[row] >> (31 - col)) & 1;
  *out = set ? 0xFFFFFF : 0x000050;
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

  // Patterns chosen so a swapped bit order, a swapped word order or a stuck
  // cell all show up: a walking one, a walking zero, and two words whose hex
  // digits are all distinct.
  const uint32_t w1[NWORDS] = {0x00000001u, 0x80000000u, 0x01234567u,
                               0x89abcdefu, 0xffffffffu, 0x00000000u};
  const uint32_t w2[NWORDS] = {0xdeadbeefu, 0x55555555u, 0xaaaaaaaau,
                               0x0f0f0f0fu, 0xf0f0f0f0u, 0x12345678u};

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
