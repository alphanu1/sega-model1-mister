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
// Reciprocal square root, for normalizing the polygon normal.
//
// WHY THIS EXISTS RATHER THAN A DIVIDE
//
// push_object normalizes the normal of every polygon record (glm::normalize, and
// glm computes it as v * inversesqrt(dot(v,v))). That is a reciprocal square root
// once per record, on top of the two reciprocals projection already needs. fp_div
// is 29 cycles and does not pipeline, so three of them is **87 cycles against a
// budget of 68** - the stage does not fit behind one divider, and there is no
// square root unit to build it out of anyway.
//
// THE PRECISION REQUIREMENT IS LOW, AND IT WAS MEASURED
//
// The normalized normal feeds a dot product, then a specular term, then
//
//     lumval = (255 * min(1, ln)) >> 2, clamped to 0x3f
//
// which is SIX BITS. Over 400,000 random normals against the light parameters
// measured from the real display list, truncating the reciprocal square root's
// mantissa changes that six-bit luminance:
//
//     10 bits   0.776% of polygons, by up to 2 levels
//     12 bits   0.190%, by at most 1
//     16 bits   0.013%, by at most 1
//     23 bits   never
//
// Specular squares its argument up to three times, so it amplifies error
// eightfold and is the path that sets this requirement - the diffuse term alone
// would be satisfied by ten bits. Sixteen is comfortably past it.
//
// SO: an 8-bit seed table and ONE Newton-Raphson step, which reaches ~16 bits.
//
//     y1 = y0 * (1.5 - (x/2) * y0 * y0)
//
// Four multiplies and one subtract on the SHARED pool - about 5 cycles of a
// multiplier that is at 69% - rather than 29 cycles of a divider at 85%. x/2 is
// exact and free: decrement the exponent.
//
// The seed table is 256 entries of 1/sqrt(m) at the MIDPOINT of each interval, so
// the seed error is centred rather than one-sided. Indexed by the exponent's
// parity and the top seven mantissa bits, because 1/sqrt halves the exponent and
// an odd exponent has to fold a factor of two into the mantissa.
//
// Denormal and zero inputs are not handled: dot(v,v) for a polygon normal is a
// normal number, and the project-wide position on denormals is that they are an
// open question (README.md), not something to answer by accident here.

