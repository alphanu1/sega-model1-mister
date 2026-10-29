// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The whole Digital Sound Board against MAME.
//
// Fed exactly the bytes MAME's sound 68000 transmitted in a 300 s run of
// Star Wars (tools/mame_dsb_cap.lua: attract, coin at 150 s, start at 152 s),
// each arriving one character time (320 us) after MAME's 68000 wrote it, with
// the Z80's ROM and RAM and the MPEG data behind a memory that answers in
// [1, LAT] cycles and reads 0xFFFF where nothing was written:
//
//   1. every port write the Z80 makes must equal MAME's, in order and value
//      (and the UART bytes it reads); the time of each against MAME's is
//      reported, not asserted -- MAME schedules its Z80 in slices;
//   2. every decoded sample must equal tools/dsb/dsb_fixmodel.h driven by the
//      same port writes (bit-exact; that model is within 1 LSB of MAME's
//      decoder);
//   3. every 32 kHz output sample must equal the decoded one with the volume
//      and pan in force.
//
//   inputs from tools/dsb/prepare.sh (build/rom/dsb/); DSB_SECS (default 70),
//   DSB_LAT (default 40), DSB_VOLMAME, DSB_Z80ROM / DSB_MPEG / DSB_CAP to override
#include "Vdsb_board_harness.h"
#include "verilated.h"
#include "dsb_fixmodel.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <string>
#include <vector>

static std::vector<uint8_t> mp, zr;
static double winf[512];

struct Ref {   // dsbz80.cpp's register and play logic around the fixed-point decoder
  FixDec *fx;
  uint32_t st = 0, en = 0, mp_start = 0, mp_end = 0, lp_start = 0, lp_end = 0, state = 0;
  int pos = 0;
  std::deque<uint32_t> q;
  Ref() { fx = new FixDec(mp.data(), FixCfg()); }
  void wr(int a, int v) {
    switch (a) {
      case 0: state = v; if (v == 0) q.clear(); else if (v == 1 || v == 2) pos = mp_start * 8; break;
      case 2: st = (st & 0x00ffff) | (v << 16); break;
      case 3: st = (st & 0xff00ff) | (v << 8); break;
      case 4: st = (st & 0xffff00) | v; if (state == 0) mp_start = st; else lp_start = st; break;
      case 5: en = (en & 0x00ffff) | (v << 16); break;
      case 6: en = (en & 0xff00ff) | (v << 8); break;
      case 7: en = (en & 0xffff00) | v; if (state == 0) mp_end = en; else lp_end = en; break;
    }
  }
  void next() {
    int16_t out[1152 * 2];
    while (state != 0) {
      int p = pos;
      if (fx->frame(p, mp_end * 8, out, winf)) {
        pos = p;
        for (int i = 0; i < 1152; i++)
          q.push_back(((uint32_t)(uint16_t)out[2 * i] << 16) | (uint16_t)out[2 * i + 1]);
        return;
      }
      if (state == 2) { if (pos == (int)lp_start * 8) state = 0; pos = lp_start * 8; if (lp_end) mp_end = lp_end; }
      else state = 0;
    }
  }
};

