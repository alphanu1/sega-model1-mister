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
// fp_div fuzz harness. Reference is the host C float, matching MAME's
// evaluation model (fdvd is f2u(u2f(m_d) / u2f(m_a))).
//
// Unlike fp_mul and fp_add this DUT is NOT fixed-latency: it is a radix-2
// restoring divider with a busy/out_valid handshake. So there is no pipeline
// array here — the harness issues one operation, spins until out_valid, and
// compares. That also removes the depth-off-by-one trap that cost two of the
// other harnesses a full debugging round.
//
// Skips, each for the same documented reason as the other FP blocks:
//   - denormal operands and denormal results: the RTL flushes, the host does not
//   - NaN results: the RTL emits canonical 0x7fc00000, the host propagates the
//     operand payload

#include "Vfp_div.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static bool is_denorm(uint32_t u) {
  return ((u >> 23) & 0xff) == 0 && (u & 0x7fffff) != 0;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vfp_div;

  auto tick = [&]() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
  };

  dut->rst_n = 0; dut->in_valid = 0; dut->a = 0; dut->b = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1;

  std::mt19937 rng(20260814u);
  std::uniform_int_distribution<uint32_t> dist(0, 0xffffffffu);

  const uint32_t seeds[] = {
    0x00000000, 0x80000000,             // +0 -0
    0x3f800000, 0xbf800000,             // +1 -1
    0x7f800000, 0xff800000,             // +inf -inf
    0x7fc00000, 0x7f800001,             // qNaN sNaN
    0x00800000, 0x007fffff,             // smallest normal, largest denorm
    0x7f7fffff, 0xff7fffff,             // largest finite
    0x40000000, 0x3eaaaaab,             // 2.0, 1/3
    0x3f000000, 0x41200000,             // 0.5, 10.0
    0x40490fdb, 0xc0490fdb,             // +pi -pi
  };
  const int NS = sizeof(seeds) / sizeof(seeds[0]);

  const long N = 300000;      // ~29 cycles each; 2M would run for minutes
  long checked = 0, skipped = 0, fails = 0;
  long max_cycles = 0;

  for (long n = 0; n < N; n++) {
    uint32_t a, b;
    if (n < NS * NS) { a = seeds[n / NS]; b = seeds[n % NS]; }
    else             { a = dist(rng);     b = dist(rng);     }

    // Issue.
    dut->a = a; dut->b = b; dut->in_valid = 1;
    tick();
    dut->in_valid = 0;

    // Spin to completion. The bound is a safety net: a divider that never
    // asserts out_valid would otherwise hang the run rather than fail it.
    long cycles = 1;
    while (!dut->out_valid && cycles < 200) { tick(); cycles++; }
    if (!dut->out_valid) {
      printf("TIMEOUT: no out_valid after %ld cycles for %08x / %08x\n",
             cycles, a, b);
      fails++;
      break;
    }
    if (cycles > max_cycles) max_cycles = cycles;

    float    ref_f = u2f(a) / u2f(b);
    uint32_t ref   = f2u(ref_f);
    uint32_t got   = dut->result;

    if (is_denorm(a) || is_denorm(b) || is_denorm(ref) || std::isnan(ref_f)) {
      skipped++;
      continue;
    }

    checked++;
    if (got != ref) {
      if (fails < 20) {
        printf("MISMATCH a=%08x / b=%08x  ref=%08x got=%08x  (%g / %g = %g, got %g)\n",
               a, b, ref, got, u2f(a), u2f(b), ref_f, u2f(got));
      }
      fails++;
    }
  }

  printf("fp_div: checked=%ld skipped=%ld fails=%ld max_latency=%ld\n",
         checked, skipped, fails, max_cycles);
  delete dut;
  return fails ? 1 : 0;
}
