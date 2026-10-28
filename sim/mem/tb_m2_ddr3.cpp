// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
// Taken unchanged with rtl/mem/m2_ddr3.sv from sega-model2-mister at 47ad2e2.
// Changed: unwritten memory reads 0xFFFF..., this project's rule for every bench.
//
// m2_ddr3: the DDR3 master.
//
// WHAT THIS HAS TO CATCH, and why it is written before the module is used.
// screen_rotate -- the framework's own example -- DOES NOT CHECK DDRAM_BUSY,
// because a video writer never backs up. A memory master that drops a request
// while BUSY is asserted has issued a read that never returns and a write that
// never lands, and neither shows up until something downstream is inexplicably
// wrong. So the BUSY tests below are the point of this bench, not decoration.
//
// The model is deliberately HOSTILE: BUSY is asserted for a settable number of
// cycles before a request is taken, and read data comes back a settable number
// after that. A bench whose memory always answers immediately proves nothing
// about a master that has to wait.

#include "Vm2_ddr3.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <map>
#include <deque>

static Vm2_ddr3 *d;
static long checks = 0, fails = 0;
static void ck(const char *what, long got, long want) {
  checks++;
  if (got != want) { fails++; std::printf("  FAIL %-44s got=%ld want=%ld\n", what, got, want); }
}

// ---- the DDRAM model
static std::map<uint32_t, uint64_t> mem;
static int busy_for = 0;          // cycles BUSY is held before a request is taken
static int read_lat = 4;          // cycles from acceptance to DOUT_READY
static int busy_ctr = 0;
static std::deque<std::pair<int, uint64_t>> pending;   // (countdown, data)
static long accepted_writes = 0, accepted_reads = 0;

static void tick() {
  // BUSY for the first busy_for cycles of any request
  bool asking = d->DDRAM_WE || d->DDRAM_RD;
  d->DDRAM_BUSY = (asking && busy_ctr < busy_for) ? 1 : 0;
  if (asking) busy_ctr++; else busy_ctr = 0;

  d->DDRAM_DOUT_READY = 0;
  if (!pending.empty()) {
    if (--pending.front().first <= 0) {
      d->DDRAM_DOUT = pending.front().second;
      d->DDRAM_DOUT_READY = 1;
      pending.pop_front();
    }
  }
  d->eval();

  // accept a request only when we are NOT saying busy.
  // R347: a burst is ONE accepted read command returning BURSTCNT words, and
  // for a write, BURSTCNT consecutive accepted beats at ascending addresses.
  static uint32_t wr_addr = 0; static int wr_left = 0;
  if (!d->DDRAM_BUSY) {
    if (d->DDRAM_WE) {
      if (wr_left == 0) { wr_addr = d->DDRAM_ADDR; wr_left = d->DDRAM_BURSTCNT; }
      uint64_t prev = mem.count(wr_addr) ? mem[wr_addr] : ~0ull;
      uint64_t msk = 0;
      for (int b = 0; b < 8; b++) if (d->DDRAM_BE & (1 << b)) msk |= 0xffull << (b * 8);
      mem[wr_addr] = (prev & ~msk) | (d->DDRAM_DIN & msk);
      wr_addr++; wr_left--;
      accepted_writes++; busy_ctr = 0;
    } else if (d->DDRAM_RD) {
      for (int k = 0; k < d->DDRAM_BURSTCNT; k++) {
        uint32_t a = d->DDRAM_ADDR + k;
        pending.push_back({read_lat + k, mem.count(a) ? mem[a] : ~0ull});
      }
      accepted_reads++; busy_ctr = 0;
    }
  }
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
}

