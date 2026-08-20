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
// MRA ROM loader: HPS ioctl stream -> SDRAM download port + TGP program RAM.
//
// STREAM LAYOUT IS THE SDRAM LAYOUT
//
// The MRA pads every region to a fixed size and emits them in the order the
// SDRAM map expects, so for everything that lives in external memory the
// address mapping is the identity: stream byte N is SDRAM byte N. There is
// deliberately no per-region base-address arithmetic here.
//
// That is not laziness, it is where the bugs are. s32's loader carries six
// region offsets computed from each other, and a loader that adds the wrong
// base puts a whole ROM region at the wrong address — which does not fail at
// load time, it fails much later as a game that boots to garbage, and the
// evidence points at the CPU rather than at the loader. Making the MRA
// responsible for layout means a region can only be misplaced by editing the
// MRA, where it is visible, rather than by arithmetic in RTL.
//
//   0x0000000  V60 program (ROMX)     1 MB   (D8 p0)
//   0x0100000  V60 boot (ROM0)      512 KB   (D8 p0)
//   0x0180000  V60 banked data ROM    4 MB   (D8 p0)
//   0x0580000  TGP data ROM         512 KB   (D8 p2)
//   0x0600000  sound 68000 program    1 MB   (D8 p3)
//   0x0700000  MultiPCM samples 1     4 MB   (D8 p4)
//   0x0B00000  MultiPCM samples 2     4 MB   (D8 p4)
//   0x0F00000  polygon / model ROM   16 MB   (D8 p2)
//   0x1F00000  TGP program ROM        8 KB   -> on-chip, not SDRAM
//   0x1F02000  end
//
// 31 MB of SDRAM, fitting a single 32 MB module, so D2 holds.
//
// Sized from MEASURED ROM extents across all ten dumped Model 1 games, not
// from MAME's ROM_REGION declarations. Those are upper bounds and total 33 MB,
// which would not fit — and concluding that D2 fails on the strength of them
// would have been wrong.
//
// The V60's four sub-regions are the one place the stream is not a plain copy
// of a MAME region, because `maincpu` is sparse: it spans 19.5 MB of address
// space holding 5.5 MB of ROM, with the program at 0x200000, the boot vectors
// at 0xf80000 and the banked data ROMs at 0x1000000. Storing that sparsely
// would spend 19.5 MB of the module on 5.5 MB of ROM. The MRA packs it, and
// m1_decode maps V60 addresses onto the packed layout — that mapping belongs
// with the decode because it is a property of the V60's address space, which
// is fixed silicon, rather than of the stream, which the MRA controls.
//
// The TGP program ROM is the one exception, because it is 32-bit and lives in
// the TGP's own program memory rather than external RAM. Two 16-bit ioctl
// words assemble into one 32-bit program word, low half first.
//
// BACKPRESSURE
//
// `ioctl_wait` tells the HPS to stop, but it does not stop instantly — the
// host has already-issued transfers in flight when it sees the signal. A
// loader that asserts wait and assumes the very next write will not arrive
// drops ROM bytes, and a dropped byte is a corrupt ROM that passes its own
// load and fails a checksum much later.
//
// So writes go into a short FIFO and `ioctl_wait` asserts while it still has
// room to absorb what is already in flight, not once it is full. `overflow`
// exists so a testbench can assert that the depth was actually sufficient
// rather than assuming it.

