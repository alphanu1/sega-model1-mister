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
// The polygon record walker: push_object (model1_v.cpp:856-1110).
//
// This is the piece that turns "draw object at this address" into quads. It
// reads the model out of the polygon ROM, drives the transform, the backface
// test, the projection, the normalize and the colour unit, and emits a screen-
// space quad for every record that survives.
//
// THE MODEL IS A STRIP, NOT A LIST OF POLYGONS
//
// A six-float header gives two points, and then every 10-float record adds two
// more; the quad is built from the PREVIOUS pair and the new pair. Which of the
// previous pair survives is the record's `link` field:
//
//     link 0   emit nothing, and replace both       (a new strip starts)
//     link 1   replace old_p1 with p0               (fan around old_p0)
//     link 2   replace both                         (ordinary strip advance)
//     link 3   replace old_p0 with p1
//
// link 0 is the one that matters for the budget: it emits NO quad, and 1,033 of
// 5,831 records in a peak frame are link 0 (tools/mame_poly_budget.lua).
//
// THE QUAD'S WINDING IS (old_p1, old_p0, p0, p1) AND NOT THE OBVIOUS ORDER.
// old_p1 first, then old_p0 - the previous pair reversed. The backface
// determinant is taken on (old_p1, old_p0, p0) in that same order, so getting
// the winding "right" would inverte the cull and show the inside of every model.
//
// `old_z` PERSISTS ACROSS OBJECTS, not just across records. MAME's own comment
// (model1_v.cpp:846) says netmerc's garage door inherits the previous object's
// sort z and resetting it per object made it paint through a wall. So it is an
// input and an output of this module, carried by the caller.

