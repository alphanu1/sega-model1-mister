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
// The coprocessor: mb86233_core plus the board around it.
//
// The core has been built and fuzz-verified for weeks; this is the wiring that
// was missing. From model1.cpp's machine config and model1_m.cpp's handlers —
// see docs/m2-tgp-integration.md for the full transcription.
//
//   AS_PROGRAM  0x000-0x7ff   microcode ROM, 2048 words = 315-5573.bin exactly
//   AS_DATA     internal RAM, with the two FIFOs forwarded out at 0x0100/0x0400
//   AS_IO       copro RAM window, four math units, and a 2 MB data-ROM window
//   AS_RF       LEDs, discarded
//
// THE TGP's COPRO RAM RULE IS NOT THE V60's
//
// It has FOUR address registers, selected by IO address bits 4:3 — MAME's
// `.select(0x18)` with `m_copro_ram_adr[offset >> 3]` — and its increment is
// unconditional, stepping by FOUR when bit 18 of the register is set and by one
// otherwise. The V60's single register increments only when its bit 15 is set,
// and always by one. Two different rules on the same RAM; keeping each side's
// registers on its own side is what makes that tractable.
//
// WHAT IS NOT HERE YET
//
// The four math units and the data-ROM window are brought out as external ports
// rather than implemented inside. Both are table lookups into memory far too
// large for M10K — 256 KB of tables and 2 MB of data — so they belong in SDRAM,
// and the integrator owns that. The ports exist so the core can be exercised
// against a testbench that serves them from the extracted ROMs.

