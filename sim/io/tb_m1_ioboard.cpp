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
// I/O board handshake responder.
//
// MAME runs the 315-5338A as a real Z80 and this module is not that chip, so it
// cannot be diffed instruction for instruction — but the *protocol* is fully
// measurable through it, and now is. tools/mame_iohandshake.lua and
// tools/mame_flag_state.lua establish:
//
//   * the flag is answered ONCE, 38,577 us after the V60 raises it, which is
//     740,684 cycles of this module's 19.2 MHz domain;
//   * after boot the V60 re-raises it once a frame and the Z80 NEVER clears it
//     again — set in 1,194 of 1,200 frames sampled, clear only during boot.
//
// So the tests below are written as the properties that protocol has to hold,
// and each names the failure it is aimed at, because three have happened for
// real:
//
//  * answering only the first request hangs boot at the second handshake,
//    which is what "match any non-zero write, not the literal 0x01" is for;
//  * answering a *read* of the flag as though it were a request would make the
//    V60's own polling look like an endless stream of new requests;
//  * answering EVERY request, at 64 cycles, cleared the doorbell once a frame
//    for a year. The V60 never reads it, so nothing on screen changed — but it
//    also made the instruction-trace diff report a false divergence at the boot
//    poll loop, which cost a session before it was measured.
//
// BUILT TWICE, at LATENCY 64 and at the real 740,684 — the same reason
// bw_monitor and m1_diag are. The narrow build cannot reach the 20-bit counter
// the real figure needs, and the wide one is the only one that can hold a
// reference-rate doorbell against a deadline that outlasts it. LATENCY_CFG must
// match the -GLATENCY the Makefile passes.
//
// The DPRAM has one physical write port shared with the V60, because Quartus
// will not infer a true dual-port M10K from that array — measured, it costs
// 16,384 flip-flops and reports success. So the responder holds io_we until
// io_ack, and the model below only accepts the byte on an acknowledged cycle.
// A test that ignored io_ack would pass against a responder that drops its
// write whenever the V60 is using the port.

#include "Vm1_ioboard.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

// Must equal the -GLATENCY this binary was built with. A mismatch would make
// every deadline check below test the wrong number and pass anyway.
#ifndef LATENCY_CFG
#define LATENCY_CFG 64
#endif
static const long LAT = LATENCY_CFG;

// The reference's doorbell period: 19.2 MHz / 57.5 Hz. Measured at pc=fe03fd,
// one write per frame, 1,794 of them in 1,800 frames.
static const long DOORBELL = 333913;

static long checks = 0, fails = 0;

static void check(bool ok, const char* what) {
  checks++;
  if (!ok) { fails++; printf("  FAIL %s\n", what); }
}

struct Dut {
  Vm1_ioboard* d;
  long cyc = 0;
  // Model of the DPRAM byte the responder writes, so the test observes what the
  // V60 would actually read back rather than trusting the port strobes.
  uint8_t flag = 0;

  Dut() {
    d = new Vm1_ioboard;
    d->clk = 0; d->rst_n = 0;
    d->v60_req = 0; d->v60_we = 0; d->v60_sel_dpram = 0;
    d->v60_addr = 0; d->v60_wdata = 0;
    d->io_ack = 0;
    d->eval();
    for (int i = 0; i < 4; i++) tick();
    d->rst_n = 1;
    tick();
  }
  ~Dut() { delete d; }

  // Stands in for m1_mainram's shared write port: the V60 wins, and the write
  // only lands on an acknowledged cycle.
  bool port_busy = false;

  void tick() {
    d->io_ack = (d->io_we && !port_busy) ? 1 : 0;
    d->eval();
    // The RAM samples its inputs on the edge, so the byte that lands is the one
    // presented *before* the clock — reading io_we afterwards sees it already
    // cleared by its own acknowledge and captures nothing.
    const bool     landing = d->io_we && d->io_ack;
    const uint16_t a       = d->io_addr;
    const uint8_t  din     = d->io_din;
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    if (landing && a == 0x020) flag = din;
    cyc++;
  }

  // One V60 bus beat.
  void bus(bool req, bool we, bool sel, uint16_t addr, uint8_t data) {
    d->v60_req = req; d->v60_we = we; d->v60_sel_dpram = sel;
    d->v60_addr = addr; d->v60_wdata = data;
    port_busy = req && we && sel;      // the V60 owns the port this cycle
    d->eval();
    tick();
    port_busy = false;
    d->v60_req = 0; d->v60_we = 0; d->v60_sel_dpram = 0;
    d->eval();
  }

  void idle(int n) { for (int i = 0; i < n; i++) tick(); }

  // The V60 writes the flag, then polls it. Returns cycles until it changed.
  long request_and_wait(uint8_t code, long limit = -1) {
    if (limit < 0) limit = LAT + 4000;
    flag = code;                       // the V60's own write lands in the RAM
    bus(1, 1, 1, 0x020, code);
    for (long i = 0; i < limit; i++) {
      if (flag != code) return i;
      tick();
    }
    return -1;
  }
};

