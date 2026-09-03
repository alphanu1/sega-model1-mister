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
module m1_raster_div #(
  // A RECIPROCAL TABLE INSTEAD OF SIXTEEN RESTORING STEPS.
  //
  // The edge-slope divide is 47% of the worst band's fill (tb_m1_raster3d on
  // the reference's frame 5460: 12,597 of 26,808 cycles, 663 segments at 19
  // cycles each), and a band that overruns its beam slot is presented late -
  // on the board that is the top band of the 3D missing. So the latency of
  // this unit, not the number of divides, is what to attack.
  //
  // The fast path is exact, not approximate. recip[d] = ceil(2^32/d), so
  //     q_est = (n * recip[d]) >> 32  =  n/d + n*e/(d*2^32),  0 <= e < d
  // and since e < d the error term is under n/2^32, which is under 1 for any
  // 32-bit numerator. So q_est is floor(n/d) or exactly one more, whatever
  // the numerator, and one multiply-compare corrects it. Four cycles instead
  // of nineteen, bit-identical - tb_m1_raster_fill's 152,025 checks compare
  // against the same C++ reference either way.
  //
  // THE NUMERATOR IS 16.16, NOT A PIXEL COUNT. m1_raster_fill walks its edges
  // in 16.16 fixed point, so a numerator is a screen difference shifted left
  // 16 and reaches 2^25. A first cut bounded the fast path at 2^18 on the
  // reasoning that these are screen coordinates, and every divide in the
  // heavy bands went down the slow path - the measurement said 16 cycles a
  // divide with the table in place, which is what caught it.
  //
  // Only |den| >= TN falls back to the restoring divider, so the unit stays
  // correct for every input the way it always was.
  parameter bit FAST = 1'b1
) (
  input  logic               clk,
  input  logic               rst_n,

  // The reciprocal table lives outside, in m1_recip_rom, so the fill's two
  // dividers share one copy through its second read port - 4 M10K instead of
  // 8. The address is combinational off `den` and the data is expected one
  // cycle later, which is what a registered ROM read gives.
  output logic [9:0]         rom_addr,
  input  logic [31:0]        rom_data,

  input  logic               in_valid,
  input  logic signed [31:0] num,
  input  logic signed [31:0] den,
  output logic               ready,       // idle, will accept in_valid

  output logic               out_valid,   // one cycle
  output logic signed [31:0] quo,
  output logic               div0         // den was zero; quo forced to 0
);

  localparam logic [2:0] S_IDLE = 3'd0;
  localparam logic [2:0] S_RUN  = 3'd1;
  localparam logic [2:0] S_FIN  = 3'd2;
  localparam logic [2:0] S_Z    = 3'd3;
  localparam logic [2:0] S_MUL  = 3'd4;   // fast path: the reciprocal multiply
  localparam logic [2:0] S_COR  = 3'd5;   // fast path: the single correction

  // ceil(2^32/d) for d in 1..511. Entry 0 is unused (den == 0 is trapped) and
  // entry 1 would be 2^32, so d == 1 takes the quotient straight from the
  // numerator below rather than the table.
  // 1,024 ENTRIES, NOT 512. The denominator is a scanline difference between
  // the current row and the next vertex, and the vertex is NOT clipped - the
  // measured coordinate range is -104..495, so differences reach ~600 and a
  // 512-entry table sent most divides down the slow path. Measured: with 512
  // the worst band's divide wait was 12,932 cycles for 806 divides, still 16
  // each. In M10K rather than logic: 32,768 bits is 4 blocks against ~700 ALM.
  localparam int unsigned TN = 1024;

  wire [31:0] n_abs = num[31] ? (~num + 32'd1) : num;
  wire [31:0] d_abs = den[31] ? (~den + 32'd1) : den;
  wire        fast_ok = FAST && (d_abs != 32'd0) && (d_abs < 32'(TN));

  // READ EVERY CYCLE, UNCONDITIONALLY. Reading the table inside the S_IDLE
  // arm - `if (fast_ok) rq <= recip[...]` - is a gated read with a computed
  // address and Quartus will not infer a ROM from it: it built the whole
  // 1,024 x 32 table out of logic, 3,733 ALM for the fill unit against 2,4xx.
  // The divider's operands are held by m1_raster_fill until it takes them,
  // so a free-running read is the same value one cycle later.
  assign rom_addr = d_abs[9:0];
  wire [31:0] recip_q = rom_data;

  logic [31:0] rq;          // the reciprocal, or the quotient under correction
  // 32 x 32 -> the top half is the quotient estimate, and 32 x 11 for the
  // correction's compare. Both are DSP work, which this design has spare.
  wire [63:0] mul_full = {32'd0, n_mag} * {32'd0, recip_q};
  wire [31:0] mul_hi   = mul_full[63:32];
  wire [42:0] q_times_d = {11'd0, q_fast} * {32'd0, d_mag[10:0]};
  wire        over      = q_times_d > {11'd0, n_mag};
  logic [31:0] q_fast;
  logic [2:0]  state;
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
      rq        <= 32'd0;
      q_fast    <= 32'd0;
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
            // d == 1 needs no division at all, and is not in the table.
            if (den == 32'sd0)        state <= S_Z;
            else if (fast_ok && d_abs == 32'd1) begin
              q_fast <= n_abs;
              state  <= S_COR;
            end else if (fast_ok) state <= S_MUL;
            else                  state <= S_RUN;
          end
        end

        // q_est = (n * recip) >> 32. 18 x 32 bits; Quartus builds it from
        // DSP blocks, which this design has spare.
        S_MUL: begin
          q_fast <= mul_hi;
          state  <= S_COR;
        end

        // The single downward correction. q_est is floor(n/d) or one more, so
        // this makes it exact - and the multiply is 18 x 9 bits.
        S_COR: begin
          rq    <= over ? (q_fast - 32'd1) : q_fast;
          state <= S_FIN;
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
          // is reapplied here and nowhere else. `rq` carries the fast path's
          // corrected quotient, `q` the restoring divider's.
          quo       <= fast_done ? (neg ? $signed(~rq + 32'd1) : $signed(rq))
                                 : (neg ? $signed(~q  + 32'd1) : $signed(q));
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

  // Which path produced the quotient waiting in S_FIN.
  logic fast_done;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                 fast_done <= 1'b0;
    else if (state == S_COR)    fast_done <= 1'b1;
    else if (state == S_RUN)    fast_done <= 1'b0;
  end

  always_comb ready = (state == S_IDLE);

endmodule
