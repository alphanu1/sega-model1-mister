// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The quad store's vertex payload, in DDR3.
//
// WHY DDR3 AND NOT THE SDRAM
//
// The payload is 112 of the device's 553 M10K and has to go somewhere. The
// SDRAM was the obvious home and is the wrong one, measured:
//
//   - it is 16 bits wide, so a 128-bit payload is TWO burst reads and EIGHT
//     single-word writes - the write port takes one 16-bit word per request
//   - that is ~71,000 transactions a pass, about +15% controller occupancy
//   - and it is already the contended bus: 40% peak occupancy with the tile
//     character port waiting 26% of the time and overrunning (M=7,417 misses
//     in a 90-second capture). Paying for M10K with tile fetches trades one
//     overrun for another.
//
// DDR3 is 64 bits wide, so the same payload is ONE transaction each way at
// BURSTCNT=2, and `Model1.sv` tied the whole interface to zero - nothing in
// this core has ever used it.
//
// LATENCY IS THE RISK, AND PREFETCH IS WHY IT IS SURVIVABLE
//
// The HPS arbitrates this bus against Linux, so a read can be slow and the
// worst case is not ours to choose. What makes that affordable is that
// emissions are FILL-paced, not scan-paced: measured on a real race, one every
// ~1.87 us (~107 cycles of clk_3d) because the span fill, not the list walk,
// sets the rate. The scan can run ahead of that.
//
// So reads are issued from the SCAN and consumed by the OUTPUT, with a FIFO
// between. The scan fills the FIFO and stalls; every read then completes
// during a fill the core was doing anyway. Latency is hidden entirely while it
// stays under DEPTH x 107 cycles - about 1,700 at DEPTH=16.
//
// Serial waiting would NOT work and the numbers say so: 22,700 emissions a
// pass at even 60 cycles of latency is 1.36 M cycles against a pass of about
// 1.2 M. Prefetch is not an optimisation here, it is the thing that makes it
// possible at all.
//
// RETURNS ARE IN ORDER. One master, one outstanding stream, so the reply FIFO
// needs no tags - the Nth DOUT_READY pair belongs to the Nth request.

