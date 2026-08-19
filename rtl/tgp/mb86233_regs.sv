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
//   src/devices/cpu/mb86233/mb86233.cpp   (read_reg / write_reg)
//   SPDX-License-Identifier: BSD-3-Clause
//   Copyright-holders: Olivier Galibert
//
// That BSD-3-Clause attribution must be retained. See THIRD-PARTY.md.
//
// Fujitsu MB86233 "TGP" — register file
//
// The 0x00-0x3f register space that read_reg/write_reg address, plus the
// 16-entry general register file that occupies 0x20-0x2f within it.
//
// NOT OWNED HERE, deliberately:
//   pc, pcs[], c0, c1, rep   mb86233_seq owns these. Writes to c0/c1 (0x0c and
//                            0x0d) are forwarded as strobes, because setting
//                            them also sets or clears the ZC flags and the
//                            sequencer owns those.
//   x0, x1                   written here AND post-incremented by the AGU, so
//                            the AGU's writeback takes priority (see below).
//   d, p                     written here AND by the ALU. The ALU already
//                            resolves that arbitration internally via its
//                            xfer_d_valid port, so its result wins.
//
// ONE ASYMMETRY THAT LOOKS LIKE A BUG AND IS NOT
//
// get_mant sign-extends through the exponent field while set_mant does not.
// Real, and load-bearing: dropping it costs 93765 mismatches in this module's
// fuzz run.
//
// The repo previously documented a SECOND quirk here, that set_mant's
// 0x07f800000 mask "evaluates as written" differently from its intent. It does
// not — the extra hex digit is a leading zero and the mask is 0x7f800000
// either way. Verified by mutation: zero mismatches over 3,000,000 cases.
//
// Most of these registers are narrower than the 32-bit value written to them:
// b0/b1/x0/x1/i0/i1/sp/mask are u16 and c0/c1/sft/rpc/vsm are u8. Writing
// 0xffffffff to b0 and reading it back yields 0x0000ffff. That truncation is
// architecturally visible and is modelled rather than widened.

