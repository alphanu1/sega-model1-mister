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
// Reciprocal, for the perspective divide in m1_geo_project.
//
// WHY THIS EXISTS RATHER THAN A DIVIDE
//
// Projection needs 1/z per point. fp_div is 29 cycles and does not pipeline,
// and it was the largest single term inside projection in a pass that needed
// 316% of a frame - the reason the 3D drops objects on busy frames.
//
// The bench used to call that term "425% of a frame budget". It was not: its
// four inside-projection counters were never reset, so they covered the whole
// run while the denominator covered only the throughput loop. Fixed on
// 2026-09-08. The RATIOS were sound - all four shared the same wrong window -
// so the reciprocal really was the term to attack, and afterwards the same
// bench reads recip 11.2%, scale 47.0%, handover 6.4%, idle 34.3%. Treat any
// inside-projection percentage quoted from before that date as inflated.
//
// A SECOND DIVIDER DOES NOT FIX IT, measured twice. fp_div is only 263 ALM and
// the grant race that broke the first attempt is fixed, so it was retried:
// 543.2 -> 545.4 cycles per quad, slightly WORSE. The tell is `idle 545%`
// INSIDE projection - the unit is not queueing behind a busy divider, it is
// waiting on its own single reciprocal, because every point needs 1/z before
// its multiplies start. One request outstanding means the second divider idles.
// That is latency, not contention; more units help the one, only a faster
// operation helps the other.
//
// AND NEITHER DOES THE SHARED FP POOL. The first version of this module ran
// Newton's step on m1_fp_pool's float multiplier and adder. It was correct -
// 22.3 bits, 0.15% of points a pixel out - and it measured 21.0 cycles against
// fp_div's 29, a 27% cut where 3x was needed. Three round trips through an
// arbiter (request, grant, respond) cost more than the arithmetic does. That
// version is gone; the lesson is that on a latency problem the pool IS the
// latency.
//
// WHAT THIS DOES INSTEAD: FIXED POINT, IN DSPs, WITH NO ARBITER
//
// The Newton step r' = r * (2 - m*r) squares its own error. It only ever runs
// on the MANTISSA, which is a fixed-point value in [1,2) - so it needs two
// integer multiplies and a subtract, not floats. The exponent is handled by
// subtracting it, because 1/(m * 2^e) = (1/m) * 2^-e exactly.
//
// A 64-entry table seeds it to ~7 bits. Squaring twice gives 7 -> 14 -> 24,
// and a float32 mantissa only HAS 24 bits, so a bigger table cannot buy
// anything: it would start closer to an answer that is already exact. Every
// operand is 27 bits or fewer, which is one Cyclone V DSP per multiply.
//
//   latency    6 cycles, versus fp_div's 29
//   pipelined  a new reciprocal every cycle; fp_div takes none until it retires
//   cost       4 DSP, 64 x 27b of LUT ROM, no M10K
//   measured   543.2 -> 413.5 cycles a quad, 316% -> 243% of a peak frame
//
// PRECISION, MEASURED IN PIXELS AGAINST THE SAME CORPUS
//
// 4 million points, x in +/-4096, z over six decades, zoom 256, comparing
// floor(x * recip * zoom) against floor(x / z * zoom):
//
//     exact reciprocal, which is what ships today   0.1646% land a pixel out
//     64-entry seed + two Newton steps              0.1667%, never more than 1
//     64-entry seed + ONE Newton step              14%, up to 62 px - rejected
//
// The 0.078%/0.002% figures this header used to carry were taken over six
// FIXED zoom levels and flatter the exact divider; on the corpus above it
// measures 0.1646% itself. Compare the two rows, not one row against a number
// from another corpus - doing that made this look like a 100x regression when
// it is a 1.3% one. Recorded in docs/findings.md.
//
// Denormals, zero, infinity and NaN return zero. The caller guards z <= 0
// already; this keeps the unit total anyway.

