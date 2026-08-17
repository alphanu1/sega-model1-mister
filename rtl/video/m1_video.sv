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
// 2D video path: four tilemap layers, line buffered, mixed, palette mapped.
//
// STRUCTURE
//
// One fetch engine is instantiated, not four, and the four layers are rendered
// through it one after another into four line buffers. That is not a saving of
// three engines' worth of logic so much as a saving of arbitration: the
// character fetches all go to one SDRAM port, and four concurrent engines would
// need an arbiter in front of it whose only job would be to serialise them
// anyway. Sequential rendering makes the port, the tile RAM port and the decode
// datapath single-owner by construction.
//
// The cost is that the four layers' fetch times add rather than overlap, which
// is exactly the budget recorded in docs/m1-m4-plan.md: about 700 cycles per
// layer on repeated tiles against ~1025 available per layer, and about 1600 on
// entirely distinct ones. Text and menu screens fit; four dense layers do not.
//
// TIMING
//
// Everything runs on the core clock. `ce_pix` divides it to the 16 MHz dot
// clock MAME specifies, so scanout advances on ce_pix while fetch runs at full
// rate — which is the whole reason a line's worth of fetching fits inside a
// line's worth of display time.
//
// Rendering happens a line ahead. m1_video_timing raises `line_start` at the
// beginning of the horizontal blanking that precedes a line and names the line
// about to be rendered; the buffers written during that period are the ones
// scanned out next. Rendering into the buffer being displayed would need fetch
// to stay ahead of the beam, which at 1600 cycles for a dense layer it cannot.
//
// SCROLL REGISTERS LIVE IN TILE RAM
//
// draw_common reads them out of the tilemap's own RAM rather than from a
// separate register file:
//
//   hscr = tile_ram[0x5000 + (layer >> 1)]
//   vscr = tile_ram[0x5004 + (layer >> 1)]
//
// so they are fetched through the same port as everything else, two reads per
// layer per line, before that layer starts.

