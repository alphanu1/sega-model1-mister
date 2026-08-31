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
// RADIX-4 RESTORING DIVISION, two quotient bits per cycle, 16 cycles.
//
// It was radix-2 at 32 cycles, on the note that setup runs at most four times
// per quad and never per pixel, and that the lever if it ever hurt was radix-4
// or a reciprocal table - "a measurement to take rather than a guess to build".
//
// The measurement was taken. sim/video/tb_m1_raster3d.cpp, the reference's own
// frame 900 swept against a real raster:
//
//     FILLW  3,487,790 cycles over 8 passes = 436,000 a frame, of 818,133
//
// and the quad count says 275 cycles of fill per quad against at most eight
// divides of 32. The divider IS the fill.
//
// Radix-4 needs three multiples of the divisor - d, 2d, 3d - compared against
// the shifted remainder, and 3d is the only one that is not a shift. The
// quotient is exact integer division either way, so the result is bit-identical
// to the radix-2 version and tb_m1_raster_fill's 152,025 checks are unchanged.
//
// Radix-8 would want seven multiples for another 5 cycles; that is where this
// stops being worth it.
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
  logic [31:0] rem;      // always < d_mag, so 32 bits is enough
  logic [31:0] q;
  logic        neg;      // quotient sign: operands differed
  logic [4:0]  cnt;      // 16 steps, not 32

  // One restoring step: bring down the next TWO dividend bits and subtract the
  // largest of d, 2d, 3d that fits. 34 bits because rem*4 + 3 can exceed 32.
  wire [33:0] shifted = {rem, n_mag[31:30]};
  wire [33:0] d1 = {2'b00, d_mag};
  wire [33:0] d2 = {1'b0,  d_mag, 1'b0};
  wire [33:0] d3 = d1 + d2;

  logic [1:0]  qdig;
  logic [33:0] rnext;
  always_comb begin
    if      (shifted >= d3) begin qdig = 2'd3; rnext = shifted - d3; end
    else if (shifted >= d2) begin qdig = 2'd2; rnext = shifted - d2; end
    else if (shifted >= d1) begin qdig = 2'd1; rnext = shifted - d1; end
    else                    begin qdig = 2'd0; rnext = shifted;      end
  end

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
            cnt   <= 5'd0;
            // Cannot happen from fill_quad: the startup loops skip every vertex
            // sharing the current y, so the next vertex is strictly lower and
            // the denominator is strictly nonzero. Guarded anyway, because the
            // alternative is an X that propagates into the span stream.
            state <= (den == 32'sd0) ? S_Z : S_RUN;
          end
        end

        S_RUN: begin
          n_mag <= {n_mag[29:0], 2'b00};
          rem   <= rnext[31:0];        // a restored remainder is always < d_mag
          q     <= {q[29:0], qdig};
          cnt   <= cnt + 5'd1;
          if (cnt == 5'd15) state <= S_FIN;
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
