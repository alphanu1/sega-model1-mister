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
//   src/devices/cpu/mb86233/mb86233.cpp   (execute_run)
//   SPDX-License-Identifier: BSD-3-Clause
//   Copyright-holders: Olivier Galibert
//
// One instruction of execute_run. The switch order, the case numbering and the
// order of operations within each case follow the source deliberately — the
// ordering IS the specification here, not an implementation detail. In
// particular alu_post_1 runs before the destination write in ld/mov, and
// alu_post_2 runs after the whole transfer.

#include "mb86233_ref.h"

namespace mb {

bool Cpu::step() {
  ppc = pc;
  uint32_t opcode = prog[pc & 0x7ff];
  pc = (uint16_t)(pc + 1);

  bool decoded = true;
  switch ((opcode >> 26) & 0x3f) {

  case 0x00: {                                   // lab
    uint32_t r1 = opcode & 0x1ff, r2 = (opcode >> 9) & 0x1ff;
    uint32_t alu = (opcode >> 21) & 0x1f, op = (opcode >> 18) & 7;
    alu_pre(alu);
    switch (op) {
      case 0: case 1: {
        uint32_t v1 = data_read(ea_pre(r1,false));
        uint32_t v2 = io_read ? io_read(ea_pre(r2,true)) : 0;
        ea_post(r1,false); ea_post(r2,true); a = v1; b = v2; break;
      }
      case 3: {
        uint32_t v1 = data_read(ea_pre(r1,false));
        uint32_t v2 = data_read(ea_pre(r2,true) + 0x200);
        ea_post(r1,false); ea_post(r2,true); a = v1; b = v2; break;
      }
      case 4: {
        uint32_t v1 = data_read(ea_pre(r1,false) + 0x200);
        uint32_t v2 = data_read(ea_pre(r2,true));
        ea_post(r1,false); ea_post(r2,true); a = v1; b = v2; break;
      }
      default: unimplemented = true; break;
    }
    alu_post_1(alu); alu_post_2(alu);
    break;
  }

  case 0x07: {                                   // ld / mov
    uint32_t r1 = opcode & 0x1ff, r2 = (opcode >> 9) & 0x1ff;
    uint32_t alu = (opcode >> 21) & 0x1f, op = (opcode >> 18) & 7;
    alu_pre(alu);
    switch (op) {
      case 0: case 1: {                          // mov mem, mem (e)
        uint32_t ea = ea_pre(r1,false); uint32_t v = data_read(ea);
        ea_post(r1,false); alu_post_1(alu);
        uint16_t e2 = ea_pre(r2,true); if (io_write) io_write(e2, v);
        ea_post(r2,true); break;
      }
      case 2: {                                  // mov mem (e), mem
        uint32_t ea = ea_pre(r1,false);
        uint32_t v = io_read ? io_read(ea) : 0;
        ea_post(r1,false); alu_post_1(alu);
        uint16_t e2 = ea_pre(r2,true); data_write(e2, v); ea_post(r2,true); break;
      }
      case 3: {                                  // mov mem, mem + 0x200
        uint32_t ea = ea_pre(r1,false); uint32_t v = data_read(ea);
        ea_post(r1,false); alu_post_1(alu);
        // write_mem_internal_1 with bank=true holds the EA in a u16, so the
        // +0x200 wraps at 0x10000 here where the mem+0x200 forms do not.
        uint16_t e2 = (uint16_t)(ea_pre(r2,true) + 0x200);
        data_write(e2, v); ea_post(r2,true); break;
      }
      case 4: {                                  // mov mem + 0x200, mem
        uint32_t ea = ea_pre(r1,false) + 0x200; uint32_t v = data_read(ea);
        ea_post(r1,false); alu_post_1(alu);
        uint16_t e2 = ea_pre(r2,true); data_write(e2, v); ea_post(r2,true); break;
      }
      case 5: {                                  // mov mem (o), mem
        uint32_t ea = ea_pre(r1,false); uint32_t v = prog[ea & 0x7ff];
        ea_post(r1,false); alu_post_1(alu);
        uint16_t e2 = ea_pre(r2,true); data_write(e2, v); ea_post(r2,true); break;
      }
      case 7: {
        switch (r2 >> 6) {
          case 0: { uint32_t v = read_reg(r2); alu_post_1(alu);
                    uint16_t e = ea_pre(r1,true); data_write(e, v);
                    ea_post(r1,true); break; }
          case 1: { uint32_t v = read_reg(r2); alu_post_1(alu);
                    uint16_t e = ea_pre(r1,true); if (io_write) io_write(e, v);
                    ea_post(r1,true); break; }
          case 2: { uint32_t v = data_read(ea_pre(r1,true) + 0x200);
                    ea_post(r1,true); alu_post_1(alu); write_reg(r2, v); break; }
          case 3: { uint32_t v = data_read(ea_pre(r1,true));
                    ea_post(r1,true); alu_post_1(alu); write_reg(r2, v); break; }
          case 4: { uint32_t v = io_read ? io_read(ea_pre(r1,true)) : 0;
                    ea_post(r1,true); alu_post_1(alu); write_reg(r2, v); break; }
          // ea_pre_0 here, unlike 7/2, 7/3 and 7/4 either side of it.
          case 5: { uint32_t v = prog[ea_pre(r1,false) & 0x7ff];
                    ea_post(r1,false); alu_post_1(alu); write_reg(r2, v); break; }
          case 6: { uint32_t v = read_reg(r1); alu_post_1(alu);
                    write_reg(r2, v); break; }
          default: alu_post_1(alu); unimplemented = true; break;
        }
        break;
      }
      default: alu_post_1(alu); unimplemented = true; break;
    }
    alu_post_2(alu);                             // FP results land after the transfer
    break;
  }

  case 0x0d: {                                   // stm / clm
    uint32_t sub2 = (opcode >> 17) & 7;
    if (sub2 == 5) m = (uint16_t)opcode;         // stmh
    else unimplemented = true;
    break;
  }

  case 0x0e: {                                   // lipl / lia / lib / lid
    switch ((opcode >> 24) & 3) {
      // m_p is a u32, so the 48-bit mask truncates to 0xff000000: the top byte
      // survives and only the low 24 bits are replaced.
      case 0: p = (uint32_t)((p & 0xffffff000000ull) | (opcode & 0xffffff)); break;
      case 1: a = (uint32_t)sext(opcode, 24); break;
      case 2: b = (uint32_t)sext(opcode, 24); break;
      case 3: d = (uint32_t)sext(opcode, 24); break;
    }
    break;
  }

  case 0x0f: {                                   // rep / clr0 / clr1 / set
    uint32_t alu = (opcode >> 20) & 0x1f;        // note: >> 20, not >> 21
    uint32_t sub2 = (opcode >> 17) & 7;
    alu_pre(alu);
    switch (sub2) {
      case 0:
        if (opcode & 0x0004) a = 0;
        if (opcode & 0x0008) b = 0;
        if (opcode & 0x0010) d = 0;
        break;
      case 1: break;                             // clr1, flags mapping unknown
      case 2:                                    // rep: skips the repeat block
        r = (uint8_t)((opcode & 0x8000) ? read_reg(opcode) : opcode);
        alu_post_1(alu);
        return decoded;                          // goto rep_start
      case 3: break;                             // set, flags mapping unknown
      default: unimplemented = true; break;
    }
    alu_post_1(alu);
    break;
  }

  case 0x10: case 0x11: case 0x12: case 0x13:
  case 0x14: case 0x15: case 0x16: case 0x17:
  case 0x18: case 0x19: case 0x1a: case 0x1b:
  case 0x1c: case 0x1d: case 0x1e: case 0x1f:    // ldi
    write_reg(opcode >> 24, (uint32_t)sext(opcode, 24));
    break;

  case 0x2f: case 0x3f: {                        // conditional branch
    uint32_t cond = (opcode >> 20) & 0x1f;
    uint32_t subtype = (opcode >> 17) & 7;
    uint32_t data = opcode & 0xffff;
    bool invert = (opcode & 0x40000000) != 0;

    bool passed = false;
    switch (cond) {
      case 0x00: passed = st & F_ZRD; break;
      case 0x01: passed = !(st & F_SGD); break;
      case 0x02: passed = st & (F_ZRD | F_SGD); break;
      case 0x0a: passed = gpio0; break;
      case 0x0b: passed = gpio1; break;
      case 0x0c: passed = gpio2; break;
      case 0x10: passed = !(st & F_ZC0); break;
      case 0x11: passed = !(st & F_ZC1); break;
      case 0x12: passed = gpio3; break;
      case 0x16: passed = true; break;
      default: passed = false; unimplemented = true; break;
    }
    if (invert) passed = !passed;

    if (passed) {
      switch (subtype) {
        case 0: pc = (uint16_t)data; break;
        case 1: pc = (uint16_t)((opcode & 0x4000)
                  ? read_reg(opcode)
                  : data_read(ea_pre(opcode,false)));
                if (!(opcode & 0x4000)) ea_post(opcode,false);
                break;
        case 2: pcs_push(); pc = (uint16_t)data; break;
        case 3: {
          uint32_t v = (opcode & 0x4000) ? read_reg(opcode)
                                         : data_read(ea_pre(opcode,false));
          if (!(opcode & 0x4000)) ea_post(opcode,false);
          pcs_push(); pc = (uint16_t)v; break;
        }
        case 5: pcs_pop(); break;
        case 6: {
          uint32_t v = data_read(ea_pre(opcode,false));
          ea_post(opcode,false); write_reg(opcode >> 9, v); break;
        }
        default: unimplemented = true; break;
      }
    }

    // Outside the passed block, and only for subtype < 2.
    if (subtype < 2) {
      if (cond == 0x10 && c0 != 1) { c0--; if (c0 == 1) st |= F_ZC0; }
      if (cond == 0x11 && c1 != 1) { c1--; if (c1 == 1) st |= F_ZC1; }
    }
    break;
  }

  default: unimplemented = true; decoded = false; break;
  }

  // The repeat override: below the whole switch, so it discards a taken branch.
  if (r != 1) { pc = ppc; r--; }
  return decoded;
}

} // namespace mb
