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

  // SDRAM word addresses, from the byte layout above.
  parameter logic [24:1] WRAM_BASE = 24'hF80000,   // 0x1F00000 >> 1
  parameter logic [24:1] NVRAM_BASE = 24'hFA0000,  // 0x1F40000 >> 1
  parameter logic [24:1] CHAR_BASE = 24'hFA8000    // 0x1F50000 >> 1
) (
  input  logic        clk,
  input  logic        ce,          // V60 clock enable
  input  logic        rst_n,
  input  logic        rom_loaded,  // hold the CPU until the ROMs are there

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

  // Tile RAM, second port for the video renderer.
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
    .irq_n(irq_n), .irq_vector(8'h00), .irq_ack(), .nmi_n(1'b1),
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
  logic [15:0] tram  [32768];   // SCR  0x700000-0x70ffff
  logic [15:0] pram  [8192];    // COL  0x900000-0x903fff
  logic [15:0] dl0   [32768];   // TGP  0x600000-0x60ffff
  logic [15:0] dl1   [32768];   // TGP  0x610000-0x61ffff
  logic [15:0] cxlat [24576];   // COL  0x910000-0x91bfff
  logic [15:0] dpram [2048];    // I/O  0xc00000-0xc00fff

  logic [15:0] tram_q, pram_q, dl0_q, dl1_q, cxlat_q, dpram_q;

  always_ff @(posedge clk) begin
    if (m_req && m_we && sel_tileram) begin
      if (m_be[0]) tram[m_addr[15:1]][7:0]  <= m_wdata[7:0];
      if (m_be[1]) tram[m_addr[15:1]][15:8] <= m_wdata[15:8];
    end
    tram_q        <= tram[m_addr[15:1]];
    vid_tram_data <= tram[vid_tram_addr];
  end

  always_ff @(posedge clk) begin
    if (m_req && m_we && sel_palette) begin
      if (m_be[0]) pram[m_addr[13:1]][7:0]  <= m_wdata[7:0];
      if (m_be[1]) pram[m_addr[13:1]][15:8] <= m_wdata[15:8];
    end
    pram_q       <= pram[m_addr[13:1]];
    vid_pal_data <= pram[{1'b0, vid_pal_addr}];
  end

  // Byte-enabled like the rest: the V60 writes bytes as well as words, and a
  // region that only takes 16-bit writes corrupts every byte store to it.
  always_ff @(posedge clk) begin
    if (m_req && m_we && sel_dlist0) begin
      if (m_be[0]) dl0[m_addr[15:1]][7:0]  <= m_wdata[7:0];
      if (m_be[1]) dl0[m_addr[15:1]][15:8] <= m_wdata[15:8];
    end
    dl0_q <= dl0[m_addr[15:1]];

    if (m_req && m_we && sel_dlist1) begin
      if (m_be[0]) dl1[m_addr[15:1]][7:0]  <= m_wdata[7:0];
      if (m_be[1]) dl1[m_addr[15:1]][15:8] <= m_wdata[15:8];
    end
    dl1_q <= dl1[m_addr[15:1]];

    if (m_req && m_we && sel_colxlat && (m_addr[15:1] < 15'd24576)) begin
      if (m_be[0]) cxlat[m_addr[14:1]][7:0]  <= m_wdata[7:0];
      if (m_be[1]) cxlat[m_addr[14:1]][15:8] <= m_wdata[15:8];
    end
    cxlat_q <= cxlat[m_addr[14:1]];

    if (m_req && m_we && sel_dpram) begin
      if (m_be[0]) dpram[m_addr[11:1]][7:0]  <= m_wdata[7:0];
      if (m_be[1]) dpram[m_addr[11:1]][15:8] <= m_wdata[15:8];
    end
    dpram_q <= dpram[m_addr[11:1]];
  end

  // ---------------------------------------------------------- GLUE regs
  // Extracted into m1_glue so the interrupt semantics can be tested directly.
  // They are subtle enough to have already been wrong here once — see that
  // file's header on the mask polarity.
  logic [15:0] glue_rdata;

  m1_glue glue (
    .clk(clk), .ce(ce), .rst_n(rst_n),
    .sel(sel_glue), .we(m_req && m_we), .a(m_addr[3:1]),
    .be(m_be), .wdata(m_wdata), .rdata(glue_rdata),
    .vblank(vblank_irq),
    .irq_n(irq_n), .rom_bank(rom_bank)
  );

  // --------------------------------------------------------- bus routing
  typedef enum logic [1:0] { B_IDLE, B_SDRAM, B_LOCAL, B_ACK } bstate_t;
  bstate_t bst;

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
          if      (sel_tileram) rdata_r <= tram_q;
          else if (sel_palette) rdata_r <= pram_q;
          else if (sel_dlist0)  rdata_r <= dl0_q;
          else if (sel_dlist1)  rdata_r <= dl1_q;
          else if (sel_colxlat) rdata_r <= cxlat_q;
          else if (sel_dpram)   rdata_r <= dpram_q;
          else if (sel_glue)    rdata_r <= glue_rdata;
          // Everything the board does not decode, plus the regions this does
          // not implement yet: acknowledge and read as an unpulled bus.
          else                  rdata_r <= 16'hFFFF;
          ack_r <= 1'b1;
          bst   <= B_ACK;
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
