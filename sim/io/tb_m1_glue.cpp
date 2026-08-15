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
// GLUE registers: interrupts, banking, timers.
//
// This exists because the interrupt semantics were already wrong once. The
// mask was implemented as an enable, and that fails silently: the mask resets
// to zero, so no interrupt ever reaches the CPU and a game boots, initialises,
// and then sits there while vblank arrives every frame with nothing responding.
// The integration test could not see it — the CPU program it runs never enables
// an interrupt — so the behaviour needs checking where it can be driven
// directly.

#include "Vm1_glue.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static const int PRESC = 0x800;

struct Glue {
  Vm1_glue* d;
  long cyc = 0;
  Glue() {
    d = new Vm1_glue;
    d->clk = 0; d->ce = 1; d->rst_n = 0;
    d->sel = 0; d->we = 0; d->a = 0; d->be = 3; d->wdata = 0; d->vblank = 0;
    d->eval();
    for (int i = 0; i < 4; i++) tick();
    d->rst_n = 1;
  }
  ~Glue() { delete d; }
  void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); cyc++; }
  void wr(int addr, uint16_t v) {
    d->sel = 1; d->we = 1; d->a = addr; d->wdata = v; tick();
    d->sel = 0; d->we = 0;
  }
  uint16_t rd(int addr) { d->a = addr; d->eval(); return d->rdata; }
  void pulse_vblank() { d->vblank = 1; tick(); d->vblank = 0; tick(); }
};

static long checks = 0, fails = 0;
static void chk(bool ok, const char* what) {
  checks++;
  if (!ok) { printf("  FAIL %s\n", what); fails++; }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  printf("test: the mask blocks, it does not enable\n");
  {
    Glue g;
    // Mask at its reset value of zero: vblank must reach the CPU. Under an
    // enable reading it would not, which is the bug this is here to catch.
    chk(g.d->irq_n == 1, "idle: no interrupt pending");
    g.pulse_vblank();
    chk(g.d->irq_n == 0, "vblank raises with mask=0");

    g.wr(0, 0x10);                        // clear all
    chk(g.d->irq_n == 1, "control 0x10 clears");

    g.wr(1, 0x02);                        // mask bit 1 set = vblank blocked
    g.pulse_vblank();
    chk(g.d->irq_n == 1, "vblank blocked when its mask bit is SET");

    g.wr(1, 0x00);
    g.pulse_vblank();
    chk(g.d->irq_n == 0, "vblank raises again once unblocked");
  }

  printf("test: control 0x20 clears only the last raised\n");
  {
    Glue g;
    g.wr(4, 1);                           // timer 0 period 1
    for (int i = 0; i < PRESC * 3 + 8; i++) g.tick();
    chk(g.d->irq_n == 0, "timer raised");
    g.pulse_vblank();                     // vblank is now the last raised
    g.wr(0, 0x20);
    // Timer 0 is still pending, so the line must stay asserted.
    chk(g.d->irq_n == 0, "0x20 leaves the other source pending");
    g.wr(0, 0x10);
    chk(g.d->irq_n == 1, "0x10 clears everything");
  }

  printf("test: timers count down in units of 0x800\n");
  {
    Glue g;
    g.wr(1, 0x01);                        // block the timer IRQ; count anyway
    g.wr(4, 10);                          // timer 0 period 10
    chk(g.rd(4) == 10, "period reads back");
    chk(g.rd(6) == 10, "count starts at the period");

    for (int i = 0; i < PRESC; i++) g.tick();
    chk(g.rd(6) == 9, "one tick after 0x800 enables");

    for (int i = 0; i < PRESC * 4; i++) g.tick();
    chk(g.rd(6) == 5, "four more ticks");

    chk(g.d->irq_n == 1, "masked timer does not raise");

    // Run past zero: MAME re-arms from the period rather than stopping.
    for (int i = 0; i < PRESC * 6; i++) g.tick();
    chk(g.rd(6) == 10 || g.rd(6) == 9, "reloads on expiry");
  }

  printf("test: a period of zero stops the timer\n");
  {
    Glue g;
    g.wr(4, 0);
    for (int i = 0; i < PRESC * 4; i++) g.tick();
    chk(g.rd(6) == 0, "count stays put");
    chk(g.d->irq_n == 1, "and never raises");
  }

  printf("test: the timers are independent\n");
  {
    Glue g;
    g.wr(1, 0x01);
    g.wr(4, 20);                          // timer 0
    g.wr(5, 5);                           // timer 1
    for (int i = 0; i < PRESC * 3; i++) g.tick();
    chk(g.rd(6) == 17, "timer 0 counted 3");
    chk(g.rd(7) == 2,  "timer 1 counted 3");
  }

  printf("test: banking takes selector 1 only\n");
  {
    Glue g;
    chk(g.d->rom_bank == 0, "bank resets to 0");
    g.wr(2, 0x31);                        // selector 1, bank 3
    chk(g.d->rom_bank == 3, "selector 1 sets the bank");
    g.wr(2, 0x52);                        // selector 2 — decoded and ignored
    chk(g.d->rom_bank == 3, "selector 2 does not change it");
    g.wr(2, 0x7f);                        // selector f — likewise
    chk(g.d->rom_bank == 3, "selector f does not change it");
    g.wr(2, 0x71);
    chk(g.d->rom_bank == 7, "selector 1 again");
  }

  printf("test: 0xe0000c-f are read-only\n");
  {
    Glue g;
    g.wr(1, 0x01);
    g.wr(4, 100);
    // vf and swa write zero to the count registers at init. Treating that as a
    // period write would stop the timer they just started.
    g.wr(6, 0);
    g.wr(7, 0);
    chk(g.rd(4) == 100, "period survives a write to the count register");
    for (int i = 0; i < PRESC; i++) g.tick();
    chk(g.rd(6) == 99, "and the timer is still running");
  }

  printf("m1_glue: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
