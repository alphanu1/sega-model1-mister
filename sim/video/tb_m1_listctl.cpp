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
// The display-list control register at 0x680000.
//
// The reference is model1_v.cpp's three functions, and the expected values below
// are computed from them here rather than copied out of the RTL — the same trap
// that let six wrong identity-block bytes live in the RTL, the testbench and the
// docs at once was "typing one reading out twice".
//
//   read offset 0  -> listctl[0] | 0x30            bits 4,5 forced set
//   read offset 1  -> listctl[1]                   plain latch
//   bit 2 CLEAR    -> bit 6 mirrors bit 3          software picks the buffer
//   bit 2 SET      -> bit 6 toggles every 2 frames automatic double buffer
//
// Bit 6 is what the game tests with `test1 #6` at FF96FE, so getting it wrong
// picks the wrong display list every frame — which is what reading 0xFFFF did.

#include "Vm1_listctl.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static long checks = 0, fails = 0;
static void check(bool ok, const char* what) {
  checks++;
  if (!ok) { fails++; printf("  FAIL %s\n", what); }
}

struct Dut {
  Vm1_listctl* d;
  Dut() {
    d = new Vm1_listctl;
    d->clk = 0; d->rst_n = 0; d->we = 0; d->offset = 0;
    d->wdata = 0; d->be = 3; d->frame_pulse = 0;
    d->eval();
    for (int i = 0; i < 3; i++) tick();
    d->rst_n = 1; tick();
  }
  ~Dut() { delete d; }
  void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
  void write(bool off, uint16_t v, uint8_t bytes = 3) {
    d->we = 1; d->offset = off; d->wdata = v; d->be = bytes;
    tick();
    d->we = 0; d->be = 3; d->eval();
  }
  uint16_t read(bool off) { d->offset = off; d->eval(); return d->rdata; }
  void frame() { d->frame_pulse = 1; tick(); d->frame_pulse = 0; d->eval(); }
};

// The reference, written from model1_v.cpp rather than from the RTL.
static uint16_t ref_read0(uint16_t lc0) {
  if (!(lc0 & 4)) lc0 = (lc0 & ~0x40) | ((lc0 & 8) ? 0x40 : 0);
  return lc0 | 0x30;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  printf("test: reset reads 0x0030 — bits 4 and 5 forced, nothing else set\n");
  {
    Dut t;
    check(t.read(0) == 0x0030, "offset 0 after reset is not 0x0030");
    check(t.read(1) == 0x0000, "offset 1 after reset is not 0");
    // THE BIT THE GAME TESTS. Reading 0xFFFF here — which is what the missing
    // read handler did — makes bit 6 always 1 and picks the wrong list forever.
    check((t.read(0) & 0x40) == 0, "bit 6 set at reset: the buffer select is wrong");
    check(t.d->list_sel == 0, "list_sel disagrees with bit 6 of the read");
  }

  printf("test: bits 4 and 5 read back set whatever was written\n");
  {
    Dut t;
    for (uint16_t v : {0x0000, 0x0001, 0xffcf, 0x1234, 0xffff}) {
      t.write(0, v);
      check((t.read(0) & 0x30) == 0x30, "bits 4/5 not forced set");
      check(t.read(0) == ref_read0(v), "offset 0 disagrees with the reference");
    }
  }

  printf("test: bit 2 CLEAR — bit 6 mirrors bit 3\n");
  {
    Dut t;
    t.write(0, 0x0000);                       // bit2=0, bit3=0
    check((t.read(0) & 0x40) == 0x00, "bit 6 should mirror a clear bit 3");
    t.write(0, 0x0008);                       // bit2=0, bit3=1
    check((t.read(0) & 0x40) == 0x40, "bit 6 should mirror a set bit 3");
    check(t.d->list_sel == 1, "list_sel should follow bit 3 in manual mode");
    // And a frame pulse must NOT toggle it in this mode.
    t.frame(); t.frame(); t.frame();
    check((t.read(0) & 0x40) == 0x40, "frames toggled bit 6 while bit 2 was clear");
    // Writing bit 6 directly is overridden by the mirror, as the reference does.
    t.write(0, 0x0040);                       // bit2=0, bit3=0, bit6=1
    check((t.read(0) & 0x40) == 0x00, "a written bit 6 survived the mirror");
  }

  printf("test: bit 2 SET — bit 6 toggles once every two frames\n");
  {
    Dut t;
    t.write(0, 0x0004);                       // bit2=1, bit6=0
    check((t.read(0) & 0x40) == 0, "bit 6 should start clear");
    int flips = 0, last = 0;
    for (int f = 0; f < 8; f++) {
      t.frame();
      int now = (t.read(0) & 0x40) ? 1 : 0;
      if (now != last) flips++;
      last = now;
    }
    // Eight frames, toggling on every second one.
    check(flips == 4, "bit 6 did not toggle once per two frames");
    printf("  8 frames produced %d flips\n", flips);
  }

  printf("test: offset 1 is independent, unforced and unmirrored\n");
  {
    Dut t;
    t.write(1, 0xabcd);
    check(t.read(1) == 0xabcd, "offset 1 did not latch");
    check(t.read(0) == 0x0030, "writing offset 1 disturbed offset 0");
    t.write(0, 0x00ff);
    check(t.read(1) == 0xabcd, "writing offset 0 disturbed offset 1");
  }

  printf("test: byte enables\n");
  {
    Dut t;
    t.write(1, 0xffff);
    t.write(1, 0x0000, 1);                    // low byte only
    check(t.read(1) == 0xff00, "low-byte-only write hit the high byte");
    t.write(1, 0x0000, 2);                    // high byte only
    check(t.read(1) == 0x0000, "high-byte-only write did not land");
  }

  printf("m1_listctl: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
