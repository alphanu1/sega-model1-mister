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
// Reciprocal square root, for normalizing the polygon normal.
//
// WHY THIS EXISTS RATHER THAN A DIVIDE
//
// push_object normalizes the normal of every polygon record (glm::normalize, and
// glm computes it as v * inversesqrt(dot(v,v))). That is a reciprocal square root
// once per record. fp_div is 29 cycles and does not pipeline, and there is no
// square root unit to build it out of anyway.
//
// THE PRECISION REQUIREMENT IS LOW, AND IT WAS MEASURED
//
// The normalized normal feeds a dot product, then a specular term, then
//
//     lumval = (255 * min(1, ln)) >> 2, clamped to 0x3f
//
// which is SIX BITS. Over 400,000 random normals against the light parameters
// measured from the real display list, truncating the reciprocal square root's
// mantissa changes that six-bit luminance:
//
//     10 bits   0.776% of polygons, by up to 2 levels
//     12 bits   0.190%, by at most 1
//     16 bits   0.013%, by at most 1
//     23 bits   never
//
// Specular squares its argument up to three times, so it amplifies error
// eightfold and is the path that sets this requirement - the diffuse term alone
// would be satisfied by ten bits. Sixteen is comfortably past it.
//
// SO: a small seed table and TWO Newton-Raphson steps.
//
//     y' = y * (1.5 - (x/2) * y * y)
//
// ONE STEP IS NOT ENOUGH, AND THE UNIT TEST DOES NOT SHOW IT. A single step
// from a 128-entry seed reaches 17.4 bits, whose worst relative error is
// 5.68e-06 - slightly BETTER than the pool version it replaced, and it passed
// this module's own 30,186 checks. It still changed the picture: 123 of 15,688
// real-model polygons came out one luminance level different, because luminance
// is six bits and an error of the same SIZE in a different DIRECTION lands on
// the other side of a quantisation boundary. Accuracy that passes a tolerance
// is not the same as accuracy that reproduces the reference.
//
// Two steps reach 24.5 bits, which is past the 23 in the table above where the
// luminance never moves at all, and the real-model colours are exact again.
// Newton squares its error, so the seed can be SMALLER with two steps than with
// one: 6 bits -> 12 -> 24. Thirty-two entries per parity is enough and the
// table shrinks from 5.8 Kbit to 1.7 Kbit.
//
// THE POOL WAS THE LATENCY. THIS USED TO RUN ON IT.
//
// The note here used to read "four multiplies and one subtract on the SHARED
// pool - about 5 cycles of a multiplier that is at 69%". Five cycles is the
// MULTIPLIER'S OCCUPANCY. End to end it measured **27.0 cycles per record**,
// because each of those operations is a separate round trip through an arbiter:
// request, wait for grant, wait for the result to come back.
//
// The identical mistake was made in m1_geo_project's reciprocal and corrected
// on 2026-09-08; this is the same fix, for the same reason, and it matters more
// here because `normalize -> colour` is the longest pole in a record now that
// projection is not.
//
// WHAT IT DOES INSTEAD: FIXED POINT, IN DSPs, WITH NO ARBITER
//
// Newton's step runs on the MANTISSA, which is fixed point, so it is three
// integer multiplies and a subtract. The exponent is handled by halving it,
// which is why the seed table is indexed by the exponent's PARITY as well as
// the mantissa: 1/sqrt(m * 2^E) = (1/sqrt(m * 2^p)) * 2^-k for E = 2k + p, and
// the table therefore covers u in [1,4) rather than [1,2).
//
//   latency    8 cycles, versus 27 through the pool
//   pipelined  a new result every cycle
//   cost       6 DSP, 2 x 32 x 27b of LUT ROM, no M10K
//
// Denormal and zero inputs are not handled: dot(v,v) for a polygon normal is a
// sum of three squares and cannot be zero for a real normal. That contract is
// unchanged from the pool version.

