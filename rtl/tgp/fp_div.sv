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
// IEEE-754 single precision divider. Serves fdvd (ALU op 0x10) only.
//
// MAME evaluates it as f2u(u2f(m_d) / u2f(m_a)) — plain host division with the
// default round-to-nearest-even. Numerator is D, denominator is A.
//
// Radix-2 restoring division, one quotient bit per cycle. NOT pipelined, and
// deliberately so: this is the only op that needs it, the TGP retires ~5.3 M
// instructions/sec against a 50 MHz fabric clock, and a pipelined or
// Newton-Raphson divider costs far more area than one opcode is worth. The
// significand loop is 27 iterations, so a divide costs ~29 cycles.
//
// LATENCY IS NOT 2. fp_mul and fp_add are fixed-latency-2 and mb86233_alu is
// built around that uniformity. This block cannot be, so it exposes a
// busy/out_valid handshake and the caller must stall. See the note in
// docs/m0-mb86233-spike.md.
//
// Denormals and NaN payloads are out of scope here exactly as they are in
// fp_mul and fp_add: denormal inputs are treated as zero on the way in, no
// denormal outputs are produced, and NaN results are canonical 0x7fc00000
// rather than payload-propagating.

`timescale 1ns/1ps

module fp_div #(
  parameter bit FLUSH_DENORM_IN = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        in_valid,     // accepted only when !busy
  input  logic [31:0] a,            // numerator   (D)
  input  logic [31:0] b,            // denominator (A)

  output logic        busy,
  output logic        out_valid,
  output logic [31:0] result,
  output logic        overflow,
  output logic        underflow,
  output logic        div_by_zero,  // finite nonzero / zero
  output logic        invalid       // 0/0, inf/inf, or a NaN operand
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

  logic [23:0] a_sig, b_sig;
  assign a_sig = (a_is_den && !FLUSH_DENORM_IN) ? {1'b0, a_frac} : {1'b1, a_frac};
  assign b_sig = (b_is_den && !FLUSH_DENORM_IN) ? {1'b0, b_frac} : {1'b1, b_frac};

  logic signed [10:0] a_e_eff, b_e_eff;
  assign a_e_eff = (a_exp == 8'h00) ? 11'sd1 : $signed({3'b000, a_exp});
  assign b_e_eff = (b_exp == 8'h00) ? 11'sd1 : $signed({3'b000, b_exp});

  // Result classes, decided at issue and carried through the iteration.
  logic res_nan, res_inf, res_zero, res_dvz;
  assign res_nan  = a_is_nan | b_is_nan
                  | (a_is_inf & b_is_inf) | (a_is_zero & b_is_zero);
  assign res_inf  = ~res_nan & (a_is_inf | b_is_zero);
  assign res_zero = ~res_nan & ~res_inf & (a_is_zero | b_is_inf);
  assign res_dvz  = ~res_nan & b_is_zero & ~a_is_inf;

  // ------------------------------------------------------- normalisation
  //
  // Both significands sit in [2^23, 2^24), so the quotient lands in (0.5, 2).
  // Pre-shifting the numerator when it is the smaller of the two forces the
  // quotient into [1, 2), which makes the leading quotient bit unconditionally
  // 1 and removes the post-normalise shifter entirely.

  logic        pre_shift;
  logic [25:0] num_init;
  assign pre_shift = (a_sig < b_sig);
  assign num_init  = pre_shift ? {1'b0, a_sig, 1'b0} : {2'b00, a_sig};

  logic signed [10:0] exp_init;
  assign exp_init = a_e_eff - b_e_eff + 11'sd127 - (pre_shift ? 11'sd1 : 11'sd0);

  // --------------------------------------------------------------- FSM

  localparam int ITERS = 27;         // 1 integer bit + 26 fraction bits

  typedef enum logic [1:0] { S_IDLE, S_DIV, S_DONE } state_e;
  state_e state;

  logic [25:0]        rem;
  logic [23:0]        den;
  logic [26:0]        quo;
  logic [4:0]         iter;
  logic               q_sign;
  logic signed [10:0] q_exp;
  logic               q_nan, q_inf, q_zero, q_dvz, q_inv;

  // One restoring step.
  logic        step_ge;
  logic [25:0] step_sub;
  assign step_ge  = (rem >= {2'b00, den});
  assign step_sub = step_ge ? (rem - {2'b00, den}) : rem;

  assign busy = (state != S_IDLE);

  // ------------------------------------------------------------- round
  //
  // quo is 1.f1..f26. Mantissa takes f1..f23; f24 is guard, f25 is round, and
  // f26 together with any leftover remainder forms sticky.

  logic [22:0] frac_pre;
  logic        guard, round_b, sticky;

  assign frac_pre = quo[25:3];
  assign guard    = quo[2];
  assign round_b  = quo[1];
  assign sticky   = quo[0] | (rem != 26'd0);

  logic round_up;
  assign round_up = guard & (round_b | sticky | frac_pre[0]);

  logic [23:0]        frac_rnd;
  logic signed [10:0] exp_rnd;
  logic [22:0]        frac_final;

  assign frac_rnd   = {1'b0, frac_pre} + {23'd0, round_up};
  assign exp_rnd    = q_exp + (frac_rnd[23] ? 11'sd1 : 11'sd0);
  assign frac_final = frac_rnd[23] ? 23'd0 : frac_rnd[22:0];

  logic ovf, unf;
  assign ovf = (exp_rnd >= 11'sd255);
  assign unf = (exp_rnd <= 11'sd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      out_valid   <= 1'b0;
      result      <= 32'd0;
      overflow    <= 1'b0;
      underflow   <= 1'b0;
      div_by_zero <= 1'b0;
      invalid     <= 1'b0;
    end else begin
      out_valid   <= 1'b0;
      overflow    <= 1'b0;
      underflow   <= 1'b0;
      div_by_zero <= 1'b0;
      invalid     <= 1'b0;

      unique case (state)
        S_IDLE: begin
          if (in_valid) begin
            rem    <= num_init;
            den    <= b_sig;
            quo    <= 27'd0;
            iter   <= 5'd0;
            q_sign <= a_sign ^ b_sign;
            q_exp  <= exp_init;
            q_nan  <= res_nan;
            q_inf  <= res_inf;
            q_zero <= res_zero;
            q_dvz  <= res_dvz;
            q_inv  <= res_nan;
            state  <= S_DIV;
          end
        end

        S_DIV: begin
          // q <<= 1; if (rem >= den) { rem -= den; q |= 1; } rem <<= 1;
          quo  <= {quo[25:0], step_ge};
          rem  <= {step_sub[24:0], 1'b0};
          iter <= iter + 5'd1;
          if (iter == 5'(ITERS - 1)) state <= S_DONE;
        end

        S_DONE: begin
          out_valid <= 1'b1;
          state     <= S_IDLE;

          if (q_nan) begin
            result  <= 32'h7fc00000;
            invalid <= 1'b1;
          end else if (q_inf) begin
            result      <= {q_sign, 8'hff, 23'd0};
            div_by_zero <= q_dvz;
          end else if (q_zero) begin
            result <= {q_sign, 8'h00, 23'd0};
          end else if (ovf) begin
            result   <= {q_sign, 8'hff, 23'd0};
            overflow <= 1'b1;
          end else if (unf) begin
            // No denormal output path, same as fp_mul and fp_add.
            result    <= {q_sign, 8'h00, 23'd0};
            underflow <= 1'b1;
          end else begin
            result <= {q_sign, exp_rnd[7:0], frac_final};
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
