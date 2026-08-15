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
//   IRQ 3  UART ready — the sound path, not implemented yet
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

  output logic        irq_n,     // active low, to the V60
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
        last_irq      <= 3'd1;
      end

      if (ce) begin
        for (int t = 0; t < 2; t++) begin
          if (timer_period[t] != 16'd0) begin
            if (timer_presc[t] == 11'h7FF) begin
              timer_presc[t] <= '0;
              if (timer_count[t] == 16'd0) begin
                timer_count[t] <= timer_period[t];   // MAME re-arms on expiry
                if (!irq_mask[0]) begin
                  irq_status[0] <= 1'b1;
                  last_irq      <= 3'd0;
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
          3'd1: if (be[0]) irq_mask <= wdata[7:0];
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
