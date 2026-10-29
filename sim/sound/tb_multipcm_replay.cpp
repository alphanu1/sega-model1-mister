// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
//
// ONE MULTIPCM, DRIVEN BY THE REFERENCE'S OWN REGISTER TRAFFIC.
//
// The full sound-board bench needs a 68000, a command stream and minutes of
// simulation to reach a game's sound, and what comes out is the mix of three
// chips. This puts m2_multipcm alone on the bench, replays the register
// writes MAME's sound CPU made to one chip (captured by a write tap with
// timestamps), serves the chip's 4 MB sample region exactly as SDRAM holds
// it, and plays the same writes through a transcription of MAME's gew.cpp
// (multipcm_ref.h). Both run in sample time, so the two outputs line up
// sample for sample and can be compared directly - level, spectrum and, per
// voice, what each slot is playing.
//
// Writes are applied at a pass boundary: every write timestamped before
// sample n's time is in before sample n is produced, on both sides.
//
// Environment:
//   REGS    register log, lines "<seconds> <addr hex> <data hex>"
//   CHIP    1 (C40000/C50000) or 2 (C60000/C70000)
//   REGION  the chip's 4 MB region image (the MRA's sound stream slice)
//   SECONDS how much to play (default 60)
//   OUT     output prefix: <OUT>_rtl.wav and <OUT>_ref.wav at 44,643 Hz
#include <verilated.h>
#include "Vm2_multipcm.h"
#include "Vm2_multipcm___024root.h"
#include "multipcm_ref.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <random>

