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
// Clock-domain bridge for one m1_sdram port.
//
// WHY THE CORE HAS TWO CLOCKS AT ALL
//
// The V60 closes at 24.62 MHz and the tilemap fetch engine needs about 700
// cycles per layer per scanline on repeated tiles, 1,614 on distinct ones. A
// scanline is 656 pixel clocks at the 16 MHz dot clock, 41 us, so four layers
// want 2,796-6,456 core cycles — 68 MHz at the very least and closer to 100 for
// the video side. A clock enable does not help: `ce` decides when the CPU
// advances, but every path still has to meet setup at the actual clock.
//
// So the CPU sits in a slow domain and memory, ROM loading and video in a fast
// one, and this is what carries a memory port between them. The V60 can afford
// it: measured, 64-cycle memory latency costs it 1.8% (docs/m1-m4-plan.md,
// "V60 fetch"), and this bridge adds far less than that.
//
// THE TWO HANDSHAKES IT HAS TO SATISFY, WHICH ARE NOT THE SAME
//
//  * m1_sdram takes **one transaction per req RISING EDGE** and samples address,
//    write data and byte enables on that edge. A level held high is serviced
//    once, so the fast side must be given a clean edge, not a stretched level.
//
//  * m1_main pulses its request for a single cycle and latches read data on the
//    **ack rising edge**. So the slow side must be given an edge too, with data
//    already stable when it arrives.
//
// A level-crossing synchroniser satisfies neither. This is a two-phase toggle
// handshake: a toggle per request crossing one way, a toggle per completion
// crossing back, each edge-detected in its destination domain to make exactly
// one pulse.
//
// There is deliberately no guard against a completion toggle arriving with
// nothing outstanding. It cannot do harm — the slow side edge-detects the
// toggle *and* gates on a_busy, so a stray edge while idle is discarded and the
// next real completion is still just an edge. A guard was written, and mutation
// testing showed removing it changed nothing any test could observe, which by
// hard rule 5 makes it unverified code rather than defence in depth.
//
// Address, write data and byte enables cross without synchronisers on purpose.
// They are captured in a register that cannot change while a transaction is
// outstanding, and the destination only samples them two or more clocks after
// the toggle that announced them, by which point they have been stable for
// longer than any metastability window. Synchronising a 24-bit bus bit by bit
// would be actively wrong — the bits would arrive skewed.
module m1_cdc_port #(
  // POSTED WRITES. With this on, a WRITE raises a_ack the cycle it is accepted
  // rather than when the far side completes it, so the CPU stops waiting for a
  // result a store does not have. The transaction stays in flight -- a_busy is
  // held until the real completion -- so a following access still waits and
  // ordering is preserved exactly. No buffer, no reordering.
  //
  // Measured reason: a data access costs 6.1 clk_cpu cycles of which the
  // crossing is 74% and the RETURN path alone is 45%, and the V60 spends 91%
  // of its cycles in S_WB_MEM, which is that return. The data port is
  // 157,770 writes to 48 reads.
  //
  // Off by default: a requester that needs write completion before it proceeds
  // must not have this. The V60's store does not -- S_WB_MEM's only use of
  // dack is to leave the state.
  parameter bit POST_WRITES = 1'b0,

  parameter int AW  = 24,
  parameter int DW  = 16,
  parameter int BEW = 2
) (
  // ---------------------------------------------------- requester, slow domain
  input  logic           a_clk,
  input  logic           a_rst_n,
  input  logic           a_req,     // pulse OR level; a level is re-accepted only after a gap cycle
  input  logic           a_we,
  input  logic [AW-1:0]  a_addr,
  input  logic [DW-1:0]  a_din,
  input  logic [BEW-1:0] a_be,
  output logic [DW-1:0]  a_dout,
  output logic           a_ack,     // one-cycle pulse, data valid with it
  output logic           a_busy,

  // ------------------------------------------------------- memory, fast domain
  input  logic           b_clk,
  input  logic           b_rst_n,
  output logic           b_req,     // one-cycle pulse: the rising edge is the request
  output logic           b_we,
  output logic [AW-1:0]  b_addr,
  output logic [DW-1:0]  b_din,
  output logic [BEW-1:0] b_be,
  input  logic [DW-1:0]  b_dout,
  input  logic           b_ack
);

  // Payload registers. Written in the A domain when a request is accepted, read
  // in the B domain after the toggle has crossed. Not synchronised, by design —
  // see the header.
  logic [AW-1:0]  x_addr;
  logic [DW-1:0]  x_din;
  logic [BEW-1:0] x_be;
  logic           x_we;
  logic [DW-1:0]  x_dout;

  logic req_tog;   // A -> B, one edge per request
  logic ack_tog;   // B -> A, one edge per completion

  // ------------------------------------------------------------- slow domain
  logic ack_s1, ack_s2, ack_s3;
  logic a_req_d;
  logic post_w;      // the in-flight transaction was acked on acceptance

  always_ff @(posedge a_clk or negedge a_rst_n) begin
    if (!a_rst_n) begin
      req_tog <= 1'b0;
      a_busy  <= 1'b0;
      a_ack   <= 1'b0;
      a_dout  <= '0;
      x_addr  <= '0;
      x_din   <= '0;
      x_be    <= '0;
      x_we    <= 1'b0;
      {ack_s3, ack_s2, ack_s1} <= 3'b000;
      a_req_d <= 1'b0;
      post_w  <= 1'b0;
    end else begin
      {ack_s3, ack_s2, ack_s1} <= {ack_s2, ack_s1, ack_tog};
      a_req_d <= a_req;
      a_ack <= 1'b0;

      // A request while one is outstanding is dropped rather than queued. The
      // V60 bus cannot produce one — it waits for its ack — and silently
      // accepting a second would corrupt the payload of the first.
      // NOT ON THE CYCLE AFTER AN ACK. a_busy clears on the same edge that
      // raises the one-cycle a_ack, so on the next edge `a_req && !a_busy` was
      // true again for a requester that holds a_req as a LEVEL - and its
      // address on that cycle is still the OLD one, because it only learns of
      // the ack during that cycle and moves on at its end. The port then ran a
      // duplicate transaction at the old address, ignored the requester's real
      // next request while busy, and delivered the duplicate's ack - with the
      // old data - as if it were the new read's.
      //
      // Measured 2026-08-30 on the coprocessor's sincos unit, microcode
      // 0370/0371 - two back-to-back io reads with no gap: the second returned
      // the first's word (table entry 0x131 for a read whose index was 0x3ecf),
      // 249 events into an otherwise identical stream. The V60's bus FSM drops
      // its request on the ack cycle and idles before the next, which is why
      // that path never showed it; the TGP core presents its next read at once.
      // `a_ack` is registered and high for exactly that one cycle; the
      // requester's new address is on the bus by the cycle after.
      // ...but a fresh PULSE that lands on the ack cycle must still be taken,
      // or it is lost and the requester hangs - tb_m1_cdc_port's requester does
      // exactly that and completed 1 of 20,000 with a bare `!a_ack` guard. What
      // distinguishes the stale level is that a_req was ALREADY high on the ack
      // cycle: a_req_d carries that.
      if (a_req && !a_busy && !(a_ack && a_req_d)) begin
        x_addr  <= a_addr;
        x_din   <= a_din;
        x_be    <= a_be;
        x_we    <= a_we;
        req_tog <= ~req_tog;
        a_busy  <= 1'b1;
        // A store has no result, so the requester can go now. a_busy stays set,
        // so the NEXT access still waits for this one to land.
        post_w  <= POST_WRITES & a_we;
        if (POST_WRITES & a_we) a_ack <= 1'b1;
      end

      if (a_busy && (ack_s2 ^ ack_s3)) begin
        a_dout <= x_dout;
        // Already acknowledged on acceptance if this was a posted write;
        // raising a_ack twice for one request would look like two completions.
        a_ack  <= ~post_w;
        a_busy <= 1'b0;
        post_w <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------- fast domain
  logic req_s1, req_s2, req_s3;
  logic b_ack_d;

  always_ff @(posedge b_clk or negedge b_rst_n) begin
    if (!b_rst_n) begin
      ack_tog   <= 1'b0;
      b_req     <= 1'b0;
      b_we      <= 1'b0;
      b_addr    <= '0;
      b_din     <= '0;
      b_be      <= '0;
      b_ack_d   <= 1'b0;
      x_dout    <= '0;
      {req_s3, req_s2, req_s1} <= 3'b000;
    end else begin
      {req_s3, req_s2, req_s1} <= {req_s2, req_s1, req_tog};
      b_ack_d <= b_ack;
      b_req   <= 1'b0;

      if (req_s2 ^ req_s3) begin
        // Address and data are presented in the same cycle as the pulse, so
        // they are stable on the rising edge m1_sdram samples.
        b_addr    <= x_addr;
        b_din     <= x_din;
        b_be      <= x_be;
        b_we      <= x_we;
        b_req     <= 1'b1;
      end

      // The port stretches ack for slow requesters, so take the rising edge and
      // ignore however long it stays up.
      if (b_ack && !b_ack_d) begin
        x_dout  <= b_dout;
        ack_tog <= ~ack_tog;
      end
    end
  end

endmodule
