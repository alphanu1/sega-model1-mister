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
// ROM loader verification, against the real SDRAM controller.
//
// A ROM loader is one of the few blocks where a bug is nearly undebuggable
// downstream. Every failure mode — a dropped word under backpressure, a
// misplaced region, a byte-swapped pair, releasing reset before the last write
// drains — produces a core that loads without complaint and then fails a
// checksum or boots to garbage, with all the evidence pointing at the CPU.
//
// So the model of the HPS here is deliberately hostile in the one way the real
// HPS is: it does NOT stop the instant ioctl_wait asserts. It keeps sending
// for a randomised few cycles, which is what a real host with transfers
// already in flight does, and it is the case a loader that treats wait as
// instantaneous gets wrong.

#include "Vm1_loader_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <map>
#include <random>
#include <vector>

static const uint32_t TGP_PROG_BASE = 0x1F00000;
static const uint32_t STREAM_END    = 0x1F02000;

struct Loader {
  Vm1_loader_harness* d;
  long cyc = 0;
  long fails = 0, checks = 0;

  // What the stream said should end up where.
  std::map<uint32_t, uint16_t> expect_sdram;   // word address -> data
  std::map<uint32_t, uint32_t> expect_tgp;     // program word index -> data
  std::map<uint32_t, uint32_t> got_tgp;

  Loader() {
    d = new Vm1_loader_harness;
    d->clk = 0; d->rst_n = 0;
    d->ioctl_download = 0; d->ioctl_index = 0; d->ioctl_wr = 0;
    d->ioctl_addr = 0; d->ioctl_dout = 0;
    d->p0_req = 0; d->p0_addr = 0;
    d->eval();
  }
  ~Loader() { delete d; }

  void tick() {
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    cyc++;
    // The TGP program port is a plain write strobe; capture it as it goes by.
    if (d->tgp_wr) got_tgp[d->tgp_addr] = d->tgp_din;
  }

  void reset() {
    d->rst_n = 0;
    for (int i = 0; i < 8; i++) tick();
    d->rst_n = 1;
    long guard = 0;
    while (!d->mem_ready && guard++ < 20000) tick();
    if (!d->mem_ready) { printf("  FAIL SDRAM never became ready\n"); fails++; }
  }
};

// Streams a region, modelling a host that reacts to ioctl_wait late.
static void stream(Loader& h, std::mt19937& rng, uint32_t base, uint32_t words,
                   int wait_latency) {
  std::vector<int> pending;              // cycles of "already in flight"
  uint32_t i = 0;
  h.d->ioctl_download = 1;
  h.d->ioctl_index = 0;

  int slack = 0;
  while (i < words) {
    bool waiting = h.d->ioctl_wait;
    // The host only notices ioctl_wait after `wait_latency` cycles, so it
    // keeps pushing words into a loader that has already asked it to stop.
    // That is the whole point of this test.
    if (waiting) {
      if (slack < wait_latency) slack++;
      else { h.d->ioctl_wr = 0; h.tick(); continue; }
    } else {
      slack = 0;
    }

    uint32_t addr = base + i * 2;
    uint16_t data = (uint16_t)rng();
    h.d->ioctl_addr = addr;
    h.d->ioctl_dout = data;
    h.d->ioctl_wr = 1;

    if (addr < TGP_PROG_BASE) {
      h.expect_sdram[addr >> 1] = data;
    } else if (addr < STREAM_END) {
      uint32_t idx = (addr - TGP_PROG_BASE) >> 2;
      if (addr & 2) h.expect_tgp[idx] = (h.expect_tgp[idx] & 0xffff) | ((uint32_t)data << 16);
      else          h.expect_tgp[idx] = (h.expect_tgp[idx] & 0xffff0000u) | data;
    }
    h.tick();
    h.d->ioctl_wr = 0;
    i++;
    // Occasional idle gaps, as a real transfer has between blocks.
    if ((rng() & 31) == 0) { int g = rng() % 4; for (int k = 0; k < g; k++) h.tick(); }
  }
  h.d->ioctl_wr = 0;
}

