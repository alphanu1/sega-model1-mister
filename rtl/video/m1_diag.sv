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
// Debug words painted over the picture as HEX DIGITS, readable off a photograph.
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
// WHY DIGITS AND NOT BLOCKS
//
// The first version drew each word as 32 blocks, one per bit, with a green rule
// every four so hex could be counted off the photo. It worked, and it found two
// real faults. But reading it means locating a cell boundary to a few pixels in
// a photograph of a screen, and a phone camera against an LCD adds moiré that
// lands exactly on an 8-pixel pitch. Three values were misread that way over one
// session, twice sending the next experiment after the wrong subsystem.
//
// An instrument that is hard to read is a source of wrong answers, not a
// defence against them. So the same words are drawn as eight hex digits in a
// 5x7 font, which a camera resolves unambiguously and a human reads without
// counting anything.
//
// GEOMETRY
//
// Glyphs are 8x8 in the font and drawn at 2x, so each digit is a 16x16 cell and
// a row of eight digits is 128 pixels. Both are powers of two: the digit index
// and the pixel within it come out as bit slices rather than dividers, which
// keeps this off the critical path of a design already fighting for Fmax.
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
  parameter int unsigned NWORDS = 12
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

  localparam int unsigned CELL_W = 16;   // 8 font columns at 2x
  localparam int unsigned CELL_H = 16;   // 8 font rows at 2x
  localparam int unsigned BOX_W  = 8 * CELL_W;        // eight hex digits
  localparam int unsigned BOX_H  = NWORDS * CELL_H;

  // 5x7 hex digits in an 8x8 box, most significant bit leftmost. Written out
  // rather than generated: sixteen glyphs is small enough to read, and a
  // generated font is one more thing that can be subtly wrong in a tool whose
  // whole job is to be trusted.
  function automatic logic [7:0] glyph(input logic [3:0] d, input logic [2:0] r);
    logic [7:0] g;
    begin
      g = 8'h00;
      case (d)
        4'h0: case (r) 0: g=8'h7C; 1: g=8'hC6; 2: g=8'hCE; 3: g=8'hD6;
                       4: g=8'hE6; 5: g=8'hC6; 6: g=8'h7C; default: g=8'h00; endcase
        4'h1: case (r) 0: g=8'h18; 1: g=8'h38; 2: g=8'h18; 3: g=8'h18;
                       4: g=8'h18; 5: g=8'h18; 6: g=8'h7E; default: g=8'h00; endcase
        4'h2: case (r) 0: g=8'h7C; 1: g=8'hC6; 2: g=8'h06; 3: g=8'h1C;
                       4: g=8'h30; 5: g=8'h60; 6: g=8'hFE; default: g=8'h00; endcase
        4'h3: case (r) 0: g=8'h7C; 1: g=8'hC6; 2: g=8'h06; 3: g=8'h3C;
                       4: g=8'h06; 5: g=8'hC6; 6: g=8'h7C; default: g=8'h00; endcase
        4'h4: case (r) 0: g=8'h0C; 1: g=8'h1C; 2: g=8'h3C; 3: g=8'h6C;
                       4: g=8'hFE; 5: g=8'h0C; 6: g=8'h0C; default: g=8'h00; endcase
        4'h5: case (r) 0: g=8'hFE; 1: g=8'hC0; 2: g=8'hFC; 3: g=8'h06;
                       4: g=8'h06; 5: g=8'hC6; 6: g=8'h7C; default: g=8'h00; endcase
        4'h6: case (r) 0: g=8'h3C; 1: g=8'h60; 2: g=8'hC0; 3: g=8'hFC;
                       4: g=8'hC6; 5: g=8'hC6; 6: g=8'h7C; default: g=8'h00; endcase
        4'h7: case (r) 0: g=8'hFE; 1: g=8'hC6; 2: g=8'h0C; 3: g=8'h18;
                       4: g=8'h30; 5: g=8'h30; 6: g=8'h30; default: g=8'h00; endcase
        4'h8: case (r) 0: g=8'h7C; 1: g=8'hC6; 2: g=8'hC6; 3: g=8'h7C;
                       4: g=8'hC6; 5: g=8'hC6; 6: g=8'h7C; default: g=8'h00; endcase
        4'h9: case (r) 0: g=8'h7C; 1: g=8'hC6; 2: g=8'hC6; 3: g=8'h7E;
                       4: g=8'h06; 5: g=8'h0C; 6: g=8'h78; default: g=8'h00; endcase
        4'hA: case (r) 0: g=8'h38; 1: g=8'h6C; 2: g=8'hC6; 3: g=8'hC6;
                       4: g=8'hFE; 5: g=8'hC6; 6: g=8'hC6; default: g=8'h00; endcase
        4'hB: case (r) 0: g=8'hFC; 1: g=8'h66; 2: g=8'h66; 3: g=8'h7C;
                       4: g=8'h66; 5: g=8'h66; 6: g=8'hFC; default: g=8'h00; endcase
        4'hC: case (r) 0: g=8'h3C; 1: g=8'h66; 2: g=8'hC0; 3: g=8'hC0;
                       4: g=8'hC0; 5: g=8'h66; 6: g=8'h3C; default: g=8'h00; endcase
        4'hD: case (r) 0: g=8'hF8; 1: g=8'h6C; 2: g=8'h66; 3: g=8'h66;
                       4: g=8'h66; 5: g=8'h6C; 6: g=8'hF8; default: g=8'h00; endcase
        4'hE: case (r) 0: g=8'hFE; 1: g=8'h62; 2: g=8'h68; 3: g=8'h78;
                       4: g=8'h68; 5: g=8'h62; 6: g=8'hFE; default: g=8'h00; endcase
        default: case (r) 0: g=8'hFE; 1: g=8'h62; 2: g=8'h68; 3: g=8'h78;
                          4: g=8'h68; 5: g=8'h60; 6: g=8'hF0; default: g=8'h00; endcase
      endcase
      glyph = g;
    end
  endfunction

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
      if (vb)               y <= '0;
      else if (hb && !hb_d) y <= y + 10'd1;
    end
  end

  // ------------------------------------------------------------------- draw
  logic in_box;
  assign in_box = enable && !hb && !vb
                && (x < 10'(BOX_W)) && (y < 10'(BOX_H));

  logic [2:0] digit;                     // 0..7, digit 0 leftmost
  logic [3:0] row;
  logic [2:0] fx, fy;                    // pixel within the glyph, after 2x
  assign digit = x[6:4];
  assign row   = y[7:4];
  assign fx    = x[3:1];
  assign fy    = y[3:1];

  logic [3:0]  nib;
  logic [31:0] wsel;
  always_comb begin
    wsel = '0;
    for (int w = 0; w < NWORDS; w++)
      if (row == 4'(w)) wsel = words[w*32 +: 32];
    // Digit 0 is the most significant nibble, so the word reads left to right
    // as it would be written down.
    nib = wsel[(7 - int'(digit))*4 +: 4];
  end

  // The glyph row goes through a wire before being indexed. Quartus 17.0
  // rejects a bit select applied straight to a function call —
  // `glyph(nib, fy)[7 - fx]` — with a syntax error, the same toolchain
  // strictness that makes it reject a genvar declared in a for-loop header.
  // Both forms pass lint here and only fail after twenty minutes of synthesis,
  // which is the expensive way to find a syntax error. See
  // docs/rtl-conventions.md.
  logic [7:0] grow;
  logic       lit;
  assign grow = glyph(nib, fy);
  assign lit  = grow[7 - fx];

  always_comb begin
    out_r = in_r;
    out_g = in_g;
    out_b = in_b;
    if (in_box) begin
      if (lit) begin
        out_r = 8'hFF; out_g = 8'hFF; out_b = 8'hFF;
      end else begin
        // A dark backing so the digits stay legible over whatever the game is
        // drawing, rather than white-on-white the moment a bright screen
        // appears underneath them.
        out_r = 8'h00; out_g = 8'h00; out_b = 8'h50;
      end
    end
  end

endmodule
