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
// mb86233_regs fuzz harness.
//
// Lockstep, like the sequencer: the register file is state, so a software
// model holds the same registers and both are driven by one random stream of
// reads, writes and writebacks, with every architectural output compared each
// cycle.
//
// Reference mirrors MAME read_reg/write_reg, including the register widths —
// the truncation on write is the point, not an implementation detail:
//
//   third_party/mame/src/devices/cpu/mb86233/mb86233.cpp
//   BSD-3-Clause, copyright-holders: Olivier Galibert
//
// No skips.

#include "Vmb86233_regs.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>

// The field accessors, verbatim from mb86233_pkg / MAME.
static uint32_t set_exp(uint32_t v, uint32_t e) {
  return (v & 0x807fffffu) | ((e & 0xffu) << 23);
}
static uint32_t set_mant(uint32_t v, uint32_t m) {
  // The nine-digit 0x07f800000 is just 0x7f800000 with a leading zero, not a
  // quirk — verified by mutation, zero mismatches when swapped.
  return (uint32_t)((v & 0x07f800000ull) | ((m & 0x00800000u) << 8) | (m & 0x007fffffu));
}
static uint32_t get_exp(uint32_t v) { return (v >> 23) & 0xff; }
static uint32_t get_mant(uint32_t v) {
  return (v & 0x80000000u) ? (v | 0x7f800000u) : (v & 0x807fffffu);
}

struct Model {
  uint32_t a = 0, b = 0, d = 0, p = 0;
  uint16_t b0 = 0, b1 = 0, x0 = 0, x1 = 0, i0 = 0, i1 = 0;
  uint16_t sp = 0, mask = 0, vsmr = 7;
  uint8_t  sft = 0, rpc = 1, vsm = 0;
  uint32_t rf[16] = {0};
};

static bool in_rf(uint32_t r) { return r >= 0x20 && r < 0x30; }

static uint32_t read_reg(const Model& m, uint32_t r, uint8_t c0, uint8_t c1,
                         bool* unimpl) {
  *unimpl = false;
  if (in_rf(r)) return m.rf[r & 0x0f];
  switch (r) {
    case 0x00: return m.b0;
    case 0x01: return m.b1;
    case 0x02: return m.x0;
    case 0x03: return m.x1;
    case 0x0c: return c0;
    case 0x0d: return c1;
    case 0x10: return m.a;
    case 0x11: return get_exp(m.a);
    case 0x12: return get_mant(m.a);
    case 0x13: return m.b;
    case 0x14: return get_exp(m.b);
    case 0x15: return get_mant(m.b);
    case 0x19: return m.d;
    case 0x1a: return get_exp(m.d);
    case 0x1b: return get_mant(m.d);
    case 0x1c: return m.p;
    case 0x1d: return get_exp(m.p);
    case 0x1e: return get_mant(m.p);
    case 0x1f: return m.sft;
    case 0x34: return m.rpc;
    default: *unimpl = true; return 0;
  }
}

