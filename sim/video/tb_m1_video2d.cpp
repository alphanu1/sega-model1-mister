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
// THE 2D PATH ON REAL SCENES, AGAINST ITS LINE DEADLINE.
//
// tb_m1_video proves the picture on synthetic content chosen to FIT the line
// budget, and says so: "testing correctness with content the design does not
// claim to support would be testing the wrong thing". That leaves the deadline
// itself untested on anything a game draws. tb_m1_frame does run real game code,
// but only the scenes our own V60 reaches, at an hour and a half a race, and it
// had seen 3 overruns in play where the board shows them plainly.
//
// This replays the REFERENCE's scenes instead. tools/mame_tile_dump.lua writes
// tile RAM, character RAM and palette from MAME at a run of frames, for any
// title; each snapshot is swapped in at vblank begin - the point m1_video
// latches its frame configuration - and the frame that follows is rendered
// through the real m1_video with the character port answering at a modelled
// latency. Per frame it reports:
//
//   - every line_start the sequencer did not accept (not only the Q_RUN case
//     dbg_overruns counts), split by whether the affected lines are visible
//   - the longest line render, against the 3,280-cycle line (656 dots x 5 at
//     80 MHz - the board's divider; tb_m1_video still runs /6, 96 MHz)
//   - every visible pixel against the same end-to-end reference tb_m1_video
//     uses, so "no overrun" and "right picture" are checked together
//   - a hash of the visible frame, so two builds can be compared frame by frame
//
// Usage: tb_video2d [opts] <dump-dir>...
//   -lat N     cycles a request is high before its answer (default 16, the
//              in-play mean tb_m1_frame measures; minimum 3)
//   -jit N     plus a uniform 0..N extra per request (default 0)
//   -hist F    draw each request's latency from a histogram instead: F holds
//              the 65 counts tb_m1_frame prints as "char latency histogram
//              0..64" (the last bucket is 64 and over); -lat is then ignored
//              and -scale N/100 stretches every draw (default 100)
//   -seed N    for the jitter
//   -max N     frames per directory (default all)
//   -every N   use every Nth manifest entry
//   -ppm DIR   write each frame that overran, or every frame with -ppmall
//   -q         one summary line per directory only
//   -mame      compare against MAME'S OWN PICTURE of each frame, where the
//              manifest names one (mame_tile_dump.lua SNAP=1; take it with
//              NO3D=1 so it is the 2D alone), instead of only against the
//              model below - see "THE BACKDROP CENSUS"
//   -full DIR  a second dump of the same frames WITH the 3D (SNAP=1, no
//              NO3D): a differing pixel is also counted as `seen` when MAME's
//              2D-only and full pictures agree there, i.e. no polygon covers it
//   -srcdly N  ticks between the mixer's verdict and the vid_* sample that
//              carries it (default 2); checked, see align_err
//
// Character RAM is 0xFFFF where a dump does not cover it, which is what an
// unwritten SDRAM model reads; nothing here assumes zero.

#include "Vm1_video.h"
#include "Vm1_video___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>
#include <algorithm>

static const int H_TOTAL = 656, H_VIS = 496, V_TOTAL = 424, V_VIS = 384;
static const int CE_DIV = 5;                       // 80 MHz / 5 = 16 MHz
static const int BUDGET = H_TOTAL * CE_DIV;        // 3,280 cycles a line
static const uint16_t TILE_MASK = 0x3fff;

static std::vector<uint16_t> tile_ram(0x8000, 0xffff);
static std::vector<uint16_t> char_ram(0x40000, 0xffff);
static std::vector<uint16_t> pal_ram(4096, 0xffff);

static bool load(const std::string& path, std::vector<uint16_t>& v) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return false;
  std::vector<uint8_t> b(v.size() * 2);
  size_t n = fread(b.data(), 1, b.size(), f);
  fclose(f);
  for (size_t i = 0; i < n / 2; i++) v[i] = (uint16_t)(b[2*i] | (b[2*i+1] << 8));
  return n == b.size();
}

