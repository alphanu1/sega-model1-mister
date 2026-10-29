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
// THE DSB'S Z80, CUT DOWN TO ITS PROGRAM.
//
// Star Wars' Digital Sound Board runs epr-16471.2, 725 bytes of code. Traced
// statically from the reset and interrupt vectors (tools/dsb/z80_census.py)
// it reaches 391 instructions of 76 distinct opcodes: no IX/IY, no EXX or
// EX AF, no IM 2, no R register, no data-dependent jump, and interrupts that
// can never be taken (IFF is 0 from reset and the only EI is inside the IM 1
// handler). swa and swaj carry the same ROM. This executes exactly those 76;
// anything else TRAPS -- counted, its PC kept, run as a no-op of 4 or 8 T.
//
// MICROCODED. A regular datapath -- seven 8-bit registers, PC, SP, a 16-bit
// TMP, one 16-bit address adder, one 8-bit ALU -- is driven by 130 40-bit
// micro-ops in one M10K (tools/dsb/gen_z80_ucode.py writes them). A
// per-opcode state machine was tried first and came out at 1,543 ALM against
// tv80s's 956, because every opcode grew its own path into every register.
//
// What the rest of the board can see is preserved exactly:
//   - every instruction takes the Z80's documented T-states (taken and
//     untaken branches, LDIR per iteration), carried on the micro-op that
//     ends it, so the firmware's loops, fades and delays run at real speed;
//   - every I/O access lands at the T-state at which tv80s commits it.
// Only Z and C exist, the only flags the program reads.
//
// TIMING. `ahead` is how far the core's T-time is ahead of real T-time: an
// instruction adds its T-states, each `tick` takes one away. Fetching waits
// while the core is ahead, and an I/O access waits until real time reaches
// it, so SDRAM latency never moves an I/O event; a stall only makes the core
// run back to back until it has caught up.

