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
// A FILLED BAND, OUT OF ITS BAND BUFFER AND INTO THE DDR3 FRAME BUFFER.
//
// The fill still draws into m1_raster_band, eight rows at a time, exactly as
// it did when the band buffer was the display. What changed is who reads it:
// not the beam, against a deadline, but this - which copies the finished band
// into the frame being drawn in DDR3, line by line, as write bursts, while the
// fill draws the next band into the other buffer.
//
// WHY NOT ONE DDR3 WRITE PER SPAN, as the Model 2 core's m2_fb_write does.
// Measured first, on the hills of Virtua Racing's beginner course (MAME frame
// 2780, render3d, the board's 58.947 MHz, DDR3 at 40 cycles and never busy):
// a head, a body and a tail command per span, each waiting out its own
// acknowledge, took 538,361 cycles to draw the frame - 0.53 of a video frame,
// on top of the geometry pass, against a fill that needs about 290,000. Model
// 1's spans are a polygon's rows, so successive spans are on different lines
// and the Model 2 combining writer (m2_fb_wcomb, its R661) would have nothing
// to combine. The band buffer IS the write combiner that study names as the
// right answer (R640), and on this core it is already built.
//
// AND THE FRAME NEEDS NO CLEAR. Every pixel of every line of the band goes
// out, painted or not, so the frame in DDR3 is wholly rewritten by its own
// draw. The band buffer is emptied behind the copy (wc_*), one group the cycle
// after it is read, so it comes back ready for the next band without a clear.
//
// THE LINE IN DDR3, 132 words of the 256 a line is given:
//
//     words 0-123     RGB565, four pixels a word, pixel 4w+k in bits 16k+15:16k
//     words 124-131   PAINTED, one bit a pixel, pixel 64f+i in bit i of 124+f
//
// The band buffer's 17 bits a pixel, split so that the colour packs four to a
// beat: half the beats of Model 2's 32-bit pixel (two to a beat). Measured on
// MAME frame 1180, the draw was waiting on this copy for longer than it filled
// (1.20 M cycles against 1.00 M over the run); the copy and the scanout's line
// fetch both halve.
//
// A burst goes out only once every beat of it is queued, so the bus never
// waits on the band buffer and no beat is ever taken before it exists.

