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
// The main board's on-chip memories, kept together so their block-RAM
// inference can be synthesised and checked without the rest of the design.
//
// EVERY MEMORY IS SPLIT INTO BYTE LANES, AND THAT IS THE WHOLE POINT
//
// Quartus 17.0 does not infer block RAM from the obvious byte-enable idiom:
//
//     if (we) begin
//       if (be[0]) mem[a][7:0]  <= d[7:0];
//       if (be[1]) mem[a][15:8] <= d[15:8];
//     end
//     q <= mem[a];
//
// It builds that from flip-flops instead, silently. Written that way these
// arrays total 2.7 Mbit — roughly 2.7 million registers on a device with
// 41,910 ALMs — and synthesis simply never finished, grinding for
// twenty-five minutes at 15 GB before being killed. Twice.
//
// Two byte-wide arrays with plain write enables infer immediately. Confirmed
// by synthesising both forms side by side in one small module: the 16-bit
// form produced nothing, the byte-lane form produced two altsyncram
// megafunctions. Testing the idiom at 1024 entries took thirty seconds and
// answered what hours of full-size builds had not.
//
// The ramstyle attribute stays as belt and braces: it makes a future
// regression a build error rather than a silent resource catastrophe.
// Simulation cannot catch any of this — Verilator has no opinion about
// whether storage lands in RAM or registers.
//
// Tile RAM and palette RAM appear twice because they are read by the CPU and
// by the video renderer at independent addresses. Two reads plus a write fits
// no M10K configuration, so the copies are explicit and take the same writes.

