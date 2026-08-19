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
// Everything built so far, as one design — now with the two clock domains the
// core actually needs.
//
// WHY TWO CLOCKS
//
// The V60 closes at 24.62 MHz. The tilemap fetch engine costs 699 cycles per
// layer per scanline on repeated tiles and 1,614 on distinct ones, and a
// scanline is 656 pixel clocks at the 16 MHz dot clock — 41 us. Four layers
// therefore want 2,796-6,456 cycles, which is 68 MHz at the absolute minimum
// and closer to 100 for any margin. Those two numbers cannot be the same clock,
// and a clock enable does not bridge them: ce decides when the CPU advances,
// every path still has to meet setup at the actual clock.
//
// So the CPU and its bus run on clk_cpu, and memory, ROM loading, video fetch
// and scanout run on clk_sys. Everything that crosses does so through a module
// written for it: m1_cdc_port for the data port, m1_fetch_bridge for the
// instruction port, m1_cdc_pulse for the frame interrupt, and the video-side
// tilemap and palette copies inside m1_mainram, which are dual-clock RAMs and
// need no handshake because only the CPU writes them.
//
// The earlier single-clock version of this file measured 24.62 MHz and that was
// an Fmax figure — it was never checked against the video's own scanline
// budget, which it fails by three to six times.
//
// It is still not the core: no MiSTer framework, no PLL, no reset sequencing
// beyond the synchronisers here, and the TGP is not instantiated.
//
// The ports are deliberately narrow so the fitter cannot optimise the design
// away through unconnected outputs, and every real interface is brought out.

