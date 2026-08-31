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

`timescale 1ns/1ps

module m1_raster3d #(
  // THIRTY-TWO ROWS, NOT SIXTY-FOUR, AND THE REASON IS SOUND.
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
  parameter int unsigned BAND_H = 32,
  parameter int unsigned SCR_W  = 496,
  parameter int unsigned SCR_H  = 384
) (
  input  logic        clk,            // the 3D clock, 45.714 MHz
  input  logic        rst_n,

  // ---- frame control, already synchronised to clk
  input  logic        frame_start,    // one pulse at the start of vblank
  input  logic        dl_sel,         // which display list buffer to walk

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
  output logic [3:0]  disp_band,
  output logic        disp_valid,

  // ---- counted, for the overlay
  output logic [15:0] dbg_objects,
  output logic [15:0] dbg_quads,
  output logic [15:0] dbg_dropped,
  output logic [15:0] dbg_frames,

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
  wire lw_stall = (st != T_WALK) && (st != T_IDLE);

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
    .tex_addr(tex_addr), .tex_req(tex_req),
    .tex_valid(tex_valid), .tex_data(tex_data),
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
  // Two buffers: one being filled, one being displayed. `wr_buf` is the one the
  // fill writes; the scanout reads the other.
  logic        wr_buf;
  logic [1:0]  bd_clear_req, bd_clear_busy;
  logic [1:0]  bd_span_valid, bd_span_ready;
  logic signed [15:0] bd_y0 [2];
  logic [15:0] bd_rd_col [2];
  logic [1:0]  bd_rd_hit;
  logic [15:0] bd_dbg_spans [2], bd_dbg_drop [2];
  logic [31:0] bd_dbg_px [2];

  // RGB565 in the band, RGB888 out of the geometry: the band buffer is 17 bits
  // wide because that is what an M10K holds without doubling (docs/findings.md),
  // so the low bits of each channel are dropped on the way in and replaced on
  // the way out. A lit polygon's colour is already quantised by the six-bit
  // luminance, so this costs less than it appears to.
  wire [15:0] span_565 = {fl_span_col[23:19], fl_span_col[15:10], fl_span_col[7:3]};

  genvar b;
  generate
    for (b = 0; b < 2; b++) begin : g_band
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

  assign bd_span_valid[0] = fl_span_valid && (wr_buf == 1'b0);
  assign bd_span_valid[1] = fl_span_valid && (wr_buf == 1'b1);
  assign fl_span_ready    = wr_buf ? bd_span_ready[1] : bd_span_ready[0];

  // Scanout reads the buffer that is NOT being filled, and only for the rows
  // that buffer actually covers.
  wire [15:0] rd_col_sel = wr_buf ? bd_rd_col[0] : bd_rd_col[1];
  wire        rd_hit_sel = wr_buf ? bd_rd_hit[0] : bd_rd_hit[1];

  // disp_band and disp_valid are written on `clk` and read on `scan_clk`. Two
  // flops each, and the BAND INDEX IS GRAY-SAFE BY CONSTRUCTION rather than by
  // encoding: it only ever increments, and a scanline that samples the old value
  // during a change simply shows the previous band for one pixel - which is a
  // pixel that was already showing that band. A multi-bit counter crossing
  // without care would normally be a real hazard; here the consequence is bounded
  // and the alternative is a Gray code on a value the fill side also compares
  // arithmetically.
  logic [3:0] disp_band_s1, disp_band_s2;
  logic       disp_valid_s1, disp_valid_s2;
  always_ff @(posedge scan_clk) begin
    disp_band_s1  <= disp_band;  disp_band_s2  <= disp_band_s1;
    disp_valid_s1 <= disp_valid; disp_valid_s2 <= disp_valid_s1;
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
    T_BAND_CLR, T_BAND_CLRW, T_REPLAY, T_FILL, T_FILLW, T_BAND_NEXT, T_SWAP
  } state_t;
  state_t st;

  logic [BW-1:0] cur_band;
  logic [1:0] obj_got;                 // parameters collected for this object
  logic       obj_hud;

  assign lw_start        = (st == T_IDLE) && frame_start;
  assign geo_start       = (st == T_OBJ);
  assign qs_clear        = (st == T_IDLE) && frame_start;
  assign qs_sort_start   = (st == T_SORT);
  assign qs_replay_start = (st == T_REPLAY);
  assign qs_out_ready    = (st == T_FILL) && fl_in_ready;
  assign fl_in_valid     = (st == T_FILL) && qs_out_valid;
  assign bd_clear_req[0] = (st == T_BAND_CLR) && (wr_buf == 1'b0);
  assign bd_clear_req[1] = (st == T_BAND_CLR) && (wr_buf == 1'b1);
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
      vp_lat <= 1'b0;
      wr_buf <= 1'b0; old_z <= '0;
      disp_band <= '0; disp_valid <= 1'b0;
      vxc <= '0; vyc <= '0; vzoomx <= '0; vzoomy <= '0;
      vviewx <= '0; vviewy <= '0; vlx <= '0; vly <= '0; vlz <= '0;
      vspec <= 1'b0;
      rlx <= '0; rly <= '0; rlz <= '0; light_pending <= 1'b0;
      lb_we <= 1'b0; lb_waddr <= '0; lb_wdata <= '0; lp_base <= '0;
      obj_tex <= '0; obj_poly <= '0; obj_size <= '0;
      mat_we <= 1'b0; mat_idx <= '0; mat_data <= '0;
      bd_y0[0] <= '0; bd_y0[1] <= '0;
      dbg_frames <= '0;
    end else begin
      mat_we <= 1'b0;

      // ---- display-list events. Latched wherever the walk is, because a
      // command changes state for every object that follows it.
      // The viewport centre, converted and latched. Driven from the event and
      // taken the same cycle, since fp_from_int is combinational.
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
        T_BAND_CLR: begin
          bd_y0[wr_buf] <= 16'(cur_band) * 16'(BAND_H);
          st <= T_BAND_CLRW;
        end
        T_BAND_CLRW: if (!bd_clear_busy[wr_buf]) st <= T_REPLAY;

        T_REPLAY: st <= T_FILL;

        T_FILL: begin
          if (!qs_replay_busy && !qs_out_valid) st <= T_BAND_NEXT;
          else if (qs_out_valid && fl_in_ready) st <= T_FILLW;
        end
        T_FILLW: if (fl_quad_done) st <= T_FILL;

        T_BAND_NEXT: begin
          // Hand this band to the scanout and start the next one in the other
          // buffer. The display side reads whichever buffer is not `wr_buf`.
          wr_buf     <= ~wr_buf;
          disp_band  <= 4'(cur_band);
          disp_valid <= 1'b1;
          if (cur_band == BW'(NBANDS - 1)) st <= T_IDLE;
          else begin
            cur_band <= cur_band + BW'(1);
            st       <= T_BAND_CLR;
          end
        end

        default: st <= T_IDLE;
      endcase
    end
  end

  assign qs_band = cur_band;

endmodule
