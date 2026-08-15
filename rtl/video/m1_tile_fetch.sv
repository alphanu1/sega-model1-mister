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
// Scanline fetch engine for one tilemap layer.
//
// Walks the visible tile columns of one scanline, reads the tile word from
// on-chip tile RAM, fetches the character row from external memory, and writes
// eight palette indices into a line buffer. One instance per layer; the mixer
// combines the four line buffers during scanout.
//
// WHY THIS IS FETCHED A ROW AT A TIME AND NOT A PIXEL AT A TIME
//
// Character RAM is 512 KB and lives in SDRAM (D8) because it will not fit in
// M10K beside D3's band buffer. The budget is tight enough that the access
// pattern is the design:
//
//   62 visible tile columns x 2 char words x 4 layers  = 496 words per line
//   a scanline is 656 pixel clocks at 16 MHz           ~ 41 us
//   at 100 MHz that is                                 ~ 4100 cycles
//   at the measured 14.2 cycles per 4-word burst       ~ 3520 cycles
//
// It fits, with about 15% margin, and only because each fetch brings back a
// whole 8-pixel row rather than a pixel. Fetching per pixel would need eight
// times the transactions and miss by a mile. The margin is thin enough that
// bw_monitor's per-master figures are the thing to watch when the V60 and the
// TGP are competing for the same controller.
//
// A SCREEN COLUMN IS NOT A MAP TILE
//
// The first version walked 8-pixel screen columns and fetched one tile word
// per column. That is only correct when the horizontal scroll is a multiple of
// eight. `map_x = x - hscr`, so with any other scroll a single screen column
// straddles two map tiles, and using the first tile's word for all eight
// pixels puts a slice of the wrong character on every column boundary across
// the whole screen.
//
// So the walk is driven by the tile address changing, not by column
// boundaries: it steps one pixel at a time and refetches only when the address
// the decode computes actually moves. The traffic is the same — the address
// still changes at most once per eight pixels — but it is now correct at any
// scroll value.
//
// A REPEATED TILE IS NOT REFETCHED
//
// Text layers are mostly one font: the same handful of character codes recur
// across a line, and a service menu is largely one blank tile. Holding the
// last fetched character row and reusing it when the next column names the
// same tile and row costs one comparator and removes most of the traffic on
// exactly the screens M1 has to boot. It is not a cache — one entry, no tags
// beyond the address it already has — but on this content it is most of the
// benefit of one.

