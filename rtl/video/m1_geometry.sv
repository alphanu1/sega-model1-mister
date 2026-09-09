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
// The geometry stage: an object address in, screen-space quads out.
//
// Five arithmetic stages and one walker around a SINGLE multiplier, adder and
// divider. The sharing is the point - a polygon record needs 44 multiplies and
// 43 adds against a budget that allows 68 cycles, and the pipelines retire one
// result a cycle, so one of each runs at about two thirds occupancy. Private
// units cost 446 ALM a copy and bought nothing (docs/findings.md).
//
//     m1_geo_walk      reads the model, keeps the strip, decides what is drawn
//     m1_geo_xform     the 3x4 view matrix                    client 0
//     m1_geo_project   camera space to pixels                 client 1
//     m1_geo_det       the backface determinant               client 2
//     m1_geo_norm      the normal, via m1_geo_rsqrt           client 3
//     m1_geo_color     lighting, palette and translation      client 4
//
// The walker drives them one at a time for a given record, so the pool is never
// contended within a record - the arbitration matters across records once this
// is pipelined, and the round robin is there so that when it does, no stage is
// starved on the frames that are busiest.

`timescale 1ns/1ps

module m1_geometry (
  input  logic        clk,
  input  logic        rst_n,

  // ---- the view, from the display list
  input  logic        mat_we,
  input  logic [3:0]  mat_idx,
  input  logic [31:0] mat_data,
  input  logic [31:0] xc, yc, zoomx, zoomy, viewx, viewy,
  input  logic [31:0] light_x, light_y, light_z,
  input  logic        spec_enable,
  input  logic        frame_odd,

  // ---- one object
  input  logic        start,
  // High while the frustum planes are mid-recompute. The caller must not hand
  // over an object during it - see m1_geo_planes.
  output logic        planes_wait,
  // THE LEFT CLIP PLANE ITSELF, raw IEEE-754.
  //
  // Ben's photo puts a hard vertical cut at 48% of the screen with 2D behind it
  // on the left and full 3D on the right. That is where a_left = 0.0 puts the
  // plane: screen_x = xc + a_left*zoomx + viewx, which for a correct a_left is
  // x1 = 0 and for a_left = 0 is xc + viewx - about 248 on a 496-wide screen.
  // a_left is `which == 0`, the FIRST plane computed, so if it is still at its
  // reset zero then no recompute has ever run and the display list's viewport,
  // zoom and view-translation commands are not reaching m1_geo_planes at all.
  output logic [31:0] plane_left,
  // Plane recomputes that arrived mid-set; see m1_geo_planes.
  output logic [15:0] dbg_plane_redo,
  // THE CLIPPER'S OWN FUNNEL. Connected to m1_geo_clip since it was written and
  // routed nowhere, so nobody has ever seen how many quads it eats. That is the
  // measurement that separates "the clipper culls the left side" from "the
  // geometry never produced it" - see docs/HANDOFF.md's left-side entry, where
  // the mixer and the band memory were both cleared by A=/Z= against I=/J=.
  output logic [15:0] dbg_clip_in, dbg_clip_out, dbg_clip_drop,
  input  logic [31:0] in_tex_adr,
  input  logic [31:0] in_poly_adr,
  input  logic [31:0] in_size,
  output logic        busy,
  output logic        done,
  input  logic [31:0] old_z_in,
  output logic [31:0] old_z_out,

  // ---- memories
  output logic [22:0] rom_addr,
  output logic        rom_req,
  input  logic        rom_valid,
  input  logic [31:0] rom_data,

  output logic [19:0] tex_addr,
  output logic        tex_req,
  input  logic        tex_valid,
  input  logic [15:0] tex_data,

  output logic [7:0]  lp_addr,
  input  logic [31:0] lp_d, lp_a, lp_s,
  input  logic [7:0]  lp_p,

  output logic [12:0] pal_addr,
  input  logic [15:0] pal_data,
  output logic [14:0] xlat_addr,
  input  logic [15:0] xlat_data,

  // ---- quads out
  // The viewport rectangle, which command 3 carries and which until the clipper
  // arrived nothing consumed. The four plane ratios are derived from it here.
  input  logic [31:0] vp_x1, vp_x2, vp_y1, vp_y2,
  input  logic        vp_dirty,

  output logic        q_valid,
  output logic signed [31:0] q_x0, q_y0, q_x1, q_y1,
  output logic signed [31:0] q_x2, q_y2, q_x3, q_y3,
  output logic [23:0] q_col,
  output logic [31:0] q_z,
  output logic        q_moire,

  output logic [15:0] dbg_records, dbg_quads, dbg_culled, dbg_nolink,
  output logic [15:0] dbg_culled_run,

  // A NORMALIZE SERVICE, for the caller's light vector.
  //
  // MAME normalizes the light on upload (set_light_direction is
  // glm::normalize), and the display list's vector is NOT unit length - the
  // measured one is 1.0941, so every dot product comes out 9.4% large and every
  // polygon a luminance level too bright. The caller needs a normalize once per
  // frame, and building it a second m1_geo_norm would cost another ~450 ALM of
  // multiplier and adder for one vector.
  //
  // So the walker's normalize is lent out while the stage is idle. Granted only
  // when !busy, which is exactly when the caller is between objects.
  input  logic        ext_nrm_valid,
  output logic        ext_nrm_ready,
  input  logic [31:0] ext_nrm_x, ext_nrm_y, ext_nrm_z,
  output logic        ext_nrm_out_valid,
  output logic [31:0] ext_nrm_out_x, ext_nrm_out_y, ext_nrm_out_z
);

  // Seven clients. The clipper is one; the plane derivation is another, and it
  // runs at most once a frame - it gets its own rather than sharing, because a
  // mux for something a thousand times rarer is the wrong trade.
  localparam int unsigned NC = 7;

  // ---------------------------------------------------------------- the pool
  logic [NC-1:0] mul_req, mul_gnt, mul_rsp;
  logic [31:0]   mul_a [NC], mul_b [NC];
  logic [31:0]   mul_res;
  logic [NC-1:0] add_req, add_gnt, add_rsp, add_sub;
  logic [31:0]   add_a [NC], add_b [NC];
  logic [31:0]   add_res;
  logic [NC-1:0] div_req, div_gnt, div_rsp;
  logic [31:0]   div_a [NC], div_b [NC];
  logic [31:0]   div_res;

  m1_fp_pool #(.NC(NC)) u_pool (
    .clk(clk), .rst_n(rst_n),
    .mul_req(mul_req), .mul_a(mul_a), .mul_b(mul_b),
    .mul_gnt(mul_gnt), .mul_rsp(mul_rsp), .mul_res(mul_res),
    .add_req(add_req), .add_a(add_a), .add_b(add_b), .add_sub(add_sub),
    .add_gnt(add_gnt), .add_rsp(add_rsp), .add_res(add_res),
    .div_req(div_req), .div_a(div_a), .div_b(div_b),
    .div_gnt(div_gnt), .div_rsp(div_rsp), .div_res(div_res)
  );

  // Only the projection divides.
  assign div_req[0] = 1'b0; assign div_a[0] = '0; assign div_b[0] = '0;
  assign div_req[2] = 1'b0; assign div_a[2] = '0; assign div_b[2] = '0;
  assign div_req[3] = 1'b0; assign div_a[3] = '0; assign div_b[3] = '0;
  assign div_req[4] = 1'b0; assign div_a[4] = '0; assign div_b[4] = '0;

  // ---------------------------------------------------------------- walker
  logic        xf_valid, xf_ready, xf_translate, xf_out_valid;
  logic [31:0] xf_x, xf_y, xf_z, xf_out_x, xf_out_y, xf_out_z;
  // THE PROJECTION UNIT HAS TWO CALLERS AND THEY DO OVERLAP.
  //
  // Wired first as a plain mux, on the reasoning that the walker projects a
  // quad's corners before it emits, so it would be finished by the time the
  // clipper wanted the unit. That is false: the walker hands the quad over and
  // immediately starts the NEXT record, projecting, while the clipper is still
  // cutting the last one. Both issued, and each took the other's answer.
  //
  // The clipper alone is bit-exact - 400 fuzzed quads through
  // sim/video/tb_m1_geo_clip.cpp, zero disagreements with the same fclip the
  // reference model uses - so this was the whole of the integration fault.
  //
  // Two parts to the fix. The walker may not ISSUE while the clipper is busy,
  // so at most one request is ever outstanding; and an owner flag routes the
  // answer, because "who asked last" is not something either can infer.
  logic        pj_ready, pj_out_valid;
  logic        w_pj_valid;
  logic [31:0] w_pj_x, w_pj_y, w_pj_z;
  logic        k_pj_valid;
  logic [31:0] k_pj_x, k_pj_y, k_pj_z;
  logic [31:0] pj_out_z;
  // in_ready is high only when the clipper is idle, so this is exactly "the
  // clipper is not busy". The walker stalls mid-record instead of corrupting
  // the answer, which it would otherwise be waiting to do at its next handoff
  // in any case.
  wire         w_pj_gated = w_pj_valid && w_q_ready;
  wire         pj_valid = w_pj_gated || k_pj_valid;
  logic        pj_owner;      // 0 = walker, 1 = clipper
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                    pj_owner <= 1'b0;
    else if (pj_valid && pj_ready) pj_owner <= k_pj_valid;
  end
  wire w_pj_out_valid = pj_out_valid && !pj_owner;
  wire k_pj_out_valid = pj_out_valid &&  pj_owner;
  wire [31:0]  pj_x = k_pj_valid ? k_pj_x : w_pj_x;
  wire [31:0]  pj_y = k_pj_valid ? k_pj_y : w_pj_y;
  wire [31:0]  pj_z = k_pj_valid ? k_pj_z : w_pj_z;

  logic        w_q_valid /* verilator public_flat_rd */;
  logic        w_q_ready /* verilator public_flat_rd */;
  logic signed [31:0] w_x0, w_y0, w_x1, w_y1, w_x2, w_y2, w_x3, w_y3;
  logic [31:0] w_cx0 /* verilator public_flat_rd */, w_cy0 /* verilator public_flat_rd */, w_cz0 /* verilator public_flat_rd */;
  logic [31:0] w_cx1 /* verilator public_flat_rd */, w_cy1 /* verilator public_flat_rd */, w_cz1 /* verilator public_flat_rd */;
  logic [31:0] w_cx2 /* verilator public_flat_rd */, w_cy2 /* verilator public_flat_rd */, w_cz2 /* verilator public_flat_rd */;
  logic [31:0] w_cx3 /* verilator public_flat_rd */, w_cy3 /* verilator public_flat_rd */, w_cz3 /* verilator public_flat_rd */;
  logic [23:0] w_col;
  logic [31:0] w_z;
  logic        w_moire;
  logic signed [15:0] k_sx0, k_sy0, k_sx1, k_sy1, k_sx2, k_sy2, k_sx3, k_sy3;
  logic        k_out_valid;
  logic [15:0] k_dbg_in, k_dbg_out, k_dbg_drop;
  assign dbg_clip_in   = k_dbg_in;
  assign dbg_clip_out  = k_dbg_out;
  assign dbg_clip_drop = k_dbg_drop;
  logic signed [31:0] pj_out_sx, pj_out_sy;
  logic        pj_out_behind;
  logic        dt_valid, dt_ready, dt_out_valid, dt_out_positive;
  logic [31:0] dt_p1x, dt_p1y, dt_p1z, dt_p2x, dt_p2y, dt_p2z;
  logic [31:0] dt_p3x, dt_p3y, dt_p3z, dt_out_det;
  logic        nm_valid;
  logic        nm_ready, nm_out_valid;
  logic [31:0] nm_x, nm_y, nm_z;
  logic [31:0] nm_out_x, nm_out_y, nm_out_z;
  logic        cl_valid, cl_ready, cl_out_valid;
  logic [31:0] cl_nx, cl_ny, cl_nz, cl_lp_d, cl_lp_a, cl_lp_s;
  logic [15:0] cl_tex;
  logic [7:0]  cl_lp_p;
  logic [23:0] cl_out_rgb;
  logic [5:0]  cl_out_lum;

  assign planes_wait = planes_busy;
  assign plane_left  = a_left;

  m1_geo_walk u_walk (
    .clk(clk), .rst_n(rst_n),
    .start(start), .in_tex_adr(in_tex_adr), .in_poly_adr(in_poly_adr),
    .in_size(in_size), .busy(busy), .done(w_done),
    .old_z_in(old_z_in), .old_z_out(old_z_out),
    .rom_addr(rom_addr), .rom_req(rom_req),
    .rom_valid(rom_valid), .rom_data(rom_data),
    .tex_addr(tex_addr), .tex_req(tex_req),
    .tex_valid(tex_valid), .tex_data(tex_data),
    .lp_addr(lp_addr), .lp_d(lp_d), .lp_a(lp_a), .lp_s(lp_s), .lp_p(lp_p),
    .frame_odd(frame_odd),
    .xf_valid(xf_valid), .xf_ready(xf_ready),
    .xf_x(xf_x), .xf_y(xf_y), .xf_z(xf_z), .xf_translate(xf_translate),
    .xf_out_valid(xf_out_valid),
    .xf_out_x(xf_out_x), .xf_out_y(xf_out_y), .xf_out_z(xf_out_z),
    .pj_valid(w_pj_valid), .pj_ready(pj_ready && w_q_ready),
    .pj_x(w_pj_x), .pj_y(w_pj_y), .pj_z(w_pj_z),
    .pj_out_valid(w_pj_out_valid), .pj_out_sx(pj_out_sx), .pj_out_sy(pj_out_sy),
    .dt_valid(dt_valid), .dt_ready(dt_ready),
    .dt_p1x(dt_p1x), .dt_p1y(dt_p1y), .dt_p1z(dt_p1z),
    .dt_p2x(dt_p2x), .dt_p2y(dt_p2y), .dt_p2z(dt_p2z),
    .dt_p3x(dt_p3x), .dt_p3y(dt_p3y), .dt_p3z(dt_p3z),
    .dt_out_valid(dt_out_valid), .dt_out_positive(dt_out_positive),
    .nm_valid(nm_valid), .nm_ready(nm_ready),
    .nm_x(nm_x), .nm_y(nm_y), .nm_z(nm_z),
    .nm_out_valid(nm_out_valid),
    .nm_out_x(nm_out_x), .nm_out_y(nm_out_y), .nm_out_z(nm_out_z),
    .cl_valid(cl_valid), .cl_ready(cl_ready),
    .cl_nx(cl_nx), .cl_ny(cl_ny), .cl_nz(cl_nz), .cl_tex(cl_tex),
    .cl_lp_d(cl_lp_d), .cl_lp_a(cl_lp_a), .cl_lp_s(cl_lp_s), .cl_lp_p(cl_lp_p),
    .cl_out_valid(cl_out_valid), .cl_out_rgb(cl_out_rgb),
    .q_valid(w_q_valid), .q_ready(w_q_ready),
    .q_cx0(w_cx0), .q_cy0(w_cy0), .q_cz0(w_cz0),
    .q_cx1(w_cx1), .q_cy1(w_cy1), .q_cz1(w_cz1),
    .q_cx2(w_cx2), .q_cy2(w_cy2), .q_cz2(w_cz2),
    .q_cx3(w_cx3), .q_cy3(w_cy3), .q_cz3(w_cz3),
    .q_x0(w_x0), .q_y0(w_y0), .q_x1(w_x1), .q_y1(w_y1),
    .q_x2(w_x2), .q_y2(w_y2), .q_x3(w_x3), .q_y3(w_y3),
    .q_col(w_col), .q_z(w_z), .q_moire(w_moire),
    .dbg_records(dbg_records), .dbg_quads(dbg_quads),
    .dbg_culled(dbg_culled), .dbg_nolink(dbg_nolink),
    .dbg_culled_run(dbg_culled_run)
  );

  // ---------------------------------------------------------------- stages
  m1_geo_xform u_xform (
    .clk(clk), .rst_n(rst_n),
    .mat_we(mat_we), .mat_idx(mat_idx), .mat_data(mat_data),
    .in_valid(xf_valid), .in_ready(xf_ready),
    .in_x(xf_x), .in_y(xf_y), .in_z(xf_z), .in_translate(xf_translate),
    .mul_req(mul_req[0]), .mul_a(mul_a[0]), .mul_b(mul_b[0]),
    .mul_gnt(mul_gnt[0]), .mul_rsp(mul_rsp[0]), .mul_res(mul_res),
    .add_req(add_req[0]), .add_a(add_a[0]), .add_b(add_b[0]), .add_sub(add_sub[0]),
    .add_gnt(add_gnt[0]), .add_rsp(add_rsp[0]), .add_res(add_res),
    .out_valid(xf_out_valid), .out_x(xf_out_x), .out_y(xf_out_y), .out_z(xf_out_z)
  );

  // The walker's quad goes through the frustum clipper before it leaves. A quad
  // crossing no plane passes through for sixteen multiplies; one that does is
  // cut into one or two with new vertices created and projected on the
  // boundary. Without it a road vertex past 32,767 wraps to the far side of
  // the screen, because the store keeps 16 bits and the fill works in 16.16.
  // DONE WAITS FOR THE CLIPPER TO DRAIN.
  //
  // It used to be the walker's own done, which says "no more RECORDS" - not "no
  // more quads". The clipper can still be cutting the last one, and its output
  // then lands after the consumer has been told the object finished: measured
  // as a quad emitted before the first quad of the NEXT object was even handed
  // over, and counted against it. In m1_raster3d that is worse than a miscount,
  // because the sort starts on geo_done and would begin while geometry was
  // still arriving.
  logic w_done, done_pend;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) done_pend <= 1'b0;
    else if (w_done) done_pend <= 1'b1;
    else if (done_pend && w_q_ready) done_pend <= 1'b0;
  end
  assign done = done_pend && w_q_ready;

  logic [31:0] a_left /* verilator public_flat_rd */, a_right /* verilator public_flat_rd */;
  logic [31:0] a_bottom /* verilator public_flat_rd */, a_top /* verilator public_flat_rd */;
  logic        planes_valid /* verilator public_flat_rd */;
  logic        planes_busy  /* verilator public_flat_rd */;

  m1_geo_planes u_planes (
    .clk(clk), .rst_n(rst_n),
    .xc(xc), .yc(yc), .zoomx(zoomx), .zoomy(zoomy),
    .viewx(viewx), .viewy(viewy),
    .x1(vp_x1), .x2(vp_x2), .y1(vp_y1), .y2(vp_y2),
    .recompute(vp_dirty),
    .add_req(add_req[6]), .add_a(add_a[6]), .add_b(add_b[6]),
    .add_sub(add_sub[6]),
    .add_gnt(add_gnt[6]), .add_rsp(add_rsp[6]), .add_res(add_res),
    .div_req(div_req[6]), .div_a(div_a[6]), .div_b(div_b[6]),
    .div_gnt(div_gnt[6]), .div_rsp(div_rsp[6]), .div_res(div_res),
    .a_left(a_left), .a_right(a_right),
    .a_bottom(a_bottom), .a_top(a_top), .valid(planes_valid),
    .dbg_redo(dbg_plane_redo),
    .busy(planes_busy)
  );

  m1_geo_clip u_clip (
    .clk(clk), .rst_n(rst_n),
    .a_left(a_left), .a_right(a_right), .a_bottom(a_bottom), .a_top(a_top),
    .in_valid(w_q_valid), .in_ready(w_q_ready),
    .in_x0(w_cx0), .in_y0(w_cy0), .in_z0(w_cz0),
    .in_x1(w_cx1), .in_y1(w_cy1), .in_z1(w_cz1),
    .in_x2(w_cx2), .in_y2(w_cy2), .in_z2(w_cz2),
    .in_x3(w_cx3), .in_y3(w_cy3), .in_z3(w_cz3),
    .in_sx0(w_x0[15:0]), .in_sy0(w_y0[15:0]),
    .in_sx1(w_x1[15:0]), .in_sy1(w_y1[15:0]),
    .in_sx2(w_x2[15:0]), .in_sy2(w_y2[15:0]),
    .in_sx3(w_x3[15:0]), .in_sy3(w_y3[15:0]),
    .in_col(w_col), .in_z(w_z), .in_moire(w_moire),
    .mul_req(mul_req[5]), .mul_a(mul_a[5]), .mul_b(mul_b[5]),
    .mul_gnt(mul_gnt[5]), .mul_rsp(mul_rsp[5]), .mul_res(mul_res),
    .add_req(add_req[5]), .add_a(add_a[5]), .add_b(add_b[5]),
    .add_sub(add_sub[5]),
    .add_gnt(add_gnt[5]), .add_rsp(add_rsp[5]), .add_res(add_res),
    .div_req(div_req[5]), .div_a(div_a[5]), .div_b(div_b[5]),
    .div_gnt(div_gnt[5]), .div_rsp(div_rsp[5]), .div_res(div_res),
    .pj_valid(k_pj_valid), .pj_ready(pj_ready),
    .pj_x(k_pj_x), .pj_y(k_pj_y), .pj_z(k_pj_z),
    .pj_out_valid(k_pj_out_valid),
    .pj_out_sx(pj_out_sx), .pj_out_sy(pj_out_sy),
    .out_valid(k_out_valid), .out_ready(1'b1),
    .out_sx0(k_sx0), .out_sy0(k_sy0), .out_sx1(k_sx1), .out_sy1(k_sy1),
    .out_sx2(k_sx2), .out_sy2(k_sy2), .out_sx3(k_sx3), .out_sy3(k_sy3),
    .out_col(q_col), .out_z(q_z), .out_moire(q_moire),
    .dbg_in(k_dbg_in), .dbg_out(k_dbg_out), .dbg_dropped(k_dbg_drop)
  );

  // The attributes ride through unchanged: a clipped quad keeps its colour, its
  // sort z and its stipple, exactly as fclip_push_quad copies them.
  assign q_valid = k_out_valid;
  assign q_x0 = 32'(signed'(k_sx0)); assign q_y0 = 32'(signed'(k_sy0));
  assign q_x1 = 32'(signed'(k_sx1)); assign q_y1 = 32'(signed'(k_sy1));
  assign q_x2 = 32'(signed'(k_sx2)); assign q_y2 = 32'(signed'(k_sy2));
  assign q_x3 = 32'(signed'(k_sx3)); assign q_y3 = 32'(signed'(k_sy3));

  m1_geo_project u_project (
    .clk(clk), .rst_n(rst_n),
    .xc(xc), .yc(yc), .zoomx(zoomx), .zoomy(zoomy), .viewx(viewx), .viewy(viewy),
    .in_valid(pj_valid), .in_ready(pj_ready),
    .in_x(pj_x), .in_y(pj_y), .in_z(pj_z),
    .mul_req(mul_req[1]), .mul_a(mul_a[1]), .mul_b(mul_b[1]),
    .mul_gnt(mul_gnt[1]), .mul_rsp(mul_rsp[1]), .mul_res(mul_res),
    .add_req(add_req[1]), .add_a(add_a[1]), .add_b(add_b[1]), .add_sub(add_sub[1]),
    .add_gnt(add_gnt[1]), .add_rsp(add_rsp[1]), .add_res(add_res),
    .div_req(div_req[1]), .div_a(div_a[1]), .div_b(div_b[1]),
    .div_gnt(div_gnt[1]), .div_rsp(div_rsp[1]), .div_res(div_res),
    .out_valid(pj_out_valid), .out_sx(pj_out_sx), .out_sy(pj_out_sy),
    .out_z(pj_out_z), .out_behind(pj_out_behind)
  );

  m1_geo_det u_det (
    .clk(clk), .rst_n(rst_n),
    .in_valid(dt_valid), .in_ready(dt_ready),
    .p1x(dt_p1x), .p1y(dt_p1y), .p1z(dt_p1z),
    .p2x(dt_p2x), .p2y(dt_p2y), .p2z(dt_p2z),
    .p3x(dt_p3x), .p3y(dt_p3y), .p3z(dt_p3z),
    .mul_req(mul_req[2]), .mul_a(mul_a[2]), .mul_b(mul_b[2]),
    .mul_gnt(mul_gnt[2]), .mul_rsp(mul_rsp[2]), .mul_res(mul_res),
    .add_req(add_req[2]), .add_a(add_a[2]), .add_b(add_b[2]), .add_sub(add_sub[2]),
    .add_gnt(add_gnt[2]), .add_rsp(add_rsp[2]), .add_res(add_res),
    .out_valid(dt_out_valid), .out_det(dt_out_det), .out_positive(dt_out_positive)
  );

  // The service only gets in when the geometry stage is idle, so the walker
  // never contends with it.
  wire        lend      = !busy;
  wire        n_valid   = lend ? ext_nrm_valid : nm_valid;
  wire [31:0] n_x       = lend ? ext_nrm_x : nm_x;
  wire [31:0] n_y       = lend ? ext_nrm_y : nm_y;
  wire [31:0] n_z       = lend ? ext_nrm_z : nm_z;
  logic       n_ready, n_out_valid;
  logic [31:0] n_ox, n_oy, n_oz;

  assign nm_ready          = !lend && n_ready;
  assign ext_nrm_ready     =  lend && n_ready;
  assign nm_out_valid      = !lend && n_out_valid;
  assign ext_nrm_out_valid =  lend && n_out_valid;
  assign nm_out_x = n_ox; assign nm_out_y = n_oy; assign nm_out_z = n_oz;
  assign ext_nrm_out_x = n_ox;
  assign ext_nrm_out_y = n_oy;
  assign ext_nrm_out_z = n_oz;

  m1_geo_norm u_norm (
    .clk(clk), .rst_n(rst_n),
    .in_valid(n_valid), .in_ready(n_ready),
    .in_x(n_x), .in_y(n_y), .in_z(n_z),
    .mul_req(mul_req[3]), .mul_a(mul_a[3]), .mul_b(mul_b[3]),
    .mul_gnt(mul_gnt[3]), .mul_rsp(mul_rsp[3]), .mul_res(mul_res),
    .add_req(add_req[3]), .add_a(add_a[3]), .add_b(add_b[3]), .add_sub(add_sub[3]),
    .add_gnt(add_gnt[3]), .add_rsp(add_rsp[3]), .add_res(add_res),
    .out_valid(n_out_valid),
    .out_x(n_ox), .out_y(n_oy), .out_z(n_oz)
  );

  m1_geo_color u_color (
    .clk(clk), .rst_n(rst_n),
    .light_x(light_x), .light_y(light_y), .light_z(light_z),
    .spec_enable(spec_enable),
    .in_valid(cl_valid), .in_ready(cl_ready),
    .in_nx(cl_nx), .in_ny(cl_ny), .in_nz(cl_nz), .in_tex(cl_tex),
    .in_lp_d(cl_lp_d), .in_lp_a(cl_lp_a), .in_lp_s(cl_lp_s), .in_lp_p(cl_lp_p),
    .in_frame_odd(frame_odd),
    .pal_addr(pal_addr), .pal_data(pal_data),
    .xlat_addr(xlat_addr), .xlat_data(xlat_data),
    .mul_req(mul_req[4]), .mul_a(mul_a[4]), .mul_b(mul_b[4]),
    .mul_gnt(mul_gnt[4]), .mul_rsp(mul_rsp[4]), .mul_res(mul_res),
    .add_req(add_req[4]), .add_a(add_a[4]), .add_b(add_b[4]), .add_sub(add_sub[4]),
    .add_gnt(add_gnt[4]), .add_rsp(add_rsp[4]), .add_res(add_res),
    .out_valid(cl_out_valid), .out_rgb(cl_out_rgb), .out_lum(cl_out_lum)
  );

endmodule