// The handshake checks below assume the write port is idle between requests.
// With PUBLISH_INPUTS on it never is — the module refreshes the control bytes
// continuously — so this binary is built with publishing OFF and the publisher
// has its own build. Testing both through one binary would mean weakening the
// handshake assertions to accommodate traffic they are specifically about.
int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  printf("built with LATENCY=%ld (doorbell period %ld)\n", LAT, DOORBELL);

  // ------------------------------------------------- the handshake itself
  printf("test: a request is answered, and the flag ends up cleared\n");
  {
    Dut t;
    long n = t.request_and_wait(0x01);
    check(n >= 0, "first handshake was never answered");
    check(t.flag == 0x00, "flag was not cleared");
    check(t.d->replies == 1, "reply counter did not advance");
    // AT THE DEADLINE, NOT BEFORE. The old test only asked whether an answer
    // ever came, so it passed identically at 64 cycles and at the measured
    // 740,684 — it could not have caught the figure being a guess.
    check(n >= LAT - 8, "answered EARLY: the deadline is not being honoured");
    check(n <= LAT + 32, "answered late by more than the port arbitration costs");
    printf("  answered after %ld cycles (deadline %ld), flag=%02x\n", n, LAT, t.flag);
  }

  // The property that makes ONE number reproduce BOTH measured behaviours. If a
  // fresh request did not re-arm the deadline, the steady state below would be
  // impossible without a separate one-shot rule.
  printf("test: a fresh request re-arms the deadline\n");
  {
    Dut t;
    // Margins are a fraction of the deadline, not a constant: at LATENCY=64 a
    // 64-cycle margin overshoots the re-armed deadline and the test fails on a
    // correct module. It did.
    const long m = (LAT / 16 < 8) ? 8 : LAT / 16;
    t.flag = 0x01;
    t.bus(1, 1, 1, 0x020, 0x01);          // deadline at LAT
    t.idle(LAT / 2);
    check(t.flag == 0x01, "answered before the deadline");
    t.flag = 0x01;
    t.bus(1, 1, 1, 0x020, 0x01);          // re-raise: deadline moves to 1.5*LAT
    t.idle(LAT / 2 + m);                  // now past the FIRST deadline
    check(t.flag == 0x01, "the second request did not re-arm the deadline");
    t.idle(LAT / 2 + 2 * m);              // and past the SECOND
    check(t.flag == 0x00, "never answered after the re-armed deadline");
    printf("  deferred through the first deadline, answered after the second\n");
  }

  // THE MEASUREMENT, AS A TEST. The reference leaves the flag set forever once
  // the game is running, and this is why: the doorbell arrives faster than the
  // deadline, so the deadline never expires. It only holds when LATENCY exceeds
  // the doorbell period, which is exactly what the narrow build cannot reach —
  // and the narrow build asserts the opposite, so the difference is on record
  // rather than implied.
  printf("test: a reference-rate doorbell leaves the flag SET (or does not)\n");
  {
    Dut t;
    long cleared = 0;
    for (int frame = 0; frame < 8; frame++) {
      t.flag = 0x01;                      // the V60's own write lands first
      t.bus(1, 1, 1, 0x020, 0x01);
      t.idle(DOORBELL);
      if (t.flag == 0x00) cleared++;
    }
    if (LAT > DOORBELL) {
      check(cleared == 0, "the doorbell was answered: the flag did not stay set");
      check(t.d->replies == 0, "a reply was sent during the steady state");
      printf("  8 doorbells, 0 answered, flag stayed set — matches the reference\n");
    } else {
      check(cleared == 8, "a sub-doorbell latency should answer every doorbell");
      printf("  8 doorbells, %ld answered — the pre-measurement behaviour\n", cleared);
    }
  }

  // The one that hung boot: the second handshake carries a different code.
  printf("test: a second request with a different code is also answered\n");
  {
    Dut t;
    t.request_and_wait(0x01);
    long n = t.request_and_wait(0x5a);
    check(n >= 0, "second handshake with a different code was not answered");
    check(t.d->replies == 2, "second reply not counted");
    printf("  answered after %ld cycles\n", n);
  }

  // Skipped on the wide build: 255 deadlines of 740,684 cycles is 189M ticks and
  // the property under test — "any non-zero code counts" — has nothing to do
  // with the deadline's width. The narrow build covers it in milliseconds.
  printf("test: every non-zero code is a request, all 255 of them\n");
  if (LAT > DOORBELL) {
    printf("  skipped on the wide build (189M cycles, covered by the narrow one)\n");
  } else {
    Dut t;
    int answered = 0;
    for (int code = 1; code < 256; code++)
      if (t.request_and_wait((uint8_t)code) >= 0) answered++;
    check(answered == 255, "not every non-zero code was treated as a request");
    check(t.d->replies == 255, "reply count does not match");
    printf("  %d/255 answered\n", answered);
  }

  // ------------------------------------------------------- what must NOT fire
  printf("test: things that must not look like a request\n");
  {
    Dut t;
    long before = t.d->replies;

    t.bus(1, 0, 1, 0x020, 0x01);   // a READ of the flag — this is the poll
    t.idle(500);
    check(t.d->replies == before, "a read of the flag was answered as a request");

    t.bus(1, 1, 1, 0x020, 0x00);   // writing zero is not a request
    t.idle(500);
    check(t.d->replies == before, "a zero write was answered as a request");

    t.bus(1, 1, 1, 0x01a, 0x53);   // the "SEGA" block, a different address
    t.bus(1, 1, 1, 0x01b, 0x45);
    t.bus(1, 1, 1, 0x100, 0x53);   // the second block at 0x100
    t.idle(500);
    check(t.d->replies == before, "a write to another address was answered");

    t.bus(1, 1, 0, 0x020, 0x01);   // right address, but not the DPRAM select
    t.idle(500);
    check(t.d->replies == before, "a write outside the DPRAM was answered");

    t.bus(0, 1, 1, 0x020, 0x01);   // we without req is not a bus beat
    t.idle(500);
    check(t.d->replies == before, "a write without req was answered");
    printf("  five non-requests correctly ignored\n");
  }

  // ------------------------------------------------------------- turnaround
  printf("test: the answer is not instantaneous\n");
  {
    // A real Z80 takes time to notice a mailbox. More importantly, an answer in
    // the same cycle as the request would beat the V60's own write into the
    // RAM and be overwritten by it — the handshake would then never complete
    // even though the responder had "answered".
    // Qualified on the address, not merely on io_we: the port is shared with
    // the startup block push and the input sweep, so "is anything being
    // written" no longer answers the question this test is asking. What must
    // not happen early is a write to the FLAG.
    Dut t;
    t.bus(1, 1, 1, 0x020, 0x01);
    check(!(t.d->io_we && t.d->io_addr == 0x020),
          "answered in the same cycle as the request");
    t.idle(2);
    check(!(t.d->io_we && t.d->io_addr == 0x020),
          "answered before any turnaround delay");
    printf("  no reply for at least 3 cycles after the request\n");
  }

  // A request arriving while one is outstanding must restart, not be dropped.
  printf("test: a request during an outstanding one is not lost\n");
  {
    Dut t;
    t.flag = 0x01;
    t.bus(1, 1, 1, 0x020, 0x01);
    t.idle(4);
    t.flag = 0x02;
    t.bus(1, 1, 1, 0x020, 0x02);   // second request before the first answered
    long n = -1;
    for (long i = 0; i < LAT + 4000; i++) {   // bound scales with the deadline
      if (t.flag != 0x02) { n = i; break; }
      t.tick();
    }
    check(n >= 0, "a request arriving during an outstanding one was lost");
    printf("  answered after %ld cycles\n", n);
  }

  // --------------------------------------------------------------- reset
  printf("test: a busy write port delays the answer, it does not lose it\n");
  {
    Dut t;
    t.flag = 0x01;
    t.bus(1, 1, 1, 0x020, 0x01);
    // THE PORT HAS TO BE BUSY ACROSS THE DEADLINE, not merely for a while after
    // the request. Holding it for a fixed 400 cycles tested nothing once the
    // deadline became 740,684: the reply was not due yet, io_we was low, and the
    // test failed against a module that was behaving correctly.
    const long pre = (LAT > 200) ? LAT - 100 : 0;
    t.idle(pre);
    t.port_busy = true;
    for (int i = 0; i < 400; i++) t.tick();     // the deadline passes in here
    check(t.flag == 0x01, "answered while the write port was held busy");
    check(t.d->io_we == 1, "responder dropped its write instead of holding it");
    t.port_busy = false;
    long n = -1;
    for (long i = 0; i < 100; i++) { t.tick(); if (t.flag != 0x01) { n = i; break; } }
    check(n >= 0, "write never landed after the port was released");
    check(t.d->replies == 1, "reply counted without the byte reaching the RAM");
    printf("  held busy across the deadline, landed %ld cycles after release\n", n);
  }

  printf("test: reset clears the pending state\n");
  {
    Dut t;
    t.bus(1, 1, 1, 0x020, 0x01);
    t.d->rst_n = 0; t.d->eval();
    t.idle(4);
    t.d->rst_n = 1; t.d->eval();
    t.flag = 0x01;
    t.idle(LAT + 3000);       // past the deadline, or the request is not proven dead
    check(t.flag == 0x01, "a request survived reset and was answered afterwards");
    check(t.d->replies == 0, "reply counter survived reset");
    printf("  pending request dropped by reset\n");
  }

  printf("m1_ioboard: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
