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
// Scanline fetch engine.
//
// The reference recomputes every pixel of the line from MAME's character
// layout, using the same byte-level bit-address formula as the decode test
// rather than the RTL's word-level shortcut.
//
// The risk this is really aimed at is the retained character row. Skipping a
// fetch when the next column names the same row is worth most of the layer's
// bandwidth on text screens, and it is also the easiest way to emit stale
// pixels: hold it one column too long, or across a scanline boundary, and the
// image is subtly wrong in a way that looks like a decode fault. So the tests
// deliberately include content where tiles repeat heavily, content where they
// never repeat, and a check that the retained row does not survive into the
// next line.

#include "Vm1_tile_fetch.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <vector>

static const int COLUMNS = 62;
static const uint16_t TILE_MASK = 0x3fff;

static std::vector<uint16_t> tile_ram(0x8000);
static std::vector<uint16_t> char_ram(0x40000);

static inline uint8_t char_byte(uint32_t idx) {
  uint16_t w = char_ram[idx >> 1];
  return (idx & 1) ? (uint8_t)(w >> 8) : (uint8_t)(w & 0xff);
}

// MAME's gfx decode, the long way — see tb_m1_tile_decode.cpp.
static uint8_t ref_pixel(uint32_t tile, int row, int col) {
  uint8_t val = 0;
  for (int plane = 0; plane < 4; plane++) {
    int bit = (row * 32 + col * 4 + plane) ^ 8;
    uint8_t b = char_byte(tile * 32 + (bit >> 3));
    val |= (uint8_t)(((b >> (7 - (bit & 7))) & 1) << (3 - plane));
  }
  return val;
}

struct Fetch {
  Vm1_tile_fetch* d;
  long cyc = 0;
  // Line buffer as the DUT writes it.
  uint16_t lb_pal[512];
  uint8_t  lb_tr[512], lb_pr[512];
  bool     lb_written[512];

  // Character port model with latency.
  int lat = 0, lat_cnt = 0;

  Fetch() {
    d = new Vm1_tile_fetch;
    d->clk = 0; d->rst_n = 0; d->start = 0; d->line = 0; d->layer = 0;
    d->hscr = 0; d->vscr = 0; d->tile_mask = TILE_MASK;
    d->tram_data = 0; d->char_data = 0; d->char_ack = 0;
    d->eval();
  }
  ~Fetch() { delete d; }

  void tick() {
    // Tile RAM: combinational address, data available next cycle.
    d->tram_data = tile_ram[d->tram_addr & 0x7fff];

    // Character RAM: two consecutive words, acked after `lat` cycles.
    if (d->char_req) {
      if (lat_cnt >= lat) {
        uint32_t a = d->char_addr & 0x3ffff;
        d->char_data = ((uint32_t)char_ram[(a + 1) & 0x3ffff] << 16) | char_ram[a];
        d->char_ack = 1;
      } else { lat_cnt++; d->char_ack = 0; }
    } else { lat_cnt = 0; d->char_ack = 0; }

    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    cyc++;

    if (d->lb_we) {
      uint16_t a = d->lb_addr & 0x1ff;
      lb_pal[a] = d->lb_pal;
      lb_tr[a] = d->lb_transparent;
      lb_pr[a] = d->lb_prio;
      lb_written[a] = true;
    }
  }

  void reset() {
    d->rst_n = 0;
    for (int i = 0; i < 4; i++) tick();
    d->rst_n = 1;
  }

  // Render one scanline; returns cycles taken.
  long render(int line, int layer, uint16_t hscr, uint16_t vscr) {
    for (int i = 0; i < 512; i++) lb_written[i] = false;
    d->line = line; d->layer = layer; d->hscr = hscr; d->vscr = vscr;
    long t0 = cyc;
    d->start = 1; tick(); d->start = 0;
    long guard = 0;
    while (!d->done && guard++ < 200000) tick();
    return cyc - t0;
  }
};

static long checks = 0, fails = 0;

