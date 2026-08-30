// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Bench top for the render capture: the geometry stage and the fill unit side by
// side, driven independently by the bench so the painter's sort can sit between
// them. In the real design that sort is a quad store in SDRAM (docs/findings.md);
// here the bench holds the quads and orders them.

`timescale 1ns/1ps

module m1_render_top (
  input  logic        clk, rst_n,

  // view
  input  logic        mat_we,
  input  logic [3:0]  mat_idx,
  input  logic [31:0] mat_data,
  input  logic [31:0] xc, yc, zoomx, zoomy, viewx, viewy,
  input  logic [31:0] light_x, light_y, light_z,
  input  logic        spec_enable, frame_odd,

  // geometry
  input  logic        g_start,
  input  logic [31:0] g_tex_adr, g_poly_adr, g_size,
  output logic        g_busy, g_done,
  input  logic [31:0] g_old_z_in,
  output logic [31:0] g_old_z_out,
  output logic [22:0] g_rom_addr,
  output logic        g_rom_req,
  input  logic        g_rom_valid,
  input  logic [31:0] g_rom_data,
  output logic [19:0] g_tex_addr,
  input  logic [15:0] g_tex_data,
  output logic [7:0]  g_lp_addr,
  input  logic [31:0] g_lp_d, g_lp_a, g_lp_s,
  input  logic [7:0]  g_lp_p,
  output logic [12:0] g_pal_addr,
  input  logic [15:0] g_pal_data,
  output logic [14:0] g_xlat_addr,
  input  logic [15:0] g_xlat_data,
  output logic        g_q_valid,
  output logic signed [31:0] g_q_x0, g_q_y0, g_q_x1, g_q_y1,
  output logic signed [31:0] g_q_x2, g_q_y2, g_q_x3, g_q_y3,
  output logic [23:0] g_q_col,
  output logic [31:0] g_q_z,
  output logic        g_q_moire,
  output logic [15:0] g_dbg_records, g_dbg_quads, g_dbg_culled, g_dbg_nolink,

  // fill
  input  logic        f_in_valid,
  output logic        f_in_ready,
  input  logic signed [31:0] f_in_x0, f_in_y0, f_in_x1, f_in_y1,
  input  logic signed [31:0] f_in_x2, f_in_y2, f_in_x3, f_in_y3,
  input  logic [23:0] f_in_col,
  input  logic        f_in_moire,
  input  logic signed [31:0] f_view_x1, f_view_x2, f_view_y1, f_view_y2,
  output logic        f_span_valid,
  input  logic        f_span_ready,
  output logic signed [31:0] f_span_y, f_span_x0, f_span_x1,
  output logic [23:0] f_span_col,
  output logic        f_span_moire,
  output logic        f_quad_done, f_line_case
);

  m1_geometry u_geo (
    .clk(clk), .rst_n(rst_n),
    .mat_we(mat_we), .mat_idx(mat_idx), .mat_data(mat_data),
    .xc(xc), .yc(yc), .zoomx(zoomx), .zoomy(zoomy), .viewx(viewx), .viewy(viewy),
    .light_x(light_x), .light_y(light_y), .light_z(light_z),
    .spec_enable(spec_enable), .frame_odd(frame_odd),
    .start(g_start), .in_tex_adr(g_tex_adr), .in_poly_adr(g_poly_adr),
    .in_size(g_size), .busy(g_busy), .done(g_done),
    .old_z_in(g_old_z_in), .old_z_out(g_old_z_out),
    .rom_addr(g_rom_addr), .rom_req(g_rom_req),
    .rom_valid(g_rom_valid), .rom_data(g_rom_data),
    .tex_addr(g_tex_addr), .tex_data(g_tex_data),
    .lp_addr(g_lp_addr), .lp_d(g_lp_d), .lp_a(g_lp_a), .lp_s(g_lp_s), .lp_p(g_lp_p),
    .pal_addr(g_pal_addr), .pal_data(g_pal_data),
    .xlat_addr(g_xlat_addr), .xlat_data(g_xlat_data),
    .q_valid(g_q_valid),
    .q_x0(g_q_x0), .q_y0(g_q_y0), .q_x1(g_q_x1), .q_y1(g_q_y1),
    .q_x2(g_q_x2), .q_y2(g_q_y2), .q_x3(g_q_x3), .q_y3(g_q_y3),
    .q_col(g_q_col), .q_z(g_q_z), .q_moire(g_q_moire),
    .dbg_records(g_dbg_records), .dbg_quads(g_dbg_quads),
    .dbg_culled(g_dbg_culled), .dbg_nolink(g_dbg_nolink)
  );

  m1_raster_fill u_fill (
    .clk(clk), .rst_n(rst_n),
    .in_valid(f_in_valid), .in_ready(f_in_ready),
    .in_x0(f_in_x0), .in_y0(f_in_y0), .in_x1(f_in_x1), .in_y1(f_in_y1),
    .in_x2(f_in_x2), .in_y2(f_in_y2), .in_x3(f_in_x3), .in_y3(f_in_y3),
    .in_col(f_in_col), .in_moire(f_in_moire),
    .view_x1(f_view_x1), .view_x2(f_view_x2),
    .view_y1(f_view_y1), .view_y2(f_view_y2),
    .span_valid(f_span_valid), .span_ready(f_span_ready),
    .span_y(f_span_y), .span_x0(f_span_x0), .span_x1(f_span_x1),
    .span_col(f_span_col), .span_moire(f_span_moire),
    .quad_done(f_quad_done), .line_case(f_line_case)
  );

endmodule
