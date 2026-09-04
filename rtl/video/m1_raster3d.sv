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
  parameter int unsigned SCR_H  = 384,
  // Quads a store bank holds. The attract pit stop needs 2,671 for its frame
  // 2500 and at 2,048 the grandstand at the end of the list fell off. With
  // the store's narrowed, split record (see m1_quad_store) a 4,096-quad bank
  // is 68 M10K where the old 2,048 was 52 - measured with make quartus
  // MOD=qs4096 - so both banks cost +32 over the old design. Ben's call,
  // 2026-09-03: "if there is space make the blocks bigger". A parameter so a
  // bench can still ask what a smaller store would drop.
  // 3,072 WITH 16-BIT VERTICES. 4,096 fitted only with 9-bit vertices, and
  // those were wrong (see m1_quad_store); with the full coordinate a
  // 3,072-quad bank is ~74 blocks, both banks ~+44 over the old design and
  // the whole core ~540 of 553. Frame 2500 needs 2,671.
  parameter int unsigned NQ     = 3072
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
  // PUBLIC so the bench can read them: both are left unconnected at the top
  // level, and without this Verilator optimises them away. They are the only
  // measurement of whether the band filler fits inside a frame, which is what
  // decides whether a completed geometry pass is handed over or waits.
  output logic [31:0] dbg_band_cycles /* verilator public_flat_rd */,
  output logic [15:0] dbg_bands /* verilator public_flat_rd */,
  // How long the last geometry pass took, start to P_READY, in clk cycles. A
  // frame is 818,133 of them, and a pass longer than that is what turns the
  // two-frame cadence into three - see prod_go. Sent to the UART as L=.
  output logic [31:0] dbg_pass_cycles /* verilator public_flat_rd */,
  // Bands presented LATE: the beam was already past the band's first row when
  // it went up, so part of it was never drawn. N= counts every presentation,
  // late or not, and read as "the consumer keeps up" while the board showed
  // bands missing in busy scenes. Free-running; the UART reads differences.
  output logic [15:0] dbg_late /* verilator public_flat_rd */,
  // Quads the store could not hold, summed over passes, and passes that walked
  // fewer than half the objects of the pass before - a list read while the
  // game was still writing it ends early, and that is a missing stadium.
  output logic [15:0] dbg_drop_total /* verilator public_flat_rd */,
  output logic [15:0] dbg_short /* verilator public_flat_rd */,
  // Vertices the store could not hold in 9+9 bits, both banks summed.
  output logic [15:0] dbg_oob /* verilator public_flat_rd */,
  // Late bands SPLIT BY INDEX: band 0 against every other band. Four
  // iterations of this defect were spent inferring which band was late from
  // a single total and from what Ben could see; the two have different
  // causes and different fixes, so the counter says which.
  output logic [15:0] dbg_late0 /* verilator public_flat_rd */,

  // The view state the geometry is actually using. Exposed because "2,001 quads
  // in both" proves the walk agrees and says nothing about the projection - two
  // renders can agree on every quad and disagree on where each one lands.
  output logic [31:0] dbg_xc, dbg_yc, dbg_zoomx, dbg_zoomy, dbg_viewx, dbg_viewy,
  // The LEFT CLIP PLANE the frustum is using, as a screen coordinate rather
  // than a float, so it can go on a 16-bit telemetry field. It should read 0
  // for ever; the left half of the 3D vanishing on the board is the shape of
  // this having latched something else. Exponent-and-mantissa to integer by
  // the same shift fp_to_int uses, truncated - a plane at 248.5 and one at
  // 248 are the same answer for this purpose.
  output logic [15:0] dbg_vx1,

  // PIXELS EMITTED INTO THE LEFT AND RIGHT HALVES OF THE SCREEN, in units of
  // 1024, free-running.
  //
  // The left half of the 3D drops out on corners and stays gone while the car
  // is parked, and every counter this design already has says the pipeline is
  // healthy while it happens: all 24 bands presented, no quads dropped, no
  // short passes, nothing clipped. So the loss is inside a band that is
  // present and on time, which is downstream of everything we can see.
  //
  // These two split the remaining possibilities in one reading. If both halves
  // are populated, the spans are being drawn and the loss is in scanout - Ben's
  // reading, and the tile overruns become the suspect. If the left is starved,
  // the spans never get emitted and the fault is upstream in geometry or fill.
  // The split is counted where the fill hands a span over, with the same clamp
  // the band buffer applies, so it measures what is actually written.
  output logic [15:0] dbg_px_l,
  output logic [15:0] dbg_px_r
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
  logic [31:0] obj_tex, obj_size;
  logic [31:0] obj_poly /* verilator public_flat_rd */;
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
  // P_IDLE IS EXCLUDED, because `start` is asserted there. A stalled walker
  // ignores everything including its own start, so stalling in P_IDLE means the
  // walk never begins - which reads as an empty display list rather than as a
  // handshake fault: zero objects, zero quads, no error.
  // Held while a colour write is still outstanding as well: the walk emits one
  // body item per cycle and an SDRAM write takes far longer, so without this the
  // second item would overwrite the first before it left.
  wire lw_stall = ((pst != P_WALK) && (pst != P_IDLE)) || w_tex_req;

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
  // The viewport RECTANGLE, which command 3 carries. Until the frustum clipper
  // arrived nothing consumed it - the fill clips to the band, so the screen
  // extents never reached anything.
  logic [31:0] vx1, vx2, vy1, vy2;
  logic        vp_dirty;

  // Indices 1..6 are xc, yc, x1, y2, x2, y1 - model1_v.cpp:1502-1507. The x
  // words are taken as they are; every y word is 383 - (word - 39), which is
  // 422 - word, because the display list gives a top-down coordinate and the
  // projection wants a bottom-up one.
  wire vp_is_y = (lw_ev_idx == 16'd2) || (lw_ev_idx == 16'd4)
              || (lw_ev_idx == 16'd6);
  wire signed [15:0] vp_int = vp_is_y
                            ? (16'sd422 - $signed(lw_ev_data[15:0]))
                            : $signed(lw_ev_data[15:0]);
  fp_from_int u_vp (.i(vp_int), .f(vp_flt));

  // ---------------------------------------------------------------- geometry
  logic        geo_start, geo_busy, geo_done;
  logic [31:0] geo_oldz_out;
  logic        mat_we;
  logic [3:0]  mat_idx;
  logic [31:0] mat_data;
  logic        q_valid /* verilator public_flat_rd */;
  logic signed [31:0] q_x0 /* verilator public_flat_rd */, q_y0 /* verilator public_flat_rd */, q_x1 /* verilator public_flat_rd */, q_y1 /* verilator public_flat_rd */, q_x2 /* verilator public_flat_rd */, q_y2 /* verilator public_flat_rd */, q_x3 /* verilator public_flat_rd */, q_y3 /* verilator public_flat_rd */;
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
    .vp_x1(vx1), .vp_x2(vx2), .vp_y1(vy1), .vp_y2(vy2), .vp_dirty(vp_dirty),
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
  logic        qs_clear, qs_sort_start;
  wire         qs_sort_busy;
  logic        qs_replay_start, qs_out_ready;
  wire         qs_replay_busy, qs_out_valid;
  logic [BW-1:0] qs_band;
  wire signed [15:0] qo_x0, qo_y0, qo_x1, qo_y1, qo_x2, qo_y2, qo_x3, qo_y3;
  wire [23:0] qo_col;
  wire        qo_moire;
  wire [15:0] qs_count, qs_dropped;

  // The store keeps 16-bit screen coordinates. The geometry emits 32-bit ones,
  // as MAME's spoint_t does, and they are truncated here - which matches the
  // reference's own overflow: fill_quad shifts s.x left by 16 into an int32, so
  // anything past +/-32768 has already wrapped by the time it is drawn.
  // TWO STORES, AND THE REASON IS THAT THE PICTURE HAS TO BE THERE EVERY FRAME.
  //
  // With one store the geometry and the band sweep cannot overlap: the geometry
  // rewrites the store the sweep is reading. So on the frame where the geometry
  // runs, NO band can be presented and the whole 3D layer vanishes - full
  // picture one frame, nothing the next, which a screen shows as a uniformly
  // half-transparent image whatever is on it. That is what the board was doing,
  // and it is not a rendering fault at all; it is a scheduling one.
  //
  // The producer builds into one store while the consumer sweeps the other, and
  // they swap at a frame boundary when the producer has a complete frame ready.
  // The sweep then runs EVERY frame - repeating the last complete geometry if a
  // new one is not ready yet, which is exactly what the reference does at its
  // 28.8 Hz list rate.
  //
  // It costs a second store, 53 M10K and about 1,000 ALM, and it only became
  // affordable when the vertex arrays stopped being duplicated - see the note
  // in m1_quad_store on the double read.
  logic        bank;                  // the store the PRODUCER is writing
  logic [1:0]  qs_sort_busy_v, qs_replay_busy_v, qs_out_valid_v;
  logic [15:0] qs_count_v [2], qs_dropped_v [2];
  logic [15:0] qs_oob_v [2] /* verilator public_flat_rd */;   // contract violations, see the store
  logic signed [15:0] qo_x0_v [2], qo_y0_v [2], qo_x1_v [2], qo_y1_v [2];
  logic signed [15:0] qo_x2_v [2], qo_y2_v [2], qo_x3_v [2], qo_y3_v [2];
  logic [23:0] qo_col_v [2];
  logic [1:0]  qo_moire_v;

  genvar k;
  generate
    for (k = 0; k < 2; k++) begin : g_store
      // Each store takes the producer's writes only when it IS the producer's
      // bank, and the consumer's replay only when it is not. Nothing else can
      // reach it, so the two roles cannot collide by construction.
      wire mine_p = (bank == 1'(k));
      m1_quad_store #(
        .NQ(NQ), .IW($clog2(NQ)),
        .BAND_H(BAND_H), .NBANDS(NBANDS), .BW(BW), .SCR_H(SCR_H)
      ) u_store (
        .clk(clk), .rst_n(rst_n),
        .clear(qs_clear && mine_p),
        .in_valid(q_valid && mine_p),
        .in_x0(q_x0[15:0]), .in_y0(q_y0[15:0]),
        .in_x1(q_x1[15:0]), .in_y1(q_y1[15:0]),
        .in_x2(q_x2[15:0]), .in_y2(q_y2[15:0]),
        .in_x3(q_x3[15:0]), .in_y3(q_y3[15:0]),
        .in_col(q_col), .in_z(q_z), .in_moire(q_moire),
        .sort_start(qs_sort_start && mine_p), .sort_busy(qs_sort_busy_v[k]),
        .replay_band(qs_band),
        .replay_start(qs_replay_start && !mine_p),
        .replay_busy(qs_replay_busy_v[k]),
        .out_ready(qs_out_ready && !mine_p), .out_valid(qs_out_valid_v[k]),
        .out_x0(qo_x0_v[k]), .out_y0(qo_y0_v[k]),
        .out_x1(qo_x1_v[k]), .out_y1(qo_y1_v[k]),
        .out_x2(qo_x2_v[k]), .out_y2(qo_y2_v[k]),
        .out_x3(qo_x3_v[k]), .out_y3(qo_y3_v[k]),
        .out_col(qo_col_v[k]), .out_moire(qo_moire_v[k]),
        .dbg_count(qs_count_v[k]), .dbg_dropped(qs_dropped_v[k]),
        .dbg_oob(qs_oob_v[k])
      );
    end
  endgenerate

  // The producer's view is its own bank; the consumer's is the other one.
  assign qs_sort_busy   = qs_sort_busy_v[bank];
  assign qs_replay_busy = qs_replay_busy_v[~bank];
  assign qs_out_valid   = qs_out_valid_v[~bank];
  assign qo_x0 = qo_x0_v[~bank];  assign qo_y0 = qo_y0_v[~bank];
  assign qo_x1 = qo_x1_v[~bank];  assign qo_y1 = qo_y1_v[~bank];
  assign qo_x2 = qo_x2_v[~bank];  assign qo_y2 = qo_y2_v[~bank];
  assign qo_x3 = qo_x3_v[~bank];  assign qo_y3 = qo_y3_v[~bank];
  assign qo_col   = qo_col_v[~bank];
  assign qo_moire = qo_moire_v[~bank];
  assign qs_count   = qs_count_v[bank];
  assign qs_dropped = qs_dropped_v[bank];

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

  // The half-screen span census. Clamped exactly as m1_raster_band clamps, so
  // a span running off either edge contributes only its visible part.
  localparam int signed HALFX = int'(SCR_W) / 2;
  wire signed [15:0] sp_x0 = fl_span_x0[15:0];
  wire signed [15:0] sp_x1 = fl_span_x1[15:0];
  wire signed [15:0] sp_l  = (sp_x0 < 16'sd0) ? 16'sd0 : sp_x0;
  wire signed [15:0] sp_r  = (sp_x1 > 16'(SCR_W) - 16'sd1) ? 16'(SCR_W) - 16'sd1
                                                           : sp_x1;
  wire               sp_ok = fl_span_valid && fl_span_ready && (sp_r >= sp_l);
  wire signed [15:0] l_hi  = (sp_r > 16'(HALFX) - 16'sd1) ? 16'(HALFX) - 16'sd1
                                                          : sp_r;
  wire signed [15:0] r_lo  = (sp_l < 16'(HALFX)) ? 16'(HALFX) : sp_l;
  wire [15:0] n_l = (sp_ok && (l_hi >= sp_l)) ? 16'(l_hi - sp_l + 16'sd1) : 16'd0;
  wire [15:0] n_r = (sp_ok && (sp_r >= r_lo)) ? 16'(sp_r - r_lo + 16'sd1) : 16'd0;

  logic [25:0] acc_l, acc_r;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_l <= '0; acc_r <= '0;
    end else begin
      acc_l <= acc_l + 26'(n_l);
      acc_r <= acc_r + 26'(n_r);
    end
  end
  assign dbg_px_l = acc_l[25:10];
  assign dbg_px_r = acc_r[25:10];

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
  logic frame_armed, beam_blank_d, swapped, swept, early_sweep;
  // True while the sweep now running was started early - before the blanking
  // edge - and therefore had a whole extra band time to fill band 0.
  wire armed_ok = !early_sweep;

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
  // BAND 0 GOES UP IN BLANKING OR NOT AT ALL, now that it has time to be
  // ready. `frame_armed` used to let a late band 0 present mid-frame, which
  // was the right trade when band 0 could only be filled inside vertical
  // blanking: better a partial band than a stalled sweep. It is the wrong
  // trade once the sweep starts a band early, because the rows band 0 covers
  // are already behind the beam and `in_disp_band` refuses to draw them - so
  // the band is invisible AND the sweep shifts behind it. Measured: with the
  // early restart and the arm still live, the board went from 10 late bands
  // a second to 48, with a middle band dropping too.
  //
  // The arm is kept for the case it was built for - a sweep that begins at
  // the blanking edge because there was nothing to hand over - and that is
  // what `armed_ok` gates.
  wire present_now = ready_valid
                  && ((want_ext == '0) ? (beam_blank || (frame_armed && armed_ok))
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
  // TWO SEQUENCERS, NOT ONE.
  //
  // The producer walks the list, runs the geometry and sorts, into its own
  // store. The consumer sweeps the 24 bands out of the other store, every
  // frame, whether or not new geometry has arrived. They swap banks at a frame
  // boundary once the producer has a complete frame ready.
  //
  // As one FSM the geometry and the sweep were in series, so the frame that
  // built geometry showed no 3D at all - the layer was on screen half the time
  // and read as uniformly transparent. Splitting them is the fix; the second
  // store is what makes the split possible.
  typedef enum logic [2:0] {
    P_IDLE, P_WALK, P_OBJ, P_OBJW, P_SORT, P_SORTW, P_READY
  } pstate_t;
  pstate_t pst /* verilator public_flat_rd */;

  typedef enum logic [2:0] {
    C_IDLE, C_CLR, C_CLRW, C_REPLAY, C_FILL, C_FILLW, C_WAIT
  } cstate_t;
  cstate_t cst /* verilator public_flat_rd */;

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
      dl_sel_s2_d <= 1'b0; fs_since_flip <= '0;
    end else begin
      dl_sel_s1 <= dl_sel;
      dl_sel_s2 <= dl_sel_s1;
      if (prod_go) dl_sel_q <= dl_sel_s2;
      dl_sel_s2_d <= dl_sel_s2;
      if (dl_sel_s2 != dl_sel_s2_d)        fs_since_flip <= '0;
      else if (frame_start && !no_flips)   fs_since_flip <= fs_since_flip + 3'd1;
    end
  end

  wire in_bands = (cst != C_IDLE);

  wire ev_present = present_now;

  // THE SWAP, at a frame boundary and only when a whole new frame is ready.
  //
  // The consumer must be between sweeps, so the picture it is showing is never
  // torn by a bank change halfway down the screen; and the producer must have a
  // complete, sorted frame. If it has not finished, the consumer simply sweeps
  // the same store again - which is right, and is what the reference does
  // between its 28.8 Hz list updates.
  // THE EDGE, and the edge is not a race.
  //
  // The consumer leaves C_IDLE on this same edge to begin its next sweep and
  // does not come back to it until that sweep ends, so "anywhere in blanking
  // while the consumer is idle" is this cycle and no other. It was written that
  // way once (2026-09-03) on the theory that the consumer reached C_IDLE a few
  // cycles late and lost a one-cycle race here; it changed nothing, and could
  // not have: the board presents all 24 bands every frame (N= on the UART,
  // 1,392 a second), which means the consumer restarts on this edge every
  // frame and is therefore always idle when it arrives. What is missing at the
  // edge, one frame in three on the board, is P_READY - see prod_go.
  // AS SOON AS THE CONSUMER IS BETWEEN SWEEPS, not at the blanking edge.
  //
  // The consumer hands band 23 off when the beam reaches band 22 and then
  // sat idle for ~30 lines until the edge, and band 0 of the next sweep only
  // began at the edge - so its clear, replay and fill had to fit inside
  // vertical blanking (40 lines). With the 3,072-quad store every band
  // replays more quads and band 0 went up late every frame: the top band of
  // the 3D missing, on the board (T= +58 a second). Swapping here is as safe
  // as at the edge: the band buffers already hold bands 22 and 23, so the
  // quad-store bank is not being read by anything, and band 0 still cannot
  // PRESENT before blanking (present_now arms it on beam_blank).
  //
  // The consumer restarts on the swap, or at the edge if there was nothing
  // to swap; both can only happen from C_IDLE, so a sweep never restarts
  // twice in a frame.
  // START THE SWEEP A BAND EARLY, so band 0 has band 23's time as well as
  // vertical blanking to clear, replay and fill.
  //
  // Band 0 is the one band whose fill has nowhere to hide: the sweep used to
  // begin at the blanking edge, so band 0 had the 40 lines of blanking -
  // about 77,000 cycles - and nothing more. On the board the worst band runs
  // 42,000 cycles in the heavy scenes, which fits, but only just, and band 0
  // was the only band Ben ever saw drop. With band 23's slot as well it has
  // about 111,000.
  //
  // Safe: the band buffers already hold bands 22 and 23 at this point, so the
  // fill buffer is free, and the quad-store bank the sweep reads is not being
  // written - the producer only writes its own bank. Band 0 still cannot
  // PRESENT before blanking, which is what keeps the picture whole.
  wire late_beam = (beam_ext >= (BW+1)'(NBANDS - 1));
  wire sweep_go  = (cst == C_IDLE) && late_beam && !swept;
  wire swap_now  = sweep_go && (pst == P_READY);
  wire ev_handoff = (cst == C_WAIT) && (!ready_valid || ev_present);
  logic [1:0] obj_got;                 // parameters collected for this object
  logic       obj_hud;

  // THE PRODUCER STARTS WHEN THE GAME PRESENTS A NEW LIST, and only otherwise
  // on a frame.
  //
  // It used to start on frame_start alone. That loses a whole frame whenever a
  // pass runs longer than one: the swap that frees the producer is at the
  // blanking EDGE, a few hundred cycles after frame_start, so a pass that
  // reached P_READY during frame k+1 was swapped out at the k+2 edge and could
  // not begin again before frame_start of k+3. Three frames a pass against the
  // game's two-frame list rate - which is the board's ~20 completed passes a
  // second against ~29 list swaps: a third of the game's frames never became
  // new geometry, and on screen the 3D advanced in jerks under a smooth 2D.
  //
  // And a pass IS longer than a frame on the board. tb_m1_raster3d measures
  // 0.95 of a frame for the reference's frame 900 with a polygon ROM that
  // answers in a cycle; the board's ROM is SDRAM shared with the V60, the tile
  // fetch and the coprocessor, and the same bench with a 64-cycle memory makes
  // the same pass 2.9 frames. tb_m1_frame's memory model keeps it just under a
  // frame, so the defect never reproduced there - which is why every earlier
  // fix was aimed at the band FILL, the sequencer that was never late.
  //
  // The list select changing is the natural trigger. Virtua Racing flips by
  // hand, every second frame, at the V60's listctl write rather than at vblank,
  // and tools/mame_flip_writes.lua shows the buffer it flips TO is finished at
  // the flip and untouched until the next one. Starting there is what MAME
  // effectively does - set_current_render_list at the next render - less the
  // wait for vblank, and it also settles the PHASE: a pass finishes before the
  // V60 flips again and starts rewriting the buffer it read, for any pass up to
  // two frames. Restarting on the swap alone would lock a two-frame cadence to
  // the game's two-frame flips in whichever phase it happened to land, and the
  // wrong phase reads a buffer the V60 is writing for the tail of every pass.
  //
  // frame_start remains the trigger for a list that has not flipped in four
  // frames - a game or a bench that does not double-buffer - which is the
  // behaviour this replaces. It is held off while flips are arriving so it can
  // never pre-empt one by a few cycles and walk the stale buffer.
  //
  // Free-running was tried before either: a pass beginning the moment its bank
  // was free walks a list the V60 is halfway through writing, and showed on the
  // board as geometry in the wrong place with vertices collapsed toward the
  // origin. The flip is precisely the moment at which that cannot happen.
  logic       dl_sel_s2_d;
  logic [2:0] fs_since_flip;       // frame pulses since the last flip, saturating
  wire  list_flipped = (dl_sel_s2 != dl_sel_q);
  wire  no_flips     = fs_since_flip[2];
  // AND NOT BEFORE THE VBLANK AFTER THE FLIP. MAME renders the list at the
  // end of the frame in which the game flipped, so the game has the rest of
  // that frame to finish whatever it writes after the flip. In attract it
  // writes nothing (tools/mame_flip_writes.lua, 992 of 994 flips); gameplay
  // was not measured, and a pass that walked a list still being written
  // would drop whole objects for a frame - which is what a stadium vanishing
  // for one frame looks like. fs_since_flip is cleared by the flip and counts
  // frame pulses after it, so "at least one" is exactly MAME's timing. The
  // cadence is unchanged: the pulse that satisfies it comes before the swap
  // that frees the producer, and the level is still true after the swap.
  wire  prod_trig    = (list_flipped && (fs_since_flip != '0))
                    || (frame_start && no_flips);
  wire  prod_go      = (pst == P_IDLE) && prod_trig;
  logic [31:0] pass_timer;
  logic [15:0] prev_objs;
  assign lw_start        = prod_go;
  assign geo_start       = (pst == P_OBJ);
  assign qs_clear        = prod_go;
  assign qs_sort_start   = (pst == P_SORT);
  assign qs_replay_start = (cst == C_REPLAY);
  assign qs_out_ready    = (cst == C_FILL) && fl_in_ready;
  assign fl_in_valid     = (cst == C_FILL) && qs_out_valid;
  always_comb begin
    bd_clear_req = '0;
    // Every band clears in full, and it costs 1,984 cycles because the band
    // memory is banked four ways and the clear writes all four at once. The
    // background clear this replaces wrote a buffer while the beam was reading
    // it - see rtl/video/m1_raster_band.sv.
    // HELD UNTIL THE CLEAR IS SEEN TO START, not pulsed for one cycle.
    // clear_busy is registered, so the first cycle of C_CLRW reads it LOW
    // whether or not the clear has begun - and the sequencer then went to the
    // replay while the clear ran on underneath, erasing spans behind the fill.
    // At 496 cycles that cost a few pixels of band 0 of the first frame; a
    // full-band clear the same way wiped the picture entirely, 95.9% of pixels
    // to zero, which is how it was found.
    if ((cst == C_CLR) || ((cst == C_CLRW) && !clr_seen))
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
  // IEEE-754 single to a small unsigned integer. Negative or huge reads as
  // 0xffff, which is a value the plane can never legitimately take and so
  // says "not a sane coordinate" rather than silently looking plausible.
  wire [7:0]  vx1_exp = vx1[30:23];
  wire [23:0] vx1_man = {1'b1, vx1[22:0]};
  wire [7:0]  vx1_sh  = 8'd150 - vx1_exp;          // 127 + 23
  assign dbg_vx1 = vx1[31]                ? 16'hffff :   // negative
                   (vx1_exp == 8'd0)      ? 16'd0    :   // zero/denormal
                   (vx1_exp >  8'd143)    ? 16'hffff :   // >= 65536
                   (vx1_exp <  8'd127)    ? 16'd0    :   // < 1.0
                   16'(vx1_man >> vx1_sh[4:0]);
  assign dbg_oob     = qs_oob_v[0] + qs_oob_v[1];
  assign dbg_quads   = qs_count;
  assign dbg_dropped = qs_dropped;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pst <= P_IDLE; cst <= C_IDLE; bank <= 1'b0;
      cur_band <= '0; obj_got <= '0; obj_hud <= 1'b0;
      ready_band <= '0; clr_seen <= 1'b0;
      frame_armed <= 1'b0; beam_blank_d <= 1'b0; swapped <= 1'b0;
      swept <= 1'b0; early_sweep <= 1'b0;
      dbg_band_cycles <= '0; dbg_bands <= '0; band_timer <= '0;
      dbg_pass_cycles <= '0; pass_timer <= '0; dbg_late <= '0; dbg_late0 <= '0;
      dbg_drop_total <= '0; dbg_short <= '0; prev_objs <= '0;
      vp_lat <= 1'b0;
      fill_buf <= 2'd0; ready_buf <= 2'd1; disp_buf <= 2'd2;
      ready_valid <= 1'b0; old_z <= '0;
      disp_band <= '0; disp_valid <= 1'b0;
      disp_tog <= 1'b0; disp_upd <= 1'b0;
      vxc <= '0; vyc <= '0; vzoomx <= '0; vzoomy <= '0;
      vx1 <= '0; vx2 <= '0; vy1 <= '0; vy2 <= '0; vp_dirty <= 1'b0;
      vviewx <= '0; vviewy <= '0; vlx <= '0; vly <= '0; vlz <= '0;
      vspec <= 1'b0;
      rlx <= '0; rly <= '0; rlz <= '0; light_pending <= 1'b0;
      lb_we <= 1'b0; lb_waddr <= '0; lb_wdata <= '0; lp_base <= '0;
      w_tex_req <= 1'b0; w_tex_addr <= '0; w_tex_data <= '0; tex_base <= '0;
      obj_tex <= '0; obj_poly <= '0; obj_size <= '0;
      mat_we <= 1'b0; mat_idx <= '0; mat_data <= '0;
      band_timer <= '0;
      bd_y0[0] <= '0; bd_y0[1] <= '0; bd_y0[2] <= '0;
      dbg_frames <= '0;
    end else begin
      mat_we <= 1'b0;
      if (cst != C_IDLE && cst != C_WAIT) band_timer <= band_timer + 32'd1;
      if (prod_go)                                pass_timer <= '0;
      else if (pst != P_IDLE && pst != P_READY)   pass_timer <= pass_timer + 32'd1;

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

      vp_lat    <= 1'b0;
      // THE FRUSTUM FOLLOWS THREE COMMANDS, NOT ONE. MAME recomputes it in
      // set_viewport, set_zoom AND set_view_translation - the ratios are
      // (edge - centre - view) / zoom, so every term has its own command.
      // Recomputing only on the viewport left the planes derived from a stale
      // zoom: a_left came out exactly right and the other three did not, which
      // is the signature of a shared divisor that changed after the fact.
      vp_dirty  <= 1'b0;
      if (lw_ev_valid && !lw_ev_body &&
          (lw_ev_kind == 8'h03 || lw_ev_kind == 8'h09 || lw_ev_kind == 8'h0c))
        vp_dirty <= 1'b1;
      if (lw_ev_valid && !lw_ev_body && lw_ev_kind == 8'h03) begin
        if (lw_ev_idx == 16'd1) vxc <= vp_flt;
        if (lw_ev_idx == 16'd2) vyc <= vp_flt;
        if (lw_ev_idx == 16'd3) vx1 <= vp_flt;
        if (lw_ev_idx == 16'd4) vy2 <= vp_flt;
        if (lw_ev_idx == 16'd5) vx2 <= vp_flt;
        if (lw_ev_idx == 16'd6) vy1 <= vp_flt;
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
            // ALL SIX ARE TAKEN NOW. The four edge words used to be read and
            // discarded, because the fill clips to the BAND and nothing needed
            // the screen extents. The frustum clipper does: MAME reduces the
            // rectangle to four ratios in set_viewport (:629) and tests every
            // vertex against them.
            if (lw_ev_idx >= 16'd1 && lw_ev_idx <= 16'd6) vp_lat <= 1'b1;
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
      if (swap_now) bank <= ~bank;
      // One sweep per frame: set when a sweep starts, cleared when the beam
      // leaves the last band, so a sweep that finishes early cannot start a
      // second one before the next frame.
      if (sweep_go)        swept <= 1'b1;
      else if (!late_beam) swept <= 1'b0;
      // Whether this sweep began before the blanking edge, which is what
      // decides if the arm is allowed to present band 0 mid-frame.
      if (sweep_go) early_sweep <= !beam_blank;
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
      // WRAPS, does not saturate. It used to stop at 0xffff, which at 1,380
      // bands a second made it readable for 47 seconds and useless after that -
      // found during the 7-minute crash capture on 2026-09-03, where the field
      // read FFFF for the entire window that mattered. A free-running counter
      // sampled once a second only needs successive DIFFERENCES to be right.
      if (ev_present) dbg_bands <= dbg_bands + 16'd1;
      // Late: band 0 outside blanking (it was armed and caught up mid-frame),
      // any other band with the beam already below its top row.
      if (ev_present && (want_ext == '0) && !beam_blank)
        dbg_late0 <= dbg_late0 + 16'd1;
      if (ev_present && (want_ext != '0) && (beam_ext > want_ext))
        dbg_late <= dbg_late + 16'd1;

      // ---- PRODUCER: list walk, geometry, sort, into store `bank`
      case (pst)
        // The transition is gated as well as the outputs. Gating only lw_start
        // left the state machine walking with a walker that was never started -
        // f=0 passes, and the layer showing nothing at all.
        P_IDLE: if (prod_trig) begin
          old_z <= '0;
          pst   <= P_WALK;
        end

        // The walk runs until it emits an object, then stops to draw it. The
        // walker holds its own position, so this is a pause and not a restart.
        P_WALK: begin
          if (lw_ev_valid && (lw_ev_kind == 8'h01 || lw_ev_kind == 8'h41)) begin
            obj_hud <= (lw_ev_kind == 8'h41);
            case (lw_ev_idx)
              16'd0: obj_tex  <= lw_ev_data;
              16'd1: obj_poly <= lw_ev_data;
              default: begin
                obj_size <= lw_ev_data;
                pst      <= P_OBJ;
              end
            endcase
          end else if (lw_done) begin
            pst <= P_SORT;
          end
        end

        P_OBJ:  pst <= P_OBJW;
        P_OBJW: if (geo_done) begin
          old_z <= geo_oldz_out;
          pst   <= P_WALK;
        end

        P_SORT:  pst <= P_SORTW;
        P_SORTW: if (!qs_sort_busy) begin
          dbg_frames      <= dbg_frames + 16'd1;
          dbg_pass_cycles <= pass_timer;
          dbg_drop_total  <= dbg_drop_total + qs_dropped;
          prev_objs       <= lw_objs;
          if (lw_objs < {1'b0, prev_objs[15:1]}) dbg_short <= dbg_short + 16'd1;
          pst             <= P_READY;
        end

        // A complete frame of quads, waiting for the consumer to reach a frame
        // boundary so the banks can swap.
        P_READY: if (swap_now) pst <= P_IDLE;

        default: pst <= P_IDLE;
      endcase

      // ---- CONSUMER: 24 bands out of store `~bank`, every frame
      case (cst)
        // Locked to the raster: a sweep starts at the top of a frame and runs
        // to the bottom, so band k is presented as the beam reaches it.
        C_IDLE: if (sweep_go) begin
          cur_band <= '0;
          cst      <= C_CLR;
        end

        C_CLR: begin
          band_timer <= '0;
          bd_y0[fill_buf] <= 16'(cur_band) * 16'(BAND_H);
          clr_seen <= 1'b0;
          cst <= C_CLRW;
        end
        C_CLRW: begin
          if (bd_clear_busy[fill_buf])      clr_seen <= 1'b1;
          else if (clr_seen)                cst <= C_REPLAY;
        end

        C_REPLAY: cst <= C_FILL;

        C_FILL: begin
          if (!qs_replay_busy && !qs_out_valid) cst <= C_WAIT;
          else if (qs_out_valid && fl_in_ready) cst <= C_FILLW;
        end
        C_FILLW: if (fl_quad_done) cst <= C_FILL;

        // Filled - hand it to the ready slot. With three band buffers this
        // waits only for that slot to be free, so the fill of band N+1 starts
        // while band N is still waiting to be shown.
        C_WAIT: begin
          dbg_band_cycles <= band_timer;
          if (ev_handoff) begin
            if (cur_band == BW'(NBANDS - 1)) cst <= C_IDLE;
            else begin
              cur_band <= cur_band + BW'(1);
              cst      <= C_CLR;
            end
          end
        end

        default: cst <= C_IDLE;
      endcase
    end
  end

  assign qs_band = cur_band;

endmodule
