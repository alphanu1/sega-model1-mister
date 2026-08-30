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
  // AN EMPTY RESULT-FIFO READ RETURNS ZERO AND COMPLETES.
  //
  // MAME's gen_fifo returns zero from a pop on an empty fifo - the same rule
  // that the TGP's inbound side needed - and the V60 POLLS this port: the
  // reference reads 0xd80000 about 1,185 times a FRAME, 710,722 over 600 frames,
  // spinning on in.w / test.b / bne. Every one of those reads completes.
  //
  // Withholding the acknowledge instead blocks the V60 on its FIRST poll, so it
  // makes ONE read where the reference makes 1,185. Measured with the
  // coprocessor enabled: 259 reads in ~340 frames, 0.76 per frame, a factor of
  // ~1,500 - which no 1.63x speed deficit can explain, and which is why the
  // outbound FIFO fills and the two processors deadlock.
  //
  // The stall was introduced to replace returning STALE data, which really did
  // hang the CPU at fed5a4. Zero is the third option and the one MAME uses.
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
  // Instruments for the FED5A4 deadlock - see the note beside ram_we below.
  output logic [11:0] dbg_tgp_ram_writes,
  output logic [15:0] dbg_sync_word,
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
  // reading RESULTS out of the output FIFO, and its zero was read as "the
  // coprocessor never drains its input". The two are opposite ends of the
  // interface and only one of them was instrumented.
  //
  // THE JUSTIFICATION THAT USED TO SIT HERE WAS WRONG. It said dbg_fifo_pops's
  // zero "is correct behaviour" because findings.md had measured the V60 as never
  // reading the coprocessor back — 0 in 2,500 accesses. That census was of the
  // PROGRAM space; the game uses in.w, so the traffic is in the V60's I/O space,
  // where the reference reads 0xd80000 710,722 times per 600 frames. It agreed
  // with our own faked IN, which returned a constant and made zero accesses, so
  // the wrong conclusion looked confirmed from two directions at once.
  //
  // A ZERO HERE IS A GAP TO CLOSE, NOT A PROPERTY TO PRESERVE. See findings.md,
  // "CORRECTED: the V60 never reads the coprocessor back".
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

  // AN M10K POWERS UP ZEROED, AND SIMULATION MUST AGREE.
  //
  // This array is deliberately not reset — Quartus 17.0 will not infer RAM from an
  // array that is, and building 8192 words out of flip-flops is the failure this
  // project has already paid for twice. On the device that is fine: a Cyclone V M10K
  // comes up cleared. In Verilator it came up as all ones, and that difference cost
  // most of an evening.
  //
  // The V60 waits for this RAM at FED5A4: `mov.h #0, D00000` sets the address to 0,
  // then `in.w [R1], R0` / `test.b R0` / `bne` spins until the low byte reads ZERO —
  // about 32 iterations in the reference. Reading 0xffffffff, our V60 span 1,120,224
  // times and never left, so it never pushed another command and never reached the
  // per-frame 2D work. Every layer between the bus and the array was correct; the
  // array's initial contents were not.
  //
  // NOT GUARDED BY translate_off. The first attempt wrapped this in
  // `// synthesis translate_off` / `translate_on`, which VERILATOR ALSO HONOURS as a
  // pragma — so the initialisation was skipped in simulation, the exact opposite of
  // the intent, and the array still came up as ones. An unguarded `initial` is
  // correct for both tools: Quartus uses it to initialise the inferred M10K, which
  // is what the device does anyway, and Verilator executes it.
  //
  // ZEROED FOR BOTH TOOLS, IN CHUNKS UNDER QUARTUS'S LOOP LIMIT.
  //
  // MAME does this and the game depends on it: model1_m.cpp:59 ends
  // device_reset with memset(m_copro_ram_data.get(), 0, 0x2000*4). The V60 spins
  // at FED5A4 reading word 0 until its LOW BYTE IS ZERO, and NOTHING EVER WRITES
  // THAT WORD - not the coprocessor, not the V60. Measured: tb_m1_frame reports
  // "TGP writes to copro RAM=0". Simulation only works because this initialiser
  // makes word 0 zero to begin with.
  //
  // It was briefly guarded on `VERILATOR`, which removed it from the DEVICE and
  // left the board reading ffff there for ever - and every reading of that as
  // "the coprocessor fails to signal completion" was backwards, because there
  // was never a signal to write.
  //
  // Quartus caps a loop at 5,000 iterations, which is why the guard went on. Two
  // loops of 4,096 are each under the cap and initialise the inferred M10K
  // exactly as one loop of 8,192 would. An `initial` is the idiom Quartus wants;
  // a reset that clears the array would be a second write port and would build
  // the whole thing out of flip-flops.
  localparam int unsigned RAM_HALF = RAM_WORDS / 2;
  initial begin
    for (int unsigned i = 0; i < RAM_HALF; i++)            ram[i] = 32'd0;
    for (int unsigned i = RAM_HALF; i < RAM_WORDS; i++)    ram[i] = 32'd0;
  end
  logic [31:0]   ram_din, ram_q;
  logic          ram_we;

  always_ff @(posedge clk) begin
    if (ram_we) ram[ram_addr] <= ram_din;
    // THE SYNC WORD, AND WHO WRITES IT. The V60 spins at FED5A4 reading word 0
    // until its low byte is zero; on hardware it never is, while simulation
    // clears it thousands of times. The microcode is verified correct on the
    // board (row 02) and SDRAM returns correct data (rows 0C and 0E), so the
    // question left is whether the coprocessor ever writes this word at all.
    // Synchronous, and in THIS block: the counter is incremented here, and a
    // reset in the other always_ff made it multiply driven.
    if (!rst_n) dbg_tgp_ram_writes <= 12'd0;
    else if (ram_we && (st == S_TGP) && dbg_tgp_ram_writes != 12'hfff)
      dbg_tgp_ram_writes <= dbg_tgp_ram_writes + 12'd1;
    dbg_sync_word <= ram[0][15:0];
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
            // Register or FIFO: no RAM, so complete now — EXCEPT the two ends of
            // the interlock, neither of which may be acknowledged.
            //
            // THE FIFOS ARE A MUTUAL HARDWARE INTERLOCK. model1_m.cpp:29-44 wires
            // both of them symmetrically:
            //
            //   copro_fifo_in ->setup(16, TGP stalls on empty, TGP HALTED on
            //                             empty, V60 HALTED on full)
            //   copro_fifo_out->setup(16, V60 stalls on empty, V60 HALTED on
            //                             empty, TGP HALTED on full)
            //
            // Each processor is halted when the FIFO it reads is empty and
            // released when the other side fills it. Withholding the acknowledge
            // is the bus equivalent: the access retries until the data is there.
            //
            // A PUSH INTO A FULL FIFO was already handled. A READ OF AN EMPTY ONE
            // WAS NOT — it acknowledged and returned `fout_head`, which on an
            // empty FIFO is stale. The V60 took that for a result, branched on it
            // and span at `fed5a4` forever while the TGP sat at pc 0x0492 waiting
            // for a command that was never going to come. Confirmed on hardware
            // 2026-08-18: row 10 = 000492, row 00 parked in the poll loop.
            //
            // Only offset 0 stalls. Offset 1 returns the HIGH half of the word
            // offset 0 already latched (`v60_copro_fifo_r`: offset 0 pops and
            // returns the low half, offset 1 returns `m_v60_copro_fifo_r >> 16`
            // without touching the FIFO), so it must always complete.
            //
            // If the coprocessor never produces, the V60 now hangs rather than
            // spinning on stale data. That is the correct failure: MAME hangs it
            // too, and a hung CPU with a stuck counter is diagnosable, whereas
            // reading rubbish gives a wrong picture and no counter moves at all.
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
              pop_r <= fout_empty ? 32'd0 : fout_head;
              if (!fout_empty) begin
                fout_rd <= fout_rd + 1'd1;
                if (dbg_fifo_pops != 16'hffff)
                  dbg_fifo_pops <= dbg_fifo_pops + 16'd1;
              end
            end
            q <= sel_adr  ? adr
               : sel_fifo ? (a1 ? pop_r[31:16]
                                : (fout_empty ? 16'd0 : fout_head[15:0]))
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
