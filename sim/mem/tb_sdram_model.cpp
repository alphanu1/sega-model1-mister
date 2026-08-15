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
// Proving the SDRAM protocol checker has teeth.
//
// The model in sdram_model.sv exists to fail a controller that violates JEDEC
// timing. A checker that never fires is worse than no checker, because it
// converts "untested" into "tested and passing" — so this harness does two
// things, and the second is the one that matters:
//
//   1. Runs a legal command stream and requires violations == 0, plus read
//      data equal to what was written. That is the false-positive side: a
//      checker that fires on correct traffic is unusable.
//
//   2. Injects one targeted fault per rule and requires that rule's own bit to
//      be set. Not "something complained" — the specific check. A model whose
//      tRP check is dead but whose tRC check fires would pass a weaker test,
//      and tRP is exactly the rule a controller gets wrong.

#include "Vsdram_model.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <map>
#include <random>
#include <vector>
#include <string>

// Mirrors the localparams in sdram_model.sv so a failure names the rule.
enum {
  V_ACT_OPEN = 0, V_TRCD = 1, V_TRAS = 2, V_TRP = 3, V_TRC = 4, V_TRRD = 5,
  V_NO_ROW = 6, V_TWR = 7, V_REF_OPEN = 8, V_REFRESH = 9, V_MRS_OPEN = 10,
  V_TMRD = 11, V_DQ_FIGHT = 12, V_RD_TRUNC = 13
};
static const char* VNAME[] = {
  "ACT on open bank", "tRCD", "tRAS", "tRP", "tRC", "tRRD", "no open row",
  "tWR", "REF with bank open", "refresh interval", "MRS with bank open",
  "tMRD", "DQ contention", "PRECHARGE truncates read"
};

// Timing, matching the model's parameters. Overridable so the harness can be
// built against a second parameter set — see the tRC note below.
#ifndef TB_T_RC
#define TB_T_RC 7
#endif
static const int T_RCD = 2, T_RP = 2, T_RC = TB_T_RC, T_RAS = 5, T_RRD = 2;
static const int T_WR = 2, T_MRD = 2, CL = 2;

struct Dev {
  Vsdram_model* d;
  long cyc = 0;

  Dev() {
    d = new Vsdram_model;
    d->cke = 1; d->dqm = 0; d->dq_i = 0; d->dq_oe_i = 0;
    d->ba = 0; d->a = 0;
    nopSignals();
    d->clk = 0; d->eval();
  }
  ~Dev() { delete d; }

  void nopSignals() { d->cs_n = 0; d->ras_n = 1; d->cas_n = 1; d->we_n = 1; }

  // One clock. Command inputs must already be set.
  void tick() {
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    cyc++;
    nopSignals();          // default back to NOP so a held command is explicit
  }
  void nop(int n = 1) { for (int i = 0; i < n; i++) tick(); }

  void cmd(int cs, int ras, int cas, int we) {
    d->cs_n = cs; d->ras_n = ras; d->cas_n = cas; d->we_n = we;
  }
  long last_act = -10000;
  void act(int bank, int row)  {
    cmd(0,0,1,1); d->ba = bank; d->a = row; tick(); last_act = cyc;
  }
  // Pads until tRC allows another ACTIVATE. The legal-traffic test must stay
  // legal across both parameter sets, and hand-counted cadences do not.
  void actSafe(int bank, int row) {
    while (cyc - last_act < T_RC) tick();
    act(bank, row);
  }
  void rd (int bank, int col)  { cmd(0,1,0,1); d->ba = bank; d->a = col;  tick(); }
  // A10 set: read with auto-precharge, which is what the controller issues on
  // the final CAS of a burst.
  void rdAp(int bank, int col) { cmd(0,1,0,1); d->ba = bank; d->a = col | (1<<10); tick(); }
  void wr (int bank, int col, uint16_t v, int mask = 0) {
    cmd(0,1,0,0); d->ba = bank; d->a = col;
    d->dq_i = v; d->dq_oe_i = 1; d->dqm = mask; tick();
    d->dq_oe_i = 0; d->dqm = 0;
  }
  void pre(int bank)     { cmd(0,0,1,0); d->ba = bank; d->a = 0;      tick(); }
  void preAll()          { cmd(0,0,1,0); d->a = 1 << 10;              tick(); }
  void ref()             { cmd(0,0,0,1);                              tick(); }
  void mrs(int mode)     { cmd(0,0,0,0); d->ba = 0; d->a = mode;      tick(); }

  // JEDEC init: precharge all, eight refreshes, load mode register.
  void init() {
    nop(8);
    preAll();
    nop(T_RP);
    for (int i = 0; i < 8; i++) { ref(); nop(T_RC - 1); }
    mrs(0x020);            // CL2, sequential, burst 1
    nop(T_MRD);
  }

  uint32_t flags() const { return d->v_flags; }
  uint32_t viol()  const { return d->violations; }
};

static int failures = 0;

static void expect_flag(const char* what, Dev& dv, int code) {
  bool got = (dv.flags() >> code) & 1;
  if (!got) {
    printf("  FAIL %-28s did not set [%d] %s (flags=%04x viol=%u)\n",
           what, code, VNAME[code], dv.flags(), dv.viol());
    failures++;
  }
}

