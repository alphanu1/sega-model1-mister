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
// There is no MAME oracle for this one. MAME runs the 315-5338A as a real Z80
// and this module is not that chip, so the reference here is the *protocol* the
// boot trace established, and the tests are written as the properties that
// protocol has to hold. Each one names the failure it is aimed at, because two
// of them have already happened for real:
//
//  * answering only the first request hangs boot at the second handshake,
//    which is what "match any non-zero write, not the literal 0x01" is for;
//  * answering a *read* of the flag as though it were a request would make the
//    V60's own polling look like an endless stream of new requests.
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
  long request_and_wait(uint8_t code, long limit = 4000) {
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

  // ------------------------------------------------- the handshake itself
  printf("test: a request is answered, and the flag ends up cleared\n");
  {
    Dut t;
    long n = t.request_and_wait(0x01);
    check(n >= 0, "first handshake was never answered");
    check(t.flag == 0x00, "flag was not cleared");
    check(t.d->replies == 1, "reply counter did not advance");
    printf("  answered after %ld cycles, flag=%02x\n", n, t.flag);
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

  printf("test: every non-zero code is a request, all 255 of them\n");
  {
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
    Dut t;
    t.bus(1, 1, 1, 0x020, 0x01);
    check(t.d->io_we == 0, "answered in the same cycle as the request");
    t.idle(2);
    check(t.d->io_we == 0, "answered before any turnaround delay");
    printf("  no write for at least 3 cycles after the request\n");
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
    for (long i = 0; i < 4000; i++) {
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
    // Hold the port for far longer than the turnaround, as if the V60 were
    // hammering the DPRAM, then release it.
    t.port_busy = true;
    for (int i = 0; i < 400; i++) t.tick();
    check(t.flag == 0x01, "answered while the write port was held busy");
    check(t.d->io_we == 1, "responder dropped its write instead of holding it");
    t.port_busy = false;
    long n = -1;
    for (long i = 0; i < 100; i++) { t.tick(); if (t.flag != 0x01) { n = i; break; } }
    check(n >= 0, "write never landed after the port was released");
    check(t.d->replies == 1, "reply counted without the byte reaching the RAM");
    printf("  held for 400 cycles, landed %ld cycles after release\n", n);
  }

  printf("test: reset clears the pending state\n");
  {
    Dut t;
    t.bus(1, 1, 1, 0x020, 0x01);
    t.d->rst_n = 0; t.d->eval();
    t.idle(4);
    t.d->rst_n = 1; t.d->eval();
    t.flag = 0x01;
    t.idle(3000);
    check(t.flag == 0x01, "a request survived reset and was answered afterwards");
    check(t.d->replies == 0, "reply counter survived reset");
    printf("  pending request dropped by reset\n");
  }

  printf("m1_ioboard: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
