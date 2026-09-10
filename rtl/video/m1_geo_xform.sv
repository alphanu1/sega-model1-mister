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
// The geometry stage's matrix transform: a point through the 3x4 view matrix.
//
// Behavioural contract is MAME's model1_v.cpp view_t::transform_point (:38) and
// transform_vector (:48):
//
//     xx = m[0]*x + m[3]*y + m[6]*z + m[ 9]
//     yy = m[1]*x + m[4]*y + m[7]*z + m[10]
//     zz = m[2]*x + m[5]*y + m[8]*z + m[11]
//
// transform_vector is the same without the m[9..11] column, and is what the
// polygon's normal goes through - a direction has no origin, so translating it
// would be wrong.
//
// THE YAW IS NOT IMPLEMENTED, AND THAT IS CORRECT. transform_point ends with
//
//     p->x = ayyc * xx - ayys * zz;
//     p->z = ayys * xx + ayyc * zz;
//
// which looks like a second rotation and is not one: `ayy` is only ever written
// inside an `#if 0` debug free-camera (model1_v.cpp:1793-1842), so it is always
// 0, ayyc is always 1 and ayys always 0, and the pair reduces to x = xx, z = zz.
// Building it would cost four multiplies and two adds per point - about 12% of
// this module's arithmetic - to compute an identity. Checked before omitting.
//
// WHY IT IS BIT-EXACT AGAINST MAME AND NOT MERELY CLOSE
//
// MAME evaluates the geometry in host `float`, and fp_mul and fp_add are fuzzed
// against host float directly (sim/tgp/tb_fp_mul.cpp: "reference is the host C
// float, matching MAME's evaluation model"). So the same operations in the same
// ORDER give the same bits, and the order is what this module is careful about:
// floating-point addition is not associative, and summing the three products
// left to right rather than as a balanced tree is a different answer in the last
// place. MAME sums left to right. So does this.
//
// SCHEDULING, AND THE MEASUREMENT THAT FORCED IT
//
// A polygon record needs THREE transforms - two points and the normal - and the
// budget is 68 cycles a record (docs/findings.md: 5,831 records in a peak frame,
// 818,133 cycles - see the note on the budget in rtl/video/m1_raster3d.sv).
//
// The obvious structure - issue nine multiplies, wait for all nine, then three
// rounds of adds each drained before the next - was built first and MEASURED at
// **40 cycles a transform, 120 a record, 1.76x over budget**. The multiplier is
// idle for 31 of those 40 cycles. That is what the throughput case in the bench
// exists to catch, and it caught it.
//
// So the multiply and add phases are separate stages that run CONCURRENTLY on
// different points, and the products live in a ping-pong bank so the adds of
// point N-1 can read one bank while the multiplies of point N fill the other.
//
// The add schedule is fixed and spaced, not packed:
//
//     ac  0  1  2   |  5  6  7   |  10 11 12
//         round 0      round 1      round 2
//
// Three-cycle gaps, not two. fp_add's latency is 4, so round 1's first add reads
// a t[] the round-0 result must already have been WRITTEN to - issuing it on the
// cycle that result arrives reads the old value, because the capture is
// non-blocking. One cycle of slack is the difference between a correct sum and a
// stale one, and it is invisible in a wave until the numbers are compared.