`timescale 1ns/1ps

module m1_video #(
  parameter int unsigned COLUMNS = 62
) (
  input  logic        clk,
  input  logic        ce_pix,
  input  logic        rst_n,

  input  logic [13:0] tile_mask,

  // Tile RAM, on chip. The V60 owns the other port.
  output logic [14:0] tram_addr,
  input  logic [15:0] tram_data,

  // Character RAM, external. Two consecutive words per request.
  output logic        char_req,
  output logic [17:0] char_addr,
  input  logic [31:0] char_data,
  input  logic        char_ack,

  // Palette RAM, on chip. The V60 owns the other port.
  output logic [11:0] pal_addr,
  input  logic [15:0] pal_data,

  // Video out
  output logic [7:0]  vid_r,
  output logic [7:0]  vid_g,
  output logic [7:0]  vid_b,
  output logic        vid_hs,
  output logic        vid_vs,
  output logic        vid_hb,
  output logic        vid_vb,

  output logic        vblank_irq,     // to the V60
  output logic [7:0]  dbg_fetches,    // last line's fetch count, worst layer

  // HOW OFTEN THE FETCH ENGINE MISSED ITS DEADLINE.
  //
  // A line's worth of fetching is about 3,280 core cycles at 80 MHz and four
  // dense layers want roughly 6,456, so the budget can be exceeded — see
  // docs/m1-m4-plan.md and task 2a in HANDOFF. When it is, line_start arrives
  // while the sequencer is still in Q_RUN, the bank does not flip and the
  // previous line is displayed again.
  //
  // That is a deliberate, locally-wrong-but-stable failure, and it is invisible
  // from the outside: the picture is merely wrong. Counted here so "the image
  // shifts and tears" can be told apart from "the renderer is broken" without
  // guessing, because the two look identical on a screen and have nothing in
  // common as bugs.
  output logic [15:0] dbg_overruns,

  // WHICH TILEMAPS ARE ACTUALLY REACHING THE SCREEN.
  //
  // The mixer already decides which slot wins every pixel, so counting wins per
  // tilemap per frame turns "is this layer being drawn?" from an inference into a
  // number. Both of this project's 2D faults would have been obvious at a glance
  // here: the row mask left one layer painting solid over the others, and the
  // window mode had tilemap 3 covering the picture while tilemap 2 drew nothing.
  //
  // Counted per frame and latched at vblank, so the value is a whole frame's
  // worth rather than a partial sweep.
  //
  // WHAT IT DOES AND DOES NOT PROVE. All four tilemaps are composited every
  // frame in a FIXED order — tilemap 0 nearest, 3 furthest, the 3D layer between
  // the two category passes — and each pixel shows the frontmost non-transparent
  // contributor. So this counts which layer WON a pixel, not whether a layer was
  // fetched. A layer reading zero may be drawing perfectly and simply be covered
  // by something in front of it.
  //
  // It is therefore an alarm, not a proof: a layer that has content in tile RAM
  // and wins nothing anywhere is worth investigating, and both of this project's
  // 2D faults would have shown up that way. Proving the composite is RIGHT needs
  // a frame diff against the reference, which is a different instrument.
  //
  // Saturating: a count that wraps reads as a small number and says the opposite
  // of what happened.
  //
  // EIGHTEEN BITS, NOT SIXTEEN. A full visible frame is 496 x 384 = 190,464
  // pixels, so a 16-bit counter saturates at 65,535 — barely a third of one
  // screen. That is not a corner case: a layer painting an opaque fill over
  // everything, which is the exact fault this was built to find, pins at the
  // maximum and reads identically to a layer covering a small window. It did,
  // and the saturated value was quoted as evidence for a frame.
  output logic [17:0] dbg_layer_px [4],

  // The window/split-scroll control register for each PAIR, latched as the
  // renderer reads it. dbg_layer_px says a layer covered the screen; this says
  // whether the game asked for a split and where, which separates "the game set
  // a mode we implement wrongly" from "we invented a split it never requested".
  output logic [15:0] dbg_ctrl [2]
);

  // ------------------------------------------------------------- timing
  logic [9:0] hcnt, vcnt;
  logic       hblank, vblank, visible, line_start, vblank_start;
  logic       hsync_i, vsync_i;
  logic [8:0] line_number;

  m1_video_timing timing (
    .clk(clk), .ce_pix(ce_pix), .rst_n(rst_n),
    .hcnt(hcnt), .vcnt(vcnt),
    .hblank(hblank), .vblank(vblank),
    .hsync(hsync_i), .vsync(vsync_i), .visible(visible),
    .line_start(line_start), .line_number(line_number),
    .vblank_start(vblank_start)
  );

  assign vblank_irq  = vblank_start;

  // Per-tilemap visible-pixel census. mix_src encodes 0-3 as a tilemap's
  // category-1 win and 4-7 as its category-0 win, so both fold onto the same
  // tilemap. 8 is the 3D layer and 15 the backdrop; neither is a tilemap.
  logic [17:0] px_acc [4];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) begin px_acc[i] <= '0; dbg_layer_px[i] <= '0; end
    end else begin
      if (vblank_start) begin
        for (int i = 0; i < 4; i++) begin
          dbg_layer_px[i] <= px_acc[i];
          px_acc[i]       <= '0;
        end
      end else if (ce_pix && visible && mix_src < 4'd8) begin
        if (px_acc[mix_src[1:0]] != 18'h3ffff)
          px_acc[mix_src[1:0]] <= px_acc[mix_src[1:0]] + 18'd1;
      end
    end
  end

  // ------------------------------------------------------- line buffers
  // Double buffered: `bank` is written while ~bank is displayed.
  logic bank;
  logic [14:0] rd_q [4];              // {masked, prio, transparent, pal_index}

  // EIGHT SEPARATE RAMS, NOT ONE ARRAY INDEXED BY BANK
  //
  // The obvious form is `logic [14:0] lbuf [2][4][512]` written at
  // lbuf[bank][cur_layer][...] and read at lbuf[~bank][L][...]. Quartus cannot
  // infer block RAM from that: the bank index is a signal rather than a
  // constant, so the write is a dynamic selection across both banks and the
  // read is a four-way dynamic select on top. It synthesises the whole thing
  // as flip-flops — measured at 28,816 ALM and 57,658 registers with zero
  // M10K, which is 69% of the device for 57 kbit of storage.
  //
  // Split into one array per (bank, layer) with the indices resolved at
  // elaboration, each becomes an ordinary one-write one-read memory and maps to
  // a single M10K. Both banks are read every cycle at the same address and the
  // result is muxed afterwards, which costs a 14-bit mux instead of an address
  // mux and keeps the memories inferrable.
  wire [14:0] lb_q [2][4];

  // ---------------------------------------------------------- sequencer
  typedef enum logic [3:0] {
    Q_IDLE, Q_HSCR, Q_HSCR_W, Q_VSCR, Q_VSCR_W,
    Q_CTRL, Q_CTRL_W, Q_HCTRL, Q_HCTRL_W, Q_MASK, Q_MASK_W, Q_RUN, Q_NEXT
  } qstate_t;
  qstate_t q;

  logic [1:0]  cur_layer;
  logic [8:0]  cur_line;
  logic [15:0] hscr_r, vscr_r;

  // This scanline's row mask for the pair the current layer belongs to.
  //
  // segas24 keeps two tables: tilemaps 0/1 read tile_ram 0x6000 and 2/3 read
  // 0x6800, four words per scanline in both. MAME indexes them by SCREEN line,
  // not by the scrolled map line — `mask += yy1*4` walks the destination
  // rectangle — so this is cur_line, unscrolled.
  logic [63:0] mask_r;
  logic [1:0]  mask_i;

  // ---------------------------------------------- ctrl: window/split-scroll
  // The four tilemaps are two PAIRS, not four peers — MAME names them 0s/0w and
  // 1s/1w, scroll map and window map. When the pair's ctrl register has
  // bits 13:14 set, the two maps are not independent layers: the screen is
  // split and each region shows ONE of them.
  //
  // Unimplemented, this is what put a flat opaque fill over the picture on
  // hardware. Virtua Racing's attract mode sets ctrl = 0x2000, which is mode 1
  // with v = 0 — meaning MAME draws tilemap 3 across the whole screen and
  // tilemap 2 NOT AT ALL. Drawing both, with tilemap 3's category-0 pass opaque,
  // buries everything underneath it.
  logic [15:0] ctrl_r;

  // The PAIR's even hscr, read the same way ctrl is. Needed because the window
  // decision belongs to the pair, not to each map: MAME reaches that branch only
  // through the even map's draw call, so it is the even map's hscr bit 15 that
  // decides for both. Reading each map's own would let the odd one disagree.
  logic [15:0] hctrl_r;

  // Mode 1, the vertical split, from draw_common's per-line loop:
  //
  //   v = (-vscr) & 0x1ff
  //   rows 0..v-1  show `layer`,  rows v..383 show `layer ^ 1`
  //   and layer is swapped first when ((-vscr) & 0x200) is CLEAR
  //
  // So per scanline exactly one map of the pair is live and the other must not
  // draw at all.
  wire [15:0] neg_vscr = -ctrl_r;
  wire [8:0]  win_v    = neg_vscr[8:0];
  wire        win_swap = ~neg_vscr[9];
  wire        win_mode = (ctrl_r[14:13] != 2'b00);

  // Which map of the pair this scanline belongs to: 0 = the even one.
  wire        win_upper = (cur_line < win_v);
  wire        win_pick  = win_upper ? win_swap : ~win_swap;

  // WINDOW MODE WITHOUT hscr BIT 15 DRAWS NOTHING AT ALL.
  //
  // This is the shape of draw_common, and the nesting is the whole point:
  //
  //   if (ctrl & 0x6000) {              // window mode
  //       if (layer & 1) return;        // the ODD map never draws directly
  //       set_scrolly(both maps);
  //       if (hscr & 0x8000) {          // <-- and ONLY here is anything drawn
  //           switch ((ctrl & 0x6000) >> 13) { case 1: ...; case 2: case 3: ... }
  //       }
  //   } else { ... normal path, with the row mask ... }
  //
  // There is no else on that inner `if`. So with the window mode selected and
  // hscr bit 15 clear, the pair sets its scroll and draws NEITHER map.
  //
  // Measured in the reference: Virtua Racing's attract sets ctrl = 0x2000-0x23xx
  // on pair 2/3 — window mode 1 — while hscr for every tilemap stays below 0x0200,
  // so bit 15 is NEVER set. MAME therefore draws tilemaps 2 and 3 not at all, and
  // we drew tilemap 2 opaquely across all 190,464 pixels. That is where the sky
  // and sea came from: a pair the hardware does not display.
  wire        win_hs       = hctrl_r[15];
  wire        win_suppress = win_mode
                           && (!win_hs || (cur_layer[0] != win_pick));

  // Base of this layer's table. MAME picks it with `layer & 4` on the 8-way
  // draw index, which is bit 1 of the tilemap number: 0/1 -> 0x6000,
  // 2/3 -> 0x6800. Four words per scanline, so the line scales by four.
  logic [14:0] mask_base;
  always_comb
    mask_base = (cur_layer[1] ? 15'h6800 : 15'h6000) + {4'd0, cur_line, 2'd0};
  logic        f_start;
  logic        f_busy, f_done;
  logic [14:0] f_tram_addr;
  logic [7:0]  f_fetches;

  logic [3:0]       f_lb_we;
  logic [8:0]       f_lb_addr;
  logic [3:0][11:0] f_lb_pal;
  logic [3:0]       f_lb_transparent, f_lb_prio, f_lb_masked;

  // The sequencer borrows the tile RAM port to read the scroll registers, so
  // the address is muxed rather than driven straight from the fetch engine.
  logic [14:0] seq_tram_addr;
  logic        seq_owns_tram;
  assign tram_addr = seq_owns_tram ? seq_tram_addr : f_tram_addr;

  m1_tile_fetch #(.COLUMNS(COLUMNS)) fetch (
    .clk(clk), .rst_n(rst_n),
    .start(f_start), .line(cur_line), .layer(cur_layer),
    .hscr(hscr_r), .vscr(vscr_r), .tile_mask(tile_mask),
    .layer_off(win_suppress),
    .busy(f_busy), .done(f_done),
    .tram_addr(f_tram_addr), .tram_data(tram_data),
    .char_req(char_req), .char_addr(char_addr),
    .char_data(char_data), .char_ack(char_ack),
    .lb_we(f_lb_we), .lb_addr(f_lb_addr), .lb_pal(f_lb_pal),
    .lb_transparent(f_lb_transparent), .lb_prio(f_lb_prio),
    .lb_masked(f_lb_masked), .row_mask(mask_r),
    .fetches(f_fetches)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q <= Q_IDLE; cur_layer <= '0; cur_line <= '0;
      hscr_r <= '0; vscr_r <= '0; ctrl_r <= '0; f_start <= 1'b0;
      dbg_ctrl[0] <= '0; dbg_ctrl[1] <= '0;
      mask_r <= '0; mask_i <= '0;
      seq_tram_addr <= '0; seq_owns_tram <= 1'b1;
      bank <= 1'b0; dbg_fetches <= '0; dbg_overruns <= '0;
    end else begin
      f_start <= 1'b0;

      case (q)
        Q_IDLE: begin
          seq_owns_tram <= 1'b1;
          if (line_start) begin
            // Only reached when the previous line finished in time. If it did
            // not, the sequencer is still in Q_RUN and this edge is ignored —
            // see the overrun note on Q_RUN.
            cur_line    <= line_number;
            cur_layer   <= 2'd0;
            dbg_fetches <= '0;
            // Flip on the line boundary: what was just rendered becomes what
            // is displayed.
            bank        <= ~bank;
            q           <= Q_HSCR;
          end
        end

        // hscr = tile_ram[0x5000 + layer]
        Q_HSCR: begin
          seq_tram_addr <= 15'h5000 + {13'd0, cur_layer};
          q             <= Q_HSCR_W;
        end
        Q_HSCR_W: begin
          hscr_r        <= tram_data;
          seq_tram_addr <= 15'h5004 + {13'd0, cur_layer};
          q             <= Q_VSCR;
        end
        Q_VSCR: q <= Q_VSCR_W;
        Q_VSCR_W: begin
          vscr_r        <= tram_data;
          // ctrl is the PAIR's EVEN vscr, not this layer's own register:
          // MAME reads tile_ram[0x5004 + ((layer >> 1) & 2)], which for our
          // 0..3 numbering is 0x5004 + (layer & 2). One register governs both
          // maps of a pair, and reading each map's own would make the window
          // mode look inactive on the odd one.
          seq_tram_addr <= 15'h5004 + {13'd0, cur_layer[1], 1'b0};
          q             <= Q_CTRL;
        end

        Q_CTRL: q <= Q_CTRL_W;
        Q_CTRL_W: begin
          ctrl_r        <= tram_data;
          // Same value the window logic is about to act on, kept for the
          // overlay. Latched here rather than re-read at vblank so it cannot
          // disagree with what actually drove the decision.
          dbg_ctrl[cur_layer[1]] <= tram_data;
          // The pair's even hscr, for the window decision — see win_hs.
          seq_tram_addr <= 15'h5000 + {13'd0, cur_layer[1], 1'b0};
          q             <= Q_HCTRL;
        end

        Q_HCTRL: q <= Q_HCTRL_W;
        Q_HCTRL_W: begin
          hctrl_r       <= tram_data;
          seq_tram_addr <= mask_base + {13'd0, 2'd0};
          mask_i        <= 2'd0;
          q             <= Q_MASK;
        end

        // Four words, read one per pass. Eight more tile-RAM reads per line
        // than before across the four layers, against a budget measured in
        // thousands of cycles, so it does not move the deadline.
        Q_MASK: q <= Q_MASK_W;
        Q_MASK_W: begin
          // INVERTED FOR THE ODD TILEMAP, AND ONLY FOR THAT.
          //
          // draw_common computes two different things from the same expression
          // and they are one line apart:
          //
          //   uint16_t tpri = layer & 1;   // BEFORE the shift -> tile CATEGORY
          //   layer >>= 1;                 // now the tilemap, 0..3
          //   int win = layer & 1;         // AFTER the shift -> ODD tilemap
          //
          // and draw_rect then uses them as two independent gates: `if (win)
          // m = ~m` decides whether the 8-pixel column is drawn from this tilemap
          // at all, while `srct[xx] == tpri` decides which tiles inside it
          // contribute. Both categories of one tilemap therefore see the SAME
          // mask polarity, set by whether that tilemap is odd or even.
          //
          // This was implemented as `mask ^ category`, which is the same
          // expression read one line too late. The effect on an even tilemap is
          // that its category-1 tiles need the mask bit SET where MAME needs it
          // clear — so with the tables the game actually writes, every
          // category-1 tile on tilemaps 0 and 2 was suppressed. That is the
          // missing text: `INSERT COIN(S)`, `CREDIT 0` and the ranking table live
          // there, tile RAM held them all along, and the census showed tilemap 0
          // winning zero pixels for 640 consecutive frames.
          mask_r[{mask_i, 4'd0} +: 16] <= cur_layer[0] ? ~tram_data : tram_data;
          if (mask_i == 2'd3) begin
            seq_owns_tram <= 1'b0;
            f_start       <= 1'b1;
            q             <= Q_RUN;
          end else begin
            seq_tram_addr <= mask_base + {13'd0, mask_i + 2'd1};
            mask_i        <= mask_i + 2'd1;
            q             <= Q_MASK;
          end
        end

        Q_RUN: begin
          // OVERRUN
          //
          // A line's worth of fetching is 3,936 core cycles and four dense
          // layers need about 6,456, so the budget can be exceeded — see
          // docs/m1-m4-plan.md. When it is, line_start arrives while this is
          // still running.
          //
          // Ignoring it, which is what happens by virtue of not being in
          // Q_IDLE, means the bank does not flip and the line already in the
          // display buffer is shown again. That is a repeated scanline: wrong,
          // but locally wrong and stable. Flipping mid-fetch instead would
          // send the remaining writes to the buffer being displayed, tearing
          // every layer of every following line — a whole-screen failure from
          // a one-line overrun.
          // Saturating, not wrapping: a counter that rolls over reads as a
          // small number on a screen and says the opposite of what happened.
          if (line_start && !(&dbg_overruns)) dbg_overruns <= dbg_overruns + 1'd1;

          if (f_done) begin
            if (f_fetches > dbg_fetches) dbg_fetches <= f_fetches;
            q <= Q_NEXT;
          end
        end

        Q_NEXT: begin
          seq_owns_tram <= 1'b1;
          if (cur_layer == 2'd3) q <= Q_IDLE;
          else begin
            cur_layer <= cur_layer + 2'd1;
            q         <= Q_HSCR;
          end
        end

        default: q <= Q_IDLE;
      endcase
    end
  end

  // genvars declared outside the loop headers. Inline `for (genvar i = ...)` is
  // legal SystemVerilog and Verilator takes it, but Quartus 17.0 rejects it
  // with "genvar is a reserved keyword" — the same toolchain-strictness class
  // as the yosys and Icarus issues recorded in docs/rtl-conventions.md.
  //
  // FOUR LANES, SO FOUR PIXELS LAND IN ONE WRITE EVEN WHEN UNALIGNED.
  //
  // The fetch engine now emits four pixels a cycle, and they are consecutive
  // on screen but not aligned to four: the tile boundary moves with hscr. Each
  // lane holds the pixels whose screen position has that value mod 4, so four
  // consecutive positions touch each lane exactly once — with one lane pair
  // landing in the next group along. That makes it four independent
  // single-write memories rather than one memory needing four ports, which is
  // the only form Quartus will infer.
  //
  // A per-lane byte-enable would have been the obvious alternative and Quartus
  // 17.0 does not infer RAM from it at all — see rtl/m1_mainram.sv, where that
  // idiom cost 28,816 ALM before it was found.
  genvar gb, gl, gn;
  generate
    for (gb = 0; gb < 2; gb++) begin : g_bank
      for (gl = 0; gl < 4; gl++) begin : g_layer
        logic [14:0] lane_q [4];
        logic [1:0]  sel_q;

        for (gn = 0; gn < 4; gn++) begin : g_lane
          logic [14:0] mem [128];

          // Which incoming pixel belongs to this lane, and which group it
          // lands in. Pixels before the base's own lane have wrapped into the
          // next group.
          logic [1:0] widx;
          logic [8:0] wpos;
          logic [6:0] waddr;
          logic       wen;
          assign widx  = 2'(gn[1:0] - f_lb_addr[1:0]);
          // The screen position this lane is writing, then its group. Written
          // as the sum rather than "base group plus a carry" because the carry
          // form makes lane 3's comparison constant, which is true but reads
          // as a mistake and trips -Wall.
          assign wpos  = f_lb_addr + 9'(widx);
          assign waddr = wpos[8:2];
          assign wen   = f_lb_we[widx] && (bank == gb[0])
                       && (cur_layer == 2'(gl));

          always_ff @(posedge clk) begin
            if (wen)
              mem[waddr] <= {f_lb_masked[widx], f_lb_prio[widx], f_lb_transparent[widx],
                             f_lb_pal[widx]};
            lane_q[gn] <= mem[hcnt[8:2]];
          end
        end

        // The select is registered from the same hcnt as the address, so the
        // mux picks the lane that address fetched. Registering only the data
        // and muxing with live hcnt would take the wrong lane for the cycles
        // between a counter step and the read landing.
        always_ff @(posedge clk) sel_q <= hcnt[1:0];
        assign lb_q[gb][gl] = lane_q[sel_q];
      end
    end
  endgenerate

  // Writes go to the bank being rendered; reads come from the other one.
  always_comb
    for (int L = 0; L < 4; L++) rd_q[L] = lb_q[bank ? 0 : 1][L];

  // ------------------------------------------------------------- mixing
  logic [3:0][11:0] mix_pal;
  logic [3:0]       mix_transp, mix_prio, mix_masked;

  always_comb begin
    for (int L = 0; L < 4; L++) begin
      mix_pal[L]    = rd_q[L][11:0];
      mix_transp[L] = rd_q[L][12];
      mix_prio[L]   = rd_q[L][13];
      mix_masked[L] = rd_q[L][14];
    end
  end

  logic [11:0] mixed;
  logic [3:0]  mix_src;

  m1_tile_mixer mixer (
    .pal_index(mix_pal),
    .transparent(mix_transp),
    .prio(mix_prio),
    .masked(mix_masked),
    .disabled(4'b0000),          // already folded into transparent by the fetch
    .poly_index(12'd0),
    .poly_valid(1'b0),           // no 3D until M2
    .backdrop(12'd0),
    .pixel(mixed),
    .source(mix_src)
  );

  assign pal_addr = mixed;

  logic [7:0] pr, pg, pb;
  m1_palette pal (.entry(pal_data), .r(pr), .g(pg), .b(pb));

  // The colour for column hcnt is not ready in the same pixel it is addressed:
  // the line buffer read is registered, and so is the palette RAM. Both settle
  // easily inside one dot clock — there are several core cycles per ce_pix —
  // but the result still lands one pixel later than the counter that selected
  // it.
  //
  // So blanking is delayed by exactly the same one pixel. Without that the
  // image sits one column left of its own blanking window, which does not look
  // like a timing bug on a scaler that crops a little; it looks like the game
  // is drawing one column of garbage at the edge.
  // Everything here is delayed by exactly ONE pixel, and it has to be the same
  // one for the data and for the flags.
  //
  // `pr` is already the colour for the current hcnt — the line buffer and
  // palette reads both complete inside the pixel period — so latching it here
  // makes vid_r the colour of the column just passed, and latching `hblank`
  // alongside makes the flags describe that same column. Gating the data with
  // a second delayed copy of `visible` instead put the colour one pixel behind
  // its own blanking, which blanked the first visible column of every line and
  // left the rest correct: a single black column down the left edge.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vid_r <= '0; vid_g <= '0; vid_b <= '0;
      vid_hb <= 1'b1; vid_vb <= 1'b1; vid_hs <= 1'b0; vid_vs <= 1'b0;
    end else if (ce_pix) begin
      // Every sync and blank is delayed with the data, not just `visible`.
      // Exposing undelayed blanking beside delayed colour puts the picture one
      // column out of its own window, which a scaler renders as a stray column
      // at the edge rather than as anything recognisably a timing fault.
      vid_hb <= hblank;
      vid_vb <= vblank;
      vid_hs <= hsync_i;
      vid_vs <= vsync_i;
      vid_r <= visible ? pr : 8'd0;
      vid_g <= visible ? pg : 8'd0;
      vid_b <= visible ? pb : 8'd0;
    end
  end

endmodule
