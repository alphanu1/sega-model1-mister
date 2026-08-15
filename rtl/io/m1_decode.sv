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
// 315-5465 address decode: V60 bus -> chip selects, and V60 ROM addresses ->
// packed SDRAM addresses.
//
// Transcribed from `model1_state::model1_mem` in MAME's model1.cpp. The region
// comments (ROMA, RAMB, SCR, CPR, GLUE) are Sega's own names, carried over from
// that map so the two can be read side by side.
//
// THE V60 ROM REGION IS SPARSE, AND THAT IS WHY THIS EXISTS
//
// The loader maps the ioctl stream to SDRAM as the identity, because the MRA
// controls the layout. That works for every region except the V60's, because
// MAME's `maincpu` is not contiguous — measured across all ten dumped games it
// spans 19.5 MB of address space holding 5.5 MB of ROM:
//
//   0x0000000            ROMA, empty in every dumped game
//   0x0200000  1   MB    ROMX, the program
//   0x0F80000  512 KB    ROM0, the boot vectors (256 KB used)
//   0x1000000  4   MB    the data ROMs banked into 0x100000-0x1fffff
//
// Storing that sparsely would cost 19.5 MB of a 32 MB module for 5.5 MB of
// ROM. So the MRA packs it and this block maps V60 addresses onto the packed
// layout. The mapping is here rather than in the loader because it is a
// property of the V60's address space, which is fixed silicon, not of the
// stream, which the MRA controls.
//
// Packed SDRAM layout, byte addresses. Everything from 0x0600000 on is
// untouched by this subdivision — those bases are the loader's.
//
//   0x0000000  1   MB   V60 program        <- V60 0x200000-0x2fffff
//   0x0100000  512 KB   V60 boot           <- V60 0xf80000-0xffffff
//   0x0180000  4   MB   V60 banked data    <- V60 0x100000-0x1fffff, +bank
//   0x0580000  512 KB   TGP data ROM
//   0x0600000  1   MB   sound 68000
//   0x0700000  4   MB   MultiPCM 1
//   0x0B00000  4   MB   MultiPCM 2
//   0x0F00000  16  MB   polygon ROM
//                       ------------------
//                       31 MB, so D2 holds against measured sizes rather than
//                       against MAME's region declarations, which are upper
//                       bounds and total 33 MB.

