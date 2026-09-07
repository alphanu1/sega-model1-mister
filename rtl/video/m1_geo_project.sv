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
// The geometry stage's projection: a transformed point to a pixel.
//
// Behavioural contract is MAME's view_t::project_point (model1_v.cpp:79), and
// push_object's guard around it (:911):
//
//     if (z > 0) { xx = x/z;  yy = y/z;
//                  s.x = xc + (xx*zoomx + viewx);
//                  s.y = yc - (yy*zoomy + viewy); }
//     else       { s.x = s.y = 0; }
//
// The z <= 0 case is not a clip - it is a point BEHIND the eye given the
// coordinates (0,0), which the frustum clipper upstream is expected to have
// dealt with. Reproduced rather than improved: a point behind the eye that
// reaches here lands at the top-left corner in MAME too, and quads built from it
// are what the viewport clip then throws away.
//
// ONE RECIPROCAL, NOT TWO DIVIDES, AND THE COST IS MEASURED
//
// MAME divides twice per point with the same divisor. fp_div is 29 cycles and
// does not pipeline, so two of them is 58 cycles against a 34-cycle-per-point
// budget (docs/findings.md) - it cannot be afforded. One reciprocal and two
// multiplies costs 29 and fits.
//
// It is not bit-identical, so the difference was measured rather than waved
// through: over 8 million points at six zoom levels, spread across six decades
// of depth, x*(1/z) lands on a different PIXEL than x/z in **0.002% of cases and
// never by more than one pixel** - about half a vertex coordinate per frame at
// 11,662 points. Recorded in docs/findings.md. That is the one place this design
// is knowingly not bit-exact with the reference, and it is a rounding difference
// in the last place of a value that is about to be truncated to an integer, not
// a different algorithm.
//
// STRUCTURE. The reciprocal is the throughput limit at 29 cycles, so it is a
// stage of its own and the multiply/add chain runs concurrently on the previous
// point - the same shape as m1_geo_xform, and for the same measured reason.

