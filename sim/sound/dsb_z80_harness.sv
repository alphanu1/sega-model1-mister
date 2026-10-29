// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// dsb_z80 and a full tv80s side by side on the same ROM, the same T clock and
// the same UART bytes, each with its own RAM and its own UART. tv80s is the
// reference for what a Z80 does with this program; the bench compares every
// port access of the two, value and T-state.
`timescale 1ns/1ps
module dsb_z80_harness (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        tick,
  input  logic        rx_stb,        // a byte arrives at both UARTs
  input  logic  [7:0] rx_byte,
  input  logic  [7:0] lat,           // dsb_z80 memory latency, cycles
  // tv80s port accesses (commit edge)
  output logic        t_wr, t_rd,
  output logic  [7:0] t_port, t_data,
  // dsb_z80 port accesses
  output logic        c_wr, c_rd,
  output logic  [7:0] c_port, c_data,
  output logic        trap,
  output logic [15:0] trap_cnt, trap_pc, c_pc
);
  // ---------------------------------------------------------- shared ROM
  logic [7:0] rom [32768];
  initial $readmemh("build/rom/dsb/epr-16471.hex", rom);   // tools/dsb/prepare.sh

  // ---------------------------------------------------------- UART model
  // status {DSR, 0, FE OE PE = 0, TXEMPTY, RXRDY, TXRDY}, as m2_i8251
  logic t_rxrdy, c_rxrdy; logic [7:0] t_rxd, c_rxd;

  // ---------------------------------------------------------- tv80s
  logic [15:0] A; logic [7:0] di, dout;
  logic mreq_n, iorq_n, rd_n, wr_n, m1_n;
  logic [7:0] tram [32768];
  tv80s u_ref (
    .reset_n(rst_n), .clk(clk), .cen(tick),
    .wait_n(1'b1), .int_n(1'b1), .nmi_n(1'b1), .busrq_n(1'b1),
    .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
    .rfsh_n(), .halt_n(), .busak_n(), .A(A), .di(di), .dout(dout));
  wire io_rd_l = !iorq_n && !rd_n && m1_n;
  wire io_wr_l = !iorq_n && !wr_n && m1_n;
  wire mem_wr  = !mreq_n && !wr_n;
  // tv80s latches di during T2, by which point it may already have lifted
  // rd_n: hold the I/O data until the next memory cycle begins.
  logic io_hold;
  always_ff @(posedge clk) begin
    if (!rst_n || !mreq_n) io_hold <= 1'b0;
    else if (io_rd_l)      io_hold <= 1'b1;
  end
  always_comb begin
    if (io_rd_l || io_hold) di = (A[7:0] == 8'hf1) ? {5'b10000, 1'b1, t_rxrdy, 1'b1} :
                      (A[7:0] == 8'hf0) ? t_rxd : 8'h00;
    else         di = A[15] ? tram[A[14:0]] : rom[A[14:0]];
  end
  logic io_rd_d, io_wr_d, mem_wr_d; logic [15:0] aw; logic [7:0] dw;
  always_ff @(posedge clk) begin
    io_rd_d <= io_rd_l; io_wr_d <= io_wr_l; mem_wr_d <= mem_wr;
    if (io_wr_l || mem_wr) begin aw <= A; dw <= dout; end
    if (io_rd_l) begin aw <= A; end
  end
  // commit on the trailing edge, as m1_ioz80 does
  assign t_wr = io_wr_d && !io_wr_l;
  assign t_rd = io_rd_d && !io_rd_l;
  assign t_port = aw[7:0];
  assign t_data = t_wr ? dw : (aw[7:0] == 8'hf1 ? {5'b10000, 1'b1, t_rxrdy, 1'b1} : t_rxd);
  always_ff @(posedge clk) begin
    if (mem_wr_d && !mem_wr && aw[15]) tram[aw[14:0]] <= dw;
    if (!rst_n) t_rxrdy <= 1'b0;
    else begin
      if (rx_stb) begin t_rxrdy <= 1'b1; t_rxd <= rx_byte; end
      else if (t_rd && aw[7:0] == 8'hf0) t_rxrdy <= 1'b0;
    end
  end

  // ---------------------------------------------------------- dsb_z80
  logic m_req, m_we, m_ack; logic [15:0] m_addr; logic [7:0] m_wdata, m_rdata;
  logic [7:0] cram [32768];
  logic io_rd, io_wr; logic [7:0] io_addr, io_wdata, io_rdata;
  dsb_z80 u_cut (
    .clk(clk), .rst_n(rst_n), .tick(tick),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_ack(m_ack), .m_rdata(m_rdata),
    .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_wdata(io_wdata), .io_rdata(io_rdata),
    .trap(trap), .trap_pc(trap_pc), .trap_cnt(trap_cnt), .dbg_pc(c_pc));
  logic [7:0] cnt; logic busy;
  always_ff @(posedge clk) begin
    m_ack <= 1'b0;
    if (!rst_n) begin busy <= 1'b0; cnt <= '0; end
    else if (!busy && m_req && !m_ack) begin busy <= 1'b1; cnt <= lat; end
    else if (busy) begin
      if (cnt == 0) begin
        busy <= 1'b0; m_ack <= 1'b1;
        if (m_we) begin if (m_addr[15]) cram[m_addr[14:0]] <= m_wdata; end
        else m_rdata <= m_addr[15] ? cram[m_addr[14:0]] : rom[m_addr[14:0]];
      end else cnt <= cnt - 8'd1;
    end
  end
  assign io_rdata = (io_addr == 8'hf1) ? {5'b10000, 1'b1, c_rxrdy, 1'b1} : (io_addr == 8'hf0) ? c_rxd : 8'h00;
  assign c_wr = io_wr; assign c_rd = io_rd; assign c_port = io_addr;
  assign c_data = io_wr ? io_wdata : io_rdata;
  always_ff @(posedge clk) begin
    if (!rst_n) c_rxrdy <= 1'b0;
    else begin
      if (rx_stb) begin c_rxrdy <= 1'b1; c_rxd <= rx_byte; end
      else if (io_rd && io_addr == 8'hf0) c_rxrdy <= 1'b0;
    end
  end
endmodule
