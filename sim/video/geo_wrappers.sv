// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Bench wrappers: one geometry stage plus a private, single-client m1_fp_pool.
//
// The stages no longer own their arithmetic - one multiplier, one adder and one
// divider serve all of them in the real design (rtl/video/m1_fp_pool.sv). Their
// unit benches still test ONE stage at a time, so each gets a pool of its own
// here with a single client. That keeps the per-stage tests focused while the
// stages themselves are wired for sharing, and it exercises the grant path: with
// one client the grant is always given, so these wrappers prove the refactor did
// not break the stages, and m1_geometry's bench proves the sharing itself.

`timescale 1ns/1ps

module m1_geo_xform_top (
  input  logic        clk, rst_n,
  input  logic        mat_we,
  input  logic [3:0]  mat_idx,
  input  logic [31:0] mat_data,
  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] in_x, in_y, in_z,
  input  logic        in_translate,
  output logic        out_valid,
  output logic [31:0] out_x, out_y, out_z
);
  logic [0:0] mr, mg, mrsp, ar, ag, arsp, dr, dg, drsp;
  logic [31:0] ma [1], mb [1], aa [1], ab [1], da [1], db [1];
  logic [0:0]  asub;
  logic [31:0] mres, ares, dres;

  m1_geo_xform u_dut (
    .clk(clk), .rst_n(rst_n),
    .mat_we(mat_we), .mat_idx(mat_idx), .mat_data(mat_data),
    .in_valid(in_valid), .in_ready(in_ready),
    .in_x(in_x), .in_y(in_y), .in_z(in_z), .in_translate(in_translate),
    .mul_req(mr[0]), .mul_a(ma[0]), .mul_b(mb[0]),
    .mul_gnt(mg[0]), .mul_rsp(mrsp[0]), .mul_res(mres),
    .add_req(ar[0]), .add_a(aa[0]), .add_b(ab[0]), .add_sub(asub[0]),
    .add_gnt(ag[0]), .add_rsp(arsp[0]), .add_res(ares),
    .out_valid(out_valid), .out_x(out_x), .out_y(out_y), .out_z(out_z)
  );

  assign dr = 1'b0; assign da[0] = '0; assign db[0] = '0;

  m1_fp_pool #(.NC(1)) u_pool (
    .clk(clk), .rst_n(rst_n),
    .mul_req(mr), .mul_a(ma), .mul_b(mb), .mul_gnt(mg), .mul_rsp(mrsp), .mul_res(mres),
    .add_req(ar), .add_a(aa), .add_b(ab), .add_sub(asub),
    .add_gnt(ag), .add_rsp(arsp), .add_res(ares),
    .div_req(dr), .div_a(da), .div_b(db), .div_gnt(dg), .div_rsp(drsp), .div_res(dres)
  );
endmodule

module m1_geo_project_top (
  input  logic        clk, rst_n,
  input  logic [31:0] xc, yc, zoomx, zoomy, viewx, viewy,
  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] in_x, in_y, in_z,
  output logic        out_valid,
  output logic signed [31:0] out_sx, out_sy,
  output logic [31:0] out_z,
  output logic        out_behind
);
  logic [0:0] mr, mg, mrsp, ar, ag, arsp, dr, dg, drsp;
  logic [31:0] ma [1], mb [1], aa [1], ab [1], da [1], db [1];
  logic [0:0]  asub;
  logic [31:0] mres, ares, dres;

  m1_geo_project u_dut (
    .clk(clk), .rst_n(rst_n),
    .xc(xc), .yc(yc), .zoomx(zoomx), .zoomy(zoomy), .viewx(viewx), .viewy(viewy),
    .in_valid(in_valid), .in_ready(in_ready),
    .in_x(in_x), .in_y(in_y), .in_z(in_z),
    .mul_req(mr[0]), .mul_a(ma[0]), .mul_b(mb[0]),
    .mul_gnt(mg[0]), .mul_rsp(mrsp[0]), .mul_res(mres),
    .add_req(ar[0]), .add_a(aa[0]), .add_b(ab[0]), .add_sub(asub[0]),
    .add_gnt(ag[0]), .add_rsp(arsp[0]), .add_res(ares),
    .div_req(dr[0]), .div_a(da[0]), .div_b(db[0]),
    .div_gnt(dg[0]), .div_rsp(drsp[0]), .div_res(dres),
    .out_valid(out_valid), .out_sx(out_sx), .out_sy(out_sy),
    .out_z(out_z), .out_behind(out_behind)
  );

  m1_fp_pool #(.NC(1)) u_pool (
    .clk(clk), .rst_n(rst_n),
    .mul_req(mr), .mul_a(ma), .mul_b(mb), .mul_gnt(mg), .mul_rsp(mrsp), .mul_res(mres),
    .add_req(ar), .add_a(aa), .add_b(ab), .add_sub(asub),
    .add_gnt(ag), .add_rsp(arsp), .add_res(ares),
    .div_req(dr), .div_a(da), .div_b(db), .div_gnt(dg), .div_rsp(drsp), .div_res(dres)
  );
endmodule

module m1_geo_det_top (
  input  logic        clk, rst_n,
  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] p1x, p1y, p1z, p2x, p2y, p2z, p3x, p3y, p3z,
  output logic        out_valid,
  output logic [31:0] out_det,
  output logic        out_positive
);
  logic [0:0] mr, mg, mrsp, ar, ag, arsp, dr, dg, drsp;
  logic [31:0] ma [1], mb [1], aa [1], ab [1], da [1], db [1];
  logic [0:0]  asub;
  logic [31:0] mres, ares, dres;

  m1_geo_det u_dut (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid), .in_ready(in_ready),
    .p1x(p1x), .p1y(p1y), .p1z(p1z),
    .p2x(p2x), .p2y(p2y), .p2z(p2z),
    .p3x(p3x), .p3y(p3y), .p3z(p3z),
    .mul_req(mr[0]), .mul_a(ma[0]), .mul_b(mb[0]),
    .mul_gnt(mg[0]), .mul_rsp(mrsp[0]), .mul_res(mres),
    .add_req(ar[0]), .add_a(aa[0]), .add_b(ab[0]), .add_sub(asub[0]),
    .add_gnt(ag[0]), .add_rsp(arsp[0]), .add_res(ares),
    .out_valid(out_valid), .out_det(out_det), .out_positive(out_positive)
  );

  assign dr = 1'b0; assign da[0] = '0; assign db[0] = '0;

  m1_fp_pool #(.NC(1)) u_pool (
    .clk(clk), .rst_n(rst_n),
    .mul_req(mr), .mul_a(ma), .mul_b(mb), .mul_gnt(mg), .mul_rsp(mrsp), .mul_res(mres),
    .add_req(ar), .add_a(aa), .add_b(ab), .add_sub(asub),
    .add_gnt(ag), .add_rsp(arsp), .add_res(ares),
    .div_req(dr), .div_a(da), .div_b(db), .div_gnt(dg), .div_rsp(drsp), .div_res(dres)
  );
endmodule

module m1_geo_rsqrt_top (
  input  logic        clk, rst_n,
  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] in_x,
  output logic        out_valid,
  output logic [31:0] out_y
);
  logic [0:0] mr, mg, mrsp, ar, ag, arsp, dr, dg, drsp;
  logic [31:0] ma [1], mb [1], aa [1], ab [1], da [1], db [1];
  logic [0:0]  asub;
  logic [31:0] mres, ares, dres;

  m1_geo_rsqrt u_dut (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid), .in_ready(in_ready), .in_x(in_x),
    .mul_req(mr[0]), .mul_a(ma[0]), .mul_b(mb[0]),
    .mul_gnt(mg[0]), .mul_rsp(mrsp[0]), .mul_res(mres),
    .add_req(ar[0]), .add_a(aa[0]), .add_b(ab[0]), .add_sub(asub[0]),
    .add_gnt(ag[0]), .add_rsp(arsp[0]), .add_res(ares),
    .out_valid(out_valid), .out_y(out_y)
  );

  assign dr = 1'b0; assign da[0] = '0; assign db[0] = '0;

  m1_fp_pool #(.NC(1)) u_pool (
    .clk(clk), .rst_n(rst_n),
    .mul_req(mr), .mul_a(ma), .mul_b(mb), .mul_gnt(mg), .mul_rsp(mrsp), .mul_res(mres),
    .add_req(ar), .add_a(aa), .add_b(ab), .add_sub(asub),
    .add_gnt(ag), .add_rsp(arsp), .add_res(ares),
    .div_req(dr), .div_a(da), .div_b(db), .div_gnt(dg), .div_rsp(drsp), .div_res(dres)
  );
endmodule

module m1_geo_color_top (
  input  logic        clk, rst_n,
  input  logic [31:0] light_x, light_y, light_z,
  input  logic        spec_enable,
  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] in_nx, in_ny, in_nz,
  input  logic [15:0] in_tex,
  input  logic [31:0] in_lp_d, in_lp_a, in_lp_s,
  input  logic [7:0]  in_lp_p,
  input  logic        in_frame_odd,
  output logic [12:0] pal_addr,
  input  logic [15:0] pal_data,
  output logic [14:0] xlat_addr,
  input  logic [15:0] xlat_data,
  output logic        out_valid,
  output logic [23:0] out_rgb,
  output logic [5:0]  out_lum
);
  logic [0:0] mr, mg, mrsp, ar, ag, arsp, dr, dg, drsp;
  logic [31:0] ma [1], mb [1], aa [1], ab [1], da [1], db [1];
  logic [0:0]  asub;
  logic [31:0] mres, ares, dres;

  m1_geo_color u_dut (
    .clk(clk), .rst_n(rst_n),
    .light_x(light_x), .light_y(light_y), .light_z(light_z),
    .spec_enable(spec_enable),
    .in_valid(in_valid), .in_ready(in_ready),
    .in_nx(in_nx), .in_ny(in_ny), .in_nz(in_nz), .in_tex(in_tex),
    .in_lp_d(in_lp_d), .in_lp_a(in_lp_a), .in_lp_s(in_lp_s), .in_lp_p(in_lp_p),
    .in_frame_odd(in_frame_odd),
    .pal_addr(pal_addr), .pal_data(pal_data),
    .xlat_addr(xlat_addr), .xlat_data(xlat_data),
    .mul_req(mr[0]), .mul_a(ma[0]), .mul_b(mb[0]),
    .mul_gnt(mg[0]), .mul_rsp(mrsp[0]), .mul_res(mres),
    .add_req(ar[0]), .add_a(aa[0]), .add_b(ab[0]), .add_sub(asub[0]),
    .add_gnt(ag[0]), .add_rsp(arsp[0]), .add_res(ares),
    .out_valid(out_valid), .out_rgb(out_rgb), .out_lum(out_lum)
  );

  assign dr = 1'b0; assign da[0] = '0; assign db[0] = '0;

  m1_fp_pool #(.NC(1)) u_pool (
    .clk(clk), .rst_n(rst_n),
    .mul_req(mr), .mul_a(ma), .mul_b(mb), .mul_gnt(mg), .mul_rsp(mrsp), .mul_res(mres),
    .add_req(ar), .add_a(aa), .add_b(ab), .add_sub(asub),
    .add_gnt(ag), .add_rsp(arsp), .add_res(ares),
    .div_req(dr), .div_a(da), .div_b(db), .div_gnt(dg), .div_rsp(drsp), .div_res(dres)
  );
endmodule

module m1_geo_norm_top (
  input  logic        clk, rst_n,
  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] in_x, in_y, in_z,
  output logic        out_valid,
  output logic [31:0] out_x, out_y, out_z
);
  logic [0:0] mr, mg, mrsp, ar, ag, arsp, dr, dg, drsp;
  logic [31:0] ma [1], mb [1], aa [1], ab [1], da [1], db [1];
  logic [0:0]  asub;
  logic [31:0] mres, ares, dres;

  m1_geo_norm u_dut (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid), .in_ready(in_ready),
    .in_x(in_x), .in_y(in_y), .in_z(in_z),
    .mul_req(mr[0]), .mul_a(ma[0]), .mul_b(mb[0]),
    .mul_gnt(mg[0]), .mul_rsp(mrsp[0]), .mul_res(mres),
    .add_req(ar[0]), .add_a(aa[0]), .add_b(ab[0]), .add_sub(asub[0]),
    .add_gnt(ag[0]), .add_rsp(arsp[0]), .add_res(ares),
    .out_valid(out_valid), .out_x(out_x), .out_y(out_y), .out_z(out_z)
  );

  assign dr = 1'b0; assign da[0] = '0; assign db[0] = '0;

  m1_fp_pool #(.NC(1)) u_pool (
    .clk(clk), .rst_n(rst_n),
    .mul_req(mr), .mul_a(ma), .mul_b(mb), .mul_gnt(mg), .mul_rsp(mrsp), .mul_res(mres),
    .add_req(ar), .add_a(aa), .add_b(ab), .add_sub(asub),
    .add_gnt(ag), .add_rsp(arsp), .add_res(ares),
    .div_req(dr), .div_a(da), .div_b(db), .div_gnt(dg), .div_rsp(drsp), .div_res(dres)
  );
endmodule
