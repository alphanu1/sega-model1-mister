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

// THIS ENGINE IS LATENCY-BOUND, AND THAT IS STILL THE THING THAT LIMITS IT
//
// Every distinct character row is one SDRAM round trip on a port that takes
// one request at a time, and a dense line has ~150 of them. Measured on MAME's
// own scenes replayed through m1_video (tb_m1_video2d, 2026-10-28): Virtua
// Racing's course select needs 148 fetches on its worst line, and at the
// in-play mean of 16 cycles a request the old engine took 3,448 cycles against
// a 3,280-cycle line - 20 lines a frame repeated, at the mean, before any
// contention tail. The clock cannot fix it and neither can bandwidth: the
// controller is ~70% idle (findings 2026-09-04).
//
// So the engine's own overhead is what is cut, and invisible work is not done:
//
//   - the old fetch side spent four cycles of its own on every column around
//     each round trip (check, tile read, raise, hand-off), all in series with
//     the memory. Now a lookahead reads the next columns' tile words while a
//     request is in flight and the next request rises the cycle after the
//     ack's own: L+1 a fetch, not L+4.
//   - a column whose every pixel is masked - the row mask, the window pair's
//     suppressed map, the modes 2/3 split - is not fetched at all. The mixer
//     never looks at a masked pixel, so what lands in the line buffer there is
//     immaterial; the masked bit itself is still written for every pixel. On
//     the course select a whole layer of text columns is masked.
//   - the emitter takes the next column on the last cycle of the previous one,
//     two cycles a column rather than three.
//
// See docs/findings.md 2026-10-28 for the measurements.

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
  input  logic [31:0] char_data,      // {word1, word0}
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
  // THREE PARTS, DECOUPLED BY TWO SMALL QUEUES.
  //
  //   lookahead  walks the columns, reads each one's tile word and classifies
  //              it: FETCH (a new character row), REPEAT (the same row as the
  //              last visible column - reuse its data), or INVIS (every pixel
  //              masked - no tile read, no fetch). Descriptors go into a
  //              four-entry queue in column order.
  //   requester  walks the same queue and issues one character request at a
  //              time for the FETCH entries, as early as the port allows; the
  //              data goes into a two-entry queue, in order.
  //   emitter    takes descriptors in order, pairing each FETCH with the head
  //              of the data queue, and writes four pixels a cycle.
  //
  // The port contract is unchanged: one request outstanding, raised on a rising
  // edge, the address held from that edge (m1_sdram latches it there), the ack
  // ignored on the cycle the request rises - m1_sdram holds an ack for two
  // cycles, so the second of them is still high when the next request goes up,
  // and must not be taken as its answer. That is exactly what the old F_CHAR
  // did too: it only looked at ack once char_req was already high.
  //
  // Data correspondence needs no tags: requests complete in issue order, issue
  // order is column order, and REPEAT/INVIS entries produce no data.
  // ------------------------------------------------------------------------

  localparam logic [1:0] K_FETCH = 2'd0, K_REPEAT = 2'd1, K_INVIS = 2'd2;

  typedef enum logic [1:0] { P_IDLE, P_ADDR, P_DATA } pstate_t;
  typedef enum logic [1:0] { E_IDLE, E_WAIT, E_EMIT, E_DONE } estate_t;

  pstate_t pst;
  estate_t est;

  logic [8:0]  map_y;
  assign map_y = line;

  // ------------------------------------------------------------ lookahead
  logic [9:0]  px;          // first screen pixel of the column being looked up
  logic [17:0] p_last_ca;   // last VISIBLE column's character row
  logic        p_last_v;

  logic [14:0] f_tile_addr;
  logic [17:0] f_char_addr;
  logic [11:0] f_unused_pal;
  logic  [3:0] f_unused_pixel;
  logic        f_unused_prio, f_unused_transp, f_unused_disabled;

  // The tile word goes straight in from the RAM: the character address depends
  // only on it and on map_y, so it is valid in P_DATA, the cycle the word is.
  m1_tile_decode dec_f (
    .x(px[8:0]), .y(map_y), .layer(layer),
    .hscr(hscr), .vscr(vscr),
    .tile_word(tram_data),
    .char_w0(16'd0), .char_w1(16'd0),
    .tile_mask(tile_mask),
    .tile_addr(f_tile_addr), .char_addr(f_char_addr),
    .pal_index(f_unused_pal), .pixel(f_unused_pixel), .prio(f_unused_prio),
    .transparent(f_unused_transp), .disabled(f_unused_disabled)
  );
  assign tram_addr = f_tile_addr;

  // Pixels from px to the next tile boundary: eight once aligned, which is
  // every column after the first.
  logic [2:0] f_off;
  logic [3:0] f_step;
  logic [9:0] p_next, p_last;
  logic       p_end;
  assign f_off  = 3'(px[8:0] - hscr[8:0]);
  assign f_step = 4'd8 - {1'b0, f_off};
  assign p_next = px + 10'(f_step);
  assign p_end  = (p_next >= 10'(COLUMNS * 8));
  assign p_last = p_end ? 10'(COLUMNS * 8 - 1) : p_next - 10'd1;

  // A pixel is masked when its 8-pixel mask column says so, when the window
  // pair's other map owns this line, or when the modes 2/3 split gives its x to
  // the other map. The same predicate the emitter applies per pixel below.
  function automatic logic rmask_bit(input logic [9:0] x);
    logic [15:0] w;
    w = row_mask[{x[8:7], 4'd0} +: 16];
    return w[4'd15 - x[6:3]];
  endfunction
  function automatic logic split_bit(input logic [9:0] x);
    return split_en && ((x < {1'b0, split_x}) == split_right);
  endfunction
  function automatic logic pmask(input logic [9:0] x);
    return rmask_bit(x) | layer_off | split_bit(x);
  endfunction

  // A WHOLE COLUMN IS INVISIBLE when one cause covers all of it. A column spans
  // at most two 8-pixel mask columns, so the row mask covers it when both end
  // pixels' bits are set; the split is monotonic in x, so it covers it when
  // both end pixels are on the far side. NOT pmask(first) && pmask(last): the
  // two ends can be masked by DIFFERENT causes with visible pixels between -
  // the split boundary inside a column whose right half the row mask hides.
  // The fuzz in tb_m1_tile_fetch found exactly that. A column masked by a mix
  // of causes is simply fetched, which is always correct.
  logic p_invis;
  assign p_invis = layer_off
                || (rmask_bit(px) && rmask_bit(p_last))
                || (split_bit(px) && split_bit(p_last));

  // ---------------------------------------------------- descriptor queue
  // Pointers one bit wider than the index so full and empty differ. Flip-flops
  // by instruction, not left to inference: four entries read at two places is
  // two MLAB copies if Quartus decides it is a memory, and MLAB is ALM.
  //
  // No character address is queued: it is the tile number and the row, wired
  // side by side ({tile_num, row, 0} - the low four bits of tile_num<<4 are
  // zero, so the decode's "+" is a concatenation), so the requester rebuilds it
  // from the queued tile word for nothing.
  (* ramstyle = "logic" *) logic [1:0]  dq_kind [4];
  (* ramstyle = "logic" *) logic [15:0] dq_tw   [4];
  logic [2:0]  q_wr, q_iss, q_rd;
  wire  [2:0]  q_used = q_wr - q_rd;
  wire         q_full = (q_used == 3'd4);
  logic        q_push;
  logic [1:0]  q_push_kind;
  logic        q_pop;

  // ------------------------------------------------------------ data queue
  (* ramstyle = "logic" *) logic [31:0] cd [2];
  logic [1:0]  cd_wr, cd_rd;          // one bit wider than the index
  wire  [1:0]  cd_used = cd_wr - cd_rd;
  logic        cd_pop;

  // ------------------------------------------------------------ lookahead
  always_comb begin
    q_push      = 1'b0;
    q_push_kind = K_FETCH;
    if (pst == P_ADDR && !q_full && p_invis) begin
      q_push = 1'b1; q_push_kind = K_INVIS;
    end else if (pst == P_DATA && !q_full) begin
      q_push = 1'b1;
      q_push_kind = (p_last_v && f_char_addr == p_last_ca) ? K_REPEAT : K_FETCH;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pst <= P_IDLE; px <= '0; p_last_ca <= '0; p_last_v <= 1'b0;
      q_wr <= '0; tw_nonblank <= 1'b0;
      for (int i = 0; i < 4; i++) begin dq_kind[i] <= K_INVIS; dq_tw[i] <= '0; end
    end else if (start) begin
      // Nothing survives a scanline: a tile address repeats across lines when
      // the map row is unchanged, so a retained row would be the previous
      // line's.
      pst <= P_ADDR; px <= '0; p_last_v <= 1'b0; q_wr <= '0;
      tw_nonblank <= 1'b0;
    end else begin
      tw_nonblank <= 1'b0;   // one-cycle pulse; see the port comment
      if (q_push) begin
        dq_kind[q_wr[1:0]] <= q_push_kind;
        dq_tw[q_wr[1:0]]   <= tram_data;
        q_wr <= q_wr + 3'd1;
        if (q_push_kind != K_INVIS) begin
          p_last_ca <= f_char_addr;
          p_last_v  <= 1'b1;
          // Same rule the MAME script and the frame testbench use: non-zero,
          // and not tile 0x20, the space. Counted on the words the engine
          // reads, so a column it does not need - a masked one - is not.
          tw_nonblank <= (tram_data != 16'h0000)
                      && ((tram_data & 16'h3fff) != 16'h0020);
        end
      end
      case (pst)
        P_IDLE: ;
        // The tile address is on tram_addr this cycle; its word arrives next.
        // An invisible column needs neither and is queued from here.
        P_ADDR: if (q_push) begin
                  px  <= p_next;
                  pst <= p_end ? P_IDLE : P_ADDR;
                end else if (!p_invis) pst <= P_DATA;
        P_DATA: if (q_push) begin
                  px  <= p_next;
                  pst <= p_end ? P_IDLE : P_ADDR;
                end
        default: pst <= P_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------ requester
  // q_iss passes over REPEAT and INVIS entries a cycle each and stops on a FETCH
  // until its data is back. A request rises only with room for its data.
  wire        iss_any   = (q_iss != q_wr);
  wire  [1:0] iss_kind  = dq_kind[q_iss[1:0]];
  wire  [15:0] iss_tw   = dq_tw[q_iss[1:0]];
  // m1_tile_decode's char_addr, {tile_num, 4'b0000} + {map_y[2:0], 1'b0} with
  // map_y = line + vscr: the same value, written as the wiring it is.
  wire  [8:0]  iss_my   = map_y + vscr[8:0];
  wire  [17:0] iss_ca   = {iss_tw[13:0] & tile_mask, iss_my[2:0], 1'b0};
  logic [17:0] char_addr_r;
  assign char_addr = char_addr_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_iss <= '0; char_req <= 1'b0; char_addr_r <= '0; fetches <= '0;
      cd_wr <= '0; cd[0] <= '0; cd[1] <= '0;
    end else if (start) begin
      q_iss <= '0; char_req <= 1'b0; fetches <= '0; cd_wr <= '0;
    end else begin
      if (char_req) begin
        if (char_ack) begin
          char_req         <= 1'b0;
          cd[cd_wr[0]]     <= char_data;
          cd_wr            <= cd_wr + 2'd1;
          q_iss            <= q_iss + 3'd1;
          fetches          <= fetches + 8'd1;
        end
      end else if (iss_any) begin
        if (iss_kind != K_FETCH) q_iss <= q_iss + 3'd1;
        else if (cd_used != 2'd2) begin
          // The data queue has room, so the answer will too. (Only the emitter
          // removes entries, and only this request can add one.)
          char_req    <= 1'b1;
          char_addr_r <= iss_ca;
        end
      end
    end
  end

  // -------------------------------------------------------------- emitter
  logic [9:0]  sx;        // first pixel of the group being written
  logic [3:0]  rem;       // pixels of the current tile still to come
  logic [15:0] tw_e;
  logic [31:0] ch_e;
  logic [3:0]  gn;
  logic [9:0]  left;

  // The head descriptor is ready to take once the requester has passed it. For
  // a FETCH that means its data is back - the requester passes a FETCH only on
  // its ack, pushing the data in the same edge, and they complete in order, so
  // the data queue's head is this entry's. A REPEAT or INVIS is passed in a
  // cycle; making the emitter wait for that keeps q_iss from ever falling
  // behind q_rd, which would let the lookahead overwrite an entry the requester
  // had not yet seen.
  wire  [1:0] hd_kind = dq_kind[q_rd[1:0]];
  wire        hd_ok   = (q_rd != q_iss);

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

  assign busy = (est != E_IDLE) || (pst != P_IDLE) || char_req;

  logic [2:0] e_off;
  assign e_off = 3'(sx[8:0] - hscr[8:0]);

  assign left = 10'(COLUMNS * 8) - sx;
  always_comb begin
    gn = 4'd4;
    if (rem  < gn)        gn = rem;
    if (left < 10'(gn))   gn = 4'(left);
  end

  // Four consecutive screen pixels can straddle an 8-pixel mask column, so each
  // is looked up on its own.
  logic [3:0]  px_m;
  always_comb
    for (int i = 0; i < 4; i++) px_m[i] = pmask(sx + 10'(i));

  // The take: a FETCH brings its tile word and data, a REPEAT its tile word and
  // the data already held (same character row, perhaps another colour or
  // category), an INVIS nothing at all - its pixels are all masked, and keeping
  // ch_e is what lets a REPEAT after it still find the right row.
  wire take_wait = !start && (est == E_WAIT) && hd_ok;
  logic take_emit;
  assign q_pop  = take_wait || take_emit;
  assign cd_pop = q_pop && (hd_kind == K_FETCH);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      est <= E_IDLE; sx <= '0; rem <= '0; tw_e <= '0; ch_e <= '0;
      q_rd <= '0; cd_rd <= '0;
      lb_we <= 4'd0; done <= 1'b0;
      lb_addr <= '0; lb_pal <= '0; lb_transparent <= '0; lb_prio <= '0;
      lb_masked <= '0;
    end else begin
      lb_we <= 4'd0;
      done  <= 1'b0;

      if (start) begin
        sx  <= '0;
        q_rd <= '0; cd_rd <= '0;
        est <= E_WAIT;
      end else begin
        if (q_pop) begin
          q_rd <= q_rd + 3'd1;
          if (hd_kind != K_INVIS) tw_e <= dq_tw[q_rd[1:0]];
          if (cd_pop) begin
            ch_e  <= cd[cd_rd[0]];
            cd_rd <= cd_rd + 2'd1;
          end
        end
        case (est)
          E_IDLE: ;

          E_WAIT: begin
            // Pixels of this tile still to come. Only the first tile of a
            // line is ever short, and only when hscr is not a multiple of
            // eight - the boundary moves with the scroll.
            if (take_wait) begin
              rem <= 4'd8 - {1'b0, e_off};
              est <= E_EMIT;
            end
          end

          E_EMIT: begin
            lb_we          <= 4'((4'd1 << gn) - 4'd1);
            lb_addr        <= sx[8:0];
            lb_pal         <= dec_pal;
            lb_transparent <= dec_transp | dec_disabled;
            lb_prio        <= dec_prio;
            // The mask bit alone, NOT combined with the tile's category: its
            // polarity was applied when the word was read (m1_video inverts it
            // for the odd tilemap, MAME's `if (win) m = ~m`).
            lb_masked      <= px_m;

            sx  <= sx + 10'(gn);
            rem <= rem - gn;

            if (10'(gn) >= left)      est <= E_DONE;
            // Tile finished: the next one starts aligned, eight pixels. Taken
            // here when it is ready, so a column costs two cycles, not three.
            else if ((rem - gn) == 0) begin
              if (take_emit) rem <= 4'd8;
              else           est <= E_WAIT;
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

  always_comb
    take_emit = !start && (est == E_EMIT) && (10'(gn) < left)
             && ((rem - gn) == 4'd0) && hd_ok;

endmodule
