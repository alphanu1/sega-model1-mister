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
// One-cycle pulse across a clock domain.
//
// Written for the vertical-blank interrupt. m1_video raises vblank_irq for a
// single clk_sys cycle, and the V60's interrupt controller is in the slow
// domain: at 96 MHz that pulse is about 10 ns, and a 24 MHz clock has a 42 ns
// period, so it can land entirely between two destination edges and simply not
// exist. A missing frame interrupt does not look like a clock-domain fault
// downstream — it looks like the game hanging in its vblank wait.
//
// A level would not do either, because the destination needs an edge per frame,
// not a state.
//
// So: toggle in the source, edge-detect in the destination. The toggle carries
// no data, which is what makes the crossing safe — a single bit that is stable
// between events cannot be sampled half-changed in any way that matters, and
// the two flops in the destination resolve the metastability.
//
// LIMIT, and why it is fine here: pulses closer together than about three
// destination clocks are merged, because the toggle has not been sampled twice
// before it flips again. vblank arrives at 57.52 Hz against a 24 MHz clock,
// which is roughly 417,000 destination cycles apart. Anything periodic and fast
// wants a FIFO instead, not this.
module m1_cdc_pulse (
  input  logic a_clk,
  input  logic a_rst_n,
  input  logic a_pulse,

  input  logic b_clk,
  input  logic b_rst_n,
  output logic b_pulse
);

  logic tog;
  always_ff @(posedge a_clk or negedge a_rst_n) begin
    if (!a_rst_n) tog <= 1'b0;
    else if (a_pulse) tog <= ~tog;
  end

  logic s1, s2, s3;
  always_ff @(posedge b_clk or negedge b_rst_n) begin
    if (!b_rst_n) {s3, s2, s1} <= 3'b000;
    else          {s3, s2, s1} <= {s2, s1, tog};
  end

  // s1 is the metastability catcher and is never used for logic; the edge is
  // taken between the two stages behind it.
  always_comb b_pulse = s2 ^ s3;

endmodule
