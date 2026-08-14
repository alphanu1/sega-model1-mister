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
// mb86233_dec fuzz harness.
//
// The reference extracts fields with the same expressions MAME's execute_run
// uses, in the same order, so a disagreement points at one transcription rather
// than at "the decoder":
//
//   third_party/mame/src/devices/cpu/mb86233/mb86233.cpp
//   BSD-3-Clause, copyright-holders: Olivier Galibert
//
// Combinational DUT, so no pipeline and no latency to misalign — the trap that
// has now cost three harnesses in this repo a debugging round.
//
// No skips. Every 32-bit word is a defined input: those that decode to nothing
// must assert `unimplemented`, and that is checked too.

#include "Vmb86233_dec.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>

static int32_t sext24(uint32_t v) {
  return (int32_t)((v & 0xffffff) ^ 0x800000) - 0x800000;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vmb86233_dec;

  std::mt19937 rng(20260814u);
  std::uniform_int_distribution<uint32_t> dist(0, 0xffffffffu);

  const long N = 3000000;
  long checked = 0, fails = 0;
  long hit[7] = {0};          // lab, ldmov, stm, lipl, repgrp, ldi, branch
  long hit_unimpl = 0;
  long hit_op7[8] = {0};
  long hit_subop[8] = {0};

  for (long n = 0; n < N; n++) {
    uint32_t op;
    if (n < 64) {
      // Walk every top-level dispatch value first so no type can be missed.
      op = ((uint32_t)n << 26) | (dist(rng) & 0x03ffffff);
    } else if ((dist(rng) & 3) == 0) {
      // Bias toward the types that actually decode.
      static const uint32_t tops[] = {0x00,0x07,0x0d,0x0e,0x0f,
                                      0x10,0x17,0x1f,0x2f,0x3f};
      op = (tops[dist(rng) % 10] << 26) | (dist(rng) & 0x03ffffff);
    } else {
      op = dist(rng);
    }

    uint32_t top = (op >> 26) & 0x3f;

    bool lab    = (top == 0x00);
    bool ldmov  = (top == 0x07);
    bool stm    = (top == 0x0d);
    bool lipl   = (top == 0x0e);
    bool repgrp = (top == 0x0f);
    bool ldi    = (top >= 0x10 && top <= 0x1f);
    bool branch = (top == 0x2f || top == 0x3f);
    bool unimpl = !(lab || ldmov || stm || lipl || repgrp || ldi || branch);

    uint32_t e_r1  = op & 0x1ff;
    uint32_t e_r2  = (op >> 9) & 0x1ff;
    uint32_t e_sub = (op >> 18) & 7;
    uint32_t e_op7 = e_r2 >> 6;
    // The ALU field position differs between the transfer types and 0x0f.
    uint32_t e_alu = repgrp ? ((op >> 20) & 0x1f) : ((op >> 21) & 0x1f);

    uint32_t e_cond = (op >> 20) & 0x1f;
    uint32_t e_bsub = (op >> 17) & 7;
    uint32_t e_data = op & 0xffff;
    bool     e_inv  = (op & 0x40000000) != 0;

    uint32_t e_ldireg = (op >> 24) & 0x3f;
    uint32_t e_ldival = (uint32_t)sext24(op);

    uint32_t e_lsel   = (op >> 24) & 3;
    uint32_t e_lpimm  = op & 0xffffff;
    uint32_t e_lval   = (uint32_t)sext24(op);

    uint32_t e_fsub   = (op >> 17) & 7;
    bool     e_clra   = (op & 0x0004) != 0;
    bool     e_clrb   = (op & 0x0008) != 0;
    bool     e_clrd   = (op & 0x0010) != 0;
    bool     e_repreg = (op & 0x8000) != 0;
    uint32_t e_repimm = op & 0xff;

    uint32_t e_stmsub = (op >> 17) & 7;
    uint32_t e_stmm   = op & 0xffff;

    dut->opcode = op;
    dut->eval();

    checked++;
    if (lab) hit[0]++; if (ldmov) hit[1]++; if (stm) hit[2]++;
    if (lipl) hit[3]++; if (repgrp) hit[4]++; if (ldi) hit[5]++;
    if (branch) hit[6]++; if (unimpl) hit_unimpl++;
    if (ldmov) { hit_subop[e_sub]++; if (e_sub == 7) hit_op7[e_op7]++; }

    bool bad = false;
    #define CK(a,b) do { if ((uint32_t)(a) != (uint32_t)(b)) bad = true; } while (0)
    CK(dut->is_lab, lab);
    CK(dut->is_ldmov, ldmov);
    CK(dut->is_stm, stm);
    CK(dut->is_lipl, lipl);
    CK(dut->is_rep_grp, repgrp);
    CK(dut->is_ldi, ldi);
    CK(dut->is_branch, branch);
    CK(dut->unimplemented, unimpl);
    CK(dut->r1, e_r1);
    CK(dut->r2, e_r2);
    CK(dut->alu, e_alu);
    CK(dut->sub_op, e_sub);
    CK(dut->op7_sub, e_op7);
    CK(dut->br_cond, e_cond);
    CK(dut->br_subtype, e_bsub);
    CK(dut->br_data, e_data);
    CK(dut->br_invert, e_inv);
    CK(dut->ldi_reg, e_ldireg);
    CK(dut->ldi_val, e_ldival);
    CK(dut->lipl_sel, e_lsel);
    CK(dut->lipl_p_imm, e_lpimm);
    CK(dut->lipl_val, e_lval);
    CK(dut->f_sub, e_fsub);
    CK(dut->f_clr_a, e_clra);
    CK(dut->f_clr_b, e_clrb);
    CK(dut->f_clr_d, e_clrd);
    CK(dut->f_rep_from_reg, e_repreg);
    CK(dut->f_rep_imm, e_repimm);
    CK(dut->stm_sub, e_stmsub);
    CK(dut->stm_m, e_stmm);
    #undef CK

    if (bad) {
      if (fails < 20) {
        printf("MISMATCH n=%ld opcode=%08x top=%02x\n", n, op, top);
        printf("    type ref lab%d ldmov%d stm%d lipl%d rep%d ldi%d br%d un%d\n",
               lab, ldmov, stm, lipl, repgrp, ldi, branch, unimpl);
        printf("    type got lab%d ldmov%d stm%d lipl%d rep%d ldi%d br%d un%d\n",
               (int)dut->is_lab, (int)dut->is_ldmov, (int)dut->is_stm,
               (int)dut->is_lipl, (int)dut->is_rep_grp, (int)dut->is_ldi,
               (int)dut->is_branch, (int)dut->unimplemented);
        printf("    r1 %03x/%03x r2 %03x/%03x alu %02x/%02x sub %d/%d op7 %d/%d\n",
               e_r1, (uint32_t)dut->r1, e_r2, (uint32_t)dut->r2,
               e_alu, (uint32_t)dut->alu, e_sub, (int)dut->sub_op,
               e_op7, (int)dut->op7_sub);
        printf("    ldi %02x/%02x %08x/%08x   lipl sel %d/%d val %08x/%08x\n",
               e_ldireg, (uint32_t)dut->ldi_reg, e_ldival, (uint32_t)dut->ldi_val,
               e_lsel, (int)dut->lipl_sel, e_lval, (uint32_t)dut->lipl_val);
      }
      fails++;
    }
  }

  int uncovered = 0;
  const char* names[7] = {"lab","ldmov","stm","lipl","rep_grp","ldi","branch"};
  for (int i = 0; i < 7; i++)
    if (!hit[i]) { printf("NO COVERAGE for %s\n", names[i]); uncovered++; }
  if (!hit_unimpl) { printf("NO COVERAGE for unimplemented\n"); uncovered++; }
  for (int i = 0; i < 8; i++)
    if (!hit_subop[i]) { printf("NO COVERAGE for ld/mov sub-op %d\n", i); uncovered++; }
  for (int i = 0; i < 8; i++)
    if (!hit_op7[i]) { printf("NO COVERAGE for ld/mov 7/%d\n", i); uncovered++; }

  printf("mb86233_dec: checked=%ld skipped=0 fails=%ld uncovered=%d\n",
         checked, fails, uncovered);
  delete dut;
  return (fails || uncovered) ? 1 : 0;
}
