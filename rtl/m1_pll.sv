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
// The core's two clocks.
//
// 96 MHz — memory, ROM loading, tilemap fetch and scanout.
//
//   Chosen for the video path, not for the memory. The tilemap fetch engine
//   costs 699 cycles per layer per scanline on repeated tiles and 1,614 on
//   distinct ones, and a scanline is 656 pixel clocks at the 16 MHz dot clock
//   — 41 us. Four layers therefore need 2,796-6,456 cycles, so anything under
//   68 MHz cannot draw the screen. 96 also divides by exactly 6 to give the
//   16 MHz dot clock, which no nearby alternative does.
//
//   Measured closure: 110.04 MHz on this domain, so there is real margin.
//
// 19.2 MHz — the V60 and its bus.
//
//   Not 24. The design measured **23.81 MHz** on clk_cpu once it was properly
//   constrained, so a 24 MHz target misses by under 1% — which is still a miss.
//   96/5 is a clean divide from the same VCO and sits clear of that ceiling.
//
//   19.2 is above what the CPU needs: matching a 16 MHz part wants
//   F >= 16 * 8.56 / CPI_real, which is ~17.1 MHz against MAME's disclaimed
//   flat-8 CPI and lower against any more realistic figure.
//
//   The lever if this ever becomes tight is S32_V60_NO_FP, measured at -1,987
//   ALM and a V60 Fmax of 45.54 MHz, which would make the CPU clock a
//   non-question. It is evidenced but not spent — see docs/m1-m4-plan.md.
//
// The two are asynchronous as far as timing analysis is concerned, and
// quartus/spike.sdc declares them so. Everything that crosses goes through
// m1_cdc_port, m1_fetch_bridge, m1_cdc_pulse or a dual-clock RAM.
//
// NOT SIMULABLE. altera_pll is a device primitive; Verilator cannot elaborate
// it. Nothing simulates this file — the testbenches drive their clocks
// directly, which is also why tb_m1_boot runs 100/25 rather than 96/19.2: the
// ratio is what the crossings care about, and round half-periods keep the trace
// arithmetic readable.
module m1_pll (
  input  logic refclk,     // CLK_50M
  input  logic rst,
  output logic clk_sys,    // 96 MHz
  output logic clk_cpu,    // 19.2 MHz
  output logic locked
);

  altera_pll #(
    .fractional_vco_multiplier("false"),
    .reference_clock_frequency("50.0 MHz"),
    .operation_mode("normal"),
    .number_of_clocks(2),
    .output_clock_frequency0("96.000000 MHz"),
    .phase_shift0("0 ps"),
    .duty_cycle0(50),
    .output_clock_frequency1("19.200000 MHz"),
    .phase_shift1("0 ps"),
    .duty_cycle1(50)
  ) pll_inst (
    .rst      (rst),
    .refclk   (refclk),
    .outclk   ({clk_cpu, clk_sys}),
    .locked   (locked),
    .fbclk    (1'b0),
    .fboutclk ()
  );

endmodule
