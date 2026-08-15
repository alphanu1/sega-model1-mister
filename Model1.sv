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
  wire clk_sys, clk_cpu, pll_locked;

  m1_pll pll (
    .refclk  (CLK_50M),
    .rst     (1'b0),
    .clk_sys (clk_sys),
    .clk_cpu (clk_cpu),
    .locked  (pll_locked)
  );

  // Held until the PLL locks and the OSD reset clears. Asynchronous assertion
  // is deliberate: m1_integrated synchronises release into each domain, which
  // is the part that has to be per-clock.
  wire rst_n = pll_locked & ~(RESET | status[0] | buttons[1]);

  // 96 MHz to the 16 MHz dot clock the board runs at.
  reg [2:0] pixdiv = 0;
  reg       ce_pix = 0;
  always @(posedge clk_sys) begin
    ce_pix <= (pixdiv == 3'd5);
    pixdiv <= (pixdiv == 3'd5) ? 3'd0 : pixdiv + 3'd1;
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
  assign p_addr = {24'd0, 24'd0, ifp_addr, {6'd0, char_addr}, sdr_addr};
  assign p_din  = {16'd0, 16'd0, 16'd0,    16'd0,             sdr_din};
  assign p_be   = {2'd0,  2'd0,  2'd0,     2'd0,              sdr_be};

  assign sdr_ack   = p_ack[0];
  assign char_ack  = p_ack[1];
  assign char_data = p_dout[1][31:0];

  wire        sd_dq_oe;
  wire [15:0] sd_dq_o;
  wire        mem_ready;

  m1_sdram sdram (
    .clk(clk_sys), .rst_n(rst_n), .ready(mem_ready),
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

  m1_integrated core (
    .clk_sys(clk_sys), .ce_pix(ce_pix),
    .clk_cpu(clk_cpu), .ce_cpu(1'b1),
    .rst_n(rst_n), .rom_loaded(mem_ready),

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

    .dbg_pc(), .dbg_halted(), .dbg_fp_trap(), .dbg_io_replies(),
    .rom_loaded_o(), .dbg_fetches()
  );

  // ------------------------------------------------------------------ video
  assign CLK_VIDEO = clk_sys;
  assign CE_PIXEL  = ce_pix;
  assign VGA_R     = vid_r;
  assign VGA_G     = vid_g;
  assign VGA_B     = vid_b;
  assign VGA_HS    = vid_hs;
  assign VGA_VS    = vid_vs;
  assign VGA_DE    = ~(vid_hb | vid_vb);

  // Lit while the ROM set is loading, so a failed load is visible without a
  // screen — the first thing to check when a board shows nothing.
  assign LED_USER  = ioctl_download;

endmodule
