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
// V60 data cache: 16 KB, 4-word lines, direct-mapped, write-through,
// no-write-allocate.
//
// WHY, MEASURED (docs/findings.md 2026-09-01)
//
// The V60's SDRAM accesses cost 33 clk_sys against 7.80 for on-chip block RAM -
// 4.3x - and they are 72% of its data traffic, about a quarter of every CPU
// cycle. That is the single largest remaining cost on this core now that the FP
// group has been shown to be un-removable.
//
// The gap is not the DRAM. It is that the CPU port crosses a clock domain
// (m1_cdc_port, clk_cpu <-> clk_sys) and then arbitrates against six other
// masters. So this cache sits on the CPU SIDE of the crossing: a hit never
// crosses clocks and never arbitrates, and costs what on-chip memory costs.
//
// GEOMETRY CHOSEN BY MEASUREMENT, NOT BY ROUNDING
//
// `tools/cache_sweep.py` replays 1,695,059 real SDRAM accesses captured from
// tb_m1_frame through every geometry. What it found:
//
//   * LINE LENGTH is the whole story. 4-word lines hit 92.3%, 16-word 98.1%.
//   * SIZE barely matters above 16 KB: 16 KB and 64 KB both hit 92.3% at four
//     words. The working set is small.
//   * ASSOCIATIVITY buys 0.1%. Direct-mapped it is, which is one comparator -
//     and ALM is the binding constraint on this device, not M10K.
//   * NO-WRITE-ALLOCATE is equal or better than write-allocate (97.9% vs 97.3%
//     at 8 KB, identical at 16 KB) as well as far simpler. Writes do not
//     allocate.
//
// FOUR WORDS AND NOT SIXTEEN, on purpose. 16-word lines hit 98.1% against
// 92.3%, but the hit COST dominates the average: at a 7.8-cycle hit and a
// 33-cycle miss the two geometries come out at 9.9 and 9.2 cycles. Six percent,
// for a fill state machine and four times the burst length on a controller
// whose tile fetcher is already missing deadlines. A 4-word line is ONE
// transaction on a port that returns 64 bits anyway, so there is no fill
// sequencer here at all.
//
// COHERENCY IS FREE HERE, AND THAT IS WHY IT IS CHEAP
//
// Nothing else writes what the CPU reads. Of the seven SDRAM masters the other
// six are read-only except the ROM loader, and the loader runs while the CPU is
// held in reset. So there is no snooping, no invalidation traffic, and no
// coherency state: write-through keeps SDRAM authoritative, and `flush` clears
// the array when a load happens.
//
// A WRITE HIT UPDATES THE LINE rather than invalidating it. Invalidating is one
// gate cheaper and would cost hit rate on work RAM, which takes 13% writes; the
// data array carries byte enables so the update is a lane write, not a
// read-modify-write.

