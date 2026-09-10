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
// GLUE registers: interrupt control, ROM banking, and the two timers.
//
//   0xe00000 irq control   0xe00002 irq mask     0xe00004 bank
//   0xe00006 timer mode    0xe00008 period 0     0xe0000a period 1
//   0xe0000c timer 0       0xe0000e timer 1
//
// THE MASK BLOCKS, IT DOES NOT ENABLE
//
// Every source in model1.cpp raises through
//
//   if (!BIT(m_irq_mask, n)) irq_raise(n);
//
// so a SET bit suppresses that source, and irq_raise asserts the CPU line from
// the status word alone — the mask never gates the line, only the raising.
//
// The first version of this had it backwards, as an enable, with the line
// computed as status & mask. That fails in a particularly quiet way: the mask
// resets to zero, so with an enable reading no interrupt ever reaches the CPU
// and the game boots, initialises, and then sits there with vblank arriving
// every frame and nothing responding to it. Nothing about that looks like an
// interrupt polarity bug.
//
//   IRQ 0  timer expiry
//   IRQ 1  vblank, raised at scanline 384
//   IRQ 3  USART ready — the sound path
//
// LEVEL 3 IS RAISED BY THE SOUND USART, AND LEAVING IT OUT COSTS A DIVERGENCE
//
// model1.cpp wires the uPD71051C's txrdy and rxrdy handlers to sound_ready_w(),
// and calls that from irq_mask_w() as well:
//
//   if ((txrdy_r() || rxrdy_r()) && !BIT(m_irq_mask, 3)) irq_raise(3);
//
// Note it RE-READS the line rather than trusting the argument it was handed, so
// the raise is a level test taken at each of those events. Virtua Fighter's
// level 3 vector is 0xfe3f5c and its handler pumps the sound queue out through
// the USART; the game unmasks level 3 while that queue is non-empty and masks
// it again once it drains. With no USART, level 3 never existed here, the queue
// never drained, and `make v60_trace GAME=vf` diverged from MAME 21,817
// instructions in — one boundary after the game enables interrupts — because
// the reference services vblank AND THEN level 3 and we serviced vblank alone.
// That read as a CPU bug and was not one. See rtl/io/m1_sound_usart.sv.
//
// THE TIMERS COUNT IN UNITS OF 0x800
//
// MAME arms each timer for 0x800 * period CPU clocks and timer_r returns the
// remaining ticks divided by 0x800. So the register software reads is a
// down-counter in units of 0x800 clocks, and the prescaler here is what makes
// the visible count match. Reloading on expiry is MAME's behaviour too: the
// callback re-arms from the period rather than stopping.

