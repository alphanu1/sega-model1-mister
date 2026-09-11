// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The wire between the two i8251s, and the only thing that crosses between the
// main board and the sound board.
//
// One byte in flight each way, delivered after BYTE_CYCLES. That delay is the
// whole point: at 31.25 kHz a byte takes about 32 microseconds, so a sender
// that writes two bytes back to back finds the second one refused until the
// first has landed. Deliver instantly and the transmitter is never busy, which
// is a link no real program was written against -- a command burst arrives in a
// few microseconds instead of a few hundred, and anything that paces itself on
// TXRDY runs at the wrong speed.
//
// Directions are independent, as they are on the real pair: the i960 can be
// sending a command while the sound board is answering.

`timescale 1ns/1ps

module m2_sound_link #(
  parameter int unsigned BYTE_CYCLES = 16_000    // 31,250 baud 8N1 at 50 MHz
) (
  input  logic       clk,
  input  logic       rst_n,

  // Main board end.
  input  logic [7:0] a_tx_data,
  input  logic       a_tx_valid,
  output logic       a_tx_ack,
  output logic [7:0] a_rx_data,
  output logic       a_rx_valid,
  input  logic       a_rx_ack,

  // Sound board end.
  input  logic [7:0] b_tx_data,
  input  logic       b_tx_valid,
  output logic       b_tx_ack,
  output logic [7:0] b_rx_data,
  output logic       b_rx_valid,
  input  logic       b_rx_ack,

  // Every byte the main board has sent, for the serial debug channel. The
  // reference emits a known 59 bytes over attract mode, so this is a byte-exact
  // oracle for the whole path before any sound chip exists.
  output logic [31:0] dbg_a_bytes,
  output logic  [7:0] dbg_a_last,
  // AN ORDER-SENSITIVE SIGNATURE OF THE WHOLE STREAM, in one register.
  //
  // A count says how many bytes went; a sum or an xor says which bytes went but
  // not in what order, and a command protocol is entirely order. Rotate the
  // accumulator one bit and xor the byte in, and the same 48 bytes in a
  // different order give a different answer. MAME's attract-mode stream is
  // 0x6ae52ed8, so the board has a single number to be right or wrong against
  // over a channel that carries two words a frame.
  output logic [31:0] dbg_a_sig
);

  localparam int unsigned CW = $clog2(BYTE_CYCLES);

  // One shot per direction: take the byte, wait the line time, present it.
  logic [CW-1:0] a2b_cnt, b2a_cnt;
  logic          a2b_busy, b2a_busy;
  logic [7:0]    a2b_byte, b2a_byte;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a2b_cnt <= '0; a2b_busy <= 1'b0; a2b_byte <= 8'd0;
      b2a_cnt <= '0; b2a_busy <= 1'b0; b2a_byte <= 8'd0;
      a_tx_ack <= 1'b0; b_tx_ack <= 1'b0;
      a_rx_valid <= 1'b0; b_rx_valid <= 1'b0;
      a_rx_data <= 8'd0;  b_rx_data <= 8'd0;
      dbg_a_bytes <= 32'd0; dbg_a_last <= 8'd0; dbg_a_sig <= 32'd0;
    end else begin
      a_tx_ack <= 1'b0;
      b_tx_ack <= 1'b0;

      // ---- main board -> sound board
      if (!a2b_busy && !b_rx_valid) begin
        if (a_tx_valid) begin
          a2b_byte    <= a_tx_data;
          a2b_cnt     <= CW'(BYTE_CYCLES - 1);
          a2b_busy    <= 1'b1;
          a_tx_ack    <= 1'b1;       // accepted; the sender may prepare another
          dbg_a_last  <= a_tx_data;
          dbg_a_sig   <= {dbg_a_sig[30:0], dbg_a_sig[31]} ^ {24'd0, a_tx_data};
          if (!(&dbg_a_bytes)) dbg_a_bytes <= dbg_a_bytes + 32'd1;
        end
      end else if (a2b_busy) begin
        if (a2b_cnt == '0) begin
          b_rx_data  <= a2b_byte;
          b_rx_valid <= 1'b1;
          a2b_busy   <= 1'b0;
        end else a2b_cnt <= a2b_cnt - CW'(1);
      end
      if (b_rx_valid && b_rx_ack) b_rx_valid <= 1'b0;

      // ---- sound board -> main board
      if (!b2a_busy && !a_rx_valid) begin
        if (b_tx_valid) begin
          b2a_byte <= b_tx_data;
          b2a_cnt  <= CW'(BYTE_CYCLES - 1);
          b2a_busy <= 1'b1;
          b_tx_ack <= 1'b1;
        end
      end else if (b2a_busy) begin
        if (b2a_cnt == '0) begin
          a_rx_data  <= b2a_byte;
          a_rx_valid <= 1'b1;
          b2a_busy   <= 1'b0;
        end else b2a_cnt <= b2a_cnt - CW'(1);
      end
      if (a_rx_valid && a_rx_ack) a_rx_valid <= 1'b0;
    end
  end

endmodule
