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
// Behavioural SDRAM device model that CHECKS THE PROTOCOL.
//
// WHY THIS EXISTS
//
// s32 ships an SDRAM testbench and it is not enough to build a controller
// against. Its device model returns `0xa000 ^ column` for every read — a
// column echo, not storage — so:
//
//   - the write path cannot be verified at all, because a read never returns
//     what was written to it;
//   - every command timing rule is unchecked. A controller that drives READ
//     one cycle after ACTIVATE, precharges a row it activated last cycle, or
//     never refreshes at all, passes.
//
// Those faults do not show up in simulation. They show up as a core that
// works on the author's board and hangs or corrupts on someone else's, at a
// different temperature, with a different SDRAM stick — which is the single
// worst failure mode to ship, because the person seeing it has no way to
// debug it and the author cannot reproduce it.
//
// So this model stores what is written, returns it, and asserts on every
// JEDEC timing rule the controller can violate. A controller is not
// considered working here until it runs a full traffic mix through this with
// `violations == 0`.
//
// CLOCKING CONTRACT
//
// Commands are sampled on posedge. Read data is presented CL cycles later,
// also on posedge, and the controller samples it on the following edge. The
// real board's +90-degree forwarded clock to the chip is a pin-timing matter
// handled by the PLL and the .sdc, and deliberately not modelled here: mixing
// physical phase into a protocol checker makes both harder to reason about.
//
// DQ is split into separate in/out/oe rather than a tri-state `inout`. That
// keeps the model and the controller Verilator-friendly, and the tri-state
// assign lives in one place at the top level where the physical pin is.

