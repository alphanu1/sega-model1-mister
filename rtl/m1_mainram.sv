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
// The main board's on-chip memories, kept together so their block-RAM
// inference can be synthesised and checked without the rest of the design.
//
// EVERY MEMORY IS SPLIT INTO BYTE LANES, AND THAT IS THE WHOLE POINT
//
// Quartus 17.0 does not infer block RAM from the obvious byte-enable idiom:
//
//     if (we) begin
//       if (be[0]) mem[a][7:0]  <= d[7:0];
//       if (be[1]) mem[a][15:8] <= d[15:8];
//     end
//     q <= mem[a];
//
// It builds that from flip-flops instead, silently. Written that way these
// arrays total 2.7 Mbit — roughly 2.7 million registers on a device with
// 41,910 ALMs — and synthesis simply never finished, grinding for
// twenty-five minutes at 15 GB before being killed. Twice.
//
// Two byte-wide arrays with plain write enables infer immediately. Confirmed
// by synthesising both forms side by side in one small module: the 16-bit
// form produced nothing, the byte-lane form produced two altsyncram
// megafunctions. Testing the idiom at 1024 entries took thirty seconds and
// answered what hours of full-size builds had not.
//
// The ramstyle attribute stays as belt and braces: it makes a future
// regression a build error rather than a silent resource catastrophe.
// Simulation cannot catch any of this — Verilator has no opinion about
// whether storage lands in RAM or registers.
//
// Tile RAM and palette RAM appear twice because they are read by the CPU and
// by the video renderer at independent addresses. Two reads plus a write fits
// no M10K configuration, so the copies are explicit and take the same writes.

