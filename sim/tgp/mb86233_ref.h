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
// Behaviour transcribed from MAME's MB86233 device model:
//
//   src/devices/cpu/mb86233/mb86233.cpp
//   SPDX-License-Identifier: BSD-3-Clause
//   Copyright-holders: Olivier Galibert
//
// That BSD-3-Clause attribution must be retained. See THIRD-PARTY.md.
//
// MB86233 reference model — a whole-CPU execute_run, for lockstep.
//
// This is the oracle M0 exit criterion 2 compares against. Every piece of it is
// already proven: alu_pre came from tb_mb86233_alu, ea_pre/ea_post from
// tb_mb86233_agu, read_reg/write_reg from tb_mb86233_regs, and the sequencer
// step from tb_mb86233_seq — each verified in volume against its own DUT before
// being assembled here. What is NEW is only the dispatch and the ordering
// between them, which is exactly the surface the core FSM has to get right.
//
// Structured to mirror execute_run's switch, case for case, so a divergence
// points at one transcription rather than at "the model".

#pragma once
#include <cstdint>
#include <cstring>
#include <cmath>
#include <vector>

namespace mb {

static inline uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static inline int32_t  sext(uint32_t v, int bits) {
  uint32_t m = 1u << (bits - 1);
  return (int32_t)((v & ((1u << bits) - 1)) ^ m) - (int32_t)m;
}

enum {
  F_ZRC = 1u<<0,  F_ZRD = 1u<<1,  F_SGC = 1u<<2,  F_SGD = 1u<<3,
  F_CPD = 1u<<5,  F_OVD = 1u<<7,  F_DVZD = 1u<<11,
  F_ZX0 = 1u<<27, F_ZX1 = 1u<<28, F_ZX2 = 1u<<29,
  F_ZC0 = 1u<<30, F_ZC1 = 1u<<31,
};
static const uint32_t ST_MASK = F_ZRD | F_SGD | F_CPD | F_OVD | F_DVZD;

struct Cpu {
  // Architectural state, widths exactly as MAME declares them.
  uint32_t a=0, b=0, d=0, p=0, st=0;
  uint16_t pc=0, ppc=0, sp=0, b0=0, b1=0, x0=0, x1=0, i0=0, i1=0;
  uint16_t vsmr=7, mask=0, m=0, pcs[4]={0,0,0,0};
  uint8_t  r=1, rpc=1, c0=1, c1=1, sft=0, vsm=0;
  uint32_t rf[16]={0};
  bool     gpio0=false, gpio1=false, gpio2=false, gpio3=false;

  std::vector<uint32_t> prog;   // 2048 words
  std::vector<uint32_t> ram0;   // 0x000-0x0ff
  std::vector<uint32_t> ram1;   // 0x200-0x3ff

  // Board side. Supplied by the harness; the CPU has no opinion about them.
  uint32_t (*io_read)(uint32_t addr) = nullptr;
  void     (*io_write)(uint32_t addr, uint32_t v) = nullptr;
  uint32_t (*fifo_read)() = nullptr;
  void     (*fifo_write)(uint32_t v) = nullptr;

  bool unimplemented = false;   // sticky: hit a case MAME only logs

  // Write trace. Recorded at the call, NOT inferred by diffing the RAM after
  // the fact: a store of a value already present changes nothing, so array
  // diffing silently misses it and makes the DUT look like it wrote alone.
  struct Wr { uint32_t addr, data; };
  std::vector<Wr> writes;
  std::vector<Wr> reads;      // same treatment for loads

  Cpu() : prog(2048,0), ram0(256,0), ram1(512,0) {
    st = F_ZRC|F_ZRD|F_ZX0|F_ZX1|F_ZX2|F_ZC0|F_ZC1;
  }

  // ------------------------------------------------------ field accessors
  static uint32_t set_exp (uint32_t v,uint32_t e){return (v&0x807fffffu)|((e&0xffu)<<23);}
  static uint32_t set_mant(uint32_t v,uint32_t x){
    return (uint32_t)((v&0x07f800000ull)|((x&0x00800000u)<<8)|(x&0x007fffffu));
  }
  static uint32_t get_exp (uint32_t v){return (v>>23)&0xff;}
  static uint32_t get_mant(uint32_t v){
    return (v&0x80000000u)?(v|0x7f800000u):(v&0x807fffffu);
  }

