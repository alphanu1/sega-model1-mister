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
// Normalize a vector: glm::normalize, as push_object applies it to the polygon
// normal before lighting (model1_v.cpp:1013).
//
//     v * inversesqrt(dot(v, v))
//
// which is glm's own formulation - a reciprocal square root and three multiplies,
// NOT a square root and three divides. Following glm here matters because it is
// what MAME evaluates: the two differ in the last place, and the last place is
// the only thing that can differ at all once m1_geo_rsqrt's accuracy is settled.
//
// The dot product's three squares are issued back to back - they are independent,
// and a multiplier that retires one a cycle should not be asked once every fifth.
// The two sums are left to right, as C evaluates `x*x + y*y + z*z`.
//
// A ZERO-LENGTH VECTOR IS PASSED THROUGH UNCHANGED rather than producing
// infinities. MAME would divide by zero here and glm would return a vector of
// NaNs, which then makes the whole lighting term NaN and the luminance zero via
// fp_to_int's indefinite - so the visible result is a black polygon either way,
// and passing the vector through avoids feeding NaNs into the shared pool where
// they cost nothing but confuse every trace that looks at it. Recorded as a
// deliberate difference; no real polygon normal is zero.

`timescale 1ns/1ps

module m1_geo_norm (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] in_x, in_y, in_z,

  // Shared arithmetic - see rtl/video/m1_fp_pool.sv. The reciprocal square root
  // sits behind this module and uses the same ports, arbitrated here.
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

  output logic        out_valid,
  output logic [31:0] out_x, out_y, out_z
);

  typedef enum logic [3:0] {
    N_IDLE, N_SQ_I, N_SQ_W, N_A0_I, N_A0_W, N_A1_I, N_A1_W,
    N_RS_I, N_RS_W, N_MU_I, N_MU_W, N_OUT
  } state_t;
  state_t st;

  logic [31:0] vx, vy, vz;
  logic [31:0] s0, s1, s2, len2, inv;
  logic [31:0] ox, oy, oz;
  logic [1:0]  sq_i, sq_n, mu_i, mu_n;

  // ---------------------------------------------------------------- rsqrt
  logic        rs_in_valid, rs_in_ready, rs_out_valid;
  logic [31:0] rs_out;

  m1_geo_rsqrt u_rsqrt (
    .clk(clk), .rst_n(rst_n),
    .in_valid(rs_in_valid), .in_ready(rs_in_ready), .in_x(len2),
    .out_valid(rs_out_valid), .out_y(rs_out)
  );

  // The rsqrt used to take the pool ports away from this module while it ran -
  // it needed four multiplies and a subtract from the shared units. It is a
  // self-contained DSP pipeline as of 2026-09-08, so this module owns the pool
  // outright and its own multiplies no longer stop while a normal is being
  // normalised.
  logic        my_mul_req, my_add_req, my_add_sub;
  logic [31:0] my_mul_a, my_mul_b, my_add_a, my_add_b;

  assign mul_req = my_mul_req;
  assign mul_a   = my_mul_a;
  assign mul_b   = my_mul_b;
  assign add_req = my_add_req;
  assign add_a   = my_add_a;
  assign add_b   = my_add_b;
  assign add_sub = my_add_sub;

  wire my_mul_gnt = mul_gnt;
  wire my_mul_rsp = mul_rsp;
  wire my_add_gnt = add_gnt;
  wire my_add_rsp = add_rsp;

  assign in_ready = (st == N_IDLE);

  // A zero-length vector: pass through rather than divide by it.
  wire len2_zero = (len2[30:0] == 31'd0);

  always_comb begin
    my_mul_req = 1'b0; my_mul_a = '0; my_mul_b = '0;
    my_add_req = 1'b0; my_add_a = '0; my_add_b = '0; my_add_sub = 1'b0;
    case (st)
      N_SQ_I: begin
        my_mul_req = 1'b1;
        my_mul_a = (sq_i == 2'd0) ? vx : (sq_i == 2'd1) ? vy : vz;
        my_mul_b = my_mul_a;
      end
      N_A0_I: begin my_add_req = 1'b1; my_add_a = s0;   my_add_b = s1; end
      N_A1_I: begin my_add_req = 1'b1; my_add_a = len2; my_add_b = s2; end
      N_MU_I: begin
        my_mul_req = 1'b1;
        my_mul_a = (mu_i == 2'd0) ? vx : (mu_i == 2'd1) ? vy : vz;
        my_mul_b = inv;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= N_IDLE;
      vx <= '0; vy <= '0; vz <= '0;
      s0 <= '0; s1 <= '0; s2 <= '0; len2 <= '0; inv <= '0;
      ox <= '0; oy <= '0; oz <= '0;
      sq_i <= '0; sq_n <= '0; mu_i <= '0; mu_n <= '0;
      rs_in_valid <= 1'b0;
      out_valid <= 1'b0; out_x <= '0; out_y <= '0; out_z <= '0;
    end else begin
      out_valid   <= 1'b0;
      rs_in_valid <= 1'b0;

      // The three squares come back in issue order.
      if ((st == N_SQ_I || st == N_SQ_W) && my_mul_rsp) begin
        case (sq_n)
          2'd0: s0 <= mul_res;
          2'd1: s1 <= mul_res;
          default: s2 <= mul_res;
        endcase
        sq_n <= sq_n + 2'd1;
      end
      // ...and so do the three scalings.
      if ((st == N_MU_I || st == N_MU_W) && my_mul_rsp) begin
        case (mu_n)
          2'd0: ox <= mul_res;
          2'd1: oy <= mul_res;
          default: oz <= mul_res;
        endcase
        mu_n <= mu_n + 2'd1;
      end

      case (st)
        N_IDLE: if (in_valid) begin
          vx <= in_x; vy <= in_y; vz <= in_z;
          sq_i <= '0; sq_n <= '0; mu_i <= '0; mu_n <= '0;
          st <= N_SQ_I;
        end

        N_SQ_I: if (my_mul_gnt) begin
          if (sq_i == 2'd2) st <= N_SQ_W;
          else              sq_i <= sq_i + 2'd1;
        end
        N_SQ_W: if (sq_n == 2'd2 && my_mul_rsp) st <= N_A0_I;

        N_A0_I: if (my_add_gnt) st <= N_A0_W;
        N_A0_W: if (my_add_rsp) begin len2 <= add_res; st <= N_A1_I; end
        N_A1_I: if (my_add_gnt) st <= N_A1_W;
        N_A1_W: if (my_add_rsp) begin
          len2 <= add_res;
          st   <= N_RS_I;
        end

        N_RS_I: begin
          if (len2_zero) begin
            // Pass the vector through untouched.
            ox <= vx; oy <= vy; oz <= vz;
            st <= N_OUT;
          end else if (rs_in_ready) begin
            rs_in_valid <= 1'b1;
            st          <= N_RS_W;
          end
        end
        N_RS_W: if (rs_out_valid) begin inv <= rs_out; st <= N_MU_I; end

        N_MU_I: if (my_mul_gnt) begin
          if (mu_i == 2'd2) st <= N_MU_W;
          else              mu_i <= mu_i + 2'd1;
        end
        N_MU_W: if (mu_n == 2'd2 && my_mul_rsp) st <= N_OUT;

        N_OUT: begin
          out_x <= ox; out_y <= oy; out_z <= oz;
          out_valid <= 1'b1;
          st <= N_IDLE;
        end
        default: st <= N_IDLE;
      endcase
    end
  end

endmodule
