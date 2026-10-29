// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// dsb_mpeg against tools/dsb/dsb_fixmodel.h, BIT-EXACT, sample for sample.
//
// The reference side reproduces dsbz80.cpp's register and play/loop/stop logic
// around the fixed-point decoder (which tools/dsb/dsb_cmp.cpp holds within
// 1 LSB of MAME's own decoder). Every scenario plays real Star Wars data:
//   - every song in the Z80's table, from its start, for NF frames, then stop;
//   - every song's last frames, so the frame that would cross the end address
//     is dropped and play stops (MAME's limit rule);
//   - a looping play that runs off the end into its latched loop start and
//     loop end, more than once;
//   - the loop abort (failing AT the loop start stops play);
//   - a stop mid-frame then a play, and a play mid-frame (MAME: the frame in
//     progress finishes, then the new position);
// with SDRAM latency drawn per request from [1, LAT], LAT swept 1..400.
//
// Output stage: every 32 kHz sample is checked against the decoded stream
// with pan and volume applied, both volume modes.
//
//   DSB_MPEG (default build/rom/dsb/mpeg.bin, from tools/dsb/prepare.sh)
//   DSB_FULL=1 plays every song to its end (long). DSB_LAT, DSB_VOLMAME.
#include "Vdsb_mpeg.h"
#include "verilated.h"
#include "dsb_fixmodel.h"
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <string>
#include <vector>

static std::vector<uint8_t> rom;
static double winf[512];
static Vdsb_mpeg *d;
static uint64_t cyc = 0;
static std::mt19937 rng(12345);
static int LAT = 20;
static long fails = 0, checks = 0, frames_chk = 0, outchk = 0;
static int mem_wait = -1;

// ---------------------------------------------------------------- reference
struct Ref {
  FixDec *fx;
  uint32_t st = 0, en = 0, mp_start = 0, mp_end = 0, lp_start = 0, lp_end = 0, state = 0;
  int pos = 0;
  std::deque<uint32_t> q;          // decoded, not yet seen from the RTL
  Ref() { fx = new FixDec(rom.data(), FixCfg()); fx->trace = getenv("DSB_CTRACE") != nullptr; }
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
  // sound_stream_update's decode loop: one frame, or nothing once stopped
  bool next() {
    int16_t out[1152 * 2];
    while (state != 0) {
      int p = pos;
      if (fx->frame(p, mp_end * 8, out, winf)) {
        pos = p;
        for (int i = 0; i < 1152; i++)
          q.push_back(((uint32_t)(uint16_t)out[2 * i] << 16) | (uint16_t)out[2 * i + 1]);
        return true;
      }
      if (state == 2) {
        if (pos == (int)lp_start * 8) state = 0;
        pos = lp_start * 8;
        if (lp_end) mp_end = lp_end;
      } else state = 0;
    }
    return false;
  }
};
static Ref *ref;

// ---------------------------------------------------------------- RTL side
static std::deque<uint32_t> popq;    // pushed into the FIFO, not yet output
static int vol = 0x7f, pan = 0, volmame = 0;
static long got = 0;

static void tick() {
  // memory: one request outstanding, random latency, unwritten reads 0xFFFF
  if (d->m_req && mem_wait < 0) mem_wait = 1 + (int)(rng() % LAT);
  d->m_ack = 0;
  if (mem_wait == 0) {
    uint32_t a = d->m_addr * 2;
    d->m_data = (a + 1 < rom.size()) ? (rom[a] | (rom[a + 1] << 8)) : 0xffff;
    d->m_ack = 1;
    mem_wait = -1;
  } else if (mem_wait > 0) mem_wait--;
  d->clk = 0; d->eval(); d->clk = 1; d->eval(); cyc++;
  if (d->m_ack) { d->m_ack = 0; }
  if (d->smp_stb) {
    got++;
    popq.push_back(d->smp_lr);
    if (ref->q.empty()) ref->next();
    if (ref->q.empty()) {
      if (fails < 10) printf("FAIL: RTL produced a sample the reference does not have (cycle %llu)\n", (unsigned long long)cyc);
      fails++;
    } else {
      uint32_t e = ref->q.front(); ref->q.pop_front(); checks++;
      if (e != d->smp_lr) {
        if (fails < 10) printf("FAIL: sample %ld rtl=%08x ref=%08x\n", got, d->smp_lr, e);
        fails++;
      }
    }
  }
  if (d->out_stb) {
    if (d->out_src) {
      if (popq.empty()) { fails++; printf("FAIL: output with nothing pushed\n"); }
      else {
        uint32_t s = popq.front(); popq.pop_front();
        int16_t L = s >> 16, R = s & 0xffff;
        int16_t sl = pan == 2 ? R : L, sr = pan == 1 ? L : R;
        int16_t el = pan == 3 ? 0 : (int16_t)((sl * vol) >> 7);
        int16_t er = pan == 3 ? 0 : (int16_t)((sr * vol) >> 7);
        outchk++;
        if (el != (int16_t)d->out_l || er != (int16_t)d->out_r) {
          if (fails < 10) printf("FAIL: out %d %d expected %d %d (pan %d vol %d)\n", (int16_t)d->out_l, (int16_t)d->out_r, el, er, pan, vol);
          fails++;
        }
      }
    } else if (d->out_l || d->out_r) { fails++; printf("FAIL: silence not silent\n"); }
  }
}