static std::vector<uint8_t> load(const char *p) {
  std::vector<uint8_t> v; FILE *f = p ? std::fopen(p, "rb") : nullptr;
  if (!f) return v;
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  v.resize(n); if (std::fread(v.data(), 1, n, f) != (size_t)n) v.clear();
  std::fclose(f); return v;
}
static void wav(const std::string &p, const std::vector<int16_t> &d, uint32_t rate) {
  FILE *f = std::fopen(p.c_str(), "wb"); if (!f) return;
  uint32_t nd = d.size() * 2, sz = 36 + nd, br = rate * 4, s1 = 16; uint16_t fmt = 1, ch = 2, ba = 4, bits = 16;
  std::fwrite("RIFF",1,4,f); std::fwrite(&sz,4,1,f); std::fwrite("WAVEfmt ",1,8,f); std::fwrite(&s1,4,1,f);
  std::fwrite(&fmt,2,1,f); std::fwrite(&ch,2,1,f); std::fwrite(&rate,4,1,f); std::fwrite(&br,4,1,f);
  std::fwrite(&ba,2,1,f); std::fwrite(&bits,2,1,f); std::fwrite("data",1,4,f); std::fwrite(&nd,4,1,f);
  std::fwrite(d.data(), 2, d.size(), f); std::fclose(f);
}
static int16_t clamp16(int32_t v) { return v > 32767 ? 32767 : v < -32768 ? -32768 : v; }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *regs_p = std::getenv("REGS"), *region_p = std::getenv("REGION");
  const int chip = std::getenv("CHIP") ? atoi(std::getenv("CHIP")) : 1;
  const double secs = std::getenv("SECONDS") ? atof(std::getenv("SECONDS")) : 60.0;
  const std::string out = std::getenv("OUT") ? std::getenv("OUT") : "replay";
  // SYNTH=1: no ROM needed. A random 4 MB region whose first 6 KB is a
  // descriptor table - 8- and 12-bit, every envelope field, loops inside,
  // at and past their ends, all-FF entries like NetMerc's - and a random
  // register stream of key-ons, key-offs, sample changes, pitch, pan, level
  // and banks. Run with REF_RTL=1 it is the RTL's fuzz against MAME's
  // arithmetic, and it is what `make test_multipcm` runs.
  const bool synth = std::getenv("SYNTH") && atoi(std::getenv("SYNTH"));
  std::mt19937 rng(0x5560);
  std::vector<uint8_t> region = synth ? std::vector<uint8_t>(0x400000) : load(region_p);
  struct W { double t; int reg; int bank; uint8_t d; };
  std::vector<W> ws;
  if (synth) {
    for (auto &b : region) b = rng() & 0xff;
    for (int i = 0; i < 512; i++) {
      uint8_t *e = &region[i * 12];
      const int kind = rng() % 8;
      if (kind == 0) { std::memset(e, 0xff, 12); continue; }        // NetMerc's bad dump
      uint32_t start = rng() & 0x3fffff, len = 1 + rng() % 0x10000, loop = rng() % (len + 1);
      if (kind == 1) loop = len + rng() % 64;                          // loop past the end
      if (kind == 2) loop = len;                                       // empty loop
      e[0] = (start >> 16) | (rng() & 0xc0); e[1] = start >> 8; e[2] = start;
      e[3] = loop >> 8; e[4] = loop;
      const uint32_t neg = (0x10000 - len) & 0xffff; e[5] = neg >> 8; e[6] = neg;
      e[7] = rng() & 0xff; e[8] = rng() & 0xff; e[9] = rng() & 0xff; e[10] = rng() & 0xff; e[11] = rng() & 0xff;
      if (rng() % 2) e[8] |= 0xf0;                                    // instant attack, as games mostly use
    }
    const double rate = 10000000.0 / 224.0, secs_s = secs;
    uint8_t sel[2] = {0, 0};
    int smp_hi8[32] = {0};
    // Every slot gets a sample number before anything keys it on, as games
    // do. MAME keys on whatever reg 1 last loaded (nothing, after reset);
    // the RTL re-reads the descriptor at key-on from reg 1 as it stands. The
    // two agree whenever reg 1 has been written - see docs/findings.md.
    for (int sl = 0; sl < 32; sl++) {
      ws.push_back({0.0, 1, 0, (uint8_t)sl}); ws.push_back({0.0, 2, 0, 2}); ws.push_back({0.0, 0, 0, 0});
      ws.push_back({0.0, 2, 0, 1}); ws.push_back({0.0, 0, 0, (uint8_t)(rng() & 0xff)});
    }
    for (double t = 0; t < secs_s; t += (1 + rng() % 400) / rate) {
      const int nw = (rng() % 3 == 0) ? 1 : 1 + rng() % 6;
      for (int k = 0; k < nw; k++) {
        const int op = rng() % 16;
        if (op == 0) { ws.push_back({t, -1, 1, (uint8_t)(rng() & 3)}); continue; }
        const uint8_t slot = rng() % 32;
        ws.push_back({t, 1, 0, slot});
        int reg; uint8_t v = rng() & 0xff;
        if      (op < 6)  { reg = 4; v = (rng() % 3) ? 0x80 : 0x00; }
        else if (op < 8)  reg = 1;
        else if (op < 10) reg = 3;
        else if (op < 12) reg = 2;
        else if (op < 13) reg = 0;
        else if (op < 15) reg = 5;
        else              reg = rng() % 8;
        // Reg 2 bit 0 is the sample number's bit 8, latched by MAME at the
        // reg 1 write and re-read here when the descriptor is fetched, which
        // can be after a reg 2 write in the same burst. Games set it before
        // reg 1 and keep it; so does this stream.
        if (reg == 1) {
          // bit 8 of the sample number goes in first, as games order it
          smp_hi8[slot] = rng() & 1;
          ws.push_back({t, 2, 0, 2});
          ws.push_back({t, 0, 0, (uint8_t)((rng() & 0xfe) | smp_hi8[slot])});
        }
        if (reg == 2) v = (v & 0xfe) | smp_hi8[slot];
        ws.push_back({t, 2, 0, (uint8_t)reg});
        ws.push_back({t, 0, 0, v});
        (void)sel;
      }
    }
  } else {
  if (region.size() != 0x400000) { std::printf("multipcm_replay: SKIP (REGION must be a 4 MB image)\n"); return 0; }
  { FILE *f = regs_p ? std::fopen(regs_p, "r") : nullptr;
    if (!f) { std::printf("multipcm_replay: SKIP (no REGS log)\n"); return 0; }
    double t; unsigned a, d;
    const unsigned base = chip == 1 ? 0xc40000 : 0xc60000, bnk = chip == 1 ? 0xc50000 : 0xc70000;
    while (std::fscanf(f, "%lf %x %x", &t, &a, &d) == 3) {
      if (a >= base && a < base + 8)  ws.push_back({t, (int)((a & 7) >> 1), 0, (uint8_t)d});
      else if ((a & ~1u) == bnk)      ws.push_back({t, -1, 1, (uint8_t)d});
    }
    std::fclose(f); }
  }

  // MAME's view of the chip's 22-bit space: segam1audio's mpcm map, 1 MB
  // direct, 1 MB banked, and nothing above 2 MB.
  int bank = 0;
  MultiPcmRef ref(10000000.0f);
  // REF_ALIAS=1 reads the RTL's way instead: everything at or above 1 MB
  // through the bank window, 2-4 MB included.
  const bool ref_alias = std::getenv("REF_ALIAS") && atoi(std::getenv("REF_ALIAS"));
  ref.no_eg     = std::getenv("REF_NOEG") && atoi(std::getenv("REF_NOEG"));
  ref.fmt8      = std::getenv("REF_8BIT") && atoi(std::getenv("REF_8BIT"));
  ref.no_interp = std::getenv("REF_NOINTERP") && atoi(std::getenv("REF_NOINTERP"));
  // REF_RTL=1: the reference with the RTL's known simplifications (no LFO,
  // exact step, its level/pan/mix) - everything else must then match the
  // RTL sample for sample, and the bench counts where it does not.
  const bool ref_rtl = std::getenv("REF_RTL") && atoi(std::getenv("REF_RTL"));
  if (ref_rtl) { ref.no_lfo = ref.exact_step = ref.rtl_mix = true; }
  if (std::getenv("REF_NOLFO") && atoi(std::getenv("REF_NOLFO"))) ref.no_lfo = true;
  if (std::getenv("REF_EXACTSTEP") && atoi(std::getenv("REF_EXACTSTEP"))) ref.exact_step = true;
  if (std::getenv("REF_RTLMIX") && atoi(std::getenv("REF_RTLMIX"))) ref.rtl_mix = true;
  ref.read_byte = [&](uint32_t a) -> uint8_t {
    a &= 0x3fffff;
    if (a < 0x100000) return region[a];
    if (a < 0x200000 || ref_alias) return region[(bank & 3) * 0x100000 + (a & 0xfffff)];
    return 0;
  };

  auto *d = new Vm2_multipcm;
  d->clk = 0; d->ce = 1; d->rst = 1; d->cs = 0; d->we = 0; d->rom_ack = 0; d->bank_sel = 0;
  for (int i = 0; i < 8; i++) { d->clk = !d->clk; d->eval(); }
  d->rst = 0;

  const double rate = 10000000.0 / 224.0;
  // DUMP_FROM/DUMP_TO (seconds): every sample in the window to <OUT>_dump.txt -
  // "n ref_l ref_r voice0..27" (ref, per voice before pan), "R n rtl_l rtl_r",
  // and the first 400 RTL fetches as "F n slot addr data".
  const double dfrom = std::getenv("DUMP_FROM") ? atof(std::getenv("DUMP_FROM")) : -1;
  const double dto   = std::getenv("DUMP_TO")   ? atof(std::getenv("DUMP_TO"))   : -1;
  FILE *dump = dfrom >= 0 ? std::fopen((out + "_dump.txt").c_str(), "w") : nullptr;
  const long nsamp = (long)(secs * rate);
  std::vector<int16_t> o_rtl, o_ref; o_rtl.reserve(nsamp * 2); o_ref.reserve(nsamp * 2);
  size_t wi = 0; long n = 0; int rtl_bank = 0;
  int pend = 0, ntrace = 0; uint32_t pend_addr = 0; long cyc = 0, stalls = 0;
  bool pass_open = true;                      // writes for sample 0 go in first

  // LAT: ROM latency in clocks, random up to this (default 2, fixed).
  // CE: the chip's enable, 1 = every clock (the hardest spacing for the
  // registered ROMs), N = a random 1-in-N.
  const int lat_max = std::getenv("LAT") ? atoi(std::getenv("LAT")) : 0;
  const int ce_n = std::getenv("CE") ? atoi(std::getenv("CE")) : 1;
  int lat_now = 2; bool writing = false;
  auto tick = [&]() {
    if (!writing) d->ce = (ce_n <= 1) ? 1 : (rng() % ce_n == 0);
    d->clk = 1; d->eval();
    // ROM: acknowledge after the latency, held for a cycle then dropped.
    if (d->rom_ack) d->rom_ack = 0;
    else if (d->rom_req) { if (++pend >= lat_now) { lat_now = lat_max ? 1 + rng() % lat_max : 2; d->rom_data = region[d->rom_addr & 0x3fffff]; d->rom_ack = 1; pend = 0;
      if (dump && n / rate >= dfrom && n / rate < dto && ntrace < 400) { ntrace++;
        std::fprintf(dump, "F %ld slot %d addr %06x data %02x\n", n, d->rom_slot, d->rom_addr, d->rom_data); } } }
    d->clk = 0; d->eval(); cyc++;
  };

  // Each write's pass: the first sample whose time is at or after it.
  std::vector<uint32_t> blo(nsamp + 2), bhi(nsamp + 2);
  { size_t k = 0;
    for (long m = 0; m <= nsamp + 1; m++) {
      blo[m] = k;
      while (k < ws.size() && ws[k].t <= m / rate) k++;
      bhi[m] = k;
    } }
  // MIDPASS=1: the RTL gets each burst DURING the pass before it, as a 68000
  // write would land, not at the boundary - once the highest slot it touches
  // has had its tick 0 (between tick 0 and the envelope's update when it can
  // be: the retrigger-mid-slot path). MAME still sees it at the boundary, and
  // the RTL must agree. A burst with a bank write, or a level or pan write to
  // that slot (read by the mix at tick 4), goes in at the boundary instead.
  const bool midpass = std::getenv("MIDPASS") && atoi(std::getenv("MIDPASS"));
  static const int V2C[32] = {0,1,2,3,4,5,6,-1, 7,8,9,10,11,12,13,-1, 14,15,16,17,18,19,20,-1, 21,22,23,24,25,26,27,-1};
  std::vector<char> injected(nsamp + 2, 0);
  long early = 0, stale_cov = 0;
  auto inject = [&](long m) {
    if (injected[m]) return;
    injected[m] = 1;
    d->ce = 0; writing = true;
    for (uint32_t k = blo[m]; k < bhi[m]; k++) {
      const W &w = ws[k];
      if (w.bank) { rtl_bank = w.d & 3; d->bank_sel = rtl_bank; continue; }
      d->cs = 1; d->we = 1; d->addr = w.reg; d->wdata = w.d; tick();
      d->cs = 0; d->we = 0; tick();
    }
    writing = false;
  };
  // For a burst: the highest channel it writes, whether it may go mid-pass.
  auto plan = [&](long m, int &maxc, bool &ok) {
    maxc = -1; ok = true; int sel = -1, reg = 0;
    for (uint32_t k = blo[m]; k < bhi[m]; k++) {
      const W &w = ws[k];
      if (w.bank) { ok = false; continue; }
      if (w.reg == 1) sel = V2C[w.d & 0x1f];
      else if (w.reg == 2) reg = w.d > 7 ? 7 : w.d;
      else if (sel >= 0) { if (sel > maxc) maxc = sel; }
    }
    if (!ok) return;
    sel = -1; reg = 0;
    for (uint32_t k = blo[m]; k < bhi[m]; k++) {
      const W &w = ws[k];
      if (w.reg == 1) sel = V2C[w.d & 0x1f];
      else if (w.reg == 2) reg = w.d > 7 ? 7 : w.d;
      else if (sel == maxc && (reg == 0 || reg == 5)) ok = false;
    }
  };
  int pmax = -1; bool pok = false;

  int32_t vref[28];
  while (n < nsamp) {
    if (pass_open) {
      const double tn = n / rate;
      for (uint32_t k = blo[n]; k < bhi[n]; k++) {
        const W &w = ws[k];
        if (w.bank) bank = w.d & 3; else ref.write(w.reg, w.d);
        if (dump && tn >= dfrom - 0.01 && tn < dto) std::fprintf(dump, "W %ld %d %02x\n", n, w.reg, w.d);
      }
      wi = bhi[n];
      inject(n);                 // at the boundary, unless it went in early
      if (midpass) plan(n + 1, pmax, pok);
      int32_t l, r; ref.step(l, r, vref);
      if (dump && n / rate >= dfrom && n / rate < dto) {
        std::fprintf(dump, "%ld %d %d", n, l, r);
        for (int v = 0; v < 28; v++) std::fprintf(dump, " %d", vref[v]);
        std::fprintf(dump, "\n");
      }
      o_ref.push_back(clamp16(l)); o_ref.push_back(clamp16(r));
      pass_open = false;
    }
    tick();
    // Coverage of the race the envelope guards: a retrigger completing for
    // the slot whose update is pending (eg_stale), and a key-off landing in
    // the same window (rel_pend set after the snapshot).
    if (d->rootp->m2_multipcm__DOT__eg_p_valid && d->rootp->m2_multipcm__DOT__eg_stale) stale_cov++;
    if (midpass && pok && pmax >= 0 && !injected[n + 1] && n + 1 < nsamp + 2) {
      const int rs = d->rootp->m2_multipcm__DOT__slot, rt = d->rootp->m2_multipcm__DOT__tick;
      if ((rs == pmax && rt >= 1 && rt <= 3) || rs > pmax) {
        if (!d->sample_stb) { inject(n + 1); early++; }
      }
    }
    if (d->sample_stb) {
      o_rtl.push_back((int16_t)d->out_l); o_rtl.push_back((int16_t)d->out_r);
      if (dump && n / rate >= dfrom && n / rate < dto)
        std::fprintf(dump, "R %ld %d %d\n", n, (int16_t)d->out_l, (int16_t)d->out_r);
      n++; pass_open = true;
      if (cyc > 4000L * n + 100000) { stalls++; }
    }
  }
  if (midpass) std::printf("  MIDPASS: %ld bursts went in mid-pass, %ld clocks with a stale envelope update pending\n", early, stale_cov);

  wav(out + "_rtl.wav", o_rtl, 44643);
  wav(out + "_ref.wav", o_ref, 44643);
  auto stats = [](const std::vector<int16_t> &v, double &rms, int &pk) {
    double s = 0; pk = 0; for (int16_t x : v) { s += (double)x * x; int a = x < 0 ? -x : x; if (a > pk) pk = a; }
    rms = v.empty() ? 0 : std::sqrt(s / v.size()); };
  double r1, r2; int p1, p2; stats(o_rtl, r1, p1); stats(o_ref, r2, p2);
  std::printf("multipcm_replay chip%d: %ld samples (%.1f s), %zu writes, %ld cycles\n", chip, n, n / rate, wi, cyc);
  std::printf("  RTL  rms %8.1f  peak %6d\n  MAME rms %8.1f  peak %6d\n", r1, p1, r2, p2);
  if (ref_rtl) {
    long mism = 0, first = -1; double err = 0;
    if (synth) {
      long m2 = 0; for (size_t i = 0; i < o_rtl.size() && i < o_ref.size(); i++) m2 += o_rtl[i] != o_ref[i];
      long nz = 0; for (int16_t x : o_ref) nz += x != 0;
      std::printf("m2_multipcm: checks=%zu fails=%ld nonzero=%ld writes=%zu\n", o_rtl.size(), m2, nz, wi);
    }
    for (size_t i = 0; i < o_rtl.size() && i < o_ref.size(); i++)
      if (o_rtl[i] != o_ref[i]) { mism++; if (first < 0) first = i / 2; err += (double)(o_rtl[i] - o_ref[i]) * (o_rtl[i] - o_ref[i]); }
    std::printf("  REF_RTL: %ld of %zu values differ, first at sample %ld, error rms %.2f\n",
                mism, o_rtl.size(), first, o_rtl.empty() ? 0.0 : std::sqrt(err / o_rtl.size()));
  }
  delete d;
  return 0;
}
