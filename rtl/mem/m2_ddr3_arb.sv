// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// FROM THE MODEL 2 CORE, sega-model2-mister at 47ad2e2 (main), rtl/mem/m2_ddr3_arb.sv.
// Unchanged.
// The R-numbers below are entries in that project's design study
// (docs/model2a-design-study.md), where each failure mode is recorded.
//
// TWO MASTERS, ONE DDRAM PORT. The framebuffer has a writer (spans, from the
// fill) and a reader (a line at a time, for the scanout) and the framework
// gives the core exactly one DDRAM interface.
//
// THE READER WINS, ALWAYS, AND IT IS NOT A CLOSE CALL. The scanout has a beam
// deadline: a line that is not in the buffer when the beam arrives is a torn
// line. The writer has none -- the fill runs ahead of the display by a whole
// frame, and a span that lands late simply lands late. Round-robin would be
// the wrong answer here, and this is the opposite of m2_sdram's arbiter, where
// every master is equally entitled.
//
// STARVATION IS BOUNDED BY ARITHMETIC, not by a fairness rule. The reader takes
// one 248-beat burst per scanline -- about 2.6 us of a 30 us line, under 9% --
// so the writer has the rest and cannot be locked out. That only holds while
// the reader is one burst a line; anything that makes it greedier has to
// revisit this.
//
// A TRANSACTION IS NOT INTERRUPTED once granted. DDR3 bursts carry their own
// address and the beats must not be interleaved with another master's, so the
// grant is held to the acknowledge.

