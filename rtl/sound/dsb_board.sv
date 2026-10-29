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
// STAR WARS ARCADE'S DIGITAL SOUND BOARD (Sega DSB, MAME dsbz80.cpp).
//
// A Z80 at 4 MHz running epr-16471.2 (first 32 KB at 0000-7fff, 32 KB of RAM
// at 8000-ffff), an i8251 at f0/f1 that receives what the SOUND 68000
// transmits, and an MPEG-1 Layer II player behind ports e0-e9 with 4 MB of
// MPEG data. Star Wars is the only Model 1 game that has one; it carries the
// music. See docs/findings.md, 2026-10-28 (c).
//
//   dsb_z80   the Z80, cut down to the 76 opcodes its program uses
//   m2_i8251  the UART, byte-level, the same model as the sound board's
//   dsb_mpeg  ports e0-e9 and the decoder
//
// Everything bulky lives in SDRAM through ONE port: the Z80's ROM and RAM and
// the MPEG data. The Z80 sees them through a one-word cache (it reads two
// bytes from every word it fetches) and simply waits; its T clock keeps
// running and it catches up, so its I/O lands at the right T-time regardless
// (see dsb_z80).
//
// clk is clk_cpu (560/19 MHz). The Z80's T clock is 4 MHz from it, exactly:
// 19/140 of clk.

