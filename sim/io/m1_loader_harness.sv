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
// ROM loader wired to the real SDRAM controller and the protocol-checking
// device model.
//
// The loader could be tested against a stub write port, and that would verify
// its own state machine while proving nothing about whether ROM data actually
// reaches memory. The interesting failures are at the seam: the download port
// contract is one transaction per request RISING EDGE, single outstanding, and
// a loader that holds req high gets exactly one word written and silently
// loses the rest of the ROM. Only the real controller catches that.
//
// p0 is brought out so the test can read back what was loaded through the same
// path the V60 will use.

`timescale 1ns/1ps

module m1_loader_harness (
  input  logic        clk,
  input  logic        rst_n,
  output logic        mem_ready,

  // HPS ioctl
  input  logic        ioctl_download,
  input  logic [15:0] ioctl_index,
  input  logic        ioctl_wr,
  input  logic [26:0] ioctl_addr,
  input  logic [15:0] ioctl_dout,
  output logic        ioctl_wait,

  // Loader status
  output logic        rom_loaded,
  output logic        overflow,

  // TGP program memory write port, observed directly
  output logic        tgp_wr,
  output logic [10:0] tgp_addr,
  output logic [31:0] tgp_din,

  // Verification read port (p0)
  input  logic        p0_req,
  input  logic [24:1] p0_addr,
  output logic [63:0] p0_dout,
  output logic        p0_ack,

  output int unsigned violations,
  output logic [15:0] v_flags,
  // Writes the device actually accepted. rom_loaded is only honest if this has
  // reached the stream length by the time it asserts.
  output int unsigned writes_served
);

  localparam int unsigned NP    = 5;
  localparam int unsigned T_RCD = 2, T_RP = 2, T_RC = 7, T_RAS = 5;
  localparam int unsigned T_WR  = 2, CL = 2, T_REFI = 700, INIT_NOP = 600;

  logic        wr_req, wr_ack;
  logic [24:1] wr_addr;
  logic [15:0] wr_din;
  logic [1:0]  wr_be;

  m1_rom_loader loader (
    .clk(clk), .rst(~rst_n), .mem_ready(mem_ready),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .sdr_wr_req(wr_req), .sdr_wr_addr(wr_addr), .sdr_wr_din(wr_din),
    .sdr_wr_be(wr_be), .sdr_wr_ack(wr_ack),
    .tgp_wr(tgp_wr), .tgp_addr(tgp_addr), .tgp_din(tgp_din),
    .rom_loaded(rom_loaded), .overflow(overflow)
  );

  logic [NP-1:0]       p_req, p_we, p_ack;
  logic [NP-1:0][24:1] p_addr;
  logic [NP-1:0][15:0] p_din;
  logic [NP-1:0][1:0]  p_be;
  logic [NP-1:0][63:0] p_dout;
  logic [NP-1:0]       dbg_req, dbg_grant;

  assign p_req  = {4'b0000, p0_req};
  assign p_we   = '0;
  assign p_addr = {{4{24'd0}}, p0_addr};
  assign p_din  = '0;
  assign p_be   = '0;
  assign p0_ack  = p_ack[0];
  assign p0_dout = p_dout[0];

  logic        cke, cs_n, ras_n, cas_n, we_n;
  logic [1:0]  ba, dqm;
  logic [12:0] a;
  logic [15:0] dq_c2m, dq_m2c;
  logic        dq_oe_c, dq_oe_m;

  m1_sdram #(
    .NP(NP), .T_RCD(T_RCD), .T_RP(T_RP), .T_RC(T_RC), .T_RAS(T_RAS),
    .T_WR(T_WR), .CL(CL), .T_REFI(T_REFI), .INIT_NOP(INIT_NOP), .ACK_HOLD(2)
  ) sdram (
    .clk(clk), .rst_n(rst_n), .ready(mem_ready),
    .rd_lat_sel(2'd1),   // CL+3, what this harness is baselined on
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n),
    .sd_we_n(we_n), .sd_ba(ba), .sd_a(a), .sd_dqm(dqm),
    .sd_dq_o(dq_c2m), .sd_dq_oe(dq_oe_c), .sd_dq_i(dq_m2c),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_din(wr_din), .wr_be(wr_be),
    .wr_ack(wr_ack),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack),
    .dbg_req(dbg_req), .dbg_grant(dbg_grant)
  );

  sdram_model #(
    .COL_BITS(9), .T_RCD(T_RCD), .T_RP(T_RP), .T_RC(T_RC), .T_RAS(T_RAS),
    .T_WR(T_WR), .CL(CL), .T_REFI(781), .REFI_SLACK(9)
  ) device (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .ba(ba), .a(a), .dqm(dqm),
    .dq_i(dq_c2m), .dq_oe_i(dq_oe_c),
    .dq_o(dq_m2c), .dq_oe_o(dq_oe_m),
    .violations(violations), .v_flags(v_flags),
    .reads_served(), .writes_served(writes_served)
  );

endmodule