`timescale 1ns/1ps

module m1_mainram (
  input  logic        clk,

  // CPU side
  input  logic        we,
  input  logic [1:0]  be,
  input  logic [23:1] addr,
  input  logic [15:0] wdata,
  input  logic        sel_tileram, sel_palette, sel_dlist0,
  input  logic        sel_dlist1, sel_colxlat, sel_dpram,
  output logic [15:0] tram_q, pram_q, dl0_q, dl1_q, cxlat_q,
  // Driven combinationally from the single registered read below.
  output wire  [15:0] dpram_q,
  // Writes above the 16,384-word cap the two display lists are sized to.
  // Measured zero over 40 s; nonzero means the cap is wrong. See below.
  output logic [15:0] dbg_dl_oob,

  // Video side. Its own clock: the video path runs in the fast domain and the
  // CPU in the slow one, and these two arrays are where the domains meet.
  // Written by the CPU, read by the renderer, never the other way, so the
  // crossing needs no handshake — the renderer sees whatever the CPU last
  // wrote, which is exactly what a tilemap read off a shared bus does on the
  // real board.
  //
  // Dual-clock inference measured before it was used: 32768x8 written on one
  // clock and read on another gives 32 M10K and 37 ALM standalone. Two
  // always_ff blocks are REQUIRED here — one per clock — which is the opposite
  // of the rule for the dpram below, where two blocks on one array killed
  // inference. The difference is one write port versus two.
  input  logic        vid_clk,
  input  logic [14:0] vid_tram_addr,
  output logic [15:0] vid_tram_data,
  input  logic [11:0] vid_pal_addr,
  output logic [15:0] vid_pal_data,

  // The 3D layer's read ports. The display list and the colour-translation table
  // are read by m1_raster3d while the CPU is writing them, which is exactly what
  // m1_tdp_ram exists for - the alternative is a second copy of each, and the
  // display lists alone are 64 KB.
  input  logic        r3d_clk,
  input  logic [14:0] r3d_dl_addr,
  input  logic        r3d_dl_sel,
  output logic [15:0] r3d_dl_data,
  input  logic [14:0] r3d_xlat_addr,
  output logic [15:0] r3d_xlat_data,

  // The 3D layer's palette read. ONLY 1,024 ENTRIES, not the whole 8,192: the
  // colour unit indexes `0x1000 | (tex & 0x3ff)` and nothing else, so a mirror of
  // that one bank is 2 M10K where a second full copy would be 13 and a third port
  // on the real palette is not something altsyncram offers.
  input  logic [9:0]  r3d_pal_addr,
  output logic [15:0] r3d_pal_data,

  // I/O board side of the RAM at 0xc00000. Byte-wide, and it shares the V60's
  // physical write port — hold io_we until io_ack.
  input  logic        io_we,
  input  logic [10:0] io_addr,
  input  logic [7:0]  io_din,
  output logic        io_ack,
  // AND A READ PORT, for the Z80 I/O board. The behavioural board only ever
  // wrote; the firmware reads dpram[addr] back through the 315-5338A's
  // register 0x0c, so it needs one. Registered, one cycle.
  input  logic [10:0] io_raddr,
  output logic [7:0]  io_rdata
);

  logic tram_we, pram_we, dl0_we, dl1_we, cxlat_we, dpram_we;
  assign tram_we  = we && sel_tileram;
  assign pram_we  = we && sel_palette;
  assign dl0_we   = we && sel_dlist0;
  assign dl1_we   = we && sel_dlist1;
  assign cxlat_we = we && sel_colxlat && (addr[15:1] < 15'd24576);
  assign dpram_we = we && sel_dpram;

  // SCR 0x700000-0x70ffff and COL 0x900000-0x903fff.
  //
  // ONE COPY EACH, in m1_tdp_ram. These were two copies apiece - `tram_c_*` for
  // the CPU's read port and `tram_v_*` for the video's, written identically from
  // `clk` - because an M10K has two ports and write + CPU read + video read is
  // three. Port A can serve the write AND the CPU read, leaving port B for the
  // video, which is two, and Cyclone V M10K is true dual-port silicon with an
  // independent clock per port.
  //
  // Measured cost of the duplication, from the fitter's by-entity M10K column:
  // 128 blocks on tile RAM and 32 on palette, half of each wasted, 80 of a
  // 553-block device already at 82%. Quartus 17.0 will not INFER the sharing -
  // it replicates one template silently and refuses the other with Error 276001
  // - so m1_tdp_ram instantiates altsyncram explicitly. See its header.
  //
  // The byte lanes are gone: both ports must be the SAME WIDTH or the block is
  // replicated again, so this is 16 bits wide with a byteena rather than two
  // byte-wide arrays.
  m1_tdp_ram #(.AW(15)) u_tram (
    .a_clk (clk),
    .a_addr(addr[15:1]), .a_din(wdata), .a_be(be), .a_we(tram_we), .a_q(tram_q),
    .b_clk (vid_clk),
    .b_addr(vid_tram_addr), .b_q(vid_tram_data)
  );

  m1_tdp_ram #(.AW(13)) u_pram (
    .a_clk (clk),
    .a_addr(addr[13:1]), .a_din(wdata), .a_be(be), .a_we(pram_we), .a_q(pram_q),
    .b_clk (vid_clk),
    .b_addr({1'b0, vid_pal_addr}), .b_q(vid_pal_data)
  );

  // TGP 0x600000-0x60ffff and 0x610000-0x61ffff, and COL 0x910000-0x91bfff.
  //
  // All three are TRUE DUAL PORT now: the CPU writes them while the 3D layer
  // reads them from its own clock domain. Byte-split arrays with one port would
  // need a second copy of each to be readable, and the two display lists alone
  // are 64 KB - 51 M10K duplicated for want of a port.
  logic [15:0] dl0_b_q, dl1_b_q;

  // THE GAME USES THE BOTTOM 16,384 WORDS OF EACH LIST, AND ONLY THOSE.
  //
  // `model1.cpp:994` maps each buffer as the full 64 KB, and `model1_v.cpp:25`
  // masks the walker's address with 0x7fff, so the ARCHITECTURE really is
  // 32,768 words. At 16 bits that is 52 M10K apiece - 104 of the device's 553,
  // on a design already at 100% of them, which is the reason the V60 has no
  // data cache.
  //
  // `tools/mame_dl_extent.lua` taps every write to 0x600000-0x61ffff and keeps
  // the highest word touched. Over 2,400 frames - 40 seconds, well past attract
  // and into the game - it is 0x3fff on BOTH buffers, out of 1.5 million writes
  // each. Exactly half, which reads as a program constant rather than as an
  // accident of what happened to be drawn.
  //
  // SO THE STORAGE IS HALVED AND THE DECODE IS NOT. Shrinking the address
  // instead would alias word 0x4000 onto word 0, and word 0 holds a live
  // command - a read that used to return an all-zero terminator would start
  // executing the list again. Above the cap this reads as ZERO, which is what
  // the never-written upper half returned, and writes are DROPPED.
  //
  // `dbg_dl_oob` counts anything that goes up there. A measurement over one
  // 40-second window is not a proof about every code path, so the assumption
  // reports itself rather than corrupting quietly.
  localparam int unsigned DL_WORDS = 16384;

  // addr[15:1] is the word address, so its bit 14 - which is addr[15] - is
  // exactly "at or above 16,384".
  wire dl_a_hi = addr[15];
  wire dl_b_hi = r3d_dl_addr[14];

  logic [15:0] dl0_q_raw, dl1_q_raw, dl0_b_raw, dl1_b_raw;
  logic        dl_a_hi_q, dl_b_hi_q;

  always_ff @(posedge clk)     dl_a_hi_q <= dl_a_hi;
  always_ff @(posedge r3d_clk) dl_b_hi_q <= dl_b_hi;

  m1_tdp_ram #(.AW(14), .WORDS(DL_WORDS)) u_dl0 (
    .a_clk(clk), .a_addr(addr[14:1]), .a_din(wdata), .a_be(be),
    .a_we(dl0_we && !dl_a_hi), .a_q(dl0_q_raw),
    .b_clk(r3d_clk), .b_addr(r3d_dl_addr[13:0]), .b_q(dl0_b_raw)
  );

  m1_tdp_ram #(.AW(14), .WORDS(DL_WORDS)) u_dl1 (
    .a_clk(clk), .a_addr(addr[14:1]), .a_din(wdata), .a_be(be),
    .a_we(dl1_we && !dl_a_hi), .a_q(dl1_q_raw),
    .b_clk(r3d_clk), .b_addr(r3d_dl_addr[13:0]), .b_q(dl1_b_raw)
  );

  assign dl0_q  = dl_a_hi_q ? 16'h0000 : dl0_q_raw;
  assign dl1_q  = dl_a_hi_q ? 16'h0000 : dl1_q_raw;
  assign dl0_b_q = dl_b_hi_q ? 16'h0000 : dl0_b_raw;
  assign dl1_b_q = dl_b_hi_q ? 16'h0000 : dl1_b_raw;

  // Saturating, and NOT reset: this module has no reset port and the counter
  // does not need one - Cyclone V registers power up cleared, and an initial
  // covers the simulator.
  initial dbg_dl_oob = 16'd0;
  always_ff @(posedge clk)
    if ((dl0_we || dl1_we) && dl_a_hi && !(&dbg_dl_oob))
      dbg_dl_oob <= dbg_dl_oob + 16'd1;

  // The buffer select is the reader's, and it is applied to the DATA rather than
  // the address so both memories are read in parallel and the choice costs a mux
  // instead of a cycle.
  assign r3d_dl_data = r3d_dl_sel ? dl1_b_q : dl0_b_q;

  // 24,576 words rounds up to a 32,768-word memory. The waste is real - eight
  // M10K - and the alternative is a non-power-of-two depth, which altsyncram
  // will take but which stops the two ports sharing an address decode cleanly.
  // The 3D palette bank mirror, written whenever the CPU writes 0x1000..0x13ff.
  // Kept in step by construction rather than by a copy pass: the same write that
  // reaches the palette reaches here.
  wire pal_3d_hit = sel_palette && (addr[13:1] >= 13'h1000) && (addr[13:1] <= 13'h13ff);

  m1_tdp_ram #(.AW(10)) u_pal3d (
    .a_clk(clk), .a_addr(addr[10:1]), .a_din(wdata), .a_be(be),
    .a_we(we && pal_3d_hit), .a_q(),
    .b_clk(r3d_clk), .b_addr(r3d_pal_addr), .b_q(r3d_pal_data)
  );

  // addr[15:1], NOT {1'b0, addr[14:1]} - THE TABLE IS 24,576 WORDS AND NEEDS
  // ALL FIFTEEN BITS.
  //
  // The colour translation table is three stacked 8,192-word sections and
  // m1_geo_color addresses them at 0x0000 for red, 0x2000 for green and 0x4000
  // for BLUE. Forcing the top bit to zero dropped word-address bit 14, so every
  // blue write aliased onto the red section - and because the game writes red
  // after blue, red came out correct and blue was never stored at all.
  //
  // Measured: our table against MAME's, per section. Red identical 8,192 of
  // 8,192, green identical 8,192 of 8,192, blue ZERO non-zero words against the
  // reference's 7,935. On the board that is a 3D layer with no blue in it - a
  // grey road drawn olive, a white car drawn yellow, and red unaffected because
  // its blue was already zero.
  //
  // Every other memory here already slices the address the natural way; this
  // was the only one that did not.
  m1_tdp_ram #(.AW(15), .WORDS(24576)) u_cxlat (
    .a_clk(clk), .a_addr(addr[15:1]), .a_din(wdata), .a_be(be),
    .a_we(cxlat_we), .a_q(cxlat_q),
    .b_clk(r3d_clk), .b_addr(r3d_xlat_addr), .b_q(r3d_xlat_data)
  );

  // I/O 0xc00000-0xc00fff
  //
  // The real board has an MB8421 here — a true dual-port RAM, V60 on one side
  // and the I/O board on the other. **Quartus 17.0 will not infer one from this
  // array.** Measured, not assumed: adding a second write port took m1_mainram
  // from 192 ALM / 324 M10K to 16,059 ALM / 322 M10K, because 2048x8 of
  // dpram_lo fell out of block RAM into 16,384 flip-flops — and the fit
  // reported success. Both the textbook true-dual-port shape and the same shape
  // with `no_rw_check` were tried at 2048 entries on their own; both gave zero
  // M10K. See docs/rtl-conventions.md.
  //
  // So the two masters share one physical write port, with the V60 taking
  // priority and the I/O side told to wait. That is behaviourally identical
  // here: the I/O board writes about three bytes across an entire boot, and
  // io_ack makes the stall explicit rather than dropping a write on a
  // collision. What it gives up is simultaneous writes from both sides, which
  // nothing in this design does.
  logic        dp_we;
  logic [10:0] dp_waddr;
  logic [7:0]  dp_wdata;
  logic        v60_dp_write;

  always_comb begin
    v60_dp_write = dpram_we && be[0];
    if (v60_dp_write) begin
      dp_we    = 1'b1;
      dp_waddr = addr[11:1];
      dp_wdata = wdata[7:0];
    end else begin
      dp_we    = io_we;
      dp_waddr = io_addr;
      dp_wdata = io_din;
    end
    // The I/O write landed this cycle. Held low while the V60 owns the port,
    // which is what the responder waits on.
    io_ack = io_we && !v60_dp_write;
  end

  (* ramstyle = "M10K" *) logic [7:0] dpram_lo [2048];
  (* ramstyle = "M10K" *) logic [7:0] dpram_hi [2048];
  // THE I/O BOARD SHARES THE V60'S READ PORT rather than getting a copy.
  //
  // An M10K has two ports and dpram_lo uses both - the shared write and the
  // V60's read - so a third reader needs either a duplicate array or the
  // existing port on the cycles nobody else wants it. The duplicate was tried
  // first and cost 2 blocks, which the design cannot spare: adding the Z80
  // board took memory to 546 of 553 and the framework's scaler path from
  // +0.325 ns to -2.003, because placement at 99% memory is what lengthens it.
  //
  // Sharing is safe here in a way it would not be for a CPU. The Z80 sets the
  // DPRAM address through the 315-5338A with one command and reads the data
  // back with a later one, so its address is held for hundreds of cycles and
  // it does not care which of them answers. The V60 keeps absolute priority
  // and never waits.
  // ONE READ SITE, NOT TWO - the same trap m1_quad_store documents.
  //
  // Writing `dpram_lo[v60 ? a : b]` in one place and `dpram_lo[b]` in another
  // is two reads of one array as far as synthesis is concerned, and Quartus
  // answers the second by DUPLICATING the memory: dpram_lo_rtl_0 and
  // dpram_lo_rtl_1 in the fit report, which is exactly the 2 blocks this was
  // meant to save. So the array is read once, at a muxed address, and the two
  // consumers take their answer from that one registered value.
  wire dp_v60_rd = sel_dpram;
  logic       dp_lo_q;
  logic [7:0] dp_lo_d;
  logic [7:0] dpram_hi_q;
  always_ff @(posedge clk) begin
    if (dp_we)             dpram_lo[dp_waddr]   <= dp_wdata;
    if (dpram_we && be[1]) dpram_hi[addr[11:1]] <= wdata[15:8];
    dp_lo_d    <= dpram_lo[dp_v60_rd ? addr[11:1] : io_raddr];
    dp_lo_q    <= dp_v60_rd;                 // whose answer dp_lo_d carries
    dpram_hi_q <= dpram_hi[addr[11:1]];
    // The I/O board's copy updates only on cycles the V60 was not reading, so
    // it is always this array's answer to io_raddr and never the CPU's word.
    if (!dp_lo_q) io_rdata <= dp_lo_d;
  end
  assign dpram_q = {dpram_hi_q, dp_lo_d};

  // ------------------------------------------------- POWER-ON CONTENTS ARE ZERO
  //
  // Not a simulation convenience. Cyclone V M10K blocks take their contents from
  // the FPGA configuration bitstream, so on the device every one of these comes up
  // cleared. Leaving them undefined in RTL makes simulation disagree with the
  // hardware it models — and Verilator brings unpacked arrays up as ONES, so the
  // disagreement is maximal rather than subtle.
  //
  // `mb86233_mem.sv` already carries this reasoning and this fix, and says it was
  // found by lockstep: a program read address 0x6a before writing it, the reference
  // returned 0 and the DUT returned 0x26000000, and it "looked exactly like a
  // transfer bug for several rounds of narrowing". The same thing then happened
  // again in `m1_copro_if` on 2026-08-18 and cost most of a session: the V60 waits
  // at FED5A4 for coprocessor RAM to read zero, read 0xffffffff instead, and span
  // 1,120,224 times without ever leaving the loop. Four layers of RTL between the
  // bus and the array were read and found correct.
  //
  // DPRAM is the one here that is demonstrably read before it is written — the I/O
  // board only fills 0x00-0x0e, 0x20 and 0x100-0x17f, so every other byte is
  // whatever the array came up as. The rest are swept with it rather than waiting to
  // find out which of them matters.
  //
  // NOT A RESET. Quartus 17.0 will not infer RAM from an array that is reset, and
  // building 348,160 entries out of flip-flops is a failure this project has already
  // paid for twice.
  //
  // SIMULATION ONLY, AND GUARDED ON `VERILATOR` RATHER THAN ON A PRAGMA. The device
  // does this by itself: Cyclone V M10K powers up cleared, so hardware needs no
  // initialiser at all — only Verilator, which brings unpacked arrays up as ones.
  //
  // `synthesis translate_off` is the obvious wrapper and it is WRONG here: Verilator
  // honours that pragma too and skips the code, which is exactly how the first attempt
  // at the copro-RAM fix changed nothing at all. Leaving it unguarded is also wrong,
  // and cost a 25-minute build — Quartus caps a loop at 5,000 iterations and these run
  // to 32,768, so synthesis fails with "loop must terminate within 5000 iterations" and
  // the whole hierarchy under it fails to elaborate. The guard macro below is
  // predefined by every simulator build here (lint, test, m1_boot, m1_frame) and
  // by no synthesis tool.
  //
  // Do NOT begin a comment line with the simulator's name: `// <name> ...` is
  // valid metacomment syntax, so the line is parsed as a pragma and the build
  // dies with BADVLTPRAGMA. This comment did exactly that.
  // CHUNKED, NOT GUARDED. Quartus caps a loop at 5,000 iterations and these run
  // to 32,768, which is why this was wrapped in `VERILATOR` earlier today - and
  // wrapping it removed the initialisation from the DEVICE, which is exactly the
  // bug that left the coprocessor's RAM reading ffff on the board. Splitting
  // each sweep into 4,096-word chunks is under the cap and initialises the
  // inferred M10K for both tools.
  //
  // Cyclone V M10K does come up cleared, so this is belt and braces here - but
  // the coprocessor RAM proved that "the device does it anyway" is a bad thing
  // to rely on when the simulator is relying on the initialiser.
  integer zi, zc;
  initial begin
    // The display lists and the translation table are cleared inside m1_tdp_ram
    // now, along with the tile RAM and the palette. Only the DPRAM is still a
    // plain array here.
    for (zi = 0; zi < 2048; zi = zi + 1) begin
      dpram_lo[zi] = 8'd0; dpram_hi[zi] = 8'd0;
    end
  end

endmodule
