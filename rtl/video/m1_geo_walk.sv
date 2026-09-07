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
// The polygon record walker: push_object (model1_v.cpp:856-1110).
//
// This is the piece that turns "draw object at this address" into quads. It
// reads the model out of the polygon ROM, drives the transform, the backface
// test, the projection, the normalize and the colour unit, and emits a screen-
// space quad for every record that survives.
//
// THE MODEL IS A STRIP, NOT A LIST OF POLYGONS
//
// A six-float header gives two points, and then every 10-float record adds two
// more; the quad is built from the PREVIOUS pair and the new pair. Which of the
// previous pair survives is the record's `link` field:
//
//     link 0   emit nothing, and replace both       (a new strip starts)
//     link 1   replace old_p1 with p0               (fan around old_p0)
//     link 2   replace both                         (ordinary strip advance)
//     link 3   replace old_p0 with p1
//
// link 0 is the one that matters for the budget: it emits NO quad, and 1,033 of
// 5,831 records in a peak frame are link 0 (tools/mame_poly_budget.lua).
//
// THE QUAD'S WINDING IS (old_p1, old_p0, p0, p1) AND NOT THE OBVIOUS ORDER.
// old_p1 first, then old_p0 - the previous pair reversed. The backface
// determinant is taken on (old_p1, old_p0, p0) in that same order, so getting
// the winding "right" would inverte the cull and show the inside of every model.
//
// `old_z` PERSISTS ACROSS OBJECTS, not just across records. MAME's own comment
// (model1_v.cpp:846) says netmerc's garage door inherits the previous object's
// sort z and resetting it per object made it paint through a wall. So it is an
// input and an output of this module, carried by the caller.

