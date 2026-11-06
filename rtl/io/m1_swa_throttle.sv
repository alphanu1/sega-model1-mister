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
// STAR WARS ARCADE'S THROTTLE (issue #7): MSM6253 channel 2, which the I/O
// firmware publishes at DPRAM 0x02. MAME 0.289: PORT_MINMAX(28,200),
// PORT_REVERSE, default 0x7f. Measured in MAME (headless, the field driven
// from lua, DPRAM read back through the V60's 0xc00004): released, MAME's
// pedal reads 0xc8 (200) there; driven to 28 it reads 0x1c; nothing else in
// DPRAM 0x00-0x07 moves. The pilot's bar on INPUT TEST 2/2 sits at FAST for
// 28 and at SLOW for 200. Nothing drove it here before: Model1.sv held 127.
//
// Two buttons move it like the cabinet's lever: Throttle Up toward 28
// (faster), Throttle Down toward 200, one count every STEP cycles while held,
// and it stays where it is let go. At 80 MHz and STEP = 2^19 a count is
// 6.55 ms, so the whole travel of 172 counts takes 1.13 s. It powers up at
// 127, the value this core always gave and MAME's port default.
//
// Or, with `stick`, the right stick's Y takes it: pushed fully up 28, fully
// down 200, centred 114. (The stick's dead band is the caller's.)

`timescale 1ns/1ps

module m1_swa_throttle #(
  parameter int unsigned STEP = 1 << 19
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        up,
  input  logic        dn,
  input  logic        stick,       // the OSD: the right stick's Y instead
  input  logic [7:0]  ry,          // the right stick's Y, signed, + is down
  output logic [7:0]  thr
);
  localparam int unsigned SW = $clog2(STEP);
  localparam logic [7:0] THR_FAST = 8'd28, THR_SLOW = 8'd200;

  logic [SW-1:0] div;
  logic [7:0]    lever;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div <= '0; lever <= 8'd127;
    end else begin
      div <= (up ^ dn) ? div + 1'b1 : '0;      // a press counts from zero
      if ((up ^ dn) && div == '0) begin
        if (up && lever > THR_FAST) lever <= lever - 8'd1;
        if (dn && lever < THR_SLOW) lever <= lever + 8'd1;
      end
    end
  end

  // 114 + ry * 86 / 128: -128 -> 28, +127 -> 199
  wire signed [15:0] sy = $signed(ry) * 16'sd86;
  wire        [7:0]  st = 8'(16'sd114 + (sy >>> 7));
  assign thr = stick ? st : lever;
endmodule
