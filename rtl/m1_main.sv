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
// Main board: V60, its bus, the 315-5465 decode, on-chip RAM and the GLUE
// registers. Everything the CPU can reach, and nothing that draws.
//
// WHERE MEMORY LIVES
//
// D8 put ROM, work RAM and character RAM in SDRAM and kept the small,
// scanned-every-line things on chip. The ROM half of that is the loader's
// packed layout; the RAM half needs somewhere too, and it goes in the 1 MB
// left above the ROMs:
//
//   0x1F00000  V60 work RAM   (RAMB, 0x500000-0x53ffff)   256 KB
//   0x1F40000  NVRAM          (RAMA, 0x400000-0x40ffff)    64 KB
//   0x1F50000  character RAM  (SCR,  0x780000-0x7fffff)   512 KB
//   0x1FD0000  spare                                      192 KB
//
// Character RAM is written by the CPU here and read by the video fetcher on a
// different SDRAM port, which is why its base appears in both places and is a
// parameter rather than a literal.
//
// UNMAPPED ACCESSES MUST STILL ACKNOWLEDGE
//
// The decode covers what the board decodes; the V60 can address more than
// that. An access that no target claims still has to be acknowledged, because
// the adapter waits for m_ack and a CPU waiting on an ack that never comes is
// stopped forever with no indication of why. Reads of nothing return all ones,
// matching an unpulled bus and MAME's ERASEFF regions, and writes are
// discarded — which is what makes a stray pointer a graphical glitch rather
// than a hang.

