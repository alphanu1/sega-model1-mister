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
// Simulation wiring for the SDRAM controller: controller, protocol-checking
// device model, and the bandwidth monitor, with the same timing parameters
// handed to both sides.
//
// Passing one set of localparams to both the controller and the checker is the
// point. A controller built for one clock and checked against a model built
// for another agrees with itself and with nothing real, and that mistake
// leaves no trace in the output.
//
// Ports are broken out per master rather than as packed arrays so the C++
// harness can drive them without unpacking wide vectors by hand.

`timescale 1ns/1ps

module m1_sdram_harness (
  input  logic        clk,
  input  logic        rst_n,
  output logic        ready,

  // ROM download
  input  logic        wr_req,
  input  logic [24:1] wr_addr,
  input  logic [15:0] wr_din,
  input  logic [1:0]  wr_be,
  output logic        wr_ack,

  // p0 V60 (read/write), p1 tile char, p2 polygon/TGP, p3 sound 68000,
  // p4 MultiPCM. See docs/00-decisions.md D8.
  input  logic        p0_req, p1_req, p2_req, p3_req, p4_req,
  input  logic        p0_we,
  input  logic [24:1] p0_addr, p1_addr, p2_addr, p3_addr, p4_addr,
  input  logic [15:0] p0_din,
  input  logic [1:0]  p0_be,
  output logic [63:0] p0_dout, p1_dout, p2_dout, p3_dout, p4_dout,
  output logic        p0_ack, p1_ack, p2_ack, p3_ack, p4_ack,

  // Device model observability
  output int unsigned violations,
  output logic [15:0] v_flags,
  output int unsigned reads_served,
  output int unsigned writes_served,

  // Telemetry readback
  input  logic [2:0]  mon_sel,
  input  logic        mon_snap,
  output logic [23:0] mon_req,
  output logic [23:0] mon_grant,
  output logic [23:0] mon_wait,
  output logic [7:0]  mon_bmax,
  output logic [23:0] mon_total
);

  localparam int unsigned NP    = 5;
  localparam int unsigned T_RCD = 2;
  localparam int unsigned T_RP  = 2;
  localparam int unsigned T_RC  = 7;
  localparam int unsigned T_RAS = 5;
  localparam int unsigned T_WR  = 2;
  localparam int unsigned CL    = 2;
  localparam int unsigned T_REFI = 700;
  // Long enough to be a real bring-up but short enough that every test does
  // not pay 100 us of NOPs; the sequence exercised is identical.
  localparam int unsigned INIT_NOP = 600;

  logic [NP-1:0]       p_req, p_we, p_ack;
  logic [NP-1:0][24:1] p_addr;
  logic [NP-1:0][15:0] p_din;
  logic [NP-1:0][1:0]  p_be;
  logic [NP-1:0][63:0] p_dout;
  logic [NP-1:0]       dbg_req, dbg_grant;

  assign p_req  = {p4_req, p3_req, p2_req, p1_req, p0_req};
  assign p_we   = {4'b0000, p0_we};
  assign p_addr = {p4_addr, p3_addr, p2_addr, p1_addr, p0_addr};
  assign p_din  = {64'd0, p0_din};
  assign p_be   = {8'd0, p0_be};

  assign {p4_ack, p3_ack, p2_ack, p1_ack, p0_ack} = p_ack;
  assign p0_dout = p_dout[0];
  assign p1_dout = p_dout[1];
  assign p2_dout = p_dout[2];
  assign p3_dout = p_dout[3];
  assign p4_dout = p_dout[4];

  logic        cke, cs_n, ras_n, cas_n, we_n;
  logic [1:0]  ba, dqm;
  logic [12:0] a;
  logic [15:0] dq_c2m, dq_m2c;
  logic        dq_oe_c, dq_oe_m;

  m1_sdram #(
    .NP(NP), .T_RCD(T_RCD), .T_RP(T_RP), .T_RC(T_RC), .T_RAS(T_RAS),
    .T_WR(T_WR), .CL(CL), .T_REFI(T_REFI), .INIT_NOP(INIT_NOP), .ACK_HOLD(2)
  ) dut (
    .clk(clk), .rst_n(rst_n), .ready(ready),
    .rd_lat_sel(2'd0),   // CL+3, what this harness is baselined on
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n),
    .sd_we_n(we_n), .sd_ba(ba), .sd_a(a), .sd_dqm(dqm),
    .sd_dq_o(dq_c2m), .sd_dq_oe(dq_oe_c), .sd_dq_i(dq_m2c),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_din(wr_din), .wr_be(wr_be),
    .wr_ack(wr_ack),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack),
    .dbg_req(dbg_req), .dbg_grant(dbg_grant)
  );

  // The same timing numbers, so the checker is checking the clock the
  // controller was built for.
  sdram_model #(
    .COL_BITS(9),
    .T_RCD(T_RCD), .T_RP(T_RP), .T_RC(T_RC), .T_RAS(T_RAS), .T_WR(T_WR),
    .CL(CL), .T_REFI(781), .REFI_SLACK(9)
  ) device (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .ba(ba), .a(a), .dqm(dqm),
    .dq_i(dq_c2m), .dq_oe_i(dq_oe_c),
    .dq_o(dq_m2c), .dq_oe_o(dq_oe_m),
    .violations(violations), .v_flags(v_flags),
    .reads_served(reads_served), .writes_served(writes_served)
  );

  bw_monitor #(.MASTERS(NP), .CW(24), .BW(8)) mon (
    .clk(clk), .rst_n(rst_n),
    .req(dbg_req), .grant(dbg_grant),
    .snap(mon_snap), .sel(mon_sel[2:0]),
    .req_count(mon_req), .grant_count(mon_grant), .wait_count(mon_wait),
    .burst_max(mon_bmax), .total_cycles(mon_total)
  );

endmodule