`timescale 1ns/1ps

module m1_geo_walk (
  input  logic        clk,
  input  logic        rst_n,

  // One object. tex_adr/poly_adr/size are the display list's command 1 payload.
  input  logic        start,
  input  logic [31:0] in_tex_adr,
  input  logic [31:0] in_poly_adr,
  input  logic [31:0] in_size,
  output logic        busy,
  output logic        done,

  // The flat-z register, carried across objects by the caller.
  input  logic [31:0] old_z_in,
  output logic [31:0] old_z_out,

  // Polygon ROM, 32-bit words. Held request, one word at a time.
  output logic [22:0] rom_addr,
  output logic        rom_req,
  input  logic        rom_valid,
  input  logic [31:0] rom_data,

  // tgp_ram, for the colour word. REQUEST/VALID, not a registered read.
  //
  // tgp_ram is 786,432 words - far too large for M10K, and declaring it as an
  // array would have Quartus build it out of flip-flops silently (CLAUDE.md
  // records that costing 28,816 ALM once). So it lives in SDRAM, which answers
  // in tens of cycles rather than one, and the walker has to wait for it.
  //
  // The single-cycle version was correct only for a block RAM and would have
  // read whatever happened to be on the bus once the memory moved.
  output logic [19:0] tex_addr,
  output logic        tex_req,
  input  logic        tex_valid,
  input  logic [15:0] tex_data,

  // Light parameter bank, indexed by the record's lightmode. Registered read.
  output logic [7:0]  lp_addr,
  input  logic [31:0] lp_d, lp_a, lp_s,
  input  logic [7:0]  lp_p,

  input  logic        frame_odd,

  // ---- sub-stage handshakes, wired to the instances in m1_geometry
  output logic        xf_valid,
  input  logic        xf_ready,
  output logic [31:0] xf_x, xf_y, xf_z,
  output logic        xf_translate,
  input  logic        xf_out_valid,
  input  logic [31:0] xf_out_x, xf_out_y, xf_out_z,

  output logic        pj_valid,
  input  logic        pj_ready,
  output logic [31:0] pj_x, pj_y, pj_z,
  input  logic        pj_out_valid,
  input  logic signed [31:0] pj_out_sx, pj_out_sy,

  output logic        dt_valid,
  input  logic        dt_ready,
  output logic [31:0] dt_p1x, dt_p1y, dt_p1z,
  output logic [31:0] dt_p2x, dt_p2y, dt_p2z,
  output logic [31:0] dt_p3x, dt_p3y, dt_p3z,
  input  logic        dt_out_valid,
  input  logic        dt_out_positive,

  output logic        nm_valid,
  input  logic        nm_ready,
  output logic [31:0] nm_x, nm_y, nm_z,
  input  logic        nm_out_valid,
  input  logic [31:0] nm_out_x, nm_out_y, nm_out_z,

  output logic        cl_valid,
  input  logic        cl_ready,
  output logic [31:0] cl_nx, cl_ny, cl_nz,
  output logic [15:0] cl_tex,
  output logic [31:0] cl_lp_d, cl_lp_a, cl_lp_s,
  output logic [7:0]  cl_lp_p,
  input  logic        cl_out_valid,
  input  logic [23:0] cl_out_rgb,

  // ---- quad out. The screen coordinates AND the camera-space points, because
  // the clipper works in camera space: MAME's planes are frustum ratios tested
  // against p.x/p.y versus p.z, not a screen rectangle.
  output logic [31:0] q_cx0, q_cy0, q_cz0, q_cx1, q_cy1, q_cz1,
  output logic [31:0] q_cx2, q_cy2, q_cz2, q_cx3, q_cy3, q_cz3,
  // HELD until the consumer takes it. The clipper can be busy for hundreds of
  // cycles on a quad that crosses a plane, so a one-cycle pulse would be lost.
  input  logic        q_ready,
  output logic        q_valid,
  output logic signed [31:0] q_x0, q_y0, q_x1, q_y1,
  output logic signed [31:0] q_x2, q_y2, q_x3, q_y3,
  output logic [23:0] q_col,
  output logic [31:0] q_z,
  output logic        q_moire,

  // Counted, for the bench and the overlay.
  output logic [15:0] dbg_records,
  output logic [15:0] dbg_quads,
  output logic [15:0] dbg_culled,
  output logic [15:0] dbg_nolink,

  // BACKFACE CULLS, FREE-RUNNING ACROSS THE WHOLE PASS.
  //
  // dbg_culled above is cleared per object, so sampling it once a second reads
  // whatever the last object happened to do. That is useless for the question
  // being asked on the board: the road and the scenery vanish while the cars
  // stay, which is what a facing test with the wrong sign does to single-sided
  // geometry. A ground plane culled wrongly disappears completely; a closed
  // object like a car always has faces pointing at the eye, so it never does.
  //
  // This one never clears, so its RATE is meaningful and a spike lines up with
  // the moment the road goes.
  output logic [15:0] dbg_culled_run
);

  // ---------------------------------------------------------------- state
  //
  // THE STAGES STREAM; THIS USED TO ISSUE THEM ONE AT A TIME.
  //
  // m1_geo_xform carries a ping-pong product bank so the adds of point N-1 run
  // while the multiplies of point N are issued, and m1_geo_project keeps the
  // reciprocal and the scale chain as separate stages for the same reason. Both
  // were built that way deliberately, and the walker then waited for out_valid
  // before issuing the next point, which used neither.
  //
  // Measured (sim/video/tb_m1_geometry.cpp, 20 objects):
  //
  //     transform   32.7% of 444 cycles a quad   three points, fully serial
  //     project     38.4%                        two points, fully serial
  //     normalize   11.7%   colour 10.8%
  //     polygon ROM  3.4% at a one-cycle memory, 40% at a twelve-cycle one
  //
  // against 44 multiplies and 43 adds a record through pipelines that retire one
  // a cycle - a floor of about 68 cycles. The stages were not the problem.
  //
  // So the record path is now a DATAFLOW SCHEDULE rather than a chain: each
  // stage is issued the moment its operands exist and the stage will take it,
  // and the record retires when everything it needs has come back. Counters
  // track issue and collection separately because results arrive in issue order
  // but not on any fixed cycle.
  //
  //     xform    P0, VN, P1 back to back as xf_ready allows
  //     project  P0 once n0 is collected, P1 once n1 is
  //     det      once n0 is collected - concurrent with both projections
  //     normal   once vn is collected, SPECULATIVELY
  //     colour   once the normal and the colour word are both back
  //
  // THE POINT COMES FIRST AND THE NORMAL SECOND, which is not the order the
  // record stores them in. p0 is what the first projection and the determinant
  // both wait on, and the projection is a 29-cycle reciprocal that cannot be
  // pipelined - so transforming the normal ahead of it put the longest pole in
  // the stage 18 cycles further out for nothing.
  //
  // AND THE NORMALIZE IS ISSUED WITHOUT WAITING FOR THE CULL. Gating it on the
  // determinant made the tail of the record det -> normalize -> colour, three
  // stages in series, when only the last two have a data dependency. It costs a
  // reciprocal square root on every culled record and takes 40 cycles off the
  // critical path of every record that is not.
  //
  // THE POLYGON ROM IS PREFETCHED. The walker asked for ten words one at a time
  // and waited for each, which at a real SDRAM latency is ten round trips and
  // 40% of the stage. The next record is read while the current one is in the
  // pipeline, so the latency is hidden entirely as long as a record takes longer
  // than ten reads - which it does by a wide margin.
  typedef enum logic [3:0] {
    W_IDLE,
    W_HDR_W, W_HDR_XF, W_HDR_XFW, W_HDR_PJ, W_HDR_PJW,
    W_REC_W, W_REC_DEC, W_REC,
    W_EMIT, W_EMITW, W_NEXT, W_DONE
  } state_t;
  state_t st /* verilator public_flat_rd */;

  logic [22:0] padr;              // polygon ROM word address, owned by the prefetch
  logic [31:0] tadr;              // texture address, incremented by flag 0x1000
  logic [31:0] nleft;             // records remaining, from `size`
  logic [31:0] rec [10];          // the record being decoded
  logic [2:0]  hdr_i;             // header point index
  logic [31:0] flags;
  logic [1:0]  link;
  logic [1:0]  zmode;
  logic        moire;
  logic        nocull;
  logic [31:0] oldz;

  // ---------------------------------------------------------------- prefetch
  // One reader for the whole module. It fills `nrec` with `pf_n` words and the
  // sequencer takes them in one cycle, then it starts on the next record
  // immediately - so the ROM is read during the arithmetic rather than between
  // records. Reading one record past the terminator is harmless and is the
  // price of not knowing where the model ends until it is decoded.
  logic [31:0] nrec [10];
  logic [3:0]  pf_wi;
  logic [3:0]  pf_n;
  logic        pf_en;
  wire         pf_ready = pf_en && (pf_wi == pf_n);

  assign rom_addr  = padr;
  assign rom_req   = pf_en && (pf_wi < pf_n);

  // ---------------------------------------------------------------- in flight
  // Issued and collected are separate counts: a stage takes an operand set on a
  // grant and answers some cycles later, and with three transforms in flight the
  // two are never equal.
  logic [1:0] xf_iss /* verilator public_flat_rd */;   // 0..3
  logic [1:0] xf_col /* verilator public_flat_rd */;
  logic [1:0] pj_iss /* verilator public_flat_rd */;   // 0..2
  logic [1:0] pj_col /* verilator public_flat_rd */;
  logic       dt_iss /* verilator public_flat_rd */;
  logic       dt_col /* verilator public_flat_rd */;
  logic       nm_iss /* verilator public_flat_rd */;
  logic       nm_col /* verilator public_flat_rd */;
  logic       cl_iss /* verilator public_flat_rd */;
  logic       cl_col /* verilator public_flat_rd */;
  logic       tx_iss;
  logic       tx_col /* verilator public_flat_rd */;
  logic       cull_known, culled;
  logic       z_done /* verilator public_flat_rd */;

  // Camera-space and screen-space points. o0/o1 are old_p0/old_p1.
  logic [31:0] o0x, o0y, o0z, o1x, o1y, o1z;
  logic signed [31:0] o0sx, o0sy, o1sx, o1sy;
  logic [31:0] n0x, n0y, n0z, n1x, n1y, n1z;
  logic signed [31:0] n0sx, n0sy, n1sx, n1sy;
  logic [31:0] vnx, vny, vnz;
  logic [31:0] nvx, nvy, nvz;      // normalized
  logic [31:0] qz;
  logic [15:0] tex_hold;      // latched, since tex_data is only valid on the ack

  assign busy      = (st != W_IDLE);
  // MAME indexes `m_tgp_ram[tex_adr - 0x40000]`, so the BASE IS SUBTRACTED here.
  // Without it every colour word is read from 0x40000 words too high, which on a
  // real dump returns 0xffff - a valid-looking colour word with the unlit bit
  // set - so the geometry is perfect and the entire picture comes out one shade.
  // Found by rendering a real frame, not by any unit test: the per-stage benches
  // supply tex_data directly and cannot see the address arithmetic.
  assign tex_addr  = tadr[19:0] - 20'h40000;
  assign old_z_out = oldz;

  // lightmode: bits 20:17 of the flags, with bit 22 selecting the second bank.
  // netmerc is the only game that sets bit 22, but it costs one wire.
  assign lp_addr = {flags[22], 3'b000, flags[20:17]};

  assign cl_nx = nvx; assign cl_ny = nvy; assign cl_nz = nvz;
  assign cl_tex = tex_hold;
  assign cl_lp_d = lp_d; assign cl_lp_a = lp_a; assign cl_lp_s = lp_s;
  assign cl_lp_p = lp_p;

  assign dt_p1x = o1x; assign dt_p1y = o1y; assign dt_p1z = o1z;
  assign dt_p2x = o0x; assign dt_p2y = o0y; assign dt_p2z = o0z;
  assign dt_p3x = n0x; assign dt_p3y = n0y; assign dt_p3z = n0z;

  assign nm_x = vnx; assign nm_y = vny; assign nm_z = vnz;

  // ---------------------------------------------------------------- float min/max
  // IEEE floats compare as sign-magnitude, so a plain integer compare is wrong
  // across zero. The standard monotonic key: negatives inverted, positives with
  // the sign bit set.
  function automatic [31:0] fkey(input logic [31:0] f);
    fkey = f[31] ? ~f : (f | 32'h80000000);
  endfunction
  function automatic [31:0] fmin(input logic [31:0] a, input logic [31:0] b);
    fmin = (fkey(a) < fkey(b)) ? a : b;
  endfunction
  function automatic [31:0] fmax(input logic [31:0] a, input logic [31:0] b);
    fmax = (fkey(a) > fkey(b)) ? a : b;
  endfunction

  // THE INNER LEVEL IS REGISTERED, WHICH IS A TIMING FIX.
  // This was fmin(fmin(o1z,o0z), fmin(n0z,n1z)) in one expression, and the two
  // levels of 32-bit compare feeding qz were m1_geometry's critical path:
  //   m1_geo_walk|o0z[20] -> qz[8], holding the module to 59.36 MHz.
  // fkey is already the cheap monotonic-key trick, so the depth was the cost,
  // not the comparator.
  //
  // Safe because the four z values are settled a cycle before they are used.
  // qz is assigned once, gated on xf_col == 2'd3, and xf_col only reaches 3 the
  // cycle AFTER the fourth column's transform retires; o0z/o1z are written in
  // the W_HDR_XFW header states earlier still. So the pair-minima registered
  // here are always the current values by the time the assignment fires.
  //
  // The 3D layer needs clk_3d at 69.2 MHz for the geometry pass to fit inside
  // one frame -- it measures len=1.47 fr at 47.059 -- so this is on the path to
  // 800/11 = 72.73, not a cosmetic gain.
  // ONLY THE O PAIR IS REGISTERED, AND THAT ASYMMETRY IS THE POINT.
  // o0z/o1z are the OBJECT header's two transformed points, written in the
  // W_HDR_XFW states well before any quad is emitted, so a registered pair
  // minimum of them is always current. n0z/n1z are the per-quad points and are
  // written right up against the xf_col == 2'd3 trigger, so registering THOSE
  // reads a stale value -- tried, and m1_geometry's real-model walk failed 1,264
  // of 44,752 while m1_listwalk's 55,791 unit checks all passed. The integration
  // test caught what the unit test could not.
  logic [31:0] zmin_o, zmax_o;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin zmin_o <= '0; zmax_o <= '0; end
    else begin
      zmin_o <= fmin(o1z, o0z);
      zmax_o <= fmax(o1z, o0z);
    end
  end
  wire [31:0] z_min4 = fmin(zmin_o, fmin(n0z, n1z));
  wire [31:0] z_max4 = fmax(zmax_o, fmax(n0z, n1z));

  // A record with no link draws nothing, so nothing but the two projections is
  // needed from it - and 1,033 of 5,831 records in a peak frame are link 0
  // (tools/mame_poly_budget.lua). Issuing the determinant, the normalize and the
  // colour for them anyway would spend a fifth of the stage's arithmetic on
  // results that are discarded.
  wire draws = (link != 2'd0);

  // Everything issued has come back. Not "everything needed", which is the
  // weaker condition and the one that let a speculative result leak forward.
  wire rec_quiet = (xf_col == 2'd3) && (pj_col == 2'd2)
                && (dt_iss == dt_col) && (nm_iss == nm_col) && (cl_iss == cl_col);

  // ---------------------------------------------------------------- transform mux
  always_comb begin
    xf_x = '0; xf_y = '0; xf_z = '0; xf_translate = 1'b1;
    if (st == W_HDR_XF) begin
      // The header's two points, straight out of the ROM.
      xf_x = rec[{1'b0, hdr_i} * 4'd3];
      xf_y = rec[{1'b0, hdr_i} * 4'd3 + 4'd1];
      xf_z = rec[{1'b0, hdr_i} * 4'd3 + 4'd2];
      xf_translate = 1'b1;
    end else begin
      case (xf_iss)
        2'd0: begin xf_x = rec[4]; xf_y = rec[5]; xf_z = rec[6]; end
        // A NORMAL IS A DIRECTION: transform_vector, no translation column.
        2'd1: begin xf_x = rec[1]; xf_y = rec[2]; xf_z = rec[3];
                    xf_translate = 1'b0; end
        // A type-2 record has only ONE new point: p1 is a copy of p0, so the
        // same model coordinates go through the transform twice rather than
        // reading words 7..9, which for that record are not a point at all.
        default: begin
          if (flags[1:0] == 2'd2) begin
            xf_x = rec[4]; xf_y = rec[5]; xf_z = rec[6];
          end else begin
            xf_x = rec[7]; xf_y = rec[8]; xf_z = rec[9];
          end
        end
      endcase
    end
  end

  assign xf_valid = (st == W_HDR_XF) || ((st == W_REC) && (xf_iss < 2'd3));

  // ---------------------------------------------------------------- projection mux
  always_comb begin
    pj_x = '0; pj_y = '0; pj_z = '0;
    if (st == W_HDR_PJ) begin
      pj_x = (hdr_i == 3'd1) ? o0x : o1x;
      pj_y = (hdr_i == 3'd1) ? o0y : o1y;
      pj_z = (hdr_i == 3'd1) ? o0z : o1z;
    end else if (pj_iss == 2'd0) begin
      pj_x = n0x; pj_y = n0y; pj_z = n0z;
    end else begin
      pj_x = n1x; pj_y = n1y; pj_z = n1z;
    end
  end

  // A projection is issued once its point has been COLLECTED, not once the
  // transform has taken it: xf_col counts n0, then vn, then n1.
  assign pj_valid = (st == W_HDR_PJ)
                 || ((st == W_REC) && (pj_iss < 2'd2)
                     && (pj_iss == 2'd0 ? (xf_col >= 2'd1) : (xf_col >= 2'd3)));

  // The determinant needs only n0, so it runs alongside both projections. The
  // cull it decides then gates the normalize, which is the one stage worth NOT
  // issuing speculatively: it is a reciprocal square root.
  assign dt_valid = (st == W_REC) && draws && !nocull && !dt_iss && (xf_col >= 2'd1);
  assign nm_valid = (st == W_REC) && draws && !nm_iss && (xf_col >= 2'd2);
  assign cl_valid = (st == W_REC) && draws && !cl_iss && nm_col && tx_col;

  // The colour word is fetched as soon as the record is decoded, because on the
  // real design it comes from SDRAM and is the second-longest wait in the stage.
  assign tex_req  = (st == W_REC) && draws && !tx_col;

  // ---------------------------------------------------------------- sequencer
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= W_IDLE;
      padr <= '0; tadr <= '0; nleft <= '0; hdr_i <= '0;
      pf_wi <= '0; pf_n <= 4'd10; pf_en <= 1'b0;
      flags <= '0; link <= '0; zmode <= '0; moire <= 1'b0; nocull <= 1'b0;
      tex_hold <= '0;
      oldz <= '0; qz <= '0;
      xf_iss <= '0; xf_col <= '0; pj_iss <= '0; pj_col <= '0;
      dt_iss <= 1'b0; dt_col <= 1'b0; nm_iss <= 1'b0; nm_col <= 1'b0;
      cl_iss <= 1'b0; cl_col <= 1'b0; tx_iss <= 1'b0; tx_col <= 1'b0;
      cull_known <= 1'b0; culled <= 1'b0; z_done <= 1'b0;
      o0x <= '0; o0y <= '0; o0z <= '0; o1x <= '0; o1y <= '0; o1z <= '0;
      o0sx <= '0; o0sy <= '0; o1sx <= '0; o1sy <= '0;
      n0x <= '0; n0y <= '0; n0z <= '0; n1x <= '0; n1y <= '0; n1z <= '0;
      n0sx <= '0; n0sy <= '0; n1sx <= '0; n1sy <= '0;
      vnx <= '0; vny <= '0; vnz <= '0; nvx <= '0; nvy <= '0; nvz <= '0;
      for (int i = 0; i < 10; i++) begin rec[i] <= '0; nrec[i] <= '0; end
      q_valid <= 1'b0; q_col <= '0; q_z <= '0; q_moire <= 1'b0;
      q_cx0 <= '0; q_cy0 <= '0; q_cz0 <= '0; q_cx1 <= '0; q_cy1 <= '0; q_cz1 <= '0;
      q_cx2 <= '0; q_cy2 <= '0; q_cz2 <= '0; q_cx3 <= '0; q_cy3 <= '0; q_cz3 <= '0;
      q_x0 <= '0; q_y0 <= '0; q_x1 <= '0; q_y1 <= '0;
      q_x2 <= '0; q_y2 <= '0; q_x3 <= '0; q_y3 <= '0;
      done <= 1'b0;
      dbg_records <= '0; dbg_quads <= '0; dbg_culled <= '0; dbg_nolink <= '0;
      dbg_culled_run <= '0;
    end else begin
      // q_valid is NOT cleared here: it is a held handshake and W_EMITW owns
      // it. Clearing it every cycle made it a one-cycle pulse, which a consumer
      // that can be busy would miss.
      done    <= 1'b0;

      // ---- the prefetch, running under everything else
      if (rom_req && rom_valid) begin
        nrec[pf_wi] <= rom_data;
        padr        <= padr + 23'd1;
        pf_wi       <= pf_wi + 4'd1;
      end

      // ---- collection, which happens whatever state the sequencer is in
      if (st == W_REC) begin
        if (xf_valid && xf_ready) xf_iss <= xf_iss + 2'd1;
        if (pj_valid && pj_ready) pj_iss <= pj_iss + 2'd1;
        if (dt_valid && dt_ready) dt_iss <= 1'b1;
        if (nm_valid && nm_ready) nm_iss <= 1'b1;
        if (cl_valid && cl_ready) cl_iss <= 1'b1;

        // COLLECT ONLY WHAT WAS ISSUED. `!collected` alone is the weaker test:
        // it accepts any pulse the stage happens to make, including one left
        // over from the previous record, and a record that issues nothing then
        // ends up with a collected flag it can never match. That deadlocked at
        // record 19 of iteration 19 with cl 0/1 - a colour collected for a
        // link-0 record that never asked for one.
        if (xf_out_valid && (xf_col < xf_iss)) begin
          case (xf_col)
            2'd0: begin n0x <= xf_out_x; n0y <= xf_out_y; n0z <= xf_out_z; end
            2'd1: begin vnx <= xf_out_x; vny <= xf_out_y; vnz <= xf_out_z; end
            default: begin n1x <= xf_out_x; n1y <= xf_out_y; n1z <= xf_out_z; end
          endcase
          xf_col <= xf_col + 2'd1;
        end
        if (pj_out_valid && (pj_col < pj_iss)) begin
          if (pj_col == 2'd0) begin n0sx <= pj_out_sx; n0sy <= pj_out_sy; end
          else                begin n1sx <= pj_out_sx; n1sy <= pj_out_sy; end
          pj_col <= pj_col + 2'd1;
        end
        if (dt_out_valid && dt_iss && !dt_col) begin
          dt_col     <= 1'b1;
          cull_known <= 1'b1;
          culled     <= dt_out_positive;   // `view_determinant(...) > 0` culls
          if (dt_out_positive && dbg_culled != 16'hffff)
            dbg_culled <= dbg_culled + 16'd1;
          // Wraps rather than saturating: the rate is what matters, and a
          // counter that stops reads as "it went away" when it did not.
          if (dt_out_positive) dbg_culled_run <= dbg_culled_run + 16'd1;
        end
        if (nm_out_valid && nm_iss && !nm_col) begin
          nvx <= nm_out_x; nvy <= nm_out_y; nvz <= nm_out_z;
          nm_col <= 1'b1;
        end
        if (cl_out_valid && cl_iss && !cl_col) begin
          q_col  <= cl_out_rgb;
          cl_col <= 1'b1;
        end
        if (tex_req && tex_valid && !tx_col) begin
          tex_hold <= tex_data;
          tx_col   <= 1'b1;
        end

        // The sort z, chosen by flags bits 11:10. Mode 0 REUSES the previous
        // quad's z, which is why old_z is carried across objects. It needs all
        // four points and is only taken for a record that survives the cull -
        // MAME reaches this code after `if (view_determinant(...) > 0) goto
        // next`, so a culled record must not disturb oldz.
        if (!z_done && draws && cull_known && !culled && (xf_col == 2'd3)) begin
          z_done <= 1'b1;
          case (zmode)
            2'd0: qz <= oldz;
            2'd1: begin qz <= z_min4; oldz <= z_min4; end
            2'd2: begin qz <= z_max4; oldz <= z_max4; end
            default: qz <= 32'd0;
          endcase
        end
      end

      case (st)
        W_IDLE: if (start) begin
          // push_object's own guards: a texture address of 0xffffffff or an
          // absurd size is bad data and the object is skipped entirely.
          if (in_tex_adr == 32'hffffffff || in_size >= 32'h01000000) begin
            done <= 1'b1;
          end else begin
            padr  <= in_poly_adr[22:0];
            tadr  <= in_tex_adr;
            // `if (!size) size = 0xffffffff` - zero means "until the terminator".
            nleft <= (in_size == 32'd0) ? 32'hffffffff : in_size;
            oldz  <= old_z_in;
            hdr_i <= '0;
            pf_wi <= '0; pf_n <= 4'd6; pf_en <= 1'b1;
            dbg_records <= '0; dbg_quads <= '0;
            dbg_culled  <= '0; dbg_nolink <= '0;
            st    <= W_HDR_W;
          end
        end

        // ---- six-float header: two points
        W_HDR_W: if (pf_ready) begin
          for (int i = 0; i < 6; i++) rec[i] <= nrec[i];
          pf_wi <= '0; pf_n <= 4'd10;      // the first record, during the header
          hdr_i <= '0;
          st    <= W_HDR_XF;
        end
        W_HDR_XF:  if (xf_ready) st <= W_HDR_XFW;
        W_HDR_XFW: if (xf_out_valid) begin
          if (hdr_i == 3'd0) begin o0x <= xf_out_x; o0y <= xf_out_y; o0z <= xf_out_z; end
          else               begin o1x <= xf_out_x; o1y <= xf_out_y; o1z <= xf_out_z; end
          if (hdr_i == 3'd1) begin hdr_i <= 3'd1; st <= W_HDR_PJ; end
          else               begin hdr_i <= 3'd1; st <= W_HDR_XF; end
        end
        W_HDR_PJ:  if (pj_ready) st <= W_HDR_PJW;
        W_HDR_PJW: if (pj_out_valid) begin
          if (hdr_i == 3'd1) begin
            o0sx <= pj_out_sx; o0sy <= pj_out_sy;
            hdr_i <= 3'd2; st <= W_HDR_PJ;
          end else begin
            o1sx <= pj_out_sx; o1sy <= pj_out_sy;
            st <= W_REC_W;
          end
        end

        // ---- ten-float record, already in the prefetch buffer
        W_REC_W: if (pf_ready) begin
          for (int i = 0; i < 10; i++) rec[i] <= nrec[i];
          pf_wi <= '0;                     // the NEXT record starts now
          st    <= W_REC_DEC;
        end

        W_REC_DEC: begin
          flags  <= rec[0];
          link   <= rec[0][9:8];
          zmode  <= rec[0][11:10];
          moire  <= rec[0][13];
          nocull <= rec[0][14];
          if (rec[0][12]) tadr <= tadr + 32'd1;     // flag 0x1000
          if (dbg_records != 16'hffff) dbg_records <= dbg_records + 16'd1;
          // `type = flags & 3; if (!type) break;` - and the size limit.
          if (rec[0][1:0] == 2'd0 || nleft == 32'd0) begin
            pf_en <= 1'b0;
            st    <= W_DONE;
          end else begin
            nleft <= nleft - 32'd1;
            xf_iss <= '0; xf_col <= '0; pj_iss <= '0; pj_col <= '0;
            dt_iss <= 1'b0; dt_col <= 1'b0; nm_iss <= 1'b0; nm_col <= 1'b0;
            cl_iss <= 1'b0; cl_col <= 1'b0; tx_iss <= 1'b0; tx_col <= 1'b0;
            // flag 0x4000 skips the test, so the cull answer is known already.
            cull_known <= rec[0][14];
            culled     <= 1'b0;
            z_done     <= 1'b0;
            st         <= W_REC;
          end
        end

        // Everything above happens here; this only decides when the record is
        // finished. Both projections are always needed - the strip advance uses
        // their screen coordinates even for a record that draws nothing.
        // A SPECULATIVE ISSUE HAS TO BE DRAINED, not abandoned. The normalize
        // and the colour are started before the cull is known, so a culled
        // record can reach this point with one of them still in the pipeline -
        // and leaving then lets its result arrive during the NEXT record and
        // overwrite that record's normal or colour. Measured as 345 of 3,357
        // colours wrong, 10.3%, with the geometry itself exact.
        W_REC: begin
          if (rec_quiet) begin
            if (!draws) begin
              if (dbg_nolink != 16'hffff) dbg_nolink <= dbg_nolink + 16'd1;
              st <= W_NEXT;
            end else if (cull_known && culled) begin
              st <= W_NEXT;
            end else if (cull_known && !culled && cl_col && z_done) begin
              st <= W_EMIT;
            end
          end
        end

        W_EMIT: begin
          // (old_p1, old_p0, p0, p1) - the previous pair REVERSED. Matching the
          // determinant's argument order; the obvious winding inverts the cull.
          q_x0 <= o1sx; q_y0 <= o1sy;
          q_x1 <= o0sx; q_y1 <= o0sy;
          q_x2 <= n0sx; q_y2 <= n0sy;
          q_x3 <= n1sx; q_y3 <= n1sy;
          q_z     <= qz;
          q_cx0 <= o1x; q_cy0 <= o1y; q_cz0 <= o1z;
          q_cx1 <= o0x; q_cy1 <= o0y; q_cz1 <= o0z;
          q_cx2 <= n0x; q_cy2 <= n0y; q_cz2 <= n0z;
          q_cx3 <= n1x; q_cy3 <= n1y; q_cz3 <= n1z;
          q_moire <= moire;
          q_valid <= 1'b1;
          if (dbg_quads != 16'hffff) dbg_quads <= dbg_quads + 16'd1;
          st <= W_EMITW;
        end

        W_EMITW: if (q_ready) begin
          q_valid <= 1'b0;
          st      <= W_NEXT;
        end

        W_NEXT: begin
          // The strip advance. link 0 and 2 replace both points, 1 replaces
          // old_p1 with p0, 3 replaces old_p0 with p1.
          case (link)
            2'd0, 2'd2: begin
              o0x <= n0x; o0y <= n0y; o0z <= n0z; o0sx <= n0sx; o0sy <= n0sy;
              o1x <= n1x; o1y <= n1y; o1z <= n1z; o1sx <= n1sx; o1sy <= n1sy;
            end
            2'd1: begin
              o1x <= n0x; o1y <= n0y; o1z <= n0z; o1sx <= n0sx; o1sy <= n0sy;
            end
            default: begin
              o0x <= n1x; o0y <= n1y; o0z <= n1z; o0sx <= n1sx; o0sy <= n1sy;
            end
          endcase
          st <= W_REC_W;
        end

        W_DONE: begin
          done <= 1'b1;
          st   <= W_IDLE;
        end

        default: st <= W_IDLE;
      endcase
    end
  end

endmodule