`timescale 1ns/1ps

module m1_integrated (
  // Fast domain: memory, ROM loading, video fetch and scanout. 96 MHz gives an
  // exact 16 MHz dot clock at ce_pix = /6.
  input  logic        clk_sys,
  input  logic        ce_pix,

  // Slow domain: the V60 and its bus. 24 MHz sits under the 24.62 MHz the core
  // closes at, and ce_cpu throttles it from there.
  input  logic        clk_cpu,
  input  logic        ce_cpu,

  // Asynchronous, released into both domains by the synchronisers below.
  input  logic        rst_n,

  // The memory subsystem's reset: PLL lock only, never the OSD or game reset.
  // The ROM loader lives on this one because it holds the HPS off while SDRAM
  // is initialising, and MiSTer resets the core while streaming a ROM — so a
  // loader on the game reset waits for SDRAM that is held in reset, while the
  // HPS waits for the loader. See Model1.sv.
  input  logic        mem_rst_n,

  // SDRAM BRING-UP DONE. NOT "THE ROM IS LOADED".
  //
  // The loader needs this to know the controller can accept a write, and the
  // V60 needs to know something else entirely — that a ROM has actually
  // arrived. This port used to be called rom_loaded and served both, which
  // reads as harmless until the top level tries to gate the CPU with it.
  //
  // Feeding it `mem_ready & <loader's rom_loaded>` deadlocks the machine: the
  // loader holds ioctl_wait while ~mem_ready, mem_ready is now false until the
  // loader finishes, and the loader cannot finish because the HPS is waiting
  // on ioctl_wait. On screen that is "Assembling ROM" frozen at zero bytes,
  // and in simulation it is a download that never places its first word.
  //
  // So the CPU's gate is derived HERE, from the loader's own output, and never
  // routed out through the top level and back in.
  input  logic        mem_ready,      // clk_sys domain

  // Control state for the I/O board, idle-high. Crosses into the CPU domain
  // inside m1_main; it changes at human speed and is read by a polling CPU, so
  // a synchroniser buys nothing a metastable bit would not survive anyway.
  input  logic [119:0] in_bytes,

  // SDRAM data port and instruction fetch
  output logic        sdr_req,
  output logic        sdr_we,
  output logic [24:1] sdr_addr,
  output logic [15:0] sdr_din,
  output logic [1:0]  sdr_be,
  input  logic [15:0] sdr_dout,
  input  logic        sdr_ack,

  output logic        if_req,
  output logic [23:0] if_addr,
  output logic [24:1] if_sdram_addr,
  input  logic [63:0] if_data,
  input  logic        if_ack,

  // Character RAM fetch, for the tilemap
  output logic        char_req,
  output logic [17:0] char_addr,
  input  logic [31:0] char_data,
  input  logic        char_ack,

  // ROM download
  input  logic        ioctl_download,
  input  logic [15:0] ioctl_index,
  input  logic        ioctl_wr,
  input  logic [26:0] ioctl_addr,
  input  logic [15:0] ioctl_dout,
  output logic        ioctl_wait,
  output logic        ldr_wr_req,
  output logic [24:1] ldr_wr_addr,
  output logic [15:0] ldr_wr_din,
  output logic [1:0]  ldr_wr_be,
  input  logic        ldr_wr_ack,
  // The microcode now goes straight into m1_main's coprocessor rather than out
  // to the top level, where it was connected to nothing.
  // The coprocessor's read-only SDRAM port, in the FAST domain. 64-bit burst
  // read like the instruction fetch, because a 32-bit fetch is two words.
  output logic        tgp_mem_req,
  output logic [24:1] tgp_mem_addr,
  input  logic [63:0] tgp_mem_dout,
  input  logic        tgp_mem_ack,

  output logic [15:0] dbg_tgp_retires,
  output logic [15:0] dbg_tgp_pc,
  output logic        dbg_tgp_unimpl,
  output logic [15:0] dbg_copro_pushes,
  output logic [15:0] dbg_copro_returns,

  // Video out
  output logic [7:0]  vid_r, vid_g, vid_b,
  output logic        vid_hs, vid_vs, vid_hb, vid_vb,

  // Telemetry
  input  logic [2:0]  mon_sel,
  input  logic        mon_snap,
  output logic [23:0] mon_req, mon_grant, mon_wait,
  output logic [7:0]  mon_bmax,
  output logic [23:0] mon_total,
  input  logic [4:0]  mon_req_in,
  input  logic [4:0]  mon_grant_in,

  output logic [23:0] dbg_pc,
  output logic        dbg_halted,
  output logic        dbg_fp_trap,
  output logic [15:0] dbg_io_replies,
  output logic        rom_loaded_o,
  // Set, and stuck, if the loader ever had to drop a word the HPS sent after
  // ioctl_wait went up. Brought out because a dropped word is a corrupt ROM
  // that reports a successful load and fails much later as a CPU fault.
  output logic        ldr_overflow,
  output logic [7:0]  dbg_fetches,
  output logic [15:0] dbg_overruns,

  // Visible pixels per tilemap, per frame — see m1_video. An alarm for a layer
  // that never reaches the screen, not a proof the composite is right.
  output logic [17:0] dbg_layer_px [4],

  // Each pair's window/split-scroll control register, as the renderer read it.
  output logic [15:0] dbg_ctrl [2],

  // Non-blank tile words fetched per layer per frame — see m1_video. Separates a
  // layer that holds nothing from one holding content that is not drawn.
  output logic [11:0] dbg_layer_have [4],

  // CPU writes into tile RAM by region — see m1_main. The counterpart to
  // dbg_layer_have: one says what was written, the other what was read back.
  output logic [11:0] dbg_tram_writes [4],

  // Microcode load evidence — see m1_rom_loader. 0x800 words is a complete load.
  output logic [11:0] dbg_ucode_words,
  output logic [15:0] dbg_ucode_csum,

  // Coprocessor command-FIFO pops — see m1_main.
  output logic [15:0] dbg_copro_pops,

  // The TGP taking a command — see m1_copro_if.
  output logic [15:0] dbg_copro_drains
);

  logic [14:0] vid_tram_addr;
  logic [15:0] vid_tram_data;
  logic [11:0] vid_pal_addr;
  logic [15:0] vid_pal_data;
  logic        vblank_irq_sys, vblank_irq_cpu;
  logic [2:0]  rom_bank;

  // ------------------------------------------------------ reset into each domain
  // Asserted asynchronously, released synchronously, separately per domain. A
  // reset released on one clock and used on another is the classic way to have
  // half a design come out of reset a cycle before the rest.
  logic [1:0] rst_sync_sys, rst_sync_cpu, rst_sync_mem;
  logic       rst_n_sys, rst_n_cpu, rst_n_mem;

  always_ff @(posedge clk_sys or negedge rst_n) begin
    if (!rst_n) rst_sync_sys <= 2'b00;
    else        rst_sync_sys <= {rst_sync_sys[0], 1'b1};
  end
  always_ff @(posedge clk_cpu or negedge rst_n) begin
    if (!rst_n) rst_sync_cpu <= 2'b00;
    else        rst_sync_cpu <= {rst_sync_cpu[0], 1'b1};
  end
  always_ff @(posedge clk_sys or negedge mem_rst_n) begin
    if (!mem_rst_n) rst_sync_mem <= 2'b00;
    else            rst_sync_mem <= {rst_sync_mem[0], 1'b1};
  end

  always_comb rst_n_sys = rst_sync_sys[1];
  always_comb rst_n_cpu = rst_sync_cpu[1];
  always_comb rst_n_mem = rst_sync_mem[1];

  // The V60's release: SDRAM up AND the loader reporting the stream ended with
  // its buffer drained. A level raised in the fast domain and read in the slow
  // one, so two flops — nothing downstream cares about the two-cycle skew
  // because it only ever goes high once, before the CPU is allowed to run.
  logic rom_present;
  always_comb rom_present = mem_ready & rom_loaded_o;

  logic [1:0] rom_loaded_sync;
  always_ff @(posedge clk_cpu or negedge rst_n_cpu) begin
    if (!rst_n_cpu) rom_loaded_sync <= 2'b00;
    else            rom_loaded_sync <= {rom_loaded_sync[0], rom_present};
  end

  // The frame interrupt is one clk_sys cycle wide — about 10 ns at 96 MHz,
  // against a 42 ns slow clock. It has to be carried, not sampled.
  m1_cdc_pulse u_vblank_cdc (
    .a_clk(clk_sys), .a_rst_n(rst_n_sys), .a_pulse(vblank_irq_sys),
    .b_clk(clk_cpu), .b_rst_n(rst_n_cpu), .b_pulse(vblank_irq_cpu)
  );

  // ------------------------------------------------------------- slow domain
  logic        cpu_sdr_req, cpu_sdr_we;
  logic [24:1] cpu_sdr_addr;
  logic [15:0] cpu_sdr_din, cpu_sdr_dout;
  logic [1:0]  cpu_sdr_be;
  logic        cpu_sdr_ack;

  logic        cpu_if_req, cpu_if_ack;
  logic [23:0] cpu_if_addr;
  logic [24:1] cpu_if_sdram_addr;
  logic [63:0] cpu_if_data;

  m1_main main (
    .clk(clk_cpu), .ce(ce_cpu), .rst_n(rst_n_cpu),
    .rom_loaded(rom_loaded_sync[1]),
    .in_bytes(in_bytes),
    // Microcode from the loader, written in the FAST domain into the dual-clock
    // program RAM inside m1_tgp. Complete before the CPU is released, so there
    // is no crossing to handshake.
    .ucode_clk(clk_sys), .ucode_we(u_tgp_wr),
    .ucode_addr(u_tgp_addr), .ucode_data(u_tgp_din),
    // The TGP's math tables and 2 MB data window belong in SDRAM and are not
    // wired yet. Acknowledged with zero so the coprocessor runs rather than
    // stalling: the math units are not implemented either, so nothing it
    // computes is correct at this stage and pretending otherwise would be worse
    // than a documented zero.
    .tgp_tbl_req(t_tbl_req), .tgp_tbl_addr(t_tbl_addr),
    .tgp_tbl_rdata(t_mem_rdata), .tgp_tbl_ack(t_tbl_ack),
    .tgp_dat_req(t_dat_req), .tgp_dat_addr(t_dat_addr),
    .tgp_dat_rdata(t_mem_rdata), .tgp_dat_ack(t_dat_ack),
    .dbg_tgp_retires(dbg_tgp_retires), .dbg_tgp_pc(dbg_tgp_pc),
    .dbg_tgp_unimpl(dbg_tgp_unimpl),
    .dbg_copro_pushes(dbg_copro_pushes), .dbg_copro_returns(dbg_copro_returns),
    .sdr_req(cpu_sdr_req), .sdr_we(cpu_sdr_we), .sdr_addr(cpu_sdr_addr),
    .sdr_din(cpu_sdr_din), .sdr_be(cpu_sdr_be),
    .sdr_dout(cpu_sdr_dout), .sdr_ack(cpu_sdr_ack),
    .if_req(cpu_if_req), .if_addr(cpu_if_addr),
    .if_sdram_addr(cpu_if_sdram_addr),
    .if_data(cpu_if_data), .if_ack(cpu_if_ack),
    .vid_clk(clk_sys),
    .vid_tram_addr(vid_tram_addr), .vid_tram_data(vid_tram_data),
    .vid_pal_addr(vid_pal_addr), .vid_pal_data(vid_pal_data),
    .vblank_irq(vblank_irq_cpu),
    .dbg_pc(dbg_pc), .dbg_halted(dbg_halted), .dbg_fp_trap(dbg_fp_trap),
    .dbg_io_replies(dbg_io_replies),
    .dbg_tram_writes(dbg_tram_writes),
    .dbg_copro_pops(dbg_copro_pops),
    .dbg_copro_drains(dbg_copro_drains),
    .rom_bank(rom_bank)
  );

  logic        u_tgp_wr;
  logic [10:0] u_tgp_addr;
  logic [31:0] u_tgp_din;

  // ------------------------------- the coprocessor's read-only SDRAM regions
  //
  // copro_tables (256 KB) and copro_data (2 MB) share ONE port and one clock
  // crossing, because the TGP can only ever have one access outstanding — its
  // IO handshake holds until ack. Two ports would cost a second m1_cdc_port to
  // no purpose.
  //
  // Word bases follow the packer: copro_data at SDRAM word 0x300000, tables at
  // 0x400000, both immediately above the V60 image so the download stream stays
  // contiguous. Each is a 32-bit fetch, which is TWO 16-bit SDRAM words.
  localparam logic [24:1] COPRO_DAT_BASE = 24'h300000;
  localparam logic [24:1] COPRO_TBL_BASE = 24'h400000;

  logic        t_tbl_req, t_tbl_ack, t_dat_req, t_dat_ack;
  logic [15:0] t_tbl_addr;
  logic [18:0] t_dat_addr;
  logic [31:0] t_mem_rdata;

  // ONE REQUEST LINE, TWO MASTERS: FORCE A DEAD CYCLE WHEN THE OWNER CHANGES.
  //
  // t_mem_req is the OR of both requesters, so when a table read ends and a data
  // read begins on the SAME cycle the line never falls. The CDC port sees one
  // continuous request, keeps its acknowledge asserted, and the new master
  // captures the PREVIOUS transaction's data - a stale read that looks exactly
  // like a wrong value from the ROM.
  //
  // Measured: tgp_wrtrace write 455, data[0x305], where the reference reads
  // 41b39db2 and we read 41f00000, which is the word our PREVIOUS read returned.
  // One word in four thousand, because it needs a table access immediately
  // followed by a data access with no gap - which is a sequence the math units
  // only started producing once they were implemented.
  //
  // Suppressing the request for the cycle in which the owner changes costs one
  // cycle of latency on a master switch and guarantees the port sees a clean
  // boundary. The alternative - latching the owner when the transaction starts -
  // needs to know the CDC port's accept semantics, and a dead cycle needs to know
  // nothing.
  logic        t_prev_tbl;
  always_ff @(posedge clk_cpu or negedge rst_n_cpu)
    if (!rst_n_cpu) t_prev_tbl <= 1'b0;
    else            t_prev_tbl <= t_tbl_req;
  wire         t_owner_change = (t_tbl_req != t_prev_tbl);
  wire         t_mem_req  = (t_tbl_req || t_dat_req) && !t_owner_change;
  wire [24:1]  t_mem_addr = t_tbl_req
                          ? (COPRO_TBL_BASE + {7'd0, t_tbl_addr, 1'b0})
                          : (COPRO_DAT_BASE + {4'd0, t_dat_addr, 1'b0});

  // A 32-bit read is two 16-bit words. The SDRAM port returns a 64-bit burst,
  // so one transaction covers both halves and the low 32 bits are the word.
  logic t_mem_ack;
  assign t_tbl_ack = t_mem_ack &&  t_tbl_req;
  assign t_dat_ack = t_mem_ack && !t_tbl_req && t_dat_req;

  // Named rather than left empty: an empty-by-name pin and a forgotten one look
  // identical in a diff, and one of those was the bug above.
  logic        tgp_mem_unused_we;
  logic [31:0] tgp_mem_unused_din;
  logic [1:0]  tgp_mem_unused_be;

  // The crossing, THIRTY-TWO BITS WIDE.
  //
  // A coprocessor fetch is one 32-bit word, which is two 16-bit SDRAM words, and
  // the controller returns a 64-bit burst — so the low 32 bits of one burst are
  // the whole answer and DW=32 carries it back in a single transaction.
  //
  // The first version used DW=16 and connected the SDRAM's data to `b_dout`
  // while leaving `a_dout` open. b_dout is the INPUT carrying data from the far
  // side; a_dout is the OUTPUT to the requester. So the requester's wire was
  // driven by nothing and every read returned zero — with the accesses
  // completing normally, which is what made it look like an address fault. The
  // two captured data words are what localised it.
  m1_cdc_port #(.AW(24), .DW(32), .BEW(2)) u_tgp_mem_cdc (
    .a_clk(clk_cpu), .a_rst_n(rst_n_cpu),
    .a_req(t_mem_req), .a_we(1'b0), .a_addr(t_mem_addr),
    .a_din(32'd0), .a_be(2'b11),
    .a_dout(t_mem_rdata), .a_ack(t_mem_ack), .a_busy(),
    .b_clk(clk_sys), .b_rst_n(rst_n_sys),
    .b_req(tgp_mem_req), .b_we(tgp_mem_unused_we), .b_addr(tgp_mem_addr),
    .b_din(tgp_mem_unused_din), .b_be(tgp_mem_unused_be),
    // A 4-word burst carries TWO 32-bit words. Which one was asked for is bit 1
    // of the address, and the top level aligns the request down to the burst
    // boundary — a burst port's address must be burst-aligned.
    .b_dout(tgp_mem_addr[1] ? tgp_mem_dout[63:32] : tgp_mem_dout[31:0]),
    .b_ack(tgp_mem_ack)
  );

  // ------------------------------------------------------------- the crossings
  logic cpu_sdr_busy;

  m1_cdc_port #(.AW(24), .DW(16), .BEW(2)) u_data_cdc (
    .a_clk(clk_cpu), .a_rst_n(rst_n_cpu),
    .a_req(cpu_sdr_req), .a_we(cpu_sdr_we), .a_addr(cpu_sdr_addr),
    .a_din(cpu_sdr_din), .a_be(cpu_sdr_be),
    .a_dout(cpu_sdr_dout), .a_ack(cpu_sdr_ack), .a_busy(cpu_sdr_busy),
    .b_clk(clk_sys), .b_rst_n(rst_n_sys),
    .b_req(sdr_req), .b_we(sdr_we), .b_addr(sdr_addr),
    .b_din(sdr_din), .b_be(sdr_be),
    .b_dout(sdr_dout), .b_ack(sdr_ack)
  );

  // if_addr is still brought out because the burst port's consumer wants the
  // raw address for telemetry; the bridge itself only needs its low three bits.
  always_comb if_addr = cpu_if_addr;

  m1_fetch_bridge u_fetch (
    .cpu_clk(clk_cpu), .cpu_rst_n(rst_n_cpu),
    .if_req(cpu_if_req), .if_off(cpu_if_addr[2:0]),
    .if_sdram_addr(cpu_if_sdram_addr),
    .if_data(cpu_if_data), .if_ack(cpu_if_ack),
    .mem_clk(clk_sys), .mem_rst_n(rst_n_sys),
    .p_req(if_req), .p_addr(if_sdram_addr),
    .p_dout(if_data), .p_ack(if_ack)
  );

  // ------------------------------------------------------------- fast domain
  m1_video video (
    .clk(clk_sys), .ce_pix(ce_pix), .rst_n(rst_n_sys),
    .tile_mask(14'h3fff),
    .tram_addr(vid_tram_addr), .tram_data(vid_tram_data),
    .char_req(char_req), .char_addr(char_addr),
    .char_data(char_data), .char_ack(char_ack),
    .pal_addr(vid_pal_addr), .pal_data(vid_pal_data),
    .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
    .vid_hs(vid_hs), .vid_vs(vid_vs), .vid_hb(vid_hb), .vid_vb(vid_vb),
    .vblank_irq(vblank_irq_sys), .dbg_fetches(dbg_fetches),
    .dbg_overruns(dbg_overruns), .dbg_layer_px(dbg_layer_px),
    .dbg_ctrl(dbg_ctrl), .dbg_layer_have(dbg_layer_have)
  );

  m1_rom_loader loader (
    .clk(clk_sys), .rst(~rst_n_mem), .mem_ready(mem_ready),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .sdr_wr_req(ldr_wr_req), .sdr_wr_addr(ldr_wr_addr),
    .sdr_wr_din(ldr_wr_din), .sdr_wr_be(ldr_wr_be), .sdr_wr_ack(ldr_wr_ack),
    .tgp_wr(u_tgp_wr), .tgp_addr(u_tgp_addr), .tgp_din(u_tgp_din),
    .ucode_words(dbg_ucode_words), .ucode_csum(dbg_ucode_csum),
    .rom_loaded(rom_loaded_o), .overflow(ldr_overflow)
  );

  bw_monitor #(.MASTERS(5), .CW(24), .BW(8)) mon (
    .clk(clk_sys), .rst_n(rst_n_sys),
    .req(mon_req_in), .grant(mon_grant_in),
    .snap(mon_snap), .sel(mon_sel),
    .req_count(mon_req), .grant_count(mon_grant), .wait_count(mon_wait),
    .burst_max(mon_bmax), .total_cycles(mon_total)
  );

endmodule
