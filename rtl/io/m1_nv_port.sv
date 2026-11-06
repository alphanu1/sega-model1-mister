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
// THE NVRAM SAVE: the OSD's "Save settings (NVRAM)" line, and the upload of
// the MRA's <nvram index="7" size="65672"> back to the HPS. The LOAD of that
// file is m1_rom_loader's (index 7), which has the layout and the tag:
//
//   0x00000-0x00007  "M1NVRAM1"
//   0x00008-0x00087  the 93C46, 64 words      SDRAM word IOFW_BASE+EE_WOFF+n
//   0x00088-0x10087  RAMA, 64 KB              SDRAM word NV_BASE+n
//
// Both live in SDRAM: RAMA is where the V60 keeps it, and m1_ioz80 writes
// every EEPROM word it changes through to the image's block. So the upload is
// one SDRAM read per word, through port 4 - the I/O board's firmware port,
// shared here rather than adding a thirteenth port to the controller. The
// Z80's requests (from its clock crossing) and the upload's are queued and
// served one at a time; neither ever waits behind more than one of the other.
//
// THE FRAMEWORK'S UPLOAD (sys/hps_io.sv, WIDE): each FIO_FILE_TX_DAT strobe
// samples ioctl_din into the word it returns, moves ioctl_addr on by two and
// pulses ioctl_rd. So ioctl_din must hold the word at ioctl_addr by the next
// strobe. An SDRAM read cannot promise that, so ioctl_wait is held from the
// ioctl_rd until the word is in din_r: sys_top then withholds the strobe's
// acknowledge and the HPS waits. GATED ON ioctl_upload, because ioctl_wait
// stalls the HPS itself - held outside a transfer, the core never shows its
// OSD (m1_rom_loader's note).
//
// THE SAVE IS HOST-INITIATED ONLY AFTER THE CORE ASKS. Main_MiSTer saves the
// MRA's <nvram> on the OSD's close when UIO_CHK_UPLOAD answers - which hps_io
// does once per rising edge of ioctl_upload_req - and on "Save settings" in
// the system menu. save_req is that edge.
//
// The game keeps running while the file is read: a save taken in the middle
// of a settings write can hold half of it, as the Model 2 core's can.

