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
  // The 3D layer's clock, 47.059 MHz - an exact half of nothing here, but an
  // exact DOUBLE of clk_cpu, which is what keeps that crossing cheap.
  input  logic        clk_3d,

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

  // The 3D layer's two SDRAM masters, in the clk_sys domain like the others.
  // p5 bursts the polygon models, p6 carries tgp_ram.
  output logic        r3d_rom_req,
  output logic [24:1] r3d_rom_addr,
  input  logic [63:0] r3d_rom_dout,
  input  logic        r3d_rom_ack,
  output logic        r3d_tex_req,
  output logic        r3d_tex_we,
  output logic [24:1] r3d_tex_addr,
  output logic [15:0] r3d_tex_din,
  input  logic [15:0] r3d_tex_dout,
  input  logic        r3d_tex_ack,

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

  // ------------------------------------------------ SDRAM read-back self-test
  //
  // MOVED HERE FROM Model1.sv SO A TESTBENCH CAN SEE IT. It was written and
  // flashed without ever being simulated, and it returned 04FFFB where the
  // hand-folded image says 63110D - a number that could equally mean SDRAM is
  // wrong or that this FSM is. tb_m1_frame drives m1_integrated against the
  // SDRAM model, so with the sweep in here simulation produces the expected
  // value through THE SAME LOGIC, which also retires my hand-written assumption
  // about burst word order (neither it nor its reverse matches the board).
  output logic        rb_req,
  output logic [24:1] rb_addr,
  input  logic [63:0] rb_dout,
  input  logic        rb_ack,
  output logic [23:0] dbg_rb_csum,     // math tables, word 0x400000
  output logic [23:0] dbg_rb_csum0,    // V60 ROM, word 0 - the control
  output logic [12:0] dbg_rb_n,      // bursts actually completed

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
  output logic [23:0] dbg_ucode_ram_csum,
  output logic        dbg_ucode_ram_ok,
  output logic [11:0] dbg_tgp_ram_writes,
  output logic [15:0] dbg_sync_word,
  output logic [11:0] dbg_tm0_writes,
  output logic [11:0] dbg_tm0_text_writes,
  output logic [11:0] dbg_mask_nz_writes,
  output logic [23:0] dbg_tm0_first_pc,
  output logic [11:0] dbg_mask_writes,
  // A CHECKSUM OF EVERYTHING THE COPROCESSOR READS FROM SDRAM.
  //
  // The math tables and the 2 MB data window are read at RUNTIME over the SDRAM
  // port, and docs/00-decisions.md records that interface as having no timing
  // constraints and a read capture phase found empirically. The board shows the
  // coprocessor retiring instructions and consuming commands while never
  // clearing the V60's sync word, which is what wrong ARITHMETIC looks like from
  // outside - a different microcode path, taken confidently.
  //
  // Simulation reads the same words from a model. Folding both sides the same
  // way turns "are the reads good on hardware" from a guess into one comparison.
  output logic [23:0] dbg_copro_rd_csum,
  output logic [23:0] dbg_rd_a0, dbg_rd_a1, dbg_rd_a2, dbg_rd_a3,

  // Microcode load evidence — see m1_rom_loader. 0x800 words is a complete load.
  output logic [11:0] dbg_ucode_words,
  output logic [15:0] dbg_ucode_csum,
  output logic [23:0] dbg_sdram_csum,
  output logic [23:0] dbg_sdram_words,

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
    // The 3D layer's second ports into the display lists, the colour-translation
    // table and the palette mirror, all read from clk_3d.
    .r3d_clk(clk_3d),
    .r3d_dl_addr(r3d_dl_addr), .r3d_dl_data(r3d_dl_data),
    .listctl_sel(listctl_sel), .r3d_dl_sel(r3d_dl_sel),
    .r3d_xlat_addr(r3d_xlat_addr), .r3d_xlat_data(r3d_xlat_data),
    .r3d_pal_addr(r3d_pal_addr), .r3d_pal_data(r3d_pal_data),
    .vblank_irq(vblank_irq_cpu),
    .dbg_pc(dbg_pc), .dbg_halted(dbg_halted), .dbg_fp_trap(dbg_fp_trap),
    .dbg_io_replies(dbg_io_replies),
    .dbg_tram_writes(dbg_tram_writes),
    .dbg_ucode_ram_csum(dbg_ucode_ram_csum), .dbg_ucode_ram_ok(dbg_ucode_ram_ok),
    .dbg_tgp_ram_writes(dbg_tgp_ram_writes), .dbg_sync_word(dbg_sync_word),
    .dbg_tm0_writes(dbg_tm0_writes), .dbg_mask_writes(dbg_mask_writes),
    .dbg_tm0_text_writes(dbg_tm0_text_writes), .dbg_tm0_first_pc(dbg_tm0_first_pc),
    .dbg_mask_nz_writes(dbg_mask_nz_writes),
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
  // Sweep the math-table region and fold what SDRAM RETURNS. Sequential on
  // purpose: the V60 reads SDRAM correctly all day while the coprocessor's
  // tables are scattered across 256 KB, so a clean sequential sweep would put
  // the fault in the access PATTERN rather than in the data.
  // TWO REGIONS, SWEPT IN TURN.
  //
  // The board reads back the math tables as 04FFFB where the model gives 991AF0,
  // and it gives the SAME wrong value from two different builds - so this is not
  // marginal timing, which would vary, but something systematic about that
  // region. The discriminator is to sweep a region the V60 provably reads
  // correctly: word 0 is V60 program ROM, and the CPU executes from it all day.
  //
  //   region 0 right, region 1 wrong   the fault is specific to the high region
  //                                    - addressing, size or a write that never
  //                                    landed - and not the read path at all
  //   both wrong                       the read path or this sweep is at fault,
  //                                    and everything inferred from row 0C so far
  //                                    needs re-examining
  // THE WHOLE IMAGE, NOT A WINDOW.
  //
  // Two 16 K-word windows both matched the model, and that proved only that
  // those two windows are good. The image is 0x420000 words and a dropped word
  // anywhere in it is a ROM with a hole - reported as a successful load, because
  // rows 07 and 0B are folded at the IOCTL INPUT, before the FIFO. The loader is
  // hardened for that (FIFO_DEPTH 512, WAIT_MARGIN 256, after 8/6 was measured
  // dropping words at 16 cycles of host reaction) but hardened is not verified.
  //
  // 0x420000 words is 0x108000 bursts of four.
  localparam int          RB_BURSTS = 24'h108000;
  logic        rb_done;
  logic        rb_region;                          // 0 = V60 ROM, 1 = math tables
  logic [23:0] rb_n;
  assign dbg_rb_n = rb_n[12:0];
  wire [24:1] rb_region_base = rb_region ? 24'h400000 : 24'h000000;

  // THE FAST DOMAIN. The SDRAM ports are clk_sys; clocking this sweep on clk_cpu
  // missed the acknowledge and completed exactly ONE burst of 4096, which is how
  // the flaw was found - in simulation, where it was cheap.
  always_ff @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) begin
      rb_addr <= 24'd0; rb_req <= 1'b0; rb_done <= 1'b0; rb_region <= 1'b0;
      dbg_rb_csum <= 24'd0; dbg_rb_csum0 <= 24'd0; rb_n <= 24'd0;
    end else if (rom_present && !rb_done) begin
      if (!rb_req) begin
        rb_req <= 1'b1;
      end else if (rb_ack) begin
        rb_req  <= 1'b0;
        rb_addr <= rb_addr + 24'd4;
        rb_n    <= rb_n + 13'd1;
        // ONE CHECKSUM PER BURST HALF, BOTH OVER THE SAME REGION.
        //
        // The coprocessor takes a 32-bit word out of a 64-bit burst with
        //   tgp_mem_addr[1] ? rb_dout[63:32] : rb_dout[31:0]
        // and the sweep has only ever folded rb_dout[23:0] - the LOW half. If
        // the device returns the halves in a different order than the model,
        // the coprocessor reads wrong data while this sweep reports everything
        // correct. It did report everything correct, on both regions, which is
        // exactly the blind spot.
        //
        // Region 0 now folds the LOW half and region 1 the HIGH half of the SAME
        // math-table region, so the two rows are directly comparable:
        //   0E matches, 0C differs   the halves are swapped or the high half is
        //                            wrong, and the coprocessor is the only
        //                            master that cares
        // Both halves of every burst, folded separately: the low half is what the
        // sweep has always checked, and the high half is what the coprocessor
        // reads for an odd table index and nothing has ever verified.
        dbg_rb_csum0 <= {dbg_rb_csum0[22:0], dbg_rb_csum0[23]} ^ rb_dout[23:0];
        dbg_rb_csum  <= {dbg_rb_csum[22:0],  dbg_rb_csum[23]}  ^ rb_dout[55:32];
        if (rb_n == 24'(RB_BURSTS - 1)) begin
          rb_n <= 24'd0;
          begin
            rb_done <= 1'b1;
            rb_n    <= 24'(RB_BURSTS);   // leave the count showing completion
          end
        end
      end
    end
  end

  logic t_mem_ack;

  // Fold the FIRST 1024 acknowledged words and then FREEZE.
  //
  // Folding everything since reset was the obvious thing and it is useless: the
  // checksum then depends on how many reads have happened, and the board is
  // parked at FED5A4 while simulation runs on, so the two would differ even if
  // every read were perfect. A fixed window makes the comparison mean something
  // - both machines execute the same early boot, and v60_trace shows the V60
  // matching the reference instruction for instruction through it.
  //
  // Rotate then XOR, not plain XOR, so two swapped reads do not cancel: that is
  // a failure mode a marginal capture phase actually produces.
  // THE FIRST FOUR READ ADDRESSES, NOT JUST A FOLD OF THEM.
  //
  // The checksum says the coprocessor reads something different on hardware and
  // says nothing about WHERE. SDRAM is verified whole-image and the microcode is
  // verified byte-identical, so it is reading different ADDRESSES - a different
  // path through the same code - and the first divergent read is the thing to
  // find. Four addresses is four rows; if they all match, the split is later and
  // the window moves.
  logic [10:0] rd_n;
  always_ff @(posedge clk_cpu or negedge rst_n_cpu) begin
    if (!rst_n_cpu) begin
      dbg_copro_rd_csum <= 24'd0;
      rd_n              <= 11'd0;
      dbg_rd_a0 <= 24'd0; dbg_rd_a1 <= 24'd0;
      dbg_rd_a2 <= 24'd0; dbg_rd_a3 <= 24'd0;
    end else if ((t_tbl_ack || t_dat_ack) && !rd_n[10]) begin
      dbg_copro_rd_csum <= {dbg_copro_rd_csum[22:0], dbg_copro_rd_csum[23]}
                         ^ t_mem_rdata[23:0];
      rd_n              <= rd_n + 11'd1;
      // THE WORD ADDRESS, NOT THE BYTE ADDRESS. {t_mem_addr, 1'b0} is 25 bits and
      // the row carries 24, so the math tables at word 0x400000 - byte 0x800000
      // - truncated to 000000 and every captured address read as zero.
      // BISECTING THE DIVERGENCE. Reads 0 and 1 match the model exactly on
      // hardware while the fold over all 1024 differs, so the split is later
      // than read 4. Sampling at 64, 256 and 512 halves the range each build -
      // the method that took tgp_wrtrace from "diverges at write 38" to a named
      // instruction, nine times over.
      if (rd_n == 11'd0)   dbg_rd_a0 <= t_mem_addr;   // row 0E
      if (rd_n == 11'd64)  dbg_rd_a1 <= t_mem_addr;   // row 07
      if (rd_n == 11'd256) dbg_rd_a2 <= t_mem_addr;   // row 0B
      if (rd_n == 11'd512) dbg_rd_a3 <= t_mem_addr;   // row 1B
    end
  end
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

  // ------------------------------------------------------------- the 3D layer
  //
  // m1_raster3d is the whole 3D path in one block: the display-list walk, the
  // geometry, the painter's sort, the fill and the band buffers. It runs on its
  // own 47.059 MHz clock because the shared FP pool measures 53.25 MHz and the
  // fill unit 63.75 - clk_sys's 80 does not close - and reads five memories.
  //
  // WHERE ITS TWO SDRAM REGIONS LIVE
  //
  //   polygon models  0x840000 bytes = word 0x420000, 16 MB, read-only, in the
  //                   ROM image (mra/*.mra and tools/build_rom_image.py)
  //   tgp_ram         word 0xC20000, 786,432 words, read/write at run time,
  //                   ABOVE the 25.4 MB ROM image and inside the 32 MB device
  //
  // tgp_ram is not part of the ROM image: it is written by display-list command
  // 4 while the game runs. It is far too large for M10K - 12.6 Mbit against the
  // device's 5.5 - and declaring it as an array would have Quartus build it from
  // flip-flops without saying so.
  localparam logic [24:1] POLY_BASE    = 24'h420000;
  localparam logic [24:1] TGP_RAM_BASE = 24'hC20000;

  logic        rst_n_3d;
  logic [1:0]  rst_sync_3d;
  always_ff @(posedge clk_3d or negedge rst_n) begin
    if (!rst_n) rst_sync_3d <= 2'b00;
    else        rst_sync_3d <= {rst_sync_3d[0], 1'b1};
  end
  assign rst_n_3d = rst_sync_3d[1];

  // The frame pulse. vblank_irq_sys is one clk_sys cycle; m1_cdc_pulse is what
  // this design already uses to carry a pulse across a domain, and a pulse is
  // exactly what must not be sampled directly.
  logic frame_start_3d;
  m1_cdc_pulse u_frame_pulse (
    .a_clk(clk_sys), .a_rst_n(rst_n_sys), .a_pulse(vblank_irq_sys),
    .b_clk(clk_3d),  .b_rst_n(rst_n_3d),  .b_pulse(frame_start_3d)
  );

  logic [22:0] r3_rom_addr;
  logic        r3_rom_req, r3_rom_valid;
  logic [31:0] r3_rom_data;
  logic [19:0] r3_tex_addr;
  logic        r3_tex_req, r3_tex_valid, r3_tex_we;
  logic [15:0] r3_tex_data, r3_tex_wdata;
  logic [14:0] r3_dl_addr;
  logic        r3_dl_req, r3_dl_valid;
  wire  [15:0] r3_dl_data;
  logic [12:0] r3_pal_addr;
  logic [14:0] r3_xlat_addr;
  logic [23:0] r3_scan_rgb;
  logic        r3_scan_hit;
  logic [15:0] r3_dbg_objects, r3_dbg_quads, r3_dbg_dropped, r3_dbg_frames;
  logic [5:0]  r3_disp_band;
  logic        r3_disp_valid;

  // The read ports m1_main exposes for the 3D layer, and the buffer select.
  logic [14:0] r3d_dl_addr;
  wire  [15:0] r3d_dl_data;
  // The live listctl bit out of m1_main, and the latched one coming back from
  // the 3D layer. The read port uses the latched one.
  wire         listctl_sel;
  wire         r3d_dl_sel;
  logic [14:0] r3d_xlat_addr;
  wire  [15:0] r3d_xlat_data;
  logic [9:0]  r3d_pal_addr;
  wire  [15:0] r3d_pal_data;

  // The raster position, from the video timing.
  logic [9:0]  vid_hpos, vid_vpos;

  // The display list and the translation table answer in one cycle from their
  // second port, so `valid` is the request delayed by one. The palette mirror is
  // the same and needs no handshake at all.
  always_ff @(posedge clk_3d or negedge rst_n_3d) begin
    if (!rst_n_3d) r3_dl_valid <= 1'b0;
    else           r3_dl_valid <= r3_dl_req;
  end

  m1_raster3d u_raster3d (
    .clk(clk_3d), .rst_n(rst_n_3d),
    .frame_start(frame_start_3d), .dl_sel(listctl_sel), .dl_sel_q(r3d_dl_sel),
    .dl_addr(r3_dl_addr), .dl_req(r3_dl_req),
    .dl_valid(r3_dl_valid), .dl_data(r3_dl_data),
    .rom_addr(r3_rom_addr), .rom_req(r3_rom_req),
    .rom_valid(r3_rom_valid), .rom_data(r3_rom_data),
    .tex_addr(r3_tex_addr), .tex_req(r3_tex_req),
    .tex_we(r3_tex_we), .tex_wdata(r3_tex_wdata),
    .tex_valid(r3_tex_valid), .tex_data(r3_tex_data),
    .pal_addr(r3_pal_addr), .pal_data(r3d_pal_data),
    .xlat_addr(r3_xlat_addr), .xlat_data(r3d_xlat_data),
    .frame_odd(1'b0),
    .scan_clk(clk_sys), .scan_x(vid_hpos), .scan_y(vid_vpos),
    .scan_rgb(r3_scan_rgb), .scan_hit(r3_scan_hit),
    .disp_band(r3_disp_band), .disp_valid(r3_disp_valid),
    .dbg_objects(r3_dbg_objects), .dbg_quads(r3_dbg_quads),
    .dbg_dropped(r3_dbg_dropped), .dbg_frames(r3_dbg_frames)
  );

  // The display list's data comes back from m1_main's second port.
  assign r3_dl_data    = r3d_dl_data;
  assign r3d_pal_addr  = r3_pal_addr[9:0];
  assign r3d_xlat_addr = r3_xlat_addr;
  assign r3d_dl_addr   = r3_dl_addr;

  // ---- polygon models, through p5.
  //
  // rom_addr counts 32-bit model words; SDRAM counts 16-bit words, so the
  // address doubles. p5 bursts four 16-bit words, which is TWO model words, and
  // a burst port's address must be burst-aligned - so the request is aligned
  // down and bit 0 of the model address picks which half came back. Exactly the
  // arrangement u_tgp_mem_cdc uses on p3, and for the same reason.
  // THE FULL ADDRESS CROSSES, AND THE ALIGNMENT HAPPENS AT THE SDRAM PIN.
  //
  // Aligning here instead destroys the very bit the half-select needs. POLY_BASE
  // is 4-aligned and forcing the low two bits to zero makes rom_sdram_addr[1]
  // always zero - so every odd model word came back with the EVEN word's data
  // and half of every polygon model was wrong. On the board that is objects of
  // the wrong shape, which is what it looked like.
  //
  // p3 has always done it the other way and this was meant to copy it: the whole
  // address goes through the CDC, bit 1 still carries the model word's low bit,
  // and Model1.sv aligns down with {addr[24:2], 1'b0} on the way to the port.
  wire [24:1] rom_sdram_addr = POLY_BASE + {r3_rom_addr, 1'b0};

  m1_cdc_port #(.AW(24), .DW(32), .BEW(2)) u_r3d_rom_cdc (
    .a_clk(clk_3d), .a_rst_n(rst_n_3d),
    .a_req(r3_rom_req), .a_we(1'b0), .a_addr(rom_sdram_addr),
    .a_din(32'd0), .a_be(2'b11),
    .a_dout(r3_rom_data), .a_ack(r3_rom_valid), .a_busy(),
    .b_clk(clk_sys), .b_rst_n(rst_n_sys),
    .b_req(r3d_rom_req), .b_we(), .b_addr(r3d_rom_addr),
    .b_din(), .b_be(),
    .b_dout(r3d_rom_addr[1] ? r3d_rom_dout[63:32] : r3d_rom_dout[31:0]),
    .b_ack(r3d_rom_ack)
  );

  // ---- tgp_ram, through p6. Single word, and writable: display-list command 4
  // uploads colour words into it.
  m1_cdc_port #(.AW(24), .DW(16), .BEW(2)) u_r3d_tex_cdc (
    .a_clk(clk_3d), .a_rst_n(rst_n_3d),
    .a_req(r3_tex_req), .a_we(r3_tex_we),
    .a_addr(TGP_RAM_BASE + {4'd0, r3_tex_addr}),
    .a_din(r3_tex_wdata), .a_be(2'b11),
    .a_dout(r3_tex_data), .a_ack(r3_tex_valid), .a_busy(),
    .b_clk(clk_sys), .b_rst_n(rst_n_sys),
    .b_req(r3d_tex_req), .b_we(r3d_tex_we), .b_addr(r3d_tex_addr),
    .b_din(r3d_tex_din), .b_be(),
    .b_dout(r3d_tex_dout), .b_ack(r3d_tex_ack)
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
    .dbg_ctrl(dbg_ctrl), .dbg_layer_have(dbg_layer_have),
    .poly_rgb(r3_scan_rgb), .poly_hit(r3_scan_hit),
    .vid_hpos(vid_hpos), .vid_vpos(vid_vpos)
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
    .sdram_csum(dbg_sdram_csum), .sdram_words(dbg_sdram_words),
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
