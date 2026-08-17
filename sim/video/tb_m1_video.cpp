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
// Whole 2D video path, frame by frame.
//
// Every earlier video test checked one stage against MAME. This checks that
// the stages, wired together, still produce MAME's picture: it renders real
// frames and compares every visible pixel's RGB against a reference that runs
// the entire chain — scroll, tile lookup, 4bpp unpack, the four-layer priority
// order, and the palette's intensity bit.
//
// Integration is where the per-stage tests cannot help. Each of decode, mixer
// and palette passes on its own with the layers connected in the wrong order,
// the line buffers read a pixel out of step, or the scroll registers fetched
// for the wrong layer. Those are exactly the faults this can see and they are
// only visible end to end.

#include "Vm1_video.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <vector>

static const int H_TOTAL = 656, H_VIS = 496, V_TOTAL = 424, V_VIS = 384;
static const int COLUMNS = 62;
static const uint16_t TILE_MASK = 0x3fff;

static std::vector<uint16_t> tile_ram(0x8000);
static std::vector<uint16_t> char_ram(0x40000);
static std::vector<uint16_t> pal_ram(4096);

static inline uint8_t char_byte(uint32_t i) {
  uint16_t w = char_ram[i >> 1];
  return (i & 1) ? (uint8_t)(w >> 8) : (uint8_t)(w & 0xff);
}
static uint8_t ref_pixel(uint32_t tile, int row, int col) {
  uint8_t v = 0;
  for (int p = 0; p < 4; p++) {
    int bit = (row * 32 + col * 4 + p) ^ 8;
    uint8_t b = char_byte(tile * 32 + (bit >> 3));
    v |= (uint8_t)(((b >> (7 - (bit & 7))) & 1) << (3 - p));
  }
  return v;
}
static inline int pal5bit(int v) { v &= 0x1f; return (v << 3) | (v >> 2); }