  // ------------------------------------------------------------ registers
  uint32_t read_reg(uint32_t rr) {
    rr &= 0x3f;
    if (rr >= 0x20 && rr < 0x30) return rf[rr & 0x0f];
    switch (rr) {
      case 0x00: return b0;  case 0x01: return b1;
      case 0x02: return x0;  case 0x03: return x1;
      case 0x0c: return c0;  case 0x0d: return c1;
      case 0x10: return a;   case 0x11: return get_exp(a);
      case 0x12: return get_mant(a);
      case 0x13: return b;   case 0x14: return get_exp(b);
      case 0x15: return get_mant(b);
      case 0x19: return d;   case 0x1a: return get_exp(d);
      case 0x1b: return get_mant(d);
      case 0x1c: return p;   case 0x1d: return get_exp(p);
      case 0x1e: return get_mant(p);
      case 0x1f: return sft; case 0x34: return rpc;
      default: unimplemented = true; return 0;
    }
  }
  void write_reg(uint32_t rr, uint32_t v) {
    rr &= 0x3f;
    if (rr >= 0x20 && rr < 0x30) { rf[rr & 0x0f] = v; return; }
    switch (rr) {
      case 0x00: b0=(uint16_t)v; break;  case 0x01: b1=(uint16_t)v; break;
      case 0x02: x0=(uint16_t)v; break;  case 0x03: x1=(uint16_t)v; break;
      case 0x05: i0=(uint16_t)v; break;  case 0x06: i1=(uint16_t)v; break;
      case 0x08: sp=(uint16_t)v; break;
      case 0x0a: vsm=v&7; vsmr=(uint16_t)((8u<<vsm)-1u); break;
      case 0x0c: c0=(uint8_t)v; if(c0==1) st|=F_ZC0; else st&=~F_ZC0; break;
      case 0x0d: c1=(uint8_t)v; if(c1==1) st|=F_ZC1; else st&=~F_ZC1; break;
      case 0x0f: break;
      case 0x10: a=v; break; case 0x11: a=set_exp(a,v); break;
      case 0x12: a=set_mant(a,v); break;
      case 0x13: b=v; break; case 0x14: b=set_exp(b,v); break;
      case 0x15: b=set_mant(b,v); break;
      case 0x19: d=v; break; case 0x1a: d=set_exp(d,v); break;
      case 0x1b: d=set_mant(d,v); break;
      case 0x1c: p=v; break; case 0x1d: p=set_exp(p,v); break;
      case 0x1e: p=set_mant(p,v); break;
      case 0x1f: sft=(uint8_t)v; break;
      case 0x34: rpc=(uint8_t)v; break;
      case 0x3c: mask=(uint16_t)v; break;
      default: unimplemented = true; break;
    }
  }

  // ------------------------------------------------------------------ EA
  uint16_t ea_pre(uint32_t rr, bool bank) {
    uint16_t B = bank ? b1 : b0, X = bank ? x1 : x0;
    switch (rr & 0x180) {
      case 0x000: return (uint16_t)(rr & 0x7f);
      case 0x080: case 0x100: return (uint16_t)((rr & 0x7f) + B + X);
      case 0x180:
        switch (rr & 0x60) {
          case 0x00: return (uint16_t)(B + X);
          case 0x20: return (uint16_t)(X);
          case 0x40: return (uint16_t)(B + (X & vsmr));
          case 0x60: return (uint16_t)(X & vsmr);
        }
    }
    return 0;
  }
  void ea_post(uint32_t rr, bool bank) {
    if (!(rr & 0x100)) return;
    uint16_t& X = bank ? x1 : x0;
    uint16_t  I = bank ? i1 : i0;
    if (!(rr & 0x080)) X = (uint16_t)(X + I);
    else               X = (uint16_t)(X + sext(rr, 5));
  }

  // -------------------------------------------------------- data memory
  uint32_t data_read(uint32_t ea) {
    uint32_t v = data_read_raw(ea);
    reads.push_back({ea, v});
    return v;
  }
  uint32_t data_read_raw(uint32_t ea) {
    if (ea <= 0x0ff) return ram0[ea];
    if (ea == 0x100) return fifo_read ? fifo_read() : 0;
    if (ea >= 0x200 && ea <= 0x3ff) return ram1[ea - 0x200];
    return 0;
  }
  void data_write(uint32_t ea, uint32_t v) {
    writes.push_back({ea, v});
    if (ea <= 0x0ff) { ram0[ea] = v; return; }
    if (ea >= 0x200 && ea <= 0x3ff) { ram1[ea - 0x200] = v; return; }
    if (ea == 0x400 && fifo_write) fifo_write(v);
  }

  // ------------------------------------------------------------- the ALU
  uint32_t alu_r1=0, alu_r2=0, alu_stmask=0, alu_stset=0;

  void sz_int(uint32_t v){ alu_stset = v ? ((v&0x80000000u)?F_SGD:0) : F_ZRD; }
  void sz_fp (uint32_t v){ alu_stset = (v&0x7fffffffu)?((v&0x80000000u)?F_SGD:0):F_ZRD; }

