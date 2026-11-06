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
// THE PAD'S BUTTONS TO THE BOARD'S IN.0 / IN.1 / IN.2, PER GAME (issue #2).
//
// MiSTer names joystick bits from 4 upward after the MRA's <buttons names>.
// Until 2026-11-05 every game had the same twelve positions - eight game
// buttons, then Start, Coin, Service, Test, Coin 2 - so Virtua Fighter, Star
// Wars and Wing War listed "Unused 4".."Unused 8" to push Start and Coin to
// bits 12 and 13. Now each game has its own layout, keyed on the MRA's game
// id as the Model 2 core keys its own, and each MRA lists only real buttons:
//
//   joy bit   4      5       6        7        8        9      10     11     12     13     14     15     16
//   VR / VFm  Accel  Brake   Shift Up Shift Dn VR1      VR2    VR3    VR4    Start  Coin   Svc    Test   Coin 2
//   VF        Punch  Kick    Guard    Start    Coin     Svc    Test   Coin 2
//   SWA       Fire   Thumb   Button 3 Thr Up   Thr Down Start  Coin   Svc    Test   Coin 2
//   Wing War  M.Gun  Missile Smoke    View 1   View 2   View 3 View 4 Start  Coin   Svc    Test   Coin 2
//   NetMerc   Trigger Thumb  MVD Holder Coin   Svc      Test
//
// The first three positions are unchanged for every game, so everything the
// analogue paths take from joy0[4] and joy0[5] (the pedal buttons) is too.
// Player 2 (Virtua Fighter, Star Wars' gunner) uses the same layout on the
// second pad, so its Start is at the same position as player 1's.
//
// The bit order inside each byte is MAME 0.289's INPUT_PORTS (model1.cpp),
// active low throughout. tb_m1_pad_map checks every named button of every
// game against the previous fixed layout and against MAME's bit.

`timescale 1ns/1ps

module m1_pad_map (
  input  logic [6:0]  game,      // 0 VR/VFormula, 1 VF, 2 SWA, 3 Wing War, 4 NetMerc
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] joy0,
  input  logic [31:0] joy1,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic        osd_test,
  input  logic        osd_service,
  output logic [7:0]  in0,
  output logic [7:0]  in1,
  output logic [7:0]  in2,
  output logic        thr_up,    // Star Wars' throttle buttons (m1_swa_throttle)
  output logic        thr_dn
);
  wire p1_right = joy0[0], p1_left = joy0[1], p1_down = joy0[2], p1_up = joy0[3];
  wire p2_right = joy1[0], p2_left = joy1[1], p2_down = joy1[2], p2_up = joy1[3];

  logic start, start2, coin, coin2, svc, tst, v1, v2, v3, v4;
  always_comb begin
    // Virtua Racing and Virtua Formula, and any id this does not know
    start = joy0[12]; coin = joy0[13]; svc = joy0[14]; tst = joy0[15]; coin2 = joy0[16];
    start2 = 1'b0;
    v1 = joy0[8]; v2 = joy0[9]; v3 = joy0[10]; v4 = joy0[11];
    thr_up = 1'b0; thr_dn = 1'b0;
    case (game)
      7'd1: begin   // Virtua Fighter
        start = joy0[7]; coin = joy0[8]; svc = joy0[9]; tst = joy0[10]; coin2 = joy0[11];
        start2 = joy1[7];
        v1 = 1'b0; v2 = 1'b0; v3 = 1'b0; v4 = 1'b0;
      end
      7'd2: begin   // Star Wars Arcade
        thr_up = joy0[7]; thr_dn = joy0[8];
        start = joy0[9]; coin = joy0[10]; svc = joy0[11]; tst = joy0[12]; coin2 = joy0[13];
        start2 = joy1[9];
        v1 = 1'b0; v2 = 1'b0; v3 = 1'b0; v4 = 1'b0;
      end
      7'd3: begin   // Wing War: the four view buttons follow the weapons
        v1 = joy0[7]; v2 = joy0[8]; v3 = joy0[9]; v4 = joy0[10];
        start = joy0[11]; coin = joy0[12]; svc = joy0[13]; tst = joy0[14]; coin2 = joy0[15];
      end
      7'd4: begin   // NetMerc: no Start and no second chute (IN.0 0xf2 unused)
        coin = joy0[7]; svc = joy0[8]; tst = joy0[9];
        start = 1'b0; coin2 = 1'b0;
        v1 = 1'b0; v2 = 1'b0; v3 = 1'b0; v4 = 1'b0;
      end
      default: ;
    endcase
    svc = svc | osd_service;
    tst = tst | osd_test;
  end

  always_comb begin
    case (game)
      7'd1: begin   // INPUT_PORTS_START( vf )
        in0 = ~{2'b00, start2, start, svc, tst, coin2, coin};
        in1 = ~{p1_left, p1_right, p1_up, p1_down, 1'b0, joy0[6], joy0[5], joy0[4]};
        in2 = ~{p2_left, p2_right, p2_up, p2_down, 1'b0, joy1[6], joy1[5], joy1[4]};
      end
      7'd2: begin   // ( swa ): the two players' buttons interleaved on IN.1
        in0 = ~{2'b00, start2, start, svc, tst, coin2, coin};
        in1 = ~{3'b000, joy0[6], joy1[5], joy1[4], joy0[5], joy0[4]};
        in2 = 8'hff;
      end
      7'd3: begin   // ( wingwar ): IN.0 is VR's, IN.1 the weapons and View 4
        in0 = ~{v3, v2, v1, start, svc, tst, coin2, coin};
        in1 = ~{1'b0, joy0[6], joy0[5], joy0[4], 3'b000, v4};
        in2 = 8'hff;
      end
      7'd4: begin   // ( netmerc ): Trigger, Thumb, MVD Holder on IN.1 0-2
        in0 = ~{4'b0000, svc, tst, 1'b0, coin};
        in1 = ~{5'b00000, joy0[6], joy0[5], joy0[4]};
        in2 = 8'hff;
      end
      default: begin   // ( vr ): the gears on the d-pad's up/down as well
        in0 = ~{v3, v2, v1, start, svc, tst, coin2, coin};
        in1 = ~{2'b00, joy0[6] | p1_up, joy0[7] | p1_down, 3'b000, v4};
        in2 = 8'hff;
      end
    endcase
  end
endmodule
