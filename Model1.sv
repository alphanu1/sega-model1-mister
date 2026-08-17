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
  assign VIDEO_ARX = 13'd4;
  assign VIDEO_ARY = 13'd3;

  // ------------------------------------------------------------------- OSD
  `include "build_id.v"
  localparam CONF_STR = {
    "Model1;;",
    "-;",
    "O[2],Video timing,Original 24kHz,Scandoubled;",
    "O[3],Debug overlay,Off,On;",
    "O[5:4],SDRAM read phase,CL+2,CL+3,CL+4,CL+5;",
    "O[6],Test switch,Off,On;",
    "O[7],Service switch,Off,On;",
    "-;",
    "T[0],Reset;",
    "R[0],Reset and close OSD;",
    "V,v",`BUILD_DATE
  };

  wire        forced_scandoubler;
  wire  [1:0] buttons;
  wire [127:0] status;

  wire [31:0] joy0, joy1;
  wire [15:0] joy0_lstick, joy0_rstick;
  wire [10:0] ps2_key;

  // The board's controls, gathered in one place so the I/O board takes a named
  // bundle rather than reaching into hps_io's bit order.
  //
  // MRA order is Start, Coin, Service, Test. MiSTer's joystick bits are
  // right,left,down,up then the buttons in order, so the four the MRAs name
  // are bits 4..7.
  // Virtua Racing's control panel, from model1.cpp's INPUT_PORTS( vr ): coin,
  // test, service, start, four VR view buttons and a two-position shifter.
  // Twelve digital controls, not the four the generic MRA line named.
  //
  // Test and service are OSD switches as well as buttons: they are things you
  // set before boot rather than press during play, and mapping a pad button to
  // something you need held at power-on is awkward.
  // Bit order matches the MRA's <buttons names=...> list, which is what maps
  // pad buttons onto these. The two must be edited together — they disagreed
  // once, the MRA naming bit 4 "Start" while this read it as Coin, and a
  // mismatch there is invisible until someone presses the button.
  wire io_accel_b  = joy0[4];
  wire io_brake_b  = joy0[5];
  wire io_shift_up = joy0[6];
  wire io_shift_dn = joy0[7];
  wire io_vr1      = joy0[8];
  wire io_vr2      = joy0[9];
  wire io_vr3      = joy0[10];
  wire io_vr4      = joy0[11];
  wire io_start    = joy0[12];
  wire io_coin     = joy0[13];
  wire io_service  = joy0[14] | status[7];
  wire io_test     = joy0[15] | status[6];

  // Coin 2 has a real bit on the board — measured at IN.0 bit 1 — and is left
  // off the MRA's name list because this is a single-seat cabinet and the pad
  // has run out of buttons. Wired rather than tied off, so naming it later is
  // one line rather than a hunt for which bit it was.
  wire io_coin2    = joy0[16];

  // Steering on the d-pad as well as the stick.
  wire io_steer_l  = joy0[1];
  wire io_steer_r  = joy0[0];

  // Steering and pedals. Virtua Racing reads these through the I/O board's
  // MSM6253 ADC, so they are 8-bit unsigned there; MiSTer delivers signed
  // -128..127 on each axis, hence the offset.
  // The eight bytes published into the shared RAM. Idle is 0xFF because every
  // control in MAME's model1.cpp is IP_ACTIVE_LOW; a byte left at zero reads as
  // every button on it held down.
  //
  // Byte 0 is Virtua Racing's IN.0 and byte 1 its IN.1, in MAME's bit order.
  // WHERE these land in the DPRAM is a parameter on m1_ioboard and is not yet
  // confirmed — see docs/io-board.md. The bit assignment within a byte is from
  // model1.cpp and is not a guess; the base address is.
  // Bit order is MAME's INPUT_PORTS( vr ), not a guess:
  //   IN.0  0 coin1, 1 coin2, 2 test, 3 service, 4 start, 5 VR1, 6 VR2, 7 VR3
  //   IN.1  0 VR4, 4 shift down, 5 shift up
  // Inverted because every control on this hardware is active low.
  wire [7:0] io_in0 = ~{io_vr3, io_vr2, io_vr1, io_start,
                        io_service, io_test, io_coin2, io_coin};
  wire [7:0] io_in1 = ~{2'b00, io_shift_up, io_shift_dn, 3'b000, io_vr4};
  wire [7:0] io_in2 = 8'hff;          // drive board RX line, nothing on it here

  // The three MSM6253 channels. Each idle value is measured rather than assumed
  // — see docs/io-board.md — and they are not the same: steering rests centred
  // at 0x80, while a released pedal reads 0x01, matching MAME's
  // PORT_MINMAX(1,0xff). Resting a pedal at 0x00 or 0xff is a car that will not
  // move or will not stop.
  //
  // The d-pad goes to full lock rather than ramping. That is what a digital
  // steering input does on the cabinet, and a pad has no travel to interpolate.
  wire [7:0] wheel_stick = {~joy0_lstick[7], joy0_lstick[6:0]};
  wire [7:0] io_wheel = io_steer_l ? 8'h00 :
                        io_steer_r ? 8'hff : wheel_stick;

  // Buttons, not axes. hps_io's analog ports are two-axis sticks, so there is
  // no travel to read from them for a pedal; a button giving full press is
  // honest about that rather than pretending to be analog.
  wire [7:0] io_accel = io_accel_b ? 8'hff : 8'h01;
  wire [7:0] io_brake = io_brake_b ? 8'hff : 8'h01;

  // The fifteen bytes the sweep publishes, DPRAM 0x00 first. The DIP banks read
  // as all-ones — every switch off — until an MRA <switches> element drives
  // them. 0x03-0x07 are 0xff because that is what the real board sets them to
  // at startup; what they carry is not known.
  wire [119:0] io_in_bytes = {8'hff,     // 0x0e port 6
                              8'hff,     // 0x0d DSW3
                              8'hff,     // 0x0c DSW2
                              8'hff,     // 0x0b DSW1
                              io_in2,    // 0x0a
                              io_in1,    // 0x09
                              io_in0,    // 0x08
                              8'hff,     // 0x07
                              8'hff,     // 0x06
                              8'hff,     // 0x05
                              8'hff,     // 0x04
                              8'hff,     // 0x03
                              io_brake,  // 0x02
                              io_accel,  // 0x01
                              io_wheel}; // 0x00

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

    // CONTROLS. Wired here so they exist; what consumes them is the I/O board.
    //
    // Until now hps_io was instantiated with none of these, so every MRA's
    // <buttons names="Start,Coin,Service,Test,-,-"> went nowhere and the
    // service menu could not be operated at all. Virtua Racing is a driving
    // game: steering is an analog axis and the pedals are two more, so the
    // analog ports are taken as well as the digital ones.
    .joystick_0(joy0),
    .joystick_1(joy1),
    .joystick_l_analog_0(joy0_lstick),
    .joystick_r_analog_0(joy0_rstick),
    .ps2_key(ps2_key),

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
  // `rom_loaded` — the stream has ended AND the write buffer has drained.
  //
  // It is combined with mem_ready INSIDE m1_integrated, not here. Routing it
  // out and feeding it back in as the core's mem_ready deadlocks the download:
  // the loader holds ioctl_wait until SDRAM is ready, and SDRAM would not be
  // reported ready until the loader had finished. rom_ready is brought out for
  // the overlay only.
  wire rom_ready;

  // ioctl_download is deliberately NOT in this reset. Holding the game side
  // through the download also holds m1_video, which leaves vid_hb and vid_vb
  // asserted, VGA_DE low and no picture at all while the ROM streams — so the
  // diagnostic overlay, which is the only instrument this core has, is blank
  // for exactly the part of startup that most needs watching. The V60 is
  // already held inside the core until the ROM lands, which is what was
  // actually wanted.
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
  assign p_req  = {1'b0, tgp_mem_req, ifp_req, char_req, sdr_req};
  assign p_we   = {1'b0, 1'b0,        1'b0,    1'b0,     sdr_we};
  // Character RAM lives at CHAR_BASE in SDRAM, exactly where m1_main maps the
// CPU's writes to 0x780000-0x7fffff. The renderer emits an offset within that
// region, so the base has to be added here — without it the tilemap fetches
// from word 0, which is V60 program ROM, and every glyph decodes from the same
// wrong data. 31 distinct tile numbers then render identically and the screen
// is a uniform pattern that looks like a video bug rather than an address one.
// p3's address is aligned down to its 4-word burst boundary; m1_integrated keeps
// bit 1 to pick which 32-bit half of the burst it wanted.
assign p_addr = {24'd0, {tgp_mem_addr[24:2], 1'b0}, ifp_addr,
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
  // READ CAPTURE PHASE, SELECTABLE FROM THE OSD.
  //
  // The board returned every burst shifted right by one 16-bit word — the
  // controller called the burst's word 1 its word 0 — which is what left the
  // V60 reading FE104E as its reset vector where the ROM holds 4EF3D6. The
  // derivation of CL+3 in m1_sdram is against sdram_model, which presents data
  // on the same clock edge the controller uses; the board's device is clocked
  // on the inverse of clk_sys and so answers half a period away.
  //
  // Rather than guess the correction one twenty-five minute build at a time,
  // the phase is an OSD option. It defaults to CL+2, one cycle earlier than the
  // model needs, which is what the measured shift implies.
  m1_sdram #(.T_REFI(600)) sdram (
    .clk(clk_sys), .rst_n(mem_rst_n), .ready(mem_ready),
    // OSD order is CL+2, CL+3, CL+4, CL+5 and the selector's own encoding puts
    // CL+3 at zero, so the two are mapped rather than passed through. The board
    // wants CL+2, which is the OSD default.
    .rd_lat_sel(status[5:4] == 2'd0 ? 2'd1 :
                status[5:4] == 2'd1 ? 2'd0 : status[5:4]),
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
  wire [15:0] dbg_copro_pushes, dbg_copro_returns;
  wire [17:0] dbg_layer_px [4];
  wire [15:0] dbg_ctrl [2];
  wire        tgp_mem_req;
  wire [24:1] tgp_mem_addr;
  wire [15:0] dbg_tgp_retires, dbg_tgp_pc;
  wire        dbg_tgp_unimpl;
  wire  [7:0] dbg_fetches;
  wire [15:0] dbg_overruns;
  wire [15:0] dbg_io_replies;

  m1_integrated core (
    .clk_sys(clk_sys), .ce_pix(ce_pix),
    .clk_cpu(clk_cpu), .ce_cpu(1'b1),
    .rst_n(rst_n), .mem_rst_n(mem_rst_n), .mem_ready(mem_ready),
    .in_bytes(io_in_bytes),

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
    .tgp_mem_req(tgp_mem_req), .tgp_mem_addr(tgp_mem_addr),
    .tgp_mem_dout(p_dout[3]), .tgp_mem_ack(p_ack[3]),
    .dbg_tgp_retires(dbg_tgp_retires), .dbg_tgp_pc(dbg_tgp_pc),
    .dbg_tgp_unimpl(dbg_tgp_unimpl),
    .dbg_copro_pushes(dbg_copro_pushes), .dbg_copro_returns(dbg_copro_returns),

    .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
    .vid_hs(vid_hs), .vid_vs(vid_vs), .vid_hb(vid_hb), .vid_vb(vid_vb),

    .mon_sel(3'd0), .mon_snap(1'b0),
    .mon_req(), .mon_grant(), .mon_wait(), .mon_bmax(), .mon_total(),
    .mon_req_in(5'd0), .mon_grant_in(5'd0),

    .dbg_pc(dbg_pc), .dbg_halted(dbg_halted), .dbg_fp_trap(dbg_fp_trap),
    .dbg_io_replies(dbg_io_replies),
    .rom_loaded_o(rom_ready), .ldr_overflow(ldr_overflow),
    .dbg_fetches(dbg_fetches), .dbg_overruns(dbg_overruns),
    .dbg_layer_px(dbg_layer_px), .dbg_ctrl(dbg_ctrl)
  );

  // -------------------------------------------------------------- diagnostics
  //
  // DEBUG_OVERLAY=0 removes the whole instrument — the renderer, the capture
  // registers, the fetch trace and the frame-rate counters — so its cost can be
  // measured by building both ways rather than estimated, and so a release
  // build can drop it. See docs/debug-overlay.md for the measurement and for
  // what every row means.
  localparam bit DEBUG_OVERLAY = 1;

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

  // THE WHOLE OF THE CPU'S LIFE, BECAUSE IT IS ONLY SIX FETCHES LONG.
  //
  // The board reports the V60 halted at PC 3 after exactly six instruction
  // fetches. Six is small enough to enumerate, and simulation on identical RTL
  // gives the sequence they should be:
  //
  //   0  000000   a prefetch artefact, address not yet valid
  //   1  0bfff8   THE RESET VECTOR: f3d6 104e 00fe -> PC fe104e
  //   2  0bfffc
  //   3  000000
  //   4  0b0824   boot code, V60 fe1048
  //   5  0b0828
  //
  // The counter freezing at six is itself evidence: V60 address 0 is work RAM,
  // which is on chip, so a CPU that jumped there would stop generating SDRAM
  // fetches entirely — exactly what a null reset vector would produce.
  //
  // So capture all of them and put them on screen. Whichever row first
  // disagrees with the table above is where hardware leaves the rails, and the
  // data rows say whether it was given the wrong bytes or given the right ones
  // and mis-executed them.
  localparam int unsigned NFETCH = 8;
  reg [24:1] fa [NFETCH];
  reg [31:0] fd [NFETCH];
  reg [3:0]  fn;
  reg [31:0] r_if_count;
  reg        d_if_ack;

  integer fi;
  always @(posedge clk_sys) begin
    if (!mem_rst_n) begin
      fn <= 0; r_if_count <= 0; d_if_ack <= 0;
      for (fi = 0; fi < NFETCH; fi = fi + 1) begin
        fa[fi] <= 0; fd[fi] <= 0;
      end
    end else begin
      d_if_ack <= p_ack[2];
      if (p_ack[2] && !d_if_ack) begin
        r_if_count <= r_if_count + 1'd1;
        // fn is four bits so it can hold NFETCH itself as the "full" state, but
        // the arrays are NFETCH=8 deep, so index with the low three. The guard
        // makes them equivalent; spelling it out keeps the width lint clean.
        if (fn < 4'(NFETCH)) begin
          fa[fn[2:0]] <= ifp_addr;
          fd[fn[2:0]] <= p_dout[2][31:0];
          fn          <= fn + 4'd1;
        end
      end
    end
  end

  assign char_data_l = r_char_data;
  assign char_addr_l = r_char_addr;
  assign ldr_words   = r_ldr_words;
  assign char_acks   = r_char_acks;
  assign cpu_reads   = r_cpu_reads;
  assign ioctl_words = r_ioctl_words;

  // dbg_pc and friends live in the CPU domain and are sampled here in the
  // video one through two flops. Enough for something read off a still image:
  // a PC that is parked — which is the case this exists to diagnose — reads
  // exactly, while one changing every cycle may show a value never held.
  reg [23:0] pc_s1, pc_s2;
  reg [17:0] st_s1, st_s2;
  always @(posedge clk_sys) begin
    pc_s1 <= dbg_pc;
    pc_s2 <= pc_s1;
    st_s1 <= {dbg_halted, dbg_fp_trap, dbg_io_replies};
    st_s2 <= st_s1;
  end

  // FRAME RATE, MEASURED RATHER THAN ASSUMED.
  //
  // The core is meant to emit MAME's 57.52 Hz and MiSTer's own Information
  // screen agrees, but that reports what the scaler locked onto, not what the
  // core produced. This counts the core's own vertical syncs.
  //
  // Two numbers because they answer different questions. Frames per ten
  // seconds in BCD gives one decimal place — 0575 reads as 57.5 Hz — and is
  // the number to quote. The frame period in clk_sys cycles updates every
  // frame and is exact, so a rate that is drifting or a frame that is the
  // wrong length shows up immediately instead of being averaged away.
  //
  // 1,390,720 cycles is the nominal period: 656 x 424 dots at five clk_sys
  // per dot.
  reg [26:0] fps_cyc;
  reg  [3:0] fps_sec;
  reg [15:0] fps_bcd_run, fps_bcd;
  reg [23:0] fper_run, fper;
  reg        d_vs;

  // BCD so the digits render as themselves; a binary count would need dividing
  // by hand off a photograph, which is exactly the sort of arithmetic this
  // overlay exists to remove.
  function automatic [15:0] bcd_inc(input [15:0] v);
    reg [15:0] r;
    begin
      r = v;
      if (r[3:0] == 4'd9) begin
        r[3:0] = 4'd0;
        if (r[7:4] == 4'd9) begin
          r[7:4] = 4'd0;
          if (r[11:8] == 4'd9) begin
            r[11:8]  = 4'd0;
            r[15:12] = r[15:12] + 4'd1;
          end else r[11:8] = r[11:8] + 4'd1;
        end else r[7:4] = r[7:4] + 4'd1;
      end else r[3:0] = r[3:0] + 4'd1;
      bcd_inc = r;
    end
  endfunction

  always @(posedge clk_sys) begin
    if (!mem_rst_n) begin
      fps_cyc <= 0; fps_sec <= 0; fps_bcd_run <= 0; fps_bcd <= 0;
      fper_run <= 0; fper <= 0; d_vs <= 0;
    end else begin
      d_vs     <= vid_vs;
      fper_run <= fper_run + 1'd1;

      if (vid_vs && !d_vs) begin
        fper        <= fper_run;
        fper_run    <= 0;
        fps_bcd_run <= bcd_inc(fps_bcd_run);
      end

      if (fps_cyc == 27'd79_999_999) begin
        fps_cyc <= 0;
        if (fps_sec == 4'd9) begin
          fps_sec     <= 0;
          fps_bcd     <= fps_bcd_run;
          fps_bcd_run <= 0;
        end else begin
          fps_sec <= fps_sec + 4'd1;
        end
      end else begin
        fps_cyc <= fps_cyc + 1'd1;
      end
    end
  end

  // Every row carries its own number in the top byte. Tagging only some rows
  // meant counting bands from an edge that was sometimes out of frame, and two
  // rows got misread that way.
  //
  // THE TAG IS AN IDENTITY, NOT A POSITION. Row order can change between builds;
  // a tag must not, or photographs from different builds cannot be compared. So
  // when two rows were dropped here the remaining tags kept their values and the
  // sequence simply has gaps.
  //
  // EACH ROW IS EXACTLY 32 BITS: an 8-bit tag and 24 bits of payload. Two rows
  // were written 40 bits wide and silently truncated — and Verilog truncation
  // discards the HIGH bits, so what those rows lost was their own tag. They
  // rendered with a wrong row number, which is the one failure this tagging
  // scheme was supposed to make impossible. `make lint_top` now fails on it.
  //
  // TWENTY-FOUR ROWS IS THE CEILING: 384 visible lines at 16 pixels per row.
  wire [31:0] dw [23];
  assign dw[0]  = {8'h00, pc_s2};                  // V60 program counter
  assign dw[1]  = {8'h01, r_if_count[23:0]};       // instruction fetches
  assign dw[2]  = {8'h02, fa[0]};                  // fetch 0 address
  assign dw[3]  = {8'h03, fa[1]};                  // fetch 1  <- reset vector
  assign dw[4]  = {8'h04, fa[2]};                  // fetch 2
  assign dw[5]  = {8'h05, fa[3]};                  // fetch 3
  assign dw[6]  = {8'h06, fa[4]};                  // fetch 4
  assign dw[7]  = {8'h07, fa[5]};                  // fetch 5
  assign dw[8]  = {8'h08, fd[1][23:0]};            // reset vector, low 24
  // Tags 09 and 0A — the data words of fetches 4 and 5 — are GONE, to stay under
  // the 24-row ceiling. They were boot forensics: they proved ROM contents were
  // arriving, which a core that now boots and runs proves better. Their
  // ADDRESSES survive as tags 06 and 07.
  assign dw[9]  = {8'h0B, 2'd0, ldr_overflow, st_s2[17:16],
                   rom_ready, mem_ready, ioctl_download,
                   st_s2[15:0]};                   // flags, I/O replies
  // Fetch deadline misses against the worst layer's fetch count for the last
  // line. If the picture is shifting and tearing, this says whether the
  // renderer is failing or merely running out of scanline.
  assign dw[10] = {8'h0C, dbg_overruns, dbg_fetches};
  assign dw[11] = {8'h0D, 8'h00, fps_bcd};             // frames per 10 s, BCD
  assign dw[12] = {8'h0E, fper};                       // frame period, cycles
  // M2 telemetry, one value per row. A retire count that moves means the
  // coprocessor is executing real microcode; the PC says where it stopped if it
  // did. These two were packed into one row each with a second value and both
  // overflowed 32 bits.
  assign dw[13] = {8'h0F, 7'd0, dbg_tgp_unimpl, dbg_tgp_retires};
  assign dw[14] = {8'h10, 8'd0, dbg_tgp_pc};
  // Visible pixels per tilemap, per frame — ONE PER ROW. A layer with content in
  // tile RAM and a zero here is not reaching the screen, which is checkable
  // without a reference image, and a layer reading near 0x2E800 (496 x 384) is
  // covering the whole picture.
  //
  // One per row because the count needs 18 bits and a row carries 24 after its
  // tag, so two will not fit. They were packed two-up at 16 bits each, which
  // saturated at 65,535 — a third of one screen — and made a full-screen opaque
  // fill indistinguishable from a small window.
  assign dw[15] = {8'h11, 6'd0, dbg_layer_px[0]};
  assign dw[16] = {8'h12, 6'd0, dbg_layer_px[1]};
  assign dw[17] = {8'h13, 6'd0, dbg_layer_px[2]};
  assign dw[18] = {8'h14, 6'd0, dbg_layer_px[3]};
  // The window/split-scroll control register for each pair, as the renderer read
  // it. Bits 14:13 nonzero means a split was requested, and -value gives the
  // scanline it splits at. This says what the GAME asked for, which the census
  // cannot: a layer covering everything could be our window logic misfiring or
  // the game genuinely asking for a full-screen fill.
  assign dw[19] = {8'h15, 8'd0, dbg_ctrl[0]};
  assign dw[20] = {8'h16, 8'd0, dbg_ctrl[1]};
  // FIFO traffic in both directions, which separates "the V60 is not sending
  // work" from "the coprocessor is not taking it" — the two look identical from
  // a screen.
  assign dw[21] = {8'h17, 8'd0, dbg_copro_pushes};
  assign dw[22] = {8'h18, 8'd0, dbg_copro_returns};

  wire [7:0] dg_r, dg_g, dg_b;

  // PACKED BY A LOOP, NOT BY A HAND-WRITTEN CONCATENATION.
  //
  // Word 0 is the LOW 32 bits of the port and the top row of the display, so a
  // literal concatenation has to run bottom row first. That was written out as
  // {dw[14], dw[13], ... dw[0]} to keep the order under control — and when rows
  // 0F to 12 were added, the array and the NWORDS parameter grew while the
  // concatenation did not. Four words of the port were left undriven, reading as
  // zero, so those rows rendered as 00000000 including their own row tags. They
  // looked absent rather than wrong, which sent the diagnosis after the
  // bitstream instead of the wiring.
  //
  // The lint that should have caught it did not. A short pin connection is a
  // WIDTHEXPAND warning, and `make lint_top` — the only lint that sees this file
  // — grepped its log for `%Error` alone and discarded every warning, so it
  // reported clean. That grep now fails on width warnings too.
  //
  // The loop removes the drift rather than relying on that check: NDW sizes the
  // array, the loop bound and the parameter, so adding a row cannot leave the
  // port half-connected. Note the residual risk is silent — a wrong loop bound
  // leaves undriven wires, which lint_top does not report — but there is no
  // second number to keep in step, which is what actually went wrong before.
  localparam int unsigned NDW = 23;
  wire [NDW*32-1:0] dw_packed;
  genvar gi;
  generate
    for (gi = 0; gi < NDW; gi = gi + 1) begin : g_pack
      assign dw_packed[gi*32 +: 32] = dw[gi];
    end
  endgenerate

  generate
  if (DEBUG_OVERLAY) begin : g_diag
  m1_diag #(.NWORDS(NDW)) diag (
    .clk(clk_sys), .ce_pix(ce_pix), .rst_n(mem_rst_n),
    // Off by default: it is an instrument, not a feature, and it sits on top
    // of the picture. Kept in the build because it has now found four faults
    // that nothing else could see, and the next hardware problem will want it.
    .enable(status[3]),
    .hb(vid_hb), .vb(vid_vb),
    .words(dw_packed),
    .in_r(vid_r), .in_g(vid_g), .in_b(vid_b),
    .out_r(dg_r), .out_g(dg_g), .out_b(dg_b)
  );
  end else begin : g_nodiag
    assign dg_r = vid_r;
    assign dg_g = vid_g;
    assign dg_b = vid_b;
  end
  endgenerate

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
