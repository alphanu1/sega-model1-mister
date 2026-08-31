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
// The 3D layer: a display list in, a lit pixel out.
//
// Everything between those two points is here - the list walk, the geometry, the
// painter's sort, the fill and the band buffers - so the rest of the core sees
// one block with memory ports and a pixel, rather than eleven modules to wire.
//
//     m1_listwalk    the display list's command grammar
//     m1_geometry    transform, cull, project, normalize, light   (five stages,
//                    one shared multiplier/adder/divider)
//     m1_quad_store   collect, sort z-descending, replay per band
//     m1_raster_fill  quad to spans
//     m1_raster_band  two 64-row buffers, filled and displayed alternately
//
// THE CLOCK IS NOT THE CPU'S. The pool tops out at 53.25 MHz measured and the
// fill unit at 63.75, so this runs at 45.714 MHz - exactly twice clk_cpu, which
// makes the crossing to the CPU domain a clock enable rather than a handshake.
// This project has lost time twice to pulse-versus-level faults across domains;
// a synchronous ratio removes that class of bug rather than testing for it.
//
// WHAT IT DOES NOT DO YET, stated because a silent gap reads as a bug later:
//
//   * NO FRUSTUM CLIP. MAME clips against the four side planes in 3D before
//     projecting; here the fill unit's 2D clamp does the visible work, which is
//     equivalent for the pixels EXCEPT that a vertex beyond +/-32768 wraps in the
//     16.16 span arithmetic (m1_raster_fill's own header says so). Geometry that
//     leaves the screen by a long way will tear until the clipper exists.
//   * ONE FRAME OF LATENCY, AND NOT EVERY FRAME. The geometry needs about 888,000
//     cycles for a measured 2,001-quad frame and a frame is 800,000 at 45.714 MHz,
//     so a new picture arrives roughly every second frame until the walker is
//     pipelined. The band fill and the display keep running at full rate off
//     whatever the store last held, so the picture is steady, not flickering.

// THE FRAME BUDGET IS 818,133 CYCLES, NOT 397,515.
//
// The figure quoted throughout this project came from a 22.9 MHz plan for the
// 3D clock. It runs at 47.059 MHz - a PLL output of its own, 800/17 - so a frame
// at 57.52 Hz is 818,133 cycles and every per-stage budget derived from the old
// number was half of the real one. Corrected 2026-08-31, in the same change that
// measured where the geometry actually spends its cycles.

