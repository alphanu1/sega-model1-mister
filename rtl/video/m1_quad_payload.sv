// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The quad store's VERTEX PAYLOAD, behind a request/valid interface.
//
// WHY THIS IS A SEPARATE MODULE
//
// The quad store is 196 of the device's 553 M10K - 35% of all block RAM - and
// M10K has been the binding constraint on the 3D layer for weeks: the band
// buffer, the second display list and the sound board have all been costed
// against it and all lost. Measured per bank (NQ=3,584):
//
//     vtx0-3  lo+hi   56 M10K     <- this module, and it can leave the chip
//     att     lo+hi   14          band range: the FILTER, it cannot
//     key     lo+hi   14          the radix sort reads it four times
//     idx_a/b lo+hi   14          the radix scatter writes it randomly
//
// The vertices are the only part with an SDRAM-friendly access pattern. `att`
// is read for EVERY quad on EVERY one of the 48 bands - 172,032 reads a pass -
// because it carries the band range that decides whether a quad is in this
// band at all. The vertices are read ONLY for a quad that passes, which
// measured 11,320 times in the busiest pass of a real race.
//
// THE INTERFACE IS REQUEST/VALID EVEN THOUGH M10K ANSWERS NEXT CYCLE
//
// The point of this module is that the backing can change without the store's
// replay pipeline changing again. The pipeline used to read `vtx0_lo[q2]`
// free-running and rely on the answer being there one cycle later; that
// assumption is what an off-chip backing breaks. Asking through `req`/`valid`
// costs one cycle per emission here - about 2% of a pass - and buys a store
// that does not care how long the answer takes.
//
// Measured headroom for that change, from the same race: emissions arrive one
// every ~1.87 us because the fill, not the scan, paces them. SDRAM needs about
// ten cycles for a 20-byte payload on a 16-bit bus, so there is roughly 15x
// margin. See docs/findings.md 2026-09-10 (10).
//
// ONE READ PER ARRAY, NOT TWO. `vtx0[q][15:0]` and `vtx0[q][31:16]` are two
// reads of one array as far as synthesis is concerned, and Quartus answers the
// second by DUPLICATING the memory - measured at 91 blocks for 411,648 bits of
// unique data, 40% packing. The whole payload is therefore one concatenated
// word in and one out, split by the caller.

`timescale 1ns/1ps

module m1_quad_payload #(
  parameter int unsigned NQ = 3584,
  parameter int unsigned IW = 12,
  parameter int unsigned VW = 32          // one vertex: {y, x}
) (
  input  logic            clk,
  input  logic            rst_n,

  // Write port, one quad as it is accepted into the store.
  input  logic            we,
  input  logic [IW-1:0]   waddr,
  input  logic [4*VW-1:0] wdata,          // {v3, v2, v1, v0}

  // Read port. `valid` answers a `req`; with this backing it is the next
  // cycle, and nothing downstream may assume that.
  input  logic            req,
  input  logic [IW-1:0]   raddr,
  output logic            valid,
  output logic [4*VW-1:0] rdata
);

  // The 2,048-entry split exists because Quartus builds a memory deeper than
  // one M10K row out of whole blocks, and a 3,584-deep array wastes the
  // remainder. Two arrays, 2,048 and NQ-2,048, pack exactly.
  localparam int unsigned NLO = (NQ > 2048) ? 2048 : NQ;
  localparam int unsigned NHI = (NQ > 2048) ? NQ - 2048 : 1;
  localparam int unsigned LW  = (NLO > 1) ? $clog2(NLO) : 1;

  function automatic logic in_hi(input logic [IW-1:0] a);
    in_hi = (NQ > 2048) && (a >= IW'(NLO));
  endfunction
  function automatic [LW-1:0] lo_a(input logic [IW-1:0] a);
    lo_a = a[LW-1:0];
  endfunction
  function automatic [LW-1:0] hi_a(input logic [IW-1:0] a);
    hi_a = LW'(a - IW'(NLO));
  endfunction

  (* ramstyle = "M10K" *) logic [4*VW-1:0] pay_lo [NLO];
  (* ramstyle = "M10K" *) logic [4*VW-1:0] pay_hi [NHI];

  logic [4*VW-1:0] q_lo, q_hi;
  logic            sel_hi;

  always_ff @(posedge clk) begin
    if (we) begin
      if (in_hi(waddr)) pay_hi[hi_a(waddr)] <= wdata;
      else              pay_lo[lo_a(waddr)] <= wdata;
    end
    // Free-running reads: both halves every cycle, the half chosen on the way
    // out. Gating them on `req` would add a mux into the address path for no
    // saving - a block RAM read costs nothing when its result is discarded.
    q_lo   <= pay_lo[lo_a(raddr)];
    q_hi   <= pay_hi[hi_a(raddr)];
    sel_hi <= in_hi(raddr);
  end

  assign rdata = sel_hi ? q_hi : q_lo;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) valid <= 1'b0;
    else        valid <= req;
  end

endmodule
