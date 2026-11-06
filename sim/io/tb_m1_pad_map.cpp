// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m1_pad_map against two references, for every game:
//   1. THE PREVIOUS LAYOUT: Model1.sv's IN.0/IN.1/IN.2 equations on main
//      (7168ad8), copied here, driven with each button at its OLD joystick bit
//      (the old MRA names: eight game buttons, then Start, Coin, Service, Test,
//      Coin 2 at bits 12-16). The new module is driven with the same button,
//      by name, at its NEW bit. The three bytes must be equal.
//   2. MAME 0.289's INPUT_PORTS: the bit each named control must clear.
// Every single button, every d-pad direction, both OSD switches, and 200,000
// random combinations of named buttons on both pads.
//
// NetMerc is the one game whose bytes are meant to differ from main: main gave
// it the driving layout, so its Thumb and MVD Holder were unreachable and its
// "VR1-3", "Start", "Coin 2" and d-pad up/down drove bits MAME marks unused.
// For NetMerc the comparison with main is masked to the bits MAME defines.

#include "Vm1_pad_map.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <string>
#include <vector>

struct Btn { const char *name; int oldbit; int newbit; int pad; int mbyte; int mbit; };
// mbyte/mbit: MAME's IN.<mbyte> bit, -1 for none (analogue-only or a gear on
// the d-pad's alternate route)
struct Game { int id; const char *name; std::vector<Btn> b; uint8_t m0, m1, m2; };

static Vm1_pad_map *t;

// ---- main's equations (Model1.sv at 7168ad8), verbatim in C
static void ref_main(int game, uint32_t j0, uint32_t j1, int ot, int os, uint8_t o[3]) {
  auto b = [](uint32_t v, int i) { return int((v >> i) & 1); };
  int svc = b(j0, 14) | os, tst = b(j0, 15) | ot, coin = b(j0, 13), coin2 = b(j0, 16), start = b(j0, 12);
  int start2 = b(j1, 12);
  int vr1 = b(j0, 8), vr2 = b(j0, 9), vr3 = b(j0, 10), vr4 = b(j0, 11);
  int shu = b(j0, 6) | b(j0, 3), shd = b(j0, 7) | b(j0, 2);
  int p1r = b(j0, 0), p1l = b(j0, 1), p1d = b(j0, 2), p1u = b(j0, 3);
  int p2r = b(j1, 0), p2l = b(j1, 1), p2d = b(j1, 2), p2u = b(j1, 3);
  bool vf = game == 1, swa = game == 2, ww = game == 3;
  uint8_t in0_vr = ~uint8_t(vr3 << 7 | vr2 << 6 | vr1 << 5 | start << 4 | svc << 3 | tst << 2 | coin2 << 1 | coin);
  uint8_t in1_vr = ~uint8_t(shu << 5 | shd << 4 | vr4);
  uint8_t in0_vf = ~uint8_t(start2 << 5 | start << 4 | svc << 3 | tst << 2 | coin2 << 1 | coin);
  uint8_t in1_vf = ~uint8_t(p1l << 7 | p1r << 6 | p1u << 5 | p1d << 4 | b(j0, 6) << 2 | b(j0, 5) << 1 | b(j0, 4));
  uint8_t in2_vf = ~uint8_t(p2l << 7 | p2r << 6 | p2u << 5 | p2d << 4 | b(j1, 6) << 2 | b(j1, 5) << 1 | b(j1, 4));
  uint8_t in1_swa = ~uint8_t(b(j0, 6) << 4 | b(j1, 5) << 3 | b(j1, 4) << 2 | b(j0, 5) << 1 | b(j0, 4));
  uint8_t in1_ww = ~uint8_t(b(j0, 6) << 6 | b(j0, 5) << 5 | b(j0, 4) << 4 | vr4);
  o[0] = (vf || swa) ? in0_vf : in0_vr;
  o[1] = swa ? in1_swa : ww ? in1_ww : vf ? in1_vf : in1_vr;
  o[2] = vf ? in2_vf : 0xff;
}

