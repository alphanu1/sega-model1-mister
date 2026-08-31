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
// FAN-OUT AND THE POINT POOL
//
// This is not general Sutherland-Hodgman. MAME rotates the quad so vertex 0 is
// outside and vertex 3 is inside, then takes one of four fixed cases, emitting
// one or two child quads and creating two or four points. Four levels, so one
// quad can become sixteen.
//
// Depth-first, a quad at level L only ever references points created at levels
// below it, and a level's points are dead once its whole subtree has retired. So
// the pool is FOUR POINTS PER LEVEL plus the four that came in - twenty - rather
// than one entry per point ever created. It is registers, not memory: M10K is at
// 553 of 553 and an inferred RAM here would fail the fit outright.
//
// SCREEN COORDINATES ARE STORED AT SIXTEEN BITS. After clipping every vertex is
// inside the viewport by construction, so the width the quad store keeps is the
// width that is needed - and storing 32 would double the pool for nothing.

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

  // Counted: quads in, quads out, and how many were dropped entirely. A clipper
  // that silently drops everything and one that passes everything through look
  // identical from the picture if the scene happens to fit on screen.
  output logic [15:0] dbg_in, dbg_out, dbg_dropped
);

  localparam int unsigned NPOOL = 20;      // 4 in + 4 per level x 4 levels
  localparam int unsigned PW    = 5;       // pool index width
  localparam int unsigned NSTK  = 8;

  localparam logic [31:0] F_ONE = 32'h3f800000;

  // ---------------------------------------------------------------- the pool
  logic [31:0]        px [NPOOL], py [NPOOL], pz [NPOOL];
  logic signed [15:0] psx [NPOOL], psy [NPOOL];

  // ---------------------------------------------------------------- the stack
  logic [2:0]     st_lvl [NSTK];
  logic [PW-1:0]  st_p0 [NSTK], st_p1 [NSTK], st_p2 [NSTK], st_p3 [NSTK];
  logic [3:0]     sp;                       // entries in use

  // ---------------------------------------------------------- current quad
  logic [2:0]    lvl;
  logic [PW-1:0] q0, q1, q2, q3;
  logic [3:0]    is_out;                    // per vertex, this level's plane

  // The plane this level tests, and whether it compares x or y. Level order is
  // MAME's: bottom, top, left, right.
  wire [31:0] plane_a = (lvl == 3'd0) ? a_bottom :
                        (lvl == 3'd1) ? a_top    :
                        (lvl == 3'd2) ? a_left   : a_right;
  wire        plane_x = (lvl >= 3'd2);      // left/right test x, bottom/top y
  // bottom and right are `>`, top and left are `<`.
  wire        plane_gt = (lvl == 3'd0) || (lvl == 3'd3);

  // ---------------------------------------------------------- float compare
  // IEEE floats compare as sign-magnitude, so an integer compare is wrong across
  // zero. The standard monotonic key: negatives inverted, positives with the
  // sign bit set.
  function automatic [31:0] fkey(input logic [31:0] f);
    fkey = f[31] ? ~f : (f | 32'h80000000);
  endfunction
  function automatic logic fgt(input logic [31:0] a, input logic [31:0] b);
    fgt = fkey(a) > fkey(b);
  endfunction

  // ---------------------------------------------------------------- sequencer
  typedef enum logic [4:0] {
    K_IDLE, K_LOAD, K_POP, K_TEST, K_TESTW, K_DECIDE, K_ROT, K_SET,
    K_CLIP, K_CLIPW, K_PROJ, K_PROJW, K_CHILD, K_EMIT, K_DRAIN
  } kstate_t;
  kstate_t kst;

  logic [1:0]  ti;                          // vertex under test
  logic [31:0] t_zprod;                     // p.z * a for that vertex

  // Rotation: pt[j] = q[(i + j) & 3], chosen so pt[0] is out and pt[3] is in.
  logic [1:0]  rot;
  logic [PW-1:0] r0, r1, r2, r3;
  logic [3:0]  ro;                          // is_out, rotated

  // Which pair each created point comes from, and where it lands.
  logic [1:0]  cn;                          // clips done for this quad
  logic [1:0]  cn_want;                     // clips this case needs
  logic [PW-1:0] cp_a, cp_b;                // the edge's two endpoints
  logic [PW-1:0] cp_dst;                    // pool slot for the result
  logic [PW-1:0] mk0, mk1, mk2, mk3;        // the points this case created

  // Microcoded clip arithmetic. One sequence, all four planes.
  logic [3:0]  cs;
  logic [31:0] c_num, c_den, c_t, c_u, c_m1, c_m2;
  logic [1:0]  c_axis;                      // 0 = x, 1 = y, 2 = z lerp

  // Base slot for this level's four points.
  wire [PW-1:0] lvl_base = PW'(4 + {2'd0, lvl} * 4);

  assign in_ready = (kst == K_IDLE);
  assign dbg_in   = dbg_in_r;
  logic [15:0] dbg_in_r;

  // ------------------------------------------------------------- pool reads
  wire [31:0] ax = px[cp_a], ay = py[cp_a], az = pz[cp_a];
  wire [31:0] bx = px[cp_b], by = py[cp_b], bz = pz[cp_b];
  wire [31:0] a_v = plane_x ? ax : ay;      // the tested coordinate, p1
  wire [31:0] b_v = plane_x ? bx : by;      // and p2

  wire [31:0] test_v = plane_x ? px[tq] : py[tq];
  logic [PW-1:0] tq;
  always_comb begin
    case (ti)
      2'd0:    tq = q0;
      2'd1:    tq = q1;
      2'd2:    tq = q2;
      default: tq = q3;
    endcase
  end

  // ------------------------------------------------------------- pool writes
  // Every arithmetic request is issued from a state and taken on a grant, so a
  // cycle where another client won the pool simply repeats - the same shape the
  // other geometry stages use.
  always_comb begin
    mul_req = 1'b0; mul_a = '0; mul_b = '0;
    add_req = 1'b0; add_a = '0; add_b = '0; add_sub = 1'b0;
    div_req = 1'b0; div_a = '0; div_b = '0;
    case (kst)
      K_TEST: begin mul_req = 1'b1; mul_a = pz[tq]; mul_b = plane_a; end
      K_CLIP: case (cs)
        4'd0: begin mul_req = 1'b1; mul_a = bz;    mul_b = plane_a; end
        4'd1: begin add_req = 1'b1; add_a = c_num; add_b = b_v;  add_sub = 1'b1; end
        4'd2: begin add_req = 1'b1; add_a = bz;    add_b = az;    add_sub = 1'b1; end
        4'd3: begin mul_req = 1'b1; mul_a = c_den; mul_b = plane_a; end
        4'd4: begin add_req = 1'b1; add_a = b_v;   add_b = a_v;   add_sub = 1'b1; end
        4'd5: begin add_req = 1'b1; add_a = c_den; add_b = c_m1;  add_sub = 1'b1; end
        4'd6: begin div_req = 1'b1; div_a = c_num; div_b = c_den; end
        4'd7: begin add_req = 1'b1; add_a = F_ONE; add_b = c_t;   add_sub = 1'b1; end
        // the three lerps, two multiplies and an add each
        4'd8:  begin mul_req = 1'b1;
                     mul_a = (c_axis == 2'd0) ? ax : (c_axis == 2'd1) ? ay : az;
                     mul_b = c_t; end
        4'd9:  begin mul_req = 1'b1;
                     mul_a = (c_axis == 2'd0) ? bx : (c_axis == 2'd1) ? by : bz;
                     mul_b = c_u; end
        4'd10: begin add_req = 1'b1; add_a = c_m1; add_b = c_m2; end
        default: ;
      endcase
      default: ;
    endcase
  end

  assign pj_valid = (kst == K_PROJ);
  assign pj_x = px[cp_dst]; assign pj_y = py[cp_dst]; assign pj_z = pz[cp_dst];

  assign out_sx0 = psx[q0]; assign out_sy0 = psy[q0];
  assign out_sx1 = psx[q1]; assign out_sy1 = psy[q1];
  assign out_sx2 = psx[q2]; assign out_sy2 = psy[q2];
  assign out_sx3 = psx[q3]; assign out_sy3 = psy[q3];
  assign out_valid = (kst == K_EMIT);

  // ---------------------------------------------------------------- sequencer
  //
  // Depth first over the four planes. A quad is popped, tested against this
  // level's plane, and either passed to the next level whole, dropped, or cut
  // into one or two children whose new vertices are created here.
  //
  // MAME's case analysis, after rotating so pt[0] is outside and pt[3] is in:
  //
  //   out 0,1,2   clip(2,3) clip(3,0)            -> one triangle
  //   out 0,1     clip(1,2) clip(3,0)            -> one quad
  //   out 0,2     clip(0,1) clip(1,2)            -> two triangles
  //               clip(2,3) clip(3,0)               ("shouldn't happen")
  //   out 0       clip(0,1) clip(3,0)            -> a quad and a triangle
  //
  // A triangle is a quad with its last vertex repeated, which is what
  // fclip_push_quad_next does and what the fill unit already expects.
  logic [1:0] ccase;
  logic       second_child;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      kst <= K_IDLE; sp <= '0; ti <= '0; cs <= '0; cn <= '0; cn_want <= '0;
      lvl <= '0; q0 <= '0; q1 <= '0; q2 <= '0; q3 <= '0; is_out <= '0;
      rot <= '0; r0 <= '0; r1 <= '0; r2 <= '0; r3 <= '0; ro <= '0;
      cp_a <= '0; cp_b <= '0; cp_dst <= '0;
      mk0 <= '0; mk1 <= '0; mk2 <= '0; mk3 <= '0;
      c_num <= '0; c_den <= '0; c_t <= '0; c_u <= '0;
      c_m1 <= '0; c_m2 <= '0; c_axis <= '0; t_zprod <= '0;
      ccase <= '0; second_child <= 1'b0;
      dbg_in_r <= '0; dbg_out <= '0; dbg_dropped <= '0;
      for (int i = 0; i < NPOOL; i++) begin
        px[i] <= '0; py[i] <= '0; pz[i] <= '0; psx[i] <= '0; psy[i] <= '0;
      end
      for (int i = 0; i < NSTK; i++) begin
        st_lvl[i] <= '0; st_p0[i] <= '0; st_p1[i] <= '0;
        st_p2[i] <= '0; st_p3[i] <= '0;
      end
    end else begin
      case (kst)
        K_IDLE: if (in_valid) begin
          px[0] <= in_x0; py[0] <= in_y0; pz[0] <= in_z0;
          px[1] <= in_x1; py[1] <= in_y1; pz[1] <= in_z1;
          px[2] <= in_x2; py[2] <= in_y2; pz[2] <= in_z2;
          px[3] <= in_x3; py[3] <= in_y3; pz[3] <= in_z3;
          psx[0] <= in_sx0; psy[0] <= in_sy0;
          psx[1] <= in_sx1; psy[1] <= in_sy1;
          psx[2] <= in_sx2; psy[2] <= in_sy2;
          psx[3] <= in_sx3; psy[3] <= in_sy3;
          st_lvl[0] <= 3'd0;
          st_p0[0] <= PW'(0); st_p1[0] <= PW'(1);
          st_p2[0] <= PW'(2); st_p3[0] <= PW'(3);
          sp   <= 4'd1;
          if (dbg_in_r != 16'hffff) dbg_in_r <= dbg_in_r + 16'd1;
          kst  <= K_POP;
        end

        K_POP: if (sp == 4'd0) kst <= K_IDLE;
        else begin
          lvl <= st_lvl[sp - 4'd1];
          q0  <= st_p0[sp - 4'd1]; q1 <= st_p1[sp - 4'd1];
          q2  <= st_p2[sp - 4'd1]; q3 <= st_p3[sp - 4'd1];
          sp  <= sp - 4'd1;
          ti  <= '0;
          kst <= (st_lvl[sp - 4'd1] == 3'd4) ? K_EMIT : K_TEST;
        end

        // One multiply and a float compare per vertex. The compare is
        // sign-magnitude, so an integer compare would be wrong across zero.
        K_TEST:  if (mul_gnt) kst <= K_TESTW;
        K_TESTW: if (mul_rsp) begin
          is_out[ti] <= plane_gt ? fgt(test_v, mul_res) : fgt(mul_res, test_v);
          if (ti == 2'd3) kst <= K_DECIDE;
          else begin ti <= ti + 2'd1; kst <= K_TEST; end
        end

        K_DECIDE: begin
          if (is_out == 4'b0000) begin
            // Wholly inside: straight to the next plane, nothing created.
            st_lvl[sp] <= lvl + 3'd1;
            st_p0[sp] <= q0; st_p1[sp] <= q1; st_p2[sp] <= q2; st_p3[sp] <= q3;
            sp  <= sp + 4'd1;
            kst <= K_POP;
          end else if (is_out == 4'b1111) begin
            // Wholly outside. This is the branch that stops off-screen quads
            // reaching the store at all.
            if (dbg_dropped != 16'hffff) dbg_dropped <= dbg_dropped + 16'd1;
            kst <= K_POP;
          end else kst <= K_ROT;
        end

        // Find n so that point n is clipped and n-1 is not, and rotate.
        K_ROT: begin
          automatic logic [1:0] i;
          i = 2'd0;
          for (int k = 3; k >= 0; k--)
            if (is_out[k] && !is_out[(k + 3) & 3]) i = 2'(k);
          rot <= i;
          r0 <= sel4(i + 2'd0); r1 <= sel4(i + 2'd1);
          r2 <= sel4(i + 2'd2); r3 <= sel4(i + 2'd3);
          ro <= {is_out[(i + 2'd3) & 2'd3], is_out[(i + 2'd2) & 2'd3],
                 is_out[(i + 2'd1) & 2'd3], is_out[i]};
          cn <= '0; second_child <= 1'b0;
          // The case, from the rotated out-flags. ro[0] is always 1 and ro[3]
          // always 0 by construction, so only the middle two choose.
          ccase <= is_out[(i + 2'd1) & 2'd3]
                     ? (is_out[(i + 2'd2) & 2'd3] ? 2'd0 : 2'd1)
                     : (is_out[(i + 2'd2) & 2'd3] ? 2'd2 : 2'd3);
          cn_want <= is_out[(i + 2'd1) & 2'd3] ? 2'd2
                   : (is_out[(i + 2'd2) & 2'd3] ? 2'd0 : 2'd2);   // 0 means four
          kst <= K_SET;
        end

        // The edge this clip cuts, and where the new vertex lands. One slot per
        // clip within this level's four.
        K_SET: begin
          cp_a   <= edge_a(ccase, cn);
          cp_b   <= edge_b(ccase, cn);
          cp_dst <= lvl_base + PW'({3'd0, cn});
          cs     <= '0;
          c_axis <= '0;
          kst    <= K_CLIP;
        end

        // One created vertex. The same eleven steps for all four planes, with
        // the tested coordinate muxed between x and y - see the datapath above.
        K_CLIP: begin
          case (cs)
            4'd0:  if (mul_gnt) kst <= K_CLIPW;
            4'd3:  if (mul_gnt) kst <= K_CLIPW;
            4'd6:  if (div_gnt) kst <= K_CLIPW;
            4'd8:  if (mul_gnt) kst <= K_CLIPW;
            4'd9:  if (mul_gnt) kst <= K_CLIPW;
            default: if (add_gnt) kst <= K_CLIPW;
          endcase
        end

        K_CLIPW: begin
          case (cs)
            4'd0:  if (mul_rsp) begin c_num <= mul_res; cs <= 4'd1; kst <= K_CLIP; end
            4'd1:  if (add_rsp) begin c_num <= add_res; cs <= 4'd2; kst <= K_CLIP; end
            4'd2:  if (add_rsp) begin c_den <= add_res; cs <= 4'd3; kst <= K_CLIP; end
            4'd3:  if (mul_rsp) begin c_den <= mul_res; cs <= 4'd4; kst <= K_CLIP; end
            4'd4:  if (add_rsp) begin c_m1  <= add_res; cs <= 4'd5; kst <= K_CLIP; end
            4'd5:  if (add_rsp) begin c_den <= add_res; cs <= 4'd6; kst <= K_CLIP; end
            4'd6:  if (div_rsp) begin c_t   <= div_res; cs <= 4'd7; kst <= K_CLIP; end
            4'd7:  if (add_rsp) begin c_u   <= add_res; cs <= 4'd8; kst <= K_CLIP; end
            4'd8:  if (mul_rsp) begin c_m1  <= mul_res; cs <= 4'd9; kst <= K_CLIP; end
            4'd9:  if (mul_rsp) begin c_m2  <= mul_res; cs <= 4'd10; kst <= K_CLIP; end
            default: if (add_rsp) begin
              case (c_axis)
                2'd0:    px[cp_dst] <= add_res;
                2'd1:    py[cp_dst] <= add_res;
                default: pz[cp_dst] <= add_res;
              endcase
              if (c_axis == 2'd2) kst <= K_PROJ;
              else begin c_axis <= c_axis + 2'd1; cs <= 4'd8; kst <= K_CLIP; end
            end
          endcase
        end

        // MAME projects a created vertex immediately, inside the clip function.
        K_PROJ:  if (pj_ready) kst <= K_PROJW;
        K_PROJW: if (pj_out_valid) begin
          // Sixteen bits is enough: a clipped vertex is inside the viewport by
          // construction, which is the whole reason the store can keep 16.
          psx[cp_dst] <= pj_out_sx[15:0];
          psy[cp_dst] <= pj_out_sy[15:0];
          case (cn)
            2'd0:    mk0 <= cp_dst;
            2'd1:    mk1 <= cp_dst;
            2'd2:    mk2 <= cp_dst;
            default: mk3 <= cp_dst;
          endcase
          if ((cn_want == 2'd0 && cn == 2'd3) ||
              (cn_want == 2'd2 && cn == 2'd1)) kst <= K_CHILD;
          else begin cn <= cn + 2'd1; kst <= K_SET; end
        end

        // Push the case's children, at the next level. A triangle is a quad
        // with its last vertex repeated, exactly as fclip_push_quad_next does.
        K_CHILD: begin
          st_lvl[sp] <= lvl + 3'd1;
          case (ccase)
            2'd0: begin st_p0[sp] <= mk0; st_p1[sp] <= r3;
                        st_p2[sp] <= mk1; st_p3[sp] <= mk1; end
            2'd1: begin st_p0[sp] <= mk0; st_p1[sp] <= r2;
                        st_p2[sp] <= r3;  st_p3[sp] <= mk1; end
            2'd2: if (!second_child) begin
                        st_p0[sp] <= mk0; st_p1[sp] <= r1;
                        st_p2[sp] <= mk1; st_p3[sp] <= mk1; end
                  else begin
                        st_p0[sp] <= mk2; st_p1[sp] <= r3;
                        st_p2[sp] <= mk3; st_p3[sp] <= mk3; end
            default: if (!second_child) begin
                        st_p0[sp] <= mk0; st_p1[sp] <= r1;
                        st_p2[sp] <= r2;  st_p3[sp] <= r3; end
                  else begin
                        st_p0[sp] <= r3;  st_p1[sp] <= mk1;
                        st_p2[sp] <= mk0; st_p3[sp] <= mk0; end
          endcase
          sp <= sp + 4'd1;
          if ((ccase == 2'd2 || ccase == 2'd3) && !second_child) begin
            second_child <= 1'b1;
          end else kst <= K_POP;
        end

        K_EMIT: if (out_ready) begin
          if (dbg_out != 16'hffff) dbg_out <= dbg_out + 16'd1;
          kst <= K_POP;
        end

        default: kst <= K_IDLE;
      endcase
    end
  end

  // The two endpoints of the edge each clip cuts, per case and per clip index.
  // Straight from fclip_push_quad's four branches.
  function automatic [PW-1:0] edge_a(input logic [1:0] c, input logic [1:0] n);
    case (c)
      2'd0:    edge_a = (n == 2'd0) ? r2 : r3;
      2'd1:    edge_a = (n == 2'd0) ? r1 : r3;
      2'd2:    edge_a = (n == 2'd0) ? r0 : (n == 2'd1) ? r1 : (n == 2'd2) ? r2 : r3;
      default: edge_a = (n == 2'd0) ? r0 : r3;
    endcase
  endfunction
  function automatic [PW-1:0] edge_b(input logic [1:0] c, input logic [1:0] n);
    case (c)
      2'd0:    edge_b = (n == 2'd0) ? r3 : r0;
      2'd1:    edge_b = (n == 2'd0) ? r2 : r0;
      2'd2:    edge_b = (n == 2'd0) ? r1 : (n == 2'd1) ? r2 : (n == 2'd2) ? r3 : r0;
      default: edge_b = (n == 2'd0) ? r1 : r0;
    endcase
  endfunction

  // Rotation helper: the quad's vertices by index, modulo four.
  function automatic [PW-1:0] sel4(input logic [1:0] k);
    case (k)
      2'd0:    sel4 = q0;
      2'd1:    sel4 = q1;
      2'd2:    sel4 = q2;
      default: sel4 = q3;
    endcase
  endfunction

endmodule
