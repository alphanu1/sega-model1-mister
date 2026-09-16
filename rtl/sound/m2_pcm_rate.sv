// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// A fixed output rate for a chip whose own rate depends on memory.
//
// THE PROBLEM, MEASURED. m2_multipcm advances its slot counter only while no
// fetch is outstanding, so SDRAM latency does not delay a sample, it stretches
// the sample PERIOD. Against fetch latency in cycles the period runs:
//
//     latency 100 -> 1075..1805 cycles, sd 6.0%
//     latency 300 -> 1075..3015 cycles, sd 15.8%
//
// against a nominal 1075. That is not a chip playing flat, it is a chip whose
// sample rate moves by a factor of nearly three from one sample to the next,
// and it is heard as CRACKLE rather than as slowness.
//
// It is also why adding a per-voice cache made the sound WORSE while making
// every average better. With no cache every fetch missed, so every period was
// equally long: uniformly flat, like a tape running slow, and tolerable. With a
// cache the miss count varies per period, so the average improved and the
// STABILITY collapsed. Average rate cannot distinguish those two and this
// project measured only the average for three builds.
//
// THE FIX. Give the chip clock headroom so it can run ahead, buffer what it
// produces, and drain that buffer at exactly one rate. Memory stalls are then
// absorbed by the buffer instead of appearing at the speaker, and the output
// rate is a constant by construction rather than an average that happens to
// come out near the right value.
//
//   * `ce` is issued at CE_NUM/CE_DEN, above the chip's nominal 10 MHz, and is
//     WITHHELD whenever the buffer is full. The chip is therefore throttled to
//     exactly the drain rate on average -- its envelopes and pitch stay correct
//     because those advance per sample period, and the period is now fixed.
//   * The drain is a phase accumulator at 44,643 Hz, which is the chip's own
//     10 MHz / 224 and not a number anyone chose.
//
// Underrun holds the last sample rather than emitting zero: a repeated sample
// is a moment of flat, a zero is a click, and a buffer that has run dry is
// already the interesting event -- it is counted so the headroom can be judged
// rather than assumed.

