// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
//
// THE SOUND BOARD'S COUNTERS, ONCE A SECOND, OVER THE PRINTF UART.
//
// The board reaches the hardware with DISK and POWER lit and USER dark: the
// ROMs load, the MULTIPCMs are fetching sample data out of SDRAM, and the mix
// never exceeds 16. Every stage between those two facts is invisible, and
// three LEDs cannot separate them. m2_sound_board already exposes the
// counters; not one of them was connected.
//
// This exists because the alternative was another round of guessing. It is
// deliberately TINY -- no line buffer, no field names longer than a letter,
// no m1_speed_report -- because M10K is at 553/553 and ALM has 557 spare.
// UART_REPORT is 0 for exactly that reason, so this shares the idle line.
//
// What each field answers, in the order the signal travels:
//
//   r  bytes the V60 has sent through the uPD71051C. ZERO means the game is
//      not commanding the board at all and nothing downstream matters.
//   i  68000 instructions retired, low 16 bits. ZERO means it is not running.
//   y  YM3438 register writes. The FM is stubbed, but the WRITES still count,
//      so this says the driver is running its sequencer.
//   p  MULTIPCM register writes. ZERO with i moving means the driver never
//      keys a voice -- a command-path fault, not an audio one.
//   s  sample slots the first MULTIPCM has produced, low 16 bits. Two readings
//      a second apart give the rate against the chip's own 44,643 Hz.
//   v  the rate stage's buffer level, u its underruns.
//   m  PEAK |snd_l| since the last line, which is the thing the USER LED could
//      only say "under 16" about.

