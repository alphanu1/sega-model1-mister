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
    d->req = 0; d->we = 0; d->a1 = 0; d->be = 3; d->wdata = 0;
    d->fifo_in_pop = 0; d->fifo_out_push = 0; d->fifo_out_data = 0;
    d->eval();
    for (int i = 0; i < 4; i++) tick();
    d->rst_n = 1;
    tick();
  }
  ~Dut() { delete d; }

  void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }

  void idle(int n = 1) {
    d->req = 0; d->sel_adr = d->sel_ram = d->sel_fifo = 0; d->we = 0;
    for (int i = 0; i < n; i++) tick();
  }

  // A held request, released on ack — the same discipline m1_main uses for
  // SDRAM. Holding it is the realistic case, and the one that would expose a
  // double-pop or a repeated increment if the action were not a one-shot.
  int run_until_ack(int limit = 16) {
    for (int i = 0; i < limit; i++) {
      tick();
      if (d->ack) return i + 1;
    }
    return -1;
  }
  void wr(int which, int a1, uint16_t data, int be = 3) {
    d->sel_adr = (which == 0); d->sel_ram = (which == 1); d->sel_fifo = (which == 2);
    d->req = 1; d->we = 1; d->a1 = a1; d->be = be; d->wdata = data;
    check(run_until_ack() > 0, "write was never acknowledged");
    idle();
  }
  // q is valid with ack.
  uint16_t rd(int which, int a1) {
    d->sel_adr = (which == 0); d->sel_ram = (which == 1); d->sel_fifo = (which == 2);
    d->req = 1; d->we = 0; d->a1 = a1;
    check(run_until_ack() > 0, "read was never acknowledged");
    uint16_t v = d->q;
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

  printf("test: a held request acts exactly once\n")
  ;
  {
    // req is held until ack, so the guard is no longer "keep it short" but
    // "act once however long it is held". A held request that incremented per
    // cycle would read downstream as the V60 skipping words.
    Dut t;
    t.set_adr(0x8200);
    t.d->sel_ram = 1; t.d->sel_adr = 0; t.d->sel_fifo = 0;
    t.d->req = 1; t.d->we = 0; t.d->a1 = 1;
    (void)t.run_until_ack();
    // hold it well past the acknowledge
    for (int i = 0; i < 6; i++) t.tick();
    t.idle();
    check(t.rd(Dut::ADR, 0) == 0x8201,
          "a held request incremented more than once");
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

  printf("test: the TGP port reads and writes the same RAM\n");
  {
    // One RAM, two masters. The TGP's own four address registers and its
    // increment rule (always, by 4 when bit 18 is set) live on its side — this
    // port is plain memory, and what matters here is that both sides see the
    // same words.
    Dut t;
    t.d->tgp_addr = 0x0055; t.d->tgp_wdata = 0xfeedface; t.d->tgp_we = 1;
    t.d->tgp_req = 1;
    for (int i = 0; i < 8 && !t.d->tgp_ack; i++) t.tick();
    check(t.d->tgp_ack == 1, "the TGP write was not acknowledged");
    t.d->tgp_req = 0; t.d->tgp_we = 0; t.idle();

    // the V60 must see it
    t.set_adr(0x0055);
    check(t.rd(Dut::RAM, 0) == 0xface, "the V60 does not see the TGP's low half");
    check(t.rd(Dut::RAM, 1) == 0xfeed, "the V60 does not see the TGP's high half");

    // and the other direction
    t.set_adr(0x0056);
    t.wr(Dut::RAM, 0, 0x1234); t.wr(Dut::RAM, 1, 0x5678); t.idle(2);
    t.d->tgp_addr = 0x0056; t.d->tgp_we = 0; t.d->tgp_req = 1;
    for (int i = 0; i < 8 && !t.d->tgp_ack; i++) t.tick();
    check(t.d->tgp_ack == 1, "the TGP read was not acknowledged");
    check(t.d->tgp_rdata == 0x56781234u, "the TGP does not see the V60's word");
    t.d->tgp_req = 0; t.idle();
  }

  printf("test: the V60 wins the port, and the TGP still completes\n");
  {
    // Both asserted at once. The V60 goes first because it is the side whose
    // CPU stalls; the TGP must not be starved or dropped.
    Dut t;
    t.set_adr(0x0060);
    t.d->tgp_addr = 0x0061; t.d->tgp_wdata = 0xa5a5a5a5; t.d->tgp_we = 1;
    t.d->tgp_req = 1;
    t.d->sel_ram = 1; t.d->req = 1; t.d->we = 0; t.d->a1 = 0;

    int v60_at = -1, tgp_at = -1;
    for (int i = 0; i < 24; i++) {
      t.tick();
      if (t.d->ack     && v60_at < 0) v60_at = i;
      if (t.d->tgp_ack && tgp_at < 0) tgp_at = i;
    }
    check(v60_at >= 0, "the V60 access never completed under contention");
    check(tgp_at >= 0, "the TGP access never completed — starved");
    check(v60_at <= tgp_at, "the TGP was served before the V60");
    printf("  V60 acked at cycle %d, TGP at %d\n", v60_at, tgp_at);
    t.d->req = 0; t.d->tgp_req = 0; t.d->tgp_we = 0; t.idle();

    t.set_adr(0x0061);
    check(t.rd(Dut::RAM, 0) == 0xa5a5, "the TGP's contended write was lost");
  }

  printf("m1_copro_if: checks=%ld fails=%ld\n", checks, fails);
  return fails ? 1 : 0;
}