// ----------------------------------------------------- the reference picture
// The same end-to-end model as tb_m1_video's ref_rgb, including the decisions
// recorded there (layers 2/3 draw category 0 opaque, and outside window mode
// category 1 as well; no row mask in window mode; a disabled layer draws
// nothing; the per-line H-scroll
// table at hscr bit 15 is not modelled because the RTL does not have it). It is
// a model of what the RTL is MEANT to draw, so it decides whether an overrun
// corrupted a frame - not whether the RTL agrees with MAME.
static inline uint8_t char_byte(uint32_t i) {
  uint16_t w = char_ram[(i >> 1) & 0x3ffff];
  return (i & 1) ? (uint8_t)(w >> 8) : (uint8_t)(w & 0xff);
}
static uint8_t ref_pixel(uint32_t tile, int row, int col) {
  uint8_t v = 0;
  for (int p = 0; p < 4; p++) {
    int bit = (row * 32 + col * 4 + p) ^ 8;
    uint8_t b = char_byte(tile * 32 + (bit >> 3));
    v |= (uint8_t)(((b >> (7 - (bit & 7))) & 1) << (3 - p));
  }
  return v;
}
static inline int pal5bit(int v) { v &= 0x1f; return (v << 3) | (v >> 2); }

static void ref_rgb(int x, int y, int* R, int* G, int* B) {
  int pal[4], transp[4], prio[4], dis[4];
  for (int L = 0; L < 4; L++) {
    uint16_t pctrl = tile_ram[0x5004 + (L & 2)];
    int      inwin = (pctrl & 0x6000) != 0;
    uint16_t hscr = tile_ram[0x5000 + (inwin ? (L & 2) : L)];
    uint16_t vscr = tile_ram[0x5004 + (inwin ? (L & 2) : L)];
    uint32_t mx = ((uint32_t)x - (hscr & 0x1ff)) & 0x1ff;
    uint32_t my = ((uint32_t)y + (vscr & 0x1ff)) & 0x1ff;
    uint16_t tw = tile_ram[L * 0x1000 + (my >> 3) * 64 + (mx >> 3)];
    uint32_t tn = tw & TILE_MASK;
    uint8_t px = ref_pixel(tn, my & 7, mx & 7);
    pal[L] = (((tw >> 7) & 0xff) << 4) | px;
    transp[L] = (px == 0);
    dis[L] = (vscr >> 15) & 1;               // draw_common returns: nothing drawn
    prio[L] = (tw >> 15) & 1;
  }
  int win_off[4];
  for (int L = 0; L < 4; L++) {
    uint16_t ctrl = tile_ram[0x5004 + (L & 2)];
    if (!(ctrl & 0x6000)) { win_off[L] = 0; continue; }
    if (((ctrl & 0x6000) >> 13) != 1) {
      uint16_t hs    = tile_ram[0x5000 + (L & 2)];
      int h          = hs & 0x1ff;
      int left_pick  = !(hs & 0x200);
      int owns_right = ((L & 1) != left_pick);
      win_off[L]     = ((x < h) == owns_right);
      continue;
    }
    uint16_t nv   = (uint16_t)(-(int)ctrl);
    int v         = nv & 0x1ff;
    int swap      = !(nv & 0x200);
    int pick      = (y < v) ? swap : !swap;
    win_off[L]    = ((L & 1) != pick);
  }
  int mbit[4];
  for (int L = 0; L < 4; L++) {
    uint16_t m = tile_ram[((L & 2) ? 0x6800 : 0x6000) + y * 4 + (x >> 7)];
    if (L & 1) m = (uint16_t)~m;
    mbit[L] = (m >> (15 - ((x >> 3) & 15))) & 1;
    if (tile_ram[0x5004 + (L & 2)] & 0x6000) mbit[L] = 0;   // no mask in window mode
  }
  int idx = 0;
  // Tilemaps 2/3 outside window mode: draw_rect's opaque pass writes
  // category-1 tiles too (see THE BACKDROP CENSUS below).
  auto cat0 = [&](int i) {
    bool rect = (i >= 2) && !(tile_ram[0x5004 + (i & 2)] & 0x6000);
    if (dis[i] || win_off[i] || (prio[i] && !rect) || mbit[i]) return;
    if (transp[i] && i < 2) return;
    idx = pal[i];
  };
  auto cat1 = [&](int i) {
    if (dis[i] || win_off[i] || !prio[i] || transp[i] || mbit[i]) return;
    idx = pal[i];
  };
  cat0(3); cat0(2); cat0(1); cat0(0);
  cat1(3); cat1(2); cat1(1); cat1(0);
  uint16_t e = pal_ram[idx & 0xfff];
  int r = pal5bit(e), g = pal5bit(e >> 5), b = pal5bit(e >> 10);
  if (!((e >> 15) & 1)) { r >>= 1; g >>= 1; b >>= 1; }
  *R = r; *G = g; *B = b;
}