`timescale 1ns/1ps

module m1_snd_report #(
  parameter int unsigned CLK_HZ = 80_000_000,
  parameter int unsigned BAUD   = 115_200
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic [15:0] v60_bytes,      // r
  input  logic [15:0] insns,          // i
  input  logic [15:0] ym_writes,      // y
  input  logic [15:0] pcm_writes,     // p
  input  logic [15:0] pcm_samples,    // s
  input  logic  [7:0] pcm_level,      // v
  input  logic [15:0] pcm_under,      // u
  input  logic signed [15:0] snd_l,   // m, as a running peak

  output logic        tx
);

  // ---- the peak, reset when a line is sent so each line is its own window
  logic [15:0] mag, peak;
  always_comb mag = snd_l[15] ? (~snd_l + 16'd1) : snd_l;

  // ---- one line a second
  localparam int unsigned TICK = CLK_HZ;
  logic [31:0] div;
  logic        fire;

  // ---- the line, emitted a nibble at a time straight out of a mux
  //
  // "r=XXXX i=XXXX y=XXXX p=XXXX s=XXXX v=XX u=XXXX m=XXXX\r\n" is 55 bytes:
  // 53 of content, indices 0..52, then CR at 53 and LF at 54. It was 54 here,
  // which put CR on top of the LAST NIBBLE of the m field -- the bench saw
  // "m=012" for a peak of 0x012c.
  // A ROM would be an M10K and there are none; a case is LUTs, of which there
  // are 557 ALM worth.
  localparam int unsigned NCH = 55;
  logic [5:0]  idx;
  logic        busy;
  logic [7:0]  ch;
  logic [3:0]  nib;
  logic [15:0] cur;

  // Which value each hex position belongs to, and which nibble of it.
  always_comb begin
    case (idx)
      6'd2,  6'd3,  6'd4,  6'd5 : cur = v60_bytes;
      6'd9,  6'd10, 6'd11, 6'd12: cur = insns;
      6'd16, 6'd17, 6'd18, 6'd19: cur = ym_writes;
      6'd23, 6'd24, 6'd25, 6'd26: cur = pcm_writes;
      6'd30, 6'd31, 6'd32, 6'd33: cur = pcm_samples;
      6'd37, 6'd38             : cur = {8'd0, pcm_level};
      6'd42, 6'd43, 6'd44, 6'd45: cur = pcm_under;
      default                  : cur = peak;
    endcase
  end

  always_comb begin
    case (idx)
      6'd2,  6'd9,  6'd16, 6'd23, 6'd30, 6'd42, 6'd49: nib = cur[15:12];
      6'd3,  6'd10, 6'd17, 6'd24, 6'd31, 6'd43, 6'd50: nib = cur[11:8];
      6'd4,  6'd11, 6'd18, 6'd25, 6'd32, 6'd37, 6'd44, 6'd51: nib = cur[7:4];
      default                                         : nib = cur[3:0];
    endcase
  end

  wire [7:0] hex = (nib < 4'd10) ? (8'h30 + {4'd0, nib}) : (8'h57 + {4'd0, nib});

  always_comb begin
    case (idx)
      6'd0 : ch = "r";  6'd1 : ch = "=";
      6'd6 : ch = " ";  6'd7 : ch = "i";  6'd8 : ch = "=";
      6'd13: ch = " ";  6'd14: ch = "y";  6'd15: ch = "=";
      6'd20: ch = " ";  6'd21: ch = "p";  6'd22: ch = "=";
      6'd27: ch = " ";  6'd28: ch = "s";  6'd29: ch = "=";
      6'd34: ch = " ";  6'd35: ch = "v";  6'd36: ch = "=";
      6'd39: ch = " ";  6'd40: ch = "u";  6'd41: ch = "=";
      6'd46: ch = " ";  6'd47: ch = "m";  6'd48: ch = "=";
      6'd53: ch = 8'h0d; 6'd54: ch = 8'h0a;
      default: ch = hex;
    endcase
  end

  // THE CHARACTER IS REGISTERED WITH THE STROBE, not read from idx when the
  // strobe lands. `wr` is a register and `ch` is combinational on `idx`, so
  // taking ch at the FIFO push meant taking it after idx had already advanced:
  // every byte was the next position's, which dropped the first character of
  // the line and the last. tb_m1_snd_report caught it -- the fields were all
  // correct and the ends were missing, which reads like a UART fault.
  // THE PUSH IS COMBINATIONAL, and it has to be.
  //
  // It was a REGISTER, decided from `full` one cycle earlier. With a 64-entry
  // FIFO that never mattered -- a 55-byte line could not fill it -- but at
  // depth 8 the lag pushed one byte past full on every fill and the line came
  // out with characters missing. Deciding and pushing in the same cycle means
  // `full` is never stale, and `ch` is combinational on `idx` so the byte and
  // the strobe always agree.
  wire        full;
  wire        push = busy && !full;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div <= '0; fire <= 1'b0; idx <= '0; busy <= 1'b0;
      peak <= '0;
    end else begin
      fire <= 1'b0;

      // The peak is a running maximum, cleared as a line STARTS so the window
      // is the second just gone rather than an all-time high that never falls.
      if (mag > peak) peak <= mag;

      if (div == TICK - 1) begin div <= '0; fire <= 1'b1; end
      else                      div <= div + 32'd1;

      if (!busy) begin
        if (fire) begin busy <= 1'b1; idx <= '0; end
      end else if (push) begin
        if (idx == 6'(NCH - 1)) begin
          busy <= 1'b0;
          idx  <= '0;
          peak <= mag;          // start the next window at the current sample
        end else idx <= idx + 6'd1;
      end
    end
  end

  // DEPTH 8, AND THAT IS A FIT DECISION. At 64 this FIFO is 64 deep by 8 wide,
  // which Quartus maps as EIGHT M10K blocks -- one per bit -- for 512 bits of
  // storage. M10K is at 553/553, so those eight tipped it to 561 and the
  // overflow spilled into logic: ALM stayed at 99% and the fit failed on LABs.
  //
  // Nothing here needs depth. The formatter checks `full` before every push and
  // simply waits, and a 55-byte line once a second against 11,520 bytes a
  // second of line rate has four orders of magnitude of slack. Eight entries
  // is small enough that it cannot be inferred as RAM at all.
  m1_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .DEPTH(8)) u_tx (
    .clk(clk), .rst_n(rst_n),
    /* verilator lint_off PINCONNECTEMPTY */
    .wr(push), .din(ch), .full(full), .overflow(),
    /* verilator lint_on PINCONNECTEMPTY */
    .tx(tx)
  );

endmodule
