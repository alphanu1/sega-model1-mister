// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The i8251 (T82C51) either end of the sound link.
//
// daytona93 is model2o, and its sound board is the MODEL 1 board -- model2.cpp
// instantiates SEGAM1AUDIO, the same device model1.cpp uses. The two boards talk
// over a serial pair and nothing else: the i960 has an i8251 at 0x01c80000 and
// the sound board's 68000 has one at 0xc20000, wired
//
//     m_uart->txd_handler().set(m_m1audio, &segam1audio_device::write_txd)
//     m_m1audio->rxd_handler().set(m_uart, &i8251_device::write_rxd)
//
// at 16 MHz / 2 / 16 -- "16 times 31.25kHz (standard Sega/MIDI sound data rate)".
//
// BYTE-LEVEL, NOT BIT-LEVEL, AND THAT IS A DELIBERATE HLE.
//
// Both ends are configured identically by their own firmware and the only thing
// either program can observe is the BYTE STREAM and the rate it arrives at. A
// bit-serial model would reproduce the same bytes at the same times through ten
// times the logic and a shift register nobody can see. So this carries bytes and
// paces them at the real 31.25 kHz, which keeps the one property the software
// depends on -- a byte takes ~32 us, so the sender cannot outrun the receiver.
//
// It is written down as an approximation rather than left to be discovered:
// framing errors, break detection and parity are NOT modelled, because neither
// firmware can produce them across a board-to-board link that is always
// configured the same way at both ends. If a game is ever found that reads the
// error bits meaningfully, this is the file that has to grow.
//
// THE ORACLE. MAME emits exactly 59 bytes to this port over 900 frames of
// attract mode, beginning
//
//     00 x11, f8, f8, ff, be 14 1f, be 16 02, be 1b 17, ...
//
// so the i960 side can be verified byte for byte before a single sound chip
// exists. That is the whole reason this piece is built first.