// ------------------------------------------------- THE BACKDROP CENSUS
// Where the mixer's verdict is the backdrop (source 15: no tile, no polygon),
// what MAME does there instead, from draw_common and draw_rect read against
// the frame's own tile RAM. Only tilemaps 2/3 matter: their category-0 pass is
// screen_update's TILEMAP_DRAW_OPAQUE fill, so they are the only layers that
// leave the backdrop visible or not. Each uncovered pixel gets one cause:
//
//   CAT1     non-window mode, the map that owns the pixel's mask column has a
//            CATEGORY-1 tile there. draw_rect's opaque test is
//            `srct == tpri || flags & TILEMAP_DRAW_OPAQUE`, so MAME writes
//            that tile's pen (bank<<4 | pen) in the category-0 pass anyway.
//   WINMASK  window mode, and the row mask removed the owning map - MAME's
//            window branch draws through tile_layer->draw() and never reaches
//            draw_rect, where the mask lives.
//   WINCAT1  window mode, the owning map's tile is category 1 and its pen is
//            0. tilemap_t::draw keeps the category test under OPAQUE
//            (configure_blit_parameters clears only the layer bits), so MAME
//            leaves this pixel at the backdrop too.
//   DIS      the owning map is disabled (vscr bit 15): draw_common returns
//            before drawing anything.
//   OTHER    none of those.
enum { C_CAT1, C_WINMASK, C_WINCAT1, C_DIS, C_OTHER, C_N };
static const char* cname[C_N] = {"cat1", "winmask", "wincat1", "disabled", "other"};

static int backdrop_cause(int x, int y) {
  uint16_t ctrl = tile_ram[0x5006];
  int mode = (ctrl >> 13) & 3;
  uint16_t m = tile_ram[0x6800 + y * 4 + (x >> 7)];
  int mbit = (m >> (15 - ((x >> 3) & 15))) & 1;
  int L;
  if (mode == 0) {
    L = mbit ? 3 : 2;                 // tilemap 2 draws where the bit is 0
  } else if (mode == 1) {
    uint16_t nv = (uint16_t)(-(int)ctrl);
    int v = nv & 0x1ff, swap = !(nv & 0x200);
    L = 2 | ((y < v) ? swap : !swap);
  } else {
    uint16_t hs = tile_ram[0x5002];
    int h = hs & 0x1ff, left = !(hs & 0x200);
    L = 2 | ((x < h) ? left : !left);
  }
  int E = mode ? 2 : L;               // window mode scrolls (and disables) by the even map
  uint16_t hscr = tile_ram[0x5000 + E], vscr = tile_ram[0x5004 + E];
  if (vscr & 0x8000) return C_DIS;
  if (mode) {
    int own_masked = (L & 1) ? !mbit : mbit;
    if (own_masked) return C_WINMASK;
  }
  uint32_t mx = ((uint32_t)x - (hscr & 0x1ff)) & 0x1ff;
  uint32_t my = ((uint32_t)y + (vscr & 0x1ff)) & 0x1ff;
  uint16_t tw = tile_ram[L * 0x1000 + (my >> 3) * 64 + (mx >> 3)];
  if (tw & 0x8000) return mode ? C_WINCAT1 : C_CAT1;
  return C_OTHER;
}

static bool load_rgb(const std::string& path, std::vector<uint8_t>& v) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return false;
  size_t n = fread(v.data(), 1, v.size(), f);
  fclose(f);
  return n == v.size();
}

