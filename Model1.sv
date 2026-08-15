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
// MiSTer top level.
//
// WHAT THIS CORE CAN AND CANNOT DO TODAY
//
// It boots real Virtua Racing code and drives the 2D tilemap path. It does NOT
// render 3D: the TGP is built and verified but instantiated nowhere, there is
// no geometry pipeline, and the rasterizer is one block of several. Anything
// that would be drawn with polygons is simply absent, so attract mode will show
// its HUD and text layers over an empty field rather than a road.
//
// That is worth knowing before looking at a screen and concluding the video
// path is broken. The 2D path is verified against MAME at 380,929 checks, and
// the boot trace shows the V60 filling every memory it reads from — 168,288
// character RAM accesses, 53,673 to tile RAM, 40,960 to the colour translation
// tables and 8,433 real xBGR-555 palette entries.
//
// CLOCKS
//
// Two domains, because they cannot be one: the V60 closes at 23.81 MHz and the
// video path needs 68 MHz at an absolute minimum to fetch four tilemap layers
// inside a scanline. See rtl/m1_pll.sv for the frequency choice and
// rtl/m1_integrated.sv for what crosses between them.
module emu
(
  `include "sys/emu_ports.vh"
);

  // ------------------------------------------------------------- unused ports
  assign ADC_BUS  = 'Z;
  assign USER_OUT = '1;
  assign {UART_RTS, UART_TXD, UART_DTR} = 0;
  assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
  assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN,
          DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

  assign VGA_SL       = 0;
  assign VGA_F1       = 0;
  assign VGA_SCALER   = 0;
  assign VGA_DISABLE  = 0;
  assign HDMI_FREEZE  = 0;
  assign HDMI_BLACKOUT = 0;
  assign HDMI_BOB_DEINT = 0;

  // No sound yet: the 68000, YM3438 and two MultiPCMs are M4.
  assign AUDIO_S   = 0;
  assign AUDIO_L   = 0;
  assign AUDIO_R   = 0;
  assign AUDIO_MIX = 0;

  assign LED_DISK  = 0;
  assign LED_POWER = 0;
  assign BUTTONS   = 0;

  // 496x384 is close to 4:3; let the framework letterbox rather than stretch.
  assign VIDEO_ARX = 12'd4;
  assign VIDEO_ARY = 12'd3;

  // ------------------------------------------------------------------- OSD
  `include "build_id.v"
  localparam CONF_STR = {
    "Model1;;",
    "-;",
    "O[2],Video timing,Original 24kHz,Scandoubled;",
    "O[3],Debug overlay,On,Off;",
    "-;",
    "T[0],Reset;",
    "R[0],Reset and close OSD;",
    "V,v",`BUILD_DATE
  };

  wire        forced_scandoubler;
  wire  [1:0] buttons;
  wire [127:0] status;

  // ROM download. m1_rom_loader consumes this and writes SDRAM through the
  // controller's dedicated high-priority write port.
  wire        ioctl_download;
  wire        ioctl_wr;
  wire [26:0] ioctl_addr;
  wire [15:0] ioctl_dout;
  wire [15:0] ioctl_index;
  wire        ioctl_wait;

  hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
  (
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    .EXT_BUS(),
    .gamma_bus(),

    .forced_scandoubler(forced_scandoubler),
    .buttons(buttons),
    .status(status),

    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_index(ioctl_index),
    .ioctl_wait(ioctl_wait)
  );

  // ---------------------------------------------------------------- clocks
  //
  // The generated Altera PLL IP from rtl/pll.qip, NOT a hand-instantiated
  // altera_pll. Three things come with the IP that a direct instantiation does
  // not, and the core does not run without them:
  //
  //   * PLL_COMPENSATION_MODE DIRECT and operation_mode("direct"). A direct
  //     instantiation defaulting to "normal" uses feedback compensation, and
  //     with fbclk tied low it need not lock at all.
  //   * PLL_AUTO_RESET ON, which re-locks a PLL that fails to lock at
  //     configuration. Without it, rst tied to 0 means a PLL that misses lock
  //     once stays unlocked forever — and Quartus warns exactly that.
  //   * The module and instance both named `pll`, which is what sys_top.sdc's
  //     clock-group pattern and the MiSTer documentation require.
  //
  // 80 MHz and 19.2 MHz; see docs/m1-m4-plan.md for why those two numbers.
  wire clk_sys, clk_cpu, pll_locked;

  pll pll (
    .refclk   (CLK_50M),
    .rst      (1'b0),
    .outclk_0 (clk_sys),
    .outclk_1 (clk_cpu),
    .locked   (pll_locked)
  );

  // TWO RESETS, AND THE SPLIT IS LOAD-BEARING.
  //
  // The memory subsystem — SDRAM controller and ROM loader — comes out of reset
  // when the PLL locks and stays out. It must NOT follow the OSD or framework
  // reset, because MiSTer holds the core in reset while it streams a ROM: the
  // loader asserts ioctl_wait until SDRAM is ready, SDRAM is not ready while it
  // is held in reset, and the HPS then waits for a signal that only the HPS can
  // release. That deadlocks mid-transfer, which on screen is "Assembling ROM"
  // freezing partway with no error.
  //
  // The game side takes the OSD and framework resets as usual, and the V60 is
  // held additionally until the ROM is actually in memory.
  //
  // `mem_ready` IS NOT "THE ROM IS LOADED"
  //
  // It is m1_sdram's `ready`: JEDEC bring-up finished, about 100 us after the
  // PLL locks and long before the HPS has sent a single byte. Releasing the V60
  // on it starts the CPU on an SDRAM nobody has written — which reads as all
  // ones — while the ROM streams in underneath it. The CPU is then several
  // million cycles into executing nothing by the time its program arrives, and
  // nothing resets it afterwards, so it never starts again.
  //
  // On screen that is a solid white raster: the palette is written only by the
  // V60, an all-ones read fills it with 0xFFFF, and 0xFFFF is white. It looks
  // like a video fault and is a reset-sequencing one.
  //
  // The signal that does mean what is wanted is m1_rom_loader's own
  // `rom_loaded` — the stream has ended AND the write buffer has drained — so
  // that is what comes back out of the core and gates it here.
  wire rom_ready;

  // ioctl_download is deliberately NOT in this reset. Holding the game side
  // through the download also holds m1_video, which leaves vid_hb and vid_vb
  // asserted, VGA_DE low and no picture at all while the ROM streams — so the
  // diagnostic overlay, which is the only instrument this core has, is blank
  // for exactly the part of startup that most needs watching. The V60 is
  // already held by rom_ready below, which is what the download needed.
  wire mem_rst_n  = pll_locked;
  wire rst_n      = pll_locked & ~(RESET | status[0] | buttons[1]);

  // 80 MHz to the 16 MHz dot clock the board runs at. Exactly /5 — the dot
  // clock sets the refresh rate, so an inexact divider would show up as the
  // wrong frame rate rather than as anything obviously broken.
  reg [2:0] pixdiv = 0;
  reg       ce_pix = 0;
  always @(posedge clk_sys) begin
    ce_pix <= (pixdiv == 3'd4);
    pixdiv <= (pixdiv == 3'd4) ? 3'd0 : pixdiv + 3'd1;
  end

  // ------------------------------------------------------------------ SDRAM
  wire        sdr_req, sdr_we, sdr_ack;
  wire [24:1] sdr_addr;
  wire [15:0] sdr_din;
  wire  [1:0] sdr_be;

  wire        ifp_req;
  wire [24:1] ifp_addr;

  wire        char_req, char_ack;
  wire [17:0] char_addr;
  wire [31:0] char_data;

  wire        ldr_wr_req, ldr_wr_ack;
  wire [24:1] ldr_wr_addr;
  wire [15:0] ldr_wr_din;
  wire  [1:0] ldr_wr_be;

  wire [4:0]       p_req, p_we, p_ack;
  wire [4:0][24:1] p_addr;
  wire [4:0][15:0] p_din;
  wire [4:0][1:0]  p_be;
  wire [4:0][63:0] p_dout;

  // Port map per docs/00-decisions.md D8: p0 CPU data, p1 character RAM,
  // p2 instruction fetch. p3 and p4 are sound, unbuilt.
  assign p_req  = {2'b00, ifp_req,  char_req,           sdr_req};
  assign p_we   = {2'b00, 1'b0,     1'b0,               sdr_we};
  // Character RAM lives at CHAR_BASE in SDRAM, exactly where m1_main maps the
// CPU's writes to 0x780000-0x7fffff. The renderer emits an offset within that
// region, so the base has to be added here — without it the tilemap fetches
// from word 0, which is V60 program ROM, and every glyph decodes from the same
// wrong data. 31 distinct tile numbers then render identically and the screen
// is a uniform pattern that looks like a video bug rather than an address one.
assign p_addr = {24'd0, 24'd0, ifp_addr,
                 24'hFA8000 + {6'd0, char_addr}, sdr_addr};
  assign p_din  = {16'd0, 16'd0, 16'd0,    16'd0,             sdr_din};
  assign p_be   = {2'd0,  2'd0,  2'd0,     2'd0,              sdr_be};

  assign sdr_ack   = p_ack[0];
  assign char_ack  = p_ack[1];
  assign char_data = p_dout[1][31:0];

  wire        sd_dq_oe;
  wire [15:0] sd_dq_o;
  wire        mem_ready;

  // T_REFI is in clock cycles and this domain is 80 MHz: 8192 rows in 64 ms is
  // one refresh every 7.8125 us, which is 625 cycles. The default of 700 suits
  // 100 MHz and under-refreshes here — a data-retention fault that would look
  // like random ROM corruption rather than a timing setting.
  m1_sdram #(.T_REFI(600)) sdram (
    .clk(clk_sys), .rst_n(mem_rst_n), .ready(mem_ready),
    .sd_cke(SDRAM_CKE), .sd_cs_n(SDRAM_nCS), .sd_ras_n(SDRAM_nRAS),
    .sd_cas_n(SDRAM_nCAS), .sd_we_n(SDRAM_nWE), .sd_ba(SDRAM_BA),
    .sd_a(SDRAM_A), .sd_dqm({SDRAM_DQMH, SDRAM_DQML}),
    .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(SDRAM_DQ),
    .wr_req(ldr_wr_req), .wr_addr(ldr_wr_addr), .wr_din(ldr_wr_din),
    .wr_be(ldr_wr_be), .wr_ack(ldr_wr_ack),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack),
    .dbg_req(), .dbg_grant()
  );

  assign SDRAM_DQ  = sd_dq_oe ? sd_dq_o : 16'bZ;
  assign SDRAM_CLK = ~clk_sys;   // clock the device on the falling edge

  // ------------------------------------------------------------------- core
  wire [7:0] vid_r, vid_g, vid_b;
  wire       vid_hs, vid_vs, vid_hb, vid_vb;
  wire [23:0] dbg_pc;
  wire        dbg_halted, dbg_fp_trap, ldr_overflow;
  wire [15:0] dbg_io_replies;

  m1_integrated core (
    .clk_sys(clk_sys), .ce_pix(ce_pix),
    .clk_cpu(clk_cpu), .ce_cpu(1'b1),
    .rst_n(rst_n), .mem_rst_n(mem_rst_n),
    .rom_loaded(mem_ready & rom_ready),

    .sdr_req(sdr_req), .sdr_we(sdr_we), .sdr_addr(sdr_addr),
    .sdr_din(sdr_din), .sdr_be(sdr_be),
    .sdr_dout(p_dout[0][15:0]), .sdr_ack(sdr_ack),

    .if_req(ifp_req), .if_addr(), .if_sdram_addr(ifp_addr),
    .if_data(p_dout[2]), .if_ack(p_ack[2]),

    .char_req(char_req), .char_addr(char_addr),
    .char_data(char_data), .char_ack(char_ack),

    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .ldr_wr_req(ldr_wr_req), .ldr_wr_addr(ldr_wr_addr),
    .ldr_wr_din(ldr_wr_din), .ldr_wr_be(ldr_wr_be), .ldr_wr_ack(ldr_wr_ack),
    .tgp_wr(), .tgp_addr(), .tgp_din(),

    .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
    .vid_hs(vid_hs), .vid_vs(vid_vs), .vid_hb(vid_hb), .vid_vb(vid_vb),

    .mon_sel(3'd0), .mon_snap(1'b0),
    .mon_req(), .mon_grant(), .mon_wait(), .mon_bmax(), .mon_total(),
    .mon_req_in(5'd0), .mon_grant_in(5'd0),

    .dbg_pc(dbg_pc), .dbg_halted(dbg_halted), .dbg_fp_trap(dbg_fp_trap),
    .dbg_io_replies(dbg_io_replies),
    .rom_loaded_o(rom_ready), .ldr_overflow(ldr_overflow),
    .dbg_fetches()
  );

  // -------------------------------------------------------------- diagnostics
  //
  // Six words painted over the top left of the picture, readable off a phone
  // photograph. See rtl/video/m1_diag.sv for why this exists: on a bench the
  // screen is the only output channel, and without it every hypothesis about a
  // hardware-only fault costs a twenty-five minute Quartus build to test and
  // comes back as "still white".
  //
  // Everything here is observation only. Nothing in this block drives the core.
  wire [31:0] char_data_l, ldr_words, char_acks, cpu_reads, ioctl_words;
  wire [17:0] char_addr_l;

  reg [31:0] r_char_data, r_ldr_words, r_char_acks, r_cpu_reads, r_ioctl_words;
  reg [17:0] r_char_addr;
  reg        d_char_ack, d_ldr_req, d_sdr_ack;

  always @(posedge clk_sys) begin
    if (!mem_rst_n) begin
      r_char_data <= 0; r_ldr_words <= 0; r_char_acks <= 0; r_cpu_reads <= 0;
      r_char_addr <= 0; d_char_ack <= 0; d_ldr_req <= 0; d_sdr_ack <= 0;
      r_ioctl_words <= 0;
    end else begin
      // Words the HPS sent against words that reached SDRAM. These must be
      // equal; a shortfall is the loader having dropped what arrived after
      // ioctl_wait went up, which is a corrupt ROM reported as a good load.
      if (ioctl_wr && ioctl_download && ioctl_index == 16'd0)
        r_ioctl_words <= r_ioctl_words + 1'd1;

      d_char_ack <= char_ack;
      d_ldr_req  <= ldr_wr_req;
      d_sdr_ack  <= sdr_ack;

      // The last character-RAM word the renderer was given. All ones here is
      // the signature of a tilemap reading memory the CPU never wrote — which
      // renders as pixel value 0xF everywhere, palette index 0x00F, and a
      // uniform white screen.
      if (char_ack && !d_char_ack) begin
        r_char_data <= char_data;
        r_char_addr <= char_addr;
        r_char_acks <= r_char_acks + 1'd1;
      end

      // Counted on the rising edge of req, which is the loader's contract with
      // the write port: one transaction per edge. The whole stream is
      // 0x300000 words, so anything short says the download stopped early.
      if (ldr_wr_req && !d_ldr_req) r_ldr_words <= r_ldr_words + 1'd1;

      if (sdr_ack && !d_sdr_ack) r_cpu_reads <= r_cpu_reads + 1'd1;
    end
  end

  assign char_data_l = r_char_data;
  assign char_addr_l = r_char_addr;
  assign ldr_words   = r_ldr_words;
  assign char_acks   = r_char_acks;
  assign cpu_reads   = r_cpu_reads;
  assign ioctl_words = r_ioctl_words;

  // dbg_pc and friends live in the CPU domain and are sampled here in the
  // video one through two flops. That is enough for something a human reads
  // off a still image: individual bits are stable, but the 24 bits are not
  // guaranteed to be one coherent instant, so a PC that is changing every
  // cycle can show a value the CPU never had. A PC that is parked — which is
  // the case this exists to diagnose — reads exactly.
  reg [23:0] pc_s1, pc_s2;
  reg [17:0] st_s1, st_s2;
  always @(posedge clk_sys) begin
    pc_s1 <= dbg_pc;
    pc_s2 <= pc_s1;
    st_s1 <= {dbg_halted, dbg_fp_trap, dbg_io_replies};
    st_s2 <= st_s1;
  end

  // The rows, top of the screen first. Each leads with its own row number so a
  // photograph that is cropped, rotated or partly glared out can still be
  // matched up row by row instead of counted from an edge that may not be in
  // the frame.
  wire [31:0] dw [8];
  assign dw[0] = {8'h00, pc_s2};                       // V60 program counter
  assign dw[1] = char_data_l;                          // last character data
  assign dw[2] = {8'h02, 6'd0, char_addr_l};           // ...and its address
  assign dw[3] = ioctl_words;                          // words the HPS sent
  assign dw[4] = ldr_words;                            // ...that reached SDRAM
  assign dw[5] = char_acks;                            // character fetches
  assign dw[6] = cpu_reads;                            // CPU data reads
  assign dw[7] = {8'h07, 2'd0, ldr_overflow, st_s2[17:16],
                  rom_ready, mem_ready, ioctl_download,
                  st_s2[15:0]};                        // I/O replies

  wire [7:0] dg_r, dg_g, dg_b;

  // Word 0 is the LOW 32 bits of the port and the top row of the display, so
  // the concatenation runs bottom row first. Written with explicit indices
  // rather than as a list, because getting this backwards produces a display
  // that is perfectly legible and entirely wrong.
  m1_diag #(.NWORDS(8)) diag (
    .clk(clk_sys), .ce_pix(ce_pix), .rst_n(mem_rst_n),
    .enable(~status[3]),
    .hb(vid_hb), .vb(vid_vb),
    .words({dw[7], dw[6], dw[5], dw[4], dw[3], dw[2], dw[1], dw[0]}),
    .in_r(vid_r), .in_g(vid_g), .in_b(vid_b),
    .out_r(dg_r), .out_g(dg_g), .out_b(dg_b)
  );

  // ------------------------------------------------------------------ video
  assign CLK_VIDEO = clk_sys;
  assign CE_PIXEL  = ce_pix;
  assign VGA_R     = dg_r;
  assign VGA_G     = dg_g;
  assign VGA_B     = dg_b;
  assign VGA_HS    = vid_hs;
  assign VGA_VS    = vid_vs;
  assign VGA_DE    = ~(vid_hb | vid_vb);

  // Lit while the ROM set is loading, so a failed load is visible without a
  // screen — the first thing to check when a board shows nothing.
  assign LED_USER  = ioctl_download;

endmodule
