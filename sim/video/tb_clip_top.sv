// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The clipper ALONE, with just enough around it to run: the shared FP pool and
// the projection unit it borrows from the geometry stage.
//
// Written because the first attempt at m1_geo_clip was built whole, wired into
// m1_geometry, and then debugged by reading it - and every conclusion drawn
// that way rested on a probe that was never verified to print. One quad, known
// plane values, and every internal signal reachable is the difference between
// finding a fault and theorising about one.
`timescale 1ns/1ps

module tb_clip_top (
  input  logic clk,
  input  logic rst_n,

  input  logic [31:0] a_left, a_right, a_bottom, a_top,
  input  logic [31:0] xc, yc, zoomx, zoomy, viewx, viewy,

  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] in_x0, in_y0, in_z0, in_x1, in_y1, in_z1,
  input  logic [31:0] in_x2, in_y2, in_z2, in_x3, in_y3, in_z3,
  input  logic signed [15:0] in_sx0, in_sy0, in_sx1, in_sy1,
  input  logic signed [15:0] in_sx2, in_sy2, in_sx3, in_sy3,

  output logic        out_valid,
  output logic signed [15:0] out_sx0, out_sy0, out_sx1, out_sy1,
  output logic signed [15:0] out_sx2, out_sy2, out_sx3, out_sy3,
  output logic [15:0] dbg_in, dbg_out, dbg_dropped
);

  localparam int unsigned NC = 2;      // 0 = projection, 1 = clipper

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

  logic        pj_valid, pj_ready, pj_out_valid, pj_behind;
  logic [31:0] pj_x, pj_y, pj_z, pj_out_z;
  logic signed [31:0] pj_out_sx, pj_out_sy;

  m1_geo_project u_project (
    .clk(clk), .rst_n(rst_n),
    .xc(xc), .yc(yc), .zoomx(zoomx), .zoomy(zoomy),
    .viewx(viewx), .viewy(viewy),
    .in_valid(pj_valid), .in_ready(pj_ready),
    .in_x(pj_x), .in_y(pj_y), .in_z(pj_z),
    .mul_req(mul_req[0]), .mul_a(mul_a[0]), .mul_b(mul_b[0]),
    .mul_gnt(mul_gnt[0]), .mul_rsp(mul_rsp[0]), .mul_res(mul_res),
    .add_req(add_req[0]), .add_a(add_a[0]), .add_b(add_b[0]),
    .add_sub(add_sub[0]),
    .add_gnt(add_gnt[0]), .add_rsp(add_rsp[0]), .add_res(add_res),
    .div_req(div_req[0]), .div_a(div_a[0]), .div_b(div_b[0]),
    .div_gnt(div_gnt[0]), .div_rsp(div_rsp[0]), .div_res(div_res),
    .out_valid(pj_out_valid), .out_sx(pj_out_sx), .out_sy(pj_out_sy),
    .out_z(pj_out_z), .out_behind(pj_behind)
  );

  m1_geo_clip u_clip (
    .clk(clk), .rst_n(rst_n),
    .a_left(a_left), .a_right(a_right), .a_bottom(a_bottom), .a_top(a_top),
    .in_valid(in_valid), .in_ready(in_ready),
    .in_x0(in_x0), .in_y0(in_y0), .in_z0(in_z0),
    .in_x1(in_x1), .in_y1(in_y1), .in_z1(in_z1),
    .in_x2(in_x2), .in_y2(in_y2), .in_z2(in_z2),
    .in_x3(in_x3), .in_y3(in_y3), .in_z3(in_z3),
    .in_sx0(in_sx0), .in_sy0(in_sy0), .in_sx1(in_sx1), .in_sy1(in_sy1),
    .in_sx2(in_sx2), .in_sy2(in_sy2), .in_sx3(in_sx3), .in_sy3(in_sy3),
    .in_col(24'h334455), .in_z(32'h40000000), .in_moire(1'b0),
    .mul_req(mul_req[1]), .mul_a(mul_a[1]), .mul_b(mul_b[1]),
    .mul_gnt(mul_gnt[1]), .mul_rsp(mul_rsp[1]), .mul_res(mul_res),
    .add_req(add_req[1]), .add_a(add_a[1]), .add_b(add_b[1]),
    .add_sub(add_sub[1]),
    .add_gnt(add_gnt[1]), .add_rsp(add_rsp[1]), .add_res(add_res),
    .div_req(div_req[1]), .div_a(div_a[1]), .div_b(div_b[1]),
    .div_gnt(div_gnt[1]), .div_rsp(div_rsp[1]), .div_res(div_res),
    .pj_valid(pj_valid), .pj_ready(pj_ready),
    .pj_x(pj_x), .pj_y(pj_y), .pj_z(pj_z),
    .pj_out_valid(pj_out_valid),
    .pj_out_sx(pj_out_sx), .pj_out_sy(pj_out_sy),
    .out_valid(out_valid), .out_ready(1'b1),
    .out_sx0(out_sx0), .out_sy0(out_sy0), .out_sx1(out_sx1), .out_sy1(out_sy1),
    .out_sx2(out_sx2), .out_sy2(out_sy2), .out_sx3(out_sx3), .out_sy3(out_sy3),
    .out_col(), .out_z(), .out_moire(),
    .dbg_in(dbg_in), .dbg_out(dbg_out), .dbg_dropped(dbg_dropped)
  );

endmodule
