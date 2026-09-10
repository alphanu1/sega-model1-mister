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
// uPD71051C USART on the MAIN board, at 0xc40000 - the link to the sound PCB.
//
// THIS IS ARCADE HARDWARE, NOT A DEBUG CHANNEL. Three unrelated things in this
// repository are called a UART and keeping them apart matters:
//   - this module: the board's i8251-compatible USART, what M4's sound path
//     talks through, mapped at 0xc40000 by model1.cpp:1014;
//   - rtl/io/m1_uart_tx.sv: a printf channel into the HPS, ours, not Sega's;
//   - the DE10-Nano's physical UART header, a third thing again.
//
// WHY THIS EXISTS BEFORE ANY SOUND DOES
//
// The USART's TxRDY line is an INTERRUPT SOURCE. model1.cpp wires both
// txrdy_handler and rxrdy_handler to sound_ready_w(), which raises IRQ level 3
// whenever the line is ready and level 3 is unmasked. Virtua Fighter's level 3
// vector is 0xfe3f5c and its handler pumps the game's sound queue out through
// here; the game unmasks level 3 while that queue is non-empty and masks it
// again once it drains (model1.cpp's irq_mask_w comment).
//
// With no USART at all the address decoded to nothing, the bus returned its
// undecoded 0xffff, and level 3 was never raised by anything. `make v60_trace
// GAME=vf` proved what that costs: our instruction stream is identical to
// MAME's for 21,816 instructions and then, one boundary after the game enables
// interrupts at 0xfe4648, the reference services vblank AND THEN level 3,
// while we service vblank alone and return. The V60 was not diverging - it
// took the same interrupt on the same instruction. It was never offered the
// second one. See docs/findings.md.
//
// So this models the USART faithfully enough to drive that interrupt and to
// let the queue drain, and throws the transmitted bytes away. tx_data/tx_stb
// are where a sound board attaches when M4 arrives.
//
// TIMING IS A RATIO OF THE CPU, NOT AN ABSOLUTE
//
// The board feeds the USART 16 MHz / 2 / 16 = 500 kHz and it divides by 16 for
// a 31.25 kbit/s line, the standard Sega/MIDI sound data rate. A 10-bit
// character is therefore 3,125 a second against a 16 MHz V60: 5,120 CPU clocks.
// Holding that as a RATIO rather than as microseconds means overclocking the
// core moves the sound handshake with it and the game sees the same pacing
// relative to its own code that it does on hardware - the same reasoning as
// m1_ioz80's CEN_NUM/CEN_DEN.

