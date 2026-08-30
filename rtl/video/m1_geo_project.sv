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

  output logic        out_valid,
  output logic signed [31:0] out_sx, out_sy,   // pixels
  output logic [31:0] out_z,                   // passed through, for the sort
  output logic        out_behind                // z <= 0: the (0,0) case
);

  // ------------------------------------------------------------ reciprocal
  typedef enum logic [1:0] { R_IDLE, R_BUSY, R_FULL } rstate_t;
  rstate_t rst_st;

  logic [31:0] rx, ry, rz, recip;
  logic        r_behind;

  logic        div_in_valid, div_busy, div_out_valid;
  logic [31:0] div_result;
  logic        div_ovf, div_unf, div_dz, div_inv;

  localparam logic [31:0] ONE = 32'h3f800000;

  fp_div u_div (
    .clk(clk), .rst_n(rst_n),
    .in_valid(div_in_valid), .a(ONE), .b(rz),
    .busy(div_busy), .out_valid(div_out_valid), .result(div_result),
    .overflow(div_ovf), .underflow(div_unf),
    .div_by_zero(div_dz), .invalid(div_inv)
  );

  // z > 0 means positive, nonzero and not a NaN. A NaN compares false against
  // everything in C, so `z > 0` is false for it and MAME takes the behind path -
  // reproduced by testing the sign bit AND that the value is not zero or NaN.
  wire z_is_nan  = (in_z[30:23] == 8'hff) && (in_z[22:0] != 23'd0);
  wire z_is_zero = (in_z[30:0] == 31'd0);
  wire z_pos     = !in_z[31] && !z_is_zero && !z_is_nan;

  logic div_started;
  assign div_in_valid = (rst_st == R_BUSY) && !div_busy && !div_started && !r_behind;

  // ------------------------------------------------------------ scale stage
  typedef enum logic [2:0] { S_IDLE, S_M0, S_M1, S_A0, S_A1, S_OUT } sstate_t;
  sstate_t sst;

  logic [31:0] sx_f, sy_f, sxx, syy, sr, sx_in, sy_in;
  logic        s_behind;
  logic [31:0] s_z;
  logic [2:0]  step;
  logic [1:0]  n_got;

  logic        mul_in_valid, mul_out_valid;
  logic [31:0] mul_a, mul_b, mul_result;
  logic        mul_ovf, mul_unf, mul_inv;

  fp_mul u_mul (
    .clk(clk), .rst_n(rst_n),
    .in_valid(mul_in_valid), .a(mul_a), .b(mul_b),
    .out_valid(mul_out_valid), .result(mul_result),
    .overflow(mul_ovf), .underflow(mul_unf), .invalid(mul_inv)
  );

  logic        add_in_valid, add_out_valid, add_sub;
  logic [31:0] add_a, add_b, add_result;
  logic        add_ovf, add_unf, add_inv;

  fp_add u_add (
    .clk(clk), .rst_n(rst_n),
    .in_valid(add_in_valid), .a(add_a), .b(add_b), .sub(add_sub),
    .out_valid(add_out_valid), .result(add_result),
    .overflow(add_ovf), .underflow(add_unf), .invalid(add_inv)
  );

  // Two converters, not one muxed between the coordinates: the conversion is a
  // shift and a negate, so a second instance is cheaper than the state it would
  // take to reuse the first, and muxing one between sx_f and sy_f is how the
  // first version of this module ended up never assigning out_sy at all.
  logic signed [31:0] sx_i, sy_i;
  fp_to_int u_f2i_x (.f(sx_f), .i(sx_i));
  fp_to_int u_f2i_y (.f(sy_f), .i(sy_i));

  wire unused_flags = &{1'b0, mul_ovf, mul_unf, mul_inv, add_ovf, add_unf,
                        add_inv, div_ovf, div_unf, div_dz, div_inv};

  assign in_ready = (rst_st == R_IDLE);

  // Two multiplies then two multiplies, then two adds then two adds. Each pair
  // is issued back to back and collected before the next, which costs the FP
  // latency three times over - 19 cycles - and is still well inside the 29 the
  // reciprocal takes, so tightening it would buy nothing.
  always_comb begin
    mul_in_valid = 1'b0; mul_a = '0; mul_b = '0;
    add_in_valid = 1'b0; add_a = '0; add_b = '0; add_sub = 1'b0;
    case (sst)
      S_M0: begin                       // xx = x*r, yy = y*r
        mul_in_valid = (step < 3'd2);
        mul_a = (step == 3'd0) ? sx_in : sy_in;
        mul_b = sr;
      end
      S_M1: begin                       // ax = xx*zoomx, ay = yy*zoomy
        mul_in_valid = (step < 3'd2);
        mul_a = (step == 3'd0) ? sxx : syy;
        mul_b = (step == 3'd0) ? zoomx : zoomy;
      end
      S_A0: begin                       // bx = ax+viewx, by = ay+viewy
        add_in_valid = (step < 3'd2);
        add_a = (step == 3'd0) ? sxx : syy;
        add_b = (step == 3'd0) ? viewx : viewy;
      end
      S_A1: begin                       // sx = xc+bx, sy = yc-by
        add_in_valid = (step < 3'd2);
        add_a = (step == 3'd0) ? xc : yc;
        add_b = (step == 3'd0) ? sxx : syy;
        add_sub = (step == 3'd1);       // yc MINUS, the screen y axis is flipped
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rst_st <= R_IDLE; sst <= S_IDLE;
      rx <= '0; ry <= '0; rz <= '0; recip <= '0; r_behind <= 1'b0;
      div_started <= 1'b0;
      sx_in <= '0; sy_in <= '0; sr <= '0; sxx <= '0; syy <= '0;
      sx_f <= '0; sy_f <= '0; s_behind <= 1'b0; s_z <= '0;
      step <= '0; n_got <= '0;
      out_valid <= 1'b0; out_sx <= '0; out_sy <= '0; out_z <= '0;
      out_behind <= 1'b0;
    end else begin
      out_valid <= 1'b0;

      // ---------------------------------------------------- reciprocal stage
      case (rst_st)
        R_IDLE: begin
          if (in_valid) begin
            rx <= in_x; ry <= in_y; rz <= in_z;
            r_behind    <= !z_pos;
            div_started <= 1'b0;
            rst_st      <= R_BUSY;
          end
        end
        R_BUSY: begin
          if (div_in_valid) div_started <= 1'b1;
          if (r_behind) begin
            // No divide at all for a point behind the eye: MAME does not call
            // project_point, it assigns zero. Spending 29 cycles to compute a
            // number that is then discarded would halve the throughput on a
            // frame full of back-facing geometry.
            recip  <= '0;
            rst_st <= R_FULL;
          end else if (div_out_valid) begin
            recip  <= div_result;
            rst_st <= R_FULL;
          end
        end
        R_FULL: begin
          if (sst == S_IDLE) rst_st <= R_IDLE;
        end
        default: rst_st <= R_IDLE;
      endcase

      // ---------------------------------------------------- scale stage
      case (sst)
        S_IDLE: begin
          if (rst_st == R_FULL) begin
            sx_in <= rx; sy_in <= ry; s_z <= rz;
            sr <= recip; s_behind <= r_behind;
            step <= '0; n_got <= '0;
            sst  <= r_behind ? S_OUT : S_M0;
          end
        end

        S_M0, S_M1: begin
          if (step < 3'd2) step <= step + 3'd1;
          if (mul_out_valid) begin
            if (n_got == 2'd0) sxx <= mul_result;
            else               syy <= mul_result;
            n_got <= n_got + 2'd1;
            if (n_got == 2'd1) begin
              step  <= '0;
              n_got <= '0;
              sst   <= (sst == S_M0) ? S_M1 : S_A0;
            end
          end
        end

        S_A0, S_A1: begin
          if (step < 3'd2) step <= step + 3'd1;
          if (add_out_valid) begin
            if (n_got == 2'd0) begin
              if (sst == S_A0) sxx <= add_result; else sx_f <= add_result;
            end else begin
              if (sst == S_A0) syy <= add_result; else sy_f <= add_result;
            end
            n_got <= n_got + 2'd1;
            if (n_got == 2'd1) begin
              step  <= '0;
              n_got <= '0;
              sst   <= (sst == S_A0) ? S_A1 : S_OUT;
            end
          end
        end

        S_OUT: begin
          // Behind the eye is a literal (0,0), as MAME assigns - not a converted
          // one, because the float chain was never run for it.
          out_sx     <= s_behind ? 32'sd0 : sx_i;
          out_sy     <= s_behind ? 32'sd0 : sy_i;
          out_z      <= s_z;
          out_behind <= s_behind;
          out_valid  <= 1'b1;
          sst        <= S_IDLE;
        end

        default: sst <= S_IDLE;
      endcase
    end
  end

endmodule
