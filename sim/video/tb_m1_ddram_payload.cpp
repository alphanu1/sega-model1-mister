// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The DDR3 payload client, against a model whose LATENCY IS A PARAMETER.
//
// The point of this bench is not that the data comes back - that is the easy
// part - but WHERE IT BREAKS. The HPS arbitrates DDR3 against Linux, so the
// worst-case latency is not ours to choose, and the design's claim is that
// prefetching hides it up to about DEPTH x 107 cycles because emissions are
// paced by the span fill rather than by the list scan.
//
// So the sweep below runs the client at latencies from 10 to 2,000 cycles and
// reports the throughput at each. A design that only works at short latency
// will show it here rather than on the board.

#include "Vm1_ddram_payload.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <deque>
#include <map>
#include <vector>

static long checks = 0, fails = 0;
static void chk(bool ok, const char* what) {
  checks++;
  if (!ok) { printf("  FAIL %s\n", what); fails++; }
}

// A DDR3 that answers after `latency` cycles, in order, two beats per burst,
// and can go busy for a while like a real arbitrated bus.
struct Ddr3 {
  Vm1_ddram_payload* d;
  std::map<uint32_t, uint64_t> mem;
  struct Reply { long due; uint64_t data; };
  std::deque<Reply> replies;
  long cyc = 0, latency = 40;
  int busy_run = 0;
  unsigned seed = 12345;
  bool model_busy = false;

  unsigned rnd() { seed = seed * 1103515245u + 12345u; return (seed >> 16) & 0x7fff; }

  void pre() {
    // BUSY is asserted in bursts, as a shared bus would.
    if (model_busy) {
      if (busy_run > 0) busy_run--;
      else if ((rnd() % 100) < 8) busy_run = 1 + rnd() % 12;
    }
    d->DDRAM_BUSY = (busy_run > 0);
    d->eval();

    // CONSUME THE COMMAND PRESENTED DURING THIS CYCLE - the one the master
    // registered at the previous edge - not the one it registers at this
    // edge. Sampling after the edge instead is off by one, and under a BUSY
    // that lands between the two beats of a write burst it drops the low half:
    // the master holds its command while BUSY, the model skipped it, and by
    // the time BUSY cleared the master had advanced to the high beat. The
    // symptom was a payload reading back as zero, which looks like an
    // addressing bug rather than a lost beat.
    if (!d->DDRAM_BUSY) {
      if (d->DDRAM_WE) {
        if (wr_left == 0) { wr_addr = d->DDRAM_ADDR; wr_left = d->DDRAM_BURSTCNT; }
        mem[wr_addr] = d->DDRAM_DIN;
        wr_addr++;
        wr_left--;
      }
      if (d->DDRAM_RD) {
        uint32_t a = d->DDRAM_ADDR;
        for (int b = 0; b < d->DDRAM_BURSTCNT; b++)
          replies.push_back({cyc + latency + b, mem.count(a + b) ? mem[a + b] : 0});
      }
    }

    // Slave outputs are presented for this cycle and latched by the master at
    // the edge that ends it.
    d->DDRAM_DOUT_READY = 0;
    if (!replies.empty() && replies.front().due <= cyc) {
      d->DDRAM_DOUT = replies.front().data;
      d->DDRAM_DOUT_READY = 1;
      replies.pop_front();
    }
    d->eval();
  }

  void post() { cyc++; }

  int wr_left = 0; uint32_t wr_addr = 0;
};

// The write burst's second beat lands at ADDR+1 on a real controller; the
// client re-presents ADDR unchanged, so the model tracks the beat itself.
struct Harness {
  Vm1_ddram_payload* d;
  Ddr3 ddr;
  Harness() {
    d = new Vm1_ddram_payload;
    ddr.d = d;
    d->clk = 0; d->rst_n = 0;
    d->wr_req = 0; d->rd_req = 0; d->rd_take = 0;
    d->DDRAM_BUSY = 0; d->DDRAM_DOUT_READY = 0; d->DDRAM_DOUT = 0;
    d->eval();
    for (int i = 0; i < 8; i++) tick();
    d->rst_n = 1;
  }
  ~Harness() { delete d; }
  // SPLIT, because BUSY decides whether a request is accepted and the model
  // drives it. A test that reads rd_ready before pre() sees it against the
  // PREVIOUS cycle's BUSY, counts a request the DUT never took, and then
  // compares payloads against the wrong index - which reads exactly like the
  // client returning out of order.
  void begin_cycle() { ddr.pre(); d->eval(); }
  void end_cycle() {
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    ddr.post();
    d->eval();
  }
  void tick() { begin_cycle(); end_cycle(); }
};