`timescale 1ns/1ps

module m1_geo_rsqrt (
  input  logic        clk,
  input  logic        rst_n,

  // Fully pipelined: in_ready is tied high and exists only so the caller's
  // handshake does not have to change.
  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] in_x,

  output logic        out_valid,
  output logic [31:0] out_y
);

  assign in_ready = 1'b1;

  // Q26 seed for 1/sqrt(u) at the midpoint of each of 32 equal intervals, for
  // u in [1,2) and again for u in [2,4). The midpoint is the minimax constant
  // on an interval; 32 entries is worth ~6 bits, and two Newton steps square
  // that twice to 24.
  localparam logic [26:0] SEED [0:63] = '{
    27'd66590641,   // 1 <= u < 2
    27'd65589221,
    27'd64631663,
    27'd63714855,
    27'd62835987,
    27'd61992513,
    27'd61182119,
    27'd60402697,
    27'd59652324,
    27'd58929238,
    27'd58231826,
    27'd57558603,
    27'd56908203,
    27'd56279364,
    27'd55670920,
    27'd55081793,
    27'd54510982,
    27'd53957557,
    27'd53420652,
    27'd52899463,
    27'd52393236,
    27'd51901270,
    27'd51422907,
    27'd50957532,
    27'd50504567,
    27'd50063471,
    27'd49633733,
    27'd49214876,
    27'd48806447,
    27'd48408020,
    27'd48019194,
    27'd47639590,
    27'd47086694,   // 2 <= u < 4
    27'd46378583,
    27'd45701487,
    27'd45053206,
    27'd44431753,
    27'd43835326,
    27'd43262291,
    27'd42711156,
    27'd42180562,
    27'd41669264,
    27'd41176119,
    27'd40700079,
    27'd40240176,
    27'd39795520,
    27'd39365285,
    27'd38948710,
    27'd38545085,
    27'd38153754,
    27'd37774106,
    27'd37405569,
    27'd37047613,
    27'd36699740,
    27'd36361486,
    27'd36032416,
    27'd35712122,
    27'd35400220,
    27'd35096349,
    27'd34800172,
    27'd34511369,
    27'd34229639,
    27'd33954698,
    27'd33686277
  };

  localparam logic [27:0] ONE5_Q26 = 28'd3 << 25;    // 1.5 in Q26

  // E = e - 127 = 2k + p. The parity of E is the low bit of e inverted, and k
  // is the arithmetic halving of E - p. u = 1.mantissa scaled by 2^p, so u/2 in
  // Q24 is exactly the 24-bit mantissa shifted left by p.
  wire        par = ~in_x[23];
  wire signed [10:0] ee = $signed({3'b000, in_x[30:23]}) - 11'sd127;
  wire signed [10:0] pp = $signed({10'd0, par});
  wire signed [10:0] kk = (ee - pp) >>> 1;

  // DELAY LINES, because a product lands a cycle after its operands and each
  // Newton step therefore meets its own multiplicand three cycles downstream.
  // ra must reach h1 and rb must reach h2; pairing either with a fresher copy
  // multiplies one point's seed by another point's correction.
  logic        v [0:6];
  logic signed [10:0] kq [0:6];
  logic [25:0] uh [0:4];
  logic [26:0] ra [0:2];            // the seed, aligned to h1
  logic [26:0] rb [0:1];            // the first step's result, aligned to h2
  logic [53:0] p1, p3, p4, p6;      // r*r and r*h, both 27x27
  logic [52:0] p2, p5;              // (r*r) * u/2, 27x26

  // Each stage shifts the previous product back to its Q, forms 1.5 - t, and
  // feeds that straight into the next multiply's input register, so the DSP
  // absorbs the subtract and it costs no cycle of its own.
  wire [26:0] s1 = p1[52:26];
  wire [28:0] t1 = p2[52:24];
  wire [26:0] h1 = 27'(29'(ONE5_Q26) - t1);
  wire [26:0] r1 = p3[52:26];
  wire [26:0] s2 = p4[52:26];
  wire [28:0] t2 = p5[52:24];
  wire [26:0] h2 = 27'(29'(ONE5_Q26) - t2);
  wire [26:0] r2 = p6[52:26];

  // ------------------------------------------------------------ normalise
  // r2 is Q26 in (0.5,1], so its leading one is bit 25 - or bit 26 when u was
  // an exact power of four and the result is 1.0. 1/sqrt(x) = r2 * 2^-k, so the
  // biased exponent is 127 - k, less one for the leading bit sitting at 25.
  wire        rtop  = r2[26];
  wire [23:0] mr    = rtop ? 24'd0 : ({1'b0, r2[24:2]} + 24'(r2[1]));
  wire signed [11:0] e_pre = (rtop ? 12'sd127 : 12'sd126) - 12'(kq[6]);
  wire signed [11:0] e_fin = e_pre + 12'(mr[23]);     // rounding carried into 1.0
  wire [22:0] m_fin = mr[23] ? 23'd0 : mr[22:0];
  wire        e_bad = (e_fin <= 12'sd0) || (e_fin >= 12'sd255);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 7; i++) begin v[i] <= 1'b0; kq[i] <= '0; end
      for (int i = 0; i < 5; i++) uh[i] <= '0;
      for (int i = 0; i < 3; i++) ra[i] <= '0;
      for (int i = 0; i < 2; i++) rb[i] <= '0;
      p1 <= '0; p2 <= '0; p3 <= '0; p4 <= '0; p5 <= '0; p6 <= '0;
      out_valid <= 1'b0; out_y <= '0;
    end else begin
      v[0]  <= in_valid;
      kq[0] <= kk;
      uh[0] <= 26'({1'b0, 1'b1, in_x[22:0]} << par);   // u/2 in Q24
      ra[0] <= SEED[{par, in_x[22:18]}];

      for (int i = 1; i < 7; i++) begin v[i] <= v[i-1]; kq[i] <= kq[i-1]; end
      for (int i = 1; i < 5; i++) uh[i] <= uh[i-1];
      for (int i = 1; i < 3; i++) ra[i] <= ra[i-1];
      rb[1] <= rb[0];

      // -------- Newton, first pass
      p1 <= ra[0] * ra[0];
      p2 <= s1 * uh[1];
      p3 <= ra[2] * h1;
      // -------- and second, on its result
      rb[0] <= r1;
      p4 <= r1 * r1;
      p5 <= s2 * uh[4];
      p6 <= rb[1] * h2;

      out_valid <= v[6];
      out_y     <= e_bad ? 32'd0 : {1'b0, e_fin[7:0], m_fin};
    end
  end

endmodule
