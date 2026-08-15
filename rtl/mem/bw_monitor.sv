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
// Per-master SDRAM bandwidth telemetry.
//
// docs/m1-m4-plan.md: "Instrument the arbiter now. Per-master cycle counters
// dumped to the HPS. This is how D2 and D3 get validated with numbers instead
// of arithmetic, and it costs almost nothing to add at this stage versus
// retrofitting during M3."
//
// This is that instrument, and the numbers it produces decide two open
// decisions rather than merely being interesting:
//
//   D2  single SDRAM module is a hard requirement. Reverses only if M3 shows
//       the band renderer cannot close — which is a bandwidth measurement.
//   D3  band renderer keeps framebuffer traffic off external RAM. The estimate
//       is 130-160 MB/s naive against ~120-140 MB/s usable, falling to 55-75
//       with banding. Those are arithmetic; this makes them observations.
//
// WHAT IS COUNTED, AND WHY EACH ONE
//
//   req    cycles a master was asserting a request. Demand.
//   grant  cycles it was granted. Throughput.
//   wait   req && !grant. The queue. This is the number that says whether a
//          master is being starved, and it is the one a naive
//          transactions-per-second counter hides completely.
//   burst  granted cycles with no gap. Row-hit efficiency; a controller that
//          reopens a row per word shows short bursts even at high grant count.
//
// Counters are free-running and read as a snapshot. There is deliberately no
// clear-on-read: two readers would race, and the HPS side is easier to write
// against monotonic counters that it differences itself.
//
// COUNTER WIDTHS ARE NOT FREE
//
// The plan calls this instrument "almost nothing" to add. At 32 bits per
// counter it is not: 4 masters x 5 counters x 32 bits measured 1082 LUT and
// 1216 flops under `make area`, which is roughly 600 ALM — around 8% of what
// is left after three TGP instances. So the widths are sized to the job:
//
//   CW=24  rate counters. Free-running and differenced by the reader, so the
//          only requirement is that it not wrap twice between two reads.
//          16.7 M cycles is 0.33 s at 50 MHz; the HPS polls per frame.
//          Unsigned subtraction gives the right delta across a single wrap.
//   BW=8   burst counters. A burst is a run of consecutive granted cycles.
//          A controller doing 8-word bursts on a 16-bit bus tops out well
//          under 255, and burst_max saturates rather than wrapping, because a
//          wrapped maximum reads as a small number and would be mistaken for
//          good row-hit behaviour when it is the opposite.

`timescale 1ns/1ps

module bw_monitor #(
  parameter int unsigned MASTERS = 4,
  parameter int unsigned CW      = 24,  // rate counter width, wraps and is differenced
  parameter int unsigned BW      = 8    // burst counter width, saturates
) (
  input  logic                     clk,
  input  logic                     rst_n,

  // One bit per master, from the arbiter.
  input  logic [MASTERS-1:0]       req,
  input  logic [MASTERS-1:0]       grant,

  // Sampling window. Held low, the counters free-run; pulsing `snap` latches
  // every counter into the readback set in one cycle, so a reader never sees
  // a torn set from different cycles.
  input  logic                     snap,

  // Flat readback. Index with sel; one port keeps the HPS interface trivial.
  input  logic [$clog2(MASTERS)-1:0] sel,
  output logic [CW-1:0]            req_count,
  output logic [CW-1:0]            grant_count,
  output logic [CW-1:0]            wait_count,
  output logic [BW-1:0]            burst_max,
  output logic [CW-1:0]            total_cycles
);

  logic [CW-1:0] c_req   [MASTERS];
  logic [CW-1:0] c_grant [MASTERS];
  logic [CW-1:0] c_wait  [MASTERS];
  logic [BW-1:0] c_bmax  [MASTERS];
  logic [BW-1:0] c_brun  [MASTERS];   // current burst length
  logic [CW-1:0] c_total;

  logic [CW-1:0] s_req   [MASTERS];
  logic [CW-1:0] s_grant [MASTERS];
  logic [CW-1:0] s_wait  [MASTERS];
  logic [BW-1:0] s_bmax  [MASTERS];
  logic [CW-1:0] s_total;

  integer m;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (m = 0; m < MASTERS; m = m + 1) begin
        c_req[m]   <= '0; c_grant[m] <= '0; c_wait[m] <= '0;
        c_bmax[m]  <= '0; c_brun[m]  <= '0;
        s_req[m]   <= '0; s_grant[m] <= '0; s_wait[m] <= '0; s_bmax[m] <= '0;
      end
      c_total <= '0;
      s_total <= '0;
    end else begin
      c_total <= c_total + 1'b1;

      for (m = 0; m < MASTERS; m = m + 1) begin
        if (req[m])               c_req[m]   <= c_req[m]   + 1'b1;
        if (grant[m])             c_grant[m] <= c_grant[m] + 1'b1;
        // Starvation: asking and not getting. A transaction-rate counter
        // cannot show this, which is why it is counted separately.
        if (req[m] && !grant[m])  c_wait[m]  <= c_wait[m]  + 1'b1;

        // Burst tracking. The run extends while grant holds and is committed
        // to the maximum when it breaks, so a burst still in flight at snap
        // time is not counted until it ends — deliberately, since its length
        // is not yet known.
        // burst_max saturates without needing a saturation guard, and an
        // explicit one was written here first and then removed: c_bmax only
        // ever takes a value strictly greater than itself, so it is monotonic,
        // and reaching all-ones is therefore permanent. c_brun wrapping past
        // that point cannot pull it back down, because the wrapped value
        // 0 fails the greater-than test. A mutation test proved the guard
        // unobservable — it changed no output and only cost area.
        //
        // That matters for the reader: burst_max stuck at all-ones means
        // overflow, not a genuinely long burst.
        if (grant[m]) begin
          c_brun[m] <= c_brun[m] + 1'b1;
          if ((c_brun[m] + 1'b1) > c_bmax[m]) c_bmax[m] <= c_brun[m] + 1'b1;
        end else begin
          c_brun[m] <= '0;
        end
      end

      // Latch everything on one edge: a reader differencing two snapshots must
      // be comparing counters from the same cycle or the ratios are nonsense.
      if (snap) begin
        for (m = 0; m < MASTERS; m = m + 1) begin
          s_req[m]   <= c_req[m];
          s_grant[m] <= c_grant[m];
          s_wait[m]  <= c_wait[m];
          s_bmax[m]  <= c_bmax[m];
        end
        s_total <= c_total;
      end
    end
  end

  assign req_count    = s_req[sel];
  assign grant_count  = s_grant[sel];
  assign wait_count   = s_wait[sel];
  assign burst_max    = s_bmax[sel];
  assign total_cycles = s_total;

endmodule
