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
// The backface test: view_determinant (model1_v.cpp:68).
//
//     x1 = p2.x - p1.x;  y1 = p2.y - p1.y;  z1 = p2.z - p1.z;
//     x2 = p3.x - p1.x;  y2 = p3.y - p1.y;  z2 = p3.z - p1.z;
//     det = p1.x*(y1*z2 - y2*z1) + p1.y*(z1*x2 - z2*x1) + p1.z*(x1*y2 - x2*y1);
//
// push_object culls on `!(flags & 0x4000) && view_determinant(...) > 0` (:1017),
// so this decides whether a polygon is drawn at all. It runs on the TRANSFORMED
// points, in camera space, not on the model's own coordinates.
//
// It is a scalar triple product - the signed volume of the parallelepiped on the
// three vectors - and its sign is which way the face turns relative to the eye.
// Written out as MAME writes it rather than refactored into a cross product and a
// dot, because the association is what fixes the last bit: `A + B + C` is
// `(A + B) + C` in C, and the six differences are formed BEFORE the products, not
// folded into them.
//
// STRICTLY GREATER THAN ZERO. A determinant of exactly zero is an edge-on polygon
// and MAME draws it. `>= 0` would cull a thin sliver of geometry that the
// reference keeps, which is invisible on a still frame and flickers in motion.

