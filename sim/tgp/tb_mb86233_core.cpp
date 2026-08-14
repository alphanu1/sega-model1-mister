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
// mb86233_core directed harness.
//
// DIRECTED, NOT LOCKSTEP, AND THAT IS A GAP. M0 exit criterion 2 is a full
// instruction-by-instruction trace comparison against MAME across a Virtua
// Racing cold boot, and this is not that. What this does is run small programs
// through the assembled FSM and check the architectural state each instruction
// leaves behind, which is enough to catch wiring and sequencing faults — the
// class of bug that assembling ten independently-verified blocks introduces.
//
// The blocks themselves are already verified in volume; what is unproven here
// is the glue. Encoding fields are per mb86233_dec, semantics per:
//
//   third_party/mame/src/devices/cpu/mb86233/mb86233.cpp

#include "Vmb86233_core.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Vmb86233_core* dut;
static std::vector<uint32_t> prog(2048, 0);

static void tick() {
  dut->clk = 0; dut->eval();
  dut->clk = 1; dut->eval();
}

// Drive the program ROM: synchronous, data valid the cycle after addr.
static void step_cycle() {
  dut->prog_rdata = prog[dut->prog_addr & 0x7ff];
  dut->io_ack = 1;          // IO always ready in this harness
  dut->fifo_ack = 1;
  dut->io_rdata = 0xa5a5a5a5;
  dut->fifo_rdata = 0x5a5a5a5a;
  tick();
}

// Run until `n` instructions have retired, or until a cycle budget is spent.
//
// `retire` is combinational on the state register, so reading it after a tick
// observes S_RETIRE at its START — the instruction's register writes land on
// the NEXT edge. Stopping the moment the count is reached therefore samples the
// architectural state one cycle too early, and the last instruction of every
// program appears not to have executed. That reads exactly like a broken core:
// here it made ldi-to-D and lipl-to-P look dead while ldi-to-A, written three
// instructions earlier, passed.
//
// Settle one extra cycle so the final write is visible. This is the fourth
// off-by-one of this shape in this repo; see docs/rtl-conventions.md.
static bool run_instrs(int n, int settle = 8, long budget = 4000) {
  int seen = 0;
  while (seen < n && budget-- > 0) {
    step_cycle();
    if (dut->retire) seen++;
  }
  // Settle for longer than one cycle. One is enough for the retire's own write,
  // but NOT enough to expose a late writeback from elsewhere: the ALU is
  // latency-2 and free-running, so an operation wrongly launched by a
  // non-ALU instruction lands two cycles after retire. Checking at +1 cycle
  // made the ldi-clobbers-D bug invisible — mutation confirmed the harness
  // passed with the fix removed. The following instructions here are nops,
  // which write nothing, so the extra cycles cannot mask a real write.
  if (seen == n) for (int i = 0; i < settle; i++) step_cycle();
  return seen == n;
}

static void reset() {
  dut->rst_n = 0;
  dut->prog_rdata = 0; dut->io_rdata = 0; dut->io_ack = 0;
  dut->fifo_rdata = 0; dut->fifo_ack = 0; dut->gpio = 0;
  for (int i = 0; i < 8; i++) tick();
  dut->rst_n = 1;
}

// ------------------------------------------------------------- encoders
static uint32_t enc_ldi(uint32_t reg, uint32_t imm24) {
  // top 0x10-0x1f, target in bits 29:24, 24-bit immediate
  return (0x10u << 26) | ((reg & 0x3f) << 24) | (imm24 & 0xffffff);
}
static uint32_t enc_lipl(uint32_t sel, uint32_t imm24) {
  return (0x0eu << 26) | ((sel & 3) << 24) | (imm24 & 0xffffff);
}
static uint32_t enc_nop() { return (0x0fu << 26); }   // rep group, sub 0, no clears