// The whole chain for one pixel, independent of the RTL's structure.
static void ref_rgb(int x, int y, int* R, int* G, int* B) {
  int pal[4], transp[4], prio[4];
  for (int L = 0; L < 4; L++) {
    uint16_t hscr = tile_ram[0x5000 + L];
    uint16_t vscr = tile_ram[0x5004 + L];
    uint32_t mx = ((uint32_t)x - (hscr & 0x1ff)) & 0x1ff;
    uint32_t my = ((uint32_t)y + (vscr & 0x1ff)) & 0x1ff;
    uint16_t tw = tile_ram[L * 0x1000 + (my >> 3) * 64 + (mx >> 3)];
    uint32_t tn = tw & TILE_MASK;
    uint8_t px = ref_pixel(tn, my & 7, mx & 7);
    pal[L] = (((tw >> 7) & 0xff) << 4) | px;
    transp[L] = (px == 0) || ((vscr >> 15) & 1);
    prio[L] = (tw >> 15) & 1;
  }
  // Window/split-scroll. `ctrl` is the PAIR's even vscr — MAME reads
  // tile_ram[0x5004 + ((layer >> 1) & 2)] — so one register governs both maps of
  // a pair.
  //
  // The nesting in draw_common matters as much as the arithmetic:
  //
  //   if (ctrl & 0x6000) {           // window mode
  //       if (layer & 1) return;     // the odd map never draws directly
  //       set_scrolly(both);
  //       if (hscr & 0x8000) { ...draw per line... }   // no else
  //   } else { ...normal path with the row mask... }
  //
  // With the mode selected and hscr bit 15 clear, NEITHER map of the pair draws.
  // The game does exactly that — ctrl 0x2000 on pair 2/3 with hscr never above
  // 0x0200 — and drawing the even map anyway put an opaque full-screen fill
  // (the sky and sea) where the hardware shows nothing.
  int win_off[4];
  for (int L = 0; L < 4; L++) {
    uint16_t ctrl = tile_ram[0x5004 + (L & 2)];
    if (!(ctrl & 0x6000)) { win_off[L] = 0; continue; }
    uint16_t hs   = tile_ram[0x5000 + (L & 2)];   // the PAIR's even hscr
    if (!(hs & 0x8000)) { win_off[L] = 1; continue; }   // nothing draws
    uint16_t nv   = (uint16_t)(-(int)ctrl);
    int v         = nv & 0x1ff;
    int swap      = !(nv & 0x200);
    int pick      = (y < v) ? swap : !swap;   // which map of the pair is live
    win_off[L]    = ((L & 1) != pick);
  }

  // The row mask, from draw_common/draw_rect. Two tables — 0x6000 for tilemaps
  // 0/1, 0x6800 for 2/3 — four words per SCREEN scanline, one bit per 8-pixel
  // column, bit 15 leftmost.
  //
  // THE MASK IS KEYED TO THE ODD/EVEN TILEMAP, NOT TO THE TILE CATEGORY. Both
  // come out of `layer & 1` in draw_common, one line apart and either side of a
  // shift, which is how they got conflated:
  //
  //   uint16_t tpri = layer & 1;   // before the shift -> category
  //   layer >>= 1;
  //   int win = layer & 1;         // after the shift  -> odd tilemap
  //
  // draw_rect applies them as independent gates: `if (win) m = ~m` decides
  // whether the column draws from this tilemap at all, `srct[xx] == tpri`
  // decides which tiles within it. So a set bit hides an even tilemap's column
  // in BOTH categories, and reveals an odd tilemap's.
  //
  // Read as `mask ^ category`, every category-1 tile on an even tilemap was
  // suppressed wherever the bit was clear — which is where the game's text is.
  int mbit[4];
  for (int L = 0; L < 4; L++) {
    uint16_t m = tile_ram[((L & 2) ? 0x6800 : 0x6000) + y * 4 + (x >> 7)];
    if (L & 1) m = (uint16_t)~m;
    mbit[L] = (m >> (15 - ((x >> 3) & 15))) & 1;
  }

  // Mixer: paint back to front, MAME's draw order 6,4,2,0 then 7,5,3,1.
  int idx = 0;
  // The mask gate is the same in both passes — it is a property of the tilemap,
  // not of the category.
  auto cat0 = [&](int i) {
    if (win_off[i]) return;                  // this line belongs to the partner
    if (prio[i]) return;
    if (mbit[i]) return;                 // this column is not drawn from map i
    if (transp[i] && i < 2) return;      // 6 and 4 are opaque, 2 and 0 are not
    idx = pal[i];
  };
  auto cat1 = [&](int i) {
    if (win_off[i]) return;
    if (!prio[i] || transp[i]) return;
    if (mbit[i]) return;                 // same gate, same polarity
    idx = pal[i];
  };
  cat0(3); cat0(2); cat0(1); cat0(0);
  cat1(3); cat1(2); cat1(1); cat1(0);

  uint16_t e = pal_ram[idx & 0xfff];
  int r = pal5bit(e), g = pal5bit(e >> 5), b = pal5bit(e >> 10);
  if (!((e >> 15) & 1)) { r >>= 1; g >>= 1; b >>= 1; }
  *R = r; *G = g; *B = b;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vm1_video;
  std::mt19937 rng(20260815u);

  for (auto& w : char_ram) w = (uint16_t)rng();
  for (auto& w : pal_ram)  w = (uint16_t)rng();
  // Text-like content: a small set of recurring tiles, which is what a menu or
  // a status line actually contains and what the fetch budget was measured
  // against. Filling tile RAM at random is the all-distinct worst case, which
  // docs/m1-m4-plan.md records as NOT fitting a line period — rendering then
  // overruns into the next line and the picture is legitimately wrong. Testing
  // correctness with content the design does not claim to support would be
  // testing the wrong thing; the overrun is checked separately below.
  for (size_t i = 0; i < tile_ram.size(); i++) {
    static const uint16_t font[8] = {0x0020, 0x0041, 0x0042, 0x0043,
                                     0x8020, 0x8041, 0x0000, 0x00ff};
    // Vary by tile ROW, not by column. Indexing with (i & 7) changes the tile
    // every column, which is the all-distinct worst case wearing a font's
    // clothing — 62 fetches per layer per line, over budget, exactly what this
    // fill was meant to avoid.
    tile_ram[i] = font[(i >> 6) & 7];
  }
  // Scroll registers: a mix of aligned, unaligned and one disabled layer.
  tile_ram[0x5000] = 0;      tile_ram[0x5004] = 0;
  tile_ram[0x5001] = 5;      tile_ram[0x5005] = 3;
  tile_ram[0x5002] = 0x1f8;  tile_ram[0x5006] = 0x101;
  tile_ram[0x5003] = 11;     tile_ram[0x5007] = 0x8000;   // layer 3 disabled

  // Pair 2/3 in window mode 1 with a mid-screen split, so the path the game
  // actually uses is covered. Without this ctrl reads 0x0020, the mode is off,
  // and the whole window implementation goes untested — which it was, and both
  // suites still passed.
  tile_ram[0x5006] = 0x2000 | (uint16_t)(-160 & 0x1ff);   // mode 1, v = 160
  tile_ram[0x5004] = 0x0000;                              // pair 0/1 normal
  // Window mode has TWO outcomes and they need separate coverage: with hscr bit
  // 15 set the pair draws one map per region, and with it clear the pair draws
  // NOTHING. The second is what the game selects, and the first is the logic that
  // would silently stop being tested if only the second were covered. So this
  // alternates per frame — see the frame loop.
  //
  // Only ever set on the window-mode pair. In the NORMAL path hscr bit 15 selects
  // the per-line H-scroll table at 0x4000, which is unimplemented, so setting it
  // on pair 0/1 would be testing against a divergence rather than a fixture.
  tile_ram[0x5002] = 0x8000 | 0x1f8;                      // pair 2/3 hscr

  d->clk = 0; d->rst_n = 0; d->ce_pix = 0; d->tile_mask = TILE_MASK;
  d->tram_data = 0; d->char_data = 0; d->char_ack = 0; d->pal_data = 0;

  int cediv = 0, lat_cnt = 0;
  const int CE_DIV = 6;            // 96 MHz core / 6 = 16 MHz dot clock
  const int CHAR_LAT = 14;         // measured SDRAM burst latency

  auto tick = [&]() {
    d->tram_data = tile_ram[d->tram_addr & 0x7fff];
    if (d->char_req) {
      if (lat_cnt >= CHAR_LAT) {
        uint32_t a = d->char_addr & 0x3ffff;
        d->char_data = ((uint32_t)char_ram[(a + 1) & 0x3ffff] << 16) | char_ram[a];
        d->char_ack = 1;
      } else { lat_cnt++; d->char_ack = 0; }
    } else { lat_cnt = 0; d->char_ack = 0; }

    d->ce_pix = (cediv == 0);
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    d->pal_data = pal_ram[d->pal_addr & 0xfff];    // registered palette read
    cediv = (cediv + 1) % CE_DIV;
  };

  for (int i = 0; i < 40; i++) tick();
  d->rst_n = 1;

  long checks = 0, fails = 0;

  // Frame 0 warms the line buffers; frame 1 and 2 are checked.
  printf("test: two full frames, every visible pixel against the reference\n");
  int x = 0, y = 0;
  long captured = 0, frames = 0;
  bool prev_vb = false;

  for (long n = 0; n < (long)H_TOTAL * V_TOTAL * CE_DIV * 3 + 4000; n++) {
    tick();
    if (!d->ce_pix) continue;

    // Frame boundary on the rising edge of delayed vblank.
    if (d->vid_vb && !prev_vb) {
      frames++; x = 0; y = 0;
      // Flip the window pair between its two outcomes. Changed on the rising
      // edge of vblank, which is ~40 blank lines before the first visible line
      // is rendered, so the RTL and the reference cannot disagree about which
      // value applied to a line.
      tile_ram[0x5002] = (frames & 1) ? (uint16_t)(0x8000 | 0x1f8)
                                      : (uint16_t)0x01f8;
    }
    prev_vb = d->vid_vb;

    if (!d->vid_hb && !d->vid_vb) {
      if (frames >= 1 && y < V_VIS && x < H_VIS) {
        int R, G, B;
        ref_rgb(x, y, &R, &G, &B);
        checks++;
        if (d->vid_r != R || d->vid_g != G || d->vid_b != B) {
          if (fails < 10)
            printf("  FAIL (%d,%d) got %02x/%02x/%02x want %02x/%02x/%02x\n",
                   x, y, (unsigned)d->vid_r, (unsigned)d->vid_g,
                   (unsigned)d->vid_b, R, G, B);
          fails++;
        }
        captured++;
      }
      x++;
    } else if (x) {
      x = 0; y++;
    }
    if (frames >= 3) break;
  }

  printf("  %ld pixels compared over %ld frames, worst-layer fetches %u\n",
         captured, frames, (unsigned)d->dbg_fetches);
  checks++;
  if (captured < (long)H_VIS * V_VIS) {
    printf("  FAIL only %ld pixels captured, expected at least %ld\n",
           captured, (long)H_VIS * V_VIS);
    fails++;
  }

  printf("m1_video: checks=%ld fails=%ld\n", checks, fails);
  delete d;
  return fails ? 1 : 0;
}
