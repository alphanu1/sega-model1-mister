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
// The TMPZ84C015's CTC, as Wing War's I/O board firmware programs it.
//
// EPR-16891 does all of its work in CTC channel 1's interrupt handler, so the
// tick period and the daisy chain are what this checks, driven directly:
//
//   - the period in Z80 clocks for both prescalers and a sweep of time
//     constants, including 0 (= 256), an order of magnitude past the 38 the
//     firmware uses;
//   - the vector: channel 0's write sets bits 7:3, the channel goes in 2:1;
//   - a channel in service blocks itself and lower channels until RETI, and a
//     higher channel can still interrupt it;
//   - a pending request survives until acknowledged; disabling the interrupt
//     drops it; a software reset stops the count;
//   - the down-counter reads back.

#include "Vm1_ctc.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static long checks = 0, fails = 0;
static void chk(bool ok, const char* what) {
  checks++;
  if (!ok) { printf("  FAIL %s\n", what); fails++; }
}

struct Ctc {
  Vm1_ctc* d;
  Ctc() {
    d = new Vm1_ctc;
    d->clk = 0; d->rst_n = 0; d->cen = 0; d->wr = 0; d->ch = 0; d->wdata = 0;
    d->inta = 0; d->reti = 0;
    d->eval();
    for (int i = 0; i < 4; i++) tick();
    d->rst_n = 1;
    tick();
  }
  ~Ctc() { delete d; }
  void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
  // One Z80 clock: cen for one clk, then an idle clk so writes never share it.
  void zclk() { d->cen = 1; tick(); d->cen = 0; tick(); }
  void wr(int ch, uint8_t v) {
    d->ch = ch; d->wdata = v; d->wr = 1; tick(); d->wr = 0; tick();
  }
  uint8_t rd(int ch) { d->ch = ch; d->eval(); return d->rdata; }
  uint8_t ack() {
    uint8_t v = d->vector;
    d->inta = 1; tick(); d->inta = 0; tick();
    return v;
  }
  void reti() { d->reti = 1; tick(); d->reti = 0; tick(); }
  // Z80 clocks until int_req rises, or -1.
  long until_int(long limit) {
    for (long n = 1; n <= limit; n++) { zclk(); if (d->int_req) return n; }
    return -1;
  }
};

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  // ---- the firmware's own programming: vector E8h, ch1 = A5h, TC 26h.
  {
    Ctc c;
    c.wr(0, 0xE8);                     // channel 0 vector write
    c.wr(1, 0xA5);                     // int on, timer, /256, auto, TC follows
    chk(!c.d->int_req, "no request before the time constant");
    c.wr(1, 0x26);
    long n = c.until_int(100000);
    chk(n == 256 * 0x26, "first tick after 256*38 Z80 clocks");
    if (n != 256 * 0x26) printf("    got %ld\n", n);
    chk(c.d->vector == 0xEA, "channel 1 vector is EAh (table entry 08FDh)");
    uint8_t v = c.ack();
    chk(v == 0xEA, "acknowledge returns EAh");
    chk(!c.d->int_req, "request cleared by the acknowledge");
    // In service: the next tick is held until RETI.
    long m = c.until_int(256 * 0x26 + 10);
    chk(m == -1, "channel 1 in service blocks its own next tick");
    c.reti();
    chk(c.d->int_req, "the held tick is presented after RETI");
    c.ack(); c.reti();
    // Steady period: the counter free-runs regardless of the handshake.
    long p = c.until_int(100000);
    chk(p > 0 && p <= 256 * 0x26, "periodic tick");
  }

  // ---- period sweep: both prescalers, TCs 1..255 and 0 (= 256).
  {
    int tcs[] = {1, 2, 3, 15, 38, 100, 255, 0};
    for (int pre = 0; pre < 2; pre++)
      for (int t : tcs) {
        Ctc c;
        c.wr(2, pre ? 0xA5 : 0x85);
        c.wr(2, t);
        long want = (pre ? 256L : 16L) * (t == 0 ? 256 : t);
        long n1 = c.until_int(want * 2 + 10);
        c.ack(); c.reti();
        long n2 = c.until_int(want * 2 + 10);
        char msg[96];
        snprintf(msg, sizeof msg, "period presc=%d tc=%d: %ld then %ld, want %ld",
                 pre ? 256 : 16, t, n1, n2, want);
        chk(n1 == want, msg);
        // n2 is measured from after the ack/reti, which took no Z80 clocks.
        chk(n2 == want, msg);
      }
  }

  // ---- priority: channel 0 can interrupt channel 1's handler, not vice versa.
  {
    Ctc c;
    c.wr(0, 0xE8);
    c.wr(1, 0x85); c.wr(1, 1);         // ch1 every 16 clocks
    c.wr(0, 0x85); c.wr(0, 3);         // ch0 every 48 clocks
    c.until_int(100);
    chk(c.d->vector == 0xEA, "ch1 first");
    c.ack();                            // ch1 in service
    long n = c.until_int(100);
    chk(n > 0 && c.d->vector == 0xE8, "ch0 interrupts ch1's handler");
    c.ack();                            // ch0 in service too
    for (int i = 0; i < 100; i++) c.zclk();
    chk(!c.d->int_req, "nothing while ch0 is in service");
    c.reti();                           // ends ch0's handler
    chk(!c.d->int_req || c.d->vector == 0xE8,
        "after ch0's RETI only ch0 may ask (ch1 still in service)");
    if (c.d->int_req) { c.ack(); c.reti(); }
    c.reti();                           // ends ch1's handler
    long m = c.until_int(100);
    chk(m >= 0, "both channels free again");
  }

  // ---- disable drops a pending request; reset stops the count; readback.
  {
    Ctc c;
    c.wr(3, 0x85); c.wr(3, 10);
    c.until_int(1000);
    chk(c.d->int_req, "ch3 pending");
    c.wr(3, 0x05 & ~0x04);             // control word, interrupt off, no TC
    chk(!c.d->int_req, "interrupt disable drops the pending request");
    c.wr(3, 0x07); c.wr(3, 200);       // reset + TC follows: restart, no int
    for (int i = 0; i < 16 * 5; i++) c.zclk();
    chk(c.rd(3) == 195, "down-counter reads back");
    c.wr(3, 0x03);                     // software reset, no TC
    uint8_t a = c.rd(3);
    for (int i = 0; i < 16 * 20; i++) c.zclk();
    chk(c.rd(3) == a, "reset stops the count");
    // A trigger-started timer never starts: nothing drives CLK/TRG.
    c.wr(2, 0x8D); c.wr(2, 1);
    chk(c.until_int(1000) == -1, "trigger-started timer waits forever");
  }

  printf("m1_ctc: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