`timescale 1ns/1ps

module m1_tgp #(
  // AS_PROGRAM is 0x000-0x7ff. The microcode is exactly this size, so a smaller
  // parameter would silently alias rather than fail.
  parameter int unsigned PROG_WORDS = 2048
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---------------------------------------------------------- microcode ROM
  // Written before the core is released from reset. On hardware this arrives
  // over the MRA path like every other ROM; hard rule 2 keeps it out of the
  // repository either way.
  input  logic        ucode_we,
  input  logic [10:0] ucode_addr,
  input  logic [31:0] ucode_data,

  // ------------------------------------------------------- copro RAM port
  // Straight through to m1_copro_if, which arbitrates against the V60.
  output logic        ram_req,
  output logic        ram_we,
  output logic [12:0] ram_addr,
  output logic [31:0] ram_wdata,
  input  logic [31:0] ram_rdata,
  input  logic        ram_ack,

  // ------------------------------------------------------------ the FIFOs
  input  logic [31:0] fifo_in_data,    // V60 -> TGP, at data 0x0100
  input  logic        fifo_in_valid,
  output logic        fifo_in_pop,

  output logic [31:0] fifo_out_data,   // TGP -> V60, at data 0x0400
  output logic        fifo_out_push,
  input  logic        fifo_out_full,

  // ------------------------------------- math tables and the data-ROM window
  // Both live in SDRAM. `tbl_addr` indexes 32-bit words of copro_tables, whose
  // four 16K-word quadrants are sincos/atan/inv/isqrt; `dat_addr` indexes the
  // 2 MB copro_data as 32-bit words.
  output logic        tbl_req,
  output logic [15:0] tbl_addr,
  input  logic [31:0] tbl_rdata,
  input  logic        tbl_ack,

  output logic        dat_req,
  output logic [18:0] dat_addr,
  input  logic [31:0] dat_rdata,
  input  logic        dat_ack,

  // Telemetry: is it executing, and is it retiring anything.
  output logic [15:0] dbg_retires,
  output logic [15:0] dbg_pc,
  output logic        dbg_unimplemented
);

  // ------------------------------------------------------------ microcode ROM
  // 2048 x 32 is 8 M10K. One write port for the loader, one read for the core.
  (* ramstyle = "M10K" *) logic [31:0] prog [PROG_WORDS];

  logic [15:0] prog_addr;
  logic [31:0] prog_rdata;

  always_ff @(posedge clk) begin
    if (ucode_we) prog[ucode_addr] <= ucode_data;
    prog_rdata <= prog[prog_addr[10:0]];
  end

  // ----------------------------------------------------------- the core
  logic [15:0] io_addr;
  logic        io_rd, io_wr;
  logic [31:0] io_wdata, io_rdata;
  logic        io_ack;
  logic        fifo_rd, fifo_wr;
  logic [31:0] fifo_wdata, fifo_rdata;
  logic        fifo_ack;
  logic        retire;
  logic [15:0] retire_pc;

  // Architectural state the lockstep harness uses; unread here.
  logic [31:0] u_a, u_b, u_d, u_p, u_st, u_mwdata, u_mrdata;
  logic [15:0] u_m;
  logic [16:0] u_maddr;
  logic        u_mwe, u_mre;
  logic [7:0]  u_c0, u_c1, u_rep;

  mb86233_core core (
    .clk(clk), .rst_n(rst_n),
    .prog_addr(prog_addr), .prog_rdata(prog_rdata),
    .io_addr(io_addr), .io_rd(io_rd), .io_wr(io_wr),
    .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ack(io_ack),
    .fifo_rd(fifo_rd), .fifo_wr(fifo_wr), .fifo_wdata(fifo_wdata),
    .fifo_rdata(fifo_rdata), .fifo_ack(fifo_ack),
    .gpio(4'd0),
    .retire(retire), .retire_pc(retire_pc), .unimplemented(dbg_unimplemented),
    // The lockstep bridge's view: unused in the design, driven from sim/tgp for
    // M0 exit criterion 2. Named rather than left empty so the connection is
    // explicit — an empty-by-name pin and a genuinely forgotten one look
    // identical in a diff.
    .dbg_a(u_a), .dbg_b(u_b), .dbg_d(u_d), .dbg_p(u_p), .dbg_st(u_st),
    .dbg_m(u_m), .dbg_mem_addr(u_maddr), .dbg_mem_wdata(u_mwdata),
    .dbg_mem_we(u_mwe), .dbg_mem_re(u_mre), .dbg_mem_rdata(u_mrdata),
    .dbg_c0(u_c0), .dbg_c1(u_c1), .dbg_rep(u_rep)
  );

  // ------------------------------------------------------- data-space FIFOs
  // mb86233_mem forwards exactly two data addresses out here: 0x0100 reads the
  // inbound FIFO and 0x0400 writes the outbound one. Both are held until ack.
  assign fifo_in_pop   = fifo_rd && fifo_in_valid;
  assign fifo_out_push = fifo_wr && !fifo_out_full;
  assign fifo_out_data = fifo_wdata;
  assign fifo_rdata    = fifo_in_data;

  // A read of an empty inbound FIFO must NOT acknowledge, or the microcode
  // proceeds on a stale word. MAME's generic_fifo blocks the same way; that is
  // how the TGP waits for the V60 without a status register.
  assign fifo_ack = fifo_rd ? fifo_in_valid
                  : fifo_wr ? !fifo_out_full
                  : 1'b0;

  // ------------------------------------------------------------- IO space
  //   0x0000-0x001f   copro RAM: addr at [2:0]==0, data at [2:0]==1,
  //                   register index in [4:3]
  //   0x0020-0x0023   sincos     0x0024-0x0027  atan
  //   0x0028-0x0029   inv        0x002a-0x002b  isqrt
  //   0x002e          copro_data window base
  //   0x8000-0xffff   copro_data read, low 15 bits from the address
  logic [31:0] copro_adr [4];         // the TGP's four registers
  logic [31:0] dat_base;

  wire        io_lo    = (io_addr[15:5] == 11'd0);
  wire        sel_radr = io_lo && (io_addr[2:0] == 3'd0);
  wire        sel_rdat = io_lo && (io_addr[2:0] == 3'd1);
  wire [1:0]  radr_i   = io_addr[4:3];

  wire        io_mid   = (io_addr[15:5] == 11'd1);   // 0x20-0x3f
  wire        sel_math = io_mid && (io_addr[4:0] <= 5'h0b);
  wire        sel_datb = io_mid && (io_addr[4:0] == 5'h0e);
  wire        sel_datw = io_addr[15];               // 0x8000-0xffff

  // The math tables: four 16K-word quadrants, selected by which unit. Index
  // arithmetic and the exponent fixups are NOT here yet — see the header — so a
  // read presents the quadrant base and the integrator's memory answers.
  wire [1:0] math_unit = (io_addr[4:0] <= 5'h03) ? 2'd0    // sincos
                       : (io_addr[4:0] <= 5'h07) ? 2'd1    // atan
                       : (io_addr[4:0] <= 5'h09) ? 2'd2    // inv
                       :                           2'd3;   // isqrt

  assign tbl_req  = (io_rd && sel_math);
  assign tbl_addr = {math_unit, 14'd0};
  assign dat_req  = (io_rd && sel_datw);
  // index = (base & ~0x7fff) | offset, masked to the ROM's word count.
  assign dat_addr = {dat_base[18:15], io_addr[14:0]};

  // The copro RAM window drives m1_copro_if. Held until its acknowledge.
  assign ram_req   = (io_rd || io_wr) && sel_rdat;
  assign ram_we    = io_wr && sel_rdat;
  assign ram_addr  = copro_adr[radr_i][12:0];
  assign ram_wdata = io_wdata;

  always_comb begin
    io_rdata = 32'd0;
    if      (sel_radr) io_rdata = copro_adr[radr_i];
    else if (sel_rdat) io_rdata = ram_rdata;
    else if (sel_math) io_rdata = tbl_rdata;
    else if (sel_datw) io_rdata = dat_rdata;
  end

  // Register reads and writes finish immediately; anything behind memory waits.
  assign io_ack = sel_radr ? (io_rd || io_wr)
                : sel_rdat ? ram_ack
                : sel_math ? (io_wr || tbl_ack)
                : sel_datb ? io_wr
                : sel_datw ? dat_ack
                : (io_rd || io_wr);   // AS_RF LEDs and anything unmapped

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) copro_adr[i] <= '0;
      dat_base <= '0;
      dbg_retires <= '0; dbg_pc <= '0;
    end else begin
      if (io_wr && sel_radr) copro_adr[radr_i] <= io_wdata;
      if (io_wr && sel_datb) dat_base <= io_wdata;

      // THE TGP's INCREMENT: unconditional, and by four when bit 18 is set.
      // Not the V60's rule — see the header. MAME does this on both the read
      // and the write handler.
      if (ram_ack && sel_rdat)
        copro_adr[radr_i] <= copro_adr[radr_i]
                           + (copro_adr[radr_i][18] ? 32'd4 : 32'd1);

      if (retire) begin
        dbg_pc <= retire_pc;
        if (dbg_retires != 16'hffff) dbg_retires <= dbg_retires + 16'd1;
      end
    end
  end

endmodule
