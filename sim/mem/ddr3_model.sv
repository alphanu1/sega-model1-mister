// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The MiSTer framework's DDRAM port as a behavioural model, for the SV
// benches (tb_m1_frame). The C++ benches use sim/mem/ddr3_model.h, which is
// the same model with the same rules.
//
// LATENCY cycles from an accepted read to its first beat, replies in order,
// BUSY asserted at random in runs (BUSY_PERMILLE of idle cycles start one), and
// unwritten memory reads all ones - never zero, so a read of something never
// written cannot pass for data. Avalon rules are checked every cycle and
// violations counted in `protocol_errs`.
//
// Simulation only.

`timescale 1ns/1ps

module ddr3_model #(
  parameter int LATENCY      = 40,
  parameter int BUSY_PERMILLE = 0,
  parameter int BUSY_MAX     = 24
) (
  input  logic        clk,
  output logic        busy,
  input  logic [7:0]  burstcnt,
  input  logic [28:0] addr,
  output logic [63:0] dout,
  output logic        dout_ready,
  input  logic        rd,
  input  logic [63:0] din,
  input  logic [7:0]  be,
  input  logic        we
);
  logic [63:0] mem [logic [28:0]];
  typedef struct { longint due; logic [63:0] data; } reply_t;
  reply_t q [$];
  longint cyc = 0, protocol_errs = 0, reads = 0, writes = 0;
  int busy_run = 0, wr_left = 0;
  logic [28:0] wr_addr;
  logic p_busy = 0, p_rd = 0, p_we = 0;
  logic [28:0] p_addr; logic [7:0] p_bc; logic [63:0] p_din;
  int unsigned seed = 32'd12345;

  initial begin busy = 0; dout = '0; dout_ready = 0; end

  always @(posedge clk) begin
    // the command presented during the cycle that ends at this edge
    if (rd && we) begin protocol_errs++; $display("DDR3 PROTOCOL: RD and WE together"); end
    if ((rd || we) && be == 8'h00) begin protocol_errs++; $display("DDR3 PROTOCOL: BE = 0"); end
    if (p_busy && (p_rd || p_we) &&
        (rd != p_rd || we != p_we || addr != p_addr || burstcnt != p_bc || (we && din != p_din))) begin
      protocol_errs++; $display("DDR3 PROTOCOL: command changed while BUSY");
    end
    if (!busy) begin
      if (we) begin
        if (wr_left == 0) begin wr_addr = addr; wr_left = burstcnt; writes++; end
        mem[wr_addr] = din; wr_addr++; wr_left--;
      end
      if (rd) begin
        longint t = cyc + LATENCY;
        if (wr_left != 0) begin protocol_errs++; $display("DDR3 PROTOCOL: read inside a write burst"); end
        if (q.size() != 0 && q[$].due >= t) t = q[$].due + 1;
        for (int b = 0; b < burstcnt; b++)
          q.push_back('{t + b, mem.exists(addr + 29'(b)) ? mem[addr + 29'(b)] : '1});
        reads++;
      end
    end
    p_busy <= busy; p_rd <= rd; p_we <= we; p_addr <= addr; p_bc <= burstcnt; p_din <= din;

    // what is presented for the next cycle
    dout_ready <= 1'b0;
    if (q.size() != 0 && q[0].due <= cyc) begin
      dout <= q[0].data; dout_ready <= 1'b1; void'(q.pop_front());
    end
    if (BUSY_PERMILLE > 0) begin
      seed = seed * 32'd1103515245 + 32'd12345;
      if (busy_run > 0) busy_run--;
      else if (((seed >> 16) % 1000) < BUSY_PERMILLE) busy_run = 1 + ((seed >> 4) % BUSY_MAX);
      busy <= (busy_run > 0);
    end
    cyc++;
  end
endmodule