`timescale 1ns/1ps

module m1_glue (
  input  logic        clk,
  input  logic        ce,        // CPU clock enable; the timers run on it
  input  logic        rst_n,

  // Register port, from the CPU bus.
  input  logic        sel,
  input  logic        we,
  input  logic [3:1]  a,
  input  logic [1:0]  be,
  input  logic [15:0] wdata,
  output logic [15:0] rdata,

  input  logic        vblank,    // pulse at the start of vertical blanking

  // The sound USART's interrupt line. `snd_ready_ev` pulses where MAME calls
  // update_tx_ready(); `snd_txrdy` is the level it re-reads there.
  input  logic        snd_txrdy,
  input  logic        snd_ready_ev,

  output logic        irq_n,     // active low, to the V60
  // The vector the CPU takes, and the pulse telling us it took it. MAME's
  // irq_callback scans irq_status from bit 0 and returns the FIRST SET BIT,
  // storing it as m_last_irq at that moment — so the vector is computed at
  // acknowledge, not at raise. Getting this wrong is not subtle in effect and
  // is completely silent in appearance: with a fixed vector every interrupt
  // dispatches to the same handler, so vblank runs the timer's routine, the
  // game's frame flag is never set, and it sits in a three-instruction poll
  // loop forever looking exactly like a hung CPU.
  output logic [2:0]  irq_vec,
  input  logic        irq_ack,
  output logic [2:0]  rom_bank
);

  logic [7:0]  irq_status, irq_mask;
  logic [2:0]  last_irq;
  logic        vbl_d;

  logic [15:0] timer_period [2];
  logic [15:0] timer_count  [2];
  logic [10:0] timer_presc  [2];
  logic [15:0] timer_mode;

  assign irq_n = ~(|irq_status);

  // Lowest set bit, written as an overwriting loop from the top down because
  // yosys rejects a loop with a break — docs/rtl-conventions.md.
  always_comb begin
    irq_vec = 3'd0;
    for (int i = 7; i >= 0; i--)
      if (irq_status[i]) irq_vec = 3'(i);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      irq_status <= '0; irq_mask <= '0; rom_bank <= '0; vbl_d <= 1'b0;
      last_irq <= '0; timer_mode <= '0;
      for (int t = 0; t < 2; t++) begin
        timer_period[t] <= '0; timer_count[t] <= '0; timer_presc[t] <= '0;
      end
    end else begin
      vbl_d <= vblank;
      if (vblank && !vbl_d && !irq_mask[1]) begin
        irq_status[1] <= 1'b1;
      end

      // sound_ready_w(), from the USART's own handlers. Placed above the
      // register writes so that an explicit 0x10/0x20 acknowledge arriving in
      // the same cycle still wins: in MAME these are separate calls that can
      // never coincide, and letting the clear lose would strand a level the
      // handler believed it had cleared.
      if (snd_ready_ev && snd_txrdy && !irq_mask[3]) begin
        irq_status[3] <= 1'b1;
      end

      // MAME stores the vector inside irq_callback, i.e. when the CPU consumes
      // it. `last_irq` is what the 0x20 control write clears, so latching it at
      // raise time would clear whichever source raised most recently rather
      // than the one just serviced.
      if (irq_ack) last_irq <= irq_vec;

      if (ce) begin
        for (int t = 0; t < 2; t++) begin
          if (timer_period[t] != 16'd0) begin
            if (timer_presc[t] == 11'h7FF) begin
              timer_presc[t] <= '0;
              if (timer_count[t] == 16'd0) begin
                timer_count[t] <= timer_period[t];   // MAME re-arms on expiry
                if (!irq_mask[0]) begin
                  irq_status[0] <= 1'b1;
                end
              end else begin
                timer_count[t] <= timer_count[t] - 16'd1;
              end
            end else begin
              timer_presc[t] <= timer_presc[t] + 11'd1;
            end
          end
        end
      end

      if (sel && we) begin
        case (a)
          // irq_control_w: 0x10 clears everything, 0x20 clears the last raised.
          3'd0: if (be[0]) begin
                  if      (wdata[7:0] == 8'h10) irq_status <= '0;
                  else if (wdata[7:0] == 8'h20) irq_status[last_irq] <= 1'b0;
                end
          // irq_mask_w() ends with its own sound_ready_w() call, against the
          // mask it has JUST written - so unmasking level 3 while the line is
          // ready raises it immediately, which is how vf's queue pump starts.
          3'd1: if (be[0]) begin
                  irq_mask <= wdata[7:0];
                  if (snd_txrdy && !wdata[3]) irq_status[3] <= 1'b1;
                end
          // bank_w: the low nibble selects which window and bits 7:4 the bank.
          // Only selector 1 — the 0x100000-0x1fffff data ROM window — is used
          // by any dumped game; the others are decoded and ignored, as there.
          3'd2: if (be[0] && (wdata[3:0] == 4'h1)) rom_bank <= wdata[6:4];
          3'd3: timer_mode <= wdata;
          3'd4, 3'd5: begin
            timer_period[a[1]] <= wdata;
            timer_count[a[1]]  <= wdata;
            timer_presc[a[1]]  <= '0;
          end
          // 0xe0000c-f are read-only. vf and swa write zero there at init and
          // MAME discards it, so this must not treat the write as a period.
          default: ;
        endcase
      end
    end
  end

  always_comb begin
    case (a)
      3'd1:    rdata = {8'd0, irq_mask};
      3'd3:    rdata = timer_mode;
      3'd4:    rdata = timer_period[0];
      3'd5:    rdata = timer_period[1];
      3'd6:    rdata = timer_count[0];
      3'd7:    rdata = timer_count[1];
      default: rdata = 16'd0;
    endcase
  end

endmodule
