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
// That BSD-3-Clause attribution must be retained. See THIRD_PARTY.md.
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

  assign st = {seq_zc1, seq_zc0, alu_st_out[29:0]};

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

  mb86233_alu u_alu (
    .clk(clk), .rst_n(rst_n),
    .in_valid(alu_in_valid), .op(d_alu),
    .reg_a(reg_a), .reg_b(reg_b), .reg_d(reg_d), .reg_p(reg_p),
    .sft(sft), .m(reg_m), .st_in(st),
    .xfer_d_valid(xfer_d_valid), .xfer_d_data(xfer_d_data),
    // lab and ld/mov reach alu_post_2; the 0x0f group does not.
    .fp_post_en(d_lab | d_ldmov),
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
    S_ALU, S_RETIRE
  } state_e;

  state_e state;

  // The ALU runs for exactly three instruction types. MAME calls alu_pre and
  // alu_post only from cases 0x00, 0x07 and 0x0f; everywhere else the bits that
  // would be the ALU field are immediate data that merely aliases onto it.
  // Running the ALU unconditionally lets `ldi 0x19` — whose immediate puts 0x0f
  // (cfxd) in bits 25:21 — write D and destroy the value it just loaded.
  logic alu_active;
  assign alu_active = d_lab | d_ldmov | d_repgrp;

  // The ALU is fixed-latency-2 and free-running: holding in_valid across the
  // whole wait state launches a fresh operation every cycle, and their
  // writebacks land during S_RETIRE and S_FETCH, clobbering whatever the
  // instruction actually wrote. Issue exactly one.
  logic alu_launched;

  logic [31:0] src_val;          // value in flight between source and dest
  logic [31:0] lab_a_val;

  // Which side's r/bank the AGU should present this cycle.
  logic        use_dst_side;
  assign agu_r    = use_dst_side ? (x_dst_r2 ? d_r2 : d_r1)
                                 : (x_src_r2 ? d_r2 : d_r1);
  assign agu_bank = use_dst_side ? x_dst_bank : x_src_bank;

  // +0x200 is applied outside the AGU because it is per-instruction-form, not
  // an addressing mode. See mb86233_agu's header.
  logic [16:0] ea_src, ea_dst;
  assign ea_src = agu_ea + (x_src_200 ? 17'h200 : 17'd0);
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
      alu_launched <= 1'b0;
    end else begin
      unique case (state)
        S_FETCH:   state <= S_FETCH_W;
        S_FETCH_W: begin ir <= prog_rdata; state <= S_DECODE; end

        S_DECODE: begin
          if (d_lab || d_ldmov) state <= S_SRC;
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
          if (!mem_stall && !(x_lab_b_sp == mb86233_pkg::EP_IO && !io_ack))
            state <= S_ALU;
        end

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
            state        <= S_RETIRE;
            alu_launched <= 1'b0;
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

  always_comb begin
    use_dst_side = (state == S_DST) || (state == S_DST_W);
    agu_post_en  = (state == S_SRC_W) || (state == S_DST_W) || (state == S_LABB_W);

    mem_req   = 1'b0; mem_we = 1'b0; mem_addr = 17'd0; mem_wdata = 32'd0;
    io_rd     = 1'b0; io_wr  = 1'b0; io_addr  = 16'd0; io_wdata  = 32'd0;
    rf_rd_addr = 6'd0; rf_wr_en = 1'b0; rf_wr_addr = 6'd0; rf_wr_data = 32'd0;
    alu_in_valid = 1'b0;
    xfer_d_valid = 1'b0; xfer_d_data = 32'd0;
    seq_valid = 1'b0; seq_stall = 1'b0;
    seq_branch_val = 16'd0; seq_is_rep = 1'b0; seq_rep_count = 8'd0;

    unique case (state)
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
        seq_branch_val = d_bdata;

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
