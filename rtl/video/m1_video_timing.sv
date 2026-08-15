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
// Video timing, from MAME's screen configuration in model1.cpp:
//
//   m_screen->set_raw(XTAL(16'000'000), 656, 0, 496, 424, 0, 384);
//
// 16 MHz pixel clock, 656 total columns of which 496 are visible, 424 total
// lines of which 384 are visible. That gives 16e6 / (656 * 424) = 57.52 Hz,
// which is the refresh the whole core has to hit — the tilemap fetch budget in
// m1_tile_fetch.sv is derived from the 656-clock line this defines.
//
// WHERE THE SYNC PULSES SIT IS NOT FROM MAME
//
// `set_raw` specifies the total and the visible window; it says nothing about
// where inside the blanking interval the sync pulses go, because MAME does not
// need to know. A real display does, so the positions below are chosen rather
// than derived, and are parameters so they can be corrected against a real
// board or a service-mode geometry screen without touching logic.
//
// The totals and the visible window ARE from MAME and must not be adjusted to
// make a monitor happy: they set the frame rate, and a core that runs at the
// wrong rate has audio that drifts and scrolling that tears in ways that look
// like unrelated bugs.

`timescale 1ns/1ps

module m1_video_timing #(
  parameter int unsigned H_TOTAL   = 656,   // MAME set_raw
  parameter int unsigned H_VISIBLE = 496,   // MAME set_raw
  parameter int unsigned V_TOTAL   = 424,   // MAME set_raw
  parameter int unsigned V_VISIBLE = 384,   // MAME set_raw

  // Chosen, not derived. See the note above.
  parameter int unsigned H_SYNC_START = 520,
  parameter int unsigned H_SYNC_END   = 584,
  parameter int unsigned V_SYNC_START = 392,
  parameter int unsigned V_SYNC_END   = 395
) (
  input  logic       clk,        // 16 MHz pixel clock enable domain
  input  logic       ce_pix,
  input  logic       rst_n,

  output logic [9:0] hcnt,
  output logic [9:0] vcnt,
  output logic       hblank,
  output logic       vblank,
  output logic       hsync,
  output logic       vsync,
  output logic       visible,

  // Rising edge one line before a visible line starts, so a scanline renderer
  // has a whole line of blanking to fill its buffer. Rendering during the line
  // it is displayed would need the fetch to keep ahead of the beam, which the
  // measured 699-1614 cycles per layer cannot guarantee.
  output logic       line_start,
  output logic [8:0] line_number,

  // Frame boundary, for the V60's vblank interrupt.
  output logic       vblank_start
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hcnt <= '0;
      vcnt <= '0;
    end else if (ce_pix) begin
      if (hcnt == 10'(H_TOTAL - 1)) begin
        hcnt <= '0;
        vcnt <= (vcnt == 10'(V_TOTAL - 1)) ? '0 : vcnt + 10'd1;
      end else begin
        hcnt <= hcnt + 10'd1;
      end
    end
  end

  assign hblank  = (hcnt >= 10'(H_VISIBLE));
  assign vblank  = (vcnt >= 10'(V_VISIBLE));
  assign visible = !hblank && !vblank;

  assign hsync = (hcnt >= 10'(H_SYNC_START)) && (hcnt < 10'(H_SYNC_END));
  assign vsync = (vcnt >= 10'(V_SYNC_START)) && (vcnt < 10'(V_SYNC_END));

  // Kick the renderer at the start of the horizontal blanking that precedes
  // the next line, and name that next line.
  assign line_start  = ce_pix && (hcnt == 10'(H_VISIBLE));
  assign line_number = (vcnt == 10'(V_TOTAL - 1)) ? 9'd0 : 9'(vcnt + 10'd1);

  assign vblank_start = ce_pix && (hcnt == 10'(H_VISIBLE)) &&
                        (vcnt == 10'(V_VISIBLE - 1));

endmodule