`timescale 1ns/1ps

module m1_fb_flush #(
  parameter int unsigned SCR_W  = 496,
  parameter int unsigned BAND_H = 8,
  parameter int unsigned STRIDE = 512,     // pixels a DDR3 line, a power of two
  // The longest write burst. 16 is what the Model 2 core's writers have run on
  // the board (its R362); the framework's own DDR3 writer never bursts.
  parameter int unsigned WBURST = 16
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        fb_sel,            // the frame being drawn
  input  logic        start,             // copy band `band` (a pulse, while !busy)
  input  logic [5:0]  band,
  output logic        busy,

  // ---- the band buffer's read port (its rd_clk is clk here)
  output logic [8:0]  rd_x,              // a multiple of four
  output logic [$clog2(BAND_H)-1:0] rd_row,
  input  logic [67:0] rd_q4,             // one cycle after rd_x/rd_row
  // and the group just read, emptied behind the read (m1_raster_band wc_*)
  output logic        wc_en,
  output logic [8:0]  wc_x,
  output logic [$clog2(BAND_H)-1:0] wc_row,

  // ---- to m2_ddr3, through m2_ddr3_arb
  output logic        m_req,
  output logic        m_we,
  output logic [24:0] m_addr,
  output logic [7:0]  m_blen,
  output logic [63:0] m_din,
  output logic [7:0]  m_be,
  input  logic        m_wnext,
  input  logic        m_wacc,
  input  logic        m_ack,

  output logic [31:0] dbg_beats
);

  localparam int unsigned GRPS  = (SCR_W + 3) / 4;      // 124 colour words a line
  localparam int unsigned FWDS  = (SCR_W + 63) / 64;    // 8 flag words
  localparam int unsigned BEATS = GRPS + FWDS;          // 132 a line
  localparam int unsigned RW    = $clog2(BAND_H);
  localparam int unsigned QD    = 32;                   // beats queued

  assign m_we = 1'b1;
  assign m_be = 8'hFF;

  // ---- the producer: a line's groups, then its flags
  typedef enum logic [1:0] { G_IDLE, G_RD, G_DRAIN, G_FL } gst_t;
  gst_t          g_st;
  logic [6:0]    g_x;                    // group to read next
  logic [RW-1:0] g_row;
  logic [2:0]    g_f;                    // flag word to queue next
  logic          g_v;                    // a read is landing this cycle
  logic [6:0]    v_x;
  logic [RW-1:0] v_row;
  logic [63:0]   flg [FWDS];             // this line's painted bits
  assign rd_x   = {g_x, 2'b00};
  assign rd_row = g_row;
  assign wc_en  = g_v;
  assign wc_x   = {v_x, 2'b00};
  assign wc_row = v_row;

  // ---- the queue, in MLAB. A burst is issued only when all its beats are
  // here, so the head is never the word written the cycle before.
  (* ramstyle = "MLAB, no_rw_check" *) logic [63:0] q [QD];
  logic [5:0]  q_wp, q_rp;
  wire  [5:0]  q_n    = q_wp - q_rp;
  logic        q_push;
  logic [63:0] q_wd;
  // room for this push and the read still landing
  wire         q_room = (q_n + (g_v ? 6'd1 : 6'd0)) < 6'(QD - 1);
  assign m_din = q[q_rp[4:0]];

  always_comb begin
    q_push = 1'b0; q_wd = '0;
    if (g_v) begin
      q_push = 1'b1;
      q_wd   = {rd_q4[66:51], rd_q4[49:34], rd_q4[32:17], rd_q4[15:0]};
    end else if (g_st == G_FL && q_room) begin
      q_push = 1'b1;
      q_wd   = flg[g_f];
    end
  end
  always_ff @(posedge clk) if (q_push) q[q_wp[4:0]] <= q_wd;

  // ---- the consumer: bursts, in order, over the whole band
  logic [RW-1:0] w_row;
  logic [8:0]    w_beat;                 // first beat of the next burst within the line
  logic          w_wait;                 // a burst is out; waiting for its ack
  logic          w_on;
  wire  [8:0]    w_left = 9'(BEATS) - w_beat;
  wire  [7:0]    w_len  = (w_left > 9'(WBURST)) ? 8'(WBURST) : 8'(w_left);
  logic [5:0]    band_r;
  wire  [8:0]    line   = 9'(band_r) * 9'(BAND_H) + 9'(w_row);

  assign busy = (g_st != G_IDLE) || w_on;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      g_st <= G_IDLE; g_x <= '0; g_row <= '0; g_f <= '0; g_v <= 1'b0;
      v_x <= '0; v_row <= '0;
      q_wp <= '0; q_rp <= '0;
      w_row <= '0; w_beat <= '0; w_wait <= 1'b0; w_on <= 1'b0; band_r <= '0;
      m_req <= 1'b0; m_addr <= '0; m_blen <= 8'd1; dbg_beats <= '0;
      for (int i = 0; i < FWDS; i++) flg[i] <= '0;
    end else begin
      g_v <= 1'b0;
      v_x <= g_x; v_row <= g_row;
      // the read issued last cycle lands now: its painted bits
      if (g_v) flg[v_x[6:4]][{v_x[3:0], 2'b00} +: 4] <= {rd_q4[67], rd_q4[50], rd_q4[33], rd_q4[16]};
      case (g_st)
        G_IDLE: if (start) begin
          band_r <= band;
          g_x <= '0; g_row <= '0; g_st <= G_RD;
          w_row <= '0; w_beat <= '0; w_on <= 1'b1;
        end
        G_RD: if (q_room) begin
          g_v <= 1'b1;
          if (g_x == 7'(GRPS - 1)) begin g_x <= '0; g_st <= G_DRAIN; end
          else                     g_x <= g_x + 7'd1;
        end
        G_DRAIN: begin                   // the last group's bits land this cycle
          g_f <= '0; g_st <= G_FL;
        end
        G_FL: if (q_room) begin
          if (g_f == 3'(FWDS - 1)) begin
            for (int i = 0; i < FWDS; i++) flg[i] <= '0;
            if (g_row == RW'(BAND_H - 1)) g_st <= G_IDLE;
            else begin g_row <= g_row + RW'(1); g_st <= G_RD; end
          end else g_f <= g_f + 3'd1;
        end
        default: g_st <= G_IDLE;
      endcase
      q_wp <= q_wp + (q_push ? 6'd1 : 6'd0);
      if (m_wacc) begin
        q_rp <= q_rp + 6'd1;
        if (!(&dbg_beats)) dbg_beats <= dbg_beats + 32'd1;
      end

      // A burst is asked for once all its beats are queued; the request is
      // held until its first beat is taken (R348) and the next waits for this
      // one's acknowledge.
      if (w_on && !w_wait && !m_req && (q_n >= 6'(w_len))) begin
        m_req  <= 1'b1;
        m_addr <= ({fb_sel, line} * 25'(STRIDE / 2)) + 25'(w_beat);   // 256 words a line
        m_blen <= w_len;
        w_wait <= 1'b1;
      end
      if (m_wnext) m_req <= 1'b0;
      if (m_ack) begin
        m_req  <= 1'b0;
        w_wait <= 1'b0;
        if (w_beat + 9'(m_blen) >= 9'(BEATS)) begin
          w_beat <= '0;
          if (w_row == RW'(BAND_H - 1)) w_on <= 1'b0;
          else                          w_row <= w_row + RW'(1);
        end else w_beat <= w_beat + 9'(m_blen);
      end
    end
  end

endmodule