`timescale 1ns/1ps

module m1_geo_xform #(
  // m1_fp_pool's add latency. MUST MATCH the pool, which is why it is a
  // parameter and not a local guess: the add schedule below is spaced from it.
  parameter int FP_ADD_LAT = 5
) (
  input  logic        clk,
  input  logic        rst_n,

  // The view matrix, written a float at a time by the display-list walker's
  // command 0x0b. Held until the next one.
  input  logic        mat_we,
  input  logic [3:0]  mat_idx,        // 0..11
  input  logic [31:0] mat_data,

  // Point in.
  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] in_x, in_y, in_z,
  input  logic        in_translate,   // 1 = transform_point, 0 = transform_vector

  // Shared arithmetic. See rtl/video/m1_fp_pool.sv: one multiplier and one adder
  // serve every geometry stage, because a record needs 44 multiplies and 43 adds
  // against a 68-cycle budget and the pipelines retire one a cycle.
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

  // Point out, in issue order.
  output logic        out_valid,
  output logic [31:0] out_x, out_y, out_z
);

  logic [31:0] mat [12] /* verilator public_flat_rd */;
  always_ff @(posedge clk) if (mat_we) mat[mat_idx] <= mat_data;

  // ------------------------------------------------------------ product bank
  // Two banks of nine products: one being filled by the multiplier for point N
  // while the other is being summed for point N-1.
  logic [31:0] r [2][9];
  logic        fill_bank;      // bank the multiplier is writing
  logic        sum_bank;       // bank the adder is reading
  logic        bank_full;      // fill_bank holds a complete set of nine
  logic        bank_trans;     // and whether that point wanted the translation

  // ------------------------------------------------------------ multiply stage
  typedef enum logic [1:0] { M_IDLE, M_ISSUE, M_WAIT } mstate_t;
  mstate_t mst;

  logic [31:0] px, py, pz;
  logic        ptrans;
  logic [3:0]  issue;          // multiplies issued, 0..8
  logic [3:0]  got;            // results captured, 0..9

  wire [1:0]  term  = 2'(issue % 4'd3);       // which of x, y, z
  wire [1:0]  comp  = 2'(issue / 4'd3);       // which output component
  wire [3:0]  m_sel = 4'({2'd0, term} * 4'd3 + {2'd0, comp});

  assign mul_a = mat[m_sel];
  assign mul_b = (term == 2'd0) ? px : (term == 2'd1) ? py : pz;

  wire mul_out_valid = mul_rsp;
  wire [31:0] mul_result = mul_res;

  // ------------------------------------------------------------ add stage
  typedef enum logic [1:0] { A_IDLE, A_RUN, A_OUT } astate_t;
  astate_t ast;

  logic [3:0]  ac;             // position in the add schedule, 0..12
  logic [1:0]  a_got;          // results captured within the current round
  logic [3:0]  a_total;        // results captured overall, 0..9
  logic [31:0] t [3];
  logic        atrans;

  // Schedule: adds at ac 0,1,2 / 5,6,7 / 10,11,12. round = ac/S, comp = ac%S.
  //
  // THE STRIDE IS DERIVED FROM THE POOL'S LATENCY, NOT A LITERAL. It used to be
  // a bare 4'd5, and that one magic number is what pins m1_fp_pool's pipeline
  // depth: the pool's operand mux is the clk_3d critical path, registering it
  // adds a cycle, and a stride hard-coded for latency 4 then reads results that
  // have not been written yet. That cost 7,806 fails of 7,813 before the reason
  // was found -- see docs/findings.md.
  //
  // Three adds per round plus the gap that covers the latency, so S = LAT + 1.
  // Every other pool consumer waits on *_rsp and is latency-agnostic; this one
  // schedules statically because it streams, so it is the only module that has
  // to be told.
  localparam int A_STRIDE = FP_ADD_LAT + 1;
  wire [1:0] a_round = 2'(ac / 4'(A_STRIDE));
  wire [2:0] a_comp  = 3'(ac % 4'(A_STRIDE));
  wire       a_slot  = (a_comp <= 3'd2);

  wire [3:0]  ra    = 4'({1'd0, a_comp} * 4'd3);
  assign add_a = (a_round == 2'd0) ? r[sum_bank][ra] : t[a_comp[1:0]];
  assign add_b = (a_round == 2'd0) ? r[sum_bank][ra + 4'd1] :
                 (a_round == 2'd1) ? r[sum_bank][ra + 4'd2]
                                   : mat[4'd9 + {2'd0, a_comp[1:0]}];
  assign add_sub = 1'b0;

  wire        add_out_valid = add_rsp;
  wire [31:0] add_result    = add_res;

  // The last round is skipped for a vector: a direction has no origin.
  // Last slot: two full strides plus the three adds for a 3-round transform,
  // one stride plus three for a 2-round one. Was 4'd12 / 4'd7 for stride 5.
  wire [3:0] ac_last  = atrans ? 4'(2*A_STRIDE + 2) : 4'(A_STRIDE + 2);
  wire [3:0] want_res = atrans ? 4'd9  : 4'd6;

  assign mul_req = (mst == M_ISSUE);
  assign add_req = (ast == A_RUN) && a_slot;

  // A new point is taken when the multiplier is free AND the bank it would fill
  // holds nothing the adder has yet to collect.
  //
  // `!bank_full` and not `!(bank_full && fill_bank == sum_bank)`: fill_bank does
  // not flip when the products are finished, it flips when the ADDER TAKES them,
  // so between those two moments the full bank is still the one the multiplier
  // would write. The identity test reads as the more careful condition and is
  // the weaker one - it let the next point overwrite nine products that had not
  // been summed yet. Streaming found it at result 18; one point at a time never
  // could, because the bank was always collected before the next point arrived.
  assign in_ready = (mst == M_IDLE) && !bank_full;


  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mst <= M_IDLE; ast <= A_IDLE;
      issue <= '0; got <= '0; ac <= '0; a_got <= '0; a_total <= '0;
      fill_bank <= 1'b0; sum_bank <= 1'b0; bank_full <= 1'b0;
      bank_trans <= 1'b0; atrans <= 1'b0;
      px <= '0; py <= '0; pz <= '0; ptrans <= 1'b0;
      out_valid <= 1'b0; out_x <= '0; out_y <= '0; out_z <= '0;
      for (int b = 0; b < 2; b++)
        for (int i = 0; i < 9; i++) r[b][i] <= '0;
      for (int i = 0; i < 3; i++) t[i] <= '0;
    end else begin
      out_valid <= 1'b0;

      // Results come back in issue order, so a counter places them.
      if (mul_out_valid && got < 4'd9) begin
        r[fill_bank][got] <= mul_result;
        got               <= got + 4'd1;
      end
      if (add_out_valid && a_total < 4'd9) begin
        t[a_got] <= add_result;
        a_got    <= (a_got == 2'd2) ? 2'd0 : a_got + 2'd1;
        a_total  <= a_total + 4'd1;
      end

      // -------------------------------------------------- multiply stage
      case (mst)
        M_IDLE: begin
          if (in_valid && in_ready) begin
            px <= in_x; py <= in_y; pz <= in_z; ptrans <= in_translate;
            issue <= '0; got <= '0;
            mst <= M_ISSUE;
          end
        end
        M_ISSUE: begin
          // ONLY ON A GRANT. With a private multiplier every issue was accepted,
          // so the counter could run free; sharing means a cycle where another
          // stage won the arbitration, and advancing through it would skip a
          // product and leave r[] one short forever.
          if (mul_gnt) begin
            if (issue == 4'd8) mst <= M_WAIT;  // stop at 8: m_sel must stay in range
            else               issue <= issue + 4'd1;
          end
        end
        M_WAIT: begin
          if (got == 4'd9) begin
            bank_full  <= 1'b1;
            bank_trans <= ptrans;
            mst        <= M_IDLE;
          end
        end
        default: mst <= M_IDLE;
      endcase

      // -------------------------------------------------- add stage
      case (ast)
        A_IDLE: begin
          if (bank_full) begin
            sum_bank  <= fill_bank;
            atrans    <= bank_trans;
            fill_bank <= ~fill_bank;
            bank_full <= 1'b0;
            ac        <= '0;
            a_got     <= '0;
            a_total   <= '0;
            ast       <= A_RUN;
          end
        end
        A_RUN: begin
          // The schedule advances on a gap (no request) or on a granted add. A
          // stall only STRETCHES the spacing between rounds, which is the safe
          // direction: the gaps exist so a round reads a t[] the previous round
          // has already written.
          if (!a_slot || add_gnt) begin
            if (ac == ac_last) ast <= A_OUT;
            else               ac  <= ac + 4'd1;
          end
        end
        A_OUT: begin
          if (a_total == want_res) begin
            out_x     <= t[0];
            out_y     <= t[1];
            out_z     <= t[2];
            out_valid <= 1'b1;
            ast       <= A_IDLE;
          end
        end
        default: ast <= A_IDLE;
      endcase
    end
  end

endmodule
