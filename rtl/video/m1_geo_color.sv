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
// The lit colour of a polygon: push_object's colour block (model1_v.cpp:1050).
//
//     dif    = dot(vn, light)
//     spec   = compute_specular(vn, light, dif, lightmode)
//     ln     = lp.a + lp.d * max(0, dif) + spec
//     lumval = (255 * min(1, ln)) >> 2, clamped to 0x3f
//     colour = paletteram[0x1000 | (tex_data & 0x3ff)]
//     r,g,b  = 5 bits each, then color_xlat[(c << 8) | lumval | bank] >> 3
//
// EVERY BRANCH OF THIS IS LIVE FOR VIRTUA RACING, MEASURED
//
// tools/mame_light_census.lua over 1,200 frames of attract:
//
//     spec_enable          set on 294 of 294 mode words
//     unlit (bit 0x400)    40,852 + 5,832 colour words, 22% of them
//     blink (mode 01)      5,832 words
//
// So none of it could be dropped as "netmerc only", which was the hope. The
// specular term in particular is not optional here.
//
// THE BLINK IS A CHANNEL ROTATION ON ALTERNATE FRAMES, not a brightness change:
// b -> g -> r -> b, applied BEFORE the translation lookup. It reads as a colour
// cycle on the HUD, and doing it after the lookup shifts the wrong values.
//
// THE UNLIT FLAG OVERRIDES THE WHOLE LIGHTING CALCULATION, and does so AFTER the
// clamp, not instead of the arithmetic: MAME still computes lumval and then
// replaces it with 0x3f. That matters only for how this module is sequenced -
// the result is the same - but it is why the flag is applied at the end here too
// rather than short-circuiting the FP work.
//
// `lumval >>= 2` is MAME's, with its own comment: "there must be a luma
// translation table somewhere". Reproduced as written; the table it suspects
// would be a different design and is not evidenced.