struct Entry { int frame; std::string tram, chr, pal, snap; };

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  int lat = 16, jit = 0, maxf = 1 << 30, every = 1;
  unsigned seed = 1;
  bool quiet = false, ppmall = false, mame = false;
  int srcdly = 2;
  std::string ppmdir, histf, fulldir;
  int scale = 100;
  std::vector<std::string> dirs;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if      (a == "-lat"  && i + 1 < argc) lat   = atoi(argv[++i]);
    else if (a == "-jit"  && i + 1 < argc) jit   = atoi(argv[++i]);
    else if (a == "-seed" && i + 1 < argc) seed  = (unsigned)atoi(argv[++i]);
    else if (a == "-max"  && i + 1 < argc) maxf  = atoi(argv[++i]);
    else if (a == "-every"&& i + 1 < argc) every = atoi(argv[++i]);
    else if (a == "-ppm"  && i + 1 < argc) ppmdir = argv[++i];
    else if (a == "-hist" && i + 1 < argc) histf = argv[++i];
    else if (a == "-scale"&& i + 1 < argc) scale = atoi(argv[++i]);
    else if (a == "-ppmall") ppmall = true;
    else if (a == "-mame") mame = true;
    else if (a == "-full" && i + 1 < argc) fulldir = argv[++i];
    else if (a == "-srcdly" && i + 1 < argc) srcdly = atoi(argv[++i]);
    else if (a == "-q") quiet = true;
    else if (a[0] == '+') ;                       // verilator plusargs
    else dirs.push_back(a);
  }
  if (dirs.empty()) { fprintf(stderr, "usage: tb_video2d [opts] <dump-dir>...\n"); return 2; }

  auto* d = new Vm1_video;
  auto* r = d->rootp;
  std::mt19937 rng(seed);
  std::uniform_int_distribution<int> jd(0, jit > 0 ? jit : 0);
  std::vector<double> hw;
  if (!histf.empty()) {
    FILE* hf = fopen(histf.c_str(), "r");
    if (!hf) { fprintf(stderr, "cannot read %s\n", histf.c_str()); return 2; }
    double v; while (fscanf(hf, "%lf", &v) == 1) hw.push_back(v);
    fclose(hf);
  }
  std::discrete_distribution<int> hd(hw.begin(), hw.end());
  auto draw_lat = [&]() -> int {
    if (hw.empty()) return lat + (jit ? jd(rng) : 0);
    return std::max(3, (hd(rng) * scale + 50) / 100);
  };

  d->clk = 0; d->rst_n = 0; d->ce_pix = 0; d->tile_mask = TILE_MASK;
  d->tram_data = 0; d->char_data = 0; d->char_ack = 0; d->pal_data = 0;
  d->poly_rgb = 0; d->poly_hit = 0;

  int cediv = 0;
  long cyc = 0;
  // The character port, as m1_sdram behaves: a request is latched on its
  // RISING edge with the address on that edge; it is answered once it has been
  // high `lat` cycles (plus jitter) - tb_m1_frame's character wait, 16 in play;
  // the ack is then held TWO cycles whatever the request does (ACK_HOLD = 2);
  // and the data stays until the next answer. Protocol errors are counted.
  bool req_d = false, pend = false;
  int cnt = 0, ack_hold = 0;
  uint32_t addr_l = 0;
  long proto_err = 0;
  uint8_t src_hist[8] = {0};
  auto tick = [&]() {
    d->tram_data = tile_ram[d->tram_addr & 0x7fff];
    bool     req_s  = d->char_req;
    uint32_t addr_s = d->char_addr & 0x3ffff;
    d->ce_pix = (cediv == 0);
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    // The controller's edge.
    if (ack_hold > 0 && --ack_hold == 0) d->char_ack = 0;
    if (pend) {
      if (cnt == 0) {
        d->char_data = ((uint32_t)char_ram[(addr_l + 1) & 0x3ffff] << 16) | char_ram[addr_l];
        d->char_ack = 1; ack_hold = 2; pend = false;
      } else cnt--;
    }
    if (req_s && !req_d) {
      if (pend) proto_err++;
      pend = true; addr_l = addr_s;
      cnt = std::max(draw_lat() - 3, 0);
    }
    if (!req_s && req_d && pend) proto_err++;
    req_d = req_s;
    d->eval();
    d->pal_data = pal_ram[d->pal_addr & 0xfff];
    for (int k = 7; k > 0; k--) src_hist[k] = src_hist[k-1];
    src_hist[0] = r->m1_video__DOT__mix_src;
    cediv = (cediv + 1) % CE_DIV;
    cyc++;
  };

  for (int i = 0; i < 40; i++) tick();
  d->rst_n = 1;

  long tot_frames = 0, tot_ovr = 0, tot_ovr_vis = 0, tot_bad_frames = 0, tot_px_fail = 0;
  long tot_ovr_frames = 0, worst_all = 0, tot_lines = 0, hist[17] = {0};
  long over90 = 0, over75 = 0;
  std::vector<uint8_t> img((size_t)H_VIS * V_VIS * 3);
  std::vector<uint8_t> msnap((size_t)H_VIS * V_VIS * 3), mfull((size_t)H_VIS * V_VIS * 3);
  long g_mframes = 0, g_diff = 0, g_bd = 0, g_bd_diff = 0, g_bd_seen = 0, g_other = 0;
  long g_other_seen = 0, g_align = 0, g_cause[C_N] = {0}, g_cause_diff[C_N] = {0};
  long g_drew_dis = 0;

  for (const auto& dir : dirs) {
    std::vector<Entry> es;
    {
      FILE* m = fopen((dir + "/manifest.txt").c_str(), "r");
      if (!m) { fprintf(stderr, "no manifest in %s\n", dir.c_str()); continue; }
      char t[128], c[128], p[128], sn[128], ln[640]; int f; int k = 0;
      while (fgets(ln, sizeof ln, m)) {
        int nf = sscanf(ln, "%d %127s %127s %127s %127s", &f, t, c, p, sn);
        if (nf < 4) continue;
        if ((k++ % every) == 0)
          es.push_back({f, dir + "/" + t, dir + "/" + c, dir + "/" + p,
                        nf == 5 ? dir + "/" + sn : std::string()});
      }
      fclose(m);
    }
    long d_frames = 0, d_ovr = 0, d_ovr_vis = 0, d_bad = 0, d_worst = 0, d_ovr_frames = 0;
    int d_worst_frame = -1;
    std::string cur_char;
    for (size_t ei = 0; ei < es.size() && (long)ei < maxf; ei++) {
      const Entry& e = es[ei];
      // Run to vblank begin, then swap the snapshot in: m1_video latches the
      // frame's scroll and control words here, and renders the first visible
      // line two lines before the end of vblank, so the whole visible frame is
      // drawn from this snapshot.
      while (!d->vblank_irq) tick();
      std::fill(tile_ram.begin(), tile_ram.end(), 0xffff);
      std::fill(pal_ram.begin(), pal_ram.end(), 0xffff);
      bool ok = load(e.tram, tile_ram) & load(e.pal, pal_ram);
      if (e.chr != cur_char) {
        std::fill(char_ram.begin(), char_ram.end(), 0xffff);
        ok &= load(e.chr, char_ram);
        cur_char = e.chr;
      }
      if (!ok) { fprintf(stderr, "short read in %s frame %d\n", dir.c_str(), e.frame); }
      bool cmp = mame && !e.snap.empty() && load_rgb(e.snap, msnap);
      bool have_full = false;
      if (cmp && !fulldir.empty()) {
        char fn[64]; snprintf(fn, sizeof fn, "/snap_%05d.bin", e.frame);
        have_full = load_rgb(fulldir + fn, mfull);
      }
      long f_diff = 0, f_bd = 0, f_bd_diff = 0, f_bd_seen = 0, f_other = 0, f_other_seen = 0;
      long f_align = 0, f_cause_diff[C_N] = {0}, f_drew_dis = 0;
      int R0, G0, B0;
      {
        uint16_t e0 = pal_ram[0];
        R0 = pal5bit(e0); G0 = pal5bit(e0 >> 5); B0 = pal5bit(e0 >> 10);
        if (!((e0 >> 15) & 1)) { R0 >>= 1; G0 >>= 1; B0 >>= 1; }
      }
      tick();

      // One whole frame: from here to the next vblank begin. Visible output
      // lags the counters by one pixel (see m1_video's output stage), so
      // pixels are taken from vid_* with the delayed blanking.
      long ovr = 0, ovr_vis = 0, worst = 0, fail = 0;
      int worst_line = -1;
      uint64_t h = 1469598103934665603ull;
      int x = 0, y = 0;
      bool in_line = false;
      long t0 = 0; int busy_line = -1; bool busy = false;
      bool seen_vis = false;
      while (true) {
        tick();
        uint8_t q = r->m1_video__DOT__q;
        // A lost line is a display line whose buffer was not finished when
        // the beam reached it: m1_video's lost_line, with the line number.
        // (Before the ring of line buffers this was a line_start finding the
        // sequencer busy, and the loss fell on that render line and the next.)
        if (r->m1_video__DOT__lost_line) {
          ovr++;
          if (r->m1_video__DOT__lost_no < V_VIS) ovr_vis++;
        }
        // Line duration: the sequencer leaves Q_IDLE the cycle after an
        // accepted line_start and returns when the fourth layer is done.
        if (!busy && q != 0) { busy = true; t0 = cyc; busy_line = r->m1_video__DOT__cur_line; }
        else if (busy && q == 0) {
          busy = false;
          long dur = cyc - t0;
          tot_lines++;
          hist[dur / 256 > 16 ? 16 : dur / 256]++;
          if (dur * 10 > BUDGET * 9) over90++;
          if (dur * 4  > BUDGET * 3) over75++;
          if (busy_line < V_VIS && dur > worst) { worst = dur; worst_line = busy_line; }
        }
        if (d->ce_pix) {
          if (!d->vid_hb && !d->vid_vb) {
            seen_vis = true;
            if (y < V_VIS && x < H_VIS) {
              int R, G, B;
              ref_rgb(x, y, &R, &G, &B);
              if (d->vid_r != R || d->vid_g != G || d->vid_b != B) fail++;
              size_t o = ((size_t)y * H_VIS + x) * 3;
              if (cmp) {
                int src = src_hist[srcdly];
                bool bd = (src == 15);
                bool df = d->vid_r != msnap[o] || d->vid_g != msnap[o+1] || d->vid_b != msnap[o+2];
                bool seen = !have_full || (msnap[o] == mfull[o] && msnap[o+1] == mfull[o+1]
                                           && msnap[o+2] == mfull[o+2]);
                if (bd && (d->vid_r != R0 || d->vid_g != G0 || d->vid_b != B0)) f_align++;
                if (df) f_diff++;
                if (bd) {
                  f_bd++;
                  int c = backdrop_cause(x, y);
                  g_cause[c]++;
                  if (df) { f_bd_diff++; f_cause_diff[c]++; if (seen) f_bd_seen++; }
                } else if (df) {
                  f_other++; if (seen) f_other_seen++;
                  // A tilemap 2/3 category-0 win on a DISABLED layer: the
                  // opaque pass drew a map MAME returns from.
                  if ((src == 6 || src == 7) && (tile_ram[0x5004 + (src - 4)] & 0x8000)) f_drew_dis++;
                }
              }
              img[o] = d->vid_r; img[o+1] = d->vid_g; img[o+2] = d->vid_b;
              h = (h ^ d->vid_r) * 1099511628211ull;
              h = (h ^ d->vid_g) * 1099511628211ull;
              h = (h ^ d->vid_b) * 1099511628211ull;
            }
            x++; in_line = true;
          } else if (in_line) { in_line = false; x = 0; y++; }
        }
        if (seen_vis && d->vblank_irq) break;
      }
      if (cmp) {
        g_mframes++; g_diff += f_diff; g_bd += f_bd; g_bd_diff += f_bd_diff;
        g_bd_seen += f_bd_seen; g_other += f_other; g_other_seen += f_other_seen;
        g_align += f_align; g_drew_dis += f_drew_dis;
        for (int c = 0; c < C_N; c++) g_cause_diff[c] += f_cause_diff[c];
        printf("MAME %s %d differ=%ld backdrop=%ld backdrop_differ=%ld (seen %ld) [",
               dir.c_str(), e.frame, f_diff, f_bd, f_bd_diff, f_bd_seen);
        for (int c = 0; c < C_N; c++) printf("%s%s=%ld", c ? " " : "", cname[c], f_cause_diff[c]);
        printf("] other_differ=%ld (seen %ld) drew_disabled=%ld align_err=%ld ctrl23=%04x vscr=%04x/%04x/%04x/%04x\n",
               f_other, f_other_seen, f_drew_dis, f_align, tile_ram[0x5006],
               tile_ram[0x5004], tile_ram[0x5005], tile_ram[0x5006], tile_ram[0x5007]);
      }
      d_frames++; tot_frames++;
      d_ovr += ovr; d_ovr_vis += ovr_vis; tot_ovr += ovr; tot_ovr_vis += ovr_vis;
      if (ovr_vis) { d_ovr_frames++; tot_ovr_frames++; }
      if (fail) { d_bad++; tot_bad_frames++; tot_px_fail += fail; }
      if (worst > d_worst) { d_worst = worst; d_worst_frame = e.frame; }
      if (worst > worst_all) worst_all = worst;
      if (!quiet)
        printf("F %s %d ovr=%ld vis=%ld worst=%ld line=%d fail=%ld hash=%016llx\n",
               dir.c_str(), e.frame, ovr, ovr_vis, worst, worst_line, fail,
               (unsigned long long)h);
      if (!ppmdir.empty() && (ppmall || ovr_vis || fail)) {
        std::string base = dir;
        size_t sl = base.find_last_of('/');
        if (sl != std::string::npos) base = base.substr(sl + 1);
        char fn[512];
        snprintf(fn, sizeof fn, "%s/%s_%05d.ppm", ppmdir.c_str(), base.c_str(), e.frame);
        FILE* f = fopen(fn, "wb");
        if (f) { fprintf(f, "P6\n%d %d\n255\n", H_VIS, V_VIS); fwrite(img.data(), 1, img.size(), f); fclose(f); }
      }
    }
    printf("DIR %s frames=%ld overrun_frames=%ld overruns=%ld visible=%ld bad_frames=%ld worst=%ld (frame %d) budget=%d lat=%d jit=%d\n",
           dir.c_str(), d_frames, d_ovr_frames, d_ovr, d_ovr_vis, d_bad, d_worst, d_worst_frame,
           BUDGET, lat, jit);
    fflush(stdout);
  }
  if (mame) {
    printf("MAMETOTAL frames=%ld differ=%ld backdrop=%ld backdrop_differ=%ld (seen %ld) [",
           g_mframes, g_diff, g_bd, g_bd_diff, g_bd_seen);
    for (int c = 0; c < C_N; c++) printf("%s%s=%ld", c ? " " : "", cname[c], g_cause_diff[c]);
    printf("] other_differ=%ld (seen %ld) drew_disabled=%ld align_err=%ld\n",
           g_other, g_other_seen, g_drew_dis, g_align);
    printf("MAMETOTAL backdrop by cause, all:");
    for (int c = 0; c < C_N; c++) printf(" %s=%ld", cname[c], g_cause[c]);
    printf("\n");
  }
  if (!hw.empty()) printf("LATENCY drawn from %s at %d%%\n", histf.c_str(), scale);
  printf("TOTAL frames=%ld overrun_frames=%ld overruns=%ld visible=%ld bad_frames=%ld px_fail=%ld worst=%ld lines=%ld >90%%=%ld >75%%=%ld proto_err=%ld\n",
         tot_frames, tot_ovr_frames, tot_ovr, tot_ovr_vis, tot_bad_frames, tot_px_fail,
         worst_all, tot_lines, over90, over75, proto_err);
  printf("HIST 256-cycle buckets:");
  for (int i = 0; i < 17; i++) printf(" %ld", hist[i]);
  printf("\n");
  delete d;
  return 0;
}