`timescale 1ns/1ps

module dsb_z80 (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        tick,          // one real T-state

  // memory, byte-wide, request held until ack
  output logic        m_req,
  output logic        m_we,
  output logic [15:0] m_addr,
  output logic  [7:0] m_wdata,
  input  logic        m_ack,
  input  logic  [7:0] m_rdata,

  // I/O, one-cycle strobes at the real T-time
  output logic        io_rd,
  output logic        io_wr,
  output logic  [7:0] io_addr,
  output logic  [7:0] io_wdata,
  input  logic  [7:0] io_rdata,

  output logic        trap,          // an opcode outside the census was executed
  output logic [15:0] trap_pc,
  output logic [15:0] trap_cnt,
  output logic [15:0] dbg_pc
);

`include "dsb_z80_ucode.svh"

  // ---------------------------------------------------------------- state
  logic [7:0]  R [8];                // B C D E H L - A, by Z80 register number
  logic        fZ, fC;
  logic [15:0] PC, SP, TMP;
  logic [7:0]  IR, dat;
  logic [1:0]  pfx;
  logic signed [11:0] ahead;

  typedef enum logic [2:0] {S_FETCH, S_FWAIT, S_DISP, S_RUN, S_IO} st_t;
  st_t st;

  // ---------------------------------------------------------------- micro-op
  logic [7:0]    upc, upc_n;
  logic [UW-1:0] uw;
  always_ff @(posedge clk) uw <= urom[upc_n];
  logic [7:0] ent_q;
  always_ff @(posedge clk) ent_q <= uent[{pfx, m_rdata}];   // valid in S_DISP

  wire [1:0] f_mem  = uw[39:38];
  wire [2:0] f_asrc = uw[37:35];
  wire [2:0] f_aoff = uw[34:32];
  wire [2:0] f_awb  = uw[31:29];
  wire [1:0] f_wsrc = uw[28:27];
  wire [2:0] f_rmod = uw[26:24];
  wire [2:0] f_ridx = uw[23:21];
  wire       f_rsrc = uw[20];
  wire [3:0] f_alu  = uw[19:16];
  wire [1:0] f_ysel = uw[15:14];
  wire       f_fz   = uw[13];
  wire       f_fc   = uw[12];
  wire [1:0] f_nxt  = uw[11:10];
  wire [1:0] f_csel = uw[9:8];
  wire [2:0] f_io   = uw[7:5];
  wire [4:0] f_tst  = uw[4:0];

  wire [15:0] BC = {R[0], R[1]}, DE = {R[2], R[3]}, HL = {R[4], R[5]};

  // ---------------------------------------------------------------- AGU
  logic [15:0] abase, aoffv;
  always_comb begin
    case (f_asrc)
      3'd0: abase = PC;  3'd1: abase = SP;  3'd2: abase = BC;
      3'd3: abase = DE;  3'd4: abase = HL;  default: abase = TMP;
    endcase
    case (f_aoff)
      3'd0: aoffv = 16'h0000; 3'd1: aoffv = 16'h0001; 3'd2: aoffv = 16'hffff;
      3'd3: aoffv = 16'hfffe; 3'd4: aoffv = 16'h0002; 3'd5: aoffv = {{8{dat[7]}}, dat};
      3'd6: aoffv = BC;       default: aoffv = HL;
    endcase
  end
  wire [16:0] asum = {1'b0, abase} + {1'b0, aoffv};
  // post-increment (read at the base, write back base+1) vs offset address
  wire        a_post = (f_awb != 3'd0) && (f_aoff == 3'd1);
  wire [15:0] maddr  = a_post ? abase : asum[15:0];

  // ---------------------------------------------------------------- ALU
  wire        is_rd = (f_mem == 2'd1);
  wire [7:0]  din   = is_rd ? m_rdata : dat;        // a read's data, on its ack
  logic [7:0] Y;
  always_comb begin
    case (f_ysel)
      2'd0: Y = R[IR[2:0]];
      2'd1: Y = R[IR[5:3]];
      2'd2: Y = din;
      default: Y = R[0];
    endcase
  end
  logic [3:0] aop;
  always_comb begin
    aop = f_alu;
    if (f_alu == 4'd1)       // the 8-bit ALU group, by IR[5:3]: add / and / xor / or / cp
      case (IR[5:3])
        3'd4: aop = 4'd3; 3'd5: aop = 4'd4; 3'd6: aop = 4'd5; 3'd7: aop = 4'd6;
        default: aop = 4'd2;
      endcase
  end
  logic [7:0] alu_r; logic alu_c;
  logic [8:0] alu_s;
  always_comb begin
    alu_c = 1'b0; alu_r = Y; alu_s = 9'd0;
    case (aop)
      4'd2:  begin alu_s = {1'b0, R[7]} + {1'b0, Y}; alu_r = alu_s[7:0]; alu_c = alu_s[8]; end
      4'd3:  alu_r = R[7] & Y;
      4'd4:  alu_r = R[7] ^ Y;
      4'd5:  alu_r = R[7] | Y;
      4'd6:  begin alu_s = {1'b0, R[7]} - {1'b0, Y}; alu_r = R[7]; alu_c = alu_s[8]; end
      4'd7:  alu_r = Y + 8'd1;
      4'd8:  alu_r = Y - 8'd1;
      4'd9:  begin alu_r = {Y[6:0], Y[7]}; alu_c = Y[7]; end
      4'd10: begin alu_r = {Y[6:0], 1'b0}; alu_c = Y[7]; end
      4'd12: alu_c = asum[16];
      default: ;
    endcase
  end
  // Z: from the ALU result, except cp (from the difference) and bit
  wire alu_z = (aop == 4'd6)  ? (R[7] == Y) :
               (aop == 4'd11) ? !Y[IR[5:3]] : (alu_r == 8'd0);

  // ---------------------------------------------------------------- conditions
  wire [2:0] cc   = IR[7] ? IR[5:3] : {1'b0, IR[4:3]};
  wire       ccv  = cc[1] ? (fC ^ !cc[0]) : (fZ ^ !cc[0]);
  logic      cond;
  always_comb begin
    case (f_csel)
      2'd0: cond = ccv;
      2'd1: cond = (R[0] != 8'd0);
      2'd2: cond = (BC != 16'd0);
      default: cond = 1'b1;
    endcase
  end

  // ---------------------------------------------------------------- sequencing
  // A micro-op completes when its memory access (if any) is acknowledged; an
  // I/O micro-op completes in S_IO.
  wire u_done = (st == S_RUN) && (f_io == 3'd0) && ((f_mem == 2'd0) || m_ack);
  wire u_end  = (f_nxt == 2'd1) || (f_nxt == 2'd3) || (f_nxt == 2'd2 && !cond);
  wire pfx_byte = (pfx == 2'd0) && (m_rdata == 8'hcb || m_rdata == 8'hed);

  always_comb begin
    upc_n = upc;
    if (st == S_DISP)                        upc_n = ent_q;
    else if (u_done && !u_end)               upc_n = upc + 8'd1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 8; i++) R[i] <= (i == 7) ? 8'hff : 8'h00;
      fZ <= 1'b1; fC <= 1'b1;
      PC <= '0; SP <= 16'hffff; TMP <= '0; IR <= '0; dat <= '0; pfx <= '0;
      ahead <= '0; st <= S_FETCH; upc <= '0;
      m_req <= 1'b0; m_we <= 1'b0; m_addr <= '0; m_wdata <= '0;
      io_rd <= 1'b0; io_wr <= 1'b0; io_addr <= '0; io_wdata <= '0;
      trap <= 1'b0; trap_pc <= '0; trap_cnt <= '0;
    end else begin
      logic signed [11:0] addT;
      logic [7:0] wv;
      addT = 12'sd0;
      io_rd <= 1'b0; io_wr <= 1'b0;
      upc <= upc_n;
      if (m_ack) m_req <= 1'b0;

      case (st)
        S_FETCH: if (ahead <= 12'sd32) begin
          m_req <= 1'b1; m_we <= 1'b0; m_addr <= PC; st <= S_FWAIT;
        end
        S_FWAIT: if (m_ack) begin
          PC <= PC + 16'd1;
          if (pfx_byte) begin
            pfx <= (m_rdata == 8'hcb) ? 2'd1 : 2'd2;
            m_req <= 1'b1; m_addr <= PC + 16'd1;           // the second opcode byte
          end else begin
            IR <= m_rdata; st <= S_DISP;
          end
        end

        S_DISP: st <= S_RUN;

        S_RUN: begin
          // issue this micro-op's memory access once
          if (f_mem != 2'd0 && !m_req && !m_ack) begin
            m_req <= 1'b1; m_we <= (f_mem == 2'd2); m_addr <= maddr;
            case (f_wsrc)
              2'd0: m_wdata <= R[f_ridx];
              2'd1: m_wdata <= PC[15:8];
              2'd2: m_wdata <= PC[7:0];
              default: m_wdata <= alu_r;
            endcase
          end
          if (f_io != 3'd0) begin
            // charge the instruction's T-states, then wait for real time
            addT = 12'(f_tst);
            case (f_io)
              3'd1: begin io_addr <= dat;  io_wdata <= R[7]; end
              3'd2: begin io_addr <= R[1]; io_wdata <= R[7]; end
              3'd3: begin io_addr <= R[1]; io_wdata <= dat;  end
              default: io_addr <= dat;
            endcase
            st <= S_IO;
          end
          if (u_done) begin
            if (is_rd) dat <= m_rdata;
            // 8-bit register write
            wv = f_rsrc ? alu_r : din;
            case (f_rmod)
              3'd1: R[IR[5:3]] <= wv;
              3'd2: R[IR[2:0]] <= wv;
              3'd3: R[f_ridx]  <= wv;
              3'd4: TMP[7:0]   <= wv;
              3'd5: TMP[15:8]  <= wv;
              default: ;
            endcase
            // 16-bit write back from the address adder
            case (f_awb)
              3'd1: PC <= asum[15:0];
              3'd2: SP <= asum[15:0];
              3'd3: {R[0], R[1]} <= asum[15:0];
              3'd4: {R[2], R[3]} <= asum[15:0];
              3'd5: {R[4], R[5]} <= asum[15:0];
              3'd6: TMP <= asum[15:0];
              default: ;
            endcase
            if (f_fz) fZ <= alu_z;
            if (f_fc) fC <= alu_c;
            if (u_end) begin
              addT = 12'(f_tst);
              pfx <= 2'd0; st <= S_FETCH;
              if (f_nxt == 2'd3) begin
                trap <= 1'b1; trap_pc <= PC;
                if (trap_cnt != 16'hffff) trap_cnt <= trap_cnt + 16'd1;
              end
            end
          end
        end

        // the strobe a real Z80 (and tv80s) ends one T before the instruction does
        S_IO: if (ahead <= 12'sd1) begin
          if (f_io == 3'd4) begin io_rd <= 1'b1; R[7] <= io_rdata; end
          else io_wr <= 1'b1;
          pfx <= 2'd0; st <= S_FETCH;
        end
        default: st <= S_FETCH;
      endcase
      // one T of real time per tick (floored, so a long stall cannot wrap)
      ahead <= ahead + addT - ((tick && ahead > -12'sd2000) ? 12'sd1 : 12'sd0);
    end
  end

  assign dbg_pc = PC;

endmodule
