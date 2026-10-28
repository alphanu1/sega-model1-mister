// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// m1_fb_flush -> m2_ddr3 -> DDRAM, as m1_raster3d builds them (less the
// arbiter's reader side, which tb_m1_fb_read covers), for tb_m1_fb_flush.
`timescale 1ns/1ps
module fb_flush_chain (
  input  logic        clk, rst_n,
  input  logic        fb_sel, start,
  input  logic [5:0]  band,
  output logic        busy,
  output logic [8:0]  rd_x,
  output logic [2:0]  rd_row,
  input  logic [67:0] rd_q4,
  output logic        wc_en,
  output logic [8:0]  wc_x,
  output logic [2:0]  wc_row,
  input  logic        DDRAM_BUSY,
  output logic [7:0]  DDRAM_BURSTCNT,
  output logic [28:0] DDRAM_ADDR,
  input  logic [63:0] DDRAM_DOUT,
  input  logic        DDRAM_DOUT_READY,
  output logic        DDRAM_RD,
  output logic [63:0] DDRAM_DIN,
  output logic [7:0]  DDRAM_BE,
  output logic        DDRAM_WE,
  output logic [31:0] dbg_beats
);
  logic        m_req, m_we, m_wnext, m_wacc, m_rvalid, m_ack;
  logic [24:0] m_addr;
  logic [7:0]  m_blen, m_be;
  logic [63:0] m_din, m_dout;
  m1_fb_flush #(.SCR_W(496), .BAND_H(8)) u_flush (
    .clk(clk), .rst_n(rst_n), .fb_sel(fb_sel), .start(start), .band(band), .busy(busy),
    .rd_x(rd_x), .rd_row(rd_row), .rd_q4(rd_q4),
    .wc_en(wc_en), .wc_x(wc_x), .wc_row(wc_row),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_blen(m_blen), .m_din(m_din), .m_be(m_be),
    .m_wnext(m_wnext), .m_wacc(m_wacc), .m_ack(m_ack), .dbg_beats(dbg_beats));
  m2_ddr3 u_ddr3 (
    .clk(clk), .rst_n(rst_n), .req(m_req), .we(m_we), .base(29'h0601_0000), .addr(m_addr),
    .blen(m_blen), .din(m_din), .be(m_be),
    .wnext(m_wnext), .wacc(m_wacc), .rvalid(m_rvalid), .ack(m_ack), .dout(m_dout),
    .DDRAM_CLK(), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
    .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
    .DDRAM_WE(DDRAM_WE), .DDRAM_RD(DDRAM_RD), .DDRAM_DOUT(DDRAM_DOUT),
    .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
    .dbg_lat_last(), .dbg_lat_max(), .dbg_inflight_max(), .dbg_stuck_wr(), .dbg_acks());
endmodule