`timescale 1ns/1ps

module m2_pcm_rate #(
  // BYPASS IS THE DEFAULT, for the same reason m2_pcm_fetch's is: the last
  // arrangement the board reported as sounding like the game had neither of
  // these stages. The jitter this removes is real and measured -- 1075..3015
  // cycles against a nominal 1075 -- but a fix for a real fault that does not
  // restore the sound is not yet the fix for THIS fault, and the way to find
  // out which stage is responsible is to turn them on one at a time.
  //
  // Bypassed, the chip gets a plain 10 MHz enable and its samples pass straight
  // through, which is exactly what it had four builds ago.
  parameter bit BYPASS = 1'b1,
  parameter int unsigned PLAIN_NUM = 10,   // the chip's own 10 MHz, when bypassed
  // 20/48 of 48 MHz is 20 MHz against the chip's nominal 10 -- two times over, and
  // sized by measurement rather than taste: at 13 the buffer ran dry 2,436 times
  // with a 600-cycle fetch latency, at 16 it ran dry 391 times, and at 20 it did
  // not run dry at all. The chip idles half the time as a result, which is the
  // point -- idle is what absorbs a stall.
  parameter int unsigned CE_NUM  = 20,
  parameter int unsigned CE_DEN  = 50,
  // 48 MHz / 44,643 Hz = 1075.2 cycles a sample. Accumulator, not a counter,
  // because 1075 flat is 0.02% sharp and this is the one rate that must not
  // drift.
  parameter int unsigned OUT_NUM = 44643,
  parameter int unsigned OUT_DEN = 50_000_000,
  parameter int unsigned DEPTH   = 16
) (
  input  logic        clk,
  input  logic        rst_n,

  output logic        ce,               // to the chip, throttled

  input  logic        s_valid,          // the chip finished a sample
  input  logic signed [15:0] s_l,
  input  logic signed [15:0] s_r,

  output logic signed [15:0] o_l,
  output logic signed [15:0] o_r,

  output logic [15:0] dbg_underruns,
  output logic  [7:0] dbg_level
);

  localparam int unsigned PW = $clog2(DEPTH);

  // MLAB -- AND IT NEEDED THE DEBUG CHANNEL TURNED OFF FIRST.
  //
  // These are 16 x 16, 256 bits each, four across the two instances, and
  // Quartus gives every one a whole 10 Kbit M10K block: four blocks for 1,024
  // bits, out of the 553 the sound build fails on.
  //
  // THE FIRST ATTEMPT FAILED AND THE REASON MATTERS. An MLAB IS a LAB used as
  // memory, so it competes with logic for the same LABs. At 99% ALM there were
  // none spare and the fit died with
  //     Error (170012): Fitter requires 4236 LABs ... device contains only 4191
  // UART_REPORT=0 (rtl/m1_integrated.sv) freed ~350 ALM, and that headroom is
  // what makes this affordable. MLAB IS NOT FREE WHEN LOGIC IS FULL.
  //
  // `ramstyle = "logic"` is worse again: tagging m1_uart_tx's FIFO and
  // m1_copro_if's `fin` that way cost +795 ALM and pushed M10K UP, because the
  // storage is cheap and the READ MUX is not.
  //
  // The shape was always right for inference: ONE write port (`fl[wp] <= s_l`)
  // and a REGISTERED read (`o_l <= fl[rp]`), both in the same always_ff.
  // `no_rw_check` because the 2'b11 arm writes and reads in one cycle; wp and
  // rp are separated by `lvl` there, so they are never the same address.
  // NO ramstyle ATTRIBUTE, MATCHING MODEL 2, WHOSE SOUND WORKS.
  //
  // These carried `ramstyle = "MLAB, no_rw_check"` here and nowhere else.
  // `no_rw_check` tells Quartus that a read and a write never address the same
  // location in the same cycle, so it REMOVES the read-during-write bypass. If
  // they ever do collide the device returns something the simulator does not,
  // which is precisely the shape of a fault that passes every bench and fails
  // on the board.
  //
  // This is a sample FIFO written by the chip and drained at a fixed rate; its
  // pointers meet whenever it runs empty or full. Model 2 leaves these as
  // plain arrays and its sound works.
  logic signed [15:0] fl [DEPTH];
  logic signed [15:0] fr [DEPTH];
  logic [PW-1:0] wp, rp;
  logic [PW:0]   lvl;

  wire full  = (lvl >= (PW+1)'(DEPTH - 1));
  wire empty = (lvl == '0);

  // ---- the chip's clock enable, with headroom and a throttle
  localparam int unsigned CW  = $clog2(CE_DEN) + 1;
  localparam int unsigned NUM = BYPASS ? PLAIN_NUM : CE_NUM;
  logic [CW-1:0] cacc;
  logic          ce_raw;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cacc <= '0; ce_raw <= 1'b0;
    end else if (cacc + CW'(NUM) >= CW'(CE_DEN)) begin
      cacc   <= cacc + CW'(NUM) - CW'(CE_DEN);
      ce_raw <= 1'b1;
    end else begin
      cacc   <= cacc + CW'(NUM);
      ce_raw <= 1'b0;
    end
  end
  // Withheld when the buffer is full: that is what holds the AVERAGE rate to
  // the drain rate rather than to the headroom.
  assign ce = BYPASS ? ce_raw : (ce_raw && !full);

  // ---- the drain, at exactly 44,643 Hz
  logic [31:0] oacc;
  wire         pop_tick = (oacc + 32'(OUT_NUM) >= 32'(OUT_DEN));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wp <= '0; rp <= '0; lvl <= '0; oacc <= '0;
      o_l <= 16'sd0; o_r <= 16'sd0;
      dbg_underruns <= 16'd0;
    end else begin
      oacc <= pop_tick ? (oacc + 32'(OUT_NUM) - 32'(OUT_DEN)) : (oacc + 32'(OUT_NUM));

      // Push and pop can land on the same edge; the level is adjusted once for
      // the pair so it never counts a sample twice or loses one.
      case ({!BYPASS && s_valid && !full, !BYPASS && pop_tick && !empty})
        2'b10: begin fl[wp] <= s_l; fr[wp] <= s_r; wp <= wp + PW'(1); lvl <= lvl + 1'b1; end
        2'b01: begin o_l <= fl[rp]; o_r <= fr[rp]; rp <= rp + PW'(1); lvl <= lvl - 1'b1; end
        2'b11: begin
          fl[wp] <= s_l; fr[wp] <= s_r; wp <= wp + PW'(1);
          o_l <= fl[rp]; o_r <= fr[rp]; rp <= rp + PW'(1);
        end
        default: ;
      endcase

      // Bypassed: the chip's samples go straight out, no buffer in the path.
      if (BYPASS && s_valid) begin
        o_l <= s_l;
        o_r <= s_r;
      end

      // Dry. Hold the last sample -- a repeat is flat, a zero is a click.
      if (!BYPASS && pop_tick && empty && !(&dbg_underruns))
        dbg_underruns <= dbg_underruns + 16'd1;
    end
  end

  assign dbg_level = {{(8-PW-1){1'b0}}, lvl};

endmodule