`timescale 1ns/1ps

module m1_geo_det (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] p1x, p1y, p1z,
  input  logic [31:0] p2x, p2y, p2z,
  input  logic [31:0] p3x, p3y, p3z,

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

  output logic        out_valid,
  output logic [31:0] out_det,
  output logic        out_positive     // det > 0: the culling condition
);

  typedef enum logic [2:0] {
    D_IDLE, D_SUB1, D_MUL1, D_SUB2, D_MUL2, D_ADD1, D_ADD2, D_OUT
  } state_t;
  state_t st;

  logic [31:0] a1x, a1y, a1z, a2x, a2y, a2z, a3x, a3y, a3z;
  logic [31:0] d [6];      // x1 y1 z1 x2 y2 z2
  logic [31:0] m [6];      // the six cross-product terms
  logic [31:0] c [3];      // the three cofactors
  logic [31:0] t [3];      // p1.* times each cofactor
  logic [31:0] acc;
  logic [2:0]  step;
  logic [2:0]  ngot;

  // ---------------------------------------------------------------- units
  wire        mul_out_valid = mul_rsp;
  wire [31:0] mul_result    = mul_res;
  wire        add_out_valid = add_rsp;
  wire [31:0] add_result    = add_res;

  // ---------------------------------------------------------------- operands
  // The six differences, in MAME's order: x1 y1 z1 x2 y2 z2.
  logic [31:0] sub1_a, sub1_b;
  always_comb begin
    case (step)
      3'd0: begin sub1_a = a2x; sub1_b = a1x; end
      3'd1: begin sub1_a = a2y; sub1_b = a1y; end
      3'd2: begin sub1_a = a2z; sub1_b = a1z; end
      3'd3: begin sub1_a = a3x; sub1_b = a1x; end
      3'd4: begin sub1_a = a3y; sub1_b = a1y; end
      default: begin sub1_a = a3z; sub1_b = a1z; end
    endcase
  end

  // y1*z2, y2*z1, z1*x2, z2*x1, x1*y2, x2*y1
  // indices into d:  x1=0 y1=1 z1=2 x2=3 y2=4 z2=5
  logic [31:0] mul1_a, mul1_b;
  always_comb begin
    case (step)
      3'd0: begin mul1_a = d[1]; mul1_b = d[5]; end   // y1*z2
      3'd1: begin mul1_a = d[4]; mul1_b = d[2]; end   // y2*z1
      3'd2: begin mul1_a = d[2]; mul1_b = d[3]; end   // z1*x2
      3'd3: begin mul1_a = d[5]; mul1_b = d[0]; end   // z2*x1
      3'd4: begin mul1_a = d[0]; mul1_b = d[4]; end   // x1*y2
      default: begin mul1_a = d[3]; mul1_b = d[1]; end // x2*y1
    endcase
  end

  logic [31:0] p1c [3];
  assign p1c[0] = a1x;
  assign p1c[1] = a1y;
  assign p1c[2] = a1z;

  always_comb begin
    mul_req = 1'b0; mul_a = '0; mul_b = '0;
    add_req = 1'b0; add_a = '0; add_b = '0; add_sub = 1'b0;
    case (st)
      D_SUB1: begin
        add_req = (step < 3'd6);
        add_a = sub1_a; add_b = sub1_b; add_sub = 1'b1;
      end
      D_MUL1: begin
        mul_req = (step < 3'd6);
        mul_a = mul1_a; mul_b = mul1_b;
      end
      D_SUB2: begin
        // a = m0-m1, b = m2-m3, c = m4-m5
        add_req = (step < 3'd3);
        add_a = m[{1'b0, step[1:0]} << 1];
        add_b = m[({1'b0, step[1:0]} << 1) + 3'd1];
        add_sub = 1'b1;
      end
      D_MUL2: begin
        mul_req = (step < 3'd3);
        mul_a = p1c[step[1:0]];
        mul_b = c[step[1:0]];
      end
      D_ADD1: begin
        add_req = (step == 3'd0);
        add_a = t[0]; add_b = t[1];
      end
      D_ADD2: begin
        add_req = (step == 3'd0);
        add_a = acc; add_b = t[2];
      end
      default: ;
    endcase
  end

  assign in_ready = (st == D_IDLE);

  // det > 0 as IEEE compares it: positive sign, and not a zero, and not a NaN.
  wire det_nan  = (out_det[30:23] == 8'hff) && (out_det[22:0] != 23'd0);
  wire det_zero = (out_det[30:0] == 31'd0);
  assign out_positive = !out_det[31] && !det_zero && !det_nan;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= D_IDLE; step <= '0; ngot <= '0; acc <= '0;
      a1x <= '0; a1y <= '0; a1z <= '0;
      a2x <= '0; a2y <= '0; a2z <= '0;
      a3x <= '0; a3y <= '0; a3z <= '0;
      for (int i = 0; i < 6; i++) begin d[i] <= '0; m[i] <= '0; end
      for (int i = 0; i < 3; i++) begin c[i] <= '0; t[i] <= '0; end
      out_valid <= 1'b0; out_det <= '0;
    end else begin
      out_valid <= 1'b0;

      // Results land in issue order, so a counter places them.
      if (add_out_valid) begin
        case (st)
          D_SUB1, D_MUL1: d[ngot] <= add_result;     // still collecting phase 1
          D_SUB2, D_MUL2: c[ngot[1:0]] <= add_result;
          D_ADD1, D_ADD2: acc <= add_result;
          default: ;
        endcase
        ngot <= ngot + 3'd1;
      end
      if (mul_out_valid) begin
        case (st)
          D_MUL1, D_SUB2: m[ngot] <= mul_result;
          D_MUL2, D_ADD1: t[ngot[1:0]] <= mul_result;
          default: ;
        endcase
        ngot <= ngot + 3'd1;
      end

      case (st)
        D_IDLE: begin
          if (in_valid) begin
            a1x <= p1x; a1y <= p1y; a1z <= p1z;
            a2x <= p2x; a2y <= p2y; a2z <= p2z;
            a3x <= p3x; a3y <= p3y; a3z <= p3z;
            step <= '0; ngot <= '0;
            st   <= D_SUB1;
          end
        end
        D_SUB1: begin
          if (step < 3'd6 && add_gnt) step <= step + 3'd1;
          if (ngot == 3'd5 && add_out_valid) begin step <= '0; ngot <= '0; st <= D_MUL1; end
        end
        D_MUL1: begin
          if (step < 3'd6 && mul_gnt) step <= step + 3'd1;
          if (ngot == 3'd5 && mul_out_valid) begin step <= '0; ngot <= '0; st <= D_SUB2; end
        end
        D_SUB2: begin
          if (step < 3'd3 && add_gnt) step <= step + 3'd1;
          if (ngot == 3'd2 && add_out_valid) begin step <= '0; ngot <= '0; st <= D_MUL2; end
        end
        D_MUL2: begin
          if (step < 3'd3 && mul_gnt) step <= step + 3'd1;
          if (ngot == 3'd2 && mul_out_valid) begin step <= '0; ngot <= '0; st <= D_ADD1; end
        end
        D_ADD1: begin
          if (step < 3'd1 && add_gnt) step <= step + 3'd1;
          if (add_out_valid) begin step <= '0; ngot <= '0; st <= D_ADD2; end
        end
        D_ADD2: begin
          if (step < 3'd1 && add_gnt) step <= step + 3'd1;
          if (add_out_valid) begin
            out_det   <= add_result;
            step <= '0; ngot <= '0;
            st   <= D_OUT;
          end
        end
        D_OUT: begin
          out_valid <= 1'b1;
          st        <= D_IDLE;
        end
        default: st <= D_IDLE;
      endcase
    end
  end

endmodule