`timescale 1ns/1ps

module m1_dcache #(
  // 2048 lines x 4 words x 16 bits = 16 KB. Both must be powers of two.
  parameter int unsigned LINES = 2048,
  parameter int unsigned AW    = 24
) (
  input  logic            clk,
  input  logic            rst_n,
  // Held high while the ROM loader owns SDRAM; clears the array. Level, not a
  // pulse: the array takes LINES cycles to walk and the loader is much longer.
  input  logic            flush,

  // ------------------------------------------------ CPU side (m1_main's port)
  // Exactly the shape m1_main already drives: one transaction per c_req RISING
  // edge, c_ack a one-cycle pulse with data valid on it. That is m1_cdc_port's
  // contract, which this module is spliced in front of, so m1_main is unchanged.
  input  logic            c_req,
  input  logic            c_we,
  input  logic [AW:1]     c_addr,
  input  logic [15:0]     c_din,
  input  logic [1:0]      c_be,
  output logic [15:0]     c_dout,
  output logic            c_ack,

  // ------------------------------------------------- memory side (to the CDC)
  // m_dout is 64 bits: port 0 now bursts four words like p1/p2/p3/p5, and a
  // 4-word line is exactly one burst. m_addr is burst-aligned on a fill.
  output logic            m_req,
  output logic            m_we,
  output logic [AW:1]     m_addr,
  output logic [15:0]     m_din,
  output logic [1:0]      m_be,
  input  logic [63:0]     m_dout,
  input  logic            m_ack,

  // Telemetry. Hits and misses are what say whether the sweep's 92.3% survived
  // contact with the real access stream; a cache that silently never hits looks
  // exactly like one that is working.
  output logic [31:0]     dbg_hits,
  output logic [31:0]     dbg_misses,
  output logic [31:0]     dbg_writes,
  // Requests arriving while this module could not accept them. Must be zero.
  // A dropped request stops the CPU dead with no other indication, so it is
  // counted rather than assumed impossible.
  output logic [31:0]     dbg_dropped
);

  localparam int unsigned IDX_W = $clog2(LINES);
  localparam int unsigned TAG_W = AW - IDX_W - 2;   // -2: word offset in a line

  // c_addr is [AW:1], a WORD address, so bit 1 is the low bit.
  //   [2:1]              which word of the line
  //   [IDX_W+2 : 3]      line index
  //   [AW : IDX_W+3]     tag
  wire [1:0]         a_off = c_addr[2:1];
  wire [IDX_W-1:0]   a_idx = c_addr[IDX_W+2:3];
  wire [TAG_W-1:0]   a_tag = c_addr[AW:IDX_W+3];

  // Latched copy of the request: c_req is a single-cycle pulse.
  logic [1:0]        r_off;
  logic [IDX_W-1:0]  r_idx;
  logic [TAG_W-1:0]  r_tag;
  logic              r_we;
  logic [15:0]       r_din;
  logic [1:0]        r_be;

  // A REQUEST THAT CANNOT BE SERVED THIS CYCLE IS HELD, NOT DROPPED.
  //
  // Narrowing the window is not a fix. m1_main issues c_req as a ONE-CYCLE
  // pulse and then waits for an ack indefinitely, so any cycle in which this
  // module is not in C_IDLE is a cycle where a request vanishes and the CPU
  // stops forever - and the window that mattered was the handover out of the
  // init walk, which lands exactly where the V60 leaves reset. m1_main issues
  // at most one outstanding transaction, so one slot is enough.
  logic              pend;
  logic [1:0]        p_off;
  logic [IDX_W-1:0]  p_idx;
  logic [TAG_W-1:0]  p_tag;
  logic              p_we;
  logic [15:0]       p_din;
  logic [1:0]        p_be;

  // The live request wins over the held one: they cannot both be new, because
  // m1_main will not issue again until the held one is acknowledged.
  wire [IDX_W-1:0] sel_idx = c_req ? a_idx : p_idx;

  // ---------------------------------------------------------------- the arrays
  // Tag: {valid, tag}. Data: one 64-bit line per entry with byte enables, so a
  // fill is a single full-width write and a write hit is a lane write.
  (* ramstyle = "M10K" *) logic [TAG_W:0]  tag_mem  [LINES];
  (* ramstyle = "M10K" *) logic [7:0]      data_mem [LINES][8];

  logic [TAG_W:0] tag_q;
  logic [63:0]    data_q;

  logic              tag_we;
  logic [TAG_W:0]    tag_wd;
  logic [IDX_W-1:0]  mem_addr;
  logic              data_we;
  logic [7:0]        data_be;
  logic [63:0]       data_wd;

  integer bi;
  always_ff @(posedge clk) begin
    if (tag_we) tag_mem[mem_addr] <= tag_wd;
    tag_q <= tag_mem[mem_addr];
    for (bi = 0; bi < 8; bi = bi + 1) begin
      if (data_we && data_be[bi]) data_mem[mem_addr][bi] <= data_wd[bi*8 +: 8];
      data_q[bi*8 +: 8] <= data_mem[mem_addr][bi];
    end
  end

`ifdef VERILATOR
  // The device powers up cleared and the flush walk clears it again before the
  // CPU runs, so this is for the simulator's benefit only. NOT
  // `synthesis translate_off`: Verilator honours that too and would skip it.
  integer zi, zj;
  initial for (zi = 0; zi < int'(LINES); zi = zi + 1) begin
    tag_mem[zi] = '0;
    for (zj = 0; zj < 8; zj = zj + 1) data_mem[zi][zj] = 8'd0;
  end
`endif

  // ------------------------------------------------------------------ the FSM
  typedef enum logic [2:0] { C_INIT, C_IDLE, C_LOOK, C_FILL, C_WRITE } cst_t;
  cst_t cst;

  logic [IDX_W-1:0] init_idx;
  // THE WALK MUST BE FINISHED BEFORE THE CPU'S FIRST ACCESS, NOT MERELY
  // STARTED. `flush` falls when the ROM has arrived - which is the same edge
  // that releases the V60 from reset. Exiting the walk on `&init_idx && !flush`
  // means up to LINES cycles of still-initialising AFTER the CPU is running,
  // and a request arriving in that window was dropped: m1_main sat in B_SDRAM
  // waiting for an ack that could never come, 7 instructions retired, and it
  // presented as a dead CPU rather than as a handshake fault. That is the third
  // time this project has produced that exact symptom.
  //
  // flush is held for the whole ROM load, which is millions of cycles, so the
  // walk completes long before it falls: latch that and leave immediately.
  logic init_done;
  wire  hit = tag_q[TAG_W] && (tag_q[TAG_W-1:0] == r_tag);

  // The line word the CPU asked for, selected out of the 64-bit entry.
  wire [15:0] line_word = data_q[{r_off, 4'b0000} +: 16];
  wire [15:0] fill_word = m_dout[{r_off, 4'b0000} +: 16];

  always_comb begin
    // Default: address the array with the incoming request so a lookup starts
    // in the same cycle c_req arrives.
    mem_addr = (cst == C_INIT) ? init_idx : (cst == C_IDLE ? sel_idx : r_idx);
    tag_we   = 1'b0;
    tag_wd   = '0;
    data_we  = 1'b0;
    data_be  = 8'h00;
    data_wd  = '0;

    if (cst == C_INIT) begin
      tag_we = 1'b1;                     // valid = 0 across the array
    end else if (cst == C_FILL && m_ack) begin
      tag_we  = 1'b1;
      tag_wd  = {1'b1, r_tag};
      data_we = 1'b1;
      data_be = 8'hFF;
      data_wd = m_dout;
    end else if (cst == C_LOOK && r_we && hit) begin
      // Write hit: update the addressed lane only. SDRAM is written anyway.
      data_we = 1'b1;
      data_be = {6'b0, r_be} << {r_off, 1'b0};
      data_wd = {4{r_din}};
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cst <= C_INIT; init_idx <= '0; init_done <= 1'b0;
      m_req <= 1'b0; c_ack <= 1'b0; c_dout <= '0;
      r_off <= '0; r_idx <= '0; r_tag <= '0; r_we <= 1'b0; r_din <= '0; r_be <= '0;
      dbg_hits <= '0; dbg_misses <= '0; dbg_writes <= '0; dbg_dropped <= '0;
      pend <= 1'b0; p_off <= '0; p_idx <= '0; p_tag <= '0;
      p_we <= 1'b0; p_din <= '0; p_be <= '0;
    end else begin
      // Hold anything that arrives while busy. dbg_dropped counts only the
      // genuinely impossible case - a second request while one is already held.
      if (c_req && cst != C_IDLE) begin
        if (pend) dbg_dropped <= dbg_dropped + 1'b1;
        pend  <= 1'b1;
        p_off <= a_off; p_idx <= a_idx; p_tag <= a_tag;
        p_we  <= c_we;  p_din <= c_din; p_be  <= c_be;
      end
      c_ack <= 1'b0;      // one-cycle pulse
      m_req <= 1'b0;      // one transaction per rising edge

      case (cst)
        // Walk the array clearing valid. Re-entered whenever flush is high, so
        // a mid-run ROM load cannot leave a stale line behind.
        C_INIT: begin
          init_idx <= init_idx + 1'b1;
          if (&init_idx)  init_done <= 1'b1;
          if (init_done && !flush) cst <= C_IDLE;
        end

        C_IDLE: if (flush) begin
          cst <= C_INIT; init_idx <= '0; init_done <= 1'b0;
        end else if (c_req || pend) begin
          r_off <= c_req ? a_off : p_off;
          r_idx <= c_req ? a_idx : p_idx;
          r_tag <= c_req ? a_tag : p_tag;
          r_we  <= c_req ? c_we  : p_we;
          r_din <= c_req ? c_din : p_din;
          r_be  <= c_req ? c_be  : p_be;
          pend  <= 1'b0;
          cst   <= C_LOOK;
        end

        C_LOOK: begin
          if (r_we) begin
            // Write-through, always. no-write-allocate: a miss does not fill.
            // POSTED. The CPU is acknowledged NOW, not when SDRAM has taken
            // the data: nothing it does next depends on the write having
            // landed, and a write costs ~33 clk_sys it would otherwise stall
            // for. Writes are 21% of the V60's SDRAM traffic and the cache
            // does nothing for them otherwise - write-through by construction.
            //
            // ONE outstanding, and the ordering falls out of the `pend` slot
            // that is already here: a following access is held until m_ack, so
            // no read can overtake a write in flight and no write-miss can be
            // read back from SDRAM before it has arrived. Depth one is enough
            // because the V60 issues an access about every 27 CPU cycles and a
            // write completes in about 10.
            dbg_writes <= dbg_writes + 1'b1;
            m_req <= 1'b1; m_we <= 1'b1;
            m_addr <= {r_tag, r_idx, r_off};
            m_din  <= r_din; m_be <= r_be;
            c_ack  <= 1'b1;
            cst    <= C_WRITE;
          end else if (hit) begin
            dbg_hits <= dbg_hits + 1'b1;
            c_dout <= line_word;
            c_ack  <= 1'b1;
            cst    <= C_IDLE;
          end else begin
            dbg_misses <= dbg_misses + 1'b1;
            // BURST-ALIGNED. The port bursts four now, and an unaligned address
            // on a bursting port reads the wrong four words - the failure mode
            // m1_fetch_bridge documents, where the CPU executes whatever came
            // back and it looks like a dead core.
            m_req <= 1'b1; m_we <= 1'b0;
            m_addr <= {r_tag, r_idx, 2'b00};
            m_be   <= 2'b11;
            cst    <= C_FILL;
          end
        end

        C_FILL: if (m_ack) begin
          c_dout <= fill_word;
          c_ack  <= 1'b1;
          cst    <= C_IDLE;
        end

        // The CPU was acknowledged when the write was posted; this only waits
        // for the memory side so the next access cannot overtake it.
        C_WRITE: if (m_ack) cst <= C_IDLE;

        default: cst <= C_IDLE;
      endcase
    end
  end

endmodule
