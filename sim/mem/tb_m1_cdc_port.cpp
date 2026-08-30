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
// Clock-domain bridge for one memory port.
//
// The two clocks are driven from an event scheduler rather than a fixed ratio,
// because the failure this is really aimed at is a transaction lost or
// duplicated at some *particular* phase relationship. A 4:1 ratio tested on its
// own proves very little: the interesting cases are the ratios where a toggle
// edge lands next to the sampling edge, so the ratios below are deliberately
// awkward (7:2, 13:4) as well as the ones the core will actually use.
//
// Both endpoints are modelled the way the real ones behave, and getting either
// wrong would make this test pass against a broken bridge:
//
//  * the requester pulses req for ONE cycle and latches read data on the ack
//    RISING edge, which is what m1_main does;
//  * the memory services one transaction per req RISING edge and stretches ack,
//    which is what m1_sdram does. A level held high must be serviced once.
//
// Every transaction carries a distinct value, so a duplicate or a dropped
// completion shows up as wrong data rather than as a count that still adds up.

#include "Vm1_cdc_port.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <vector>

static long checks = 0, fails = 0, printed = 0;

struct Bridge {
  Vm1_cdc_port* d;
  // Fast-side memory model.
  std::vector<uint16_t> mem;
  int  lat = 0;              // cycles of service latency
  int  lat_cnt = 0;
  bool servicing = false;
  uint32_t svc_addr = 0;
  bool svc_we = false;
  uint16_t svc_din = 0;
  uint8_t  svc_be = 0;
  int  ack_hold = 0;
  long b_transactions = 0;   // one per accepted memory-side request
  int  force_ack = 0;        // inject a spurious ack with nothing outstanding

  // Slow-side driver state.
  bool outstanding = false;
  uint32_t exp_addr = 0;
  uint16_t exp_data = 0;
  bool exp_we = false;

  long done = 0;

  Bridge() : mem(1u << 16, 0) {
    d = new Vm1_cdc_port;
    d->a_clk = 0; d->b_clk = 0;
    d->a_rst_n = 0; d->b_rst_n = 0;
    d->a_req = 0; d->a_we = 0; d->a_addr = 0; d->a_din = 0; d->a_be = 3;
    d->b_dout = 0; d->b_ack = 0;
    d->eval();
  }
  ~Bridge() { delete d; }

  // One fast-domain edge, with the memory model attached.
  void tick_b() {
    // Request is taken on the rising edge of b_req; a held level is one job.
    bool req_rise = d->b_req && !b_req_d;
    b_req_d = d->b_req;

    if (req_rise) b_transactions++;

    if (force_ack) {
      d->b_ack = 1;
      if (--force_ack == 0) d->b_ack = 0;
      d->eval();
      d->b_clk = 1; d->eval();
      d->b_clk = 0; d->eval();
      return;
    }

    if (req_rise && !servicing) {
      servicing = true;
      lat_cnt = 0;
      svc_addr = d->b_addr & 0xffff;
      svc_we = d->b_we;
      svc_din = d->b_din;
      svc_be = d->b_be;
    } else if (req_rise && servicing) {
      // The bridge must never issue a second request while one is in flight.
      checks++; fails++;
      if (printed++ < 20) printf("  FAIL overlapping request on the memory side\n");
    }

    if (servicing) {
      if (lat_cnt < lat) {
        lat_cnt++;
      } else if (!ack_hold) {
        if (svc_we) {
          uint16_t old = mem[svc_addr];
          uint16_t nw  = svc_din;
          if (!(svc_be & 1)) nw = (uint16_t)((nw & 0xff00) | (old & 0x00ff));
          if (!(svc_be & 2)) nw = (uint16_t)((nw & 0x00ff) | (old & 0xff00));
          mem[svc_addr] = nw;
        }
        d->b_dout = mem[svc_addr];
        d->b_ack = 1;
        ack_hold = 2;                 // m1_sdram's ACK_HOLD
      }
    }
    if (ack_hold) {
      if (--ack_hold == 0) { d->b_ack = 0; servicing = false; }
    }

    d->eval();
    d->b_clk = 1; d->eval();
    d->b_clk = 0; d->eval();
  }

  bool b_req_d = false;

  void tick_a() {
    d->eval();
    d->a_clk = 1; d->eval();
    // The requester latches on the ack rising edge.
    if (d->a_ack) {
      if (outstanding) {
        if (!exp_we) {
          checks++;
          if (d->a_dout != exp_data) {
            fails++;
            if (printed++ < 20)
              printf("  FAIL addr %04x read %04x, expected %04x\n",
                     exp_addr, d->a_dout, exp_data);
          }
        }
        outstanding = false;
        done++;
      } else {
        checks++; fails++;
        if (printed++ < 20) printf("  FAIL ack with no request outstanding\n");
      }
    }
    d->a_clk = 0; d->eval();
    d->a_req = 0;                     // req is a one-cycle pulse
    d->eval();
  }

  void reset() {
    for (int i = 0; i < 8; i++) { tick_a(); tick_b(); }
    d->a_rst_n = 1; d->b_rst_n = 1;
    for (int i = 0; i < 8; i++) { tick_a(); tick_b(); }
  }
};