static void expect_clean(const char* what, Dev& dv) {
  if (dv.viol() != 0) {
    printf("  FAIL %-28s expected clean, got %u violations flags=%04x\n",
           what, dv.viol(), dv.flags());
    failures++;
  }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  long checks = 0;

  // ---------------------------------------------------------------- legal
  // A correct controller's command stream. If this trips a check, every fault
  // case below is meaningless, so it runs first.
  printf("test: legal traffic is accepted, and stores what it is told\n");
  {
    Dev dv;
    dv.init();
    std::mt19937 rng(20260815u);
    std::map<uint32_t, uint16_t> shadow;    // bank/row/col -> word
    std::vector<uint32_t> written;
    // Keys already written, so reads can target a location that holds known
    // data. Drawing addresses at random gave 3860 writes against 99 reads —
    // the read data-integrity check is the point of this test and it was
    // running on 2.5% of the traffic.

    // One transaction per 7-cycle slot, which satisfies tRC. Refresh is folded
    // in often enough to stay inside the interval check.
    for (int t = 0; t < 4000; t++) {
      if ((t % 96) == 95) { dv.preAll(); dv.nop(T_RP); dv.ref(); dv.nop(T_RC); continue; }

      bool do_read = !written.empty() && (rng() & 1);
      uint32_t key;
      if (do_read) key = written[rng() % written.size()];
      else         key = ((rng() & 3) << 23) | ((rng() & 0x7f) << 10) | (rng() & 0x3f);
      int bank = (key >> 23) & 3;
      int row  = (key >> 10) & 0x7f;
      int col  = key & 0x3f;

      dv.actSafe(bank, row);
      dv.nop(T_RCD);
      if (!do_read) {
        uint16_t v = (uint16_t)rng();
        dv.wr(bank, col, v);
        if (!shadow.count(key)) written.push_back(key);
        shadow[key] = v;
        dv.nop(T_WR > T_RAS - T_RCD - 1 ? T_WR : T_RAS - T_RCD - 1);
      } else {
        dv.rd(bank, col);
        // Data lands CL cycles after the READ edge.
        dv.nop(CL);
        uint16_t got = (uint16_t)dv.d->dq_o;
        checks++;
        if (!dv.d->dq_oe_o) {
          printf("  FAIL read did not drive DQ at CL=%d\n", CL);
          failures++;
        } else if (got != shadow[key]) {
          printf("  FAIL read b%d r%d c%d got=%04x want=%04x\n",
                 bank, row, col, got, shadow[key]);
          failures++;
        }
        dv.nop(T_RAS);
      }
      dv.pre(bank);
      dv.nop(T_RP);
    }
    expect_clean("legal traffic", dv);
    checks++;
    printf("  legal: %ld cycles, %u reads, %u writes, %u violations\n",
           dv.cyc, dv.d->reads_served, dv.d->writes_served, dv.viol());
  }

  // ------------------------------------------------------------ byte masking
  // DQM suppresses a byte lane. The ROM loader depends on this for odd-width
  // regions, so a model that ignores DQM would hide a real loader bug.
  printf("test: DQM masks the byte lane it names\n");
  {
    Dev dv; dv.init();
    dv.act(0, 5); dv.nop(T_RCD);
    dv.wr(0, 9, 0xbeef);        dv.nop(T_WR);
    dv.wr(0, 9, 0x1234, 0b01);  // suppress low byte -> expect 0x12ef
    dv.nop(T_WR);
    dv.rd(0, 9); dv.nop(CL);
    checks++;
    if (dv.d->dq_o != 0x12ef) {
      printf("  FAIL DQM: got=%04x want=12ef\n", (unsigned)dv.d->dq_o);
      failures++;
    }
    dv.nop(T_RAS); dv.pre(0); dv.nop(T_RP);
    expect_clean("DQM traffic", dv);
    checks++;
  }

  // ------------------------------------------------------- auto-precharge
  // The device delays an auto-precharge internally until tRAS is met, so
  // issuing one early is legal. What it must still enforce is tRP for the
  // next ACTIVATE, measured from the effective precharge — not from the CAS.
  printf("test: auto-precharge closes the row and still enforces tRP\n");
  {
    Dev dv; dv.init();
    dv.act(0, 3); dv.nop(T_RCD); dv.wr(0, 4, 0xcafe); dv.nop(T_WR);
    dv.rdAp(0, 4);
    dv.nop(CL);
    checks++;
    if (dv.d->dq_o != 0xcafe) {
      printf("  FAIL auto-precharge read got=%04x want=cafe\n", (unsigned)dv.d->dq_o);
      failures++;
    }
    // Effective precharge is at tRAS after the ACTIVATE here, so wait past it
    // and then tRP before re-activating the same bank.
    dv.nop(T_RAS + T_RP + T_RC);
    dv.act(0, 9); dv.nop(T_RCD); dv.rd(0, 4); dv.nop(CL + T_RAS);
    dv.pre(0); dv.nop(T_RP);
    expect_clean("legal auto-precharge", dv); checks++;
  }
  {
    // Same shape, but re-activating immediately. tRP is measured from the
    // delayed precharge point, so this must fail even though the CAS itself
    // was many cycles ago.
    Dev dv; dv.init();
    dv.act(0, 3); dv.nop(T_RCD); dv.rdAp(0, 4); dv.act(0, 9);
    expect_flag("tRP after auto-precharge", dv, V_TRP); checks++;
  }

  // ------------------------------------------------------------ fault cases
  // One per rule. Each starts from a clean initialised device so the flag that
  // fires can only have come from the fault injected here.
  printf("test: every rule fires on its own violation\n");

  { Dev dv; dv.init(); dv.act(0,1); dv.nop(T_RC); dv.act(0,2);
    expect_flag("ACT on open bank", dv, V_ACT_OPEN); checks++; }

  { Dev dv; dv.init(); dv.act(0,1); dv.nop(T_RCD-2); dv.rd(0,0);
    expect_flag("tRCD", dv, V_TRCD); checks++; }

  { Dev dv; dv.init(); dv.act(0,1); dv.nop(T_RCD); dv.pre(0);
    expect_flag("tRAS", dv, V_TRAS); checks++; }

  { Dev dv; dv.init(); dv.act(0,1); dv.nop(T_RAS); dv.pre(0); dv.act(0,2);
    expect_flag("tRP", dv, V_TRP); checks++; }

  // tRC is ACT-to-ACT on the same bank, with a legal precharge in between so
  // the only rule left to break is tRC itself. Spacing is the exact legal
  // minimum: PRE at tRAS after ACT, next ACT at tRP after PRE.
  //
  // At the default timings that minimum is tRAS + tRP = 7, which equals tRC.
  // So on a part where tRC == tRAS + tRP the check CANNOT fire — it is implied
  // by the other two, and a test asserting it would be asserting something
  // unreachable. It becomes live only where tRC exceeds that sum, which is why
  // this harness is built a second time with T_RC=12.
  { Dev dv; dv.init(); dv.act(0,1); dv.nop(T_RAS-1); dv.pre(0); dv.nop(T_RP-1);
    dv.act(0,2);
    if (T_RC > T_RAS + T_RP) { expect_flag("tRC", dv, V_TRC); checks++; }
    else printf("  tRC unreachable at tRC=%d <= tRAS+tRP=%d, checked in the "
                "T_RC=12 build\n", T_RC, T_RAS + T_RP);
  }

  { Dev dv; dv.init(); dv.act(0,1); dv.act(1,1);
    expect_flag("tRRD", dv, V_TRRD); checks++; }

  { Dev dv; dv.init(); dv.rd(2,4);
    expect_flag("access with no open row", dv, V_NO_ROW); checks++; }

  // The write has to land immediately before the precharge. Waiting tRAS
  // after it — which the first version of this test did — satisfies tWR too,
  // and the case silently tested nothing.
  { Dev dv; dv.init(); dv.act(0,1); dv.nop(T_RAS-1); dv.wr(0,3,0x1111);
    dv.pre(0);
    expect_flag("tWR", dv, V_TWR); checks++; }

  { Dev dv; dv.init(); dv.act(0,1); dv.nop(T_RCD); dv.ref();
    expect_flag("REF with bank open", dv, V_REF_OPEN); checks++; }

  { Dev dv; dv.init(); dv.nop(781 * 9 + 16);
    expect_flag("refresh interval", dv, V_REFRESH); checks++; }

  { Dev dv; dv.init(); dv.act(0,1); dv.nop(T_RCD); dv.mrs(0x020);
    expect_flag("MRS with bank open", dv, V_MRS_OPEN); checks++; }

  { Dev dv; dv.nop(8); dv.preAll(); dv.nop(T_RP);
    for (int i = 0; i < 8; i++) { dv.ref(); dv.nop(T_RC - 1); }
    dv.mrs(0x020); dv.act(0,1);          // no tMRD wait
    expect_flag("tMRD", dv, V_TMRD); checks++; }

  { Dev dv; dv.init();
    dv.act(0,1); dv.nop(T_RCD); dv.wr(0,7,0x2222); dv.nop(T_WR);
    dv.rd(0,7);
    // Drive DQ from the controller side during the cycle the device is
    // actually driving it, which is CL edges after the READ.
    dv.nop(CL);
    dv.d->dq_oe_i = 1; dv.tick(); dv.tick(); dv.d->dq_oe_i = 0;
    expect_flag("DQ contention", dv, V_DQ_FIGHT); checks++; }

  // PRECHARGE issued before the read data has been delivered truncates the
  // burst. The controller must hold off precharging a bank while its own read
  // is still returning, and nothing checked that until now.
  { Dev dv; dv.init(); dv.act(0,1); dv.nop(T_RAS-1); dv.rd(0,2); dv.pre(0);
    expect_flag("PRECHARGE truncates read", dv, V_RD_TRUNC); checks++; }

  printf("sdram_model[trc=%d]: checks=%ld fails=%d\n", T_RC, checks, failures);
  return failures ? 1 : 0;
}
