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
// mb86233_seq fuzz harness.
//
// The sequencer is stateful, so this is a lockstep comparison rather than a
// per-operation one: a software model holds the same architectural state and
// both are stepped by the same random instruction stream, with every visible
// register compared after each retire. A divergence that only shows up after
// a specific sequence of branches would be invisible to a stateless harness.
//
// Reference mirrors MAME execute_run's control flow, including the order of
// the repeat override against the branch:
//
//   third_party/mame/src/devices/cpu/mb86233/mb86233.cpp
//   BSD-3-Clause, copyright-holders: Olivier Galibert
//
// No skips. Undecoded conditions and subtypes are defined behaviour (they log
// and fall through) and are driven deliberately.

#include "Vmb86233_seq.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>

enum { F_ZRD_BIT = 1, F_SGD_BIT = 3 };

struct Model {
  uint16_t pc = 0;
  uint16_t pcs[4] = {0, 0, 0, 0};
  uint8_t  c0 = 1, c1 = 1, rep = 1;
  bool     zc0 = true, zc1 = true;
};

struct Instr {
  bool     is_branch, invert, is_rep, stall;
  uint8_t  cond, subtype;
  uint16_t data, branch_val;
  uint8_t  rep_count;
  uint8_t  gpio;
  uint32_t st;
  bool     c0_we, c1_we;
  uint8_t  c0_wd, c1_wd;
};

