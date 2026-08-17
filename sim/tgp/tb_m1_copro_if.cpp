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
// The V60 side of the coprocessor interface.
//
// Directed rather than fuzzed, because what can go wrong here is not a value
// but a RULE, and there are four of them. Each is transcribed from
// model1_m.cpp and each is the kind of thing that reads as plausible either way
// round:
//
//   1. the RAM window commits on the HIGH half
//   2. the address post-increments only when bit 15 of the register is set
//   3. a FIFO read pops on the LOW access
//   4. a FIFO write pushes on the HIGH access
//
// 3 and 4 are opposite ways round, which is the whole reason this file exists.
// A symmetric implementation passes a careless test and skews every transfer by
// one word.

#include "Vm1_copro_if.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static long checks = 0, fails = 0;
static void check(bool ok, const char* what) {
  checks++;
  if (!ok) { printf("  FAIL %s\n", what); fails++; }
}

struct Dut {
  Vm1_copro_if* d;

  Dut() {
    d = new Vm1_copro_if;
    d->clk = 0; d->rst_n = 0;
    d->sel_adr = 0; d->sel_ram = 0; d->sel_fifo = 0;
    d->stb = 0; d->we = 0; d->a1 = 0; d->be = 3; d->wdata = 0;
    d->fifo_in_pop = 0; d->fifo_out_push = 0; d->fifo_out_data = 0;
    d->eval();
    for (int i = 0; i < 4; i++) tick();
    d->rst_n = 1;
    tick();
  }
  ~Dut() { delete d; }

