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
// SDRAM controller verification.
//
// Two things are being checked at once, and they catch different faults:
//
//   DATA    every read returns what was written to that address, through a
//           shadow memory in C++. Catches address decode, burst ordering,
//           byte enables, and delivering one master's data to another.
//
//   TIMING  the device model counts zero protocol violations for the whole
//           run. Catches the failures that simulate perfectly and then eat a
//           real SDRAM stick — tRP, tRCD, refresh interval, activating an
//           already-open row.
//
// All five masters run concurrently with transactions genuinely in flight at
// the same time. Driving one port at a time would exercise the state machine
// but not the arbiter, and the arbiter is where the interesting bugs are: a
// controller that delivers p2's data to p1 passes every single-port test.

#include "Vm1_sdram_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <map>
#include <random>
#include <vector>

static const int NP = 5;

// Burst length per port, mirroring blen() in m1_sdram.sv.
static int burst_of(int p) { return (p == 1 || p == 2) ? 4 : 1; }

struct Harness {
  Vm1_sdram_harness* d;
  long cyc = 0;
  std::map<uint32_t, uint16_t> shadow;   // word address -> data

  // Per-port transaction state.
  struct Port {
    bool     busy = false;
    bool     req_held = false;
    uint32_t addr = 0;
    int      words = 1;
    bool     write = false;
    uint16_t wdata = 0;
    uint8_t  be = 3;
    bool     ack_prev = false;
    long     issued_at = 0;
    long     n_done = 0;
  } port[NP];

  bool wr_busy = false, wr_req_held = false, wr_ack_prev = false;
  uint32_t wr_addr = 0;
  uint16_t wr_data = 0;

  long fails = 0, checks = 0, max_latency = 0;

  Harness() {
    d = new Vm1_sdram_harness;
    d->clk = 0; d->rst_n = 0;
    d->wr_req = 0; d->wr_addr = 0; d->wr_din = 0; d->wr_be = 3;
    d->p0_req = d->p1_req = d->p2_req = d->p3_req = d->p4_req = 0;
    d->p0_we = 0; d->p0_din = 0; d->p0_be = 3;
    d->p0_addr = d->p1_addr = d->p2_addr = d->p3_addr = d->p4_addr = 0;
    d->mon_sel = 0; d->mon_snap = 0;
    d->eval();
  }
  ~Harness() { delete d; }

  void setReq(int p, int v) {
    switch (p) {
      case 0: d->p0_req = v; break; case 1: d->p1_req = v; break;
      case 2: d->p2_req = v; break; case 3: d->p3_req = v; break;
      default: d->p4_req = v; break;
    }
  }
  void setAddr(int p, uint32_t a) {
    switch (p) {
      case 0: d->p0_addr = a; break; case 1: d->p1_addr = a; break;
      case 2: d->p2_addr = a; break; case 3: d->p3_addr = a; break;
      default: d->p4_addr = a; break;
    }
  }
  bool getAck(int p) {
    switch (p) {
      case 0: return d->p0_ack; case 1: return d->p1_ack;
      case 2: return d->p2_ack; case 3: return d->p3_ack;
      default: return d->p4_ack;
    }
  }
  uint64_t getDout(int p) {
    switch (p) {
      case 0: return d->p0_dout; case 1: return d->p1_dout;
      case 2: return d->p2_dout; case 3: return d->p3_dout;
      default: return d->p4_dout;
    }
  }

