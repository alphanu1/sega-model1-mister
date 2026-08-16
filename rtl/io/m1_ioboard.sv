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
  parameter int          LATENCY = 64,

  // PUBLISHING INPUT STATE INTO THE SHARED RAM
  //
  // The real board's Z80 keeps the controls somewhere in the DPRAM and the V60
  // reads them there. Where is not yet known — see docs/io-board.md — so the
  // base address is a parameter and this can be swept rather than asserted.
  //
  // The 315-5338A has a single-command fast write to DPRAM bytes 0..7, which no
  // designer adds unless those bytes are refreshed often. That makes 0x000 the
  // first place to look, not a guess dressed up as a default.
  //
  // IDLE IS 0xFF, NOT 0x00. Every control in MAME's model1.cpp is
  // IP_ACTIVE_LOW, and an M10K comes up zeroed — so a core that publishes
  // nothing presents every button as held. That is worth ruling out before
  // anything subtler.
  // Where the sweep lands, and how far it runs. 0x00-0x0e is the whole control
  // region, confirmed by watching MAME run the real Z80 — see docs/io-board.md:
  //
  //   0x00-0x02  the MSM6253 ADC channels: steering, accelerator, brake
  //   0x03-0x07  set to 0xff at startup, contents unknown
  //   0x08-0x0a  IN.0/IN.1/IN.2
  //   0x0b-0x0d  the three DIP banks
  //   0x0e       port 6
  //
  // It stops at 0x0e deliberately. 0x0f toggles on a regular period in the
  // capture, so it is something the board drives outward — a lamp, most likely
  // — and writing control state over it would be modelling the wrong direction.
  parameter logic [10:0] INPUT_BASE  = 11'h000,
  parameter int          SWEEP_BYTES = 15,

  // Cycles between one byte of the sweep and the next.
  //
  // NOT every cycle. The real Z80 sweeps its ports once per loop at 4 MHz, and
  // refreshing thousands of times faster is what turned a collision that is
  // rare on hardware into a constant one — the DPRAM here has a single shared
  // write port, because Quartus will not infer the MB8421's second one.
  // Sweeping at roughly the board's rate makes that workaround stop mattering
  // instead of papering over it.
  //
  // 2048 at 19.2 MHz is a full fifteen-byte pass every ~1.6 ms, near enough a
  // 4 MHz Z80 round trip. That is ten passes per frame, so the steering axis is
  // sampled far more often than it can be drawn, let alone moved.
  parameter int          SWEEP_GAP = 2048,
  // Sweeping the control bytes into the shared RAM, as the board does.
  parameter bit          PUBLISH_INPUTS = 1'b1
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

  // The control region, byte 0 first, refreshed into the shared RAM
  // continuously so the V60 sees current state whenever it looks.
  //
  // Idle is 0xFF for the digital bytes — every control in model1.cpp is
  // IP_ACTIVE_LOW — but NOT for the analog ones, whose released values were
  // measured as 0x80 centre for steering and 0x01 for each pedal. Publishing a
  // blanket 0xff would read as both pedals floored.
  input  logic [SWEEP_BYTES*8-1:0] in_bytes,

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

  // Which byte to refresh next. Round robin rather than write-on-change: the
  // port is shared with the V60 and can be refused, so a change-triggered write
  // would need a retry queue to avoid losing an edge, and a button held for one
  // frame is millions of cycles wide anyway.
  localparam int IDX_W = (SWEEP_BYTES < 2) ? 1 : $clog2(SWEEP_BYTES);

  logic [IDX_W-1:0] pub_idx;
  logic [7:0]       pub_byte;
  always_comb pub_byte = in_bytes[{pub_idx, 3'b000} +: 8];

  // A request is any non-zero write to the flag byte. The V60 writes the flag
  // with a code that differs between the two handshakes, so the value is not
  // matched — only that it is not the cleared state.
  logic request;
  always_comb request = v60_req && v60_we && v60_sel_dpram &&
                        (v60_addr == FLAG_ADDR[10:0]) && (v60_wdata != 8'h00);

  // Which write is outstanding. WITHOUT THIS, ANY completed write clears a
  // pending handshake: a routine refresh landing mid-handshake counted as the
  // reply and the flag byte was never written, so the V60 waited forever for a
  // flag nobody cleared. That is what broke the first version of this, not the
  // arbitration it was blamed on.
  logic wr_reply;

  localparam int GAP_W = (SWEEP_GAP < 2) ? 1 : $clog2(SWEEP_GAP + 1);
  logic [GAP_W-1:0] gap;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending  <= 1'b0;
      wait_cnt <= '0;
      io_we    <= 1'b0;
      io_addr  <= FLAG_ADDR;
      io_din   <= REPLY;
      replies  <= 16'd0;
      pub_idx  <= '0;
      wr_reply <= 1'b0;
      gap      <= '0;
    end else begin
      if (gap != GAP_W'(SWEEP_GAP)) gap <= gap + GAP_W'(1);

      // A request is latched whenever it arrives, including while a refresh is
      // in flight. The V60 raises the flag again for the second handshake and
      // losing that one hangs boot.
      if (request) begin
        pending  <= 1'b1;
        wait_cnt <= '0;
      end else if (pending && wait_cnt < CNT_W'(LATENCY)) begin
        wait_cnt <= wait_cnt + CNT_W'(1);
      end

      if (io_we && io_ack) begin
        // Completion is attributed to whatever was actually issued.
        io_we <= 1'b0;
        if (wr_reply) begin
          pending <= 1'b0;
          if (replies != 16'hffff) replies <= replies + 16'd1;
        end else begin
          // Wrapped explicitly: SWEEP_BYTES is 15, so the counter's own natural
          // wrap at 16 would index two bytes past the end of in_bytes.
          pub_idx <= (pub_idx == IDX_W'(SWEEP_BYTES - 1)) ? '0
                                                          : pub_idx + IDX_W'(1);
          gap     <= '0;
        end
      end else if (!io_we) begin
        // One issue point, and the handshake takes it first: that is the reply
        // boot blocks on, and the sweep can always wait another 850 us.
        if (pending && wait_cnt >= CNT_W'(LATENCY)) begin
          io_we    <= 1'b1;
          io_addr  <= FLAG_ADDR;
          io_din   <= REPLY;
          wr_reply <= 1'b1;
        end else if (PUBLISH_INPUTS && gap == GAP_W'(SWEEP_GAP)) begin
          io_we    <= 1'b1;
          io_addr  <= INPUT_BASE + 11'(pub_idx);
          io_din   <= pub_byte;
          wr_reply <= 1'b0;
        end
      end
    end
  end

endmodule