`timescale 1ns/1ps

module m1_sound_usart #(
  parameter int unsigned CHAR_CLKS = 5120
) (
  input  logic        clk,
  input  logic        ce,        // CPU clock enable; the character timer runs on it
  input  logic        rst_n,

  // Register port, from the CPU bus. One byte per word, low lane, as
  // model1.cpp's .umask16(0x00ff) has it.
  input  logic        sel,
  input  logic        we,
  input  logic        a,         // 0 = data (0xc40000), 1 = command/status (0xc40002)
  input  logic [1:0]  be,
  input  logic [15:0] wdata,
  output logic [15:0] rdata,

  // To the glue's interrupt controller.
  output logic        txrdy,     // i8251_device::txrdy_r()
  output logic        ready_ev,  // pulses where MAME calls update_tx_ready()

  // To a sound board that does not exist yet.
  output logic [7:0]  tx_data,
  output logic        tx_stb
);

  // Status bits, named as i8251.h names them. Only the two the transmit path
  // owns are modelled: nothing on this board ever sends TO the main CPU in a
  // game we run, so RX_READY and the three error bits stay clear.
  logic st_txrdy;      // I8251_STATUS_TX_READY  - the DB buffer is free
  logic st_txempty;    // I8251_STATUS_TX_EMPTY  - the shifter is idle too
  logic [7:0] command;
  logic       mode_seen;   // the first control write after reset is the mode byte
  logic       shifting;
  logic [$clog2(CHAR_CLKS+1)-1:0] char_cnt;

  // is_tx_enabled(): command bit 0 AND !CTS. model1.cpp's irq_init() does
  // write_cts(0), which asserts it permanently, so TxEN alone decides.
  wire tx_enabled = command[0];

  assign txrdy = tx_enabled && st_txrdy;

  // A character has finished shifting out.
  wire char_done = shifting && ce && (char_cnt == '0);

  // check_for_tx_start(): the byte moves from the buffer into the shifter the
  // moment the shifter is free, so TX_READY comes BACK UP inside the same
  // write. That double buffering is what makes the drain loop work - the
  // handler writes a byte, TxRDY re-asserts, level 3 is raised again, and the
  // queue empties one byte per character time rather than one per frame.
  // A WRITE IS AN EDGE HERE, NOT A LEVEL, AND THAT IS NOT THE HOUSE STYLE.
  //
  // Everything else on this bus - m1_mainram, m1_glue - takes `we` as
  // `m_req && m_we` and is handed it for the WHOLE transaction, several cycles,
  // because those writes are idempotent: storing the same word into the same
  // register or RAM cell three times is indistinguishable from once. A USART's
  // are not. Each write to the data register launches a character and pulses
  // ready_ev, so a level-held write would transmit three or four bytes and
  // raise level 3 as many times, from one `mov.b`.
  //
  // Detecting the rising edge here rather than asking the bus for a strobe
  // keeps the interface the same shape as every other consumer's.
  logic wr_d;
  wire  wr_lvl = sel && we && be[0];
  wire  wr_stb = wr_lvl && !wr_d;

  wire wr_data = wr_stb && !a;
  wire wr_ctrl = wr_stb &&  a;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // i8251 reset state: buffer free and shifter idle.
      st_txrdy   <= 1'b1;
      st_txempty <= 1'b1;
      command    <= '0;
      mode_seen  <= 1'b0;
      shifting   <= 1'b0;
      char_cnt   <= '0;
      tx_data    <= '0;
      tx_stb     <= 1'b0;
      ready_ev   <= 1'b0;
      wr_d       <= 1'b0;
    end else begin
      tx_stb   <= 1'b0;
      ready_ev <= 1'b0;
      wr_d     <= wr_lvl;

      if (ce && shifting && char_cnt != '0)
        char_cnt <= char_cnt - 1'b1;

      // transmit_clock(): at the character boundary, either the buffered byte
      // starts shifting or the shifter goes empty.
      if (char_done) begin
        if (!st_txrdy && tx_enabled) begin
          // A byte was waiting in the buffer: start it and free the buffer.
          st_txrdy <= 1'b1;
          tx_stb   <= 1'b1;
          char_cnt <= ($clog2(CHAR_CLKS+1))'(CHAR_CLKS - 1);
        end else begin
          shifting   <= 1'b0;
          st_txempty <= 1'b1;
        end
        ready_ev <= 1'b1;
      end

      if (wr_data) begin
        tx_data <= wdata[7:0];
        if (tx_enabled && !shifting) begin
          // start_tx(): straight into the shifter, buffer free again at once.
          shifting   <= 1'b1;
          st_txempty <= 1'b0;
          st_txrdy   <= 1'b1;
          tx_stb     <= 1'b1;
          char_cnt   <= ($clog2(CHAR_CLKS+1))'(CHAR_CLKS - 1);
        end else begin
          // Shifter busy: the byte waits, and TxRDY stays down until it moves.
          st_txrdy <= 1'b0;
        end
        ready_ev <= 1'b1;
      end

      if (wr_ctrl) begin
        if (!mode_seen) begin
          // The mode byte. Its baud factor and character length would set the
          // character time; we hold that as a parameter instead, because every
          // Model 1 game programs the same 31.25 kbit/s line.
          mode_seen <= 1'b1;
        end else begin
          command <= wdata[7:0];
          // Internal reset (command bit 6) puts it back to expecting a mode byte.
          if (wdata[6]) begin
            mode_seen  <= 1'b0;
            command    <= '0;
            shifting   <= 1'b0;
            st_txrdy   <= 1'b1;
            st_txempty <= 1'b1;
          end
        end
        ready_ev <= 1'b1;
      end
    end
  end

  // status_r(): {DSR, SYNDET, FE, OE, PE, TX_EMPTY, RX_READY, TX_READY}.
  // DSR is not driven on this board, so it reads back low.
  always_comb begin
    if (a) rdata = {8'd0, 5'd0, st_txempty, 1'b0, st_txrdy};
    else   rdata = 16'd0;    // nothing is ever received
  end

endmodule
