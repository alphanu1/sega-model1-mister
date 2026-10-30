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
// NETMERC'S HEAD TRACKER, FROM THE LEFT STICK.
//
// The cabinet is a VR game: a Polhemus tracker on the player's headset
// supplies six int16 at DPRAM 0x80-0x8b, little-endian, and the V60 reads them
// as the camera's pose (MAME declares the tracker's i386SX board and does not
// run it). Measured in MAME 0.289 by writing each word during play
// (docs/findings.md 2026-10-29, "NetMerc's head look"):
//
//   word  DPRAM      what                     forward     sign
//   0-2   0x80-0x85  head position            0, 0, 0     moves the eye off the body
//   3     0x86-0x87  YAW                      12868       + looks RIGHT
//   4     0x88-0x89  roll                     25736       + rolls the view
//   5     0x8a-0x8b  PITCH                    12868       + looks DOWN
//
// The angles are radians x 8192 (Q3.13): 12868 is pi/2, 25736 is pi, which is
// MAME's machine_reset seed. The game applies the pose as it reads it - a step
// shows complete on the next read, no smoothing - and yaw and pitch combine as
// a head turns: the horizon stays level with both offset.
//
// THE STICK IS AN ABSOLUTE HEAD POSITION, NOT A RATE. Released is looking
// straight ahead. A dead band of +-15 counts (the core's other sticks use the
// same) is subtracted, not snapped, so the look starts from zero at its edge
// rather than jumping 12 degrees; the remaining 112 counts span
//
//   yaw    +-112 x 115 = +-12,880  (+-90.1 degrees)
//   pitch  +-112 x  57 = +- 6,384  (+-44.6 degrees)
//
// Ninety degrees of yaw turns the view fully sideways and 45 of pitch looks
// down onto the player's own platform or up into open sky; both read right in
// MAME. Stick right looks right; stick up (hps_io's negative Y) looks up
// unless `mode` is 1, which inverts Y. Mode 2 or 3 holds the pose forward,
// which is what this core did before: the stick is then free to aim the gun.
//
// NO WORD IS EVER READ HALF-WRITTEN, and that is the design of the writer.
// The I/O side of the DPRAM is a byte port, so a word cannot be written in one
// cycle; what keeps the V60 from reading a mixture is WHEN the bytes go in:
//
// - The game reads all twelve bytes in one ascending block, 0x80 first and
//   0x8b last, low byte before high (MAME read tap: every second frame, the
//   twelve within ~6 us). `busy` is set by the V60 reading any of 0x80-0x8a
//   and cleared by its reading 0x8b, so a block that an interrupt splits still
//   holds the writer off until it is finished. A block abandoned part-way
//   releases it after 2^TO_W cycles.
// - A rewrite starts only when no block is in progress and no read of the
//   twelve is on the bus that cycle. It then writes all twelve, ascending, one
//   byte a cycle, and never in a cycle with one of the twelve on the V60's bus
//   (a cycle is also lost to a Z80 write or a V60 write). A read that arrives
//   before byte 0 is written abandons the burst until the block is done. Once
//   byte 0 is in, the V60 cannot overtake: it needs an instruction for each
//   byte it reads, at least several cycles, and the burst gains a byte in
//   every one of them, so any byte it reads is already new.
// - Every byte of a burst comes from one snapshot of the pose, taken as the
//   burst starts. So a block the game reads is one pose throughout.
//
// The rewrite runs every 2^TICK_W cycles (1.1 ms at 29.49 MHz), so the pose
// the game reads is never more than about a millisecond behind the stick,
// whenever in the frame it reads. While `seed` (the V60 and the Z80 held in
// reset) it rewrites continuously, as the reset seed it replaces did.
//
// THE Z80 GOES FIRST on the shared write port: its z_we is a one-cycle pulse
// with no retry, so the writer never drives a cycle in which it is high. A V60
// write takes the port from either (io_ack low); the writer holds its byte
// until io_ack says it landed.
//
// THE STICK IS IN clk_sys's DOMAIN. It is synchronised and taken only when two
// consecutive samples agree, so a sample caught between two values - bits
// from each - is never used.