`timescale 1ns/1ps

module m1_decode (
  // V60 byte address. Model 1 decodes 24 bits; the V60 drives 32 but nothing
  // above bit 23 is connected on the board.
  input  logic [23:0] addr,

  // Bank register, written through the GLUE region. MAME's bank_w takes the
  // low nibble as a selector and bits 7:4 as the bank; only selector 1, the
  // 0x100000-0x1fffff data ROM window, is used by any dumped game.
  input  logic [2:0]  rom_bank,

  // ---- chip selects, one-hot
  output logic        sel_rom,        // any ROM region that is mapped
  output logic        sel_rom_void,   // ROMA: decoded, but no game populates it
  output logic        sel_nvram,      // RAMA
  output logic        sel_wram,       // RAMB
  output logic        sel_dlist0,
  output logic        sel_dlist1,
  output logic        sel_listctl,
  output logic        sel_tileram,    // SCR tile_r/w
  output logic        sel_charram,    // SCR char_r/w
  output logic        sel_vsync,      // write-only sync registers, discarded
  output logic        sel_palette,    // COL
  output logic        sel_colxlat,
  output logic        sel_dpram,      // I/O board dual-port RAM
  output logic        sel_uart,
  output logic        sel_copro_adr,  // CPR
  output logic        sel_copro_ram,
  output logic        sel_copro_fifo,
  output logic        sel_fifo_stat,
  output logic        sel_glue,       // irq control, bank, timer

  // SDRAM word address for ROM reads. Only meaningful when sel_rom is set.
  output logic [24:1] rom_addr
);

  // Region compares are written against the same address slices MAME's map
  // uses, so a change there is a one-line change here.
  wire [7:0] hi = addr[23:16];

  always_comb begin
    sel_rom        = 1'b0;
    sel_rom_void   = 1'b0;
    sel_nvram      = 1'b0;
    sel_wram       = 1'b0;
    sel_dlist0     = 1'b0;
    sel_dlist1     = 1'b0;
    sel_listctl    = 1'b0;
    sel_tileram    = 1'b0;
    sel_charram    = 1'b0;
    sel_vsync      = 1'b0;
    sel_palette    = 1'b0;
    sel_colxlat    = 1'b0;
    sel_dpram      = 1'b0;
    sel_uart       = 1'b0;
    sel_copro_adr  = 1'b0;
    sel_copro_ram  = 1'b0;
    sel_copro_fifo = 1'b0;
    sel_fifo_stat  = 1'b0;
    sel_glue       = 1'b0;
    rom_addr       = '0;

    // ---------------------------------------------------------------- ROM
    if (hi <= 8'h0f) begin
      // ROMA. Decoded so it does not fall through to "nothing", but no dumped
      // game loads anything here, so it must read as erased rather than
      // aliasing onto another region's data.
      sel_rom_void = 1'b1;
    end else if (hi <= 8'h1f) begin
      // ROMO: the banked data ROM window.
      sel_rom  = 1'b1;
      rom_addr = 24'h0C0000 + {rom_bank, 19'd0} + {5'd0, addr[19:1]};
    end else if (hi <= 8'h2f) begin
      // ROMX: the program.
      sel_rom  = 1'b1;
      rom_addr = 24'h000000 + {5'd0, addr[19:1]};
    end else if (hi >= 8'hf8) begin
      // ROM0: boot vectors. The V60 resets into the top of memory.
      sel_rom  = 1'b1;
      rom_addr = 24'h080000 + {6'd0, addr[18:1]};

    // ---------------------------------------------------------------- RAM
    end else if (hi == 8'h40) begin
      sel_nvram = 1'b1;                       // RAMA, battery backed
    end else if (hi >= 8'h50 && hi <= 8'h53) begin
      sel_wram = 1'b1;                        // RAMB, work RAM

    // ---------------------------------------------------------------- TGP
    end else if (hi == 8'h60) begin
      sel_dlist0 = 1'b1;
    end else if (hi == 8'h61) begin
      sel_dlist1 = 1'b1;
    end else if (hi == 8'h68) begin
      sel_listctl = 1'b1;

    // ---------------------------------------------------------------- SCR
    end else if (hi == 8'h70) begin
      sel_tileram = 1'b1;
    end else if (hi == 8'h72 || hi == 8'h74 || hi == 8'h76 || hi == 8'h77) begin
      // Horizontal/vertical sync and the video mode switch. MAME discards
      // them; they are decoded here so they cannot read as unmapped.
      sel_vsync = 1'b1;
    end else if (hi >= 8'h78 && hi <= 8'h7f) begin
      sel_charram = 1'b1;

    // ---------------------------------------------------------------- COL
    end else if (hi == 8'h90) begin
      sel_palette = 1'b1;
    end else if (hi == 8'h91) begin
      sel_colxlat = 1'b1;

    // ---------------------------------------------------------------- I/O
    end else if (hi == 8'hc0) begin
      sel_dpram = 1'b1;
    end else if (hi == 8'hc4) begin
      sel_uart = 1'b1;

    // ---------------------------------------------------------------- CPR
    // Every copro register carries a mirror in MAME's map — .mirror(0x1fffe)
    // on the address register and .mirror(0x1fffc) on the rest — so each one
    // covers a full 128 KB rather than the four bytes it appears to occupy.
    // Decoding only the base address would leave software that uses a mirror
    // reading nothing, and Sega's code does use them.
    end else if (hi == 8'hd0 || hi == 8'hd1) begin
      sel_copro_adr = 1'b1;
    end else if (hi == 8'hd2 || hi == 8'hd3) begin
      sel_copro_ram = 1'b1;
    end else if (hi == 8'hd8 || hi == 8'hd9) begin
      sel_copro_fifo = 1'b1;
    end else if (hi == 8'hdc || hi == 8'hdd) begin
      sel_fifo_stat = 1'b1;

    // --------------------------------------------------------------- GLUE
    end else if (hi == 8'he0) begin
      sel_glue = 1'b1;
    end
  end

endmodule
