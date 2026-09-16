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
// 315-5465 decode, checked against an independent transcription of MAME's map.
//
// The reference below is written from `model1_state::model1_mem` directly
// rather than from the RTL, so the two are independent transcriptions of the
// same source. That is the point: a reference derived from the DUT agrees with
// the DUT's bugs. Both were read from MAME, and where they disagree one of them
// misread it.
//
// The residual risk this does NOT cover: both were transcribed by the same
// person from the same source in one sitting, so a misreading of MAME's map
// appears identically in both and the comparison passes. Mutation testing
// proves the harness detects a difference; it cannot prove there is no shared
// error. What would settle it is running real game code against this decode,
// which is what M1's boot test is for.
//
// Coverage is exhaustive over the top byte — every one of the 256 possible
// 64 KB pages is decoded and compared — plus fuzzing inside pages to catch
// mis-sliced offsets, plus the exact boundary of every region, which is where
// off-by-one decode errors live.

#include "Vm1_decode.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <set>

enum Sel {
  NONE = 0, ROM, ROM_VOID, NVRAM, WRAM, DLIST0, DLIST1, LISTCTL, TILERAM,
  CHARRAM, VSYNC, PALETTE, COLXLAT, DPRAM, UART, COPRO_ADR, COPRO_RAM,
  COPRO_FIFO, FIFO_STAT, GLUE
};
static const char* SNAME[] = {
  "none", "rom", "rom_void", "nvram", "wram", "dlist0", "dlist1", "listctl",
  "tileram", "charram", "vsync", "palette", "colxlat", "dpram", "uart",
  "copro_adr", "copro_ram", "copro_fifo", "fifo_stat", "glue"
};

// Independent transcription of model1_mem.
static Sel ref_sel(uint32_t a, int roma_mode) {
  uint32_t hi = (a >> 16) & 0xff;
  // ROMA. MAME maps it .rom() for every game; four of the six populate it by
  // mirroring the boot ROM in with ROM_RELOAD, so whether it reads erased is a
  // property of the SET, not of the address space.
  //   mode 0  vr, vformula, vf   no reload
  //   mode 1  swa, swaj          512 KB at 0xf80000 reloaded to 0 AND 0x80000
  //           netmerc            the same part, reloaded to 0 only
  //   mode 2  wingwar            two 128 KB parts at 0xfc0000 / 0xfe0000
  //                              reloaded to 0x000000 / 0x020000 -- 256 KB
  //                              total, so above that it is erased again
  if (hi <= 0x0f) {
    if (roma_mode == 0) return ROM_VOID;
    if (roma_mode == 2 && (a & 0xc0000)) return ROM_VOID;
    return ROM;
  }
  if (hi <= 0x1f) return ROM;                       // ROMO, banked
  if (hi <= 0x2f) return ROM;                       // ROMX
  if (hi >= 0xf8) return ROM;                       // ROM0
  if (hi == 0x40) return NVRAM;                     // RAMA
  if (hi >= 0x50 && hi <= 0x53) return WRAM;        // RAMB
  if (hi == 0x60) return DLIST0;
  if (hi == 0x61) return DLIST1;
  if (hi == 0x68) return LISTCTL;
  if (hi == 0x70) return TILERAM;
  if (hi == 0x72 || hi == 0x74 || hi == 0x76 || hi == 0x77) return VSYNC;
  if (hi >= 0x78 && hi <= 0x7f) return CHARRAM;
  if (hi == 0x90) return PALETTE;
  if (hi == 0x91) return COLXLAT;
  if (hi == 0xc0) return DPRAM;
  if (hi == 0xc4) return UART;
  if (hi == 0xd0 || hi == 0xd1) return COPRO_ADR;   // mirror 0x1fffe
  if (hi == 0xd2 || hi == 0xd3) return COPRO_RAM;   // mirror 0x1fffc
  if (hi == 0xd8 || hi == 0xd9) return COPRO_FIFO;  // mirror 0x1fffc
  if (hi == 0xdc || hi == 0xdd) return FIFO_STAT;   // mirror 0x1fffc
  // GLUE IS SIXTEEN BYTES, NOT A PAGE. MAME maps e00000..e0000f individually and
  // nothing else in the page, with no mirror:
  //   e00000 irq_control_w  e00004 bank_w       e00008 timer_period_w
  //   e00002 irq_mask_r/w   e00006 timer_mode_w e0000c timer_r
  //
  // This model said the whole 0xe0 page, matching the RTL, so both were wrong
  // together and 466,714 checks passed anyway. Boot writes a run of bytes from
  // 0xe00010 upward and 0xe00012 aliased onto 0xe00002, clearing irq_mask right
  // after the game set it — found by diffing our write trace against MAME's.
  if (hi == 0xe0 && (a & 0xfff0) == 0) return GLUE;
  return NONE;
}