`timescale 1ns/1ps

module m1_mainram (
  input  logic        clk,

  // CPU side
  input  logic        we,
  input  logic [1:0]  be,
  input  logic [23:1] addr,
  input  logic [15:0] wdata,
  input  logic        sel_tileram, sel_palette, sel_dlist0,
  input  logic        sel_dlist1, sel_colxlat, sel_dpram,
  output logic [15:0] tram_q, pram_q, dl0_q, dl1_q, cxlat_q, dpram_q,

  // Video side. Its own clock: the video path runs in the fast domain and the
  // CPU in the slow one, and these two arrays are where the domains meet.
  // Written by the CPU, read by the renderer, never the other way, so the
  // crossing needs no handshake — the renderer sees whatever the CPU last
  // wrote, which is exactly what a tilemap read off a shared bus does on the
  // real board.
  //
  // Dual-clock inference measured before it was used: 32768x8 written on one
  // clock and read on another gives 32 M10K and 37 ALM standalone. Two
  // always_ff blocks are REQUIRED here — one per clock — which is the opposite
  // of the rule for the dpram below, where two blocks on one array killed
  // inference. The difference is one write port versus two.
  input  logic        vid_clk,
  input  logic [14:0] vid_tram_addr,
  output logic [15:0] vid_tram_data,
  input  logic [11:0] vid_pal_addr,
  output logic [15:0] vid_pal_data,

  // I/O board side of the RAM at 0xc00000. Byte-wide, write-only, and it
  // shares the V60's physical write port — hold io_we until io_ack.
  input  logic        io_we,
  input  logic [10:0] io_addr,
  input  logic [7:0]  io_din,
  output logic        io_ack
);

  logic tram_we, pram_we, dl0_we, dl1_we, cxlat_we, dpram_we;
  assign tram_we  = we && sel_tileram;
  assign pram_we  = we && sel_palette;
  assign dl0_we   = we && sel_dlist0;
  assign dl1_we   = we && sel_dlist1;
  assign cxlat_we = we && sel_colxlat && (addr[15:1] < 15'd24576);
  assign dpram_we = we && sel_dpram;

  // SCR 0x700000-0x70ffff, CPU side
  (* ramstyle = "M10K" *) logic [7:0] tram_c_lo [32768];
  (* ramstyle = "M10K" *) logic [7:0] tram_c_hi [32768];
  always_ff @(posedge clk) begin
    if (tram_we && be[0]) tram_c_lo[addr[15:1]] <= wdata[7:0];
    if (tram_we && be[1]) tram_c_hi[addr[15:1]] <= wdata[15:8];
    tram_q <= {tram_c_hi[addr[15:1]], tram_c_lo[addr[15:1]]};
  end

  //                        video side, read in the video clock domain
  (* ramstyle = "M10K" *) logic [7:0] tram_v_lo [32768];
  (* ramstyle = "M10K" *) logic [7:0] tram_v_hi [32768];
  always_ff @(posedge clk) begin
    if (tram_we && be[0]) tram_v_lo[addr[15:1]] <= wdata[7:0];
    if (tram_we && be[1]) tram_v_hi[addr[15:1]] <= wdata[15:8];
  end
  always_ff @(posedge vid_clk) begin
    vid_tram_data <= {tram_v_hi[vid_tram_addr], tram_v_lo[vid_tram_addr]};
  end

  // COL 0x900000-0x903fff, CPU side
  (* ramstyle = "M10K" *) logic [7:0] pram_c_lo [8192];
  (* ramstyle = "M10K" *) logic [7:0] pram_c_hi [8192];
  always_ff @(posedge clk) begin
    if (pram_we && be[0]) pram_c_lo[addr[13:1]] <= wdata[7:0];
    if (pram_we && be[1]) pram_c_hi[addr[13:1]] <= wdata[15:8];
    pram_q <= {pram_c_hi[addr[13:1]], pram_c_lo[addr[13:1]]};
  end

  //                        video side, read in the video clock domain
  (* ramstyle = "M10K" *) logic [7:0] pram_v_lo [8192];
  (* ramstyle = "M10K" *) logic [7:0] pram_v_hi [8192];
  always_ff @(posedge clk) begin
    if (pram_we && be[0]) pram_v_lo[addr[13:1]] <= wdata[7:0];
    if (pram_we && be[1]) pram_v_hi[addr[13:1]] <= wdata[15:8];
  end
  always_ff @(posedge vid_clk) begin
    vid_pal_data <= {pram_v_hi[{1'b0, vid_pal_addr}], pram_v_lo[{1'b0, vid_pal_addr}]};
  end

  // TGP 0x600000-0x60ffff
  (* ramstyle = "M10K" *) logic [7:0] dl0_lo [32768];
  (* ramstyle = "M10K" *) logic [7:0] dl0_hi [32768];
  always_ff @(posedge clk) begin
    if (dl0_we && be[0]) dl0_lo[addr[15:1]] <= wdata[7:0];
    if (dl0_we && be[1]) dl0_hi[addr[15:1]] <= wdata[15:8];
    dl0_q <= {dl0_hi[addr[15:1]], dl0_lo[addr[15:1]]};
  end

  // TGP 0x610000-0x61ffff
  (* ramstyle = "M10K" *) logic [7:0] dl1_lo [32768];
  (* ramstyle = "M10K" *) logic [7:0] dl1_hi [32768];
  always_ff @(posedge clk) begin
    if (dl1_we && be[0]) dl1_lo[addr[15:1]] <= wdata[7:0];
    if (dl1_we && be[1]) dl1_hi[addr[15:1]] <= wdata[15:8];
    dl1_q <= {dl1_hi[addr[15:1]], dl1_lo[addr[15:1]]};
  end

  // COL 0x910000-0x91bfff
  (* ramstyle = "M10K" *) logic [7:0] cxlat_lo [24576];
  (* ramstyle = "M10K" *) logic [7:0] cxlat_hi [24576];
  always_ff @(posedge clk) begin
    if (cxlat_we && be[0]) cxlat_lo[addr[14:1]] <= wdata[7:0];
    if (cxlat_we && be[1]) cxlat_hi[addr[14:1]] <= wdata[15:8];
    cxlat_q <= {cxlat_hi[addr[14:1]], cxlat_lo[addr[14:1]]};
  end

  // I/O 0xc00000-0xc00fff
  //
  // The real board has an MB8421 here — a true dual-port RAM, V60 on one side
  // and the I/O board on the other. **Quartus 17.0 will not infer one from this
  // array.** Measured, not assumed: adding a second write port took m1_mainram
  // from 192 ALM / 324 M10K to 16,059 ALM / 322 M10K, because 2048x8 of
  // dpram_lo fell out of block RAM into 16,384 flip-flops — and the fit
  // reported success. Both the textbook true-dual-port shape and the same shape
  // with `no_rw_check` were tried at 2048 entries on their own; both gave zero
  // M10K. See docs/rtl-conventions.md.
  //
  // So the two masters share one physical write port, with the V60 taking
  // priority and the I/O side told to wait. That is behaviourally identical
  // here: the I/O board writes about three bytes across an entire boot, and
  // io_ack makes the stall explicit rather than dropping a write on a
  // collision. What it gives up is simultaneous writes from both sides, which
  // nothing in this design does.
  logic        dp_we;
  logic [10:0] dp_waddr;
  logic [7:0]  dp_wdata;
  logic        v60_dp_write;

  always_comb begin
    v60_dp_write = dpram_we && be[0];
    if (v60_dp_write) begin
      dp_we    = 1'b1;
      dp_waddr = addr[11:1];
      dp_wdata = wdata[7:0];
    end else begin
      dp_we    = io_we;
      dp_waddr = io_addr;
      dp_wdata = io_din;
    end
    // The I/O write landed this cycle. Held low while the V60 owns the port,
    // which is what the responder waits on.
    io_ack = io_we && !v60_dp_write;
  end

  (* ramstyle = "M10K" *) logic [7:0] dpram_lo [2048];
  (* ramstyle = "M10K" *) logic [7:0] dpram_hi [2048];
  always_ff @(posedge clk) begin
    if (dp_we)             dpram_lo[dp_waddr]   <= dp_wdata;
    if (dpram_we && be[1]) dpram_hi[addr[11:1]] <= wdata[15:8];
    dpram_q <= {dpram_hi[addr[11:1]], dpram_lo[addr[11:1]]};
  end

endmodule