`timescale 1ns/1ps

module m1_rom_loader #(
  // The microcode arrives on ITS OWN DOWNLOAD INDEX, not at an offset inside
  // the main stream.
  //
  // It used to be keyed on byte offset 0x1F0_0000 — near the top of SDRAM,
  // which is a sensible place to PUT it but a terrible way to DELIVER it: the
  // game stream is 6 MB, so reaching that offset would mean padding 25 MB of
  // filler through the HPS to carry 8 KB. MRA supports a second <rom index=>
  // and MiSTer cores route extra regions that way as standard.
  //
  // Kept as a parameter so the routing is stated rather than buried, and so the
  // testbench can drive both indices.
  parameter logic [15:0] TGP_INDEX     = 16'd1,
  parameter logic [26:0] TGP_PROG_END  = 27'h0_2000,   // 8 KB of microcode

  // Write buffer depth, in 16-bit words, and how many in-flight transfers to
  // leave room for after `ioctl_wait` asserts.
  //
  // WHAT THESE HAVE TO SURVIVE IS THE HPS, NOT THE TESTBENCH
  //
  // ioctl_wait does not stop the host; it asks it to stop. Everything already
  // in flight still arrives, and `FIFO_DEPTH - WAIT_MARGIN` is exactly how many
  // of those the buffer can absorb before it starts dropping them.
  //
  // At 8 and 6 the buffer tolerated 15 cycles of host reaction and silently
  // dropped words at 16 — 200 ns at 80 MHz, well inside a single HPS bus round
  // trip. The test did not catch it because it swept 0..6, which is the margin
  // the parameter was set to: it confirmed the setting instead of testing it.
  // On hardware that is a ROM with holes in it, reported as a successful load,
  // and the CPU crashes on it much later looking like a core bug.
  //
  // 512 and 256 give roughly 3.2 us of host latency. The sweep now runs to 64
  // — an order of magnitude past anything plausible — and the buffer is block
  // RAM rather than flip-flops, so the depth costs two M10K instead of 20,000
  // registers.
  parameter int unsigned FIFO_DEPTH = 512,
  parameter int unsigned WAIT_MARGIN = 256,

  // ioctl index carrying the ROM stream.
  parameter logic [15:0] ROM_INDEX = 16'd0
) (
  input  logic        clk,
  input  logic        rst,

  // The SDRAM controller's JEDEC bring-up must finish before any write can be
  // serviced; accepting stream bytes before that desynchronises everything
  // after them.
  input  logic        mem_ready,

  // HPS ioctl, hps_io built with WIDE=1 so this is 16-bit and ioctl_addr
  // advances by two per word.
  input  logic        ioctl_download,
  input  logic [15:0] ioctl_index,
  input  logic        ioctl_wr,
  input  logic [26:0] ioctl_addr,
  input  logic [15:0] ioctl_dout,
  output logic        ioctl_wait,

  // SDRAM download write port. Contract is one transaction per rising edge of
  // req, single outstanding — see m1_sdram.sv.
  output logic        sdr_wr_req,
  output logic [24:1] sdr_wr_addr,
  output logic [15:0] sdr_wr_din,
  output logic [1:0]  sdr_wr_be,
  input  logic        sdr_wr_ack,

  // TGP program memory, 2048 x 32.
  output logic        tgp_wr,
  output logic [10:0] tgp_addr,
  output logic [31:0] tgp_din,

  output logic        rom_loaded,
  output logic        overflow,     // buffer was written while full

  // DID THE MICROCODE ACTUALLY ARRIVE? Nothing measured this, and its absence
  // cost a whole round of diagnosis: the RTL path from here to the TGP's program
  // RAM is wired and the MRA element is well formed, so "the microcode loads" was
  // inferred from the code existing rather than from anything observed. The board
  // cannot be asked either — MiSTer does not log ROM assembly, and /media/fat is
  // mounted noatime so the file access leaves no trace.
  //
  // ucode_words counts 32-bit words written, so 2048 (0x800) is a complete load.
  // ucode_csum folds both halves of every word, so a load of the WRONG 8 KB is
  // distinguishable from the right one rather than merely non-zero.
  output logic [11:0] ucode_words,
  output logic [15:0] ucode_csum,
  // A FOLD OF EVERY WORD HANDED TO SDRAM, and of how many there were.
  //
  // Row 02 proves the MICROCODE arrives, but that goes straight to the
  // coprocessor's RAM and never touches SDRAM. The math tables and the data
  // window do, and the board reads different values from them than the model
  // returns at every one of the four capture phases. That leaves two
  // possibilities - the data never reached SDRAM, or SDRAM does not return what
  // was written - and nothing so far separates them.
  //
  // This is the write side. tools/rom_csum.py folds the packed image the same
  // way, so a match means the HPS delivered the right bytes in the right order
  // and the fault is on the read side.
  output logic [23:0] sdram_csum,
  output logic [23:0] sdram_words
);

  localparam int unsigned AW = $clog2(FIFO_DEPTH);

  // ---------------------------------------------------------------- buffer
  //
  // Block RAM, and it has to stay that way: at 512 entries the register form is
  // 20,480 flip-flops, which Quartus builds without complaint — the same silent
  // fallback documented in rtl/m1_mainram.sv. The ramstyle makes a regression a
  // build error rather than half the device.
  (* ramstyle = "M10K" *) logic [24:1] fifo_addr [FIFO_DEPTH];
  (* ramstyle = "M10K" *) logic [15:0] fifo_data [FIFO_DEPTH];
  logic [AW:0]        wptr, rptr;          // one extra bit distinguishes full
  logic [AW:0]        level;

  assign level = wptr - rptr;

  logic fifo_empty, fifo_full;
  assign fifo_empty = (wptr == rptr);
  assign fifo_full  = (level == (AW+1)'(FIFO_DEPTH));

  // Assert wait with room still left, not once full. The host keeps sending
  // for a few cycles after it sees this.
  // GATED ON ioctl_download, AND THAT IS NOT COSMETIC.
  //
  // hps_io drives this straight onto the HPS bus — `assign HPS_BUS[37] =
  // ioctl_wait` — so it is not a private signal between this module and the
  // loader. It tells the HPS to stall.
  //
  // Ungated, ~mem_ready holds it from the instant the FPGA is configured until
  // the SDRAM controller finishes its JEDEC bring-up, about 125 us at 80 MHz.
  // MiSTer reads the core's CONF_STR immediately after enabling the bridge,
  // which lands inside that window: it gets nothing, the core reports no name,
  // and the core never appears to load at all. The FPGA is running the whole
  // time, which is what makes it look like a dead bitstream rather than a
  // handshake held low.
  //
  // Outside a download there is nothing to wait for, so say nothing.
  assign ioctl_wait = ioctl_download &
                      (~mem_ready | (level >= (AW+1)'(FIFO_DEPTH - WAIT_MARGIN)));

  logic is_sdram, is_tgp;
  // Routed by index, not by address. Both streams start at byte 0.
  assign is_sdram = (ioctl_index == ROM_INDEX);
  assign is_tgp   = (ioctl_index == TGP_INDEX) && (ioctl_addr < TGP_PROG_END);

  logic stream_ok;
  // Either index is a stream we accept; which one decides where it goes.
  assign stream_ok = ioctl_download &&
                     ((ioctl_index == ROM_INDEX) || (ioctl_index == TGP_INDEX));

  // ------------------------------------------------------------ SDRAM side
  logic        req_q;
  logic        busy;          // a transaction is outstanding
  logic        ack_d;

  assign sdr_wr_req  = req_q;
  assign sdr_wr_be   = 2'b11;               // whole-word writes only

  logic sok_d;      // stream_ok, delayed, for end-of-stream detection
  logic dl_done;    // stream has ended, waiting for the buffer to drain
  logic [15:0] tgp_lo;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      wptr <= '0; rptr <= '0;
      req_q <= 1'b0; busy <= 1'b0; ack_d <= 1'b0;
      sdr_wr_addr <= '0; sdr_wr_din <= '0;
      tgp_wr <= 1'b0; tgp_addr <= '0; tgp_din <= '0; tgp_lo <= '0;
      rom_loaded <= 1'b0; overflow <= 1'b0; sok_d <= 1'b0; dl_done <= 1'b0;
      ucode_words <= '0; ucode_csum <= '0;
      sdram_csum <= 24'd0; sdram_words <= 24'd0;
      // THE ARRAYS ARE DELIBERATELY NOT CLEARED HERE.
      //
      // A reset that writes every entry is a second write port on the memory
      // and no block RAM has one, so it forces the whole buffer into
      // flip-flops. Nothing reads an entry the pointers have not written:
      // rptr only advances behind wptr, so the contents at reset are
      // unreachable rather than merely unlikely to matter.
    end else begin
      tgp_wr <= 1'b0;
      ack_d  <= sdr_wr_ack;
      sok_d  <= stream_ok;

      // -------------------------------------------------------- accept
      if (stream_ok && ioctl_wr) begin
        if (is_sdram) begin
          if (fifo_full) begin
            overflow <= 1'b1;
          end else begin
            fifo_addr[wptr[AW-1:0]] <= ioctl_addr[24:1];
            fifo_data[wptr[AW-1:0]] <= ioctl_dout;
            wptr <= wptr + 1'b1;
            // Rotate then XOR, so a reordering does not cancel.
            sdram_csum  <= {sdram_csum[22:0], sdram_csum[23]}
                         ^ {8'd0, ioctl_dout};
            sdram_words <= sdram_words + 24'd1;
          end
        end else if (is_tgp) begin
          // 32-bit program words, low half first. Bit 1 of the byte address
          // selects the half because ioctl_addr counts bytes and advances by
          // two per 16-bit word.
          if (!ioctl_addr[1]) begin
            tgp_lo <= ioctl_dout;
          end else begin
            tgp_din  <= {ioctl_dout, tgp_lo};
            // A 32-bit program word is FOUR bytes, so the word index is the
            // byte offset shifted by two — bits [12:2]. Using [13:3] shifted
            // by three and indexed every other program word, which produced
            // 128 wrong words out of 128 and looked like a byte-order fault.
            // No base to subtract now that this is its own index.
            tgp_addr <= ioctl_addr[12:2];
            tgp_wr   <= 1'b1;
            // Counted here rather than on tgp_wr downstream so the count cannot
            // disagree with what was actually presented to the program RAM.
            ucode_words <= ucode_words + 12'd1;
            ucode_csum  <= ucode_csum ^ ioctl_dout ^ tgp_lo;
          end
        end
      end

      // -------------------------------------------------------- drain
      // One transaction at a time, req pulsed so the controller sees a rising
      // edge. Holding req high would be serviced exactly once and the rest of
      // the ROM would never be written.
      if (busy) begin
        req_q <= 1'b0;
        if (sdr_wr_ack && !ack_d) begin
          busy <= 1'b0;
          rptr <= rptr + 1'b1;
        end
      end else if (!fifo_empty && mem_ready) begin
        sdr_wr_addr <= fifo_addr[rptr[AW-1:0]];
        sdr_wr_din  <= fifo_data[rptr[AW-1:0]];
        req_q       <= 1'b1;
        busy        <= 1'b1;
      end

      // ---------------------------------------------------- completion
      // Only once the download has ended AND everything buffered has been
      // written. Releasing reset while writes are still draining starts the
      // V60 on a ROM that is not all there yet.
      //
      // The end of the stream has to be LATCHED. Testing
      // `falling_edge && drained` in one expression only ever samples the
      // single cycle the download ends, and at that moment the buffer is
      // normally still full — so rom_loaded never asserted at all and the core
      // would have sat in reset forever.
      if (stream_ok) begin
        rom_loaded <= 1'b0;
        dl_done    <= 1'b0;
      end else begin
        if (sok_d && !stream_ok) dl_done <= 1'b1;
        if (dl_done && fifo_empty && !busy) begin
          rom_loaded <= 1'b1;
          dl_done    <= 1'b0;
        end
      end
    end
  end

endmodule