`timescale 1ns/1ps

module m1_hmd_pose #(
  parameter int TICK_W = 15,   // a rewrite every 2^TICK_W cycles
  parameter int TO_W   = 20    // a block read abandoned this long stops holding writes off
) (
  input  logic        clk,
  input  logic        en,          // NetMerc (game id 4)
  input  logic        seed,        // V60 and Z80 in reset: rewrite continuously
  input  logic [15:0] stick,       // hps_io left stick: [7:0] X, [15:8] Y, signed (clk_sys)
  input  logic [1:0]  mode,        // 0 look, 1 look with Y inverted, 2-3 fixed forward

  // The V60's side of the DPRAM, observed only.
  input  logic        v60_rd,      // a V60 read of the DPRAM is on the bus
  input  logic [10:0] v60_idx,     // its byte index

  // The I/O side's write port, shared with the Z80.
  input  logic        z_we,        // the Z80 writes this cycle: it has the port
  input  logic        io_ack,      // the RAM took this cycle's write
  output logic        we,
  output logic [10:0] addr,
  output logic [7:0]  din,

  output logic [15:0] dbg_yaw,     // the pose being presented
  output logic [15:0] dbg_pitch
);

  localparam logic [15:0] FWD  = 16'd12868;   // pi/2 x 8192
  localparam logic [15:0] ROLL = 16'd25736;   // pi   x 8192

  // ------------------------------------------------------------ the stick
  // The OSD's mode comes from clk_sys too; two flops, it changes once a menu.
  logic [15:0] s_m, s_a, s_q;
  logic [1:0]  m_m, m_q;
  always_ff @(posedge clk) begin
    s_m <= stick;
    s_a <= s_m;
    if (s_a == s_m) s_q <= s_a;
    m_m <= mode;
    m_q <= m_m;
  end

  // Dead band subtracted, then clamped to +-112.
  function automatic logic signed [7:0] dz(input logic [7:0] v);
    logic signed [8:0] t;
    t = $signed({v[7], v});
    if (t > 9'sd15)       dz = 8'(t - 9'sd15);                          // 127 -> 112
    else if (t < -9'sd15) dz = (t == -9'sd128) ? -8'sd112 : 8'(t + 9'sd15);
    else                  dz = 8'sd0;
  endfunction

  wire               look = en && !m_q[1];
  wire signed [7:0]  sx   = look ? dz(s_q[7:0])  : 8'sd0;
  wire signed [7:0]  sy0  = look ? dz(s_q[15:8]) : 8'sd0;
  wire signed [7:0]  sy   = m_q[0] ? -sy0 : sy0;      // +-112: negation cannot overflow
  wire signed [15:0] yaw_off   = 16'(sx * 16'sd115);
  wire signed [15:0] pitch_off = 16'(sy * 16'sd57);
  logic [15:0] yaw_q, pitch_q;
  always_ff @(posedge clk) begin
    yaw_q   <= FWD + yaw_off;
    pitch_q <= FWD + pitch_off;
  end
  assign dbg_yaw   = yaw_q;
  assign dbg_pitch = pitch_q;

  // ------------------------------------------------- the game's block read
  wire pose_rd = v60_rd && (v60_idx >= 11'h080) && (v60_idx <= 11'h08b);
  logic            busy;
  logic [TO_W-1:0] to_cnt;
  always_ff @(posedge clk) begin
    if (seed) begin
      busy <= 1'b0; to_cnt <= '0;
    end else if (pose_rd) begin
      busy <= (v60_idx != 11'h08b); to_cnt <= '0;
    end else if (busy) begin
      to_cnt <= to_cnt + 1'b1;
      if (&to_cnt) busy <= 1'b0;
    end
  end

  // ------------------------------------------------------------ the writer
  logic [TICK_W-1:0] tick;
  logic              pend, run;
  logic [3:0]        j;
  logic [15:0]       w_yaw, w_pitch;

  wire start = !run && (seed || (pend && !busy && !pose_rd));
  // NEVER IN A CYCLE WITH ONE OF THE TWELVE ON THE V60's BUS. The V60's read
  // is captured by the RAM at the end of the first cycle its request is up
  // (m1_main dispatches it to B_LOCAL on that edge and takes dpram_q in the
  // next), so a write on that same edge to the same byte would hand it the
  // old value - or, M10K mixed-port, an undefined one - with the next byte
  // already new. Keeping off the bus while a read is on it rules that edge
  // out for any byte. A read that arrives before byte 0 is in abandons the
  // burst: that block is then read whole from the previous burst, and
  // `busy` restarts this one after it.
  assign we   = en && run && !z_we && !pose_rd;
  assign addr = {7'h08, j};
  always_comb begin
    case (j)
      4'd6:    din = w_yaw[7:0];
      4'd7:    din = w_yaw[15:8];
      4'd8:    din = ROLL[7:0];
      4'd9:    din = ROLL[15:8];
      4'd10:   din = w_pitch[7:0];
      4'd11:   din = w_pitch[15:8];
      default: din = 8'h00;           // position 0, 0, 0
    endcase
  end

  always_ff @(posedge clk) begin
    tick <= tick + 1'b1;
    if (&tick) pend <= 1'b1;
    if (!en) begin
      run <= 1'b0; pend <= 1'b0; j <= 4'd0;
    end else if (start) begin
      run <= 1'b1; pend <= 1'b0; j <= 4'd0;
      w_yaw <= yaw_q; w_pitch <= pitch_q;
    end else if (run && j == 4'd0 && pose_rd && !seed) begin
      run <= 1'b0; pend <= 1'b1;                    // read came first: wait for the block
    end else if (we && io_ack) begin
      j <= j + 4'd1;
      if (j == 4'd11) run <= 1'b0;
    end
  end

endmodule