// A payload is 128 bits; Verilator presents it as four 32-bit words.
static void set_wr(Vm1_ddram_payload* d, uint32_t seed) {
  for (int i = 0; i < 4; i++) d->wr_data[i] = seed * 2654435761u + i * 0x9e3779b9u;
}
static bool cmp_rd(Vm1_ddram_payload* d, uint32_t seed) {
  for (int i = 0; i < 4; i++)
    if (d->rd_data[i] != (uint32_t)(seed * 2654435761u + i * 0x9e3779b9u)) return false;
  return true;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  printf("test: a payload written comes back byte for byte\n");
  {
    Harness h;
    h.ddr.latency = 40;
    const int N = 64;
    // write
    for (int i = 0; i < N; i++) {
      set_wr(h.d, i + 1);
      h.d->wr_bank = i & 1; h.d->wr_idx = i; h.d->wr_req = 1;
      do { h.begin_cycle(); } while (!h.d->wr_ready ? (h.end_cycle(), true) : false);
      h.end_cycle();
      h.d->wr_req = 0;
      for (int k = 0; k < 3; k++) h.tick();     // let the burst finish
    }
    // read back, one at a time
    int got = 0;
    for (int i = 0; i < N; i++) {
      h.d->rd_bank = i & 1; h.d->rd_idx = i; h.d->rd_req = 1;
      int guard = 0;
      while (!h.d->rd_ready && guard++ < 500) h.tick();
      h.tick();
      h.d->rd_req = 0;
      guard = 0;
      while (!h.d->rd_valid && guard++ < 2000) h.tick();
      if (h.d->rd_valid) {
        if (cmp_rd(h.d, i + 1)) got++;
        h.d->rd_take = 1; h.tick(); h.d->rd_take = 0;
      }
    }
    chk(got == N, "every payload read back matches what was written");
  }

  printf("test: THE LATENCY SWEEP - where does prefetching stop hiding it?\n");
  {
    // Fill a region, then stream reads with the consumer taking one every
    // CONSUME cycles - the fill's measured pace - and see how long the whole
    // stream takes as the bus gets slower.
    const int N = 256, CONSUME = 107;
    printf("   %8s %10s %12s\n", "latency", "cycles", "vs ideal");
    long ideal = (long)N * CONSUME;
    for (long lat : {10L, 40L, 100L, 400L, 1000L, 2000L}) {
      Harness h;
      h.ddr.latency = lat;
      for (int i = 0; i < N; i++) {
        set_wr(h.d, i + 1);
        h.d->wr_bank = 0; h.d->wr_idx = i; h.d->wr_req = 1;
        do { h.begin_cycle(); } while (!h.d->wr_ready ? (h.end_cycle(), true) : false);
        h.end_cycle(); h.d->wr_req = 0;
        for (int k = 0; k < 3; k++) h.tick();
      }
      long t0 = h.ddr.cyc;
      int issued = 0, taken = 0, since = 0, bad = 0;
      long guard = 0;
      while (taken < N && guard++ < 4000000) {
        h.begin_cycle();
        if (issued < N && h.d->rd_ready) {
          h.d->rd_bank = 0; h.d->rd_idx = issued; h.d->rd_req = 1;
        } else h.d->rd_req = 0;
        bool will_issue = h.d->rd_req && h.d->rd_ready;
        // consumer takes one every CONSUME cycles - the fill's measured pace
        h.d->rd_take = 0;
        if (h.d->rd_valid && since >= CONSUME) {
          if (!cmp_rd(h.d, taken + 1)) {
            if (!bad) printf("     first mismatch at take %d: got %08x want %08x (issued=%d)\n",
                             taken, h.d->rd_data[0],
                             (uint32_t)((taken + 1) * 2654435761u), issued);
            bad++;
          }
          h.d->rd_take = 1; taken++; since = 0;
        }
        h.end_cycle();
        if (will_issue) issued++;
        since++;
      }
      long took = h.ddr.cyc - t0;
      chk(bad == 0, "payloads arrive in order under load");
      chk(taken == N, "the stream completes");
      printf("   %8ld %10ld %11.2fx\n", lat, took, (double)took / ideal);
    }
  }

  printf("test: it survives a bus that goes busy at random\n");
  {
    Harness h;
    h.ddr.latency = 120;
    h.ddr.model_busy = true;
    const int N = 64;
    for (int i = 0; i < N; i++) {
      set_wr(h.d, i + 1);
      h.d->wr_bank = 1; h.d->wr_idx = i; h.d->wr_req = 1;
      do { h.begin_cycle(); } while (!h.d->wr_ready ? (h.end_cycle(), true) : false);
      h.end_cycle(); h.d->wr_req = 0;
      for (int k = 0; k < 4; k++) h.tick();
    }
    int issued = 0, taken = 0, bad = 0; long guard = 0;
    while (taken < N && guard++ < 2000000) {
      h.begin_cycle();
      if (issued < N && h.d->rd_ready) { h.d->rd_bank = 1; h.d->rd_idx = issued; h.d->rd_req = 1; }
      else h.d->rd_req = 0;
      bool will = h.d->rd_req && h.d->rd_ready;
      h.d->rd_take = 0;
      if (h.d->rd_valid) {
        if (!cmp_rd(h.d, taken + 1)) {
          if (!bad) printf("     busy-test mismatch at take %d: got %08x want %08x issued=%d\n",
                           taken, h.d->rd_data[0], (uint32_t)((taken + 1) * 2654435761u), issued);
          bad++;
        }
        h.d->rd_take = 1; taken++;
      }
      h.end_cycle();
      if (will) issued++;
    }
    chk(taken == N, "the stream completes with BUSY asserted at random");
    chk(bad == 0, "and still in order");
  }

  printf("m1_ddram_payload: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
