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
// GAME SPEED, MEASURED ON THE BOARD, OVER THE PRINTF CHANNEL.
//
// Simulation says the game runs at 65% of hardware speed and the instruction
// rate agrees at 67%. Ben times the MiSTer against real running time and reads
// about a third. Both cannot describe the same machine, and the two answers
// call for completely different work - at 65% it is memory latency, at 33%
// something is being waited on that simulation does not reproduce. So measure
// the board rather than infer it.
//
// THE METRIC IS THE DISPLAY-LIST SWAP, because it needs no modelling: the game
// flips listctl's buffer select once per completed logic frame, and the
// reference's rate is measured at exactly 2 video frames - 993 flips of 996,
// tools/mame_listctl_rate.lua. So frames-per-swap IS the speed ratio.
//
//     2.00 frames a swap   100% of hardware speed
//     3.04                  65%   (what simulation measures)
//     6.00                  33%   (what the board looks like)
//
// One line a second over rtl/io/m1_uart_tx.sv, which drives UART_TXD into the
// HPS's own ttyS1. Read it with the console's getty out of the way, since
// /proc/cmdline carries console=ttyS0,115200:
//
//     ssh root@<mister> "stty -F /dev/ttyS1 115200 raw -echo; cat /dev/ttyS1"
//
// IT IS ttyS1, NOT ttyS0, AND THERE IS NO GETTY TO KILL. Measured on the board
// 2026-09-01: /proc/tty/driver/serial shows port 0 (ttyS0, mmio FFC02000) is the
// console with rx:0, and port 1 (ttyS1, mmio FFC03000) carrying rx:460058 - our
// bytes. sys_top wires emu's UART_TXD into cyclonev_hps_interface_peripheral_uart,
// which is the HPS's SECOND uart; ttyS0 is the physical console header and never
// sees a byte of this. The old instruction also piped through `pgrep`, which does
// not exist on the MiSTer's BusyBox, so the kill was a silent no-op - and killing
// it was never needed, because nothing holds ttyS1.
//
// HEX, NOT DECIMAL. A binary-to-decimal conversion is a divider and a state
// machine for something a human reads once; a nibble to ASCII is four gates.
// 24 bytes a second against 11,520 is nothing, and m1_uart_tx drops rather than
// stalls, so a debug channel can never hold up the design.

