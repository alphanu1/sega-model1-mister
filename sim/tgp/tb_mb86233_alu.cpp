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
// mb86233_alu fuzz harness.
//
// The reference is written to mirror MAME's alu_pre / alu_post_1 / alu_post_2
// structure directly rather than to restate the semantics in another form:
// same switch, same case order, same helper names. When this disagrees with
// the DUT the first question is which of the two drifted from mb86233.cpp, and
// that is much easier to answer if the reference reads like the source.
//
//   third_party/mame/src/devices/cpu/mb86233/mb86233.cpp
//   BSD-3-Clause, copyright-holders: Olivier Galibert
//
// Skips, every one deliberate and explained at its skip site:
//   - fdvd (0x10): NOT DRIVEN. It is variable-latency: the ALU holds `busy` for
//     the ~29 cycles the divider runs and cannot accept work meanwhile. This
//     harness issues one op per cycle and has no way to honour that, so driving
//     fdvd corrupts the ops pipelined around it — 40000 failures, none of them
//     in fdvd itself. Covered by tb_fp_div and by the core harness, which does
//     respect busy.
//   - denormal operands and denormal results: the RTL flushes, the host does
//     not (same open question as fp_add/fp_mul)
//   - cfxd out-of-range and non-finite inputs: s32(float) is UB in C++
//   - SFT above 31: m_d >> m_sft is UB in C++ above 31

#include "Vmb86233_alu.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static bool is_denorm(uint32_t u) {
  return ((u >> 23) & 0xff) == 0 && (u & 0x7fffff) != 0;
}
static bool is_finite_u(uint32_t u) { return ((u >> 23) & 0xff) != 0xff; }
static bool is_nan_u(uint32_t u) {
  return ((u >> 23) & 0xff) == 0xff && (u & 0x7fffff) != 0;
}

// Flag bits, from mb86233.h.
enum {
  F_ZRD = 0x00000002, F_SGD = 0x00000008, F_CPD = 0x00000020,
  F_OVD = 0x00000080, F_DVZD = 0x00000800,
};
static const uint32_t ST_MASK = F_ZRD | F_SGD | F_CPD | F_OVD | F_DVZD;

// ------------------------------------------------------------------ opcodes
enum {
  ANDD=0x01, ORAD=0x02, EORD=0x03, NOTD=0x04, FCPD=0x05, FADD=0x06,
  FSBD=0x07, FML=0x08,  FMSD=0x09, FMRD=0x0a, FABD=0x0b, FSMD=0x0c,
  FSPD=0x0d, CXFD=0x0e, CFXD=0x0f, FDVD=0x10, FNED=0x11,
  BAPA=0x13, BSPA=0x14,
  LSRD=0x16, LSLD=0x17, ASRD=0x18, ASLD=0x19, ADDD=0x1a, SUBD=0x1b,
};

static bool is_int_d(uint32_t op) {
  switch (op) {
    case ANDD: case ORAD: case EORD: case NOTD: case CXFD: case CFXD:
    case LSRD: case LSLD: case ASRD: case ASLD: case ADDD: case SUBD:
      return true;
    default: return false;
  }
}
static bool is_fp_d(uint32_t op) {
  switch (op) {
    case FADD: case FSBD: case FABD: case FSMD:
    case FMSD: case FMRD: case FSPD:
    case FDVD: case FNED: case BAPA: case BSPA:
      return true;
    default: return false;
  }
}
static bool writes_p(uint32_t op) {
  return op == FML || op == FMSD || op == FMRD || op == FSPD;
}
static bool touches_st(uint32_t op) {
  return is_int_d(op) || is_fp_d(op) || op == FCPD;
}

// --------------------------------------------------------------- reference
struct Regs { uint32_t a, b, d, p, st; uint8_t sft; uint16_t m; };
struct Ref  { uint32_t d_out, p_out, st_out; bool d_we, p_we; };

// MAME stset_set_sz_int / stset_set_sz_fp.
static uint32_t sz_int(uint32_t v) {
  return v ? ((v & 0x80000000u) ? F_SGD : 0) : F_ZRD;
}
static uint32_t sz_fp(uint32_t v) {
  return (v & 0x7fffffffu) ? ((v & 0x80000000u) ? F_SGD : 0) : F_ZRD;
}

