// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// dsb_board as the core instantiates it, with its internals brought out for
// tb_dsb_board: the Z80's port accesses, the decoded samples, the T clock.
`timescale 1ns/1ps
module dsb_board_harness (
  input  logic        clk, rst_n,
  input  logic        rx_tog,
  input  logic  [7:0] rx_byte,
  input  logic        vol_mame,
  output logic        s_req, s_we,
  output logic [25:1] s_addr,
  output logic [15:0] s_din,
  output logic  [1:0] s_be,
  input  logic        s_ack,
  input  logic [15:0] s_dout,
  output logic signed [15:0] out_l, out_r,
  output logic        out_stb, trap,
  output logic        io_wr, io_rd, tick,
  output logic  [7:0] io_addr, io_data,
  output logic        smp_stb,
  output logic [31:0] smp_lr,
  output logic        out_src
);
  dsb_board u (.clk, .rst_n, .rx_tog, .rx_byte, .vol_mame, .s_req, .s_we, .s_addr, .s_din, .s_be,
               .s_ack, .s_dout, .out_l, .out_r, .out_stb, .dbg_trap(trap), .dbg_frames());
  assign io_wr = u.io_wr, io_rd = u.io_rd, tick = u.tick, io_addr = u.io_addr;
  assign io_data = u.io_wr ? u.io_wdata : u.io_rdata;
  assign smp_stb = u.u_mpeg.smp_stb, smp_lr = u.u_mpeg.smp_lr, out_src = u.u_mpeg.out_src;
endmodule