`timescale 1ns/1ps

module m1_geo_walk (
  input  logic        clk,
  input  logic        rst_n,

  // One object. tex_adr/poly_adr/size are the display list's command 1 payload.
  input  logic        start,
  input  logic [31:0] in_tex_adr,
  input  logic [31:0] in_poly_adr,
  input  logic [31:0] in_size,
  output logic        busy,
  output logic        done,

  // The flat-z register, carried across objects by the caller.
  input  logic [31:0] old_z_in,
  output logic [31:0] old_z_out,

  // Polygon ROM, 32-bit words. Held request, one word at a time.
  output logic [22:0] rom_addr,
  output logic        rom_req,
  input  logic        rom_valid,
  input  logic [31:0] rom_data,

  // tgp_ram, for the colour word. Registered read.
  output logic [19:0] tex_addr,
  input  logic [15:0] tex_data,

  // Light parameter bank, indexed by the record's lightmode. Registered read.
  output logic [7:0]  lp_addr,
  input  logic [31:0] lp_d, lp_a, lp_s,
  input  logic [7:0]  lp_p,

  input  logic        frame_odd,

  // ---- sub-stage handshakes, wired to the instances in m1_geometry
  output logic        xf_valid,
  input  logic        xf_ready,
  output logic [31:0] xf_x, xf_y, xf_z,
  output logic        xf_translate,
  input  logic        xf_out_valid,
  input  logic [31:0] xf_out_x, xf_out_y, xf_out_z,

  output logic        pj_valid,
  input  logic        pj_ready,
  output logic [31:0] pj_x, pj_y, pj_z,
  input  logic        pj_out_valid,
  input  logic signed [31:0] pj_out_sx, pj_out_sy,

  output logic        dt_valid,
  input  logic        dt_ready,
  output logic [31:0] dt_p1x, dt_p1y, dt_p1z,
  output logic [31:0] dt_p2x, dt_p2y, dt_p2z,
  output logic [31:0] dt_p3x, dt_p3y, dt_p3z,
  input  logic        dt_out_valid,
  input  logic        dt_out_positive,

  output logic        nm_valid,
  input  logic        nm_ready,
  output logic [31:0] nm_x, nm_y, nm_z,
  input  logic        nm_out_valid,
  input  logic [31:0] nm_out_x, nm_out_y, nm_out_z,

  output logic        cl_valid,
  input  logic        cl_ready,
  output logic [31:0] cl_nx, cl_ny, cl_nz,
  output logic [15:0] cl_tex,
  output logic [31:0] cl_lp_d, cl_lp_a, cl_lp_s,
  output logic [7:0]  cl_lp_p,
  input  logic        cl_out_valid,
  input  logic [23:0] cl_out_rgb,

  // ---- quad out, in screen space
  output logic        q_valid,
  output logic signed [31:0] q_x0, q_y0, q_x1, q_y1,
  output logic signed [31:0] q_x2, q_y2, q_x3, q_y3,
  output logic [23:0] q_col,
  output logic [31:0] q_z,
  output logic        q_moire,

  // Counted, for the bench and the overlay.
  output logic [15:0] dbg_records,
  output logic [15:0] dbg_quads,
  output logic [15:0] dbg_culled,
  output logic [15:0] dbg_nolink
);

  // ---------------------------------------------------------------- state
  typedef enum logic [4:0] {
    W_IDLE,
    W_HDR_RD, W_HDR_XF, W_HDR_XFW, W_HDR_PJ, W_HDR_PJW,
    W_REC_RD, W_REC_DEC,
    W_XF_VN, W_XF_VNW, W_XF_P0, W_XF_P0W, W_XF_P1, W_XF_P1W,
    W_PJ_P0, W_PJ_P0W, W_PJ_P1, W_PJ_P1W,
    W_DET, W_DETW,
    W_NORM, W_NORMW,
    W_TEX, W_COL, W_COLW,
    W_EMIT, W_NEXT, W_DONE
  } state_t;
  state_t st;

  logic [22:0] padr;              // polygon ROM word address
  logic [31:0] tadr;              // texture address, incremented by flag 0x1000
  logic [31:0] nleft;             // records remaining, from `size`
  logic [31:0] rec [10];          // the record being decoded
  logic [3:0]  wi;                // words read into rec
  logic [2:0]  hdr_i;             // header point index
  logic [31:0] flags;
  logic [1:0]  link;
  logic [1:0]  zmode;
  logic        moire;
  logic        nocull;
  logic [31:0] oldz;

  // Camera-space and screen-space points. o0/o1 are old_p0/old_p1.
  logic [31:0] o0x, o0y, o0z, o1x, o1y, o1z;
  logic signed [31:0] o0sx, o0sy, o1sx, o1sy;
  logic [31:0] n0x, n0y, n0z, n1x, n1y, n1z;
  logic signed [31:0] n0sx, n0sy, n1sx, n1sy;
  logic [31:0] vnx, vny, vnz;
  logic [31:0] nvx, nvy, nvz;      // normalized
  logic [1:0]  xf_which;           // 0 = vn, 1 = p0, 2 = p1
  logic [31:0] qz;

  assign busy      = (st != W_IDLE);
  assign rom_addr  = padr;
  assign rom_req   = (st == W_HDR_RD) || (st == W_REC_RD);
  // MAME indexes `m_tgp_ram[tex_adr - 0x40000]`, so the BASE IS SUBTRACTED here.
  // Without it every colour word is read from 0x40000 words too high, which on a
  // real dump returns 0xffff - a valid-looking colour word with the unlit bit
  // set - so the geometry is perfect and the entire picture comes out one shade.
  // Found by rendering a real frame, not by any unit test: the per-stage benches
  // supply tex_data directly and cannot see the address arithmetic.
  assign tex_addr  = tadr[19:0] - 20'h40000;
  assign old_z_out = oldz;

  // lightmode: bits 20:17 of the flags, with bit 22 selecting the second bank.
  // netmerc is the only game that sets bit 22, but it costs one wire.
  assign lp_addr = {flags[22], 3'b000, flags[20:17]};

  assign cl_nx = nvx; assign cl_ny = nvy; assign cl_nz = nvz;
  assign cl_tex = tex_data;
  assign cl_lp_d = lp_d; assign cl_lp_a = lp_a; assign cl_lp_s = lp_s;
  assign cl_lp_p = lp_p;

  assign dt_p1x = o1x; assign dt_p1y = o1y; assign dt_p1z = o1z;
  assign dt_p2x = o0x; assign dt_p2y = o0y; assign dt_p2z = o0z;
  assign dt_p3x = n0x; assign dt_p3y = n0y; assign dt_p3z = n0z;

  assign nm_x = vnx; assign nm_y = vny; assign nm_z = vnz;

  // ---------------------------------------------------------------- float min/max
  // IEEE floats compare as sign-magnitude, so a plain integer compare is wrong
  // across zero. The standard monotonic key: negatives inverted, positives with
  // the sign bit set.
  function automatic [31:0] fkey(input logic [31:0] f);
    fkey = f[31] ? ~f : (f | 32'h80000000);
  endfunction
  function automatic [31:0] fmin(input logic [31:0] a, input logic [31:0] b);
    fmin = (fkey(a) < fkey(b)) ? a : b;
  endfunction
  function automatic [31:0] fmax(input logic [31:0] a, input logic [31:0] b);
    fmax = (fkey(a) > fkey(b)) ? a : b;
  endfunction

  wire [31:0] z_min4 = fmin(fmin(o1z, o0z), fmin(n0z, n1z));
  wire [31:0] z_max4 = fmax(fmax(o1z, o0z), fmax(n0z, n1z));

  // ---------------------------------------------------------------- transform mux
  always_comb begin
    xf_x = '0; xf_y = '0; xf_z = '0; xf_translate = 1'b1;
    case (st)
      W_HDR_XF: begin
        // The header's two points, straight out of the ROM.
        xf_x = rec[{1'b0, hdr_i} * 4'd3];
        xf_y = rec[{1'b0, hdr_i} * 4'd3 + 4'd1];
        xf_z = rec[{1'b0, hdr_i} * 4'd3 + 4'd2];
        xf_translate = 1'b1;
      end
      W_XF_VN: begin
        // A NORMAL IS A DIRECTION: transform_vector, no translation column.
        xf_x = rec[1]; xf_y = rec[2]; xf_z = rec[3];
        xf_translate = 1'b0;
      end
      W_XF_P0: begin xf_x = rec[4]; xf_y = rec[5]; xf_z = rec[6]; end
      // A type-2 record has only ONE new point: p1 is a copy of p0, so the same
      // model coordinates go through the transform twice rather than reading
      // words 7..9, which for that record are not a point at all.
      W_XF_P1: begin
        if (flags[1:0] == 2'd2) begin
          xf_x = rec[4]; xf_y = rec[5]; xf_z = rec[6];
        end else begin
          xf_x = rec[7]; xf_y = rec[8]; xf_z = rec[9];
        end
      end
      default: ;
    endcase
  end

  assign xf_valid = (st == W_HDR_XF) || (st == W_XF_VN)
                 || (st == W_XF_P0)  || (st == W_XF_P1);

  // ---------------------------------------------------------------- projection mux
  always_comb begin
    pj_x = '0; pj_y = '0; pj_z = '0;
    case (st)
      W_HDR_PJ: begin
        pj_x = (hdr_i == 3'd1) ? o0x : o1x;
        pj_y = (hdr_i == 3'd1) ? o0y : o1y;
        pj_z = (hdr_i == 3'd1) ? o0z : o1z;
      end
      W_PJ_P0: begin pj_x = n0x; pj_y = n0y; pj_z = n0z; end
      W_PJ_P1: begin pj_x = n1x; pj_y = n1y; pj_z = n1z; end
      default: ;
    endcase
  end
  assign pj_valid = (st == W_HDR_PJ) || (st == W_PJ_P0) || (st == W_PJ_P1);

  assign dt_valid = (st == W_DET);
  assign nm_valid = (st == W_NORM);
  assign cl_valid = (st == W_COL);

  // ---------------------------------------------------------------- sequencer
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= W_IDLE;
      padr <= '0; tadr <= '0; nleft <= '0; wi <= '0; hdr_i <= '0;
      flags <= '0; link <= '0; zmode <= '0; moire <= 1'b0; nocull <= 1'b0;
      oldz <= '0; qz <= '0; xf_which <= '0;
      o0x <= '0; o0y <= '0; o0z <= '0; o1x <= '0; o1y <= '0; o1z <= '0;
      o0sx <= '0; o0sy <= '0; o1sx <= '0; o1sy <= '0;
      n0x <= '0; n0y <= '0; n0z <= '0; n1x <= '0; n1y <= '0; n1z <= '0;
      n0sx <= '0; n0sy <= '0; n1sx <= '0; n1sy <= '0;
      vnx <= '0; vny <= '0; vnz <= '0; nvx <= '0; nvy <= '0; nvz <= '0;
      for (int i = 0; i < 10; i++) rec[i] <= '0;
      q_valid <= 1'b0; q_col <= '0; q_z <= '0; q_moire <= 1'b0;
      q_x0 <= '0; q_y0 <= '0; q_x1 <= '0; q_y1 <= '0;
      q_x2 <= '0; q_y2 <= '0; q_x3 <= '0; q_y3 <= '0;
      done <= 1'b0;
      dbg_records <= '0; dbg_quads <= '0; dbg_culled <= '0; dbg_nolink <= '0;
    end else begin
      q_valid <= 1'b0;
      done    <= 1'b0;

      case (st)
        W_IDLE: if (start) begin
          // push_object's own guards: a texture address of 0xffffffff or an
          // absurd size is bad data and the object is skipped entirely.
          if (in_tex_adr == 32'hffffffff || in_size >= 32'h01000000) begin
            done <= 1'b1;
          end else begin
            padr  <= in_poly_adr[22:0];
            tadr  <= in_tex_adr;
            // `if (!size) size = 0xffffffff` - zero means "until the terminator".
            nleft <= (in_size == 32'd0) ? 32'hffffffff : in_size;
            oldz  <= old_z_in;
            wi    <= '0; hdr_i <= '0;
            dbg_records <= '0; dbg_quads <= '0;
            dbg_culled  <= '0; dbg_nolink <= '0;
            st    <= W_HDR_RD;
          end
        end

        // ---- six-float header: two points
        W_HDR_RD: if (rom_valid) begin
          rec[wi] <= rom_data;
          padr    <= padr + 23'd1;
          if (wi == 4'd5) begin wi <= '0; hdr_i <= '0; st <= W_HDR_XF; end
          else            wi <= wi + 4'd1;
        end
        W_HDR_XF:  if (xf_ready) st <= W_HDR_XFW;
        W_HDR_XFW: if (xf_out_valid) begin
          if (hdr_i == 3'd0) begin o0x <= xf_out_x; o0y <= xf_out_y; o0z <= xf_out_z; end
          else               begin o1x <= xf_out_x; o1y <= xf_out_y; o1z <= xf_out_z; end
          if (hdr_i == 3'd1) begin hdr_i <= 3'd1; st <= W_HDR_PJ; end
          else               begin hdr_i <= 3'd1; st <= W_HDR_XF; end
        end
        W_HDR_PJ:  if (pj_ready) st <= W_HDR_PJW;
        W_HDR_PJW: if (pj_out_valid) begin
          if (hdr_i == 3'd1) begin
            o0sx <= pj_out_sx; o0sy <= pj_out_sy;
            hdr_i <= 3'd2; st <= W_HDR_PJ;
          end else begin
            o1sx <= pj_out_sx; o1sy <= pj_out_sy;
            wi <= '0; st <= W_REC_RD;
          end
        end

        // ---- ten-float record
        W_REC_RD: if (rom_valid) begin
          rec[wi] <= rom_data;
          padr    <= padr + 23'd1;
          if (wi == 4'd9) begin wi <= '0; st <= W_REC_DEC; end
          else            wi <= wi + 4'd1;
        end

        W_REC_DEC: begin
          flags  <= rec[0];
          link   <= rec[0][9:8];
          zmode  <= rec[0][11:10];
          moire  <= rec[0][13];
          nocull <= rec[0][14];
          if (rec[0][12]) tadr <= tadr + 32'd1;     // flag 0x1000
          if (dbg_records != 16'hffff) dbg_records <= dbg_records + 16'd1;
          // `type = flags & 3; if (!type) break;` - and the size limit.
          if (rec[0][1:0] == 2'd0 || nleft == 32'd0) st <= W_DONE;
          else begin
            nleft <= nleft - 32'd1;
            st    <= W_XF_VN;
          end
        end

        W_XF_VN:  if (xf_ready) st <= W_XF_VNW;
        W_XF_VNW: if (xf_out_valid) begin
          vnx <= xf_out_x; vny <= xf_out_y; vnz <= xf_out_z;
          st  <= W_XF_P0;
        end
        W_XF_P0:  if (xf_ready) st <= W_XF_P0W;
        W_XF_P0W: if (xf_out_valid) begin
          n0x <= xf_out_x; n0y <= xf_out_y; n0z <= xf_out_z;
          st  <= W_XF_P1;
        end
        W_XF_P1:  if (xf_ready) st <= W_XF_P1W;
        W_XF_P1W: if (xf_out_valid) begin
          n1x <= xf_out_x; n1y <= xf_out_y; n1z <= xf_out_z;
          st  <= W_PJ_P0;
        end

        W_PJ_P0:  if (pj_ready) st <= W_PJ_P0W;
        W_PJ_P0W: if (pj_out_valid) begin
          n0sx <= pj_out_sx; n0sy <= pj_out_sy;
          st   <= W_PJ_P1;
        end
        W_PJ_P1:  if (pj_ready) st <= W_PJ_P1W;
        W_PJ_P1W: if (pj_out_valid) begin
          n1sx <= pj_out_sx; n1sy <= pj_out_sy;
          // `if (!link) goto next;` - nothing is drawn, but the strip still
          // advances, so this is not the same as skipping the record.
          if (link == 2'd0) begin
            if (dbg_nolink != 16'hffff) dbg_nolink <= dbg_nolink + 16'd1;
            st <= W_NEXT;
          end else if (nocull) begin
            st <= W_NORM;                      // flag 0x4000 skips the test
          end else begin
            st <= W_DET;
          end
        end

        W_DET:  if (dt_ready) st <= W_DETW;
        W_DETW: if (dt_out_valid) begin
          if (dt_out_positive) begin
            // `view_determinant(...) > 0` culls.
            if (dbg_culled != 16'hffff) dbg_culled <= dbg_culled + 16'd1;
            st <= W_NEXT;
          end else begin
            st <= W_NORM;
          end
        end

        W_NORM:  if (nm_ready) st <= W_NORMW;
        W_NORMW: if (nm_out_valid) begin
          nvx <= nm_out_x; nvy <= nm_out_y; nvz <= nm_out_z;
          // The sort z, chosen by flags bits 11:10. Mode 0 REUSES the previous
          // quad's z, which is why old_z is carried across objects.
          case (zmode)
            2'd0: qz <= oldz;
            2'd1: begin qz <= z_min4; oldz <= z_min4; end
            2'd2: begin qz <= z_max4; oldz <= z_max4; end
            default: qz <= 32'd0;
          endcase
          st <= W_TEX;
        end

        // tex_addr has been driven since the record was decoded; one cycle here
        // covers the registered read of both tgp_ram and the light bank.
        W_TEX: st <= W_COL;

        W_COL:  if (cl_ready) st <= W_COLW;
        W_COLW: if (cl_out_valid) begin
          q_col <= cl_out_rgb;
          st    <= W_EMIT;
        end

        W_EMIT: begin
          // (old_p1, old_p0, p0, p1) - the previous pair REVERSED. Matching the
          // determinant's argument order; the obvious winding inverts the cull.
          q_x0 <= o1sx; q_y0 <= o1sy;
          q_x1 <= o0sx; q_y1 <= o0sy;
          q_x2 <= n0sx; q_y2 <= n0sy;
          q_x3 <= n1sx; q_y3 <= n1sy;
          q_z     <= qz;
          q_moire <= moire;
          q_valid <= 1'b1;
          if (dbg_quads != 16'hffff) dbg_quads <= dbg_quads + 16'd1;
          st <= W_NEXT;
        end

        W_NEXT: begin
          // The strip advance. link 0 and 2 replace both points, 1 replaces
          // old_p1 with p0, 3 replaces old_p0 with p1.
          case (link)
            2'd0, 2'd2: begin
              o0x <= n0x; o0y <= n0y; o0z <= n0z; o0sx <= n0sx; o0sy <= n0sy;
              o1x <= n1x; o1y <= n1y; o1z <= n1z; o1sx <= n1sx; o1sy <= n1sy;
            end
            2'd1: begin
              o1x <= n0x; o1y <= n0y; o1z <= n0z; o1sx <= n0sx; o1sy <= n0sy;
            end
            default: begin
              o0x <= n1x; o0y <= n1y; o0z <= n1z; o0sx <= n1sx; o0sy <= n1sy;
            end
          endcase
          wi <= '0;
          st <= W_REC_RD;
        end

        W_DONE: begin
          done <= 1'b1;
          st   <= W_IDLE;
        end

        default: st <= W_IDLE;
      endcase
    end
  end

endmodule
