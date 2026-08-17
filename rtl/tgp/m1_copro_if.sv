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
// The V60 side of the coprocessor interface — CPR, 0xd00000-0xdfffff.
//
// Four registers, transcribed from model1.cpp's memory map and model1_m.cpp's
// handlers. See docs/m2-tgp-integration.md; the two rules worth restating here
// are the ones that would cost a debugging session if guessed:
//
//   1. THE RAM WINDOW COMMITS ON THE HIGH HALF, and post-increments the address
//      register only when bit 15 of that register is set. The increment is a
//      property of the register, not of the access.
//
//   2. THE FIFO WINDOW IS ASYMMETRIC. A read pops on the LOW access and the
//      high access returns the high half of that same popped word; a write
//      latches on the low access and pushes on the HIGH one. Reversed, every
//      transfer is skewed by one word, which surfaces as a geometry fault a
//      long way from here.
//
// The FIFO status register is a constant 0xFFFF in MAME — it never reports full
// or empty. That is reproduced rather than improved on: inventing a status
// encoding the V60 might act on is a way to invent a bug. Note that m1_main's
// default read of 0xFFFF for undecoded space already produces this, so the
// register needs no logic at all; it is listed here so the next reader does not
// go looking for it.
//
// WHAT THIS DOES NOT DO YET
//
// The TGP is not attached. The copro RAM is here because the V60 writes it and
// the boot trace shows 510 accesses to the address register in 700 M cycles, so
// this much is immediately observable on its own. The second port for the TGP,
// the microcode ROM, the data-ROM window and the four math units come after.

