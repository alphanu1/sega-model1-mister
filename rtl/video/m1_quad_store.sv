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

  localparam int unsigned AW = IW + 2;        // four words per quad

  // Four 32-bit words a quad: two vertices, then colour and key.
  //   w0 {y0,x0}   w1 {y1,x1}   w2 {y2,x2}   w3 {y3,x3}
  // and a separate narrow array for colour+moire, and one for the sort key, so
  // the sort never reads the wide one.
  (* ramstyle = "M10K" *) logic [31:0] vtx [NQ*4];
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
        vtx[{count[IW-1:0], 2'd0}] <= {in_y0, in_x0};
        vtx[{count[IW-1:0], 2'd1}] <= {in_y1, in_x1};
        vtx[{count[IW-1:0], 2'd2}] <= {in_y2, in_x2};
        vtx[{count[IW-1:0], 2'd3}] <= {in_y3, in_x3};
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
    R_IDLE, R_INIT, R_CNT, R_CNT2, R_CNT3, R_CNT4,
    R_SUM, R_SCAT, R_SCAT2, R_SCAT3, R_NEXT, R_DONE
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

  wire [IW-1:0] src_idx = which ? idx_b[ri[IW-1:0]] : idx_a[ri[IW-1:0]];
  wire [31:0]   src_key = key[cur_idx];
  wire [7:0]    digit   = (pass == 2'd0) ? src_key[7:0]   :
                          (pass == 2'd1) ? src_key[15:8]  :
                          (pass == 2'd2) ? src_key[23:16] : src_key[31:24];

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
          if (hi == 9'd255) begin hi <= '0; ri <= '0; rst_st <= R_CNT2; end
          else                     hi <= hi + 9'd1;
        end

        // Counting is THREE cycles an element, the same shape as the scatter
        // below, and for the same reason: the index memory answers in one cycle
        // and the key memory in another, so the digit is only valid two cycles
        // after the index is addressed.
        //
        // The first version folded all three into one state and incremented
        // hist[cur_digit] while cur_digit still held the PREVIOUS element's
        // digit - and, on the last element, wrote hist[cur_digit] twice in one
        // cycle, so one count was silently lost. Both faults leave the histogram
        // nearly right, which is why the directed cases passed and only the fuzz
        // caught it.
        R_CNT2: begin cur_idx <= src_idx; rst_st <= R_CNT3; end
        R_CNT3: begin cur_digit <= digit; rst_st <= R_CNT4; end
        R_CNT4: begin
          hist[cur_digit] <= hist[cur_digit] + 1'b1;
          if (ri + 1 >= count) begin
            hi <= '0; acc <= '0; rst_st <= R_SUM;
          end else begin
            ri     <= ri + 1'b1;
            rst_st <= R_CNT2;
          end
        end

        R_SUM: begin                       // exclusive prefix sum
          base[hi[7:0]] <= acc;
          acc <= acc + hist[hi[7:0]];
          if (hi == 9'd255) begin ri <= '0; rst_st <= R_SCAT; end
          else                     hi <= hi + 9'd1;
        end

        // Scatter, in order, which is what makes it stable.
        R_SCAT: begin
          cur_idx <= src_idx;
          rst_st  <= R_SCAT2;
        end
        R_SCAT2: begin
          cur_digit <= digit;
          rst_st    <= R_SCAT3;
        end
        R_SCAT3: begin
          if (which) idx_a[base[cur_digit][IW-1:0]] <= cur_idx;
          else       idx_b[base[cur_digit][IW-1:0]] <= cur_idx;
          base[cur_digit] <= base[cur_digit] + 1'b1;
          if (ri + 1 >= count) rst_st <= R_NEXT;
          else begin ri <= ri + 1'b1; rst_st <= R_SCAT; end
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
  typedef enum logic [2:0] { P_IDLE, P_ADDR, P_RD1, P_RD2, P_OUT } pstate_t;
  pstate_t p_st;
  logic [IW:0]  pi;
  logic [IW-1:0] q;

  // QUARTUS WILL NOT TAKE A BIT-SELECT OF A PART-SELECT.
  // `att[q][AT_W-1:25][replay_band]` is legal to Verilator and is rejected by
  // Quartus 17.0 with "range must be the final index in the indexed name", which
  // is a synthesis error and not a simulation one - so it passed every bench and
  // failed the first real build. Split into a named wire.
  wire [NBANDS-1:0] q_band_mask = att[q][AT_W-1:25];

  // After four passes the result is back in idx_a: each pass flips `which`, and
  // four flips return it. Stated rather than tracked, because a fifth pass added
  // later would silently read the wrong array.
  wire [IW-1:0] ord_idx = idx_a[pi[IW-1:0]];

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
          if (replay_start) begin pi <= '0; p_st <= (count == 0) ? P_IDLE : P_ADDR; end
        end
        P_ADDR: begin q <= ord_idx; p_st <= P_RD1; end
        P_RD1:  p_st <= P_RD2;
        P_RD2: if (!q_band_mask[replay_band]) begin
          // Not in this band: step straight to the next quad without emitting.
          if (pi + 1 >= count) p_st <= P_IDLE;
          else begin pi <= pi + 1'b1; p_st <= P_ADDR; end
        end else begin
          out_x0 <= vtx[{q, 2'd0}][15:0];  out_y0 <= vtx[{q, 2'd0}][31:16];
          out_x1 <= vtx[{q, 2'd1}][15:0];  out_y1 <= vtx[{q, 2'd1}][31:16];
          out_x2 <= vtx[{q, 2'd2}][15:0];  out_y2 <= vtx[{q, 2'd2}][31:16];
          out_x3 <= vtx[{q, 2'd3}][15:0];  out_y3 <= vtx[{q, 2'd3}][31:16];
          out_col   <= att[q][23:0];
          out_moire <= att[q][24];
          out_valid <= 1'b1;
          p_st      <= P_OUT;
        end
        P_OUT: if (out_ready) begin
          out_valid <= 1'b0;
          if (pi + 1 >= count) p_st <= P_IDLE;
          else begin pi <= pi + 1'b1; p_st <= P_ADDR; end
        end
        default: p_st <= P_IDLE;
      endcase
    end
  end

endmodule