static void finish_download(Loader& h) {
  h.d->ioctl_download = 0;
  long guard = 0;
  while (!h.d->rom_loaded && guard++ < 100000) h.tick();
  h.checks++;
  if (!h.d->rom_loaded) { printf("  FAIL rom_loaded never asserted\n"); h.fails++; }
}

// Read one word back through p0, the port the V60 will use.
static uint16_t read_word(Loader& h, uint32_t waddr) {
  h.d->p0_addr = waddr;
  h.d->p0_req = 1;
  h.tick();
  h.d->p0_req = 0;
  long guard = 0;
  while (!h.d->p0_ack && guard++ < 5000) h.tick();
  uint16_t v = (uint16_t)(h.d->p0_dout & 0xffff);
  while (h.d->p0_ack) h.tick();
  return v;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Loader h;
  std::mt19937 rng(20260815u);

  printf("test: SDRAM comes up, then a stream loads and reads back\n");
  h.reset();
  {
    // A slice of each region rather than 31 MB of it: the mapping is the
    // identity, so what matters is that every region's addresses are reached,
    // not that every byte of a 16 MB pad is written.
    const uint32_t regions[] = {
      0x0000000,   // V60 ROM
      0x0400000,   // TGP data ROM
      0x0600000,   // sound 68000
      0x0700000,   // MultiPCM 1
      0x0B00000,   // MultiPCM 2
      0x0F00000,   // polygon ROM
    };
    for (uint32_t base : regions) stream(h, rng, base, 400, 2);
    stream(h, rng, TGP_PROG_BASE, 256, 2);     // TGP program, 128 32-bit words
    finish_download(h);

    h.checks++;
    if (h.d->overflow) { printf("  FAIL loader buffer overflowed\n"); h.fails++; }

    // Read back a sample from each region.
    long bad = 0;
    for (auto& kv : h.expect_sdram) {
      if ((rng() & 7) != 0) continue;         // sample, a full sweep is slow
      uint16_t got = read_word(h, kv.first);
      h.checks++;
      if (got != kv.second) {
        if (bad < 10)
          printf("  FAIL sdram word %06x got=%04x want=%04x\n",
                 kv.first, got, kv.second);
        bad++; h.fails++;
      }
    }
    printf("  loaded %zu SDRAM words, %zu TGP words, %ld readback errors\n",
           h.expect_sdram.size(), h.expect_tgp.size(), bad);
  }

  printf("test: TGP program words assemble low half first\n");
  {
    long bad = 0;
    h.checks++;
    if (h.got_tgp.size() != h.expect_tgp.size()) {
      printf("  FAIL TGP wrote %zu words, expected %zu\n",
             h.got_tgp.size(), h.expect_tgp.size());
      h.fails++;
    }
    for (auto& kv : h.expect_tgp) {
      h.checks++;
      if (!h.got_tgp.count(kv.first) || h.got_tgp[kv.first] != kv.second) {
        if (bad < 10)
          printf("  FAIL tgp word %03x got=%08x want=%08x\n", kv.first,
                 h.got_tgp.count(kv.first) ? h.got_tgp[kv.first] : 0, kv.second);
        bad++; h.fails++;
      }
    }
    printf("  %zu program words, %ld mismatches\n", h.expect_tgp.size(), bad);
  }

  printf("test: nothing is dropped however late the host reacts to wait\n");
  {
    // Sweep the host's reaction latency. A loader that asserts wait and
    // assumes the next write cannot arrive loses words here, and the loss is
    // silent — which is why overflow is an explicit output rather than an
    // assumption.
    for (int lat = 0; lat <= 6; lat++) {
      Loader g;
      std::mt19937 r2(1000u + lat);
      g.reset();
      stream(g, r2, 0x0000000, 600, lat);
      finish_download(g);
      h.checks++;
      if (g.d->overflow) {
        printf("  FAIL overflow at host wait latency %d\n", lat);
        h.fails++;
        continue;
      }
      long bad = 0;
      for (auto& kv : g.expect_sdram) {
        if ((r2() & 3) != 0) continue;
        uint16_t got = read_word(g, kv.first);
        h.checks++;
        if (got != kv.second) { bad++; h.fails++; }
      }
      if (bad) printf("  FAIL latency %d: %ld words wrong\n", lat, bad);
      h.checks++;
      if (g.d->violations) {
        printf("  FAIL latency %d: %u protocol violations\n", lat, g.d->violations);
        h.fails++;
      }
    }
    printf("  host wait latency 0..6 all clean\n");
  }

  printf("test: rom_loaded waits for the last write to drain\n");
  {
    // Releasing reset while writes are still in the buffer starts the V60 on a
    // ROM that is not all there. The download ends with the buffer deliberately
    // full, and rom_loaded must not assert until it has emptied.
    Loader g;
    std::mt19937 r2(4242u);
    g.reset();
    stream(g, r2, 0x0000000, 200, 6);
    size_t want_writes = g.expect_sdram.size();
    g.d->ioctl_download = 0;

    // The real property is not "rom_loaded came a bit late", it is that when
    // it asserts, every word of the stream has actually reached the device.
    // An earlier version of this test sampled rom_loaded one cycle after the
    // download ended, printed it, and asserted nothing — so a loader that
    // raised rom_loaded the instant the stream ended passed, because the
    // buffered writes still drained before the readback got around to
    // checking them. Counting the device's accepted writes at the moment
    // rom_loaded rises is exact.
    long guard = 0;
    while (!g.d->rom_loaded && guard++ < 100000) g.tick();
    unsigned at_assert = g.d->writes_served;
    h.checks++;
    if (!g.d->rom_loaded) {
      printf("  FAIL rom_loaded never asserted\n"); h.fails++;
    } else if (at_assert < want_writes) {
      printf("  FAIL rom_loaded asserted with %u/%zu writes done\n",
             at_assert, want_writes);
      h.fails++;
    }
    // Every word must be present once it does assert.
    long bad = 0;
    for (auto& kv : g.expect_sdram) {
      uint16_t got = read_word(g, kv.first);
      h.checks++;
      if (got != kv.second) { bad++; h.fails++; }
    }
    h.checks++;
    if (bad) { printf("  FAIL %ld words missing after rom_loaded\n", bad); }
    printf("  %u/%zu writes complete when rom_loaded asserted, %ld words missing\n",
           at_assert, want_writes, bad);
  }

  printf("test: a foreign ioctl index is ignored\n");
  {
    // Other indices carry NVRAM images and similar. Writing them into ROM
    // space would corrupt whatever was loaded there.
    Loader g;
    std::mt19937 r2(77u);
    g.reset();
    stream(g, r2, 0x0000000, 100, 1);
    finish_download(g);
    auto before = g.expect_sdram.begin();
    uint16_t orig = read_word(g, before->first);

    g.d->ioctl_download = 1; g.d->ioctl_index = 2;
    for (int i = 0; i < 50; i++) {
      g.d->ioctl_addr = before->first * 2; g.d->ioctl_dout = 0xdead;
      g.d->ioctl_wr = 1; g.tick(); g.d->ioctl_wr = 0; g.tick();
    }
    g.d->ioctl_download = 0;
    for (int i = 0; i < 200; i++) g.tick();

    uint16_t after = read_word(g, before->first);
    h.checks++;
    if (after != orig) {
      printf("  FAIL index 2 overwrote ROM: %04x -> %04x\n", orig, after);
      h.fails++;
    } else {
      printf("  ROM word intact through a foreign index transfer\n");
    }
  }

  h.checks++;
  if (h.d->violations) {
    printf("  FAIL %u protocol violations, flags=%04x\n",
           h.d->violations, h.d->v_flags);
    h.fails++;
  }

  printf("m1_rom_loader: checks=%ld fails=%ld violations=%u\n",
         h.checks, h.fails, h.d->violations);
  return h.fails ? 1 : 0;
}
