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
// Tilemap priority mixer, checked against a painter's-algorithm reference.
//
// The RTL resolves priority front-to-back and takes the first hit. The
// reference does the opposite — it paints back-to-front into a pixel, exactly
// as MAME's eight successive draw() calls do, letting later writes overwrite
// earlier ones. The two are equivalent only if the ordering is right, so
// writing the reference in the other direction is what makes the comparison
// worth anything.
//
// Exhaustive: the mixer's whole input space that affects the decision is
// 4 tilemaps x (prio, transparent, disabled) plus poly_valid = 2^13 states,
// so every one is enumerated rather than sampled.

#include "Vm1_tile_mixer.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vm1_tile_mixer;

  // Distinct values so a mix-up names its source rather than blending in.
  const uint16_t PAL[4] = {0x111, 0x222, 0x333, 0x444};
  const uint16_t POLY   = 0x555;
  const uint16_t BACK   = 0x666;

  long checks = 0, fails = 0;
  long won[10] = {0};

  for (uint32_t s = 0; s < (1u << 13); s++) {
    uint32_t prio  =  s        & 0xf;
    uint32_t transp = (s >> 4) & 0xf;
    uint32_t dis    = (s >> 8) & 0xf;
    uint32_t pv     = (s >> 12) & 1;

    d->pal_index = ((uint64_t)PAL[3] << 36) | ((uint64_t)PAL[2] << 24) |
                   ((uint64_t)PAL[1] << 12) | PAL[0];
    d->transparent = transp;
    d->prio = prio;
    d->disabled = dis;
    d->poly_index = POLY;
    d->poly_valid = pv;
    d->backdrop = BACK;
    d->eval();

    // Reference: paint back to front, in MAME's draw order.
    //   6, 4 (opaque), 2, 0  ->  3D  ->  7, 5, 3, 1
    int pixel = BACK;
    int src = 15;
    auto paint_cat0 = [&](int i) {
      if (dis & (1 << i)) return;
      if (prio & (1 << i)) return;              // this tile belongs to cat1
      bool opaque = (i >= 2);                   // layers 6 and 4
      if ((transp & (1 << i)) && !opaque) return;
      pixel = PAL[i]; src = 4 + i;
    };
    auto paint_cat1 = [&](int i) {
      if (dis & (1 << i)) return;
      if (!(prio & (1 << i))) return;           // this tile belongs to cat0
      if (transp & (1 << i)) return;
      pixel = PAL[i]; src = i;
    };
    paint_cat0(3); paint_cat0(2); paint_cat0(1); paint_cat0(0);
    if (pv) { pixel = POLY; src = 8; }
    paint_cat1(3); paint_cat1(2); paint_cat1(1); paint_cat1(0);

    checks++;
    if (d->pixel != pixel || d->source != src) {
      if (fails < 12)
        printf("  FAIL prio=%x transp=%x dis=%x poly=%u  got pixel=%03x src=%u"
               "  want pixel=%03x src=%d\n",
               prio, transp, dis, pv, (unsigned)d->pixel, (unsigned)d->source,
               pixel, src);
      fails++;
    }
    won[src == 15 ? 9 : (src == 8 ? 8 : src)]++;
  }

  // Every slot must be reachable. A mixer where one layer can never win is a
  // mixer with a layer wired out, and the image still looks broadly right.
  int uncovered = 0;
  const char* SLOT[10] = {"tm0.cat1","tm1.cat1","tm2.cat1","tm3.cat1",
                          "tm0.cat0","tm1.cat0","tm2.cat0","tm3.cat0",
                          "3D","backdrop"};
  for (int i = 0; i < 10; i++)
    if (!won[i]) { printf("  NO COVERAGE: %s never wins\n", SLOT[i]); uncovered++; }

  printf("m1_tile_mixer: checks=%ld fails=%ld uncovered=%d (exhaustive)\n",
         checks, fails, uncovered);
  for (int i = 0; i < 10; i++) printf("  %-10s won %ld\n", SLOT[i], won[i]);

  delete d;
  return (fails || uncovered) ? 1 : 0;
}
