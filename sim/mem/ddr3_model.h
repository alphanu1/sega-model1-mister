// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// A HOSTILE model of the MiSTer framework's DDRAM port, for any Verilator
// bench whose top level carries the DDRAM_* signals.
//
// The Model 2 core's DDR3 work found that optimistic memory models give false
// greens (its study, R360/R364/R372/R377), so this one is unkind on purpose:
//
//   - LATENCY is a parameter, and replies come back in order
//   - BUSY is asserted at random, in runs, including between a write burst's
//     two beats
//   - reply beats are withheld at random, as a shared controller does
//   - unwritten memory reads 0xFFFF..., never zero
//
// and it CHECKS the Avalon rules on every cycle: a command presented while
// BUSY must not change, RD and WE never together, BE never zero, no read
// inside an open write burst. Violations are counted in `protocol_errs`.
//
// Use: call pre() after the DUT's outputs have settled for the cycle (before
// the rising edge), and post() after it.

#pragma once
#include <cstdint>
#include <cstdio>
#include <deque>
#include <unordered_map>

template <class T>
struct Ddr3Model {
  T* d = nullptr;
  std::unordered_map<uint32_t, uint64_t> mem;
  struct Reply { long due; uint64_t data; };
  std::deque<Reply> replies;
  long cyc = 0, latency = 40;
  int busy_run = 0, busy_pct = 0, hold_pct = 0, busy_max = 24;
  unsigned seed = 12345;
  int wr_left = 0; uint32_t wr_addr = 0;
  long protocol_errs = 0, reads = 0, writes = 0, busy_cycles = 0;
  bool p_rd = false, p_we = false, p_busy = false; uint32_t p_addr = 0; int p_bc = 0;
  uint64_t p_din = 0;

  unsigned rnd() { seed = seed * 1103515245u + 12345u; return (seed >> 16) & 0x7fff; }
  void perr(const char* w) {
    if (protocol_errs++ < 10) printf("  DDR3 PROTOCOL: %s at cycle %ld\n", w, cyc);
  }

  void pre() {
    if (busy_pct) {
      if (busy_run > 0) busy_run--;
      else if ((int)(rnd() % 1000) < busy_pct) busy_run = 1 + rnd() % busy_max;
    }
    d->DDRAM_BUSY = (busy_run > 0);
    if (d->DDRAM_BUSY) busy_cycles++;
    d->eval();

    bool rd = d->DDRAM_RD, we = d->DDRAM_WE;
    if (rd && we) perr("RD and WE together");
    if ((rd || we) && d->DDRAM_BE == 0) perr("BE = 0");
    if (p_busy && (p_rd || p_we)) {
      if (rd != p_rd || we != p_we || d->DDRAM_ADDR != p_addr || d->DDRAM_BURSTCNT != p_bc ||
          (we && d->DDRAM_DIN != p_din))
        perr("command changed while BUSY");
    }
    if (wr_left > 0 && rd) perr("read inside an open write burst");

    if (!d->DDRAM_BUSY) {
      if (we) {
        if (wr_left == 0) { wr_addr = d->DDRAM_ADDR; wr_left = d->DDRAM_BURSTCNT; writes++; }
        // BYTE ENABLES ARE HONOURED. They were ignored while the only writer
        // was the quad payload, which always writes all eight; the frame
        // buffer writes one pixel of a word with half of them, and a model
        // that wrote the whole word painted the pixel beside every odd span end.
        {
          uint64_t m = 0;
          for (int k = 0; k < 8; k++) if ((d->DDRAM_BE >> k) & 1) m |= 0xFFull << (8 * k);
          auto it = mem.find(wr_addr);
          uint64_t old = (it != mem.end()) ? it->second : 0xFFFFFFFFFFFFFFFFull;
          mem[wr_addr] = (old & ~m) | ((uint64_t)d->DDRAM_DIN & m);
        }
        wr_addr++;
        wr_left--;
      }
      if (rd) {
        uint32_t a = d->DDRAM_ADDR;
        long t = cyc + latency;
        if (!replies.empty() && replies.back().due >= t) t = replies.back().due + 1;
        for (int b = 0; b < d->DDRAM_BURSTCNT; b++) {
          auto it = mem.find(a + b);
          replies.push_back({t + b, it != mem.end() ? it->second : 0xFFFFFFFFFFFFFFFFull});
        }
        reads++;
      }
    }
    p_rd = rd; p_we = we; p_busy = d->DDRAM_BUSY; p_addr = d->DDRAM_ADDR;
    p_bc = d->DDRAM_BURSTCNT; p_din = d->DDRAM_DIN;

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
