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
// That BSD-3-Clause attribution must be retained. See THIRD-PARTY.md.
//
// Fujitsu MB86233 "TGP" — top level
//
// Ties together the ten verified blocks and adds the one thing none of them
// has: sequencing. Each instruction is fetched, then executed as a short
// sequence of memory accesses, then retired.
//
// TIMING IS NOT MAME'S. MAME executes an instruction atomically and charges
// cycles afterwards; this is a multi-cycle FSM. What must match is the
// architectural state after each instruction retires, not the cycle it happens
// on. The TGP retires ~5.3 M instructions/sec against a 50 MHz fabric, so a
// handful of cycles per instruction is free — docs/m0-mb86233-spike.md says
// explicitly not to pipeline for speed.
//
// STALLS. MAME models an incomplete external access as `m_stall` plus
// `goto do_stall`, which resets PC to ppc and re-executes the whole
// instruction. Here the FSM simply waits in the access state, which reaches the
// same architectural result without re-running the ALU. The distinction is
// invisible to the lockstep comparison because nothing is retired until the
// access completes.
//
// fdvd is the same problem in a different place: fp_div is a 29-cycle iterative
// block with a busy handshake while mb86233_alu is fixed-latency-2. The FSM
// waits for it in S_DIV rather than the ALU pretending to be variable-latency.

