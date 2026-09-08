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
  output logic        valid,               // a full set has been computed
  // Recompute requests that arrived while a set was in flight. Non-zero means
  // this module was asked to redo the planes mid-set, which before the `pend`
  // flag below was silently dropped. Reported as `q` on the UART.
  output logic [15:0] dbg_redo,
  // A RECOMPUTE IS IN FLIGHT, so the four planes are a mix of old and new.
  //
  // The planes are computed ONE AT A TIME - each is two adds and a divide from
  // the shared FP pool, so a full set is 172 cycles with the pool to itself
  // (measured, tb_m1_geo_planes) and considerably longer in the design, where
  // six other clients contend for it - and each is written as it finishes. For that whole window a_left may be the
  // new viewport's while a_right is still the previous one's.
  //
  // `valid` was meant to cover this and could not: it is set once, when the
  // first set completes, and is never cleared, so it says "a set has been
  // computed at some point" rather than "these are current". It was also wired
  // to nothing at all in m1_geometry - declared, connected, and never read - so
  // the clipper has always clipped against whatever the planes happened to hold.
  //
  // This one says what the consumer actually needs to know. Gating on it rather
  // than on `valid` also cannot deadlock: a display list that never sets a
  // viewport leaves the planes at their reset zeros, which is wrong, but it
  // does not stall the geometry waiting for a command that never comes.
  output logic        busy
);

  typedef enum logic [2:0] { S_IDLE, S_S1, S_S1W, S_S2, S_S2W, S_DIV, S_DIVW } st_t;

  // A RECOMPUTE ARRIVING MID-SET USED TO BE LOST.
  //
  // `recompute` is a ONE-CYCLE pulse and it was only ever sampled in S_IDLE, but
  // a full set is four planes of two adds and a divide, each a shared-pool round
  // trip - on the order of a thousand cycles. The frustum follows THREE display
  // list commands (viewport 0x03, zoom 0x09, view translation 0x0c) and the game
  // sends them together, so the second and third routinely land while the first
  // is still being computed. Those pulses were dropped.
  //
  // Worse, the operands below are COMBINATIONAL on the live registers, so the
  // in-flight set is computed from a MIX - a numerator from the old viewport and
  // a divisor from the new one - and then never recomputed, because the request
  // that would have fixed it was the pulse that was thrown away. The wrong plane
  // then LATCHES until some later command happens to arrive while this is idle.
  //
  // Measured on the board, 2026-09-08: a_left reads -0.0571 during the left-side
  // cut against -0.8828 healthy, which with the capture's own xc=248 zoomx=280
  // viewx=0 puts the left clip at screen x=232 of 496 - the 47% vertical cut.
  // Same viewport input in both states, so it was never the game asking for a
  // different frustum. See docs/findings.md.
  //
  // `pend` makes the request sticky: a pulse in ANY state is remembered, and the
  // whole set is redone when the current one finishes. The last command in a
  // burst therefore always gets a full pass over settled operands, which is what
  // makes the final answer correct without latching all ten inputs - 320 flops
  // this design has no room for.
  logic pend;
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

  // `pend` is part of busy, not just a restart flag. Without it the module
  // drops to S_IDLE for the single cycle between a set finishing and its redo
  // starting, and an object handed over in that cycle would be clipped against
  // the mixed planes the redo exists to replace.
  assign busy = (st != S_IDLE) || recompute || pend;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; which <= '0; acc <= '0; valid <= 1'b0;
      a_left <= '0; a_right <= '0; a_bottom <= '0; a_top <= '0;
      pend <= 1'b0; dbg_redo <= '0;
    end else begin
      // Remember a request whatever state we are in. Counted when it arrives
      // mid-set, because that is the case that used to be lost.
      if (recompute) begin
        pend <= 1'b1;
        if (st != S_IDLE) dbg_redo <= dbg_redo + 16'd1;
      end
      case (st)
        S_IDLE: if (pend || recompute) begin
                  pend <= 1'b0; which <= '0; valid <= 1'b0; st <= S_S1;
                end
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
          // A request that arrived mid-set sends the whole thing round again,
          // so the operands the final pass sees are the settled ones.
          if (which == 2'd3) begin valid <= !pend; st <= S_IDLE; end
          else begin which <= which + 2'd1; st <= S_S1; end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