`timescale 1ns/1ps

module m1_geo_rsqrt (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] in_x,

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
  output logic [31:0] out_y
);

  localparam logic [31:0] ONE_HALF_3 = 32'h3fc00000;   // 1.5

  // Seed: 1/sqrt(midpoint) for each (exponent parity, top 7 mantissa bits).
  (* romstyle = "logic" *)
  logic [31:0] seed_rom [256];
  initial begin
    seed_rom = '{
    32'h3f7f8060, 32'h3f7e8358, 32'h3f7d893a, 32'h3f7c91f7,
    32'h3f7b9d83, 32'h3f7aabcf, 32'h3f79bccf, 32'h3f78d075,
    32'h3f77e6b5, 32'h3f76ff83, 32'h3f761ad3, 32'h3f75389a,
    32'h3f7458cd, 32'h3f737b60, 32'h3f72a048, 32'h3f71c77c,
    32'h3f70f0f1, 32'h3f701c9d, 32'h3f6f4a77, 32'h3f6e7a74,
    32'h3f6dac8d, 32'h3f6ce0b7, 32'h3f6c16ea, 32'h3f6b4f1e,
    32'h3f6a8949, 32'h3f69c565, 32'h3f690368, 32'h3f68434a,
    32'h3f678505, 32'h3f66c891, 32'h3f660de5, 32'h3f6554fc,
    32'h3f649dce, 32'h3f63e854, 32'h3f633488, 32'h3f628263,
    32'h3f61d1de, 32'h3f6122f3, 32'h3f60759c, 32'h3f5fc9d4,
    32'h3f5f1f93, 32'h3f5e76d5, 32'h3f5dcf93, 32'h3f5d29c8,
    32'h3f5c856f, 32'h3f5be282, 32'h3f5b40fd, 32'h3f5aa0d9,
    32'h3f5a0212, 32'h3f5964a3, 32'h3f58c887, 32'h3f582dba,
    32'h3f579436, 32'h3f56fbf8, 32'h3f5664fa, 32'h3f55cf39,
    32'h3f553ab0, 32'h3f54a75a, 32'h3f541535, 32'h3f53843b,
    32'h3f52f469, 32'h3f5265bb, 32'h3f51d82d, 32'h3f514bbb,
    32'h3f50c062, 32'h3f50361d, 32'h3f4facea, 32'h3f4f24c5,
    32'h3f4e9daa, 32'h3f4e1796, 32'h3f4d9285, 32'h3f4d0e76,
    32'h3f4c8b63, 32'h3f4c094b, 32'h3f4b8829, 32'h3f4b07fc,
    32'h3f4a88bf, 32'h3f4a0a71, 32'h3f498d0d, 32'h3f491092,
    32'h3f4894fd, 32'h3f481a4a, 32'h3f47a078, 32'h3f472783,
    32'h3f46af68, 32'h3f463826, 32'h3f45c1ba, 32'h3f454c21,
    32'h3f44d759, 32'h3f44635f, 32'h3f43f031, 32'h3f437dcd,
    32'h3f430c31, 32'h3f429b59, 32'h3f422b45, 32'h3f41bbf1,
    32'h3f414d5c, 32'h3f40df84, 32'h3f407266, 32'h3f400600,
    32'h3f3f9a51, 32'h3f3f2f56, 32'h3f3ec50e, 32'h3f3e5b76,
    32'h3f3df28c, 32'h3f3d8a4f, 32'h3f3d22be, 32'h3f3cbbd5,
    32'h3f3c5593, 32'h3f3beff7, 32'h3f3b8aff, 32'h3f3b26a9,
    32'h3f3ac2f3, 32'h3f3a5fdc, 32'h3f39fd62, 32'h3f399b84,
    32'h3f393a3f, 32'h3f38d993, 32'h3f38797d, 32'h3f3819fd,
    32'h3f37bb10, 32'h3f375cb5, 32'h3f36feec, 32'h3f36a1b1,
    32'h3f364505, 32'h3f35e8e5, 32'h3f358d50, 32'h3f353245,
    32'h3f34aab4, 32'h3f33f7c9, 32'h3f3346ed, 32'h3f329816,
    32'h3f31eb3b, 32'h3f314052, 32'h3f309752, 32'h3f2ff032,
    32'h3f2f4ae9, 32'h3f2ea76e, 32'h3f2e05ba, 32'h3f2d65c3,
    32'h3f2cc782, 32'h3f2c2af0, 32'h3f2b9004, 32'h3f2af6b7,
    32'h3f2a5f03, 32'h3f29c8e0, 32'h3f293446, 32'h3f28a131,
    32'h3f280f98, 32'h3f277f76, 32'h3f26f0c4, 32'h3f26637d,
    32'h3f25d79a, 32'h3f254d15, 32'h3f24c3ea, 32'h3f243c11,
    32'h3f23b587, 32'h3f233045, 32'h3f22ac46, 32'h3f222985,
    32'h3f21a7fe, 32'h3f2127ac, 32'h3f20a889, 32'h3f202a91,
    32'h3f1fadc0, 32'h3f1f3210, 32'h3f1eb77f, 32'h3f1e3e06,
    32'h3f1dc5a3, 32'h3f1d4e52, 32'h3f1cd80d, 32'h3f1c62d1,
    32'h3f1bee9b, 32'h3f1b7b67, 32'h3f1b0930, 32'h3f1a97f3,
    32'h3f1a27ae, 32'h3f19b85b, 32'h3f1949f8, 32'h3f18dc82,
    32'h3f186ff5, 32'h3f18044e, 32'h3f17998a, 32'h3f172fa5,
    32'h3f16c69e, 32'h3f165e70, 32'h3f15f718, 32'h3f159095,
    32'h3f152ae3, 32'h3f14c5ff, 32'h3f1461e7, 32'h3f13fe97,
    32'h3f139c0e, 32'h3f133a49, 32'h3f12d945, 32'h3f127900,
    32'h3f121978, 32'h3f11baa9, 32'h3f115c92, 32'h3f10ff30,
    32'h3f10a281, 32'h3f104684, 32'h3f0feb35, 32'h3f0f9092,
    32'h3f0f369a, 32'h3f0edd4a, 32'h3f0e84a0, 32'h3f0e2c9b,
    32'h3f0dd538, 32'h3f0d7e75, 32'h3f0d2851, 32'h3f0cd2c9,
    32'h3f0c7ddc, 32'h3f0c2988, 32'h3f0bd5cb, 32'h3f0b82a4,
    32'h3f0b3010, 32'h3f0ade0e, 32'h3f0a8c9d, 32'h3f0a3bba,
    32'h3f09eb64, 32'h3f099b9a, 32'h3f094c59, 32'h3f08fda1,
    32'h3f08af6f, 32'h3f0861c3, 32'h3f08149b, 32'h3f07c7f5,
    32'h3f077bd0, 32'h3f07302a, 32'h3f06e503, 32'h3f069a58,
    32'h3f065029, 32'h3f060674, 32'h3f05bd38, 32'h3f057474,
    32'h3f052c25, 32'h3f04e44c, 32'h3f049ce7, 32'h3f0455f4,
    32'h3f040f72, 32'h3f03c961, 32'h3f0383bf, 32'h3f033e8b,
    32'h3f02f9c3, 32'h3f02b568, 32'h3f027176, 32'h3f022def,
    32'h3f01ead0, 32'h3f01a818, 32'h3f0165c6, 32'h3f0123da,
    32'h3f00e253, 32'h3f00a12e, 32'h3f00606d, 32'h3f00200c    };
  end

  // ---------------------------------------------------------------- decode
  //
  // The input is LATCHED on accept and everything is derived from the latch. The
  // first draft indexed the ROM straight off in_x, which is only meaningful in
  // the cycle the request is accepted - a caller that drops its operands the
  // moment in_ready falls would get a seed for whatever was on the bus next.
  logic [31:0] xr;

  wire [7:0]  x_exp  = xr[30:23];
  wire [22:0] x_mant = xr[22:0];

  // PARITY OF THE UNBIASED EXPONENT, WHICH IS NOT x_exp[0].
  //
  // 1/sqrt halves the exponent, so an odd one has to fold a factor of two into
  // the mantissa, and that is what the table's parity bit selects. The exponent
  // that matters is E = x_exp - 127, and 127 is ODD, so parity(E) is the
  // INVERSE of x_exp[0]. Using x_exp[0] directly picks the wrong half of the
  // table and mis-halves the exponent, which lands a factor of sqrt(2) out - and
  // Newton-Raphson then converges neatly onto the wrong answer, so the result
  // looks well-formed and is 29% wrong at every magnitude.
  wire        e_odd  = ~x_exp[0];
  wire [7:0]  seed_idx = {e_odd, x_mant[22:16]};

  // The table holds 1/sqrt(m) for m in [1,4), so its own exponent is already
  // right for a unit input; 2^(-E/2) is applied on top.
  wire signed [9:0] e_unb = $signed({2'b0, x_exp}) - 10'sd127;
  wire signed [9:0] e_hlf = e_odd ? ((e_unb - 10'sd1) >>> 1) : (e_unb >>> 1);

  logic [31:0] seed_raw;
  logic signed [9:0] e_hlf_q;
  always_ff @(posedge clk) begin
    seed_raw <= seed_rom[seed_idx];
    e_hlf_q  <= e_hlf;
  end

  // Fold the -E/2 scaling into the seed's exponent.
  wire signed [9:0] seed_e = $signed({2'b0, seed_raw[30:23]}) - e_hlf_q;
  wire [31:0] seed = {seed_raw[31], seed_e[7:0], seed_raw[22:0]};

  // x/2 is exact: one less on the exponent.
  logic [31:0] xh;

  // ---------------------------------------------------------------- sequence
  //
  // Every step depends on the one before it - y2 feeds t, t feeds h, h feeds y1 -
  // so each is issued and then WAITED for. There is nothing to overlap within one
  // reciprocal square root, and it runs once per polygon record against a budget
  // of 68 cycles, so the serial form is both correct and sufficient. Issuing the
  // next step on the grant of the previous one, which is what the first draft
  // did, multiplies by a stale operand: the grant means "accepted", not "done".
  typedef enum logic [3:0] {
    R_IDLE, R_SEED, R_SEED2,
    R_Y2_I, R_Y2_W, R_T_I, R_T_W, R_H_I, R_H_W, R_Y1_I, R_Y1_W, R_OUT
  } state_t;
  state_t st;

  logic [31:0] y0, y2, tt, hh;

  assign in_ready = (st == R_IDLE);

  always_comb begin
    mul_req = 1'b0; mul_a = '0; mul_b = '0;
    add_req = 1'b0; add_a = '0; add_b = '0; add_sub = 1'b0;
    case (st)
      R_Y2_I: begin mul_req = 1'b1; mul_a = y0; mul_b = y0; end
      R_T_I:  begin mul_req = 1'b1; mul_a = xh; mul_b = y2; end
      R_H_I:  begin add_req = 1'b1; add_a = ONE_HALF_3; add_b = tt; add_sub = 1'b1; end
      R_Y1_I: begin mul_req = 1'b1; mul_a = y0; mul_b = hh; end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= R_IDLE; y0 <= '0; y2 <= '0; tt <= '0; hh <= '0;
      xh <= '0; xr <= '0; out_valid <= 1'b0; out_y <= '0;
    end else begin
      out_valid <= 1'b0;
      case (st)
        R_IDLE: begin
          if (in_valid) begin
            xr <= in_x;
            // x/2, by decrementing the exponent. The input is a sum of squares
            // and cannot be zero for a real normal, so no guard here.
            xh <= {in_x[31], in_x[30:23] - 8'd1, in_x[22:0]};
            st <= R_SEED;
          end
        end
        // Three cycles now: xr is latched on accept, the ROM read and the
        // exponent halving are registered off xr, and the scaled seed is
        // combinational on top of those.
        R_SEED:  st <= R_SEED2;
        R_SEED2: begin y0 <= seed; st <= R_Y2_I; end

        R_Y2_I: if (mul_gnt) st <= R_Y2_W;
        R_Y2_W: if (mul_rsp) begin y2 <= mul_res; st <= R_T_I; end
        R_T_I:  if (mul_gnt) st <= R_T_W;
        R_T_W:  if (mul_rsp) begin tt <= mul_res; st <= R_H_I; end
        R_H_I:  if (add_gnt) st <= R_H_W;
        R_H_W:  if (add_rsp) begin hh <= add_res; st <= R_Y1_I; end
        R_Y1_I: if (mul_gnt) st <= R_Y1_W;
        R_Y1_W: if (mul_rsp) begin
                  out_y     <= mul_res;
                  out_valid <= 1'b1;
                  st        <= R_IDLE;
                end
        default: st <= R_IDLE;
      endcase
    end
  end

endmodule
