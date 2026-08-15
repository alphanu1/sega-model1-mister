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
// bw_monitor lockstep harness.
//
// The reference counts the same events in C. That sounds circular for a block
// that is itself just counters, and it would be if the counters were the whole
// point — but two of them are not obvious:
//
//   wait   req && !grant, which a transactions-per-second counter cannot show
//   burst  longest run of consecutive grants, where the run in flight at snap
//          time is deliberately NOT counted
//
// and the snapshot must latch every counter on one edge, or a reader
// differencing two snapshots compares values from different cycles and the
// derived bandwidth is quietly wrong. That last property is the one worth
// testing, and it is the one a casual implementation gets wrong.

#include "Vbw_monitor.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <vector>

static const int M = 4;

// Must track the parameters the DUT was built with. The Makefile builds this
// harness twice: once at the real widths, and once deliberately narrow so the
// wrap and saturation paths are exercised — at 24 bits a 500 k-cycle run never
// wraps, so the default build alone would leave both untested.
#ifndef TB_CW
#define TB_CW 24
#endif
#ifndef TB_BW
#define TB_BW 8
#endif
static const uint64_t CMASK = (TB_CW >= 64) ? ~0ull : ((1ull << TB_CW) - 1);
static const uint64_t BMASK = (TB_BW >= 64) ? ~0ull : ((1ull << TB_BW) - 1);

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vbw_monitor;

  auto tick = [&]() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); };

  dut->rst_n = 0; dut->req = 0; dut->grant = 0; dut->snap = 0; dut->sel = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1;

  std::mt19937 rng(20260814u);
  std::uniform_int_distribution<uint32_t> dist(0, 0xffffffffu);

  // Reference state.
  std::vector<uint64_t> c_req(M,0), c_grant(M,0), c_wait(M,0), c_bmax(M,0), c_brun(M,0);
  std::vector<uint64_t> s_req(M,0), s_grant(M,0), s_wait(M,0), s_bmax(M,0);
  uint64_t c_total = 0, s_total = 0;
  std::vector<uint32_t> prev_bmax(M, 0);
  long nonmono = 0;

  const long N = 500000;
  long checked = 0, fails = 0;
  long snaps = 0, starved = 0, bursts = 0, wrapped = 0, saturated = 0;

  // Sustained-grant state. Purely random per-cycle grants produce runs of 3-4
  // and nothing longer, so burst_max was only ever being checked at trivial
  // values and the saturation path was unreachable. A real controller holds a
  // master granted for a whole burst, so the stimulus models that: with low
  // probability one master enters a run of up to 40 held cycles.
  int burst_m = -1, burst_left = 0;

  for (long n = 0; n < N; n++) {
    uint32_t r = dist(rng) & 0xf;
    // Grant is a subset of req, as a real arbiter guarantees. Occasionally
    // violate that to prove wait cannot go negative or wrap.
    uint32_t g = r & dist(rng);
    if ((dist(rng) & 63) == 0) g = dist(rng) & 0xf;   // illegal grant, on purpose

    if (burst_left == 0 && (dist(rng) & 255) == 0) {
      burst_m = dist(rng) & 3;
      burst_left = 1 + (dist(rng) % 40);
    }
    if (burst_left > 0) {
      r |= (1u << burst_m);          // a granted master is asking
      g |= (1u << burst_m);
      burst_left--;
    }

    bool sn = (dist(rng) & 127) == 0;

    dut->req = r; dut->grant = g; dut->snap = sn;
    tick();

    // Snapshot BEFORE the increments. Every RHS in the DUT's always_ff reads
    // pre-edge values, so `s_total <= c_total` latches the count as it was
    // entering this cycle, not including this cycle's own tick. Incrementing
    // first in the reference makes every snapshot read one high — which is
    // exactly what the first run showed, total 158 against 159.
    if (sn) {
      for (int m = 0; m < M; m++) {
        s_req[m]=c_req[m]; s_grant[m]=c_grant[m];
        s_wait[m]=c_wait[m]; s_bmax[m]=c_bmax[m];
      }
      s_total = c_total; snaps++;
    }

    // Reference advances identically. Rate counters wrap — that is the
    // contract, since the reader differences two snapshots and unsigned
    // subtraction gives the right delta across one wrap.
    if (c_total == CMASK) wrapped++;
    c_total = (c_total + 1) & CMASK;
    for (int m = 0; m < M; m++) {
      bool rq = (r >> m) & 1, gr = (g >> m) & 1;
      if (rq) c_req[m]   = (c_req[m]   + 1) & CMASK;
      if (gr) c_grant[m] = (c_grant[m] + 1) & CMASK;
      if (rq && !gr) { c_wait[m] = (c_wait[m] + 1) & CMASK; starved++; }
      // Burst counters saturate instead. A wrapped maximum reads as a small
      // number and would be misread as short bursts, which is the opposite of
      // what it means.
      // Burst counters wrap like the others, but burst_max is monotonic —
      // it only ever takes a strictly greater value — so all-ones is an
      // absorbing state and reads as overflow rather than as a short burst.
      if (gr) {
        if (c_bmax[m] == BMASK) saturated++;
        c_brun[m] = (c_brun[m] + 1) & BMASK;
        if (c_brun[m] > c_bmax[m]) { c_bmax[m] = c_brun[m]; bursts++; }
      } else c_brun[m] = 0;
    }
    // Compare the readback for every master each cycle.
    for (int m = 0; m < M; m++) {
      dut->sel = m; dut->eval();
      checked++;
      bool bad = false;
      if (dut->req_count    != (uint32_t)s_req[m])   bad = true;
      if (dut->grant_count  != (uint32_t)s_grant[m]) bad = true;
      if (dut->wait_count   != (uint32_t)s_wait[m])  bad = true;
      if (dut->burst_max    != (uint32_t)s_bmax[m])  bad = true;
      // Monotonicity is checked directly rather than left to the reference.
      // It is the property the reader depends on to interpret an all-ones
      // burst_max as overflow, and a reference bug could mask its loss.
      if (dut->burst_max < prev_bmax[m]) { bad = true; nonmono++; }
      prev_bmax[m] = dut->burst_max;
      if (dut->total_cycles != (uint32_t)s_total)    bad = true;
      if (bad) {
        if (fails < 10)
          printf("MISMATCH n=%ld m=%d  req %u/%llu  grant %u/%llu  wait %u/%llu"
                 "  bmax %u/%llu  total %u/%llu\n", n, m,
                 (unsigned)dut->req_count,   (unsigned long long)s_req[m],
                 (unsigned)dut->grant_count, (unsigned long long)s_grant[m],
                 (unsigned)dut->wait_count,  (unsigned long long)s_wait[m],
                 (unsigned)dut->burst_max,   (unsigned long long)s_bmax[m],
                 (unsigned)dut->total_cycles,(unsigned long long)s_total);
        fails++;
      }
    }
  }

  int uncovered = 0;
  if (!snaps)   { printf("NO COVERAGE for snap\n");       uncovered++; }
  if (!starved) { printf("NO COVERAGE for wait\n");       uncovered++; }
  if (!bursts)  { printf("NO COVERAGE for burst_max\n");  uncovered++; }
  // Only demanded where the run can actually reach them. At the real widths a
  // 500 k-cycle run cannot wrap a 24-bit counter, and requiring it here would
  // be a test that can only be satisfied by lying about the widths.
  if ((uint64_t)N > CMASK && !wrapped)   { printf("NO COVERAGE for wrap\n");       uncovered++; }
  if (BMASK < 16 && !saturated)          { printf("NO COVERAGE for saturation\n"); uncovered++; }
  if (nonmono) { printf("burst_max DECREASED %ld times\n", nonmono); }

  printf("bw_monitor[cw=%d,bw=%d]: checked=%ld skipped=0 fails=%ld uncovered=%d"
         " snaps=%ld wraps=%ld sat=%ld\n",
         TB_CW, TB_BW, checked, fails, uncovered, snaps, wrapped, saturated);
  delete dut;
  return (fails || uncovered) ? 1 : 0;
}