`timescale 1ns/1ps

module m2_ddr3_arb (
  input  logic        clk,
  input  logic        rst_n,

  // ---- port 0: the scanout reader. PRIORITY.
  input  logic        a_req,
  input  logic        a_we,
  input  logic [24:0] a_addr,
  input  logic [7:0]  a_blen,
  input  logic [63:0] a_din,
  input  logic [7:0]  a_be,
  output logic        a_wnext,
  output logic        a_wacc,      // R660: m_wacc, routed like wnext
  output logic        a_rvalid,
  output logic        a_ack,

  // ---- port 1: the span writer
  input  logic        b_req,
  // R655: b is not GRANTED while b_hold (the framebuffer writer waits while
  // the scanout reader has a line to fetch). A grant already made runs out.
  input  logic        b_hold,
  input  logic        b_we,
  input  logic [24:0] b_addr,
  input  logic [7:0]  b_blen,
  input  logic [63:0] b_din,
  input  logic [7:0]  b_be,
  output logic        b_wnext,
  output logic        b_wacc,
  output logic        b_rvalid,
  output logic        b_ack,

  // ---- the single master
  output logic        m_req,
  output logic        m_we,
  output logic [24:0] m_addr,
  output logic [7:0]  m_blen,
  output logic [63:0] m_din,
  output logic [7:0]  m_be,
  input  logic        m_wnext,
  input  logic        m_wacc,
  input  logic        m_rvalid,
  input  logic        m_ack,
  input  logic [63:0] m_dout,
  output logic [63:0] dout,

  output logic [31:0] dbg_a_waits,     // cycles the READER spent waiting
  output logic [31:0] dbg_b_waits,
  // R364: THE ARBITER'S STATE, OBSERVABLE. A block that can wedge the whole
  // core by holding a grant must not be a black box -- the board reported
  // "0 lines fetched" with nothing in flight, and busy/owner were the two bits
  // that would have named the fault immediately.
  output logic        dbg_busy,
  output logic        dbg_owner
);

  logic       busy, owner;             // 0 = a, 1 = b
  assign dbg_busy = busy;
  assign dbg_owner = owner;
  // ONE DEAD CYCLE AFTER AN ACKNOWLEDGE, and it is not politeness.
  // A master clears its request ON the acknowledge, which is a registered
  // assignment -- so for the cycle after m_ack its req is STILL HIGH. Granting
  // in that cycle starts the same transaction a second time, and the bench
  // caught it exactly: three grants for two requests, with the second master's
  // beats delivered against the first master's burst.
  //
  // It is enforced in ONE place -- the m_req gate below. An earlier version also
  // guarded the grant condition, and a mutation test then PASSED with that guard
  // removed, because the other mechanism was silently carrying it. Two guards
  // for one rule means a mutation test cannot tell you which one works.
  logic       cool;
  wire        b_ok = b_req && !b_hold;   // R655

  assign m_req  = cool ? 1'b0
                : busy ? (owner ? b_req  : a_req)  : (a_req | b_ok);
  assign m_we   = busy ? (owner ? b_we   : a_we)   : (a_req ? a_we   : b_we);
  assign m_addr = busy ? (owner ? b_addr : a_addr) : (a_req ? a_addr : b_addr);
  assign m_blen = busy ? (owner ? b_blen : a_blen) : (a_req ? a_blen : b_blen);
  assign m_din  = busy ? (owner ? b_din  : a_din)  : (a_req ? a_din  : b_din);
  assign m_be   = busy ? (owner ? b_be   : a_be)   : (a_req ? a_be   : b_be);

  assign dout   = m_dout;

  // R374: RESPONSES ARE ROUTED BY THE REGISTERED OWNER, NEVER BY `req`.
  //
  // This was `busy ? owner : (a_req ? 1'b0 : 1'b1)`, so whenever `busy` was
  // clear the routing followed a_req LIVE -- and m2_fb_read drops a_req on its
  // FIRST returned beat, which it is entitled to do. The acknowledge for a read
  // in flight then went to the writer, the reader waited in R_FILL for ever,
  // and the arbiter held a grant nobody would release.
  //
  // MEASURED, not deduced. s121 on the board:
  //     acks ISSUED 3  ->  SEEN by the reader 2  ->  lines COMPLETED 2
  // seen == completed, so the reader FSM is correct after R368; the missing one
  // never reached it. R370's three-way counter was built to tell those apart and
  // this is the answer it gave.
  //
  // `owner` is registered at the grant and is valid for the whole transaction,
  // including any cycle where `busy` happens to be clear. A response cannot
  // arrive in the grant cycle itself -- m2_ddr3 spends a cycle in D_IDLE before
  // D_ISSUE -- so the old value of `owner` is never consulted for a live
  // transfer. The REQUEST-side muxes below still need the combinational choice,
  // because they must present the new master's address in that grant cycle.
  wire sel_b = owner;

  assign a_wnext  = m_wnext  && !sel_b;
  assign a_wacc   = m_wacc   && !sel_b;
  assign a_rvalid = m_rvalid && !sel_b;
  assign a_ack    = m_ack    && !sel_b;
  assign b_wnext  = m_wnext  &&  sel_b;
  assign b_wacc   = m_wacc   &&  sel_b;
  assign b_rvalid = m_rvalid &&  sel_b;
  assign b_ack    = m_ack    &&  sel_b;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; owner <= 1'b0; cool <= 1'b0;
      dbg_a_waits <= '0; dbg_b_waits <= '0;
    end else begin
      cool <= 1'b0;
      // HOW THE GRANT RULE GOT HERE, because the history is the argument.
      //
      //   R360  busy <= !m_ack   guard against an ack in the grant cycle
      //   R364  busy <= 1'b1     guard removed as "impossible" -- s51/s52/s61 BLACK
      //   R367  busy <= !m_ack   guard restored on that board evidence
      //   R374  sel_b = owner    responses stop following `req`  -- WORSE: 1->0->0
      //   R375  busy <= 1'b1     paired with R374, which is the point
      //
      // R364 and R374 each changed ONE half of a pair and each made things
      // worse, which is why the evidence looked contradictory: with responses
      // routed by `req`, an unconditional grant loses acknowledges; with an
      // ack-conditional grant, routing by `owner` lets owner move under a live
      // transfer. Neither half is wrong. Neither half works alone.
      if (!busy) begin
        // R375: A GRANT ALWAYS BECOMES BUSY -- and this is only safe now that
        // R374 routes responses by `owner` rather than by `req`.
        //
        // R367 kept `busy <= !m_ack` to survive an acknowledge in the grant
        // cycle. The cost was a window where the arbiter GRANTS WITHOUT BECOMING
        // BUSY, and while busy is clear it can grant again the next cycle --
        // changing `owner` while a transfer is still live. With the old routing
        // the `a_req` fallback masked that by accident; with R374's
        // `sel_b = owner` a changed owner misroutes every response, and the
        // board showed it: acks 3 -> seen 2 -> lines 2 became 1 -> 0 -> 0.
        //
        // The two halves only work together. Busy set unconditionally means
        // owner cannot move mid-transaction; routing by owner means a master
        // that has stopped asking still receives its acknowledge. R364 tried
        // the first with the old routing and black-screened; R374 tried the
        // second with the old busy rule and wedged sooner. This is the pair.
        if (a_req)      begin owner <= 1'b0; busy <= 1'b1; end
        else if (b_ok)  begin owner <= 1'b1; busy <= 1'b1; end
      end else if (busy && m_ack) begin
        busy <= 1'b0;
        cool <= 1'b1;
      end

      // R372: THE R369 WATCHDOG IS REMOVED. IT RELEASED THE ARBITER WITHOUT
      // TELLING THE MASTER, AND THAT IS NOT A SAFE THING TO DO.
      //
      // It fired after 8,191 cycles with no beat and no acknowledge, on the
      // reasoning that the scanout must not be able to starve the fill -- which
      // is a real requirement and Ben's own point. But m2_ddr3 keeps driving
      // DDRAM_RD/WE from D_ISSUE until the bridge answers, and releasing the
      // grant does not reset it. At boot, before DDR3 calibration completes,
      // the first read can sit in D_ISSUE far longer than the timeout: the
      // watchdog then re-grants, beats and acknowledges route to whoever owns
      // the port now, and the bridge is left mid-transaction. A wedged bridge
      // at boot means the ROM download never finishes and the i960 never
      // starts -- black screen, which is what the board showed.
      //
      // s93, without it, ran 2D and completed lines. s113, with it, came up
      // black on the best timing of the day (every core clock POSITIVE). The
      // bracketing is not proof, but the mechanism is concrete and the guard
      // was never justified by a measurement in the first place.
      //
      // A SAFE VERSION WOULD HAVE TO RESET THE MASTER TOO, or only fire when
      // the master is known idle -- which means m2_ddr3 must report its state
      // to the arbiter. That is a design, not a timeout, and it belongs after
      // the handshake it is meant to backstop actually works.
      //
      // TWICE TODAY A GUARD ADDED ON REASONING RATHER THAN MEASUREMENT MADE
      // THINGS WORSE (R364 removed one that was load-bearing; R369 added one
      // that was harmful). The rule earned: while a system is under diagnosis,
      // change what the evidence names and nothing else.

      // What the priority actually costs the loser, and what it saves the
      // winner. If the reader ever waits at all, the burst-per-line argument
      // above is not holding and wants re-checking on the board.
      if (a_req && (busy && owner) && !(&dbg_a_waits)) dbg_a_waits <= dbg_a_waits + 32'd1;
      if (b_req && ((busy && !owner) || (!busy && a_req)) && !(&dbg_b_waits))
        dbg_b_waits <= dbg_b_waits + 32'd1;
    end
  end

endmodule
