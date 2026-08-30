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
// The reply value and the turnaround delay are both parameters rather than
// guesses buried in the logic, per docs/rtl-conventions.md. Clearing the flag to
// zero is what boot has been observed to accept.
//
// THE DELAY IS NOW MEASURED. It was a guess — 64 cycles, on the reasoning that
// "a real Z80 at 4 MHz would take microseconds and anything non-instant works".
// The reference says 38,577 us, once, and never again; the reasoning was wrong
// in both magnitude and shape. See the LATENCY comment below for the numbers and
// the instruments, and docs/io-board.md for the protocol they establish.
module m1_ioboard #(
  // Byte address of the request/status flag inside the DPRAM. 0xc00040 on the
  // V60 bus is word address 0x20, low byte lane.
  parameter logic [10:0] FLAG_ADDR = 11'h020,

  // What to write back. Zero clears the flag, which is what boot accepts.
  parameter logic [7:0]  REPLY = 8'h00,

  // Cycles between seeing the request and answering it. MEASURED, not guessed —
  // see tools/mame_iohandshake.lua and tools/mame_flag_state.lua.
  //
  // This was 64, with a comment saying "the V60 polls, so any non-zero value
  // works and the exact figure is not known". Both halves of that were wrong,
  // and running the reference answered it in minutes:
  //
  //   The V60 raises the flag at pc=fe03fd and polls it 36,308 times over
  //   38,577.3 us before the Z80 clears it. That is 617,236 V60 cycles at
  //   16 MHz, or 881,760 of this domain's at 22.857 MHz. It is not a mailbox
  //   turnaround at all — it is the I/O board's Z80 powering up and running its
  //   own self-test before it ever looks at the flag, which is why the figure is
  //   enormous and why it happens exactly once.
  //
  //   AND AFTER BOOT THE FLAG IS NEVER CLEARED AGAIN. The V60 re-raises it once
  //   a frame as a fire-and-forget doorbell and never reads it back: sampled
  //   eight times a frame for 1,200 frames, it reads set in 1,194 of them and
  //   clear only in the six frames of boot. We were clearing it every frame.
  //
  // ONE NUMBER REPRODUCES BOTH BEHAVIOURS, which is why there is no second
  // parameter and no one-shot rule here. A request re-arms the counter (see
  // `pending` below), the doorbell arrives every 333,913 cycles, and 333,913 is
  // less than 881,760 — so once the game is running the count never expires and
  // the flag stays set on its own. At boot the V60 raises it once and then only
  // polls, so the count does expire and the single reply lands.
  //
  // A CONSEQUENCE FOR THE OVERLAY: `replies` now reaches 1 and stops, which is
  // the healthy value rather than a stalled counter. docs/debug-overlay.md row
  // 0B is corrected to say so.
  parameter int          LATENCY = 881760,

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
  parameter bit          PUBLISH_INPUTS = 1'b1,

  // Pushing the board's identity block into DPRAM 0x100-0x17f at startup.
  //
  // The V60 block-reads all 128 bytes of that window once, immediately after
  // its first handshake is answered, and will not go on to poll its controls
  // until it has. Nothing writes the window before that read — not the V60,
  // which is still spinning on the flag — so the board itself supplies it.
  //
  // Without this the window reads as zeros, the V60 rejects it and loops at
  // fe1433 forever, which is exactly where our core sat while every input byte
  // underneath it was correct.
  parameter bit          PUSH_BLOCK = 1'b1,
  parameter logic [10:0] BLOCK_BASE = 11'h100,

  // DPRAM byte 0x21, set once and never changed.
  //
  // MEASURED, not inferred: watching 0xc00042 on the reference across a boot it
  // goes 00 -> 40 at frame 9, just after the status flag at byte 0x20 is set at
  // frame 7, and holds 40 for the rest of the run. Our HLE never wrote it at
  // all, so a whole-DPRAM diff against MAME showed 0x21 as the one persistent
  // difference in 2048 bytes.
  //
  // The other byte that differed, 0x11, is NOT a fault: it is a live
  // command/response cell cycling ff -> 01/46/36 -> ff, and our 36 is one of
  // those values caught at a different phase. Two bytes differed and only one
  // was a bug - which is why the byte was watched over frames before anything
  // was changed.
  parameter logic [10:0] STAT_ADDR  = 11'h021,
  parameter logic [7:0]  STAT_VALUE = 8'h40
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

  // The board's identity block, as the reference presents it at DPRAM
  // 0x100-0x17f. Every byte here was read off MAME running the real Z80 against
  // the real ROM — see docs/io-board.md — rather than reasoned about, because
  // only five of the twenty-three non-zero bytes have a known meaning.
  //
  // THE FIRST TRANSCRIPTION CAUGHT THE BLOCK MID-PUSH. It was dumped once, just
  // after the handshake, while the Z80 was still writing — so six bytes were
  // wrong and stayed wrong in the RTL, in tb_m1_iopublish's expected values and
  // in docs/io-board.md together, because all three came from that one reading.
  // Re-dumped at frames 10, 120 and 900 (tools/mame_idblock.lua) the block is
  // stable and differs from what we had at 0x08, 0x09, 0x0b, 0x1a, 0x1b and 0x7c.
  // A single snapshot of a window another processor is filling is not a
  // measurement; sample it more than once and check it has settled.
  //
  // Bytes 0-3 are "SEGA", the same signature the V60 writes at 0x1a to announce
  // itself, returned here so the exchange is symmetric. The rest is version and
  // configuration state whose fields are not decoded; the tail to 0x7f is zero.
  //
  // Written as a case rather than an initialised array on purpose: Quartus 17.0
  // will not infer RAM from an array that is reset, and this wants to be a
  // handful of LUTs regardless.
  logic [6:0] blk_idx;
  logic [7:0] blk_byte;
  always_comb begin
    case (blk_idx)
      7'h00: blk_byte = 8'h53;   // 'S'
      7'h01: blk_byte = 8'h45;   // 'E'
      7'h02: blk_byte = 8'h47;   // 'G'
      7'h03: blk_byte = 8'h41;   // 'A'
      7'h04: blk_byte = 8'h1c;
      7'h05: blk_byte = 8'h82;
      7'h06: blk_byte = 8'h01;
      7'h08: blk_byte = 8'h88;
      7'h09: blk_byte = 8'h9a;
      7'h0a: blk_byte = 8'hff;
      // 0x0b DECIDES WHETHER THE GAME USES THE COPROCESSOR. The V60 copies this
      // whole window into work RAM at 0x40DC80 (FE08DD-FE08F5, 128 bytes) and
      // then tests `cmp.b #1, 40DC8B` — block offset 0x0b — at FF9737. With 1 it
      // falls into a block that writes 0x1000000 and the float 0x3F400000 to a
      // port and reads back with `in.w`; with anything else it branches past it.
      // We had no entry here, so we pushed 0x00 and skipped that path. Found by
      // v60_trace at instruction 25,682.
      7'h0b: blk_byte = 8'h01;
      7'h11: blk_byte = 8'h01;
      7'h12: blk_byte = 8'h01;
      7'h13: blk_byte = 8'h01;
      7'h15: blk_byte = 8'h01;
      7'h16: blk_byte = 8'h01;
      7'h17: blk_byte = 8'hff;
      7'h18: blk_byte = 8'hff;
      7'h19: blk_byte = 8'hff;
      7'h1a: blk_byte = 8'h01;
      7'h1b: blk_byte = 8'h02;
      7'h20: blk_byte = 8'h01;
      7'h7c: blk_byte = 8'h02;
      default: blk_byte = 8'h00;
    endcase
  end

  // All 128 bytes are written, including the zeros. The RAM does come up
  // cleared, so the zeros are redundant on paper — but the V60 writes its own
  // block into this same window on the path we currently take, and a push that
  // only touched the non-zero bytes would leave that debris behind.
  logic blk_done;

  // Which write is outstanding: the sweep, the handshake reply, or a block
  // byte. Two flags rather than one because all three share the single port and
  // completion has to be attributed to whichever was actually issued.
  logic wr_block;
  logic wr_stat, stat_done;

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
      blk_idx  <= '0;
      blk_done <= ~PUSH_BLOCK;
      wr_block <= 1'b0;
      wr_stat  <= 1'b0;
      stat_done <= 1'b0;
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
        end else if (wr_block) begin
          if (blk_idx == 7'h7f) blk_done <= 1'b1;
          else                  blk_idx  <= blk_idx + 7'd1;
        end else if (wr_stat) begin
          stat_done <= 1'b1;
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
          wr_block <= 1'b0;
          wr_stat  <= 1'b0;
        end else if (!stat_done && replies != 16'd0) begin
          // After the first handshake, matching the reference's ordering: the
          // flag at byte 0x20 is answered first and this appears two frames
          // later.
          io_we    <= 1'b1;
          io_addr  <= STAT_ADDR;
          io_din   <= STAT_VALUE;
          wr_reply <= 1'b0;
          wr_block <= 1'b0;
          wr_stat  <= 1'b1;
        end else if (!blk_done) begin
          // Ahead of the sweep, and at full rate rather than the sweep's gap.
          // The V60 reads this window once, right after its first handshake is
          // answered, and 128 bytes at one per 2048 cycles would not be there
          // in time. It is a startup burst, not a refresh.
          io_we    <= 1'b1;
          io_addr  <= BLOCK_BASE + 11'(blk_idx);
          io_din   <= blk_byte;
          wr_reply <= 1'b0;
          wr_block <= 1'b1;
          wr_stat  <= 1'b0;
        end else if (PUBLISH_INPUTS && gap == GAP_W'(SWEEP_GAP)) begin
          io_we    <= 1'b1;
          io_addr  <= INPUT_BASE + 11'(pub_idx);
          io_din   <= pub_byte;
          wr_reply <= 1'b0;
          wr_block <= 1'b0;
          wr_stat  <= 1'b0;
        end
      end
    end
  end

endmodule