// Packed SDRAM word address for a mapped ROM access.
static uint32_t ref_rom_addr(uint32_t a, uint32_t bank, int roma_mode) {
  uint32_t hi = (a >> 16) & 0xff;
  // ROMA mirrors the packed boot region. Bit 19 is dropped, so the 1 MB region
  // wraps onto the 512 KB part twice -- which is exactly swa's pair of
  // ROM_RELOADs. Mode 2 starts 256 KB in, where wingwar's first part sits.
  if (hi <= 0x0f)
    return (roma_mode == 2 ? 0x0A0000 : 0x080000) + ((a & 0x7ffff) >> 1);
  if (hi <= 0x1f) return 0x0C0000 + bank * 0x80000 + ((a & 0xfffff) >> 1);
  if (hi <= 0x2f) return 0x000000 + ((a & 0xfffff) >> 1);
  return 0x080000 + ((a & 0x7ffff) >> 1);
}

static Sel dut_sel(Vm1_decode* d, int* count) {
  Sel s = NONE; *count = 0;
  auto chk = [&](int bit, Sel v) { if (bit) { s = v; (*count)++; } };
  chk(d->sel_rom, ROM);              chk(d->sel_rom_void, ROM_VOID);
  chk(d->sel_nvram, NVRAM);          chk(d->sel_wram, WRAM);
  chk(d->sel_dlist0, DLIST0);        chk(d->sel_dlist1, DLIST1);
  chk(d->sel_listctl, LISTCTL);      chk(d->sel_tileram, TILERAM);
  chk(d->sel_charram, CHARRAM);      chk(d->sel_vsync, VSYNC);
  chk(d->sel_palette, PALETTE);      chk(d->sel_colxlat, COLXLAT);
  chk(d->sel_dpram, DPRAM);          chk(d->sel_uart, UART);
  chk(d->sel_copro_adr, COPRO_ADR);  chk(d->sel_copro_ram, COPRO_RAM);
  chk(d->sel_copro_fifo, COPRO_FIFO);chk(d->sel_fifo_stat, FIFO_STAT);
  chk(d->sel_glue, GLUE);
  return s;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vm1_decode;
  long checks = 0, fails = 0;
  std::set<int> seen_regions;

  auto probe = [&](uint32_t addr, uint32_t bank, int roma_mode = 0) {
    d->addr = addr & 0xffffff;
    d->rom_bank = bank & 7;
    d->roma_mode = roma_mode & 3;
    d->eval();
    int n;
    Sel got = dut_sel(d, &n);
    Sel want = ref_sel(addr, roma_mode);
    checks++;
    seen_regions.insert((int)want);
    // One-hot is a property in its own right: two selects asserting means two
    // devices drive the bus, which on hardware is contention rather than a
    // wrong read.
    if (n > 1) {
      if (fails < 15)
        printf("  FAIL addr=%06x asserts %d selects at once\n", addr, n);
      fails++;
      return;
    }
    if (got != want) {
      if (fails < 15)
        printf("  FAIL addr=%06x got=%s want=%s\n", addr, SNAME[got], SNAME[want]);
      fails++;
      return;
    }
    if (want == ROM) {
      uint32_t ra = d->rom_addr, wa = ref_rom_addr(addr, bank, roma_mode);
      checks++;
      if (ra != wa) {
        if (fails < 15)
          printf("  FAIL addr=%06x bank=%u rom_addr got=%06x want=%06x\n",
                 addr, bank, ra, wa);
        fails++;
      }
    }
  };

  printf("test: every 64 KB page decodes as MAME's map says\n");
  for (int rm = 0; rm < 3; rm++)
    for (uint32_t page = 0; page < 256; page++)
      for (uint32_t bank = 0; bank < 8; bank++)
        probe(page << 16, bank, rm);

  printf("test: region boundaries, where off-by-one decode lives\n");
  {
    // The first and last address of every region MAME names, plus the address
    // either side of it.
    const uint32_t edges[] = {
      0x000000, 0x0fffff, 0x100000, 0x1fffff, 0x200000, 0x2fffff, 0x300000,
      0x3fffff, 0x400000, 0x40ffff, 0x410000, 0x4fffff, 0x500000, 0x53ffff,
      0x540000, 0x5fffff, 0x600000, 0x60ffff, 0x610000, 0x61ffff, 0x620000,
      0x680000, 0x680003, 0x680004, 0x6fffff, 0x700000, 0x70ffff, 0x710000,
      0x720000, 0x740000, 0x760000, 0x770000, 0x780000, 0x7fffff, 0x800000,
      0x8fffff, 0x900000, 0x903fff, 0x904000, 0x90ffff, 0x910000, 0x91bfff,
      0x91c000, 0x91ffff, 0x920000, 0xbfffff, 0xc00000, 0xc00fff, 0xc01000,
      0xc0ffff, 0xc40000, 0xc40003, 0xc40004, 0xcfffff, 0xd00000, 0xd1ffff,
      0xd20000, 0xd3ffff, 0xd40000, 0xd7ffff, 0xd80000, 0xd9ffff, 0xda0000,
      0xdbffff, 0xdc0000, 0xddffff, 0xde0000, 0xdfffff, 0xe00000, 0xe0000f,
      0xe00010, 0xe0ffff, 0xe10000, 0xf7ffff, 0xf80000, 0xffffff
    };
    for (uint32_t e : edges) {
      for (uint32_t bank = 0; bank < 8; bank++)
        for (int rm = 0; rm < 3; rm++) {
          probe(e, bank, rm);
          if (e) probe(e - 1, bank, rm);
          if (e != 0xffffff) probe(e + 1, bank, rm);
        }
    }
  }

  printf("test: fuzz inside pages, for mis-sliced offsets\n");
  {
    std::mt19937 rng(20260815u);
    for (long n = 0; n < 400000; n++)
      probe(rng() & 0xffffff, rng() & 7, (int)(rng() % 3));
  }

  printf("test: ROMA mirrors the boot ROM where MAME says it does\n");
  {
    // The address that actually matters. swa's reset vector at 0xfffff0 is
    // `d6 f3 00 ff 0f 00` -- a jump to 0x000fff00, inside ROMA's second mirror.
    // Under mode 0 the V60 fetched erased space and sat on a reserved opcode at
    // PC 4 forever, which is why the game never booted. This pins the address
    // it must reach: 0x7ff00 into a 512 KB boot ROM packed at word 0x080000.
    d->addr = 0x0fff00; d->rom_bank = 0; d->roma_mode = 1; d->eval();
    checks++;
    if (!d->sel_rom || d->rom_addr != 0x080000 + (0x7ff00 >> 1)) {
      printf("  FAIL swa reset target 0x0fff00: sel_rom=%d rom_addr=%06x want=%06x\n",
             (int)d->sel_rom, (unsigned)d->rom_addr,
             (unsigned)(0x080000 + (0x7ff00 >> 1)));
      fails++;
    }
    // Both halves of ROMA land on the same word under mode 1 -- that IS the
    // pair of ROM_RELOADs, not an aliasing bug.
    d->addr = 0x000100; d->roma_mode = 1; d->eval();
    uint32_t lo = d->rom_addr;
    d->addr = 0x080100; d->roma_mode = 1; d->eval();
    checks++;
    if (d->rom_addr != lo) {
      printf("  FAIL ROMA mode 1: 0x000100 -> %06x but 0x080100 -> %06x\n",
             lo, (unsigned)d->rom_addr);
      fails++;
    }
    // wingwar's mirror starts 256 KB into the packed boot region, which is
    // where its first 128 KB part sits (V60 0xfc0000).
    d->addr = 0x000000; d->roma_mode = 2; d->eval();
    checks++;
    if (!d->sel_rom || d->rom_addr != 0x0A0000) {
      printf("  FAIL ROMA mode 2 base: sel_rom=%d rom_addr=%06x want=0A0000\n",
             (int)d->sel_rom, (unsigned)d->rom_addr);
      fails++;
    }
    // ...and only 256 KB of it. Above that MAME's region is erased again, so a
    // read must NOT run off the end of the boot region into the banked data.
    d->addr = 0x040000; d->roma_mode = 2; d->eval();
    checks++;
    if (!d->sel_rom_void) {
      printf("  FAIL ROMA mode 2 above 256 KB should be void, sel_rom=%d\n",
             (int)d->sel_rom);
      fails++;
    }
  }

  printf("test: banking moves the window by exactly 1 MB\n");
  {
    // MAME: maincpu base + 0x1000000 + 0x100000 * bank. In packed word
    // addresses that is a stride of 0x80000 words, and a bank that is off by a
    // factor of two puts the game's data ROMs somewhere plausible-looking,
    // which is far worse than putting them somewhere obviously wrong.
    for (uint32_t bank = 0; bank < 8; bank++) {
      d->addr = 0x100000; d->rom_bank = bank; d->roma_mode = 0; d->eval();
      uint32_t base = d->rom_addr;
      checks++;
      if (base != 0x0C0000 + bank * 0x80000) {
        printf("  FAIL bank %u base got=%06x want=%06x\n",
               bank, base, 0x0C0000 + bank * 0x80000);
        fails++;
      }
    }
    printf("  8 banks, stride 0x80000 words = 1 MB\n");
  }

  // A region the tests never reach is a region that is not tested, and the
  // decode is the one place where "I thought that was covered" is expensive.
  int uncovered = 0;
  for (int r = NONE; r <= GLUE; r++) {
    if (!seen_regions.count(r)) {
      printf("  NO COVERAGE for region %s\n", SNAME[r]);
      uncovered++;
    }
  }

  printf("m1_decode: checks=%ld fails=%ld uncovered=%d\n",
         checks, fails, uncovered);
  delete d;
  return (fails || uncovered) ? 1 : 0;
}
