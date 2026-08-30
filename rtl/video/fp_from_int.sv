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
// Signed 16-bit integer to IEEE-754 single. The inverse of fp_to_int, and needed
// because the display list gives the viewport centre as two 16-bit words while
// the projection multiplies them as floats - MAME writes `float xc =
// readi16(...)` and lets the compiler convert.
//
// EXACT, ALWAYS, AND THAT IS WORTH STATING. A float has a 24-bit significand and
// the input is 16 bits, so every value from -32768 to 32767 is representable with
// no rounding at all. There is no rounding mode to get wrong here and no
// tolerance to argue about: the bench checks all 65,536 inputs against the host
// and expects exact equality on every one.
//
// Combinational: a leading-one search, a shift and an exponent. The caller
// registers it.

`timescale 1ns/1ps

module fp_from_int (
  input  logic signed [15:0] i,
  output logic [31:0]        f
);

  // The magnitude needs SEVENTEEN bits, because -32768 negates to 32768 and that
  // does not fit in sixteen. Dropping the extra bit turns the most negative
  // input into zero, which is a silent wrong answer at exactly one value - the
  // kind that a fuzz over "typical" numbers never reaches.
  // NEGATE IN SIXTEEN BITS, THEN WIDEN - not the other way round. Complementing
  // the zero-extended value inverts the padding bit too, so -1 comes out as
  // 0x10001 rather than 1 and every negative input is wrong by a huge margin.
  // -32768 still works: its 16-bit negation is 0x8000, whose UNSIGNED value is
  // exactly the 32768 wanted, which is why the magnitude is 17 bits wide.
  wire [15:0] neg = (~i) + 16'd1;
  wire [16:0] mag = i[15] ? {1'b0, neg} : {1'b0, i};

  // Position of the highest set bit, 0..16.
  logic [4:0] msb;
  always_comb begin
    msb = 5'd0;
    for (int b = 0; b < 17; b++) if (mag[b]) msb = 5'(b);
  end

  // Shift the magnitude so its leading one sits at bit 23, then drop that bit -
  // it is the implicit one.
  wire [39:0] shifted = {23'd0, mag} << (5'd23 - msb);

  always_comb begin
    if (mag == 17'd0) f = 32'd0;
    else              f = {i[15], 8'(8'd127 + {3'd0, msb}), shifted[22:0]};
  end

endmodule