`timescale 1ns/1ps

// No baud parameter here on purpose: the PACING lives in m2_sound_link, which
// is the wire. This end only ever sees "the byte was taken" and "a byte
// arrived", exactly as the real part sees its shift register empty or full.
module m2_i8251 (
  input  logic       clk,
  input  logic       rst_n,

  // ---- register side, as the local CPU sees it
  // addr 0 = data, addr 1 = status (read) / command (write).
  input  logic       sel,
  input  logic       we,
  input  logic       addr,
  input  logic [7:0] din,
  output logic [7:0] dout,
  // BOTH REGISTERS, SEPARATELY, because the i960 reads them as one dword: the
  // device is .umask16(0x00ff), so data is byte 0 and status byte 2 of the same
  // 32-bit word. `dout` is the muxed view a byte-addressed master sees; these
  // two let the top level present both without asserting `sel`, which matters --
  // see the note on rd_data below, a status poll must not eat the data byte.
  output logic [7:0] data_o,
  output logic [7:0] stat_o,

  // ---- link side. One byte at a time, with an acknowledge, so the pacing
  // lives in the link rather than in either end.
  output logic [7:0] tx_data,
  output logic       tx_valid,
  input  logic       tx_ack,
  input  logic [7:0] rx_data,
  input  logic       rx_valid,
  output logic       rx_ack,

  // For the interrupt the i960 takes on RXRDY/TXRDY (model2.cpp gates it on
  // m_intena, so the core wires this into the same request register).
  output logic       irq,
  // AND THE TWO SEPARATELY, because the two ends of this link do NOT take the
  // same interrupt and combining them breaks the sound board outright.
  //
  // The main board ORs them -- model2.cpp's sound_ready_w is literally
  // `if (m_uart->txrdy_r() || m_uart->rxrdy_r())` -- because TXRDY is what
  // paces the i960's transmit loop.
  //
  // The sound board's 68000 must take RX only. TXRDY is high whenever the
  // transmitter is free, which is nearly always, so an IPL driven from the OR
  // is asserted permanently: the moment the firmware unmasks interrupts with
  // `move #$2100, SR` at 0x51E it re-enters the handler forever and never
  // executes another mainline instruction. That is exactly what it did, at
  // instruction 71,385, having matched MAME perfectly up to that point.
  output logic       irq_rx,
  output logic       irq_tx
);

  // ------------------------------------------------------------- registers
  // Only three command bits are meaningful to either firmware: 6 = internal
  // reset, 2 = RxEN, 0 = TxEN. The rest -- DTR, RTS, error reset, hunt mode --
  // are written and ignored, and the whole byte is kept so that stays visible
  // rather than being silently narrowed to the bits that happen to be read.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [7:0] cmd_r;
  /* verilator lint_on UNUSEDSIGNAL */
  // The mode byte is CAPTURED AND NOT ACTED ON. Both firmwares program 8N1 at
  // the same divisor -- there is one link and both ends configure it the same
  // way -- so nothing here varies with it. Kept because it is the register the
  // real part has, and because a mode byte arriving when a command was
  // expected is the failure this sequencing exists to prevent: if that is ever
  // suspected, this is the value to look at.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [7:0] mode_r;
  /* verilator lint_on UNUSEDSIGNAL */
  logic       expect_mode;  // an internal reset arms the mode write
  logic [7:0] rx_hold;
  logic       rxrdy;        // a byte is waiting to be read
  logic       txrdy;        // the transmit holding register is free
  logic       txempty;

  // i8251 status:
  //   7 DSR  6 SYNDET  5 FE  4 OE  3 PE  2 TXEMPTY  1 RXRDY  0 TXRDY
  // The error bits are always clear -- see the header on why.
  wire [7:0] status = {1'b1, 1'b0, 3'b000, txempty, rxrdy, txrdy};

  assign dout   = addr ? status : rx_hold;
  assign data_o = rx_hold;
  assign stat_o = status;

  // A read of the data register consumes the byte, exactly as the real part
  // does; the flag must fall or the firmware reads the same byte forever. The
  // top level therefore asserts `sel` for a read ONLY when the access names the
  // data byte alone -- a firmware polling status with a wider access would
  // otherwise consume a byte it never looked at.
  wire rd_data = sel && !we && !addr;
  wire wr_data = sel &&  we && !addr;
  wire wr_ctrl = sel &&  we &&  addr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cmd_r <= 8'd0; mode_r <= 8'd0; expect_mode <= 1'b1;
      rx_hold <= 8'd0; rxrdy <= 1'b0;
      txrdy <= 1'b1; txempty <= 1'b1;
      tx_data <= 8'd0; tx_valid <= 1'b0; rx_ack <= 1'b0;
    end else begin
      rx_ack <= 1'b0;

      // ---- control writes
      if (wr_ctrl) begin
        if (expect_mode) begin
          // After a reset the first write to the control port is the MODE
          // byte, not a command. Getting this wrong makes the mode look like a
          // command and the link never starts.
          mode_r      <= din;
          expect_mode <= 1'b0;
        end else begin
          cmd_r <= din;
          // Internal reset: the next control write is a mode byte again.
          if (din[6]) begin
            expect_mode <= 1'b1;
            rxrdy       <= 1'b0;
            txrdy       <= 1'b1;
            txempty     <= 1'b1;
            tx_valid    <= 1'b0;
          end
          // Error reset clears bits this model never sets; accepted and ignored.
        end
      end

      // ---- transmit
      if (wr_data) begin
        tx_data  <= din;
        tx_valid <= 1'b1;
        txrdy    <= 1'b0;
        txempty  <= 1'b0;
      end
      if (tx_valid && tx_ack) begin
        tx_valid <= 1'b0;
        txrdy    <= 1'b1;     // the holding register is free again
        txempty  <= 1'b1;
      end

      // ---- receive
      if (rx_valid && !rxrdy) begin
        rx_hold <= rx_data;
        rxrdy   <= 1'b1;
        rx_ack  <= 1'b1;
      end
      if (rd_data) rxrdy <= 1'b0;
    end
  end

  // RxEN/TxEN are command bits 2 and 0; the interrupt follows whichever is
  // enabled, which is what model2.cpp's txrdy_r()/rxrdy_r() gate does.
  assign irq_rx = rxrdy && cmd_r[2];
  assign irq_tx = txrdy && cmd_r[0];
  assign irq    = irq_rx || irq_tx;

endmodule