`timescale 1ns/1ps

module m1_copro_if #(
  // 8192 32-bit words: `copro_ram_data[m_v60_copro_ram_adr & 0x1fff]`.
  parameter int unsigned RAM_WORDS = 8192,

  // Depth of each direction's FIFO. MAME uses an unbounded GENERIC_FIFO_U32,
  // so there is no hardware figure to match; this is deep enough for a command
  // block plus slack, and the counters saturate rather than wrapping so an
  // overflow shows up as a stuck flag instead of silent corruption.
  parameter int unsigned FIFO_DEPTH = 64
) (
  input  logic        clk,
  input  logic        rst_n,

  // ------------------------------------------------------------- V60 side
  // Region selects from m1_decode, already mirror-aware.
  input  logic        sel_adr,
  input  logic        sel_ram,
  input  logic        sel_fifo,

  // ONE CYCLE PER ACCESS, not a held request.
  //
  // m1_main holds m_req from B_IDLE through B_ACK, so a raw request would fire
  // three times. Memory writes survive that — they are idempotent — but a FIFO
  // pop and an address post-increment do not, and triple-incrementing would
  // look like the V60 skipping two words out of every three. Drive this from
  // the single-cycle B_LOCAL state.
  input  logic        stb,
  input  logic        we,
  input  logic        a1,          // word offset: 0 = low half, 1 = high half
  input  logic [1:0]  be,          // byte enables, for the address register
  input  logic [15:0] wdata,
  // COMBINATIONAL, valid whenever the selects are.
  //
  // The RAM's data is already registered — the read address tracks the address
  // register continuously rather than being presented per access — so there is
  // nothing to wait for, and m1_main samples this in the same cycle it strobes.
  // Registering it here would hand m1_main the previous access's value.
  output logic [15:0] q,

  // ------------------------------------------------------------- TGP side
  // Present so the shape is fixed before the TGP arrives. The RAM has ONE
  // physical port — Quartus will not infer a second write port, measured in
  // m1_mainram — so TGP accesses will have to be arbitrated against the V60's
  // here rather than assumed concurrent.
  output logic [31:0] fifo_in_data,   // V60 -> TGP
  output logic        fifo_in_valid,
  input  logic        fifo_in_pop,

  input  logic [31:0] fifo_out_data,  // TGP -> V60
  input  logic        fifo_out_push,
  output logic        fifo_out_full,

  // Telemetry for the debug overlay: how much traffic has crossed. A count
  // that never moves separates "the V60 is not talking to us" from "we are not
  // answering", which on this project has been the difference between two very
  // different days.
  output logic [15:0] dbg_ram_writes,
  output logic [15:0] dbg_fifo_pushes
);

  localparam int AW = $clog2(RAM_WORDS);

  // --------------------------------------------------------- address register
  // Sixteen bits, and all sixteen are kept: bit 15 is the post-increment
  // enable and the low 13 index the RAM, so the middle bits are neither used
  // nor safe to drop — the V60 reads this register back.
  logic [15:0] adr;

  // Write latch for the low half. COMBINE_DATA in MAME, so byte enables apply
  // HERE and not to the RAM, whose write is always a full 32 bits. Only the low
  // half needs latching: the high half arrives on the access that commits.
  logic [15:0] lat_lo;

  // ----------------------------------------------------------------- the RAM
  // One 32-bit array rather than four byte lanes: the commit is always the full
  // word, so there are no byte enables to defeat inference. 8192 x 32 is 32
  // M10K, which is the single largest new cost in M2 — see the budget in
  // docs/HANDOFF.md before adding to it.
  (* ramstyle = "M10K" *) logic [31:0] ram [RAM_WORDS];

  logic [31:0] ram_q;
  logic        ram_we;
  logic [31:0] ram_din;

  // The read address tracks the address register continuously, so the data for
  // an access is already registered when the access arrives. Both halves of a
  // word therefore see the same contents, which is what MAME does — the
  // increment lands after the high half, not between the two reads.
  always_ff @(posedge clk) begin
    if (ram_we) ram[adr[AW-1:0]] <= ram_din;
    ram_q <= ram[adr[AW-1:0]];
  end

  // ------------------------------------------------------------------- FIFOs
  localparam int FW = $clog2(FIFO_DEPTH);

  logic [31:0]   fin  [FIFO_DEPTH];      // V60 -> TGP
  logic [FW:0]   fin_wr, fin_rd;
  logic [31:0]   fout [FIFO_DEPTH];      // TGP -> V60
  logic [FW:0]   fout_wr, fout_rd;

  wire fin_empty  = (fin_wr  == fin_rd);
  wire fin_full   = (fin_wr[FW-1:0] == fin_rd[FW-1:0]) && (fin_wr[FW] != fin_rd[FW]);
  wire fout_empty = (fout_wr == fout_rd);
  wire fout_full  = (fout_wr[FW-1:0] == fout_rd[FW-1:0]) && (fout_wr[FW] != fout_rd[FW]);

  assign fifo_in_data  = fin[fin_rd[FW-1:0]];
  assign fifo_in_valid = !fin_empty;
  assign fifo_out_full = fout_full;

  // The word most recently popped from the outbound FIFO, held so the high
  // access can return its top half. MAME keeps exactly this latch
  // (m_v60_copro_fifo_r) for the same reason.
  logic [31:0] pop_r;

  // The head of the outbound FIFO: what the next low access will pop. Read
  // combinationally so that access returns it and latches it in the same cycle.
  wire [31:0] fout_head = fout_empty ? pop_r : fout[fout_rd[FW-1:0]];

  always_comb begin
    if      (sel_adr)  q = adr;
    else if (sel_ram)  q = a1 ? ram_q[31:16] : ram_q[15:0];
    // Low returns the word about to be popped; high returns the high half of
    // the word the preceding low access popped. MAME keeps the same latch.
    else if (sel_fifo) q = a1 ? pop_r[31:16] : fout_head[15:0];
    else               q = 16'hffff;
  end

  // ------------------------------------------------------------------ access
  wire acc      = stb && (sel_adr || sel_ram || sel_fifo);
  wire wr_adr   = acc &&  we && sel_adr;
  wire rd_ram_h = acc && !we && sel_ram  &&  a1;
  wire wr_ram_h = acc &&  we && sel_ram  &&  a1;
  wire rd_fifo_l= acc && !we && sel_fifo && !a1;
  wire wr_fifo_h= acc &&  we && sel_fifo &&  a1;

  // Post-increment: on the high half of a RAM access in either direction, and
  // only when the register asks for it.
  wire ram_step = (rd_ram_h || wr_ram_h) && adr[15];

  always_comb begin
    ram_we  = wr_ram_h;
    // MAME: `v = latch[0] | (latch[1] << 16)`, so the committed word is
    // {high, low} — and the high half is the data arriving on THIS access,
    // while the low half comes from the latch the previous access filled.
    // Assembling these the other way round is a silent half-swap on every
    // word; the directed test catches it, nothing else would until the
    // geometry came out wrong.
    ram_din = {wdata, lat_lo};
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      adr <= '0; lat_lo <= '0; pop_r <= '0;
      fin_wr <= '0; fin_rd <= '0; fout_wr <= '0; fout_rd <= '0;
      dbg_ram_writes <= '0; dbg_fifo_pushes <= '0;
    end else begin
      // ---- the address register
      if (wr_adr) begin
        if (be[0]) adr[7:0]  <= wdata[7:0];
        if (be[1]) adr[15:8] <= wdata[15:8];
      end else if (ram_step) begin
        adr <= adr + 16'd1;
      end

      // ---- write latches. The low half is latched; the high half is used
      //      directly in ram_din, so it only needs keeping for readback.
      if (acc && we && sel_ram && !a1) begin
        if (be[0]) lat_lo[7:0]  <= wdata[7:0];
        if (be[1]) lat_lo[15:8] <= wdata[15:8];
      end
      if (wr_ram_h && dbg_ram_writes != 16'hffff)
        dbg_ram_writes <= dbg_ram_writes + 16'd1;

      // ---- inbound FIFO: the V60 pushes on the HIGH access
      if (wr_fifo_h && !fin_full) begin
        fin[fin_wr[FW-1:0]] <= {wdata, lat_lo};
        fin_wr <= fin_wr + 1'd1;
        if (dbg_fifo_pushes != 16'hffff) dbg_fifo_pushes <= dbg_fifo_pushes + 16'd1;
      end
      if (acc && we && sel_fifo && !a1) begin
        // low half latches only
        lat_lo <= wdata;
      end
      if (fifo_in_pop && !fin_empty) fin_rd <= fin_rd + 1'd1;

      // ---- outbound FIFO: the V60 pops on the LOW access
      if (fifo_out_push && !fout_full) begin
        fout[fout_wr[FW-1:0]] <= fifo_out_data;
        fout_wr <= fout_wr + 1'd1;
      end
      if (rd_fifo_l) begin
        // An empty pop keeps the previous word, which is what a FIFO with no
        // underflow reporting does. MAME's status register is a constant, so
        // there is nothing here software could have checked.
        pop_r <= fout_head;
        if (!fout_empty) fout_rd <= fout_rd + 1'd1;
      end

    end
  end

endmodule
