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
// The coprocessor RAM, and the V60's window onto it — CPR, 0xd00000-0xdfffff.
//
// Transcribed from model1.cpp's memory map and model1_m.cpp's handlers; see
// docs/m2-tgp-integration.md. Four rules matter, and each reads as plausible
// the wrong way round:
//
//   1. THE RAM WINDOW COMMITS ON THE HIGH HALF. The word is
//      `latch[0] | (latch[1] << 16)`, so the high half is the data arriving on
//      the committing access and the low half comes from the previous access.
//      Getting this backwards is a silent half-swap on every word — it was
//      written backwards here first, and the directed test caught it.
//
//   2. THE V60's POST-INCREMENT is conditional on bit 15 of its address
//      register, applies to reads as well as writes, and steps by one.
//
//   3. THE TGP's RULE IS DIFFERENT: it has FOUR address registers, always
//      increments, and steps by 4 when bit 18 is set. Those registers live on
//      the TGP's side; this module only presents it a memory port.
//
//   4. THE FIFO WINDOW IS ASYMMETRIC. A read pops on the LOW access and the
//      high access returns the high half of that same popped word; a write
//      latches low and pushes on the HIGH one. Reversed, every transfer skews by
//      one word and surfaces as a geometry fault far from here.
//
// The FIFO status register at 0xdc0000 needs no logic: MAME's fifoin_status_r
// returns a constant 0xFFFF and m1_main's default read for undecoded space is
// already exactly that. Noted so nobody goes looking for it.
//
// WHY THERE IS A HANDSHAKE
//
// The RAM has ONE port — Quartus will not infer a second write port, measured at
// 192 ALM becoming 16,059 in rtl/m1_mainram.sv — and two masters. An earlier
// version of this file returned read data combinationally, on the reasoning that
// the read address could track the V60's address register continuously. That
// stops being true the moment the TGP shares the RAM. Keeping a second copy that
// goes stale for one cycle would be correct almost always, which is how this
// project has acquired its worst bugs, so instead the access is acknowledged
// when the data is really there.