static long fails = 0, checks = 0;
static void ck(const char* what, uint32_t got, uint32_t exp) {
  checks++;
  if (got != exp) {
    printf("  FAIL %-28s got=%08x exp=%08x\n", what, got, exp);
    fails++;
  }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vmb86233_core;

  // ---------------------------------------------------------------- ldi
  printf("test: ldi writes the register file\n");
  for (auto& w : prog) w = enc_nop();
  prog[0] = enc_ldi(0x10, 0x123456);      // A
  prog[1] = enc_ldi(0x13, 0x00abcd);      // B
  prog[2] = enc_ldi(0x19, 0xff0001);      // D, negative -> sign-extends
  reset();
  if (!run_instrs(3)) { printf("  FAIL timeout\n"); fails++; }
  ck("ldi A", dut->dbg_a, 0x00123456);
  ck("ldi B", dut->dbg_b, 0x0000abcd);
  ck("ldi D sign-extended", dut->dbg_d, 0xffff0001);

  // --------------------------------------------------------------- lipl
  printf("test: lia/lib/lid sign-extend, lipl preserves P's top byte\n");
  for (auto& w : prog) w = enc_nop();
  prog[0] = enc_ldi(0x1c, 0x000000);      // P = 0
  prog[1] = enc_lipl(1, 0x800000);        // lia, negative
  prog[2] = enc_lipl(2, 0x7fffff);        // lib, positive
  prog[3] = enc_lipl(3, 0xfffffe);        // lid, negative
  reset();
  if (!run_instrs(4)) { printf("  FAIL timeout\n"); fails++; }
  ck("lia sign-extended", dut->dbg_a, 0xff800000);
  ck("lib positive",      dut->dbg_b, 0x007fffff);
  ck("lid sign-extended", dut->dbg_d, 0xfffffffe);

  // P case: the top byte survives, the low 24 bits are replaced.
  for (auto& w : prog) w = enc_nop();
  prog[0] = enc_ldi(0x1c, 0x000000);      // clear P (ldi sign-extends 0 -> 0)
  prog[1] = enc_lipl(0, 0xabcdef);
  reset();
  if (!run_instrs(2)) { printf("  FAIL timeout\n"); fails++; }
  ck("lipl P low 24", dut->dbg_p & 0x00ffffff, 0x00abcdef);

  // Now with a non-zero top byte to prove it is preserved rather than cleared.
  for (auto& w : prog) w = enc_nop();
  prog[0] = enc_ldi(0x1c, 0xff0000);      // P = 0xffff0000 after sign-extend
  prog[1] = enc_lipl(0, 0x123456);
  reset();
  if (!run_instrs(2)) { printf("  FAIL timeout\n"); fails++; }
  ck("lipl P top byte kept", dut->dbg_p, 0xff123456);

  // ------------------------------------------------------------ retire/pc
  printf("test: PC advances one per retired instruction\n");
  for (auto& w : prog) w = enc_nop();
  reset();
  // settle=0: this measures the spacing between consecutive retires, so extra
  // settle cycles would let further instructions retire between the samples.
  if (!run_instrs(1, 0)) { printf("  FAIL timeout\n"); fails++; }
  uint32_t pc1 = dut->retire_pc;
  if (!run_instrs(1, 0)) { printf("  FAIL timeout\n"); fails++; }
  uint32_t pc2 = dut->retire_pc;
  ck("pc advanced by 1", pc2 - pc1, 1);

  // ------------------------------------------------------- no false unimpl
  printf("test: a stream of decoded instructions raises no unimplemented\n");
  for (auto& w : prog) w = enc_nop();
  prog[0] = enc_ldi(0x10, 0x000001);
  prog[1] = enc_lipl(1, 0x000002);
  reset();
  bool saw_unimpl = false;
  for (int i = 0; i < 200; i++) { step_cycle(); if (dut->unimplemented) saw_unimpl = true; }
  checks++;
  if (saw_unimpl) { printf("  FAIL unimplemented asserted on decoded stream\n"); fails++; }

  printf("mb86233_core: checks=%ld fails=%ld (directed; lockstep still owed)\n",
         checks, fails);
  delete dut;
  return fails ? 1 : 0;
}
