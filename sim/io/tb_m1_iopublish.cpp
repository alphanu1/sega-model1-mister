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
// It checks the mechanism: that all eight bytes reach the RAM, that they track
// their inputs, that the handshake still wins the port, and that idle state is
// published as 0xFF rather than as zero. It CANNOT check that the layout is
// right, because the layout is not known — see docs/io-board.md. The base
// address is a parameter for exactly that reason.

#include "Vm1_ioboard.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

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

  Dut() {
    d = new Vm1_ioboard;
    d->clk = 0; d->rst_n = 0;
    d->v60_req = 0; d->v60_we = 0; d->v60_sel_dpram = 0;
    d->v60_addr = 0; d->v60_wdata = 0; d->io_ack = 0;
    d->in_bytes = 0xffffffffffffffffull;
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

  printf("test: all eight control bytes reach the shared RAM\n");
  {
    Dut t;
    t.d->in_bytes = 0x0807060504030201ull;
    t.run(4000);
    for (int i = 0; i < 8; i++)
      check(t.ram[i] == i + 1, "byte did not reach the RAM");
    printf("  bytes 0..7 = %02x %02x %02x %02x %02x %02x %02x %02x\n",
           t.ram[0], t.ram[1], t.ram[2], t.ram[3],
           t.ram[4], t.ram[5], t.ram[6], t.ram[7]);
  }

  printf("test: a change in the inputs is followed\n");
  {
    Dut t;
    t.run(4000);
    check(t.ram[0] == 0xff, "idle state was not published");

    // A button press is a bit going LOW, because every control on this
    // hardware is active low.
    t.d->in_bytes = 0xfffffffffffffffbull;   // byte 0, bit 2
    t.run(4000);
    check(t.ram[0] == 0xfb, "press was not published");

    t.d->in_bytes = 0xffffffffffffffffull;
    t.run(4000);
    check(t.ram[0] == 0xff, "release was not published");
  }

  printf("test: idle is 0xFF, not 0x00\n");
  {
    // The whole point: an M10K comes up zeroed, and zero on an active-low
    // input byte is every button held. A core that publishes nothing is not
    // neutral, it is stuck on.
    Dut t;
    check(t.ram[0] == 0x00, "test setup: RAM should start cleared");
    t.run(4000);
    for (int i = 0; i < 8; i++)
      check(t.ram[i] == 0xff, "idle byte was not 0xFF");
  }

  printf("test: the handshake still wins the port\n");
  {
    // Publishing must not delay the reply boot blocks on. Raise the flag and
    // confirm it is still answered while refreshes are competing for the same
    // single write port.
    Dut t;
    t.run(2000);

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
    t.d->in_bytes = 0x1111111111111111ull;
    t.run(4000);
    check(t.ram[3] == 0x11, "publishing did not resume after the handshake");
  }

  printf("m1_iopublish: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
