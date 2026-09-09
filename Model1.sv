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
  // UART_TXD IS THE PRINTF CHANNEL, not a tie-off. sys_top wires it to the
  // HPS UART's RECEIVE line, so bytes the core sends arrive on the Linux side
  // as /dev/ttyS0. It was tied to zero and never considered; the core now
  // reports its own game speed there once a second.
  assign {UART_RTS, UART_DTR} = 0;
  assign UART_TXD = core_uart_tx;
  wire core_uart_tx;
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
    "O[10:8],SDRAM read phase,CL+2,CL+3,CL+4,CL+5,CL+1,CL+0;",
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
  // THE GEARBOX IS ON THE D-PAD AS WELL AS ON BUTTONS.
  //
  // Six face buttons against eight controls - two pedals, two gears and four
  // view buttons - leaves two unmapped, and the four VR buttons are what a
  // player actually uses. The d-pad's up and down are free, because steering
  // takes only left and right, and up/down for gears is what a driving game
  // does anyway. Both routes are live: whichever the player has mapped works.
  wire io_shift_up = joy0[6] | joy0[3];   // button, or d-pad up
  wire io_shift_dn = joy0[7] | joy0[2];   // button, or d-pad down
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
  //
  // THE LEFT ANALOGUE STICK STEERS PROPORTIONALLY, and takes priority only
  // when the d-pad is idle - a player holding full lock means it. hps_io
  // delivers the axis as signed, centred at zero, and the wheel wants unsigned
  // centred at 0x80, so the sign bit is inverted rather than the value offset:
  // the same conversion, without an adder that could overflow at the extremes.
  wire [7:0] wheel_stick = {~joy0_lstick[7], joy0_lstick[6:0]};
  wire [7:0] io_wheel = io_steer_l ? 8'h00 :
                        io_steer_r ? 8'hff : wheel_stick;

  // PEDALS ARE ANALOGUE NOW, with the buttons still live.
  //
  // They used to be buttons only, on the reasoning that hps_io's analog ports
  // are two-axis sticks with no travel to read for a pedal. That was wrong in
  // practice: a pad's triggers reach the core through an analog port, and a
  // racing game with on/off pedals is a different game - you cannot hold a
  // line through a corner without partial throttle.
  //
  // TWO SEPARATE AXES, because a pad's triggers are two independent inputs.
  //
  // MiSTer has NO dedicated trigger signal - hps_io offers only the two
  // sticks, the paddles and the spinners, and a trigger reaches a core by the
  // player binding it to a stick AXIS in the OSD. The documented racing
  // convention is left-stick-down for the accelerator and right-stick-right
  // for the brake, so those are the axes to read; binding LT and RT to them
  // is then an ordinary OSD mapping. Sharing one axis, which an earlier
  // version did, cannot work: two triggers need two axes.
  //
  // MAGNITUDE, not sign. A trigger bound to an axis may rest at either end
  // depending on the pad, so any deflection is a press. That makes the left
  // stick's Y unusable for anything else, which costs nothing - only its X
  // steers.
  //
  // Idle is 0x01 and full 0xff, MAME's PORT_MINMAX(1,0xff): a pedal resting
  // at 0x00 is a car that will not move, measured in docs/io-board.md. The
  // buttons stay live and the larger of the two wins.
  wire signed [7:0] accel_ax = joy0_lstick[15:8];   // left stick Y
  wire signed [7:0] brake_ax = joy0_rstick[7:0];    // right stick X
  wire [6:0] accel_mag = accel_ax[7] ? (~accel_ax[6:0] + 7'd1) : accel_ax[6:0];
  wire [6:0] brake_mag = brake_ax[7] ? (~brake_ax[6:0] + 7'd1) : brake_ax[6:0];
  wire [7:0] accel_an  = {accel_mag, 1'b1};
  wire [7:0] brake_an  = {brake_mag, 1'b1};
  wire [7:0] io_accel = io_accel_b ? 8'hff :
                        (accel_an > 8'h01) ? accel_an : 8'h01;
  wire [7:0] io_brake = io_brake_b ? 8'hff :
                        (brake_an > 8'h01) ? brake_an : 8'h01;

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
  wire clk_sys, clk_cpu, clk_sdram, pll_locked;

  // The 3D layer's clock: 57.143 MHz, exactly twice clk_cpu.
  //
  // A separate domain for the geometry and rasterizer, at exactly 2x clk_cpu so
  // the crossing to the CPU side is a clock enable rather than a handshake.
  //
  // 57.143 rather than clk_sys's 80 because the TGP's state machine misses at
  // m1_raster_fill 58.84 - 80 does not close. It was 47.059 until m1_fp_pool's
  // operand mux was registered, which took m1_geometry from 39.6 to 54.57.
  // See docs/findings.md.
  wire clk_3d;

  pll pll (
    .refclk   (CLK_50M),
    .rst      (1'b0),
    .outclk_0 (clk_sys),
    .outclk_1 (clk_cpu),
    .outclk_2 (clk_sdram),
    .outclk_3 (clk_3d),
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

  // ONE character port, and it is the RIGHT number. The tile engine pays a
  // round trip once per column, 248 times a line, and the way that was fixed
  // was to make the trip shorter rather than to add a second path for it:
  // port 1 bursts TWO words now, which is exactly what `char_data` reads, so
  // it no longer fetches and waits for two words that get discarded. Confirmed
  // on hardware 2026-09-07 at 46b9e2c, tile overruns massively reduced.
  //
  // TWO attempts to add a path were reverted first, both breaking the 2D on
  // hardware while every bench stayed green: a second SDRAM port (2026-09-05,
  // yellow rectangle, no sky or ground) and a next-scanline cache built from
  // the discarded half of each burst (2026-09-07, alternate scanlines gone).
  // The cache and the fix rest on the SAME observation about the wasted half;
  // one tried to use it, the other stopped producing it. See
  // docs/findings.md before adding a path here again - the benches did not
  // distinguish the two that broke the board from the one that worked.
  wire        char_req, char_ack;
  wire [17:0] char_addr;
  wire [31:0] char_data;

  wire        ldr_wr_req, ldr_wr_ack;
  wire [24:1] ldr_wr_addr;
  wire [15:0] ldr_wr_din;
  wire  [1:0] ldr_wr_be;

  // SEVEN PORTS. p4 is the I/O board Z80's firmware fetch - its 16 KB of code is
  // read-only and there is no block RAM left for it, see m1_ioz80.
  //
  // An eighth was added on 2026-09-05 for a second character fetch and reverted
  // when it broke the 2D. That revert MISSED THIS FILE - it was not in the
  // revert commit - so several flashed builds carried a dead p7 whose requester
  // no longer existed. It was harmless only by luck: the width truncation
  // happened to select p_dout[1][31:0] and p_ack[1], which is what the single
  // port wanted anyway. It still cost arbiter and mux area in every build.
  wire [6:0]       p_req, p_we, p_ack;
  wire [6:0][24:1] p_addr;
  wire [6:0][15:0] p_din;
  wire [6:0][1:0]  p_be;
  wire [6:0][63:0] p_dout;

  // The I/O board Z80's firmware fetch, from m1_integrated. IOFW_BASE in
  // m1_rom_loader is where the loader put it, and the two must agree - a
  // mismatch is a Z80 executing whatever else is at that address.
  localparam logic [24:1] IOFW_BASE = 24'hD00000;
  wire        iofw_req;
  wire [13:0] iofw_word;

  // The 3D layer's two masters, from m1_integrated in the clk_sys domain.
  wire        r3d_rom_req, r3d_tex_req, r3d_tex_we;
  wire [24:1] r3d_rom_addr, r3d_tex_addr;
  wire [15:0] r3d_tex_din;

  // Port map per docs/00-decisions.md D8: p0 CPU data, p1 character RAM,
  // p2 instruction fetch. p3 and p4 are sound, unbuilt.
  // The read-back sweep lives in m1_integrated now, so tb_m1_frame can verify
  // it against the SDRAM model. Port 4 was tied off; it carries the sweep.
  // p5 bursts the polygon models, p6 carries tgp_ram and is the only port
  // besides p0 that writes - display-list command 4 uploads colour words.
  // PORT 4 IS THE I/O BOARD'S NOW, not the read-back sweep's. See DEBUG_OVERLAY.
  assign p_req  = {r3d_tex_req, r3d_rom_req, iofw_req, tgp_mem_req, ifp_req, char_req, sdr_req};
  assign p_we   = {r3d_tex_we,  1'b0,        1'b0,     1'b0,        1'b0,    1'b0,     sdr_we};
  // Character RAM lives at CHAR_BASE in SDRAM, exactly where m1_main maps the
// CPU's writes to 0x780000-0x7fffff. The renderer emits an offset within that
// region, so the base has to be added here — without it the tilemap fetches
// from word 0, which is V60 program ROM, and every glyph decodes from the same
// wrong data. 31 distinct tile numbers then render identically and the screen
// is a uniform pattern that looks like a video bug rather than an address one.
// p3 is passed WHOLE now. It used to be aligned down to a 4-word boundary so
// m1_integrated could pick a half with bit 1, which meant every coprocessor
// fetch pulled four words to use two. It bursts 2 and lands on exactly the
// 32-bit word asked for, so there is no half to pick.
// p5's address is aligned DOWN to its 4-word burst boundary here. It does NOT
// pick a half - m1_integrated takes the full 64 bits of r3d_rom_dout - and a
// note here previously said it did, which was wrong.
assign p_addr = {r3d_tex_addr, {r3d_rom_addr[24:2], 1'b0},
                 IOFW_BASE + {10'd0, iofw_word},
                 tgp_mem_addr, ifp_addr,
                 24'hFA8000 + {6'd0, char_addr}, sdr_addr};
  assign p_din  = {r3d_tex_din, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0, sdr_din};
  assign p_be   = {2'b11,       2'd0,  2'd0,  2'd0,  2'd0,  2'd0,  sdr_be};

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
  wire [7:0] sdram_occ, sdram_wait1;

  m1_sdram #(.T_REFI(600)) sdram (
    .clk(clk_sys), .rst_n(mem_rst_n), .ready(mem_ready),
    // OSD POSITION IS NOT CL+n. m1_sdram's own encoding is CL+n now, but the
    // OSD list cannot be, because position 0 is what an all-zero status gives
    // and that is what a fresh config, a cleared config and a reset all
    // produce. CL+2 is the only depth this board is known to capture at, so it
    // has to stay at position 0 -- booting a default config into a depth that
    // does not work would present as a dead core, not as a wrong option.
    //
    // Positions 0-3 therefore keep exactly the meaning they have always had,
    // so a saved config still selects what it used to. The two SHALLOWER
    // depths are appended after them, because they are the ones that have
    // never been reachable: CL+2 was the floor of the old selector, so whether
    // the capture window continues below it has never been observable.
    .rd_lat_sel(status[10:8] == 3'd0 ? 3'd2 :   // CL+2 - the board's default
                status[10:8] == 3'd1 ? 3'd3 :
                status[10:8] == 3'd2 ? 3'd4 :
                status[10:8] == 3'd3 ? 3'd5 :
                status[10:8] == 3'd4 ? 3'd1 :   // CL+1 - new, below the floor
                                       3'd0),   // CL+0 - new, below the floor
    .sd_cke(SDRAM_CKE), .sd_cs_n(SDRAM_nCS), .sd_ras_n(SDRAM_nRAS),
    .sd_cas_n(SDRAM_nCAS), .sd_we_n(SDRAM_nWE), .sd_ba(SDRAM_BA),
    .sd_a(SDRAM_A), .sd_dqm({SDRAM_DQMH, SDRAM_DQML}),
    .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(SDRAM_DQ),
    .wr_req(ldr_wr_req), .wr_addr(ldr_wr_addr), .wr_din(ldr_wr_din),
    .wr_be(ldr_wr_be), .wr_ack(ldr_wr_ack),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack),
    .dbg_req(), .dbg_grant(),
    // The memory's own account of how busy it is, and of how long the tile
    // fetch waits for it. Both go to the UART, because whether the SDRAM is
    // the constraint is a hardware question.
    .dbg_occ(sdram_occ), .dbg_wait1(sdram_wait1)
  );

  assign SDRAM_DQ  = sd_dq_oe ? sd_dq_o : 16'bZ;
  // SDRAM_CLK COMES FROM THE PLL NOW, NOT FROM FABRIC.
  //
  // It was `~clk_sys` assigned to the pin - a fixed 180-degree inversion routed
  // through fabric, with no phase to adjust. The established MiSTer recipe for
  // constraining an SDRAM interface sources the generated clock from a PLL
  // OUTPUT, because the documented fix when the I/O timing fails is to shift
  // that clock's phase, "typically ranging between -0.5 ns and -2.5 ns"
  // (retroramblings.net/?p=515). Our design had no such knob: rd_lat_sel picks a
  // capture depth in WHOLE CYCLES, which is a coarse substitute for a
  // sub-nanosecond phase.
  //
  // outclk_2 starts at 6250 ps, exactly half of the 12500 ps period, so this is
  // bit-identical to the inversion it replaces. Tuning it is then one parameter
  // in rtl/pll/pll_0002.v rather than a redesign.
  assign SDRAM_CLK = clk_sdram;

  // ------------------------------------------------------------------- core
  wire [7:0] vid_r, vid_g, vid_b;
  wire       vid_hs, vid_vs, vid_hb, vid_vb;
  wire [23:0] dbg_pc;
  wire        dbg_halted, dbg_fp_trap, ldr_overflow;
  wire [15:0] dbg_copro_pushes, dbg_copro_returns;
  wire [17:0] dbg_layer_px [4];
  wire [15:0] dbg_ctrl [2];
  wire [11:0] dbg_layer_have [4];
  wire [11:0] dbg_tram_writes [4];
  wire [11:0] dbg_tm0_writes, dbg_mask_writes;
  wire [23:0] dbg_ucode_ram_csum;
  wire        dbg_ucode_ram_ok;
  wire [11:0] dbg_tgp_ram_writes;
  wire [11:0] dbg_tm0_text_writes;
  wire [11:0] dbg_mask_nz_writes;
  wire [23:0] dbg_tm0_first_pc;
  wire [15:0] dbg_sync_word;
  wire [23:0] dbg_copro_rd_csum;
  wire [23:0] dbg_rd_a0, dbg_rd_a1, dbg_rd_a2, dbg_rd_a3;
  wire        rb_req;
  wire [24:1] rb_addr;
  wire [23:0] dbg_rb_csum, dbg_rb_csum0;
  wire [12:0] dbg_rb_n;
  wire [11:0] dbg_ucode_words;
  wire [15:0] dbg_copro_pops;
  wire [15:0] dbg_copro_drains;
  wire [15:0] dbg_ucode_csum;
  wire [23:0] dbg_sdram_csum, dbg_sdram_words;
  wire        tgp_mem_req;
  wire [24:1] tgp_mem_addr;
  wire [15:0] dbg_tgp_retires, dbg_tgp_pc;
  wire        dbg_tgp_unimpl;
  wire  [7:0] dbg_fetches;
  wire [15:0] dbg_overruns;
  wire [15:0] dbg_io_replies;

  m1_integrated core (
    .sdram_occ(sdram_occ), .sdram_wait1(sdram_wait1),
    .clk_sys(clk_sys), .ce_pix(ce_pix),
    .clk_cpu(clk_cpu), .ce_cpu(1'b1),
    .clk_3d(clk_3d),
    .rst_n(rst_n), .mem_rst_n(mem_rst_n), .mem_ready(mem_ready),
    .in_bytes(io_in_bytes),

    // The 3D layer's SDRAM masters: p5 for the polygon models, p6 for tgp_ram.
    .r3d_rom_req(r3d_rom_req), .r3d_rom_addr(r3d_rom_addr),
    .r3d_rom_dout(p_dout[5]), .r3d_rom_ack(p_ack[5]),
    .r3d_tex_req(r3d_tex_req), .r3d_tex_we(r3d_tex_we),
    .r3d_tex_addr(r3d_tex_addr), .r3d_tex_din(r3d_tex_din),
    .r3d_tex_dout(p_dout[6][15:0]), .r3d_tex_ack(p_ack[6]),

    .sdr_req(sdr_req), .sdr_we(sdr_we), .sdr_addr(sdr_addr),
    .sdr_din(sdr_din), .sdr_be(sdr_be),
    .sdr_dout(p_dout[0][15:0]), .sdr_ack(sdr_ack),

    .if_req(ifp_req), .if_addr(), .if_sdram_addr(ifp_addr),
    .if_data(p_dout[2]), .if_ack(p_ack[2]),

    // The I/O board Z80's firmware fetch, on port 7.
    .iofw_req(iofw_req), .iofw_word(iofw_word),
    .iofw_ack(p_ack[4]), .iofw_din(p_dout[4][15:0]),

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
    .dbg_layer_px(dbg_layer_px), .uart_tx(core_uart_tx), .dbg_ctrl(dbg_ctrl),
    .dbg_layer_have(dbg_layer_have),
    .dbg_tram_writes(dbg_tram_writes),
    .dbg_ucode_ram_csum(dbg_ucode_ram_csum), .dbg_ucode_ram_ok(dbg_ucode_ram_ok),
    .dbg_tgp_ram_writes(dbg_tgp_ram_writes), .dbg_sync_word(dbg_sync_word),
    .dbg_tm0_writes(dbg_tm0_writes), .dbg_mask_writes(dbg_mask_writes),
    .dbg_tm0_text_writes(dbg_tm0_text_writes), .dbg_tm0_first_pc(dbg_tm0_first_pc),
    .dbg_mask_nz_writes(dbg_mask_nz_writes),
    .dbg_copro_rd_csum(dbg_copro_rd_csum),
    .dbg_rd_a0(dbg_rd_a0), .dbg_rd_a1(dbg_rd_a1),
    .dbg_rd_a2(dbg_rd_a2), .dbg_rd_a3(dbg_rd_a3),
    // The read-back sweep has no port now; it fed the overlay's row 4 only.
    .rb_req(rb_req), .rb_addr(rb_addr), .rb_dout(64'd0), .rb_ack(1'b0),
    .dbg_rb_csum(dbg_rb_csum), .dbg_rb_csum0(dbg_rb_csum0), .dbg_rb_n(dbg_rb_n),
    .dbg_ucode_words(dbg_ucode_words), .dbg_ucode_csum(dbg_ucode_csum),
    .dbg_sdram_csum(dbg_sdram_csum), .dbg_sdram_words(dbg_sdram_words),
    .dbg_copro_pops(dbg_copro_pops),
    .dbg_copro_drains(dbg_copro_drains)
  );

  // -------------------------------------------------------------- diagnostics
  //
  // DEBUG_OVERLAY=0 removes the whole instrument — the renderer, the capture
  // registers, the fetch trace and the frame-rate counters — so its cost can be
  // measured by building both ways rather than estimated, and so a release
  // build can drop it. See docs/debug-overlay.md for the measurement and for
  // what every row means.
  //
  // OFF, 2026-09-04. The UART telemetry replaced it: twenty-four rows cannot
  // show a SEQUENCE, and every defect since the 3D work started has been about
  // sequence - which band went up when, how long a pass took, what the Z80
  // fetched. It found four faults nothing else could see and the parameter
  // keeps it one character away, but it is not worth its area now.
  //
  // Turning it off also frees SDRAM PORT 4. The read-back sweep exists only to
  // feed row 4 of this overlay, and a port is 140 ALM measured (the controller
  // is 1,067 at seven ports and 1,207 at eight). So the Z80 I/O board takes
  // that port instead of an eighth being added - Ben's observation, and the
  // reason the board now costs no port growth at all.
  localparam bit DEBUG_OVERLAY = 0;

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

  // ------------------------------------------------- where the CPU actually is
  //
  // Row 00 samples the PC once a frame at the same point, so it reads ffe59c
  // whatever is happening and cannot distinguish a tight loop from a frame
  // -synchronised wait. These answer the two questions it cannot.
  //
  // THE TEARDOWN EDGE. The screen rebuilds every 0.45 s on hardware and never
  // after boot in simulation. ctrl for pair 2/3 drops 0x2000 -> 0x0000 at exactly
  // that moment, so latching the PC there names the code doing it — traceable in
  // the ROM, unlike a value sampled at an unrelated instant.
  reg [23:0] pc_at_teardown;
  reg [23:0] teardown_count;
  reg        ctrl1_was_set;
  always @(posedge clk_sys) begin
    if (!rst_n) begin
      pc_at_teardown <= '0; teardown_count <= '0; ctrl1_was_set <= 1'b0;
    end else begin
      ctrl1_was_set <= (dbg_ctrl[1][14:13] != 2'b00);
      if (ctrl1_was_set && (dbg_ctrl[1][14:13] == 2'b00)) begin
        pc_at_teardown <= pc_s2;
        teardown_count <= teardown_count + 24'd1;
      end
    end
  end

  // A COARSE PC HISTOGRAM, two buckets, both WRAPPING so their rates can be
  // compared by watching the digits move. Saturating counters cannot express
  // "still going", which is the failure mode of three instruments today.
  //
  // ROM0 is the boot vector region the V60 maps at 0xf80000-0xffffff. Everything
  // else — ROMX at 0x2xxxxx, the banked window at 0x1xxxxx, and RAM — is the
  // game proper. If the board sits almost entirely in ROM0 it is looping in boot;
  // if it is spread, it is running code simulation never reaches and "stuck in
  // boot" is the wrong reading.
  reg [23:0] cyc_rom0, cyc_other;
  wire       in_rom0 = (pc_s2[23:19] == 5'b11111);   // 0xf80000-0xffffff
  always @(posedge clk_sys) begin
    if (!rst_n) begin
      cyc_rom0 <= '0; cyc_other <= '0;
    end else if (in_rom0) cyc_rom0  <= cyc_rom0  + 24'd1;
    else                  cyc_other <= cyc_other + 24'd1;
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
  //
  // NDW sizes this array, the packing loop and m1_diag's parameter, so there is
  // exactly one number to change when a row is added. It was declared beside the
  // loop and the array kept its own literal 23 — adding row 1B then wrote past
  // the end of the array, which is the same class of drift the packing loop was
  // introduced to stop and cost a second lint run to find.
  localparam int unsigned NDW = 24;
  wire [31:0] dw [NDW];
  assign dw[0]  = {8'h00, pc_s2};                  // V60 program counter
  assign dw[1]  = {8'h01, r_if_count[23:0]};       // instruction fetches
  // ROWS 02 AND 03 WERE BOOT FETCH ADDRESSES 0 AND 1. They found the SDRAM
  // off-by-one and have shown the same two constants ever since; these two
  // questions are live and unanswered, which is a better use of the space.
  //
  // 02: DID THE MICROCODE ARRIVE? Words loaded (left 12 bits) and a checksum of
  // both halves of every word (right 16). 800 and a non-zero checksum is a
  // complete, correct load of 2048 words; 000 means the HPS never delivered
  // index 1 and the coprocessor has been executing an empty RAM. Nothing
  // measured this before, and its absence cost a full round of diagnosis — the
  // RTL path is wired and the MRA element is well formed, so "it loads" had been
  // inferred from the code existing. The board cannot be asked: MiSTer does not
  // log ROM assembly and /media/fat is noatime, so the read leaves no trace.
  // The checksum is folded to 12 bits rather than truncated, so all sixteen bits
  // of it contribute — a truncation would ignore a difference confined to the top
  // nibble, which is exactly the sort of near-miss a wrong 8 KB would produce.
  assign dw[2]  = {8'h02, dbg_ucode_words,
                   dbg_ucode_csum[11:0] ^ {8'd0, dbg_ucode_csum[15:12]}};
  // 03: IS THE COPROCESSOR DRAINING ITS COMMAND FIFO? Pushes (left) against
  // pops (right), 12 bits each, saturating. The retired rows 17/18 showed pushes
  // at FFFF and returns a constant 0, which has two very different causes: the
  // TGP not taking the work, or taking it and returning nothing. A full FIFO
  // HALTS THE V60 — depth 16, measured — so the first would stall the CPU
  // periodically, which is the shape of the 0.45 s teardown on the board.
  assign dw[3]  = {8'h03, dbg_copro_pushes[11:0], dbg_copro_drains[11:0]};
  // ROWS 04-07 WERE BOOT FETCH ADDRESSES 2 TO 5. They were captured once at boot
  // and have read the same four constants ever since. The four questions below
  // are the ones the board cannot currently answer.
  // ROW 04 WAS pc_at_teardown. Replaced with how many read-back bursts actually
  // completed, because without it a checksum cannot be told from a SWEEP THAT
  // STALLED. Simulation stalled at exactly one burst of 4096 when the sweep was
  // clocked in the wrong domain, and produced a plausible-looking number while
  // doing it.
  //   1000 (hex) = 4096 = the sweep finished and row 0C means something
  assign dw[4]  = {8'h04, 11'd0, dbg_rb_n};
  // ROW 05 WAS teardown_count, a boot forensic that has read the same value for
  // weeks. Replaced with the measurement the board is actually missing:
  // cumulative writes into tilemap 0 (left) and into the row mask at 0x6000
  // (right), neither ever cleared. The text is written once during init, so the
  // per-frame counters in row 1B read zero whether it worked or not.
  //   left ~FFF, right > 0   the CPU wrote the text and the mask; look at video
  //   left 000               the init never ran, and the fault is upstream
  // Right half is now NON-ZERO mask writes: an all-zero row mask hides every
  // category-1 tile, which is all of the text, while category-0 sky and sea
  // render normally - exactly what the board shows.
  assign dw[5]  = {8'h05, dbg_tm0_writes, dbg_mask_nz_writes};
  // ROW 06 WAS cyc_rom0. Replaced with a checksum of every word the coprocessor
  // reads from SDRAM - the math tables and the data window - so it can be
  // compared against the identical fold printed by tb_m1_frame. Equal means the
  // reads are good and the fault is logic; different means the SDRAM interface
  // is not delivering, which is the one block this core has never constrained.
  assign dw[6]  = {8'h06, dbg_copro_rd_csum};
  // ROWS 07 AND 0B: THE WRITE SIDE OF SDRAM.
  //   07  a fold of every word the loader handed to SDRAM
  //   0B  how many words that was
  // tools/rom_csum.py folds the packed image the same way. A match means the HPS
  // delivered the right bytes in the right order, and the coprocessor's bad
  // reads are a READ-side fault; a mismatch means the data never arrived and no
  // amount of capture-phase tuning will help.
  assign dw[7]  = {8'h07, dbg_rd_a1};   // coprocessor read #64
  assign dw[8]  = {8'h08, fd[1][23:0]};            // reset vector, low 24
  // Tags 09 and 0A — the data words of fetches 4 and 5 — are GONE, to stay under
  // the 24-row ceiling. They were boot forensics: they proved ROM contents were
  // arriving, which a core that now boots and runs proves better. Their
  // ADDRESSES survive as tags 06 and 07.
  assign dw[9]  = {8'h0B, dbg_rd_a2};   // coprocessor read #256
  // Fetch deadline misses against the worst layer's fetch count for the last
  // line. If the picture is shifting and tearing, this says whether the
  // renderer is failing or merely running out of scanline.
  // ROW 0C WAS overruns/fetches, which has read 000001 throughout. Replaced with
  // the read-back checksum: what SDRAM returns for the math-table region, swept
  // sequentially on the spare port. tools/rom_csum.py --region prints the same
  // fold of the bytes on disk.
  // SDRAM IS VERIFIED - row 0E read 4D2E75 against an image folding to 4D2E75,
  // 1,081,344 words across all 8.6 M - so these two rows are free for the
  // question that is actually open: the board's tilemap 0 holds 4,096 words and
  // the renderer finds eight non-blank, so the CPU clears the screen and never
  // draws.
  //   0C  PC of the FIRST real character written into tilemap 0, 0 if none
  //   0E  how many real characters were written at all
  // ROW 0C: THE PROGRAM RAM READ BACK. Row 02 folds the loader's ioctl INPUT,
  // before the write, so it cannot see a word that failed to land. This is the
  // same fold taken from the array itself - tools/rom_csum.py --ucode prints the
  // expected value from vr_tgp_prog.hex.
  assign dw[10] = {8'h0C, dbg_ucode_ram_csum};
  // ROW 0D WAS the frame rate, which has read 57.5 Hz correctly for weeks.
  // Replaced with the FED5A4 deadlock's two facts: how many times the
  // COPROCESSOR has written coprocessor RAM (left) and the current value of the
  // sync word the V60 is spinning on (right).
  //   left 000, right ffff   the coprocessor never gets far enough to signal
  //   left > 0               it writes, and the fault is elsewhere
  assign dw[11] = {8'h0D, dbg_tgp_ram_writes, dbg_sync_word[11:0]};
  // ROW 0E WAS the frame period. Replaced with the CONTROL sweep: the same
  // read-back over V60 program ROM at word 0, a region the CPU demonstrably
  // reads correctly every frame. Row 0C is the math tables at 0x400000.
  //   0E right, 0C wrong  the fault is specific to the high region
  //   both wrong          the read path or the sweep itself is at fault
  assign dw[12] = {8'h0E, dbg_rd_a0};   // coprocessor read #0
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
  // CONTENT per tilemap, two per row, against the WINS in rows 11-14.
  //
  //   have 0,   won 0     the layer holds nothing; the fault is upstream
  //   have > 0, won 0     content is there and not reaching the screen
  //
  // Rows 17 and 18 held the coprocessor's FIFO pushes and returns and were
  // dropped for these: pushes read a saturated FFFF and returns a constant 0, and
  // will keep doing so until there is a rasterizer for the TGP to feed, whereas
  // this pair is the one measurement the board is missing. Twenty-four rows is the
  // ceiling — 384 visible lines at 16 pixels a row — so something had to go.
  assign dw[21] = {8'h19, dbg_layer_have[0], dbg_layer_have[1]};
  assign dw[22] = {8'h1A, dbg_layer_have[2], dbg_layer_have[3]};
  // CPU WRITES into tile RAM per frame: the tilemaps on the left, the scroll
  // and H-scroll registers at word 0x4000-0x5fff on the right.
  //
  // The right field is deliberately NOT the other pair of tilemaps. Simulation
  // measured the game loop writing **no** tilemap words at all — `wr=0,0,12,0`
  // at frame 92 — while writing 12 to 24 scroll words every frame. So a row
  // showing both tilemap regions reads `000 000` in a working design, which is
  // indistinguishable from a counter that does not work. The scroll region is
  // the liveness control, and it is the only region the game loop touches.
  //
  //   left 0, right ~00C-018   matches simulation. The game loop never rewrites
  //                            the tilemaps, so the content came from init and
  //                            the divergence is there, not in the loop
  //   left 0, right 0          the CPU is not writing tile RAM at all. It is
  //                            further from the reference than anything measured
  //                            so far, and that is the bug
  //   left > 0                 the loop does rewrite the maps and they still
  //                            read blank — then the memory is implicated
  //
  // Rows 1B is the last one available: 24 rows at 16 pixels is 384 lines, the
  // whole visible field.
  assign dw[23] = {8'h1B, dbg_rd_a3};   // coprocessor read #512

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
