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
// Single-chip 16-bit SDR SDRAM controller with a per-master round-robin
// arbiter, for the port map in docs/00-decisions.md D8.
//
// PROVENANCE
//
// The state machine follows meathax's System 32 controller
// (third_party/s32/rtl/mem/sdram.sv, GPL-3.0, so licence-compatible per D7).
// That is deliberate. It encodes two hazards that were found the hard way and
// are invisible from a datasheet:
//
//   - Requests must be latched on the REQUEST RISING EDGE, not sampled as a
//     level qualified by !pend && !ack. The level-sampled version has a
//     one-cycle drop window: a requester that issues its next request in
//     direct response to an ack presents a pulse whose first cycle is blocked
//     by the still-clearing pend and whose second by the stretched ack. The
//     transaction vanishes and the port hangs forever. Which transactions hit
//     the window depends on arbitration history, so it appears as "adding an
//     unrelated master broke the CPU".
//
//   - Completion must clear pend on the ack RISING EDGE and must do so BEFORE
//     the new-request latch in the same process, so a chained request landing
//     on the very edge that clears pend wins rather than vanishing.
//
// Reimplementing from scratch would have meant rediscovering both.
//
// WHAT IS DIFFERENT HERE
//
//   - Ports are a generic array rather than six copy-pasted blocks. Six
//     near-identical hand-written port blocks is six chances to transpose an
//     index, and the arbiter becomes a loop instead of a priority ladder
//     repeated once per rotation position.
//   - Any port may write. D8 puts V60 work RAM in external memory, so p0
//     needs a write path; s32's read ports are read-only because all of its
//     RAM is internal.
//   - DQ is split into dq_i/dq_o/dq_oe. The tri-state lives at the top level
//     where the physical pin is, which keeps this module and the device model
//     straightforwardly simulatable.
//   - Timing is parameterised, in clock cycles, and the same numbers are
//     handed to sdram_model in simulation. Hardcoded cycle counts silently
//     stop being correct when the clock changes, and nothing catches it.
//   - dbg_req/dbg_grant are brought out for bw_monitor, so telemetry does not
//     have to reach inside the module.
//
// REQUEST CONTRACT
//
// One transaction per request RISING EDGE. The address, write data and byte
// enables are sampled on that edge. A request held high is serviced exactly
// once — a requester expecting re-service per ack from a held level will
// hang. Requesters must be single-outstanding.

