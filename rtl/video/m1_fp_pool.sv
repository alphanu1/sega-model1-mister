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
// One multiplier, one adder and one divider, shared by every geometry stage.
//
// WHY SHARED, AND THE ARITHMETIC THAT SAYS IT COSTS NOTHING
//
// The stages were first built with private units - m1_geo_xform with a multiplier
// and an adder, m1_geo_project with both plus a divider, m1_geo_det with both
// again - which is three of each. Counting what a polygon record actually needs:
//
//     transform   3 points x (9 mul, 8-9 add)   27 mul   24 add
//     determinant                                9 mul   11 add
//     projection  2 points x (4 mul, 4 add)      8 mul    8 add   2 div
//                                               --------------------------
//                                               44 mul   43 add   2 div
//
// against a budget of 68 cycles a record (docs/findings.md). fp_mul and fp_add
// are four-stage pipelines that retire one result per cycle, so ONE of each runs
// at 65% and 63%. Three of each buys nothing at all; it was convenience, not
// necessity, and it costs two multipliers and two adders.
//
// The divider is the exception and cannot be shared away: fp_div is 29 cycles and
// does not pipeline, so two reciprocals a record is 58 of the 68 on their own.
// Sharing it changes nothing because there was only ever one.
//
// SO THERE ARE NDIV OF THEM NOW, and NDIV is 2. A record projects two points and
// each needs a reciprocal, and with one divider the second waits 29 cycles for
// the first: `m1_geo_project` measures 64.1 cycles a record against a 68-cycle
// budget, 94% of the whole geometry stage, and 29 of the 32 cycles a point are
// the divide alone. The 2026-08-30 entry in docs/findings.md named a second
// divider as the obvious lever and this is it. It matters because the geometry
// pass is 1.5-2.0 frames in the busy scenes on the board (L= on the UART), and
// a pass over a frame costs three frames rather than two.
//
// It is not the polygon ROM: tb_m1_raster3d with ROM_LAT=8 measures the walker's
// prefetch hiding memory latency completely (P_OBJW 44.3% against 44.2% at one
// cycle). The geometry is arithmetic-bound and this is the arithmetic.
//
// TWO DIVIDERS CAN RETIRE ON THE SAME CYCLE and the pool has one result bus, so
// each carries a one-deep holding register and the drain is round robin. fp_div
// is not fixed-latency - the suite reports max_latency=29, so special cases come
// back early - and staggered issue is therefore not enough to keep them apart.
//
// ROUND ROBIN, NOT PRIORITY. At 65% utilisation a fixed priority would almost
// always be fine, and "almost always" is how a stage that is starved only on the
// busiest frames gets shipped. The rotating pointer costs a handful of LUTs.
//
// RESULTS ARE ROUTED BY A TAG PIPELINE. fp_mul and fp_add have a fixed four-cycle
// latency and retire in issue order, so the client index shifts through a
// four-deep register alongside the operands and selects which client's response
// line is raised. The divider holds a single tag, because only one division can
// be outstanding.
//
// Each client has SEPARATE multiply and add ports rather than one operation port.
// A stage frequently has a multiply and an add in flight at once - that is the
// whole point of the pipelines - and a single port would serialise them for no
// reason, then need a queue to sort the two results out again.

