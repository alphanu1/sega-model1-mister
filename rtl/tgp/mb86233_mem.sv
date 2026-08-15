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
// Behaviour transcribed from MAME's Model 1 driver:
//
//   src/mame/sega/model1_m.cpp   (copro_data_map)
//   BSD-3-Clause / GPL-2.0 mixed — see THIRD-PARTY.md
//
// Fujitsu MB86233 "TGP" — data-space memory subsystem
//
// Both internal RAM banks plus the decode that routes everything else off-chip.
//
// THE MAP IS NARROWER THAN THIS REPO'S DOCS SAID. copro_data_map is:
//
//   0x0000-0x00ff  RAM bank 0, 256 words
//   0x0100         copro_fifo_in,  READ only, ONE address
//   0x0200-0x03ff  RAM bank 1, 512 words
//   0x0400         copro_fifo_out, WRITE only, ONE address
//
// docs/m0-mb86233-spike.md described this as "accesses to 0x100-0x1ff and
// 0x400+ route externally", which implied two external windows of 256 and
// 64K words. There is exactly one address at each end, one direction each.
// Everything else in the space is unmapped and reads as zero.
//
// The distinction matters for the +0x200 adder: an EA of 0x200 landing on the
// output FIFO is the documented trick (x1 = 0x200 plus the adder), and it works
// precisely because 0x400 is a single decoded address rather than a window that
// a stray address could fall into unnoticed.

`timescale 1ns/1ps

module mb86233_mem (
  input  logic        clk,
  input  logic        rst_n,

  // Data-space port. Single cycle for RAM; external accesses assert ext_req
  // and the caller must hold the access until ext_ack.
  input  logic        req,
  input  logic        we,
  input  logic [16:0] addr,        // 17 bits: the +0x200 adder can reach 0x101ff
  input  logic [31:0] wdata,
  output logic [31:0] rdata,
  output logic        stall,       // external access not yet satisfied

  // Off-chip side.
  output logic        ext_rd,      // read  0x0100 (input FIFO)
  output logic        ext_wr,      // write 0x0400 (output FIFO)
  output logic [31:0] ext_wdata,
  input  logic [31:0] ext_rdata,
  input  logic        ext_ack,

  // Decode visibility, for the core and for assertions.
  output logic        sel_ram0,
  output logic        sel_ram1,
  output logic        sel_fifo_in,
  output logic        sel_fifo_out,
  output logic        unmapped
);

  // --------------------------------------------------------------- decode

  assign sel_ram0     = (addr <= 17'h000ff);
  assign sel_ram1     = (addr >= 17'h00200) && (addr <= 17'h003ff);
  // Single addresses, and direction-specific: 0x0100 has only a read handler
  // and 0x0400 only a write handler in copro_data_map. A write to 0x0100 or a
  // read from 0x0400 hits no handler at all.
  assign sel_fifo_in  = (addr == 17'h00100) && !we;
  assign sel_fifo_out = (addr == 17'h00400) &&  we;
  assign unmapped     = !(sel_ram0 | sel_ram1 | sel_fifo_in | sel_fifo_out);

  // ------------------------------------------------------------------ RAM
  //
  // Kept as two separate arrays rather than one 0x000-0x3ff block with a hole:
  // the banks are physically distinct on the die (the 86233 has "two normal
  // independent ram banks, one of 256 dwords and one of 512" per MAME's header)
  // and inferring them separately is what gets two M10K blocks instead of one
  // oversized one with 256 words of dead space.

  logic [31:0] ram0 [0:255];
  logic [31:0] ram1 [0:511];

  // Power-on contents are ZERO, and that is not a simulation convenience.
  // Cyclone V M10K blocks take their contents from the FPGA configuration
  // bitstream, so on real hardware these come up initialised. Leaving them
  // undefined in RTL makes simulation disagree with the device it models.
  //
  // This was found by lockstep: a generated program read address 0x6a before
  // ever writing it, the reference returned 0 from a zeroed array and the DUT
  // returned 0x26000000 from uninitialised memory. It looked exactly like a
  // transfer bug for several rounds of narrowing — the store path, the read
  // addresses and the write streams were all correct, because nothing had
  // been stored at all.
  integer ri;
  initial begin
    for (ri = 0; ri < 256; ri = ri + 1) ram0[ri] = 32'd0;
    for (ri = 0; ri < 512; ri = ri + 1) ram1[ri] = 32'd0;
  end

  logic [7:0] a0;
  logic [8:0] a1;
  assign a0 = addr[7:0];
  assign a1 = addr[8:0];          // 0x200-0x3ff, so bit 9 distinguishes, [8:0] indexes

  logic [31:0] ram0_q, ram1_q;

  always_ff @(posedge clk) begin
    if (req && we && sel_ram0) ram0[a0] <= wdata;
    ram0_q <= ram0[a0];
  end

  always_ff @(posedge clk) begin
    if (req && we && sel_ram1) ram1[a1] <= wdata;
    ram1_q <= ram1[a1];
  end

  // --------------------------------------------------------- external side

  assign ext_rd    = req & sel_fifo_in;
  assign ext_wr    = req & sel_fifo_out;
  assign ext_wdata = wdata;

  // MAME models this as m_stall plus `goto do_stall`, which re-executes the
  // whole instruction. Here the access simply is not complete until ext_ack,
  // and the core holds the instruction.
  assign stall = req & (sel_fifo_in | sel_fifo_out) & ~ext_ack;

  // ------------------------------------------------------------- read mux
  //
  // RAM reads are registered, so the select must be too or the mux picks the
  // new address's bank while the data is still the old address's.

  logic sel_ram0_q, sel_ram1_q, sel_fifo_in_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sel_ram0_q    <= 1'b0;
      sel_ram1_q    <= 1'b0;
      sel_fifo_in_q <= 1'b0;
    end else begin
      sel_ram0_q    <= req & sel_ram0;
      sel_ram1_q    <= req & sel_ram1;
      sel_fifo_in_q <= req & sel_fifo_in;
    end
  end

  always_comb begin
    if      (sel_fifo_in_q) rdata = ext_rdata;
    else if (sel_ram0_q)    rdata = ram0_q;
    else if (sel_ram1_q)    rdata = ram1_q;
    else                    rdata = 32'd0;   // unmapped reads as zero
  end

endmodule
