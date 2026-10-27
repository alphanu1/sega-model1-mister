// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The DDR3 payload client against a HOSTILE model: latency is a parameter,
// BUSY is asserted at random including between the two beats of a burst,
// and reply beats are withheld at random. The Model 2 core's benches gave
// false greens with optimistic memory models (its study, R360/R364/R372), so
// this one checks the Avalon rules on every cycle as well as the data:
//
//   - while BUSY is high a presented command does not change
//   - RD and WE are never presented together, BE is never zero
//   - a write burst's second beat follows its first before anything else
//   - every address lies inside the payload region
//
// and then the client's own contract:
//
//   - every payload written comes back byte for byte, in order
//   - a posted write is never lost (dbg_wr_ovf stays zero) at the store's rate
//   - a FLUSH in any state - mid burst, with replies owed, with writes queued -
//     leaves the bus consistent and the next stream correct
//   - rd_ready never depends on BUSY in the same cycle
//
// And the latency sweep, which is the point: where does prefetch stop hiding
// the round trip at the fill's measured pace?

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
  if (!ok) { if (fails < 20) printf("  FAIL %s\n", what); fails++; }
}

static const uint32_t BASE = 0x06000000;     // byte 0x30000000 in 64-bit words
static const int IW = 12;

struct Ddr3 {
  Vm1_ddram_payload* d;
  std::map<uint32_t, uint64_t> mem;
  struct Reply { long due; uint64_t data; };
  std::deque<Reply> replies;
  long cyc = 0, latency = 40;
  int busy_run = 0, busy_pct = 0, hold_pct = 0;
  unsigned seed = 12345;
  int wr_left = 0; uint32_t wr_addr = 0;
  long protocol_errs = 0;
  // the command presented last cycle, for the stability check
  bool p_rd = false, p_we = false, p_busy = false; uint32_t p_addr = 0; int p_bc = 0;
  uint64_t p_din = 0;

  unsigned rnd() { seed = seed * 1103515245u + 12345u; return (seed >> 16) & 0x7fff; }

  void perr(const char* w) { if (protocol_errs++ < 10) printf("  PROTOCOL %s at cycle %ld\n", w, cyc); }

  void pre() {
    if (busy_pct) {
      if (busy_run > 0) busy_run--;
      else if ((int)(rnd() % 100) < busy_pct) busy_run = 1 + rnd() % 24;
    }
    d->DDRAM_BUSY = (busy_run > 0);
    d->eval();

    bool rd = d->DDRAM_RD, we = d->DDRAM_WE;
    if (rd && we) perr("RD and WE together");
    if ((rd || we) && d->DDRAM_BE == 0) perr("BE = 0");
    if (p_busy && (p_rd || p_we)) {
      // the command that was held under BUSY must still be presented as it was
      if (rd != p_rd || we != p_we || d->DDRAM_ADDR != p_addr || d->DDRAM_BURSTCNT != p_bc ||
          (we && d->DDRAM_DIN != p_din))
        perr("command changed while BUSY");
    }
    if (wr_left > 0 && rd) perr("read presented inside an open write burst");

    // CONSUME THE COMMAND PRESENTED DURING THIS CYCLE - the one the master
    // registered at the previous edge. A write burst's second beat lands at
    // ADDR+1; the master re-presents ADDR, so the model tracks the beat.
    if (!d->DDRAM_BUSY) {
      if (we) {
        if (wr_left == 0) {
          wr_addr = d->DDRAM_ADDR; wr_left = d->DDRAM_BURSTCNT;
          if (wr_addr < BASE || wr_addr >= BASE + (2u << (IW + 1))) perr("write outside the region");
        }
        mem[wr_addr] = d->DDRAM_DIN;
        wr_addr++;
        wr_left--;
      }
      if (rd) {
        uint32_t a = d->DDRAM_ADDR;
        if (a < BASE || a >= BASE + (2u << (IW + 1))) perr("read outside the region");
        long t = cyc + latency;
        if (!replies.empty() && replies.back().due >= t) t = replies.back().due + 1;
        for (int b = 0; b < d->DDRAM_BURSTCNT; b++)
          replies.push_back({t + b, mem.count(a + b) ? mem[a + b] : 0xFFFFFFFFFFFFFFFFull});
      }
    }
    p_rd = rd; p_we = we; p_busy = d->DDRAM_BUSY; p_addr = d->DDRAM_ADDR;
    p_bc = d->DDRAM_BURSTCNT; p_din = d->DDRAM_DIN;

    // Reply beats, withheld at random as a shared controller does.
    d->DDRAM_DOUT_READY = 0;
    if (!replies.empty() && replies.front().due <= cyc &&
        !(hold_pct && (int)(rnd() % 100) < hold_pct)) {
      d->DDRAM_DOUT = replies.front().data;
      d->DDRAM_DOUT_READY = 1;
      replies.pop_front();
    }
    d->eval();
  }
  void post() { cyc++; }
};

