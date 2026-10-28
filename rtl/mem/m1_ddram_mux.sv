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
// TWO DDRAM MASTERS ON THE FRAMEWORK'S ONE DDRAM PORT.
//
// The 3D layer has two DDR3 users and the framework gives a core one port
// (the Model 2 study's R656: ram1 is the core's, ram2 the framework's own, and
// a third would need framework changes). They are different shapes, which is
// why this sits at the DDRAM level rather than in front of m2_ddr3:
//
//   A  the 3D frame buffer, through m2_ddr3: one transaction at a time, line
//      reads of 248 beats, write bursts of up to 16
//   B  the quad payload, m1_ddram_payload: PIPELINED two-beat reads, up to
//      sixteen in flight, and posted two-beat writes
//
// m2_ddr3's request/acknowledge port would serialise B to one read in flight,
// and B's prefetch exists to have several. So each master keeps its own Avalon
// port and this passes one through at a time.
//
// THE RULES, each one an Avalon obligation rather than a preference:
//
//   - A COMMAND ON THE BUS IS NOT TAKEN AWAY. While DDRAM_BUSY holds the
//     granted master's command, the grant stays; switching would change the
//     command under a BUSY, which the model counts as a protocol error and the
//     bridge is entitled to mis-take.
//   - A WRITE BURST IS NOT SPLIT. Its beats after the first carry no address;
//     another master's command between them would be taken as data.
//   - READ REPLIES COME BACK IN ORDER, so the owner of every read is queued as
//     it is accepted and each DDRAM_DOUT_READY beat goes to the queue's head.
//
// The master not granted sees BUSY, which is exactly what a busy bridge looks
// like to it - both masters already hold their commands through a BUSY.
//
// PRIORITY: alternate, so neither waits longer than one of the other's
// commands; and `hold_b` keeps B off while the scanout is fetching (the Model 2
// study's R655 - a line read must not queue behind a flood of other traffic).