static void verify(Fetch& f, int line, int layer, uint16_t hscr, uint16_t vscr,
                   const char* what) {
  long bad = 0;
  for (int sx = 0; sx < COLUMNS * 8; sx++) {
    uint32_t map_x = ((uint32_t)sx - (hscr & 0x1ff)) & 0x1ff;
    uint32_t map_y = ((uint32_t)line + (vscr & 0x1ff)) & 0x1ff;
    uint32_t taddr = (layer & 3) * 0x1000 + (map_y >> 3) * 64 + (map_x >> 3);
    uint16_t tw = tile_ram[taddr];
    uint32_t tnum = tw & TILE_MASK;
    uint32_t colour = (tw >> 7) & 0xff;
    uint8_t pix = ref_pixel(tnum, map_y & 7, map_x & 7);
    uint16_t want_pal = (uint16_t)((colour << 4) | pix);
    bool want_tr = (pix == 0) || ((vscr >> 15) & 1);
    bool want_pr = (tw >> 15) & 1;

    checks++;
    if (!f.lb_written[sx]) {
      if (bad < 6) printf("  FAIL %s: pixel %d never written\n", what, sx);
      bad++; fails++; continue;
    }
    if (f.lb_pal[sx] != want_pal || f.lb_tr[sx] != want_tr ||
        f.lb_pr[sx] != want_pr) {
      if (bad < 6)
        printf("  FAIL %s x=%d got pal=%03x tr=%d pr=%d want pal=%03x tr=%d pr=%d\n",
               what, sx, f.lb_pal[sx], f.lb_tr[sx], f.lb_pr[sx],
               want_pal, (int)want_tr, (int)want_pr);
      bad++; fails++;
    }
  }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  std::mt19937 rng(20260815u);
  for (auto& w : char_ram) w = (uint16_t)rng();

  // ------------------------------------------------- every tile different
  printf("test: all columns distinct — no fetch may be skipped\n");
  {
    for (size_t i = 0; i < tile_ram.size(); i++) tile_ram[i] = (uint16_t)rng();
    Fetch f; f.lat = 4; f.reset();
    long c = f.render(37, 1, 0, 0);
    verify(f, 37, 1, 0, 0, "distinct");
    printf("  %ld cycles, %u char fetches for %d columns\n",
           c, (unsigned)f.d->fetches, COLUMNS);
    checks++;
    if (f.d->fetches < COLUMNS - 2) {
      printf("  FAIL fetches=%u is too few for distinct tiles\n",
             (unsigned)f.d->fetches);
      fails++;
    }
  }

  // ------------------------------------------------------ repeated tiles
  printf("test: one repeated tile — the retained row must be reused AND right\n");
  {
    for (size_t i = 0; i < tile_ram.size(); i++) tile_ram[i] = 0x0123;
    Fetch f; f.lat = 4; f.reset();
    long c = f.render(11, 0, 0, 0);
    verify(f, 11, 0, 0, 0, "repeated");
    printf("  %ld cycles, %u char fetches for %d columns\n",
           c, (unsigned)f.d->fetches, COLUMNS);
    checks++;
    if (f.d->fetches != 1) {
      printf("  FAIL a uniform line should fetch once, got %u\n",
             (unsigned)f.d->fetches);
      fails++;
    }
  }

  // ------------------------------------------- alternating, worst case for reuse
  printf("test: alternating tiles — reuse must not fire across a change\n");
  {
    for (size_t i = 0; i < tile_ram.size(); i++)
      tile_ram[i] = (i & 1) ? 0x0055 : 0x00aa;
    Fetch f; f.lat = 2; f.reset();
    f.render(5, 2, 0, 0);
    verify(f, 5, 2, 0, 0, "alternating");
    printf("  %u char fetches\n", (unsigned)f.d->fetches);
  }

  // ------------------------------------------ consecutive lines, same tiles
  printf("test: the retained row must not survive into the next line\n");
  {
    // Same tiles on every line, so a row retained across the scanline boundary
    // would emit line N's pixels on line N+1 and the reuse check would not
    // notice, because the tile number really is the same.
    for (size_t i = 0; i < tile_ram.size(); i++) tile_ram[i] = 0x0777;
    Fetch f; f.lat = 3; f.reset();
    for (int ln = 0; ln < 8; ln++) {
      f.render(ln, 0, 0, 0);
      verify(f, ln, 0, 0, 0, "consecutive");
    }
    printf("  8 consecutive lines of one tile verified\n");
  }

  // ---------------------------------------------------------- scroll + fuzz
  printf("test: scroll, layers, disable, and latency\n");
  {
    for (size_t i = 0; i < tile_ram.size(); i++) tile_ram[i] = (uint16_t)rng();
    const uint16_t scr[] = {0, 3, 8, 255, 256, 511, 0x8000, 0xffff};
    for (uint16_t hs : scr) {
      for (uint16_t vs : scr) {
        Fetch f; f.lat = (int)(rng() % 12); f.reset();
        int ln = rng() & 0x1ff, ly = rng() & 3;
        f.render(ln, ly, hs, vs);
        verify(f, ln, ly, hs, vs, "scroll");
      }
    }
    printf("  64 scroll combinations across all four layers\n");
  }

  // ------------------------------------------------------------- budget
  printf("test: cycles per line against the scanline budget\n");
  {
    // A scanline is 656 pixel clocks at 16 MHz; at 100 MHz that is ~4100
    // cycles for all four layers, so one layer has ~1025.
    for (size_t i = 0; i < tile_ram.size(); i++) tile_ram[i] = (uint16_t)rng();
    Fetch f; f.lat = 14; f.reset();          // measured burst latency
    long c = f.render(99, 0, 0, 0);
    printf("  worst case (all distinct, lat=14): %ld cycles/layer/line\n", c);
    for (size_t i = 0; i < tile_ram.size(); i++) tile_ram[i] = 0x0040;
    Fetch g; g.lat = 14; g.reset();
    long c2 = g.render(99, 0, 0, 0);
    printf("  text case (one repeated tile):     %ld cycles/layer/line\n", c2);
  }

  printf("m1_tile_fetch: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
