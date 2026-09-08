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
  // Forwarded to m1_tgp — see its io_rdata mux. Experiment switch for the
  // unimplemented math units, default off.
  parameter bit TGP_MATH_ZERO = 1'b0,
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

  // The I/O board Z80's firmware fetch, into SDRAM. It is 16 KB of read-only
  // code and block RAM has no room for it - see m1_ioz80.
  output logic        iofw_req,
  output logic [13:0] iofw_word,
  input  logic        iofw_ack,
  input  logic [15:0] iofw_din,

  // ------------------------------------------------- coprocessor microcode
  // From m1_rom_loader, in the FAST memory domain. The program RAM inside
  // m1_tgp is dual-clock for this reason; the write side finishes before the
  // CPU is released, so no handshake is needed.
  // THE COPROCESSOR'S OWN CLOCK. The real board runs the MB86233 at 40 MHz
  // against a 16 MHz V60 - a 2.5:1 ratio - and we had both on clk_cpu at 1:1.
  // Measured: the TGP asserts a command-FIFO read on 71% of cycles (idle,
  // waiting for the V60) while the V60 finds the result FIFO empty on 99.2% of
  // its reads (waiting for the TGP). Neither is starved; they are SERIALISED,
  // and each half of the ping-pong runs at our clock. Halving the TGP's half
  // is what the board's 2.5:1 buys, and 1.70x of clock deficit is the same
  // size as the 1.71x by which the board's 3D frames trail simulation's.
  //
  // clk_3d is 47.059 MHz, EXACTLY twice clk_cpu and from the same PLL, so this
  // is not an asynchronous crossing: the edges are phase-aligned at an integer
  // ratio and Quartus times the paths normally. What makes it safe is that the
  // V60 side of m1_copro_if is level-based throughout - `v60_acc = req &&
  // !served`, with `served` cleared on `!req` - so it serves one access per
  // request however many fast edges observe the level, and the acknowledge is
  // held until the request drops, which is the house rule anyway.
  input  logic        clk_tgp,
  input  logic        rst_n_tgp,     // gated on rom_loaded: the coprocessor
  input  logic        rst_n_tgp_if,  // raw: its interface, live during ROM load

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

  // The 3D layer's reads of the display list and the colour-translation table,
  // from its own clock. Both memories are true dual port for this.
  input  logic        r3d_clk,
  input  logic [14:0] r3d_dl_addr,
  output logic [15:0] r3d_dl_data,
  input  logic [14:0] r3d_xlat_addr,
  output logic [15:0] r3d_xlat_data,
  input  logic [9:0]  r3d_pal_addr,
  output logic [15:0] r3d_pal_data,
  // Which display list the video hardware should render.
  //
  // `listctl_sel` is the live register bit, on the CPU clock. `r3d_dl_sel` is
  // the LATCHED choice coming back from the 3D layer, and it is what the read
  // port actually uses.
  //
  // THE LIVE BIT CANNOT DRIVE THE READ PORT. The walk takes about 48% of a
  // frame and the game swaps buffers at some point inside that - measured at
  // every second frame, tools/mame_listctl_rate.lua - so a walk in progress
  // would switch buffers halfway and build a display list out of two. MAME
  // takes the same care: set_current_render_list() assigns
  // m_display_list_current once, at the start of a render, and everything
  // afterwards reads that pointer.
  output logic        listctl_sel,
  input  logic        r3d_dl_sel,

  input  logic        vblank_irq,

  output logic [23:0] dbg_pc,
  output logic        dbg_halted,
  // Sticky. Set if a build without the FP group ever meets an FP opcode; see
  // the note on the port in v60.sv.
  output logic        dbg_fp_trap,
  // Display-list writes above the 16,384-word cap m1_mainram sizes the two
  // buffers to. Measured zero over 40 s in MAME; nonzero means that is wrong.
  output logic [15:0] dbg_dl_oob,
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
  // CUMULATIVE, NOT PER FRAME. dbg_tram_writes above is latched and cleared
  // every vblank, which is right for liveness and blind to this: the text is
  // written into tile RAM ONCE during init and never rewritten, so a per-frame
  // counter reads zero on a working machine and on a broken one alike. The
  // board shows tilemap 0 holding 8 non-blank words against simulation's 79 and
  // winning 5 pixels against 11,038, so the question is whether those init
  // writes happened at all - and only a total since reset can answer it.
  output logic [23:0] dbg_ucode_ram_csum,
  output logic        dbg_ucode_ram_ok,
  output logic [11:0] dbg_tgp_ram_writes,
  output logic [15:0] dbg_sync_word,
  output logic [11:0] dbg_tm0_writes,
  output logic [11:0] dbg_tm0_text_writes,
  output logic [11:0] dbg_mask_nz_writes,
  output logic [23:0] dbg_tm0_first_pc,     // tile RAM words 0x0000-0x0fff, tilemap 0
  output logic [11:0] dbg_mask_writes,    // tile RAM words 0x6000-0x67ff, the row mask
  // Command-FIFO pops, alongside the pushes already brought out. Was internal;
  // brought out because pushes-without-pops and pops-without-returns are
  // different faults and the overlay could not tell them apart.
  output logic [15:0] dbg_copro_pops,
  // The TGP taking a command — see m1_copro_if. dbg_copro_pops is the V60
  // reading results back, which it never does; this is the live one.
  output logic [15:0] dbg_copro_drains,
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
  // The Z80 I/O board's read side of the shared RAM. Unused by the
  // behavioural board, which only ever wrote it.
  logic [10:0] io_raddr;
  // The DPRAM window as the I/O board sees it: held for a few cycles so a Z80
  // paced at one clock in six can sample it. clk_cpu is 23.529 MHz and the
  // real board's Z80 runs at 4 MHz, which is what CEN_DIV(6) gives.
  logic [5:0] dp_busy_sr;
  wire        dp_busy_z = |dp_busy_sr;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) dp_busy_sr <= '0;
    else        dp_busy_sr <= {dp_busy_sr[4:0], (m_req && sel_dpram)};
  end
  wire  [7:0]  io_rdata;
  logic [10:0] io_addr;
  logic [7:0]  io_din;

  m1_mainram rams (
    .clk(clk),
    .we(m_req && m_we), .be(m_be), .addr(m_addr), .wdata(m_wdata),
    .sel_tileram(sel_tileram), .sel_palette(sel_palette),
    .sel_dlist0(sel_dlist0), .sel_dlist1(sel_dlist1),
    .sel_colxlat(sel_colxlat), .sel_dpram(sel_dpram),
    .tram_q(tram_q), .pram_q(pram_q), .dl0_q(dl0_q), .dl1_q(dl1_q),
    .cxlat_q(cxlat_q), .dpram_q(dpram_q), .dbg_dl_oob(dbg_dl_oob),
    .vid_clk(vid_clk),
    .vid_tram_addr(vid_tram_addr), .vid_tram_data(vid_tram_data),
    .vid_pal_addr(vid_pal_addr), .vid_pal_data(vid_pal_data),
    .r3d_clk(r3d_clk), .r3d_dl_addr(r3d_dl_addr), .r3d_dl_sel(r3d_dl_sel),
    .r3d_dl_data(r3d_dl_data),
    .r3d_xlat_addr(r3d_xlat_addr), .r3d_xlat_data(r3d_xlat_data),
    .r3d_pal_addr(r3d_pal_addr), .r3d_pal_data(r3d_pal_data),
    .io_we(io_we), .io_addr(io_addr), .io_din(io_din), .io_ack(io_ack),
    .io_raddr(io_raddr), .io_rdata(io_rdata)
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
      dbg_tm0_writes  <= 12'd0;
      dbg_tm0_text_writes <= 12'd0;
      dbg_mask_nz_writes  <= 12'd0;
      dbg_tm0_first_pc    <= 24'd0;
      dbg_mask_writes <= 12'd0;
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
        // Saturating totals, never cleared. See the port comment.
        if (m_addr[15:12] == 4'h0 && dbg_tm0_writes != 12'hfff)
          dbg_tm0_writes <= dbg_tm0_writes + 12'd1;
        // CHARACTERS, NOT SPACES.
        //
        // The board's tilemap 0 holds 4,096 words and the renderer finds eight
        // of them non-blank, so the CPU clears the screen and never draws. The
        // total above cannot tell those apart - a screen clear is 4,096 writes
        // and saturates it either way. m1_tile_fetch calls a word blank when it
        // is zero or when (word & 0x3fff) == 0x0020, which is a space, so use
        // exactly that test here.
        //
        // The PC of the FIRST real character says which routine drew it, and
        // zero says none ever ran.
        if (m_addr[15:12] == 4'h0 && m_wdata != 16'h0000
            && (m_wdata & 16'h3fff) != 16'h0020) begin
          if (dbg_tm0_text_writes != 12'hfff)
            dbg_tm0_text_writes <= dbg_tm0_text_writes + 12'd1;
          if (dbg_tm0_text_writes == 12'd0) dbg_tm0_first_pc <= dbg_pc;
        end
        if (m_addr[15:11] == 5'b01100 && dbg_mask_writes != 12'hfff)
          dbg_mask_writes <= dbg_mask_writes + 12'd1;
        // NON-ZERO MASK WORDS, WHICH IS THE ONLY KIND THAT MATTERS.
        //
        // The text is CATEGORY 1 - bit 15 of the tile word - and a category-1
        // tile is visible only where its row-mask bit is SET. The sky and sea
        // are category 0 and show wherever the mask is clear. So an all-zero
        // mask produces exactly what the board shows: background rendering,
        // characters written into tile RAM and never visible.
        //
        // The total above counts writes and cannot tell a mask being filled from
        // a mask being cleared - the same distinction as spaces against
        // characters, which is what settled the previous question.
        if (m_addr[15:11] == 5'b01100 && m_wdata != 16'h0000
            && dbg_mask_nz_writes != 12'hfff)
          dbg_mask_nz_writes <= dbg_mask_nz_writes + 12'd1;
      end
    end
  end

  // -------------------------------------------- display-list control register
  //
  // 0x680000-0x680003. This was decoded for writes and had NO READ HANDLER, so
  // reads fell through the mux below and returned 0xFFFF — which makes bit 6, the
  // display-list buffer select, read as 1 forever. `make v60_trace` caught it at
  // instruction 26,283, where the game does `test1 #6` on it and branches.
  //
  // vblank_irq is the frame pulse. It is a level here, so the rising edge is what
  // counts — tw_vb_d already tracks it for the tile census, so reuse that rather
  // than add a second delay register that could disagree with it.
  logic [15:0] listctl_q;

  m1_listctl u_listctl (
    .clk(clk), .rst_n(rst_n),
    .we(m_req & m_we & sel_listctl),
    .offset(m_addr[1]),
    .wdata(m_wdata), .be(m_be),
    .rdata(listctl_q),
    .frame_pulse(vblank_irq & ~tw_vb_d),
    .list_sel(listctl_sel)
  );

  // ------------------------------------------------------- I/O board
  // Answers the boot handshake through the DPRAM's far side. What it covers
  // and what it deliberately does not is in m1_ioboard.sv's header.
  // THE REAL BOARD: a Z80 running EPR-14869, not an imitation of it.
  //
  // Decision D9 chose a behavioural I/O board on an area budget made of
  // estimates, and said in its own words that the choice should be revisited
  // once the real numbers were known. They are, and Ben's call on 2026-09-04
  // is the Z80. The firmware is a MAME BIOS set, which is what made it
  // possible: model1io.zip is required to run any Model 1 game in MAME too.
  //
  // The inputs come out of `in_bytes` rather than through new ports of their
  // own. That bus is the fifteen bytes the behavioural board published at
  // DPRAM 0x00 upward, and its layout is exactly what the Z80 wants: the
  // three control ports at 0x08-0x0a, the three DIP banks at 0x0b-0x0d, and
  // the wheel, accelerator and brake at 0x00-0x02 for the ADC channels.
  generate
    if (IOBOARD) begin : g_ioboard
      // HELD UNTIL THE FIRMWARE IS IN MEMORY, not merely until reset lifts.
      //
      // This is the coprocessor's bug again, exactly. The TGP was wired to the
      // raw rst_n while the V60 waited on rom_loaded, so it executed its
      // program RAM while the HPS was still streaming into it, blocked, and
      // never recovered - `tgp=4/0/004c` for a whole session. The Z80 did the
      // same thing here: it left reset, fetched word 0 of a firmware that was
      // not there yet, cached the 0xffff that unwritten SDRAM returns, and
      // executed RST 38h forever. One fetch in forty million cycles.
      //
      // rst_cpu is ~rst_n | ~rom_loaded, which is what the V60 uses.
      // NO PARAMETER OVERRIDE ON PURPOSE. The default is the board's own
      // V60:Z80 clock ratio of 4:1, which is a property of the hardware and not
      // of whatever we clock the V60 at. The override that stood here was
      // CEN_DIV(6) - a 6:1 ratio, so the I/O board ran at two thirds speed
      // relative to the CPU it handshakes with, and always had.
      m1_ioz80 ioboard (
        .clk(clk), .rst_n(~rst_cpu),
        .fw_req(iofw_req), .fw_word(iofw_word),
        .fw_ack(iofw_ack), .fw_din(iofw_din),
        .in0 (in_bytes[8*8  +: 8]),
        .in1 (in_bytes[9*8  +: 8]),
        .in2 (in_bytes[10*8 +: 8]),
        .dsw1(in_bytes[11*8 +: 8]),
        .dsw2(in_bytes[12*8 +: 8]),
        .dsw3(in_bytes[13*8 +: 8]),
        // BUSY MEANS "THE GAME IS IN THE WINDOW", not "my write is pending".
        //
        // I had this as `io_we && !io_ack`, which is the Z80's own write
        // waiting for the shared port - a different signal entirely, and one
        // the firmware has no use for. The Model 2 core, which runs this same
        // board and works, feeds its status bit from whether the CPU is inside
        // the DPRAM block window: the firmware polls it so it does not read a
        // half-written request, and with the wrong signal it waits on
        // something that never means what it thinks.
        //
        // STRETCHED, because the Z80 samples it through a clock enable of one
        // in six and a single clk_cpu pulse would be invisible.
        .dp_busy(dp_busy_z),
        .adc0(in_bytes[0*8 +: 8]),   // wheel, centre 0x80
        .adc1(in_bytes[1*8 +: 8]),   // accelerator
        .adc2(in_bytes[2*8 +: 8]),   // brake
        .adc3(8'hff),
        .z_we(io_we), .z_addr(io_addr), .z_wdata(io_din), .z_rdata(io_rdata),
        .dbg_ee(), .dbg_wrcnt(dbg_io_replies), .dbg_wr_stb(),
        .dbg_dout(), .dbg_di(), .dbg_rd_end(), .dbg_ra(), .dbg_rdat(),
        .dbg_m1_n(), .dbg_a(), .dbg_last_wr(), .dbg_pf(),
        .dbg_pa(), .dbg_seccnt()
      );
      assign io_raddr = io_addr;
    end else begin : g_no_ioboard
      always_comb begin
        io_we          = 1'b0;
        io_addr        = 11'd0;
        io_din         = 8'd0;
        io_raddr       = 11'd0;
        dbg_io_replies = 16'd0;
        iofw_req       = 1'b0;
        iofw_word      = 14'd0;
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
  // B_SDRAM_RMW reads a word before a partial write; see the note at the state.
typedef enum logic [2:0] { B_IDLE, B_SDRAM, B_LOCAL, B_ACK, B_SDRAM_RMW } bstate_t;
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

  // THE INTERFACE TAKES THE RAW RESET, THE COPROCESSOR TAKES THE GATED ONE.
  //
  // That asymmetry is original and load-bearing: m1_copro_if was `.rst_n(rst_n)`
  // while m1_tgp was `.rst_n(~rst_cpu)` - the coprocessor is held until the ROMs
  // have arrived, but the INTERFACE around it, which holds the copro RAM and
  // both FIFOs, stays live. Giving them a single shared reset put the interface
  // in reset for the whole ROM load too, and that is a black screen on the
  // board: the CPU runs normally (S=26-27 swaps/s, the healthy rate) while the
  // coprocessor produces nothing at all (P=0000 in every telemetry sample).
  //
  // Ben: the Model 2 core had the same failure, from things not being held
  // correctly while the ROM loaded.
  m1_copro_if copro (
    .clk(clk_tgp), .rst_n(rst_n_tgp_if),
    .dbg_tgp_ram_writes(dbg_tgp_ram_writes), .dbg_sync_word(dbg_sync_word),
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

  // HELD UNTIL THE MICROCODE IS THERE, exactly like the V60.
  //
  // This was `.rst_n(rst_n)` - the raw reset - while the CPU used
  // rst_cpu = ~rst_n | ~rom_loaded. So the coprocessor left reset at power-on
  // and executed its program RAM while the HPS was still streaming the ROMs
  // into it. An unwritten program RAM reads as zeros, a zero word decodes as
  // `lab`, and one of the first four does a data-space read of 0x100 - the
  // command FIFO - which BLOCKS until the V60 sends something. By the time the
  // microcode arrived the coprocessor was already parked on that read and never
  // recovered: tb_m1_frame reports tgp=4/0/004c with frd=1 held for the whole
  // run, and the V60 then hangs at ff9754 waiting for a result that never comes.
  //
  // tb_m1_boot preloads the microcode and so never saw it. That bench found the
  // same race in ITS OWN reset this morning and fixing it there masked this one
  // - the real instance, on the path hardware actually uses.
  m1_tgp #(.MATH_ZERO(TGP_MATH_ZERO)) tgp (
    .dbg_ucode_ram_csum(dbg_ucode_ram_csum), .dbg_ucode_ram_ok(dbg_ucode_ram_ok),
    .clk(clk_tgp), .rst_n(rst_n_tgp),
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
  // A PARTIAL WRITE NEVER REACHES THE DEVICE AS A MASK.
  //
  // From the Model 2 core, measured on hardware: "DQM tied low is common on
  // these boards and would make every byte write land in all four lanes exactly
  // as observed - invisible to every test we own, because they all test the
  // FPGA." Their symptom was a loop counter reading 27272727 where MAME holds
  // 00000027, which made a 39-pass loop run 656 million times.
  //
  // WE HAVE THE SAME EXPOSURE AND IT IS NOT SMALL: 11,918 sub-word writes reach
  // SDRAM over 600 M cycles of boot, against 686,647 full-word ones. Every one
  // of those would land in both lanes if DQM is ignored, and character RAM - the
  // glyph data - is in SDRAM.
  //
  // So the design stops depending on it. A partial write reads the word first,
  // merges the enabled byte in fabric, and writes back full width with both
  // lanes enabled. If the underlying fault is ever found this becomes an
  // optimisation to remove rather than a workaround to unpick.
  logic        rmw_active;   // this transaction is the READ half of a partial write
  logic        rmw_done;     // the merged word is ready
  // SET ONLY FOR THE DISPATCH THAT IS THE WRITE HALF.
  //
  // rmw_done alone is not safe to gate sdr_din on: it stays set from the read
  // completing until the write is acknowledged, and ANY other SDRAM write
  // dispatched in that window - a full-word one, or a fresh partial after the
  // CPU dropped the first request - would write the stale merged word instead of
  // its own data. That corrupts memory progressively, survives a core reset
  // because nothing reloads SDRAM, and clears only on a full MRA reload. Which
  // is exactly how it presented: correct for about ten minutes, then a black
  // screen, then the pre-fix picture after a reset.
  logic        rmw_wr;
  logic [15:0] rmw_merged;
  wire         needs_rmw = m_we && (m_be != 2'b11);

  assign sdr_we  = rmw_active ? 1'b0 : m_we;
  assign sdr_be  = rmw_active ? 2'b11 : (m_we ? 2'b11 : m_be);
  assign sdr_din = rmw_wr ? rmw_merged : m_wdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bst <= B_IDLE; sdr_req <= 1'b0; sdr_addr <= '0;
      rmw_active <= 1'b0; rmw_done <= 1'b0; rmw_merged <= '0; rmw_wr <= 1'b0;
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
              if (needs_rmw && !rmw_done) begin
                rmw_active <= 1'b1;
                rmw_wr     <= 1'b0;
                bst        <= B_SDRAM_RMW;
              end else begin
                // The merged word is used ONLY by the write half of the very
                // sequence that produced it; anything else takes m_wdata and
                // clears the flag, so a stale merge can never escape.
                rmw_wr     <= needs_rmw && rmw_done;
                rmw_done   <= 1'b0;
                bst        <= B_SDRAM;
              end
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
            rdata_r  <= sdr_dout;
            ack_r    <= 1'b1;
            rmw_wr   <= 1'b0;
            bst      <= B_ACK;
          end
        end

        // The READ half of a partial write. The merge happens here and the write
        // is re-dispatched from B_IDLE with both lanes enabled, so no mask ever
        // reaches the device.
        B_SDRAM_RMW: begin
          sdr_req <= 1'b0;
          if (sdr_ack && !sdr_ack_d) begin
            rmw_merged <= {m_be[1] ? m_wdata[15:8] : sdr_dout[15:8],
                           m_be[0] ? m_wdata[7:0]  : sdr_dout[7:0]};
            rmw_active <= 1'b0;
            rmw_done   <= 1'b1;
            bst        <= B_IDLE;
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
          else if (sel_listctl) rdata_r <= listctl_q;
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