`timescale 1ns/1ps

module mb86233_core (
  input  logic        clk,
  input  logic        rst_n,

  // Program space: 32-bit words, synchronous read, data valid the cycle after
  // addr. Model 1 maps 0x000-0x7ff of microcode ROM here.
  output logic [15:0] prog_addr,
  input  logic [31:0] prog_rdata,

  // IO space (copro_io_map): the board's sincos/atan/inv/isqrt accelerators.
  // Not memory, and not internal — always external, always able to stall.
  output logic [15:0] io_addr,
  output logic        io_rd,
  output logic        io_wr,
  output logic [31:0] io_wdata,
  input  logic [31:0] io_rdata,
  input  logic        io_ack,

  // Data-space external endpoints, forwarded from mb86233_mem: the input FIFO
  // at 0x0100 and the output FIFO at 0x0400.
  output logic        fifo_rd,
  output logic        fifo_wr,
  output logic [31:0] fifo_wdata,
  input  logic [31:0] fifo_rdata,
  input  logic        fifo_ack,

  input  logic [3:0]  gpio,

  // Retire strobe and PC, for the lockstep harness and for tracing.
  output logic        retire,
  output logic [15:0] retire_pc,
  output logic        unimplemented,

  // Architectural state, exposed for the lockstep bridge. M0 exit criterion 2
  // compares every architecturally visible register every instruction, so this
  // is not debug scaffolding — it is the interface that criterion is checked
  // through.
  output logic [31:0] dbg_a,
  output logic [31:0] dbg_b,
  output logic [31:0] dbg_d,
  output logic [31:0] dbg_p,
  output logic [31:0] dbg_st,
  output logic [15:0] dbg_m,
  // Data-memory write port, for the lockstep bridge. Registers alone cannot
  // localise a store/load divergence — you see the wrong value arrive without
  // seeing where it was written.
  output logic [16:0] dbg_mem_addr,
  output logic [31:0] dbg_mem_wdata,
  output logic        dbg_mem_we,
  output logic        dbg_mem_re,
  output logic [31:0] dbg_mem_rdata,
  output logic [7:0]  dbg_c0,
  output logic [7:0]  dbg_c1,
  output logic [7:0]  dbg_rep
);

  // ==================================================================
  // Decode
  // ==================================================================

  logic [31:0] ir;                 // latched instruction

  logic        d_lab, d_ldmov, d_stm, d_lipl, d_repgrp, d_ldi, d_branch, d_unimpl;
  logic [8:0]  d_r1, d_r2;
  logic [4:0]  d_alu;
  logic [2:0]  d_sub, d_op7;
  logic [4:0]  d_cond;
  logic [2:0]  d_bsub;
  logic [15:0] d_bdata;
  logic        d_binv;
  logic [5:0]  d_ldireg;
  logic [31:0] d_ldival;
  logic [1:0]  d_lsel;
  logic [31:0] d_lval;
  logic [23:0] d_lpimm;
  logic [2:0]  d_fsub;
  logic        d_clra, d_clrb, d_clrd, d_repreg;
  logic [7:0]  d_repimm;
  logic [2:0]  d_stmsub;
  logic [15:0] d_stmm;

  mb86233_dec u_dec (
    .opcode(ir),
    .is_lab(d_lab), .is_ldmov(d_ldmov), .is_stm(d_stm), .is_lipl(d_lipl),
    .is_rep_grp(d_repgrp), .is_ldi(d_ldi), .is_branch(d_branch),
    .unimplemented(d_unimpl),
    .r1(d_r1), .r2(d_r2), .alu(d_alu), .sub_op(d_sub), .op7_sub(d_op7),
    .br_cond(d_cond), .br_subtype(d_bsub), .br_data(d_bdata), .br_invert(d_binv),
    .ldi_reg(d_ldireg), .ldi_val(d_ldival),
    .lipl_sel(d_lsel), .lipl_val(d_lval), .lipl_p_imm(d_lpimm),
    .f_sub(d_fsub), .f_clr_a(d_clra), .f_clr_b(d_clrb), .f_clr_d(d_clrd),
    .f_rep_from_reg(d_repreg), .f_rep_imm(d_repimm),
    .stm_sub(d_stmsub), .stm_m(d_stmm)
  );

  logic [1:0] x_src_sp, x_dst_sp, x_lab_b_sp;
  logic       x_src_reg, x_dst_reg, x_src_bank, x_dst_bank;
  logic       x_src_200, x_dst_200, x_src_r2, x_dst_r2;
  logic       x_lab2, x_lab_a200, x_lab_b200, x_unimpl;

  mb86233_xfer u_xfer (
    .is_lab(d_lab), .is_ldmov(d_ldmov), .sub_op(d_sub), .op7_sub(d_op7),
    .src_space(x_src_sp), .src_is_reg(x_src_reg), .src_bank(x_src_bank),
    .src_add200(x_src_200), .src_use_r2(x_src_r2),
    .dst_space(x_dst_sp), .dst_is_reg(x_dst_reg), .dst_bank(x_dst_bank),
    .dst_add200(x_dst_200), .dst_use_r2(x_dst_r2),
    .lab_two_reads(x_lab2), .lab_b_space(x_lab_b_sp),
    .lab_a_add200(x_lab_a200), .lab_b_add200(x_lab_b200),
    .unimplemented(x_unimpl)
  );

  // ==================================================================
  // Register file, sequencer, AGU
  // ==================================================================

  logic [31:0] reg_a, reg_b, reg_d, reg_p;
  logic [15:0] b0, b1, x0, x1, i0, i1, vsmr, mask;
  logic [7:0]  sft;
  logic [7:0]  seq_c0, seq_c1, seq_rep;
  logic        seq_zc0, seq_zc1;

  logic        rf_wr_en;
  logic [5:0]  rf_wr_addr;
  logic [31:0] rf_wr_data;
  logic [5:0]  rf_rd_addr;
  logic [31:0] rf_rd_data;
  logic        rf_rd_unimpl, rf_wr_unimpl;
  logic        c0_we, c1_we;
  logic [7:0]  c0_wd, c1_wd;

  logic        clr_a_now, clr_b_now, clr_d_now;
  logic        alu_d_we, alu_p_we;
  logic [31:0] alu_d_val, alu_p_val;
  logic        agu_x0_we, agu_x1_we;
  logic [15:0] agu_x_next;

  mb86233_regs u_regs (
    .clk(clk), .rst_n(rst_n),
    .rd_addr(rf_rd_addr), .rd_data(rf_rd_data), .rd_unimpl(rf_rd_unimpl),
    .wr_en(rf_wr_en), .wr_addr(rf_wr_addr), .wr_data(rf_wr_data),
    .wr_unimpl(rf_wr_unimpl),
    .alu_d_we(alu_d_we), .alu_d(alu_d_val),
    .alu_p_we(alu_p_we), .alu_p(alu_p_val),
    .agu_x0_we(agu_x0_we), .agu_x0(agu_x_next),
    .agu_x1_we(agu_x1_we), .agu_x1(agu_x_next),
    .clr_a(clr_a_now), .clr_b(clr_b_now), .clr_d(clr_d_now),
    .c0_we(c0_we), .c0_wd(c0_wd), .c1_we(c1_we), .c1_wd(c1_wd),
    .c0(seq_c0), .c1(seq_c1),
    .reg_a(reg_a), .reg_b(reg_b), .reg_d(reg_d), .reg_p(reg_p),
    .b0(b0), .b1(b1), .x0(x0), .x1(x1), .i0(i0), .i1(i1),
    .vsmr(vsmr), .sft(sft), .mask(mask)
  );

  // M is NOT the MASK register. write_reg(0x3c) sets m_mask; m_m is written
  // only by the stm instruction (0x0d sub-op 5), and cfxd reads its rounding
  // mode from (m_m >> 1) & 3. Wiring MASK here instead makes every cfxd use
  // whatever an unrelated register write last left behind.
  logic [15:0] reg_m;

  // The status word. Only ZRD/SGD come from the ALU and only ZC0/ZC1 from the
  // sequencer, so ST is assembled here rather than owned by either.
  logic [31:0] st;
  logic [31:0] alu_st_out;

  logic        seq_valid, seq_stall;
  logic [15:0] seq_pc;
  logic        seq_cond_passed, seq_unimpl;
  logic [15:0] seq_branch_val;
  logic        seq_is_rep;
  logic [7:0]  seq_rep_count;

  mb86233_seq u_seq (
    .clk(clk), .rst_n(rst_n),
    .in_valid(seq_valid),
    .is_branch(d_branch), .cond(d_cond), .subtype(d_bsub),
    .data(d_bdata), .invert(d_binv),
    .branch_val(seq_branch_val),
    .is_rep(seq_is_rep), .rep_count(seq_rep_count),
    .stall(seq_stall),
    .gpio(gpio), .st_in(st),
    .c0_we(c0_we), .c0_wd(c0_wd), .c1_we(c1_we), .c1_wd(c1_wd),
    .pc(seq_pc), .c0(seq_c0), .c1(seq_c1), .rep(seq_rep),
    .zc0(seq_zc0), .zc1(seq_zc1),
    .cond_passed(seq_cond_passed), .unimplemented(seq_unimpl)
  );

  // ST IS AN ARCHITECTURAL REGISTER, NOT A COMBINATIONAL VIEW OF THE ALU.
  //
  // This used to be `assign st = {seq_zc1, seq_zc0, alu_st_out[29:0]}`, and
  // alu_st_out is combinational — `(s2_st & ~st_mask) | st_set`, where s2_st is
  // st_in pipelined through ALU_LAT stages. So ST was carried in the ALU's
  // pipeline registers and RECOMPUTED for whatever instruction happened to be in
  // the ALU. A conditional branch immediately after an ALU op therefore read a
  // corrupted ST.
  //
  // Found by `make tgp_trace` in the coprocessor's command-dispatch loop:
  //
  //   0048: subd       d=00000000  st=c0000002  zrd=1    correct
  //   0049: brif !zrd  d=00000000  st=c0000008  zrd=0    ST changed under it
  //
  // subd sets ZRD on its zero result; the branch then cleared ZRD and set SGD
  // before the condition was evaluated, so `!zrd` read true and the TGP spun in
  // the loop forever — 41 iterations against the reference's one, which is why
  // the coprocessor never got past dispatch and never wrote a result.
  //
  // MAME keeps m_st as state and updates it exactly once per instruction:
  //   mb86233.cpp:201  m_st = F_ZRC|F_ZRD|F_ZX0|F_ZX1|F_ZX2|F_ZC0|F_ZC1;
  //   mb86233.cpp:499  m_st = (m_st & ~m_alu_stmask) | m_alu_stset;
  // That is what this now is. alu_out_valid marks the one cycle an ALU result
  // retires, so flags update then and hold otherwise.
  //
  // ZC0/ZC1 (bits 31/30) stay with the sequencer, which owns the loop counters —
  // see its header. Only bits 29:0 live here.
  //
  // Reset value is MAME's, minus the two the sequencer owns:
  //   F_ZRC(0) | F_ZRD(1) | F_ZX0(27) | F_ZX1(28) | F_ZX2(29) = 0x38000003
  logic [29:0] st_hold;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)              st_hold <= 30'h3800_0003;
    else if (alu_out_valid)  st_hold <= alu_st_out[29:0];
  end

  assign st = {seq_zc1, seq_zc0, st_hold};

  // The AGU is shared between the two transfer sides, so it is driven from the
  // FSM's current step rather than hardwired to one of them.
  logic [8:0]  agu_r;
  logic        agu_bank;
  logic [16:0] agu_ea;
  logic        agu_x0_we_raw, agu_x1_we_raw;
  logic        agu_post_en;      // only apply the post-increment once, on use

  mb86233_agu u_agu (
    .r(agu_r), .bank(agu_bank),
    .b0(b0), .x0(x0), .i0(i0), .b1(b1), .x1(x1), .i1(i1),
    .vsmr(vsmr), .add_0x200(1'b0), .wrap16(1'b0),
    .ea(agu_ea), .x_next(agu_x_next),
    .x0_we(agu_x0_we_raw), .x1_we(agu_x1_we_raw)
  );

  assign agu_x0_we = agu_post_en & agu_x0_we_raw;
  assign agu_x1_we = agu_post_en & agu_x1_we_raw;

  // ==================================================================
  // Data memory
  // ==================================================================

  logic        mem_sel_ram0, mem_sel_ram1, mem_sel_fin, mem_sel_fout, mem_unmapped;
  logic        mem_req, mem_we;
  logic [16:0] mem_addr;
  logic [31:0] mem_wdata, mem_rdata;
  logic        mem_stall;

  mb86233_mem u_mem (
    .clk(clk), .rst_n(rst_n),
    .req(mem_req), .we(mem_we), .addr(mem_addr), .wdata(mem_wdata),
    .rdata(mem_rdata), .stall(mem_stall),
    .ext_rd(fifo_rd), .ext_wr(fifo_wr), .ext_wdata(fifo_wdata),
    .ext_rdata(fifo_rdata), .ext_ack(fifo_ack),
    // Decode visibility, unused here but named rather than left empty: an
    // unmapped data access is a real condition the lockstep harness watches for.
    .sel_ram0(mem_sel_ram0), .sel_ram1(mem_sel_ram1),
    .sel_fifo_in(mem_sel_fin), .sel_fifo_out(mem_sel_fout),
    .unmapped(mem_unmapped)
  );

  // ==================================================================
  // ALU
  // ==================================================================

  logic        alu_in_valid, alu_out_valid;
  logic        alu_extra, alu_busy;
  logic        xfer_d_valid;
  logic [31:0] xfer_d_data;

  // ALU OPERANDS ARE SNAPSHOT AT DECODE, NOT READ LIVE.
  //
  // MAME calls alu_pre(alu) at the TOP of every instruction, before the memory
  // access and before the parallel transfer writes its register. Our FSM writes
  // the transfer in S_DST and only reaches S_ALU afterwards, so an ALU fed from
  // the live register file computes on the value this same instruction just
  // stored:
  //
  //     069E: mov $0x5c, a
  //     069F: fsbd : mov $0x5e, a     <- d = d - a, with the OLD a (0x5c)
  //     06A0: mov d, $0x44
  //
  //     reference   TW 0044 bf9e1480
  //     ours        TW 0044 c33b6666   <- subtracted data[0x5e] instead
  //
  // The separate xfer_d_valid path still carries the write-priority rule for a
  // transfer targeting D; this is about the OPERANDS, which is a different
  // question and was never modelled.
  logic [31:0] pre_a, pre_b, pre_d, pre_p;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pre_a <= 32'd0; pre_b <= 32'd0; pre_d <= 32'd0; pre_p <= 32'd0;
    end else if (state == S_DECODE) begin
      pre_a <= reg_a; pre_b <= reg_b; pre_d <= reg_d; pre_p <= reg_p;
    end
  end

  mb86233_alu u_alu (
    .clk(clk), .rst_n(rst_n),
    .in_valid(alu_in_valid), .op(alu_op_r),
    .reg_a(pre_a), .reg_b(pre_b), .reg_d(pre_d), .reg_p(pre_p),
    .sft(sft), .m(reg_m), .st_in(st),
    .xfer_d_valid(xfer_d_valid), .xfer_d_data(xfer_d_data),
    // lab and ld/mov reach alu_post_2; the 0x0f group does not.
    .fp_post_en(fp_post_r),
    .out_valid(alu_out_valid),
    .d_out(alu_d_val), .d_we(alu_d_we),
    .p_out(alu_p_val), .p_we(alu_p_we),
    .st_out(alu_st_out), .extra_cycle(alu_extra),
    .busy(alu_busy)
  );

  // ==================================================================
  // FSM
  // ==================================================================

  typedef enum logic [3:0] {
    S_FETCH, S_FETCH_W, S_DECODE,
    S_SRC, S_SRC_W, S_LABB, S_LABB_W,
    S_DST, S_DST_W,
    S_ALU, S_RETIRE,
    S_BRUL_RD, S_BRUL_W,
    S_LAB_WA, S_LAB_WB
  } state_e;

  state_e state;

  // The ALU runs for exactly three instruction types. MAME calls alu_pre and
  // alu_post only from cases 0x00, 0x07 and 0x0f; everywhere else the bits that
  // would be the ALU field are immediate data that merely aliases onto it.
  // Running the ALU unconditionally lets `ldi 0x19` — whose immediate puts 0x0f
  // (cfxd) in bits 25:21 — write D and destroy the value it just loaded.
  logic alu_active;
  assign alu_active = d_lab | d_ldmov | d_repgrp;

  // RETIMING: the ALU op reaches the FP operand mux through a REGISTER, not
  // straight out of the decoder.
  //
  // The critical path was ir -> u_dec -> ALU operand mux -> fp_add stage 1:
  // the instruction register feeding combinational decode, which selects
  // fp_add's operands, which then drive a 27-bit align shifter and a subtract
  // before the first flop. Quartus named it as
  //   From ir[28]  To mb86233_alu|fp_add|s1_exact_cancel
  // and it held the core to 51.47 MHz against an 80 MHz gate.
  //
  // Latching the decoded op in S_DECODE cuts the path in two without changing
  // behaviour: the FSM already spends a whole state there, so the register is
  // free in cycles as well as in area.
  logic [4:0] alu_op_r;
  logic       fp_post_r;

  // The ALU is fixed-latency-2 and free-running: holding in_valid across the
  // whole wait state launches a fresh operation every cycle, and their
  // writebacks land during S_RETIRE and S_FETCH, clobbering whatever the
  // instruction actually wrote. Issue exactly one.
  logic alu_launched;

  logic [31:0] src_val;          // value in flight between source and dest
  logic [31:0] lab_a_val, lab_b_val;

  // Which side's r/bank the AGU should present this cycle.
  //
  // THE B SIDE OF A `lab` IS A THIRD CASE. MAME reads A with ea_pre_0(r1) and B
  // with ea_pre_1(r2) - different field, different bank, and ea_post_1(r2)
  // afterwards. The mux had only a source and a destination side, so the B read
  // addressed with r1/bank0 and fetched the A operand's neighbourhood; B came
  // back holding the same value as A.
  //
  // This was invisible for as long as the B value was read and discarded. The
  // fix that made `lab` write its registers is what exposed it, one instruction
  // later in the same trace.
  logic        use_dst_side;
  wire         use_lab_b = (state == S_LABB) || (state == S_LABB_W);
  assign agu_r    = use_lab_b    ? d_r2
                  : use_dst_side ? (x_dst_r2 ? d_r2 : d_r1)
                                 : (x_src_r2 ? d_r2 : d_r1);
  assign agu_bank = use_lab_b ? 1'b1
                  : use_dst_side ? x_dst_bank : x_src_bank;

  // +0x200 is applied outside the AGU because it is per-instruction-form, not
  // an addressing mode. See mb86233_agu's header.
  logic [16:0] ea_src, ea_dst;
  // lab's A side carries its own +0x200 flag. ea_src honoured only x_src_200, so
  // `lab (x0+6)+0x200, $0x74` addressed 0x106 instead of 0x306 - and 0x100 is
  // the COMMAND FIFO, so the coprocessor blocked reading a FIFO that was empty
  // and stayed blocked. It presented as a dead TGP with fifo_rd stuck high.
  //
  // Only reachable once the branch at 0731 went the right way; this instruction
  // had never executed before today.
  assign ea_src = agu_ea + ((x_src_200 || x_lab_a200) ? 17'h200 : 17'd0);
  assign ea_dst = agu_ea + (x_dst_200 ? 17'h200 : 17'd0);

  assign prog_addr = (state == S_SRC || state == S_SRC_W)
                     && (x_src_sp == mb86233_pkg::EP_PROG)
                     ? agu_ea[15:0] : seq_pc;

  assign clr_a_now = (state == S_RETIRE) & d_repgrp & (d_fsub == 3'd0) & d_clra;
  assign clr_b_now = (state == S_RETIRE) & d_repgrp & (d_fsub == 3'd0) & d_clrb;
  assign clr_d_now = (state == S_RETIRE) & d_repgrp & (d_fsub == 3'd0) & d_clrd;

  assign dbg_a  = reg_a;  assign dbg_b  = reg_b;
  assign dbg_d  = reg_d;  assign dbg_p  = reg_p;
  assign dbg_st = st;  assign dbg_m = reg_m;
  assign dbg_mem_addr  = mem_addr;
  assign dbg_mem_wdata = mem_wdata;
  assign dbg_mem_we    = mem_req & mem_we;
  assign dbg_mem_re    = mem_req & ~mem_we;
  assign dbg_mem_rdata = mem_rdata;
  assign dbg_c0 = seq_c0; assign dbg_c1 = seq_c1; assign dbg_rep = seq_rep;

  // Which indirect form a brul/bsul is using. Bit 14 of the instruction's low
  // half selects register over memory, exactly as MAME's `opcode & 0x4000` does.
  logic brul_regform, brul_memform, brul_ea_simple;
  always_comb begin
    brul_regform = d_branch & ((d_bsub == 3'd1) | (d_bsub == 3'd3)) &  d_bdata[14];
    brul_memform = d_branch & ((d_bsub == 3'd1) | (d_bsub == 3'd3)) & ~d_bdata[14];
    // MAME's ea_pre_0: `switch(r & 0x180) case 0x000: return r & 0x7f`. The other
    // three modes add b0/x0 and are not reached by this microcode — both sites,
    // 0x04c5 and 0x04da, use the direct one. Anything else warns above rather than
    // branching somewhere plausible.
    brul_ea_simple = (d_bdata[8:7] == 2'b00);
  end

  // The target word, read from data memory before the branch can resolve.
  logic [15:0] brul_target;

  // THE MEMORY FORM IS NOT IMPLEMENTED and says so out loud rather than jumping
  // somewhere plausible. Resolving it needs a data-memory read before the branch,
  // which is another FSM state. Two sites exist in the vr microcode, both bsul at
  // 0x04c5 and 0x04da, and neither has been reached yet. Reported the way v60.sv
  // reports a skipped BRK: visible in simulation, no effect on synthesis.
  // NOT WRAPPED IN A SYNTHESIS PRAGMA. The first version of this warning was, and
  // the linter honours those pragmas too — so the one tool that could have printed
  // it skipped it. `bsul` memory form then went undiagnosed for a day while its own
  // warning sat switched off. A $display costs nothing in synthesis; the pragma was
  // never needed.
  //
  // rst_n deliberately NOT tested: reading it in a posedge-clk block trips
  // SYNCASYNCNET, and state resets to S_FETCH so it cannot be S_RETIRE in reset.
  always @(posedge clk) begin
    if ((state == S_RETIRE) && brul_memform && !brul_ea_simple)
      $display("TGP: brul/bsul memory form with addressing mode %02h at pc %04h is not implemented (op %08h)",
               d_bdata[8:7], seq_pc, ir);
  end

  assign retire    = (state == S_RETIRE);
  assign retire_pc = seq_pc;
  assign unimplemented = d_unimpl | x_unimpl | rf_rd_unimpl | rf_wr_unimpl
                       | seq_unimpl;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state        <= S_FETCH;
      reg_m        <= 16'd0;
      ir           <= 32'd0;
      src_val      <= 32'd0;
      lab_a_val    <= 32'd0;
      lab_b_val    <= 32'd0;
      alu_launched <= 1'b0;
      alu_op_r     <= 5'd0;
      fp_post_r    <= 1'b0;
    end else begin
      unique case (state)
        S_FETCH:   state <= S_FETCH_W;
        S_FETCH_W: begin ir <= prog_rdata; state <= S_DECODE; end

        S_DECODE: begin
          alu_op_r  <= d_alu;
          fp_post_r <= d_lab | d_ldmov;
          // brul/bsul memory form needs its target FETCHED before the branch can
          // resolve, so it takes the read states like any other source operand.
          if (brul_memform && brul_ea_simple) state <= S_BRUL_RD;
          else if (d_lab || d_ldmov) state <= S_SRC;
          else                  state <= S_ALU;
        end

        S_SRC: begin
          if (x_src_reg) begin src_val <= rf_rd_data; state <= d_lab ? S_LABB : S_DST; end
          else                                        state <= S_SRC_W;
        end

        S_SRC_W: begin
          if (!mem_stall && !(x_src_sp == mb86233_pkg::EP_IO && !io_ack)) begin
            src_val <= (x_src_sp == mb86233_pkg::EP_PROG) ? prog_rdata
                     : (x_src_sp == mb86233_pkg::EP_IO)   ? io_rdata
                                                          : mem_rdata;
            state   <= d_lab ? S_LABB : S_DST;
          end
        end

        S_LABB:   begin lab_a_val <= src_val; state <= S_LABB_W; end
        S_LABB_W: begin
          if (!mem_stall && !(x_lab_b_sp == mb86233_pkg::EP_IO && !io_ack)) begin
            // THE SECOND OPERAND WAS BEING READ AND THROWN AWAY. `lab` is load A
            // AND B - MAME's case 0x00 ends `m_a = v1; m_b = v2;` - and this
            // state issued the read for v2, waited for it, and never captured
            // it, while lab_a_val was assigned and never read by anything. The
            // instruction loaded neither register.
            lab_b_val <= (x_lab_b_sp == mb86233_pkg::EP_IO) ? io_rdata
                                                            : mem_rdata;
            state     <= S_ALU;
          end
        end

        // A and B are written AFTER the ALU, not before it. MAME calls
        // alu_pre(alu) at the top of the instruction and only then assigns
        // m_a/m_b, so the parallel ALU op of a `lab` sees the OLD operands.
        // Writing them any earlier would feed this instruction's loads into its
        // own arithmetic. One register per cycle: the file has a single write
        // port and the ALU's own writeback to d/p does not use it.
        S_LAB_WA: state <= S_LAB_WB;
        S_LAB_WB: state <= S_RETIRE;

        S_DST:   state <= x_dst_reg ? S_ALU : S_DST_W;
        S_DST_W: begin
          if (!mem_stall && !(x_dst_sp == mb86233_pkg::EP_IO && !io_ack))
            state <= S_ALU;
        end

        S_ALU: begin
          alu_launched <= 1'b1;
          // out_valid already accounts for the divide: it is div_done for
          // fdvd and the pipeline for everything else. Do NOT also gate on
          // alu_busy — div_inflight only clears on the edge, so busy is still
          // high during the very cycle div_done fires, and the FSM would never
          // leave this state.
          if (!alu_active || alu_out_valid) begin
            state        <= d_lab ? S_LAB_WA : S_RETIRE;
            alu_launched <= 1'b0;
          end
        end
        S_BRUL_RD: state <= S_BRUL_W;
        S_BRUL_W: begin
          if (!mem_stall) begin
            brul_target <= mem_rdata[15:0];
            state       <= S_RETIRE;
          end
        end

        S_RETIRE: begin
          // stm/stmh: bit 0 selects floating point, bits 2:1 the cfxd rounding
          // mode. Only sub-op 5 is implemented in MAME; the rest log.
          if (d_stm && d_stmsub == 3'd5) reg_m <= d_stmm;
          state <= S_FETCH;
        end

        default: state <= S_FETCH;
      endcase
    end
  end

  // ------------------------------------------------------------ datapath

  // ONCE PER ACCESS, NOT ONCE PER CYCLE. The _W states are HELD while the
  // access completes - mem_stall for data, io_ack for external - so gating the
  // post-increment on the state alone applies it on every waiting cycle. The
  // external reads in this microcode wait eight and nine cycles (the boot trace
  // prints "TGP io 2: R 8010 waited 8"), and x0 advanced by 9 and by 7 where the
  // reference advanced by 1: the wait count, not the increment.
  //
  // Same fault as the coprocessor FIFO's pop/push, which was one per cycle
  // instead of one per access. Look for this shape wherever a held state drives
  // a side effect.
  wire src_done  = !mem_stall && !(x_src_sp    == mb86233_pkg::EP_IO && !io_ack);
  wire dst_done  = !mem_stall && !(x_dst_sp    == mb86233_pkg::EP_IO && !io_ack);
  wire labb_done = !mem_stall && !(x_lab_b_sp  == mb86233_pkg::EP_IO && !io_ack);

  always_comb begin
    use_dst_side = (state == S_DST) || (state == S_DST_W);
    agu_post_en  = ((state == S_SRC_W)  && src_done)
                || ((state == S_DST_W)  && dst_done)
                || ((state == S_LABB_W) && labb_done);

    mem_req   = 1'b0; mem_we = 1'b0; mem_addr = 17'd0; mem_wdata = 32'd0;
    io_rd     = 1'b0; io_wr  = 1'b0; io_addr  = 16'd0; io_wdata  = 32'd0;
    rf_rd_addr = 6'd0; rf_wr_en = 1'b0; rf_wr_addr = 6'd0; rf_wr_data = 32'd0;
    alu_in_valid = 1'b0;
    xfer_d_valid = 1'b0; xfer_d_data = 32'd0;
    seq_valid = 1'b0; seq_stall = 1'b0;
    seq_branch_val = 16'd0; seq_is_rep = 1'b0; seq_rep_count = 8'd0;

    unique case (state)
      S_BRUL_RD, S_BRUL_W: begin
        // EA = opcode & 0x7f, MAME's ea_pre_0 mode 0. Direct data address, no AGU
        // state involved, so it does not disturb x0/b0 the way a source read would.
        mem_req  = 1'b1;
        mem_addr = {10'd0, d_bdata[6:0]};
      end

      S_SRC, S_SRC_W: begin
        // read_reg masks its argument to 6 bits, so the index is agu_r[5:0].
        // Taking only [2:0] silently reads register 0 for every target above
        // 7 — every transfer out of A (0x10), B (0x13), D (0x19) or P (0x1c)
        // read the wrong register and no directed test noticed.
        if (x_src_reg) rf_rd_addr = agu_r[5:0];
        else if (x_src_sp == mb86233_pkg::EP_DATA) begin
          mem_req = 1'b1; mem_addr = ea_src;
        end else if (x_src_sp == mb86233_pkg::EP_IO) begin
          io_rd = 1'b1; io_addr = ea_src[15:0];
        end
      end

      S_LABB, S_LABB_W: begin
        if (x_lab_b_sp == mb86233_pkg::EP_DATA) begin
          mem_req = 1'b1;
          mem_addr = agu_ea + (x_lab_b200 ? 17'h200 : 17'd0);
        end else begin
          io_rd = 1'b1; io_addr = agu_ea[15:0];
        end
      end

      S_DST, S_DST_W: begin
        if (x_dst_reg) begin
          rf_wr_en = 1'b1; rf_wr_addr = d_r2[5:0]; rf_wr_data = src_val;
        end else if (x_dst_sp == mb86233_pkg::EP_DATA) begin
          mem_req = 1'b1; mem_we = 1'b1; mem_addr = ea_dst; mem_wdata = src_val;
        end else begin
          io_wr = 1'b1; io_addr = ea_dst[15:0]; io_wdata = src_val;
        end
      end

      S_LAB_WA: begin
        rf_wr_en = 1'b1; rf_wr_addr = 6'h10; rf_wr_data = lab_a_val;  // A
      end
      S_LAB_WB: begin
        rf_wr_en = 1'b1; rf_wr_addr = 6'h13; rf_wr_data = lab_b_val;  // B
      end

      S_ALU: begin
        alu_in_valid = alu_active & ~alu_launched;
        // A transfer targeting D competes with the ALU; mb86233_alu applies the
        // priority rule, this only tells it one is present.
        xfer_d_valid = d_ldmov & x_dst_reg & (d_r2[5:0] == 6'h19);
        xfer_d_data  = src_val;
      end

      S_RETIRE: begin
        seq_valid     = 1'b1;
        seq_is_rep    = d_repgrp & (d_fsub == 3'd2);
        seq_rep_count = d_repreg ? rf_rd_data[7:0] : d_repimm;
        // brul/bsul TAKE THEIR TARGET FROM A REGISTER OR FROM DATA MEMORY, not
        // from the immediate field. This was `seq_branch_val = d_bdata` for every
        // subtype, so the register- and memory-indirect branches jumped to their
        // own immediate field instead — a computed jump turned into a constant one.
        //
        // MAME, mb86233.cpp case 1 (brul) and case 3 (bsul):
        //     if(opcode & 0x4000) { v = read_reg(opcode); }        // register
        //     else { ea = ea_pre_0(opcode); v = read_dword(ea); }  // memory
        // and read_reg masks its argument to SIX bits (`r &= 0x3f`), so the index
        // is d_bdata[5:0] — not the five the disassembler prints.
        //
        // Found by `make tgp_trace` at pc 0x0052, `brul alw d`: the microcode
        // computes d = 8 + 0x53 = 0x5b and dispatches through it, and we jumped to
        // 0x4019 — the instruction's own low half. That is the command dispatch
        // table, so nothing past it ran.
        //
        // The vr microcode has exactly one brul (0x0052, register form, reg 0x19 =
        // d) and two bsul (0x04c5 and 0x04da, both MEMORY form, addresses 0x35 and
        // 0x36). The register form is implemented here; the memory form needs a
        // data read before the branch resolves, which means another FSM state, and
        // is not built yet — see the warning below.
        if (brul_regform) begin
          rf_rd_addr     = d_bdata[5:0];
          seq_branch_val = rf_rd_data[15:0];
        end else if (brul_memform && brul_ea_simple) begin
          seq_branch_val = brul_target;
        end else begin
          seq_branch_val = d_bdata;
        end

        // Immediate-form writes all land here, after any transfer.
        if (d_ldi) begin
          rf_wr_en = 1'b1; rf_wr_addr = d_ldireg; rf_wr_data = d_ldival;
        end else if (d_lipl) begin
          rf_wr_en = 1'b1;
          unique case (d_lsel)
            2'd0: begin rf_wr_addr = 6'h1c;        // P: top byte preserved
                        rf_wr_data = {reg_p[31:24], d_lpimm}; end
            2'd1: begin rf_wr_addr = 6'h10; rf_wr_data = d_lval; end
            2'd2: begin rf_wr_addr = 6'h13; rf_wr_data = d_lval; end
            2'd3: begin rf_wr_addr = 6'h19; rf_wr_data = d_lval; end
          endcase
        end
      end

      default: ;
    endcase
  end

endmodule