struct Harness {
  Vm1_ddram_payload* d;
  Ddr3 ddr;
  Harness() {
    d = new Vm1_ddram_payload;
    ddr.d = d;
    d->clk = 0; d->rst_n = 0; d->flush = 0;
    d->wr_req = 0; d->rd_req = 0; d->rd_take = 0;
    d->DDRAM_BUSY = 0; d->DDRAM_DOUT_READY = 0; d->DDRAM_DOUT = 0;
    d->eval();
    for (int i = 0; i < 8; i++) tick();
    d->rst_n = 1;
  }
  ~Harness() { delete d; }
  void begin_cycle() { ddr.pre(); d->eval(); }
  void end_cycle() {
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    ddr.post();
    d->eval();
  }
  void tick() { begin_cycle(); end_cycle(); }
};

static uint32_t pw(uint32_t tag, int i) { return tag * 2654435761u + i * 0x9e3779b9u; }
static void set_wr(Vm1_ddram_payload* d, uint32_t tag) { for (int i = 0; i < 4; i++) d->wr_data[i] = pw(tag, i); }
static bool cmp_rd(Vm1_ddram_payload* d, uint32_t tag) {
  for (int i = 0; i < 4; i++) if (d->rd_data[i] != pw(tag, i)) return false;
  return true;
}

// Post N writes at one every `gap` cycles - the store has no backpressure, so
// this is exactly how the geometry drives it - then wait for wr_idle.
static void post_writes(Harness& h, int bank, int first, int n, int gap, uint32_t tagbase) {
  for (int i = 0; i < n; i++) {
    h.begin_cycle();
    set_wr(h.d, tagbase + first + i);
    h.d->wr_bank = bank; h.d->wr_idx = first + i; h.d->wr_req = 1;
    h.end_cycle();
    h.d->wr_req = 0;
    for (int k = 1; k < gap; k++) h.tick();
  }
  long g = 0;
  do { h.tick(); } while (!h.d->wr_idle && g++ < 200000);
  chk(h.d->wr_idle, "wr_idle rises once the posted writes are on the bus");
}

