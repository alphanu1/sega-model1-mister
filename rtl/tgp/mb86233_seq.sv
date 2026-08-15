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
//   src/devices/cpu/mb86233/mb86233.cpp   (execute_run, pcs_push/pcs_pop)
//   SPDX-License-Identifier: BSD-3-Clause
//   Copyright-holders: Olivier Galibert
//
// That BSD-3-Clause attribution must be retained. See THIRD-PARTY.md.
//
// Fujitsu MB86233 "TGP" — sequencer
//
// Owns PC, the 4-deep hardware PC stack, the two loop counters and their ZC
// flags, and the repeat counter. One instruction retires per in_valid.
//
// Memory and register reads are the caller's job: brul/bsul take their target
// from `branch_val`, whether that came from read_reg or from data memory.
//
// THREE ORDERING RULES THAT ARE NOT OPTIONAL
//
// 1. The repeat override runs AFTER the branch has already written PC.
//    MAME's `if(m_r != 1) { m_pc = m_ppc; m_r--; }` sits below the whole
//    instruction switch, so a taken branch inside an active repeat is
//    computed and then discarded. Ordering these the other way round would
//    make loops branch out on their first iteration.
//
// 2. `rep` skips that override via `goto rep_start`. Setting the repeat count
//    must not immediately re-execute the instruction that set it.
//
// 3. A stall also skips it, and skips the loop-counter decrement, because
//    `goto do_stall` leaves from inside the subtype switch.

