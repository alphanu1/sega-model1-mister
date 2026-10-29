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
// SDRAM port p6, shared by the 3D layer's two SDRAM-resident memories:
// tgp_ram (the colour words, read per polygon and written by display-list
// command 4) and the UPPER HALF of the display list, words 0x4000-0x7fff,
// which the board has and the on-chip list RAM does not (m1_main DLHI_BASE).
//
// Command 4 is the one place both are busy: the walker reads a colour word out
// of the list's upper half and the 3D layer writes it into tgp_ram, then the
// next. Both requesters HOLD their request until acknowledged, so the arbiter
// is one owner at a time, tgp_ram first on a tie, with the access latched at
// the grant (see the note in the body for why the latch, not the request,
// drives the port).
//
// Tested by sim/video/tb_m1_p6_arb.cpp: both requesters at random against a
// port with random latency; every word comes back to the requester that asked,
// for the address it asked, exactly once.

`timescale 1ns/1ps

module m1_p6_arb #(
  parameter logic [25:1] TEX_BASE  = 25'hC20000,   // tgp_ram
  parameter logic [25:1] DLHI_BASE = 25'hCE0000    // display lists, upper halves
) (
  input  logic        clk,
  input  logic        rst_n,

  // tgp_ram, from m1_raster3d
  input  logic        tex_req,
  input  logic        tex_we,
  input  logic [19:0] tex_addr,
  input  logic [15:0] tex_wdata,
  output logic        tex_valid,
  output logic [15:0] tex_data,

  // the upper half of the display list, from m1_raster3d's walker; the
  // caller raises dl_req only for word addresses at or above 0x4000
  input  logic        dl_req,
  input  logic        dl_sel,          // which buffer the walk is reading
  input  logic [13:0] dl_addr,         // word within the upper half
  output logic        dl_valid,
  output logic [15:0] dl_data,

  // to m1_cdc_port's requester side
  output logic        p_req,
  output logic        p_we,
  output logic [25:1] p_addr,
  output logic [15:0] p_din,
  input  logic [15:0] p_dout,
  input  logic        p_ack
);

  // EVERYTHING IS LATCHED AT THE GRANT and the port is driven from the
  // latch, not from the requesters. The walker can STALL - m1_listwalk drops
  // mem_req while its consumer is busy - and a request that falls and rises
  // around its own acknowledge is a NEW level to m1_cdc_port, accepted on the
  // acknowledge cycle itself: a second, stray transaction that the next owner
  // would then be handed. tb_m1_p6_arb found exactly that against the first
  // version, which drove the port straight from the requests. So the list
  // side's answer is kept in a one-word buffer, tagged with its address, and
  // handed over when the walker asks again; the port's request is the latch's,
  // and drops for at least the cycle after every acknowledge.
  logic [1:0]  own;              // 0 free, 1 tgp_ram, 2 display list
  logic [25:1] l_addr;
  logic        l_we;
  logic [15:0] l_din;
  logic [14:0] l_tag;            // {dl_sel, dl_addr} of the list read in flight
  logic        b_v;              // the list word below is held for the walker
  logic [14:0] b_tag;
  logic [15:0] b_data;

  wire [14:0] dl_tag  = {dl_sel, dl_addr};
  wire        b_hit   = b_v && (b_tag == dl_tag);
  wire        dl_need = dl_req && !b_hit;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      own <= 2'd0; l_addr <= '0; l_we <= 1'b0; l_din <= '0; l_tag <= '0;
      b_v <= 1'b0; b_tag <= '0; b_data <= '0;
    end else begin
      if (own != 2'd0) begin
        if (p_ack) begin
          own <= 2'd0;
          if (own == 2'd2) begin b_v <= 1'b1; b_tag <= l_tag; b_data <= p_dout; end
        end
      end else if (tex_req) begin
        own <= 2'd1; l_addr <= TEX_BASE + {5'd0, tex_addr};
        l_we <= tex_we; l_din <= tex_wdata;
      end else if (dl_need) begin
        own <= 2'd2; l_addr <= DLHI_BASE + {10'd0, dl_tag};
        l_we <= 1'b0; l_tag <= dl_tag;
      end
      // handed over: the walker had it this cycle
      if (dl_req && b_hit) b_v <= 1'b0;
    end
  end

  assign p_req  = (own != 2'd0);
  assign p_we   = l_we && (own == 2'd1);
  assign p_addr = l_addr;
  assign p_din  = l_din;

  // tgp_ram's requester holds its request (with the same address) until this.
  assign tex_valid = p_ack && (own == 2'd1);
  assign tex_data  = p_dout;
  assign dl_valid  = dl_req && b_hit;
  assign dl_data   = b_data;

endmodule