`timescale 1ns/1ps

module m1_sdram #(
  parameter int unsigned NP = 7,      // read/write ports, see D8

  // Device timing, in clk cycles. Defaults suit -7E parts around 100 MHz.
  parameter int unsigned T_RCD  = 2,
  parameter int unsigned T_RP   = 2,
  parameter int unsigned T_RC   = 7,
  parameter int unsigned T_RAS  = 5,
  parameter int unsigned T_WR   = 2,
  parameter int unsigned CL     = 2,

  // Refresh cadence. 8192 rows per 64 ms is one per 781 cycles at 100 MHz;
  // the margin below that absorbs a transfer in flight when the timer fires.
  parameter int unsigned T_REFI = 700,

  // Power-up delay. JEDEC wants >100 us of NOP before the first command.
  parameter int unsigned INIT_NOP = 10000,

  // Ack hold. Requesters on a slower synchronous clock must see exactly one
  // rising edge with ack high, so this is 2 for a clk/2 requester.
  parameter int unsigned ACK_HOLD = 2
) (
  input  logic                 clk,
  input  logic                 rst_n,
  output logic                 ready,

  // Read capture depth. **0 IS CL+3, NOT CL+2**, and the ordering is that way
  // round on purpose: an unconnected port reads as zero, and zero has to be the
  // value that matches sdram_model, so forgetting to wire it degrades to
  // "works" rather than to "every burst arrives one word late".
  //
  // It was the other way round for one commit and tb_m1_boot, which does not
  // wire this port and is built with -Wno-PINMISSING, silently got the hardware
  // phase against the simulation model. The V60 halted after a single
  // instruction and the trace read "0 distinct addresses" — a testbench
  // reporting a clean absence of the thing it was measuring.
  //
  //   0 -> CL+3  (sdram_model, and the safe default)
  //   1 -> CL+2  (the board: its device is clocked on the inverse of clk_sys)
  //   2 -> CL+4
  //   3 -> CL+5
  input  logic [1:0]           rd_lat_sel,

  // SDRAM device
  output logic                 sd_cke,
  output logic                 sd_cs_n,
  output logic                 sd_ras_n,
  output logic                 sd_cas_n,
  output logic                 sd_we_n,
  output logic [1:0]           sd_ba,
  output logic [12:0]          sd_a,
  output logic [1:0]           sd_dqm,
  output logic [15:0]          sd_dq_o,
  output logic                 sd_dq_oe,
  input  logic [15:0]          sd_dq_i,

  // ROM download. Highest priority while it is active; game logic is held in
  // reset during download, so starving the other ports costs nothing.
  input  logic                 wr_req,
  input  logic [24:1]          wr_addr,
  input  logic [15:0]          wr_din,
  input  logic [1:0]           wr_be,
  output logic                 wr_ack,

  // Masters. Word-addressed; a burst port's address must be burst-aligned.
  input  logic [NP-1:0]        p_req,
  input  logic [NP-1:0]        p_we,
  input  logic [NP-1:0][24:1]  p_addr,
  input  logic [NP-1:0][15:0]  p_din,
  input  logic [NP-1:0][1:0]   p_be,
  output logic [NP-1:0][63:0]  p_dout,
  output logic [NP-1:0]        p_ack,

  // MEMORY OCCUPANCY AND TILE-PORT WAIT, each as a fraction of a fixed window.
  //
  // Ben reads the tile overruns as the memory controller being the constraint.
  // That is a bandwidth claim, and nothing in this design has ever measured
  // bandwidth ON HARDWARE - bw_monitor exists, but its numbers only reach
  // simulation, and simulation models memory load differently enough that it
  // cannot answer this.
  //
  // Two very different repairs follow from the two possible answers. A
  // saturated controller wants a faster clock or a tighter issue pipeline; an
  // idle one that still misses deadlines wants different arbitration, and the
  // clock would buy nothing. So measure which it is before building either.
  //
  // The window is 2^20 cycles, about 13 ms at 80 MHz, and each output is the
  // top eight bits of a count within it: 0x00 idle, 0xFF saturated. A ratio
  // taken this way needs no division and no knowledge of the clock rate.
  output logic [7:0]           dbg_occ,    // controller not idle
  output logic [7:0]           dbg_wait1,  // port 1, the tile character fetch,
                                           // asking and not yet served

  // Telemetry taps for bw_monitor. `dbg_req` is the latched pending state
  // rather than the raw input, because demand is "asking and not yet served",
  // which a one-cycle request pulse would not show.
  output logic [NP-1:0]        dbg_req,
  output logic [NP-1:0]        dbg_grant
);

  // Burst length per port, in 16-bit words. D8: p1 is tile character fetch and
  // p2 is polygon/TGP data, both of which are consumed in runs, so they burst.
  // The rest are single-word random access.
  //
  // p3 is the coprocessor's read-only regions — copro_data and the math tables.
  // A coprocessor fetch is one 32-bit word, so it needs TWO 16-bit words, and
  // only 1 and 4 are available: the capture below assembles the non-single case
  // from cap[2], cap[1], cap[0], so a length of 2 would take two of those from
  // stale slots. So it bursts 4 and the requester picks its half — see
  // m1_integrated, which aligns the address down and selects on bit 1.
  // p5 is the 3D layer's polygon-model fetch: ten 32-bit words per record, read
  // strictly in sequence, so it bursts for the same reason p1 and p2 do. p6 is
  // its tgp_ram colour-word access - one random word per polygon, and a write
  // path for the display list's uploads - so it stays single.
  function automatic logic [3:0] blen(input int unsigned p);
    case (p)
      // p7 is the tile engine's second character port and bursts exactly as p1
      // does - it fetches the same shaped data, just on the other half of the
      // overlap.
      1, 2, 3, 5, 7: blen = 4'd4;
      default:    blen = 4'd1;
    endcase
  endfunction

  localparam logic [3:0] C_NOP   = 4'b0111;   // {cs,ras,cas,we}
  localparam logic [3:0] C_ACT   = 4'b0011;
  localparam logic [3:0] C_READ  = 4'b0101;
  localparam logic [3:0] C_WRITE = 4'b0100;
  localparam logic [3:0] C_PRE   = 4'b0010;
  localparam logic [3:0] C_REF   = 4'b0001;
  localparam logic [3:0] C_MRS   = 4'b0000;

  // Round trip from the edge that issues a READ to the edge that can read the
  // captured word, counted term by term rather than guessed:
  //
  //   +1  cmd is registered, so the device sees the command one edge later
  //   +CL the device presents data CL edges after it samples the command
  //   +1  dq_i is registered into dq_r, which is what puts the pin-to-register
  //       path in the input IOE instead of in a core timing arc
  //   +1  the capture logic reads dq_r, which is a register output
  //
  // CL+3. The first version of this said CL+2 — the outbound register was
  // counted and the capture read was not — and every read returned zero.
  // This off-by-one has now cost the project six debugging sessions across
  // four modules, which is why it is spelled out instead of asserted.
  //
  // THAT DERIVATION IS AGAINST sdram_model, AND THE BOARD DISAGREES.
  //
  // The model samples commands and presents data on the same clock edge the
  // controller uses. The board does not: SDRAM_CLK is the inverse of clk_sys,
  // so the device samples and drives half a period away, and the model's own
  // header says that forwarded-clock phase is "deliberately not modelled
  // here". Every term above is right and the total is still a simulation
  // figure.
  //
  // Measured on hardware: the assembled line came back shifted right by one
  // 16-bit word — the controller tagged the burst's word 1 as word 0. The
  // V60's reset vector read FE104E where the ROM holds 4EF3D6, which is
  // exactly bits [39:16] of the same burst. It hid for a session because the
  // only other address fetched is word 0, where the ROM is 000d 000d 000d
  // 000d and a one-word shift is invisible.
  //
  // So the capture point is selectable at run time rather than guessed one
  // Quartus build at a time. `rd_lat_sel` picks CL+2 through CL+5; the
  // pipeline is always the longest of those and the tag is injected at the
  // chosen depth. Simulation ties it to 1 and keeps CL+3, so every existing
  // harness measures what it always measured.
  localparam int unsigned RD_LAT     = CL + 5;   // pipeline depth, the maximum
  localparam int unsigned RD_LAT_DEF = CL + 3;   // what the model needs

  // Which stage the tag is injected at, so it reaches slot 0 after that many
  // cycles. Registered off the selector to keep a slow OSD bit out of the
  // command path.
  logic [3:0] cap_depth;
  // Synchronous, like the command block below — see the note there. Mixing the two
  // disciplines on one reset net is what verilator's SYNCASYNCNET flags, and it is
  // a real smell rather than a nuisance: half the module would reset on a different
  // event from the other half.
  always_ff @(posedge clk) begin
    if (!rst_n) cap_depth <= 4'(RD_LAT_DEF);
    else case (rd_lat_sel)
      2'd0:    cap_depth <= 4'(CL + 3);   // unconnected lands here, by design
      2'd1:    cap_depth <= 4'(CL + 2);
      2'd2:    cap_depth <= 4'(CL + 4);
      default: cap_depth <= 4'(CL + 5);
    endcase
  end

  localparam int unsigned WIDX = NP;          // write port's grant index

  // ADDRESS DECODE
  //
  // A 32 MB module is 8192 rows x 512 columns x 4 banks of 16-bit words, so
  // 13 + 9 + 2 = 24 bits, which is exactly the [24:1] word address the ports
  // supply. Column is therefore NINE bits.
  //
  // s32's controller takes the column from [10:1] — ten bits — which with 13
  // row bits and 2 bank bits needs 25 address bits and so overlaps bit 10
  // between row and column. Copying that here would have aliased every
  // address pair differing only in bit 10 onto one location, which reads as
  // sporadic data corruption rather than as an address fault.
  localparam int unsigned COL_BITS = 9;

  logic [3:0]  cmd;
  assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd;
  assign sd_cke = 1'b1;

  typedef enum logic [3:0] {
    S_INIT, S_IDLE, S_DISPATCH, S_PRE_XFER, S_ACT, S_RCD,
    S_RD, S_WR, S_WRRC, S_PRE_REF, S_REFW
  } state_t;
  state_t state;

  logic [19:0] occ_win, occ_cnt, wt_cnt;

  // ---------------------------------------------------------------- mailbox
  // Metadata is captured with the request because arbitration may delay a
  // port long after the producer moved on to its next address.
  logic [NP-1:0]        pend;
  logic [NP-1:0][24:1]  addr_p;
  logic [NP-1:0][15:0]  din_p;
  logic [NP-1:0][1:0]   be_p;
  logic [NP-1:0]        we_p;
  logic                 wr_pend;
  logic [24:1]          wr_addr_p;
  logic [15:0]          wr_din_p;
  logic [1:0]           wr_be_p;

  logic [NP-1:0] req_d, ack_d;
  logic          wr_req_d, wr_ack_d;

  assign dbg_req = pend;

  int unsigned i;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pend <= '0; wr_pend <= 1'b0;
      req_d <= '0; ack_d <= '0; wr_req_d <= 1'b0; wr_ack_d <= 1'b0;
      addr_p <= '0; din_p <= '0; be_p <= '0; we_p <= '0;
      wr_addr_p <= '0; wr_din_p <= '0; wr_be_p <= '0;
    end else begin
      req_d    <= p_req;
      ack_d    <= p_ack;
      wr_req_d <= wr_req;
      wr_ack_d <= wr_ack;

      // Completion first, so a request edge landing on the same edge that
      // clears pend overrides it below rather than vanishing. See the header.
      for (i = 0; i < NP; i = i + 1)
        if (p_ack[i] && !ack_d[i]) pend[i] <= 1'b0;
      if (wr_ack && !wr_ack_d) wr_pend <= 1'b0;

      for (i = 0; i < NP; i = i + 1) begin
        if (p_req[i] && !req_d[i]) begin
          pend[i]   <= 1'b1;
          addr_p[i] <= p_addr[i];
          din_p[i]  <= p_din[i];
          be_p[i]   <= p_be[i];
          we_p[i]   <= p_we[i];
        end
      end
      if (wr_req && !wr_req_d) begin
        wr_pend   <= 1'b1;
        wr_addr_p <= wr_addr;
        wr_din_p  <= wr_din;
        wr_be_p   <= wr_be;
      end
    end
  end

  // ------------------------------------------------------------- arbitration
  // Round-robin over pending read/write ports, rotating after every grant so a
  // master that always has a request outstanding — the V60 during a cache miss
  // storm — cannot hold the bus. The write port sits above the rotation and
  // only matters during ROM download.
  logic [$clog2(NP)-1:0] rr_next;
  logic [$clog2(NP)-1:0] rr_grant;
  logic                  rr_valid;

  int unsigned j, cand;
  always_comb begin
    rr_valid = 1'b0;
    rr_grant = rr_next;
    // Walk the rotation from rr_next and take the first pending port. A loop
    // rather than a case ladder per rotation position: the ladder form is NP
    // copies of the same priority chain and every copy is a chance to mistype
    // an index.
    for (j = 0; j < NP; j = j + 1) begin
      cand = (rr_next + j) % NP;
      if (pend[cand] && !inflight[cand] && !rr_valid) begin
        rr_valid = 1'b1;
        rr_grant = ($clog2(NP))'(cand);
      end
    end
  end

  // THE ARBITER'S DECISION IS REGISTERED, one cycle ahead of dispatch.
  //
  // MEASURED: rr_next -> rr_next was the worst path in the whole design, and it
  // is the binding one - even at TGP 1:1 the build closes by only +0.044 ns. The
  // chain is rr_next -> rotate -> NP-deep priority -> rr_grant -> and then
  // rr_grant fans out to 7:1 muxes on addr (24 bits), din (16), be, blen() and
  // we_p before anything is registered. Arbitration and the whole port mux in
  // one cycle.
  //
  // Splitting it is free because the decision is only consumed at DISPATCH, and
  // a transfer occupies the controller for ten cycles or more - so the next
  // grant is computed while the current one is still running. The guard below
  // re-checks the port at dispatch, because a decision taken a cycle early can
  // be stale: a port may have gone in flight, or its request may have dropped.
  // Round-robin fairness is unaffected - a stale choice simply defers that port
  // by one transfer, which the rotation corrects on the next pass.
  logic [$clog2(NP)-1:0] arb_grant;
  logic                  arb_valid;
  // SYNCHRONOUS reset, like the rest of this module - see the note above
  // cap_depth. Mixing disciplines on one reset net is what SYNCASYNCNET flags,
  // and this block was written async first and caught by it.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      arb_grant <= '0;
      arb_valid <= 1'b0;
    end else begin
      arb_grant <= rr_grant;
      arb_valid <= rr_valid;
    end
  end
  // Stale-proofing: the registered choice is only usable if that port is still
  // asking and still free.
  wire arb_ok = arb_valid && pend[arb_grant] && !inflight[arb_grant];

  // ------------------------------------------------------------- transfer
  logic [$clog2(NP+1)-1:0] grant;
  logic                    grant_is_wr;
  logic [24:1]             xfer_addr;
  logic [3:0]              rd_total, rd_issued, rd_captured;
  logic                    is_write;
  logic [15:0]             din_r;
  logic [1:0]              be_r;
  logic [15:0]             cap_buf [4];

  // ROW STATE IS PER BANK
  //
  // The device holds one open row in each of its four banks, and the first
  // version of this controller tracked a single one and closed all four with
  // a precharge-all on every row change. With five masters interleaving, that
  // meant p0's access evicted p1's row and almost every transfer became a row
  // miss — a 16-cycle transfer instead of 10. Tracking each bank separately
  // and precharging only the bank actually being reused is what lets the
  // masters coexist, because D8 puts them in different address regions and
  // therefore usually in different banks.
  logic [3:0]  bank_open;
  logic [12:0] bank_row [4];
  // Cycles still owed to tRAS before that bank's row may be precharged. With
  // auto-precharge the device enforced this internally; taking that back means
  // taking the obligation back with it.
  logic [3:0]  ras_cnt [4];

  logic [1:0]  tbank;
  logic [12:0] trow;
  assign tbank = xfer_addr[24:23];
  assign trow  = xfer_addr[22:10];

  // A transfer whose bank and row are already open skips PRECHARGE and
  // ACTIVATE. This is the entire reason locality is worth anything: measured
  // before it existed, sequential traffic ran at exactly the same rate as
  // random — 0.263 words/cycle either way on a 4-word burst port — because
  // every read closed the row behind itself.
  logic        row_hit;
  assign row_hit = bank_open[tbank] && (bank_row[tbank] == trow);

  // Refresh needs every bank closed, so it must wait for the longest
  // outstanding tRAS rather than just the one it happens to look at.
  logic ras_any;
  assign ras_any = (ras_cnt[0] != 0) || (ras_cnt[1] != 0)
                || (ras_cnt[2] != 0) || (ras_cnt[3] != 0);

  logic [15:0]              init_cnt;
  logic [$clog2(T_REFI+1)-1:0] ref_cnt;
  logic                     ref_pend;
  logic [3:0]               wait_cnt;
  logic [15:0]              dq_r;

  // TAGGED READ CAPTURE
  //
  // The first version had one shared capture buffer and stalled each transfer
  // until its own data had drained — S_RDW waiting for the pipeline to empty.
  // That is five dead cycles on a ten-cycle row-hit burst, 40% of the
  // transfer, spent idle waiting for words already in flight.
  //
  // Instead every CAS carries a tag naming the port it belongs to and which
  // word of that port's burst it is. Capture then depends only on the tag, so
  // the issue side never waits: it can activate a row or issue the next
  // transfer's CAS while earlier data is still on its way back. Per-port
  // buffers are what make that safe — a shared one would interleave two
  // masters' words into the same array.
  logic [RD_LAT-1:0]        tag_v;
  logic [RD_LAT-1:0][2:0]   tag_p;      // port index
  logic [RD_LAT-1:0][1:0]   tag_w;      // word index within the burst
  logic [RD_LAT-1:0]        tag_last;
  logic [NP-1:0][3:0][15:0] cap;

  // Acks are per port now. A single shared hold counter was fine when only one
  // transfer existed at a time; with two ports in flight it would clear the
  // other port's ack early.
  logic [NP-1:0][1:0]       ack_cnt;
  logic [1:0]               wack_cnt;

  // Cycles until this bank's last outstanding read data has landed. A bank may
  // not be precharged while its own read is still returning, but other banks
  // are free — which is the entire point of overlapping.
  logic [3:0]               rd_bank_cnt [4];

  // Ports with a transfer issued but not yet acknowledged.
  //
  // `pend` alone cannot serve this purpose. It means "wants service" and only
  // clears on the ack, which used to be safe only because each transfer
  // stalled until its own data had drained. Once the pipeline removed that
  // stall, the FSM returned to arbitration while the data was still in flight,
  // saw pend still set, and dispatched the very same transaction again —
  // duplicate CAS commands, duplicate acks, and every port reading one
  // delivery behind. The arbiter must therefore skip a port that is already
  // being served, which is what this is.
  logic [NP-1:0]            inflight;
  logic                     wr_inflight;

  logic pipe_busy;
  assign pipe_busy = |tag_v;

  // A port is "granted" for telemetry while its transfer is in flight, not
  // merely on the cycle it was selected. Bandwidth is a question about
  // occupancy, and counting selection edges would report a fraction of it.
  // With the pipeline this is genuinely several ports at once, which is what
  // the telemetry is there to show.
  assign dbg_grant = inflight;

  // SYNCHRONOUS RESET, DELIBERATELY, and it is about the pins rather than style.
  //
  // Template.qsf asks for `Fast Output Register=ON` on `SDRAM_*` so the command and
  // address registers sit in the I/O cells, where clock-to-output is short and
  // fixed. With an ASYNC reset the fitter refuses, sixteen times:
  //
  //   Warning (176279): Can't pack register node "sd_a[8]" into I/O pin
  //     "SDRAM_A[8]". The node cannot simultaneously use clear and load signals.
  //
  // A Cyclone V I/O register has one or the other. `sd_a` needs the load, so the
  // asynchronous clear is what has to go — as a synchronous reset it becomes part
  // of the D-side logic and the register itself can live in the pin.
  //
  // Safe here because clk_sys free-runs from the PLL and rst_n is held through
  // lock, so the first clocked edges after lock perform the reset. Nothing in this
  // controller needs to be reset while its clock is stopped.
  always_ff @(posedge clk) begin
    // HOLD sd_a EXPLICITLY, so it has no ENABLE.
    //
    // Quartus refuses to pack sd_a into the I/O cells - sixteen copies of
    // "cannot simultaneously use clear and load signals" - and a Cyclone V I/O
    // register has one or the other. sd_a is never assigned in the reset branch,
    // so the CLEAR is the block's; the LOAD is sd_a being assigned only in some
    // states, which synthesises as an enable. Writing the hold explicitly makes
    // the D input an unconditional mux and removes the enable, leaving a
    // register the pin can hold.
    //
    // Behaviourally identical: a register with no assignment already holds.
    //
    // WHY IT MATTERS. The framework constrains this interface not at all - no
    // generated clock on SDRAM_CLK, no input or output delay, in sys_top.sdc or
    // ours - so the address path leaves through fabric with uncontrolled delay.
    // Skewed address bits select the wrong row or column, which is written into
    // this file's own history: a build whose only change was a debug counter
    // produced a garbage picture with +0.296 ns reported slack and no new
    // warnings. The board now reads back a 4096-burst sweep of the math tables
    // as 04FFFB where the model gives 991AF0 - correct data written, different
    // data returned - and unpacked address registers are the best candidate for
    // that in the whole design.
    sd_a <= sd_a;
    if (!rst_n) begin
      // cmd IS RESET AND THE OTHERS ARE NOT, deliberately.
      //
      // A synchronous reset did not let these pack into the I/O cells either —
      // Quartus counts it as a clear just the same, and the warning stayed at
      // sixteen. The clear has to be gone, not merely synchronous.
      //
      // cmd keeps its reset because a garbage command at power-up would be issued
      // to the device. sd_a, sd_ba and sd_dqm are don't-care whenever cmd is NOP,
      // and the init sequence writes all three before the first real command, so
      // their power-up value is unobservable.
      cmd <= C_NOP;
      // HELD, NOT CLEARED, so the register carries a LOAD and no CLEAR and can
      // pack into the I/O cell. Sixteen "cannot simultaneously use clear and
      // load signals" warnings kept sd_a in fabric, and with the interface
      // constrained the fitter SEGFAULTS immediately after them - three builds,
      // with and without the multicycle, so it is not the multicycle as our own
      // note claimed.
      //
      // Safe: sd_a is don't-care whenever cmd is NOP, and the init sequence
      // writes it before the first real command, so its power-up value is
      // unobservable. That is the same reasoning that already left it out of the
      // reset list; this states the hold explicitly instead of leaving the
      // register unassigned in this branch.
      sd_a <= sd_a;
      sd_dq_o <= '0; sd_dq_oe <= 1'b0;
      state <= S_INIT; ready <= 1'b0;
      init_cnt <= 16'(INIT_NOP);
      ref_cnt <= '0; ref_pend <= 1'b0;
      bank_open <= '0;
      for (int b = 0; b < 4; b++) begin bank_row[b] <= '0; ras_cnt[b] <= '0; end
      tag_v <= '0; tag_p <= '0; tag_w <= '0; tag_last <= '0; cap <= '0;
      ack_cnt <= '0; wack_cnt <= '0; inflight <= '0; wr_inflight <= 1'b0;
      for (int b = 0; b < 4; b++) rd_bank_cnt[b] <= '0;
      p_ack <= '0; wr_ack <= 1'b0; p_dout <= '0;
      grant <= '0; grant_is_wr <= 1'b0; rr_next <= '0;
      rd_total <= 4'd1; rd_issued <= '0; rd_captured <= '0;
      is_write <= 1'b0; xfer_addr <= '0; din_r <= '0; be_r <= '0;
      wait_cnt <= '0; dq_r <= '0;
    end else begin
      cmd      <= C_NOP;
      sd_dq_oe <= 1'b0;
      dq_r     <= sd_dq_i;

      for (int q = 0; q < NP; q++) begin
        if (ack_cnt[q] != 0) ack_cnt[q] <= ack_cnt[q] - 1'b1;
        else p_ack[q] <= 1'b0;
        // inflight must clear on the SAME edge as pend, not on the delivery
        // edge one cycle earlier. The mailbox clears pend when it observes the
        // ack rising, so clearing inflight at delivery opens a one-cycle window
        // where pend still holds the finished transaction and inflight no
        // longer blocks it — and the arbiter re-dispatches the completed
        // transaction's stale address. That returned the previous word for
        // every read, which looks like a broken data path and is not one.
        if (p_ack[q] && !ack_d[q]) inflight[q] <= 1'b0;
      end
      if (wr_ack && !wr_ack_d) wr_inflight <= 1'b0;
      if (wack_cnt != 0) wack_cnt <= wack_cnt - 1'b1;
      else wr_ack <= 1'b0;

      if (state == S_INIT) begin
        sd_dqm <= 2'b11;
        init_cnt <= init_cnt - 1'b1;
        // JEDEC bring-up: NOPs, precharge all, eight refreshes, mode register.
        // Spacing is generous rather than minimal; this runs once.
        case (init_cnt)
          16'd400: begin cmd <= C_PRE; sd_a <= 13'h400; end
          16'd360, 16'd350, 16'd340, 16'd330,
          16'd320, 16'd310, 16'd300, 16'd290: cmd <= C_REF;
          16'd200: begin
            cmd   <= C_MRS;
            sd_ba <= 2'b00;
            sd_a  <= 13'b000_0_00_010_0_000;   // CL2, sequential, burst 1
          end
          16'd1: begin ready <= 1'b1; state <= S_IDLE; end
          default: ;
        endcase
      end else begin
        sd_dqm <= 2'b00;

        for (int b = 0; b < 4; b++)
          if (ras_cnt[b] != 0) ras_cnt[b] <= ras_cnt[b] - 1'b1;

        ref_cnt <= ref_cnt + 1'b1;
        if (ref_cnt == ($clog2(T_REFI+1))'(T_REFI)) begin
          ref_cnt  <= '0;
          ref_pend <= 1'b1;
        end

        for (int b = 0; b < 4; b++)
          if (rd_bank_cnt[b] != 0) rd_bank_cnt[b] <= rd_bank_cnt[b] - 1'b1;

        // Read capture, driven entirely by the tag that travelled with the CAS.
        tag_v    <= {1'b0, tag_v[RD_LAT-1:1]};
        tag_p    <= {3'd0, tag_p[RD_LAT-1:1]};
        tag_w    <= {2'd0, tag_w[RD_LAT-1:1]};
        tag_last <= {1'b0, tag_last[RD_LAT-1:1]};
        if (tag_v[0]) begin
          cap[tag_p[0]][tag_w[0]] <= dq_r;
          if (tag_last[0]) begin
            // The final word and its buffer write share an edge, so deliver
            // the staged word directly rather than reading back a stale slot.
            // Word index 0 on the last word means this was a single-word
            // transfer; anything else means the full four.
            if (tag_w[0] == 2'd0)
              p_dout[tag_p[0]] <= {48'd0, dq_r};
            else
              p_dout[tag_p[0]] <= {dq_r, cap[tag_p[0]][2],
                                   cap[tag_p[0]][1], cap[tag_p[0]][0]};
            p_ack[tag_p[0]]    <= 1'b1;
            ack_cnt[tag_p[0]]  <= 2'(ACK_HOLD - 1);
          end
        end

        case (state)
          S_IDLE: begin
            if (ref_pend && !pipe_busy && !ras_any) begin
              cmd       <= C_PRE;
              sd_a      <= 13'h400;             // A10: precharge all
              bank_open <= '0;
              wait_cnt <= 4'(T_RP - 1);
              state    <= S_PRE_REF;
            end else if (!ref_pend &&
                         ((wr_pend && !wr_inflight && !pipe_busy) ||
                          (arb_ok && !(we_p[arb_grant] && pipe_busy)))) begin
              // No new transfer once a refresh is due. Refresh needs every
              // bank precharged and the read pipeline empty, and under
              // continuous traffic the pipeline is never empty — so without
              // this the refresh waits forever. The device model caught it
              // immediately once the drain stall was removed; on hardware it
              // would have been silent data decay, which is about the worst
              // failure to debug in the field.
              //
              // The cost is a bubble of roughly a drain plus tRP plus tRC once
              // every T_REFI cycles, which is a couple of percent.
              // A write drives DQ, so it may not be issued while read data is
              // still returning on the same wires. Reads have no such
              // restriction, which is what lets them overlap.
              logic [24:1] sel;
              if (wr_pend && !wr_inflight && !pipe_busy) begin
                grant       <= ($clog2(NP+1))'(WIDX);
                grant_is_wr <= 1'b1;
                wr_inflight <= 1'b1;
                sel         = wr_addr_p;
                din_r       <= wr_din_p;
                be_r        <= wr_be_p;
                is_write    <= 1'b1;
                rd_total    <= 4'd1;
              end else begin
                grant       <= ($clog2(NP+1))'(arb_grant);
                grant_is_wr <= 1'b0;
                sel         = addr_p[arb_grant];
                din_r       <= din_p[arb_grant];
                be_r        <= be_p[arb_grant];
                is_write    <= we_p[arb_grant];
                rd_total    <= we_p[arb_grant] ? 4'd1 : blen(arb_grant);
                // Writes take it too: a port writing is equally in flight and
                // equally must not be re-selected before it completes.
                inflight[arb_grant] <= 1'b1;
                rr_next     <= (arb_grant == ($clog2(NP))'(NP-1))
                                 ? '0 : arb_grant + 1'b1;
              end
              xfer_addr   <= sel;
              rd_issued   <= '0;
              rd_captured <= '0;
              // A dedicated dispatch cycle keeps the port mux and the row
              // comparator out of the command-output timing cone. Requesters
              // wait for ack, so this costs latency, not semantics.
              state <= S_DISPATCH;
            end
          end

          S_DISPATCH: begin
            if (row_hit) begin
              state <= is_write ? S_WR : S_RD;
            end else if (bank_open[tbank]) begin
              // Precharge only the bank being reused: A10 low with the bank
              // address, not the precharge-all the first version used. tRAS is
              // owed from the ACTIVATE that opened this bank's row.
              // rd_bank_cnt is defensive and, at this FSM's spacing, not
              // currently reachable — deleting it changes no test result. The
              // reason is structural, not a missing case: the earliest a
              // precharge can follow that bank's last CAS is CAS -> S_IDLE ->
              // S_DISPATCH, which lands exactly on the cycle the data is due,
              // never before it. It is kept because that margin is one state
              // wide, and any future shortening of the dispatch path would
              // start truncating read bursts silently.
              if (ras_cnt[tbank] == 0 && rd_bank_cnt[tbank] == 0) begin
                cmd              <= C_PRE;
                sd_ba            <= tbank;
                sd_a             <= 13'h000;
                bank_open[tbank] <= 1'b0;
                wait_cnt         <= 4'(T_RP - 1);
                state            <= S_PRE_XFER;
              end
            end else begin
              state <= S_ACT;
            end
          end

          S_PRE_XFER: begin
            if (wait_cnt == 0) state <= S_ACT;
            else wait_cnt <= wait_cnt - 1'b1;
          end

          S_ACT: begin
            cmd       <= C_ACT;
            sd_ba     <= xfer_addr[24:23];
            sd_a      <= xfer_addr[22:10];
            bank_row[tbank]  <= trow;
            bank_open[tbank] <= 1'b1;
            ras_cnt[tbank]   <= 4'(T_RAS - 1);
            wait_cnt  <= 4'(T_RCD - 1);
            state     <= S_RCD;
          end

          S_RCD: begin
            if (wait_cnt == 0) state <= is_write ? S_WR : S_RD;
            else wait_cnt <= wait_cnt - 1'b1;
          end

          S_WR: begin
            cmd      <= C_WRITE;
            sd_ba    <= xfer_addr[24:23];
            sd_a     <= {3'b000, 1'b0, xfer_addr[9:1]};  // A10 low: keep row open
            sd_dq_o  <= din_r;
            sd_dq_oe <= 1'b1;
            sd_dqm   <= ~be_r;
            // Hold past tWR and tRAS before anything can precharge this row.
            // The row is left open on purpose: a download write stream is
            // sequential and the next word usually hits the same row.
            wait_cnt <= 4'((T_WR > T_RAS - T_RCD) ? T_WR : T_RAS - T_RCD);
            state    <= S_WRRC;
          end

          S_WRRC: begin
            if (wait_cnt == 4'((T_WR > T_RAS - T_RCD) ? T_WR : T_RAS - T_RCD)) begin
              if (grant_is_wr) begin
                wr_ack   <= 1'b1;
                wack_cnt <= 2'(ACK_HOLD - 1);
              end else begin
                p_ack[grant]    <= 1'b1;
                ack_cnt[grant]  <= 2'(ACK_HOLD - 1);
              end
            end
            if (wait_cnt == 0) state <= S_IDLE;
            else wait_cnt <= wait_cnt - 1'b1;
          end

          S_RD: begin
            // One READ per cycle. The last one carries A10, requesting
            // auto-precharge, so the row closes without a separate command.
            cmd        <= C_READ;
            sd_ba      <= xfer_addr[24:23];
            // A10 low: the row stays open so the next transfer to it can skip
            // PRECHARGE and ACTIVATE entirely. A10 is the auto-precharge bit
            // and the column is nine bits, so A9 is padded explicitly — a
            // packing of {3'b000, x, col} would land x on A9, which the device
            // ignores.
            sd_a       <= {2'b00, 1'b0, 1'b0, xfer_addr[9:1]};
            // Injected at the selected depth, not at the top of the
            // pipeline: the tag reaches slot 0 after cap_depth cycles, which
            // is what decides which bus word is called word 0.
            tag_v[cap_depth-1]    <= 1'b1;
            tag_p[cap_depth-1]    <= grant[2:0];
            tag_w[cap_depth-1]    <= rd_issued[1:0];
            tag_last[cap_depth-1] <= (rd_issued + 1'b1 == rd_total);
            rd_bank_cnt[tbank]    <= cap_depth;
            // Bursts wrap inside the open row: incrementing the full address
            // would walk off the end of the row on the last column and read
            // from a row that was never activated.
            xfer_addr[9:1] <= xfer_addr[9:1] + 1'b1;
            rd_issued  <= rd_issued + 1'b1;
            if (rd_issued + 1'b1 == rd_total) begin
              // Straight back to arbitration. The row stays open, and the data
              // still in flight is the tag pipeline's problem, not this state
              // machine's — which is the change that removes the drain stall.
              state <= S_IDLE;
            end
          end

          S_PRE_REF: begin
            if (wait_cnt == 0) begin
              cmd       <= C_REF;
              bank_open <= '0;
              ref_pend  <= 1'b0;
              wait_cnt <= 4'(T_RC - 1);
              state    <= S_REFW;
            end else wait_cnt <= wait_cnt - 1'b1;
          end

          S_REFW: begin
            if (wait_cnt == 0) state <= S_IDLE;
            else wait_cnt <= wait_cnt - 1'b1;
          end

          default: state <= S_IDLE;
        endcase
      end
    end
  end

  // The occupancy window. Counted here rather than inside the command process
  // so the measurement cannot perturb the command timing path.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      occ_win <= '0; occ_cnt <= '0; wt_cnt <= '0;
      dbg_occ <= '0; dbg_wait1 <= '0;
    end else begin
      occ_win <= occ_win + 1'b1;
      if (&occ_win) begin
        dbg_occ   <= occ_cnt[19:12];
        dbg_wait1 <= wt_cnt[19:12];
        occ_cnt   <= (state != S_IDLE && state != S_INIT) ? 20'd1 : 20'd0;
        wt_cnt    <= (NP > 1 && pend[1]) ? 20'd1 : 20'd0;
      end else begin
        if (state != S_IDLE && state != S_INIT) occ_cnt <= occ_cnt + 1'b1;
        if (NP > 1 && pend[1])                  wt_cnt  <= wt_cnt  + 1'b1;
      end
    end
  end

endmodule
