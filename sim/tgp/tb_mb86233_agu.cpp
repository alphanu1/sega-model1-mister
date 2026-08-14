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
// mb86233_agu fuzz harness.
//
// The reference mirrors MAME's ea_pre_0/ea_pre_1/ea_post_0/ea_post_1 with the
// same switch structure and the same u16 return type, because the truncation
// that return type performs is load-bearing:
//
//   third_party/mame/src/devices/cpu/mb86233/mb86233.cpp
//   BSD-3-Clause, copyright-holders: Olivier Galibert
//
// The DUT is combinational, so unlike the ALU and FP harnesses there is no
// pipeline to track and no latency to get wrong.
//
// No skips. Every input combination is defined behaviour on both sides.

#include "Vmb86233_agu.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>

// MAME's util::sext(value, 5): bit 4 is the sign, range -16..+15.
static int32_t sext5(uint32_t v) {
  return (int32_t)((v & 0x1f) ^ 0x10) - 0x10;
}

struct Regs { uint16_t b, x, i, vsmr; };

// Mirrors ea_pre_0 / ea_pre_1. Return type is u16 in MAME and that truncation
// is deliberate here: every sum below is modulo 2^16.
static uint16_t ea_pre(uint32_t r, const Regs& g) {
  switch (r & 0x180) {
    case 0x000: return (uint16_t)(r & 0x7f);
    case 0x080:
    case 0x100: return (uint16_t)((r & 0x7f) + g.b + g.x);
    case 0x180:
      switch (r & 0x60) {
        case 0x00: return (uint16_t)(g.b + g.x);
        case 0x20: return (uint16_t)(g.x);
        case 0x40: return (uint16_t)(g.b + (g.x & g.vsmr));
        case 0x60: return (uint16_t)(g.x & g.vsmr);
      }
  }
  return 0;
}

// Mirrors ea_post_0 / ea_post_1. Returns whether X is written, and the value.
static bool ea_post(uint32_t r, const Regs& g, uint16_t* x_out) {
  if (!(r & 0x100)) return false;
  if (!(r & 0x080)) *x_out = (uint16_t)(g.x + g.i);
  else              *x_out = (uint16_t)(g.x + sext5(r));
  return true;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vmb86233_agu;

  std::mt19937 rng(20260814u);
  std::uniform_int_distribution<uint32_t> dist(0, 0xffffffffu);

  const long N = 3000000;
  long checked = 0, fails = 0;
  // Coverage per addressing mode: [r&0x180 index][r&0x60 index]
  long mode_hits[4][4] = {{0}};

  for (long n = 0; n < N; n++) {
    uint32_t r;
    // Bias the first pass across the whole 9-bit field so every mode and every
    // post-increment value is hit exhaustively before going random.
    if (n < 512) r = (uint32_t)n;
    else         r = dist(rng) & 0x1ff;

    Regs g0, g1;
    g0.b = (uint16_t)dist(rng); g0.x = (uint16_t)dist(rng); g0.i = (uint16_t)dist(rng);
    g1.b = (uint16_t)dist(rng); g1.x = (uint16_t)dist(rng); g1.i = (uint16_t)dist(rng);

    // vsmr is not free: write_reg(0x0a) sets vsm = v & 7 and
    // vsmr = (8 << vsm) - 1, so only 7/15/31/63/127/255/511/1023 are
    // reachable. Fuzzing arbitrary 16-bit masks would test states the
    // hardware cannot enter.
    uint32_t vsm = dist(rng) & 7;
    uint16_t vsmr = (uint16_t)((8u << vsm) - 1u);
    g0.vsmr = vsmr; g1.vsmr = vsmr;

    bool bank      = dist(rng) & 1;
    bool add_200   = dist(rng) & 1;
    bool wrap16    = dist(rng) & 1;

    // Push every EA near the 16-bit boundary sometimes, so the two +0x200
    // arithmetics actually diverge instead of agreeing by luck.
    if ((dist(rng) & 7) == 0) {
      uint16_t near = (uint16_t)(0xfe00 + (dist(rng) & 0x1ff));
      if (bank) { g1.x = near; g1.b = 0; } else { g0.x = near; g0.b = 0; }
    }

    dut->r         = r;
    dut->bank      = bank;
    dut->b0 = g0.b; dut->x0 = g0.x; dut->i0 = g0.i;
    dut->b1 = g1.b; dut->x1 = g1.x; dut->i1 = g1.i;
    dut->vsmr      = vsmr;
    dut->add_0x200 = add_200;
    dut->wrap16    = wrap16;
    dut->eval();

    const Regs& g = bank ? g1 : g0;

    uint16_t pre = ea_pre(r, g);
    uint32_t ref_ea;
    if (!add_200)     ref_ea = pre;
    else if (wrap16)  ref_ea = (uint16_t)(pre + 0x200);   // u16 += 0x200
    else              ref_ea = (uint32_t)pre + 0x200;     // u32 = u16 + 0x200

    uint16_t ref_x = 0;
    bool ref_we = ea_post(r, g, &ref_x);

    checked++;
    mode_hits[(r >> 7) & 3][(r >> 5) & 3]++;

    bool got_we = bank ? dut->x1_we : dut->x0_we;
    bool oth_we = bank ? dut->x0_we : dut->x1_we;

    bool bad = false;
    if ((uint32_t)dut->ea != ref_ea)      bad = true;
    if (got_we != ref_we)                 bad = true;
    if (ref_we && dut->x_next != ref_x)   bad = true;
    // The unselected bank must never be written.
    if (oth_we)                           bad = true;

    if (bad) {
      if (fails < 20) {
        printf("MISMATCH r=%03x bank=%d add200=%d wrap16=%d "
               "b=%04x x=%04x i=%04x vsmr=%04x\n",
               r, bank, add_200, wrap16, g.b, g.x, g.i, g.vsmr);
        printf("    ea:     ref=%05x got=%05x   (ea_pre=%04x)\n",
               ref_ea, (uint32_t)dut->ea, pre);
        printf("    x:      ref we=%d %04x  got we=%d %04x  (other bank we=%d)\n",
               ref_we, ref_x, got_we, dut->x_next, oth_we);
      }
      fails++;
    }
  }

  // Every addressing mode must have been exercised. Mode 3's sub-select only
  // exists when r[8:7]==3, so the other rows are reported but not required.
  int uncovered = 0;
  for (int m = 0; m < 4; m++) {
    if (m != 3) {
      if (mode_hits[m][0] + mode_hits[m][1] + mode_hits[m][2] + mode_hits[m][3] == 0) {
        printf("NO COVERAGE for ea mode %d\n", m);
        uncovered++;
      }
    } else {
      for (int s = 0; s < 4; s++)
        if (mode_hits[3][s] == 0) {
          printf("NO COVERAGE for ea mode 3 sub %d\n", s);
          uncovered++;
        }
    }
  }

  printf("mb86233_agu: checked=%ld skipped=0 fails=%ld uncovered_modes=%d\n",
         checked, fails, uncovered);
  delete dut;
  return (fails || uncovered) ? 1 : 0;
}
