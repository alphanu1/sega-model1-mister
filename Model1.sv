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
  // BOTH IDLE HIGH, so a wired-AND shares the line. UART_REPORT is 0 (M10K is
  // full), which ties core_uart_tx to 1, so only the sound monitor transmits.
  // If the speed report is ever turned back on, only one of the two may be
  // enabled at a time.
  assign UART_TXD = core_uart_tx;
  wire core_uart_tx;
  assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
  // DDR3 carries the 3D layer's quad payload (m1_raster3d, PAY_DDR3), driven
  // from m1_integrated below.

  assign VGA_SL       = 0;
  assign VGA_SCALER   = 0;
  assign VGA_DISABLE  = 0;
  assign HDMI_FREEZE  = 0;
  assign HDMI_BLACKOUT = 0;
  assign HDMI_BOB_DEINT = 0;

  // No sound yet: the 68000, YM3438 and two MultiPCMs are M4.
  // SIGNED, because the sound board's mixer produces signed samples and
  // AUDIO_S tells the framework how to read them. Tying it to 0 with signed
  // data would fold the negative half of every waveform to the top of the
  // range - loud, and wrong in a way that sounds like a broken DAC.
  assign AUDIO_S   = 1;
  // ---------------------------------------------------------------- VOLUME
  //
  // UNITY. NO GAIN. MEASURED AGAINST MAME, 2026-09-14, and this reverses an
  // earlier x16 that was actively making the sound worse.
  //
  // MAME's own output for vr over 75 seconds, in five-second windows:
  //
  //     0-35 s   peak   ~100   zero-x ~125 Hz    idle
  //    35-40 s   peak 16,330   zero-x  395 Hz    the attract audio
  //    40-65 s   peak   ~100                     idle
  //    65-70 s   peak 16,322                     the next burst
  //
  // THE REFERENCE IS NEARLY SILENT FOR THIRTY-FIVE SECONDS AT A TIME, and it
  // produces the same low-level ~125 Hz drone we do while it waits. The real
  // audio is -6 dBFS and needs nothing added.
  //
  // The x16 came from measuring -54 dBFS on the board and sizing a gain to it.
  // That reading was taken during the IDLE window: it amplified the drone to
  // audibility -- the "constant rumble" -- and saturated the 16,330 peaks into
  // clipping, which is the "static". Both symptoms were manufactured by the
  // gain, not revealed by it.
  //
  // If the board ever measures genuinely quiet DURING a burst, size a gain
  // against THAT window and not against silence.
  // Star Wars' Digital Sound Board is summed in, as MAME sums its "mpeg"
  // speaker with the sound board's. Zero for every other game.
  wire signed [15:0] mix_l, mix_r;
  assign AUDIO_L = mix_l;
  assign AUDIO_R = mix_r;
  assign AUDIO_MIX = 0;

  // (The DISK bit stays: snd_ready is cheap and worth seeing.)
  // TWO FREE DIAGNOSTIC BITS, because the UART is compiled out to make the
  // design fit and the sound board is silent for a reason simulation cannot
  // reproduce. b[1]=1 takes sole control of the LED; b[0] is the value.
  //
  // The sound board boots correctly in `make test_m1_sndboard` against the real
  // ROM -- 1.25 M instructions, MAME's own main loop at PC 0x1100, both
  // MultiPCMs driven, and it survives SDRAM latency from 12 to 100 cycles. So
  // the board is right and the fault is in the integration. These two bits ask
  // the only questions left that the board can answer:
  //
  //   DISK  solid  = snd_ready asserted, so the 68000 was released at all
  //   POWER blinks = the 68000 is writing the MultiPCMs, so it is ALIVE
  //
  // Off/off means the sound stream never completed. Solid/dark means it was
  // released and then died. Both lit means it is running and the fault is
  // downstream, in the mix or the audio output.
  assign LED_DISK  = {1'b1, snd_ready};
  // THE V60'S COMMANDS, which is the FIRST question in the chain and the one
  // no reading so far has answered. LED_POWER was tied to ZERO here, so the
  // "power on" seen on the board was the framework's own default LED and said
  // nothing about our design -- it was read as "sample data arrived", which it
  // never meant.
  assign LED_POWER = {1'b1, v60_cmd_seen};
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
    "O[6],Test switch,Off,On;",
    "O[7],Service switch,Off,On;",
    "O[11],Pedals,Up=Accel,Up=Brake;",
    "O[15:14],Analog control,Standard,Wheel A,Wheel B;",
    "-;",
    // 15 kHz, as the Model 2 core has it (its study R898, R939): the native
    // 24 kHz picture through a scan converter to 15 kHz interlaced, 240 lines
    // a field. A [15kHz CRT] MRA sets bit 7 of the game id and the option then
    // shows as fixed, so a CRT is never handed 24 kHz by a saved setting.
    "H0O[16],Video,Native 24kHz,15kHz interlaced;",
    "h0O[16],Video,15kHz (CRT MRA),15kHz (CRT MRA);",
    "O[18:17],15kHz lines,273/274 (15.7kHz),268/269 (15.4kHz),262/263 (15.1kHz);",
    "O[19],15kHz pairing,Auto,Off;",
    "O[20],Star Wars music volume,Firmware,MAME;",
    "O[12],Stick Y axis,Normal,Inverted;",
    "O[13],Stick X axis,Normal,Inverted;",
    "O[22:21],NetMerc head look,Left stick,Left stick Y inv,Off;",
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
  wire [15:0] joy1_lstick;   // pad 2, the gunner seat
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
  // Two players, for the fighters. joy[0] right, [1] left, [2] down, [3] up,
  // buttons from [4] - the same order the VR decode above relies on.
  wire p1_right = joy0[0], p1_left = joy0[1], p1_down = joy0[2], p1_up = joy0[3];
  wire p1_b1    = joy0[4], p1_b2   = joy0[5], p1_b3   = joy0[6];
  wire p2_right = joy1[0], p2_left = joy1[1], p2_down = joy1[2], p2_up = joy1[3];
  wire p2_b1    = joy1[4], p2_b2   = joy1[5], p2_b3   = joy1[6];
  wire io_start2   = joy1[12];

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
  // WHICH GAME IS LOADED, from the MRA.
  //
  // Six titles share one bitstream and they do not agree about the input map,
  // so the core has to be told. The MRA carries a literal byte on its own
  // download index - the same mechanism every multi-game MiSTer core uses -
  // and it arrives once, before the ROM.
  //
  //   0  Virtua Racing (and Virtua Formula: the same cabinet)
  //   1  Virtua Fighter
  //   2  Star Wars Arcade
  //   3  Wing War
  //   4  Sega NetMerc
  //
  // Held through an OSD reset and cleared only at power-on: the byte arrives
  // before the ROM and must not be lost when the game side is reset. An MRA
  // with no such element leaves this at 0, which is Virtua Racing - the
  // behaviour every existing MRA had before this existed.
  // Declared here because the input map below needs it; DRIVEN further down,
  // after the ioctl wires exist. Verilator accepts a reference above the
  // declaration and Quartus does not, which has already cost this project a
  // build once.
  localparam [15:0] GAMEID_INDEX = 16'd4;
  logic [7:0] game_id;
  // BIT 7 IS NOT THE GAME. A [15kHz CRT] MRA sends the same id with bit 7 set
  // (the Model 2 core's convention, its study R795), so every game test reads
  // bits 6:0 and bit 7 alone says "this is a CRT".
  wire [6:0] game = game_id[6:0];
  wire crt_mra = game_id[7];
  wire is_vf = (game == 7'd1);
  wire is_swa = (game == 7'd2);
  wire is_ww  = (game == 7'd3);
  wire is_nm  = (game == 7'd4);

  // ROMA MIRRORING, per game.
  //
  // MAME maps 0x000000-0x0fffff as .rom() for every Model 1 game, and four of
  // the six populate it by mirroring the boot ROM in with ROM_RELOAD:
  //
  //   vr, vformula, vf   no reload           -> void
  //   swa, swaj          512 KB at 0xf80000, reloaded to 0x000000 AND 0x080000
  //   netmerc            512 KB at 0xf80000, reloaded to 0x000000
  //   wingwar            128 KB at 0xfc0000 -> 0x000000
  //                      128 KB at 0xfe0000 -> 0x020000
  //
  // So wingwar's mirror begins 256 KB into the packed boot region and the rest
  // begin at its base; hence two modes rather than one flag.
  //
  // STAR WARS ARCADE COULD NOT BOOT WITHOUT THIS. Its reset vector at 0xfffff0
  // is a jump to 0x000fff00 -- into ROMA -- so with the region decoded as void
  // the V60 fetched erased space and sat on `reserved opcode 03` at PC 4
  // forever. Virtua Racing jumps into its own boot ROM instead, which is why
  // the gap survived this long.
  logic [1:0] roma_mode;
  always_comb begin
    case (game)
      7'd2:    roma_mode = 2'd1;   // Star Wars Arcade
      7'd3:    roma_mode = 2'd2;   // Wing War
      7'd4:    roma_mode = 2'd1;   // NetMerc
      default: roma_mode = 2'd0;   // Virtua Racing / Formula, Virtua Fighter
    endcase
  end

  // WHICH I/O BOARD. Wing War does not use the board the other games do:
  // model1.cpp's wingwar() replaces it with SEGA_MODEL1IO2 running EPR-16891,
  // a TMPZ84C015 with a different map whose firmware is driven by a CTC timer
  // interrupt. On EPR-14869 the game's V60 never gets its handshake answered
  // and sits in boot -- the grey screen the board showed. The MRA loads
  // EPR-16891 on index 2 for Wing War; this tells m1_ioz80 to be that board.
  //
  // NetMerc is a model1io2 game too (EPR-18021) but its MRA still sends
  // EPR-14869 and it boots on it, so it stays on the first board until its own
  // firmware has been run here.
  wire io_board2 = (game == 7'd3);

  // NetMerc reads its camera's orientation from a head tracker that MiSTer
  // does not have. The LEFT STICK stands in for the player's head: m1_main's
  // m1_hmd_pose writes the pose, forward when the stick is released, turned
  // up to +-90 degrees of yaw and +-45 of pitch at full deflection (that
  // module carries the format, measured in MAME). The gun moves to the right
  // stick (nm_stick_* below).
  //
  // O[22:21] "NetMerc head look": 0 Left stick, 1 Left stick with Y inverted
  // (push up to look down, as a flight game has it), 2 Off - the pose fixed
  // forward and both sticks aiming the gun, which is what this core did
  // before, for a pad with one stick. The OSD cannot select 3; it reads as Off.
  wire       hmd_pose = (game == 7'd4);
  wire [1:0] hmd_mode = status[22:21];
  wire       hmd_look = !hmd_mode[1];

  // THE INPUT MAP IS PER GAME, AND IT HAS TO BE.
  //
  // These three bytes are the board's IN.0/IN.1/IN.2 and the games do not agree
  // about them beyond IN.0's bottom five bits. Virtua Racing puts its four view
  // buttons and two shift levers here; VIRTUA FIGHTER puts a full 8-way stick
  // and three buttons for EACH of two players, on IN.1 and IN.2. Publishing
  // VR's layout unconditionally left Virtua Fighter with no left or right for
  // player 1, buttons 2 and 3 unreachable, and player 2 entirely dead, because
  // IN.2 was tied to 0xff for the drive board that only VR has.
  //
  // model1.cpp INPUT_PORTS_START( vr ) and ( vf ). Active LOW throughout, so
  // idle is all-ones and a press is a bit going low.
  wire [7:0] io_in0_vr = ~{io_vr3, io_vr2, io_vr1, io_start,
                           io_service, io_test, io_coin2, io_coin};
  wire [7:0] io_in1_vr = ~{2'b00, io_shift_up, io_shift_dn, 3'b000, io_vr4};
  wire [7:0] io_in2_vr = 8'hff;       // drive board RX line, nothing on it here

  // Virtua Fighter. IN.0 bit 5 is START2 where VR has its first view button -
  // without it player 2 cannot join at all.
  wire [7:0] io_in0_vf = ~{2'b00, io_start2, io_start,
                           io_service, io_test, io_coin2, io_coin};
  wire [7:0] io_in1_vf = ~{p1_left, p1_right, p1_up, p1_down,
                           1'b0, p1_b3, p1_b2, p1_b1};
  wire [7:0] io_in2_vf = ~{p2_left, p2_right, p2_up, p2_down,
                           1'b0, p2_b3, p2_b2, p2_b1};

  // Star Wars Arcade. INPUT_PORTS_START( swa ).
  //
  // IN.0 is bit for bit Virtua Fighter's -- coin, coin2, test, service, START1
  // at 0x10 and START2 at 0x20 -- so it is shared rather than retyped. IN.1 is
  // its own: two buttons for EACH player plus a third for player 1, and the
  // two players are interleaved rather than given a byte each.
  //
  //   0x01 P1 button 1   0x02 P1 button 2   0x10 P1 button 3
  //   0x04 P2 button 1   0x08 P2 button 2
  //
  // IN.2 is declared entirely unused, so it stays idle-high.
  wire [7:0] io_in1_swa = ~{3'b000, p1_b3, p2_b2, p2_b1, p1_b2, p1_b1};

  // Wing War. INPUT_PORTS_START( wingwar ).
  //
  // IN.0 IS ALREADY VIRTUA RACING'S, BIT FOR BIT -- coin at 0x01, the
  // no-toggle service at 0x04, SERVICE1 at 0x08, START1 at 0x10 and View 1-3
  // at 0x20/0x40/0x80. Nothing to do, and worth stating because Start not
  // working on the board was first read as a mapping fault. It is not one.
  //
  // IN.1 differs by exactly one reachable bit. View 4 at 0x01 already lands on
  // io_vr4; Machine Gun (0x10), Missile (0x20) and Smoke (0x40) are the three
  // weapons, and only the first two had anything driving them -- the gear
  // levers, by coincidence of position. SMOKE WAS TIED LOW AND UNREACHABLE.
  //
  // The three take joy0[4]/[5]/[6], which are the pedals and first gear on a
  // racer and free here, so they sit under the MRA's first three button names.
  wire [7:0] io_in1_ww = ~{1'b0, joy0[6], joy0[5], joy0[4], 3'b000, io_vr4};

  wire [7:0] io_in0 = (is_vf | is_swa) ? io_in0_vf : io_in0_vr;
  wire [7:0] io_in1 = is_swa ? io_in1_swa : is_ww ? io_in1_ww :
                      is_vf  ? io_in1_vf  : io_in1_vr;
  wire [7:0] io_in2 = is_vf ? io_in2_vf : io_in2_vr;

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
  // ALL OF IT IN m1_drive_inputs NOW, with the OSD's "Analog control" beside
  // it: Standard is the logic that stood here, bit for bit (the module's
  // bench checks it against a frozen copy for every input); Wheel A and Wheel
  // B read a USB wheel's pedals from axes of their own, as the Model 2 core
  // does (its study R958). See that module.
  wire [7:0] io_wheel, io_accel, io_brake;
  m1_drive_inputs u_drive (
    .mode(status[15:14]), .swap(status[11]),
    .steer_l(io_steer_l), .steer_r(io_steer_r),
    .accel_b(io_accel_b), .brake_b(io_brake_b),
    .lstick(joy0_lstick), .rstick(joy0_rstick),
    .wheel(io_wheel), .accel(io_accel), .brake(io_brake)
  );

  // ------------------------------------------------ Star Wars Arcade, analogue
  //
  // MAME's an_callback<N> index IS the DPRAM byte index -- vr publishes WHEEL,
  // ACCEL, BRAKE on 0/1/2 and reads them at 0x00/0x01/0x02. So swa's five
  // channels land on five bytes:
  //
  //   0x00 STICK1X   0x01 STICK1Y   0x02 THROTTLE
  //   0x04 STICK2X   0x05 STICK2Y        (channel 3 is skipped)
  //
  // BOTH OF THE GAME'S STICKS GET THE SAME VALUE. It is a two-seat cabinet and
  // one player has one pad, so player 2's pot follows player 1's rather than
  // sitting at an idle the game would read as a second gunner holding still.
  //
  // BOTH OF THE PAD'S STICKS DRIVE IT TOO. The left stick is taken unless it is
  // resting, in which case the right one is, so it does not matter which the
  // player reaches for. The d-pad overrides either and goes to full deflection,
  // the same rule the wheel already uses -- a digital input has no travel to
  // interpolate and a player holding a direction means it.
  //
  // SCALED INTO THE POT'S RANGE, NOT LEFT AT FULL SCALE. MAME declares
  // PORT_MINMAX(27,227) with a 0x7f centre, so the real pot swings 27..227 and
  // never reaches the rails. Publishing 0x00..0xff would hand the game values
  // its calibration never sees. 200/256 of the axis plus 27 lands exactly in
  // range, and costs a multiply on a path that changes at human speed.
  wire [7:0] swa_lx = {~joy0_lstick[7],  joy0_lstick[6:0]};
  wire [7:0] swa_ly = {~joy0_lstick[15], joy0_lstick[14:8]};
  wire [7:0] swa_rx = {~joy0_rstick[7],  joy0_rstick[6:0]};
  wire [7:0] swa_ry = {~joy0_rstick[15], joy0_rstick[14:8]};

  // "Resting" is a dead band, not equality: an analogue stick almost never
  // reports exactly centre, so testing for 0x80 would keep the left stick
  // selected forever and the right one would never be reachable.
  // DEAD-ZONE EACH STICK, THEN LET THE FURTHER-PUSHED ONE WIN, PER AXIS.
  //
  // The first version asked "is the LEFT stick resting?" and used the right one
  // if so. That is fragile in exactly the way pads are: a left stick that rests
  // a few counts off centre is never "resting", so it locks the right stick out
  // AND feeds its own drift through as a permanent off-centre reading -- an aim
  // that runs away and stays there. A worn pad should degrade into a slightly
  // less precise stick, not into a stuck axis and a dead second stick.
  //
  // So each axis is snapped to centre inside the dead band first, which removes
  // drift at the source, and then the axis further from centre wins. Either
  // stick drives, neither can be locked out, and a drifting one loses to a
  // stick somebody is actually pushing.
  //
  // Per axis rather than per stick: pushing left-stick X must not drag
  // right-stick Y along with it.
  // COMPUTED ONCE EACH, NOT PER USE. These were functions called thirteen
  // times, and Quartus builds one comparator per call rather than sharing them
  // -- the same duplication that cost this design its routing once already.
  // Six wires instead, and clk_3d came back positive.
  function automatic [7:0] dev(input [7:0] v);          // distance from centre
    dev = (v >= 8'h80) ? (v - 8'h80) : (8'h80 - v);
  endfunction

  wire [7:0] lx_d = (swa_lx > 8'h70 && swa_lx < 8'h90) ? 8'h80 : swa_lx;
  wire [7:0] ly_d = (swa_ly > 8'h70 && swa_ly < 8'h90) ? 8'h80 : swa_ly;
  wire [7:0] rx_d = (swa_rx > 8'h70 && swa_rx < 8'h90) ? 8'h80 : swa_rx;
  wire [7:0] ry_d = (swa_ry > 8'h70 && swa_ry < 8'h90) ? 8'h80 : swa_ry;
  wire [7:0] swa_ax_r = (dev(rx_d) > dev(lx_d)) ? rx_d : lx_d;
  wire [7:0] swa_ay_r = (dev(ry_d) > dev(ly_d)) ? ry_d : ly_d;

  // X IS REVERSED BY DECLARATION, NOT BY TASTE.
  //
  // swa's STICK1X and STICK2X both carry PORT_REVERSE, and so does wingwar's
  // STICKX; none of the Y axes do. That asymmetry is why left/right came out
  // swapped on the board while up/down was fine -- the reverse was read off
  // model1.cpp and then not applied. O[13] flips it back for anyone whose pad
  // disagrees, and for wingwar360, which declares the opposite polarity to
  // wingwar on BOTH axes while sharing its game id.
  //
  // THE INVERSION IS RE-CENTRED, and that is not cosmetic. `0xff - v` maps a
  // centred 0x80 to 0x7f -- one count off -- so with the invert ON, which is
  // the DEFAULT here because MAME declares PORT_REVERSE, a stick sitting
  // perfectly still sent 126 where the pot's centre is 127. Star Wars reads the
  // pot as a RATE, so a permanent one-count offset is a crosshair that creeps
  // and never settles: "it does not recenter after turning right". Passing the
  // inverted value back through the dead zone snaps 0x7f to 0x80 again, so
  // centre survives the flip in both directions.
  wire       x_inv  = ~status[13];
  // The arbitrated value is already snapped, so preserving centre through the
  // flip needs one equality, not a second dead zone: 0xff - 0x80 is 0x7f.
  wire [7:0] swa_ax = !x_inv               ? swa_ax_r :
                      (swa_ax_r == 8'h80)  ? 8'h80    : (8'hff - swa_ax_r);
  // Y inversion, O[12], SHARED BY EVERY GAME THAT HAS A PITCH AXIS. Only one
  // game runs at a time, so one switch serves Star Wars and Wing War both --
  // and it is needed twice over, because wingwar360 declares the opposite Y
  // polarity to wingwar with all four Wing War MRAs sending the same game id.
  // Which way a stick pushes is a preference the pads do not agree on anyway,
  // exactly as the Pedals switch above exists for.
  wire [7:0] swa_ay = !status[12]          ? swa_ay_r :
                      (swa_ay_r == 8'h80)  ? 8'h80    : (8'hff - swa_ay_r);

  wire [15:0] swa_sx_m = swa_ax * 16'd200;
  wire [15:0] swa_sy_m = swa_ay * 16'd200;
  wire [7:0]  swa_sx_a = 8'd27 + swa_sx_m[15:8];
  wire [7:0]  swa_sy_a = 8'd27 + swa_sy_m[15:8];

  // The d-pad wins, at the ends of the pot's travel rather than the byte's.
  // THE BUTTON SELECTS, THE INVERT SWAPS THE ENDPOINTS. It must not be written
  // as `(p1_left ^ x_inv)`: that reads as "pressed XOR inverted", so with
  // nothing pressed and the invert SET it evaluates true and pins the axis to
  // an endpoint, and the analogue value below is never reached. x_inv defaults
  // to 1 because MAME declares PORT_REVERSE on X, so that is exactly what
  // happened on the board -- the left stick did nothing and the aim sat hard
  // over. The Y form had the same shape and was only harmless because O[12]
  // defaults to 0; it would have broken the moment anyone used the switch.
  wire [7:0] swa_stick_x = p1_left  ? (x_inv ? 8'd227 : 8'd27 ) :
                           p1_right ? (x_inv ? 8'd27  : 8'd227) : swa_sx_a;
  wire [7:0] swa_stick_y = p1_up    ? (status[12] ? 8'd227 : 8'd27 ) :
                           p1_down  ? (status[12] ? 8'd27  : 8'd227) : swa_sy_a;

  // THROTTLE is PORT_MINMAX(28,200) with a 0x7f default and nothing on this pad
  // to drive it, so it rests mid-travel. 0x01 -- the value an idle VR pedal
  // takes -- would be a throttle held at one end.
  wire [7:0] swa_throttle = 8'd127;

  // ------------------------------------------------------ Wing War, analogue
  //
  //   0x00 STICKX    0x01 STICKY    0x02 THROTTLE
  //
  // TWO OF THE THREE WERE ALREADY RIGHT. STICKX centres at 0x80 and so does
  // io_wheel; THROTTLE is PORT_MINMAX(1,0xff) resting at 0x01 and so is the
  // brake pedal. Only the pitch axis was wrong, and it was wrong in the way
  // that matters most: it took io_accel, which RESTS AT 0x01 -- hard over.
  //
  // A flight stick pitched fully up at rest is a plane looking at nothing but
  // sky, which is a strong candidate for the featureless grey screen reported
  // from the board, and would read as "the 3D is not working" while the 3D is
  // fine. Unverified, but it is the first thing to check now it is centred.
  //
  // Full 0x00-0xff here rather than Star Wars' 27..227: wingwar declares
  // PORT_BIT( 0xff, 0x80, ... ) with no PORT_MINMAX, so the pot does reach the
  // rails on this cabinet.
  wire [7:0] ww_stick_x = p1_left  ? (x_inv ? 8'hff : 8'h00) :
                          p1_right ? (x_inv ? 8'h00 : 8'hff) : swa_ax;
  wire [7:0] ww_stick_y = p1_up    ? (status[12] ? 8'hff : 8'h00) :
                          p1_down  ? (status[12] ? 8'h00 : 8'hff) : swa_ay;

  // ------------------------------------------------------ NetMerc, analogue
  //
  //   0x00 STICKX    0x01 (nothing, 0xff)    0x02 STICKY
  //
  // NetMerc's stick aims the gun. It took the VR pedals' bytes: 0x02 was the
  // brake, RESTING AT 0x01, so the gun sat pitched hard over in play - the
  // top of the gun and the hands' wrong side toward the camera. MAME's
  // DPRAM in play reads 7f ff 7f at 0x00-0x02 with the stick at rest
  // (model1io2 an_callback 0 and 2, both defaulting to 0x7f).
  //
  // Wing War's stick, with both axes the other way round: netmerc declares
  // PORT_REVERSE on STICKY and not on STICKX, wingwar the opposite. The flip
  // keeps 0x80 at 0x80, as swa_ax's does. O[12]/O[13] still flip them.
  //
  // THE GUN IS ON THE RIGHT STICK when the head look is on: the left stick is
  // the player's head (hmd_mode above), so it must not also swing the gun.
  // The d-pad still aims it, at full deflection, exactly as before. With the
  // look Off it is Wing War's stick unchanged - both sticks, the further-
  // pushed winning - so a one-stick pad aims as it always did.
  wire [7:0] nm_ax = !x_inv              ? rx_d  :
                     (rx_d == 8'h80)     ? 8'h80 : (8'hff - rx_d);
  wire [7:0] nm_ay = !status[12]         ? ry_d  :
                     (ry_d == 8'h80)     ? 8'h80 : (8'hff - ry_d);
  wire [7:0] nm_gx = p1_left  ? (x_inv ? 8'hff : 8'h00) :
                     p1_right ? (x_inv ? 8'h00 : 8'hff) : nm_ax;
  wire [7:0] nm_gy = p1_up    ? (status[12] ? 8'hff : 8'h00) :
                     p1_down  ? (status[12] ? 8'h00 : 8'hff) : nm_ay;
  wire [7:0] nm_src_x = hmd_look ? nm_gx : ww_stick_x;
  wire [7:0] nm_src_y = hmd_look ? nm_gy : ww_stick_y;
  wire [7:0] nm_stick_x = (nm_src_x == 8'h80) ? 8'h80 : (8'hff - nm_src_x);
  wire [7:0] nm_stick_y = (nm_src_y == 8'h80) ? 8'h80 : (8'hff - nm_src_y);

  // -------------------------------------------- Star Wars Arcade, the GUNNER
  //
  // swa is a two-SEAT cabinet, not merely two-player: one pilot, one gunner,
  // each with a stick. The gunner is player 2 throughout -- STICK2X/Y on
  // channels 4 and 5, and buttons 1 and 2 on IN.1 bits 0x04 and 0x08, which
  // already come from pad 2.
  //
  // PAD 2 DRIVES IT WHEN PAD 2 IS BEING USED, AND MIRRORS PLAYER 1 WHEN IT IS
  // NOT. A single player must still be able to fly and shoot, which is what
  // mirroring gives; leaving the gunner's pot at a fixed idle would read as a
  // second crew member holding the turret still. But once a second stick moves
  // it has to win, or the gunner seat is decorative.
  //
  // The dead band is the same one the pilot's two sticks use: an analogue stick
  // never reports exactly centre, so equality would never fire.
  wire [7:0] g_lx = {~joy1_lstick[7],  joy1_lstick[6:0]};
  wire [7:0] g_ly = {~joy1_lstick[15], joy1_lstick[14:8]};
  // Same dead zone, so a drifting pad 2 does not permanently claim the gunner
  // seat from the pilot's mirrored stick.

  wire [7:0] gx_d = (g_lx > 8'h70 && g_lx < 8'h90) ? 8'h80 : g_lx;
  wire [7:0] gy_d = (g_ly > 8'h70 && g_ly < 8'h90) ? 8'h80 : g_ly;
  wire g_idle = (gx_d == 8'h80) && (gy_d == 8'h80) &&
                !p2_left && !p2_right && !p2_up && !p2_down;
  wire [7:0] g_ax = !x_inv            ? gx_d  :
                    (gx_d == 8'h80)   ? 8'h80 : (8'hff - gx_d);
  wire [7:0] g_ay = !status[12]       ? gy_d  :
                    (gy_d == 8'h80)   ? 8'h80 : (8'hff - gy_d);
  wire [15:0] g_sx_m = g_ax * 16'd200;
  wire [15:0] g_sy_m = g_ay * 16'd200;
  wire [7:0] g_stick_x = p2_left  ? (x_inv ? 8'd227 : 8'd27 ) :
                         p2_right ? (x_inv ? 8'd27  : 8'd227) : (8'd27 + g_sx_m[15:8]);
  wire [7:0] g_stick_y = p2_up    ? (status[12] ? 8'd227 : 8'd27 ) :
                         p2_down  ? (status[12] ? 8'd27  : 8'd227) : (8'd27 + g_sy_m[15:8]);

  wire [7:0] swa_gun_x = g_idle ? swa_stick_x : g_stick_x;
  wire [7:0] swa_gun_y = g_idle ? swa_stick_y : g_stick_y;

  // Bytes 0x00-0x02 and 0x04-0x05 are per game. Everything else in the sweep is
  // the same for all of them.
  wire [7:0] io_an0 = is_swa ? swa_stick_x : is_ww ? ww_stick_x :
                      is_nm  ? nm_stick_x  : io_wheel;
  wire [7:0] io_an1 = is_swa ? swa_stick_y : is_ww ? ww_stick_y :
                      is_nm  ? 8'hff       : io_accel;
  wire [7:0] io_an2 = is_swa ? swa_throttle : is_nm ? nm_stick_y : io_brake;
  wire [7:0] io_an4 = is_swa ? swa_gun_x : 8'hff;
  wire [7:0] io_an5 = is_swa ? swa_gun_y : 8'hff;

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
                              io_an5,    // 0x05  swa STICK2Y
                              io_an4,    // 0x04  swa STICK2X
                              8'hff,     // 0x03  swa skips this channel
                              io_an2,    // 0x02  vr BRAKE   / swa THROTTLE / netmerc STICKY
                              io_an1,    // 0x01  vr ACCEL   / swa STICK1Y
                              io_an0};   // 0x00  vr WHEEL   / swa STICK1X  / netmerc STICKX

  // ROM download. m1_rom_loader consumes this and writes SDRAM through the
  // controller's dedicated high-priority write port.
  wire        ioctl_download;
  wire        ioctl_wr;
  wire [26:0] ioctl_addr;
  wire [15:0] ioctl_dout;
  wire [15:0] ioctl_index;

  // The game id itself. See GAMEID_INDEX above for the mapping and why it is
  // held through an OSD reset.
  always_ff @(posedge clk_sys) begin
    if (!pll_locked)                                    game_id <= 8'd0;
    else if (ioctl_wr && (ioctl_index == GAMEID_INDEX)) game_id <= ioctl_dout[7:0];
  end
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
    // Bit 0 hides the selectable Video line and shows the fixed one: a
    // [15kHz CRT] MRA is loaded.
    .status_menumask({15'd0, crt_mra}),

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
    .joystick_l_analog_1(joy1_lstick),
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

  // The 3D layer's clock: 58.947 MHz, exactly twice clk_cpu.
  //
  // A separate domain for the geometry and rasterizer, at exactly 2x clk_cpu so
  // the crossing to the CPU side is a clock enable rather than a handshake.
  //
  // 58.947 rather than clk_sys's 80 because the TGP's state machine misses at
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
  // The sound board waits for ITS OWN stream, not for rom_ready. rom_ready
  // latches when index 0 finishes and the sound ROMs come later in the MRA, so
  // gating on it releases the 68000 onto SDRAM that has not been written yet --
  // it fetches a garbage reset vector and is never heard from again. That is
  // the coprocessor's old bug (the rules file) in a new place.
  wire snd_ready;

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
  wire [25:1] sdr_addr;
  wire [15:0] sdr_din;
  wire  [1:0] sdr_be;

  wire        ifp_req;
  wire [25:1] ifp_addr;

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
  wire [25:1] ldr_wr_addr;
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
  // TEN PORTS. Seven were the main board; 7, 8 and 9 are the sound board -
  // the 68000's memory (its ROM and work RAM share one port because a 68000
  // has one bus), and the two MultiPCM sample streams.
  // ELEVEN PORTS. Widened with NP: the sound 68000's work RAM moved off port 7
  // onto port 10 so its program ROM no longer shares a bus with it.
  // TWELVE PORTS (2026-10-28): port 11 is Star Wars' Digital Sound Board --
  // its Z80's ROM and RAM and its MPEG data, one single-word port behind a
  // clock crossing, see dsb_board.
  wire [11:0]       p_req, p_we, p_ack;
  wire [11:0][25:1] p_addr;
  wire [11:0][15:0] p_din;
  wire [11:0][1:0]  p_be;
  wire [11:0][63:0] p_dout;
  wire        dsb_sreq, dsb_swe;
  wire [25:1] dsb_saddr;
  wire [15:0] dsb_sdin;
  wire  [1:0] dsb_sbe;

  // THE SOUND BOARD'S ROMS, above the I/O firmware in the existing 32 MB map.
  //
  // No widening was needed: vr's sound ROMs are epr-14870a.7 (128 KB of 68000
  // program), mpr-14873.32 and mpr-14876.4 (2 MB of PCM each) - 4.125 MB, and
  // there is ~6 MB free above IOFW_BASE. The rules file's "8 MB of PCM" is sized
  // for the largest Model 1 game, not this one; that assumption sent a whole
  // session into widening the controller to 64 MB for nothing.
  // FOUR MEGABYTES PER MULTIPCM, 2026-09-15. One layout for every Model 1 game.
  //
  // vr and vformula carry 2 MB per sample chip; vf, swa and wingwar carry FOUR
  // (netmerc is 4 + 2). Sizing the map to the small pair meant the four games
  // with big sample sets could never have sound at all, and their MRAs simply
  // omitted the stream. Now the core allocates 4 MB per chip always and the
  // small games are zero-padded to fill it, so one core and one layout serve
  // all six.
  //
  // THE ROOM CAME FROM TWO OVER-ALLOCATIONS, both measured against MAME rather
  // than assumed:
  //
  //   polygons     declared 16 MB, largest game actually uses 14 MB   -> 2.00
  //   copro_data   declared  2 MB, largest game actually uses  0.5 MB -> 1.50
  //   free above the old SND_PCM2                                     -> 1.50
  //                                                            total    5.00 MB
  //
  // against 4.125 MB needed (+2 MB per chip, two chips, plus the 68000 program
  // going 128 KB -> 256 KB for vf and wingwar). One megabyte spare.
  //
  // THE DATAPATH ALREADY SUPPORTED IT. `snd_pcm1_addr` is [21:3], a 4 MB byte
  // address, because the chip's upper window banks across four 1 MB pages. The
  // only thing confining it to 2 MB was the `snd_pcm1_addr[21] ? 64'd0` mask
  // below, which existed because only 2 MB was ever loaded. That mask is gone.
  //
  // PCM1 AND PCM2 MUST STAY CONTIGUOUS: m1_rom_loader splits the sound stream
  // TWO ways, not three, because one linear mapping covers both sample sets.
  // 0xB80000 + 4 MB of words (0x200000) is exactly 0xD80000.
  // FOUR MB PER MULTIPCM, 2026-09-16, IN SPACE THAT ONLY EXISTS BECAUSE OF THE
  // 64 MB CONTROLLER.
  //
  // vr and vformula carry 2 MB per sample chip; vf, swa and wingwar carry FOUR.
  // At 2 MB those four games could not have sound at all, and their MRAs simply
  // omitted the stream.
  //
  // NOTHING BELOW MOVES. The previous attempt at this (2026-09-15, reverted)
  // tried to find 4 MB inside the 32 MB map by sliding POLY_BASE, COPRO_TBL_BASE
  // and TGP_RAM_BASE downward. The packer and the MRA kept writing the polygon
  // data, copro tables and TGP RAM at the OLD offsets, so the 3D read empty
  // memory and the screen went black on hardware. The regions the packer fills
  // are load-bearing constants shared with tools/build_rom_image.py and the
  // MRA; they must not move without moving those in the same change.
  //
  // Here every sound region is placed ABOVE 32 MB, which was unaddressable
  // before COL_BITS went to 10. The map below 32 MB is byte-for-byte what it
  // was, so the packer, the MRA and the 3D are untouched.
  //
  //   SND_ROM   32.00 MB   512 KB  (netmerc's is a SINGLE 512 KB ROM; vf and
  //                                  wingwar have two 128 KB ones; vr has one)
  //   SND_RAM   32.50 MB    64 KB
  //   SND_PCM1  33.00 MB     4 MB
  //   SND_PCM2  37.00 MB     4 MB   ends at 41 MB of 64
  //
  // PCM1 AND PCM2 MUST STAY CONTIGUOUS: m1_rom_loader splits the sound stream
  // TWO ways, not three, because one linear mapping covers both sample sets.
  // 0x1080000 + 4 MB of words (0x200000) is exactly 0x1280000.
  localparam logic [25:1] SND_ROM_BASE  = 25'h1000000;   // 32.0 MB, 512 KB
  localparam logic [25:1] SND_RAM_BASE  = 25'h1040000;   // 32.5 MB, 64 KB
  localparam logic [25:1] SND_PCM1_BASE = 25'h1080000;   // 33.0 MB, 4 MB
  localparam logic [25:1] SND_PCM2_BASE = 25'h1280000;   // 37.0 MB, 4 MB
  // THE TWO DISPLAY LISTS, 16 K words each. Off-chip since 2026-09-12: they
  // were 64 of the 553 M10K blocks and M10K was exhausted. Sits above the PCM
  // samples (which end at word 0xF3FFFF) and below the V60's work RAM at
  // 0xF80000 -- 32 K words, so 0xF40000..0xF47FFF.

  // The 68000's ROM and work RAM share one port: it has one bus.
  wire        snd_rom_req,  snd_ram_req,  snd_ram_we;
  wire [17:1] snd_rom_addr;
  wire [15:1] snd_ram_addr;
  wire [1:0]  snd_ram_be;
  wire [15:0] snd_ram_wdata;
  // ROM ON PORT 7, WORK RAM ON PORT 10. THEY DO NOT SHARE.
  //
  // They did, and the arbitration was combinational: every field -- address,
  // write enable, byte enables and the acknowledge routing -- muxed on the
  // current value of `snd_ram_req`. A ROM fetch in flight when the RAM asked
  // had its address changed under it and its acknowledge delivered to the
  // wrong master. Latching ownership fixed the corruption but kept the
  // serialisation: the 68000 has one bus and every RAM access still blocked a
  // prefetch.
  //
  // An eleventh port removes the question. `NP=11 is BROKEN` stood in the rules file
  // as an unexplained controller fault -- it was tb_m1_sdram driving port 10's
  // REQUEST onto port 9 while reading port 10's ACKNOWLEDGE, so the port was
  // never asked and never answered. The controller is fine at eleven ports:
  // 68,873 checks, 0 fails, p10 serving 2,116 transactions.
  //
  // Model 2 runs eleven ports with working sound and textures on a heavier 3D
  // path, which is what said the sharing was a choice rather than a necessity.
  // Port 7 answers the ROM, port 10 the work RAM. Separate acknowledges and
  // separate data: nothing is shared and nothing can be delivered to the wrong
  // master.
  wire        snd_mem_ack  = p_ack[7];
  wire [15:0] snd_mem_data = p_dout[7][15:0];      // ROM, byte-swapped below
  wire [15:0] snd_ram_data = p_dout[10][15:0];     // work RAM, not swapped

  // THE 68000'S ROM IS BYTE-SWAPPED ON THE WAY IN, AND ITS WORK RAM IS NOT.
  //
  // MiSTer hands the loader 16-bit words LITTLE-endian (hps_io.sv:692,
  // `ioctl_dout <= io_din`), which is what the little-endian V60 wants and what
  // every other region here is written as. The sound CPU is a 68000 and wants
  // BIG-endian, so its program lands in SDRAM with the halves the wrong way
  // round: it reads SP=F000FEFF, PC=00000002, jumps into nothing and is never
  // heard from again. On the board that is the sound board released and
  // immediately dead -- LED_DISK solid, LED_POWER dark, which is exactly what
  // it did (2026-09-12).
  //
  // Model 2 has the same line and it is why their sound works:
  //     Model2.sv:2155  wire [15:0] snd_rom_q = {snd_rom_w[7:0], snd_rom_w[15:8]};
  //
  // NOT the work RAM. That is written and read by the same CPU through the same
  // path, so it is self-consistent either way, and `ram_be` already maps UDS to
  // the upper byte. Swapping it would only have to be undone on the write side.
  //
  // tb_m1_sndboard could not catch this: it feeds the board words from the ROM
  // file directly, so it models the CHIP and not the path that fills it.
  wire [15:0] snd_rom_data = {snd_mem_data[7:0], snd_mem_data[15:8]};

  wire        snd_pcm1_req, snd_pcm2_req;
  wire [21:3] snd_pcm1_addr, snd_pcm2_addr;

  // The I/O board Z80's firmware fetch, from m1_integrated. IOFW_BASE in
  // m1_rom_loader is where the loader put it, and the two must agree - a
  // mismatch is a Z80 executing whatever else is at that address.
  localparam logic [25:1] IOFW_BASE = 25'hD00000;
  wire        iofw_req;
  wire [13:0] iofw_word;

  // The 3D layer's two masters, from m1_integrated in the clk_sys domain.
  wire        r3d_rom_req, r3d_tex_req, r3d_tex_we;
  wire [25:1] r3d_rom_addr, r3d_tex_addr;
  wire [15:0] r3d_tex_din;

  // Port map per docs/00-decisions.md D8: p0 CPU data, p1 character RAM,
  // p2 instruction fetch. p3 and p4 are sound, unbuilt.
  // The read-back sweep lives in m1_integrated now, so tb_m1_frame can verify
  // it against the SDRAM model. Port 4 was tied off; it carries the sweep.
  // p5 bursts the polygon models, p6 carries tgp_ram and is the only port
  // besides p0 that writes - display-list command 4 uploads colour words.
  // ---- PORT 4 CARRIES TWO MASTERS: the I/O board's firmware fetch and the
  // display lists.
  //
  // The lists moved off-chip to free 64 M10K (m1_mainram's u_dl0/u_dl1), and
  // they SHARE a port rather than adding an eleventh. Two reasons:
  //
  //   1. They do not need one. tools/dl_census.lua over 400 reference frames
  //      measures 3,032 writes a frame, 16,418 at peak, and ZERO READS -- one
  //      write every 85 cycles at worst, against a port that is otherwise a
  //      Z80 fetching firmware.
  //   2. NP=11 is BROKEN. tb_m1_sdram at TB_NP=11 reports "port 10 never
  //      acknowledged": the eleventh port serves one read and then stalls.
  //      Unexplained, and not worth solving to gain a port we do not need.
  //
  // PORT 4 IS THE I/O BOARD'S FIRMWARE FETCH, and only that.
  //
  // The display lists shared it while they lived in SDRAM. That move is
  // REVERTED -- see docs/HANDOFF.md, 2026-09-13. It bought 54 M10K and cost
  // the 3D layer, and four real bugs fixed inside it did not bring the picture
  // back. The work is preserved in build/dlist_work/ with its tests.
  assign iofw_ack = p_ack[4];


  // PORT 4 IS THE I/O BOARD'S NOW, not the read-back sweep's. See DEBUG_OVERLAY.
  assign p_req  = {dsb_sreq, snd_ram_req, snd_pcm2_req, snd_pcm1_req, snd_rom_req,
                   r3d_tex_req, r3d_rom_req, iofw_req, tgp_mem_req, ifp_req, char_req, sdr_req};
  assign p_we   = {dsb_swe,  snd_ram_we,  1'b0,         1'b0,         1'b0,
                   r3d_tex_we,  1'b0,        1'b0,     1'b0,        1'b0,    1'b0,     sdr_we};
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
// THE MULTIPCM ADDRESSES ARE 64-BIT LINES AND SDRAM IS WORD-ADDRESSED, SO THEY
// SHIFT LEFT BY TWO. `snd_pcm1_addr` is [21:3] -- a line index -- and a line is
// four 16-bit words. Zero-extending it instead of scaling it put every sample
// fetch at a QUARTER of the address the chip asked for, inside the first 512 KB
// of a 2 MB region, so the chips read busily and returned the wrong bytes:
// LED_DISK solid, LED_POWER blinking, and silence.
//
// Model 2 has the scaling and says why it matters (Model2.sv:770): a port width
// mismatch there "was making everything unlistenable" (their R94).
assign p_addr = {dsb_saddr,
                 SND_RAM_BASE  + {9'd0, snd_ram_addr},
                 SND_PCM2_BASE + 25'({snd_pcm2_addr, 2'b00}),
                 SND_PCM1_BASE + 25'({snd_pcm1_addr, 2'b00}),
                 SND_ROM_BASE + {7'd0, snd_rom_addr},
                 // EVERY ELEMENT HERE MUST BE EXACTLY 25 BITS.
                 //
                 // Concatenation operands are SELF-DETERMINED: a short element
                 // is not zero-extended into its slot, it shifts everything
                 // BELOW it. `{r3d_rom_addr[24:2], 1'b0}` was 24 bits when the
                 // address went to [25:1], which slid ifp_addr -- the V60's
                 // instruction fetch -- one bit down and halted the CPU 520
                 // cycles after reset. The unit benches all passed; only a
                 // bench that boots the CPU sees it.
                 r3d_tex_addr, {r3d_rom_addr[25:2], 1'b0},
                 IOFW_BASE + {10'd0, iofw_word},
                 tgp_mem_addr, ifp_addr,
                 25'hFA8000 + {6'd0, char_addr}, sdr_addr};
  assign p_din  = {dsb_sdin, snd_ram_wdata, 16'd0, 16'd0, 16'd0,
                   r3d_tex_din, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0, sdr_din};
  assign p_be   = {dsb_sbe, snd_ram_be, 2'b11, 2'b11, 2'b11,
                   2'b11,       2'd0,  2'd0,  2'd0,  2'd0,  2'd0,  sdr_be};

  // One master per port: no arbitration, no ownership, nothing to get wrong.
  assign snd_rom_ack = p_ack[7];
  assign snd_ram_ack = p_ack[10];

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
  wire [11:0] sd_pend;     // ports with a request outstanding (FREEZE_DIAG); twelve with the DSB on p11

  // ------------------------------------------------------------ SOUND BOARD
  // Model 2's m2_sound_board IS the Model 1 board - see rtl/sound/README.md.
  // It runs on clk_sys and divides to a 10 MHz 68000 with a phase accumulator,
  // so the ratio is given as a fraction rather than a divisor: an integer
  // divide of 80 MHz would give 8 or 11.4, and a 4% tempo error is audible.
  wire [7:0]  snd_tx_data;
  wire        snd_tx_stb;

  // The byte crosses from clk_cpu to clk_sys and must be HELD until the board
  // takes it - a pulse would be missed outright, which is the same handshake
  // fault that has bitten this project twice (see docs/HANDOFF.md).
  wire        snd_rx_ack;
  reg  [7:0]  snd_rx_data;
  reg         snd_rx_valid;
  reg         snd_stb_a, snd_stb_b, snd_stb_c;
  always @(posedge clk_sys) begin
    snd_stb_a <= snd_tx_stb_tog;
    snd_stb_b <= snd_stb_a;
    snd_stb_c <= snd_stb_b;
    if (snd_stb_b != snd_stb_c) begin
      snd_rx_data  <= snd_tx_data_h;
      snd_rx_valid <= 1'b1;
    end else if (snd_rx_ack) snd_rx_valid <= 1'b0;
    if (!rst_n) begin snd_rx_valid <= 1'b0; snd_rx_data <= 8'd0; end
  end
  // Toggle on the CPU side, so a single-cycle strobe survives the crossing.
  reg        snd_tx_stb_tog;
  reg  [7:0] snd_tx_data_h;
  always @(posedge clk_cpu) begin
    if (snd_tx_stb) begin
      snd_tx_stb_tog <= ~snd_tx_stb_tog;
      snd_tx_data_h  <= snd_tx_data;
    end
    if (!rst_n) begin snd_tx_stb_tog <= 1'b0; snd_tx_data_h <= 8'd0; end
  end

  // THE SOUND BOARD'S COUNTERS, out over the printf UART once a second.
  // Every one of these was left unconnected, which is why the board reaching
  // hardware with DISK and POWER lit and USER dark could not be taken further
  // than "somewhere between the samples arriving and the mix". See
  // rtl/sound/m1_snd_report.sv.

  // Bytes the V60 has actually pushed into the uPD71051C. If this stays at
  // zero the game is not commanding the board at all and nothing the sound
  // board reports about itself matters.
  reg  [15:0] sb_v60_bytes;
  always @(posedge clk_cpu) begin
    if (!rst_n)            sb_v60_bytes <= 16'd0;
    else if (snd_tx_stb && !(&sb_v60_bytes)) sb_v60_bytes <= sb_v60_bytes + 16'd1;
  end

  // Two latching bits, both free, both on clocks that already exist.
  reg v60_cmd_seen, mix_seen;
  always @(posedge clk_cpu) begin
    if (!rst_n)          v60_cmd_seen <= 1'b0;
    else if (snd_tx_stb) v60_cmd_seen <= 1'b1;
  end

  wire signed [15:0] snd_l, snd_r;
  wire  [7:0] snd_txd;                 // the 68000's transmit line, for the DSB
  wire        snd_txv, snd_txa;
  wire        snd_rom_ack, snd_ram_ack;

  // PCM_CACHE(1) -- MODEL 2'S SETTING, AND IT STAYS.
  //
  // This was 0 to save ~864 ALM, argued on the grounds that the cache is a
  // LATENCY fix and tb_m1_sndboard measured no underruns without it. THAT
  // ARGUMENT WAS WRONG and it is worth recording why: the bench acknowledged
  // every PCM fetch on the SAME CYCLE as the request -- ACK_HOLD set how long
  // the ack stayed up, not how long it took to arrive -- so fetch latency was
  // ZERO, and a cache whose whole purpose is hiding latency measured as free.
  // A null result from an instrument that cannot see the effect is not
  // evidence against it. (tb_m1_sndboard has a PCM_LAT knob now.)
  //
  // Model 2 sets it deliberately (Model2.sv:2423) after measuring that they
  // need it, and their sound works. Our port 8/9 wait tens of cycles on a
  // controller shared with the V60, the tile fetch, the TGP and the 3D
  // renderer -- strictly worse than the case Model 2 measured.
  //
  // The cost is paid down by putting m2_pcm_fetch's tag array in MLAB: 32 x 19
  // bits per fetcher was 608 flip-flops each, and buf_q beside it was already
  // an MLAB.
  m2_sound_board #(.TICK_NUM(20), .TICK_DEN(80), .PCM_CACHE(1'b1)) u_snd (
    .clk(clk_sys), .rst_n(rst_n && snd_ready),
    .rx_data(snd_rx_data), .rx_valid(snd_rx_valid), .rx_ack(snd_rx_ack),
    // The main board never reads back, but Star Wars' DSB listens to this
    // line: model1.cpp appends dsbz80's write_txd to m1audio's rxd_handler.
    .tx_data(snd_txd), .tx_valid(snd_txv), .tx_ack(snd_txa),
    .rom_req(snd_rom_req), .rom_addr(snd_rom_addr),
    .rom_ack(snd_rom_ack), .rom_data(snd_rom_data),
    .ram_req(snd_ram_req), .ram_addr(snd_ram_addr), .ram_we(snd_ram_we),
    .ram_be(snd_ram_be),   .ram_wdata(snd_ram_wdata),
    .ram_ack(snd_ram_ack), .ram_data(snd_ram_data),
    .pcm1_rom_req(snd_pcm1_req), .pcm1_rom_addr(snd_pcm1_addr),
    // THE ZEROING MUX IS GONE, AND THE BEHAVIOUR IT PROTECTED IS NOT.
    //
    // This used to be `snd_pcm1_addr[21] ? 64'd0 : p_dout[8]`, because
    // `pcm1_rom_addr` is [21:3] -- a 4 MB span -- while only 2 MB was allocated
    // per chip. Without the mask the top half of PCM1's reach landed in PCM2's
    // samples and the top half of PCM2's landed in the DISPLAY LISTS, geometry
    // rewritten every frame and read as PCM. On the board that was a constant
    // rumble and crackle that resembled no sound effect.
    //
    // It also reproduced the reference: model1.cpp gives each MULTIPCM a
    // 0x400000 region and loads 0x200000 into it for vr, so a voice addressing
    // the top half reads ZEROS in MAME.
    //
    // As of 2026-09-15 each chip really has its 4 MB and the mask is
    // unnecessary. **MAME EQUIVALENCE IS PRESERVED BY THE MRA, NOT BY LOGIC**:
    // vr and vformula are zero-padded to fill the 4 MB slot (`<part
    // repeat="2097152">00</part>`), so the upper half holds actual zeros and a
    // voice reading it gets what the reference gets. That is why the pad fill
    // is 00 and not the FF used elsewhere in those files -- FF would be
    // full-scale noise exactly where MAME is silent.
    .pcm1_rom_data(p_dout[8]), .pcm1_rom_ack(p_ack[8]),
    .pcm2_rom_req(snd_pcm2_req), .pcm2_rom_addr(snd_pcm2_addr),
    .pcm2_rom_data(p_dout[9]), .pcm2_rom_ack(p_ack[9]),
    .snd_l(snd_l), .snd_r(snd_r),
    .dbg_pc(sb_pc), .dbg_insns(sb_insns), .dbg_ym_writes(sb_ym_wr),
    .dbg_pcm_writes(sb_pcm_wr),
    .dbg_pcm_samples(sb_pcm_smp), .dbg_pcm_lat(), .dbg_pcm_miss(),
    // LEFT UNCONNECTED DELIBERATELY. Connecting a debug output stops Quartus
    // pruning it AND everything that feeds it; these two instrument the rate
    // stage's buffers and brought 8 M10K back with them, which on a design at
    // 553/553 spills into logic and fails the fit. The chain below -- r i y p
    // s m -- is what names the broken stage; these two only characterise a
    // stage that is already known to be running.
    .dbg_pcm_under(), .dbg_pcm_level()
  );

  // ------------------------------------------------- STAR WARS' SOUND BOARD
  // Sega's Digital Sound Board: a Z80, an i8251 and an MPEG-1 Layer II
  // player with 4 MB of music. Star Wars is the only Model 1 game that has
  // one (model1.cpp swa()); it is held in reset for every other game, whose
  // streams carry no DSB data. See rtl/sound/dsb_board.sv and
  // docs/findings.md, 2026-10-28 (c).
  //
  // ITS INPUT IS THE SOUND 68000'S UART LINE, paced as the wire is: a
  // holding register and a shift register, one character (10 bits at
  // 31.25 kbaud, 320 us) per byte. The 68000 sees TXRDY drop only while both
  // are full, as on the real part. Before this the line was acknowledged
  // instantly and went nowhere.
  reg         txh_full, txs_busy, dsb_rx_tog;
  reg   [7:0] txh_d, txs_d, dsb_rx_byte;
  reg  [14:0] txs_cnt;
  assign snd_txa = !txh_full;
  always @(posedge clk_sys) begin
    if (!rst_n) begin
      txh_full <= 1'b0; txs_busy <= 1'b0; dsb_rx_tog <= 1'b0; txs_cnt <= 15'd0;
    end else begin
      if (snd_txv && !txh_full) begin txh_d <= snd_txd; txh_full <= 1'b1; end
      if (!txs_busy && txh_full) begin
        txs_d <= txh_d; txh_full <= 1'b0; txs_busy <= 1'b1;
        txs_cnt <= 15'd25599;                       // 320 us at 80 MHz
      end else if (txs_busy) begin
        if (txs_cnt == 15'd0) begin
          txs_busy <= 1'b0; dsb_rx_byte <= txs_d; dsb_rx_tog <= ~dsb_rx_tog;
        end else txs_cnt <= txs_cnt - 15'd1;
      end
    end
  end

  // Released only for Star Wars (game 2), only once its stream is in SDRAM.
  reg  [2:0] dsb_rst_s;
  always @(posedge clk_cpu or negedge rst_n) begin
    if (!rst_n) dsb_rst_s <= 3'b000;
    else        dsb_rst_s <= {dsb_rst_s[1:0], snd_ready && (game == 7'd2)};
  end
  reg  [1:0] dsb_volm_s;
  always @(posedge clk_cpu) dsb_volm_s <= {dsb_volm_s[0], status[20]};

  wire        dsb_areq, dsb_awe, dsb_aack;
  wire [25:1] dsb_aaddr;
  wire [15:0] dsb_adin, dsb_adout;
  wire  [1:0] dsb_abe;
  wire signed [15:0] dsb_l, dsb_r;
  wire        dsb_stb, dsb_trap;
  dsb_board u_dsb (
    .clk(clk_cpu), .rst_n(dsb_rst_s[2]),
    .rx_tog(dsb_rx_tog), .rx_byte(dsb_rx_byte),
    .vol_mame(dsb_volm_s[1]),
    .s_req(dsb_areq), .s_we(dsb_awe), .s_addr(dsb_aaddr), .s_din(dsb_adin),
    .s_be(dsb_abe), .s_ack(dsb_aack), .s_dout(dsb_adout),
    .out_l(dsb_l), .out_r(dsb_r), .out_stb(dsb_stb),
    .dbg_trap(dsb_trap), .dbg_frames()
  );

  m1_cdc_port #(.AW(25), .DW(16), .BEW(2)) u_dsb_cdc (
    .a_clk(clk_cpu), .a_rst_n(rst_n),
    .a_req(dsb_areq), .a_we(dsb_awe), .a_addr(dsb_aaddr), .a_din(dsb_adin),
    .a_be(dsb_abe), .a_dout(dsb_adout), .a_ack(dsb_aack), .a_busy(),
    .b_clk(clk_sys), .b_rst_n(rst_n),
    .b_req(dsb_sreq), .b_we(dsb_swe), .b_addr(dsb_saddr), .b_din(dsb_sdin),
    .b_be(dsb_sbe), .b_dout(p_dout[11][15:0]), .b_ack(p_ack[11])
  );

  // The DSB's 32 kHz samples into clk_sys: each is held for ~920 clk_cpu
  // cycles, so a toggle and two flops are enough; then the sum, saturated.
  reg        dsb_ot, dsb_os1, dsb_os2, dsb_os3;
  reg signed [15:0] dsb_ls, dsb_rs;
  always @(posedge clk_cpu) if (dsb_stb) dsb_ot <= ~dsb_ot;
  always @(posedge clk_sys) begin
    {dsb_os3, dsb_os2, dsb_os1} <= {dsb_os2, dsb_os1, dsb_ot};
    if (dsb_os2 ^ dsb_os3) begin dsb_ls <= dsb_l; dsb_rs <= dsb_r; end
    if (!dsb_rst_s[2])     begin dsb_ls <= 16'sd0; dsb_rs <= 16'sd0; end
  end
  wire signed [16:0] sum_l = snd_l + dsb_ls;
  wire signed [16:0] sum_r = snd_r + dsb_rs;
  assign mix_l = (sum_l[16] == sum_l[15]) ? sum_l[15:0] : (sum_l[16] ? 16'sh8000 : 16'sh7fff);
  assign mix_r = (sum_r[16] == sum_r[15]) ? sum_r[15:0] : (sum_r[16] ? 16'sh8000 : 16'sh7fff);

  always @(posedge clk_sys) begin
    if (!rst_n)                            mix_seen <= 1'b0;
    else if (snd_l > 16'sd64 || snd_l < -16'sd64) mix_seen <= 1'b1;
  end

  // LED_USER IS THE OUT-OF-RANGE FLAG NOW, not the mix level -- the mix is
  // known to carry audio, and the open question is whether a voice reaches
  // past the 2 MB that is actually loaded. If this lights, the zeroing above
  // is doing real work and the rumble was PCM2's samples and the display
  // lists being played as audio.
  // IS THE SOUND 68000 RUNNING THE REAL DRIVER? Nothing has ever answered
  // this on hardware -- every LED so far reported the V60 side or the ROM
  // load. tb_m1_sndboard settles at pc=0x00116e, inside MAME's main loop at
  // page 0x001100, after 901,005 instructions. If the 68000 ever reaches that
  // page it is executing the real program and the fault is downstream; if it
  // never does, it is lost in its own ROM and everything it writes to the
  // MULTIPCMs is noise -- which is what a continuous rumble that does not stop
  // for silence sounds like.
  wire [31:0] sb_pc, sb_insns, sb_pcm_smp;
  wire [15:0] sb_ym_wr, sb_pcm_wr;
  reg  snd_mainloop_seen;
  always @(posedge clk_sys) begin
    if (!rst_n)                        snd_mainloop_seen <= 1'b0;
    else if (sb_pc[23:8] == 16'h0011)  snd_mainloop_seen <= 1'b1;
  end

  m1_sdram #(.NP(12), .T_REFI(600)) sdram (
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
    // The OSD's "SDRAM read phase" (O[10:8]) is gone for the release (Ben,
    // 2026-10-30): CL+2, its default and the only depth this board captures
    // at, is fixed. O[10:8] is free.
    .rd_lat_sel(3'd2),
    .sd_cke(SDRAM_CKE), .sd_cs_n(SDRAM_nCS), .sd_ras_n(SDRAM_nRAS),
    .sd_cas_n(SDRAM_nCAS), .sd_we_n(SDRAM_nWE), .sd_ba(SDRAM_BA),
    .sd_a(SDRAM_A), .sd_dqm({SDRAM_DQMH, SDRAM_DQML}),
    .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(SDRAM_DQ),
    .wr_req(ldr_wr_req), .wr_addr(ldr_wr_addr), .wr_din(ldr_wr_din),
    .wr_be(ldr_wr_be), .wr_ack(ldr_wr_ack),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack),
    .dbg_req(sd_pend), .dbg_grant(),
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
  wire [25:1] rb_addr;
  wire [23:0] dbg_rb_csum, dbg_rb_csum0;
  wire [12:0] dbg_rb_n;
  wire [11:0] dbg_ucode_words;
  wire [15:0] dbg_copro_pops;
  wire [15:0] dbg_copro_drains;
  wire [15:0] dbg_ucode_csum;
  wire [23:0] dbg_sdram_csum, dbg_sdram_words;
  wire        tgp_mem_req;
  wire [25:1] tgp_mem_addr;
  wire [15:0] dbg_tgp_retires, dbg_tgp_pc;
  wire        dbg_tgp_unimpl;
  wire  [7:0] dbg_fetches;
  wire [15:0] dbg_overruns;
  wire [15:0] dbg_io_replies;

  // The freeze diagnostic's taps (FREEZE_DIAG, below). Observation only.
  wire [15:0] fz_rom_wr, fz_tex_drop, fz_passes, fz_bands, fz_swaps;
  wire [23:0] fz_rom_wr_pc, fz_rom_wr_addr;
  wire [2:0]  fz_rom_wr_bank;
  wire [11:0] fz_copro_fifo;
  wire [15:0] fz_lw_bad, fz_lw_over, fz_pay_ovf, fz_pay_refused, fz_pay_wait;

  m1_integrated core (
    .DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY),
    .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
    .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
    .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
    .DDRAM_WE(DDRAM_WE),
    .r3d_show_tag(r3d_show_tag),
    .sdram_occ(sdram_occ), .sdram_wait1(sdram_wait1),
    .clk_sys(clk_sys), .ce_pix(ce_pix),
    .clk_cpu(clk_cpu), .ce_cpu(1'b1),
    .clk_3d(clk_3d),
    .rst_n(rst_n), .mem_rst_n(mem_rst_n), .mem_ready(mem_ready),
    .in_bytes(io_in_bytes),
    .roma_mode(roma_mode),
    .io2(io_board2),
    .hmd_pose(hmd_pose), .hmd_stick(joy0_lstick), .hmd_mode(hmd_mode),

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
    .snd_tx_data(snd_tx_data), .snd_tx_stb(snd_tx_stb),
    .dbg_io_replies(dbg_io_replies),
    .rom_loaded_o(rom_ready), .snd_loaded_o(snd_ready), .ldr_overflow(ldr_overflow),
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
    .dbg_copro_drains(dbg_copro_drains),
    .dbg_rom_wr(fz_rom_wr), .dbg_rom_wr_pc(fz_rom_wr_pc),
    .dbg_rom_wr_addr(fz_rom_wr_addr), .dbg_rom_wr_bank(fz_rom_wr_bank),
    .dbg_copro_fifo(fz_copro_fifo), .dbg_tex_drop(fz_tex_drop),
    .dbg_r3_passes(fz_passes), .dbg_r3_bands(fz_bands),
    .dbg_r3_lw_bad(fz_lw_bad), .dbg_r3_lw_over(fz_lw_over),
    .dbg_r3_pay_ovf(fz_pay_ovf), .dbg_r3_pay_refused(fz_pay_refused),
    .dbg_r3_pay_wait(fz_pay_wait), .dbg_swaps(fz_swaps)
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

  // THE FREEZE DIAGNOSTIC (2026-10-28). Virtua Racing freezes to black on the
  // board, the 3D never comes back, and RESTART does not recover it. Built
  // with M1_FREEZE_DIAG defined, the overlay (always on in such a build) shows
  // the rows below instead of the old ones, and a snapshot of the machine at
  // the moment it stopped, which survives RESTART. docs/HANDOFF.md says how to
  // read it. Off in every normal build.
`ifdef M1_FREEZE_DIAG
  localparam bit FREEZE_DIAG = 1;
`else
  localparam bit FREEZE_DIAG = 0;
`endif

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
  reg [25:1] fa [NFETCH];
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
  // ROWS 07, 0B, 0E AND 1B WERE COPROCESSOR READ ADDRESSES. They answered that
  // question long ago and have shown constants since. The sound board is the
  // live unknown and NOTHING on hardware reports it: three LEDs cannot show a
  // count, and the UART monitor needs 8 M10K this design does not have. The
  // overlay is already built and costs nothing to fill.
  //
  // 07: the sound 68000's PC. tb_m1_sndboard settles in MAME's main loop at
  //     0x00116e. A PC anywhere else, or one that never moves, means the CPU
  //     is lost in its own ROM and everything it programs is noise.
  assign dw[7]  = {8'h07, sb_pc[23:0]};
  assign dw[8]  = {8'h08, fd[1][23:0]};            // reset vector, low 24
  // Tags 09 and 0A — the data words of fetches 4 and 5 — are GONE, to stay under
  // the 24-row ceiling. They were boot forensics: they proved ROM contents were
  // arriving, which a core that now boots and runs proves better. Their
  // ADDRESSES survive as tags 06 and 07.
  // 0B: 68000 instructions retired. The bench does 901,005 in half a second;
  //     a count that is tiny or static is a dead or looping CPU.
  assign dw[9]  = {8'h0B, sb_insns[23:0]};
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
  // 0E: YM register writes (left 12) and MULTIPCM register writes (right 12).
  //     The bench does 342 and 479 in half a second with no V60 driving it.
  //     Both zero means the driver never reaches its output stage.
  assign dw[12] = {8'h0E, sb_ym_wr[11:0], sb_pcm_wr[11:0]};
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
  // 1B: sample slots the first MULTIPCM has produced. Two readings a second
  //     apart give the rate directly, against the chip's own 44,643 Hz -- the
  //     number that was 71,456 before the rate stage was told the clock.
  assign dw[23] = {8'h1B, sb_pcm_smp[23:0]};

  // ------------------------------------------------- the freeze diagnostic
  //
  // Rows 00-07 are the machine now; 08-0F more of it; 10-17 are rows 00-07
  // as they stood at the last FREEZE EVENT, held through RESTART (they are in
  // the memory reset's domain, which only a core reload clears). Every field
  // is whole hex digits, so a photograph reads without bit arithmetic.
  //
  //   00  V60 PC
  //   01  [23:20] 1 = V60 held pushing into a FULL inbound FIFO
  //       [19:16] 1 = V60 held reading an EMPTY outbound FIFO   [15:0] TGP PC
  //   02  [23:16] inbound FIFO count  [15:8] outbound count (each 00-10)
  //       [7:0]   display-list flips, low byte
  //   03  [23:16] 3D passes completed, low byte   [15:0] TGP retires
  //   04  [23:20] bank of the first dropped ROM write   [15:0] V60 writes
  //       into ROM windows, dropped
  //   05  PC of the first dropped ROM write      06  its address
  //   07  [23:16] SDRAM port with the longest wait so far (00-0A)
  //       [15:0]  colour uploads dropped outside tgp_ram
  //   08  [23:16] freeze events  [15:12] last cause (2 flips stopped,
  //       1 3D passes stopped, 3 both)  [10:0] SDRAM ports waiting now
  //   09  [23:16] DDR3 reads refused  [15:0] worst DDR3 reply wait (clk_3d)
  //   0A  [23:16] DDR3 writes lost  [15:8] list walks ended on garbage
  //       [7:0] list walks run off the buffer
  //   0B  [23:20] V60 halted  [19:16] V60 FP trap  [15:0] I/O board replies
  //   0C  sound 68000 PC         0D  3D passes (16 bits)
  //   0E  display-list flips     0F  worst SDRAM wait, clk_sys cycles
  //
  // A FREEZE EVENT: after the game has flipped its display list 64 times
  // since reset, half a second with no flip, or half a second with no
  // completed 3D pass. It then needs 64 more flips to re-arm.
  wire [31:0] dwf [NDW];

  // SDRAM: how long each port's request has been outstanding, and the worst.
  logic [23:0] sd_age [12];
  logic [23:0] sd_worst;
  logic [3:0]  sd_worst_port;
  always_ff @(posedge clk_sys or negedge mem_rst_n) begin
    if (!mem_rst_n) begin
      for (int k = 0; k < 12; k++) sd_age[k] <= '0;
      sd_worst <= '0; sd_worst_port <= '0;
    end else if (FREEZE_DIAG) begin
      for (int k = 0; k < 12; k++) begin
        if (!sd_pend[k])          sd_age[k] <= '0;
        else if (~&sd_age[k])     sd_age[k] <= sd_age[k] + 24'd1;
        if (sd_pend[k] && sd_age[k] > sd_worst) begin
          sd_worst <= sd_age[k]; sd_worst_port <= 4'(k);
        end
      end
    end
  end

  // Liveness: the flip and the pass, each crossed by its low bit.
  logic [2:0]  fz_sw_s, fz_pa_s;
  logic [25:0] fz_sw_idle, fz_pa_idle;
  logic [6:0]  fz_since;          // flips since reset or since the last event
  logic [7:0]  fz_events;
  logic [1:0]  fz_cause;
  logic [23:0] fz_snap [8];
  logic        fz_grst_s0, fz_grst_s1;
  localparam logic [25:0] FZ_HALF_S = 26'd40_000_000;   // 0.5 s of clk_sys
  wire [23:0] fz_live [8];
  assign fz_live[0] = dbg_pc;
  assign fz_live[1] = {3'd0, fz_copro_fifo[1], 3'd0, fz_copro_fifo[0], dbg_tgp_pc};
  assign fz_live[2] = {3'd0, fz_copro_fifo[11:7], 3'd0, fz_copro_fifo[6:2], fz_swaps[7:0]};
  assign fz_live[3] = {fz_passes[7:0], dbg_tgp_retires};
  assign fz_live[4] = {1'b0, fz_rom_wr_bank, 4'd0, fz_rom_wr};
  assign fz_live[5] = fz_rom_wr_pc;
  assign fz_live[6] = fz_rom_wr_addr;
  assign fz_live[7] = {4'd0, sd_worst_port, fz_tex_drop};
  always_ff @(posedge clk_sys or negedge mem_rst_n) begin
    if (!mem_rst_n) begin
      fz_sw_s <= '0; fz_pa_s <= '0; fz_sw_idle <= '0; fz_pa_idle <= '0;
      fz_since <= '0; fz_events <= '0; fz_cause <= '0;
      fz_grst_s0 <= 1'b1; fz_grst_s1 <= 1'b1;
      for (int k = 0; k < 8; k++) fz_snap[k] <= '0;
    end else if (FREEZE_DIAG) begin
      fz_grst_s0 <= ~rst_n; fz_grst_s1 <= fz_grst_s0;
      fz_sw_s <= {fz_sw_s[1:0], fz_swaps[0]};
      fz_pa_s <= {fz_pa_s[1:0], fz_passes[0]};
      fz_sw_idle <= (fz_sw_s[2] != fz_sw_s[1]) ? 26'd0 : fz_sw_idle + 26'd1;
      fz_pa_idle <= (fz_pa_s[2] != fz_pa_s[1]) ? 26'd0 : fz_pa_idle + 26'd1;
      if (fz_grst_s1) begin
        fz_since <= '0; fz_sw_idle <= '0; fz_pa_idle <= '0;
      end else begin
        if (fz_sw_s[2] != fz_sw_s[1] && !fz_since[6]) fz_since <= fz_since + 7'd1;
        if (fz_since[6] && (fz_sw_idle == FZ_HALF_S || fz_pa_idle == FZ_HALF_S)) begin
          for (int k = 0; k < 8; k++) fz_snap[k] <= fz_live[k];
          fz_cause  <= {fz_sw_idle == FZ_HALF_S, fz_pa_idle == FZ_HALF_S};
          fz_events <= fz_events + 8'd1;
          fz_since  <= '0;
        end
      end
    end
  end
  genvar fzi;
  generate
    for (fzi = 0; fzi < 8; fzi = fzi + 1) begin : g_fz
      assign dwf[fzi]      = {8'(fzi),      fz_live[fzi]};
      assign dwf[fzi + 16] = {8'(fzi + 16), fz_snap[fzi]};
    end
  endgenerate
  assign dwf[8]  = {8'h08, fz_events, 2'd0, fz_cause, sd_pend};   // bit 11: the DSB's port
  assign dwf[9]  = {8'h09, fz_pay_refused[7:0], fz_pay_wait};
  assign dwf[10] = {8'h0A, fz_pay_ovf[7:0], fz_lw_bad[7:0], fz_lw_over[7:0]};
  assign dwf[11] = {8'h0B, 3'd0, dbg_halted, 3'd0, dbg_fp_trap, dbg_io_replies};
  assign dwf[12] = {8'h0C, sb_pc[23:0]};
  assign dwf[13] = {8'h0D, 8'd0, fz_passes};
  assign dwf[14] = {8'h0E, 8'd0, fz_swaps};
  assign dwf[15] = {8'h0F, sd_worst};

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
      assign dw_packed[gi*32 +: 32] = FREEZE_DIAG ? dwf[gi] : dw[gi];
    end
  endgenerate

  generate
  if (DEBUG_OVERLAY || FREEZE_DIAG) begin : g_diag
  m1_diag #(.NWORDS(NDW)) diag (
    .clk(clk_sys), .ce_pix(ce_pix), .rst_n(mem_rst_n),
    // Only built with M1_FREEZE_DIAG (DEBUG_OVERLAY is 0): a diagnostic
    // build shows it always. The OSD's "Debug overlay" (O[3]) is gone for the
    // release (Ben, 2026-10-30); O[3] is free.
    .enable(1'b1),
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
  // ------------------------------------------------------------ 15 kHz
  //
  // m1_scan15, the Model 2 core's scan converter (retrorepair's design; see
  // that module and THIRD-PARTY.md). The picture is made at 24 kHz exactly as
  // before and the converter re-times the finished pixels to 15 kHz
  // interlaced: 240 lines a field from 384 by an exact 4:5 blend, no frame of
  // delay, two output fields to exactly two native frames.
  //
  // Selected by the OSD or by a [15kHz CRT] MRA (game id bit 7). At 24 kHz it
  // idles and the pins carry the native picture, bit for bit what they did.
  // HDMI follows the same pins: the framework's scaler deinterlaces 15 kHz.
  //
  // The output enable is an exact rational of clk_sys, so two fields are
  // exactly two native frames: 547/4240 (273/274 lines, 15.7 kHz), 537/4240
  // (268/269, 15.4) or 4305/34768 (262/263, 15.1) of 80 MHz - Model 2's
  // 547/5300, 537/5300 and 861/8692 of its 100 MHz, times 5/4.
  logic vid_scan_r, vid_scan;
  logic [1:0] vid_lines;
  logic vid_pair;
  always_ff @(posedge clk_sys) begin
    vid_scan_r <= status[16] | crt_mra;
    vid_scan   <= vid_scan_r;
    vid_lines  <= status[18:17];
    vid_pair   <= ~status[19];
  end
  wire vid_nl = (vid_lines == 2'd2);
  wire vid_ml = (vid_lines == 2'd1);

  logic [15:0] ceo_acc;
  logic        ce_out;
  wire  [15:0] ceo_num = vid_nl ? 16'd4305  : vid_ml ? 16'd537  : 16'd547;
  wire  [15:0] ceo_den = vid_nl ? 16'd34768 : 16'd4240;
  always_ff @(posedge clk_sys) begin
    // >= den only after a line-count change; restart rather than run away
    if (ceo_acc >= ceo_den) begin
      ceo_acc <= '0; ce_out <= 1'b0;
    end else if (ceo_acc + ceo_num >= ceo_den) begin
      ceo_acc <= ceo_acc + ceo_num - ceo_den; ce_out <= 1'b1;
    end else begin
      ceo_acc <= ceo_acc + ceo_num; ce_out <= 1'b0;
    end
  end

  // The image on show changes when the 3D layer swaps to a new pass; the
  // converter pairs its fields to that cadence so an output frame is never
  // made of two images (R939).
  wire [3:0] r3d_show_tag;
  wire       sc_hs, sc_vs, sc_de, sc_fld;
  wire [23:0] sc_rgb;
  m1_scan15 u_scan15 (
    .clk(clk_sys), .rst_n(mem_rst_n), .en(vid_scan), .img_tag(r3d_show_tag),
    .pair_en(vid_pair),
    .ce_in(ce_pix), .de_in(~(vid_hb | vid_vb)), .vb_in(vid_vb),
    .rgb_in({dg_r, dg_g, dg_b}),
    .ce_out(ce_out), .nl(vid_nl), .ml(vid_ml),
    .o_hs(sc_hs), .o_vs(sc_vs), .o_de(sc_de), .o_field(sc_fld), .o_rgb(sc_rgb)
  );

  assign CLK_VIDEO = clk_sys;
  assign CE_PIXEL  = vid_scan ? ce_out       : ce_pix;
  assign VGA_R     = vid_scan ? sc_rgb[23:16] : dg_r;
  assign VGA_G     = vid_scan ? sc_rgb[15:8]  : dg_g;
  assign VGA_B     = vid_scan ? sc_rgb[7:0]   : dg_b;
  assign VGA_HS    = vid_scan ? sc_hs        : vid_hs;
  assign VGA_VS    = vid_scan ? sc_vs        : vid_vs;
  assign VGA_DE    = vid_scan ? sc_de        : ~(vid_hb | vid_vb);
  assign VGA_F1    = vid_scan & sc_fld;

  // Lit while the ROM set is loading, so a failed load is visible without a
  // screen — the first thing to check when a board shows nothing.
// THE DIAGNOSTIC LEDS ARE GONE, AND THEY EARNED THEIR KEEP. With the debug
  // UART compiled out to make the design fit, three free bits localised the
  // sound fault that four hardware round trips of inference had not:
  //
  //   LED_DISK  = snd_ready              -> the ROM stream completed
  //   LED_POWER = p_ack[8] && p_dout[8]  -> SDRAM returned sample data
  //   LED_USER  = snd_l != 0             -> the mix produced audio
  //
  // DISK solid / POWER dark said the 68000 ran and the sample reads came back
  // ZERO, which is what found m1_sdram tagging in-flight reads with grant[2:0]
  // in a ten-port controller: ports 8 and 9 wrapped onto 0 and 1. Two 22-bit
  // counters and a 64-bit compare, removed now the answer is in hand -- the
  // design needs the ~40 ALM back. Reinstate them from git if sound regresses.
  //
  // REWIRED 2026-09-13. The two latches described above were deleted by a
  // wholesale revert, LED_POWER was left tied to 0, and the board was then read
  // as "DISK on, POWER on" -- which was the FRAMEWORK lighting POWER, not us.
  //
  //   LED_DISK  = snd_ready       -> the sound ROM stream completed
  //   LED_POWER = v60_cmd_seen    -> the V60 has pushed a byte into the USART
  //   LED_USER  = snd_mainloop_seen -> the sound 68000 reached MAME's main loop
  //
  // v60_cmd_seen is the one that matters. The uPD71051C path (snd_tx_data /
  // snd_tx_stb) was deleted by that same revert and restored by hand; if the
  // game never commands the board, nothing downstream can make a sound and no
  // amount of gain will help. It costs two flip-flops and no M10K, which the
  // UART monitor did not -- that needed 8 blocks against 553/553.
  // LED_USER IS THE ROM LOADER'S OVERFLOW FLAG NOW, and it answers the only
  // question the board is currently asking.
  //
  // The load is INTERMITTENT on hardware -- the same core and the same MRA
  // sometimes stall at 0%, sometimes load with no 3D, and sometimes work. One
  // cause explains all three: m1_rom_loader DROPS a word silently when its FIFO
  // is full --
  //
  //     if (fifo_full) overflow <= 1'b1;   else <write it>
  //
  // -- so the stream arrives with holes in it and the load reports success. The
  // symptom then depends only on WHERE the hole lands: in the boot vector it is
  // dead at 0%, in the polygon ROM it is a game with no 3D, in padding it is a
  // game that works.
  //
  // `overflow` existed and was wired to NOTHING visible, so this was invisible
  // on hardware. The same fault was found once before at FIFO_DEPTH 8 /
  // WAIT_MARGIN 6 and fixed to 512/256, and the note there says exactly what it
  // looks like: "a ROM with holes in it, reported as a successful load".
  //
  // STICKY, because a dropped word is a single cycle and the download is
  // seconds long. If this LED comes on at any point, the ROM in SDRAM is not
  // the ROM on the card and nothing downstream is worth debugging.
  reg ldr_overflow_seen;
  always @(posedge clk_sys or negedge rst_n) begin
    if (!rst_n)           ldr_overflow_seen <= 1'b0;
    else if (ldr_overflow) ldr_overflow_seen <= 1'b1;
  end
  assign LED_USER  = ldr_overflow_seen;

endmodule