`timescale 1ns/1ps

module m1_copro_if #(
  // 8192 32-bit words: `copro_ram_data[adr & 0x1fff]` on both sides.
  parameter int unsigned RAM_WORDS = 8192,

  // DEPTH 16, from the hardware rather than from convenience.
  //
  // model1_m.cpp calls `m_copro_fifo_in->setup(16, ...)` and the same for the
  // outbound one. An earlier version of this file guessed 64 and called it
  // "several command blocks of slack", which was inventing headroom the board
  // does not have.
  //
  // The depth matters because FLOW CONTROL IS BY HALTING A CPU, not by a status
  // register — which is why fifoin_status_r can be a constant 0xFFFF that
  // nothing polls. Mapping the call site onto gen_fifo.h's setup() signature:
  //
  //   on_fifo_empty_pre_sync   -> the TGP stalls on reading an empty FIFO
  //   on_fifo_empty_post_sync  -> the TGP is HALTED while it stays empty
  //   on_fifo_unempty          -> the TGP is released
  //   on_fifo_full_post_sync   -> the V60 is HALTED while the FIFO is full
  //   on_fifo_unfull           -> the V60 is released
  //
  // So a full inbound FIFO must stop the V60 rather than drop the write, and a
  // full outbound FIFO must stop the TGP. Dropping instead loses geometry
  // silently, which is the worst available failure: the picture is wrong and
  // nothing anywhere reports it.
  parameter int unsigned FIFO_DEPTH = 16
) (
  input  logic        clk,
  input  logic        rst_n,

  // ------------------------------------------------------------- V60 side
  // Region selects from m1_decode, already mirror-aware. `req` is HELD until
  // `ack`, like the SDRAM path in m1_main. The action fires once, on the cycle
  // the access completes, so a held request cannot double-pop a FIFO or
  // triple-increment the address.
  input  logic        sel_adr,
  input  logic        sel_ram,
  input  logic        sel_fifo,
  input  logic        req,
  input  logic        we,
  input  logic        a1,          // word offset: 0 = low half, 1 = high half
  input  logic [1:0]  be,          // byte enables; they apply to the LATCHES
  input  logic [15:0] wdata,
  output logic [15:0] q,
  output logic        ack,

  // --------------------------------------------------------- TGP RAM port
  input  logic        tgp_req,
  input  logic        tgp_we,
  input  logic [12:0] tgp_addr,
  input  logic [31:0] tgp_wdata,
  output logic [31:0] tgp_rdata,
  output logic        tgp_ack,

  // ------------------------------------------------------------ the FIFOs
  output logic [31:0] fifo_in_data,   // V60 -> TGP
  output logic        fifo_in_valid,
  input  logic        fifo_in_pop,

  input  logic [31:0] fifo_out_data,  // TGP -> V60
  input  logic        fifo_out_push,
  output logic        fifo_out_full,

  // Backpressure onto the V60. Asserted while the inbound FIFO is full: the bus
  // must stall rather than accept a write that would be dropped. See the depth
  // note above — this is the board's flow control, not an optimisation.
  output logic        v60_stall,

  // Telemetry. A count that never moves separates "the V60 is not talking to
  // us" from "we are not answering", which has been the difference between two
  // very different days on this project.
  output logic [15:0] dbg_ram_writes,
  output logic [15:0] dbg_fifo_pushes,   // V60 -> TGP
  // TGP -> V60, and the V60's reads of them. Without these there is no way to
  // tell "the coprocessor is not answering" from "the coprocessor answered and
  // the V60 did not like it", which are completely different problems.
  output logic [15:0] dbg_fifo_returns,
  output logic [15:0] dbg_fifo_pops,

  // THE TGP TAKING A COMMAND. Counted because nothing counted it, and the gap
  // produced a confident wrong diagnosis: dbg_fifo_pops above counts the V60
  // reading RESULTS out of the output FIFO, which findings.md measured as never
  // happening — 0 in 2,500 accesses — so its zero is correct behaviour and was
  // read as "the coprocessor never drains its input". The two are opposite ends
  // of the interface and only one of them was instrumented.
  output logic [15:0] dbg_fifo_drains
);

  localparam int AW = $clog2(RAM_WORDS);
  localparam int FW = $clog2(FIFO_DEPTH);

  // ------------------------------------------------------------------ the RAM
  // One 32-bit array, not four byte lanes: every commit is a full word, so there
  // are no byte enables to defeat inference. 8192 x 32 is 32 M10K, the largest
  // single new cost in M2 — check the budget in HANDOFF.md before adding to it.
  (* ramstyle = "M10K" *) logic [31:0] ram [RAM_WORDS];

  logic [AW-1:0] ram_addr;
  logic [31:0]   ram_din, ram_q;
  logic          ram_we;

  always_ff @(posedge clk) begin
    if (ram_we) ram[ram_addr] <= ram_din;
    ram_q <= ram[ram_addr];
  end

  // --------------------------------------------------------- V60 registers
  logic [15:0] adr;      // all sixteen bits: bit 15 is the increment enable
  logic [15:0] lat_lo;   // only the low half needs latching
  logic [31:0] pop_r;    // the word the last low FIFO access popped

  // ------------------------------------------------------------------- FIFOs
  logic [31:0] fin  [FIFO_DEPTH];
  logic [31:0] fout [FIFO_DEPTH];
  logic [FW:0] fin_wr, fin_rd, fout_wr, fout_rd;

  wire fin_empty  = (fin_wr  == fin_rd);
  wire fin_full   = (fin_wr[FW-1:0] == fin_rd[FW-1:0]) && (fin_wr[FW] != fin_rd[FW]);
  wire fout_empty = (fout_wr == fout_rd);
  wire fout_full  = (fout_wr[FW-1:0] == fout_rd[FW-1:0]) && (fout_wr[FW] != fout_rd[FW]);

  assign fifo_in_data  = fin[fin_rd[FW-1:0]];
  assign fifo_in_valid = !fin_empty;
  assign fifo_out_full = fout_full;

  // What the next low access will pop.
  wire [31:0] fout_head = fout_empty ? pop_r : fout[fout_rd[FW-1:0]];

  // Hold the V60 off while there is nowhere to put its next command word. MAME
  // halts the CPU outright; stalling the access is the bus-level equivalent and
  // keeps the effect local to this interface.
  assign v60_stall = fin_full;

  // ---------------------------------------------------------------- arbiter
  // The V60 wins. Its accesses are rare — the boot trace shows none at all to
  // the data window over 700 M cycles — and it is the side whose CPU stalls,
  // whereas a coprocessor can be held a cycle.
  //
  // A RAM access takes two cycles: present the address, then act on the
  // registered data. Register and FIFO accesses touch no RAM and finish in one.
  typedef enum logic [1:0] { S_IDLE, S_V60_RAM, S_TGP } state_t;
  state_t st;

  // ONE ACCESS PER REQUEST, however long the request is held.
  //
  // m1_main holds m_req until it sees ack, and the region selects come from the
  // held address, so without this the state machine returns to S_IDLE, sees the
  // same request still asserted, and runs the access again — incrementing the
  // address once per pass. That is the complement of this project's other
  // handshake lesson ("acknowledges must be held, not pulsed"): here the
  // request is held and the ACTION must be a one-shot.
  logic served;

  wire v60_acc = req && !served && (sel_adr || sel_ram || sel_fifo);
  wire v60_ram = req && !served && sel_ram;

  // Post-increment: on the completing cycle of a HIGH-half RAM access, read or
  // write, and only when the register asks for it. The `a1` term is not
  // optional — MAME increments inside `if (offset)` in both handlers, so a
  // low-half access must leave the address alone. Dropping it here made every
  // access advance the pointer and the directed test caught it immediately.
  wire ram_step = (st == S_V60_RAM) && a1 && adr[15];

  always_comb begin
    ram_addr = adr[AW-1:0];
    ram_din  = {wdata, lat_lo};   // MAME: latch[0] | (latch[1] << 16)
    ram_we   = 1'b0;

    case (st)
      S_IDLE: begin
        // Present next cycle's address a cycle early so the two-cycle access
        // has its data ready when it completes.
        if (v60_ram)      ram_addr = adr[AW-1:0];
        else if (tgp_req) ram_addr = tgp_addr[AW-1:0];
      end
      S_V60_RAM: begin
        ram_we = we && a1;        // commit on the high half only
      end
      S_TGP: begin
        ram_addr = tgp_addr[AW-1:0];
        ram_din  = tgp_wdata;
        ram_we   = tgp_we;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE;
      adr <= '0; lat_lo <= '0; pop_r <= '0;
      fin_wr <= '0; fin_rd <= '0; fout_wr <= '0; fout_rd <= '0;
      q <= 16'hffff; ack <= 1'b0; served <= 1'b0;
      tgp_rdata <= '0; tgp_ack <= 1'b0;
      dbg_ram_writes <= '0; dbg_fifo_pushes <= '0;
      dbg_fifo_returns <= '0; dbg_fifo_pops <= '0; dbg_fifo_drains <= '0;
    end else begin
      ack     <= 1'b0;
      tgp_ack <= 1'b0;
      if (!req) served <= 1'b0;

      // The TGP's FIFO ends are independent of the RAM arbiter.
      if (fifo_out_push && !fout_full) begin
        fout[fout_wr[FW-1:0]] <= fifo_out_data;
        fout_wr <= fout_wr + 1'd1;
        if (dbg_fifo_returns != 16'hffff)
          dbg_fifo_returns <= dbg_fifo_returns + 16'd1;
      end
      if (fifo_in_pop && !fin_empty) begin
        fin_rd <= fin_rd + 1'd1;
        if (dbg_fifo_drains != 16'hffff)
          dbg_fifo_drains <= dbg_fifo_drains + 16'd1;
      end

      case (st)
        S_IDLE: begin
          if (v60_ram) begin
            st <= S_V60_RAM;               // address presented this cycle
          end else if (v60_acc && !(we && sel_fifo && a1 && fin_full)) begin
            // Register or FIFO: no RAM, so complete now — EXCEPT a push into a
            // full FIFO, which must not be acknowledged. The board halts the
            // V60 there; withholding the acknowledge is the bus equivalent, and
            // the access simply retries when the TGP drains.
            //
            // If the coprocessor never drains, the V60 hangs. That is the
            // correct failure: MAME hangs it too, and a hung CPU with a stuck
            // counter is diagnosable, whereas silently dropping the word gives
            // a wrong picture and no counter moves at all.
            if (we && sel_adr) begin
              if (be[0]) adr[7:0]  <= wdata[7:0];
              if (be[1]) adr[15:8] <= wdata[15:8];
            end
            if (we && sel_fifo && !a1) lat_lo <= wdata;
            if (we && sel_fifo && a1 && !fin_full) begin
              fin[fin_wr[FW-1:0]] <= {wdata, lat_lo};
              fin_wr <= fin_wr + 1'd1;
              if (dbg_fifo_pushes != 16'hffff)
                dbg_fifo_pushes <= dbg_fifo_pushes + 16'd1;
            end
            if (!we && sel_fifo && !a1) begin
              pop_r <= fout_head;
              if (!fout_empty) begin
                fout_rd <= fout_rd + 1'd1;
                if (dbg_fifo_pops != 16'hffff)
                  dbg_fifo_pops <= dbg_fifo_pops + 16'd1;
              end
            end
            q <= sel_adr  ? adr
               : sel_fifo ? (a1 ? pop_r[31:16] : fout_head[15:0])
               :            16'hffff;
            ack    <= 1'b1;
            served <= 1'b1;
          end else if (tgp_req) begin
            st <= S_TGP;
          end
        end

        S_V60_RAM: begin
          // ram_q holds ram[adr] now, and ram_we has committed a write if this
          // was the high half of one.
          if (!we) q <= a1 ? ram_q[31:16] : ram_q[15:0];
          if (we && !a1) begin
            if (be[0]) lat_lo[7:0]  <= wdata[7:0];
            if (be[1]) lat_lo[15:8] <= wdata[15:8];
          end
          if (we && a1 && dbg_ram_writes != 16'hffff)
            dbg_ram_writes <= dbg_ram_writes + 16'd1;
          if (ram_step) adr <= adr + 16'd1;
          ack    <= 1'b1;
          served <= 1'b1;
          st     <= S_IDLE;
        end

        S_TGP: begin
          tgp_rdata <= ram_q;
          tgp_ack   <= 1'b1;
          st        <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