`timescale 1ns/1ps

module m1_ddram_payload #(
  parameter int unsigned IW    = 12,          // quad index width
  parameter int unsigned DEPTH = 16,          // outstanding reads in flight
  // 64-bit word address of the payload region. Two words per quad, two banks.
  parameter logic [28:0] BASE  = 29'h100_0000
) (
  input  logic          clk,                  // drives DDRAM_CLK
  input  logic          rst_n,

  // Which bank (producer/consumer) a request belongs to.
  input  logic          wr_req,
  input  logic          wr_bank,
  input  logic [IW-1:0] wr_idx,
  input  logic [127:0]  wr_data,
  output logic          wr_ready,             // may accept a write this cycle

  input  logic          rd_req,
  input  logic          rd_bank,
  input  logic [IW-1:0] rd_idx,
  output logic          rd_ready,             // may accept a read this cycle
  output logic          rd_valid,             // a payload is presented
  input  logic          rd_take,              // consumer took it
  output logic [127:0]  rd_data,

  // MiSTer DDR3, per sys/emu_ports.vh.
  output logic          DDRAM_CLK,
  input  logic          DDRAM_BUSY,
  output logic [7:0]    DDRAM_BURSTCNT,
  output logic [28:0]   DDRAM_ADDR,
  input  logic [63:0]   DDRAM_DOUT,
  input  logic          DDRAM_DOUT_READY,
  output logic          DDRAM_RD,
  output logic [63:0]   DDRAM_DIN,
  output logic [7:0]    DDRAM_BE,
  output logic          DDRAM_WE
);

  assign DDRAM_CLK = clk;
  assign DDRAM_BE  = 8'hff;

  // Two 64-bit words per quad; bank selects the half of the region.
  function automatic logic [28:0] pay_addr(input logic bank, input logic [IW-1:0] i);
    pay_addr = BASE + {27'd0, bank, 1'b0} * 29'(1 << IW) + {16'd0, i, 1'b0};
  endfunction

  // ---------------------------------------------------------------- reply FIFO
  localparam int unsigned DW = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  logic [127:0]  fifo [DEPTH];
  logic [DW:0]   wptr, rptr;
  wire  [DW:0]   fill  = wptr - rptr;
  wire           full  = (fill == (DW+1)'(DEPTH));
  wire           empty = (fill == '0);

  // Reads still owed a reply. The FIFO must have room for every one of them or
  // a late burst would overwrite a payload the fill had not taken yet.
  //
  // IT IS COUNTED WITH ONE ASSIGNMENT, not an increment in the issue branch
  // and a decrement in the reply branch. Those two can happen in the SAME
  // cycle - a read going out as an earlier one's second beat comes back - and
  // written as two assignments the later one wins, so the increment is lost,
  // `owed` undercounts, rd_ready keeps granting, and the FIFO wraps over
  // payloads the fill has not taken. Caught by tb_m1_ddram_payload's latency
  // sweep: 20 reads issued against a depth of 16, and only at the latencies
  // where the two events happened to coincide.
  logic [DW:0]   owed;
  logic          owed_inc, owed_dec;   // blocking flags within the block below

  assign rd_ready = !DDRAM_BUSY && !wr_pending &&
                    ((fill + owed) < (DW+1)'(DEPTH));
  // !wr_pending MATTERS. A write is two beats and the second is still owed
  // while wr_pending is set; accepting a new one before it goes clobbers
  // wr_hi, and the first payload loses its high half. It only shows when BUSY
  // stretches the gap between the beats, which is exactly what an
  // HPS-arbitrated bus does - tb_m1_ddram_payload's random-BUSY test caught it
  // and the steady-latency sweep never would have.
  assign wr_ready = !DDRAM_BUSY && !rd_issue && !wr_pending;

  logic          wr_pending;                  // second beat of a write burst
  logic          rd_issue;
  logic [63:0]   wr_hi;

  // A burst reply arrives as two DOUT_READY beats; the first is the low half.
  logic          beat_hi;
  logic [63:0]   beat_lo;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0; DDRAM_ADDR <= '0;
      DDRAM_DIN <= '0;  DDRAM_BURSTCNT <= 8'd1;
      wptr <= '0; rptr <= '0; owed <= '0;
      owed_inc <= 1'b0; owed_dec <= 1'b0;
      wr_pending <= 1'b0; rd_issue <= 1'b0; beat_hi <= 1'b0;
      beat_lo <= '0; wr_hi <= '0;
    end else begin
      rd_issue <= 1'b0;
      owed_inc = 1'b0;
      owed_dec = 1'b0;

      // The bus accepts a command when it is not busy; hold otherwise.
      if (!DDRAM_BUSY) begin
        DDRAM_RD <= 1'b0;
        DDRAM_WE <= 1'b0;

        if (wr_pending) begin
          // Second beat of the write burst.
          DDRAM_DIN  <= wr_hi;
          DDRAM_WE   <= 1'b1;
          wr_pending <= 1'b0;
        end
        else if (wr_req && wr_ready) begin
          DDRAM_ADDR     <= pay_addr(wr_bank, wr_idx);
          DDRAM_BURSTCNT <= 8'd2;
          DDRAM_DIN      <= wr_data[63:0];
          wr_hi          <= wr_data[127:64];
          DDRAM_WE       <= 1'b1;
          wr_pending     <= 1'b1;
        end
        else if (rd_req && rd_ready) begin
          DDRAM_ADDR     <= pay_addr(rd_bank, rd_idx);
          DDRAM_BURSTCNT <= 8'd2;
          DDRAM_RD       <= 1'b1;
          rd_issue       <= 1'b1;
          owed_inc        = 1'b1;
        end
      end

      // Replies, in order, two beats each.
      if (DDRAM_DOUT_READY) begin
        if (!beat_hi) begin
          beat_lo <= DDRAM_DOUT;
          beat_hi <= 1'b1;
        end else begin
          fifo[wptr[DW-1:0]] <= {DDRAM_DOUT, beat_lo};
          wptr    <= wptr + 1'b1;
          beat_hi <= 1'b0;
          owed_dec = 1'b1;
        end
      end

      // One assignment, both events accounted.
      owed <= owed + (DW+1)'(owed_inc) - (DW+1)'(owed_dec);

      if (rd_valid && rd_take) rptr <= rptr + 1'b1;
    end
  end

  assign rd_valid = !empty;
  assign rd_data  = fifo[rptr[DW-1:0]];

endmodule
