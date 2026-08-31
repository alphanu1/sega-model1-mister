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
// The quad store and the painter's sort.
//
// Model 1 has no Z-buffer: draw_quads paints z DESCENDING with ties broken by
// submission order (quad_t::compare, model1_v.cpp:535), so every quad of a
// viewport has to be collected before any of it can be drawn. This holds them,
// sorts them, and replays them in order - once per band, because the band buffer
// covers 64 of 384 rows and the same list is walked for each.
//
// WHY A RADIX SORT AND NOT A COMPARISON SORT
//
// A comparison sort needs the quads reachable in a random order while it works.
// An LSD radix sort touches them strictly in sequence and only ever moves an
// INDEX, so the quads themselves sit still in one wide memory and the sort works
// on 11-bit indices - two arrays of 2,048, which is a handful of M10K rather than
// a second copy of the store. Four passes of eight bits over a 32-bit key is
// 4 x 2,048 reads and writes, nothing against a frame.
//
// It is also STABLE, which is what makes the tie-break free: MAME resolves equal
// z by submission order, and a stable sort that starts in submission order keeps
// it without the key ever mentioning it.
//
// THE KEY IS THE FLOAT, MADE MONOTONIC. IEEE floats compare as sign-magnitude, so
// a raw integer compare is wrong across zero. The standard transform - invert a
// negative entirely, set the sign bit of a positive - makes the unsigned integer
// order match the float order. Then the key is COMPLEMENTED, because the sort is
// ascending and the painter wants descending.
//
// OVERFLOW IS COUNTED, NOT SILENT. A frame with more quads than the store holds
// drops the excess and says so. A real frame measured 2,001 quads and a peak frame
// 4,798 records of which not all emit, so 2,048 is the right order and the counter
// is how we find out if it is not.

