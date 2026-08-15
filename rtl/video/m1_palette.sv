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
// Palette entry to RGB888, from model1_paletteram_w in model1_v.cpp.
//
//   r = pal5bit((v >> 0)  & 0x1f)
//   g = pal5bit((v >> 5)  & 0x1f)
//   b = pal5bit((v >> 10) & 0x1f)
//   if (!BIT(v, 15)) { r >>= 1; g >>= 1; b >>= 1; }
//
// BIT 15 IS INTENSITY, NOT PADDING
//
// The layout looks like plain xBGR-555 with a spare top bit, and MAME's own
// comment records that reading it that way is wrong:
//
//   "Bit 15 is an intensity/shade bit, not unused as the plain xBGR_555 decode
//    assumes. Almost every entry has it set (full brightness); a handful clear
//    it to render dimmed (e.g. Star Wars Arcade's grey menu backdrop pen
//    0x7777). Halve the channels when it is clear so those pens stop reading
//    too bright."
//
// That is a fix somebody made after seeing a specific game look wrong, and it
// is invisible in almost all content — "almost every entry has it set" — so a
// core that drops it looks correct until one screen in one game is too bright.
// Reproduced rather than simplified, per hard rule 4.
//
// pal5bit is MAME's 5-to-8 expansion: (x << 3) | (x >> 2), which replicates the
// top bits into the low ones so 0x1f maps to 0xff rather than 0xf8.

`timescale 1ns/1ps

module m1_palette (
  input  logic [15:0] entry,
  output logic [7:0]  r,
  output logic [7:0]  g,
  output logic [7:0]  b
);

  logic [4:0] r5, g5, b5;
  logic [7:0] r8, g8, b8;

  assign r5 = entry[4:0];
  assign g5 = entry[9:5];
  assign b5 = entry[14:10];

  // pal5bit
  assign r8 = {r5, r5[4:2]};
  assign g8 = {g5, g5[4:2]};
  assign b8 = {b5, b5[4:2]};

  // Dim when the intensity bit is clear. MAME halves the already-expanded
  // 8-bit value, so the shift happens after the expansion and not before —
  // halving the 5-bit field first would give a different answer.
  assign r = entry[15] ? r8 : {1'b0, r8[7:1]};
  assign g = entry[15] ? g8 : {1'b0, g8[7:1]};
  assign b = entry[15] ? b8 : {1'b0, b8[7:1]};

endmodule