// Stream N reads, taking one every `pace` cycles; returns cycles taken and
// counts mismatches.
//
// THE REQUESTER BEHAVES AS m1_quad_store DOES, and an earlier version of this
// bench did not: the store samples rd_ready, queues the quad's colour in a
// 16-deep FIFO, and presents the request FROM A REGISTER a cycle later. A
// bench that asks in the same cycle it samples ready passed while the real
// pairing froze the 3D under a busy bus (render3d, DDR_BUSY=50), because the
// client's queue was shallower than its credit and refused the late request.
// rd_ready is also sampled BEFORE pre(), against the previous cycle's state
// only - the claim that it does not depend on this cycle's BUSY.
static long stream(Harness& h, int bank, int first, int n, int pace, uint32_t tagbase, int& bad) {
  long t0 = h.ddr.cyc;
  int decided = 0, taken = 0, since = pace, meta = 0;
  bool pend = false; int pend_idx = 0;
  long guard = 0;
  bad = 0;
  while (taken < n && guard++ < 20000000) {
    h.d->eval();
    bool rdy_before = h.d->rd_ready;
    h.begin_cycle();
    if (h.d->rd_ready != rdy_before) { chk(false, "rd_ready moved with BUSY inside a cycle"); }
    // present what was decided last cycle
    h.d->rd_req = pend; h.d->rd_bank = bank; h.d->rd_idx = first + pend_idx;
    if (pend && !h.d->rd_ready) chk(false, "a request decided on rd_ready was refused a cycle later");
    // decide the next, as the store's scan does: colour room and rd_ready
    bool can = decided < n && meta < 16 && h.d->rd_ready;
    h.d->rd_take = 0;
    bool took = false;
    if (h.d->rd_valid && since >= pace) {
      if (!cmp_rd(h.d, tagbase + first + taken)) {
        if (!bad) printf("     mismatch at take %d: got %08x want %08x\n", taken,
                         h.d->rd_data[0], pw(tagbase + first + taken, 0));
        bad++;
      }
      h.d->rd_take = 1; taken++; since = 0; took = true;
    }
    h.end_cycle();
    h.d->rd_req = 0; h.d->rd_take = 0;
    pend = can; if (can) { pend_idx = decided; decided++; meta++; }
    if (took) meta--;
    since++;
  }
  chk(taken == n, "the stream completes");
  chk(h.d->dbg_rd_refused == 0, "no read refused");
  return h.ddr.cyc - t0;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  printf("test: posted writes come back byte for byte, both banks\n");
  {
    Harness h; h.ddr.latency = 40;
    post_writes(h, 0, 0, 300, 3, 1000);       // more than the 256-deep queue, at gap 3
    post_writes(h, 1, 0, 300, 3, 5000);
    int bad;
    stream(h, 0, 0, 300, 1, 1000, bad); chk(bad == 0, "bank 0 reads back");
    stream(h, 1, 0, 300, 1, 5000, bad); chk(bad == 0, "bank 1 reads back, not bank 0");
    chk(h.d->dbg_wr_ovf == 0, "no posted write lost");
    chk(h.ddr.protocol_errs == 0, "Avalon rules held");
  }

  printf("test: posted writes at one a cycle overflow the queue, AND SAY SO\n");
  {
    Harness h; h.ddr.latency = 40; h.ddr.busy_pct = 100;   // a bus that stays busy
    for (int i = 0; i < 300; i++) {
      h.begin_cycle(); set_wr(h.d, i); h.d->wr_bank = 0; h.d->wr_idx = i; h.d->wr_req = 1;
      h.end_cycle();
    }
    h.d->wr_req = 0;
    chk(h.d->dbg_wr_ovf > 0, "an overrun is counted, not silent");
  }

  printf("test: THE LATENCY SWEEP, reads at the fill's measured pace\n");
  {
    const int N = 512, PACE = 107;
    printf("   %8s %8s %10s %10s\n", "latency", "busy%", "cycles", "vs ideal");
    long ideal = (long)N * PACE;
    for (int busy : {0, 20}) {
      for (long lat : {10L, 40L, 100L, 400L, 1000L, 2000L}) {
        Harness h; h.ddr.latency = lat; h.ddr.busy_pct = busy;
        // gap 40: four times denser than the geometry's measured worst (154
        // cycles between quads, render3d), and still under a busy bus
        post_writes(h, 0, 0, N, 40, 77);
        chk(h.d->dbg_wr_ovf == 0, "no posted write lost at four times the geometry's rate");
        int bad;
        long took = stream(h, 0, 0, N, PACE, 77, bad);
        chk(bad == 0, "payloads arrive in order under load");
        chk(h.ddr.protocol_errs == 0, "Avalon rules held under load");
        printf("   %8ld %8d %10ld %9.2fx\n", lat, busy, took, (double)took / ideal);
      }
    }
  }

  printf("test: random BUSY, withheld beats, writes and reads interleaved\n");
  {
    Harness h; h.ddr.latency = 120; h.ddr.busy_pct = 15; h.ddr.hold_pct = 30;
    // bank 1 written while bank 0 is read: the producer and consumer at once
    post_writes(h, 0, 0, 1024, 40, 300);
    int issued = 0, taken = 0, bad = 0, wi = 0; long guard = 0;
    while (taken < 1024 && guard++ < 5000000) {
      h.begin_cycle();
      h.d->wr_req = 0;
      if (wi < 1024 && (h.ddr.rnd() % 40) == 0) {
        set_wr(h.d, 9000 + wi); h.d->wr_bank = 1; h.d->wr_idx = wi; h.d->wr_req = 1; wi++;
      }
      if (issued < 1024 && h.d->rd_ready) { h.d->rd_bank = 0; h.d->rd_idx = issued; h.d->rd_req = 1; }
      else h.d->rd_req = 0;
      bool will = h.d->rd_req && h.d->rd_ready;
      h.d->rd_take = 0;
      if (h.d->rd_valid && (h.ddr.rnd() % 3) == 0) {
        if (!cmp_rd(h.d, 300 + taken)) bad++;
        h.d->rd_take = 1; taken++;
      }
      h.end_cycle();
      h.d->wr_req = 0; h.d->rd_req = 0; h.d->rd_take = 0;
      if (will) issued++;
    }
    chk(taken == 1024, "the read stream completes beside the write stream");
    chk(bad == 0, "and in order");
    while (wi < 1024) { h.begin_cycle(); set_wr(h.d, 9000 + wi); h.d->wr_bank = 1; h.d->wr_idx = wi;
                        h.d->wr_req = 1; h.end_cycle(); h.d->wr_req = 0; wi++; for (int k = 0; k < 39; k++) h.tick(); }
    long g = 0; do { h.tick(); } while (!h.d->wr_idle && g++ < 200000);
    stream(h, 1, 0, 1024, 1, 9000, bad);
    chk(bad == 0, "the bank written meanwhile reads back");
    chk(h.d->dbg_wr_ovf == 0, "no posted write lost");
    chk(h.ddr.protocol_errs == 0, "Avalon rules held");
  }

  printf("test: FLUSH in every state, then a clean stream\n");
  {
    long trials = 0;
    for (int trial = 0; trial < 400; trial++) {
      Harness h; h.ddr.latency = 20 + trial % 200; h.ddr.busy_pct = 10 + trial % 30;
      h.ddr.hold_pct = trial % 40; h.ddr.seed = 777 + trial;
      post_writes(h, 0, 0, 64, 2, 40000);
      // now traffic of every kind, and a flush at a random moment in it
      int when = 5 + h.ddr.rnd() % 300, len = 1 + h.ddr.rnd() % 6;
      int issued = 0;
      for (int c = 0; c < when + len; c++) {
        h.begin_cycle();
        h.d->flush = (c >= when);
        set_wr(h.d, 123456 + c); h.d->wr_bank = 1; h.d->wr_idx = c & 0xfff; h.d->wr_req = (c % 3) == 0;
        if (h.d->rd_ready) { h.d->rd_bank = 0; h.d->rd_idx = issued & 63; h.d->rd_req = 1; }
        else h.d->rd_req = 0;
        bool will = h.d->rd_req && h.d->rd_ready;
        h.d->rd_take = (h.ddr.rnd() & 1) && h.d->rd_valid;
        h.end_cycle();
        if (will) issued++;
      }
      h.d->flush = 0; h.d->wr_req = 0; h.d->rd_req = 0; h.d->rd_take = 0;
      for (int k = 0; k < 2; k++) h.tick();
      chk(!h.d->rd_valid, "nothing presented after a flush");
      // the bus must settle and the next stream must be exactly right
      long g = 0; do { h.tick(); } while ((!h.d->wr_idle) && g++ < 100000);
      chk(h.d->wr_idle, "the bus settles after a flush");
      int bad;
      stream(h, 0, 0, 64, 1 + trial % 5, 40000, bad);
      chk(bad == 0, "a stream after a flush delivers the right payloads in order");
      chk(h.ddr.protocol_errs == 0, "no burst was cut short by the flush");
      trials++;
    }
    printf("   %ld flush trials\n", trials);
  }

  printf("m1_ddram_payload: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