`timescale 1ns/1ps

module m1_geo_color (
  input  logic        clk,
  input  logic        rst_n,

  // Light direction, already normalized (command 0x0a does that on upload).
  input  logic [31:0] light_x, light_y, light_z,
  input  logic        spec_enable,        // command 7 bit 0

  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] in_nx, in_ny, in_nz, // the NORMALIZED polygon normal
  input  logic [15:0] in_tex,              // tgp_ram[tex_adr - 0x40000]
  // Diffuse, ambient and specular arrive ALREADY DIVIDED BY 255, as floats.
  //
  // MAME stores them as `float(v)/255.0f` when command 6 uploads a bank, which is
  // once in a while, and reads them per polygon. Converting per polygon instead
  // would mean a byte-to-float and a divide inside the per-record budget, for a
  // value that has not changed in thousands of records. The first version of this
  // module took bytes and forgot the /255 entirely, so every luminance saturated
  // at 0x3f and the picture would have been uniformly full-bright.
  input  logic [31:0] in_lp_d,
  input  logic [31:0] in_lp_a,
  input  logic [31:0] in_lp_s,
  input  logic [7:0]  in_lp_p,             // power, used only as a threshold
  input  logic        in_frame_odd,        // for the blink

  // Palette and colour-translation reads. Registered, one cycle.
  output logic [12:0] pal_addr,
  input  logic [15:0] pal_data,
  output logic [14:0] xlat_addr,
  input  logic [15:0] xlat_data,

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
  output logic [23:0] out_rgb,
  output logic [5:0]  out_lum              // for the bench and the overlay
);

  localparam logic [31:0] F_ONE = 32'h3f800000;
  localparam logic [31:0] F_255 = 32'h437f0000;
  localparam logic [31:0] F_ZERO = 32'h00000000;

  typedef enum logic [5:0] {
    C_IDLE,
    C_DOT_I, C_DOT_W,                                  // three products, issued back to back
    C_DA_I, C_DA_W, C_DB_I, C_DB_W,                   // two sums -> dif
    C_S0_I, C_S0_W, C_S1_I, C_S1_W,                   // 2*dif*nz - lz
    C_SQ_I, C_SQ_W,                                   // conditional squarings
    C_SS_I, C_SS_W,                                   // * lp.s
    C_LD_I, C_LD_W, C_LA_I, C_LA_W, C_LS_I, C_LS_W,   // ln
    C_LM_I, C_LM_W,                                   // 255 * min(1,ln)
    C_LOOK, C_LOOK2, C_XR_A, C_XR_D, C_XG_A, C_XG_D, C_XB_A, C_XB_D, C_OUT
  } state_t;
  state_t st;

  logic [31:0] nx, ny, nz;
  logic [15:0] tex;
  logic [31:0] p0, p1, p2, dif, sv, ln, lum_f;
  logic [31:0] lp_d, lp_a, lp_s;
  logic [7:0]  lp_p;
  logic        frame_odd;
  logic [1:0]  sq_left;
  logic [1:0]  dot_i, dot_n;
  logic [5:0]  lumval;
  logic [4:0]  cr, cg, cb, xr, xg;

  wire [31:0] f_d = lp_d;
  wire [31:0] f_a = lp_a;
  wire [31:0] f_s = lp_s;

  // dif > 0 / <= 0 tests, on the IEEE encoding.
  function automatic is_pos(input logic [31:0] f);
    is_pos = !f[31] && (f[30:0] != 31'd0) && !((f[30:23] == 8'hff) && (f[22:0] != 0));
  endfunction

  // 2*x, exact: bump the exponent.
  function automatic [31:0] times2(input logic [31:0] f);
    times2 = {f[31], f[30:23] + 8'd1, f[22:0]};
  endfunction

  // Specular is skipped entirely when disabled, when the power is zero, or when
  // the scale is zero - compute_specular's three early returns.
  wire spec_active = spec_enable && (lp_p != 8'd0) && (lp_s[30:0] != 31'd0);

  logic [31:0] f2i_in;
  logic signed [31:0] f2i_out;
  fp_to_int u_f2i (.f(f2i_in), .i(f2i_out));
  assign f2i_in = lum_f;

  // `lumval >>= 2` on a signed int: an arithmetic shift.
  wire signed [31:0] lum_shift = f2i_out >>> 2;

  assign in_ready = (st == C_IDLE);

  // Palette word: 0x1000 | (tex & 0x3ff). pal_addr is 13 bits, so 0x1000 is the
  // TOP bit - {3'b100, ...}, not {3'b001, ...}, which lands on 0x400 and reads
  // the wrong bank of a table that is full of plausible colours either way.
  assign pal_addr = {3'b100, tex[9:0]};

  always_comb begin
    mul_req = 1'b0; mul_a = '0; mul_b = '0;
    add_req = 1'b0; add_a = '0; add_b = '0; add_sub = 1'b0;
    case (st)
      // The three products of the dot are INDEPENDENT, so they go into the
      // multiplier back to back rather than one at a time - a pipeline that
      // retires one a cycle is wasted on a request every fifth cycle. Worth 8
      // cycles of an 83-cycle budget.
      C_DOT_I: begin
        mul_req = 1'b1;
        mul_a   = (dot_i == 2'd0) ? nx : (dot_i == 2'd1) ? ny : nz;
        mul_b   = (dot_i == 2'd0) ? light_x : (dot_i == 2'd1) ? light_y : light_z;
      end
      C_DA_I: begin add_req = 1'b1; add_a = p0; add_b = p1; end
      C_DB_I: begin add_req = 1'b1; add_a = dif; add_b = p2; end
      C_S0_I: begin mul_req = 1'b1; mul_a = times2(dif); mul_b = nz; end
      C_S1_I: begin add_req = 1'b1; add_a = sv; add_b = light_z; add_sub = 1'b1; end
      C_SQ_I: begin mul_req = 1'b1; mul_a = sv; mul_b = sv; end
      C_SS_I: begin mul_req = 1'b1; mul_a = sv; mul_b = f_s; end
      // ln = a + d*max(0,dif) + spec, in MAME's order.
      C_LD_I: begin mul_req = 1'b1; mul_a = f_d;
                    mul_b = is_pos(dif) ? dif : F_ZERO; end
      C_LA_I: begin add_req = 1'b1; add_a = f_a; add_b = ln; end
      C_LS_I: begin add_req = 1'b1; add_a = ln;  add_b = sv; end
      C_LM_I: begin mul_req = 1'b1; mul_a = F_255;
                    // min(1, ln): both are positive here, so the IEEE encodings
                    // order the same way as the values and an integer compare is
                    // exact.
                    mul_b = (ln[31] == 1'b0 && ln[30:0] > F_ONE[30:0]) ? F_ONE : ln; end
      default: ;
    endcase
  end

  // The three translation lookups, one per channel, each in its own bank.
  //
  // MAME indexes `color_xlat[(c << 8) | lumval | bank]` with bank 0x0000, 0x2000
  // and 0x4000, so the channel sits at bits 12:8, the luminance at 5:0, the bank
  // at 14:13 - AND BITS 7:6 ARE ZERO. Packing {bank, c, lum} without that gap is
  // thirteen bits in a fifteen-bit field and reads a completely different table
  // entry, which looks like a plausible wrong colour rather than an error.
  always_comb begin
    case (st)
      C_XR_A, C_XR_D: xlat_addr = {2'b00, xr_src, 2'b00, lumval};
      C_XG_A, C_XG_D: xlat_addr = {2'b01, xg_src, 2'b00, lumval};
      default:        xlat_addr = {2'b10, xb_src, 2'b00, lumval};
    endcase
  end

  // The blink rotates b -> g -> r -> b on odd frames, before the lookup.
  wire blink = (tex[11:10] == 2'b01) && frame_odd;
  wire [4:0] xr_src = blink ? cg : cr;
  wire [4:0] xg_src = blink ? cb : cg;
  wire [4:0] xb_src = blink ? cr : cb;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= C_IDLE;
      nx <= '0; ny <= '0; nz <= '0; tex <= '0;
      p0 <= '0; p1 <= '0; p2 <= '0; dif <= '0; sv <= '0; ln <= '0; lum_f <= '0;
      dot_i <= '0; dot_n <= '0;
      lp_d <= '0; lp_a <= '0; lp_s <= '0; lp_p <= '0; frame_odd <= 1'b0;
      sq_left <= '0; lumval <= '0;
      cr <= '0; cg <= '0; cb <= '0; xr <= '0; xg <= '0;
      out_valid <= 1'b0; out_rgb <= '0; out_lum <= '0;
    end else begin
      out_valid <= 1'b0;

      // The dot's three products come back in issue order while the FSM is still
      // issuing or already waiting, so they are collected by their own counter
      // rather than by the state.
      if ((st == C_DOT_I || st == C_DOT_W) && mul_rsp) begin
        case (dot_n)
          2'd0: p0 <= mul_res;
          2'd1: p1 <= mul_res;
          default: p2 <= mul_res;
        endcase
        dot_n <= dot_n + 2'd1;
      end

      case (st)
        C_IDLE: if (in_valid) begin
          nx <= in_nx; ny <= in_ny; nz <= in_nz; tex <= in_tex;
          lp_d <= in_lp_d; lp_a <= in_lp_a; lp_s <= in_lp_s; lp_p <= in_lp_p;
          frame_odd <= in_frame_odd;
          dot_i <= '0; dot_n <= '0;
          st <= C_DOT_I;
        end

        C_DOT_I: if (mul_gnt) begin
          if (dot_i == 2'd2) st <= C_DOT_W;
          else               dot_i <= dot_i + 2'd1;
        end
        C_DOT_W: if (dot_n == 2'd2 && mul_rsp) st <= C_DA_I;
        C_DA_I: if (add_gnt) st <= C_DA_W;
        C_DA_W: if (add_rsp) begin dif <= add_res; st <= C_DB_I; end
        C_DB_I: if (add_gnt) st <= C_DB_W;
        C_DB_W: if (add_rsp) begin
          dif <= add_res;
          // compute_specular's early outs, taken before any of its arithmetic.
          sv  <= F_ZERO;
          st  <= spec_active ? C_S0_I : C_LD_I;
        end

        C_S0_I: if (mul_gnt) st <= C_S0_W;
        C_S0_W: if (mul_rsp) begin sv <= mul_res; st <= C_S1_I; end
        C_S1_I: if (add_gnt) st <= C_S1_W;
        C_S1_W: if (add_rsp) begin
          sv <= add_res;
          if (!is_pos(add_res)) begin
            // `if (s <= 0) return 0`
            sv <= F_ZERO;
            st <= C_LD_I;
          end else begin
            // p >= 2, p >= 4 and p >= 7 each square once more.
            sq_left <= (lp_p >= 8'd7) ? 2'd3 :
                       (lp_p >= 8'd4) ? 2'd2 :
                       (lp_p >= 8'd2) ? 2'd1 : 2'd0;
            st <= (lp_p >= 8'd2) ? C_SQ_I : C_SS_I;
          end
        end
        C_SQ_I: if (mul_gnt) st <= C_SQ_W;
        C_SQ_W: if (mul_rsp) begin
          sv      <= mul_res;
          sq_left <= sq_left - 2'd1;
          st      <= (sq_left == 2'd1) ? C_SS_I : C_SQ_I;
        end
        C_SS_I: if (mul_gnt) st <= C_SS_W;
        C_SS_W: if (mul_rsp) begin
          // min(s * lp.s, 1)
          sv <= (!mul_res[31] && mul_res[30:0] > F_ONE[30:0]) ? F_ONE : mul_res;
          st <= C_LD_I;
        end

        C_LD_I: if (mul_gnt) st <= C_LD_W;
        C_LD_W: if (mul_rsp) begin ln <= mul_res; st <= C_LA_I; end
        C_LA_I: if (add_gnt) st <= C_LA_W;
        C_LA_W: if (add_rsp) begin ln <= add_res; st <= C_LS_I; end
        C_LS_I: if (add_gnt) st <= C_LS_W;
        C_LS_W: if (add_rsp) begin ln <= add_res; st <= C_LM_I; end
        C_LM_I: if (mul_gnt) st <= C_LM_W;
        C_LM_W: if (mul_rsp) begin lum_f <= mul_res; st <= C_LOOK; end

        C_LOOK: begin
          // f2i is combinational on lum_f, which settled last cycle.
          //
          // THE SHIFT COMES BEFORE THE CLAMP. MAME computes the whole 0..255
          // value, shifts right by two, and only then clamps to 0x3f. Clamping
          // the unshifted value first turns everything above 63 - which is most
          // of the range - into full brightness, so the picture comes out
          // uniformly lit and nothing looks obviously broken.
          lumval <= (lum_shift > 32'sd63) ? 6'd63 :
                    (lum_shift < 32'sd0)  ? 6'd0  : 6'(lum_shift[5:0]);
          st <= C_LOOK2;
        end
        C_LOOK2: begin
          // The unlit flag replaces the luminance AFTER the clamp, as MAME does.
          if (tex[10]) lumval <= 6'h3f;
          cr <= pal_data[4:0];
          cg <= pal_data[9:5];
          cb <= pal_data[14:10];
          st <= C_XR_A;
        end
        // Each lookup takes two states: present the address, then capture. The
        // memories are registered, so reading xlat_data in the same cycle the
        // address is driven returns the PREVIOUS lookup's word.
        C_XR_A: st <= C_XR_D;
        C_XR_D: begin xr <= xlat_data[7:3]; st <= C_XG_A; end
        C_XG_A: st <= C_XG_D;
        C_XG_D: begin xg <= xlat_data[7:3]; st <= C_XB_A; end
        C_XB_A: st <= C_XB_D;
        C_XB_D: begin
          // pal5bit: (v << 3) | (v >> 2)
          out_rgb <= {{xr, xr[4:2]}, {xg, xg[4:2]},
                      {xlat_data[7:3], xlat_data[7:5]}};
          out_lum <= lumval;
          st      <= C_OUT;
        end
        C_OUT: begin out_valid <= 1'b1; st <= C_IDLE; end
        default: st <= C_IDLE;
      endcase
    end
  end

endmodule
