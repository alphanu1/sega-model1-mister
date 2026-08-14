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
// 4-stage pipeline, LATENCY 4. Retimed from 2 stages to meet the M0 Fmax gate.
//
//   A  unpack, order by magnitude, 27-bit align shift
//   B  add or subtract
//   C  leading-zero count and normalise shift
//   D  round and pack
//
// Two separate paths forced this, both measured with make quartus_paths:
// inside the core the ALU operand mux fed stage 1's compare-align-subtract
// chain (~54 MHz), and standalone the old stage 2 ran lzc -> normalise shift ->
// 24-bit round carry chain (~78.7 MHz). Splitting either alone leaves the other
// as the ceiling, so both are cut.
//
// fp_mul carries the same latency so mb86233_alu keeps a single alignment
// depth for its non-FP results.
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

  // ------------------------------------------------- stage A: align only
  //
  // The 27-bit barrel shifter ends here. Everything downstream of it — the
  // add, the normalise, the round — is in a later stage, which is the point
  // of the retime.

  logic        sA_valid, sA_sign, sA_nan, sA_inf, sA_invalid, sA_both_zero;
  logic        sA_zero_sign, sA_eff_sub, sA_sticky;
  logic [7:0]  sA_exp;
  logic [26:0] sA_big, sA_small;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sA_valid <= 1'b0;
    end else begin
      sA_valid   <= in_valid;
      sA_sign    <= big_sign;
      sA_exp     <= big_exp;
      sA_big     <= big_ext;
      sA_small   <= small_aligned;
      sA_sticky  <= sticky_lost;
      sA_eff_sub <= eff_sub;
      sA_invalid <= (a_is_nan | b_is_nan) | (a_is_inf & b_is_inf & (a_sign ^ b_sign));
      sA_nan     <= (a_is_nan | b_is_nan) | (a_is_inf & b_is_inf & (a_sign ^ b_sign));
      sA_inf     <= (a_is_inf | b_is_inf) & ~(a_is_inf & b_is_inf & (a_sign ^ b_sign));
      sA_both_zero <= a_is_zero & b_is_zero;
      // -0 + -0 = -0; every other zero pairing gives +0 under round-to-nearest.
      sA_zero_sign <= a_sign & b_sign;
    end
  end

  // ------------------------------------------------- stage B: add / subtract
  //
  // On effective subtract the bits discarded by the align shifter represent a
  // positive eps that was never subtracted, so big - small_aligned overshoots.
  // Borrow one LSB and let the round stage see sticky=1: the true remainder is
  // (1 - eps) LSBs, which lies strictly between 0 and 1.
  logic [27:0] sum_raw;
  assign sum_raw = sA_eff_sub
                 ? ({1'b0, sA_big} - {1'b0, sA_small} - {27'd0, sA_sticky})
                 : ({1'b0, sA_big} + {1'b0, sA_small});

  logic        s1_valid, s1_sign, s1_nan, s1_inf, s1_invalid, s1_both_zero;
  logic        s1_zero_sign;
  logic [7:0]  s1_exp;
  logic [27:0] s1_sum;
  logic        s1_sticky;
  logic        s1_exact_cancel;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
    end else begin
      s1_valid        <= sA_valid;
      s1_sign         <= sA_sign;
      s1_exp          <= sA_exp;
      s1_sum          <= sum_raw;
      s1_sticky       <= sA_sticky;
      s1_invalid      <= sA_invalid;
      s1_nan          <= sA_nan;
      s1_inf          <= sA_inf;
      // Exact cancellation returns +0 under round-to-nearest.
      s1_exact_cancel <= sA_eff_sub && (sum_raw == 28'd0) && !sA_sticky;
      s1_both_zero    <= sA_both_zero;
      s1_zero_sign    <= sA_zero_sign;
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

  // --------------------------------- stage C: register the normalised sum
  //
  // The leading-zero count and the normalise shift end here; the round adder's
  // 24-bit carry chain starts in stage D. Standalone measurement put
  // lzc -> shift -> round-carry on one path at ~78.7 MHz, which was the
  // ceiling once the core-side path was cut.
  logic        sC_valid, sC_sign, sC_nan, sC_inf, sC_invalid;
  logic        sC_both_zero, sC_zero_sign, sC_exact_cancel, sC_zero_result;
  logic [27:0] sC_shifted;
  logic        sC_sticky_in;
  logic signed [9:0] sC_exp_adj;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sC_valid <= 1'b0;
    end else begin
      sC_valid        <= s1_valid;
      sC_sign         <= s1_sign;
      sC_shifted      <= shifted;
      sC_exp_adj      <= exp_adj;
      sC_sticky_in    <= lost_bit | s1_sticky;
      sC_nan          <= s1_nan;
      sC_inf          <= s1_inf;
      sC_invalid      <= s1_invalid;
      sC_both_zero    <= s1_both_zero;
      sC_zero_sign    <= s1_zero_sign;
      sC_exact_cancel <= s1_exact_cancel;
      sC_zero_result  <= (s1_sum == 28'd0) && !s1_sticky;
    end
  end

  // ------------------------------------------------ stage D: round and pack

  logic [22:0] frac_pre;
  logic        guard, round_bit, sticky;

  assign frac_pre  = sC_shifted[25:3];
  assign guard     = sC_shifted[2];
  assign round_bit = sC_shifted[1];
  assign sticky    = sC_shifted[0] | sC_sticky_in;

  logic round_up;
  assign round_up = guard & (round_bit | sticky | frac_pre[0]);

  logic [23:0]       frac_rnd;
  logic signed [9:0] exp_rnd;
  logic [22:0]       frac_final;

  assign frac_rnd   = {1'b0, frac_pre} + {23'd0, round_up};
  assign exp_rnd    = sC_exp_adj + (frac_rnd[23] ? 10'sd1 : 10'sd0);
  assign frac_final = frac_rnd[23] ? 23'd0 : frac_rnd[22:0];

  logic ovf, unf, is_zero_result;
  assign ovf            = (exp_rnd >= 10'sd255);
  assign unf            = (exp_rnd <= 10'sd0);
  assign is_zero_result = sC_zero_result;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      result    <= 32'd0;
      overflow  <= 1'b0;
      underflow <= 1'b0;
      invalid   <= 1'b0;
    end else begin
      out_valid <= sC_valid;
      invalid   <= sC_valid & sC_invalid;
      overflow  <= 1'b0;
      underflow <= 1'b0;

      if (sC_nan) begin
        result <= 32'h7fc00000;
      end else if (sC_inf) begin
        result <= {sC_sign, 8'hff, 23'd0};
      end else if (sC_both_zero) begin
        // -0 + -0 = -0; every other zero pairing gives +0.
        result <= {sC_zero_sign, 8'h00, 23'd0};
      end else if (sC_exact_cancel || is_zero_result) begin
        result <= 32'h00000000;
      end else if (ovf) begin
        result   <= {sC_sign, 8'hff, 23'd0};
        overflow <= s1_valid;
      end else if (unf) begin
        result    <= {sC_sign, 8'h00, 23'd0};
        underflow <= sC_valid;
      end else begin
        result <= {sC_sign, exp_rnd[7:0], frac_final};
      end
    end
  end

endmodule