static bool do_req(bool we, uint32_t a, uint64_t v, uint8_t be, uint64_t *out, int budget = 400) {
  // R660: not in the cycle the previous ack is out -- m2_ddr3 ignores a request
  // there, because a requester that saw the ack is still asserting its old one
  while (d->ack) tick();
  d->req = 1; d->we = we; d->addr = a; d->din = v; d->be = be; d->blen = 1;
  tick();
  d->req = 0;
  for (int i = 0; i < budget; i++) {
    if (d->ack) { if (out) *out = d->dout; return true; }
    tick();
  }
  return false;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_ddr3;
  d->base = 0x04C00000;   // R654: the base is an input now; the bench keeps R351's
  d->clk = 0; d->rst_n = 0; d->req = 0;
  d->DDRAM_BUSY = 0; d->DDRAM_DOUT_READY = 0; d->DDRAM_DOUT = 0;
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1; tick();

  // ---- 1. a write lands and a read returns it
  {
    std::printf("test: a write lands and the read returns it\n");
    busy_for = 0; read_lat = 4;
    uint64_t got = 0;
    ck("the write acknowledged", do_req(true, 0x100, 0xDEADBEEFCAFEF00Dull, 0xFF, nullptr), 1);
    ck("the read acknowledged",  do_req(false, 0x100, 0, 0xFF, &got), 1);
    ck("and returned the data", (long)(got == 0xDEADBEEFCAFEF00Dull), 1);
  }

  // ---- 2. BUSY. THE TEST THIS BENCH EXISTS FOR.
  //      A master that drops its request while BUSY loses the transaction
  //      silently; here the memory refuses for 9 cycles before accepting.
  {
    std::printf("test: a request held through BUSY is not lost\n");
    busy_for = 9; read_lat = 6;
    uint64_t got = 0;
    long w0 = accepted_writes, r0 = accepted_reads;
    ck("the write still acknowledged", do_req(true, 0x200, 0x0123456789ABCDEFull, 0xFF, nullptr), 1);
    ck("and reached the memory ONCE",  accepted_writes - w0, 1);
    ck("the read still acknowledged",  do_req(false, 0x200, 0, 0xFF, &got), 1);
    ck("issued ONCE, not repeatedly",  accepted_reads - r0, 1);
    ck("and returned the data", (long)(got == 0x0123456789ABCDEFull), 1);
  }

  // ---- 3. the latency it reports is the latency it saw
  {
    std::printf("test: the measured latency is real, not assumed\n");
    busy_for = 3; read_lat = 11;
    uint64_t got = 0;
    do_req(true, 0x300, 0xA5A5A5A5A5A5A5A5ull, 0xFF, nullptr);
    do_req(false, 0x300, 0, 0xFF, &got);
    // request cycle + 3 busy + the read latency, within a cycle either way
    long want = 3 + 11;
    long saw  = d->dbg_lat_last;
    checks++;
    if (saw < want - 2 || saw > want + 2) {
      fails++; std::printf("  FAIL measured latency %ld, modelled %ld\n", saw, want);
    }
    ck("max is at least last", (long)(d->dbg_lat_max >= d->dbg_lat_last), 1);
  }

  // ---- 4. byte enables: a partial write must not disturb its neighbours
  {
    std::printf("test: byte enables leave the rest of the word alone\n");
    busy_for = 0; read_lat = 2;
    uint64_t got = 0;
    do_req(true, 0x400, 0xFFFFFFFFFFFFFFFFull, 0xFF, nullptr);
    do_req(true, 0x400, 0x00000000000000AAull, 0x01, nullptr);
    do_req(false, 0x400, 0, 0xFF, &got);
    ck("low byte replaced",   (long)(got & 0xff), 0xAA);
    ck("the rest untouched",  (long)((got >> 8) == 0x00FFFFFFFFFFFFFFull), 1);
  }

  // ---- 5. back to back, and the addresses do not blur into one another
  {
    std::printf("test: many transactions back to back\n");
    busy_for = 2; read_lat = 5;
    for (int i = 0; i < 64; i++)
      do_req(true, 0x1000 + i, 0x1111111100000000ull + i, 0xFF, nullptr);
    long wrong = 0;
    for (int i = 0; i < 64; i++) {
      uint64_t got = 0;
      do_req(false, 0x1000 + i, 0, 0xFF, &got);
      if (got != 0x1111111100000000ull + (uint64_t)i) wrong++;
    }
    ck("all 64 read back correctly", wrong, 0);
    // R371: the dbg_reads counter is gone. It was never on the debug wire, so it
    // existed only for this check -- and this check is weaker than the line
    // above it, which verifies all 64 words byte for byte. Thirty-two
    // flip-flops on a device with nine LABs to spare, to restate what a
    // stronger assertion already proved.
  }

  // ---- 6. R347: BURSTS. MiSTer's guidance is that DDR3 here is ~200 ns
  //      typical and unbounded in the worst case, and that a core must use
  //      high burst counts rather than rapid single-word access. A burst of 8
  //      must cost ONE command and return EIGHT words.
  {
    std::printf("test: a burst is one command and N words\n");
    busy_for = 4; read_lat = 20;          // ~200 ns at 100 MHz
    long r0 = accepted_reads, w0 = accepted_writes;
    // write eight ascending words as one burst
    while (d->ack) tick();   // R660
    d->req = 1; d->we = 1; d->addr = 0x2000; d->be = 0xFF; d->blen = 8;
    d->din = 0x7000000000000000ull;
    tick(); d->req = 0;
    int beat = 1;
    for (int i = 0; i < 400 && !d->ack; i++) {
      if (d->wnext) { d->din = 0x7000000000000000ull + beat; beat++; }
      tick();
    }
    ck("the write burst finished",      (long)(beat >= 8), 1);
    ck("ONE command, eight beats",      accepted_writes - w0, 8);
    // read them back as one burst
    while (d->ack) tick();   // R660
    d->req = 1; d->we = 0; d->addr = 0x2000; d->be = 0xFF; d->blen = 8;
    tick(); d->req = 0;
    long words = 0, wrong = 0;
    for (int i = 0; i < 600 && !d->ack; i++) {
      if (d->rvalid) {
        if (d->dout != 0x7000000000000000ull + (uint64_t)words) wrong++;
        words++;
      }
      tick();
    }
    if (d->rvalid) { if (d->dout != 0x7000000000000000ull + (uint64_t)words) wrong++; words++; }
    ck("ONE read command for the burst", accepted_reads - r0, 1);
    ck("eight words returned",           words, 8);
    ck("all correct",                    wrong, 0);
    // and the latency reported is for the WHOLE burst, which is what a
    // consumer waits for -- not the first word.
    ck("latency covers the whole burst", (long)(d->dbg_lat_last >= 20), 1);
  }

  std::printf("m2_ddr3: checks=%ld fails=%ld\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