// Mirrors alu_pre. Returns false if the op does not decode.
static bool alu_pre(uint32_t op, const Regs& r,
                    uint32_t* r1, uint32_t* r2, uint32_t* stset) {
  *r1 = 0; *r2 = 0; *stset = 0;
  switch (op) {
    case ANDD: *r1 = r.d & r.a;              *stset = sz_int(*r1); return true;
    case ORAD: *r1 = r.d | r.a;              *stset = sz_int(*r1); return true;
    case EORD: *r1 = r.d ^ r.a;              *stset = sz_int(*r1); return true;
    case NOTD: *r1 = ~r.d;                   *stset = sz_int(*r1); return true;
    case FCPD: {
      uint32_t t = f2u(u2f(r.d) - u2f(r.a)); *stset = sz_fp(t);    return true;
    }
    case FADD: *r1 = f2u(u2f(r.d) + u2f(r.a)); *stset = sz_fp(*r1); return true;
    case FSBD: *r1 = f2u(u2f(r.d) - u2f(r.a)); *stset = sz_fp(*r1); return true;
    case FML:  *r1 = f2u(u2f(r.a) * u2f(r.b)); *stset = 0;          return true;
    case FMSD:
      *r1 = f2u(u2f(r.d) + u2f(r.p));
      *r2 = f2u(u2f(r.a) * u2f(r.b));        *stset = sz_fp(*r1);  return true;
    case FMRD:
      *r1 = f2u(u2f(r.d) - u2f(r.p));
      *r2 = f2u(u2f(r.a) * u2f(r.b));        *stset = sz_fp(*r1);  return true;
    case FABD: *r1 = r.d & 0x7fffffffu;      *stset = sz_fp(*r1);  return true;
    case FSMD: *r1 = f2u(u2f(r.d) + u2f(r.p)); *stset = sz_fp(*r1); return true;
    case FSPD:
      *r1 = r.p;
      *r2 = f2u(u2f(r.a) * u2f(r.b));        *stset = sz_fp(*r1);  return true;
    case CXFD:
      // Note: int-style flags on a float result. MAME does this; see the
      // note in mb86233_pkg.sv alu_flags_int.
      *r1 = f2u((float)(int32_t)r.d);        *stset = sz_int(*r1); return true;
    case CFXD: {
      float f = u2f(r.d);
      switch ((r.m >> 1) & 3) {
        case 0: *r1 = (uint32_t)(int32_t)roundf(f); break;
        case 1: *r1 = (uint32_t)(int32_t)ceilf(f);  break;
        case 2: *r1 = (uint32_t)(int32_t)floorf(f); break;
        case 3: *r1 = (uint32_t)(int32_t)f;         break;
      }
      *stset = sz_int(*r1);
      return true;
    }
    case FNED: *r1 = r.d ? (r.d ^ 0x80000000u) : 0; *stset = sz_fp(*r1); return true;
    case BAPA: *r1 = f2u(u2f(r.b) + u2f(r.a)); *stset = sz_fp(*r1); return true;
    case BSPA: *r1 = f2u(u2f(r.b) - u2f(r.a)); *stset = sz_fp(*r1); return true;
    case LSRD: *r1 = r.d >> (r.sft & 31);    *stset = sz_int(*r1); return true;
    case LSLD: *r1 = r.d << (r.sft & 31);    *stset = sz_int(*r1); return true;
    case ASRD: *r1 = (uint32_t)((int32_t)r.d >> (r.sft & 31));
                                             *stset = sz_int(*r1); return true;
    case ASLD: *r1 = r.d << (r.sft & 31);    *stset = sz_int(*r1); return true;
    case ADDD: *r1 = r.d + r.a;              *stset = sz_int(*r1); return true;
    case SUBD: *r1 = r.d - r.a;              *stset = sz_int(*r1); return true;
    default: return false;   // alu_pre's default: logs, changes nothing
  }
}

// Mirrors alu_post_1 / alu_post_2 plus the write-priority arbitration.
static Ref model(uint32_t op, const Regs& r, bool xv, uint32_t xd) {
  uint32_t r1, r2, stset;
  bool decoded = alu_pre(op, r, &r1, &r2, &stset);

  Ref out;
  out.st_out = (decoded && touches_st(op))
             ? ((r.st & ~ST_MASK) | stset)
             : r.st;

  out.p_we  = writes_p(op);
  out.p_out = (op == FML) ? r1 : r2;   // fml puts the product in r1, not r2

  // transfers beat integer ops, FP ops beat transfers
  if (is_fp_d(op)) {
    out.d_we = true; out.d_out = r1;
  } else if (xv) {
    out.d_we = true; out.d_out = xd;
  } else {
    out.d_we = is_int_d(op); out.d_out = r1;
  }
  return out;
}