`timescale 1ns/1ps

module m1_tile_fetch #(
  parameter int unsigned COLUMNS = 62      // visible 8-pixel columns (496/8)
) (
  input  logic        clk,
  input  logic        rst_n,

  // Start rendering scanline `line` for this layer.
  input  logic        start,
  input  logic [8:0]  line,
  input  logic [1:0]  layer,
  input  logic [15:0] hscr,
  input  logic [15:0] vscr,
  input  logic [13:0] tile_mask,
  output logic        busy,
  output logic        done,

  // On-chip tile RAM read port. Single cycle, registered data.
  output logic [14:0] tram_addr,
  input  logic [15:0] tram_data,

  // Character RAM, external. Word address; two consecutive words per request.
  output logic        char_req,
  output logic [17:0] char_addr,
  input  logic [31:0] char_data,      // {word1, word0}
  input  logic        char_ack,

  // Line buffer write port: eight pixels per column.
  output logic        lb_we,
  output logic [8:0]  lb_addr,
  output logic [11:0] lb_pal,
  output logic        lb_transparent,
  output logic        lb_prio,

  // Per-line telemetry: how many character fetches were actually issued. With
  // the repeat check this is well below COLUMNS on text screens, and it is the
  // number that says whether the bandwidth budget above holds.
  output logic [7:0]  fetches
);

  typedef enum logic [2:0] {
    S_IDLE, S_CHECK, S_TILE_WAIT, S_CHAR, S_EMIT, S_DONE
  } state_t;
  state_t st;

  logic [9:0]  sx;           // screen pixel within the line
  // scr_x is the SCREEN position handed to the decode, which applies the
  // scroll itself. map_pos is the resulting position in map space, needed here
  // because the tile boundary moves with hscr. Conflating the two is what put
  // a slice of the wrong character on every column boundary: testing
  // scr_x[2:0] finds screen-aligned boundaries, which are the map boundaries
  // only when hscr is a multiple of eight.
  logic [8:0]  scr_x, map_y;
  logic [8:0]  map_pos;
  logic [15:0] tile_word_r;
  logic [31:0] char_r;
  logic [17:0] last_char;
  logic [14:0] last_tile;
  logic        char_valid, tile_valid;

  // The decode datapath is instantiated rather than reimplemented, so the
  // addressing and the 4bpp unpacking have exactly one definition.
  logic [14:0] dec_tile_addr;
  logic [17:0] dec_char_addr;
  logic [11:0] dec_pal;
  logic [3:0]  dec_pixel;
  logic        dec_prio, dec_transp, dec_disabled;

  m1_tile_decode dec (
    .x(scr_x), .y(map_y), .layer(layer),
    .hscr(hscr), .vscr(vscr),
    .tile_word(tile_word_r),
    .char_w0(char_r[15:0]), .char_w1(char_r[31:16]),
    .tile_mask(tile_mask),
    .tile_addr(dec_tile_addr), .char_addr(dec_char_addr),
    .pal_index(dec_pal), .pixel(dec_pixel), .prio(dec_prio),
    .transparent(dec_transp), .disabled(dec_disabled)
  );

  // The decode takes an unscrolled screen position and applies scroll itself,
  // so drive it with the raw position and let it do the arithmetic once.
  assign scr_x   = sx[8:0];
  assign map_y   = line;
  assign map_pos = scr_x - hscr[8:0];

  assign tram_addr = dec_tile_addr;
  assign char_addr = dec_char_addr;
  assign busy      = (st != S_IDLE) && (st != S_DONE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; sx <= '0;
      tile_word_r <= '0; char_r <= '0;
      last_char <= '0; last_tile <= '0;
      char_valid <= 1'b0; tile_valid <= 1'b0;
      char_req <= 1'b0; lb_we <= 1'b0; done <= 1'b0; fetches <= '0;
      lb_addr <= '0; lb_pal <= '0; lb_transparent <= 1'b0; lb_prio <= 1'b0;
    end else begin
      lb_we <= 1'b0;
      done  <= 1'b0;

      case (st)
        S_IDLE: begin
          if (start) begin
            sx      <= '0;
            fetches <= '0;
            // Neither retained value survives a scanline.
            //
            // Clearing char_valid is belt-and-braces and mutation testing says
            // so: deleting it changes no result. char_addr is
            // tile_num*16 + row*2, so it encodes the character row, and a new
            // scanline therefore computes a different address that the reuse
            // comparison rejects on its own. It is kept because that argument
            // rests on char_addr always carrying the row — true now, and not
            // an invariant worth depending on silently if the addressing ever
            // changes.
            //
            // Clearing tile_valid is NOT redundant: a tile address repeats
            // across lines whenever the map row is unchanged, so without this
            // the first tile of a new line would reuse the previous line's
            // tile word.
            tile_valid <= 1'b0;
            char_valid <= 1'b0;
            st         <= S_CHECK;
          end
        end

        S_CHECK: begin
          // tram_addr is combinational off sx. Refetch only when the tile the
          // decode is pointing at actually changed.
          if (tile_valid && (dec_tile_addr == last_tile)) st <= S_CHAR;
          else                                            st <= S_TILE_WAIT;
        end

        S_TILE_WAIT: begin
          tile_word_r <= tram_data;
          last_tile   <= dec_tile_addr;
          tile_valid  <= 1'b1;
          st          <= S_CHAR;
        end

        S_CHAR: begin
          // dec_char_addr is valid now the tile word is latched.
          if (char_valid && (dec_char_addr == last_char)) begin
            st <= S_EMIT;
          end else if (!char_req) begin
            char_req <= 1'b1;
          end else if (char_ack) begin
            char_req   <= 1'b0;
            char_r     <= char_data;
            last_char  <= dec_char_addr;
            char_valid <= 1'b1;
            fetches    <= fetches + 8'd1;
            st         <= S_EMIT;
          end
        end

        S_EMIT: begin
          lb_we          <= 1'b1;
          lb_addr        <= sx[8:0];
          lb_pal         <= dec_pal;
          lb_transparent <= dec_transp | dec_disabled;
          lb_prio        <= dec_prio;
          if (sx == 10'(COLUMNS * 8 - 1)) begin
            st <= S_DONE;
          end else begin
            sx <= sx + 10'd1;
            // Stay here and emit the next pixel from the row already latched,
            // unless it belongs to a different tile. A tile boundary is
            // exactly where the low three bits of the MAP position wrap, which
            // is testable directly rather than by recomputing the address for
            // sx+1 — and it is the scroll-correct form of "eight pixels per
            // fetch", since the boundary moves with hscr.
            //
            // Returning to S_CHECK for every pixel instead cost three cycles
            // per pixel and blew the scanline budget by 2.4x while producing
            // identical output.
            if (map_pos[2:0] == 3'd7) st <= S_CHECK;
          end
        end

        S_DONE: begin
          done <= 1'b1;
          st   <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
