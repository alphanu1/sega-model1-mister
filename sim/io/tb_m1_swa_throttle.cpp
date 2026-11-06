// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m1_swa_throttle: built with STEP = 16 so a full sweep is quick. The lever
// starts at 127, moves one count per STEP cycles held, stops at 28 and 200,
// holds when released, ignores both held at once; the stick maps -128..127
// onto 28..199 monotonically.
#include "Vm1_swa_throttle.h"
#include "verilated.h"
#include <cstdio>
static Vm1_swa_throttle *t;
static void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  t = new Vm1_swa_throttle;
  long checks = 0, fails = 0;
  auto chk = [&](bool ok, const char *m, int v) { checks++; if (!ok && ++fails <= 20) std::printf("  FAIL: %s (%d)\n", m, v); };
  t->rst_n = 0; t->up = 0; t->dn = 0; t->stick = 0; t->ry = 0; tick(); tick(); t->rst_n = 1; tick();
  chk(t->thr == 127, "power-up 127", t->thr);
  t->up = 1;
  for (int i = 0; i < 16 * 200; i++) { tick(); chk(t->thr >= 28 && t->thr <= 127, "up in range", t->thr); }
  chk(t->thr == 28, "up stops at 28", t->thr);
  t->up = 0; for (int i = 0; i < 1000; i++) tick();
  chk(t->thr == 28, "holds when released", t->thr);
  t->dn = 1; for (int i = 0; i < 16 * 10; i++) tick();
  chk(t->thr == 38, "ten steps down", t->thr);
  t->up = 1; for (int i = 0; i < 1000; i++) tick();
  chk(t->thr == 38, "both held: no move", t->thr);
  t->up = 0; for (int i = 0; i < 16 * 300; i++) tick();
  chk(t->thr == 200, "down stops at 200", t->thr);
  t->dn = 0;
  // a tap of one cycle is one count
  t->up = 1; tick(); t->up = 0; tick();
  chk(t->thr == 199, "a one-cycle tap is one count", t->thr);
  t->stick = 1;
  int prev = -1;
  for (int y = -128; y < 128; y++) {
    t->ry = uint8_t(y); t->eval();
    chk(t->thr >= 28 && t->thr <= 200, "stick in range", t->thr);
    chk(int(t->thr) >= prev, "stick monotonic", t->thr);
    prev = t->thr;
  }
  t->ry = uint8_t(-128); t->eval(); chk(t->thr == 28, "stick up 28", t->thr);
  t->ry = 0; t->eval(); chk(t->thr == 114, "stick centre 114", t->thr);
  t->ry = 127; t->eval(); chk(t->thr == 199, "stick down 199", t->thr);
  t->stick = 0; t->eval(); chk(t->thr == 199, "back to the lever", t->thr);
  std::printf("m1_swa_throttle: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
