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
// Behaviour transcribed from MAME's MB86233 device model:
//
//   src/devices/cpu/mb86233/mb86233.cpp   (execute_run dispatch)
//   SPDX-License-Identifier: BSD-3-Clause
//   Copyright-holders: Olivier Galibert
//
// That BSD-3-Clause attribution must be retained. See THIRD-PARTY.md.
//
// Fujitsu MB86233 "TGP" — instruction decoder
//
// Purely combinational: 32-bit opcode in, control fields out. Everything here
// is field extraction and a dispatch tree, which is exactly what execute_run's
// `switch((opcode >> 26) & 0x3f)` is.
//
// The encoding exists nowhere but MAME. mb86233d.cpp gives the field layout and
// mb86233.cpp gives the semantics; there is no datasheet with opcode encodings.
//
// Six instruction types decode, and the rest do not:
//
//   0x00        lab        load A and B from two memory sides
//   0x07        ld / mov   transfers, 8 sub-ops, one of which sub-decodes again
//   0x0d        stm / clm  only sub-op 5 (stmh) is implemented in MAME
//   0x0e        lipl/lia/lib/lid   24-bit immediate into P/A/B/D
//   0x0f        rep/clr0/clr1/set
//   0x10-0x1f   ldi        24-bit signed immediate to a register
//   0x2f, 0x3f  branches   handled by mb86233_seq, fields extracted here
//
// NOTE the two different ALU field positions. Types 0x00 and 0x07 take the ALU
// op from bits 25:21; type 0x0f takes it from bits 24:20. MAME has
// `(opcode >> 21) & 0x1f` in the first two and `(opcode >> 20) & 0x1f` in the
// third. Using one position for all three silently mis-executes every rep.

`timescale 1ns/1ps

module mb86233_dec (
  input  logic [31:0] opcode,

  // ------------------------------------------------------------ dispatch
  output logic        is_lab,        // 0x00
  output logic        is_ldmov,      // 0x07
  output logic        is_stm,        // 0x0d
  output logic        is_lipl,       // 0x0e
  output logic        is_rep_grp,    // 0x0f
  output logic        is_ldi,        // 0x10-0x1f
  output logic        is_branch,     // 0x2f / 0x3f
  output logic        unimplemented, // no dispatch case at all

  // -------------------------------------------------- shared transfer fields
  output logic [8:0]  r1,
  output logic [8:0]  r2,
  output logic [4:0]  alu,
  output logic [2:0]  sub_op,        // (opcode >> 18) & 7  for 0x00 / 0x07
  output logic [2:0]  op7_sub,       // r2 >> 6, only when 0x07 sub_op == 7

  // --------------------------------------------------------------- branches
  output logic [4:0]  br_cond,
  output logic [2:0]  br_subtype,
  output logic [15:0] br_data,
  output logic        br_invert,

  // -------------------------------------------------------------------- ldi
  output logic [5:0]  ldi_reg,
  output logic [31:0] ldi_val,

  // ------------------------------------------------- lipl / lia / lib / lid
  output logic [1:0]  lipl_sel,      // 0 P, 1 A, 2 B, 3 D
  output logic [31:0] lipl_val,      // sext24 for A/B/D; P uses the raw 24 bits
  output logic [23:0] lipl_p_imm,

  // --------------------------------------------------------------- 0x0f grp
  output logic [2:0]  f_sub,         // (opcode >> 17) & 7
  output logic        f_clr_a,
  output logic        f_clr_b,
  output logic        f_clr_d,
  output logic        f_rep_from_reg,
  output logic [7:0]  f_rep_imm,

  // --------------------------------------------------------------- 0x0d stm
  output logic [2:0]  stm_sub,
  output logic [15:0] stm_m
);

  logic [5:0] top;
  assign top = opcode[31:26];

  assign is_lab     = (top == 6'h00);
  assign is_ldmov   = (top == 6'h07);
  assign is_stm     = (top == 6'h0d);
  assign is_lipl    = (top == 6'h0e);
  assign is_rep_grp = (top == 6'h0f);
  assign is_ldi     = (top >= 6'h10) && (top <= 6'h1f);
  assign is_branch  = (top == 6'h2f) || (top == 6'h3f);

  assign unimplemented = !(is_lab | is_ldmov | is_stm | is_lipl
                         | is_rep_grp | is_ldi | is_branch);

  // ------------------------------------------------------ transfer fields

  assign r1     = opcode[8:0];
  assign r2     = opcode[17:9];
  assign sub_op = opcode[20:18];

  // r2 >> 6 selects among the seven forms of ld/mov sub-op 7. r2 is 9 bits, so
  // this is r2[8:6].
  assign op7_sub = r2[8:6];

  // The ALU field moves. 0x00 and 0x07 use 25:21; 0x0f uses 24:20. See the
  // header note — this is the single easiest thing to get wrong here.
  always_comb begin
    if (is_rep_grp) alu = opcode[24:20];
    else            alu = opcode[25:21];
  end

  // ---------------------------------------------------------------- branch

  assign br_cond    = opcode[24:20];
  assign br_subtype = opcode[19:17];
  assign br_data    = opcode[15:0];
  // bit 30 is what separates 0x2f from 0x3f, and MAME reads it directly as
  // `opcode & 0x40000000` rather than deriving it from the dispatch value.
  assign br_invert  = opcode[30];

  // ------------------------------------------------------------------- ldi
  //
  // write_reg(opcode >> 24, util::sext(opcode, 24)). write_reg masks to 6 bits,
  // so the target is opcode[29:24] — for top in 0x10-0x1f that spans the whole
  // 0x00-0x3f register space.

  assign ldi_reg = opcode[29:24];
  assign ldi_val = {{8{opcode[23]}}, opcode[23:0]};

  // ------------------------------------------- lipl / lia / lib / lid (0x0e)
  //
  // Case 0 is not a sign-extend and not a whole-register write:
  //   m_p = (m_p & 0xffffff000000) | (opcode & 0xffffff)
  // m_p is a u32, so that 48-bit mask truncates to 0xff000000 — the top byte of
  // P is preserved and the low 24 bits are replaced. Cases 1-3 sign-extend.

  assign lipl_sel   = opcode[25:24];
  assign lipl_p_imm = opcode[23:0];
  assign lipl_val   = {{8{opcode[23]}}, opcode[23:0]};

  // ----------------------------------------------------------- 0x0f group

  assign f_sub = opcode[19:17];

  // clr0 clears whichever of A/B/D the low bits select.
  assign f_clr_a = opcode[2];
  assign f_clr_b = opcode[3];
  assign f_clr_d = opcode[4];

  // rep takes its count from a register when bit 15 is set, else the immediate.
  // MAME assigns to a u8 either way, so only the low 8 bits survive.
  assign f_rep_from_reg = opcode[15];
  assign f_rep_imm      = opcode[7:0];

  // ------------------------------------------------------------- 0x0d stm

  assign stm_sub = opcode[19:17];
  // stmh takes the whole opcode into m_m, which is a u16: bit 0 selects
  // floating point and bits 2:1 are the cfxd rounding mode.
  assign stm_m   = opcode[15:0];

endmodule
