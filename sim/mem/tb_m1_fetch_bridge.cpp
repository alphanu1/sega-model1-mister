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
// V60 instruction-fetch bridge.
//
// The reference is trivial — a line read from a model memory, rotated down by
// the byte offset — so the value of this harness is entirely in modelling the
// two endpoints the way the real ones behave. Both are asymmetric, and getting
// either wrong makes a broken bridge look fine:
//
//  * the V60 holds if_req until if_ack and expects ack to STAY UP until it
//    drops the request. A one-cycle ack is invisible to a clock-enabled core,
//    which is the failure that has bitten this project twice and looked like a
//    dead CPU both times. So ack is checked for persistence, not just arrival.
//
//  * m1_sdram takes one transaction per p_req RISING edge and stretches its
//    ack. A held level is one job, so rising edges are counted and a second one
//    for the same fetch is a failure.
//
// The offset is captured with the request on purpose: the core is free to move
// if_addr once a fetch is answered, so a bridge that read the offset at
// completion time instead would rotate by the wrong amount. The random driver
// changes the offset input while a fetch is in flight to make that fail.

#include "Vm1_fetch_bridge.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <vector>

static long checks = 0, fails = 0, printed = 0;

struct Fetch {
  Vm1_fetch_bridge* d;
  std::vector<uint64_t> lines;
  int lat = 0, lat_cnt = 0;
  bool servicing = false;
  uint32_t svc_line = 0;
  int ack_hold = 0;
  bool p_req_d = false;
  long transactions = 0;

  Fetch() : lines(1u << 16, 0) {
    d = new Vm1_fetch_bridge;
    d->cpu_clk = 0; d->mem_clk = 0;
    d->cpu_rst_n = 0; d->mem_rst_n = 0;
    d->if_req = 0; d->if_off = 0; d->if_sdram_addr = 0;
    d->p_dout = 0; d->p_ack = 0;
    d->eval();
  }
  ~Fetch() { delete d; }

  void tick_mem() {
    bool rise = d->p_req && !p_req_d;
    p_req_d = d->p_req;

    if (rise) {
      transactions++;
      if (servicing) {
        checks++; fails++;
        if (printed++ < 20) printf("  FAIL a second memory request for one fetch\n");
      } else {
        servicing = true;
        lat_cnt = 0;
        svc_line = d->p_addr & 0xffff;
      }
    }

    if (servicing) {
      if (lat_cnt < lat) {
        lat_cnt++;
      } else if (!ack_hold) {
        d->p_dout = lines[svc_line];
        d->p_ack = 1;
        ack_hold = 2;                     // m1_sdram's ACK_HOLD
      }
    }
    if (ack_hold && --ack_hold == 0) { d->p_ack = 0; servicing = false; }

    d->eval();
    d->mem_clk = 1; d->eval();
    d->mem_clk = 0; d->eval();
  }

  void tick_cpu() {
    d->eval();
    d->cpu_clk = 1; d->eval();
    d->cpu_clk = 0; d->eval();
  }

  void reset() {
    for (int i = 0; i < 8; i++) { tick_cpu(); tick_mem(); }
    d->cpu_rst_n = 1; d->mem_rst_n = 1;
    for (int i = 0; i < 8; i++) { tick_cpu(); tick_mem(); }
  }
};