static void wr(int a, int v) {
  d->reg_we = 1; d->reg_a = a; d->reg_d = v; tick(); d->reg_we = 0; tick();
  ref->wr(a, v);
  if (a == 0 && v == 0) popq.clear();
  if (a == 8 && (volmame || !(v & 0x80))) vol = (~v) & 0x7f;
  if (a == 9) pan = v & 3;
}
static void set24(int base, uint32_t v) { wr(base, (v >> 16) & 0xff); wr(base + 1, (v >> 8) & 0xff); wr(base + 2, v & 0xff); }

// run until `nsamp` more samples are seen, or until the RTL goes quiet
static void run_samples(long nsamp, long idle_limit = 3000000) {
  long target = got + nsamp, idle = 0, last = got;
  while (got < target) {
    tick();
    if (got != last) { last = got; idle = 0; } else if (++idle > idle_limit) break;
  }
}
static void drain_quiet() { run_samples(1L << 40, 400000); }

static void check_ref_empty(const char *what) {
  // whatever the reference still owes must be nothing once both are stopped
  ref->next();
  if (!ref->q.empty()) {
    printf("FAIL: %s: reference has %zu samples the RTL never produced\n", what, ref->q.size());
    fails++; ref->q.clear();
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *mp = getenv("DSB_MPEG") ? getenv("DSB_MPEG") : "build/rom/dsb/mpeg.bin";
  FILE *f = fopen(mp, "rb");
  if (!f) { printf("dsb_mpeg: SKIPPED (cannot open %s)\n", mp); return 0; }
  rom.assign(4 << 20, 0xff); size_t n = fread(rom.data(), 1, 4 << 20, f); fclose(f);
  if (n != (4u << 20)) { printf("dsb_mpeg: short MPEG image (%zu)\n", n); return 1; }
  // window from the RTL's own table, so both sides hold the same integers
  { FILE *t = fopen("rtl/sound/dsb_tables.svh", "r"); char line[256]; int i, v;
    while (fgets(line, sizeof line, t)) if (sscanf(line, "  win[%d] = %d;", &i, &v) == 2) winf[i] = (double)((v & 0x20000) ? v - 0x40000 : v) / 65536.0;
    fclose(t); }
  bool full = getenv("DSB_FULL") != nullptr;
  int NF = full ? 100000 : 2;
  LAT = getenv("DSB_LAT") ? atoi(getenv("DSB_LAT")) : 20;
  volmame = getenv("DSB_VOLMAME") ? 1 : 0;

  d = new Vdsb_mpeg; ref = new Ref;
  d->vol_mame = volmame;
  d->rst_n = 0; for (int i = 0; i < 10; i++) tick(); d->rst_n = 1; tick();

  // the song table, as the firmware's: start, end, mode
  struct Song { uint32_t s, e; int mode; uint32_t ls; };
  std::vector<Song> songs;
  { FILE *t = fopen("tools/dsb/swa_songs.txt", "r"); unsigned a, b; while (fscanf(t, "%x %x", &a, &b) == 2) songs.push_back({a, b, 1, 0}); fclose(t); }

  // ---- 1. every entry, from its start (and for DSB_FULL, to its end)
  int sn = 0;
  for (auto &s : songs) {
    wr(0, 0); set24(2, s.s); set24(5, s.e);
    wr(9, sn % 4); wr(8, (sn * 13) & 0xff);
    wr(0, 1);
    run_samples((long)NF * 1152 + 500);   // stop MID-frame: see dsb_mpeg's note on stops
    if (full) { drain_quiet(); check_ref_empty("full song"); }
    wr(0, 0); ref->q.clear(); popq.clear();
    frames_chk += full ? 0 : NF;
    sn++;
  }
  wr(9, 0);
  // ---- 2. the end of every song: the frame that crosses the end is dropped
  for (auto &s : songs) {
    long g0 = got;
    wr(0, 0); set24(2, s.e - 1500); set24(5, s.e); wr(0, 1);
    drain_quiet(); check_ref_empty("end of song");
    if (getenv("DSB_VERBOSE")) printf("end-of-song %06x: samples %ld..%ld\n", s.e, g0, got);
  }
  // ---- 3. a loop off the end, into the loop start and the loop end, thrice
  {
    auto &s = songs[1];
    wr(0, 0); set24(2, s.e - 1300); set24(5, s.e); wr(0, 2);
    set24(2, s.s + 2000); set24(5, s.s + 2000 + 2400);       // latched as loop
    run_samples(10 * 1152);
    wr(0, 0); ref->q.clear(); popq.clear();
  }
  // ---- 4. loop abort: the loop start itself cannot decode
  {
    auto &s = songs[2];
    wr(0, 0); set24(2, s.e - 1300); set24(5, s.e); wr(0, 2);
    set24(2, s.e - 10); set24(5, 0);                           // loop end 0 = keep
    drain_quiet(); check_ref_empty("loop abort");
  }
  // ---- 5. stop mid-frame, play again; play mid-frame
  {
    auto &s = songs[5];
    wr(0, 0); set24(2, s.s); set24(5, s.e); wr(0, 1);
    run_samples(700);
    wr(0, 0); ref->q.clear(); popq.clear();
    for (int i = 0; i < 5000; i++) tick();
    wr(0, 1);
    run_samples(1152 + 100);
    // play mid-frame, no stop: the frame in progress finishes, then mp_start
    wr(0, 1);
    run_samples(3 * 1152);
    wr(0, 0); ref->q.clear(); popq.clear();
  }
  for (int i = 0; i < 2000; i++) tick();

  printf("dsb_mpeg[lat=%d%s%s]: checks=%ld fails=%ld out=%ld frames=%u drops=%u\n", LAT,
         volmame ? ",volmame" : "", full ? ",full" : "", checks, fails, outchk,
         d->dbg_frames, d->dbg_fails);
  delete d;
  return fails ? 1 : 0;
}
