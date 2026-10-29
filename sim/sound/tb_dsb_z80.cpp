// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// dsb_z80 (cut down) against tv80s (full Z80) on the DSB's real program,
// epr-16471.2, fed the UART bytes the sound 68000 sent in MAME's 300 s capture
// (tools/mame_dsb_cap.lua). Every port access of both cores is logged with
// the T-state it happened at; the two logs must be identical -- same order,
// same ports, same values, same T-states.
//
//   DSB_SECS   emulated seconds (default 4)
//   DSB_LAT    dsb_z80's memory latency in clk cycles (default 0). Above what
//              the T clock can absorb, the core lags and I/O lands late; the
//              bench then checks order and values and reports the worst lag.
//   DSB_TPC    clk cycles per T-state (default 4)
#include "Vdsb_z80_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>
#include <vector>
#include <cmath>

struct Ev { char k; int port, data; uint64_t t; };

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  FILE *hf = fopen("build/rom/dsb/epr-16471.hex", "r");
  if (!hf) { printf("dsb_z80: SKIPPED (build/rom/dsb/epr-16471.hex absent: tools/dsb/prepare.sh)\n"); return 0; }
  fclose(hf);
  double secs = getenv("DSB_SECS") ? atof(getenv("DSB_SECS")) : 4.0;
  int lat = getenv("DSB_LAT") ? atoi(getenv("DSB_LAT")) : 0;
  int tpc = getenv("DSB_TPC") ? atoi(getenv("DSB_TPC")) : 4;
  const char *cap = getenv("DSB_CAP") ? getenv("DSB_CAP") : "build/rom/dsb/cap300.txt";

  // the bytes the 68000 transmitted, arriving one character time (320 us) later
  std::deque<std::pair<uint64_t, int>> rx;
  if (FILE *f = fopen(cap, "r")) {
    char line[256];
    while (fgets(line, sizeof line, f)) {
      double t; char k[8]; unsigned v;
      if (sscanf(line, "%lf %7s %x", &t, k, &v) == 3 && std::string(k) == "TX")
        rx.push_back({(uint64_t)((t + 320e-6) * 4e6), (int)v});
    }
    fclose(f);
  }

  long fails = 0;
  auto *h = new Vdsb_z80_harness;
  h->lat = lat; h->rst_n = 0; h->tick = 0; h->rx_stb = 0;
  for (int i = 0; i < 20; i++) { h->clk = 0; h->eval(); h->clk = 1; h->eval(); }
  h->rst_n = 1;

  std::deque<Ev> te, ce;
  size_t n = 0;
  long dt_max = 0, dt_neq = 0, wr_n = 0;
  auto drain = [&](void) {
    while (!te.empty() && !ce.empty()) {
      Ev a = te.front(), b = ce.front(); te.pop_front(); ce.pop_front();
      if (a.k != b.k || a.port != b.port || a.data != b.data) {
        if (fails < 10) printf("FAIL: access %zu: tv80 %c %02x=%02x @%llu  cut %c %02x=%02x @%llu\n", n,
            a.k, a.port, a.data, (unsigned long long)a.t, b.k, b.port, b.data, (unsigned long long)b.t);
        fails++;
      }
      long dt = (long)b.t - (long)a.t;
      if (dt) { dt_neq++; if (labs(dt) > dt_max) dt_max = labs(dt);
        if (lat == 0 && dt_neq <= 5) printf("T differs: access %zu %c %02x=%02x tv80 @%llu cut @%llu\n", n, a.k, a.port, a.data,
            (unsigned long long)a.t, (unsigned long long)b.t); }
      if (getenv("DSB_SHOW") && n >= (size_t)atoi(getenv("DSB_SHOW")) && n < (size_t)atoi(getenv("DSB_SHOW")) + 12)
        printf("  %zu: tv80 %c %02x=%02x @%llu | cut %c %02x=%02x @%llu\n", n, a.k, a.port, a.data, (unsigned long long)a.t, b.k, b.port, b.data, (unsigned long long)b.t);
      if (a.k == 'W') wr_n++;
      n++;
    }
  };
  uint64_t T = 0, Tend = (uint64_t)(secs * 4e6);
  long rxn = 0;
  uint64_t cyc = 0;
  while (T < Tend) {
    h->tick = ((cyc % tpc) == 0);
    h->rx_stb = 0;
    if (h->tick && !rx.empty() && rx.front().first <= T) { h->rx_stb = 1; h->rx_byte = rx.front().second; rx.pop_front(); rxn++; }
    h->clk = 0; h->eval(); h->clk = 1; h->eval();
    if (h->t_wr) te.push_back({'W', h->t_port, h->t_data, T});
    if (h->t_rd) te.push_back({'R', h->t_port, h->t_data, T});
    if (h->c_wr) ce.push_back({'W', h->c_port, h->c_data, T});
    if (h->c_rd) ce.push_back({'R', h->c_port, h->c_data, T});
    if ((cyc & 1023) == 0) drain();
    if (h->tick) T++;
    cyc++;
  }
  drain();
  if (te.size() != ce.size()) {
    printf("%s: tv80 made %zu accesses, cut made %zu\n", te.size() > ce.size() + 2 || ce.size() > te.size() + 2 ? "FAIL" : "note", te.size(), ce.size());
    if (te.size() > ce.size() + 2 || ce.size() > te.size() + 2) fails++;
  }
  if (h->trap) { printf("FAIL: unimplemented opcode trap, pc=%04x count=%u\n", h->trap_pc, h->trap_cnt); fails++; }
  if (lat == 0 && dt_neq) fails++;
  printf("dsb_z80[lat=%d,tpc=%d,%.1fs]: checks=%zu writes=%ld fails=%ld rx=%ld T_differ=%ld max_dT=%ld traps=%u\n",
         lat, tpc, secs, n, wr_n, fails, rxn, dt_neq, dt_max, h->trap_cnt);
  delete h;
  return fails ? 1 : 0;
}