  void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); cyc++; }

  void reset() {
    d->rst_n = 0;
    for (int i = 0; i < 8; i++) tick();
    d->rst_n = 1;
    // Bring-up runs the JEDEC sequence; nothing may be issued until ready.
    long guard = 0;
    while (!d->ready && guard++ < 20000) tick();
    if (!d->ready) { printf("  FAIL controller never asserted ready\n"); fails++; }
  }

  // Advance one cycle, servicing whatever completed.
  void step() {
    tick();
    for (int p = 0; p < NP; p++) {
      // Requests are latched on the rising edge, so drop req the cycle after
      // asserting it. Holding it high would be serviced exactly once anyway,
      // which is the contract, but dropping keeps the stimulus honest about
      // what a real single-outstanding master does.
      if (port[p].req_held) { setReq(p, 0); port[p].req_held = false; }

      bool ack = getAck(p);
      if (ack && !port[p].ack_prev) {
        long lat = cyc - port[p].issued_at;
        if (lat > max_latency) max_latency = lat;
        if (!port[p].write) {
          uint64_t got = getDout(p);
          for (int w = 0; w < port[p].words; w++) {
            uint32_t a = port[p].addr + w;
            uint16_t want = shadow.count(a) ? shadow[a] : 0;
            uint16_t g = (uint16_t)((got >> (16 * w)) & 0xffff);
            checks++;
            if (g != want && fails < 20) {
              printf("  FAIL p%d addr=%06x word=%d got=%04x want=%04x\n",
                     p, a, w, g, want);
              fails++;
            } else if (g != want) {
              fails++;
            }
          }
        }
        port[p].busy = false;
        port[p].n_done++;
      }
      port[p].ack_prev = ack;
    }

    if (wr_req_held) { d->wr_req = 0; wr_req_held = false; }
    bool wack = d->wr_ack;
    if (wack && !wr_ack_prev) wr_busy = false;
    wr_ack_prev = wack;
  }

  void issue(int p, uint32_t addr, bool write, uint16_t data, uint8_t be = 3) {
    int words = write ? 1 : burst_of(p);
    if (words > 1) addr &= ~(uint32_t)(words - 1);   // bursts are aligned
    port[p].busy = true; port[p].addr = addr; port[p].words = words;
    port[p].write = write; port[p].wdata = data; port[p].be = be;
    port[p].issued_at = cyc;
    setAddr(p, addr);
    if (p == 0) { d->p0_we = write; d->p0_din = data; d->p0_be = be; }
    setReq(p, 1);
    port[p].req_held = true;
    if (write) {
      if (be & 1) shadow[addr] = (shadow.count(addr) ? shadow[addr] : 0);
      uint16_t cur = shadow.count(addr) ? shadow[addr] : 0;
      if (be & 1) cur = (cur & 0xff00) | (data & 0x00ff);
      if (be & 2) cur = (cur & 0x00ff) | (data & 0xff00);
      shadow[addr] = cur;
    }
  }

  void issueWrite(uint32_t addr, uint16_t data) {
    wr_busy = true; wr_addr = addr; wr_data = data;
    d->wr_addr = addr; d->wr_din = data; d->wr_be = 3; d->wr_req = 1;
    wr_req_held = true;
    shadow[addr] = data;
  }

  void drain(int maxcyc = 5000) {
    int n = 0;
    bool any = true;
    while (any && n++ < maxcyc) {
      any = wr_busy;
      for (int p = 0; p < NP; p++) any |= port[p].busy;
      step();
    }
  }
};

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Harness h;
  std::mt19937 rng(20260815u);

  printf("test: bring-up reaches ready\n");
  h.reset();

  // Addresses are drawn from a small set of banks and rows so that row
  // conflicts actually happen. A uniformly random 24-bit address almost never
  // reuses a row, and the row-management path — precharge, tRP, activate —
  // would go essentially untested.
  // The port address is [24:1], so as a 0-based C++ value bit 0 is address
  // bit 1: bank is [23:22], row is [21:9], column is [8:0]. Getting these
  // shifts wrong puts the shadow memory and the device at different
  // locations, which looks exactly like a broken read path.
  auto pick_addr = [&](std::mt19937& r) -> uint32_t {
    uint32_t bank = r() & 3;
    uint32_t row  = r() % 6;          // few rows, so conflicts are common
    uint32_t col  = r() & 0x1ff;      // 9 column bits on a 32 MB module
    return (bank << 22) | (row << 9) | col;
  };

  printf("test: ROM download writes, then read back through every port\n");
  {
    std::vector<uint32_t> addrs;
    for (int i = 0; i < 1500; i++) {
      uint32_t a = pick_addr(rng) & ~3u;      // burst-aligned so any port can read
      for (int w = 0; w < 4; w++) {
        while (h.wr_busy) h.step();
        h.issueWrite(a + w, (uint16_t)rng());
        h.step();
      }
      addrs.push_back(a);
    }
    h.drain();

    for (int p = 0; p < NP; p++) {
      for (size_t k = 0; k < addrs.size(); k += 7) {
        while (h.port[p].busy) h.step();
        h.issue(p, addrs[k], false, 0);
        h.step();
      }
    }
    h.drain();
    printf("  download+readback: %ld checks, %ld fails, %u violations\n",
           h.checks, h.fails, h.d->violations);
  }

  printf("test: all five masters concurrent, with p0 writes mixed in\n");
  {
    long start_checks = h.checks;
    for (long n = 0; n < 120000; n++) {
      for (int p = 0; p < NP; p++) {
        if (h.port[p].busy) continue;
        // Offered load differs per port so the arbiter sees an uneven mix,
        // which is what the real board presents.
        unsigned thresh = (p == 0) ? 40 : (p == 2) ? 30 : 12;
        if ((rng() % 100) >= thresh) continue;
        bool write = (p == 0) && ((rng() & 7) == 0);
        uint8_t be = 3;
        if (write && (rng() & 7) == 0) be = (rng() & 1) ? 1 : 2;  // byte writes
        h.issue(p, pick_addr(rng), write, (uint16_t)rng(), be);
      }
      // The download port stays idle here: on the real board the loader and
      // the game never run at once.
      h.step();
    }
    h.drain();
    printf("  concurrent: %ld checks, %ld fails, %u violations, max latency %ld\n",
           h.checks - start_checks, h.fails, h.d->violations, h.max_latency);
  }

  printf("test: row thrash — same bank, alternating rows\n");
  {
    long start_fails = h.fails;
    for (int n = 0; n < 4000; n++) {
      int p = n & 1 ? 0 : 3;
      while (h.port[p].busy) h.step();
      uint32_t a = (0u << 22) | (((uint32_t)(n & 1)) << 9) | (n & 0x1ff);
      h.issue(p, a, false, 0);
      h.step();
    }
    h.drain();
    printf("  row thrash: %ld fails\n", h.fails - start_fails);
  }

  // ------------------------------------------------ read/write collision
  // A WRITE drives DQ; a read in flight means the device drives DQ. The
  // controller guards against issuing one during the other, and a guard that
  // is never exercised is indistinguishable from a guard that does not work.
  // This phase alternates a burst read with a write to the same bank and row
  // as tightly as the arbiter allows, which is the tightest spacing the two
  // can ever have.
  printf("test: write against in-flight read data\n");
  {
    long start_fails = h.fails;
    // Different banks, so the two never touch the same address. Overlapping
    // them would race the shadow instead: the controller does not order a
    // concurrent read and write to one location, so a test that assumed an
    // order would be testing the harness, not the controller. The collision
    // being provoked is on the shared DQ bus, which does not need the
    // addresses to overlap.
    for (int n = 0; n < 6000; n++) {
      uint32_t rbase = (1u << 22) | (3u << 9);
      uint32_t wbase = (2u << 22) | (5u << 9);
      if (!h.port[1].busy) h.issue(1, rbase + ((n * 4) & 0x1fc), false, 0);
      if (!h.port[0].busy)
        h.issue(0, wbase + (n & 0x1ff), true, (uint16_t)(0x5a00 + (n & 0xff)));
      h.step();
    }
    h.drain();
    printf("  collision: %ld fails, %u violations\n",
           h.fails - start_fails, h.d->violations);
    h.checks++;
  }

  // ------------------------------------------------------- throughput
  // D2 and D3 rest on a bandwidth figure that has so far only been arithmetic.
  // This measures it, and specifically measures whether locality helps: the
  // real traffic mix is largely sequential (V60 code fetch, tile character
  // runs, polygon streams), so a controller that cannot exploit an open row
  // performs the same on sequential traffic as on random, and the whole
  // locality of the workload is worth nothing.
  printf("test: sustained throughput, sequential against random\n");
  {
    auto measure = [&](int p, bool sequential, long cycles) -> double {
      long words = 0;
      long t0 = h.cyc;
      uint32_t seq = 0x400000;      // bank 1, row 0, column 0
      std::mt19937 r2(99u);
      while (h.cyc - t0 < cycles) {
        if (!h.port[p].busy) {
          uint32_t a;
          if (sequential) {
            a = seq;
            seq += burst_of(p);
            // Stay inside one row so every access after the first is a row
            // hit, which is the best case a controller could exploit.
            if ((seq & 0x1ff) == 0) seq = (seq & ~0x1ffu);
          } else {
            a = (r2() & 3) << 22 | (r2() % 64) << 9 | (r2() & 0x1ff);
          }
          long before = h.port[p].n_done;
          h.issue(p, a, false, 0);
          (void)before;
          words += burst_of(p);
        }
        h.step();
      }
      h.drain();
      return (double)words / (double)(h.cyc - t0);
    };

    for (int p = 0; p < NP; p += 1) {
      if (p != 0 && p != 1) continue;    // one single-word port, one burst port
      double sq = measure(p, true,  20000);
      double rn = measure(p, false, 20000);
      // 16-bit words at 100 MHz.
      printf("  p%d (burst %d)  sequential %.3f words/cyc (%.1f MB/s)   "
             "random %.3f words/cyc (%.1f MB/s)   locality gain %.2fx\n",
             p, burst_of(p), sq, sq * 200.0, rn, rn * 200.0,
             rn > 0 ? sq / rn : 0.0);
      h.checks++;
    }
  }

  // -------------------------------------------------- realistic aggregate
  // The concurrent phase above draws addresses at random across a handful of
  // rows, which is close to worst case and useful for finding bugs. It is not
  // what the board does. Every real master streams: the V60 fetches code
  // sequentially, tile character data is read in runs, polygon data is a
  // stream, samples are a stream. Each master here walks its own cursor in its
  // own bank, which is the traffic D2 and D3 actually have to survive.
  printf("test: aggregate throughput under streaming traffic\n");
  {
    uint32_t cursor[NP];
    for (int p = 0; p < NP; p++) cursor[p] = (uint32_t)(p % 4) << 22;
    long words = 0, t0 = h.cyc;
    const long WINDOW = 60000;
    while (h.cyc - t0 < WINDOW) {
      for (int p = 0; p < NP; p++) {
        if (h.port[p].busy) continue;
        h.issue(p, cursor[p], false, 0);
        words += burst_of(p);
        cursor[p] += burst_of(p);
      }
      h.step();
    }
    h.drain();
    double wpc = (double)words / (double)(h.cyc - t0);
    printf("  aggregate %.3f words/cyc = %.1f MB/s at 100 MHz "
           "(%.1f MB/s at 143 MHz)\n", wpc, wpc * 200.0, wpc * 286.0);
    h.checks++;
  }

  // ------------------------------------------------------------- telemetry
  printf("test: bandwidth telemetry reports the traffic that actually ran\n");
  {
    h.d->mon_snap = 1; h.step(); h.d->mon_snap = 0; h.step();
    uint32_t total = 0;
    long served = 0;
    for (int p = 0; p < NP; p++) {
      h.d->mon_sel = p; h.d->eval();
      uint32_t rq = h.d->mon_req, gr = h.d->mon_grant;
      uint32_t wt = h.d->mon_wait, bm = h.d->mon_bmax;
      total = h.d->mon_total;
      printf("  p%d  req=%-8u grant=%-8u wait=%-8u burst_max=%-4u xacts=%ld\n",
             p, rq, gr, wt, bm, h.port[p].n_done);
      served += h.port[p].n_done;
      h.checks++;
      // A master that ran transactions must show demand and service. Zero
      // here means the tap is not wired to what it claims to measure, which
      // is the failure mode that makes telemetry worse than none.
      if (h.port[p].n_done > 0 && (rq == 0 || gr == 0)) {
        printf("  FAIL p%d ran %ld transactions but reports req=%u grant=%u\n",
               p, h.port[p].n_done, rq, gr);
        h.fails++;
      }
      if (wt != 0 && rq == 0) {
        printf("  FAIL p%d waited without ever requesting\n", p); h.fails++;
      }
    }
    h.checks++;
    if (total == 0) { printf("  FAIL total_cycles is zero\n"); h.fails++; }
    printf("  total cycles=%u, %ld transactions served\n", total, served);
  }

  h.checks++;
  if (h.d->violations != 0) {
    printf("  FAIL device model reported %u protocol violations, flags=%04x\n",
           h.d->violations, h.d->v_flags);
    h.fails++;
  }

  printf("m1_sdram: checks=%ld fails=%ld violations=%u reads=%u writes=%u\n",
         h.checks, h.fails, h.d->violations, h.d->reads_served,
         h.d->writes_served);
  return h.fails ? 1 : 0;
}
