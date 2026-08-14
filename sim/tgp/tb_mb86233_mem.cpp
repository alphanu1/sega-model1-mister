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
// mb86233_mem fuzz harness.
//
// Lockstep against a C model of copro_data_map:
//
//   third_party/mame/src/mame/sega/model1_m.cpp
//
// Both RAM banks are modelled as plain arrays, and the external endpoints as
// single direction-specific addresses. The address stream deliberately walks
// every decode boundary before going random: 0x00ff/0x0100/0x0101,
// 0x01ff/0x0200, 0x03ff/0x0400/0x0401, and the 0x101ff top that the +0x200
// adder can reach.
//
// No skips.

#include "Vmb86233_mem.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <vector>

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vmb86233_mem;

  auto tick = [&]() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
  };

  dut->rst_n = 0;
  dut->req = 0; dut->we = 0; dut->addr = 0; dut->wdata = 0;
  dut->ext_rdata = 0; dut->ext_ack = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1;

  std::vector<uint32_t> ram0(256, 0), ram1(512, 0);

  std::mt19937 rng(20260814u);
  std::uniform_int_distribution<uint32_t> dist(0, 0xffffffffu);

  // Boundaries first, then random across the whole reachable 17-bit space.
  const uint32_t edges[] = {
    0x000ff, 0x00100, 0x00101, 0x001ff, 0x00200, 0x00201,
    0x003ff, 0x00400, 0x00401, 0x00000, 0x00001, 0x101ff,
    0x0ffff, 0x10000, 0x00fff, 0x08000,
  };
  const int NE = sizeof(edges) / sizeof(edges[0]);

  const long N = 2000000;
  long checked = 0, fails = 0;
  long hit_ram0 = 0, hit_ram1 = 0, hit_fin = 0, hit_fout = 0, hit_unmap = 0;

  for (long n = 0; n < N; n++) {
    uint32_t a = (n < NE) ? edges[n] : (dist(rng) & 0x1ffff);
    // Weight the mapped regions so most cycles do useful work.
    if (n >= NE && (dist(rng) & 1)) a = dist(rng) & 0x7ff;

    bool     w  = dist(rng) & 1;
    uint32_t wd = dist(rng);
    uint32_t xr = dist(rng);
    bool     ack = (dist(rng) & 3) != 0;   // external ready 75% of the time
    bool     rq = (dist(rng) & 15) != 0;   // occasionally idle

    bool ram0_sel = (a <= 0x000ff);
    bool ram1_sel = (a >= 0x00200 && a <= 0x003ff);
    bool fin_sel  = (a == 0x00100) && !w;
    bool fout_sel = (a == 0x00400) &&  w;
    bool unmap    = !(ram0_sel || ram1_sel || fin_sel || fout_sel);

    dut->req = rq; dut->we = w; dut->addr = a; dut->wdata = wd;
    dut->ext_rdata = xr; dut->ext_ack = ack;
    dut->eval();

    // Combinational decode and stall, checked before the edge.
    bool bad = false;
    if ((bool)dut->sel_ram0 != ram0_sel)      bad = true;
    if ((bool)dut->sel_ram1 != ram1_sel)      bad = true;
    if ((bool)dut->sel_fifo_in != fin_sel)    bad = true;
    if ((bool)dut->sel_fifo_out != fout_sel)  bad = true;
    if ((bool)dut->unmapped != unmap)         bad = true;
    if ((bool)dut->ext_rd != (rq && fin_sel)) bad = true;
    if ((bool)dut->ext_wr != (rq && fout_sel))bad = true;
    if ((bool)dut->stall != (rq && (fin_sel || fout_sel) && !ack)) bad = true;

    if (bad) {
      if (fails < 20)
        printf("DECODE MISMATCH n=%ld a=%05x we=%d req=%d ack=%d\n",
               n, a, w, rq, ack);
      fails++;
    }

    // Expected read data for THIS access, from model state before the edge.
    // The RAM read is registered, so it appears on rdata immediately AFTER the
    // tick that latches it — this cycle's access, not the previous one.
    // Deferring the check by an extra cycle produced a 99% failure rate that
    // looked exactly like a dead memory. See docs/rtl-conventions.md.
    uint32_t expect = 0;
    bool     do_check = rq && !w && (ram0_sel || ram1_sel || fin_sel);
    if (do_check) {
      if (ram0_sel)      expect = ram0[a & 0xff];
      else if (ram1_sel) expect = ram1[a & 0x1ff];
      else               expect = xr;
    }

    tick();

    if (do_check) {
      checked++;
      if (dut->rdata != expect) {
        if (fails < 20)
          printf("RDATA MISMATCH n=%ld a=%05x  ref=%08x got=%08x\n",
                 n, a, expect, dut->rdata);
        fails++;
      }
    }

    // Writes land on the same edge.
    if (rq && w) {
      if (ram0_sel) ram0[a & 0xff]  = wd;
      if (ram1_sel) ram1[a & 0x1ff] = wd;
    }

    if (ram0_sel) hit_ram0++;
    if (ram1_sel) hit_ram1++;
    if (fin_sel)  hit_fin++;
    if (fout_sel) hit_fout++;
    if (unmap)    hit_unmap++;
  }

  int uncovered = 0;
  if (!hit_ram0)  { printf("NO COVERAGE for ram0\n");      uncovered++; }
  if (!hit_ram1)  { printf("NO COVERAGE for ram1\n");      uncovered++; }
  if (!hit_fin)   { printf("NO COVERAGE for fifo_in\n");   uncovered++; }
  if (!hit_fout)  { printf("NO COVERAGE for fifo_out\n");  uncovered++; }
  if (!hit_unmap) { printf("NO COVERAGE for unmapped\n");  uncovered++; }

  printf("mb86233_mem: checked=%ld skipped=0 fails=%ld uncovered=%d\n",
         checked, fails, uncovered);
  delete dut;
  return (fails || uncovered) ? 1 : 0;
}
