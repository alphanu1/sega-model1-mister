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
// The display-list control register at 0x680000-0x680003.
//
// WHY THIS EXISTS AS A MODULE
//
// It was decoded for WRITES and had no read handler at all: reads fell through to
// m1_main's default and returned 0xFFFF. `make v60_trace` found that at
// instruction 26,283:
//
//     FF96F7: mov.h  680000, R0
//     FF96FE: test1  #6, R0
//     FF9701: be     FF970C        reference takes it; we fell through
//
// Bit 6 is the display-list BUFFER SELECT and the game reads it to decide which
// list to write into. Reading 0xFFFF makes that bit always 1, so we always chose
// the same buffer and never followed the reference's double-buffer handshake.
//
// WHAT THE HARDWARE DOES, from model1_v.cpp
//
// The register is not a plain latch — the video hardware maintains bit 6:
//
//   set_current_render_list() / get_list_number()   (:1338, :1344)
//       if(!(m_listctl[0] & 4))
//           m_listctl[0] = (m_listctl[0] & ~0x40) | (m_listctl[0] & 8 ? 0x40 : 0);
//
//   end_frame()                                     (:1351)
//       if((m_listctl[0] & 4) && (m_screen->frame_number() & 1))
//           m_listctl[0] ^= 0x40;
//
//   model1_listctl_r()                              (:1358)
//       offset 0 -> m_listctl[0] | 0x30      bits 4 and 5 are FORCED SET
//       offset 1 -> m_listctl[1]
//
// So bit 2 picks the mode: clear means bit 6 mirrors bit 3 — software selects the
// buffer by hand — and set means bit 6 toggles once every two frames, which is
// the automatic double buffer. Bits 4 and 5 read back set whatever was written.
//
// The mirror is applied combinationally here rather than by mutating the stored
// value on a schedule. MAME applies it inside the render functions, so by the time
// anything reads the register it has already happened; doing it on the read path is
// the same observable behaviour without inventing a point in the frame to do it at.
`timescale 1ns/1ps

module m1_listctl (
  input  logic        clk,
  input  logic        rst_n,

  // CPU side. `offset` is address bit 1: 0 is 0x680000, 1 is 0x680002.
  input  logic        we,
  input  logic        offset,
  input  logic [15:0] wdata,
  input  logic [1:0]  be,
  output logic [15:0] rdata,

  // One pulse per frame. Drives the automatic toggle, which only fires on every
  // second pulse — MAME's `frame_number() & 1`.
  input  logic        frame_pulse,

  // Which display list the renderer should read. Bit 6, after the mirror.
  output logic        list_sel
);

  logic [15:0] lc0, lc1;
  logic        frame_parity;

  // Bit 2 clear: software drives the choice through bit 3.
  wire        manual    = ~lc0[2];
  wire [15:0] lc0_fixed = manual ? ((lc0 & ~16'h0040) | (lc0[3] ? 16'h0040 : 16'h0000))
                                 : lc0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lc0          <= 16'd0;
      lc1          <= 16'd0;
      frame_parity <= 1'b0;
    end else if (we) begin
      // A CPU write wins over the frame update. They coincide only if a write
      // lands on the exact vblank cycle, and the reference does them at different
      // points in the frame, so either order is a guess — this one at least never
      // loses a write.
      if (!offset) begin
        if (be[0]) lc0[7:0]  <= wdata[7:0];
        if (be[1]) lc0[15:8] <= wdata[15:8];
      end else begin
        if (be[0]) lc1[7:0]  <= wdata[7:0];
        if (be[1]) lc1[15:8] <= wdata[15:8];
      end
    end else if (frame_pulse) begin
      frame_parity <= ~frame_parity;
      // Bit 2 SET is the automatic mode and toggles on every second frame. Bit 2
      // clear needs no stored update at all, because the mirror is combinational.
      if (!manual && frame_parity) lc0 <= lc0 ^ 16'h0040;
    end
  end

  // Bits 4 and 5 forced set on offset 0, exactly as model1_listctl_r does. Offset
  // 1 is a plain latch with no forcing and no mirror.
  assign rdata    = offset ? lc1 : (lc0_fixed | 16'h0030);
  assign list_sel = lc0_fixed[6];

endmodule