// Runs `n` transactions with the two clocks interleaved at num:den.
static void run_ratio(int b_num, int a_den, int lat, long n, const char* what) {
  std::mt19937 rng(20260815u + (unsigned)(b_num * 100 + a_den));
  Bridge t;
  t.lat = lat;
  t.reset();
  for (auto& m : t.mem) m = (uint16_t)rng();

  long issued = 0;
  long acc_b = 0;
  long guard = 0;

  // A stalled bridge must FAIL, not hang. The bound is generous against the
  // slowest ratio and the longest service latency tested here, and far below
  // the point where waiting tells you anything you did not already know.
  const long limit = n * 200L + 100000L;
  while (t.done < n && ++guard < limit) {
    // Fast domain runs b_num edges for every a_den slow edges.
    acc_b += b_num;
    while (acc_b >= a_den) { acc_b -= a_den; t.tick_b(); }

    if (!t.outstanding && !t.d->a_busy && issued < n) {
      uint32_t a = rng() & 0xffff;
      bool we = (rng() & 3) == 0;
      uint16_t v = (uint16_t)rng();
      uint8_t be = (uint8_t)(1 + (rng() % 3));
      t.d->a_req = 1; t.d->a_we = we; t.d->a_addr = a;
      t.d->a_din = v; t.d->a_be = be;
      t.exp_addr = a; t.exp_we = we;
      if (we) {
        uint16_t old = t.mem[a], nw = v;
        if (!(be & 1)) nw = (uint16_t)((nw & 0xff00) | (old & 0x00ff));
        if (!(be & 2)) nw = (uint16_t)((nw & 0x00ff) | (old & 0xff00));
        t.exp_data = nw;
      } else {
        t.exp_data = t.mem[a];
      }
      t.outstanding = true;
      issued++;
    }
    t.tick_a();
  }

  checks++;
  if (t.done != n) {
    fails++;
    printf("  FAIL %s: only %ld of %ld transactions completed\n", what, t.done, n);
  } else {
    printf("  %-22s %ld transactions, b:a = %d:%d, service latency %d\n",
           what, t.done, b_num, a_den, lat);
  }
}