`timescale 1ns/1ps

module m1_ddram_mux #(
  parameter int unsigned QD = 32          // read bursts in flight, both masters
) (
  input  logic        clk,
  input  logic        rst_n,              // the MEMORY reset: never mid-burst
  input  logic        hold_b,

  // ---- master A
  input  logic        a_rd, a_we,
  input  logic [28:0] a_addr,
  input  logic [7:0]  a_burstcnt,
  input  logic [63:0] a_din,
  input  logic [7:0]  a_be,
  output logic        a_busy,
  output logic        a_dout_ready,
  output logic [63:0] dout,               // both masters' read data

  // ---- master B
  input  logic        b_rd, b_we,
  // B has something to put on the bus. m1_ddram_payload raises a command only
  // after a cycle in which it saw !BUSY, so B is granted on `want` and keeps
  // the grant until it has presented one (or wants nothing): granting only on
  // a presented command deadlocks - it never presents one while refused.
  input  logic        b_want,
  input  logic [28:0] b_addr,
  input  logic [7:0]  b_burstcnt,
  input  logic [63:0] b_din,
  input  logic [7:0]  b_be,
  output logic        b_busy,
  output logic        b_dout_ready,

  // ---- the framework's port
  input  logic        DDRAM_BUSY,
  output logic [7:0]  DDRAM_BURSTCNT,
  output logic [28:0] DDRAM_ADDR,
  input  logic [63:0] DDRAM_DOUT,
  input  logic        DDRAM_DOUT_READY,
  output logic        DDRAM_RD,
  output logic [63:0] DDRAM_DIN,
  output logic [7:0]  DDRAM_BE,
  output logic        DDRAM_WE,

  output logic [15:0] dbg_q_max,          // most read bursts ever in flight
  output logic [15:0] dbg_q_ovf           // reads accepted with the queue full: zero
);

  logic g;                                // the granted master: 0 = A, 1 = B
  logic fresh;                            // B granted and has not yet presented
  logic [7:0] wleft;                      // beats of the open write burst still to go

  assign DDRAM_RD       = g ? b_rd       : a_rd;
  assign DDRAM_WE       = g ? b_we       : a_we;
  assign DDRAM_ADDR     = g ? b_addr     : a_addr;
  assign DDRAM_BURSTCNT = g ? b_burstcnt : a_burstcnt;
  assign DDRAM_DIN      = g ? b_din      : a_din;
  assign DDRAM_BE       = g ? b_be       : a_be;
  assign dout   = DDRAM_DOUT;
  assign a_busy = DDRAM_BUSY ||  g;
  assign b_busy = DDRAM_BUSY || !g;

  wire a_cmd = a_rd || a_we;
  wire b_cmd = b_rd || b_we;
  wire cmd   = DDRAM_RD || DDRAM_WE;
  wire take  = cmd && !DDRAM_BUSY;       // the granted master's command or beat is taken
  wire rd_take = DDRAM_RD && !DDRAM_BUSY;

  // ---- the owners of the reads in flight, in order
  localparam int unsigned QW = $clog2(QD);
  // Flip-flops, deliberately: the head is read in the cycle a push to an
  // empty queue lands, which a block RAM's registered read would answer with
  // the old word (and Quartus inferred one, two M10K, when this was unmarked).
  (* ramstyle = "logic" *) logic       q_own [QD];
  (* ramstyle = "logic" *) logic [7:0] q_len [QD];
  logic [QW:0] q_wp, q_rp;
  logic [7:0]  beat;                      // beats of the head burst already returned
  wire  [QW:0] q_fill = q_wp - q_rp;
  wire         head_own = q_own[q_rp[QW-1:0]];
  wire  [7:0]  head_len = q_len[q_rp[QW-1:0]];
  assign a_dout_ready = DDRAM_DOUT_READY && (q_fill != '0) && !head_own;
  assign b_dout_ready = DDRAM_DOUT_READY && (q_fill != '0) &&  head_own;
  wire         head_done = DDRAM_DOUT_READY && (q_fill != '0)
                        && ((beat + 8'd1 >= head_len) || (head_len == 8'd0));

  // After this cycle: is a write burst still open, and is a command still
  // waiting on BUSY? Either keeps the grant where it is.
  wire [7:0] wleft_nx = (DDRAM_WE && !DDRAM_BUSY)
                      ? ((wleft == 8'd0) ? ((DDRAM_BURSTCNT == 8'd0) ? 8'd0 : DDRAM_BURSTCNT - 8'd1)
                                         : wleft - 8'd1)
                      : wleft;
  wire       stuck    = cmd && DDRAM_BUSY;
  wire       free     = (wleft_nx == 8'd0) && !stuck;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      g <= 1'b0; fresh <= 1'b0; wleft <= 8'd0; q_wp <= '0; q_rp <= '0; beat <= 8'd0;
      dbg_q_max <= '0; dbg_q_ovf <= '0;
    end else begin
      wleft <= wleft_nx;
      if (g && (b_cmd || !b_want)) fresh <= 1'b0;
      if (free) begin
        // Alternate: whichever did not just hold the port goes next if it
        // has something to say. A taken command hands over; an idle owner
        // hands over to a waiting one.
        if (!g) begin
          if ((b_cmd || b_want) && !hold_b && (take || !a_cmd)) begin
            g <= 1'b1; fresh <= 1'b1;
          end
        end else if (!(fresh && b_want && !b_cmd)) begin
          if (a_cmd && (take || !b_cmd || hold_b)) begin g <= 1'b0; fresh <= 1'b0; end
        end
      end

      if (rd_take) begin
        q_own[q_wp[QW-1:0]] <= g;
        q_len[q_wp[QW-1:0]] <= DDRAM_BURSTCNT;
        q_wp <= q_wp + 1'b1;
        if (q_fill == (QW+1)'(QD) && !(&dbg_q_ovf)) dbg_q_ovf <= dbg_q_ovf + 16'd1;
      end
      if (16'(q_fill) > dbg_q_max) dbg_q_max <= 16'(q_fill);
      if (head_done) begin
        q_rp <= q_rp + 1'b1;
        beat <= 8'd0;
      end else if (DDRAM_DOUT_READY && (q_fill != '0)) beat <= beat + 8'd1;
    end
  end

endmodule
