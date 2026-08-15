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
//   src/devices/cpu/mb86233/mb86233.cpp   (ea_pre_0/1, ea_post_0/1)
//   SPDX-License-Identifier: BSD-3-Clause
//   Copyright-holders: Olivier Galibert
//
// That BSD-3-Clause attribution must be retained. See THIRD-PARTY.md.
//
// Fujitsu MB86233 "TGP" — address generation
//
// Purely combinational. MAME's ea_pre_* computes the effective address and
// ea_post_* updates the index register; both are functions of the same
// instruction field, so there is no state here. The caller registers x_next.
//
// ea_pre_0 and ea_pre_1 are the same function over different registers
// (b0/x0/i0 versus b1/x1/i1), so one instance covers both and `bank` selects.
//
// THE +0x200 ADDER IS NOT AUTOMATIC. MAME's header comment calls it the
// "automatic 0x200 adder", which reads as if ea_pre_* applies it. It does not:
// ea_pre_* never mentions 0x200, and the adder is applied by individual
// instruction forms at their call sites — the `mem + 0x200` variants at
// mb86233.cpp lines 770, 785, 870 and 912, plus write_mem_internal_1's bank
// flag. It is a control input here for exactly that reason. Building it into
// the EA would corrupt every instruction form that does not ask for it.

`timescale 1ns/1ps

module mb86233_agu (
  // Instruction address field. Only the low 9 bits are ever examined:
  // [8:7] selects the mode, [6:0] is the direct offset, [6:5] sub-selects
  // within mode 3, and [4:0] is the signed post-increment.
  input  logic [8:0]  r,

  input  logic        bank,        // 0: b0/x0/i0   1: b1/x1/i1

  input  logic [15:0] b0,
  input  logic [15:0] x0,
  input  logic [15:0] i0,
  input  logic [15:0] b1,
  input  logic [15:0] x1,
  input  logic [15:0] i1,

  // vsmr is always (8 << vsm) - 1 for vsm in 0..7, i.e. one of
  // 7/15/31/63/127/255/511/1023. Passed in whole rather than as vsm so the
  // caller owns the write_reg(0x0a) decode.
  input  logic [15:0] vsmr,

  input  logic        add_0x200,
  // How the +0x200 is added. MAME does it both ways:
  //   1: u16 arithmetic, wraps at 0x10000 (write_mem_internal_1)
  //   0: u32 arithmetic, so 0xffff + 0x200 reaches 0x101ff (the mem + 0x200
  //      instruction forms)
  // Only reachable with an EA already near 0xffff, but the two disagree there
  // and the difference is architecturally visible.
  input  logic        wrap16,

  output logic [16:0] ea,
  output logic [15:0] x_next,      // value to write back to the selected X
  output logic        x0_we,
  output logic        x1_we
);

  // ------------------------------------------------------------ bank mux

  logic [15:0] b_sel, x_sel, i_sel;
  assign b_sel = bank ? b1 : b0;
  assign x_sel = bank ? x1 : x0;
  assign i_sel = bank ? i1 : i0;

  // ------------------------------------------------------------- ea_pre
  //
  // switch(r & 0x180):
  //   0x000            r & 0x7f
  //   0x080, 0x100     (r & 0x7f) + b + x
  //   0x180            switch(r & 0x60):
  //                      0x00   b + x
  //                      0x20   x
  //                      0x40   b + (x & vsmr)
  //                      0x60   x & vsmr
  //
  // ea_pre_* returns u16, so every one of these sums is modulo 2^16.

  logic [15:0] offset;
  assign offset = {9'd0, r[6:0]};

  logic [15:0] ea_pre;
  always_comb begin
    unique case (r[8:7])
      2'b00: ea_pre = offset;
      2'b01,
      2'b10: ea_pre = offset + b_sel + x_sel;
      2'b11: begin
        unique case (r[6:5])
          2'b00: ea_pre = b_sel + x_sel;
          2'b01: ea_pre = x_sel;
          2'b10: ea_pre = b_sel + (x_sel & vsmr);
          2'b11: ea_pre = x_sel & vsmr;
        endcase
      end
    endcase
  end

  // ---------------------------------------------------------- +0x200

  logic [16:0] ea_wide;
  assign ea_wide = {1'b0, ea_pre} + (add_0x200 ? 17'h00200 : 17'd0);

  always_comb begin
    if (!add_0x200)   ea = {1'b0, ea_pre};
    else if (wrap16)  ea = {1'b0, ea_wide[15:0]};   // u16 += 0x200
    else              ea = ea_wide;                 // u32 = u16 + 0x200
  end

  // ------------------------------------------------------------ ea_post
  //
  //   if(!(r & 0x100))  no update
  //   else if(!(r & 0x080))  x += i
  //   else                   x += sext(r, 5)
  //
  // The two conditions are not a nested pair: bit 8 gates the update and bit 7
  // selects the source, so mode 0x100 (bit 8 set, bit 7 clear) post-increments
  // by I while addressing as (r & 0x7f) + b + x.

  logic [15:0] step;
  // util::sext(r, 5): bit 4 is the sign, so the range is -16..+15.
  assign step = r[7] ? {{11{r[4]}}, r[4:0]} : i_sel;

  assign x_next = x_sel + step;
  assign x0_we  = r[8] & ~bank;
  assign x1_we  = r[8] &  bank;

endmodule
