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
// 8N1 UART transmitter — a printf channel out of the fabric.
//
// WHY THIS EXISTS
//
// The debug overlay is twenty-four 32-bit rows read off a photograph. It cannot
// show a SEQUENCE, and every question left on this core is about sequence: which
// routine wrote a register, what the CPU read just before it, what order events
// happened in. Four causes were named and withdrawn in one day partly because a
// still frame cannot answer that.
//
// The framework already exposes UART_TXD to the core — sys_top.v wires it to the
// HPS UART's RECEIVE line, so bytes sent here arrive on the Linux side and can be
// read with `cat /dev/ttyS0`. Model1.sv had it tied to 0 and nothing in the docs
// had considered it.
//
// TWO THINGS TO KNOW BEFORE USING IT
//
// 1. /proc/cmdline has `console=ttyS0,115200`, so that port is the Linux console
//    and an agetty sits on it. It will consume what the core sends. Stop it first:
//      ssh root@mister 'kill $(pgrep -f "agetty.*console"); cat /dev/ttyS0'
// 2. 115200 baud is ~11.5 KB/s, about 190 bytes per frame at 57.5 Hz. That is
//    plenty for targeted events and nowhere near enough for a bus trace. The FIFO
//    drops on overflow rather than stalling the design, and reports it, because a
//    debug channel that can halt the thing it is debugging is worse than useless.

`timescale 1ns/1ps

module m1_uart_tx #(
  parameter int unsigned CLK_HZ = 80_000_000,
  parameter int unsigned BAUD   = 115_200,
  parameter int unsigned DEPTH  = 256
) (
  input  logic       clk,
  input  logic       rst_n,

  input  logic       wr,          // strobe: push din
  input  logic [7:0] din,
  output logic       full,
  output logic       overflow,    // sticky: a byte was dropped

  output logic       tx
);

  // 80 MHz / 115200 = 694.44, so 694 gives 115,274 baud — 0.06% fast, well inside
  // the ~2% a receiver tolerates over ten bit times.
  localparam int unsigned DIV = CLK_HZ / BAUD;
  localparam int unsigned AW  = $clog2(DEPTH);

  logic [7:0]   fifo [DEPTH];
  logic [AW:0]  wptr, rptr;
  wire          empty = (wptr == rptr);
  assign        full  = (wptr[AW-1:0] == rptr[AW-1:0]) && (wptr[AW] != rptr[AW]);

  logic [$clog2(DIV)-1:0] divcnt;
  logic [3:0]             bitno;   // 0 start, 1-8 data, 9 stop
  logic [7:0]             shifter;
  logic                   busy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr <= '0; rptr <= '0; overflow <= 1'b0;
      divcnt <= '0; bitno <= '0; shifter <= '0; busy <= 1'b0;
      tx <= 1'b1;                  // idle high
    end else begin
      if (wr) begin
        if (full) overflow <= 1'b1;
        else begin
          fifo[wptr[AW-1:0]] <= din;
          wptr <= wptr + 1'b1;
        end
      end

      if (!busy) begin
        tx <= 1'b1;
        if (!empty) begin
          shifter <= fifo[rptr[AW-1:0]];
          rptr    <= rptr + 1'b1;
          busy    <= 1'b1;
          bitno   <= '0;
          divcnt  <= '0;
          tx      <= 1'b0;         // start bit begins immediately
        end
      end else if (divcnt == DIV[$clog2(DIV)-1:0] - 1) begin
        divcnt <= '0;
        if (bitno == 4'd9) begin
          busy <= 1'b0;            // stop bit done; tx already high
        end else begin
          bitno <= bitno + 4'd1;
          // Bits 1-8 are data LSB first; bit 9 is the stop bit.
          tx      <= (bitno == 4'd8) ? 1'b1 : shifter[0];
          shifter <= {1'b0, shifter[7:1]};
        end
      end else begin
        divcnt <= divcnt + 1'b1;
      end
    end
  end

endmodule
