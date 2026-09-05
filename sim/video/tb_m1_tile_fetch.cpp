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
  uint8_t  lb_tr[512], lb_pr[512], lb_mk[512];
  bool     lb_written[512];

  // TWO character ports, each modelled independently with its own latency
  // counter, because the engine now keeps a fetch in flight on one while the
  // other retires. A single shared counter would serialise them in the model
  // and hide exactly the overlap this is meant to test.
  int lat = 0, lat_cnt[2] = {0, 0};
  long tw_pulses = 0;

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

    // Character RAM: two consecutive words per port, acked after `lat` cycles.
    //
    // char_addr and char_data are PACKED arrays on the RTL side, so Verilator
    // presents each as one wide word rather than a C array - port 1 lives in
    // the upper bits. Indexing them like arrays compiles against the wrong
    // type and is how this bench first failed to build.
    uint8_t  acks = 0;
    uint64_t dat  = d->char_data;
    for (int pt = 0; pt < 2; pt++) {
      if ((d->char_req >> pt) & 1) {
        if (lat_cnt[pt] >= lat) {
          uint32_t a = (uint32_t)((d->char_addr >> (18 * pt)) & 0x3ffff);
          uint64_t w = ((uint32_t)char_ram[(a + 1) & 0x3ffff] << 16)
                     | char_ram[a];
          dat &= ~((uint64_t)0xffffffffULL << (32 * pt));
          dat |=  (w & 0xffffffffULL) << (32 * pt);
          acks |= (1 << pt);
        } else {
          lat_cnt[pt]++;
        }
      } else {
        lat_cnt[pt] = 0;
      }
    }
    d->char_data = dat;
    d->char_ack  = acks;

    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    cyc++;
    if (d->tw_nonblank) tw_pulses++;

    // Four pixels a cycle now, with lb_we a per-pixel valid mask: the group is
    // clipped at the tile boundary and at the end of the line, so the first
    // group of a scrolled line and the last of any line are short. Collected
    // by screen address, so everything downstream of here is unchanged — a
    // pixel is still checked against the reference at the position it landed.
    for (int i = 0; i < 4; i++) {
      if (!((d->lb_we >> i) & 1)) continue;
      uint16_t a = (d->lb_addr + i) & 0x1ff;
      lb_pal[a] = (d->lb_pal >> (12 * i)) & 0xfff;
      lb_tr[a] = (d->lb_transparent >> i) & 1;
      lb_pr[a] = (d->lb_prio >> i) & 1;
      lb_mk[a] = (d->lb_masked >> i) & 1;
      lb_written[a] = true;
    }
  }

  void reset() {
    d->rst_n = 0;
    for (int i = 0; i < 4; i++) tick();
    d->rst_n = 1;
  }

  // Render one scanline; returns cycles taken.
  //
  // row_mask and layer_off were never driven here and lb_masked was never
  // checked, so this module's masking was covered only end-to-end through
  // m1_video — whose reference model was written from the same reading of MAME as
  // the RTL. When that reading turned out to be wrong, 380,929 checks agreed with
  // the bug. A module's own outputs need checking at the module.
  long render(int line, int layer, uint16_t hscr, uint16_t vscr,
              uint64_t rmask = 0, bool loff = false,
              bool sen = false, int sx_split = 0, bool sright = false) {
    for (int i = 0; i < 512; i++) lb_written[i] = false;
    tw_pulses = 0;
    d->line = line; d->layer = layer; d->hscr = hscr; d->vscr = vscr;
    d->row_mask = rmask; d->layer_off = loff;
    d->split_en = sen; d->split_x = sx_split; d->split_right = sright;
    long t0 = cyc;
    d->start = 1; tick(); d->start = 0;
    long guard = 0;
    while (!d->done && guard++ < 200000) tick();
    return cyc - t0;
  }
};

static long checks = 0, fails = 0;

// The mask bit for a screen pixel: four 16-bit words across 512 pixels, bit 15
// the leftmost eight. The fetch engine applies the bit as given — the odd-tilemap
// inversion happens in m1_video when the word is read, mirroring MAME's
// `if (win) m = ~m` — so this must NOT invert.
// Window modes 2/3 add a per-pixel column split: masked on the side this layer
// does NOT own, which is the disagreement between `x < h` and split_right.
static int want_mask_bit(uint64_t rmask, int sx, bool loff,
                         bool sen = false, int h = 0, bool sright = false) {
  if (loff) return 1;
  if (sen && ((sx < h) == sright)) return 1;
  uint16_t w = (uint16_t)(rmask >> (((sx >> 7) & 3) * 16));
  return (w >> (15 - ((sx >> 3) & 15))) & 1;
}

