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
  output logic        q_valid,
  output logic signed [31:0] q_x0, q_y0, q_x1, q_y1,
  output logic signed [31:0] q_x2, q_y2, q_x3, q_y3,
  output logic [23:0] q_col,
  output logic [31:0] q_z,
  output logic        q_moire,

  output logic [15:0] dbg_records, dbg_quads, dbg_culled, dbg_nolink,

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

  localparam int unsigned NC = 5;

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
  logic        pj_valid, pj_ready, pj_out_valid;
  logic [31:0] pj_x, pj_y, pj_z, pj_out_z;
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

  m1_geo_walk u_walk (
    .clk(clk), .rst_n(rst_n),
    .start(start), .in_tex_adr(in_tex_adr), .in_poly_adr(in_poly_adr),
    .in_size(in_size), .busy(busy), .done(done),
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
    .pj_valid(pj_valid), .pj_ready(pj_ready),
    .pj_x(pj_x), .pj_y(pj_y), .pj_z(pj_z),
    .pj_out_valid(pj_out_valid), .pj_out_sx(pj_out_sx), .pj_out_sy(pj_out_sy),
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
    .q_valid(q_valid),
    .q_x0(q_x0), .q_y0(q_y0), .q_x1(q_x1), .q_y1(q_y1),
    .q_x2(q_x2), .q_y2(q_y2), .q_x3(q_x3), .q_y3(q_y3),
    .q_col(q_col), .q_z(q_z), .q_moire(q_moire),
    .dbg_records(dbg_records), .dbg_quads(dbg_quads),
    .dbg_culled(dbg_culled), .dbg_nolink(dbg_nolink)
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
