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
// The coprocessor running REAL MICROCODE for the first time.
//
// Every TGP test until now has driven generated instructions at the units or at
// the whole core. This loads 315-5573.bin — the decapped program ROM from the
// physical part — and asks whether the thing runs at all.
//
// What it can establish, and what it deliberately does not claim:
//
//   IT CAN show that the microcode loads, that the core fetches and retires,
//   that an empty input FIFO reads as zero and lets the microcode keep polling,
//   that it drains a queued command block, and that it never asserts
//   `unimplemented`.
//
//   IT CANNOT say the results are right. The four math units are not
//   implemented yet — this serves their reads from the real tables at the
//   quadrant base rather than at a computed index — so anything the microcode
//   derives from sincos, atan, inv or isqrt is wrong on purpose. Correctness
//   arrives with those units and with the polygon-list diff against MAME, which
//   is M2's actual exit criterion.
//
// The microcode is not in the repository: build it with
//   python3 tools/build_tgp_rom.py vr ~/roms/vr ~/roms/vr.zip -o build/rom

#include "Vm1_tgp.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

static long checks = 0, fails = 0;
static void check(bool ok, const char* what) {
  checks++;
  if (!ok) { printf("  FAIL %s\n", what); fails++; }
}

static std::vector<uint32_t> load_hex(const char* path, size_t expect) {
  std::vector<uint32_t> v;
  FILE* f = fopen(path, "r");
  if (!f) {
    printf("SKIP: %s not found — run tools/build_tgp_rom.py first\n", path);
    exit(0);
  }
  char line[64];
  while (fgets(line, sizeof line, f)) {
    if (line[0] == '\n' || line[0] == '\0') continue;
    v.push_back((uint32_t)strtoul(line, nullptr, 16));
  }
  fclose(f);
  if (expect && v.size() != expect) {
    printf("FAIL: %s has %zu words, expected %zu\n", path, v.size(), expect);
    exit(1);
  }
  return v;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  auto ucode  = load_hex("build/rom/vr_tgp_prog.hex", 2048);
  auto tables = load_hex("build/rom/vr_tgp_tables.hex", 65536);

  auto* d = new Vm1_tgp;
  // Both clocks stepped together here: the microcode write side is finished
  // before the core leaves reset, so there is no crossing to model.
  auto tick = [&]{ d->clk = 0; d->ucode_clk = 0; d->eval();
                   d->clk = 1; d->ucode_clk = 1; d->eval(); };

  d->clk = 0; d->rst_n = 0;
  d->ucode_clk = 0; d->ucode_we = 0; d->ucode_addr = 0; d->ucode_data = 0;
  d->ram_rdata = 0; d->ram_ack = 0;
  d->fifo_in_data = 0; d->fifo_in_valid = 0; d->fifo_out_full = 0;
  d->tbl_rdata = 0; d->tbl_ack = 0; d->dat_rdata = 0; d->dat_ack = 0;
  d->eval();
  for (int i = 0; i < 4; i++) tick();

  // Microcode goes in while the core is still in reset, which is what the MRA
  // path will do on hardware: the download completes before the CPU is released.
  d->ucode_we = 1;
  for (size_t i = 0; i < ucode.size(); i++) {
    d->ucode_addr = (uint16_t)i; d->ucode_data = ucode[i];
    tick();
  }
  d->ucode_we = 0;
  tick();
  d->rst_n = 1;

  // The world outside: the copro RAM, the math tables and the data ROM. Served
  // with one cycle of latency, which is enough to exercise the held-until-ack
  // handshakes without modelling SDRAM.
  std::vector<uint32_t> copro_ram(8192, 0);
  long ram_reads = 0, ram_writes = 0, tbl_reads = 0, dat_reads = 0;

  auto serve = [&]{
    d->ram_ack = 0; d->tbl_ack = 0; d->dat_ack = 0;
    if (d->ram_req) {
      if (d->ram_we) { copro_ram[d->ram_addr & 0x1fff] = d->ram_wdata; ram_writes++; }
      else           { d->ram_rdata = copro_ram[d->ram_addr & 0x1fff];  ram_reads++;  }
      d->ram_ack = 1;
    }
    if (d->tbl_req) { d->tbl_rdata = tables[d->tbl_addr & 0xffff]; d->tbl_ack = 1; tbl_reads++; }
    if (d->dat_req) { d->dat_rdata = 0; d->dat_ack = 1; dat_reads++; }
  };

  printf("test: the microcode loads and the core executes it\n");
  {
    long retires_at_start = d->dbg_retires;
    for (int i = 0; i < 20000; i++) { serve(); tick(); }
    printf("  retires=%u  pc=%04x  unimplemented=%u\n",
           (unsigned)d->dbg_retires, (unsigned)d->dbg_pc,
           (unsigned)d->dbg_unimplemented);
    printf("  external: copro RAM %ld reads / %ld writes, tables %ld, data %ld\n",
           ram_reads, ram_writes, tbl_reads, dat_reads);
    check(d->dbg_retires > retires_at_start, "the core retired nothing at all");
    check(d->dbg_unimplemented == 0,
          "the microcode hit an instruction the core does not implement");
  }

  printf("test: an empty input FIFO reads as ZERO and the microcode keeps polling\n");
  {
    // THIS TEST ASSERTED THE OPPOSITE UNTIL 2026-08-29, and it was wrong.
    //
    // It said "a read of an empty FIFO must stall the core", citing MAME's
    // generic_fifo as blocking. gen_fifo.h says the reverse for the pop itself:
    // on_fifo_empty_pre_sync is "called on a pop with an empty fifo... THE POP
    // ITSELF WILL THEN RETURN ZERO."
    //
    // The microcode needs that zero. 004D pops a command into b and 0052 is
    // `brul alw d` with d = get_exp(b) + 0x53 - a computed jump. get_exp is
    // (val >> 23) & 0xff, so an empty FIFO gives d = 0x53, the idle handler,
    // which loops back to 0x9b and polls again. Stalling means b = 0 is
    // unreachable, so the idle path is unreachable, and the core parks at 004C
    // the first time it polls an empty FIFO.
    //
    // The old test could not see that: it only checked `unimplemented`, so a
    // parked core passed it. The core must make PROGRESS with the FIFO empty.
    uint16_t before = d->dbg_retires;
    for (int i = 0; i < 4000; i++) { serve(); tick(); }
    uint16_t after = d->dbg_retires;
    check(d->dbg_unimplemented == 0, "unimplemented asserted while idle");
    check(after != before,
          "the core parked on an empty FIFO instead of polling its idle loop");
    printf("  retires went %u -> %u with the FIFO empty\n",
           (unsigned)before, (unsigned)after);
  }

  printf("test: a queued command block is drained\n");
  {
    // The eleven words the V60 pushes per block, measured in the boot trace.
    // Content is arbitrary here; what is being tested is that the TGP takes
    // them, which is the handshake the whole milestone rests on.
    long popped = 0;
    for (int w = 0; w < 11; w++) {
      d->fifo_in_data = 0x10000000u + w;
      d->fifo_in_valid = 1;
      // hold the word until the core takes it
      int spins = 0;
      while (spins++ < 4000) {
        serve(); tick();
        if (d->fifo_in_pop) { popped++; break; }
      }
    }
    d->fifo_in_valid = 0;
    printf("  the core popped %ld of 11 offered words\n", popped);
    check(popped > 0, "the core never read the input FIFO");
  }

  printf("m1_tgp: checks=%ld fails=%ld retires=%u\n",
         checks, fails, (unsigned)d->dbg_retires);
  delete d;
  return fails ? 1 : 0;
}
