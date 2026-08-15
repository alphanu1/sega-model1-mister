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
// Everything built so far, as one design, for measurement.
//
// This exists to answer a question no per-module build can: every ALM figure
// quoted for this project so far is a SUM of standalone synthesis runs, and
// integration moves that number in both directions. Cross-boundary
// optimisation removes logic that only existed to drive a port; routing
// congestion above about 70% utilisation costs Fmax; and a block that
// synthesised into RAM on its own can fall out of it when its neighbours
// compete for the same M10K.
//
// It is not the core. There is no MiSTer framework, no clocking, no reset
// sequencing and no I/O board, and the TGP is not instantiated. It is the V60
// side and the 2D video side wired together with their real interfaces, which
// is enough to measure the two terms that dominate the budget.
//
// The ports are deliberately narrow so the fitter cannot optimise the design
// away through unconnected outputs, and every real interface is brought out.

`timescale 1ns/1ps

module m1_integrated (
  input  logic        clk,
  input  logic        ce_cpu,
  input  logic        ce_pix,
  input  logic        rst_n,
  input  logic        rom_loaded,

  // SDRAM data port and instruction fetch
  output logic        sdr_req,
  output logic        sdr_we,
  output logic [24:1] sdr_addr,
  output logic [15:0] sdr_din,
  output logic [1:0]  sdr_be,
  input  logic [15:0] sdr_dout,
  input  logic        sdr_ack,

  output logic        if_req,
  output logic [23:0] if_addr,
  output logic [24:1] if_sdram_addr,
  input  logic [63:0] if_data,
  input  logic        if_ack,

  // Character RAM fetch, for the tilemap
  output logic        char_req,
  output logic [17:0] char_addr,
  input  logic [31:0] char_data,
  input  logic        char_ack,

  // ROM download
  input  logic        ioctl_download,
  input  logic [15:0] ioctl_index,
  input  logic        ioctl_wr,
  input  logic [26:0] ioctl_addr,
  input  logic [15:0] ioctl_dout,
  output logic        ioctl_wait,
  output logic        ldr_wr_req,
  output logic [24:1] ldr_wr_addr,
  output logic [15:0] ldr_wr_din,
  output logic [1:0]  ldr_wr_be,
  input  logic        ldr_wr_ack,
  output logic        tgp_wr,
  output logic [10:0] tgp_addr,
  output logic [31:0] tgp_din,

  // Video out
  output logic [7:0]  vid_r, vid_g, vid_b,
  output logic        vid_hs, vid_vs, vid_hb, vid_vb,

  // Telemetry
  input  logic [2:0]  mon_sel,
  input  logic        mon_snap,
  output logic [23:0] mon_req, mon_grant, mon_wait,
  output logic [7:0]  mon_bmax,
  output logic [23:0] mon_total,
  input  logic [4:0]  mon_req_in,
  input  logic [4:0]  mon_grant_in,

  output logic [23:0] dbg_pc,
  output logic        dbg_halted,
  output logic        dbg_fp_trap,
  output logic [15:0] dbg_io_replies,
  output logic        rom_loaded_o,
  output logic [7:0]  dbg_fetches
);

  logic [14:0] vid_tram_addr;
  logic [15:0] vid_tram_data;
  logic [11:0] vid_pal_addr;
  logic [15:0] vid_pal_data;
  logic        vblank_irq;
  logic [2:0]  rom_bank;

  m1_main main (
    .clk(clk), .ce(ce_cpu), .rst_n(rst_n), .rom_loaded(rom_loaded),
    .sdr_req(sdr_req), .sdr_we(sdr_we), .sdr_addr(sdr_addr),
    .sdr_din(sdr_din), .sdr_be(sdr_be), .sdr_dout(sdr_dout), .sdr_ack(sdr_ack),
    .if_req(if_req), .if_addr(if_addr), .if_sdram_addr(if_sdram_addr),
    .if_data(if_data), .if_ack(if_ack),
    .vid_tram_addr(vid_tram_addr), .vid_tram_data(vid_tram_data),
    .vid_pal_addr(vid_pal_addr), .vid_pal_data(vid_pal_data),
    .vblank_irq(vblank_irq),
    .dbg_pc(dbg_pc), .dbg_halted(dbg_halted), .dbg_fp_trap(dbg_fp_trap),
    .dbg_io_replies(dbg_io_replies),
    .rom_bank(rom_bank)
  );

  m1_video video (
    .clk(clk), .ce_pix(ce_pix), .rst_n(rst_n),
    .tile_mask(14'h3fff),
    .tram_addr(vid_tram_addr), .tram_data(vid_tram_data),
    .char_req(char_req), .char_addr(char_addr),
    .char_data(char_data), .char_ack(char_ack),
    .pal_addr(vid_pal_addr), .pal_data(vid_pal_data),
    .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
    .vid_hs(vid_hs), .vid_vs(vid_vs), .vid_hb(vid_hb), .vid_vb(vid_vb),
    .vblank_irq(vblank_irq), .dbg_fetches(dbg_fetches)
  );

  m1_rom_loader loader (
    .clk(clk), .rst(~rst_n), .mem_ready(rom_loaded),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .sdr_wr_req(ldr_wr_req), .sdr_wr_addr(ldr_wr_addr),
    .sdr_wr_din(ldr_wr_din), .sdr_wr_be(ldr_wr_be), .sdr_wr_ack(ldr_wr_ack),
    .tgp_wr(tgp_wr), .tgp_addr(tgp_addr), .tgp_din(tgp_din),
    .rom_loaded(rom_loaded_o), .overflow()
  );

  bw_monitor #(.MASTERS(5), .CW(24), .BW(8)) mon (
    .clk(clk), .rst_n(rst_n),
    .req(mon_req_in), .grant(mon_grant_in),
    .snap(mon_snap), .sel(mon_sel),
    .req_count(mon_req), .grant_count(mon_grant), .wait_count(mon_wait),
    .burst_max(mon_bmax), .total_cycles(mon_total)
  );

endmodule