  void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }

  void idle(int n = 1) {
    d->stb = 0; d->sel_adr = d->sel_ram = d->sel_fifo = 0; d->we = 0;
    for (int i = 0; i < n; i++) tick();
  }

  // One bus beat. Read data is registered, so it is valid after the tick.
  void wr(int which, int a1, uint16_t data, int be = 3) {
    d->sel_adr = (which == 0); d->sel_ram = (which == 1); d->sel_fifo = (which == 2);
    d->stb = 1; d->we = 1; d->a1 = a1; d->be = be; d->wdata = data;
    tick();
    idle();
  }
  // q is combinational, so it is sampled DURING the strobe — the same cycle
  // m1_main latches it — not after the tick.
  uint16_t rd(int which, int a1) {
    d->sel_adr = (which == 0); d->sel_ram = (which == 1); d->sel_fifo = (which == 2);
    d->stb = 1; d->we = 0; d->a1 = a1;
    d->clk = 0; d->eval();
    uint16_t v = d->q;
    d->clk = 1; d->eval();
    idle();
    return v;
  }
  static const int ADR = 0, RAM = 1, FIFO = 2;

  // The address register has to settle before a RAM read, because the read
  // address tracks it continuously rather than being presented per access.
  void set_adr(uint16_t v) { wr(ADR, 0, v); idle(2); }
};

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  printf("test: the address register reads back, with byte enables\n");
  {
    Dut t;
    t.set_adr(0x1234);
    check(t.rd(Dut::ADR, 0) == 0x1234, "address register did not read back");

    // COMBINE_DATA in MAME, so a byte-masked write leaves the other half alone.
    t.wr(Dut::ADR, 0, 0xff00, 1);            // low byte only
    check(t.rd(Dut::ADR, 0) == 0x1200, "low-byte write hit the high byte");
    // be[1] gates wdata[15:8], so the byte value belongs in the high half of
    // wdata — not in the low half as an "0x00ab means write 0xab" reading would
    // have it. That mistake was in this test first.
    t.wr(Dut::ADR, 0, 0xab00, 2);            // high byte only
    check(t.rd(Dut::ADR, 0) == 0xab00, "high-byte write hit the low byte");
  }

  printf("test: the RAM window commits on the HIGH half\n");
  {
    // Writing only the low half must leave memory untouched. If the commit were
    // on the low access instead, half the words would carry stale high halves
    // and the geometry would be wrong in a way no unit test of the TGP shows.
    Dut t;
    t.set_adr(0x0010);
    t.wr(Dut::RAM, 0, 0xbeef);               // low half: latch only
    t.idle(2);
    check(t.rd(Dut::RAM, 0) == 0x0000, "the low half committed on its own");

    t.wr(Dut::RAM, 1, 0xdead);               // high half: commits {dead,beef}
    t.idle(2);
    check(t.rd(Dut::RAM, 0) == 0xbeef, "low half of the committed word is wrong");
    check(t.rd(Dut::RAM, 1) == 0xdead, "high half of the committed word is wrong");
  }

  printf("test: post-increment happens only when bit 15 is set\n");
  {
    Dut t;
    // Bit 15 clear: the address must not move, so two writes land in one place.
    t.set_adr(0x0020);
    t.wr(Dut::RAM, 0, 0x1111); t.wr(Dut::RAM, 1, 0x2222); t.idle(2);
    check(t.rd(Dut::ADR, 0) == 0x0020, "address moved with bit 15 clear");

    t.wr(Dut::RAM, 0, 0x3333); t.wr(Dut::RAM, 1, 0x4444); t.idle(2);
    check(t.rd(Dut::ADR, 0) == 0x0020, "address moved with bit 15 clear (2)");
    check(t.rd(Dut::RAM, 0) == 0x3333, "second write did not overwrite the first");

    // Bit 15 set: each committed word advances the address by one.
    t.set_adr(0x8030);
    t.wr(Dut::RAM, 0, 0xaaaa); t.wr(Dut::RAM, 1, 0xbbbb); t.idle(2);
    check(t.rd(Dut::ADR, 0) == 0x8031, "address did not post-increment");
    t.wr(Dut::RAM, 0, 0xcccc); t.wr(Dut::RAM, 1, 0xdddd); t.idle(2);
    check(t.rd(Dut::ADR, 0) == 0x8032, "address did not post-increment (2)");

    // And the two words landed in consecutive slots, not on top of each other.
    t.set_adr(0x0030); check(t.rd(Dut::RAM, 0) == 0xaaaa, "word 0 wrong");
    t.set_adr(0x0031); check(t.rd(Dut::RAM, 0) == 0xcccc, "word 1 wrong");
  }

  printf("test: a RAM read also post-increments on the high half\n");
  {
    // MAME increments in v60_copro_ram_r as well as _w, on the same condition.
    // A write-only increment would desynchronise any read-back sweep.
    Dut t;
    t.set_adr(0x8040);
    (void)t.rd(Dut::RAM, 0);
    check(t.rd(Dut::ADR, 0) == 0x8040, "the low-half read incremented");
    (void)t.rd(Dut::RAM, 1);
    check(t.rd(Dut::ADR, 0) == 0x8041, "the high-half read did not increment");
  }

  printf("test: the FIFO is asymmetric — push on HIGH, pop on LOW\n");
  {
    Dut t;
    // Write: the low half must not push on its own.
    t.wr(Dut::FIFO, 0, 0x5678);
    check(t.d->fifo_in_valid == 0, "the low half pushed on its own");
    t.wr(Dut::FIFO, 1, 0x1234);
    check(t.d->fifo_in_valid == 1, "the high half did not push");
    check(t.d->fifo_in_data == 0x12345678u, "the pushed word is assembled wrong");

    t.d->fifo_in_pop = 1; t.tick(); t.d->fifo_in_pop = 0; t.idle();
    check(t.d->fifo_in_valid == 0, "the pop did not empty the FIFO");

    // Read: the TGP pushes a word, and the V60's LOW access is what pops it.
    t.d->fifo_out_data = 0xcafef00du; t.d->fifo_out_push = 1; t.tick();
    t.d->fifo_out_push = 0; t.idle();
    check(t.rd(Dut::FIFO, 0) == 0xf00d, "low half of the popped word is wrong");
    check(t.rd(Dut::FIFO, 1) == 0xcafe, "high half did not come from the popped word");
  }

  printf("test: two queued words come back in order\n");
  {
    // The high access must return the half of the word the LOW access popped,
    // not the head of the queue — otherwise a two-word read interleaves.
    Dut t;
    const uint32_t a = 0x11112222u, b = 0x33334444u;
    t.d->fifo_out_data = a; t.d->fifo_out_push = 1; t.tick();
    t.d->fifo_out_data = b;                          t.tick();
    t.d->fifo_out_push = 0; t.idle();

    check(t.rd(Dut::FIFO, 0) == 0x2222, "first word, low half");
    check(t.rd(Dut::FIFO, 1) == 0x1111, "first word, high half");
    check(t.rd(Dut::FIFO, 0) == 0x4444, "second word, low half");
    check(t.rd(Dut::FIFO, 1) == 0x3333, "second word, high half");
  }

  printf("test: a sweep with auto-increment reads back what it wrote\n");
  {
    // The pattern the V60 actually uses: set the address once with bit 15, then
    // stream. Exercises the increment, the commit rule and the RAM together.
    Dut t;
    t.set_adr(0x8100);
    for (int i = 0; i < 16; i++) {
      t.wr(Dut::RAM, 0, (uint16_t)(0x1000 + i));
      t.wr(Dut::RAM, 1, (uint16_t)(0x2000 + i));
    }
    t.idle(2);
    check(t.rd(Dut::ADR, 0) == 0x8110, "the sweep did not advance 16 words");

    for (int i = 0; i < 16; i++) {
      t.set_adr(0x0100 + i);
      check(t.rd(Dut::RAM, 0) == (uint16_t)(0x1000 + i), "swept low half wrong");
      check(t.rd(Dut::RAM, 1) == (uint16_t)(0x2000 + i), "swept high half wrong");
    }
  }

  printf("test: a held strobe would triple-fire, so it must be one cycle\n");
  {
    // m1_main holds m_req across B_IDLE, B_LOCAL and B_ACK. The interface is
    // driven from B_LOCAL alone for that reason, and this pins what goes wrong
    // otherwise: three cycles of strobe on an auto-incrementing access advance
    // the address three times, which reads downstream as the V60 skipping two
    // words in every three.
    Dut t;
    t.set_adr(0x8200);
    // one-cycle strobe: exactly one increment
    (void)t.rd(Dut::RAM, 1);
    check(t.rd(Dut::ADR, 0) == 0x8201, "one strobe did not advance exactly one word");

    // three cycles of strobe: three increments, which is the bug this guards
    t.d->sel_ram = 1; t.d->sel_adr = 0; t.d->sel_fifo = 0;
    t.d->stb = 1; t.d->we = 0; t.d->a1 = 1;
    t.tick(); t.tick(); t.tick();
    t.idle();
    check(t.rd(Dut::ADR, 0) == 0x8204,
          "a held strobe did not advance three words — the guard is not measuring what it claims");
  }

  printf("test: the FIFO pops exactly once per access\n");
  {
    // The same hazard on the path where it corrupts rather than skews: a held
    // strobe on a FIFO read would pop three words and return the third.
    Dut t;
    for (uint32_t i = 1; i <= 3; i++) {
      t.d->fifo_out_data = 0x1000u * i; t.d->fifo_out_push = 1; t.tick();
    }
    t.d->fifo_out_push = 0; t.idle();
    check(t.rd(Dut::FIFO, 0) == 0x1000, "first pop");
    check(t.rd(Dut::FIFO, 0) == 0x2000, "second pop — one access popped more than one word");
    check(t.rd(Dut::FIFO, 0) == 0x3000, "third pop");
  }

  printf("m1_copro_if: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
