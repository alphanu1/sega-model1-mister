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
// Behavioural contract is MAME's model1_v.cpp (BSD-3-Clause, Olivier
// Galibert). See THIRD-PARTY.md.
//
// Edge-slope divider for the quad filler.
//
// The only real arithmetic in the whole rasterizer. fill_quad computes a slope
// per edge event as
//
//     sl = (x_here - x_next) / (y_here - y_next)
//
// on int32 operands, so this must be C integer division: **truncating toward
// zero**, not floor. The two differ for exactly the negative-quotient case,
// which is every left-leaning edge, and the error is one LSB of a 16.16
// accumulator per scanline. That drifts a whole pixel over 65536 scanlines and
// a fraction of one over any real polygon — invisible in a directed test,
// caught by a frame diff a long way downstream. Magnitude-divide then negate
// gives truncation for free, which is why it is done that way here.
//
// Restoring division, one bit per cycle, 32 cycles. That is affordable because
// setup runs at most four times per quad (once per vertex event) and never per
// pixel. If a frame's quad count turns out to make 32 cycles hurt, the lever is
// radix-4 or a reciprocal table, and that is a measurement to take rather than
// a guess to build.
module m1_raster_div (
  input  logic               clk,
  input  logic               rst_n,

  input  logic               in_valid,
  input  logic signed [31:0] num,
  input  logic signed [31:0] den,
  output logic               ready,       // idle, will accept in_valid

  output logic               out_valid,   // one cycle
  output logic signed [31:0] quo,
  output logic               div0         // den was zero; quo forced to 0
);

  localparam logic [1:0] S_IDLE = 2'd0;
  localparam logic [1:0] S_RUN  = 2'd1;
  localparam logic [1:0] S_FIN  = 2'd2;
  localparam logic [1:0] S_Z    = 2'd3;

  logic [1:0]  state;
  logic [31:0] n_mag;    // dividend magnitude, shifted out MSB first
  logic [31:0] d_mag;    // divisor magnitude
  logic [31:0] rem;
  logic [31:0] q;
  logic        neg;      // quotient sign: operands differed
  logic [5:0]  cnt;

  // One restoring step: bring down the next dividend bit, subtract if it fits.
  logic [32:0] shifted;
  always_comb shifted = {rem, n_mag[31]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      n_mag     <= 32'd0;
      d_mag     <= 32'd0;
      rem       <= 32'd0;
      q         <= 32'd0;
      neg       <= 1'b0;
      cnt       <= 6'd0;
      quo       <= 32'sd0;
      out_valid <= 1'b0;
      div0      <= 1'b0;
    end else begin
      out_valid <= 1'b0;

      case (state)
        S_IDLE: begin
          if (in_valid) begin
            // Magnitudes. INT32_MIN negates to 0x80000000, which is the right
            // answer as an unsigned magnitude and wrong as a signed value —
            // hence unsigned registers.
            n_mag <= num[31] ? (~num + 32'd1) : num;
            d_mag <= den[31] ? (~den + 32'd1) : den;
            neg   <= num[31] ^ den[31];
            rem   <= 32'd0;
            q     <= 32'd0;
            cnt   <= 6'd0;
            // Cannot happen from fill_quad: the startup loops skip every vertex
            // sharing the current y, so the next vertex is strictly lower and
            // the denominator is strictly nonzero. Guarded anyway, because the
            // alternative is an X that propagates into the span stream.
            state <= (den == 32'sd0) ? S_Z : S_RUN;
          end
        end

        S_RUN: begin
          n_mag <= {n_mag[30:0], 1'b0};
          if (shifted >= {1'b0, d_mag}) begin
            rem <= shifted[31:0] - d_mag;
            q   <= {q[30:0], 1'b1};
          end else begin
            rem <= shifted[31:0];
            q   <= {q[30:0], 1'b0};
          end
          cnt <= cnt + 6'd1;
          if (cnt == 6'd31) state <= S_FIN;
        end

        S_FIN: begin
          // Truncation toward zero comes out of the magnitude divide; the sign
          // is reapplied here and nowhere else.
          quo       <= neg ? $signed(~q + 32'd1) : $signed(q);
          div0      <= 1'b0;
          out_valid <= 1'b1;
          state     <= S_IDLE;
        end

        default: begin // S_Z
          quo       <= 32'sd0;
          div0      <= 1'b1;
          out_valid <= 1'b1;
          state     <= S_IDLE;
        end
      endcase
    end
  end

  always_comb ready = (state == S_IDLE);

endmodule