`timescale 1ns/1ps

module mb86233_seq (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        in_valid,     // an instruction retires this cycle

  // Decoded instruction.
  input  logic        is_branch,    // (opcode >> 26) is 0x2f or 0x3f
  input  logic [4:0]  cond,         // (opcode >> 20) & 0x1f
  input  logic [2:0]  subtype,      // (opcode >> 17) & 7
  input  logic [15:0] data,         // opcode & 0xffff
  input  logic        invert,       // opcode & 0x40000000

  // Target for brul/bsul, already fetched by the caller from a register or
  // from data memory.
  input  logic [15:0] branch_val,

  // rep (opcode type 0x0f, sub2 == 2).
  input  logic        is_rep,
  input  logic [7:0]  rep_count,

  // The memory or register read behind brul/bsul/ldif did not complete.
  input  logic        stall,

  input  logic [3:0]  gpio,
  input  logic [31:0] st_in,        // read for ZRD (bit 1) and SGD (bit 3)

  // write_reg(0x0c/0x0d) writing the loop counters.
  input  logic        c0_we,
  input  logic [7:0]  c0_wd,
  input  logic        c1_we,
  input  logic [7:0]  c1_wd,

  output logic [15:0] pc,
  output logic [7:0]  c0,
  output logic [7:0]  c1,
  output logic [7:0]  rep,
  output logic        zc0,          // ST bit 30
  output logic        zc1,          // ST bit 31
  output logic        cond_passed,
  output logic        unimplemented
);

  // ------------------------------------------------------------ PC stack

  logic [15:0] pcs [0:3];

  // ---------------------------------------------------- condition decode
  //
  // Unlisted conditions log and leave cond_passed false — but the invert is
  // applied afterwards, so an undecoded condition with bit 30 set still
  // branches. That is MAME's behaviour and it is reachable.

  logic cond_raw, cond_known;
  always_comb begin
    cond_known = 1'b1;
    unique case (cond)
      5'h00: cond_raw =  st_in[mb86233_pkg::F_ZRD];                 // zrd
      5'h01: cond_raw = ~st_in[mb86233_pkg::F_SGD];                 // ged
      5'h02: cond_raw =  st_in[mb86233_pkg::F_ZRD]
                       | st_in[mb86233_pkg::F_SGD];                 // led
      5'h0a: cond_raw =  gpio[0];
      5'h0b: cond_raw =  gpio[1];
      5'h0c: cond_raw =  gpio[2];
      5'h10: cond_raw = ~zc0;                                       // c0 != 1
      5'h11: cond_raw = ~zc1;                                       // c1 != 1
      5'h12: cond_raw =  gpio[3];
      5'h16: cond_raw =  1'b1;                                      // alw
      default: begin cond_raw = 1'b0; cond_known = 1'b0; end
    endcase
  end

  assign cond_passed = invert ? ~cond_raw : cond_raw;

  logic sub_known;
  always_comb begin
    unique case (subtype)
      3'd0, 3'd1, 3'd2, 3'd3, 3'd5, 3'd6: sub_known = 1'b1;
      default:                            sub_known = 1'b0;
    endcase
  end

  assign unimplemented = in_valid & is_branch
                       & (~cond_known | (cond_passed & ~sub_known));

  // ------------------------------------------------------- branch result

  logic [15:0] ppc, seq_pc;
  assign ppc    = pc;
  assign seq_pc = pc + 16'd1;      // PC after the fetch, and the return address

  logic [15:0] pc_exec;            // PC as the instruction switch leaves it
  logic        do_push, do_pop;

  always_comb begin
    pc_exec = seq_pc;
    do_push = 1'b0;
    do_pop  = 1'b0;

    if (is_branch && cond_passed) begin
      unique case (subtype)
        3'd0: pc_exec = data;                            // brif #adr
        3'd1: pc_exec = branch_val;                      // brul
        3'd2: begin pc_exec = data;       do_push = 1'b1; end   // bsif #adr
        3'd3: begin pc_exec = branch_val; do_push = 1'b1; end   // bsul
        3'd5: begin pc_exec = pcs[0];     do_pop  = 1'b1; end   // rtif
        3'd6: ;                                          // ldif: no PC change
        default: ;
      endcase
    end
  end

  // ------------------------------------------------- loop counter decode
  //
  // The decrement runs whether or not the branch was taken — it is outside
  // the cond_passed block — but only for subtype < 2 (brif/brul), and a stall
  // skips it because the goto leaves before this point.

  logic dec_c0, dec_c1;
  assign dec_c0 = in_valid & is_branch & ~stall
                & (subtype < 3'd2) & (cond == 5'h10) & (c0 != 8'd1);
  assign dec_c1 = in_valid & is_branch & ~stall
                & (subtype < 3'd2) & (cond == 5'h11) & (c1 != 8'd1);

  logic [7:0] c0_dec, c1_dec;
  assign c0_dec = c0 - 8'd1;
  assign c1_dec = c1 - 8'd1;

  // --------------------------------------------------------- next state

  logic [15:0] next_pc;
  logic [7:0]  next_rep;
  logic        rep_active;

  assign rep_active = (rep != 8'd1);

  always_comb begin
    next_rep = rep;
    if (stall) begin
      // do_stall: re-execute this instruction, and skip the repeat override.
      next_pc = ppc;
    end else if (is_rep) begin
      // rep: goto rep_start, which is below the repeat override.
      next_pc  = pc_exec;
      next_rep = rep_count;
    end else if (rep_active) begin
      // The override that discards a taken branch. See rule 1 in the header.
      next_pc  = ppc;
      next_rep = rep - 8'd1;
    end else begin
      next_pc = pc_exec;
    end
  end

  // A push or pop must not happen on a stalled instruction: the goto leaves
  // before pcs_push in the bsul path, and rtif cannot stall.
  logic push_now, pop_now;
  assign push_now = in_valid & do_push & ~stall;
  assign pop_now  = in_valid & do_pop  & ~stall;

  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc  <= 16'd0;
      c0  <= 8'd1;
      c1  <= 8'd1;
      rep <= 8'd1;
      // Reset ST is F_ZRC|F_ZRD|F_ZX0|F_ZX1|F_ZX2|F_ZC0|F_ZC1, so both loop
      // flags start set — consistent with c0 == c1 == 1.
      zc0 <= 1'b1;
      zc1 <= 1'b1;
      for (k = 0; k < 4; k = k + 1) pcs[k] <= 16'd0;
    end else begin
      if (in_valid) begin
        pc  <= next_pc;
        rep <= next_rep;

        if (push_now) begin
          pcs[3] <= pcs[2];
          pcs[2] <= pcs[1];
          pcs[1] <= pcs[0];
          pcs[0] <= seq_pc;        // pcs_push stores the already-incremented PC
        end else if (pop_now) begin
          // pcs_pop shifts down and leaves pcs[3] holding its old value: the
          // loop is `for(i=0; i!=3; i++) m_pcs[i] = m_pcs[i+1]`, which never
          // writes index 3. Duplicating the top entry is the real behaviour.
          pcs[0] <= pcs[1];
          pcs[1] <= pcs[2];
          pcs[2] <= pcs[3];
        end
      end

      // The loop counters decrement on the branch, and set their flag as they
      // reach 1. Nothing ever clears these flags except an explicit write.
      if (dec_c0) begin
        c0 <= c0_dec;
        if (c0_dec == 8'd1) zc0 <= 1'b1;
      end
      if (dec_c1) begin
        c1 <= c1_dec;
        if (c1_dec == 8'd1) zc1 <= 1'b1;
      end

      // write_reg(0x0c/0x0d) sets the flag both ways, unlike the decrement
      // path which can only set it. Applied last so an explicit write in the
      // same cycle wins.
      if (c0_we) begin
        c0  <= c0_wd;
        zc0 <= (c0_wd == 8'd1);
      end
      if (c1_we) begin
        c1  <= c1_wd;
        zc1 <= (c1_wd == 8'd1);
      end
    end
  end

endmodule
