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
// Behavioural contract is MAME's model1_v.cpp fclip_push_quad (:697) and the
// four clip/isclipped pairs at :635-:690 (BSD-3-Clause, Olivier Galibert).
//
// THE VIEWPORT CLIPPER, AND WHY THE PICTURE NEEDS IT
//
// MAME clips every quad against four frustum planes before it is rasterised,
// splitting it and creating vertices on the boundary. We did not, and it showed
// on hardware as the road landing in the wrong place while most other objects
// were fine.
//
// The reason it is the ROAD is arithmetic, not luck. m1_quad_store keeps SIXTEEN
// BIT screen coordinates and m1_raster_fill works in 16.16 fixed point - `s.x
// << 16` into an int32 - so both require vertices inside +/-32768. MAME satisfies
// that by construction, because the clipper has already pulled every vertex onto
// the viewport boundary. Unclipped, a road vertex projecting to x = 100,000
// truncates to -31,072 and the quad is drawn as a slab on the opposite side of
// the screen. Objects that fit on screen never notice; the road, which runs to
// the horizon and off both sides, always does.
//
// It was NOT the geometry. tb_m1_geometry walks 50 real objects out of the
// polygon ROM and compares them quad-for-quad against push_object: 1,267 quads,
// zero vertex coordinates differing, colour exact on all of them.
//
// THE PLANES ARE IN CAMERA SPACE, NOT SCREEN SPACE
//
// view_t::set_viewport (:629) reduces the screen rectangle to four ratios:
//
//     a_left   = ( x1 - xc - viewx) / zoomx      p.x < p.z * a_left
//     a_right  = ( x2 - xc - viewx) / zoomx      p.x > p.z * a_right
//     a_bottom = (-y1 + yc - viewy) / zoomy      p.y > p.z * a_bottom
//     a_top    = (-y2 + yc - viewy) / zoomy      p.y < p.z * a_top
//
// so a point is tested with ONE multiply and a float compare, and the four
// planes are one datapath with the tested coordinate muxed between y and x.
//
// A CREATED VERTEX, identically for all four:
//
//     t = (p2.z*a - p2.v) / ((p2.z - p1.z)*a - (p2.v - p1.v))
//     pt.{x,y,z} = p1*t + p2*(1 - t)
//     project_point(pt)
//
// FAN-OUT, AND WHY THERE IS NO POINT POOL
//
// This is not general Sutherland-Hodgman. MAME rotates the quad so vertex 0 is
// outside and vertex 3 is inside, then takes one of four fixed cases, emitting
// one or two child quads and creating two or four points. Four levels, so one
// quad can become sixteen.
//
// THE FIRST VERSION KEPT A TWENTY-POINT POOL - four in, four per level - with
// the quad holding indices into it. Correct, verified, and it did not fit: 5,347
// ALM standalone against 4,358 free, and the design needed 4,392 LABs of 4,191.
// The storage was not the problem. The pool had five read ports - the two edge
// endpoints, the destination, the vertex under test and the four being emitted -
// and every one of them is a 20-to-1 mux on 32 bits. A dozen of those plus eight
// more on 16 dwarfed the registers they were reading.
//
// So there is no pool. The quad being worked on lives in plain registers, so
// every read of it is a 4-to-1 mux; the points a level creates go into four
// temporaries; and a child is formed by naming, per vertex, whether it comes
// from the current quad or from a temporary. The stack holds whole points rather
// than indices - and it is a SHIFT REGISTER, so a push or a pop is 2-to-1 muxes
// and there is no addressed read at all.
//
// FIVE ENTRIES IS ENOUGH. Depth-first, each level can leave at most one sibling
// pending, so four levels leave four - and the quad being processed is in
// registers, not on the stack.
//
// SCREEN COORDINATES ARE NOT CARRIED ON THE STACK AT ALL. They are 16 bits
// each, which is nothing until it is five entries by four vertices by two
// coordinates - 640 flops, and in a shift register every flop brings a mux with
// it. Dropping them was the last 580 ALM needed to fit, at the cost of
// projecting a quad's four vertices when it is emitted rather than when they
// were created: four reciprocals, about 116 cycles, on roughly 630 quads a
// frame against a geometry stage of 367,000.
//
// It is also closer to MAME than the alternative. project_point is called on a
// created vertex there, but every vertex is projected before it is drawn, and
// projecting at the end is the same answer from the same inputs.

