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
// The I/O board publishing control state into the shared RAM.
//
// Separate from tb_m1_ioboard because that one asserts things about the write
// port being idle between handshakes, which is exactly what publishing denies.
// Weakening those assertions to accommodate this traffic would blunt the test
// that covers the thing boot actually blocks on.
//
// WHAT THIS CAN AND CANNOT CHECK
//
// It checks the mechanism: that all fifteen bytes reach the RAM at the right
// addresses, that they track their inputs, that the handshake still wins the
// port, and that the sweep wraps at 0x0e rather than running past it.
//
// The layout it checks against is measured — MAME running the real Z80, one
// control at a time, see docs/io-board.md. 0x00-0x02 are the ADC channels and
// 0x08/0x09 the two digital ports. What it still cannot check is whether the
// V60 *likes* what it finds there; only running the game does that.

#include "Vm1_ioboard.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

// Where the sweep lands and how long a full pass takes. Both track the module's
// parameters: base 0x00 covers the whole control region, and the gap is
// deliberately slow — the real board sweeps once per loop at 4 MHz, and
// refreshing faster than that is what broke the first version of this.
static const int BASE   = 0x00;
static const int NBYTES = 15;
static const int PASS   = NBYTES * 2048 + 4096;   // a full pass, plus slack

static long checks = 0, fails = 0;
static void check(bool ok, const char* what) {
  checks++;
  if (!ok) { printf("  FAIL %s\n", what); fails++; }
}

struct Dut {
  Vm1_ioboard* d;
  // The shared RAM, as the module writes it. Starts at zero like a real M10K,
  // which is the state that presents every active-low control as held.
  uint8_t ram[2048] = {0};

  // in_bytes is 120 bits, so Verilator carries it as a word array rather than a
  // scalar. Go through these rather than touching the words directly — the byte
  // index is the DPRAM offset, which is what every expectation here is written
  // in terms of.
  void set(int idx, uint8_t v) {
    d->in_bytes[idx >> 2] &= ~(0xffu << ((idx & 3) * 8));
    d->in_bytes[idx >> 2] |= (uint32_t)v << ((idx & 3) * 8);
  }
  void set_all(uint8_t v) { for (int i = 0; i < NBYTES; i++) set(i, v); }

  Dut() {
    d = new Vm1_ioboard;
    d->clk = 0; d->rst_n = 0;
    d->v60_req = 0; d->v60_we = 0; d->v60_sel_dpram = 0;
    d->v60_addr = 0; d->v60_wdata = 0; d->io_ack = 0;
    set_all(0xff);
    d->eval();
    for (int i = 0; i < 4; i++) tick();
    d->rst_n = 1;
  }
  ~Dut() { delete d; }

