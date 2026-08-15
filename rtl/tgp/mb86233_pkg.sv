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
// Portions of this file transcribe constants (opcode numbering, status flag
// bit positions, exponent/mantissa field accessors) from MAME's MB86233
// device model:
//
//   src/devices/cpu/mb86233/mb86233.cpp
//   SPDX-License-Identifier: BSD-3-Clause
//   Copyright-holders: Olivier Galibert
//
// That BSD-3-Clause attribution must be retained. See THIRD-PARTY.md.
//
// Fujitsu MB86233 "TGP" — architectural constants
//
// Ground truth: MAME src/devices/cpu/mb86233/mb86233.cpp (Olivier Galibert).
// Where this file and that source disagree, the source wins.

`ifndef MB86233_PKG_SV
`define MB86233_PKG_SV

package mb86233_pkg;

  // ---------------------------------------------------------------- ALU ops

  // Plain sized localparams, not a `typedef enum`. yosys cannot infer a width
  // for an enum member reached through package scope resolution and dies with
  // "Failed to detect width for identifier ...ALU_ANDD"; Quartus 17.0.2 is no
  // more generous about SystemVerilog enums in packages. Since rtl-conventions
  // requires passing verilator, yosys and Quartus alike, the portable form wins
  // over the stronger typing.
  localparam logic [4:0] ALU_NOP   = 5'h00;
  localparam logic [4:0] ALU_ANDD  = 5'h01;  // D & A                      int
  localparam logic [4:0] ALU_ORAD  = 5'h02;  // D | A                      int
  localparam logic [4:0] ALU_EORD  = 5'h03;  // D ^ A                      int
  localparam logic [4:0] ALU_NOTD  = 5'h04;  // ~D                         int
  localparam logic [4:0] ALU_FCPD  = 5'h05;  // D - A, flags only
  localparam logic [4:0] ALU_FADD  = 5'h06;  // D = D + A
  localparam logic [4:0] ALU_FSBD  = 5'h07;  // D = D - A
  localparam logic [4:0] ALU_FML   = 5'h08;  // P = A * B
  localparam logic [4:0] ALU_FMSD  = 5'h09;  // D = D + P  ||  P = A * B
  localparam logic [4:0] ALU_FMRD  = 5'h0a;  // D = D - P  ||  P = A * B
  localparam logic [4:0] ALU_FABD  = 5'h0b;  // D = |D|
  localparam logic [4:0] ALU_FSMD  = 5'h0c;  // D = D + P
  localparam logic [4:0] ALU_FSPD  = 5'h0d;  // D = P      ||  P = A * B
  localparam logic [4:0] ALU_CXFD  = 5'h0e;  // D = float(int32(D))
  localparam logic [4:0] ALU_CFXD  = 5'h0f;  // D = int32(D), round per M[2:1]
  localparam logic [4:0] ALU_FDVD  = 5'h10;  // D = D / A
  localparam logic [4:0] ALU_FNED  = 5'h11;  // D = -D, zero stays +zero
  localparam logic [4:0] ALU_BAPA  = 5'h13;  // D = B + A
  localparam logic [4:0] ALU_BSPA  = 5'h14;  // D = B - A
  // Shift and integer ops. These were previously transcribed two slots high
  // (lsrd at 0x18 .. subd at 0x1d). Both MAME sources agree they are 0x16 ..
  // 0x1b: mb86233.cpp alu_pre cases 0x16-0x1b, and mb86233d.cpp lines
  // 243-248 disassemble the same numbering. 0x1c/0x1d do not decode at all —
  // they fall through alu_pre's default and log "unhandled alu pre".
  localparam logic [4:0] ALU_LSRD  = 5'h16;  // D >> SFT               logical
  localparam logic [4:0] ALU_LSLD  = 5'h17;  // D << SFT               logical
  localparam logic [4:0] ALU_ASRD  = 5'h18;  // D >>> SFT           arithmetic
  localparam logic [4:0] ALU_ASLD  = 5'h19;  // D <<< SFT           arithmetic
  localparam logic [4:0] ALU_ADDD  = 5'h1a;  // D + A                      int
  localparam logic [4:0] ALU_SUBD  = 5'h1b;  // D - A                      int

  // SFT is a u8 in MAME and the shift ops evaluate `m_d >> m_sft` directly,
  // which is undefined in C++ for counts above 31. On x86 the host masks to 5
  // bits, so that is what MAME exhibits in practice and what is modelled here.
  // Real silicon is unverified above 31. See docs/m0-mb86233-spike.md.
  localparam int unsigned SFT_BITS = 5;

  // These predicates are written as case statements rather than with the
  // `inside` operator. yosys rejects `inside` outright — "syntax error,
  // unexpected TOK_ID" — and Quartus 17.0.2 predates most of it too. The
  // original two functions here used `inside` and went unnoticed because
  // `make area` read each module file on its own and never fed this package
  // to yosys at all. Assigning to the function name is the portable form.

  // Ops that produce a floating-point D result and therefore take the extra
  // post cycle, and win the write-priority arbitration against transfers.
  function automatic logic alu_is_fp_d(input logic [4:0] op);
    case (op)
      ALU_FADD, ALU_FSBD, ALU_FABD, ALU_FSMD,
      ALU_FMSD, ALU_FMRD, ALU_FSPD,
      ALU_FDVD, ALU_FNED, ALU_BAPA, ALU_BSPA: alu_is_fp_d = 1'b1;
      default:                                alu_is_fp_d = 1'b0;
    endcase
  endfunction

  // Ops that write P.
  function automatic logic alu_writes_p(input logic [4:0] op);
    case (op)
      ALU_FML, ALU_FMSD, ALU_FMRD, ALU_FSPD: alu_writes_p = 1'b1;
      default:                               alu_writes_p = 1'b0;
    endcase
  endfunction

  // Ops that write D from the integer path (MAME alu_post_1). These take no
  // extra cycle and LOSE the write-priority arbitration against a concurrent
  // transfer. Note cxfd/cfxd sit here despite one of them producing a float:
  // MAME dispatches both from alu_post_1, not alu_post_2.
  function automatic logic alu_is_int_d(input logic [4:0] op);
    case (op)
      ALU_ANDD, ALU_ORAD, ALU_EORD, ALU_NOTD,
      ALU_CXFD, ALU_CFXD,
      ALU_LSRD, ALU_LSLD, ALU_ASRD, ALU_ASLD,
      ALU_ADDD, ALU_SUBD: alu_is_int_d = 1'b1;
      default:            alu_is_int_d = 1'b0;
    endcase
  endfunction

  // Ops that write D at all, by either path.
  function automatic logic alu_writes_d(input logic [4:0] op);
    alu_writes_d = alu_is_int_d(op) | alu_is_fp_d(op);
  endfunction

  // Ops dispatched from MAME alu_post_2, every one of which does m_icount--.
  // This is the "FP post-ops burn one additional cycle" rule.
  function automatic logic alu_is_fp_post(input logic [4:0] op);
    alu_is_fp_post = alu_is_fp_d(op) | (op == ALU_FCPD) | (op == ALU_FML);
  endfunction

  // Ops whose flags come from stset_set_sz_int rather than _fp. The two differ
  // only in whether the sign bit alone counts as nonzero, so they disagree
  // exactly on 0x80000000: int sees a negative, fp sees zero.
  //
  // cxfd (0x0e) is in this set despite producing a float. MAME computes its
  // flags with stset_set_sz_int on the float bit pattern. Unobservable in
  // practice — float(int32) never yields -0.0 — but replicated exactly.
  function automatic logic alu_flags_int(input logic [4:0] op);
    alu_flags_int = alu_is_int_d(op);
  endfunction

  // Ops that reach alu_update_st at all. Everything in alu_post_1, plus
  // alu_post_2 except fml — fml sets m_alu_stmask = 0 and never calls it.
  //
  // Opcodes outside this set (0x00, 0x12, 0x15, 0x1c-0x1f) hit alu_pre's
  // default, which logs and returns without touching m_alu_stmask/stset, so ST
  // is left completely alone. Returning the normal mask for them would clear
  // four flags and set ZRD on a zeroed result — a silent corruption on any
  // instruction word whose ALU field happens to be undecoded.
  function automatic logic alu_touches_st(input logic [4:0] op);
    alu_touches_st = alu_is_int_d(op) | alu_is_fp_d(op) | (op == ALU_FCPD);
  endfunction

  // Status update mask. Every op that touches flags uses the same one. Only
  // ZRD and SGD are ever *set*; CPD, OVD and DVZD are in the mask so they are
  // cleared and never restored.
  function automatic logic [31:0] alu_st_mask(input logic [4:0] op);
    if (!alu_touches_st(op))
      alu_st_mask = 32'd0;
    else
      alu_st_mask = (32'd1 << F_ZRD) | (32'd1 << F_SGD) | (32'd1 << F_CPD)
                  | (32'd1 << F_OVD) | (32'd1 << F_DVZD);
  endfunction

  // ---------------------------------------------------------- status flags

  localparam int unsigned F_ZRC  = 0;   localparam int unsigned F_ZRD  = 1;
  localparam int unsigned F_SGC  = 2;   localparam int unsigned F_SGD  = 3;
  localparam int unsigned F_CPC  = 4;   localparam int unsigned F_CPD  = 5;
  localparam int unsigned F_OVC  = 6;   localparam int unsigned F_OVD  = 7;
  localparam int unsigned F_UNC  = 8;   localparam int unsigned F_UND  = 9;
  localparam int unsigned F_DVZC = 10;  localparam int unsigned F_DVZD = 11;
  localparam int unsigned F_CA   = 12;  localparam int unsigned F_CPP  = 13;
  localparam int unsigned F_OVM  = 14;  localparam int unsigned F_UNM  = 15;
  localparam int unsigned F_SIF0 = 16;  localparam int unsigned F_SIF1 = 17;
  localparam int unsigned F_SOF0 = 18;
  localparam int unsigned F_PIF  = 20;  localparam int unsigned F_POF  = 21;
  localparam int unsigned F_PAIF = 22;  localparam int unsigned F_PAOF = 23;
  localparam int unsigned F_F0S  = 24;  localparam int unsigned F_F1S  = 25;
  localparam int unsigned F_IT   = 26;
  localparam int unsigned F_ZX0  = 27;  localparam int unsigned F_ZX1  = 28;
  localparam int unsigned F_ZX2  = 29;
  localparam int unsigned F_ZC0  = 30;  localparam int unsigned F_ZC1  = 31;

  // ------------------------------------------------- A/B/D/P field accessors
  //
  // Copied verbatim from MAME.
  //
  // get_mant sign-extends through the exponent field where set_mant does not.
  // That asymmetry IS real: dropping the sign-extension costs 93765 mismatches
  // in the mb86233_regs fuzz run.
  //
  // set_mant's 0x07f800000 is NOT a second quirk, despite what this repo's
  // docs said until 2026-08-14. The literal has nine hex digits but the extra
  // one is a leading zero, so it equals 0x7f800000 — the obvious intent.
  // Swapping one for the other produces zero mismatches over 3,000,000 cases.
  // Kept verbatim only so the transcription matches MAME line for line.

  function automatic logic [31:0] set_exp(input logic [31:0] v,
                                          input logic [31:0] e);
    set_exp = (v & 32'h807fffff) | ((e & 32'hff) << 23);
  endfunction

  function automatic logic [31:0] set_mant(input logic [31:0] v,
                                           input logic [31:0] m);
    set_mant = (v & 32'h07f800000) | ((m & 32'h00800000) << 8)
             | (m & 32'h007fffff);
  endfunction

  function automatic logic [31:0] get_exp(input logic [31:0] v);
    get_exp = (v >> 23) & 32'hff;
  endfunction

  function automatic logic [31:0] get_mant(input logic [31:0] v);
    get_mant = v[31] ? (v | 32'h7f800000) : (v & 32'h807fffff);
  endfunction

  // ------------------------------------------------- transfer endpoint kinds
  //
  // Where one side of a ld/mov transfer lives. A register endpoint is signalled
  // separately rather than encoded here, because it has no effective address.
  localparam logic [1:0] EP_NONE = 2'd0;
  localparam logic [1:0] EP_DATA = 2'd1;   // internal RAM / FIFO space
  localparam logic [1:0] EP_IO   = 2'd2;   // copro_io_map: sincos, atan, ...
  localparam logic [1:0] EP_PROG = 2'd3;   // microcode ROM, readable as data

  // ------------------------------------------------------------ memory map

  localparam logic [15:0] RAM0_BASE   = 16'h0000;  // bank 0: 0x000-0x0ff
  localparam logic [15:0] RAM0_TOP    = 16'h00ff;
  localparam logic [15:0] EXT_LO_BASE = 16'h0100;  // routes externally
  localparam logic [15:0] EXT_LO_TOP  = 16'h01ff;
  localparam logic [15:0] RAM1_BASE   = 16'h0200;  // bank 1: 0x200-0x3ff
  localparam logic [15:0] RAM1_TOP    = 16'h03ff;
  localparam logic [15:0] EXT_HI_BASE = 16'h0400;  // copro output FIFO on model1

  localparam logic [15:0] EA_AUTO_ADD = 16'h0200;  // automatic +0x200 adder

endpackage

`endif
