// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// A YM3438 WITH THE FM SYNTHESISER REMOVED AND THE TIMERS KEPT.
//
// WHY THIS EXISTS
//
// The sound board does not fit: measured at 43,683 ALM against a 41,910-ALM
// device, 1,773 over. jt12 is 702 ALM and 10 M10K of that, and Ben's call is
// that sound effects matter more than music - so the FM operators go and the
// PCM path stays.
//
// THE TIMERS CANNOT GO WITH THEM, and that is the whole subtlety. segam1audio
// wires the YM's timer to the 68000's IRQ4 (model1.cpp) and the sound program
// sequences on it. A board with no timer interrupt does not just lose music -
// it stops sequencing, which would take the PCM triggers with it. m2_sound_
// board's own header says as much: "a board that never sees its timer
// interrupt will not sequence music, whatever the UART does."
//
// So this keeps exactly three things:
//
//   - registers 0x24-0x27, the two timer values and the control byte
//   - jt12_timers, UPSTREAM'S, because the overflow and flag semantics are
//     fiddly and already right there
//   - the status byte the 68000 polls: busy, and the two overflow flags
//
// and discards every FM register write, which is most of them.
//
// THE TICK RATE IS THE THING TO GET RIGHT. jt12 drives the timers from `zero`,
// a one-cycle pulse once per sample period, which the FM slot rotator produces
// at one per 24 operator slots. With the rotator gone that has to be generated
// here, and it must keep the same rate or every tempo in the game is wrong in
// proportion. clk_en comes from jt12_div at the YM2612's 1/6 prescaler, and 24
// of those is one sample - so the divide is exactly the rotator's.
//
// WHAT IS LOST: all six FM channels. The game's music will not play. The DAC
// channel (register 0x2A) is FM-side too and goes with it. If music is wanted
// later, this module is a drop-in swap back to jt12 - the port list matches.

`timescale 1ns/1ps

module m1_ym_timer (
  input  logic        rst,
  input  logic        clk,
  input  logic        cen,

  input  logic  [7:0] din,
  input  logic  [1:0] addr,
  input  logic        cs_n,
  input  logic        wr_n,

  output logic  [7:0] dout,
  output logic        irq_n,

  // Kept so the instantiation matches jt12's and the swap back is a one-line
  // change. Silent, and the sample tick still runs because the mixer downstream
  // uses it for pacing.
  input  logic        en_hifi_pcm,
  output logic signed [15:0] snd_right,
  output logic signed [15:0] snd_left,
  output logic        snd_sample
);

  // ------------------------------------------------------- the prescaler
  // div_setting 2'b10 is the YM2612/YM3438 reset value: FM 1/6.
  wire clk_en;
  jt12_div u_div (
    .rst(rst), .clk(clk), .cen(cen), .div_setting(2'b10),
    .clk_en(clk_en), .clk_en_2(), .clk_en_ssg(),
    .clk_en_666(), .clk_en_111(), .clk_en_55()
  );

  // One sample per 24 operator slots, which is what the FM rotator's `zero`
  // was. Nothing else here needs the slot position.
  logic [4:0] slot;
  logic       zero;
  always_ff @(posedge clk) begin
    if (rst) begin slot <= 5'd0; zero <= 1'b0; end
    else if (clk_en) begin
      zero <= (slot == 5'd23);
      slot <= (slot == 5'd23) ? 5'd0 : slot + 5'd1;
    end else zero <= 1'b0;
  end

  // ------------------------------------------------- registers 0x24..0x27
  // Address 0 latches a register number, address 1 writes it. Part 2
  // (addresses 2 and 3) holds no timer register, so it is decoded and dropped.
  logic [7:0] reg_sel;
  logic [9:0] value_A;
  logic [7:0] value_B;
  logic       load_A, load_B, enable_irq_A, enable_irq_B;
  logic       clr_flag_A, clr_flag_B;
  logic       wr_d;
  wire        wr = !cs_n && !wr_n;
  wire        wr_edge = wr && !wr_d;

  // The 68000 polls bit 7 and will not issue the next write until it clears.
  // A real chip is busy for 32 internal cycles after a data write; anything of
  // that order works, and zero does not - the program would run ahead of its
  // own register writes.
  logic [5:0] busy_cnt;

  always_ff @(posedge clk) begin
    if (rst) begin
      reg_sel <= 8'd0; value_A <= 10'd0; value_B <= 8'd0;
      load_A <= 1'b0; load_B <= 1'b0;
      enable_irq_A <= 1'b0; enable_irq_B <= 1'b0;
      clr_flag_A <= 1'b0; clr_flag_B <= 1'b0;
      wr_d <= 1'b0; busy_cnt <= 6'd0;
    end else begin
      wr_d       <= wr;
      clr_flag_A <= 1'b0;          // one-cycle strobes
      clr_flag_B <= 1'b0;
      if (busy_cnt != 6'd0) busy_cnt <= busy_cnt - 6'd1;

      if (wr_edge) begin
        if (!addr[0]) reg_sel <= din;          // register select, either part
        else if (!addr[1]) begin               // part 1 data: the timers live here
          busy_cnt <= 6'd32;
          case (reg_sel)
            8'h24: value_A <= {din, value_A[1:0]};
            8'h25: value_A <= {value_A[9:2], din[1:0]};
            8'h26: value_B <= din;
            8'h27: begin
              load_A       <= din[0];
              load_B       <= din[1];
              enable_irq_A <= din[2];
              enable_irq_B <= din[3];
              clr_flag_A   <= din[4];
              clr_flag_B   <= din[5];
            end
            default: ;                          // every FM register, discarded
          endcase
        end else busy_cnt <= 6'd32;             // part 2 data: also discarded
      end
    end
  end

  // ------------------------------------------------------------ the timers
  wire flag_A, flag_B;
  jt12_timers u_timers (
    .clk(clk), .clk_en(clk_en), .rst(rst), .zero(zero),
    .value_A(value_A), .value_B(value_B),
    .load_A(load_A), .load_B(load_B),
    .enable_irq_A(enable_irq_A), .enable_irq_B(enable_irq_B),
    .clr_flag_A(clr_flag_A), .clr_flag_B(clr_flag_B),
    .flag_A(flag_A), .flag_B(flag_B), .overflow_A(), .irq_n(irq_n)
  );

  assign dout       = {busy_cnt != 6'd0, 5'b00000, flag_B, flag_A};
  assign snd_left   = 16'sd0;
  assign snd_right  = 16'sd0;
  assign snd_sample = zero;

endmodule
