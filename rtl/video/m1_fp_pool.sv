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
  // A CLIENT IS MASKED FOR ONE CYCLE AFTER ITS GRANT.
  //
  // Grants here are combinational, and a client's "I have been granted" flag is
  // necessarily REGISTERED - it cannot see the grant until the next edge - so
  // its request is still asserted on the grant cycle itself. With a single
  // divider that costs nothing, because the divider is then busy for up to 29
  // cycles and the stale request cannot win again. The moment a SECOND divider
  // exists the other one is free, the stale request wins immediately, and every
  // division is issued twice.
  //
  // That is exactly what happened when a second divider was tried on
  // 2026-09-04: it made the board worse and was reverted, and the cause was
  // read as the extra divider rather than as this hazard. It is not the
  // client's bug to fix either - gating m1_geo_project's div_req on div_gnt
  // closes a combinational loop through the arbiter.
  //
  // Masking here costs NC flops and no throughput: clients are single
  // outstanding, so none of them can legitimately want a grant on two
  // consecutive cycles.
  logic [NC-1:0] div_gnt_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) div_gnt_d <= '0;
    else        div_gnt_d <= div_gnt;
  end
  wire [NC-1:0] div_elig = div_req & ~div_gnt_d;

  wire [CW-1:0] div_win = rr_pick(div_elig, div_rr);

  wire mul_any = |mul_req;
  wire add_any = |add_req;
  wire div_any = |div_elig;

  // ------------------------------------------------------------- units
  logic        m_valid, a_valid, d_valid;
  logic [31:0] m_res, a_res, d_res;
  logic        d_busy;
  logic        m_ovf, m_unf, m_inv, a_ovf, a_unf, a_inv;
  logic        d_ovf, d_unf, d_dz, d_inv;

  logic        div_issue;
  assign div_issue = div_any && !d_busy && !div_outstanding;
  logic        div_outstanding;

  // OPERAND MUX REGISTERED, BECAUSE IT WAS THE clk_3d CRITICAL PATH.
  // m1_geometry's worst path ran
  //   m1_fp_pool|add_rr[1] -> m1_fp_pool|fp_add:u_add|sA_sticky
  // the round-robin arbiter, through the NC-way 32-bit operand mux
  // add_a[add_win], into fp_add's first stage, all in one cycle. The units
  // themselves are fast -- fp_add 138.48 MHz standalone, fp_mul 145.62,
  // fp_div 117.81 -- so the sharing wrapper was the limit, not the arithmetic.
  //
  // A cycle here buys clk_3d headroom, and clk_3d is tied to exactly 2x clk_cpu
  // so the crossing stays a clock enable. That makes this the gate on the CPU
  // clock as well, which is what the VR slowdowns are: ~70% of the real board's
  // work per frame at 23.529 MHz.
  //
  // THE LATENCY IS NOW 5, NOT 4, AND m1_geo_xform MUST BE TOLD. It schedules
  // its adds statically and derives the spacing from FP_ADD_LAT; every other
  // consumer waits on *_rsp and does not care. See docs/findings.md.
  //
  // div is untouched: it issues only when !d_busy and holds div_outstanding for
  // the whole iteration, so its mux is not on a per-cycle path.
  logic        add_v_q, mul_v_q, div_v_q;
  logic [31:0] add_a_q, add_b_q, mul_a_q, mul_b_q, div_a_q, div_b_q;
  logic        add_sub_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      add_v_q <= 1'b0; mul_v_q <= 1'b0; div_v_q <= 1'b0; add_sub_q <= 1'b0;
      add_a_q <= '0; add_b_q <= '0; mul_a_q <= '0; mul_b_q <= '0;
      div_a_q <= '0; div_b_q <= '0;
    end else begin
      add_v_q   <= add_any;
      add_a_q   <= add_a[add_win];
      add_b_q   <= add_b[add_win];
      add_sub_q <= add_sub[add_win];
      mul_v_q   <= mul_any;
      mul_a_q   <= mul_a[mul_win];
      mul_b_q   <= mul_b[mul_win];
      // DIV TOO, AND IT NEEDS NO TAG CHANGE. Once add and mul were registered
      // the top path became div_rr[1] -> fp_div:u_div|q_exp[10] -- the same
      // arbiter-through-operand-mux shape.
      //
      // Unlike add and mul, div is single-outstanding and self-timed: dtag is
      // ONE register held for the whole iteration, not a shift pipeline, so
      // there is no depth to re-tune. div_outstanding is set at div_issue,
      // which is still a cycle before fp_div sees in_valid, and it is what
      // blocks re-issue in that window -- so d_busy arriving a cycle later
      // cannot cause a double issue.
      //
      // No consumer can be latency-sensitive to this either: fp_div is
      // iterative with VARIABLE latency, so everything already waits on
      // div_rsp. That is why the add/mul change left geo_rsqrt untouched.
      div_v_q   <= div_issue;
      div_a_q   <= div_a[div_win];
      div_b_q   <= div_b[div_win];
    end
  end

  fp_mul u_mul (
    .clk(clk), .rst_n(rst_n),
    .in_valid(mul_v_q), .a(mul_a_q), .b(mul_b_q),
    .out_valid(m_valid), .result(m_res),
    .overflow(m_ovf), .underflow(m_unf), .invalid(m_inv)
  );

  fp_add u_add (
    .clk(clk), .rst_n(rst_n),
    .in_valid(add_v_q), .a(add_a_q), .b(add_b_q),
    .sub(add_sub_q),
    .out_valid(a_valid), .result(a_res),
    .overflow(a_ovf), .underflow(a_unf), .invalid(a_inv)
  );

  fp_div u_div (
    .clk(clk), .rst_n(rst_n),
    .in_valid(div_v_q), .a(div_a_q), .b(div_b_q),
    .busy(d_busy), .out_valid(d_valid), .result(d_res),
    .overflow(d_ovf), .underflow(d_unf), .div_by_zero(d_dz), .invalid(d_inv)
  );

  wire unused_flags = &{1'b0, m_ovf, m_unf, m_inv, a_ovf, a_unf, a_inv,
                        d_ovf, d_unf, d_dz, d_inv};

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
  // FIVE DEEP, NOT FOUR: the operand register above added a stage ahead of the
  // units, so a tag travels one more cycle before its result appears.
  logic [CW-1:0] mtag [5];
  logic [4:0]    mtag_v;
  logic [CW-1:0] atag [5];
  logic [4:0]    atag_v;
  logic [CW-1:0] dtag;

  assign mul_res = m_res;
  assign add_res = a_res;
  assign div_res = d_res;

  always_comb begin
    mul_rsp = '0;
    add_rsp = '0;
    div_rsp = '0;
    if (m_valid && mtag_v[4]) mul_rsp[mtag[4]] = 1'b1;
    if (a_valid && atag_v[4]) add_rsp[atag[4]] = 1'b1;
    if (d_valid && div_outstanding) div_rsp[dtag] = 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mul_rr <= '0; add_rr <= '0; div_rr <= '0;
      mtag_v <= '0; atag_v <= '0; dtag <= '0;
      div_outstanding <= 1'b0;
      for (int i = 0; i < 5; i++) begin mtag[i] <= '0; atag[i] <= '0; end
    end else begin
      // Shift the tags along with the operands.
      for (int i = 4; i > 0; i--) begin
        mtag[i]   <= mtag[i-1];
        atag[i]   <= atag[i-1];
      end
      mtag_v <= {mtag_v[3:0], mul_any};
      atag_v <= {atag_v[3:0], add_any};
      mtag[0] <= mul_win;
      atag[0] <= add_win;

      // Rotate past the winner so the next client gets first refusal.
      if (mul_any) mul_rr <= (mul_win == CW'(NC-1)) ? '0 : mul_win + CW'(1);
      if (add_any) add_rr <= (add_win == CW'(NC-1)) ? '0 : add_win + CW'(1);

      if (div_issue) begin
        dtag            <= div_win;
        div_outstanding <= 1'b1;
        div_rr          <= (div_win == CW'(NC-1)) ? '0 : div_win + CW'(1);
      end else if (d_valid && div_outstanding) begin
        div_outstanding <= 1'b0;
      end
    end
  end

endmodule
