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
// Virtua Racing / Virtua Formula's steering wheel and two pedals, from a pad
// or from a real wheel: the three MSM6253 channels WHEEL, ACCEL and BRAKE.
//
// THE OSD's "Analog control", AS THE MODEL 2 CORE HAS IT (sega-model2-mister
// rtl/io/m2_cab_inputs.sv, its study R958, itself modelled on the Analog
// control option of Jotego's OutRun core). A USB wheel reports its rim on the
// left stick's X and each pedal on an axis of its own, which the pad layout -
// both pedals on the right stick's Y, one per direction - cannot read: on a
// wheel neither pedal worked.
//
//   0 Standard   exactly what this core did before: wheel from the left X,
//                pedals split by sign from the right stick's Y, `Pedals` (O[11])
//                choosing which half accelerates. Bit for bit the old logic -
//                tb_m1_drive_inputs checks it against a frozen copy for every
//                input combination.
//   1 Wheel A    pedals on two axes: accelerator on the left stick's Y, brake
//                on the right stick's Y, each read from its UP half (0 to -127
//                is released to full; the down half reads released).
//   2 Wheel B    pedals on the full travel of an axis: accelerator on the left
//                Y, brake on the right X, -127 released and +127 full.
//   3            reads as Standard (the OSD cannot select it).
//
// NO DEAD ZONE ANYWHERE ON THE WHEEL. Standard never had one on Virtua Racing's
// wheel - the left X goes to the ADC at full scale - and the wheel modes take
// the same path: a wheel's first degrees are steering, not noise (R958). The
// d-pad still wins at full lock in every mode, as on the cabinet a digital
// input has no travel; Model 2's d-pad "ramp" reaches lock in ~1.2 ms, under a
// tenth of a frame, so this core's instant lock is the same thing to a game
// that samples once a frame and is kept rather than changed.
//
// THE RANGE IS VIRTUA RACING's, NOT DAYTONA's. Model 2's channels are
// PORT_MINMAX(0x20,0xe0) and its formulas scale into that. model1.cpp declares
// WHEEL as a full 0x00..0xff paddle centred at 0x80 and both pedals
// PORT_MINMAX(1,0xff), released at 0x01 (a pedal resting at 0x00 is a car that
// will not move, docs/io-board.md). So a pedal's 7-bit travel lands on 0x01..
// 0xff exactly as Standard's does, {travel, 1}, and the buttons still give
// 0xff. `Pedals` swaps accelerator and brake in the wheel modes too.

`timescale 1ns/1ps

module m1_drive_inputs (
  input  logic [1:0]  mode,          // O[15:14] Analog control
  input  logic        swap,          // O[11] Pedals
  input  logic        steer_l,       // d-pad
  input  logic        steer_r,
  input  logic        accel_b,       // buttons, full travel
  input  logic        brake_b,
  input  logic [15:0] lstick,        // hps_io: [7:0] X, [15:8] Y, signed
  input  logic [15:0] rstick,
  output logic [7:0]  wheel,
  output logic [7:0]  accel,
  output logic [7:0]  brake
);

  wire whl_a = (mode == 2'd1);
  wire whl_b = (mode == 2'd2);

  // ---- the wheel: the same in every mode. hps_io's signed axis to the ADC's
  // unsigned one by inverting the sign bit, centre 0 -> 0x80.
  wire [7:0] wheel_stick = {~lstick[7], lstick[6:0]};
  assign wheel = steer_l ? 8'h00 : steer_r ? 8'hff : wheel_stick;

  // ---- Standard: both pedals on the right stick's Y, split by sign
  //
  // Moved here from Model1.sv with the logic, where it read:
  //
  //   PEDALS ARE ANALOGUE NOW, with the buttons still live.
  //
  //   They used to be buttons only, on the reasoning that hps_io's analog ports
  //   are two-axis sticks with no travel to read for a pedal. That was wrong in
  //   practice: a pad's triggers reach the core through an analog port, and a
  //   racing game with on/off pedals is a different game - you cannot hold a
  //   line through a corner without partial throttle.
  //
  //   MiSTer has NO dedicated trigger signal - hps_io offers only the two sticks,
  //   the paddles and the spinners. An arrangement that read one axis per pedal
  //   was tried on the assumption a player would bind LT and RT to them; it put
  //   the accelerator on the LEFT stick's Y and the brake on the RIGHT stick's X,
  //   so steering with the left stick moved the throttle at the same time.
  //
  //   BOTH PEDALS ON THE RIGHT STICK'S Y AXIS, one per direction.
  //
  //   One axis, split by sign: push up to accelerate, pull down to brake, exactly
  //   as a single pedal axis behaves. That frees the LEFT stick entirely for
  //   steering, which is the only thing it should have been doing.
  //
  //   WHICH HALF IS WHICH DEPENDS ON THE PAD, and no amount of reasoning settles
  //   it - axis polarity is not standardised. `Pedals` in the OSD swaps them, so
  //   a pad that reports the opposite sign is one setting away rather than a
  //   rebuild.
  //
  //   Idle is 0x01 and full 0xff, MAME's PORT_MINMAX(1,0xff): a pedal resting at
  //   0x00 is a car that will not move, measured in docs/io-board.md. Centred is
  //   magnitude zero, so both read 0x01 and neither is applied. The buttons stay
  //   live and the larger of the two wins.

  wire signed [7:0] pedal_ax  = rstick[15:8];
  wire [6:0] pedal_mag = pedal_ax[7] ? (~pedal_ax[6:0] + 7'd1) : pedal_ax[6:0];
  wire [7:0] pedal_an  = {pedal_mag, 1'b1};
  wire       pedal_up  = swap ? ~pedal_ax[7] : pedal_ax[7];
  wire [7:0] std_accel = pedal_up ? pedal_an : 8'h01;
  wire [7:0] std_brake = pedal_up ? 8'h01    : pedal_an;

  // ---- the wheel modes: one axis a pedal
  // Up half: -128 and -127 are both full travel (127); 0 and below-centre read
  // released. Full travel: -128 is released (a pedal axis at rest), then
  // (v + 127) / 2, so -127 -> 0 and +127 -> 127.
  function automatic [6:0] whl_up(input logic [7:0] v);
    whl_up = (v == 8'h80) ? 7'd127 : v[7] ? 7'(~v[6:0] + 7'd1) : 7'd0;
  endfunction
  function automatic [6:0] whl_full(input logic [7:0] v);
    logic [7:0] t;
    t = v + 8'd127;
    whl_full = (v == 8'h80) ? 7'd0 : t[7:1];
  endfunction

  wire [6:0] whl_acc = whl_b ? whl_full(lstick[15:8]) : whl_up(lstick[15:8]);
  wire [6:0] whl_brk = whl_b ? whl_full(rstick[7:0])  : whl_up(rstick[15:8]);
  wire [7:0] whl_accel = swap ? {whl_brk, 1'b1} : {whl_acc, 1'b1};
  wire [7:0] whl_brake = swap ? {whl_acc, 1'b1} : {whl_brk, 1'b1};

  wire [7:0] an_accel = (whl_a | whl_b) ? whl_accel : std_accel;
  wire [7:0] an_brake = (whl_a | whl_b) ? whl_brake : std_brake;

  // The buttons give full travel; otherwise the axis. The old Model1.sv also
  // clamped the axis to at least 0x01, which can never act: every value above
  // has bit 0 set. The bench's frozen copy keeps that clamp and the two agree
  // for every input, so it is dropped here rather than built.
  assign accel = accel_b ? 8'hff : an_accel;
  assign brake = brake_b ? 8'hff : an_brake;

endmodule