`timescale 1ns/1ps

module m1_speed_report #(
  parameter int unsigned CLK_HZ  = 80_000_000,
  parameter int unsigned BAUD    = 115_200,
  // Video frames between reports. 58 is about a second at 57.52 Hz, and the
  // exact figure does not matter because the count of frames is reported too.
  parameter int unsigned PERIOD  = 58
) (
  input  logic clk,
  input  logic rst_n,

  input  logic vblank,          // one pulse per video frame
  input  logic list_sel,        // listctl bit 6, the display-list buffer select
  // NOT BANDS. This is wired to m1_raster3d's dbg_frames, which increments once
  // per COMPLETED GEOMETRY PASS - at P_SORTW, after the sort - and says nothing
  // about how many of the 24 bands were drawn. The old comment claimed bands
  // and cost a wrong diagnosis: on hardware B advances ~20 a second against ~28
  // display-list swaps, which is 8 logic frames a second completing no new
  // geometry, and reading it as "bands" hides that completely.
  input  logic [15:0] bands,    // completed 3D geometry passes, free-running
  input  logic [15:0] passes,   // 3D geometry passes, free-running
  // THE COPROCESSOR'S OWN STATE, because the board keeps showing a black screen
  // with the 3D layer receiving nothing and the existing fields cannot say why.
  // Parked at microcode 0x004c means starved of commands; anywhere else means it
  // is executing; retires stuck at zero means it never left reset at all. Those
  // are different faults and five builds have been spent guessing between them.
  // BANDS ACTUALLY PRESENTED, which is the one thing the other counters cannot
  // distinguish. `bands` above counts completed GEOMETRY PASSES; this counts
  // ev_present, a band handed to the display. Expected is 24 x the video frame
  // rate, ~1,380 a second. If N is at rate while B is low, the passes are being
  // lost and the display is repeating a stale one; if N is short, bands are
  // genuinely not reaching the screen. Simulation shows 24 on 668 of 669
  // frames, so whatever Ben sees on the board is not reproduced there and this
  // is the instrument that says which of the two it is.
  // THE V60'S PC, because the crash needs it and the overlay cannot show a
  // sequence. On 2026-09-03 the five-minute fault was captured for the first
  // time: video timing alive, V60 swapping display lists at full rate, bands
  // still presented, and the screen entirely black - 2D as well as 3D. That
  // cannot be a dead coprocessor, since the tile path never touches the TGP.
  // Whether the GAME has crashed or the hardware has stopped drawing is one
  // reading of this value apart.
  // The V60's pc LATCHED at the instant the coprocessor stopped retiring, as
  // opposed to v60_pc which is sampled once a second and cannot catch a
  // transition. Zero until the first stall. See m1_integrated for the detector.
  input  logic [23:0] stall_pc,
  input  logic [23:0] v60_pc,
  input  logic [15:0] bands_pres,
  input  logic [15:0] tgp_pc,      // coprocessor program counter
  input  logic [15:0] tgp_retires, // free-running retire count
  // How long the last completed geometry pass took, in clk_3d cycles. Sent as
  // L=, in units of 256 cycles: a frame is 818,133 cycles = 0x0C7C, so a pass
  // that reads above that has run over a frame - which is the whole question
  // the field exists to answer on the board. See m1_raster3d.
  input  logic [31:0] pass_cycles,
  // The last band's fill in clk_3d cycles, and bands presented late. W= is the
  // WORST band fill seen in the reporting window, in 16-cycle units: a band's
  // beam slot is 34,089 cycles = 0x0853 in those units, and above it the band
  // went up after the beam had started on it. T= is the late count itself.
  input  logic [31:0] band_cycles,
  input  logic [15:0] late,
  // D= quads dropped by the store, summed over passes; H= passes that walked
  // fewer than half the previous pass's objects. Both free-running.
  input  logic [15:0] dropped,
  input  logic [15:0] short_passes,
  // THE 3D LAYER'S LEFT CLIP PLANE, as a screen coordinate.
  //
  // The left half of the 3D vanishes on corners and STAYS gone while the car
  // is parked, which is the shape of a latched register rather than a
  // per-frame effect: vx1 becomes the frustum's left plane and everything
  // left of it is clipped away before it is ever stored, which is also why
  // the dropped-quad counter reads zero throughout. Simulation cannot answer
  // this - 700 M cycles never reached gameplay - so it goes on the wire.
  input  logic [15:0] view_x1,

  output logic tx
);

  // ------------------------------------------------------------- counters
  logic [15:0] n_frame, n_swap;
  logic [15:0] period_cnt;
  logic        sel_d;
  logic [15:0] r_frame, r_swap, r_bands, r_pass;
  logic [15:0] r_tpc, r_tret, r_npres;
  logic [23:0] r_vpc, r_spc;
  logic [15:0] r_plen, r_late, r_wband, r_drop, r_short, r_vx1;
  logic [31:0] wband_max;
  logic        report_go;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      n_frame <= '0; n_swap <= '0; period_cnt <= '0; sel_d <= 1'b0;
      r_frame <= '0; r_swap <= '0; r_bands <= '0; r_pass <= '0;
      r_tpc <= '0; r_tret <= '0; r_npres <= '0; r_vpc <= '0; r_spc <= '0;
      r_plen <= '0; r_late <= '0; r_wband <= '0; wband_max <= '0;
      r_drop <= '0; r_short <= '0; r_vx1 <= '0;
      report_go <= 1'b0;
    end else begin
      report_go <= 1'b0;
      sel_d <= list_sel;
      if (list_sel != sel_d) n_swap <= n_swap + 16'd1;
      if (band_cycles > wband_max) wband_max <= band_cycles;
      if (vblank) begin
        n_frame <= n_frame + 16'd1;
        if (period_cnt == 16'(PERIOD - 1)) begin
          // Snapshot and restart. The counters are cleared rather than left to
          // run, so a line is a rate and not a total anyone has to subtract.
          period_cnt <= '0;
          r_frame <= n_frame + 16'd1; n_frame <= '0;
          r_swap  <= n_swap;          n_swap  <= '0;
          r_bands <= bands;
          r_pass  <= passes;
          r_tpc   <= tgp_pc;
          r_tret  <= tgp_retires;
          r_npres <= bands_pres;
          r_vpc   <= v60_pc;
          r_spc   <= stall_pc;
          r_plen  <= pass_cycles[23:8];
          r_late  <= late;
          r_drop  <= dropped; r_short <= short_passes;
          r_vx1   <= view_x1;
          r_wband <= wband_max[19:4]; wband_max <= '0;
          report_go <= 1'b1;
        end else period_cnt <= period_cnt + 16'd1;
      end
    end
  end

  // ------------------------------------------------------------- formatter
  // "F=xxxx S=xxxx B=xxxx P=xxxx C=xxxx R=xxxx N=xxxx V=xxxxxx X=xxxxxx L=xxxx T=xxxx W=xxxx D=xxxx H=xxxx K=xxxx\r\n"
  // 103 bytes. ci must be SEVEN bits: at [5:0] it wraps at 64 and the line
  // silently repeats its middle.
  // 117 bytes a second against 11,520 available, so the channel is not a concern.
  localparam int unsigned NCH = 117;

  logic [6:0]  ci;
  logic        busy;
  logic [7:0]  ch;
  logic        wr;
  logic        full;
  // Named rather than left empty: a dropped byte means the line was truncated,
  // which is worth being able to see rather than silently reading a short line.
  logic        tx_overflow;

  function automatic [7:0] hexc(input logic [3:0] n);
    hexc = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
  endfunction

  // The four values, concatenated, so the character index picks a nibble.
  wire [63:0] vals = {r_frame, r_swap, r_bands, r_pass};

  always_comb begin
    ch = 8'h20;
    case (ci)
      6'd0:  ch = "F";
      6'd1:  ch = "=";
      6'd2:  ch = hexc(vals[63:60]);
      6'd3:  ch = hexc(vals[59:56]);
      6'd4:  ch = hexc(vals[55:52]);
      6'd5:  ch = hexc(vals[51:48]);
      6'd6:  ch = " ";
      6'd7:  ch = "S";
      6'd8:  ch = "=";
      6'd9:  ch = hexc(vals[47:44]);
      7'd10: ch = hexc(vals[43:40]);
      7'd11: ch = hexc(vals[39:36]);
      7'd12: ch = hexc(vals[35:32]);
      7'd13: ch = " ";
      7'd14: ch = "B";
      7'd15: ch = "=";
      7'd16: ch = hexc(vals[31:28]);
      7'd17: ch = hexc(vals[27:24]);
      7'd18: ch = hexc(vals[23:20]);
      7'd19: ch = hexc(vals[19:16]);
      7'd20: ch = " ";
      7'd21: ch = "P";
      7'd22: ch = "=";
      7'd23: ch = hexc(vals[15:12]);
      7'd24: ch = hexc(vals[11:8]);
      7'd25: ch = hexc(vals[7:4]);
      7'd26: ch = hexc(vals[3:0]);
      7'd27: ch = " ";
      7'd28: ch = "C";
      7'd29: ch = "=";
      7'd30: ch = hexc(r_tpc[15:12]);
      7'd31: ch = hexc(r_tpc[11:8]);
      7'd32: ch = hexc(r_tpc[7:4]);
      7'd33: ch = hexc(r_tpc[3:0]);
      7'd34: ch = " ";
      7'd35: ch = "R";
      7'd36: ch = "=";
      7'd37: ch = hexc(r_tret[15:12]);
      7'd38: ch = hexc(r_tret[11:8]);
      7'd39: ch = hexc(r_tret[7:4]);
      7'd40: ch = hexc(r_tret[3:0]);
      7'd41: ch = " ";
      7'd42: ch = "N";
      7'd43: ch = "=";
      7'd44: ch = hexc(r_npres[15:12]);
      7'd45: ch = hexc(r_npres[11:8]);
      7'd46: ch = hexc(r_npres[7:4]);
      7'd47: ch = hexc(r_npres[3:0]);
      7'd48: ch = " ";
      7'd49: ch = "V";
      7'd50: ch = "=";
      7'd51: ch = hexc(r_vpc[23:20]);
      7'd52: ch = hexc(r_vpc[19:16]);
      7'd53: ch = hexc(r_vpc[15:12]);
      7'd54: ch = hexc(r_vpc[11:8]);
      7'd55: ch = hexc(r_vpc[7:4]);
      7'd56: ch = hexc(r_vpc[3:0]);
      7'd57: ch = " ";
      7'd58: ch = "X";
      7'd59: ch = "=";
      7'd60: ch = hexc(r_spc[23:20]);
      7'd61: ch = hexc(r_spc[19:16]);
      7'd62: ch = hexc(r_spc[15:12]);
      7'd63: ch = hexc(r_spc[11:8]);
      7'd64: ch = hexc(r_spc[7:4]);
      7'd65: ch = hexc(r_spc[3:0]);
      7'd66: ch = " ";
      7'd67: ch = "L";
      7'd68: ch = "=";
      7'd69: ch = hexc(r_plen[15:12]);
      7'd70: ch = hexc(r_plen[11:8]);
      7'd71: ch = hexc(r_plen[7:4]);
      7'd72: ch = hexc(r_plen[3:0]);
      7'd73: ch = " ";
      7'd74: ch = "T";
      7'd75: ch = "=";
      7'd76: ch = hexc(r_late[15:12]);
      7'd77: ch = hexc(r_late[11:8]);
      7'd78: ch = hexc(r_late[7:4]);
      7'd79: ch = hexc(r_late[3:0]);
      7'd80: ch = " ";
      7'd81: ch = "W";
      7'd82: ch = "=";
      7'd83: ch = hexc(r_wband[15:12]);
      7'd84: ch = hexc(r_wband[11:8]);
      7'd85: ch = hexc(r_wband[7:4]);
      7'd86: ch = hexc(r_wband[3:0]);
      7'd87: ch = " ";
      7'd88: ch = "D";
      7'd89: ch = "=";
      7'd90: ch = hexc(r_drop[15:12]);
      7'd91: ch = hexc(r_drop[11:8]);
      7'd92: ch = hexc(r_drop[7:4]);
      7'd93: ch = hexc(r_drop[3:0]);
      7'd94: ch = " ";
      7'd95: ch = "H";
      7'd96: ch = "=";
      7'd97: ch = hexc(r_short[15:12]);
      7'd98: ch = hexc(r_short[11:8]);
      7'd99: ch = hexc(r_short[7:4]);
      7'd100: ch = hexc(r_short[3:0]);
      7'd101: ch = " ";
      7'd102: ch = "K";
      7'd103: ch = "=";
      7'd104: ch = hexc(r_vx1[15:12]);
      7'd105: ch = hexc(r_vx1[11:8]);
      7'd106: ch = hexc(r_vx1[7:4]);
      7'd107: ch = hexc(r_vx1[3:0]);
      7'd108: ch = 8'h0d;
      default: ch = 8'h0a;
    endcase
  end

  assign wr = busy && !full;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; ci <= '0;
    end else begin
      if (report_go) begin
        busy <= 1'b1; ci <= '0;
      end else if (busy && !full) begin
        // SEVEN BITS HERE TOO. Widening the declaration and the case items was
        // not enough: 6'(NCH-1) truncated 67 to 3, so every line ended after
        // "F=00" and restarted. On the wire that looks like UART corruption,
        // not an arithmetic width - which is exactly what the comment beside
        // NCH warned about, written while making this same mistake.
        if (ci == 7'(NCH - 1)) busy <= 1'b0;
        else                   ci <= ci + 7'd1;
      end
    end
  end

  m1_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .DEPTH(64)) u_tx (
    .clk(clk), .rst_n(rst_n),
    .wr(wr), .din(ch), .full(full), .overflow(tx_overflow),
    .tx(tx)
  );

endmodule
