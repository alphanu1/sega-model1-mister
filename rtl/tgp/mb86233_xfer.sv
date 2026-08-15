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
//   src/devices/cpu/mb86233/mb86233.cpp   (execute_run cases 0x00 and 0x07)
//   SPDX-License-Identifier: BSD-3-Clause
//   Copyright-holders: Olivier Galibert
//
// That BSD-3-Clause attribution must be retained. See THIRD-PARTY.md.
//
// Fujitsu MB86233 "TGP" — transfer routing
//
// Every ld/mov form reduces to one source and one destination, each being a
// memory space or a register. This module is that table and nothing else, so
// the core FSM can be written once against a uniform shape instead of thirteen
// special cases.
//
// `lab` is the exception and is flagged rather than folded in: it performs TWO
// reads and no write, landing them in A and B.
//
// THE ADDRESSING SIDE IS NOT CONSISTENT, and that is the whole reason this is
// a separate verified module. Within ld/mov sub-op 7, forms 7/2, 7/3 and 7/4
// use ea_pre_1, but 7/5 uses ea_pre_0 — its immediate neighbours disagree. The
// non-7 sub-ops read via ea_pre_0 and write via ea_pre_1 (write_mem_*_1). Get
// one of these wrong and the effect is an address off by whatever b0/x0 happen
// to hold against b1/x1, which is silent and data-dependent.

`timescale 1ns/1ps

module mb86233_xfer (
  input  logic        is_lab,
  input  logic        is_ldmov,
  input  logic [2:0]  sub_op,      // (opcode >> 18) & 7
  input  logic [2:0]  op7_sub,     // r2 >> 6, valid when sub_op == 7

  // ---------------------------------------------------------------- source
  output logic [1:0]  src_space,   // mb86233_pkg::EP_*, EP_NONE when src_is_reg
  output logic        src_is_reg,
  output logic        src_bank,    // 0 -> ea_pre_0 (b0/x0/i0), 1 -> ea_pre_1
  output logic        src_add200,
  output logic        src_use_r2,  // EA/register index comes from r2, not r1

  // ----------------------------------------------------------- destination
  output logic [1:0]  dst_space,
  output logic        dst_is_reg,
  output logic        dst_bank,
  output logic        dst_add200,
  output logic        dst_use_r2,

  // ------------------------------------------------------------------- lab
  output logic        lab_two_reads,
  output logic [1:0]  lab_b_space,  // second read's space
  output logic        lab_a_add200,
  output logic        lab_b_add200,

  output logic        unimplemented  // no case in MAME; it logs and does nothing
);

  always_comb begin
    src_space  = mb86233_pkg::EP_NONE; src_is_reg = 1'b0; src_bank = 1'b0;
    src_add200 = 1'b0;    src_use_r2 = 1'b0;
    dst_space  = mb86233_pkg::EP_NONE; dst_is_reg = 1'b0; dst_bank = 1'b0;
    dst_add200 = 1'b0;    dst_use_r2 = 1'b0;
    lab_two_reads = 1'b0; lab_b_space = mb86233_pkg::EP_NONE;
    lab_a_add200  = 1'b0; lab_b_add200 = 1'b0;
    unimplemented = 1'b0;

    if (is_lab) begin
      // A always comes from ea_pre_0(r1), B from ea_pre_1(r2). Only the space
      // of the B side and which side carries +0x200 vary.
      lab_two_reads = 1'b1;
      src_space = mb86233_pkg::EP_DATA; src_bank = 1'b0;                 // A side
      unique case (sub_op)
        3'd0, 3'd1: begin lab_b_space = mb86233_pkg::EP_IO;   end        // lab mem, mem (e)
        3'd3:       begin lab_b_space = mb86233_pkg::EP_DATA; lab_b_add200 = 1'b1; end
        3'd4:       begin lab_b_space = mb86233_pkg::EP_DATA; lab_a_add200 = 1'b1; end
        default:    begin lab_two_reads = 1'b0; unimplemented = 1'b1; end
      endcase
    end else if (is_ldmov) begin
      unique case (sub_op)
        // Sub-ops 0-5 read via ea_pre_0(r1) and write via the _1 side (r2).
        3'd0, 3'd1: begin                                   // mov mem, mem (e)
          src_space = mb86233_pkg::EP_DATA; src_bank = 1'b0;
          dst_space = mb86233_pkg::EP_IO;   dst_bank = 1'b1; dst_use_r2 = 1'b1;
        end
        3'd2: begin                                         // mov mem (e), mem
          src_space = mb86233_pkg::EP_IO;   src_bank = 1'b0;
          dst_space = mb86233_pkg::EP_DATA; dst_bank = 1'b1; dst_use_r2 = 1'b1;
        end
        3'd3: begin                                         // mov mem, mem+0x200
          src_space = mb86233_pkg::EP_DATA; src_bank = 1'b0;
          dst_space = mb86233_pkg::EP_DATA; dst_bank = 1'b1; dst_use_r2 = 1'b1;
          dst_add200 = 1'b1;                                // write_mem_internal_1 bank=true
        end
        3'd4: begin                                         // mov mem+0x200, mem
          src_space = mb86233_pkg::EP_DATA; src_bank = 1'b0; src_add200 = 1'b1;
          dst_space = mb86233_pkg::EP_DATA; dst_bank = 1'b1; dst_use_r2 = 1'b1;
        end
        3'd5: begin                                         // mov mem (o), mem
          src_space = mb86233_pkg::EP_PROG; src_bank = 1'b0;
          dst_space = mb86233_pkg::EP_DATA; dst_bank = 1'b1; dst_use_r2 = 1'b1;
        end
        3'd7: begin
          unique case (op7_sub)
            3'd0: begin                                     // mov reg, mem
              src_is_reg = 1'b1; src_use_r2 = 1'b1;
              dst_space = mb86233_pkg::EP_DATA; dst_bank = 1'b1;         // r1 side
            end
            3'd1: begin                                     // mov reg, mem (e)
              src_is_reg = 1'b1; src_use_r2 = 1'b1;
              dst_space = mb86233_pkg::EP_IO;   dst_bank = 1'b1;
            end
            3'd2: begin                                     // mov mem+0x200, reg
              src_space = mb86233_pkg::EP_DATA; src_bank = 1'b1; src_add200 = 1'b1;
              dst_is_reg = 1'b1;   dst_use_r2 = 1'b1;
            end
            3'd3: begin                                     // mov mem, reg
              src_space = mb86233_pkg::EP_DATA; src_bank = 1'b1;
              dst_is_reg = 1'b1;   dst_use_r2 = 1'b1;
            end
            3'd4: begin                                     // mov mem (e), reg
              src_space = mb86233_pkg::EP_IO;   src_bank = 1'b1;
              dst_is_reg = 1'b1;   dst_use_r2 = 1'b1;
            end
            3'd5: begin
              // ea_pre_0, NOT ea_pre_1 — unlike 7/2, 7/3 and 7/4 either side
              // of it. Verbatim from MAME; do not "fix" the inconsistency.
              src_space = mb86233_pkg::EP_PROG; src_bank = 1'b0;
              dst_is_reg = 1'b1;   dst_use_r2 = 1'b1;
            end
            3'd6: begin                                     // mov reg, reg
              src_is_reg = 1'b1;
              dst_is_reg = 1'b1;   dst_use_r2 = 1'b1;
            end
            default: unimplemented = 1'b1;
          endcase
        end
        default: unimplemented = 1'b1;                      // 6, and 0x07/6
      endcase
    end
  end

endmodule
