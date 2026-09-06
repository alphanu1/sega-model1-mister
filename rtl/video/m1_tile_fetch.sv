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

  // This scanline's row mask for the pair this layer belongs to: four 16-bit
  // words, word 0 covering screen x 0-127 and so on, bit 15 the leftmost eight
  // pixels of each word. NOT the same thing as tile_mask above, which is a
  // width mask on the tile NUMBER — MAME calls both "mask" and they are
  // unrelated.
  input  logic [63:0] row_mask,

  // Whole-layer suppression for this scanline, from the pair's window mode. Not
  // the same as vscr bit 15, which disables a layer for the whole frame: this is
  // per line, because a window splits the screen between the two maps of a pair.
  input  logic        layer_off,

  // Window modes 2 and 3: the pair's two maps split the screen at a COLUMN, not
  // at a scanline, so this cannot be folded into layer_off the way mode 1's
  // vertical split is. split_x is MAME's `h = hscr & 0x1ff` and split_right says
  // which side of it this layer owns — 1 for x >= h, 0 for x < h. MAME draws
  // `layer` into the clip left of h and `layer^1` into the clip right of it.
  input  logic        split_en,
  input  logic [8:0]  split_x,
  input  logic        split_right,

  output logic        busy,
  output logic        done,

  // On-chip tile RAM read port. Single cycle, registered data.
  output logic [14:0] tram_addr,
  input  logic [15:0] tram_data,

  // Character RAM, external. Word address; two consecutive words per request.
  output logic        char_req,
  output logic [17:0] char_addr,
  // SIXTY-FOUR BITS, because the burst already returns four words and half of
  // them were being discarded.
  //
  // char_addr points at the first of the TWO words holding an 8-pixel row, and
  // port 1 bursts FOUR. So words 2 and 3 are the same tile's NEXT row - which
  // is the next scanline - and `char_data[31:0]` was all the engine ever read.
  // Keeping the upper half halves the number of fetches a layer needs.
  input  logic [63:0] char_data,      // {word3, word2, word1, word0}
  input  logic        char_ack,

  // Line buffer write port: FOUR PIXELS PER CYCLE.
  //
  // char_data delivers eight 4bpp pixels at once and this used to spend eight
  // cycles writing them one at a time — 496 cycles a layer, 1,984 for four,
  // against 3,280 in a scanline. That, not the fetch latency, is what put the
  // line over budget: measured, the engine misses its deadline on one line in
  // six. Four at a time takes emission to 124 cycles a layer.
  //
  // `lb_we` is a per-pixel valid mask rather than a single enable, because the
  // first group of a line is short whenever hscr is not a multiple of eight,
  // and the last one is cut off by the end of the visible region. All four
  // pixels are always from the SAME tile — the group is clipped at the tile
  // boundary — so one latched character row feeds them all.
  output logic [3:0]       lb_we,
  output logic [8:0]       lb_addr,        // screen position of pixel 0
  output logic [3:0][11:0] lb_pal,
  output logic [3:0]       lb_transparent,
  output logic [3:0]       lb_prio,

  // Row-mask verdict per pixel: this pixel's category does not match the mask
  // selection for its column, so the mixer must not draw it. Carried alongside
  // rather than merged into lb_transparent because tilemaps 2 and 3 draw their
  // category-0 pass opaque, and an opaque pass ignores transparency.
  output logic [3:0]       lb_masked,

  // Per-line telemetry: how many character fetches were actually issued. With
  // the repeat check this is well below COLUMNS on text screens, and it is the
  // number that says whether the bandwidth budget above holds.
  output logic [7:0]  fetches,

  // CONTENT CENSUS: one pulse per non-blank tile word read.
  //
  // Distinct from anything reaching the screen. The win census in m1_video counts
  // pixels a layer WON, which cannot separate "this layer holds nothing" from
  // "this layer holds text that is not being drawn" — both read as zero and they
  // need opposite fixes. In simulation the pair of numbers is what located the
  // row-mask fault; hardware had no equivalent, which is why the board could not
  // be diagnosed from its overlay.
  //
  // Taken from a read the engine makes anyway, on the span actually displayed, so
  // it costs no tile RAM bandwidth. It counts words FETCHED, so the retained-row
  // optimisation hides repeats of one tile: a presence check, not an inventory.
  output logic        tw_nonblank
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

  // Emit side: sx is the first pixel of the group being written, and rem is
  // how many pixels of the current tile are still to come. A group is the
  // smaller of four, what is left of the tile, and what is left of the line.
  logic [9:0]  sx;
  logic [3:0]  rem;
  logic [15:0] tw_e;
  logic [31:0] ch_e;
  logic [3:0]  gn;        // pixels in this group, 1..4
  logic [9:0]  left;      // pixels left on the line

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

  // FOUR EMIT DECODES, ONE PER PIXEL OF THE GROUP.
  //
  // The pixel, its palette index and its transparency all depend on the screen
  // position, so four pixels a cycle needs four of them. The addressing half of
  // each is unused and synthesis drops it; what remains is the nibble select
  // and the palette compose, which is small. Instantiated rather than written
  // out again so the 4bpp unpacking keeps one definition.
  logic [3:0][11:0] dec_pal;
  logic [3:0]       dec_prio, dec_transp, dec_disabled;
  logic [3:0][14:0] e_un_tile;
  logic [3:0][17:0] e_un_char;
  logic [3:0][3:0]  e_un_pixel;

  genvar gp;
  generate
    for (gp = 0; gp < 4; gp++) begin : g_emit
      m1_tile_decode dec_e (
        .x(sx[8:0] + 9'(gp)), .y(map_y), .layer(layer),
        .hscr(hscr), .vscr(vscr),
        .tile_word(tw_e),
        .char_w0(ch_e[15:0]), .char_w1(ch_e[31:16]),
        .tile_mask(tile_mask),
        .tile_addr(e_un_tile[gp]), .char_addr(e_un_char[gp]),
        .pal_index(dec_pal[gp]), .pixel(e_un_pixel[gp]),
        .prio(dec_prio[gp]), .transparent(dec_transp[gp]),
        .disabled(dec_disabled[gp])
      );
    end
  endgenerate

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

  // ------------------------------------------------- next-scanline cache
  //
  // Every fetch returns four words: the row this scanline needs and the SAME
  // TILE'S NEXT ROW, which is what the next scanline needs. Keeping the second
  // half turns two fetches into one for every pair of scanlines.
  //
  // Keyed on the ADDRESS, not on a row-parity rule. Parity alone assumes the
  // column still maps to the same tile on the next line, and hscr can change
  // between lines - VR's changes on 1,344 frames of 2,000. Storing the address
  // that was fetched and requiring `want == cached + 2` is exact, costs 18 bits
  // an entry, and cannot be wrong.
  //
  // One entry per column per layer: 62 x 4. Written when a fetch completes,
  // read when the wanted row is the one the previous line already brought back.
  localparam int unsigned CC_N = COLUMNS * 4;
  logic [17:0] cc_addr [CC_N];
  logic [31:0] cc_data [CC_N];
  logic        cc_valid [CC_N];

  // fx is the screen position of the column being fetched, eight pixels a
  // column, so fx[8:3] is the column index.
  wire [$clog2(CC_N)-1:0] cc_i = ($clog2(CC_N))'({layer, fx[8:3]});
  wire cc_hit = cc_valid[cc_i] && (cc_addr[cc_i] + 18'd2 == f_char_addr);

  logic consume;
  assign consume = (est == E_WAIT) && f_have;

  assign left = 10'(COLUMNS * 8) - sx;
  always_comb begin
    gn = 4'd4;
    if (rem  < gn)        gn = rem;
    if (left < 10'(gn))   gn = 4'(left);
  end

  // ------------------------------------------------------------- fetch side
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fst <= F_IDLE; fx <= '0; tw_f <= '0; ch_f <= '0; f_have <= 1'b0;
      tw_nonblank <= 1'b0;
      last_tile <= '0; last_char <= '0;
      tile_valid <= 1'b0; char_valid <= 1'b0;
      char_req <= 1'b0; fetches <= '0;
      // The cache DELIBERATELY survives `start`: its whole purpose is to carry
      // a row from one scanline to the next. Only reset clears it, and a stale
      // entry cannot be used anyway because cc_hit compares the address.
      for (int c = 0; c < CC_N; c++) cc_valid[c] <= 1'b0;
    end else if (start) begin
      tw_nonblank <= 1'b0;
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
      tw_nonblank <= 1'b0;   // one-cycle pulse; see the port comment
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
          // Same rule the MAME script and the frame testbench use: non-zero, and
          // not tile 0x20, which is the space character.
          tw_nonblank <= (tram_data != 16'h0000)
                      && ((tram_data & 16'h3fff) != 16'h0020);
        end

        F_CHAR: begin
          // f_char_addr is valid now the tile word is latched.
          if (char_valid && (f_char_addr == last_char)) begin
            // ch_f already holds this character; nothing to ask for.
            f_have <= 1'b1;
            fst    <= F_FULL;
          end else if (cc_hit) begin
            // THE PREVIOUS SCANLINE ALREADY FETCHED THIS ROW. Its burst brought
            // back four words - this row and the next - and the upper half was
            // kept. No memory access at all, so the whole round trip is saved.
            ch_f            <= cc_data[cc_i];
            last_char       <= f_char_addr;
            char_valid      <= 1'b1;
            cc_valid[cc_i]  <= 1'b0;   // consumed; the next line needs a fetch
            f_have          <= 1'b1;
            fst             <= F_FULL;
          end else if (!char_req) begin
            char_req <= 1'b1;
          end else if (char_ack) begin
            char_req   <= 1'b0;
            ch_f       <= char_data[31:0];
            last_char  <= f_char_addr;
            char_valid <= 1'b1;
            fetches    <= fetches + 8'd1;
            f_have     <= 1'b1;
            fst        <= F_FULL;
            // Keep the half that used to be thrown away: words 2 and 3 are the
            // same tile's next row, which is what the next scanline asks for.
            cc_addr[cc_i]  <= f_char_addr;
            cc_data[cc_i]  <= char_data[63:32];
            cc_valid[cc_i] <= 1'b1;
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

  // Four consecutive screen pixels can straddle an 8-pixel mask column, and do
  // whenever the tile boundary is unaligned, so each is looked up on its own
  // rather than sharing one bit. Word 0 covers x 0-127; within a word bit 15 is
  // the leftmost eight pixels, which is MAME's `0x8000 >> (x >> 3)`.
  logic [9:0]  px      [4];
  logic [15:0] px_word [4];
  logic [3:0]  px_mask;
  // The column split, per pixel, off the same x. Masked when the pixel falls on
  // the side of the split this layer does NOT own, which is the disagreement
  // between `x < h` and split_right:
  //   split_right = 1  owns x >= h, so mask where (x < h) is 1
  //   split_right = 0  owns x <  h, so mask where (x < h) is 0
  logic [3:0]  px_split;
  always_comb begin
    for (int i = 0; i < 4; i++) begin
      px[i]       = sx + 10'(i);
      px_word[i]  = row_mask[{px[i][8:7], 4'd0} +: 16];
      px_mask[i]  = px_word[i][4'd15 - px[i][6:3]];
      px_split[i] = split_en
                 && ((px[i] < {1'b0, split_x}) == split_right);
    end
  end

  // -------------------------------------------------------------- emit side
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      est <= E_IDLE; sx <= '0; rem <= '0; tw_e <= '0; ch_e <= '0;
      lb_we <= 4'd0; done <= 1'b0;
      lb_addr <= '0; lb_pal <= '0; lb_transparent <= '0; lb_prio <= '0;
      lb_masked <= '0;
    end else begin
      lb_we <= 4'd0;
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
              // Pixels of this tile still to come. Only the first tile of a
              // line is ever short, and only when hscr is not a multiple of
              // eight — the boundary moves with the scroll.
              rem  <= 4'd8 - {1'b0, e_off};
              est  <= E_EMIT;
            end
          end

          E_EMIT: begin
            // Valid mask, not a single enable: the group is clipped at the
            // tile boundary and at the end of the line.
            lb_we          <= 4'((4'd1 << gn) - 4'd1);
            lb_addr        <= sx[8:0];
            lb_pal         <= dec_pal;
            lb_transparent <= dec_transp | dec_disabled;
            lb_prio        <= dec_prio;
            // Visible where the pixel's category equals its mask bit, so
            // masked is the disagreement. With an all-zero mask that leaves
            // category 0 showing and category 1 hidden, which is what MAME's
            // fast paths do: !m draws the whole 128, and the inverted pass
            // sees 0xffff and draws none of it.
            // The mask bit alone, NOT combined with the tile's category. Its
            // polarity was already applied when the word was read — m1_video
            // inverts it for the odd tilemap, which is what MAME's `if (win)
            // m = ~m` does. This was `dec_prio ^ px_mask`, which tied the mask to
            // the category instead of to the tilemap, and suppressed every
            // category-1 tile on the even tilemaps. See m1_video's Q_MASK_W.
            lb_masked      <= px_mask | {4{layer_off}} | px_split;

            sx  <= sx + 10'(gn);
            rem <= rem - gn;

            if (10'(gn) >= left)      est <= E_DONE;
            else if ((rem - gn) == 0) est <= E_WAIT;
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
