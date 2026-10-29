// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// m1_p6_arb: tgp_ram and the display list's upper half sharing SDRAM port p6.
//
// Both requesters are modelled the way the RTL drives them - a request held,
// with stable address and data, until its valid; then a gap of 0-3 cycles
// (the walker always leaves one; m1_raster3d's tgp_ram side may leave none) -
// and the walker can also STALL, dropping its request mid-transaction and
// raising it again later, which the arbiter must survive without delivering
// a stale word. The port is m1_cdc_port's requester side: a level is accepted
// once, never on the cycle of its own acknowledge, and answered after a random
// latency of 2..LATMAX cycles with whatever memory holds at that address.
//
// Checked on every valid: it reaches only the requester that holds the
// request, with the data at the address that requester asked for (the list
// region is filled with an address hash, so a word from the wrong address is
// wrong data); writes land only in tgp_ram; nobody waits forever. Swept LATMAX 2, 20 and 200 -
// the last two orders of magnitude past the ~20-cycle SDRAM round trip.

#include "Vm1_p6_arb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <random>
#include <unordered_map>

static long checks = 0, fails = 0;
static void check(bool ok, const char* what, long cyc) {
  checks++;
  if (!ok) { if (fails < 20) printf("  FAIL @%ld: %s\n", cyc, what); fails++; }
}

static const uint32_t TEX_BASE = 0xC20000, DLHI_BASE = 0xCE0000;

int run(int latmax, uint32_t seed, long cycles_total) {
  std::mt19937 rng(seed);
  auto* d = new Vm1_p6_arb;
  std::unordered_map<uint32_t, uint16_t> mem;
  auto rd = [&](uint32_t a) -> uint16_t {
    auto it = mem.find(a); return it == mem.end() ? 0xFFFF : it->second;  // unwritten reads FFFF
  };
  // port model
  bool busy = false; int wait = 0; uint32_t paddr = 0; bool pwe = false; uint16_t pdin = 0;
  bool ack_now = false, prev_req = false, ack_prev = false;
  // requesters
  bool tq = false, twe = false; uint32_t ta = 0; uint16_t twd = 0; int tgap = 0; long t_since = 0;
  bool dq = false, dsel = false; uint32_t da = 0; int dgap = 0; long d_since = 0;
  bool dstall = false;
  long tex_done = 0, dl_done = 0, worst = 0;

  for (uint32_t a = 0; a < 0x8000; a++) mem[DLHI_BASE + a] = (uint16_t)((a * 2654435761u) >> 7);
  d->clk = 0; d->rst_n = 0; d->tex_req = 0; d->dl_req = 0; d->p_ack = 0; d->p_dout = 0;
  d->eval(); d->clk = 1; d->eval(); d->clk = 0; d->rst_n = 1; d->eval();

  for (long cyc = 0; cyc < cycles_total; cyc++) {
    // ---- requesters decide this cycle's inputs
    if (!tq) {
      if (tgap > 0) tgap--;
      else if ((rng() & 3) == 0) {
        tq = true; twe = rng() & 1; ta = rng() & 0xFFFFF; twd = rng() & 0xFFFF; t_since = 0;
      }
    }
    if (!dq) {
      if (dgap > 0) dgap--;
      else if ((rng() & 3) == 0) {
        dq = true; dsel = rng() & 1; da = rng() & 0x3FFF; d_since = 0;
      }
    }
    // the walker's stall drops its request for a while, mid-transaction or not
    if (dq && !dstall && (rng() % 64) == 0) dstall = true;
    else if (dstall && (rng() % 8) == 0) dstall = false;

    d->tex_req = tq; d->tex_we = twe; d->tex_addr = ta; d->tex_wdata = twd;
    d->dl_req = dq && !dstall; d->dl_sel = dsel; d->dl_addr = da;
    d->p_ack = ack_now;
    d->p_dout = ack_now ? (pwe ? 0 : rd(paddr)) : 0x5A5A;
    d->eval();

    // ---- check what the arbiter hands back this cycle
    if (d->tex_valid) {
      check(tq, "tex_valid with no tex request", cyc);
      check(ack_now && paddr == TEX_BASE + ta && pwe == twe, "tex answered for the wrong access", cyc);
      if (!twe) check(d->tex_data == rd(TEX_BASE + ta), "tex read returned wrong data", cyc);
    }
    if (d->dl_valid) {
      check(dq && !dstall, "dl_valid with no list request", cyc);
      // the list side answers from the arbiter's buffer, after its port
      // access: the data must be the word at the address held right now
      check(d->dl_data == rd(DLHI_BASE + ((uint32_t)dsel << 14) + da), "list read wrong data", cyc);
    }
    if (d->p_we) check(d->p_req && d->p_addr >= TEX_BASE && d->p_addr < TEX_BASE + 0x100000,
                       "a write aimed outside tgp_ram", cyc);

    // ---- port model: accept a level once, never on its own ack cycle
    bool accept = d->p_req && !busy && !(ack_now && prev_req);
    bool nxt_ack = false;
    if (busy) {
      if (wait > 0) wait--;
      else { if (pwe) mem[paddr] = pdin; nxt_ack = true; busy = false; }
    }
    if (accept) {
      busy = true; wait = 2 + (rng() % (latmax - 1)); paddr = d->p_addr; pwe = d->p_we; pdin = d->p_din;
    }

    // ---- requester bookkeeping on this cycle's valids
    if (d->tex_valid) { tq = false; tgap = rng() & 3; tex_done++; if (t_since > worst) worst = t_since; }
    if (d->dl_valid)  { dq = false; dgap = 1 + (rng() & 3); dl_done++; if (d_since > worst) worst = d_since; }
    if (tq) { t_since++; check(t_since < 50L * latmax + 1000, "tgp_ram request starved", cyc); }
    if (dq && !dstall) { d_since++; check(d_since < 50L * latmax + 1000, "list request starved", cyc); }

    ack_prev = ack_now; prev_req = d->p_req; ack_now = nxt_ack;
    d->clk = 1; d->eval(); d->clk = 0; d->eval();
  }
  printf("  latency 2..%d: %ld tgp_ram accesses, %ld list reads, worst wait %ld cycles\n",
         latmax, tex_done, dl_done, worst);
  check(tex_done > 1000 && dl_done > 1000, "one side made almost no progress", cycles_total);
  delete d;
  return 0;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  run(2, 1, 400000);
  run(20, 2, 400000);
  run(200, 3, 2000000);
  printf("m1_p6_arb: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