// One fetch, driven the way the V60 drives it: hold req, wait for ack, check
// that ack persists, then drop req and check it clears.
static bool do_fetch(Fetch& t, uint32_t line, uint8_t off, int mem_per_cpu,
                     std::mt19937& rng, bool jiggle_off) {
  const uint64_t expect = t.lines[line & 0xffff] >> (off * 8);
  long before = t.transactions;

  t.d->if_sdram_addr = line;
  t.d->if_off = off;
  t.d->if_req = 1;

  // One edge with the real offset presented, which is where the bridge captures
  // it. Jiggling before this would be testing that the bridge reads a value it
  // was never shown.
  t.tick_cpu();
  for (int i = 0; i < mem_per_cpu; i++) t.tick_mem();

  long guard = 0;
  while (!t.d->if_ack && ++guard < 20000) {
    // The core may move if_off while a fetch is outstanding; the bridge must
    // use the value captured with the request.
    if (jiggle_off) t.d->if_off = (uint8_t)(rng() & 7);
    t.tick_cpu();
    for (int i = 0; i < mem_per_cpu; i++) t.tick_mem();
  }

  checks++;
  if (!t.d->if_ack) {
    fails++;
    if (printed++ < 20) printf("  FAIL fetch of line %05x never acked\n", line);
    t.d->if_req = 0;
    return false;
  }

  checks++;
  if (t.d->if_data != expect) {
    fails++;
    if (printed++ < 20)
      printf("  FAIL line %05x off %u: got %016llx expected %016llx\n",
             line, off, (unsigned long long)t.d->if_data,
             (unsigned long long)expect);
  }

  // Ack must be held, not pulsed: a clock-enabled core can be several cycles
  // away from noticing it.
  for (int i = 0; i < 5; i++) {
    t.tick_cpu();
    for (int k = 0; k < mem_per_cpu; k++) t.tick_mem();
    checks++;
    if (!t.d->if_ack) {
      fails++;
      if (printed++ < 20) printf("  FAIL ack dropped while req was still held\n");
      break;
    }
    checks++;
    if (t.d->if_data != expect) {
      fails++;
      if (printed++ < 20) printf("  FAIL data changed while ack was held\n");
      break;
    }
  }

  checks++;
  // A CACHE HIT COSTS ZERO TRANSACTIONS, and that is the point of the cache.
  // This used to require exactly one memory transaction per fetch, which was
  // right when the bridge had no storage and is now the thing under test.
  // What must still hold is that a fetch never issues MORE than one.
  if (t.transactions > before + 1) {
    fails++;
    if (printed++ < 20)
      printf("  FAIL %ld memory transactions for one fetch\n",
             t.transactions - before);
  }

  // Dropping the request must clear the answer, or the next fetch starts life
  // already "complete".
  t.d->if_req = 0;
  guard = 0;
  while (t.d->if_ack && ++guard < 100) {
    t.tick_cpu();
    for (int i = 0; i < mem_per_cpu; i++) t.tick_mem();
  }
  checks++;
  if (t.d->if_ack) {
    fails++;
    if (printed++ < 20) printf("  FAIL ack did not clear after req dropped\n");
  }
  return true;
}

static void run(int mem_per_cpu, int lat, long n, bool jiggle, const char* what) {
  std::mt19937 rng(20260815u + (unsigned)(mem_per_cpu * 31 + lat));
  Fetch t;
  t.lat = lat;
  t.reset();
  for (auto& l : t.lines) l = ((uint64_t)rng() << 32) | rng();

  for (long i = 0; i < n; i++) {
    uint32_t line = rng() & 0xffff;
    uint8_t  off  = (uint8_t)(rng() & 7);
    if (!do_fetch(t, line, off, mem_per_cpu, rng, jiggle)) break;
  }
  printf("  %-26s %ld fetches, mem:cpu = %d:1, latency %d\n", what, n, mem_per_cpu, lat);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  printf("test: every byte offset, at the design clock ratio\n");
  {
    std::mt19937 rng(1u);
    Fetch t; t.lat = 3; t.reset();
    for (auto& l : t.lines) l = ((uint64_t)rng() << 32) | rng();
    for (uint8_t off = 0; off < 8; off++) do_fetch(t, 0x1234 + off, off, 4, rng, false);
    printf("  all 8 offsets rotated correctly\n");
  }

  printf("test: clock ratios\n");
  run(4, 0,  2000, false, "96/24 MHz");
  run(4, 8,  2000, false, "96/24 MHz, latency 8");
  run(4, 64, 500,  false, "96/24 MHz, latency 64");
  run(2, 3,  2000, false, "2:1");
  run(7, 5,  2000, false, "7:1, awkward");
  run(1, 2,  2000, false, "1:1");

  printf("test: the offset must be captured with the request\n");
  run(4, 12, 2000, true, "offset jiggled in flight");

  // THE CACHE ACTUALLY CACHES. Everything above proves the bridge still returns
  // the right bytes; none of it would fail if the cache never hit. Fetch one
  // line twice and require the second to cost no memory transaction at all.
  {
    Fetch t2;
    std::mt19937 rng2(20260820u);
    t2.lat = 4;
    t2.reset();
    for (auto& l : t2.lines) l = ((uint64_t)rng2() << 32) | rng2();
    do_fetch(t2, 0x2000, 0, 4, rng2, false);
    long before2 = t2.transactions;
    do_fetch(t2, 0x2000, 0, 4, rng2, false);
    checks++;
    if (t2.transactions != before2) {
      fails++;
      printf("  FAIL repeat fetch of a cached line cost %ld transactions\n",
             t2.transactions - before2);
    }
    // A different offset inside the SAME line must also hit: the line is cached
    // unrotated precisely so that works.
    long before3 = t2.transactions;
    do_fetch(t2, 0x2000, 5, 4, rng2, false);
    checks++;
    if (t2.transactions != before3) {
      fails++;
      printf("  FAIL same line at a new offset cost %ld transactions\n",
             t2.transactions - before3);
    }
  }

  printf("m1_fetch_bridge: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