`timescale 1ns/1ps

module m1_raster3d #(
  // SIXTEEN ROWS AND THREE BUFFERS.
  //
  // A third buffer does not double the time a fill is given - it ABSORBS
  // VARIANCE. The fill runs one band ahead of the one being displayed, so a slow
  // band borrows time from a fast one instead of missing its slot. With two
  // buffers every fill had exactly one band-time and any overrun cost it, which
  // measured as one or two bands presented a frame out of twelve.
  //
  //     32 rows, 2 buffers   band-time 61,741   fill 44,868-66,819   misses
  //     16 rows, 3 buffers   band-time 30,864   fill roughly halved  absorbs
  //
  // And it FREES memory rather than costing it: 496x16x17 is 14 M10K a buffer,
  // so three are 42 against 54 for two 32-row ones. Twelve blocks back towards
  // the sound section.
  //
  // THIRTY-TWO ROWS, NOT SIXTY-FOUR, AND THE REASON WAS SOUND.
  //
  // 496x64x17 is 53 M10K a buffer and 106 for the pair; at 32 rows it is 27 and
  // 54. That is 52 blocks back, which takes the 3D layer from 145 of the 181 free
  // to 93 - leaving 88 rather than 36 for the M4 sound section, whose own M10K
  // cost is not yet measured. Guessing that 36 would have been enough was not
  // worth the risk of finding out after the rasterizer was built around it.
  //
  // The cost is twelve bands instead of six, and the store's band filter makes
  // that close to free: a quad is replayed only for the bands its rows touch, so
  // halving the band height moves a quad from touching one or two bands to two
  // or three, not from six to twelve.
  parameter int unsigned BAND_H = 16,
  parameter int unsigned SCR_W  = 496,
  parameter int unsigned SCR_H  = 384
) (
  input  logic        clk,            // the 3D clock, 45.714 MHz
  input  logic        rst_n,

  // ---- frame control, already synchronised to clk
  input  logic        frame_start,    // one pulse at the start of vblank
  // Which display list buffer to walk, live from listctl on the CPU clock, and
  // the LATCHED choice this module actually uses. The pass takes about 48% of a
  // frame and the game swaps buffers every second frame, so walking the live bit
  // builds a list out of two halves. MAME latches it once per render too
  // (set_current_render_list, model1_v.cpp:1338).
  input  logic        dl_sel,
  output logic        dl_sel_q,

  // ---- display list, 16-bit words
  output logic [14:0] dl_addr,
  output logic        dl_req,
  input  logic        dl_valid,
  input  logic [15:0] dl_data,

  // ---- polygon ROM, 32-bit words
  output logic [22:0] rom_addr,
  output logic        rom_req,
  input  logic        rom_valid,
  input  logic [31:0] rom_data,

  // ---- colour word memory, palette and colour translation. Registered reads.
  output logic [19:0] tex_addr,
  output logic        tex_req,
  output logic        tex_we,
  output logic [15:0] tex_wdata,
  input  logic        tex_valid,
  input  logic [15:0] tex_data,
  output logic [12:0] pal_addr,
  input  logic [15:0] pal_data,
  output logic [14:0] xlat_addr,
  input  logic [15:0] xlat_data,

  // The light parameter banks are INTERNAL - they are written by display-list
  // command 6, which this module already walks, so exporting them would mean
  // exporting the write path too.

  input  logic        frame_odd,

  // ---- scanout, on the VIDEO clock. The band data is static by the time it is
  // read - a band is presented only after its fill finished and the buffers
  // swapped - so only disp_band and disp_valid genuinely cross, and they are
  // synchronised here.
  input  logic        scan_clk,
  input  logic [9:0]  scan_x,
  input  logic [9:0]  scan_y,
  output logic [23:0] scan_rgb,
  output logic        scan_hit,

  // Which band the readable buffer currently holds, and whether it holds
  // anything at all. The scanout MUST check this: the read buffer always
  // contains SOME band, so returning its pixels for a scanline outside that
  // band draws band N's picture over band M's rows - a plausible, wrong image
  // rather than a blank one.
  output logic [5:0]  disp_band,
  output logic        disp_valid,

  // ---- counted, for the overlay
  output logic [15:0] dbg_objects,
  output logic [15:0] dbg_quads,
  output logic [15:0] dbg_dropped,
  output logic [15:0] dbg_frames,
  // How long the last band's fill took, and how many bands have been presented.
  // "One band a frame" and "twelve bands a frame" are the same picture in a
  // still and completely different on a screen.
  output logic [31:0] dbg_band_cycles,
  output logic [15:0] dbg_bands,

  // The view state the geometry is actually using. Exposed because "2,001 quads
  // in both" proves the walk agrees and says nothing about the projection - two
  // renders can agree on every quad and disagree on where each one lands.
  output logic [31:0] dbg_xc, dbg_yc, dbg_zoomx, dbg_zoomy, dbg_viewx, dbg_viewy
);

  localparam int unsigned NBANDS = (SCR_H + BAND_H - 1) / BAND_H;
  localparam int unsigned BW     = (NBANDS > 1) ? $clog2(NBANDS) : 1;

  // ---------------------------------------------------------------- view state
  // Everything the display list sets that the geometry needs. Latched as the
  // walk goes, so an object command uses whatever was most recently set - which
  // is what tgp_render does, and why the walk cannot be reordered.
  logic [31:0] vxc, vyc, vzoomx, vzoomy, vviewx, vviewy;
  logic [31:0] vlx, vly, vlz;          // NORMALIZED, as MAME stores it
  logic [31:0] rlx, rly, rlz;          // as the display list gave it
  logic        light_pending;
  logic        vspec;
  logic [31:0] obj_tex, obj_poly, obj_size;
  logic [31:0] old_z;

  // ---------------------------------------------------------------- list walk
  logic        lw_start, lw_busy, lw_done;
  logic        lw_ev_valid;
  logic [7:0]  lw_ev_kind;
  logic [15:0] lw_ev_idx;
  logic [31:0] lw_ev_data;
  logic        lw_ev_body;
  logic [15:0] lw_cmds, lw_objs, lw_words;
  logic        lw_bad, lw_over;

  logic [14:0] lw_addr;
  logic        lw_req;
  assign dl_addr = lw_addr;
  assign dl_req  = lw_req;

  // Held whenever the sequencer is not listening - which is most of a frame,
  // since drawing one object takes thousands of cycles and the walk would
  // otherwise run to the end of the list during the first one.
  //
  // T_IDLE IS EXCLUDED, because `start` is asserted there. A stalled walker
  // ignores everything including its own start, so stalling in T_IDLE means the
  // walk never begins - which reads as an empty display list rather than as a
  // handshake fault: zero objects, zero quads, no error.
  // Held while a colour write is still outstanding as well: the walk emits one
  // body item per cycle and an SDRAM write takes far longer, so without this the
  // second item would overwrite the first before it left.
  wire lw_stall = ((st != T_WALK) && (st != T_IDLE)) || w_tex_req;

  m1_listwalk u_walk (
    .clk(clk), .rst_n(rst_n),
    .start(lw_start), .stall(lw_stall), .busy(lw_busy), .done(lw_done),
    .mem_addr(lw_addr), .mem_req(lw_req),
    .mem_valid(dl_valid), .mem_data(dl_data),
    .ev_valid(lw_ev_valid), .ev_kind(lw_ev_kind),
    .ev_idx(lw_ev_idx), .ev_data(lw_ev_data), .ev_body(lw_ev_body),
    .dbg_cmds(lw_cmds), .dbg_objects(lw_objs), .dbg_words(lw_words),
    .dbg_bad_type(lw_bad), .dbg_overrun(lw_over)
  );

  // The viewport centre arrives as two 16-bit words and the projection needs
  // floats, so it is converted here - once per viewport command, not per pixel.
  logic [31:0] vp_flt;
  logic        vp_lat;

  // xc is the word as-is; yc is 383 - (word - 39), which is 422 - word.
  wire signed [15:0] vp_int = (lw_ev_idx == 16'd2)
                            ? (16'sd422 - $signed(lw_ev_data[15:0]))
                            : $signed(lw_ev_data[15:0]);
  fp_from_int u_vp (.i(vp_int), .f(vp_flt));

  // ---------------------------------------------------------------- geometry
  logic        geo_start, geo_busy, geo_done;
  logic [31:0] geo_oldz_out;
  logic        mat_we;
  logic [3:0]  mat_idx;
  logic [31:0] mat_data;
  logic        q_valid;
  logic signed [31:0] q_x0, q_y0, q_x1, q_y1, q_x2, q_y2, q_x3, q_y3;
  logic [23:0] q_col;
  logic [31:0] q_z;
  logic        q_moire;
  logic [15:0] g_rec, g_qds, g_cull, g_nolink;

  // ---------------------------------------------------------- tgp_ram writes
  //
  // DISPLAY-LIST COMMAND 4 IS THE ONLY THING THAT EVER FILLS tgp_ram, and it is
  // where every polygon's colour word comes from. Walking the list without
  // performing those writes leaves the memory holding whatever SDRAM powered up
  // with, so the geometry is perfect and every colour is noise - and nothing
  // reports an error, because a colour word has no invalid value.
  //
  // The port is shared with the geometry's reads. They cannot collide: the walk
  // is stalled whenever the geometry is running, so a command-4 upload and a
  // polygon's colour fetch are never outstanding at the same time.
  logic [19:0] geo_tex_addr;
  logic        geo_tex_req, geo_tex_valid;
  logic [19:0] w_tex_addr;
  logic        w_tex_req;
  logic [15:0] w_tex_data;
  logic [19:0] tex_base;

  assign tex_addr      = w_tex_req ? w_tex_addr : geo_tex_addr;
  assign tex_req       = w_tex_req || geo_tex_req;
  assign tex_we        = w_tex_req;
  assign tex_wdata     = w_tex_data;
  assign geo_tex_valid = tex_valid && !w_tex_req;

  // ---------------------------------------------------------------- light bank
  logic [7:0]  lp_addr;
  logic [31:0] lp_d, lp_a, lp_s;
  logic [7:0]  lp_p;
  logic        lb_we;
  logic [7:0]  lb_waddr;
  logic [31:0] lb_wdata;

  m1_lightbank u_lightbank (
    .clk(clk), .rst_n(rst_n),
    .we(lb_we), .waddr(lb_waddr), .wdata(lb_wdata),
    .raddr(lp_addr), .lp_d(lp_d), .lp_a(lp_a), .lp_s(lp_s), .lp_p(lp_p)
  );

  // Command 6's header gives a base address and a length; its BODY items are the
  // packed parameter words. ev_body is what separates them - without it the
  // address and the length would be written into the bank as two parameter
  // entries, over the top of whatever the upload was aiming at.
  logic [7:0] lp_base;

  // The borrowed normalize, used once a frame for the light vector.
  logic        nrm_valid, nrm_ready, nrm_out_valid;
  logic [31:0] nrm_ox, nrm_oy, nrm_oz;

  m1_geometry u_geo (
    .clk(clk), .rst_n(rst_n),
    .mat_we(mat_we), .mat_idx(mat_idx), .mat_data(mat_data),
    .xc(vxc), .yc(vyc), .zoomx(vzoomx), .zoomy(vzoomy),
    .viewx(vviewx), .viewy(vviewy),
    .light_x(vlx), .light_y(vly), .light_z(vlz),
    .spec_enable(vspec), .frame_odd(frame_odd),
    .start(geo_start), .in_tex_adr(obj_tex), .in_poly_adr(obj_poly),
    .in_size(obj_size), .busy(geo_busy), .done(geo_done),
    .old_z_in(old_z), .old_z_out(geo_oldz_out),
    .rom_addr(rom_addr), .rom_req(rom_req),
    .rom_valid(rom_valid), .rom_data(rom_data),
    .tex_addr(geo_tex_addr), .tex_req(geo_tex_req),
    .tex_valid(geo_tex_valid), .tex_data(tex_data),
    .lp_addr(lp_addr), .lp_d(lp_d), .lp_a(lp_a), .lp_s(lp_s), .lp_p(lp_p),
    .pal_addr(pal_addr), .pal_data(pal_data),
    .xlat_addr(xlat_addr), .xlat_data(xlat_data),
    .q_valid(q_valid),
    .q_x0(q_x0), .q_y0(q_y0), .q_x1(q_x1), .q_y1(q_y1),
    .q_x2(q_x2), .q_y2(q_y2), .q_x3(q_x3), .q_y3(q_y3),
    .q_col(q_col), .q_z(q_z), .q_moire(q_moire),
    .dbg_records(g_rec), .dbg_quads(g_qds),
    .dbg_culled(g_cull), .dbg_nolink(g_nolink),
    .ext_nrm_valid(nrm_valid), .ext_nrm_ready(nrm_ready),
    .ext_nrm_x(rlx), .ext_nrm_y(rly), .ext_nrm_z(rlz),
    .ext_nrm_out_valid(nrm_out_valid),
    .ext_nrm_out_x(nrm_ox), .ext_nrm_out_y(nrm_oy), .ext_nrm_out_z(nrm_oz)
  );

  // ---------------------------------------------------------------- quad store
  logic        qs_clear, qs_sort_start, qs_sort_busy;
  logic        qs_replay_start, qs_replay_busy, qs_out_valid, qs_out_ready;
  logic [BW-1:0] qs_band;
  logic signed [15:0] qo_x0, qo_y0, qo_x1, qo_y1, qo_x2, qo_y2, qo_x3, qo_y3;
  logic [23:0] qo_col;
  logic        qo_moire;
  logic [15:0] qs_count, qs_dropped;

  // The store keeps 16-bit screen coordinates. The geometry emits 32-bit ones,
  // as MAME's spoint_t does, and they are truncated here - which matches the
  // reference's own overflow: fill_quad shifts s.x left by 16 into an int32, so
  // anything past +/-32768 has already wrapped by the time it is drawn.
  m1_quad_store #(
    .BAND_H(BAND_H), .NBANDS(NBANDS), .BW(BW), .SCR_H(SCR_H)
  ) u_store (
    .clk(clk), .rst_n(rst_n),
    .clear(qs_clear),
    .in_valid(q_valid),
    .in_x0(q_x0[15:0]), .in_y0(q_y0[15:0]),
    .in_x1(q_x1[15:0]), .in_y1(q_y1[15:0]),
    .in_x2(q_x2[15:0]), .in_y2(q_y2[15:0]),
    .in_x3(q_x3[15:0]), .in_y3(q_y3[15:0]),
    .in_col(q_col), .in_z(q_z), .in_moire(q_moire),
    .sort_start(qs_sort_start), .sort_busy(qs_sort_busy),
    .replay_band(qs_band), .replay_start(qs_replay_start),
    .replay_busy(qs_replay_busy),
    .out_ready(qs_out_ready), .out_valid(qs_out_valid),
    .out_x0(qo_x0), .out_y0(qo_y0), .out_x1(qo_x1), .out_y1(qo_y1),
    .out_x2(qo_x2), .out_y2(qo_y2), .out_x3(qo_x3), .out_y3(qo_y3),
    .out_col(qo_col), .out_moire(qo_moire),
    .dbg_count(qs_count), .dbg_dropped(qs_dropped)
  );

  // ---------------------------------------------------------------- fill
  logic        fl_in_valid, fl_in_ready;
  logic        fl_span_valid, fl_span_ready, fl_quad_done, fl_line_case;
  logic signed [31:0] fl_span_y, fl_span_x0, fl_span_x1;
  logic [23:0] fl_span_col;
  logic        fl_span_moire;
  logic [BW-1:0] fill_band;

  // The viewport handed to the fill unit is the BAND, not the screen: clipping
  // to the band is what keeps a quad that spans several bands from writing
  // outside the one being filled.
  wire signed [31:0] band_y1 = 32'(fill_band) * 32'(BAND_H);
  wire signed [31:0] band_y2 = band_y1 + 32'(BAND_H) - 32'd1;

  m1_raster_fill u_fill (
    .clk(clk), .rst_n(rst_n),
    .in_valid(fl_in_valid), .in_ready(fl_in_ready),
    .in_x0({{16{qo_x0[15]}}, qo_x0}), .in_y0({{16{qo_y0[15]}}, qo_y0}),
    .in_x1({{16{qo_x1[15]}}, qo_x1}), .in_y1({{16{qo_y1[15]}}, qo_y1}),
    .in_x2({{16{qo_x2[15]}}, qo_x2}), .in_y2({{16{qo_y2[15]}}, qo_y2}),
    .in_x3({{16{qo_x3[15]}}, qo_x3}), .in_y3({{16{qo_y3[15]}}, qo_y3}),
    .in_col(qo_col), .in_moire(qo_moire),
    .view_x1(32'sd0), .view_x2(32'(SCR_W) - 32'sd1),
    .view_y1(band_y1), .view_y2(band_y2),
    .span_valid(fl_span_valid), .span_ready(fl_span_ready),
    .span_y(fl_span_y), .span_x0(fl_span_x0), .span_x1(fl_span_x1),
    .span_col(fl_span_col), .span_moire(fl_span_moire),
    .quad_done(fl_quad_done), .line_case(fl_line_case)
  );

  // ---------------------------------------------------------------- bands
  // Three slots in a ring: disp_buf is on screen, ready_buf holds the next band
  // already filled, fill_buf is being written. The fill therefore runs a band
  // ahead of the display, which is what absorbs a slow band.
  // Three slots in a ring: one displaying, one filled and waiting, one filling.
  localparam int unsigned NBUF = 3;
  logic [1:0]  fill_buf, ready_buf, disp_buf;
  logic        ready_valid;

  logic [BW-1:0]   ready_band;      // the band sitting in the ready slot
  logic            clr_seen;        // the clear has been observed to start
  logic            warm;            // every buffer has been through a display pass
  logic [NBUF-1:0] bd_clear_req, bd_clear_busy;
  logic [NBUF-1:0] bd_span_valid, bd_span_ready;
  logic signed [15:0] bd_y0 [NBUF];
  logic [15:0] bd_rd_col [NBUF];
  logic [NBUF-1:0] bd_rd_hit;
  logic [15:0] bd_dbg_spans [NBUF], bd_dbg_drop [NBUF];
  logic [31:0] bd_dbg_px [NBUF];

  // RGB565 in the band, RGB888 out of the geometry: the band buffer is 17 bits
  // wide because that is what an M10K holds without doubling (docs/findings.md),
  // so the low bits of each channel are dropped on the way in and replaced on
  // the way out. A lit polygon's colour is already quantised by the six-bit
  // luminance, so this costs less than it appears to.
  wire [15:0] span_565 = {fl_span_col[23:19], fl_span_col[15:10], fl_span_col[7:3]};

  genvar b;
  generate
    for (b = 0; b < NBUF; b++) begin : g_band
      m1_raster_band #(.WIDTH(SCR_W), .HEIGHT(BAND_H)) u_band (
        .clk(clk), .rd_clk(scan_clk), .rst_n(rst_n),
        .band_y0(bd_y0[b]),
        .clear_req(bd_clear_req[b]), .clear_busy(bd_clear_busy[b]),
        .span_valid(bd_span_valid[b]), .span_ready(bd_span_ready[b]),
        .span_y(fl_span_y[15:0]),
        .span_x0(fl_span_x0[15:0]), .span_x1(fl_span_x1[15:0]),
        .span_col(span_565), .span_moire(fl_span_moire),
        .rd_x(scan_x[$clog2(SCR_W)-1:0]),
        .rd_row(scan_y[$clog2(BAND_H)-1:0]),
        .rd_col(bd_rd_col[b]), .rd_hit(bd_rd_hit[b]),
        .dbg_spans(bd_dbg_spans[b]), .dbg_dropped(bd_dbg_drop[b]),
        .dbg_pixels(bd_dbg_px[b])
      );
    end
  endgenerate

  always_comb begin
    bd_span_valid = '0;
    bd_span_valid[fill_buf] = fl_span_valid;
  end
  assign fl_span_ready = bd_span_ready[fill_buf];

  // Scanout reads the buffer that is NOT being filled, and only for the rows
  // that buffer actually covers.
  wire [15:0] rd_col_sel = bd_rd_col[disp_buf_s2];
  wire        rd_hit_sel = bd_rd_hit[disp_buf_s2];

  // A MULTI-BIT CROSSING NEEDS A HANDSHAKE, AND "IT ONLY EVER INCREMENTS" IS
  // NOT ONE.
  //
  // This carried three values into the video clock on plain two-flop
  // synchronisers - the band index, its valid, and which of the three buffers
  // holds it - with a comment claiming the band index was "gray-safe by
  // construction, it only ever increments". An increment is not a single-bit
  // change: 7 to 8 flips four bits and 15 to 16 flips five. The two flops of a
  // multi-bit bus can resolve differently on the same edge, so the receiver can
  // see a value that is neither the old one nor the new one.
  //
  // What that looks like on a screen: at a band boundary disp_band_s2 is
  // briefly wrong, in_disp_band goes false, scan_hit drops and the 2D shows
  // through - at the same rows every frame, twenty-four times a frame. Bars of
  // transparency. And disp_buf can transiently read 2'd3, which is not one of
  // the three buffers at all.
  //
  // NONE OF THIS CAN APPEAR IN THE BENCHES. render3d ticks both clocks from one
  // edge and tb_m1_frame drives them from exact multiples, so neither has any
  // way to produce a settling failure. It is a hardware-only fault by
  // construction, which is why two throughput fixes measured well and changed
  // nothing on the board.
  //
  // So: the data is held stable, a single toggle bit crosses, and the receiver
  // captures the data when it sees the toggle change. The toggle flips one
  // clk_3d cycle AFTER the data, so by the time it has been through two
  // synchroniser flops the data has been stable for longer than the crossing.
  // The data only changes once a band - about 34,000 cycles - so there is no
  // shortage of settling time.
  logic       disp_tog;          // flips one cycle after disp_* changes
  logic       disp_upd;          // disp_* changed last cycle
  logic [2:0] disp_tog_s;        // synchroniser + edge detect on scan_clk

  logic [5:0] disp_band_s2;
  logic       disp_valid_s2;
  logic [1:0] disp_buf_s2;

  // THE BEAM'S BAND, crossed the other way - into the 3D clock - so the fill
  // sequence can follow the raster instead of free-running beside it.
  //
  // Without this the sequencer advanced a band whenever a FILL FINISHED, at
  // 58,000-66,000 cycles against a band-time of about 68,000. Nearly the same
  // rate and locked to nothing, so the two drift: the band being presented is
  // only occasionally the band the beam is drawing, and what reaches the screen
  // is mostly no 3D with stripes of it flashing through as the phase slips.
  // Measured on hardware before it was understood.
  logic [BW-1:0] beam_band_s1, beam_band_s2;
  logic [$clog2(BAND_H)-1:0] beam_row_s1, beam_row_s2;
  always_ff @(posedge clk) begin
    beam_band_s1 <= BW'(scan_y >> $clog2(BAND_H));
    beam_band_s2 <= beam_band_s1;
    beam_row_s1  <= scan_y[$clog2(BAND_H)-1:0];
    beam_row_s2  <= beam_row_s1;
  end

  // The row BEHIND the beam, on the buffer that is displaying. A row is only
  // cleared once the beam has read it, so the clear can never erase a pixel that
  // is still to be shown. The beam spends about 2,100 cycles on a row and a row
  // is 496 words, so it stays comfortably behind.
  // WHEN TO PRESENT A FILLED BAND.
  //
  //   the beam is in the band BEFORE this one   ready just in time
  //   the beam is already in this band          late; show the rest of it
  //   this is band 0 and the beam is blanking   the top of a frame
  //
  // Not "the beam has reached it exactly": a fill that runs slightly long has
  // then already missed, and waits a WHOLE FRAME for the beam to come round -
  // and being late, the next is late too. Measured as exactly one band a frame.
  //
  // And not "as soon as the displayed buffer is free" either: that presents all
  // twelve in a burst before the beam reaches any of them, which measured 8.8%
  // of the frame painted. The band has to be swapped in just ahead of the beam.
  wire [BW:0] beam_ext  = {1'b0, beam_band_s2};
  wire [BW:0] want_ext  = {1'b0, ready_band};
  wire        beam_blank = (beam_ext >= (BW+1)'(NBANDS));

  // NEVER EARLY, because a third buffer removes the reason to be.
  //
  // With two buffers the choice was between presenting when the beam arrived -
  // which a fill that ran even slightly long always missed, costing a whole
  // frame - and presenting a band ahead, which blanks the tail of the band still
  // on screen. Both were measured; the second is what shipped.
  //
  // Running a band ahead makes the exact-arrival rule affordable: the band is
  // already sitting in the ready slot when the beam gets there. `>=` rather than
  // `==` so a genuinely late band still shows its remainder instead of waiting
  // for the next frame, and band 0 waits for BLANKING rather than for the beam
  // to be at band 0 - by then its rows are already being drawn.
  // BAND 0 IS ARMED BY VBLANK, not by the beam standing on it.
  //
  // "present band 0 while the beam is blanking" cost a whole frame every pass:
  // the list walk, the sort and band 0's own fill all happen inside vblank and
  // together they outlast it, so band 0 was always ready a few lines too late
  // and waited for the NEXT vblank. Measured as 24 bands delivered over three
  // frames rather than one.
  //
  // Arming instead of comparing lets a late band 0 present as soon as it exists
  // and the bands behind it catch up immediately, since each of those is then
  // already `>=` the beam. The arm is cleared by that present, so band 0 of the
  // following pass cannot jump in over the middle of this frame.
  logic frame_armed, beam_blank_d;

  // BAND 0 GOES UP AT THE TOP OF A FRAME, whichever frame that turns out to be.
  //
  // The pass is geometry, then sort, then twenty-four beam-locked band fills.
  // The geometry alone measures 367,000 cycles and the sort 21,000, so band 0 is
  // ready around 48% of the way down the screen - and presenting it there put
  // rows 0..191 of the picture out during rows 192..383 of the raster, where
  // in_disp_band correctly refuses to draw them. Sixteen of twenty-four bands
  // presented and 257 of 384 rows painted, with every band technically on time.
  //
  // So band 0 waits for a vblank: either the one the beam is in right now, which
  // is the case when the geometry finished inside it, or the next one. The
  // picture is then always complete, and a pass that overruns costs a whole
  // frame of REFRESH rather than half a frame of PICTURE. At the measured
  // 796,000 cycles of work against 818,133 in a frame that is a complete 3D
  // layer at 28.8 Hz over a 57.5 Hz 2D one.
  //
  // Going faster than this is not a throughput problem any more: the geometry
  // cannot overlap the fill, because both use the quad store, and double
  // buffering it is 49 more M10K.
  wire present_now = ready_valid
                  && ((want_ext == '0) ? (beam_blank || frame_armed)
                                       : (!beam_blank && beam_ext >= want_ext));


  always_ff @(posedge scan_clk or negedge rst_n) begin
    if (!rst_n) begin
      disp_tog_s <= '0;
      disp_band_s2 <= '0; disp_valid_s2 <= 1'b0; disp_buf_s2 <= 2'd0;
    end else begin
      disp_tog_s <= {disp_tog_s[1:0], disp_tog};
      // Capture only on the toggle's edge, when the data behind it is settled.
      if (disp_tog_s[2] != disp_tog_s[1]) begin
        disp_band_s2  <= disp_band;
        disp_valid_s2 <= disp_valid;
        disp_buf_s2   <= disp_buf;
      end
    end
  end

  wire in_disp_band = disp_valid_s2
                   && ({6'd0, scan_y} >= 10'(disp_band_s2) * 10'(BAND_H))
                   && ({6'd0, scan_y} <  (10'(disp_band_s2) + 10'd1) * 10'(BAND_H));

  // REPLICATE THE TOP BITS, do not zero-fill. Five bits of 0x1f must expand to
  // 0xff and not 0xf8, or white is dim and every colour is biased dark by up to
  // 3%. This is what MAME's pal5bit does - (v << 3) | (v >> 2) - and the same
  // convention m1_geo_color already uses on the way in, so zero-filling here
  // undoes it on the way out.
  assign scan_rgb = {rd_col_sel[15:11], rd_col_sel[15:13],
                     rd_col_sel[10:5],  rd_col_sel[10:9],
                     rd_col_sel[4:0],   rd_col_sel[4:2]};
  assign scan_hit = rd_hit_sel && in_disp_band;

  // ---------------------------------------------------------------- sequencer
  typedef enum logic [3:0] {
    T_IDLE, T_WALK, T_OBJ, T_OBJW, T_SORT, T_SORTW,
    T_BAND_CLR, T_BAND_CLRW, T_REPLAY, T_FILL, T_FILLW,
    T_BAND_WAIT
  } state_t;
  state_t st /* verilator public_flat_rd */;

  logic [BW-1:0] cur_band;
  logic [31:0]   band_timer;

  // The two things that move a buffer round the ring. They are independent -
  // that independence IS the third buffer - and when they coincide the three
  // slots rotate in one step.
  // The band phase, as opposed to the walk and the sort that precede it.
  // Two flops, then latched at the pass start. `dl_sel` is a level from another
  // domain that only changes once every two frames, so the synchroniser is all
  // it needs; the latch is about WHEN it is sampled, not about the crossing.
  logic dl_sel_s1, dl_sel_s2;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dl_sel_s1 <= 1'b0; dl_sel_s2 <= 1'b0; dl_sel_q <= 1'b0;
    end else begin
      dl_sel_s1 <= dl_sel;
      dl_sel_s2 <= dl_sel_s1;
      if ((st == T_IDLE) && frame_start) dl_sel_q <= dl_sel_s2;
    end
  end

  wire in_bands = (st == T_BAND_CLR) || (st == T_BAND_CLRW) || (st == T_REPLAY)
               || (st == T_FILL)     || (st == T_FILLW)     || (st == T_BAND_WAIT);

  wire ev_present = present_now;
  wire ev_handoff = (st == T_BAND_WAIT) && (!ready_valid || ev_present);
  logic [1:0] obj_got;                 // parameters collected for this object
  logic       obj_hud;

  assign lw_start        = (st == T_IDLE) && frame_start;
  assign geo_start       = (st == T_OBJ);
  assign qs_clear        = (st == T_IDLE) && frame_start;
  assign qs_sort_start   = (st == T_SORT);
  assign qs_replay_start = (st == T_REPLAY);
  assign qs_out_ready    = (st == T_FILL) && fl_in_ready;
  assign fl_in_valid     = (st == T_FILL) && qs_out_valid;
  always_comb begin
    bd_clear_req = '0;
    // Every band clears in full, and it costs 1,984 cycles because the band
    // memory is banked four ways and the clear writes all four at once. The
    // background clear this replaces wrote a buffer while the beam was reading
    // it - see rtl/video/m1_raster_band.sv.
    // HELD UNTIL THE CLEAR IS SEEN TO START, not pulsed for one cycle.
    // clear_busy is registered, so the first cycle of T_BAND_CLRW reads it LOW
    // whether or not the clear has begun - and the sequencer then went to the
    // replay while the clear ran on underneath, erasing spans behind the fill.
    // At 496 cycles that cost a few pixels of band 0 of the first frame; a
    // full-band clear the same way wiped the picture entirely, 95.9% of pixels
    // to zero, which is how it was found.
    if ((st == T_BAND_CLR) || ((st == T_BAND_CLRW) && !clr_seen))
      bd_clear_req[fill_buf] = 1'b1;
  end
  assign fill_band       = cur_band;

  // Issued only while the geometry is idle, which the service also enforces.
  assign nrm_valid = light_pending && !geo_busy;

  assign dbg_xc    = vxc;
  assign dbg_yc    = vyc;
  assign dbg_zoomx = vzoomx;
  assign dbg_zoomy = vzoomy;
  assign dbg_viewx = vviewx;
  assign dbg_viewy = vviewy;

  assign dbg_objects = lw_objs;
  assign dbg_quads   = qs_count;
  assign dbg_dropped = qs_dropped;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= T_IDLE; cur_band <= '0; obj_got <= '0; obj_hud <= 1'b0;
      ready_band <= '0; clr_seen <= 1'b0;
      frame_armed <= 1'b0; beam_blank_d <= 1'b0;
      dbg_band_cycles <= '0; dbg_bands <= '0; band_timer <= '0;
      vp_lat <= 1'b0;
      fill_buf <= 2'd0; ready_buf <= 2'd1; disp_buf <= 2'd2;
      ready_valid <= 1'b0; old_z <= '0;
      disp_band <= '0; disp_valid <= 1'b0;
      disp_tog <= 1'b0; disp_upd <= 1'b0;
      vxc <= '0; vyc <= '0; vzoomx <= '0; vzoomy <= '0;
      vviewx <= '0; vviewy <= '0; vlx <= '0; vly <= '0; vlz <= '0;
      vspec <= 1'b0;
      rlx <= '0; rly <= '0; rlz <= '0; light_pending <= 1'b0;
      lb_we <= 1'b0; lb_waddr <= '0; lb_wdata <= '0; lp_base <= '0;
      w_tex_req <= 1'b0; w_tex_addr <= '0; w_tex_data <= '0; tex_base <= '0;
      obj_tex <= '0; obj_poly <= '0; obj_size <= '0;
      mat_we <= 1'b0;
      if (st == T_BAND_CLR || st == T_BAND_CLRW || st == T_REPLAY ||
          st == T_FILL || st == T_FILLW) band_timer <= band_timer + 32'd1; mat_idx <= '0; mat_data <= '0;
      bd_y0[0] <= '0; bd_y0[1] <= '0;
      dbg_frames <= '0;
    end else begin
      mat_we <= 1'b0;
      if (st == T_BAND_CLR || st == T_BAND_CLRW || st == T_REPLAY ||
          st == T_FILL || st == T_FILLW) band_timer <= band_timer + 32'd1;

      // ---- display-list events. Latched wherever the walk is, because a
      // command changes state for every object that follows it.
      // The viewport centre, converted and latched. Driven from the event and
      // taken the same cycle, since fp_from_int is combinational.
      // ---- colour word uploads, command 4, into tgp_ram
      //
      // The header gives a base address and a length; the body items are the
      // words. MAME indexes m_tgp_ram[adr - 0x40000 + i], so the base is
      // subtracted here exactly as m1_geo_walk subtracts it on the read side.
      if (w_tex_req && tex_valid) w_tex_req <= 1'b0;
      if (lw_ev_valid && lw_ev_kind == 8'h04) begin
        if (!lw_ev_body) begin
          if (lw_ev_idx == 16'd0) tex_base <= lw_ev_data[19:0] - 20'h40000;
        end else begin
          w_tex_req  <= 1'b1;
          w_tex_addr <= tex_base + {4'd0, lw_ev_idx};
          w_tex_data <= lw_ev_data[15:0];
        end
      end

      // ---- light parameter uploads, command 6
      lb_we <= 1'b0;
      if (lw_ev_valid && lw_ev_kind == 8'h06) begin
        if (!lw_ev_body) begin
          if (lw_ev_idx == 16'd0) lp_base <= lw_ev_data[7:0];
          // index 1 is the length, which the walker already honours
        end else begin
          lb_we    <= 1'b1;
          lb_waddr <= lp_base + lw_ev_idx[7:0];
          lb_wdata <= lw_ev_data;
        end
      end

      // The normalized light, when the borrowed unit returns it.
      if (nrm_out_valid && light_pending) begin
        vlx <= nrm_ox; vly <= nrm_oy; vlz <= nrm_oz;
        light_pending <= 1'b0;
      end

      vp_lat <= 1'b0;
      if (lw_ev_valid && !lw_ev_body && lw_ev_kind == 8'h03) begin
        if (lw_ev_idx == 16'd1) vxc <= vp_flt;
        if (lw_ev_idx == 16'd2) vyc <= vp_flt;
      end

      // Header parameters only. Commands 9, 0x0a, 0x0b and 0x0c have no body, so
      // this is belt and braces for them - but taking a body item as a matrix
      // element is exactly the class of mistake ev_body exists to prevent, and
      // the guard costs one gate.
      if (lw_ev_valid && !lw_ev_body) begin
        case (lw_ev_kind)
          8'h03: begin
            // Viewport, indices 0..6: a 32-bit word this design does not use,
            // then six 16-bit ones.
            //
            //     xc = readi16(+4)
            //     yc = 383 - (readi16(+6) - 39)
            //
            // MAME's own transformation, and the y one is not cosmetic: the
            // display list gives a top-down coordinate and the projection wants a
            // bottom-up one. Leaving it out puts the horizon in the wrong place
            // and tilts every object with it.
            //
            // The four edge words are read and ignored here on purpose - the fill
            // unit is clipped to the BAND rather than to the viewport, so the
            // screen extents do not reach it. They are still numbered so a later
            // consumer can take them without renumbering anything.
            if (lw_ev_idx == 16'd1) vp_lat <= 1'b1;        // xc next cycle
            else if (lw_ev_idx == 16'd2) vp_lat <= 1'b1;   // yc next cycle
          end
          8'h09: begin
            // TIMES FOUR. MAME: `set_zoom(readf(+2) * 4, readf(+4) * 4)`. Taking
            // the word as written under-zooms the entire scene by exactly four,
            // which does not look like a missing multiply - it looks like a
            // stretched picture with objects wandering off the edges, and the
            // quad count is identical either way.
            //
            // Multiplying a float by four is exact and free: add two to the
            // exponent. No pool operation, no rounding.
            if (lw_ev_idx == 16'd0)
              vzoomx <= {lw_ev_data[31], lw_ev_data[30:23] + 8'd2, lw_ev_data[22:0]};
            else
              vzoomy <= {lw_ev_data[31], lw_ev_data[30:23] + 8'd2, lw_ev_data[22:0]};
          end
          8'h0a: begin
            // The light direction is NOT unit length as the list gives it -
            // measured at 1.0941 - and MAME normalizes it on upload
            // (set_light_direction is glm::normalize). Storing it raw makes
            // every dot product 9.4% too large and every polygon one luminance
            // level too bright: a picture that looks right and is uniformly
            // washed out. Latched here and normalized below.
            if      (lw_ev_idx == 16'd0) rlx <= lw_ev_data;
            else if (lw_ev_idx == 16'd1) rly <= lw_ev_data;
            else begin rlz <= lw_ev_data; light_pending <= 1'b1; end
          end
          8'h0b: begin
            mat_we   <= 1'b1;
            mat_idx  <= lw_ev_idx[3:0];
            mat_data <= lw_ev_data;
          end
          8'h0c: begin
            if (lw_ev_idx == 16'd0) vviewx <= lw_ev_data;
            else                    vviewy <= lw_ev_data;
          end
          8'h07: vspec <= lw_ev_data[0];
          default: ;
        endcase
      end

      beam_blank_d <= beam_blank;
      // The toggle trails the data by a cycle, so the receiver's two
      // synchroniser flops always land on settled data.
      disp_upd <= 1'b0;
      if (disp_upd) disp_tog <= ~disp_tog;
      // Armed only by a vblank the BAND PHASE sees. The pass starts inside a
      // vblank of its own and the blank flag rises two synchroniser stages after
      // frame_start, so clearing on frame_start alone re-armed three cycles
      // later and changed nothing at all - measured, twice the same numbers.
      // Cleared when band 0 goes up, so the next pass's band 0 cannot land in
      // the middle of this frame.
      if (ev_present && (ready_band == '0))         frame_armed <= 1'b0;
      else if (beam_blank && !beam_blank_d && in_bands) frame_armed <= 1'b1;

      // ---- the three-slot ring
      //
      //   handoff   the fill finished a band and the ready slot is free
      //   present   the beam reached the band the ready slot holds
      //
      // Together they are a three-way rotation: what was ready goes on screen,
      // what was filling becomes ready, and what the beam has finished with
      // becomes the next fill target. Either alone is a two-way swap.
      if (ev_handoff && ev_present) begin
        disp_buf  <= ready_buf;  ready_buf <= fill_buf;  fill_buf <= disp_buf;
        disp_band <= 6'(ready_band); disp_valid <= 1'b1; disp_upd <= 1'b1;
        ready_band <= cur_band;  ready_valid <= 1'b1;
      end else if (ev_present) begin
        disp_buf  <= ready_buf;  ready_buf <= disp_buf;
        disp_band <= 6'(ready_band); disp_valid <= 1'b1; disp_upd <= 1'b1;
        ready_valid <= 1'b0;
      end else if (ev_handoff) begin
        ready_buf <= fill_buf;   fill_buf  <= ready_buf;
        ready_band <= cur_band;  ready_valid <= 1'b1;
      end
      if (ev_present && dbg_bands != 16'hffff) dbg_bands <= dbg_bands + 16'd1;

      case (st)
        T_IDLE: if (frame_start) begin
          old_z <= '0;
          st    <= T_WALK;
        end

        // The walk runs until it emits an object, then stops to draw it. The
        // walker holds its own position, so this is a pause and not a restart.
        T_WALK: begin
          if (lw_ev_valid && (lw_ev_kind == 8'h01 || lw_ev_kind == 8'h41)) begin
            obj_hud <= (lw_ev_kind == 8'h41);
            case (lw_ev_idx)
              16'd0: obj_tex  <= lw_ev_data;
              16'd1: obj_poly <= lw_ev_data;
              default: begin
                obj_size <= lw_ev_data;
                st       <= T_OBJ;
              end
            endcase
          end else if (lw_done) begin
            st <= T_SORT;
          end
        end

        T_OBJ:  st <= T_OBJW;
        T_OBJW: if (geo_done) begin
          old_z <= geo_oldz_out;
          st    <= T_WALK;
        end

        T_SORT:  st <= T_SORTW;
        T_SORTW: if (!qs_sort_busy) begin
          cur_band   <= '0;
          dbg_frames <= dbg_frames + 16'd1;
          st         <= T_BAND_CLR;
        end

        // ---- one band at a time into the write buffer
        //
        // ONLY BAND 0 CLEARS. Every other buffer was cleared behind the beam
        // while it was displaying, so the fill path does not pay for it: 15,872
        // cycles of a band-time of 68,000, against a fill measured at 60,777 to
        // 77,618. Band 0 still clears because at the very first frame neither
        // buffer has displayed anything yet.
        T_BAND_CLR: begin
          band_timer <= '0;
          bd_y0[fill_buf] <= 16'(cur_band) * 16'(BAND_H);
          clr_seen <= 1'b0;
          st <= T_BAND_CLRW;
        end
        T_BAND_CLRW: begin
          if (bd_clear_busy[fill_buf])      clr_seen <= 1'b1;
          else if (clr_seen)                st <= T_REPLAY;
        end

        T_REPLAY: st <= T_FILL;

        T_FILL: begin
          if (!qs_replay_busy && !qs_out_valid) st <= T_BAND_WAIT;
          else if (qs_out_valid && fl_in_ready) st <= T_FILLW;
        end
        T_FILLW: if (fl_quad_done) st <= T_FILL;

        // FILLED, NOW WAIT FOR THE BEAM. The band is not presented until the
        // raster actually reaches it, which is what keeps the two in step. If
        // the fill was slower than the beam this simply presents late and the
        // band is missed rather than shown in the wrong place.
        // FILLED - HAND IT TO THE READY SLOT, do not wait for the beam.
        //
        // With two buffers this state waited for the raster, because the only
        // other buffer was on screen. With three it waits only for the ready
        // slot to be free, so the fill of band N+1 starts while band N is still
        // waiting to be shown - which is what lets a slow band borrow time from
        // a fast one instead of missing outright.
        T_BAND_WAIT: begin
          dbg_band_cycles <= band_timer;   // the fill alone, before the wait
          if (ev_handoff) begin
            if (cur_band == BW'(NBANDS - 1)) begin
              st <= T_IDLE;
            end else begin
              cur_band <= cur_band + BW'(1);
              st       <= T_BAND_CLR;
            end
          end
        end

        default: st <= T_IDLE;
      endcase
    end
  end

  assign qs_band = cur_band;

endmodule
