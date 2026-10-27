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
// The quad store's vertex payload, in DDR3.
//
// WHY DDR3 AND NOT THE SDRAM
//
// The payload is 4 x 32 bits a quad, 3,072 quads a bank, two banks: about 96
// of the device's 553 M10K. The SDRAM was the obvious home and is the wrong
// one, measured:
//
//   - it is 16 bits wide, so a 128-bit payload is TWO burst reads and EIGHT
//     single-word writes - the write port takes one 16-bit word per request
//   - that is ~71,000 transactions a pass, about +15% controller occupancy
//   - and it is already the contended bus: 40% peak occupancy with the tile
//     character port waiting 26% of the time and overrunning. Paying for M10K
//     with tile fetches trades one overrun for another.
//
// DDR3 is 64 bits wide, so the same payload is ONE transaction each way at
// BURSTCNT=2, and nothing else in this core uses it.
//
// LATENCY IS THE RISK, AND PREFETCH IS WHY IT IS SURVIVABLE
//
// The HPS arbitrates this bus against Linux and the scaler, so a read can be
// slow and the worst case is not ours to choose. What makes that affordable is
// that emissions are FILL-paced, not scan-paced: measured on a real race, one
// every ~1.87 us because the span fill, not the list walk, sets the rate. The
// store's scan runs ahead of that, so reads are issued from the SCAN and
// consumed by the OUTPUT with this module's reply FIFO between them. Latency
// is hidden entirely while it stays under about DEPTH x the fill's pace.
//
// WHAT THE MODEL 2 CORE PAID TO LEARN, applied here rather than re-learned
// (sega-model2-mister, docs/model2a-design-study.md):
//
//   R345  RD/WE are HELD until BUSY is low, with ADDR and BURSTCNT latched for
//         the whole burst. The framework's screen_rotate does not check BUSY
//         and is not a model to copy.
//   R346  DDRAM_ADDR counts 64-bit WORDS. BASE is a word address.
//   R377  The master runs on the clock of its consumers - DDRAM_CLK is ours to
//         choose - so no request or reply crosses a clock domain.
//   R654  0x30000000 is the cores' own region; the scaler sits at 0x20000000.
//   R649  A burst cut short by a reset wedges the HPS bridge until the FPGA is
//         reconfigured, and a core reset does not clear it. So this module is
//         reset ONLY with the memory (PLL lock), and the game reset arrives as
//         `flush`: it discards what is queued, but a burst already started is
//         always finished and replies already owed are always drained.
//   R660  A command is never re-taken in the cycle it is accepted, and no beat
//         goes out with BE = 0.
//
// WRITES ARE POSTED. The store accepts a quad in one cycle and has no way to
// stall the geometry, so the write side is a queue the geometry cannot overrun
// in practice - 256 quads, in four M10K - and an overrun, which would lose a
// payload, is COUNTED rather than silent (`dbg_wr_ovf`). `wr_idle` says every
// posted write has been accepted by the bus; the raster3d producer waits for it
// before its bank is handed to the reader.
//
// RETURNS ARE IN ORDER. One master, one stream, so the reply FIFO needs no
// tags - the Nth burst reply belongs to the Nth read.

