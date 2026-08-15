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
// V60 instruction-fetch port to SDRAM burst port.
//
// This existed only inside sim/top/tb_m1_boot.sv until now, which meant every
// consumer implemented its own copy and none of them was tested. Same shape of
// problem as the I/O responder: a working experiment standing in for a module.
//
// WHAT IT HAS TO RECONCILE
//
// The V60 side is a LEVEL. `if_req` goes high and stays high until the line
// comes back; `if_ack` must then stay high until `if_req` drops, because the
// core is clock-enabled and a pulse narrower than its enable is simply not
// seen. That is the failure that cost this project two debugging sessions, once
// on m1_main's bus and once on this very bridge — both times it looked like a
// dead CPU rather than a handshake fault.
//
// The memory side is an EDGE. m1_sdram takes one transaction per `p_req` rising
// edge and samples the address there.
//
// And the two are now in different clock domains, so the crossing itself is
// m1_cdc_port rather than being reimplemented here.
//
// THE SHIFT
//
// The V60 asks for eight bytes starting at an arbitrary byte address, but the
// burst port can only fetch a line aligned to it. m1_main therefore emits the
// aligned address on if_sdram_addr and the byte offset separately, and the line
// that comes back has to be rotated down so byte zero is the byte the core
// actually asked for. Feeding the burst port the unaligned address instead is a
// silent failure — the fetch reads whatever lives at the wrong address, the CPU
// executes it, and with an erased region that decodes as a stream of HALT. It
// looks exactly like a CPU that will not start.
module m1_fetch_bridge (
  // ---------------------------------------------------------- V60, slow domain
  input  logic        cpu_clk,
  input  logic        cpu_rst_n,
  input  logic        if_req,          // level, held until if_ack
  input  logic [2:0]  if_off,          // byte offset of the wanted byte in the line
  input  logic [24:1] if_sdram_addr,   // burst-aligned line address
  output logic [63:0] if_data,
  output logic        if_ack,          // held until if_req drops

  // ------------------------------------------------------- memory, fast domain
  input  logic        mem_clk,
  input  logic        mem_rst_n,
  output logic        p_req,           // one-cycle pulse
  output logic [24:1] p_addr,
  input  logic [63:0] p_dout,
  input  logic        p_ack
);

  logic        c_req;
  logic [63:0] c_dout;
  logic        c_ack, c_busy;

  // The fetch port never writes, so the crossing's write side is tied off and
  // its outputs land here rather than being left dangling — an unconnected pin
  // is a lint error and, worse, hides a genuine wiring mistake in the noise.
  logic        unused_we, unused_be;
  logic [63:0] unused_din;
  logic        pending, served;
  logic [2:0]  off_q;

  // The crossing is the same two-phase handshake the data port uses; only the
  // width and the absence of a write side differ.
  m1_cdc_port #(.AW(24), .DW(64), .BEW(1)) u_cdc (
    .a_clk   (cpu_clk),
    .a_rst_n (cpu_rst_n),
    .a_req   (c_req),
    .a_we    (1'b0),
    .a_addr  (if_sdram_addr),
    .a_din   (64'd0),
    .a_be    (1'b0),
    .a_dout  (c_dout),
    .a_ack   (c_ack),
    .a_busy  (c_busy),

    .b_clk   (mem_clk),
    .b_rst_n (mem_rst_n),
    .b_req   (p_req),
    .b_we    (unused_we),
    .b_addr  (p_addr),
    .b_din   (unused_din),
    .b_be    (unused_be),
    .b_dout  (p_dout),
    .b_ack   (p_ack)
  );

  always_ff @(posedge cpu_clk or negedge cpu_rst_n) begin
    if (!cpu_rst_n) begin
      c_req   <= 1'b0;
      pending <= 1'b0;
      served  <= 1'b0;
      off_q   <= 3'd0;
      if_data <= 64'd0;
    end else begin
      c_req <= 1'b0;

      if (!if_req) begin
        // The request going away is what clears the answer. Holding served
        // beyond this would make the next fetch appear already complete.
        served  <= 1'b0;
        pending <= 1'b0;
      end else if (!served && !pending) begin
        // Capture the offset with the request: if_addr belongs to the fetch in
        // flight, and the core is free to move it once this one is answered.
        off_q   <= if_off;
        c_req   <= 1'b1;
        pending <= 1'b1;
      end else if (pending && c_ack) begin
        // Rotate the line so byte zero is the byte the core asked for.
        if_data <= c_dout >> {off_q, 3'b000};
        served  <= 1'b1;
        pending <= 1'b0;
      end
    end
  end

  always_comb if_ack = served;

endmodule
