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
  // See the io_rdata mux: forces unimplemented math-unit reads to 0 rather than
  // table-base data. An experiment switch, not a feature.
  parameter bit MATH_ZERO = 1'b0,
  // AS_PROGRAM is 0x000-0x7ff. The microcode is exactly this size, so a smaller
  // parameter would silently alias rather than fail.
  parameter int unsigned PROG_WORDS = 2048,
  // AN EMPTY COMMAND FIFO READS AS ZERO -- CORRECT, AND OFF BY DEFAULT.
  //
  // gen_fifo.h: "the pop itself will then return zero", and the microcode needs
  // that zero. 0052 `brul alw d` jumps to d = get_exp(b) + 0x53, so an empty
  // FIFO gives 0x53 - the idle handler, which loops back to 0x9b and polls
  // again. Stalling instead makes b = 0 unreachable and parks the core at 004C
  // forever. All of that is measured and stands; see docs/findings.md.
  //
  // BUT TURNING IT ON DEADLOCKS THE MACHINE, on the board and in simulation.
  // Unparking the coprocessor means it starts PRODUCING results, and our V60
  // never drains them: `fout` fills at ~400 M cycles, the TGP then stops taking
  // commands, `fin` fills, and both halt permanently around frame 340. On
  // hardware that is sky and sea with no glyphs and nothing moving - WORSE than
  // the parked behaviour, which at least left the V60 running and drawing text.
  //
  // The interlocks are right and must not be relaxed. What is wrong is the
  // V60's 1.63x speed deficit, which keeps it off the code that reads results.
  // FLIP THIS TO 1 WHEN THAT IS FIXED - it is the correct behaviour, and the
  // deadlock cannot arm once the V60 keeps up.
  parameter bit EMPTY_FIFO_READS_ZERO = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  // Read-back of the program RAM: see the sweep below.
  output logic [23:0] dbg_ucode_ram_csum,
  output logic        dbg_ucode_ram_ok,

  // ---------------------------------------------------------- microcode ROM
  // Written before the core is released from reset. On hardware this arrives
  // over the MRA path like every other ROM; hard rule 2 keeps it out of the
  // repository either way.
  //
  // ON ITS OWN CLOCK. The ROM loader lives in the fast memory domain and the
  // coprocessor in the CPU domain, so this is a dual-clock memory: one write
  // port, one read port, different clocks. That is the one memory shape Quartus
  // infers without argument (measured in docs/mister-integration.md: 32768x8
  // dual clock gives 32 M10K and 37 ALM), and it needs no handshake because the
  // write side is finished before the core leaves reset.
  input  logic        ucode_clk,
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
  output logic        dbg_unimplemented,

  // What it is waiting on, if it has stopped. A retire count that freezes says
  // only "stopped"; these say WHERE. io_rd or io_wr held with no ack is an
  // unanswered IO access, and the address names which one — a decode gap looks
  // identical to a dead coprocessor without this.
  output logic [15:0] dbg_io_addr,
  output logic        dbg_io_rd,
  output logic        dbg_io_wr,
  output logic        dbg_io_ack,
  output logic        dbg_fifo_rd,
  output logic        dbg_fifo_wr
);

  // ------------------------------------------------------------ microcode ROM
  // 2048 x 32 is 8 M10K. One write port for the loader, one read for the core.
  (* ramstyle = "M10K" *) logic [31:0] prog [PROG_WORDS];

  logic [15:0] prog_addr;
  logic [31:0] prog_rdata;

  always_ff @(posedge ucode_clk) begin
    if (ucode_we) prog[ucode_addr] <= ucode_data;
  end
  // ------------------------------------------- program-RAM read-back checksum
  //
  // WHAT ROW 02 DOES NOT PROVE. The loader's ucode_csum is folded at the IOCTL
  // INPUT, before the write, so `800B9A` says the HPS delivered 2048 correct
  // words and nothing about what reached this array. That is exactly the gap
  // rows 07/0B had for SDRAM, which was only closed by reading the memory back -
  // and the board is sitting at pc 0x7E6 with 53 retires, which is where a
  // coprocessor executing an EMPTY program RAM ends up.
  //
  // Swept while the core is still in reset, through the existing read port, so
  // no third port is needed. 2048 cycles, and the core is released when it
  // finishes - invisible next to a ROM download.
  // THE RELEASE DELAY IS DELIBERATE, NOT A SIDE EFFECT OF THE SWEEP.
  //
  // Measured on hardware 2026-08-23: without it the coprocessor parked at
  // microcode 0x7E6 with 53 retires and made no SDRAM reads at all - the
  // empty-program-RAM signature - and the V60 then filled the command FIFO and
  // halted behind it. Adding the sweep, whose only other effect is to hold the
  // core in reset for 2048 cycles, made it run. So there is a race at release,
  // and the delay is what wins it.
  //
  // The sweep proves the RAM is intact (row 0C reads A07D51, matching the ROM
  // image exactly), so the race is not the microcode still arriving - it is
  // something at the moment of release that this has not identified yet. Until
  // it is identified the delay stays, EXPLICITLY, so that removing the debug
  // instrument cannot silently bring the hang back.
  localparam int RELEASE_DELAY = 2048;

  logic [11:0] sw_addr;
  logic        sw_busy, sw_done;
  logic [23:0] sw_csum;
  logic [11:0] rel_cnt;
  logic        rel_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rel_cnt <= 12'd0; rel_done <= 1'b0;
    end else if (!rel_done) begin
      rel_cnt <= rel_cnt + 12'd1;
      if (rel_cnt == 12'(RELEASE_DELAY - 1)) rel_done <= 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sw_addr <= 12'd0; sw_busy <= 1'b1; sw_done <= 1'b0; sw_csum <= 24'd0;
    end else if (sw_busy) begin
      sw_addr <= sw_addr + 12'd1;
      // One cycle of read latency: fold the word for the PREVIOUS address.
      if (sw_addr != 12'd0)
        sw_csum <= {sw_csum[22:0], sw_csum[23]} ^ prog_rdata[23:0];
      if (sw_addr == 12'(PROG_WORDS)) begin
        sw_busy <= 1'b0;
        sw_done <= 1'b1;
      end
    end
  end

  assign dbg_ucode_ram_csum = sw_csum;
  assign dbg_ucode_ram_ok   = sw_done;

  always_ff @(posedge clk) begin
    prog_rdata <= prog[sw_busy ? sw_addr[10:0] : prog_addr[10:0]];
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
    .clk(clk), .rst_n(rst_n && sw_done && rel_done),
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
  //
  // ONE POP PER ACCESS, NOT ONE PER CYCLE.
  //
  // `fifo_in_pop = fifo_rd && fifo_in_valid` popped on EVERY cycle the request
  // was held, and mb86233_core asserts mem_req in BOTH S_SRC and S_SRC_W — it has
  // to, because a RAM read is registered and the address must stay put. A RAM read
  // does not care: reading twice returns the same word. A FIFO read does. Every
  // `mov (x1), b` therefore consumed TWO command words.
  //
  // Measured: the microcode at 0x00a5/0x00a6 is two consecutive FIFO reads, and
  // both of the last two words were popped at pc 0x00a5 — the reference pops one at
  // 0x00a5 and one at 0x00a6, then multiplies at 0x00a7 and writes its result. Ours
  // ate the command and waited forever for a word the V60 had already sent.
  //
  // `popped` clears when the request drops, so it is one pop per access however
  // long the access is held, and it fires on the first cycle the data is actually
  // there — an access that arrives at an empty FIFO still pops when the V60 fills
  // it. The word is latched because the head moves on as soon as it is taken.
  logic        popped;
  logic [31:0] pop_data;
  logic        pushed;

  assign fifo_in_pop   = fifo_rd && fifo_in_valid && !popped;
  // AND THE SAME ON THE WRITE SIDE. mem_req is asserted in both S_DST and S_DST_W
  // for the same reason, so every `mov p, (bx1)` pushed its result into the
  // outbound FIFO TWICE — visible the moment the first correct result appeared,
  // as `COPRO RESULT: 42520000` printed twice for one multiply. The V60 would then
  // read a duplicate for its next result and go wrong a command later.
  assign fifo_out_push = fifo_wr && !fifo_out_full && !pushed;
  assign fifo_out_data = fifo_wdata;
  assign fifo_rdata    = popped ? pop_data
                       : (fifo_in_valid || EMPTY_FIFO_READS_ZERO) ? fifo_in_data : 32'd0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sincos_base <= 32'd0; inv_base <= 32'd0; isqrt_base <= 32'd0;
      atan_base[0] <= 32'd0; atan_base[1] <= 32'd0;
      atan_base[2] <= 32'd0; atan_base[3] <= 32'd0;
    end else if (io_wr && sel_math) begin
      unique case (math_unit)
        2'd0: sincos_base            <= io_wdata;
        2'd1: atan_base[io_addr[1:0]] <= io_wdata;
        2'd2: inv_base               <= io_wdata;
        2'd3: isqrt_base             <= io_wdata;
      endcase
    end
    if (!rst_n) begin
      popped   <= 1'b0;
      pop_data <= 32'd0;
    end else if (!fifo_rd) begin
      popped   <= 1'b0;
    end else if (fifo_rd && !popped && (EMPTY_FIFO_READS_ZERO || fifo_in_valid)) begin
      // Latched on the first cycle of the access whether or not the FIFO had
      // anything, so one access yields one value. Without this an access held
      // across S_SRC and S_SRC_W could read 0 on one cycle and a word the V60
      // pushed in between on the next.
      popped   <= 1'b1;
      pop_data <= fifo_in_valid ? fifo_in_data : 32'd0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)               pushed <= 1'b0;
    else if (!fifo_wr)        pushed <= 1'b0;
    else if (fifo_out_push)   pushed <= 1'b1;
  end

  // A READ OF AN EMPTY INBOUND FIFO RETURNS ZERO AND COMPLETES. It must not
  // block, and the comment that used to stand here - "MAME's generic_fifo blocks
  // the same way" - was wrong about the one thing it was cited for.
  // gen_fifo.h, on_fifo_empty_pre_sync: "Called on a pop with an empty fifo.
  // Must ask the destination to try again. THE POP ITSELF WILL THEN RETURN ZERO."
  //
  // THE MICROCODE DEPENDS ON THAT ZERO. 004D-0052 is a dispatch:
  //
  //     004D  mov (x1), b        x1 = 0x100, so this POPS a command
  //     ...
  //     0052  brul alw d         d = get_exp(b) + 0x53 - a COMPUTED JUMP
  //
  // get_exp is `(val >> 23) & 0xff`, so an empty FIFO gives b = 0, d = 0x53, and
  // 0x53 is the IDLE handler, which loops back to 0x9b and polls again. The
  // command type is carried in the exponent field and selects a handler above it.
  //
  // Blocking here means the microcode can NEVER see b = 0 and can never reach its
  // idle path, so it parks at 004C forever the first time it polls an empty FIFO.
  // That is precisely the recorded symptom - pc=004c, 342 retires, and about
  // fourteen io accesses per run where the reference makes 158,391 in 400 frames.
  // tgp_trace agreed for 75,175 instructions and then split exactly here: the
  // reference took 0052 -> 0053 -> 009b and kept polling, we took 0052 -> 0064.
  //
  // Measured, same 16s window: 61 pushes against a pop capture that filled its
  // 300-entry cap. Nearly every pop the reference makes is an empty one.
  //
  // The OUTBOUND fifo keeps its stall. That direction is the V60 reading results,
  // where acknowledging an empty read returned a stale word and hung the CPU at
  // fed5a4; MAME halts the maincpu there rather than letting it proceed.
  assign fifo_ack = fifo_rd ? (EMPTY_FIFO_READS_ZERO || fifo_in_valid || popped)
                  : fifo_wr ? (!fifo_out_full || pushed)
                  : 1'b0;

  // ------------------------------------------------------------- IO space
  //   0x0000-0x001f   copro RAM: addr at [2:0]==0, data at [2:0]==1,
  //                   register index in [4:3]
  //   0x0020-0x0023   sincos     0x0024-0x0027  atan
  //   0x0028-0x0029   inv        0x002a-0x002b  isqrt
  //   0x002e          copro_data window base
  //   0x8000-0xffff   copro_data read, low 15 bits from the address
  logic [31:0] copro_adr [4];         // the TGP's four registers

  // Power-on zero, same reasoning as mb86233_regs' rf and m1_copro_if's ram: four
  // flops on the device, ones in Verilator, and the TGP reads one of these to
  // address coprocessor RAM before necessarily writing it.
  integer za;
  initial for (za = 0; za < 4; za = za + 1) copro_adr[za] = 32'd0;
  logic [31:0] dat_base;

  wire        io_lo    = (io_addr[15:5] == 11'd0);
  wire        sel_radr = io_lo && (io_addr[2:0] == 3'd0);
  wire        sel_rdat = io_lo && (io_addr[2:0] == 3'd1);
  wire [1:0]  radr_i   = io_addr[4:3];

  wire        io_mid   = (io_addr[15:5] == 11'd1);   // 0x20-0x3f
  wire        sel_math = io_mid && (io_addr[4:0] <= 5'h0b);
  wire        sel_datb = io_mid && (io_addr[4:0] == 5'h0e);
  wire        sel_datw = io_addr[15];               // 0x8000-0xffff

  // ---------------------------------------------------- the math units
  //
  // sincos, atan, inv and isqrt, read off model1_m.cpp's copro_sincos_r,
  // copro_atan_r, copro_inv_r and copro_isqrt_r. Each is a table lookup in one
  // 16K-word quadrant plus a fixup; the quadrant is the top two bits of the
  // table index, which is why {unit, index} is the whole address.
  //
  // These used to return the quadrant BASE word, unindexed and unfixed, and
  // this file's own comment predicted exactly what that caused: "the TGP
  // computes with a wrong operand and writes a wrong result into coprocessor
  // RAM - and the V60 then waits at FED5A4 for that word's low byte to read
  // zero, forever." It does, 6,221,912 times in a fifteen-second run.
  //
  // Each unit latches an operand on a WRITE and computes on a READ. The bases
  // are separate registers, not one shared register: the units are independent
  // hardware and the microcode interleaves them.
  wire [1:0] math_unit = (io_addr[4:0] <= 5'h03) ? 2'd0    // sincos 0x20-0x23
                       : (io_addr[4:0] <= 5'h07) ? 2'd1    // atan   0x24-0x27
                       : (io_addr[4:0] <= 5'h09) ? 2'd2    // inv    0x28-0x29
                       :                           2'd3;   // isqrt  0x2a-0x2b

  logic [31:0] sincos_base, inv_base, isqrt_base;
  logic [31:0] atan_base [4];
  integer zb;
  initial begin
    sincos_base = 32'd0; inv_base = 32'd0; isqrt_base = 32'd0;
    for (zb = 0; zb < 4; zb = zb + 1) atan_base[zb] = 32'd0;
  end

  // sincos: ang = base + offset*0x4000, index = ang & 0x3fff, and the second
  // quadrant mirrors - std::min(0x4000 - index, 0x3fff), so index 0 maps to
  // 0x3fff rather than to 0x4000, which is off the end of the quadrant.
  wire [15:0] sc_ang   = sincos_base[15:0] + {io_addr[1:0], 14'd0};
  wire [13:0] sc_raw   = sc_ang[13:0];
  wire [14:0] sc_mirr  = 15'h4000 - {1'b0, sc_raw};
  wire [13:0] sc_index = !sc_ang[14] ? sc_raw
                       : (sc_mirr > 15'h3fff) ? 14'h3fff : sc_mirr[13:0];

  // inv / isqrt: the index comes from the operand's mantissa, the exponent is
  // rebiased against the operand's, and the sign is patched in afterwards.
  wire [13:0] inv_index   = {inv_base[22:10], 1'b0} | {13'd0, io_addr[0]};
  wire [13:0] isqrt_index = 14'h2000 ^ ({isqrt_base[23:11], 1'b0}
                                        | {13'd0, io_addr[0]});

  wire [13:0] math_index = (math_unit == 2'd0) ? sc_index
                         : (math_unit == 2'd1) ? (|atan_base[3][15:14] ? 14'h3fff
                                                 : atan_base[3][13:0])
                         : (math_unit == 2'd2) ? inv_index
                         :                       isqrt_index;

  assign tbl_req  = (io_rd && sel_math);
  assign tbl_addr = {math_unit, math_index};

  // ---- the fixups, applied to the word the table returned

  wire [7:0] inv_exp = tbl_rdata[30:23] + (8'h7f - inv_base[30:23]);
  wire [31:0] inv_val_raw = {tbl_rdata[31], inv_exp, tbl_rdata[22:0]};
  wire [31:0] inv_val = inv_base[31] ? {~inv_val_raw[31], inv_val_raw[30:0]}
                                     : inv_val_raw;

  wire [7:0] isq_exp = tbl_rdata[30:23] + (8'h3f - {1'b0, isqrt_base[30:24]});
  wire [31:0] isq_raw = {tbl_rdata[31], isq_exp, tbl_rdata[22:0]};
  wire [31:0] isqrt_val = io_addr[0] ? isq_raw : {1'b0, isq_raw[30:0]};

  wire [31:0] sincos_val = sc_ang[15] ? {~tbl_rdata[31], tbl_rdata[30:0]}
                                      : tbl_rdata;

  // atan's table is WRONG IN THE ROM and MAME corrects it on the way out, with
  // the note that "the hardware does something equivalent somehow". Reproduced
  // rather than cleaned up, per the project's rule about hardware quirks: the
  // microcode's results depend on these exact values.
  wire [15:0] at_dt = tbl_rdata[31:16] + tbl_rdata[15:0];
  logic [31:0] at_fix;
  always_comb begin
    at_fix = tbl_rdata;
    if (at_dt[0])
      at_fix = (at_fix[3:0] == 4'he) ? at_fix - 32'h00000001
                                     : at_fix - 32'h00010000;
    if (at_dt[4])
      at_fix = (at_fix[7:4] == 4'he) ? at_fix - 32'h00000010
                                     : at_fix - 32'h00100000;
    if (at_dt[8])
      at_fix = (at_fix[11:8] == 4'he) ? at_fix - 32'h00000100
                                      : at_fix - 32'h01000000;
  end

  wire at_s0 = atan_base[0][31];
  wire at_s1 = atan_base[1][31];
  wire at_s2 = atan_base[2][31];
  wire [31:0] at_shifted = (at_s0 ^ at_s1 ^ at_s2) ? {16'd0, at_fix[31:16]}
                                                   : at_fix;
  wire [31:0] at_signed  = at_shifted
                         + (at_s2 ? 32'h4000 : 32'd0)
                         + (((at_s0 && !at_s2) || (at_s1 && at_s2)) ? 32'h8000
                                                                    : 32'd0);
  wire [31:0] atan_val = {16'd0, at_signed[15:0]};

  wire [31:0] math_val = (math_unit == 2'd0) ? sincos_val
                       : (math_unit == 2'd1) ? atan_val
                       : (math_unit == 2'd2) ? inv_val
                       :                       isqrt_val;
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
    // MATH_ZERO forces every math unit to answer zero. It was the switch that
    // established the units were the blocker while they were unimplemented; it
    // is kept only so that experiment can be repeated, and the default path is
    // now the real function.
    else if (sel_math) io_rdata = MATH_ZERO ? 32'd0 : math_val;
    else if (sel_datw) io_rdata = dat_rdata;
  end

  // Register reads and writes finish immediately; anything behind memory waits.
  assign io_ack = sel_radr ? (io_rd || io_wr)
                : sel_rdat ? ram_ack
                : sel_math ? (io_wr || tbl_ack)
                : sel_datb ? io_wr
                : sel_datw ? dat_ack
                : (io_rd || io_wr);   // AS_RF LEDs and anything unmapped

  assign dbg_io_addr = io_addr;
  assign dbg_io_rd   = io_rd;
  assign dbg_io_wr   = io_wr;
  assign dbg_io_ack  = io_ack;
  assign dbg_fifo_rd = fifo_rd;
  assign dbg_fifo_wr = fifo_wr;

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
        // WRAPS, DELIBERATELY, rather than saturating.
        //
        // A saturated counter cannot answer the only question worth asking of
        // it on a running board — is this thing still executing? It read FFFF
        // for two sessions while the coprocessor's state was in doubt, and
        // could not distinguish "retired 65,535 instructions and stopped" from
        // "still going". A wrapping counter visibly churns when it is alive and
        // sits still when it is not.
        dbg_retires <= dbg_retires + 16'd1;
      end
    end
  end

endmodule
