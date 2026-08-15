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
// 315-5292 tilemap decode datapath — the pure function from a screen position
// to a palette index.
//
// Model 1 reuses System 24's tilemap chip. Olivier Galibert's note in MAME's
// segaic24.cpp says why: "The tilemap chip has been reused for model1 and
// model2, probably because they had it handy and it handles medium res." So
// the reference is segaic24.cpp, and the layer names below (0s, 0w, 1s, 1w)
// are its.
//
// This block is deliberately only the decode: screen position and scroll in,
// addresses out, fetched words in, palette index out. The SDRAM fetch
// scheduling that feeds it is separate, because the bugs here are bit-packing
// bugs and they are worth isolating where they can be fuzzed as a pure
// function against MAME's own layout description.
//
// THE 4BPP PACKING, AND WHY IT LOOKS TOO TIDY
//
// MAME describes the character layout as
//
//   8, 8, SYS24_TILES, 4, {0,1,2,3}, {STEP8(0,4)}, {STEP8(0,32)}, 8*32
//
// which is 8x8, 4 bits per pixel, pixels every 4 bits, rows every 32 bits, 32
// bytes per tile — with bit addresses running MSB-first over a byte array.
// Taken literally that gives an awkward mapping, because char_ram is a 16-bit
// array being addressed as bytes.
//
// The resolution is the xormask in device_start:
//
//   set_gfx(..., (uint8_t *)char_ram.get(), NATIVE_ENDIAN_VALUE_LE_BE(8,0), ...)
//
// On a little-endian host that xormask is 8, which flips bit 3 of every bit
// address — swapping the two bytes inside each 16-bit word. That is not a
// graphics decision, it is undoing the host's byte order so the layout matches
// the hardware. Applying it, pixel p of a row lands at:
//
//   word   = p >> 2          (two 16-bit words per 8-pixel row)
//   nibble = p & 3, MSB first
//
// so pixels 0..3 are the nibbles of the first word from the top down, and 4..7
// the same of the second. Reproducing MAME's byte-level formula and forgetting
// the xormask gives a plausible image with pairs of pixels transposed, which
// reads as a corrupt font rather than as an endianness bug.

`timescale 1ns/1ps

module m1_tile_decode (
  // Screen position, 512x512 map space.
  input  logic [8:0]  x,
  input  logic [8:0]  y,

  // Which of the four tilemap layers: 0s, 0w, 1s, 1w.
  input  logic [1:0]  layer,

  // Scroll registers, from tile RAM 0x5000 / 0x5004.
  input  logic [15:0] hscr,
  input  logic [15:0] vscr,

  // Fetched data. tile_word comes from tile RAM at tile_addr; char_w0/w1 come
  // from character RAM at char_addr and char_addr+1.
  input  logic [15:0] tile_word,
  input  logic [15:0] char_w0,
  input  logic [15:0] char_w1,

  // Tile index mask. Model 1 instantiates S24TILE with 0x3fff.
  input  logic [13:0] tile_mask,

  output logic [14:0] tile_addr,
  output logic [17:0] char_addr,

  output logic [11:0] pal_index,   // colour<<4 | pixel
  output logic [3:0]  pixel,
  output logic        prio,        // MAME's tile "category"
  output logic        transparent, // pen 0 is transparent on every layer
  output logic        disabled     // layer switched off
);

  // ------------------------------------------------------------- scrolling
  //
  // MAME applies these asymmetrically and it is not a typo there, so it must
  // not be "tidied" here:
  //
  //   set_scrollx(0, -h)              horizontal is NEGATED
  //   set_scrolly(0, vscr & 0x1ff)    vertical is not
  //
  // The map is 64x64 tiles of 8x8, so 512x512, and both wrap in 9 bits.
  logic [8:0] map_x, map_y;
  assign map_x = x - hscr[8:0];
  assign map_y = y + vscr[8:0];

  // Bit 15 of the vertical scroll register is the layer disable.
  assign disabled = vscr[15];

  // ----------------------------------------------------------- tile lookup
  //
  // TILEMAP_SCAN_ROWS over 64x64, and each layer occupies 0x1000 words:
  // 0s at 0x0000, 0w at 0x1000, 1s at 0x2000, 1w at 0x3000.
  assign tile_addr = {1'b0, layer, map_y[8:3], map_x[8:3]};

  // ------------------------------------------------------- tile word decode
  //
  // MAME:  tileinfo.set(gfx, val & tile_mask, (val >> 7) & 0xff, 0);
  //        tileinfo.category = (val & 0x8000) != 0;
  //
  // Note that the tile index and the colour OVERLAP — index is bits 13:0 and
  // colour is bits 14:7, so bits 13:7 belong to both. That is real: the chip
  // does not have enough bits to separate them and software picks tile numbers
  // whose high bits double as the palette. Masking the colour out of the index
  // "to clean it up" changes which tile is drawn.
  logic [13:0] tile_num;
  logic [7:0]  colour;
  assign tile_num = tile_word[13:0] & tile_mask;
  assign colour   = tile_word[14:7];
  assign prio     = tile_word[15];

  // ------------------------------------------------------------ char lookup
  //
  // 32 bytes per tile = 16 words; two words per 8-pixel row.
  // 0x4000 tiles x 16 words is 0x40000 words, so this is 18 bits, not 17.
  // char_addr points at the FIRST word of the row; the fetcher reads it and
  // char_addr+1, which together hold the row's eight pixels.
  assign char_addr = {tile_num, 4'b0000} + {14'd0, map_y[2:0], 1'b0};

  // ------------------------------------------------------------ pixel
  logic [15:0] cw;
  assign cw = map_x[2] ? char_w1 : char_w0;

  always_comb begin
    case (map_x[1:0])
      2'd0: pixel = cw[15:12];
      2'd1: pixel = cw[11:8];
      2'd2: pixel = cw[7:4];
      default: pixel = cw[3:0];
    endcase
  end

  assign transparent = (pixel == 4'd0);
  assign pal_index   = {colour, pixel};

endmodule
