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

// THIS ENGINE IS LATENCY-BOUND, AND THAT IS THE THING TO FIX
//
// Measured per layer per scanline: 1,614 cycles on distinct tiles, of which
// 496 are emitting pixels and **1,118 are spent waiting**. 69% idle.
//
// The state machine below is strictly serialized — S_TILE, S_TILE_WAIT, S_CHAR
// (request, then stall for the ~14-cycle SDRAM latency), S_EMIT for eight
// pixels, repeat. Nothing overlaps, so every column pays the full memory
// latency in series.
//
// The consequence is that the CLOCK CANNOT FIX IT. Four dense layers need
// 6,456 cycles against 3,280 available in a scanline at 80 MHz; closing that by
// frequency alone would take ~157 MHz, which this device will not give. Anyone
// arriving here because four layers do not fit should not go looking for a
// faster clock or spend S32_V60_NO_FP on it.
//
// What does fix it: the SDRAM side is nowhere near saturated. 62 bursts per
// layer at ~9 cycles each on an open row is ~558 cycles, so prefetching two or
// three columns ahead — hiding the latency behind the eight cycles of emission
// already happening — makes a layer cost max(emit, fetch) ~= 560 instead of
// emit + wait = 1,614. Four layers then fit in ~2,240 cycles with room spare.
//
// A second lever after that: char_data is 32 bits, which is eight 4bpp pixels
// arriving at once, and S_EMIT currently spends eight cycles writing them one
// at a time. A wider line-buffer write takes emission from 496 cycles to 62.
//
// Full working in docs/m1-m4-plan.md, "Where the 1,614 cycles go".

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

  // ------------------------------------------------------------------------
  // TWO ENGINES, ONE COLUMN APART.
  //
  // The fetch side works on the column after the one the emit side is drawing,
  // so a column's SDRAM latency is paid underneath the eight cycles of
  // emission already happening rather than after them. Cost per column goes
  // from emit + wait to max(emit, wait).
  //
  // They are separate state machines rather than one with more states because
  // the whole point is that they advance independently; a single sequencer
  // that has to be in one place at a time is what made this serial.
  //
  // The hand-off is a single-entry buffer. `f_have` says the fetch side has a
  // column ready; the emit side takes it at a tile boundary and the fetch side
  // moves to the next. The fetch side never rewrites the buffer in the same
  // cycle the emit side reads it — it goes to F_CHECK first, and only F_TILE
  // writes — so no interlock beyond the flag is needed.
  // ------------------------------------------------------------------------

  typedef enum logic [2:0] {
    F_IDLE, F_CHECK, F_TILE, F_CHAR, F_FULL
  } fstate_t;
  typedef enum logic [1:0] {
    E_IDLE, E_WAIT, E_EMIT, E_DONE
  } estate_t;

  fstate_t fst;
  estate_t est;

  // Fetch side: fx is the screen position of the FIRST pixel of the column
  // being fetched.
  logic [9:0]  fx;
  logic [15:0] tw_f;
  logic [31:0] ch_f;
  logic        f_have;
  logic [14:0] last_tile;
  logic [17:0] last_char;
  logic        tile_valid, char_valid;

  // Emit side: sx is the pixel being written.
  logic [9:0]  sx;
  logic [15:0] tw_e;
  logic [31:0] ch_e;

  logic [8:0]  map_y;
  assign map_y = line;

  // TWO DECODES, NOT TWO COPIES OF THE ADDRESSING.
  //
  // The addresses have to be computed for the column being fetched while the
  // pixels are still coming out of the column being drawn, which is one
  // position each. m1_tile_decode is instantiated twice rather than having its
  // arithmetic written out again here, so the addressing and the 4bpp
  // unpacking keep exactly one definition — the reason it was a module in the
  // first place.
  logic [14:0] f_tile_addr;
  logic [17:0] f_char_addr;

  // The fetch decode only supplies addresses and the emit decode only supplies
  // pixels, so each leaves the other half of m1_tile_decode unused. Named
  // rather than connected empty: -Wall rejects an empty pin, and a named wire
  // says the output was considered and not wanted.
  logic [11:0] f_unused_pal;
  logic  [3:0] f_unused_pixel;
  logic        f_unused_prio, f_unused_transp, f_unused_disabled;
  logic [14:0] e_unused_tile_addr;
  logic [17:0] e_unused_char_addr;
  logic  [3:0] e_unused_pixel;

  m1_tile_decode dec_f (
    .x(fx[8:0]), .y(map_y), .layer(layer),
    .hscr(hscr), .vscr(vscr),
    .tile_word(tw_f),
    .char_w0(16'd0), .char_w1(16'd0),
    .tile_mask(tile_mask),
    .tile_addr(f_tile_addr), .char_addr(f_char_addr),
    .pal_index(f_unused_pal), .pixel(f_unused_pixel), .prio(f_unused_prio),
    .transparent(f_unused_transp), .disabled(f_unused_disabled)
  );

  logic [11:0] dec_pal;
  logic        dec_prio, dec_transp, dec_disabled;

  m1_tile_decode dec_e (
    .x(sx[8:0]), .y(map_y), .layer(layer),
    .hscr(hscr), .vscr(vscr),
    .tile_word(tw_e),
    .char_w0(ch_e[15:0]), .char_w1(ch_e[31:16]),
    .tile_mask(tile_mask),
    .tile_addr(e_unused_tile_addr), .char_addr(e_unused_char_addr),
    .pal_index(dec_pal), .pixel(e_unused_pixel), .prio(dec_prio),
    .transparent(dec_transp), .disabled(dec_disabled)
  );

  assign tram_addr = f_tile_addr;
  assign char_addr = f_char_addr;
  assign busy      = (est != E_IDLE) || (fst != F_IDLE);

  // Where the emit side is inside its tile, and where the fetch side is inside
  // its own. Both are map-space positions: a tile boundary moves with hscr, so
  // testing the screen position finds the right place only when hscr is a
  // multiple of eight.
  logic [2:0] e_off, f_off;
  assign e_off = 3'(sx[8:0] - hscr[8:0]);
  assign f_off = 3'(fx[8:0] - hscr[8:0]);

  // Pixels from fx to the start of the next tile. Eight when fx is already
  // aligned, which is every column after the first.
  logic [3:0] f_step;
  assign f_step = 4'd8 - {1'b0, f_off};

  logic consume;
  assign consume = (est == E_WAIT) && f_have;

  // ------------------------------------------------------------- fetch side
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fst <= F_IDLE; fx <= '0; tw_f <= '0; ch_f <= '0; f_have <= 1'b0;
      last_tile <= '0; last_char <= '0;
      tile_valid <= 1'b0; char_valid <= 1'b0;
      char_req <= 1'b0; fetches <= '0;
    end else if (start) begin
      // Neither retained value survives a scanline. tile_valid especially: a
      // tile address repeats across lines whenever the map row is unchanged,
      // so without clearing it the first tile of a new line would reuse the
      // previous line's word.
      fst        <= F_CHECK;
      fx         <= '0;
      f_have     <= 1'b0;
      tile_valid <= 1'b0;
      char_valid <= 1'b0;
      char_req   <= 1'b0;
      fetches    <= '0;
    end else begin
      case (fst)
        F_IDLE: ;

        F_CHECK: begin
          // f_tile_addr is combinational off fx. Refetch only when the tile
          // actually changed.
          if (tile_valid && (f_tile_addr == last_tile)) fst <= F_CHAR;
          else                                          fst <= F_TILE;
        end

        F_TILE: begin
          tw_f       <= tram_data;
          last_tile  <= f_tile_addr;
          tile_valid <= 1'b1;
          fst        <= F_CHAR;
        end

        F_CHAR: begin
          // f_char_addr is valid now the tile word is latched.
          if (char_valid && (f_char_addr == last_char)) begin
            // ch_f already holds this character; nothing to ask for.
            f_have <= 1'b1;
            fst    <= F_FULL;
          end else if (!char_req) begin
            char_req <= 1'b1;
          end else if (char_ack) begin
            char_req   <= 1'b0;
            ch_f       <= char_data;
            last_char  <= f_char_addr;
            char_valid <= 1'b1;
            fetches    <= fetches + 8'd1;
            f_have     <= 1'b1;
            fst        <= F_FULL;
          end
        end

        F_FULL: begin
          if (consume) begin
            f_have <= 1'b0;
            // Stop once the whole line has been fetched; the emit side has
            // everything it will ask for.
            if ((fx + 10'(f_step)) >= 10'(COLUMNS * 8)) begin
              fst <= F_IDLE;
            end else begin
              fx  <= fx + 10'(f_step);
              fst <= F_CHECK;
            end
          end
        end

        default: fst <= F_IDLE;
      endcase
    end
  end

  // -------------------------------------------------------------- emit side
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      est <= E_IDLE; sx <= '0; tw_e <= '0; ch_e <= '0;
      lb_we <= 1'b0; done <= 1'b0;
      lb_addr <= '0; lb_pal <= '0; lb_transparent <= 1'b0; lb_prio <= 1'b0;
    end else begin
      lb_we <= 1'b0;
      done  <= 1'b0;

      if (start) begin
        sx  <= '0;
        est <= E_WAIT;
      end else begin
        case (est)
          E_IDLE: ;

          E_WAIT: begin
            // Stalls only when the fetch side has not caught up, which after
            // the first column of a line is the whole measure of whether the
            // engine is keeping ahead of the beam.
            if (f_have) begin
              tw_e <= tw_f;
              ch_e <= ch_f;
              est  <= E_EMIT;
            end
          end

          E_EMIT: begin
            lb_we          <= 1'b1;
            lb_addr        <= sx[8:0];
            lb_pal         <= dec_pal;
            lb_transparent <= dec_transp | dec_disabled;
            lb_prio        <= dec_prio;
            if (sx == 10'(COLUMNS * 8 - 1)) begin
              est <= E_DONE;
            end else begin
              sx <= sx + 10'd1;
              // The last pixel of a tile is where the low three bits of the
              // MAP position wrap, so the next pixel needs the next column.
              if (e_off == 3'd7) est <= E_WAIT;
            end
          end

          E_DONE: begin
            done <= 1'b1;
            est  <= E_IDLE;
          end

          default: est <= E_IDLE;
        endcase
      end
    end
  end

endmodule