`timescale 1ns/1ps

module m1_geo_project (
  input  logic        clk,
  input  logic        rst_n,

  // Viewport parameters, all IEEE-754 single. xc/yc come from command 3, zoom
  // from command 9 (as readf * 4), view from command 0x0c.
  input  logic [31:0] xc, yc,
  input  logic [31:0] zoomx, zoomy,
  input  logic [31:0] viewx, viewy,

  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] in_x, in_y, in_z,

  // Shared arithmetic - see rtl/video/m1_fp_pool.sv.
  output logic        mul_req,
  output logic [31:0] mul_a, mul_b,
  input  logic        mul_gnt,
  input  logic        mul_rsp,
  input  logic [31:0] mul_res,

  output logic        add_req,
  output logic [31:0] add_a, add_b,
  output logic        add_sub,
  input  logic        add_gnt,
  input  logic        add_rsp,
  input  logic [31:0] add_res,

  output logic        div_req,
  output logic [31:0] div_a, div_b,
  input  logic        div_gnt,
  input  logic        div_rsp,
  input  logic [31:0] div_res,

  output logic        out_valid,
  output logic signed [31:0] out_sx, out_sy,   // pixels
  output logic [31:0] out_z,                   // passed through, for the sort
  output logic        out_behind                // z <= 0: the (0,0) case
);

  // ------------------------------------------------------------ in flight
  // NSLOT points at once, allocated and retired in order. The walker already
  // issues two projections per record and cannot finish until both are back,
  // so one-at-a-time made them strictly serial; four covers those two plus the
  // header pair. Cost is four slots of {vx,vy,z,r} and change.
  localparam int NSLOT = 4;
  localparam int SW    = 2;                 // $clog2(NSLOT)

  logic [31:0]   q_vx [NSLOT], q_vy [NSLOT], q_z [NSLOT], q_r [NSLOT];
  logic          q_beh [NSLOT], q_rv [NSLOT];
  logic [2:0]    q_stg [NSLOT];             // 0 M0, 1 M1, 2 A0, 3 A1, 4 done
  logic [1:0]    q_iss [NSLOT], q_got [NSLOT];
  logic [SW-1:0] wr_ptr, rc_ptr, rd_ptr;
  logic [SW:0]   count;

  // count is SW+1 bits, so full is exactly its top bit.
  assign in_ready = !count[SW];

  // z > 0 means positive, nonzero and not a NaN. A NaN compares false against
  // everything in C, so `z > 0` is false for it and MAME takes the behind path -
  // reproduced by testing the sign bit AND that the value is not zero or NaN.
  wire z_is_nan  = (in_z[30:23] == 8'hff) && (in_z[22:0] != 23'd0);
  wire z_is_zero = (in_z[30:0] == 31'd0);
  wire z_pos     = !in_z[31] && !z_is_zero && !z_is_nan;

  wire accept = in_valid && in_ready;

  // The reciprocal is LOCAL and pipelined, not the pool's divider: 6 cycles
  // against 29, one per cycle, and every point's multiplies wait on it.
  // m1_geo_recip's header carries the measurement. The pool's div port is tied
  // off here; m1_geo_clip and m1_geo_planes still use it.
  assign div_req = 1'b0;
  assign div_a   = '0;
  assign div_b   = '0;

  wire        rcp_valid;
  wire [31:0] rcp_out;

  // EVERY accepted point goes through it, behind-the-eye ones included, and a
  // behind slot waits for its result before retiring even though it discards it.
  // That keeps one reciprocal per slot in allocation order, so rc_ptr never has
  // to skip - and a skipped slot could be reallocated while its result was still
  // in flight, landing on the wrong point. It costs nothing: the unit is
  // pipelined, so the extra points ride along in cycles that were already spent.
  m1_geo_recip u_recip (
    .clk(clk), .rst_n(rst_n),
    .in_valid(accept), .in_ready(), .in_x(in_z),
    .out_valid(rcp_valid), .out_y(rcp_out)
  );

  // ------------------------------------------------------------ issue
  // Oldest slot first, for each unit independently. Scanning down from the
  // newest means the last write wins and that is slot rd_ptr, so a stalled
  // point can never be overtaken into the same unit by a younger one.
  logic          mul_sel_v, add_sel_v;
  logic [SW-1:0] mul_sel,   add_sel;
  logic [SW-1:0] scan_s;          // loop temp, hoisted so yosys will take it

  always_comb begin
    mul_sel_v = 1'b0; mul_sel = '0;
    add_sel_v = 1'b0; add_sel = '0;
    for (int k = NSLOT-1; k >= 0; k--) begin
      scan_s = SW'(rd_ptr + SW'(k[SW-1:0]));
      if ({1'b0, SW'(k[SW-1:0])} < count) begin
        if (q_rv[scan_s] && (q_stg[scan_s] < 3'd2) && (q_iss[scan_s] < 2'd2)) begin
          mul_sel_v = 1'b1; mul_sel = scan_s;
        end
        if ((q_stg[scan_s] >= 3'd2) && (q_stg[scan_s] < 3'd4) && (q_iss[scan_s] < 2'd2)) begin
          add_sel_v = 1'b1; add_sel = scan_s;
        end
      end
    end
  end

  wire m_c1 = (q_iss[mul_sel] == 2'd1);     // second of the pair: the y coord
  wire a_c1 = (q_iss[add_sel] == 2'd1);
  wire a_st1 = (q_stg[add_sel] == 3'd3);    // A1 rather than A0

  assign mul_req = mul_sel_v;
  assign mul_a   = m_c1 ? q_vy[mul_sel] : q_vx[mul_sel];
  assign mul_b   = (q_stg[mul_sel] == 3'd0) ? q_r[mul_sel]
                                            : (m_c1 ? zoomy : zoomx);

  assign add_req = add_sel_v;
  assign add_a   = a_st1 ? (a_c1 ? yc : xc)
                         : (a_c1 ? q_vy[add_sel] : q_vx[add_sel]);
  assign add_b   = a_st1 ? (a_c1 ? q_vy[add_sel] : q_vx[add_sel])
                         : (a_c1 ? viewy : viewx);
  assign add_sub = a_st1 && a_c1;           // yc MINUS, the screen y axis is flipped

  // ------------------------------------------------------------ tags
  // fp_mul and fp_add are fixed-latency pipelines, so a client's results come
  // back in the order it issued them. That is the whole reason several points
  // can be in flight: each unit needs nothing more than a queue recording which
  // slot and which coordinate each outstanding operation belongs to.
  logic [SW-1:0] mtag_s [8], atag_s [8];
  logic          mtag_c [8], atag_c [8];
  logic [2:0]    mt_wr, mt_rd, at_wr, at_rd;

  wire [SW-1:0] m_rs = mtag_s[mt_rd];
  wire          m_rc = mtag_c[mt_rd];
  wire [SW-1:0] a_rs = atag_s[at_rd];
  wire          a_rc = atag_c[at_rd];

  // ------------------------------------------------------------ retire
  logic signed [31:0] sx_i, sy_i;
  fp_to_int u_f2i_x (.f(q_vx[rd_ptr]), .i(sx_i));
  fp_to_int u_f2i_y (.f(q_vy[rd_ptr]), .i(sy_i));

  wire retire = (count != 0) && (q_stg[rd_ptr] == 3'd4) && q_rv[rd_ptr];

  // tb_m1_geometry reads these two by name for its inside-projection split.
  // They are summaries of the queue now, not states of a machine.
  wire [1:0] rst_st /* verilator public_flat_rd */ =
      (rc_ptr != wr_ptr) ? 2'd1 : ((count != 0) ? 2'd2 : 2'd0);
  logic [2:0] sst /* verilator public_flat_rd */;
  always_comb begin
    sst = 3'd0;
    for (int k = 0; k < NSLOT; k++)
      if (({1'b0, SW'(k[SW-1:0])} < count) && (q_stg[SW'(rd_ptr + SW'(k[SW-1:0]))] < 3'd4))
        sst = sst + 3'd1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= '0; rc_ptr <= '0; rd_ptr <= '0; count <= '0;
      mt_wr <= '0; mt_rd <= '0; at_wr <= '0; at_rd <= '0;
      out_valid <= 1'b0; out_sx <= '0; out_sy <= '0; out_z <= '0;
      out_behind <= 1'b0;
      for (int i = 0; i < NSLOT; i++) begin
        q_vx[i] <= '0; q_vy[i] <= '0; q_z[i] <= '0; q_r[i] <= '0;
        q_beh[i] <= 1'b0; q_rv[i] <= 1'b0;
        q_stg[i] <= 3'd4; q_iss[i] <= '0; q_got[i] <= '0;
      end
    end else begin
      out_valid <= 1'b0;

      // ------------------------------------------------------ allocate
      if (accept) begin
        q_vx[wr_ptr]  <= in_x;
        q_vy[wr_ptr]  <= in_y;
        q_z[wr_ptr]   <= in_z;
        q_beh[wr_ptr] <= !z_pos;
        // Behind the eye skips the chain entirely, as MAME does: it does not
        // call project_point, it assigns zero.
        q_stg[wr_ptr] <= z_pos ? 3'd0 : 3'd4;
        q_iss[wr_ptr] <= '0;
        q_got[wr_ptr] <= '0;
        q_rv[wr_ptr]  <= 1'b0;
        wr_ptr        <= wr_ptr + SW'(1);
      end

      // ------------------------------------------------------ reciprocal in
      if (rcp_valid) begin
        q_r[rc_ptr]  <= rcp_out;
        q_rv[rc_ptr] <= 1'b1;
        rc_ptr       <= rc_ptr + SW'(1);
      end

      // ------------------------------------------------------ issue accepted
      // Advance only on a grant: a shared unit can refuse a cycle, and stepping
      // through the refusal drops an operand silently.
      if (mul_req && mul_gnt) begin
        mtag_s[mt_wr] <= mul_sel;
        mtag_c[mt_wr] <= m_c1;
        mt_wr         <= mt_wr + 3'd1;
        q_iss[mul_sel] <= q_iss[mul_sel] + 2'd1;
      end
      if (add_req && add_gnt) begin
        atag_s[at_wr] <= add_sel;
        atag_c[at_wr] <= a_c1;
        at_wr         <= at_wr + 3'd1;
        q_iss[add_sel] <= q_iss[add_sel] + 2'd1;
      end

      // ------------------------------------------------------ collect
      if (mul_rsp) begin
        mt_rd <= mt_rd + 3'd1;
        if (m_rc) q_vy[m_rs] <= mul_res; else q_vx[m_rs] <= mul_res;
        if (q_got[m_rs] == 2'd1) begin
          q_got[m_rs] <= '0; q_iss[m_rs] <= '0; q_stg[m_rs] <= q_stg[m_rs] + 3'd1;
        end else begin
          q_got[m_rs] <= q_got[m_rs] + 2'd1;
        end
      end
      if (add_rsp) begin
        at_rd <= at_rd + 3'd1;
        if (a_rc) q_vy[a_rs] <= add_res; else q_vx[a_rs] <= add_res;
        if (q_got[a_rs] == 2'd1) begin
          q_got[a_rs] <= '0; q_iss[a_rs] <= '0; q_stg[a_rs] <= q_stg[a_rs] + 3'd1;
        end else begin
          q_got[a_rs] <= q_got[a_rs] + 2'd1;
        end
      end

      // ------------------------------------------------------ retire
      if (retire) begin
        // Behind the eye is a literal (0,0), as MAME assigns - not a converted
        // one, because the float chain was never run for it.
        out_sx     <= q_beh[rd_ptr] ? 32'sd0 : sx_i;
        out_sy     <= q_beh[rd_ptr] ? 32'sd0 : sy_i;
        out_z      <= q_z[rd_ptr];
        out_behind <= q_beh[rd_ptr];
        out_valid  <= 1'b1;
        rd_ptr     <= rd_ptr + SW'(1);
      end

      count <= count + {2'd0, accept} - {2'd0, retire};
    end
  end

endmodule