// Two properties the random driver structurally cannot reach, both of which
// survived mutation until these were written: the busy guard on the requester
// side and the pending guard on the memory side were dead code as far as the
// test was concerned.
static void run_directed() {
  printf("test: a second request while one is in flight is ignored, not queued\n");
  {
    Bridge t; t.lat = 4; t.reset();
    for (size_t i = 0; i < t.mem.size(); i++) t.mem[i] = (uint16_t)(i * 7 + 1);

    t.d->a_req = 1; t.d->a_we = 0; t.d->a_addr = 0x1234; t.d->a_be = 3;
    t.exp_addr = 0x1234; t.exp_we = false; t.exp_data = t.mem[0x1234];
    t.outstanding = true;
    t.tick_a();
    long before = t.b_transactions;

    // Bang on the request line mid-flight with a different address, but ONLY
    // while the bridge reports busy — a request issued after the completion is
    // a legitimate new transaction, and asserting past that point tests nothing
    // except the testbench's own bookkeeping.
    long guard = 0;
    while (t.outstanding && ++guard < 10000) {
      if (t.d->a_busy) {
        t.d->a_req = 1; t.d->a_addr = 0x4321; t.d->a_din = 0xbeef; t.d->a_we = 1;
      }
      t.tick_a();
      t.tick_b(); t.tick_b(); t.tick_b(); t.tick_b();
    }

    checks++;
    if (t.outstanding) { fails++; printf("  FAIL the first transaction never completed\n"); }
    checks++;
    if (t.b_transactions != before + 1) {
      fails++;
      printf("  FAIL %ld memory transactions for one request (expected 1)\n",
             t.b_transactions - before);
    }
    checks++;
    if (t.mem[0x4321] == 0xbeef) {
      fails++;
      printf("  FAIL the ignored request was executed anyway\n");
    }
    printf("  one request served once, the mid-flight requests dropped\n");
  }

  printf("test: a LEVEL requester that changes address the cycle after the ack gets the NEW word\n");
  {
    // THE COPROCESSOR'S REQUESTER IS A LEVEL, NOT A PULSE. mb86233_core holds
    // io_rd through m1_tgp -> m1_integrated -> this port's a_req until io_ack,
    // sees the ack during the ack cycle with its OLD address still on the bus,
    // and presents the next read the cycle after. Two back-to-back io reads
    // (microcode 0370 `mov $0x22 (e)` then 0371 `mov $0x21 (e)`) are exactly
    // that sequence.
    //
    // The port used to accept on `a_req && !a_busy`, and a_busy clears on the
    // edge that raises a_ack - so on the ack+1 edge the held level was
    // re-accepted WITH THE OLD ADDRESS, a duplicate transaction ran, the real
    // next request was ignored as busy, and the duplicate's ack arrived with
    // the old data as though it were the new read's. Measured 2026-08-30 as
    // the sincos unit returning table entry 0x131 for a read whose index was
    // 0x3ecf, 249 events into an otherwise identical stream, and from there
    // every coprocessor answer that touched sincos.
    //
    // tick_a() drops a_req at the end of every tick, so the level is
    // re-asserted before each one. tb_m1_cdc_port's other requesters are
    // pulses; this is the only test that holds the line.
    Bridge t; t.lat = 4; t.reset();
    for (size_t i = 0; i < t.mem.size(); i++) t.mem[i] = (uint16_t)(i * 7 + 1);
    long before = t.b_transactions;

    // First read: address A, held as a level until the ack.
    t.exp_addr = 0x0131; t.exp_we = false; t.exp_data = t.mem[0x0131];
    t.outstanding = true;
    long guard = 0;
    while (t.outstanding && ++guard < 10000) {
      t.d->a_req = 1; t.d->a_we = 0; t.d->a_addr = 0x0131; t.d->a_be = 3;
      t.tick_a();
      t.tick_b(); t.tick_b(); t.tick_b(); t.tick_b();
    }
    checks++;
    if (t.outstanding) { fails++; printf("  FAIL the first read never completed\n"); }

    // The ack was seen on that last tick. THE REAL CORE STILL PRESENTS A ON
    // THE NEXT EDGE: it sees io_ack during the ack cycle, its state advances at
    // the end of it, and the address follows the state - so address B is on
    // the bus only from the edge after that. A bench that switches to B in
    // zero time is faster than the hardware and does not reproduce the
    // hazard; the first version of this test did exactly that and passed on
    // the broken port. One tick with A held, then B.
    t.d->a_req = 1; t.d->a_we = 0; t.d->a_addr = 0x0131; t.d->a_be = 3;
    t.tick_a();
    t.tick_b(); t.tick_b(); t.tick_b(); t.tick_b();

    t.exp_addr = 0x3ecf; t.exp_data = t.mem[0x3ecf];
    t.outstanding = true;
    guard = 0;
    while (t.outstanding && ++guard < 10000) {
      t.d->a_req = 1; t.d->a_we = 0; t.d->a_addr = 0x3ecf; t.d->a_be = 3;
      t.tick_a();                     // tick_a checks a_dout against exp_data
      t.tick_b(); t.tick_b(); t.tick_b(); t.tick_b();
    }
    checks++;
    if (t.outstanding) { fails++; printf("  FAIL the second read never completed\n"); }
    checks++;
    if (t.b_transactions != before + 2) {
      fails++;
      printf("  FAIL %ld memory transactions for two reads (expected 2: a duplicate ran)\n",
             t.b_transactions - before);
    }
    t.d->a_req = 0;
    for (int i = 0; i < 8; i++) { t.tick_a(); t.tick_b(); t.tick_b(); t.tick_b(); t.tick_b(); }
    printf("  two back-to-back level reads, two transactions, the second returned its own word\n");
  }

  printf("test: a spurious ack with nothing outstanding is ignored\n");
  {
    Bridge t; t.lat = 0; t.reset();
    t.force_ack = 3;
    for (int i = 0; i < 40; i++) { t.tick_b(); t.tick_a(); }
    checks++;
    if (t.d->a_busy) { fails++; printf("  FAIL bridge went busy on a spurious ack\n"); }

    // And it must still work afterwards.
    t.force_ack = 0; t.d->b_ack = 0;
    for (size_t i = 0; i < t.mem.size(); i++) t.mem[i] = (uint16_t)(i ^ 0x5a5a);
    t.d->a_req = 1; t.d->a_we = 0; t.d->a_addr = 0x0777; t.d->a_be = 3;
    t.exp_addr = 0x0777; t.exp_we = false; t.exp_data = t.mem[0x0777];
    t.outstanding = true;
    long guard = 0;
    t.tick_a();
    while (t.outstanding && ++guard < 10000) { t.tick_b(); t.tick_a(); }
    checks++;
    if (t.outstanding) { fails++; printf("  FAIL bridge did not recover after a spurious ack\n"); }
    printf("  spurious ack ignored, next transaction still correct\n");
  }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  run_directed();

  printf("test: the ratios the core will actually use\n");
  run_ratio(4, 1, 0,  20000, "96/24 MHz");
  run_ratio(4, 1, 6,  20000, "96/24 MHz, latency");
  run_ratio(2, 1, 3,  20000, "2:1");

  // The point of these is phase, not speed: a toggle edge landing next to the
  // sampling edge is what a fixed pretty ratio never exercises.
  printf("test: awkward ratios\n");
  run_ratio(7, 2, 0,  20000, "7:2");
  run_ratio(13, 4, 5, 20000, "13:4");
  run_ratio(9, 7, 2,  20000, "9:7, barely faster");

  // The bridge is not specified to need b faster than a; if that ever changes
  // the design should still be correct rather than accidentally dependent on it.
  printf("test: the slow side faster than the fast side\n");
  run_ratio(1, 3, 0,  20000, "1:3, inverted");

  printf("test: long run at the design ratio\n");
  run_ratio(4, 1, 8, 200000, "96/24 MHz, long");

  printf("m1_cdc_port: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