  void alu_pre(uint32_t op) {
    alu_stmask = ST_MASK; alu_r1 = 0; alu_r2 = 0; alu_stset = 0;
    switch (op) {
      case 0x00: alu_stmask = 0; break;
      case 0x01: alu_r1 = d & a; sz_int(alu_r1); break;
      case 0x02: alu_r1 = d | a; sz_int(alu_r1); break;
      case 0x03: alu_r1 = d ^ a; sz_int(alu_r1); break;
      case 0x04: alu_r1 = ~d;    sz_int(alu_r1); break;
      case 0x05: { uint32_t t = f2u(u2f(d) - u2f(a)); sz_fp(t); break; }
      case 0x06: alu_r1 = f2u(u2f(d) + u2f(a)); sz_fp(alu_r1); break;
      case 0x07: alu_r1 = f2u(u2f(d) - u2f(a)); sz_fp(alu_r1); break;
      case 0x08: alu_stmask = 0; alu_r1 = f2u(u2f(a)*u2f(b)); alu_stset = 0; break;
      case 0x09: alu_r1 = f2u(u2f(d)+u2f(p)); alu_r2 = f2u(u2f(a)*u2f(b)); sz_fp(alu_r1); break;
      case 0x0a: alu_r1 = f2u(u2f(d)-u2f(p)); alu_r2 = f2u(u2f(a)*u2f(b)); sz_fp(alu_r1); break;
      case 0x0b: alu_r1 = d & 0x7fffffffu; sz_fp(alu_r1); break;
      case 0x0c: alu_r1 = f2u(u2f(d)+u2f(p)); sz_fp(alu_r1); break;
      case 0x0d: alu_r1 = p; alu_r2 = f2u(u2f(a)*u2f(b)); sz_fp(alu_r1); break;
      case 0x0e: alu_r1 = f2u((float)(int32_t)d); sz_int(alu_r1); break;
      case 0x0f: {
        float f = u2f(d);
        switch ((m >> 1) & 3) {
          case 0: alu_r1 = (uint32_t)(int32_t)roundf(f); break;
          case 1: alu_r1 = (uint32_t)(int32_t)ceilf(f);  break;
          case 2: alu_r1 = (uint32_t)(int32_t)floorf(f); break;
          case 3: alu_r1 = (uint32_t)(int32_t)f;         break;
        }
        sz_int(alu_r1); break;
      }
      case 0x10: alu_r1 = f2u(u2f(d)/u2f(a)); sz_fp(alu_r1); break;
      case 0x11: alu_r1 = d ? (d ^ 0x80000000u) : 0; sz_fp(alu_r1); break;
      case 0x13: alu_r1 = f2u(u2f(b)+u2f(a)); sz_fp(alu_r1); break;
      case 0x14: alu_r1 = f2u(u2f(b)-u2f(a)); sz_fp(alu_r1); break;
      case 0x16: alu_r1 = d >> (sft & 31); sz_int(alu_r1); break;
      case 0x17: alu_r1 = d << (sft & 31); sz_int(alu_r1); break;
      case 0x18: alu_r1 = (uint32_t)((int32_t)d >> (sft & 31)); sz_int(alu_r1); break;
      case 0x19: alu_r1 = d << (sft & 31); sz_int(alu_r1); break;
      case 0x1a: alu_r1 = d + a; sz_int(alu_r1); break;
      case 0x1b: alu_r1 = d - a; sz_int(alu_r1); break;
      default: alu_stmask = 0; unimplemented = true; break;
    }
  }
  void alu_update_st(){ st = (st & ~alu_stmask) | alu_stset; }
  void alu_post_1(uint32_t op) {
    switch (op) {
      case 0x01: case 0x02: case 0x03: case 0x04:
      case 0x0e: case 0x0f: case 0x16: case 0x17:
      case 0x18: case 0x19: case 0x1a: case 0x1b:
        d = alu_r1; alu_update_st(); break;
      default: break;
    }
  }
  void alu_post_2(uint32_t op) {
    switch (op) {
      case 0x05: alu_update_st(); break;
      case 0x06: case 0x07: case 0x0b: case 0x0c:
      case 0x10: case 0x11: case 0x13: case 0x14:
        d = alu_r1; alu_update_st(); break;
      case 0x08: p = alu_r1; break;
      case 0x09: case 0x0a: case 0x0d:
        d = alu_r1; p = alu_r2; alu_update_st(); break;
      default: break;
    }
  }

  void pcs_push(){ for(int i=3;i;i--) pcs[i]=pcs[i-1]; pcs[0]=pc; }
  void pcs_pop (){ pc = pcs[0]; for(int i=0;i!=3;i++) pcs[i]=pcs[i+1]; }

  // ------------------------------------------------------------ one step
  //
  // Mirrors execute_run's body for one instruction. Returns false only if the
  // instruction type has no dispatch case at all.
  bool step();
};

} // namespace mb