static void verify(Fetch& f, int line, int layer, uint16_t hscr, uint16_t vscr,
                   const char* what, uint64_t rmask = 0, bool loff = false,
                   bool sen = false, int h = 0, bool sright = false) {
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
    int want_mk = want_mask_bit(rmask, sx, loff, sen, h, sright);
    if (f.lb_pal[sx] != want_pal || f.lb_tr[sx] != want_tr ||
        f.lb_pr[sx] != want_pr || f.lb_mk[sx] != want_mk) {
      if (bad < 6)
        printf("  FAIL %s x=%d got pal=%03x tr=%d pr=%d mk=%d want pal=%03x tr=%d pr=%d mk=%d\n",
               what, sx, f.lb_pal[sx], f.lb_tr[sx], f.lb_pr[sx], f.lb_mk[sx],
               want_pal, (int)want_tr, (int)want_pr, want_mk);
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

  // ------------------------------------------------- content census pulse
  // tw_nonblank must follow the tile WORD and nothing else: blank means zero or
  // tile 0x20, the space. Asserted directly because the whole value of this
  // instrument is that a zero means "this layer holds nothing" — an instrument
  // that pulses on blank tiles would report content everywhere and send the next
  // investigation at the wrong subsystem.
  printf("test: content census pulses only on non-blank tile words\n");
  {
    struct { uint16_t word; const char* what; bool want; } cases[] = {
      {0x0000, "all-zero",    false},
      {0x0020, "all-space",   false},
      {0x8020, "space+cat1",  false},   // the blank rule masks to 0x3fff first
      {0x0123, "real tile",   true},
      {0x3fff, "max tile",    true},
    };
    Fetch f; f.lat = 2; f.reset();
    for (auto& c : cases) {
      for (size_t i = 0; i < tile_ram.size(); i++) tile_ram[i] = c.word;
      f.render(5, 0, 0, 0);
      checks++;
      bool got = f.tw_pulses > 0;
      if (got != c.want) {
        printf("  FAIL %s: %ld pulses, expected %s\n",
               c.what, f.tw_pulses, c.want ? "some" : "none");
        fails++;
      }
      // A pulse must never outnumber the tile-word reads it comes from, which is
      // what a level held instead of a one-cycle pulse would do.
      checks++;
      if (f.tw_pulses > COLUMNS) {
        printf("  FAIL %s: %ld pulses exceeds %d columns — held level, not a pulse\n",
               c.what, f.tw_pulses, COLUMNS);
        fails++;
      }
    }
  }

  // ------------------------------------------------------------- row mask
  // The mask must reach lb_masked per pixel, unmodified and independent of the
  // tile's category. Four pixels are emitted per cycle and can straddle an
  // 8-pixel mask column whenever the scroll is unaligned, so an unaligned hscr
  // is the case that matters — a per-group lookup instead of a per-pixel one
  // passes an aligned test and fails this one.
  printf("test: row mask reaches lb_masked per pixel, category-independent\n");
  {
    for (size_t i = 0; i < tile_ram.size(); i++) tile_ram[i] = (uint16_t)rng();
    Fetch f; f.lat = 3; f.reset();
    // Mixed: solid, empty, alternating and a single isolated bit, so a wrong
    // word order or a reversed bit order inside a word both show up.
    const uint64_t rm = 0xffff0000a5a50100ull;
    f.render(23, 2, 5, 0, rm, false);
    verify(f, 23, 2, 5, 0, "mask-unaligned", rm, false);
    f.render(23, 2, 0, 0, rm, false);
    verify(f, 23, 2, 0, 0, "mask-aligned", rm, false);
    // Category must not enter into it: the same mask over tile words with bit 15
    // set everywhere must give the same lb_masked. This is the fault that hid the
    // game's text, so it is asserted directly rather than inferred.
    for (size_t i = 0; i < tile_ram.size(); i++) tile_ram[i] |= 0x8000;
    f.render(23, 2, 5, 0, rm, false);
    verify(f, 23, 2, 5, 0, "mask-cat1", rm, false);
    // layer_off forces every pixel masked, whatever the table says.
    f.render(23, 2, 5, 0, rm, true);
    verify(f, 23, 2, 5, 0, "mask-layer-off", rm, true);
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
    // TWO, not one, and by design. The engine keeps two requests in flight and
    // the repeat cache matches COMPLETED fetches only, so the first two columns
    // are both issued before either retires and the second misses the cache.
    // One extra fetch a line is the price of covering the round trip; matching
    // against the in-flight set as well would cost more than it saves.
    //
    // The property that matters is unchanged and still tested: 62 columns of
    // one tile must not become 62 fetches.
    checks++;
    if (f.d->fetches > 2) {
      printf("  FAIL a uniform line should fetch at most twice, got %u\n",
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

  // ----------------------------------- window modes 2/3, the per-pixel split
  //
  // Mode 1's vertical split is one bit for a whole scanline and rides on
  // layer_off. Modes 2/3 split at an arbitrary x, so the mask has to change part
  // way through a four-pixel emit group — which is the only reason this belongs
  // here rather than in m1_video. 194 frames of 2,478 on real game code select
  // mode 2 on the pair the TEXT lives on, and it was blanked outright until this.
  printf("test: the modes 2/3 column split masks exactly one side\n");
  {
    for (size_t i = 0; i < tile_ram.size(); i++) tile_ram[i] = (uint16_t)(i * 7 + 1);
    Fetch f; f.lat = 3; f.reset();
    // h=0 collapses the left region to nothing and h=496 the right; those are
    // where MAME's clip rectangles degenerate and where an off-by-one shows up as
    // a whole missing region rather than one wrong pixel.
    const int hs[] = {0, 1, 3, 8, 137, 248, 249, 495, 496};
    for (int hi = 0; hi < 9; hi++)
      for (int side = 0; side < 2; side++) {
        char what[64];
        snprintf(what, sizeof what, "split h=%d right=%d", hs[hi], side);
        f.render(11, 0, 0, 0, 0, false, true, hs[hi], side != 0);
        verify(f, 11, 0, 0, 0, what, 0, false, true, hs[hi], side != 0);
      }
    // It composes with the row mask rather than replacing it, and layer_off still
    // wins over both — so mode 1 and modes 2/3 cannot end up half-applied.
    uint64_t rm = 0xf0f00f0fffff0000ull;
    f.render(12, 1, 0, 0, rm, false, true, 200, true);
    verify(f, 12, 1, 0, 0, "split+rowmask", rm, false, true, 200, true);
    f.render(13, 0, 0, 0, 0, true, true, 100, false);
    verify(f, 13, 0, 0, 0, "split+layer_off", 0, true, true, 100, false);
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
