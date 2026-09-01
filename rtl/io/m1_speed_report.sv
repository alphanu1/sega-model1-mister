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
  input  logic [15:0] bands,    // 3D bands presented, free-running
  input  logic [15:0] passes,   // 3D geometry passes, free-running

  output logic tx
);

  // ------------------------------------------------------------- counters
  logic [15:0] n_frame, n_swap;
  logic [15:0] period_cnt;
  logic        sel_d;
  logic [15:0] r_frame, r_swap, r_bands, r_pass;
  logic        report_go;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      n_frame <= '0; n_swap <= '0; period_cnt <= '0; sel_d <= 1'b0;
      r_frame <= '0; r_swap <= '0; r_bands <= '0; r_pass <= '0;
      report_go <= 1'b0;
    end else begin
      report_go <= 1'b0;
      sel_d <= list_sel;
      if (list_sel != sel_d) n_swap <= n_swap + 16'd1;
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
          report_go <= 1'b1;
        end else period_cnt <= period_cnt + 16'd1;
      end
    end
  end

  // ------------------------------------------------------------- formatter
  // "F=xxxx S=xxxx B=xxxx P=xxxx\r\n" - 29 bytes.
  localparam int unsigned NCH = 29;

  logic [4:0]  ci;
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
      5'd0:  ch = "F";
      5'd1:  ch = "=";
      5'd2:  ch = hexc(vals[63:60]);
      5'd3:  ch = hexc(vals[59:56]);
      5'd4:  ch = hexc(vals[55:52]);
      5'd5:  ch = hexc(vals[51:48]);
      5'd6:  ch = " ";
      5'd7:  ch = "S";
      5'd8:  ch = "=";
      5'd9:  ch = hexc(vals[47:44]);
      5'd10: ch = hexc(vals[43:40]);
      5'd11: ch = hexc(vals[39:36]);
      5'd12: ch = hexc(vals[35:32]);
      5'd13: ch = " ";
      5'd14: ch = "B";
      5'd15: ch = "=";
      5'd16: ch = hexc(vals[31:28]);
      5'd17: ch = hexc(vals[27:24]);
      5'd18: ch = hexc(vals[23:20]);
      5'd19: ch = hexc(vals[19:16]);
      5'd20: ch = " ";
      5'd21: ch = "P";
      5'd22: ch = "=";
      5'd23: ch = hexc(vals[15:12]);
      5'd24: ch = hexc(vals[11:8]);
      5'd25: ch = hexc(vals[7:4]);
      5'd26: ch = hexc(vals[3:0]);
      5'd27: ch = 8'h0d;
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
        if (ci == 5'(NCH - 1)) busy <= 1'b0;
        else                   ci <= ci + 5'd1;
      end
    end
  end

  m1_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .DEPTH(64)) u_tx (
    .clk(clk), .rst_n(rst_n),
    .wr(wr), .din(ch), .full(full), .overflow(tx_overflow),
    .tx(tx)
  );

endmodule