`timescale 1ns/1ps

module sdram_model #(
  parameter int unsigned ROW_BITS = 13,
  parameter int unsigned COL_BITS = 10,
  parameter int unsigned BA_BITS  = 2,
  parameter int unsigned DQ_BITS  = 16,

  // Timing, in clock cycles. Defaults are -7E parts at roughly 100 MHz, which
  // is the usual MiSTer operating point. They are parameters because the
  // right values depend on the clock the controller ends up running at, and a
  // model with the numbers baked in is a model that silently stops checking
  // when the clock changes.
  parameter int unsigned T_RCD = 2,    // ACTIVATE -> READ/WRITE
  parameter int unsigned T_RP  = 2,    // PRECHARGE -> ACTIVATE
  parameter int unsigned T_RC  = 7,    // ACTIVATE -> ACTIVATE, same bank
  parameter int unsigned T_RAS = 5,    // ACTIVATE -> PRECHARGE, same bank
  parameter int unsigned T_RRD = 2,    // ACTIVATE -> ACTIVATE, different bank
  parameter int unsigned T_WR  = 2,    // last write data -> PRECHARGE
  parameter int unsigned T_MRD = 2,    // MRS -> any other command
  parameter int unsigned CL    = 2,    // CAS latency

  // Refresh. 8192 rows in 64 ms at 100 MHz is one every 781 cycles on
  // average. Bursting is legal, so the check is against a generous multiple
  // rather than the average itself — a controller that refreshes in bursts of
  // eight is correct and must not be failed for it.
  parameter int unsigned T_REFI     = 781,
  parameter int unsigned REFI_SLACK = 9,

  parameter bit CHECK_REFRESH = 1'b1,
  parameter int unsigned MAX_REPORT = 20,

  // What a location nobody has written reads back as.
  //
  // Zero is the convenient answer and the misleading one: zero is a legal
  // instruction, a legal tile number and a black palette entry, so a core let
  // loose on empty memory looks far healthier here than it does on a board.
  // Storage is sparse and cannot be pre-filled cheaply, so the default comes
  // from a parameter instead. Left at zero so every existing harness keeps the
  // numbers it was baselined with.
  parameter logic [DQ_BITS-1:0] DEFAULT_DATA = '0
) (
  input  logic                clk,
  input  logic                cke,
  input  logic                cs_n,
  input  logic                ras_n,
  input  logic                cas_n,
  input  logic                we_n,
  input  logic [BA_BITS-1:0]  ba,
  input  logic [ROW_BITS-1:0] a,
  input  logic [1:0]          dqm,

  // Controller -> device
  input  logic [DQ_BITS-1:0]  dq_i,
  input  logic                dq_oe_i,

  // Device -> controller
  output logic [DQ_BITS-1:0]  dq_o,
  output logic                dq_oe_o,

  // Observability. Every check that fires sets its bit in `v_flags` and bumps
  // `violations`. The bitmask matters: a harness proving this model has teeth
  // has to show that a specific injected fault trips its specific check, not
  // merely that something somewhere complained.
  output int unsigned         violations,
  output logic [15:0]         v_flags,
  output int unsigned         reads_served,
  output int unsigned         writes_served
);

  localparam int unsigned BANKS = 1 << BA_BITS;

  // Violation codes. Kept as localparams and mirrored in the harness so a
  // failure names the rule that broke rather than a bare index.
  localparam int V_ACT_OPEN   = 0;   // ACTIVATE on a bank with a row already open
  localparam int V_TRCD       = 1;
  localparam int V_TRAS       = 2;
  localparam int V_TRP        = 3;
  localparam int V_TRC        = 4;
  localparam int V_TRRD       = 5;
  localparam int V_NO_ROW     = 6;   // READ/WRITE with no open row
  localparam int V_TWR        = 7;
  localparam int V_REF_OPEN   = 8;   // REFRESH with a bank open
  localparam int V_REFRESH    = 9;   // refresh interval exceeded
  localparam int V_MRS_OPEN   = 10;  // MRS with a bank open
  localparam int V_TMRD       = 11;
  localparam int V_DQ_FIGHT   = 12;  // both ends driving DQ
  localparam int V_RD_TRUNC   = 13;  // PRECHARGE while read data still in flight

  // Command encoding, {cs_n, ras_n, cas_n, we_n}.
  localparam logic [3:0] C_NOP   = 4'b0111;
  localparam logic [3:0] C_ACT   = 4'b0011;
  localparam logic [3:0] C_READ  = 4'b0101;
  localparam logic [3:0] C_WRITE = 4'b0100;
  localparam logic [3:0] C_PRE   = 4'b0010;
  localparam logic [3:0] C_REF   = 4'b0001;
  localparam logic [3:0] C_MRS   = 4'b0000;

  wire logic [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
  // A deselected device ignores everything; so does a device with CKE low.
  wire logic       active = cke && !cs_n;

  // Sparse storage. A 13/10/2 device is 33.5 M words, and a dense array would
  // cost 67 MB of simulator memory to hold a few thousand written locations.
  logic [DQ_BITS-1:0] mem [longint];

  logic                row_open [BANKS];
  logic [ROW_BITS-1:0] open_row [BANKS];
  longint              t_act    [BANKS];   // cycle of last ACTIVATE
  longint              t_pre    [BANKS];   // cycle of last PRECHARGE
  longint              t_wr     [BANKS];   // cycle of last WRITE data
  // Cycle by which this bank's outstanding read data has been delivered. A
  // PRECHARGE before then truncates the burst on real silicon and returns
  // nothing, which is a controller bug the model previously could not see.
  longint              rd_due   [BANKS];

  longint cyc;
  longint t_act_any;
  longint t_ref;
  longint t_mrs;
  logic   initialised;                     // MRS seen

  int unsigned reported;

  // Read return pipeline. Burst length is 1 in this controller's mode word, so
  // one entry per READ is enough; depth is CL+2 so the CL parameter can move
  // without reshaping anything.
  logic                rd_v   [CL+2];
  logic [DQ_BITS-1:0]  rd_d   [CL+2];

  function automatic longint addr_of(input logic [BA_BITS-1:0] b,
                                     input logic [ROW_BITS-1:0] r,
                                     input logic [COL_BITS-1:0] c);
    addr_of = (longint'(b) << (ROW_BITS + COL_BITS))
            | (longint'(r) << COL_BITS)
            | longint'(c);
  endfunction

  // Blocking assignment inside a clocked process is flagged by -Wall, and in
  // synthesised RTL that warning is right. This is a behavioural device model,
  // never synthesised: the storage array, the address temporaries and the
  // violation counter all have to take effect immediately within the cycle
  // that computes them, which is exactly what blocking assignment means. The
  // waiver is scoped to this block rather than set globally so that a real
  // BLKSEQ fault elsewhere still fails the lint.
  /* verilator lint_off BLKSEQ */

  task automatic flag(input int code, input string msg);
    violations = violations + 1;
    v_flags[code] = 1'b1;
    if (reported < MAX_REPORT) begin
      reported = reported + 1;
      $display("SDRAM VIOLATION @%0d [%0d] %s", cyc, code, msg);
    end
  endtask

  int unsigned bi;
  initial begin
    cyc = 0; t_act_any = -1000; t_ref = 0; t_mrs = -1000;
    violations = 0; v_flags = '0; reported = 0; initialised = 1'b0;
    reads_served = 0; writes_served = 0;
    dq_o = '0; dq_oe_o = 1'b0;
    for (bi = 0; bi < BANKS; bi = bi + 1) begin
      row_open[bi] = 1'b0; open_row[bi] = '0;
      t_act[bi] = -1000; t_pre[bi] = -1000; t_wr[bi] = -1000;
      rd_due[bi] = -1000;
    end
    for (bi = 0; bi < CL+2; bi = bi + 1) begin rd_v[bi] = 1'b0; rd_d[bi] = '0; end
  end

  int unsigned k;
  logic [COL_BITS-1:0] col;
  longint              adr;
  logic [DQ_BITS-1:0]  cur;
  longint              eff_pre;

  always @(posedge clk) begin
    cyc <= cyc + 1;

    // Advance the read return pipeline first, so a READ issued this cycle
    // lands in slot 0 below and emerges exactly CL cycles later.
    for (k = 0; k < CL+1; k = k + 1) begin
      rd_v[k] <= rd_v[k+1];
      rd_d[k] <= rd_d[k+1];
    end
    rd_v[CL+1] <= 1'b0;

    dq_oe_o <= rd_v[0];
    dq_o    <= rd_d[0];

    // Both ends driving the bus is a controller bug that a tri-state model
    // would hide behind an X. Name it.
    //
    // Compare the state in which the device is ACTUALLY driving, dq_oe_o, not
    // rd_v[0] which is one edge earlier. The first version compared rd_v[0]
    // and so checked the cycle before the device took the bus — a controller
    // whose write data landed exactly one cycle later, which is the natural
    // spacing its own state machine produces, collided for real and passed.
    // The check existed, named the right hazard, and could not fire.
    if (dq_oe_o && dq_oe_i) flag(V_DQ_FIGHT, "controller drives DQ during read data");

    if (CHECK_REFRESH && initialised && (cyc - t_ref) > longint'(T_REFI) * longint'(REFI_SLACK)) begin
      flag(V_REFRESH, $sformatf("no REFRESH for %0d cycles", cyc - t_ref));
      t_ref <= cyc;   // report once per overrun, not every cycle after
    end

    if (active) begin
      // Anything other than MRS itself must respect tMRD after one.
      if (cmd != C_NOP && (cyc - t_mrs) < longint'(T_MRD) && t_mrs > 0)
        flag(V_TMRD, "command inside tMRD after MRS");

      case (cmd)
        C_MRS: begin
          for (k = 0; k < BANKS; k = k + 1)
            if (row_open[k]) flag(V_MRS_OPEN, "MRS with a bank open");
          t_mrs <= cyc;
          initialised <= 1'b1;
          t_ref <= cyc;
        end

        C_ACT: begin
          if (row_open[ba])
            flag(V_ACT_OPEN, $sformatf("ACTIVATE bank %0d with row %0d still open",
                                       ba, open_row[ba]));
          if ((cyc - t_pre[ba]) < longint'(T_RP) && t_pre[ba] > 0)
            flag(V_TRP, $sformatf("tRP: ACTIVATE %0d cycles after PRECHARGE",
                                  cyc - t_pre[ba]));
          if ((cyc - t_act[ba]) < longint'(T_RC) && t_act[ba] > 0)
            flag(V_TRC, $sformatf("tRC: ACTIVATE %0d cycles after ACTIVATE, same bank",
                                  cyc - t_act[ba]));
          if ((cyc - t_act_any) < longint'(T_RRD) && t_act_any > 0)
            flag(V_TRRD, $sformatf("tRRD: ACTIVATE %0d cycles after another ACTIVATE",
                                   cyc - t_act_any));
          row_open[ba] <= 1'b1;
          open_row[ba] <= a;
          t_act[ba]    <= cyc;
          t_act_any    <= cyc;
        end

        C_READ, C_WRITE: begin
          if (!row_open[ba]) begin
            flag(V_NO_ROW, $sformatf("%s bank %0d with no open row",
                                     (cmd == C_READ) ? "READ" : "WRITE", ba));
          end else begin
            if ((cyc - t_act[ba]) < longint'(T_RCD))
              flag(V_TRCD, $sformatf("tRCD: access %0d cycles after ACTIVATE",
                                     cyc - t_act[ba]));
            col = a[COL_BITS-1:0];
            adr = addr_of(ba, open_row[ba], col);
            if (cmd == C_READ) begin
              rd_due[ba] <= cyc + longint'(CL);
              // Slot CL-1, not CL. A READ at edge T must present data after
              // edge T+CL. The entry lands in slot S at edge T and reaches
              // slot 0 after edge T+S, and dq_o is registered from rd_d[0] one
              // edge after that — so S = CL-1. Slot CL would deliver at T+CL+1.
              // Traced rather than discovered by a failing run, because this
              // exact off-by-one has cost this project five debugging sessions
              // already and it always looks like broken hardware.
              rd_v[CL-1] <= 1'b1;
              rd_d[CL-1] <= mem.exists(adr) ? mem[adr] : DEFAULT_DATA;
              reads_served <= reads_served + 1;
            end else begin
              cur = mem.exists(adr) ? mem[adr] : DEFAULT_DATA;
              // DQM is active-high mask: a set bit suppresses that byte.
              if (!dqm[0]) cur[7:0]  = dq_i[7:0];
              if (!dqm[1]) cur[15:8] = dq_i[15:8];
              mem[adr] = cur;
              t_wr[ba] <= cyc;
              writes_served <= writes_served + 1;
            end
          end
          // A10 high on READ/WRITE requests auto-precharge, which the
          // controller uses on the final CAS of every read burst.
          //
          // The subtlety that makes this worth modelling rather than ignoring:
          // the device does NOT precharge immediately. It delays internally
          // until tRAS(min) is satisfied, so an auto-precharge that lands
          // early is legal and must not be flagged as a tRAS violation. What
          // it does affect is tRP for the next ACTIVATE to that bank, which is
          // measured from the effective precharge point, not from the CAS. A
          // model that closed the row at the CAS edge would let a controller
          // re-activate too early and call it correct.
          //
          // The tRAS clamp below is datasheet fidelity, NOT a checked
          // behaviour, and mutation testing is what established the
          // difference: deleting it changes no test result. The reason is
          // structural. The next ACTIVATE to this bank is bounded by
          // eff_pre + tRP, which with the clamp is tRAS + tRP — and tRC is
          // *defined* as tRAS + tRP, so the tRC check always binds first. It
          // is kept because a model should describe the device rather than
          // only the parts one controller can observe, but it is deliberately
          // not claimed as covered.
          if (a[10] && row_open[ba]) begin
            eff_pre = (cmd == C_READ) ? (cyc + 1) : (cyc + longint'(T_WR));
            if (eff_pre < t_act[ba] + longint'(T_RAS))
              eff_pre = t_act[ba] + longint'(T_RAS);
            row_open[ba] <= 1'b0;
            t_pre[ba]    <= eff_pre;
          end
        end

        C_PRE: begin
          for (k = 0; k < BANKS; k = k + 1) begin
            // A10 selects precharge-all over the addressed bank.
            if (a[10] || (BA_BITS'(k) == ba)) begin
              if (row_open[k]) begin
                if (cyc < rd_due[k])
                  flag(V_RD_TRUNC, $sformatf("PRECHARGE bank %0d truncates read data", k));
                if ((cyc - t_act[k]) < longint'(T_RAS))
                  flag(V_TRAS, $sformatf("tRAS: PRECHARGE %0d cycles after ACTIVATE",
                                         cyc - t_act[k]));
                if ((cyc - t_wr[k]) < longint'(T_WR) && t_wr[k] > 0)
                  flag(V_TWR, $sformatf("tWR: PRECHARGE %0d cycles after WRITE",
                                        cyc - t_wr[k]));
                t_pre[k] <= cyc;
              end
              row_open[k] <= 1'b0;
            end
          end
        end

        C_REF: begin
          for (k = 0; k < BANKS; k = k + 1)
            if (row_open[k]) flag(V_REF_OPEN, $sformatf("REFRESH with bank %0d open", k));
          t_ref <= cyc;
        end

        default: ; // NOP / deselect
      endcase
    end
  end

  /* verilator lint_on BLKSEQ */

endmodule
