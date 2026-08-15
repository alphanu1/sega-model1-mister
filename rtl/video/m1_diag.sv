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
// Debug words painted over the picture, readable off a photograph.
//
// WHY THIS EXISTS
//
// A core on a bench has one output channel. When the board showed a solid white
// raster the simulator was showing the game's test-mode screen from the same
// RTL and the same ROM, so every remaining hypothesis was about something
// simulation cannot model — SDRAM on real silicon, the ROM arriving over ioctl,
// pin timing — and each one cost a twenty-five minute Quartus build to test,
// answered only by "still white".
//
// This turns the screen into an instrument. Six 32-bit words are drawn as a
// grid of blocks at the top left: white block for a one, dark blue for a zero,
// a green rule every four bits so hex digits can be counted off a phone photo.
// Where the CPU is, what the last character fetch returned, how many words the
// loader actually wrote — all of it legible without a probe.
//
// GEOMETRY
//
// Cells are 8 wide and 16 tall, so 32 bits is 256 pixels across and a word is
// one 16-pixel row. Both are powers of two: the row and column come out as bit
// slices rather than dividers, which keeps this off the critical path of a
// design that is already fighting for Fmax.
//
// POSITION IS RECOVERED FROM BLANKING, NOT PASSED IN
//
// The counters could come from m1_video_timing, which has them. They are
// rebuilt here from hb/vb instead so this can sit at the top level between the
// core and the framework's video ports, on the finished pixel stream, without
// the video path knowing it exists. An instrument that requires modifying the
// thing it measures is worth less.

`timescale 1ns/1ps

module m1_diag #(
  parameter int unsigned NWORDS = 6
) (
  input  logic        clk,
  input  logic        ce_pix,
  input  logic        rst_n,

  input  logic        enable,

  // Blanking from the video path, on the same pixel clock as the colour.
  input  logic        hb,
  input  logic        vb,

  // The words to draw, word 0 on the top row. Packed rather than an unpacked
  // array so the port survives both Quartus 17.0 and Verilator without
  // argument about array ports.
  input  logic [NWORDS*32-1:0] words,

  input  logic [7:0]  in_r,
  input  logic [7:0]  in_g,
  input  logic [7:0]  in_b,

  output logic [7:0]  out_r,
  output logic [7:0]  out_g,
  output logic [7:0]  out_b
);

  localparam int unsigned CELL_W = 8;    // 3 bits
  localparam int unsigned CELL_H = 16;   // 4 bits
  localparam int unsigned BOX_W  = 32 * CELL_W;
  localparam int unsigned BOX_H  = NWORDS * CELL_H;

  // ---------------------------------------------------------------- position
  logic [9:0] x, y;
  logic       hb_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      x <= '0; y <= '0; hb_d <= 1'b1;
    end else if (ce_pix) begin
      hb_d <= hb;

      // x counts visible pixels from the left edge of the line.
      if (hb) x <= '0;
      else    x <= x + 10'd1;

      // y counts completed visible lines. Advancing it on the START of
      // horizontal blanking rather than its end means the count is already
      // correct when the next line's first pixel arrives; incrementing at the
      // end puts every row of the overlay one line late, which is invisible
      // here and would not be in a comparison against a reference image.
      if (vb)              y <= '0;
      else if (hb && !hb_d) y <= y + 10'd1;
    end
  end

  // ------------------------------------------------------------------- draw
  logic in_box;
  assign in_box = enable && !hb && !vb
                && (x < 10'(BOX_W)) && (y < 10'(BOX_H));

  logic [4:0] col;                       // 0..31, bit 31 leftmost
  logic [3:0] row;
  assign col = x[7:3];
  assign row = y[7:4];

  logic bit_set;
  always_comb begin
    bit_set = 1'b0;
    for (int w = 0; w < NWORDS; w++)
      if (row == 4'(w))
        // Word w occupies bits [w*32 +: 32]; column 0 shows bit 31, so the
        // word reads left to right as it would be written down.
        bit_set = words[w*32 + (31 - int'(col))];
  end

  // A green rule down the left edge of every fourth cell. Reading 32 loose
  // blocks off a photograph is error prone; reading eight groups of four is
  // not, and the groups are hex digits.
  logic nibble_rule;
  assign nibble_rule = (col[1:0] == 2'd0) && (x[2:0] == 3'd0);

  // The bottom line of each row is left black so adjacent words do not merge
  // into one block of colour.
  logic row_gap;
  assign row_gap = (y[3:0] == 4'd15);

  always_comb begin
    out_r = in_r;
    out_g = in_g;
    out_b = in_b;
    if (in_box) begin
      if (row_gap) begin
        out_r = 8'h00; out_g = 8'h00; out_b = 8'h00;
      end else if (nibble_rule) begin
        out_r = 8'h00; out_g = 8'hC0; out_b = 8'h00;
      end else if (bit_set) begin
        out_r = 8'hFF; out_g = 8'hFF; out_b = 8'hFF;
      end else begin
        out_r = 8'h00; out_g = 8'h00; out_b = 8'h50;
      end
    end
  end

endmodule