`timescale 1ns/1ps

module m1_main #(
  // The V60 resets here. Real hardware uses the architectural 0xFFFFFFF0 and
  // the boot ROM branches out of it; a test that wants to start somewhere
  // else without also encoding a branch overrides this.
  parameter logic [31:0] START_PC = 32'hFFFFFFF0,

  // Instruction fetch through the dedicated wide port. Off routes fetch back
  // through the data bus, which is slower but exercises one path instead of
  // two — useful for telling a fetch-bridge fault from a CPU one.
  parameter bit FAST_IFETCH = 1'b1,

  // The I/O board responder. On by default because boot does not complete
  // without something answering the handshake; a test that wants to drive the
  // DPRAM's far side itself turns it off.
  parameter bit IOBOARD = 1'b1,

  // SDRAM word addresses, from the byte layout above.
  parameter logic [24:1] WRAM_BASE = 24'hF80000,   // 0x1F00000 >> 1
  parameter logic [24:1] NVRAM_BASE = 24'hFA0000,  // 0x1F40000 >> 1
  parameter logic [24:1] CHAR_BASE = 24'hFA8000    // 0x1F50000 >> 1
) (
  input  logic        clk,
  input  logic        ce,          // V60 clock enable
  input  logic        rst_n,
  input  logic        rom_loaded,  // hold the CPU until the ROMs are there

  // Control state for the I/O board, idle-high. See docs/io-board.md.
  input  logic [119:0] in_bytes,

  // ------------------------------------------------- coprocessor microcode
  // From m1_rom_loader, in the FAST memory domain. The program RAM inside
  // m1_tgp is dual-clock for this reason; the write side finishes before the
  // CPU is released, so no handshake is needed.
  input  logic        ucode_clk,
  input  logic        ucode_we,
  input  logic [10:0] ucode_addr,
  input  logic [31:0] ucode_data,

  // The TGP's math tables and its 2 MB data-ROM window. Both belong in SDRAM
  // and are brought out rather than served here — see
  // docs/m2-tgp-integration.md. Tie dat_ack high with zero data to let the
  // coprocessor run before they exist; the math units are not built either, so
  // nothing it computes is right yet regardless.
  output logic        tgp_tbl_req,
  output logic [15:0] tgp_tbl_addr,
  input  logic [31:0] tgp_tbl_rdata,
  input  logic        tgp_tbl_ack,
  output logic        tgp_dat_req,
  output logic [18:0] tgp_dat_addr,
  input  logic [31:0] tgp_dat_rdata,
  input  logic        tgp_dat_ack,

  output logic [15:0] dbg_tgp_retires,
  output logic [15:0] dbg_tgp_pc,
  output logic        dbg_tgp_unimpl,
  // Coprocessor FIFO traffic, both directions, for the on-screen instrument.
  output logic [15:0] dbg_copro_pushes,
  output logic [15:0] dbg_copro_returns,
  output logic [15:0] dbg_tgp_io_addr,
  output logic        dbg_tgp_io_rd,
  output logic        dbg_tgp_io_wr,
  output logic        dbg_tgp_io_ack,
  output logic        dbg_tgp_fifo_rd,
  output logic        dbg_tgp_fifo_wr,

  // SDRAM data port (p0): ROM, work RAM, NVRAM, character RAM.
  output logic        sdr_req,
  output logic        sdr_we,
  output logic [24:1] sdr_addr,
  output logic [15:0] sdr_din,
  output logic [1:0]  sdr_be,
  input  logic [15:0] sdr_dout,
  input  logic        sdr_ack,

  // Dedicated instruction fetch (FAST_IFETCH), served from a burst port.
  //
  // if_sdram_addr is the fetch address AFTER the same ROM mapping data reads
  // go through, aligned down to the 4-word burst that holds the requested
  // 8-byte line. The raw if_addr is exposed too, because the core wants byte
  // zero of the returned line to be the frontier byte and the shift that
  // arranges that needs the low bits.
  //
  // Feeding the burst port the raw address instead is a silent failure: the
  // fetch reads whatever happens to live at the unmapped address, the CPU
  // executes it, and with an erased region that decodes as a stream of HALT.
  // It looks exactly like a CPU that will not start.
  output logic        if_req,
  output logic [23:0] if_addr,
  output logic [24:1] if_sdram_addr,
  input  logic [63:0] if_data,
  input  logic        if_ack,

  // Tile RAM and palette, second ports for the video renderer. These run on the
  // video clock; see m1_mainram.sv for why the crossing needs no handshake.
  input  logic        vid_clk,
  input  logic [14:0] vid_tram_addr,
  output logic [15:0] vid_tram_data,

  // Palette RAM, second port for the video renderer.
  input  logic [11:0] vid_pal_addr,
  output logic [15:0] vid_pal_data,

  input  logic        vblank_irq,

  output logic [23:0] dbg_pc,
  output logic        dbg_halted,
  // Sticky. Set if a build without the FP group ever meets an FP opcode; see
  // the note on the port in v60.sv.
  output logic        dbg_fp_trap,
  output logic [15:0] dbg_io_replies,
  // CPU writes into tile RAM, counted by region. The video-side census in
  // m1_video says what the renderer READS; this says what the CPU WROTE, and
  // the pair is what separates "the V60 never writes maps 0/1" from "the
  // writes do not survive the RAM". Neither number alone can tell those apart,
  // and on hardware maps 0/1 read as empty while maps 2/3 read as full.
  //   [0] word 0x0000-0x1fff, tilemaps 0 and 1
  //   [1] word 0x2000-0x3fff, tilemaps 2 and 3
  //   [2] word 0x4000-0x5fff, per-line H-scroll table and the scroll registers
  //   [3] word 0x6000-0x7fff, the row masks
  // Per frame and saturating at FFF, latched at vblank. See the counter below
  // for why cumulative does not work.
  output logic [11:0] dbg_tram_writes [4],
  // Command-FIFO pops, alongside the pushes already brought out. Was internal;
  // brought out because pushes-without-pops and pops-without-returns are
  // different faults and the overlay could not tell them apart.
  output logic [15:0] dbg_copro_pops,
  // The TGP taking a command — see m1_copro_if. dbg_copro_pops is the V60
  // reading results back, which it never does; this is the live one.
  output logic [15:0] dbg_copro_drains,

  // TRACE TAP: the CPU writing pair 2/3's window control, tile RAM word 0x5006.
  // One-cycle strobe with the data and the PC that did it, for the UART channel.
  // This register is the open question on hardware — the reference sets window
  // mode once during boot and holds it, and the board toggles it about three
  // times a second forever.
  output logic        dbg_ctrlw,
  output logic [15:0] dbg_ctrlw_data,
  output logic [23:0] dbg_ctrlw_pc,
  output logic [2:0]  rom_bank
);

  // ------------------------------------------------------------------ CPU
  logic        rst_cpu;
  assign rst_cpu = ~rst_n | ~rom_loaded;

  logic        c_req, c_we, c_ack;
  logic [31:0] c_addr, c_wdata, c_rdata;
  logic [1:0]  c_size;

  logic        m_req, m_we, m_ack;
  logic [23:1] m_addr;
  logic [15:0] m_wdata, m_rdata;
  logic [1:0]  m_be;

  logic        irq_n;
  logic [31:0] pc32;

  s32_v60 #(.START_PC(START_PC), .FAST_IFETCH(FAST_IFETCH)) cpu (
    .clk(clk), .ce(ce), .rst(rst_cpu),
    .if_req(if_req), .if_addr(if_addr), .if_data(if_data), .if_ack(if_ack),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(irq_n), .irq_vector({5'd0, glue_irq_vec}),
    .irq_ack(cpu_irq_ack), .nmi_n(1'b1),
    .dbg_pc(pc32), .dbg_halted(dbg_halted), .dbg_fp_trap(dbg_fp_trap)
  );
  assign dbg_pc = pc32[23:0];

  s32_v60_bus adapter (
    .clk(clk), .ce(ce), .rst(rst_cpu),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
  );

  // --------------------------------------------------------------- decode
  logic sel_rom, sel_rom_void, sel_nvram, sel_wram, sel_dlist0, sel_dlist1;
  logic sel_listctl, sel_tileram, sel_charram, sel_vsync, sel_palette;
  logic sel_colxlat, sel_dpram, sel_uart, sel_copro_adr, sel_copro_ram;
  logic sel_copro_fifo, sel_fifo_stat, sel_glue;
  logic [24:1] dec_rom_addr;

  m1_decode decode (
    .addr({m_addr, 1'b0}), .rom_bank(rom_bank),
    .sel_rom(sel_rom), .sel_rom_void(sel_rom_void), .sel_nvram(sel_nvram),
    .sel_wram(sel_wram), .sel_dlist0(sel_dlist0), .sel_dlist1(sel_dlist1),
    .sel_listctl(sel_listctl), .sel_tileram(sel_tileram),
    .sel_charram(sel_charram), .sel_vsync(sel_vsync),
    .sel_palette(sel_palette), .sel_colxlat(sel_colxlat),
    .sel_dpram(sel_dpram), .sel_uart(sel_uart),
    .sel_copro_adr(sel_copro_adr), .sel_copro_ram(sel_copro_ram),
    .sel_copro_fifo(sel_copro_fifo), .sel_fifo_stat(sel_fifo_stat),
    .sel_glue(sel_glue), .rom_addr(dec_rom_addr)
  );

  // The fetch address takes the same route. A second decode instance rather
  // than a shared one, because the fetch and the data port are asking about
  // different addresses at the same time.
  logic [24:1] if_rom_word;
  m1_decode if_decode (
    .addr(if_addr), .rom_bank(rom_bank),
    .sel_rom(), .sel_rom_void(), .sel_nvram(), .sel_wram(),
    .sel_dlist0(), .sel_dlist1(), .sel_listctl(), .sel_tileram(),
    .sel_charram(), .sel_vsync(), .sel_palette(), .sel_colxlat(),
    .sel_dpram(), .sel_uart(), .sel_copro_adr(), .sel_copro_ram(),
    .sel_copro_fifo(), .sel_fifo_stat(), .sel_glue(),
    .rom_addr(if_rom_word)
  );
  // Align to the 4-word burst. The ROM bases are 8-byte aligned, so aligning
  // in mapped space is the same line as aligning in CPU space.
  assign if_sdram_addr = {if_rom_word[24:3], 2'b00};

  // Which targets live in SDRAM, and where.
  logic        to_sdram;
  logic [24:1] sdram_word;
  assign to_sdram = sel_rom | sel_wram | sel_nvram | sel_charram;

  always_comb begin
    if      (sel_rom)     sdram_word = dec_rom_addr;
    else if (sel_wram)    sdram_word = WRAM_BASE  + {7'd0, m_addr[17:1]};
    else if (sel_nvram)   sdram_word = NVRAM_BASE + {9'd0, m_addr[15:1]};
    else                  sdram_word = CHAR_BASE  + {6'd0, m_addr[18:1]};
  end

  // ------------------------------------------------------------ on chip
  // Tile RAM is 0x8000 words and palette 0x2000; both are read every scanline
  // by the renderer, which is why D8 keeps them off the external bus.
  //
  // The display lists, the colour translation table and the I/O board's
  // dual-port RAM are here too. None is needed to fetch an instruction, and
  // all of them are needed to BOOT: startup code writes and reads back its RAM
  // regions, and a region that acknowledges but reads as 0xFFFF fails that
  // check. The failure is silent in the worst way — the CPU is executing
  // correctly, it just never gets past its own self-test — so these exist
  // before real ROM code is run rather than after it has been debugged.
  // ------------------------------------------------------------ on-chip RAM
  // Extracted into m1_mainram so the block-RAM inference can be synthesised
  // and checked on its own. Verifying it inside the full design meant a
  // half-hour Quartus run and 14 GB of memory to answer a question about six
  // arrays; on its own it is a couple of minutes.
  logic [15:0] tram_q, pram_q, dl0_q, dl1_q, cxlat_q, dpram_q;

  // The I/O board's far side of the DPRAM. Tied off when IOBOARD is 0 so the
  // port cannot float into the RAM.
  logic        io_we, io_ack;
  logic [10:0] io_addr;
  logic [7:0]  io_din;

  m1_mainram rams (
    .clk(clk),
    .we(m_req && m_we), .be(m_be), .addr(m_addr), .wdata(m_wdata),
    .sel_tileram(sel_tileram), .sel_palette(sel_palette),
    .sel_dlist0(sel_dlist0), .sel_dlist1(sel_dlist1),
    .sel_colxlat(sel_colxlat), .sel_dpram(sel_dpram),
    .tram_q(tram_q), .pram_q(pram_q), .dl0_q(dl0_q), .dl1_q(dl1_q),
    .cxlat_q(cxlat_q), .dpram_q(dpram_q),
    .vid_clk(vid_clk),
    .vid_tram_addr(vid_tram_addr), .vid_tram_data(vid_tram_data),
    .vid_pal_addr(vid_pal_addr), .vid_pal_data(vid_pal_data),
    .io_we(io_we), .io_addr(io_addr), .io_din(io_din), .io_ack(io_ack)
  );

  // Counted on the CPU's own write strobe, upstream of the RAM, so a fault
  // inside the memory cannot hide from it.
  //
  // PER FRAME, not cumulative, and that is the whole design of the instrument.
  // Cumulative was tried first and is useless here: the boot self-test writes
  // and reads back every word of tile RAM, so all four regions saturate before
  // the game loop starts. Simulation showed FFF on all four by frame 64, which
  // cannot distinguish "written once at boot" from "rewritten every frame" —
  // and that distinction is exactly the question. Resetting on vblank measures
  // the game loop alone.
  logic tw_vb_d;
  logic [11:0] tw_cnt [4];
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int r = 0; r < 4; r++) begin
        tw_cnt[r]           <= 12'd0;
        dbg_tram_writes[r]  <= 12'd0;
      end
      tw_vb_d <= 1'b0;
    end else begin
      tw_vb_d <= vblank_irq;
      // Latch the frame that just ended, so the overlay never shows a count
      // being accumulated. Same shape as the content census in m1_video.
      if (vblank_irq && !tw_vb_d) begin
        for (int r = 0; r < 4; r++) begin
          dbg_tram_writes[r] <= tw_cnt[r];
          tw_cnt[r]          <= 12'd0;
        end
      end else if (m_req && m_we && sel_tileram) begin
        if (tw_cnt[m_addr[15:14]] != 12'hfff)
          tw_cnt[m_addr[15:14]] <= tw_cnt[m_addr[15:14]] + 12'd1;
      end
    end
  end

  // The tap itself. m_req is held until ack, so it is edged to one strobe per
  // access rather than one per cycle of a held request.
  logic ctrlw_d;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ctrlw_d <= 1'b0; dbg_ctrlw <= 1'b0;
      dbg_ctrlw_data <= '0; dbg_ctrlw_pc <= '0;
    end else begin
      logic hit;
      hit = m_req && m_we && sel_tileram && (m_addr[15:1] == 15'h5006);
      ctrlw_d   <= hit;
      dbg_ctrlw <= hit && !ctrlw_d;
      if (hit && !ctrlw_d) begin
        dbg_ctrlw_data <= m_wdata;
        dbg_ctrlw_pc   <= dbg_pc;
      end
    end
  end

  // ------------------------------------------------------- I/O board
  // Answers the boot handshake through the DPRAM's far side. What it covers
  // and what it deliberately does not is in m1_ioboard.sv's header.
  generate
    if (IOBOARD) begin : g_ioboard
      m1_ioboard ioboard (
        .clk(clk), .rst_n(rst_n),
        .in_bytes(in_bytes),
        .v60_req(m_req), .v60_we(m_we), .v60_sel_dpram(sel_dpram),
        .v60_addr(m_addr[11:1]), .v60_wdata(m_wdata[7:0]),
        .io_we(io_we), .io_addr(io_addr), .io_din(io_din), .io_ack(io_ack),
        .replies(dbg_io_replies)
      );
    end else begin : g_no_ioboard
      always_comb begin
        io_we          = 1'b0;
        io_addr        = 11'd0;
        io_din         = 8'd0;
        dbg_io_replies = 16'd0;
      end
      // io_ack is driven by the RAM; nothing consumes it in this branch.
    end
  endgenerate

  // ---------------------------------------------------------- GLUE regs
  // Extracted into m1_glue so the interrupt semantics can be tested directly.
  // They are subtle enough to have already been wrong here once — see that
  // file's header on the mask polarity.
  logic [15:0] glue_rdata;
  logic [2:0]  glue_irq_vec;
  logic        cpu_irq_ack;

  m1_glue glue (
    .clk(clk), .ce(ce), .rst_n(rst_n),
    .sel(sel_glue), .we(m_req && m_we), .a(m_addr[3:1]),
    .be(m_be), .wdata(m_wdata), .rdata(glue_rdata),
    .vblank(vblank_irq),
    .irq_n(irq_n), .irq_vec(glue_irq_vec), .irq_ack(cpu_irq_ack),
    .rom_bank(rom_bank)
  );

  // --------------------------------------------------------- bus routing
  typedef enum logic [1:0] { B_IDLE, B_SDRAM, B_LOCAL, B_ACK } bstate_t;
  bstate_t bst;

  // ------------------------------------------------- coprocessor interface
  // CPR, 0xd00000-0xdfffff: the address register, the 8192x32 copro RAM window
  // and the command FIFOs. The TGP itself is not attached yet — see
  // docs/m2-tgp-integration.md — so its side is tied off here and the V60's
  // traffic simply lands somewhere real instead of reading 0xFFFF.
  //
  // Strobed from B_LOCAL, which is one cycle. A held request would post-
  // increment the address three times per access; m1_copro_if's testbench pins
  // that explicitly.
  logic [15:0] copro_q;
  logic        copro_ack;
  wire         to_copro = sel_copro_adr || sel_copro_ram || sel_copro_fifo;
  logic [15:0] dbg_copro_ram_writes;
  assign dbg_copro_pushes = dbg_copro_fifo_pushes;
  logic [15:0] dbg_copro_fifo_pushes;
  logic        copro_v60_stall;

  m1_copro_if copro (
    .clk(clk), .rst_n(rst_n),
    .sel_adr(sel_copro_adr), .sel_ram(sel_copro_ram), .sel_fifo(sel_copro_fifo),
    // The request is held until copro_ack; the interface serves one access per
    // request however long it is held, so nothing here needs to pulse.
    .req(m_req), .we(m_we), .a1(m_addr[1]), .be(m_be), .wdata(m_wdata),
    .q(copro_q), .ack(copro_ack),
    // The coprocessor, now present on both the RAM port and the FIFOs.
    .tgp_req(t_ram_req), .tgp_we(t_ram_we), .tgp_addr(t_ram_addr),
    .tgp_wdata(t_ram_wdata), .tgp_rdata(t_ram_rdata), .tgp_ack(t_ram_ack),
    .fifo_in_data(t_fin_data), .fifo_in_valid(t_fin_valid),
    .fifo_in_pop(t_fin_pop),
    .fifo_out_data(t_fout_data), .fifo_out_push(t_fout_push),
    .fifo_out_full(t_fout_full),
    .dbg_ram_writes(dbg_copro_ram_writes),
    .dbg_fifo_pushes(dbg_copro_fifo_pushes),
    .dbg_fifo_returns(dbg_copro_returns), .dbg_fifo_pops(dbg_copro_pops),
    .dbg_fifo_drains(dbg_copro_drains),
    .v60_stall(copro_v60_stall)
  );

  // --------------------------------------------------------- the coprocessor
  // In the CPU domain, beside the RAM it shares with the V60. MAME clocks the
  // real part at 40 MHz against this domain's 19.2, so throughput is the open
  // question — measure it against the polygon rate before moving it to the fast
  // domain, which would put a clock crossing on the shared RAM.
  logic        t_ram_req, t_ram_we, t_ram_ack;
  logic [12:0] t_ram_addr;
  logic [31:0] t_ram_wdata, t_ram_rdata;
  logic [31:0] t_fin_data, t_fout_data;
  logic        t_fin_valid, t_fin_pop, t_fout_push, t_fout_full;

  m1_tgp tgp (
    .clk(clk), .rst_n(rst_n),
    .ucode_clk(ucode_clk), .ucode_we(ucode_we),
    .ucode_addr(ucode_addr), .ucode_data(ucode_data),
    .ram_req(t_ram_req), .ram_we(t_ram_we), .ram_addr(t_ram_addr),
    .ram_wdata(t_ram_wdata), .ram_rdata(t_ram_rdata), .ram_ack(t_ram_ack),
    .fifo_in_data(t_fin_data), .fifo_in_valid(t_fin_valid),
    .fifo_in_pop(t_fin_pop),
    .fifo_out_data(t_fout_data), .fifo_out_push(t_fout_push),
    .fifo_out_full(t_fout_full),
    .tbl_req(tgp_tbl_req), .tbl_addr(tgp_tbl_addr),
    .tbl_rdata(tgp_tbl_rdata), .tbl_ack(tgp_tbl_ack),
    .dat_req(tgp_dat_req), .dat_addr(tgp_dat_addr),
    .dat_rdata(tgp_dat_rdata), .dat_ack(tgp_dat_ack),
    .dbg_retires(dbg_tgp_retires), .dbg_pc(dbg_tgp_pc),
    .dbg_unimplemented(dbg_tgp_unimpl),
    .dbg_io_addr(dbg_tgp_io_addr), .dbg_io_rd(dbg_tgp_io_rd),
    .dbg_io_wr(dbg_tgp_io_wr), .dbg_io_ack(dbg_tgp_io_ack),
    .dbg_fifo_rd(dbg_tgp_fifo_rd), .dbg_fifo_wr(dbg_tgp_fifo_wr)
  );

  logic [15:0] rdata_r;
  logic        ack_r;
  logic        sdr_ack_d;

  assign m_rdata = rdata_r;
  assign m_ack   = ack_r;
  assign sdr_we  = m_we;
  assign sdr_din = m_wdata;
  assign sdr_be  = m_be;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bst <= B_IDLE; sdr_req <= 1'b0; sdr_addr <= '0;
      rdata_r <= '0; ack_r <= 1'b0; sdr_ack_d <= 1'b0;
    end else begin
      sdr_ack_d <= sdr_ack;

      case (bst)
        B_IDLE: begin
          ack_r <= 1'b0;
          if (m_req) begin
            if (to_sdram) begin
              // One transaction per request RISING edge — see m1_sdram.sv.
              sdr_addr <= sdram_word;
              sdr_req  <= 1'b1;
              bst      <= B_SDRAM;
            end else begin
              // On-chip reads are registered, so give them a cycle. Registers
              // and unmapped space resolve in the same slot.
              bst <= B_LOCAL;
            end
          end
        end

        B_SDRAM: begin
          sdr_req <= 1'b0;
          if (sdr_ack && !sdr_ack_d) begin
            rdata_r <= sdr_dout;
            ack_r   <= 1'b1;
            bst     <= B_ACK;
          end
        end

        B_LOCAL: begin
          // The coprocessor interface shares one RAM port with the TGP, so its
          // reads are not ready in a fixed cycle. Wait for its acknowledge
          // rather than sampling on faith — everything else here is registered
          // on-chip memory that is ready now.
          if (to_copro) begin
            if (copro_ack) begin
              rdata_r <= copro_q;
              ack_r   <= 1'b1;
              bst     <= B_ACK;
            end
          end else begin
          if      (sel_tileram) rdata_r <= tram_q;
          else if (sel_palette) rdata_r <= pram_q;
          else if (sel_dlist0)  rdata_r <= dl0_q;
          else if (sel_dlist1)  rdata_r <= dl1_q;
          else if (sel_colxlat) rdata_r <= cxlat_q;
          else if (sel_dpram)   rdata_r <= dpram_q;
          else if (sel_glue)    rdata_r <= glue_rdata;
          // sel_fifo_stat deliberately falls through: MAME's fifoin_status_r
          // returns a constant 0xFFFF and the default below already is that.
          // Everything the board does not decode, plus the regions this does
          // not implement yet: acknowledge and read as an unpulled bus.
          else                  rdata_r <= 16'hFFFF;
          ack_r <= 1'b1;
          bst   <= B_ACK;
          end
        end

        // Hold the acknowledge until the requester drops m_req.
        //
        // It must not be a single-cycle pulse. The bus adapter runs on the
        // CPU's clock enable — clk/3 in the production cadence — so it only
        // looks at m_ack every third cycle and a one-cycle pulse is missed
        // outright most of the time. The CPU then waits forever on a
        // transaction that did complete. Booting real code, that presented as
        // the V60 taking its reset vector, running nineteen instructions,
        // issuing exactly one data read and then stopping dead.
        //
        // m1_sdram stretches its own ack for the same reason; this is the same
        // requirement one level up, and holding until the request drops covers
        // any enable ratio rather than a particular one.
        B_ACK: begin
          ack_r <= 1'b1;
          if (!m_req) begin
            ack_r <= 1'b0;
            bst   <= B_IDLE;
          end
        end

        default: bst <= B_IDLE;
      endcase
    end
  end

endmodule