static void dut(int game, uint32_t j0, uint32_t j1, int ot, int os, uint8_t o[3]) {
  t->game = game; t->joy0 = j0; t->joy1 = j1; t->osd_test = ot; t->osd_service = os; t->eval();
  o[0] = t->in0; o[1] = t->in1; o[2] = t->in2;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  t = new Vm1_pad_map;
  // name, old bit, new bit, pad, MAME byte, MAME bit
  std::vector<Game> games = {
    {0, "vr/vformula", {
      {"Accelerate", 4, 4, 0, -1, 0}, {"Brake", 5, 5, 0, -1, 0},
      {"Shift Up", 6, 6, 0, 1, 5}, {"Shift Down", 7, 7, 0, 1, 4},
      {"VR1", 8, 8, 0, 0, 5}, {"VR2", 9, 9, 0, 0, 6}, {"VR3", 10, 10, 0, 0, 7}, {"VR4", 11, 11, 0, 1, 0},
      {"Start", 12, 12, 0, 0, 4}, {"Coin", 13, 13, 0, 0, 0}, {"Service", 14, 14, 0, 0, 3},
      {"Test", 15, 15, 0, 0, 2}, {"Coin 2", 16, 16, 0, 0, 1},
      {"Up", 3, 3, 0, 1, 5}, {"Down", 2, 2, 0, 1, 4}, {"Left", 1, 1, 0, -1, 0}, {"Right", 0, 0, 0, -1, 0}},
      0xff, 0x31, 0x00},
    {1, "vf", {
      {"Punch", 4, 4, 0, 1, 0}, {"Kick", 5, 5, 0, 1, 1}, {"Guard", 6, 6, 0, 1, 2},
      {"Start", 12, 7, 0, 0, 4}, {"Coin", 13, 8, 0, 0, 0}, {"Service", 14, 9, 0, 0, 3},
      {"Test", 15, 10, 0, 0, 2}, {"Coin 2", 16, 11, 0, 0, 1},
      {"Up", 3, 3, 0, 1, 5}, {"Down", 2, 2, 0, 1, 4}, {"Left", 1, 1, 0, 1, 7}, {"Right", 0, 0, 0, 1, 6},
      {"P2 Punch", 4, 4, 1, 2, 0}, {"P2 Kick", 5, 5, 1, 2, 1}, {"P2 Guard", 6, 6, 1, 2, 2},
      {"P2 Start", 12, 7, 1, 0, 5},
      {"P2 Up", 3, 3, 1, 2, 5}, {"P2 Down", 2, 2, 1, 2, 4}, {"P2 Left", 1, 1, 1, 2, 7}, {"P2 Right", 0, 0, 1, 2, 6}},
      0x3f, 0xf7, 0xf7},
    {2, "swa", {
      {"Fire", 4, 4, 0, 1, 0}, {"Thumb", 5, 5, 0, 1, 1}, {"Button 3", 6, 6, 0, 1, 4},
      {"Throttle Up", -1, 7, 0, -1, 0}, {"Throttle Down", -1, 8, 0, -1, 0},
      {"Start", 12, 9, 0, 0, 4}, {"Coin", 13, 10, 0, 0, 0}, {"Service", 14, 11, 0, 0, 3},
      {"Test", 15, 12, 0, 0, 2}, {"Coin 2", 16, 13, 0, 0, 1},
      {"Up", 3, 3, 0, -1, 0}, {"Down", 2, 2, 0, -1, 0}, {"Left", 1, 1, 0, -1, 0}, {"Right", 0, 0, 0, -1, 0},
      {"P2 Fire", 4, 4, 1, 1, 2}, {"P2 Thumb", 5, 5, 1, 1, 3}, {"P2 Start", 12, 9, 1, 0, 5}},
      0x3f, 0x1f, 0x00},
    {3, "wingwar", {
      {"Machine Gun", 4, 4, 0, 1, 4}, {"Missile", 5, 5, 0, 1, 5}, {"Smoke", 6, 6, 0, 1, 6},
      {"View 1", 8, 7, 0, 0, 5}, {"View 2", 9, 8, 0, 0, 6}, {"View 3", 10, 9, 0, 0, 7}, {"View 4", 11, 10, 0, 1, 0},
      {"Start", 12, 11, 0, 0, 4}, {"Coin", 13, 12, 0, 0, 0}, {"Service", 14, 13, 0, 0, 3},
      {"Test", 15, 14, 0, 0, 2}, {"Coin 2", 16, 15, 0, 0, 1},
      {"Up", 3, 3, 0, -1, 0}, {"Down", 2, 2, 0, -1, 0}, {"Left", 1, 1, 0, -1, 0}, {"Right", 0, 0, 0, -1, 0}},
      0xff, 0x71, 0x00},
    {4, "netmerc", {
      {"Trigger", 11, 4, 0, 1, 0}, {"Thumb", -1, 5, 0, 1, 1}, {"MVD Holder", -1, 6, 0, 1, 2},
      {"Coin", 13, 7, 0, 0, 0}, {"Service", 14, 8, 0, 0, 3}, {"Test", 15, 9, 0, 0, 2},
      {"Up", 3, 3, 0, -1, 0}, {"Down", 2, 2, 0, -1, 0}, {"Left", 1, 1, 0, -1, 0}, {"Right", 0, 0, 0, -1, 0}},
      0x0d, 0x07, 0x00},
  };
  long checks = 0, fails = 0, vs_main = 0, vs_mame = 0;
  auto fail = [&](const char *fmt, auto... a) { if (++fails <= 30) { std::printf("  FAIL: "); std::printf(fmt, a...); std::printf("\n"); } };
  std::mt19937 rng(20261105);
  for (auto &g : games) {
    uint8_t mask[3] = {g.m0, g.m1, g.m2};
    bool masked = (g.id == 4);
    // one control at a time, and the OSD switches
    for (size_t k = 0; k <= g.b.size() + 1; k++) {
      uint32_t oj[2] = {0, 0}, nj[2] = {0, 0};
      int ot = 0, os = 0;
      const Btn *bb = nullptr;
      if (k < g.b.size()) {
        bb = &g.b[k];
        if (bb->oldbit >= 0) oj[bb->pad] |= 1u << bb->oldbit;
        nj[bb->pad] |= 1u << bb->newbit;
      } else if (k == g.b.size()) ot = 1; else os = 1;
      uint8_t r[3], d[3];
      ref_main(g.id, oj[0], oj[1], ot, os, r);
      dut(g.id, nj[0], nj[1], ot, os, d);
      const char *nm = bb ? bb->name : (ot ? "OSD test" : "OSD service");
      // against main (where the button existed there)
      if (!bb || bb->oldbit >= 0) {
        for (int i = 0; i < 3; i++) {
          uint8_t m = masked ? mask[i] : 0xff;
          checks++; vs_main++;
          if ((r[i] & m) != (d[i] & m))
            fail("%s %s: IN.%d %02x, main %02x", g.name, nm, i, d[i], r[i]);
        }
      }
      // against MAME's bit
      if (bb && bb->mbyte >= 0) {
        for (int i = 0; i < 3; i++) {
          uint8_t want = (i == bb->mbyte) ? uint8_t(~(1u << bb->mbit)) : 0xff;
          checks++; vs_mame++;
          if ((d[i] & mask[i]) != (want & mask[i]))
            fail("%s %s: IN.%d %02x, MAME's bit gives %02x", g.name, nm, i, d[i] & mask[i], want & mask[i]);
        }
      }
      if (!bb) {   // the OSD switches are Test (IN.0 bit 2) and Service (bit 3)
        uint8_t want = uint8_t(~(1u << (ot ? 2 : 3)));
        checks++; vs_mame++;
        if ((d[0] & mask[0]) != (want & mask[0]))
          fail("%s %s: IN.0 %02x", g.name, nm, d[0]);
      }
    }
    // random combinations of the named buttons present in both layouts
    for (int n = 0; n < 40000; n++) {
      uint32_t oj[2] = {0, 0}, nj[2] = {0, 0};
      for (auto &bb : g.b) if (bb.oldbit >= 0 && (rng() & 3) == 0) { oj[bb.pad] |= 1u << bb.oldbit; nj[bb.pad] |= 1u << bb.newbit; }
      int ot = rng() & 1, os = rng() & 1;
      uint8_t r[3], d[3];
      ref_main(g.id, oj[0], oj[1], ot, os, r);
      dut(g.id, nj[0], nj[1], ot, os, d);
      for (int i = 0; i < 3; i++) {
        uint8_t m = masked ? mask[i] : 0xff;
        checks++; vs_main++;
        if ((r[i] & m) != (d[i] & m)) fail("%s random %08x/%08x: IN.%d %02x, main %02x", g.name, nj[0], nj[1], i, d[i], r[i]);
      }
    }
    // the throttle buttons are Star Wars' only
    uint8_t d[3];
    dut(g.id, 1u << 7, 0, 0, 0, d); checks++;
    if (bool(t->thr_up) != (g.id == 2)) fail("%s: thr_up %d for joy bit 7", g.name, t->thr_up);
    dut(g.id, 1u << 8, 0, 0, 0, d); checks++;
    if (bool(t->thr_dn) != (g.id == 2)) fail("%s: thr_dn %d for joy bit 8", g.name, t->thr_dn);
  }
  std::printf("m1_pad_map: checks=%ld fails=%ld (vs main %ld, vs MAME %ld)\n", checks, fails, vs_main, vs_mame);
  return fails ? 1 : 0;
}