// One retire. Mirrors execute_run for the branch opcode plus the trailing
// repeat/stall handling.
static void step(Model& m, const Instr& in) {
  uint16_t ppc    = m.pc;
  uint16_t seq_pc = (uint16_t)(m.pc + 1);
  uint16_t pc_exec = seq_pc;
  bool push = false, pop = false;

  bool cond_raw = false;
  if (in.is_branch) {
    switch (in.cond) {
      case 0x00: cond_raw = (in.st >> F_ZRD_BIT) & 1; break;
      case 0x01: cond_raw = !((in.st >> F_SGD_BIT) & 1); break;
      case 0x02: cond_raw = ((in.st >> F_ZRD_BIT) & 1) ||
                            ((in.st >> F_SGD_BIT) & 1); break;
      case 0x0a: cond_raw = (in.gpio >> 0) & 1; break;
      case 0x0b: cond_raw = (in.gpio >> 1) & 1; break;
      case 0x0c: cond_raw = (in.gpio >> 2) & 1; break;
      case 0x10: cond_raw = !m.zc0; break;
      case 0x11: cond_raw = !m.zc1; break;
      case 0x12: cond_raw = (in.gpio >> 3) & 1; break;
      case 0x16: cond_raw = true; break;
      default:   cond_raw = false; break;   // logs, stays false
    }
  }
  // The invert is applied after the switch, so an undecoded condition with
  // the invert bit set still branches.
  bool passed = in.invert ? !cond_raw : cond_raw;

  if (in.is_branch && passed) {
    switch (in.subtype) {
      case 0: pc_exec = in.data; break;
      case 1: pc_exec = in.branch_val; break;
      case 2: pc_exec = in.data;       push = true; break;
      case 3: pc_exec = in.branch_val; push = true; break;
      case 5: pc_exec = m.pcs[0];      pop  = true; break;
      case 6: break;                        // ldif: no PC change
      default: break;                       // logs
    }
  }

  if (!in.stall) {
    if (push) {
      m.pcs[3] = m.pcs[2];
      m.pcs[2] = m.pcs[1];
      m.pcs[1] = m.pcs[0];
      m.pcs[0] = seq_pc;
    } else if (pop) {
      // Only indices 0..2 are written; pcs[3] keeps its old value.
      m.pcs[0] = m.pcs[1];
      m.pcs[1] = m.pcs[2];
      m.pcs[2] = m.pcs[3];
    }
  }

  // Loop counters: outside the cond_passed block, subtype < 2 only, skipped
  // on a stall because the goto leaves before this point.
  if (in.is_branch && !in.stall && in.subtype < 2) {
    if (in.cond == 0x10 && m.c0 != 1) {
      m.c0--;
      if (m.c0 == 1) m.zc0 = true;
    }
    if (in.cond == 0x11 && m.c1 != 1) {
      m.c1--;
      if (m.c1 == 1) m.zc1 = true;
    }
  }

  if (in.stall) {
    m.pc = ppc;                       // do_stall, skips the repeat override
  } else if (in.is_rep) {
    m.pc  = pc_exec;                  // goto rep_start, also skips it
    m.rep = in.rep_count;
  } else if (m.rep != 1) {
    m.pc = ppc;                       // discards a taken branch
    m.rep--;
  } else {
    m.pc = pc_exec;
  }

  // write_reg last: it sets the flag both ways where the decrement can only
  // set it.
  if (in.c0_we) { m.c0 = in.c0_wd; m.zc0 = (in.c0_wd == 1); }
  if (in.c1_we) { m.c1 = in.c1_wd; m.zc1 = (in.c1_wd == 1); }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vmb86233_seq;

  auto tick = [&]() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
  };

  dut->rst_n = 0; dut->in_valid = 0;
  dut->is_branch = 0; dut->cond = 0; dut->subtype = 0; dut->data = 0;
  dut->invert = 0; dut->branch_val = 0; dut->is_rep = 0; dut->rep_count = 0;
  dut->stall = 0; dut->gpio = 0; dut->st_in = 0;
  dut->c0_we = 0; dut->c0_wd = 0; dut->c1_we = 0; dut->c1_wd = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1;

  Model m;

  std::mt19937 rng(20260814u);
  std::uniform_int_distribution<uint32_t> dist(0, 0xffffffffu);

  const long N = 3000000;
  long checked = 0, fails = 0;
  long cond_hits[32] = {0}, sub_hits[8] = {0};
  long push_n = 0, pop_n = 0, rep_n = 0, stall_n = 0, dec_n = 0;

  // Conditions the hardware actually decodes, drawn more often than the
  // undecoded ones so the interesting paths dominate.
  static const uint8_t KNOWN[] = {0x00,0x01,0x02,0x0a,0x0b,0x0c,0x10,0x11,0x12,0x16};

  for (long n = 0; n < N; n++) {
    Instr in;
    uint32_t rr = dist(rng);

    in.is_branch = (rr & 3) != 0;          // 75% branches
    in.is_rep    = !in.is_branch && ((rr >> 2) & 7) == 0;
    in.stall     = ((rr >> 5) & 15) == 0;  // ~6%
    in.invert    = (rr >> 9) & 1;

    // Mostly real conditions, sometimes an undecoded one.
    if (((rr >> 10) & 7) == 0) in.cond = (uint8_t)(dist(rng) & 0x1f);
    else                       in.cond = KNOWN[dist(rng) % 10];

    // Favour the loop-counter conditions with subtype < 2 so the decrement
    // path is exercised heavily rather than incidentally.
    if (((rr >> 13) & 3) == 0) {
      in.cond    = (dist(rng) & 1) ? 0x10 : 0x11;
      in.subtype = (uint8_t)(dist(rng) & 1);
    } else {
      in.subtype = (uint8_t)(dist(rng) & 7);
    }

    in.data       = (uint16_t)dist(rng);
    in.branch_val = (uint16_t)dist(rng);
    in.rep_count  = (uint8_t)(dist(rng) & 7);   // small, so repeats end
    in.gpio       = (uint8_t)(dist(rng) & 15);
    in.st         = dist(rng);

    // Occasional explicit counter writes, biased to small values so the
    // decrement actually reaches 1 and latches the flag.
    in.c0_we = ((dist(rng) & 31) == 0);
    in.c1_we = ((dist(rng) & 31) == 0);
    in.c0_wd = (uint8_t)(dist(rng) & 7);
    in.c1_wd = (uint8_t)(dist(rng) & 7);

    dut->in_valid   = 1;
    dut->is_branch  = in.is_branch;
    dut->cond       = in.cond;
    dut->subtype    = in.subtype;
    dut->data       = in.data;
    dut->invert     = in.invert;
    dut->branch_val = in.branch_val;
    dut->is_rep     = in.is_rep;
    dut->rep_count  = in.rep_count;
    dut->stall      = in.stall;
    dut->gpio       = in.gpio;
    dut->st_in      = in.st;
    dut->c0_we      = in.c0_we;
    dut->c0_wd      = in.c0_wd;
    dut->c1_we      = in.c1_we;
    dut->c1_wd      = in.c1_wd;

    uint8_t c0_before = m.c0, c1_before = m.c1;
    step(m, in);
    tick();

    checked++;
    cond_hits[in.cond & 31]++;
    if (in.is_branch) sub_hits[in.subtype]++;
    if (in.is_rep) rep_n++;
    if (in.stall) stall_n++;
    if (in.is_branch && !in.stall && in.subtype == 2) push_n++;
    if (in.is_branch && !in.stall && in.subtype == 5) pop_n++;
    if (m.c0 != c0_before || m.c1 != c1_before) dec_n++;

    bool bad = false;
    if (dut->pc  != m.pc)  bad = true;
    if (dut->c0  != m.c0)  bad = true;
    if (dut->c1  != m.c1)  bad = true;
    if (dut->rep != m.rep) bad = true;
    if ((bool)dut->zc0 != m.zc0) bad = true;
    if ((bool)dut->zc1 != m.zc1) bad = true;

    if (bad) {
      if (fails < 20) {
        printf("MISMATCH n=%ld br=%d cond=%02x sub=%d inv=%d rep=%d stall=%d "
               "data=%04x bval=%04x\n",
               n, in.is_branch, in.cond, in.subtype, in.invert, in.is_rep,
               in.stall, in.data, in.branch_val);
        printf("    pc:  ref=%04x got=%04x\n", m.pc, dut->pc);
        printf("    c0:  ref=%02x got=%02x   c1: ref=%02x got=%02x\n",
               m.c0, dut->c0, m.c1, dut->c1);
        printf("    rep: ref=%02x got=%02x   zc0: ref=%d got=%d  zc1: ref=%d got=%d\n",
               m.rep, dut->rep, m.zc0, (int)dut->zc0, m.zc1, (int)dut->zc1);
      }
      fails++;
      // Resynchronise so one divergence does not cascade into millions.
      m.pc = dut->pc; m.c0 = dut->c0; m.c1 = dut->c1; m.rep = dut->rep;
      m.zc0 = dut->zc0; m.zc1 = dut->zc1;
    }
  }

  // Coverage. The PC stack is internal, so push/pop counts stand in for it.
  int uncovered = 0;
  for (unsigned i = 0; i < sizeof(KNOWN); i++)
    if (cond_hits[KNOWN[i]] == 0) {
      printf("NO COVERAGE for condition %02x\n", KNOWN[i]); uncovered++;
    }
  static const int SUBS[] = {0, 1, 2, 3, 5, 6};
  for (int i = 0; i < 6; i++)
    if (sub_hits[SUBS[i]] == 0) {
      printf("NO COVERAGE for subtype %d\n", SUBS[i]); uncovered++;
    }
  if (!push_n)  { printf("NO COVERAGE for pcs_push\n");     uncovered++; }
  if (!pop_n)   { printf("NO COVERAGE for pcs_pop\n");      uncovered++; }
  if (!rep_n)   { printf("NO COVERAGE for rep\n");          uncovered++; }
  if (!stall_n) { printf("NO COVERAGE for stall\n");        uncovered++; }
  if (!dec_n)   { printf("NO COVERAGE for loop decrement\n"); uncovered++; }

  printf("mb86233_seq: checked=%ld skipped=0 fails=%ld uncovered=%d\n",
         checked, fails, uncovered);
  delete dut;
  return (fails || uncovered) ? 1 : 0;
}