static std::vector<uint8_t> load(const char *p, size_t n) {
  std::vector<uint8_t> v(n, 0xff);
  FILE *f = fopen(p, "rb"); if (!f) return {};
  size_t r = fread(v.data(), 1, n, f); fclose(f);
  if (r != n) return {};
  return v;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *zp  = getenv("DSB_Z80ROM") ? getenv("DSB_Z80ROM") : "build/rom/dsb/epr-16471.2";
  const char *mpp = getenv("DSB_MPEG")   ? getenv("DSB_MPEG")   : "build/rom/dsb/mpeg.bin";
  zr = load(zp, 128 << 10); mp = load(mpp, 4 << 20);
  if (zr.empty() || mp.empty()) { printf("dsb_board: SKIPPED (ROMs not readable)\n"); return 0; }
  { FILE *t = fopen("rtl/sound/dsb_tables.svh", "r"); char line[256]; int i, v;
    while (fgets(line, sizeof line, t)) if (sscanf(line, "  win[%d] = %d;", &i, &v) == 2) winf[i] = (double)((v & 0x20000) ? v - 0x40000 : v) / 65536.0;
    fclose(t); }
  double secs = getenv("DSB_SECS") ? atof(getenv("DSB_SECS")) : 70.0;
  int LAT = getenv("DSB_LAT") ? atoi(getenv("DSB_LAT")) : 40;
  int volmame = getenv("DSB_VOLMAME") ? 1 : 0;
  // DSB_LOOSE: leave out the main loop's idle `e8 c4` (one per 256 passes),
  // whose count before each command depends on how long the boot took -- for
  // runs at latencies the Z80 cannot hide, where the boot finishes late.
  bool loose = getenv("DSB_LOOSE") != nullptr;
  const char *cap = getenv("DSB_CAP") ? getenv("DSB_CAP") : "build/rom/dsb/cap300.txt";
  const double CLK = 560e6 / 19;

  // MAME's side: the bytes in, the port writes and UART reads out
  struct Ev { double t; int port, v; char k; };
  std::deque<std::pair<uint64_t, int>> rx;
  std::deque<Ev> mame;
  if (FILE *f = fopen(cap, "r")) {
    char line[256];
    while (fgets(line, sizeof line, f)) {
      double t; char k[8]; unsigned a, b;
      int n = sscanf(line, "%lf %7s %x %x", &t, k, &a, &b);
      if (n == 3 && std::string(k) == "TX") rx.push_back({(uint64_t)((t + 320e-6) * CLK), (int)a});
      if (n == 4 && std::string(k) == "ZW" && t < secs && !(loose && a == 0xe8 && b == 0xc4)) mame.push_back({t, (int)a, (int)b, 'W'});
      if (n == 4 && std::string(k) == "ZR" && a == 0xf0 && t < secs) mame.push_back({t, (int)a, (int)b, 'R'});
    }
    fclose(f);
  } else { printf("dsb_board: SKIPPED (no capture %s)\n", cap); return 0; }

  // SDRAM image, word addressed: ROM, MPEG, RAM (RAM and the rest unwritten)
  const uint32_t ROMB = 0x1480000, MPB = 0x1490000, RAMB = 0x1690000;
  std::vector<uint16_t> ram(0x4000, 0xffff);
  auto rd = [&](uint32_t a) -> uint16_t {
    if (a >= ROMB && a < ROMB + 0x10000) { uint32_t b = (a - ROMB) * 2; return zr[b] | (zr[b + 1] << 8); }
    if (a >= MPB && a < MPB + 0x200000)  { uint32_t b = (a - MPB) * 2;  return mp[b] | (mp[b + 1] << 8); }
    if (a >= RAMB && a < RAMB + 0x4000)  return ram[a - RAMB];
    return 0xffff;
  };

  auto *h = new Vdsb_board_harness;
  Ref ref;
  std::mt19937 rng(777);
  h->vol_mame = volmame; h->rst_n = 0; h->rx_tog = 0; h->s_ack = 0;
  for (int i = 0; i < 20; i++) { h->clk = 0; h->eval(); h->clk = 1; h->eval(); }
  h->rst_n = 1;

  long fails = 0, wchk = 0, schk = 0, ochk = 0, rxn = 0, bad_mem = 0, nreq = 0;
  std::deque<uint32_t> popq;
  int vol = 0x7f, pan = 0;
  int pend = -1; uint32_t pa = 0; bool pw = false; uint16_t pd = 0; uint8_t pbe = 0;
  double dt_sum = 0, dt_max = 0; long dt_n = 0;
  uint64_t T = 0, cyc = 0, end = (uint64_t)(secs * CLK);
  while (cyc < end) {
    if (!rx.empty() && rx.front().first <= cyc) { h->rx_byte = rx.front().second; h->rx_tog ^= 1; rx.pop_front(); rxn++; }
    // memory: a one-cycle request pulse, answered after [1, LAT]
    h->s_ack = 0;
    if (pend == 0) {
      if (pw) { if (pa >= RAMB && pa < RAMB + 0x4000) { uint16_t &w = ram[pa - RAMB];
                  if (pbe & 1) w = (w & 0xff00) | (pd & 0xff); if (pbe & 2) w = (w & 0x00ff) | (pd & 0xff00); }
                else bad_mem++; }
      else h->s_dout = rd(pa);
      h->s_ack = 1; pend = -1;
    } else if (pend > 0) pend--;
    h->clk = 0; h->eval(); h->clk = 1; h->eval();
    if (h->s_req) {
      nreq++;
      if (pend >= 0) { printf("FAIL: second request while one is outstanding\n"); fails++; }
      pa = h->s_addr; pw = h->s_we; pd = h->s_din; pbe = h->s_be; pend = 1 + (int)(rng() % LAT);
    }
    if (h->tick) T++;
    // 1. port accesses against MAME
    if ((h->io_wr || (h->io_rd && h->io_addr == 0xf0)) && !(loose && h->io_wr && h->io_addr == 0xe8 && h->io_data == 0xc4)) {
      char k = h->io_wr ? 'W' : 'R';
      double t = T / 4e6;
      if (mame.empty()) { if (fails < 20) printf("FAIL: %c %02x=%02x at %.6f s, MAME has nothing more\n", k, h->io_addr, h->io_data, t); fails++; }
      else {
        Ev e = mame.front(); mame.pop_front(); wchk++;
        if (e.k != k || e.port != h->io_addr || e.v != h->io_data) {
          if (fails < 20) printf("FAIL: port %zu: ours %c %02x=%02x at %.6f s, MAME %c %02x=%02x at %.6f s\n",
                                 (size_t)wchk, k, h->io_addr, h->io_data, t, e.k, e.port, e.v, e.t);
          fails++;
        }
        if (getenv("DSB_SHOWT") && wchk <= atoi(getenv("DSB_SHOWT")))
          printf("  %ld: ours %c %02x=%02x %.6f  MAME %.6f\n", wchk, k, h->io_addr, h->io_data, t, e.t);
        double dt = t - e.t; dt_sum += dt; dt_n++; if (fabs(dt) > fabs(dt_max)) dt_max = dt;
      }
      if (h->io_wr && (h->io_addr & 0xf0) == 0xe0) {
        int a = h->io_addr & 0xf;
        ref.wr(a, h->io_data);
        if (a == 0 && h->io_data == 0) popq.clear();
        if (a == 8 && (volmame || !(h->io_data & 0x80))) vol = (~h->io_data) & 0x7f;
        if (a == 9) pan = h->io_data & 3;
      }
    }
    // 2. decoded samples against the model
    if (h->smp_stb) {
      popq.push_back(h->smp_lr);
      if (ref.q.empty()) ref.next();
      if (ref.q.empty()) { if (fails < 20) printf("FAIL: a sample the reference does not have\n"); fails++; }
      else { uint32_t e = ref.q.front(); ref.q.pop_front(); schk++;
             if (e != h->smp_lr) { if (fails < 20) printf("FAIL: sample %ld %08x vs %08x\n", schk, h->smp_lr, e); fails++; } }
      // EAGERLY, as MAME does: the moment a frame's samples run out it decodes
      // the next, and a frame that fails at the end address still advances
      // the synthesis history. A lazy reference would skip that frame when a
      // stop arrives first, and disagree with both MAME and the RTL.
      if (ref.q.empty()) ref.next();
    }
    // 3. the 32 kHz output
    if (h->out_stb) {
      if (h->out_src && !popq.empty()) {
        uint32_t s = popq.front(); popq.pop_front();
        int16_t L = s >> 16, R = s & 0xffff, sl = pan == 2 ? R : L, sr = pan == 1 ? L : R;
        int16_t el = pan == 3 ? 0 : (int16_t)((sl * vol) >> 7), er = pan == 3 ? 0 : (int16_t)((sr * vol) >> 7);
        ochk++;
        if (el != (int16_t)h->out_l || er != (int16_t)h->out_r) { if (fails < 20) printf("FAIL: out %d %d vs %d %d\n", (int16_t)h->out_l, (int16_t)h->out_r, el, er); fails++; }
      }
    }
    cyc++;
  }
  if (h->trap) { printf("FAIL: the Z80 executed an opcode outside its census\n"); fails++; }
  if (bad_mem) { printf("FAIL: %ld writes outside the Z80's RAM\n", bad_mem); fails++; }
  size_t left = mame.size();
  if (left > 2) { printf("FAIL: MAME made %zu more port accesses than we did\n", left); fails++; }
  printf("dsb_board[lat=%d%s%s,%.0fs]: ports=%ld fails=%ld samples=%ld out=%ld rx=%ld dt_mean=%.1fus dt_max=%.1fus sdram=%.0f/s\n",
         LAT, volmame ? ",volmame" : "", loose ? ",loose" : "", secs, wchk, fails, schk, ochk, rxn,
         dt_n ? 1e6 * dt_sum / dt_n : 0.0, 1e6 * dt_max, nreq / secs);
  delete h;
  return fails ? 1 : 0;
}
