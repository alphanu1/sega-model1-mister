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

  // ------------------------------------------------------- instruction cache
  //
  // MEASURED BEFORE IT WAS BUILT. Modelling the reference's own 31-million-PC
  // trace offline gives, for an 8-byte line:
  //
  //     1 line  (   8 B)  32.1% hit      2 lines (  16 B)  99.0% hit
  //     4 lines (  32 B)  99.2% hit      8 lines (  64 B)  99.6% hit
  //
  // One line thrashes because the V60 alternates between two of them - an
  // instruction straddling a boundary fetches N and N+1 in turn - so the single
  // entry is evicted every time and 32% is the floor, not the ceiling. Two lines
  // take it to 99%. Eight costs 512 bits of line plus 152 of tag and leaves no
  // headroom question worth arguing about.
  //
  // The core spent 34% of its cycles fetch-stalled at 9.3 cycles a line and
  // 1.29 lines an instruction, which is no reuse whatever.
  //
  // WHY NO INVALIDATE PORT. The V60 is held in reset until rom_loaded, so it
  // cannot fetch while the loader is writing SDRAM, and the cache cannot be
  // filled with pre-download data. Afterwards the fetch region is read-only:
  // the V60 does write SDRAM - character RAM lives there - but it never
  // executes what it wrote, and a write to a different address cannot alias
  // because the tag is compared in full. If either of those ever stops being
  // true this needs a real invalidate.
  // THE TAG CARRIES BITS [2:1] TOO, though m1_main drives
  // {if_rom_word[24:3], 2'b00} and they are always zero there. Dropping them
  // would make the cache correct only for as long as that stays true, and the
  // port itself does not enforce it - m1_fetch_bridge's own suite drives
  // arbitrary addresses and caught the aliasing immediately. Two flops a line.
  localparam int LINES = 8;
  typedef logic [20:0] tag_t;                 // {addr[24:6], addr[2:1]}
  logic [63:0] cline  [LINES];
  tag_t        ctag   [LINES];
  logic        cvalid [LINES];
  integer      ci;

  wire [2:0]   cidx    = if_sdram_addr[5:3];
  wire tag_t   cur_tag = {if_sdram_addr[24:6], if_sdram_addr[2:1]};
  wire         chit    = cvalid[cidx] && (ctag[cidx] == cur_tag);

  // The index and tag of the fetch IN FLIGHT, captured with the request for the
  // same reason off_q is: the core may move if_sdram_addr once a fetch is
  // answered, and the fill must land in the line that was asked for.
  logic [2:0]  idx_q;
  tag_t        tag_q;

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
      idx_q   <= 3'd0;
      tag_q   <= '0;
      for (ci = 0; ci < LINES; ci = ci + 1) cvalid[ci] <= 1'b0;
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
        idx_q   <= cidx;
        tag_q   <= cur_tag;
        if (chit) begin
          // Answered from the cache, with no memory transaction at all. The
          // rotate is the same one the miss path does; only the source differs.
          if_data <= cline[cidx] >> {if_off, 3'b000};
          served  <= 1'b1;
        end else begin
          c_req   <= 1'b1;
          pending <= 1'b1;
        end
      end else if (pending && c_ack) begin
        // Rotate the line so byte zero is the byte the core asked for. The line
        // is cached UNROTATED, so a later fetch at a different offset within it
        // still hits.
        if_data       <= c_dout >> {off_q, 3'b000};
        cline[idx_q]  <= c_dout;
        ctag[idx_q]   <= tag_q;
        cvalid[idx_q] <= 1'b1;
        served        <= 1'b1;
        pending       <= 1'b0;
      end
    end
  end

  always_comb if_ack = served;

endmodule