`timescale 1ns/1ps

module m1_quad_store #(
  parameter int unsigned NQ     = 2048,      // quads held
  parameter int unsigned IW     = 11,        // ceil(log2(NQ))
  // THE BAND GEOMETRY IS A PARAMETER, not three hardcoded constants.
  //
  // It was written for six 64-row bands: a 6-bit mask, a 3-bit band select, and
  // a row-to-band index of `y[8:6]`. Halving the band height to 32 for the sound
  // M10K budget left all three untouched, so bands 6..11 had no mask bit, the
  // select could not address them, and a 3-bit counter compared against
  // 3'(12-1) = 3 stopped the frame dead after band 3. The picture was correct as
  // far as it went and simply ended a quarter of the way down.
  parameter int unsigned BAND_H = 32,
  parameter int unsigned NBANDS = 12,
  parameter int unsigned BW     = 4,         // ceil(log2(NBANDS))
  parameter int unsigned SCR_H  = 384
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- write side, from the geometry stage
  input  logic        clear,                 // start a new frame
  input  logic        in_valid,
  input  logic signed [15:0] in_x0, in_y0, in_x1, in_y1,
  input  logic signed [15:0] in_x2, in_y2, in_x3, in_y3,
  input  logic [23:0] in_col,
  input  logic [31:0] in_z,
  input  logic        in_moire,

  // ---- sort
  input  logic        sort_start,
  output logic        sort_busy,

  // ---- read side, replayed in painter's order. Restartable per band.
  //
  // BAND FILTERED. The band buffer covers 64 of 384 rows, so the sorted list is
  // walked six times a frame - and a quad that does not touch the band must not
  // cost anything to skip. Its row range is computed once on the way IN and
  // stored as a six-bit mask, so a replay pass tests one bit instead of four
  // vertices. Without it the six passes cost ~20 cycles of setup per quad per
  // band, which is 276,000 cycles of a 397,515-cycle frame spent on quads that
  // draw nothing.
  input  logic [BW-1:0] replay_band,
  input  logic        replay_start,
  output logic        replay_busy,
  input  logic        out_ready,
  output logic        out_valid,
  output logic signed [15:0] out_x0, out_y0, out_x1, out_y1,
  output logic signed [15:0] out_x2, out_y2, out_x3, out_y3,
  output logic [23:0] out_col,
  output logic        out_moire,

  output logic [15:0] dbg_count,
  output logic [15:0] dbg_dropped
);


  // Four 32-bit words a quad: two vertices, then colour and key.
  //   w0 {y0,x0}   w1 {y1,x1}   w2 {y2,x2}   w3 {y3,x3}
  // and a separate narrow array for colour+moire, and one for the sort key, so
  // the sort never reads the wide one.
  // FOUR SEPARATE MEMORIES, ONE PER VERTEX, and this is not a style choice.
  //
  // As a single `vtx [NQ*4]` array this module wrote all four vertices of a quad
  // in one cycle and read all four in one cycle. An array with four simultaneous
  // accesses cannot be a RAM, and Quartus does not say so - it builds the whole
  // 8,192 x 32 bits out of flip-flops with 8192:1 multiplexers and carries on.
  //
  // Measured: 112,742 combinational nodes in this module alone, 93% of the 3D
  // layer and 68% of the entire design, against a device that holds 83,820. The
  // first real build failed to fit at 166,497. m1_geometry, doing all the actual
  // arithmetic, is 6,238.
  //
  // One vertex per memory gives each a single write port and a single read port,
  // which is a Simple Dual Port M10K and infers cleanly. CLAUDE.md's warning that
  // "block RAM inference is silent when it fails" cost 28,816 ALM once before.
  (* ramstyle = "M10K" *) logic [31:0] vtx0 [NQ];
  (* ramstyle = "M10K" *) logic [31:0] vtx1 [NQ];
  (* ramstyle = "M10K" *) logic [31:0] vtx2 [NQ];
  (* ramstyle = "M10K" *) logic [31:0] vtx3 [NQ];
  localparam int unsigned AT_W = NBANDS + 25;   // {band_mask, moire, col}
  (* ramstyle = "M10K" *) logic [AT_W-1:0] att [NQ];
  (* ramstyle = "M10K" *) logic [31:0] key [NQ];

  // Two index arrays, ping-ponged by the radix passes.
  (* ramstyle = "M10K" *) logic [IW-1:0] idx_a [NQ];
  (* ramstyle = "M10K" *) logic [IW-1:0] idx_b [NQ];

  logic [IW:0]  count;
  assign dbg_count = {{(16-IW-1){1'b0}}, count};

  // The capacity test, written once. count is one bit wider than an index so it
  // can hold NQ itself without wrapping.
  wire has_room = (count < {1'b0, IW'(NQ-1)} + 1'b1);

  // Which of the six 64-row bands this quad's rows touch. Computed from the
  // vertex extremes, clamped: a quad above the screen or below it lands in no
  // band and is never replayed.
  function automatic [NBANDS-1:0] band_mask(input logic signed [15:0] a, b, c, d);
    logic signed [15:0] lo, hi2;
    int b0, b1;
    begin
      lo  = a;  if (b < lo)  lo  = b;  if (c < lo)  lo  = c;  if (d < lo)  lo  = d;
      hi2 = a;  if (b > hi2) hi2 = b;  if (c > hi2) hi2 = c;  if (d > hi2) hi2 = d;
      if (hi2 < 0 || lo > $signed(16'(SCR_H - 1))) band_mask = '0;
      else begin
        if (lo  < 0)                        lo  = 16'sd0;
        if (hi2 > $signed(16'(SCR_H - 1)))  hi2 = $signed(16'(SCR_H - 1));
        // Divide rather than a fixed bit slice: y[8:6] is a division by 64 and
        // says nothing about it, so it survives a change of band height silently.
        b0 = int'(lo)  / int'(BAND_H);
        b1 = int'(hi2) / int'(BAND_H);
        band_mask = '0;
        for (int k = 0; k < int'(NBANDS); k++)
          if (k >= b0 && k <= b1) band_mask[k] = 1'b1;
      end
    end
  endfunction

  // Monotonic key, then complemented so that ASCENDING on this key is DESCENDING
  // on z - which is the order the painter wants.
  function automatic [31:0] sort_key(input logic [31:0] f);
    logic [31:0] v;
    // NEGATIVE ZERO IS EQUAL TO POSITIVE ZERO as a float, and MAME compares
    // floats - so the two must produce the SAME key and fall to the submission
    // order tie-break. The monotonic transform alone maps them to 0x7fffffff and
    // 0x80000000, one apart, which silently orders -0.0 ahead of +0.0. zmode 3
    // writes a literal zero and zmode 0 reuses whatever came before, so both
    // signs really do arrive here.
    v = (f[30:0] == 31'd0) ? 32'd0 : f;
    sort_key = ~(v[31] ? ~v : (v | 32'h80000000));
  endfunction

  // ---------------------------------------------------------------- write
  logic [IW-1:0] wi;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      count <= '0; wi <= '0; dbg_dropped <= '0;
    end else if (clear) begin
      count <= '0; wi <= '0; dbg_dropped <= '0;
    end else if (in_valid) begin
      if (has_room) begin
        vtx0[count[IW-1:0]] <= {in_y0, in_x0};
        vtx1[count[IW-1:0]] <= {in_y1, in_x1};
        vtx2[count[IW-1:0]] <= {in_y2, in_x2};
        vtx3[count[IW-1:0]] <= {in_y3, in_x3};
        att[count[IW-1:0]] <= {band_mask(in_y0, in_y1, in_y2, in_y3),
                               in_moire, in_col};
        key[count[IW-1:0]] <= sort_key(in_z);
        count <= count + 1'b1;
      end else if (dbg_dropped != 16'hffff) begin
        dbg_dropped <= dbg_dropped + 16'd1;
      end
    end
  end

  // ---------------------------------------------------------------- radix sort
  typedef enum logic [3:0] {
    R_IDLE, R_INIT, R_CNT,
    R_CNT_A, R_CNT_B, R_CNT_C, R_CNT_D, R_CNT_E,
    R_SUM,
    R_SCAT_A, R_SCAT_B, R_SCAT_C, R_SCAT_D, R_SCAT_E,
    R_NEXT, R_DONE
  } rstate_t;
  rstate_t rst_st;

  logic [1:0]   pass;                 // which byte of the key
  logic [IW:0]  ri;
  logic [8:0]   hi;
  logic [IW:0]  hist [256];
  logic [IW:0]  base [256];
  logic [IW:0]  acc;
  logic         which;                // 0: a -> b, 1: b -> a
  logic [IW-1:0] cur_idx;
  logic [7:0]   cur_digit;

  assign sort_busy = (rst_st != R_IDLE);

  // EVERY READ OF A MEMORY IS REGISTERED, and that is not a style preference.
  //
  // An M10K has a registered read port. A continuous assignment out of an array -
  // `wire x = mem[addr];` - is an ASYNCHRONOUS read, which no block RAM can do,
  // so Quartus builds the whole array out of flip-flops and says nothing.
  //
  // Measured: key[2048] as an async read was 65,536 registers, and this module
  // carried 63,630 of the design's 93,971 while m1_geometry - doing all the
  // arithmetic - had 5,778. The fit failed needing 7,465 LABs of the device's
  // 4,191. Three arrays were being read asynchronously: the sort keys, the index
  // arrays, and the band mask out of att.
  //
  // The cost is a cycle per access, which this sequencer already had states for.
  logic [IW-1:0] idx_rd;
  logic [31:0]   key_rd;
  always_ff @(posedge clk) begin
    idx_rd <= which ? idx_b[ri[IW-1:0]] : idx_a[ri[IW-1:0]];
    key_rd <= key[cur_idx];
  end

  wire [7:0] digit = (pass == 2'd0) ? key_rd[7:0]   :
                     (pass == 2'd1) ? key_rd[15:8]  :
                     (pass == 2'd2) ? key_rd[23:16] : key_rd[31:24];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rst_st <= R_IDLE; pass <= '0; ri <= '0; hi <= '0; acc <= '0;
      which <= 1'b0; cur_idx <= '0; cur_digit <= '0;
      for (int i = 0; i < 256; i++) begin hist[i] <= '0; base[i] <= '0; end
    end else begin
      case (rst_st)
        R_IDLE: if (sort_start) begin
          pass <= '0; which <= 1'b0; ri <= '0;
          rst_st <= R_INIT;
        end

        // Submission order to start with: a stable sort then keeps it as the
        // tie-break, exactly as quad_t::compare does with the address.
        R_INIT: begin
          idx_a[ri[IW-1:0]] <= ri[IW-1:0];
          if (ri + 1 >= count) begin ri <= '0; hi <= '0; rst_st <= R_CNT; end
          else                       ri <= ri + 1'b1;
        end

        R_CNT: begin                       // clear the histogram
          hist[hi[7:0]] <= '0;
          if (hi == 9'd255) begin hi <= '0; ri <= '0; rst_st <= R_CNT_A; end
          else                     hi <= hi + 9'd1;
        end

        // FIVE CYCLES AN ELEMENT, because both memory reads are registered.
        //
        //   A  the index address (ri) is settled; idx_rd lands at the end
        //   B  take idx_rd into cur_idx, which addresses the key memory
        //   C  key_rd lands at the end
        //   D  take the digit
        //   E  bump the histogram, advance
        //
        // The asynchronous version was three cycles and kept both arrays in
        // flip-flops - 65,536 registers for the keys alone. Two cycles an element
        // is what a block RAM costs, and this runs 2,000 elements four times
        // against a 397,515-cycle frame.
        R_CNT_A: rst_st <= R_CNT_B;
        R_CNT_B: begin cur_idx <= idx_rd; rst_st <= R_CNT_C; end
        R_CNT_C: rst_st <= R_CNT_D;
        R_CNT_D: begin cur_digit <= digit; rst_st <= R_CNT_E; end
        R_CNT_E: begin
          hist[cur_digit] <= hist[cur_digit] + 1'b1;
          if (ri + 1 >= count) begin
            hi <= '0; acc <= '0; rst_st <= R_SUM;
          end else begin
            ri     <= ri + 1'b1;
            rst_st <= R_CNT_A;
          end
        end

        R_SUM: begin                       // exclusive prefix sum
          base[hi[7:0]] <= acc;
          acc <= acc + hist[hi[7:0]];
          if (hi == 9'd255) begin ri <= '0; rst_st <= R_SCAT_A; end
          else                     hi <= hi + 9'd1;
        end

        // The scatter has the same shape, and the write at the end is what makes
        // the sort stable: elements are placed in the order they are walked.
        R_SCAT_A: rst_st <= R_SCAT_B;
        R_SCAT_B: begin cur_idx <= idx_rd; rst_st <= R_SCAT_C; end
        R_SCAT_C: rst_st <= R_SCAT_D;
        R_SCAT_D: begin cur_digit <= digit; rst_st <= R_SCAT_E; end
        R_SCAT_E: begin
          if (which) idx_a[base[cur_digit][IW-1:0]] <= cur_idx;
          else       idx_b[base[cur_digit][IW-1:0]] <= cur_idx;
          base[cur_digit] <= base[cur_digit] + 1'b1;
          if (ri + 1 >= count) rst_st <= R_NEXT;
          else begin ri <= ri + 1'b1; rst_st <= R_SCAT_A; end
        end

        R_NEXT: begin
          which <= ~which;
          if (pass == 2'd3) rst_st <= R_DONE;
          else begin
            pass   <= pass + 2'd1;
            hi     <= '0;
            rst_st <= R_CNT;
          end
        end

        R_DONE: rst_st <= R_IDLE;
        default: rst_st <= R_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------- replay
  typedef enum logic [2:0] { P_IDLE, P_WAIT, P_ADDR, P_RD1, P_RD2, P_OUT } pstate_t;
  pstate_t p_st;
  logic [IW:0]  pi;
  logic [IW-1:0] q;

  // QUARTUS WILL NOT TAKE A BIT-SELECT OF A PART-SELECT.
  // `att[q][AT_W-1:25][replay_band]` is legal to Verilator and is rejected by
  // Quartus 17.0 with "range must be the final index in the indexed name", which
  // is a synthesis error and not a simulation one - so it passed every bench and
  // failed the first real build. Split into a named wire.
  // Registered, for the same reason: reading att asynchronously to test one bit
  // of the band mask would keep the whole 2,048 x 37-bit array in flip-flops.
  logic [AT_W-1:0] att_rd;
  always_ff @(posedge clk) att_rd <= att[q];
  wire [NBANDS-1:0] q_band_mask = att_rd[AT_W-1:25];

  // After four passes the result is back in idx_a: each pass flips `which`, and
  // four flips return it. Stated rather than tracked, because a fifth pass added
  // later would silently read the wrong array.
  logic [IW-1:0] ord_idx;
  always_ff @(posedge clk) ord_idx <= idx_a[pi[IW-1:0]];

  assign replay_busy = (p_st != P_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_st <= P_IDLE; pi <= '0; q <= '0;
      out_valid <= 1'b0;
      out_x0 <= '0; out_y0 <= '0; out_x1 <= '0; out_y1 <= '0;
      out_x2 <= '0; out_y2 <= '0; out_x3 <= '0; out_y3 <= '0;
      out_col <= '0; out_moire <= 1'b0;
    end else begin
      case (p_st)
        P_IDLE: begin
          out_valid <= 1'b0;
          if (replay_start) begin pi <= '0; p_st <= (count == 0) ? P_IDLE : P_WAIT; end
        end
        // ord_idx is a REGISTERED read of idx_a, so it is valid one cycle after
        // pi settles - hence the wait. Taking it in the same cycle pi changes
        // reads the previous quad's index, which reorders the whole frame while
        // still drawing every quad exactly once.
        P_WAIT: p_st <= P_ADDR;
        P_ADDR: begin q <= ord_idx; p_st <= P_RD1; end
        P_RD1:  p_st <= P_RD2;
        P_RD2: if (!q_band_mask[replay_band]) begin
          // Not in this band: step straight to the next quad without emitting.
          if (pi + 1 >= count) p_st <= P_IDLE;
          else begin pi <= pi + 1'b1; p_st <= P_WAIT; end
        end else begin
          out_x0 <= vtx0[q][15:0];  out_y0 <= vtx0[q][31:16];
          out_x1 <= vtx1[q][15:0];  out_y1 <= vtx1[q][31:16];
          out_x2 <= vtx2[q][15:0];  out_y2 <= vtx2[q][31:16];
          out_x3 <= vtx3[q][15:0];  out_y3 <= vtx3[q][31:16];
          out_col   <= att_rd[23:0];
          out_moire <= att_rd[24];
          out_valid <= 1'b1;
          p_st      <= P_OUT;
        end
        P_OUT: if (out_ready) begin
          out_valid <= 1'b0;
          if (pi + 1 >= count) p_st <= P_IDLE;
          else begin pi <= pi + 1'b1; p_st <= P_WAIT; end
        end
        default: p_st <= P_IDLE;
      endcase
    end
  end

endmodule