`timescale 1ns/1ps

module m1_fp_pool #(
  parameter int unsigned NC = 3          // clients
) (
  input  logic                clk,
  input  logic                rst_n,

  // ---- multiply
  input  logic [NC-1:0]       mul_req,
  input  logic [31:0]         mul_a   [NC],
  input  logic [31:0]         mul_b   [NC],
  output logic [NC-1:0]       mul_gnt,
  output logic [NC-1:0]       mul_rsp,
  output logic [31:0]         mul_res,

  // ---- add / subtract
  input  logic [NC-1:0]       add_req,
  input  logic [31:0]         add_a   [NC],
  input  logic [31:0]         add_b   [NC],
  input  logic [NC-1:0]       add_sub,
  output logic [NC-1:0]       add_gnt,
  output logic [NC-1:0]       add_rsp,
  output logic [31:0]         add_res,

  // ---- divide
  input  logic [NC-1:0]       div_req,
  input  logic [31:0]         div_a   [NC],
  input  logic [31:0]         div_b   [NC],
  output logic [NC-1:0]       div_gnt,
  output logic [NC-1:0]       div_rsp,
  output logic [31:0]         div_res
);

  localparam int unsigned CW = (NC > 1) ? $clog2(NC) : 1;

  // ------------------------------------------------------------- arbiters
  // Rotating pointer: the client after the last winner gets first refusal.
  logic [CW-1:0] mul_rr, add_rr, div_rr;

  // The winner is chosen with a plain priority chain over a ROTATED request
  // vector, walked from the last index down so the lowest rotated index wins.
  // No loop-with-break: yosys rejects it (docs/rtl-conventions.md).
  function automatic [CW-1:0] rr_pick(input logic [NC-1:0] req, input logic [CW-1:0] first);
    logic [CW-1:0] best;
    logic          found;
    best  = first;
    found = 1'b0;
    for (int k = NC - 1; k >= 0; k--) begin
      int unsigned idx;
      idx = (int'(first) + k) % NC;
      if (req[idx]) begin
        best  = CW'(idx);
        found = 1'b1;
      end
    end
    rr_pick = found ? best : first;
  endfunction

  wire [CW-1:0] mul_win = rr_pick(mul_req, mul_rr);
  wire [CW-1:0] add_win = rr_pick(add_req, add_rr);
  wire [CW-1:0] div_win = rr_pick(div_req, div_rr);

  wire mul_any = |mul_req;
  wire add_any = |add_req;
  wire div_any = |div_req;

  // ------------------------------------------------------------- units
  logic        m_valid, a_valid;
  logic [31:0] m_res, a_res;
  logic        m_ovf, m_unf, m_inv, a_ovf, a_unf, a_inv;

  localparam int unsigned NDIV = 2;
  localparam int unsigned DW   = (NDIV > 1) ? $clog2(NDIV) : 1;

  logic [NDIV-1:0] d_busy, d_valid, div_outstanding;
  logic [31:0]     d_res [NDIV];
  logic [NDIV-1:0] d_ovf, d_unf, d_dz, d_inv;

  // A divider may take a new division when it is idle and its previous result
  // has been handed back.
  wire [NDIV-1:0] d_free = ~d_busy & ~div_outstanding & ~dh_v;
  logic [DW-1:0]  d_sel;
  always_comb begin
    d_sel = '0;
    for (int i = int'(NDIV) - 1; i >= 0; i--)
      if (d_free[i]) d_sel = DW'(i);
  end
  wire div_issue = div_any && (|d_free);

  fp_mul u_mul (
    .clk(clk), .rst_n(rst_n),
    .in_valid(mul_any), .a(mul_a[mul_win]), .b(mul_b[mul_win]),
    .out_valid(m_valid), .result(m_res),
    .overflow(m_ovf), .underflow(m_unf), .invalid(m_inv)
  );

  fp_add u_add (
    .clk(clk), .rst_n(rst_n),
    .in_valid(add_any), .a(add_a[add_win]), .b(add_b[add_win]),
    .sub(add_sub[add_win]),
    .out_valid(a_valid), .result(a_res),
    .overflow(a_ovf), .underflow(a_unf), .invalid(a_inv)
  );

  genvar gd;
  generate
    for (gd = 0; gd < int'(NDIV); gd++) begin : g_div
      fp_div u_div (
        .clk(clk), .rst_n(rst_n),
        .in_valid(div_issue && (d_sel == DW'(gd))),
        .a(div_a[div_win]), .b(div_b[div_win]),
        .busy(d_busy[gd]), .out_valid(d_valid[gd]), .result(d_res[gd]),
        .overflow(d_ovf[gd]), .underflow(d_unf[gd]),
        .div_by_zero(d_dz[gd]), .invalid(d_inv[gd])
      );
    end
  endgenerate

  wire unused_flags = &{1'b0, m_ovf, m_unf, m_inv, a_ovf, a_unf, a_inv,
                        |d_ovf, |d_unf, |d_dz, |d_inv};

  // ------------------------------------------------------------- grants
  // A grant is combinational and means "accepted this cycle" - the pipelines
  // always accept, so the only client that can be refused is one that lost the
  // arbitration.
  always_comb begin
    mul_gnt = '0;
    add_gnt = '0;
    div_gnt = '0;
    if (mul_any) mul_gnt[mul_win] = 1'b1;
    if (add_any) add_gnt[add_win] = 1'b1;
    if (div_issue) div_gnt[div_win] = 1'b1;
  end

  // ------------------------------------------------------------- tag pipelines
  logic [CW-1:0] mtag [4];
  logic [3:0]    mtag_v;
  logic [CW-1:0] atag [4];
  logic [3:0]    atag_v;
  logic [CW-1:0]   dtag [NDIV];
  // The holding registers: a result waits here until the shared result bus is
  // its turn, so two dividers retiring together cannot lose one.
  logic [NDIV-1:0] dh_v;
  logic [31:0]     dh_res [NDIV];
  logic [CW-1:0]   dh_tag [NDIV];

  logic [DW-1:0]   dh_sel;
  always_comb begin
    dh_sel = '0;
    for (int i = int'(NDIV) - 1; i >= 0; i--)
      if (dh_v[i]) dh_sel = DW'(i);
  end

  assign mul_res = m_res;
  assign add_res = a_res;
  assign div_res = dh_res[dh_sel];

  always_comb begin
    mul_rsp = '0;
    add_rsp = '0;
    div_rsp = '0;
    if (m_valid && mtag_v[3]) mul_rsp[mtag[3]] = 1'b1;
    if (a_valid && atag_v[3]) add_rsp[atag[3]] = 1'b1;
    if (|dh_v) div_rsp[dh_tag[dh_sel]] = 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mul_rr <= '0; add_rr <= '0; div_rr <= '0;
      mtag_v <= '0; atag_v <= '0;
      div_outstanding <= '0;
      dh_v <= '0;
      for (int i = 0; i < 4; i++) begin mtag[i] <= '0; atag[i] <= '0; end
      for (int i = 0; i < int'(NDIV); i++) begin
        dtag[i] <= '0; dh_res[i] <= '0; dh_tag[i] <= '0;
      end
    end else begin
      // Shift the tags along with the operands.
      for (int i = 3; i > 0; i--) begin
        mtag[i]   <= mtag[i-1];
        atag[i]   <= atag[i-1];
      end
      mtag_v <= {mtag_v[2:0], mul_any};
      atag_v <= {atag_v[2:0], add_any};
      mtag[0] <= mul_win;
      atag[0] <= add_win;

      // Rotate past the winner so the next client gets first refusal.
      if (mul_any) mul_rr <= (mul_win == CW'(NC-1)) ? '0 : mul_win + CW'(1);
      if (add_any) add_rr <= (add_win == CW'(NC-1)) ? '0 : add_win + CW'(1);

      if (div_issue) begin
        dtag[d_sel]            <= div_win;
        div_outstanding[d_sel] <= 1'b1;
        div_rr                 <= (div_win == CW'(NC-1)) ? '0 : div_win + CW'(1);
      end

      // Capture each divider's result as it retires, and release the one on
      // the bus this cycle. A divider cannot be reissued until its holding
      // register is empty (d_free above), so nothing is overwritten.
      for (int i = 0; i < int'(NDIV); i++) begin
        if (d_valid[i] && div_outstanding[i]) begin
          dh_v[i]                <= 1'b1;
          dh_res[i]              <= d_res[i];
          dh_tag[i]              <= dtag[i];
          div_outstanding[i]     <= 1'b0;
        end else if (dh_v[i] && (dh_sel == DW'(i))) begin
          dh_v[i]                <= 1'b0;
        end
      end
    end
  end

endmodule
