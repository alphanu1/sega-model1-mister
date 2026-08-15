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
// I/O board responder — the far side of the dual-port RAM at 0xc00000.
//
// On the real board a Z80 (315-5338A) sits here reading controls, coin, service
// and the DIP switches, and talks to the V60 through the shared RAM. This is
// not that chip. It answers the boot handshake and nothing else, because the
// handshake is the only thing boot has been observed to need.
//
// WHAT THE EVIDENCE SAYS
//
// From the boot trace (see docs/m1-m4-plan.md, "The handshake, observed"): the
// V60 writes "SEGA" into DPRAM 0x1a-0x1d, writes a non-zero code to byte 0x20,
// and then polls 0x20 until it changes. Later it writes a second "SEGA" block
// at 0x100 with a payload and raises 0x20 again with a different code.
//
// So the rule is **the V60 sets the flag and the responder clears it** — not
// "reply 0x01 to 0x01". Matching the first observed value answered the first
// handshake and hung on the second. Any non-zero write is a request here, which
// is the generalisation the evidence supports rather than a wider guess.
//
// Across a full boot run the V60 reads exactly one address in this region more
// than twice: 0xc00040, the status flag, forty times. It reads no input data at
// all. That bounds this module honestly — it covers the boot phase reached, and
// attract mode and the service menu have not run. Those are where controls,
// coin, service and DIPs get read, and if they poll input offsets then this is
// where the tv80-versus-HLE decision finally has to be made. See THIRD-PARTY.md
// for the licence position on both options.
//
// WHAT IS PARAMETERISED AND WHY
//
// The reply value and the turnaround delay are both unknown properties of the
// real hardware, so per docs/rtl-conventions.md they are parameters rather than
// guesses buried in the logic. Clearing the flag to zero is what boot has been
// observed to accept; a real Z80 at 4 MHz would take microseconds to notice and
// answer, and anything non-instant works, so the default is a plausible delay
// rather than a measured one.
module m1_ioboard #(
  // Byte address of the request/status flag inside the DPRAM. 0xc00040 on the
  // V60 bus is word address 0x20, low byte lane.
  parameter logic [10:0] FLAG_ADDR = 11'h020,

  // What to write back. Zero clears the flag, which is what boot accepts.
  parameter logic [7:0]  REPLY = 8'h00,

  // Cycles between seeing the request and answering it. Stands in for a 4 MHz
  // Z80 noticing a mailbox; the V60 polls, so any non-zero value works and the
  // exact figure is not known.
  parameter int          LATENCY = 64
) (
  input  logic        clk,
  input  logic        rst_n,

  // The V60 side of the DPRAM, observed. This watches the bus rather than
  // reading the RAM back, because the request is the *write*, and a poll of a
  // byte the responder has not answered yet must not look like a new request.
  input  logic        v60_req,
  input  logic        v60_we,
  input  logic        v60_sel_dpram,
  input  logic [11:1] v60_addr,
  input  logic [7:0]  v60_wdata,

  // The I/O side write into the DPRAM. That RAM has ONE physical write port
  // shared with the V60 — Quartus will not infer a true dual-port M10K from it,
  // measured — so the write is held until io_ack says it landed. Collisions are
  // vanishingly rare (three bytes per boot against the V60's own traffic) but
  // dropping one would hang the handshake, which is not a failure worth being
  // relaxed about.
  output logic        io_we,
  output logic [10:0] io_addr,
  output logic [7:0]  io_din,
  input  logic        io_ack,

  // Telemetry: how many handshakes have been answered. Saturates rather than
  // wrapping, so "stuck at 3" stays readable in a trace.
  output logic [15:0] replies
);

  localparam int CNT_W = (LATENCY < 2) ? 1 : $clog2(LATENCY + 1);

  logic [CNT_W-1:0] wait_cnt;
  logic             pending;

  // A request is any non-zero write to the flag byte. The V60 writes the flag
  // with a code that differs between the two handshakes, so the value is not
  // matched — only that it is not the cleared state.
  logic request;
  always_comb request = v60_req && v60_we && v60_sel_dpram &&
                        (v60_addr == FLAG_ADDR[10:0]) && (v60_wdata != 8'h00);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending  <= 1'b0;
      wait_cnt <= '0;
      io_we    <= 1'b0;
      io_addr  <= FLAG_ADDR;
      io_din   <= REPLY;
      replies  <= 16'd0;
    end else begin
      // Held, not pulsed: the write stays asserted until the RAM acknowledges.
      if (io_ack) io_we <= 1'b0;

      if (request) begin
        // A second request arriving while one is outstanding restarts the
        // timer rather than being dropped. The V60 raises the flag again for
        // the second handshake, and losing that one hangs boot.
        pending  <= 1'b1;
        wait_cnt <= '0;
      end else if (pending) begin
        if (wait_cnt < CNT_W'(LATENCY)) begin
          wait_cnt <= wait_cnt + CNT_W'(1);
        end else if (!io_we) begin
          io_we   <= 1'b1;
          io_addr <= FLAG_ADDR;
          io_din  <= REPLY;
        end
      end

      // The handshake is answered when the byte actually reaches the RAM, not
      // when the write was requested.
      if (io_we && io_ack) begin
        pending <= 1'b0;
        if (replies != 16'hffff) replies <= replies + 16'd1;
      end
    end
  end

endmodule