`timescale 1ns/1ps

module m1_geo_clip (
  input  logic        clk,
  input  logic        rst_n,

  // The four plane ratios, from the viewport. Held.
  input  logic [31:0] a_left, a_right, a_bottom, a_top,

  // One quad in: four points in CAMERA space, with the screen coordinates the
  // walker already computed for them, and the attributes that ride along.
  input  logic        in_valid,
  output logic        in_ready,
  input  logic [31:0] in_x0, in_y0, in_z0,
  input  logic [31:0] in_x1, in_y1, in_z1,
  input  logic [31:0] in_x2, in_y2, in_z2,
  input  logic [31:0] in_x3, in_y3, in_z3,
  input  logic signed [15:0] in_sx0, in_sy0, in_sx1, in_sy1,
  input  logic signed [15:0] in_sx2, in_sy2, in_sx3, in_sy3,
  // THE ATTRIBUTES RIDE WITH THE QUAD, and they have to be latched here.
  // The walker moves on as soon as this module accepts, so by the time a
  // clipped quad is emitted - hundreds of cycles later - the walker's colour
  // and sort z registers hold the NEXT quad's values. Taken combinationally
  // they came out wrong, which showed as `z 41480000 expected 00000000`.
  // fclip_push_quad copies the whole quad_t for the same reason.
  input  logic [23:0] in_col,
  input  logic [31:0] in_z,
  input  logic        in_moire,

  // Shared arithmetic - see rtl/video/m1_fp_pool.sv.
  output logic        mul_req,
  output logic [31:0] mul_a, mul_b,
  input  logic        mul_gnt, mul_rsp,
  input  logic [31:0] mul_res,

  output logic        add_req,
  output logic [31:0] add_a, add_b,
  output logic        add_sub,
  input  logic        add_gnt, add_rsp,
  input  logic [31:0] add_res,

  output logic        div_req,
  output logic [31:0] div_a, div_b,
  input  logic        div_gnt, div_rsp,
  input  logic [31:0] div_res,

  // Projection of a created point. Driven onto the geometry stage's existing
  // m1_geo_project, which is idle whenever this module is running: the walker
  // has finished projecting the quad's own corners by the time it emits it.
  output logic        pj_valid,
  input  logic        pj_ready,
  output logic [31:0] pj_x, pj_y, pj_z,
  input  logic        pj_out_valid,
  input  logic signed [31:0] pj_out_sx, pj_out_sy,

  // Zero or more quads out, screen space.
  output logic        out_valid,
  input  logic        out_ready,
  output logic signed [15:0] out_sx0, out_sy0, out_sx1, out_sy1,
  output logic signed [15:0] out_sx2, out_sy2, out_sx3, out_sy3,
  output logic [23:0] out_col,
  output logic [31:0] out_z,
  output logic        out_moire,

  // Counted: quads in, quads out, and how many were dropped entirely. A clipper
  // that silently drops everything and one that passes everything through look
  // identical from the picture if the scene happens to fit on screen.
  // THESE WRAP, THEY DO NOT SATURATE, and that is the whole point of them.
  //
  // They saturated at 0xffff until 2026-09-09, and free-running from reset that
  // means they peg within seconds and stop counting: a two-minute capture read
  // c=FFFF d=FFFF e=FFFF and said nothing at all. m1_quad_store's D= is
  // readable because it is CLEARED every pass; the clipper has no pass boundary
  // to clear on, so it wraps and the reader takes deltas - which is how A=/Z=
  // and I=/J= are read.
  //
  // dbg_dropped counts quads whose four vertices are ALL outside the frustum,
  // which is legitimate work, not a fault. The signal to look for is the RATIO
  // against dbg_in, and whether it moves when the left side cuts out.
  output logic [15:0] dbg_in, dbg_out, dbg_dropped
);

  localparam int unsigned NSTK = 5;
  localparam logic [31:0] F_ONE = 32'h3f800000;

  // ------------------------------------------------------- the current quad
  // Four points in registers. Every read of these is a 4-to-1 mux, which is the
  // whole point of not having a pool.
  logic [31:0]        qx [4], qy [4], qz [4];
  logic signed [15:0] qsx [4], qsy [4];   // filled at emit, not carried
  logic [2:0]         lvl;
  logic [3:0]         is_out;

  // The points this level creates. At most four, in the "0,2 out" case.
  logic [31:0]        tx [4], ty [4], tz [4];

  // ------------------------------------------------------------- the stack
  // ADDRESSED BY sp, NOT A SHIFT REGISTER. It used to be one, on the reasoning
  // that keeping the top at entry 0 avoids an addressed read. It does - and it
  // costs the whole stack moving on every push and pop: 5 x 4 x 32 x 3 = 1,920
  // flops, each needing a mux between hold, shift-up, shift-down and load. That
  // was most of this module's 3,277 ALM, three times m1_geo_project and larger
  // than the TGP's whole ALU, for a clipper.
  //
  // A stack does not have to move; a pointer moves instead. Push writes entry
  // sp, pop reads entry sp-1, and every flop keeps a plain enable. The read mux
  // an addressed stack needs is five-deep and costs a fraction of what the
  // shift network did.
  logic [2:0]         sk_lvl [NSTK];
  logic [31:0]        sk_x [NSTK][4], sk_y [NSTK][4], sk_z [NSTK][4];
  logic [2:0]         sp;
  wire  [2:0]         sp_top = sp - 3'd1;   // the entry a pop reads

  // ------------------------------------------------------------ the plane
  wire [31:0] plane_a = (lvl == 3'd0) ? a_bottom :
                        (lvl == 3'd1) ? a_top    :
                        (lvl == 3'd2) ? a_left   : a_right;
  wire        plane_x = (lvl >= 3'd2);        // left/right test x, bottom/top y
  wire        plane_gt = (lvl == 3'd0) || (lvl == 3'd3);

  // ---------------------------------------------------------- float compare
  // IEEE floats compare as sign-magnitude, so an integer compare is wrong across
  // zero. Negatives inverted, positives with the sign bit set.
  function automatic [31:0] fkey(input logic [31:0] f);
    fkey = f[31] ? ~f : (f | 32'h80000000);
  endfunction
  function automatic logic fgt(input logic [31:0] a, input logic [31:0] b);
    fgt = fkey(a) > fkey(b);
  endfunction

  // ---------------------------------------------------------------- states
  typedef enum logic [3:0] {
    K_IDLE, K_POP, K_TEST, K_TESTW, K_ROT, K_SET,
    K_CLIP, K_CLIPW, K_CHILD, K_EPROJ, K_EPROJW, K_EMIT
  } kstate_t;
  kstate_t kst;

  logic [1:0] ti;                            // vertex under test
  logic [1:0] rot;                           // rotation offset
  logic [1:0] ccase;
  logic [1:0] cn, cn_last;                   // clips done, and the last index
  logic [1:0] cp_a, cp_b;                    // edge endpoints, quad indices
  logic [1:0] cp_dst;                        // which temporary
  logic       second_child;
  logic [3:0] cs;
  logic [1:0] c_axis;
  logic [31:0] c_num, c_den, c_t, c_u, c_m1, c_m2;
  logic [23:0] a_col;
  logic [31:0] a_z;
  logic        a_moire;

  // Rotated index: pt[j] is quad vertex (rot + j) mod 4.
  function automatic [1:0] rt(input logic [1:0] j);
    rt = rot + j;
  endfunction
  wire [1:0] r0 = rt(2'd0), r1 = rt(2'd1), r2 = rt(2'd2), r3 = rt(2'd3);

  // The edge each clip cuts, per case and clip index - fclip_push_quad's four
  // branches, as quad indices rather than pool slots.
  function automatic [1:0] edge_a(input logic [1:0] c, input logic [1:0] n);
    case (c)
      2'd0:    edge_a = (n == 2'd0) ? r2 : r3;
      2'd1:    edge_a = (n == 2'd0) ? r1 : r3;
      2'd2:    edge_a = (n == 2'd0) ? r0 : (n == 2'd1) ? r1 : (n == 2'd2) ? r2 : r3;
      default: edge_a = (n == 2'd0) ? r0 : r3;
    endcase
  endfunction
  function automatic [1:0] edge_b(input logic [1:0] c, input logic [1:0] n);
    case (c)
      2'd0:    edge_b = (n == 2'd0) ? r3 : r0;
      2'd1:    edge_b = (n == 2'd0) ? r2 : r0;
      2'd2:    edge_b = (n == 2'd0) ? r1 : (n == 2'd1) ? r2 : (n == 2'd2) ? r3 : r0;
      default: edge_b = (n == 2'd0) ? r1 : r0;
    endcase
  endfunction

  // ------------------------------------------------------------ operands
  wire [31:0] ax = qx[cp_a], ay = qy[cp_a], az = qz[cp_a];
  wire [31:0] bx = qx[cp_b], by = qy[cp_b], bz = qz[cp_b];
  wire [31:0] a_v = plane_x ? ax : ay;
  wire [31:0] b_v = plane_x ? bx : by;
  wire [31:0] test_v = plane_x ? qx[ti] : qy[ti];

  // A child vertex is named rather than copied: bit 2 says "from a temporary",
  // bits 1:0 index the quad or the temporaries.
  function automatic [2:0] kid(input logic [1:0] c, input logic sc,
                               input logic [1:0] v);
    case (c)
      2'd0: case (v)                                  // 0,1,2 out: a triangle
              2'd0:    kid = {1'b1, 2'd0};
              2'd1:    kid = {1'b0, r3};
              default: kid = {1'b1, 2'd1};
            endcase
      2'd1: case (v)                                  // 0,1 out: a quad
              2'd0:    kid = {1'b1, 2'd0};
              2'd1:    kid = {1'b0, r2};
              2'd2:    kid = {1'b0, r3};
              default: kid = {1'b1, 2'd1};
            endcase
      2'd2: if (!sc) case (v)                         // 0,2 out: two triangles
              2'd0:    kid = {1'b1, 2'd2};
              2'd1:    kid = {1'b0, r3};
              default: kid = {1'b1, 2'd3};
            endcase
            else case (v)
              2'd0:    kid = {1'b1, 2'd0};
              2'd1:    kid = {1'b0, r1};
              default: kid = {1'b1, 2'd1};
            endcase
      default: if (!sc) case (v)                      // 0 out: a quad and a tri
              2'd0:    kid = {1'b0, r3};
              2'd1:    kid = {1'b1, 2'd1};
              default: kid = {1'b1, 2'd0};
            endcase
            else case (v)
              2'd0:    kid = {1'b1, 2'd0};
              2'd1:    kid = {1'b0, r1};
              2'd2:    kid = {1'b0, r2};
              default: kid = {1'b0, r3};
            endcase
    endcase
  endfunction

  // ---------------------------------------------------------- pool requests
  always_comb begin
    mul_req = 1'b0; mul_a = '0; mul_b = '0;
    add_req = 1'b0; add_a = '0; add_b = '0; add_sub = 1'b0;
    div_req = 1'b0; div_a = '0; div_b = '0;
    case (kst)
      K_TEST: begin mul_req = 1'b1; mul_a = qz[ti]; mul_b = plane_a; end
      K_CLIP: case (cs)
        4'd0: begin mul_req = 1'b1; mul_a = bz;    mul_b = plane_a; end
        4'd1: begin add_req = 1'b1; add_a = c_num; add_b = b_v;  add_sub = 1'b1; end
        4'd2: begin add_req = 1'b1; add_a = bz;    add_b = az;    add_sub = 1'b1; end
        4'd3: begin mul_req = 1'b1; mul_a = c_den; mul_b = plane_a; end
        4'd4: begin add_req = 1'b1; add_a = b_v;   add_b = a_v;   add_sub = 1'b1; end
        4'd5: begin add_req = 1'b1; add_a = c_den; add_b = c_m1;  add_sub = 1'b1; end
        4'd6: begin div_req = 1'b1; div_a = c_num; div_b = c_den; end
        4'd7: begin add_req = 1'b1; add_a = F_ONE; add_b = c_t;   add_sub = 1'b1; end
        4'd8: begin mul_req = 1'b1;
                    mul_a = (c_axis == 2'd0) ? ax : (c_axis == 2'd1) ? ay : az;
                    mul_b = c_t; end
        4'd9: begin mul_req = 1'b1;
                    mul_a = (c_axis == 2'd0) ? bx : (c_axis == 2'd1) ? by : bz;
                    mul_b = c_u; end
        default: begin add_req = 1'b1; add_a = c_m1; add_b = c_m2; end
      endcase
      default: ;
    endcase
  end

  assign in_ready  = (kst == K_IDLE);
  // The projection unit is used only at emit now, one vertex at a time.
  assign pj_valid  = (kst == K_EPROJ);
  assign pj_x = qx[ti]; assign pj_y = qy[ti]; assign pj_z = qz[ti];
  assign out_valid = (kst == K_EMIT);
  assign out_sx0 = qsx[0]; assign out_sy0 = qsy[0];
  assign out_sx1 = qsx[1]; assign out_sy1 = qsy[1];
  assign out_sx2 = qsx[2]; assign out_sy2 = qsy[2];
  assign out_sx3 = qsx[3]; assign out_sy3 = qsy[3];
  assign out_col = a_col; assign out_z = a_z; assign out_moire = a_moire;

  // ---------------------------------------------------------------- sequencer
  integer si, sv;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      kst <= K_IDLE; sp <= '0; lvl <= '0; is_out <= '0; ti <= '0;
      rot <= '0; ccase <= '0; cn <= '0; cn_last <= '0;
      cp_a <= '0; cp_b <= '0; cp_dst <= '0; second_child <= 1'b0;
      cs <= '0; c_axis <= '0;
      c_num <= '0; c_den <= '0; c_t <= '0; c_u <= '0; c_m1 <= '0; c_m2 <= '0;
      a_col <= '0; a_z <= '0; a_moire <= 1'b0;
      dbg_in <= '0; dbg_out <= '0; dbg_dropped <= '0;
      for (si = 0; si < 4; si = si + 1) begin
        qx[si] <= '0; qy[si] <= '0; qz[si] <= '0; qsx[si] <= '0; qsy[si] <= '0;
        tx[si] <= '0; ty[si] <= '0; tz[si] <= '0;
      end
      for (si = 0; si < NSTK; si = si + 1) begin
        sk_lvl[si] <= '0;
        for (sv = 0; sv < 4; sv = sv + 1) begin
          sk_x[si][sv] <= '0; sk_y[si][sv] <= '0; sk_z[si][sv] <= '0;
        end
      end
    end else begin
      case (kst)
        K_IDLE: if (in_valid) begin
          qx[0] <= in_x0; qy[0] <= in_y0; qz[0] <= in_z0;
          qx[1] <= in_x1; qy[1] <= in_y1; qz[1] <= in_z1;
          qx[2] <= in_x2; qy[2] <= in_y2; qz[2] <= in_z2;
          qx[3] <= in_x3; qy[3] <= in_y3; qz[3] <= in_z3;
          a_col <= in_col; a_z <= in_z; a_moire <= in_moire;
          lvl <= 3'd0; sp <= '0; ti <= '0;
          dbg_in <= dbg_in + 16'd1;         // WRAPS - see the note above
          kst <= K_TEST;
        end

        // Pop: the top is entry sp-1. Nothing moves; the pointer does.
        K_POP: if (sp == 3'd0) kst <= K_IDLE;
        else begin
          lvl <= sk_lvl[sp_top];
          for (sv = 0; sv < 4; sv = sv + 1) begin
            qx[sv] <= sk_x[sp_top][sv];
            qy[sv] <= sk_y[sp_top][sv];
            qz[sv] <= sk_z[sp_top][sv];
          end
          sp  <= sp - 3'd1;
          ti  <= '0;
          kst <= (sk_lvl[sp_top] == 3'd4) ? K_EPROJ : K_TEST;
        end

        K_TEST:  if (mul_gnt) kst <= K_TESTW;
        K_TESTW: if (mul_rsp) begin
          is_out[ti] <= plane_gt ? fgt(test_v, mul_res) : fgt(mul_res, test_v);
          if (ti == 2'd3) begin
            // Decided on the last vertex, so the whole flag word is ready one
            // cycle later - which is why the decision lives in K_ROT.
            ti  <= '0;
            kst <= K_ROT;
          end else begin ti <= ti + 2'd1; kst <= K_TEST; end
        end

        K_ROT: begin
          if (is_out == 4'b0000) begin
            // Wholly inside: on to the next plane, nothing created.
            lvl <= lvl + 3'd1;
            ti  <= '0;
            kst <= (lvl + 3'd1 == 3'd4) ? K_EPROJ : K_TEST;
          end else if (is_out == 4'b1111) begin
            dbg_dropped <= dbg_dropped + 16'd1;   // WRAPS
            kst <= K_POP;
          end else begin
            automatic logic [1:0] i;
            i = 2'd0;
            for (int k = 3; k >= 0; k--)
              if (is_out[k] && !is_out[(k + 3) & 3]) i = 2'(k);
            rot <= i;
            ccase <= is_out[(i + 2'd1) & 2'd3]
                       ? (is_out[(i + 2'd2) & 2'd3] ? 2'd0 : 2'd1)
                       : (is_out[(i + 2'd2) & 2'd3] ? 2'd2 : 2'd3);
            cn_last <= is_out[(i + 2'd1) & 2'd3] ? 2'd1
                     : (is_out[(i + 2'd2) & 2'd3] ? 2'd3 : 2'd1);
            cn <= '0; second_child <= 1'b0;
            kst <= K_SET;
          end
        end

        K_SET: begin
          cp_a   <= edge_a(ccase, cn);
          cp_b   <= edge_b(ccase, cn);
          cp_dst <= cn;
          cs     <= '0;
          c_axis <= '0;
          kst    <= K_CLIP;
        end

        K_CLIP: case (cs)
          4'd0, 4'd3, 4'd8, 4'd9: if (mul_gnt) kst <= K_CLIPW;
          4'd6:                   if (div_gnt) kst <= K_CLIPW;
          default:                if (add_gnt) kst <= K_CLIPW;
        endcase

        K_CLIPW: case (cs)
          4'd0: if (mul_rsp) begin c_num <= mul_res; cs <= 4'd1; kst <= K_CLIP; end
          4'd1: if (add_rsp) begin c_num <= add_res; cs <= 4'd2; kst <= K_CLIP; end
          4'd2: if (add_rsp) begin c_den <= add_res; cs <= 4'd3; kst <= K_CLIP; end
          4'd3: if (mul_rsp) begin c_den <= mul_res; cs <= 4'd4; kst <= K_CLIP; end
          4'd4: if (add_rsp) begin c_m1  <= add_res; cs <= 4'd5; kst <= K_CLIP; end
          4'd5: if (add_rsp) begin c_den <= add_res; cs <= 4'd6; kst <= K_CLIP; end
          4'd6: if (div_rsp) begin c_t   <= div_res; cs <= 4'd7; kst <= K_CLIP; end
          4'd7: if (add_rsp) begin c_u   <= add_res; cs <= 4'd8; kst <= K_CLIP; end
          4'd8: if (mul_rsp) begin c_m1  <= mul_res; cs <= 4'd9; kst <= K_CLIP; end
          4'd9: if (mul_rsp) begin c_m2  <= mul_res; cs <= 4'd10; kst <= K_CLIP; end
          default: if (add_rsp) begin
            case (c_axis)
              2'd0:    tx[cp_dst] <= add_res;
              2'd1:    ty[cp_dst] <= add_res;
              default: tz[cp_dst] <= add_res;
            endcase
            if (c_axis == 2'd2) begin
              // No projection here any more: a created vertex carries only its
              // camera coordinates and is projected when its quad is emitted.
              if (cn == cn_last) kst <= K_CHILD;
              else begin cn <= cn + 2'd1; kst <= K_SET; end
            end else begin c_axis <= c_axis + 2'd1; cs <= 4'd8; kst <= K_CLIP; end
          end
        endcase

        // Four vertices, one reciprocal each, at the point of emission.
        K_EPROJ:  if (pj_ready) kst <= K_EPROJW;
        K_EPROJW: if (pj_out_valid) begin
          // Sixteen bits: a clipped vertex is inside the viewport by
          // construction, which is why the quad store can keep 16.
          qsx[ti] <= pj_out_sx[15:0];
          qsy[ti] <= pj_out_sy[15:0];
          if (ti == 2'd3) kst <= K_EMIT;
          else begin ti <= ti + 2'd1; kst <= K_EPROJ; end
        end

        // Push a child, naming each vertex as coming from the current quad or
        // from a temporary. The SECOND child is pushed first, so it sits deeper
        // and is popped last - which is MAME's recursion order.
        K_CHILD: begin
          // Writes the free entry sp and advances the pointer, so the deeper
          // entries are untouched and keep the order the shift version gave
          // them. The bound matters: the shift version dropped the DEEPEST
          // entry when it overflowed, an addressed one would write past the
          // array, so a full stack drops the newest instead. Recursion is
          // bounded by the five clip levels, so it should never fire - and if
          // it ever does, dropping is what the old code did too, at the other
          // end.
          if (sp < 3'(NSTK)) begin
            sk_lvl[sp] <= lvl + 3'd1;
            for (sv = 0; sv < 4; sv = sv + 1) begin
              automatic logic [2:0] k;
              // second_child, NOT its inverse: on the first pass this selects
              // MAME's SECOND child, so it sits deeper in the stack and is
              // popped last - the order MAME's recursion emits in.
              k = kid(ccase, second_child, 2'(sv));
              sk_x[sp][sv]  <= k[2] ? tx[k[1:0]]  : qx[k[1:0]];
              sk_y[sp][sv]  <= k[2] ? ty[k[1:0]]  : qy[k[1:0]];
              sk_z[sp][sv]  <= k[2] ? tz[k[1:0]]  : qz[k[1:0]];
            end
            sp <= sp + 3'd1;
          end
          if ((ccase == 2'd2 || ccase == 2'd3) && !second_child)
            second_child <= 1'b1;
          else kst <= K_POP;
        end

        K_EMIT: if (out_ready) begin
          dbg_out <= dbg_out + 16'd1;       // WRAPS
          kst <= K_POP;
        end

        default: kst <= K_IDLE;
      endcase
    end
  end

endmodule
