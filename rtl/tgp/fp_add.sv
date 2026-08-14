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
// IEEE-754 single precision adder / subtractor.
//
// 2-stage pipeline. Stage 1 orders operands by magnitude and aligns. Stage 2
// adds, normalises via leading-zero count, rounds and packs.
//
// This is the area-dominant FP block: two barrel shifters and an LZC, all soft
// logic. If the M0 resource gate fails, this module is where to look first.
// The align shifter can be narrowed by capping the shift at 26 and folding
// everything beyond into sticky, which is already done below.
//
// Serves fadd, fsbd, fcpd, fsmd, fmsd, fmrd, and the B+A / B-A forms. The
// caller selects operands and the effective subtract; this module does not
// know about opcodes.

`timescale 1ns/1ps

module fp_add #(
  parameter bit FLUSH_DENORM_IN = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        in_valid,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        sub,          // compute a - b

  output logic        out_valid,
  output logic [31:0] result,
  output logic        overflow,
  output logic        underflow,
  output logic        invalid       // inf - inf, or NaN operand
);

  // ------------------------------------------------------------- unpack

  logic [31:0] b_eff;
  assign b_eff = {b[31] ^ sub, b[30:0]};

  logic        a_sign, b_sign;
  logic [7:0]  a_exp,  b_exp;
  logic [22:0] a_frac, b_frac;

  assign a_sign = a[31];      assign a_exp = a[30:23];      assign a_frac = a[22:0];
  assign b_sign = b_eff[31];  assign b_exp = b_eff[30:23];  assign b_frac = b_eff[22:0];

  logic a_is_zero, b_is_zero, a_is_inf, b_is_inf, a_is_nan, b_is_nan;
  assign a_is_zero = (a_exp == 8'h00) && (FLUSH_DENORM_IN ? 1'b1 : (a_frac == 23'd0));
  assign b_is_zero = (b_exp == 8'h00) && (FLUSH_DENORM_IN ? 1'b1 : (b_frac == 23'd0));
  assign a_is_inf  = (a_exp == 8'hff) && (a_frac == 23'd0);
  assign b_is_inf  = (b_exp == 8'hff) && (b_frac == 23'd0);
  assign a_is_nan  = (a_exp == 8'hff) && (a_frac != 23'd0);
  assign b_is_nan  = (b_exp == 8'hff) && (b_frac != 23'd0);

  logic [23:0] a_sig, b_sig;
  assign a_sig = {(a_exp != 8'h00), a_frac};
  assign b_sig = {(b_exp != 8'h00), b_frac};

  logic [7:0] a_e_eff, b_e_eff;
  assign a_e_eff = (a_exp == 8'h00) ? 8'd1 : a_exp;
  assign b_e_eff = (b_exp == 8'h00) ? 8'd1 : b_exp;

  // -------------------------------------------------- order by magnitude

  logic a_ge;
  assign a_ge = (a_e_eff > b_e_eff) ||
                ((a_e_eff == b_e_eff) && (a_sig >= b_sig));

  logic [23:0] big_sig, small_sig;
  logic [7:0]  big_exp;
  logic        big_sign, small_sign;

  assign big_sig    = a_ge ? a_sig   : b_sig;
  assign small_sig  = a_ge ? b_sig   : a_sig;
  assign big_exp    = a_ge ? a_e_eff : b_e_eff;
  assign big_sign   = a_ge ? a_sign  : b_sign;
  assign small_sign = a_ge ? b_sign  : a_sign;

  logic [8:0] exp_diff_full;
  logic [4:0] shamt;
  logic       shift_saturated;

  assign exp_diff_full   = {1'b0, a_ge ? a_e_eff : b_e_eff}
                         - {1'b0, a_ge ? b_e_eff : a_e_eff};
  assign shift_saturated = (exp_diff_full > 9'd26);
  assign shamt           = shift_saturated ? 5'd26 : exp_diff_full[4:0];

  // 3 extra low bits: guard, round, sticky.
  logic [26:0] small_ext, small_aligned;
  logic        sticky_lost;

  assign small_ext     = {small_sig, 3'b000};
  assign small_aligned = small_ext >> shamt;
  assign sticky_lost   = shift_saturated ? (|small_ext)
                                         : (|(small_ext & ((27'd1 << shamt) - 27'd1)));

  logic [26:0] big_ext;
  assign big_ext = {big_sig, 3'b000};

  logic eff_sub;
  assign eff_sub = big_sign ^ small_sign;

  // ------------------------------------------------------------ stage 1

  logic        s1_valid, s1_sign, s1_nan, s1_inf, s1_invalid, s1_both_zero;
  logic        s1_zero_sign;
  logic [7:0]  s1_exp;
  logic [27:0] s1_sum;
  logic        s1_sticky;
  logic        s1_exact_cancel;

  // On effective subtract the bits discarded by the align shifter represent a
  // positive eps that was never subtracted, so big - small_aligned overshoots.
  // Borrow one LSB and let the round stage see sticky=1: the true remainder is
  // (1 - eps) LSBs, which lies strictly between 0 and 1.
  logic [27:0] sum_raw;
  assign sum_raw = eff_sub
                 ? ({1'b0, big_ext} - {1'b0, small_aligned} - {27'd0, sticky_lost})
                 : ({1'b0, big_ext} + {1'b0, small_aligned});

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
    end else begin
      s1_valid   <= in_valid;
      s1_sign    <= big_sign;
      s1_exp     <= big_exp;
      s1_sum     <= sum_raw;
      s1_sticky  <= sticky_lost;
      s1_invalid <= (a_is_nan | b_is_nan) | (a_is_inf & b_is_inf & (a_sign ^ b_sign));
      s1_nan     <= (a_is_nan | b_is_nan) | (a_is_inf & b_is_inf & (a_sign ^ b_sign));
      s1_inf     <= (a_is_inf | b_is_inf) & ~(a_is_inf & b_is_inf & (a_sign ^ b_sign));
      // Exact cancellation returns +0 under round-to-nearest.
      s1_exact_cancel <= eff_sub && (sum_raw == 28'd0) && !sticky_lost;
      s1_both_zero    <= a_is_zero & b_is_zero;
      // -0 + -0 = -0; every other zero pairing gives +0 under round-to-nearest.
      s1_zero_sign    <= a_sign & b_sign;
    end
  end

  // ------------------------------------------------------------ stage 2

  // Effective-add can carry into bit 27. Effective-sub can cancel arbitrarily.
  logic [4:0]  lzc;
  logic [27:0] shifted;
  logic        lost_bit;
  logic signed [9:0] exp_adj;

  // Leading-zero count as an explicit priority encoder. Written without a
  // loop-with-break so it reads identically to yosys, Verilator and Quartus.
  // lzc == 1 means the leading one already sits at bit 26.
  always_comb begin
    lzc = 5'd27;
    for (int i = 0; i < 27; i++)
      if (s1_sum[i]) lzc = 5'(27 - i);
  end

  always_comb begin
    if (s1_sum[27]) begin
      // Carry out of the significand: shift right one, exponent up one.
      shifted  = s1_sum >> 1;
      lost_bit = s1_sum[0];
      exp_adj  = $signed({2'b00, s1_exp}) + 10'sd1;
    end else begin
      // lzc == 1 means the leading one already sits at bit 26.
      shifted  = s1_sum << (lzc - 5'd1);
      lost_bit = 1'b0;
      exp_adj  = $signed({2'b00, s1_exp}) - $signed({5'd0, lzc}) + 10'sd1;
    end
  end

  logic [22:0] frac_pre;
  logic        guard, round_bit, sticky;

  assign frac_pre  = shifted[25:3];
  assign guard     = shifted[2];
  assign round_bit = shifted[1];
  assign sticky    = shifted[0] | lost_bit | s1_sticky;

  logic round_up;
  assign round_up = guard & (round_bit | sticky | frac_pre[0]);

  logic [23:0]       frac_rnd;
  logic signed [9:0] exp_rnd;
  logic [22:0]       frac_final;

  assign frac_rnd   = {1'b0, frac_pre} + {23'd0, round_up};
  assign exp_rnd    = exp_adj + (frac_rnd[23] ? 10'sd1 : 10'sd0);
  assign frac_final = frac_rnd[23] ? 23'd0 : frac_rnd[22:0];

  logic ovf, unf, is_zero_result;
  assign ovf            = (exp_rnd >= 10'sd255);
  assign unf            = (exp_rnd <= 10'sd0);
  assign is_zero_result = (s1_sum == 28'd0) && !s1_sticky;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      result    <= 32'd0;
      overflow  <= 1'b0;
      underflow <= 1'b0;
      invalid   <= 1'b0;
    end else begin
      out_valid <= s1_valid;
      invalid   <= s1_valid & s1_invalid;
      overflow  <= 1'b0;
      underflow <= 1'b0;

      if (s1_nan) begin
        result <= 32'h7fc00000;
      end else if (s1_inf) begin
        result <= {s1_sign, 8'hff, 23'd0};
      end else if (s1_both_zero) begin
        // -0 + -0 = -0; every other zero pairing gives +0.
        result <= {s1_zero_sign, 8'h00, 23'd0};
      end else if (s1_exact_cancel || is_zero_result) begin
        result <= 32'h00000000;
      end else if (ovf) begin
        result   <= {s1_sign, 8'hff, 23'd0};
        overflow <= s1_valid;
      end else if (unf) begin
        result    <= {s1_sign, 8'h00, 23'd0};
        underflow <= s1_valid;
      end else begin
        result <= {s1_sign, exp_rnd[7:0], frac_final};
      end
    end
  end

endmodule