// --------------------------------------------------------------- harness
int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vmb86233_alu;

  auto tick = [&]() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
  };

  // This harness models the lab / ld/mov context, where MAME does reach
  // alu_post_2. The 0x0f group, which does not, is exercised by the core
  // harness in sequence — it cannot be expressed here, because this drives the
  // ALU directly with no instruction type around it.
  dut->fp_post_en = 1;
  dut->rst_n = 0; dut->in_valid = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1;

  std::mt19937 rng(20260814u);
  std::uniform_int_distribution<uint32_t> dist(0, 0xffffffffu);

  static const uint32_t OPS[] = {
    ANDD, ORAD, EORD, NOTD, FCPD, FADD, FSBD, FML, FMSD, FMRD, FABD,
    FSMD, FSPD, CXFD, CFXD, FNED, BAPA, BSPA, LSRD, LSLD, ASRD, ASLD,
    ADDD, SUBD,
    0x00, 0x12, 0x15, 0x1c,   // undecoded: must leave D and ST alone
  };
  const int NOPS = sizeof(OPS) / sizeof(OPS[0]);

  const uint32_t seeds[] = {
    0x00000000, 0x80000000, 0x3f800000, 0xbf800000,
    0x7f800000, 0xff800000, 0x7fc00000, 0x00800000,
    0x007fffff, 0x7f7fffff, 0xff7fffff, 0x40000000,
    0x3eaaaaab, 0x3f000000, 0xbf000000, 0x4b000000,
    0x00000001, 0xffffffff, 0x7fffffff, 0x0000002a,
  };
  const int NS = sizeof(seeds) / sizeof(seeds[0]);

  struct Pend { uint32_t op; Regs r; bool xv; uint32_t xd; bool live; };
  // Depth follows the ALU's uniform latency, now 5: the FP units are 4 and the operand mux adds one. It was 4 after fp_add and fp_mul were
  // retimed for the Fmax gate. This is the fifth time a latency change has had
  // to be mirrored here; a stale depth produces a 100% failure rate that looks
  // exactly like broken hardware.
  Pend pipe[6] = {};

  const int PER_OP = 80000;
  const int N = NOPS * PER_OP;
  long checked = 0, skipped = 0, fails = 0;
  long per_op_checked[32] = {0};

  for (int i = 0; i < N + 4; i++) {
    uint32_t op = OPS[i % NOPS];
    Regs r;
    int k = i / NOPS;
    if (k < NS * NS) {                     // seeded cross-product first
      r.a = seeds[k / NS]; r.b = seeds[k % NS];
      r.d = seeds[(k / NS + 1) % NS]; r.p = seeds[(k % NS + 3) % NS];
    } else {
      r.a = dist(rng); r.b = dist(rng); r.d = dist(rng); r.p = dist(rng);
    }
    r.st  = dist(rng);
    // SFT constrained to 0-31: above that MAME's `m_d >> m_sft` is UB.
    r.sft = (uint8_t)(dist(rng) & 31);
    r.m   = (uint16_t)(dist(rng) & 7);
    bool     xv = (dist(rng) & 3) == 0;    // transfer present ~25% of the time
    uint32_t xd = dist(rng);

    bool feed = (i < N);
    dut->in_valid    = feed;
    dut->op          = op;
    dut->reg_a       = r.a;
    dut->reg_b       = r.b;
    dut->reg_d       = r.d;
    dut->reg_p       = r.p;
    dut->sft         = r.sft;
    dut->m           = r.m;
    dut->st_in       = r.st;
    dut->xfer_d_valid = xv;
    dut->xfer_d_data  = xd;

    for (int s = 5; s > 0; s--) pipe[s] = pipe[s - 1];
    pipe[0] = { op, r, xv, xd, feed };

    tick();

    // Latency 2. After the shift and this tick, pipe[0] holds the operands
    // just applied and pipe[1] holds the pair whose result out_valid is
    // presenting now. Indexing pipe[2] here instead produces a 100% failure
    // rate that reads exactly like a broken DUT — see docs/rtl-conventions.md.
    if (!dut->out_valid || !pipe[4].live) continue;

    const Pend& q = pipe[4];
    Ref ref = model(q.op, q.r, q.xv, q.xd);

    // fcpd writes no register, so ref.d_out holds whatever the arbitration
    // picked (the transfer data, when one is present) rather than the FP
    // difference its flags are derived from. Every result-shaped exclusion
    // below has to test this value instead for that op.
    const uint32_t fcpd_val =
        (q.op == FCPD) ? f2u(u2f(q.r.d) - u2f(q.r.a)) : 0u;

    // ---------------------------------------------------------- skips
    bool skip = false;

    // fdvd is NOT driven by this harness at all — see the OPS list.

    // Denormal operands and denormal results: the RTL flushes, the host does
    // not. Same open question as fp_add/fp_mul, tracked in the M0 doc.
    if (is_fp_d(q.op) || q.op == FCPD || q.op == FML) {
      if (is_denorm(q.r.a) || is_denorm(q.r.b) ||
          is_denorm(q.r.d) || is_denorm(q.r.p)) skip = true;
      if (is_denorm(ref.d_out) || (ref.p_we && is_denorm(ref.p_out))) skip = true;
      // Two tiny normals can subtract to a denormal: the host keeps it, the
      // RTL flushes to zero and sets ZRD where the host does not.
      if (q.op == FCPD && is_denorm(fcpd_val)) skip = true;
    }
    // cxfd rounds an integer into a float; its result is always normal, but a
    // denormal D operand still means the *integer* read of D is fine. No skip.

    // NaN payload. The FP units emit a canonical quiet NaN, the host
    // propagates the operand's payload, so any NaN coming out of fp_add or
    // fp_mul differs in the low bits. fp_add and fp_mul were themselves
    // verified with exactly this exclusion (tb_fp_add skips isnan results).
    //
    // Scoped to values that actually pass through an FP unit. fabd, fned and
    // fspd's D path are bitwise and DO reproduce the payload exactly, so they
    // stay in scope and are compared.
    switch (q.op) {
      // fcpd writes no register, but its flags come from the FP difference, and
      // a canonical NaN has a clear sign bit where a propagated one may not.
      case FCPD:
        if (is_nan_u(fcpd_val)) skip = true;
        break;
      case FADD: case FSBD: case FMSD: case FMRD:
      case FSMD: case BAPA: case BSPA:
        if (is_nan_u(ref.d_out)) skip = true;
        break;
      default: break;
    }
    if (writes_p(q.op) && is_nan_u(ref.p_out)) skip = true;

    // cfxd: s32(float) is UB unless the rounded value fits int32, and roundf /
    // ceilf / floorf of inf or NaN then converted is UB too.
    if (q.op == CFXD) {
      float f = u2f(q.r.d);
      if (!is_finite_u(q.r.d) || is_denorm(q.r.d)) skip = true;
      else {
        float g;
        switch ((q.r.m >> 1) & 3) {
          case 0: g = roundf(f); break;
          case 1: g = ceilf(f);  break;
          case 2: g = floorf(f); break;
          default: g = truncf(f); break;
        }
        if (!(g >= -2147483648.0f && g <= 2147483520.0f)) skip = true;
      }
    }

    if (skip) { skipped++; continue; }

    // -------------------------------------------------------- compare
    checked++;
    per_op_checked[q.op & 31]++;

    bool bad = false;
    if ((bool)dut->d_we != ref.d_we) bad = true;
    if (ref.d_we && dut->d_out != ref.d_out) bad = true;
    if ((bool)dut->p_we != ref.p_we) bad = true;
    if (ref.p_we && dut->p_out != ref.p_out) bad = true;
    if (dut->st_out != ref.st_out) bad = true;

    if (bad) {
      if (fails < 20) {
        printf("MISMATCH op=%02x a=%08x b=%08x d=%08x p=%08x sft=%u m=%u "
               "xv=%d xd=%08x\n", q.op, q.r.a, q.r.b, q.r.d, q.r.p,
               q.r.sft, q.r.m, q.xv, q.xd);
        printf("    d: ref we=%d %08x (%g)   got we=%d %08x (%g)\n",
               ref.d_we, ref.d_out, u2f(ref.d_out),
               (int)dut->d_we, dut->d_out, u2f(dut->d_out));
        printf("    p: ref we=%d %08x (%g)   got we=%d %08x (%g)\n",
               ref.p_we, ref.p_out, u2f(ref.p_out),
               (int)dut->p_we, dut->p_out, u2f(dut->p_out));
        printf("    st: ref=%08x got=%08x  (in=%08x)\n",
               ref.st_out, dut->st_out, q.r.st);
      }
      fails++;
    }
  }

  // Per-op coverage, so a silently-untested opcode cannot hide behind a big
  // aggregate pass count.
  int uncovered = 0;
  for (int i = 0; i < NOPS; i++) {
    uint32_t op = OPS[i];
    if (op == FDVD) continue;
    if (per_op_checked[op & 31] == 0) {
      printf("NO COVERAGE for op %02x\n", op);
      uncovered++;
    }
  }

  printf("mb86233_alu: checked=%ld skipped=%ld fails=%ld uncovered_ops=%d\n",
         checked, skipped, fails, uncovered);
  delete dut;
  return (fails || uncovered) ? 1 : 0;
}