static void write_reg(Model& m, uint32_t r, uint32_t v, bool* unimpl) {
  *unimpl = false;
  if (in_rf(r)) { m.rf[r & 0x0f] = v; return; }
  switch (r) {
    case 0x00: m.b0 = (uint16_t)v; break;
    case 0x01: m.b1 = (uint16_t)v; break;
    case 0x02: m.x0 = (uint16_t)v; break;
    case 0x03: m.x1 = (uint16_t)v; break;
    case 0x05: m.i0 = (uint16_t)v; break;
    case 0x06: m.i1 = (uint16_t)v; break;
    case 0x08: m.sp = (uint16_t)v; break;
    case 0x0a: m.vsm = v & 7; m.vsmr = (uint16_t)((8u << m.vsm) - 1u); break;
    case 0x0c: case 0x0d: break;      // forwarded to the sequencer
    case 0x0f: break;                 // explicit no-op in MAME
    case 0x10: m.a = v; break;
    case 0x11: m.a = set_exp(m.a, v); break;
    case 0x12: m.a = set_mant(m.a, v); break;
    case 0x13: m.b = v; break;
    case 0x14: m.b = set_exp(m.b, v); break;
    case 0x15: m.b = set_mant(m.b, v); break;
    case 0x19: m.d = v; break;
    case 0x1a: m.d = set_exp(m.d, v); break;
    case 0x1b: m.d = set_mant(m.d, v); break;
    case 0x1c: m.p = v; break;
    case 0x1d: m.p = set_exp(m.p, v); break;
    case 0x1e: m.p = set_mant(m.p, v); break;
    case 0x1f: m.sft = (uint8_t)v; break;
    case 0x34: m.rpc = (uint8_t)v; break;
    case 0x3c: m.mask = (uint16_t)v; break;
    default: *unimpl = true; break;
  }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vmb86233_regs;

  auto tick = [&]() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
  };

  dut->rst_n = 0;
  dut->rd_addr = 0; dut->wr_en = 0; dut->wr_addr = 0; dut->wr_data = 0;
  dut->alu_d_we = 0; dut->alu_d = 0; dut->alu_p_we = 0; dut->alu_p = 0;
  dut->agu_x0_we = 0; dut->agu_x0 = 0; dut->agu_x1_we = 0; dut->agu_x1 = 0;
  dut->c0 = 1; dut->c1 = 1;
  dut->clr_a = 0; dut->clr_b = 0; dut->clr_d = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1;

  Model m;
  std::mt19937 rng(20260814u);
  std::uniform_int_distribution<uint32_t> dist(0, 0xffffffffu);

  const long N = 3000000;
  long checked = 0, fails = 0;
  long addr_hits[64] = {0};

  for (long n = 0; n < N; n++) {
    // Walk every address exhaustively before going random, so no register can
    // escape coverage by luck.
    uint32_t wa = (n < 64) ? (uint32_t)n : (dist(rng) & 0x3f);
    uint32_t ra = (n < 128 && n >= 64) ? (uint32_t)(n - 64) : (dist(rng) & 0x3f);
    uint32_t wd = dist(rng);
    bool     we = (dist(rng) & 3) != 0;          // 75% writes

    // Writebacks, rarer, so ordinary writes are not always masked by them.
    bool     dwe = (dist(rng) & 7) == 0;
    bool     pwe = (dist(rng) & 7) == 0;
    bool     x0we = (dist(rng) & 7) == 0;
    bool     x1we = (dist(rng) & 7) == 0;
    uint32_t dv = dist(rng), pv = dist(rng);
    uint16_t x0v = (uint16_t)dist(rng), x1v = (uint16_t)dist(rng);
    uint8_t  c0v = (uint8_t)dist(rng), c1v = (uint8_t)dist(rng);

    dut->rd_addr = ra;
    dut->wr_en = we; dut->wr_addr = wa; dut->wr_data = wd;
    dut->alu_d_we = dwe; dut->alu_d = dv;
    dut->alu_p_we = pwe; dut->alu_p = pv;
    dut->agu_x0_we = x0we; dut->agu_x0 = x0v;
    dut->agu_x1_we = x1we; dut->agu_x1 = x1v;
    dut->c0 = c0v; dut->c1 = c1v;
    dut->eval();

    // Combinational read is checked against the state BEFORE this cycle's
    // writes land, matching MAME where read_reg happens before write_reg.
    bool ref_rd_unimpl = false;
    uint32_t ref_rd = read_reg(m, ra, c0v, c1v, &ref_rd_unimpl);

    bool ref_wr_unimpl = false;
    bool ref_c0_we = we && wa == 0x0c;
    bool ref_c1_we = we && wa == 0x0d;

    bool bad = false;
    if (dut->rd_data != ref_rd)                     bad = true;
    if ((bool)dut->rd_unimpl != ref_rd_unimpl)      bad = true;
    if ((bool)dut->c0_we != ref_c0_we)              bad = true;
    if ((bool)dut->c1_we != ref_c1_we)              bad = true;

    if (bad) {
      if (fails < 20) {
        printf("MISMATCH n=%ld rd=%02x wr=%02x we=%d wd=%08x\n", n, ra, wa, we, wd);
        printf("    rd:  ref=%08x got=%08x   unimpl ref=%d got=%d\n",
               ref_rd, dut->rd_data, ref_rd_unimpl, (int)dut->rd_unimpl);
        printf("    c_we: ref %d/%d got %d/%d\n",
               ref_c0_we, ref_c1_we, (int)dut->c0_we, (int)dut->c1_we);
      }
      fails++;
    }

    // Advance both.
    if (we) write_reg(m, wa, wd, &ref_wr_unimpl);
    if (dwe) m.d = dv;
    if (pwe) m.p = pv;
    if (x0we) m.x0 = x0v;
    if (x1we) m.x1 = x1v;
    tick();

    checked++;
    addr_hits[wa]++;

    // Architectural outputs compared after the edge.
    bool bad2 = false;
    if (dut->reg_a != m.a) bad2 = true;
    if (dut->reg_b != m.b) bad2 = true;
    if (dut->reg_d != m.d) bad2 = true;
    if (dut->reg_p != m.p) bad2 = true;
    if (dut->b0 != m.b0)   bad2 = true;
    if (dut->b1 != m.b1)   bad2 = true;
    if (dut->x0 != m.x0)   bad2 = true;
    if (dut->x1 != m.x1)   bad2 = true;
    if (dut->i0 != m.i0)   bad2 = true;
    if (dut->i1 != m.i1)   bad2 = true;
    if (dut->vsmr != m.vsmr) bad2 = true;
    if (dut->sft != m.sft) bad2 = true;
    if (dut->mask != m.mask) bad2 = true;

    if (bad2) {
      if (fails < 20) {
        printf("STATE MISMATCH n=%ld after wr=%02x we=%d wd=%08x "
               "(dwe=%d pwe=%d x0we=%d x1we=%d)\n",
               n, wa, we, wd, dwe, pwe, x0we, x1we);
        printf("    a ref=%08x got=%08x   b ref=%08x got=%08x\n",
               m.a, dut->reg_a, m.b, dut->reg_b);
        printf("    d ref=%08x got=%08x   p ref=%08x got=%08x\n",
               m.d, dut->reg_d, m.p, dut->reg_p);
        printf("    b0 %04x/%04x b1 %04x/%04x x0 %04x/%04x x1 %04x/%04x\n",
               m.b0, dut->b0, m.b1, dut->b1, m.x0, dut->x0, m.x1, dut->x1);
        printf("    i0 %04x/%04x i1 %04x/%04x vsmr %04x/%04x sft %02x/%02x\n",
               m.i0, dut->i0, m.i1, dut->i1, m.vsmr, dut->vsmr, m.sft, dut->sft);
      }
      fails++;
      m.a = dut->reg_a; m.b = dut->reg_b; m.d = dut->reg_d; m.p = dut->reg_p;
      m.b0 = dut->b0; m.b1 = dut->b1; m.x0 = dut->x0; m.x1 = dut->x1;
      m.i0 = dut->i0; m.i1 = dut->i1; m.vsmr = dut->vsmr;
      m.sft = dut->sft; m.mask = dut->mask;
    }
  }

  int uncovered = 0;
  for (int i = 0; i < 64; i++)
    if (addr_hits[i] == 0) { printf("NO COVERAGE for reg %02x\n", i); uncovered++; }

  printf("mb86233_regs: checked=%ld skipped=0 fails=%ld uncovered_regs=%d\n",
         checked, fails, uncovered);
  delete dut;
  return (fails || uncovered) ? 1 : 0;
}