`timescale 1ns/1ps

module m1_nv_port #(
  parameter logic [15:0] NVS_INDEX = 16'd7,
  parameter logic [25:1] NV_BASE   = 25'hFA0000,             // RAMA, 0x1F40000
  parameter logic [25:1] EE_BASE   = 25'hD00000 + 25'h2000   // IOFW_BASE + EE_WOFF
) (
  input  logic        clk,
  input  logic        rst_n,            // power-on (mem_rst_n): never the game's

  input  logic        save_btn,         // the OSD line's status bit
  output logic        save_req,         // to hps_io's ioctl_upload_req

  // hps_io
  input  logic        ioctl_upload,
  input  logic        ioctl_rd,
  input  logic [15:0] ioctl_index,
  input  logic [26:0] ioctl_addr,
  output logic [15:0] ioctl_din,
  output logic        ioctl_wait,

  // The Z80's side of port 4, from its clock crossing (m1_cdc_port's b side):
  // a one-cycle request, its operands held until the next one.
  input  logic        io_req,
  input  logic        io_we,
  input  logic [25:1] io_addr,
  input  logic [15:0] io_din,
  output logic        io_ack,
  output logic [15:0] io_dout,

  // SDRAM port 4. m1_sdram takes one transaction per rising edge of p_req and
  // stretches p_ack; data is valid on the ack's rising edge.
  output logic        p_req,
  output logic        p_we,
  output logic [25:1] p_addr,
  output logic [15:0] p_din,
  input  logic        p_ack,
  input  logic [15:0] p_dout
);

  // "M1NVRAM1", little-endian words
  function automatic logic [15:0] tagw(input logic [1:0] i);
    case (i)
      2'd0: tagw = 16'h314d;
      2'd1: tagw = 16'h564e;
      2'd2: tagw = 16'h4152;
      default: tagw = 16'h314d;
    endcase
  endfunction

  // --------------------------------------------------------- save request
  logic [2:0] save_sync;
  always_ff @(posedge clk) save_sync <= {save_sync[1:0], save_btn};
  assign save_req = save_sync[1] & ~save_sync[2];

  // ------------------------------------------------------------ the upload
  wire ul     = ioctl_upload && (ioctl_index == NVS_INDEX);
  wire a_tag  = (ioctl_addr[26:3] == 24'd0);
  wire a_ee   = (ioctl_addr[26:8] == 19'd0) && !a_tag && (ioctl_addr[7:0] < 8'h88);
  wire a_ram  = (ioctl_addr >= 27'h88) && (ioctl_addr < 27'h10088);

  logic        nv_pend;      // a word is wanted from SDRAM
  logic [25:1] nv_addr;
  logic        nv_wait;      // ioctl_rd seen, din_r not yet holding its word
  logic [15:0] din_r;

  // ---------------------------------------------------------- port 4 share
  logic        io_pend, busy, own_nv, ack_d;
  logic        io_we_q;
  logic [25:1] io_addr_q;
  logic [15:0] io_din_q;
  wire         ack_rise = p_ack && !ack_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      nv_pend <= 1'b0; nv_addr <= '0; nv_wait <= 1'b0; din_r <= 16'hffff;
      io_pend <= 1'b0; io_we_q <= 1'b0; io_addr_q <= '0; io_din_q <= '0;
      busy <= 1'b0; own_nv <= 1'b0; ack_d <= 1'b0;
      p_req <= 1'b0; p_we <= 1'b0; p_addr <= '0; p_din <= '0;
    end else begin
      ack_d <= p_ack;
      p_req <= 1'b0;

      // The upload: a word from SDRAM, a tag word, or FFFF past the end.
      if (ul && ioctl_rd) begin
        if (a_tag) begin
          din_r <= tagw(ioctl_addr[2:1]);
        end else if (a_ee || a_ram) begin
          nv_pend <= 1'b1;
          nv_wait <= 1'b1;
          nv_addr <= a_ee ? (EE_BASE + 25'(ioctl_addr[7:1] - 7'd4))
                          : (NV_BASE + 25'(16'(ioctl_addr[16:1] - 16'h44)));
        end else begin
          din_r <= 16'hffff;
        end
      end
      if (!ioctl_upload) begin nv_pend <= 1'b0; nv_wait <= 1'b0; end

      // The Z80's request is a single-cycle pulse: hold it until served.
      if (io_req) begin
        io_pend <= 1'b1; io_we_q <= io_we; io_addr_q <= io_addr; io_din_q <= io_din;
      end

      // One transaction at a time; the next waits for the ack to fall, so a
      // new rising edge of p_req can never meet a stretched ack.
      if (!busy && !p_ack && !p_req) begin
        if (io_pend) begin
          p_req <= 1'b1; p_we <= io_we_q; p_addr <= io_addr_q; p_din <= io_din_q;
          busy <= 1'b1; own_nv <= 1'b0; io_pend <= 1'b0;
        end else if (nv_pend) begin
          p_req <= 1'b1; p_we <= 1'b0; p_addr <= nv_addr; p_din <= 16'd0;
          busy <= 1'b1; own_nv <= 1'b1; nv_pend <= 1'b0;
        end
      end
      if (busy && ack_rise) begin
        busy <= 1'b0;
        if (own_nv) begin din_r <= p_dout; nv_wait <= 1'b0; end
      end
    end
  end

  // The Z80's acknowledge is the controller's, while the transaction is its
  // own: m1_cdc_port takes the rising edge and the data with it.
  assign io_ack  = p_ack && busy && !own_nv;
  assign io_dout = p_dout;

  assign ioctl_din  = din_r;
  // ioctl_rd is in the term so the wait is up in the very cycle after the
  // strobe, before nv_wait can be: sys_top raises the acknowledge on the next
  // edge unless ioctl_wait is high in that cycle.
  assign ioctl_wait = ioctl_upload && ((ul && ioctl_rd) || nv_wait);

endmodule
