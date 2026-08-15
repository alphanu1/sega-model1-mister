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
// 80 MHz — memory, ROM loading, tilemap fetch and scanout.
//
//   Chosen for the video path, not for the memory. The tilemap fetch engine
//   costs 699 cycles per layer per scanline on repeated tiles and 1,614 on
//   distinct ones, and a scanline is 656 pixel clocks at the 16 MHz dot clock
//   — 41 us. Four layers therefore need 2,796-6,456 cycles, so anything under
//   68 MHz cannot draw the screen at all. 80 divides by exactly 5 to the 16 MHz
//   dot clock; 88 and 90 would close timing too but give the wrong dot clock,
//   and the refresh rate is not worth trading for headroom nothing uses yet.
//
//   WAS 96, WHICH DOES NOT CLOSE IN THE REAL BUILD. Standalone this domain
//   measured 110-113 MHz, but that was m1_integrated alone at 52% utilisation.
//   With sys/ present and the device at 62% it misses 96 MHz by 0.910 ns —
//   total negative slack only -4.314 across a handful of paths, so this is a
//   near miss rather than a structural problem, and 80 MHz clears it by about
//   1.2 ns.
//
//   What it costs: 3,280 cycles per scanline instead of 4,100. Four text layers
//   need 2,796 and still fit; four dense layers need 6,456 and did not fit at 96
//   either. SDRAM falls from ~100 MB/s to ~80, against a 55-75 MB/s
//   requirement — see docs/m1-m4-plan.md.
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
// THE INSTANCE NAMES ARE LOAD-BEARING. DO NOT "TIDY" THEM.
//
// sys_top.sdc decouples the core's clocks from the framework's with
//
//     -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
//
// so the hierarchy has to be pll -> pll_inst -> altera_pll_i, which is what
// MiSTer's generated PLL IP produces. Instantiating altera_pll directly gives
// emu|pll|pll_inst|general[0]... with no altera_pll_i level, the pattern misses,
// and the core's clocks are left out of every clock group — which means they get
// timed against the audio and HDMI PLLs.
//
// That is not a warning, it is fatal: measured, it produced -87 ns of setup slack
// and a core that does not run on hardware while building and fitting cleanly.
// The inner wrapper below exists purely to put altera_pll_i at the depth the
// framework's pattern expects.
//
// NOT SIMULABLE. altera_pll is a device primitive; Verilator cannot elaborate
// it. Nothing simulates this file — the testbenches drive their clocks
// directly, which is also why tb_m1_boot runs 100/25 rather than 96/19.2: the
// ratio is what the crossings care about, and round half-periods keep the trace
// arithmetic readable.
module m1_pll (
  input  logic refclk,     // CLK_50M
  input  logic rst,
  output logic clk_sys,    // 80 MHz
  output logic clk_cpu,    // 19.2 MHz
  output logic locked
);

  logic [1:0] outclk;
  always_comb begin
    clk_sys = outclk[0];
    clk_cpu = outclk[1];
  end

  m1_pll_core pll_inst (
    .refclk (refclk),
    .rst    (rst),
    .outclk (outclk),
    .locked (locked)
  );

endmodule


// The inner level. Its only job is to put `altera_pll_i` where sys_top.sdc's
// clock-group pattern expects to find it; see the header above.
module m1_pll_core (
  input  logic       refclk,
  input  logic       rst,
  output logic [1:0] outclk,
  output logic       locked
);

  altera_pll #(
    .fractional_vco_multiplier("false"),
    .reference_clock_frequency("50.0 MHz"),
    .operation_mode("normal"),
    .number_of_clocks(2),
    .output_clock_frequency0("80.000000 MHz"),
    .phase_shift0("0 ps"),
    .duty_cycle0(50),
    .output_clock_frequency1("19.200000 MHz"),
    .phase_shift1("0 ps"),
    .duty_cycle1(50)
  ) altera_pll_i (
    .rst      (rst),
    .refclk   (refclk),
    .outclk   (outclk),
    .locked   (locked),
    .fbclk    (1'b0),
    .fboutclk ()
  );

endmodule
