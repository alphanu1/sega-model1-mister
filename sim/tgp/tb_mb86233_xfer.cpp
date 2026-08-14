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
// mb86233_xfer directed harness.
//
// Exhaustive rather than random: the input space is is_lab x is_ldmov x
// sub_op x op7_sub, which is only 4 x 8 x 8 = 256 combinations. Fuzzing a space
// that small would be theatre; every case is enumerated instead.
//
// The expected table is written out longhand from execute_run rather than
// generated, so that a disagreement is a disagreement with MAME and not with a
// cleverer restatement of it:
//
//   third_party/mame/src/devices/cpu/mb86233/mb86233.cpp
//   BSD-3-Clause, copyright-holders: Olivier Galibert

#include "Vmb86233_xfer.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

enum { EP_NONE = 0, EP_DATA = 1, EP_IO = 2, EP_PROG = 3 };

struct Exp {
  int  src_space, dst_space;
  bool src_is_reg, dst_is_reg;
  bool src_bank, dst_bank;
  bool src_add200, dst_add200;
  bool src_use_r2, dst_use_r2;
  bool lab_two_reads;
  int  lab_b_space;
  bool lab_a_add200, lab_b_add200;
  bool unimpl;
};

static Exp expect_for(bool lab, bool ldmov, int sub, int o7) {
  Exp e = {EP_NONE, EP_NONE, false, false, false, false,
           false, false, false, false, false, EP_NONE, false, false, false};
  if (lab) {
    e.lab_two_reads = true;
    e.src_space = EP_DATA; e.src_bank = false;
    switch (sub) {
      case 0: case 1: e.lab_b_space = EP_IO; break;
      case 3: e.lab_b_space = EP_DATA; e.lab_b_add200 = true; break;
      case 4: e.lab_b_space = EP_DATA; e.lab_a_add200 = true; break;
      default: e.lab_two_reads = false; e.unimpl = true;
               e.src_space = EP_DATA; break;
    }
  } else if (ldmov) {
    switch (sub) {
      case 0: case 1:
        e.src_space = EP_DATA; e.src_bank = false;
        e.dst_space = EP_IO;   e.dst_bank = true; e.dst_use_r2 = true; break;
      case 2:
        e.src_space = EP_IO;   e.src_bank = false;
        e.dst_space = EP_DATA; e.dst_bank = true; e.dst_use_r2 = true; break;
      case 3:
        e.src_space = EP_DATA; e.src_bank = false;
        e.dst_space = EP_DATA; e.dst_bank = true; e.dst_use_r2 = true;
        e.dst_add200 = true; break;
      case 4:
        e.src_space = EP_DATA; e.src_bank = false; e.src_add200 = true;
        e.dst_space = EP_DATA; e.dst_bank = true; e.dst_use_r2 = true; break;
      case 5:
        e.src_space = EP_PROG; e.src_bank = false;
        e.dst_space = EP_DATA; e.dst_bank = true; e.dst_use_r2 = true; break;
      case 7:
        switch (o7) {
          case 0: e.src_is_reg = true; e.src_use_r2 = true;
                  e.dst_space = EP_DATA; e.dst_bank = true; break;
          case 1: e.src_is_reg = true; e.src_use_r2 = true;
                  e.dst_space = EP_IO;   e.dst_bank = true; break;
          case 2: e.src_space = EP_DATA; e.src_bank = true; e.src_add200 = true;
                  e.dst_is_reg = true; e.dst_use_r2 = true; break;
          case 3: e.src_space = EP_DATA; e.src_bank = true;
                  e.dst_is_reg = true; e.dst_use_r2 = true; break;
          case 4: e.src_space = EP_IO;   e.src_bank = true;
                  e.dst_is_reg = true; e.dst_use_r2 = true; break;
          // 7/5 uses ea_pre_0 where 7/2, 7/3 and 7/4 use ea_pre_1.
          case 5: e.src_space = EP_PROG; e.src_bank = false;
                  e.dst_is_reg = true; e.dst_use_r2 = true; break;
          case 6: e.src_is_reg = true;
                  e.dst_is_reg = true; e.dst_use_r2 = true; break;
          default: e.unimpl = true; break;
        }
        break;
      default: e.unimpl = true; break;
    }
  }
  return e;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vmb86233_xfer;

  long checked = 0, fails = 0;

  for (int lab = 0; lab < 2; lab++)
  for (int ldm = 0; ldm < 2; ldm++)
  for (int sub = 0; sub < 8; sub++)
  for (int o7 = 0; o7 < 8; o7++) {
    // is_lab and is_ldmov are decoded from distinct opcode values and can
    // never both be set; drive it anyway to prove the priority is defined.
    dut->is_lab = lab; dut->is_ldmov = ldm;
    dut->sub_op = sub; dut->op7_sub = o7;
    dut->eval();

    Exp e = (lab || ldm) ? expect_for(lab, ldm && !lab, sub, o7)
                         : expect_for(false, false, sub, o7);
    checked++;

    bool bad = false;
    #define CK(a,b) do { if ((uint32_t)(a) != (uint32_t)(b)) bad = true; } while (0)
    CK(dut->src_space, e.src_space);
    CK(dut->dst_space, e.dst_space);
    CK(dut->src_is_reg, e.src_is_reg);
    CK(dut->dst_is_reg, e.dst_is_reg);
    CK(dut->src_bank, e.src_bank);
    CK(dut->dst_bank, e.dst_bank);
    CK(dut->src_add200, e.src_add200);
    CK(dut->dst_add200, e.dst_add200);
    CK(dut->src_use_r2, e.src_use_r2);
    CK(dut->dst_use_r2, e.dst_use_r2);
    CK(dut->lab_two_reads, e.lab_two_reads);
    CK(dut->lab_b_space, e.lab_b_space);
    CK(dut->lab_a_add200, e.lab_a_add200);
    CK(dut->lab_b_add200, e.lab_b_add200);
    CK(dut->unimplemented, e.unimpl);
    #undef CK

    if (bad) {
      if (fails < 20) {
        printf("MISMATCH lab=%d ldmov=%d sub=%d op7=%d\n", lab, ldm, sub, o7);
        printf("    src ref sp%d reg%d bank%d a200%d r2%d\n",
               e.src_space, e.src_is_reg, e.src_bank, e.src_add200, e.src_use_r2);
        printf("    src got sp%d reg%d bank%d a200%d r2%d\n",
               (int)dut->src_space, (int)dut->src_is_reg, (int)dut->src_bank,
               (int)dut->src_add200, (int)dut->src_use_r2);
        printf("    dst ref sp%d reg%d bank%d a200%d r2%d   unimpl %d\n",
               e.dst_space, e.dst_is_reg, e.dst_bank, e.dst_add200,
               e.dst_use_r2, e.unimpl);
        printf("    dst got sp%d reg%d bank%d a200%d r2%d   unimpl %d\n",
               (int)dut->dst_space, (int)dut->dst_is_reg, (int)dut->dst_bank,
               (int)dut->dst_add200, (int)dut->dst_use_r2,
               (int)dut->unimplemented);
      }
      fails++;
    }
  }

  printf("mb86233_xfer: checked=%ld skipped=0 fails=%ld (exhaustive)\n",
         checked, fails);
  delete dut;
  return fails ? 1 : 0;
}