`timescale 1ns/1ps

module m1_ddram_payload #(
  parameter int unsigned IW    = 12,          // quad index width
  parameter int unsigned DEPTH = 16,          // reads accepted and not yet taken
  parameter int unsigned WDEP  = 256,         // posted writes held
  // 64-bit word address of the payload region: byte 0x30000000. Two words a
  // quad, two banks.
  parameter logic [28:0] BASE  = 29'h0600_0000
) (
  input  logic          clk,                  // drives DDRAM_CLK
  input  logic          rst_n,                // MEMORY reset only - see R649
  input  logic          flush,                // game reset: drop what is queued

  // Posted writes: one quad's payload, accepted unconditionally.
  input  logic          wr_req,
  input  logic          wr_bank,
  input  logic [IW-1:0] wr_idx,
  input  logic [127:0]  wr_data,
  output logic          wr_idle,              // nothing queued, no burst open

  // Prefetched reads. `rd_ready` is a function of REGISTERED counts only, never
  // of DDRAM_BUSY, so the store's scan carries no path from the HPS.
  input  logic          rd_req,
  input  logic          rd_bank,
  input  logic [IW-1:0] rd_idx,
  output logic          rd_ready,
  output logic          rd_valid,             // a payload is presented
  input  logic          rd_take,              // consumer took it
  output logic [127:0]  rd_data,

  output logic [15:0]   dbg_wr_ovf,           // posted writes LOST, free-running
  output logic [15:0]   dbg_rd_refused,       // reads asked for with no credit: zero by contract
  // The longest the bus has kept us waiting for a reply with a read owed, in
  // clk cycles - an upper bound on the read round trip. Sticky.
  output logic [15:0]   dbg_rd_wait,

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

  // Two 64-bit words per quad; the bank selects the half of the region.
  function automatic logic [28:0] pay_addr(input logic bank, input logic [IW-1:0] i);
    pay_addr = BASE + 29'({bank, i, 1'b0});
  endfunction

  // ================================================================ writes
  // Block RAM with a registered read, presented show-ahead: the read address is
  // the pointer the head will have AFTER this edge, so `wq_q` always holds the
  // current head. An entry becomes visible a cycle after its write (wq_wp_d),
  // so a read never meets a write to the same word on the same edge.
  localparam int unsigned WW   = $clog2(WDEP);
  localparam int unsigned WE_W = 1 + IW + 128;
  (* ramstyle = "M10K" *) logic [WE_W-1:0] wq [WDEP];
  logic [WW:0]     wq_wp, wq_wp_d, wq_rp;
  logic [WE_W-1:0] wq_q;
  wire             wq_avail = (wq_wp_d != wq_rp);
  wire  [WW:0]     wq_fill  = wq_wp - wq_rp;
  wire             wq_full  = (wq_fill == (WW+1)'(WDEP));
  wire             wq_push  = wr_req && !wq_full && !flush;

  // ================================================================ read queue
  // Requests waiting for the bus, as deep as the credit: every read accepted
  // may be waiting here while the bus is busy. A shallower queue put a second
  // limit on rd_ready, and the store - which asks a cycle after it sampled
  // rd_ready, from a register - then presented a request the client refused.
  // The colour for it was already queued, so the output waited for a payload
  // that was never asked for and the 3D froze. render3d found it under a busy
  // bus; a bench that requests in the same cycle it samples ready cannot.
  //
  // So rd_ready depends on the credit alone, and the store's own limit - its
  // colour FIFO is DEPTH deep and counts the same reads a cycle EARLIER on
  // both ends - guarantees a request never arrives with the credit exhausted.
  // That guarantee is checked: dbg_rd_refused counts any that did.
  localparam int unsigned DW = $clog2(DEPTH);
  (* ramstyle = "MLAB" *) logic [IW:0] rq [DEPTH];   // {bank, idx}
  logic [DW:0]   rq_wp, rq_wp_d, rq_rp;
  logic [IW:0]   rq_q;
  wire           rq_avail = (rq_wp_d != rq_rp);

  // Everything accepted and not yet taken: queued, owed by the bus, or sitting
  // in the reply FIFO. One registered counter, so the reply FIFO cannot
  // overflow and rd_ready is a compare.
  logic [DW:0]   credit;
  assign rd_ready = (credit < (DW+1)'(DEPTH)) && !flush;
  wire   rd_acc   = rd_req && rd_ready;

  // ================================================================ replies
  (* ramstyle = "M10K" *) logic [127:0] fq [DEPTH];
  logic [DW:0]   fq_wp, fq_wp_d, fq_rp;
  logic [127:0]  fq_q;
  logic          beat_hi;                     // the next beat is a burst's high half
  logic [63:0]   beat_lo;
  logic [DW:0]   owed;                        // read bursts presented, not fully returned
  logic [DW:0]   drop;                        // of those, replies to discard (flush)
  wire           burst_done = DDRAM_DOUT_READY && beat_hi;
  wire           fq_push = burst_done && (drop == '0) && !flush;
  wire           fq_pop  = rd_valid && rd_take;
  wire  [DW:0]   fq_rp_nx = fq_rp + (DW+1)'(fq_pop);
  assign rd_valid = (fq_wp_d != fq_rp);
  assign rd_data  = fq_q;

  // ================================================================ the bus
  logic          wr_open;                     // a write burst's second beat is owed
  logic [63:0]   wr_hi;

  // What goes out at this edge, if the bus takes commands. Reads first: they
  // are what the fill is waiting for, and a write sits in a 256-deep queue.
  // A burst already open is finished before anything else (R649).
  wire bus_free  = !DDRAM_BUSY;
  wire can_issue = bus_free && !wr_open && !flush;
  wire do_rd     = can_issue && rq_avail;
  wire do_wr     = can_issue && !do_rd && wq_avail;
  wire [WW:0] wq_rp_nx = wq_rp + (WW+1)'(do_wr);
  wire [DW:0] rq_rp_nx = rq_rp + (DW+1)'(do_rd);

  assign wr_idle = (wq_fill == '0) && !wr_open && !DDRAM_WE;

  always_ff @(posedge clk) begin
    if (wq_push) wq[wq_wp[WW-1:0]] <= {wr_bank, wr_idx, wr_data};
    wq_q <= wq[wq_rp_nx[WW-1:0]];
    if (rd_acc) rq[rq_wp[DW-1:0]] <= {rd_bank, rd_idx};
    rq_q <= rq[rq_rp_nx[DW-1:0]];
    if (fq_push) fq[fq_wp[DW-1:0]] <= {DDRAM_DOUT, beat_lo};
    fq_q <= fq[fq_rp_nx[DW-1:0]];
  end

  logic [15:0] wait_t;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0; DDRAM_ADDR <= '0;
      DDRAM_DIN <= '0;  DDRAM_BURSTCNT <= 8'd2;
      wq_wp <= '0; wq_wp_d <= '0; wq_rp <= '0;
      rq_wp <= '0; rq_wp_d <= '0; rq_rp <= '0; credit <= '0; dbg_rd_refused <= '0;
      fq_wp <= '0; fq_wp_d <= '0; fq_rp <= '0;
      owed <= '0; drop <= '0; beat_hi <= 1'b0; beat_lo <= '0;
      wr_open <= 1'b0; wr_hi <= '0;
      dbg_wr_ovf <= '0; dbg_rd_wait <= '0; wait_t <= '0;
    end else begin
      // ---- posted-write queue. A flush drops everything not yet on the bus;
      // do_wr is low under flush, so nothing is being taken from it this edge.
      if (wr_req && wq_full && !flush) dbg_wr_ovf <= dbg_wr_ovf + 16'd1;
      if (flush)        wq_wp <= wq_rp;
      else if (wq_push) wq_wp <= wq_wp + 1'b1;
      wq_wp_d <= flush ? wq_rp : wq_wp;
      if (do_wr) wq_rp <= wq_rp + 1'b1;

      // ---- read queue
      if (flush) begin
        rq_wp <= rq_rp; rq_wp_d <= rq_rp;
      end else begin
        if (rd_acc) rq_wp <= rq_wp + 1'b1;
        rq_wp_d <= rq_wp;
        if (do_rd) rq_rp <= rq_rp + 1'b1;
      end
      if (rd_req && !rd_ready && !flush) dbg_rd_refused <= dbg_rd_refused + 16'd1;

      // ---- credit: accepted minus taken. A flush forgets every one; the
      // replies still owed are discarded below and never reach the FIFO.
      if (flush) credit <= '0;
      else       credit <= credit + (DW+1)'(rd_acc) - (DW+1)'(fq_pop);

      // ---- the command register, held while BUSY: a command is taken at an
      // edge where it is presented and BUSY is low.
      if (bus_free) begin
        DDRAM_RD <= 1'b0;
        DDRAM_WE <= 1'b0;
        if (wr_open) begin
          DDRAM_DIN <= wr_hi;
          DDRAM_WE  <= 1'b1;
          wr_open   <= 1'b0;
        end else if (do_rd) begin
          DDRAM_ADDR     <= pay_addr(rq_q[IW], rq_q[IW-1:0]);
          DDRAM_BURSTCNT <= 8'd2;
          DDRAM_RD       <= 1'b1;
        end else if (do_wr) begin
          DDRAM_ADDR     <= pay_addr(wq_q[WE_W-1], wq_q[WE_W-2 -: IW]);
          DDRAM_BURSTCNT <= 8'd2;
          DDRAM_DIN      <= wq_q[63:0];
          wr_hi          <= wq_q[127:64];
          DDRAM_WE       <= 1'b1;
          wr_open        <= 1'b1;
        end
      end

      // ---- replies, two beats each, in order
      if (DDRAM_DOUT_READY) begin
        beat_hi <= !beat_hi;
        if (!beat_hi) beat_lo <= DDRAM_DOUT;
      end
      // owed counts read bursts from the edge they are presented until their
      // second beat returns; a flush turns every one still owed into a drop.
      owed <= owed + (DW+1)'(do_rd) - (DW+1)'(burst_done);
      if (flush)                          drop <= owed - (DW+1)'(burst_done);
      else if (burst_done && drop != '0)  drop <= drop - 1'b1;

      if (flush) begin
        fq_wp <= fq_rp; fq_wp_d <= fq_rp;
      end else begin
        if (fq_push) fq_wp <= fq_wp + 1'b1;
        fq_wp_d <= fq_wp;
        if (fq_pop) fq_rp <= fq_rp + 1'b1;
      end

      // ---- the longest wait for a reply with a read owed
      if (owed == '0 || DDRAM_DOUT_READY) wait_t <= '0;
      else if (wait_t != 16'hffff)        wait_t <= wait_t + 16'd1;
      if (wait_t > dbg_rd_wait) dbg_rd_wait <= wait_t;
    end
  end

endmodule
