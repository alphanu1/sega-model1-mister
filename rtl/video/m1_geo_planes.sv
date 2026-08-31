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
// The four frustum plane ratios, from the viewport. model1_v.cpp:629,
// view_t::set_viewport:
//
//     a_left   = ( x1 - xc - viewx) / zoomx
//     a_right  = ( x2 - xc - viewx) / zoomx
//     a_bottom = (-y1 + yc - viewy) / zoomy
//     a_top    = (-y2 + yc - viewy) / zoomy
//
// Eight subtracts and four divides, once per viewport change - which is at most
// once a frame, so about 130 cycles a frame against 818,133. It gets a pool
// client of its own rather than sharing the clipper's, because the two would
// otherwise need a mux for the sake of an operation that happens a thousand
// times less often.
//
// It does NOT get its own divider. fp_div is 29 cycles and does not pipeline,
// and a second one costs more than this whole module.

`timescale 1ns/1ps

module m1_geo_planes (
  input  logic        clk,
  input  logic        rst_n,

  // The viewport, as the display list gives it after m1_raster3d's integer to
  // float conversion and the 422 - word flip on the y edges.
  input  logic [31:0] xc, yc, zoomx, zoomy, viewx, viewy,
  input  logic [31:0] x1, x2, y1, y2,
  input  logic        recompute,          // one pulse when any of them changed

  // Shared arithmetic.
  output logic        add_req,
  output logic [31:0] add_a, add_b,
  output logic        add_sub,
  input  logic        add_gnt, add_rsp,
  input  logic [31:0] add_res,

  output logic        div_req,
  output logic [31:0] div_a, div_b,
  input  logic        div_gnt, div_rsp,
  input  logic [31:0] div_res,

  output logic [31:0] a_left, a_right, a_bottom, a_top,
  output logic        valid                // a full set has been computed
);

  typedef enum logic [2:0] { S_IDLE, S_S1, S_S1W, S_S2, S_S2W, S_DIV, S_DIVW } st_t;
  st_t st;

  logic [1:0]  which;                      // 0 left, 1 right, 2 bottom, 3 top
  logic [31:0] acc;

  // The numerator's first term, and the divisor. bottom and top subtract the
  // edge FROM yc, which is the sign flip in MAME's -y1 + yc.
  wire [31:0] n_a = (which == 2'd0) ? x1 : (which == 2'd1) ? x2 : yc;
  wire [31:0] n_b = (which == 2'd0) ? xc : (which == 2'd1) ? xc :
                    (which == 2'd2) ? y1 : y2;
  wire [31:0] n_v = (which[1]) ? viewy : viewx;
  wire [31:0] n_z = (which[1]) ? zoomy : zoomx;

  always_comb begin
    add_req = 1'b0; add_a = '0; add_b = '0; add_sub = 1'b0;
    div_req = 1'b0; div_a = '0; div_b = '0;
    case (st)
      S_S1:  begin add_req = 1'b1; add_a = n_a; add_b = n_b; add_sub = 1'b1; end
      S_S2:  begin add_req = 1'b1; add_a = acc; add_b = n_v; add_sub = 1'b1; end
      S_DIV: begin div_req = 1'b1; div_a = acc; div_b = n_z; end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; which <= '0; acc <= '0; valid <= 1'b0;
      a_left <= '0; a_right <= '0; a_bottom <= '0; a_top <= '0;
    end else begin
      case (st)
        S_IDLE: if (recompute) begin which <= '0; st <= S_S1; end
        S_S1:   if (add_gnt) st <= S_S1W;
        S_S1W:  if (add_rsp) begin acc <= add_res; st <= S_S2; end
        S_S2:   if (add_gnt) st <= S_S2W;
        S_S2W:  if (add_rsp) begin acc <= add_res; st <= S_DIV; end
        S_DIV:  if (div_gnt) st <= S_DIVW;
        S_DIVW: if (div_rsp) begin
          case (which)
            2'd0:    a_left   <= div_res;
            2'd1:    a_right  <= div_res;
            2'd2:    a_bottom <= div_res;
            default: a_top    <= div_res;
          endcase
          if (which == 2'd3) begin valid <= 1'b1; st <= S_IDLE; end
          else begin which <= which + 2'd1; st <= S_S1; end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
