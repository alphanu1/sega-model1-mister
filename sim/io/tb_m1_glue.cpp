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
    d->irq_ack = 0; d->snd_txrdy = 0; d->snd_ready_ev = 0;
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
  // One update_tx_ready() call from the USART, with the line in `ready`.
  void snd_event(int ready) {
    d->snd_txrdy = ready; d->snd_ready_ev = 1; tick();
    d->snd_ready_ev = 0; tick();
  }
  // The CPU consuming the vector, which is when MAME's irq_callback runs.
  void ack() { d->irq_ack = 1; tick(); d->irq_ack = 0; tick(); }
};

static long checks = 0, fails = 0;
static void chk(bool ok, const char* what) {
  checks++;
  if (!ok) { printf("  FAIL %s\n", what); fails++; }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  printf("test: the mask RESETS to all-masked, as MAME's machine_reset does\n");
  {
    // This was '0 here, and it cost a real divergence once level 3 existed: the
    // USART could raise before the game had written the mask at all, and vr
    // vectored to its non-vblank handler one instruction after enabling
    // interrupts. MAME resets m_irq_mask to 0xff.
    Glue g;
    chk(g.rd(1) == 0x00ff, "irq_mask reads 0xff after reset");
    g.d->snd_txrdy = 1; g.snd_event(1);
    chk(g.d->irq_n == 1, "a ready USART cannot raise level 3 before the game unmasks it");
    g.pulse_vblank();
    chk(g.d->irq_n == 1, "and vblank is masked at reset too");
  }

  printf("test: the mask blocks, it does not enable\n");
  {
    Glue g;
    g.wr(1, 0x00);                        // the game programs the mask
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
    g.wr(1, 0x00);                        // unmask everything first
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

  // The bug this is written for cost a day of looking at a video path. The
  // vector was hardcoded to 0 in m1_main while GLUE computed it internally and
  // never exposed it, so every interrupt dispatched as IRQ 0 — vblank ran the
  // timer's handler, the game's frame flag was never set, and the CPU sat in a
  // three-instruction poll loop that looked exactly like a hung core.
  printf("test: the vector is the lowest set status bit, MAME's irq_callback\n");
  {
    Glue g;
    g.wr(1, 0x00);
    g.pulse_vblank();                       // IRQ 1
    chk(g.d->irq_n == 0, "vblank pending");
    chk(g.d->irq_vec == 1, "vector is 1 for vblank alone");

    g.wr(4, 1);                             // timer 0 period 1 -> IRQ 0
    for (int i = 0; i < PRESC * 3 + 8; i++) g.tick();
    // Both pending now. MAME scans from bit 0 and returns the FIRST set, so
    // the timer outranks vblank regardless of which was raised last.
    chk(g.d->irq_vec == 0, "with 0 and 1 pending the vector is 0, not the last raised");

    g.wr(0, 0x10);                          // clear all
    chk(g.d->irq_n == 1, "cleared");
    g.pulse_vblank();
    chk(g.d->irq_vec == 1, "vector follows status back to 1");
  }

  printf("test: 0x20 clears the source that was acknowledged\n");
  {
    Glue g;
    g.wr(1, 0x00);
    g.wr(4, 1);
    for (int i = 0; i < PRESC * 3 + 8; i++) g.tick();   // IRQ 0 pending
    g.pulse_vblank();                                   // IRQ 1 pending too
    chk(g.d->irq_vec == 0, "vector 0 with both pending");

    g.ack();                 // CPU takes vector 0; last_irq must latch 0
    g.wr(0, 0x20);           // clear the acknowledged one
    chk(g.d->irq_n == 0, "still pending: vblank was not the acknowledged source");
    chk(g.d->irq_vec == 1, "vector now 1, the timer having been cleared");

    g.ack();                 // CPU takes vector 1
    g.wr(0, 0x20);
    chk(g.d->irq_n == 1, "both sources now cleared");
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

  // LEVEL 3 IS THE SOUND USART, AND ITS ABSENCE WAS MISREAD AS A CPU BUG.
  // `make v60_trace GAME=vf` matched MAME for 21,816 instructions and then
  // parted one boundary after the game enabled interrupts: the reference took
  // vblank and then level 3, we took vblank alone. Nothing here raised 3.
  printf("test: level 3 follows the USART, as sound_ready_w does\n");
  {
    Glue g;
    g.wr(1, 0xff);                       // everything masked, as at reset in MAME
    g.snd_event(1);
    chk(g.d->irq_n == 1, "masked level 3 does not raise even with the line ready");

    // The line NOT ready must not raise either: sound_ready_w re-reads txrdy
    // rather than trusting the state change that called it. Drop the line
    // BEFORE unmasking, or the unmasking write raises it on its own - which is
    // real behaviour, and has its own test below.
    g.d->snd_txrdy = 0; g.tick();
    g.wr(1, 0xf7);                       // unmask 3 only
    g.snd_event(0);
    chk(g.d->irq_n == 1, "an event with the line down raises nothing");

    g.snd_event(1);
    chk(g.d->irq_n == 0, "line ready and unmasked raises");
    chk(g.d->irq_vec == 3, "vector 3");

    g.ack();
    g.wr(0, 0x20);
    chk(g.d->irq_n == 1, "0x20 clears it");
  }

  printf("test: unmasking level 3 while ready raises it there and then\n");
  {
    // irq_mask_w() calls sound_ready_w() against the mask it has just written,
    // so the game's "and.b #0xf7" is itself what starts the queue pump. Raising
    // only on later USART events would leave the first byte unsent.
    Glue g;
    g.wr(1, 0xff);
    g.d->snd_txrdy = 1; g.tick();
    chk(g.d->irq_n == 1, "still masked");
    g.wr(1, 0xf7);
    chk(g.d->irq_n == 0, "the unmasking write raises it");
    chk(g.d->irq_vec == 3, "vector 3");

    // ...and masking it again is not, by itself, a raise.
    g.ack(); g.wr(0, 0x20);
    g.wr(1, 0xff);
    chk(g.d->irq_n == 1, "masking again with the line still ready raises nothing");
  }

  printf("test: level 3 loses to the lower levels, as the scan from bit 0 has it\n");
  {
    Glue g;
    g.wr(1, 0xf5);                       // unmask vblank (bit 1) and sound (bit 3)
    g.snd_event(1);
    chk(g.d->irq_vec == 3, "3 alone");
    g.pulse_vblank();
    chk(g.d->irq_vec == 1, "vblank outranks it");
    g.ack(); g.wr(0, 0x20);
    chk(g.d->irq_vec == 3, "and 3 is still there underneath");
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