`timescale 1ns/1ps

module dsb_board #(
  parameter logic [25:1] ROM_BASE  = 25'h1480000,   // 128 KB, words
  parameter logic [25:1] MPEG_BASE = 25'h1490000,   // 4 MB
  parameter logic [25:1] RAM_BASE  = 25'h1690000,   // 32 KB
  parameter int unsigned T_NUM = 19,
  parameter int unsigned T_DEN = 140
) (
  input  logic        clk,
  input  logic        rst_n,

  // the sound 68000's transmitted bytes, already paced at the line rate,
  // announced by a toggle from another clock
  input  logic        rx_tog,
  input  logic  [7:0] rx_byte,

  input  logic        vol_mame,

  // one SDRAM port (through m1_cdc_port): a one-cycle request, one ack
  output logic        s_req,
  output logic        s_we,
  output logic [25:1] s_addr,
  output logic [15:0] s_din,
  output logic  [1:0] s_be,
  input  logic        s_ack,
  input  logic [15:0] s_dout,

  output logic signed [15:0] out_l,
  output logic signed [15:0] out_r,
  output logic        out_stb,

  output logic        dbg_trap,
  output logic [15:0] dbg_frames
);

  // ---------------------------------------------------------------- T clock
  logic [7:0] t_acc;
  logic       tick;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin t_acc <= '0; tick <= 1'b0; end
    else if (t_acc + 8'(T_NUM) >= 8'(T_DEN)) begin t_acc <= t_acc + 8'(T_NUM) - 8'(T_DEN); tick <= 1'b1; end
    else begin t_acc <= t_acc + 8'(T_NUM); tick <= 1'b0; end
  end

  // ---------------------------------------------------------------- Z80
  logic        z_req, z_we, z_ack;
  logic [15:0] z_addr;
  logic  [7:0] z_wdata, z_rdata;
  logic        io_rd, io_wr;
  logic  [7:0] io_addr, io_wdata, io_rdata;

  logic pre_done;
  dsb_z80 u_z80 (
    .clk(clk), .rst_n(rst_n && pre_done), .tick(tick),
    .m_req(z_req), .m_we(z_we), .m_addr(z_addr), .m_wdata(z_wdata),
    .m_ack(z_ack), .m_rdata(z_rdata),
    .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_wdata(io_wdata),
    .io_rdata(io_rdata),
    .trap(dbg_trap), .trap_pc(), .trap_cnt(), .dbg_pc()
  );

  // ---------------------------------------------------------------- UART
  logic       rx_s1, rx_s2, rx_s3, rx_valid, rx_ack;
  logic [7:0] u_dout;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin {rx_s3, rx_s2, rx_s1} <= '0; rx_valid <= 1'b0; end
    else begin
      {rx_s3, rx_s2, rx_s1} <= {rx_s2, rx_s1, rx_tog};
      // rx_byte has been stable for a character time when the toggle lands
      if (rx_s2 ^ rx_s3) rx_valid <= 1'b1;
      else if (rx_ack)   rx_valid <= 1'b0;
    end
  end
  // read data is decoded from the address alone: dsb_z80 samples io_rdata the
  // cycle BEFORE its io_rd strobe, which is when the read's side effect lands
  wire u_adr = (io_addr[7:1] == 7'b1111000);
  wire u_sel = (io_rd || io_wr) && u_adr;
  m2_i8251 u_uart (
    .clk(clk), .rst_n(rst_n),
    .sel(u_sel), .we(io_wr), .addr(io_addr[0]), .din(io_wdata), .dout(u_dout),
    .data_o(), .stat_o(),
    .tx_data(), .tx_valid(), .tx_ack(1'b1),        // the DSB transmits nothing
    .rx_data(rx_byte), .rx_valid(rx_valid), .rx_ack(rx_ack),
    .irq(), .irq_rx(), .irq_tx()
  );

  // ---------------------------------------------------------------- MPEG
  logic        mp_req, mp_ack;
  logic [20:0] mp_addr;
  logic  [7:0] mp_q;
  wire         mp_sel = io_addr[7:4] == 4'he;
  dsb_mpeg u_mpeg (
    .clk(clk), .rst_n(rst_n),
    .reg_we(io_wr && mp_sel), .reg_a(io_addr[3:0]), .reg_d(io_wdata), .reg_q(mp_q),
    .vol_mame(vol_mame),
    .m_req(mp_req), .m_addr(mp_addr), .m_ack(mp_ack), .m_data(s_dout),
    .out_l(out_l), .out_r(out_r), .out_stb(out_stb), .out_src(),
    .smp_stb(), .smp_lr(), .dbg_frames(dbg_frames), .dbg_fails()
  );

  // unmapped ports read 0, as MAME's Z80 io space does
  assign io_rdata = u_adr ? u_dout : mp_sel ? mp_q : 8'h00;

  // ---------------------------------------------------------------- memory
  // THE Z80 ALMOST NEVER TOUCHES SDRAM. Measured on the bench, a Z80 whose
  // every access went to SDRAM through a one-word cache asked for 755,000
  // words a second -- about a tenth of the controller's time, on a memory
  // the V60 already waits for. So the parts it lives in are on chip:
  //
  //   0000-07ff  a copy of the program (code ends at 03d4, the song table
  //              at 04d6), loaded from SDRAM before the Z80 is released
  //   8000-83ff  its variables (8100-8126, 8200, 8300)
  //   fc00-ffff  its stack (SP starts at fffe)
  //
  // and everything else -- the rest of the 128 KB ROM, the rest of the 32 KB
  // RAM -- stays in SDRAM behind the one-word cache, reached in practice only
  // by the boot-time clear. It is the same memory map, split by address, so
  // nothing the program can observe changes.
  wire z_prog = !z_addr[15] && (z_addr[14:11] == 4'd0);
  wire z_fast =  z_addr[15] && (z_addr[14:10] == 5'b00000 || z_addr[14:10] == 5'b11111);
  wire z_chip = z_prog || z_fast;

  (* ramstyle = "M10K" *) logic [15:0] prog [1024];
  (* ramstyle = "M10K" *) logic  [7:0] fast [2048];
  logic [15:0] prog_q;
  logic  [7:0] fast_q;
  logic  [9:0] pre_i;
  logic        pre_we;
  logic [15:0] pre_d;
  always_ff @(posedge clk) begin
    if (pre_we) prog[pre_i] <= pre_d;
    prog_q <= prog[z_addr[10:1]];
  end
  wire        fast_we = z_req && z_we && z_fast && !z_ack_r && pre_done;
  always_ff @(posedge clk) begin
    if (fast_we) fast[{z_addr[14], z_addr[9:0]}] <= z_wdata;
    fast_q <= fast[{z_addr[14], z_addr[9:0]}];
  end

  // The one-word cache for the rest: the last word read or written. Writes go
  // straight through and update it.
  logic        c_valid;
  logic [15:1] c_tag;
  logic [15:0] c_word;
  wire         c_hit = c_valid && (c_tag == z_addr[15:1]);

  typedef enum logic [1:0] {M_IDLE, M_Z, M_MP, M_PRE} mown_t;
  mown_t own;
  logic  z_ack_r;
  logic  [1:0] z_src;                // 0 cache, 1 program copy, 2 fast RAM
  assign z_ack   = z_ack_r;
  assign z_rdata = (z_src == 2'd1) ? (z_addr[0] ? prog_q[15:8] : prog_q[7:0]) :
                   (z_src == 2'd2) ? fast_q :
                   (z_addr[0] ? c_word[15:8] : c_word[7:0]);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      own <= M_PRE; s_req <= 1'b0; s_we <= 1'b0; s_addr <= '0; s_din <= '0; s_be <= '0;
      c_valid <= 1'b0; c_tag <= '0; c_word <= '0; z_ack_r <= 1'b0; mp_ack <= 1'b0;
      z_src <= 2'd0; pre_done <= 1'b0; pre_i <= '0; pre_we <= 1'b0; pre_d <= '0;
    end else begin
      s_req <= 1'b0; z_ack_r <= 1'b0; mp_ack <= 1'b0; pre_we <= 1'b0;

      // on-chip: answered the next cycle, whatever SDRAM is doing (a write
      // to the program copy is dropped, as MAME's ROM drops it)
      if (pre_done && z_req && z_chip && !z_ack_r) begin
        z_ack_r <= 1'b1; z_src <= z_prog ? 2'd1 : 2'd2;
      end

      case (own)
        // the program copy: 1,024 words from the ROM's base, once
        M_PRE: begin
          if (!s_req && !pre_we && !pre_done) begin
            s_req <= 1'b1; s_we <= 1'b0; s_be <= 2'b11;
            s_addr <= ROM_BASE + 25'(pre_i);
            own <= M_Z;              // shares M_Z's wait; told apart by !pre_done
          end
        end
        M_IDLE: begin
          if (z_req && !z_ack_r && !z_chip) begin
            if (!z_we && c_hit) begin z_ack_r <= 1'b1; z_src <= 2'd0; end   // cached
            else begin
              own <= M_Z; s_req <= 1'b1; s_we <= z_we;
              s_addr <= (z_addr[15] ? RAM_BASE : ROM_BASE) + 25'(z_addr[14:1]);
              s_din  <= {z_wdata, z_wdata};
              s_be   <= z_we ? {z_addr[0], !z_addr[0]} : 2'b11;
            end
          end else if (mp_req && !mp_ack) begin
            own <= M_MP; s_req <= 1'b1; s_we <= 1'b0; s_be <= 2'b11;
            s_addr <= MPEG_BASE + 25'(mp_addr);
          end
        end
        M_Z: if (s_ack) begin
          if (!pre_done) begin
            pre_we <= 1'b1; pre_d <= s_dout;
            own <= M_PRE;
          end else begin
            own <= M_IDLE; z_ack_r <= 1'b1; z_src <= 2'd0;
            if (!s_we) begin c_valid <= 1'b1; c_tag <= z_addr[15:1]; c_word <= s_dout; end
            else if (c_hit) begin
              if (z_addr[0]) c_word[15:8] <= z_wdata; else c_word[7:0] <= z_wdata;
            end
          end
        end
        default: if (s_ack) begin own <= M_IDLE; mp_ack <= 1'b1; end   // M_MP
      endcase

      // the preload's write lands the cycle after its data; then the next word
      if (pre_we) begin
        if (pre_i == 10'd1023) begin pre_done <= 1'b1; own <= M_IDLE; end
        pre_i <= pre_i + 10'd1;
      end
    end
  end

endmodule