`timescale 1ns/1ps

module mb86233_regs (
  input  logic        clk,
  input  logic        rst_n,

  // read_reg — combinational, as MAME's is
  input  logic [5:0]  rd_addr,
  output logic [31:0] rd_data,
  output logic        rd_unimpl,     // hit read_reg's logging default

  // write_reg
  input  logic        wr_en,
  input  logic [5:0]  wr_addr,
  input  logic [31:0] wr_data,
  output logic        wr_unimpl,     // hit write_reg's logging default

  // ALU writeback. Wins over a write_reg to the same register: the ALU has
  // already applied the transfers-beat-integer / FP-beats-transfers rule.
  input  logic        alu_d_we,
  input  logic [31:0] alu_d,
  input  logic        alu_p_we,
  input  logic [31:0] alu_p,

  // clr0 (opcode 0x0f sub-op 0) clears any combination of A, B and D in one
  // instruction, so it cannot go through the single write port.
  input  logic        clr_a,
  input  logic        clr_b,
  input  logic        clr_d,

  // AGU post-increment writeback for the index registers.
  input  logic        agu_x0_we,
  input  logic [15:0] agu_x0,
  input  logic        agu_x1_we,
  input  logic [15:0] agu_x1,

  // Forwarded to mb86233_seq, which owns c0/c1 and the ZC flags.
  output logic        c0_we,
  output logic [7:0]  c0_wd,
  output logic        c1_we,
  output logic [7:0]  c1_wd,
  input  logic [7:0]  c0,            // read back for read_reg 0x0c
  input  logic [7:0]  c1,            // read back for read_reg 0x0d

  // Architectural state consumed by the other blocks.
  output logic [31:0] reg_a,
  output logic [31:0] reg_b,
  output logic [31:0] reg_d,
  output logic [31:0] reg_p,
  output logic [15:0] b0,
  output logic [15:0] b1,
  output logic [15:0] x0,
  output logic [15:0] x1,
  output logic [15:0] i0,
  output logic [15:0] i1,
  output logic [15:0] vsmr,
  output logic [7:0]  sft,
  output logic [15:0] mask
);

  logic [15:0] sp;
  logic [7:0]  rpc;
  logic [2:0]  vsm;
  logic [31:0] rf [0:15];            // 0x20-0x2f, indexed by addr[3:0]

  // POWER-ON CONTENTS ARE ZERO. Sixteen 32-bit registers are flip-flops on the
  // device and come up cleared; MAME's RF space is zero-filled RAM. Verilator
  // brings an uninitialised unpacked array up as ONES, so a register read before
  // its first write returns 0xffffffff here and 0 everywhere else.
  //
  // mb86233_mem.sv already carries this fix and says it was found by lockstep,
  // where it "looked exactly like a transfer bug for several rounds of narrowing".
  // It then happened again in m1_copro_if, and again here: the TGP wrote
  // 0xffffffff into coprocessor RAM word 0, and the V60 waits at FED5A4 for that
  // word's low byte to read zero — 1,120,224 spins and counting.
  //
  // NOT a reset: this is small enough to be flops either way, but the file's other
  // arrays follow the same pattern and a reset on a wider one would cost RAM
  // inference. An `initial` is what Quartus uses, and it must NOT be wrapped in a
  // synthesis-pragma comment — the linter honours those and would skip it.
  integer zr;
  initial for (zr = 0; zr < 16; zr = zr + 1) rf[zr] = 32'd0;

  // --------------------------------------------------------------- read
  //
  // r >= 0x20 && r < 0x30 selects the general file. Note the index is
  // (r & 0x1f), so 0x20-0x2f maps to 0-15 and the upper half of the 32-entry
  // rf address space is unreachable this way.

  logic in_rf;
  assign in_rf = (rd_addr >= 6'h20) && (rd_addr < 6'h30);

  always_comb begin
    rd_unimpl = 1'b0;
    if (in_rf) begin
      rd_data = rf[rd_addr[3:0]];
    end else begin
      unique case (rd_addr)
        6'h00: rd_data = {16'd0, b0};
        6'h01: rd_data = {16'd0, b1};
        6'h02: rd_data = {16'd0, x0};
        6'h03: rd_data = {16'd0, x1};
        6'h0c: rd_data = {24'd0, c0};
        6'h0d: rd_data = {24'd0, c1};
        6'h10: rd_data = reg_a;
        6'h11: rd_data = mb86233_pkg::get_exp(reg_a);
        6'h12: rd_data = mb86233_pkg::get_mant(reg_a);
        6'h13: rd_data = reg_b;
        6'h14: rd_data = mb86233_pkg::get_exp(reg_b);
        6'h15: rd_data = mb86233_pkg::get_mant(reg_b);
        6'h19: rd_data = reg_d;
        6'h1a: rd_data = mb86233_pkg::get_exp(reg_d);
        6'h1b: rd_data = mb86233_pkg::get_mant(reg_d);
        6'h1c: rd_data = reg_p;
        6'h1d: rd_data = mb86233_pkg::get_exp(reg_p);
        6'h1e: rd_data = mb86233_pkg::get_mant(reg_p);
        6'h1f: rd_data = {24'd0, sft};
        6'h34: rd_data = {24'd0, rpc};
        default: begin rd_data = 32'd0; rd_unimpl = 1'b1; end
      endcase
    end
  end

  // -------------------------------------------------------------- write

  logic wr_rf;
  assign wr_rf = wr_en && (wr_addr >= 6'h20) && (wr_addr < 6'h30);

  // c0/c1 live in the sequencer; forward the write rather than holding it.
  assign c0_we = wr_en && (wr_addr == 6'h0c);
  assign c0_wd = wr_data[7:0];
  assign c1_we = wr_en && (wr_addr == 6'h0d);
  assign c1_wd = wr_data[7:0];

  always_comb begin
    wr_unimpl = 1'b0;
    if (wr_en && !wr_rf) begin
      unique case (wr_addr)
        6'h00, 6'h01, 6'h02, 6'h03,
        6'h05, 6'h06, 6'h08, 6'h0a,
        6'h0c, 6'h0d,
        6'h0f,                                   // explicit no-op in MAME
        6'h10, 6'h11, 6'h12,
        6'h13, 6'h14, 6'h15,
        6'h19, 6'h1a, 6'h1b,
        6'h1c, 6'h1d, 6'h1e, 6'h1f,
        6'h34, 6'h3c: wr_unimpl = 1'b0;
        default:      wr_unimpl = 1'b1;
      endcase
    end
  end

  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // Reset values from device_reset: everything zero except the counters,
      // which the sequencer owns, and vsm/vsmr.
      reg_a <= 32'd0; reg_b <= 32'd0; reg_d <= 32'd0; reg_p <= 32'd0;
      b0 <= 16'd0; b1 <= 16'd0; x0 <= 16'd0; x1 <= 16'd0;
      i0 <= 16'd0; i1 <= 16'd0;
      sp <= 16'd0; mask <= 16'd0;
      sft <= 8'd0; rpc <= 8'd1;
      vsm <= 3'd0; vsmr <= 16'd7;                // (8 << 0) - 1
      for (k = 0; k < 16; k = k + 1) rf[k] <= 32'd0;
    end else begin
      if (wr_rf) rf[wr_addr[3:0]] <= wr_data;

      if (wr_en && !wr_rf) begin
        unique case (wr_addr)
          6'h00: b0  <= wr_data[15:0];
          6'h01: b1  <= wr_data[15:0];
          6'h02: x0  <= wr_data[15:0];
          6'h03: x1  <= wr_data[15:0];
          6'h05: i0  <= wr_data[15:0];
          6'h06: i1  <= wr_data[15:0];
          6'h08: sp  <= wr_data[15:0];
          // vsm is masked to 3 bits and vsmr is derived, never written direct.
          6'h0a: begin vsm <= wr_data[2:0]; vsmr <= (16'd8 << wr_data[2:0]) - 16'd1; end
          6'h0c, 6'h0d: ;                        // forwarded to the sequencer
          6'h0f: ;                               // MAME: case 0x0f: break;
          6'h10: reg_a <= wr_data;
          6'h11: reg_a <= mb86233_pkg::set_exp(reg_a, wr_data);
          6'h12: reg_a <= mb86233_pkg::set_mant(reg_a, wr_data);
          6'h13: reg_b <= wr_data;
          6'h14: reg_b <= mb86233_pkg::set_exp(reg_b, wr_data);
          6'h15: reg_b <= mb86233_pkg::set_mant(reg_b, wr_data);
          6'h19: reg_d <= wr_data;
          6'h1a: reg_d <= mb86233_pkg::set_exp(reg_d, wr_data);
          6'h1b: reg_d <= mb86233_pkg::set_mant(reg_d, wr_data);
          6'h1c: reg_p <= wr_data;
          6'h1d: reg_p <= mb86233_pkg::set_exp(reg_p, wr_data);
          6'h1e: reg_p <= mb86233_pkg::set_mant(reg_p, wr_data);
          6'h1f: sft <= wr_data[7:0];
          6'h34: rpc <= wr_data[7:0];
          6'h3c: mask <= wr_data[15:0];
          default: ;                             // logs in MAME, no state change
        endcase
      end

      // Writeback wins over write_reg to the same register. For D that is not
      // a new rule: mb86233_alu has already applied the write-priority quirk
      // and its d_we reflects the outcome.
      if (alu_d_we) reg_d <= alu_d;
      if (alu_p_we) reg_p <= alu_p;

      // The AGU's post-increment likewise beats a same-cycle write_reg to the
      // index register, matching MAME's ordering: ea_post_* runs after the
      // transfer that used the address.
      if (agu_x0_we) x0 <= agu_x0;
      if (agu_x1_we) x1 <= agu_x1;

      // clr0 last: MAME applies it inside the 0x0f case, after alu_pre and
      // before alu_post_1, so it beats anything the transfer path wrote.
      if (clr_a) reg_a <= 32'd0;
      if (clr_b) reg_b <= 32'd0;
      if (clr_d) reg_d <= 32'd0;
    end
  end

endmodule