`timescale 1ns/1ps

module m1_geo_recip (
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

  // Q26 seed for 1/m, m in [1,2), taken at the midpoint of each of 64 equal
  // intervals. The midpoint is the minimax constant for 1/x on an interval,
  // and at 64 entries it is worth ~7 bits - all Newton needs.
  localparam logic [26:0] SEED [0:63] = '{
    27'd66588640,   // 1/1.0078125
    27'd65572020,   // 1/1.0234375
    27'd64585974,   // 1/1.0390625
    27'd63629145,   // 1/1.0546875
    27'd62700252,   // 1/1.0703125
    27'd61798091,   // 1/1.0859375
    27'd60921522,   // 1/1.1015625
    27'd60069473,   // 1/1.1171875
    27'd59240928,   // 1/1.1328125
    27'd58434929,   // 1/1.1484375
    27'd57650568,   // 1/1.1640625
    27'd56886984,   // 1/1.1796875
    27'd56143363,   // 1/1.1953125
    27'd55418933,   // 1/1.2109375
    27'd54712959,   // 1/1.2265625
    27'd54024746,   // 1/1.2421875
    27'd53353631,   // 1/1.2578125
    27'd52698985,   // 1/1.2734375
    27'd52060210,   // 1/1.2890625
    27'd51436734,   // 1/1.3046875
    27'd50828015,   // 1/1.3203125
    27'd50233536,   // 1/1.3359375
    27'd49652801,   // 1/1.3515625
    27'd49085341,   // 1/1.3671875
    27'd48530704,   // 1/1.3828125
    27'd47988461,   // 1/1.3984375
    27'd47458202,   // 1/1.4140625
    27'd46939533,   // 1/1.4296875
    27'd46432079,   // 1/1.4453125
    27'd45935479,   // 1/1.4609375
    27'd45449389,   // 1/1.4765625
    27'd44973480,   // 1/1.4921875
    27'd44507433,   // 1/1.5078125
    27'd44050947,   // 1/1.5234375
    27'd43603729,   // 1/1.5390625
    27'd43165500,   // 1/1.5546875
    27'd42735993,   // 1/1.5703125
    27'd42314949,   // 1/1.5859375
    27'd41902120,   // 1/1.6015625
    27'd41497269,   // 1/1.6171875
    27'd41100166,   // 1/1.6328125
    27'd40710590,   // 1/1.6484375
    27'd40328331,   // 1/1.6640625
    27'd39953184,   // 1/1.6796875
    27'd39584952,   // 1/1.6953125
    27'd39223446,   // 1/1.7109375
    27'd38868482,   // 1/1.7265625
    27'd38519886,   // 1/1.7421875
    27'd38177487,   // 1/1.7578125
    27'd37841122,   // 1/1.7734375
    27'd37510631,   // 1/1.7890625
    27'd37185864,   // 1/1.8046875
    27'd36866672,   // 1/1.8203125
    27'd36552913,   // 1/1.8359375
    27'd36244450,   // 1/1.8515625
    27'd35941149,   // 1/1.8671875
    27'd35642882,   // 1/1.8828125
    27'd35349525,   // 1/1.8984375
    27'd35060958,   // 1/1.9140625
    27'd34777063,   // 1/1.9296875
    27'd34497729,   // 1/1.9453125
    27'd34222847,   // 1/1.9609375
    27'd33952311,   // 1/1.9765625
    27'd33686018   // 1/1.9921875
  };

  localparam logic [27:0] TWO_Q26 = 28'd1 << 27;   // 2.0 in Q26

  // ---------------------------------------------------------------- stage 1
  // Unpack. m is 1.mantissa as a 24-bit Q23 integer; the seed index is the top
  // six mantissa bits, which is exactly which of the 64 intervals m sits in.
  logic        v1, sx1, deg1;
  logic [7:0]  ex1;
  logic [23:0] m1;
  logic [26:0] r0_1;

  // ---------------------------------------------------------------- stage 2
  logic        v2, sx2, deg2;
  logic [7:0]  ex2;
  logic [23:0] m2;
  logic [26:0] r0_2;
  logic [50:0] p1;                  // m * r0

  // ---------------------------------------------------------------- stage 3
  logic        v3, sx3, deg3;
  logic [7:0]  ex3;
  logic [23:0] m3;
  logic [53:0] p2;                  // r0 * (2 - m*r0)

  // ---------------------------------------------------------------- stage 4
  logic        v4, sx4, deg4;
  logic [7:0]  ex4;
  logic [26:0] r1_4;
  logic [50:0] p3;                  // m * r1

  // ---------------------------------------------------------------- stage 5
  logic        v5, sx5, deg5;
  logic [7:0]  ex5;
  logic [53:0] p4;                  // r1 * (2 - m*r1)

  // Newton, twice. Each stage shifts the previous product back to Q26, forms
  // 2 - t, and feeds the subtract straight into the next multiply's input
  // register - so the DSP absorbs it and it costs no cycle of its own.
  wire [27:0] t1 = p1[50:23];
  wire [26:0] h1 = 27'(TWO_Q26 - t1);
  wire [26:0] r1 = p2[52:26];
  wire [27:0] t2 = p3[50:23];
  wire [26:0] h2 = 27'(TWO_Q26 - t2);
  wire [26:0] r2 = p4[52:26];

  // ------------------------------------------------------------ normalise
  // r2 is Q26 in (0.5,1], so its leading one is bit 25 - or bit 26 when m was
  // an exact power of two and the reciprocal is 1.0.
  //   1/z = (1/m) * 2^-(ex-127), so the biased exponent is 254 - ex, less one
  //   for the leading bit sitting at 25 rather than 26.
  wire        top   = r2[26];
  wire [23:0] mr    = top ? 24'd0 : ({1'b0, r2[24:2]} + 24'(r2[1]));  // round to nearest
  wire [9:0]  e_pre = (top ? 10'd254 : 10'd253) - {2'd0, ex5};
  wire [9:0]  e_fin = e_pre + 10'(mr[23]);          // rounding carried into 1.0
  wire [22:0] m_fin = mr[23] ? 23'd0 : mr[22:0];
  // ex >= 253 puts the result below the smallest normal; there is no denormal
  // path here and the caller cannot use one, so it flushes to zero.
  wire        under = e_fin[9] || (e_fin[8:0] == 9'd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; v4 <= 1'b0; v5 <= 1'b0;
      sx1 <= 1'b0; sx2 <= 1'b0; sx3 <= 1'b0; sx4 <= 1'b0; sx5 <= 1'b0;
      deg1 <= 1'b0; deg2 <= 1'b0; deg3 <= 1'b0; deg4 <= 1'b0; deg5 <= 1'b0;
      ex1 <= '0; ex2 <= '0; ex3 <= '0; ex4 <= '0; ex5 <= '0;
      m1 <= '0; m2 <= '0; m3 <= '0; r0_1 <= '0; r0_2 <= '0; r1_4 <= '0;
      p1 <= '0; p2 <= '0; p3 <= '0; p4 <= '0;
      out_valid <= 1'b0; out_y <= '0;
    end else begin
      v1   <= in_valid;
      sx1  <= in_x[31];
      ex1  <= in_x[30:23];
      m1   <= {1'b1, in_x[22:0]};
      deg1 <= (in_x[30:23] == 8'd0) || (in_x[30:23] == 8'hff);
      r0_1 <= SEED[in_x[22:17]];

      v2 <= v1; sx2 <= sx1; deg2 <= deg1; ex2 <= ex1; m2 <= m1; r0_2 <= r0_1;
      p1 <= m1 * r0_1;

      v3 <= v2; sx3 <= sx2; deg3 <= deg2; ex3 <= ex2; m3 <= m2;
      p2 <= r0_2 * h1;

      v4 <= v3; sx4 <= sx3; deg4 <= deg3; ex4 <= ex3; r1_4 <= r1;
      p3 <= m3 * r1;

      v5 <= v4; sx5 <= sx4; deg5 <= deg4; ex5 <= ex4;
      p4 <= r1_4 * h2;

      out_valid <= v5;
      out_y     <= (deg5 || under) ? 32'd0 : {sx5, e_fin[7:0], m_fin};
    end
  end

endmodule
