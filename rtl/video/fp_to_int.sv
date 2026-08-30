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
// IEEE-754 single to int32, truncating toward zero - the conversion that turns a
// projected coordinate into a pixel.
//
// THE OUT-OF-RANGE RESULT IS INT32_MIN, AND THAT IS DELIBERATE.
//
// MAME assigns a float straight into `spoint_t`'s int members, so the behaviour
// that reaches the rasterizer is the host's. On x86 `cvttss2si` returns
// 0x80000000 - "integer indefinite" - for a NaN, an infinity, or any magnitude
// too large for the type, rather than saturating. MAME's own comment on
// draw_wireframe_line says so outright: "a degenerate projection yields inf/NaN,
// which float->int conversion turns into INT32_MIN on x86 hosts", and it clips
// the line precisely because that value arrives. Saturating instead would be the
// tidier arithmetic and the wrong picture: a vertex that MAME throws to the far
// left would sit on the right-hand edge.
//
// Hard rule 4 - reproduce the quirk, comment why, move on.
//
// Combinational: a shift and a negate. The caller registers it.

`timescale 1ns/1ps

module fp_to_int (
  input  logic [31:0]        f,
  output logic signed [31:0] i
);

  wire               sign = f[31];
  wire [7:0]         exp  = f[30:23];
  wire [22:0]        mant = f[22:0];

  // The implicit leading one. Denormals never reach the `e >= 0` path below - a
  // denormal is smaller than 1 and truncates to zero - so restoring the hidden
  // bit unconditionally is safe here.
  wire [23:0]        mag  = {1'b1, mant};
  wire signed [9:0]  e    = $signed({2'b0, exp}) - 10'sd127;

  // Shifted magnitude. e is at most 30 on this path, so mag << 7 is 31 bits and
  // always fits a positive int32.
  wire [30:0] up   = 31'(mag) << (e[4:0] - 5'd23);
  wire [30:0] down = 31'(31'(mag) >> (5'd23 - e[4:0]));
  wire [30:0] shifted = (e >= 10'sd23) ? up : down;

  always_comb begin
    if (exp == 8'hff) begin
      i = 32'sh80000000;                       // NaN or infinity
    end else if (e < 10'sd0) begin
      i = 32'sd0;                              // |value| < 1, and every denormal
    end else if (e > 10'sd30) begin
      // Too large for int32. -2^31 lands here too and INT32_MIN is also its
      // correct value, so the one representable boundary case needs no branch.
      i = 32'sh80000000;
    end else begin
      i = sign ? -$signed({1'b0, shifted}) : $signed({1'b0, shifted});
    end
  end

endmodule