  void tick() {
    // The RAM accepts a held write and acknowledges it, which is the contract
    // m1_mainram offers: one physical port, ack when the byte lands.
    d->io_ack = d->io_we;
    d->clk = 0; d->eval();
    if (d->io_we && d->io_ack) ram[d->io_addr & 0x7ff] = d->io_din;
    d->clk = 1; d->eval();
  }
  void run(int n) { for (int i = 0; i < n; i++) tick(); }
};

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  printf("test: all fifteen control bytes reach the shared RAM\n");
  {
    Dut t;
    for (int i = 0; i < NBYTES; i++) t.set(i, i + 1);
    t.run(PASS);
    for (int i = 0; i < NBYTES; i++)
      check(t.ram[BASE + i] == i + 1, "byte did not reach the RAM");
    printf("  DPRAM %02x..%02x =", BASE, BASE + NBYTES - 1);
    for (int i = 0; i < NBYTES; i++) printf(" %02x", t.ram[BASE + i]);
    printf("\n");
  }

  printf("test: the sweep stops at 0x0e\n");
  {
    // 0x0f is driven by the board outward — it toggles on its own period in the
    // MAME capture — so writing control state over it would be modelling the
    // wrong direction. The index counter is four bits wide and would wrap at
    // 16 by itself, which is the mistake this catches.
    Dut t;
    t.set_all(0x5a);
    t.run(PASS * 3);
    check(t.ram[BASE + NBYTES] == 0x00, "the sweep ran past 0x0e");
    check(t.ram[BASE + NBYTES + 1] == 0x00, "the sweep ran well past 0x0e");
  }

  printf("test: every byte keeps its own value\n");
  {
    // A wrap that is off by one still writes every address; what it gets wrong
    // is which byte lands where. Distinct values catch that, a uniform fill
    // does not.
    Dut t;
    for (int i = 0; i < NBYTES; i++) t.set(i, 0xf0 | i);
    t.run(PASS * 3);
    for (int i = 0; i < NBYTES; i++)
      check(t.ram[BASE + i] == (0xf0 | i), "a byte landed at the wrong address");
  }

  printf("test: a change in the inputs is followed\n");
  {
    Dut t;
    t.run(PASS);
    check(t.ram[BASE + 8] == 0xff, "idle state was not published");

    // A button press is a bit going LOW, because every digital control on this
    // hardware is active low. Bit 2 of IN.0 is Test, measured.
    t.set(8, 0xfb);
    t.run(PASS);
    check(t.ram[BASE + 8] == 0xfb, "press was not published");

    t.set(8, 0xff);
    t.run(PASS);
    check(t.ram[BASE + 8] == 0xff, "release was not published");
  }

  printf("test: the analog channels carry arbitrary values\n");
  {
    // The digital bytes only ever take values with one bit clear, so a path
    // that corrupted the data but preserved the address could survive the
    // tests above. The ADC channels sweep their whole range, which is also
    // what the steering does in practice.
    Dut t;
    for (int v = 0; v < 256; v += 37) {
      t.set(0, (uint8_t)v);            // 0x00 steering
      t.set(1, (uint8_t)(255 - v));    // 0x01 accelerator
      t.run(PASS);
      check(t.ram[BASE + 0] == (uint8_t)v, "steering value was not published");
      check(t.ram[BASE + 1] == (uint8_t)(255 - v), "pedal value was not published");
    }
  }

  printf("test: idle is 0xFF, not 0x00\n");
  {
    // The whole point: an M10K comes up zeroed, and zero on an active-low
    // input byte is every button held. A core that publishes nothing is not
    // neutral, it is stuck on.
    Dut t;
    check(t.ram[BASE + 8] == 0x00, "test setup: RAM should start cleared");
    t.run(PASS);
    for (int i = 0; i < NBYTES; i++)
      check(t.ram[BASE + i] == 0xff, "idle byte was not 0xFF");
  }

  printf("test: the handshake still wins the port\n");
  {
    // Publishing must not delay the reply boot blocks on. Raise the flag and
    // confirm it is still answered while refreshes are competing for the same
    // single write port.
    Dut t;
    t.run(PASS);

    t.d->v60_req = 1; t.d->v60_we = 1; t.d->v60_sel_dpram = 1;
    t.d->v60_addr = 0x020; t.d->v60_wdata = 0x01;
    t.tick();
    t.d->v60_req = 0; t.d->v60_we = 0; t.d->v60_sel_dpram = 0;

    long answered = -1;
    for (long i = 0; i < 20000; i++) {
      t.tick();
      if (t.d->replies == 1) { answered = i; break; }
    }
    check(answered >= 0, "handshake was not answered while publishing");
    check(t.ram[0x20] == 0x00, "flag was not cleared");
    printf("  answered after %ld cycles with refreshes competing\n", answered);

    // And publishing resumes afterwards rather than being wedged by the
    // handshake having taken the port.
    t.set(3, 0x11);
    t.run(PASS);
    check(t.ram[BASE + 3] == 0x11, "publishing did not resume after the handshake");
  }

  printf("m1_iopublish: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
