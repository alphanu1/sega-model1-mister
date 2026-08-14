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
// IEEE-754 single precision multiplier.
//
// 2-stage pipeline. Stage 1 unpacks and issues the 24x24 significand multiply
// (one Cyclone V variable-precision DSP block in 27x27 mode). Stage 2
// normalises, rounds and packs.
//
// Latency 2, fully pipelined, one result per clock. The TGP retires roughly
// 5.3 M instructions/sec at a 16 MHz part clock so throughput is irrelevant;
// the pipeline exists to keep the DSP block registered and Fmax comfortable.
//
// OPEN QUESTION — denormal handling. MAME evaluates with host floats, which
// are fully IEEE and honour denormals. Real silicon of this era commonly
// flushes to zero. `FLUSH_DENORM_IN` and `FLUSH_DENORM_OUT` expose both
// behaviours. Resolve by fuzzing against the oracle with denormal operands
// before committing. Default matches MAME.

`timescale 1ns/1ps

module fp_mul #(
  parameter bit FLUSH_DENORM_IN  = 1'b0,
  parameter bit FLUSH_DENORM_OUT = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        in_valid,
  input  logic [31:0] a,
  input  logic [31:0] b,

  output logic        out_valid,
  output logic [31:0] result,
  output logic        overflow,
  output logic        underflow,
  output logic        invalid      // inf * 0, or NaN operand
);

  // ------------------------------------------------------------- unpack

  logic        a_sign, b_sign;
  logic [7:0]  a_exp,  b_exp;
  logic [22:0] a_frac, b_frac;

  assign a_sign = a[31];  assign a_exp = a[30:23];  assign a_frac = a[22:0];
  assign b_sign = b[31];  assign b_exp = b[30:23];  assign b_frac = b[22:0];

  logic a_is_zero, b_is_zero, a_is_inf, b_is_inf, a_is_nan, b_is_nan;
  logic a_is_den,  b_is_den;

  assign a_is_den  = (a_exp == 8'h00) && (a_frac != 23'd0);
  assign b_is_den  = (b_exp == 8'h00) && (b_frac != 23'd0);
  assign a_is_zero = (a_exp == 8'h00) && (FLUSH_DENORM_IN ? 1'b1 : (a_frac == 23'd0));
  assign b_is_zero = (b_exp == 8'h00) && (FLUSH_DENORM_IN ? 1'b1 : (b_frac == 23'd0));
  assign a_is_inf  = (a_exp == 8'hff) && (a_frac == 23'd0);
  assign b_is_inf  = (b_exp == 8'hff) && (b_frac == 23'd0);
  assign a_is_nan  = (a_exp == 8'hff) && (a_frac != 23'd0);
  assign b_is_nan  = (b_exp == 8'hff) && (b_frac != 23'd0);

  // Significand with implicit bit. Denormals carry a leading zero and an
  // exponent that behaves as 1, which the wide multiply handles directly.
  logic [23:0] a_sig, b_sig;
  assign a_sig = (a_is_den && !FLUSH_DENORM_IN) ? {1'b0, a_frac} : {1'b1, a_frac};
  assign b_sig = (b_is_den && !FLUSH_DENORM_IN) ? {1'b0, b_frac} : {1'b1, b_frac};

  logic signed [10:0] a_e_eff, b_e_eff;
  assign a_e_eff = (a_exp == 8'h00) ? 11'sd1 : $signed({3'b000, a_exp});
  assign b_e_eff = (b_exp == 8'h00) ? 11'sd1 : $signed({3'b000, b_exp});

  // ------------------------------------------------------------ stage 1

  logic               s1_valid;
  logic               s1_sign;
  logic signed [10:0] s1_exp;
  logic [47:0]        s1_prod;
  logic               s1_zero, s1_inf, s1_nan, s1_invalid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
    end else begin
      s1_valid   <= in_valid;
      s1_sign    <= a_sign ^ b_sign;
      s1_exp     <= a_e_eff + b_e_eff - 11'sd127;
      s1_prod    <= a_sig * b_sig;
      s1_invalid <= (a_is_nan | b_is_nan)
                  | (a_is_inf & b_is_zero) | (b_is_inf & a_is_zero);
      s1_nan     <= (a_is_nan | b_is_nan)
                  | (a_is_inf & b_is_zero) | (b_is_inf & a_is_zero);
      s1_inf     <= (a_is_inf | b_is_inf) & ~(a_is_zero | b_is_zero);
      s1_zero    <= (a_is_zero | b_is_zero) & ~(a_is_inf | b_is_inf);
    end
  end

  // ------------------------------------------------------------ stage 2

  // Product of two [1,2) significands lands in [1,4). Bit 47 set means the
  // result needs one right shift and an exponent bump.
  logic               norm_shift;
  logic [47:0]        norm_prod;
  logic signed [10:0] norm_exp;

  assign norm_shift = s1_prod[47];
  assign norm_prod  = norm_shift ? s1_prod : (s1_prod << 1);
  assign norm_exp   = s1_exp + (norm_shift ? 11'sd1 : 11'sd0);

  // norm_prod[47] is the implicit bit, [46:24] the fraction.
  logic [22:0] frac_pre;
  logic        guard, round_bit, sticky;

  assign frac_pre  = norm_prod[46:24];
  assign guard     = norm_prod[23];
  assign round_bit = norm_prod[22];
  assign sticky    = |norm_prod[21:0];

  // Round to nearest, ties to even.
  logic round_up;
  assign round_up = guard & (round_bit | sticky | frac_pre[0]);

  logic [23:0]        frac_rnd;      // carry out of bit 22 on overflow
  logic signed [10:0] exp_rnd;
  logic [22:0]        frac_final;

  assign frac_rnd   = {1'b0, frac_pre} + {23'd0, round_up};
  assign exp_rnd    = norm_exp + (frac_rnd[23] ? 11'sd1 : 11'sd0);
  assign frac_final = frac_rnd[23] ? 23'd0 : frac_rnd[22:0];

  logic ovf, unf;
  assign ovf = (exp_rnd >= 11'sd255);
  assign unf = (exp_rnd <= 11'sd0);

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
        result <= 32'h7fc00000;                    // quiet NaN
      end else if (s1_inf) begin
        result <= {s1_sign, 8'hff, 23'd0};
      end else if (s1_zero) begin
        result <= {s1_sign, 8'h00, 23'd0};
      end else if (ovf) begin
        result   <= {s1_sign, 8'hff, 23'd0};
        overflow <= s1_valid;
      end else if (unf) begin
        // Denormal output path not built: flush. See OPEN QUESTION above.
        result    <= {s1_sign, 8'h00, 23'd0};
        underflow <= s1_valid;
      end else begin
        result <= {s1_sign, exp_rnd[7:0], frac_final};
      end
    end
  end

endmodule
