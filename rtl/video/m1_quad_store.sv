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
  // FOUR BITS A PASS, NOT EIGHT, AND THE DEVICE DECIDED IT.
  //
  // A radix sort's histogram is read-modify-written at a dynamic address, which
  // no block RAM can do, so it is registers plus a multiplexer per entry. At
  // eight bits that is two 256-entry arrays of 12 bits - about 6,000 flops and
  // two 256:1 muxes - and the design missed fitting by 15 LABs of 4,191.
  //
  // At four bits the arrays are 16 entries: a sixteenth of the flops and muxes.
  // The cost is eight passes over the key instead of four, so the sort doubles
  // from 21% of a frame to about 42%. That is affordable and not fitting is not.
  parameter int unsigned RADIX  = 4,
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
  // band, which is 276,000 cycles of a 818,133-cycle frame spent on quads that
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
    R_CNT_RUN, R_SUM, R_SCAT_RUN,
    R_NEXT, R_DONE
  } rstate_t;
  rstate_t rst_st;

  localparam int unsigned NPASS = 32 / RADIX;
  localparam int unsigned NBUCK = 1 << RADIX;
  localparam int unsigned PW    = $clog2(NPASS);

  logic [PW-1:0] pass;                // which digit of the key
  logic [IW:0]  ri;
  logic [RADIX:0] hi;
  logic [IW:0]  hist [NBUCK];
  logic [IW:0]  base [NBUCK];
  logic [IW:0]  acc;
  logic         which;                // 0: a -> b, 1: b -> a
  logic [IW-1:0] cur_idx;
  // The index that goes with the digit now leaving the pipeline: cur_idx has
  // already moved on by the time its key comes back.
  logic [IW-1:0] cidx_d;
  // Three valid bits, one per stage of the two registered reads. Named for the
  // sort; the replay path below has its own.
  logic s0, s1, s2;

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

  // ONE ELEMENT PER CYCLE, NOT FIVE.
  //
  // Both reads are registered - an asynchronous read of `key` cost 65,536
  // registers and is not coming back - so an element takes three cycles to walk
  // from `ri` to a digit. Doing that as five sequential states meant the two
  // block RAMs were idle four cycles in five, and it MEASURED as 812,776 cycles
  // of the render bench, 7.1% of everything, for a sort of at most 2,048 items:
  //
  //     5 cycles x 2 loops x 8 passes x count   =  80 cycles a quad
  //
  // Pipelined it is 16 plus a three-cycle drain per loop. The replay path in
  // this same module was already built this way; the sort was not, and the two
  // sat forty lines apart.
  wire pipe_busy = s0 || s1 || s2;
  wire more      = (ri < count);

  // The RADIX-bit field selected by `pass`, taken with a shift so the width is a
  // parameter rather than four hand-written slices that stop matching it.
  wire [31:0] key_shifted = key_rd >> (RADIX * pass);
  wire [RADIX-1:0] digit = key_shifted[RADIX-1:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rst_st <= R_IDLE; pass <= '0; ri <= '0; hi <= '0; acc <= '0;
      which <= 1'b0; cur_idx <= '0; cidx_d <= '0;
      s0 <= 1'b0; s1 <= 1'b0; s2 <= 1'b0;
      // NBUCK, not a hardcoded 256. Narrowing the radix left this loop walking
      // sixteen times past the end of both arrays - which Verilator tolerates
      // silently and Quartus rejects outright with "index 16 cannot fall outside
      // the declared range". A constant that has to track a parameter and does
      // not is the same class of bug as the band mask that was still six bits
      // after the band height halved.
      for (int i = 0; i < int'(NBUCK); i++) begin hist[i] <= '0; base[i] <= '0; end
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
          hist[hi[RADIX-1:0]] <= '0;
          if (hi == (RADIX+1)'(NBUCK-1)) begin
            hi <= '0; ri <= '0;
            s0 <= 1'b0; s1 <= 1'b0; s2 <= 1'b0;
            rst_st <= R_CNT_RUN;
          end
          else                                 hi <= hi + (RADIX+1)'(1);
        end

        // Three stages, one element issued a cycle:
        //
        //   s0  idx_rd has landed for the element issued three cycles ago
        //   s1  cur_idx holds it, and addresses the key memory
        //   s2  key_rd has landed, so `digit` is that element's digit
        //
        // cur_idx has moved on by s2, so the index that belongs with the digit
        // is carried alongside in cidx_d rather than re-derived.
        R_CNT_RUN: begin
          if (more) ri <= ri + 1'b1;
          s0 <= more; s1 <= s0; s2 <= s1;
          cur_idx <= idx_rd;
          cidx_d  <= cur_idx;
          if (s2) hist[digit] <= hist[digit] + 1'b1;
          if (!more && !pipe_busy) begin
            hi <= '0; acc <= '0; rst_st <= R_SUM;
          end
        end

        R_SUM: begin                       // exclusive prefix sum
          base[hi[RADIX-1:0]] <= acc;
          acc <= acc + hist[hi[RADIX-1:0]];
          if (hi == (RADIX+1)'(NBUCK-1)) begin
            ri <= '0; s0 <= 1'b0; s1 <= 1'b0; s2 <= 1'b0;
            rst_st <= R_SCAT_RUN;
          end else hi <= hi + (RADIX+1)'(1);
        end

        // The same pipeline, with a write at the end. The write order IS the
        // walk order, which is what makes the sort stable and therefore what
        // makes submission order the tie-break, exactly as quad_t::compare has
        // it.
        R_SCAT_RUN: begin
          if (more) ri <= ri + 1'b1;
          s0 <= more; s1 <= s0; s2 <= s1;
          cur_idx <= idx_rd;
          cidx_d  <= cur_idx;
          if (s2) begin
            if (which) idx_a[base[digit][IW-1:0]] <= cidx_d;
            else       idx_b[base[digit][IW-1:0]] <= cidx_d;
            base[digit] <= base[digit] + 1'b1;
          end
          if (!more && !pipe_busy) rst_st <= R_NEXT;
        end

        R_NEXT: begin
          which <= ~which;
          if (pass == PW'(NPASS-1)) rst_st <= R_DONE;
          else begin
            pass   <= pass + PW'(1);
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
  //
  // A THREE-STAGE PIPELINE, so a quad that is not in this band costs ONE cycle.
  //
  // The sorted list is walked once per band - twelve times a frame - and almost
  // all of what it walks is skipped, because a quad touches two or three bands.
  // As a four-state sequence that cost 4 cycles a quad, so 2,001 quads cost 8,004
  // cycles of a band-time of 61,741 no matter what the band contained.
  //
  // THE ALIGNMENT IS THE WHOLE DIFFICULTY, and a first attempt at this reordered
  // the sort by getting it wrong. Both memory reads are registered, so:
  //
  //   cycle N    pi addresses idx_a          valid v0 = (pi < count)
  //   cycle N+1  ord_idx holds idx_a[pi@N]   valid v1, and it addresses att
  //   cycle N+2  att_rd holds att[ord@N+1]   valid v2, quad q2 = ord_idx@N+1
  //
  // So the decision stage must pair att_rd with a COPY of ord_idx taken at N+1,
  // not with ord_idx itself. Re-registering ord_idx into another stage instead
  // shifts the quad one place against its own attributes, which draws every quad
  // exactly once and in the wrong order.
  typedef enum logic [1:0] { P_IDLE, P_RUN, P_OUT } pstate_t;
  pstate_t p_st;

  logic [IW:0]   pi;
  logic [IW-1:0] q;
  logic          v1, v2;
  logic [IW-1:0] q2;

  logic [IW-1:0] ord_idx;
  logic [AT_W-1:0] att_rd;

  wire v0 = (pi < count);

  // Frozen while a quad is being emitted: the vertex reads and the output
  // register are shared, and those are the quads the band exists to draw.
  wire [NBANDS-1:0] q_band_mask = att_rd[AT_W-1:25];
  wire              hit = v2 && q_band_mask[replay_band];
  wire              adv = (p_st == P_RUN) && !hit;

  assign replay_busy = (p_st != P_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_st <= P_IDLE; pi <= '0; q <= '0;
      v1 <= 1'b0; v2 <= 1'b0; q2 <= '0;
      ord_idx <= '0; att_rd <= '0;
      out_valid <= 1'b0;
      out_x0 <= '0; out_y0 <= '0; out_x1 <= '0; out_y1 <= '0;
      out_x2 <= '0; out_y2 <= '0; out_x3 <= '0; out_y3 <= '0;
      out_col <= '0; out_moire <= 1'b0;
    end else begin
      if (adv) begin
        ord_idx <= idx_a[pi[IW-1:0]];
        att_rd  <= att[ord_idx];
        q2      <= ord_idx;
        v1      <= v0;
        v2      <= v1;
        if (v0) pi <= pi + 1'b1;
      end

      case (p_st)
        P_IDLE: begin
          out_valid <= 1'b0;
          if (replay_start && count != 0) begin
            pi <= '0; v1 <= 1'b0; v2 <= 1'b0;
            p_st <= P_RUN;
          end
        end

        P_RUN: begin
          if (hit) begin
            q         <= q2;
            out_col   <= att_rd[23:0];
            out_moire <= att_rd[24];
            p_st      <= P_OUT;
          end else if (!v0 && !v1 && !v2) begin
            p_st <= P_IDLE;              // drained
          end
        end

        // The vertex memories are registered, so the quad's data is ready the
        // cycle after q settles.
        //
        // ONE READ PER ARRAY, NOT TWO. `vtx0[q][15:0]` and `vtx0[q][31:16]` are
        // two separate reads of the same array at the same address as far as
        // synthesis is concerned, and Quartus answers a second read port by
        // DUPLICATING the memory. Measured in the fit report: vtx0 as
        // vtx0_rtl_0 and vtx0_rtl_1, 10 and 11 M10K for one 65,536-bit array,
        // and the same for the other three - 91 blocks for 411,648 bits of
        // unique data, 40% packing efficiency.
        //
        // A concatenation on the left is one read, split on the way out, and it
        // is bit-identical: the store writes {in_y, in_x}.
        P_OUT: begin
          {out_y0, out_x0} <= vtx0[q];
          {out_y1, out_x1} <= vtx1[q];
          {out_y2, out_x2} <= vtx2[q];
          {out_y3, out_x3} <= vtx3[q];
          out_valid <= 1'b1;
          if (out_valid && out_ready) begin
            out_valid <= 1'b0;
            v2        <= 1'b0;           // this one is consumed
            p_st      <= P_RUN;
          end
        end

        default: p_st <= P_IDLE;
      endcase
    end
  end

endmodule
