// MICROBENCH: binary vs one-hot state in a subroutine-style FSM.
//
// Quartus extracts TEN state machines in Model 2's i960, including its main
// sequencer, and does NOT extract the V60's 95-state `st` -- confirmed in
// Model1.map.rpt's "State Machine" sections. Unextracted means binary-encoded,
// so every case arm is a 7-bit comparator and every destination mux is a
// binary-select tree. The yosys census counted 1,106 $eq cells in v60.sv.
//
// The V60 defeats extraction the way this bench does: `st <= st_after_fill`
// and `st <= ea_ret` load the state from OTHER REGISTERS, a subroutine-return
// pattern Quartus cannot prove is a closed state set.
//
// Arm A leaves it binary. Arm B one-hots the state and the two return
// registers by hand. Same states, same transitions, same destinations.

module fsm_onehot (
  input  logic clk, rst, take,
  input  logic [31:0] s0,s1,s2,s3,s4,s5,s6,s7,
  output logic [31:0] q
);
  logic [63:0] st, ret0, ret1;
  logic [31:0] d0, d1, d2, d3;
  logic [63:0] nx;
  always_comb begin
    nx = st;
    case (1'b1)
      st[0]: nx = take ? (64'b1 << 0) : (64'b1 << 7);
      st[1]: nx = take ? (64'b1 << 0) : (64'b1 << 8);
      st[2]: nx = take ? (64'b1 << 0) : (64'b1 << 9);
      st[3]: nx = 64'b1 << 4;
      st[4]: nx = take ? (64'b1 << 0) : (64'b1 << 11);
      st[5]: nx = 64'b1 << 6;
      st[6]: nx = ret0;
      st[7]: nx = take ? (64'b1 << 0) : (64'b1 << 14);
      st[8]: nx = ret0;
      st[9]: nx = take ? (64'b1 << 0) : (64'b1 << 16);
      st[10]: nx = take ? (64'b1 << 0) : (64'b1 << 17);
      st[11]: nx = 64'b1 << 12;
      st[12]: nx = ret0;
      st[13]: nx = 64'b1 << 14;
      st[14]: nx = 64'b1 << 15;
      st[15]: nx = 64'b1 << 16;
      st[16]: nx = ret0;
      st[17]: nx = take ? (64'b1 << 0) : (64'b1 << 24);
      st[18]: nx = take ? (64'b1 << 0) : (64'b1 << 25);
      st[19]: nx = ret1;
      st[20]: nx = ret1;
      st[21]: nx = take ? (64'b1 << 0) : (64'b1 << 28);
      st[22]: nx = ret0;
      st[23]: nx = 64'b1 << 24;
      st[24]: nx = ret0;
      st[25]: nx = ret0;
      st[26]: nx = take ? (64'b1 << 0) : (64'b1 << 33);
      st[27]: nx = take ? (64'b1 << 0) : (64'b1 << 34);
      st[28]: nx = ret1;
      st[29]: nx = ret0;
      st[30]: nx = 64'b1 << 31;
      st[31]: nx = ret0;
      st[32]: nx = 64'b1 << 33;
      st[33]: nx = take ? (64'b1 << 0) : (64'b1 << 40);
      st[34]: nx = 64'b1 << 35;
      st[35]: nx = 64'b1 << 36;
      st[36]: nx = take ? (64'b1 << 0) : (64'b1 << 43);
      st[37]: nx = ret0;
      st[38]: nx = ret0;
      st[39]: nx = ret0;
      st[40]: nx = ret0;
      st[41]: nx = 64'b1 << 42;
      st[42]: nx = 64'b1 << 43;
      st[43]: nx = ret1;
      st[44]: nx = ret1;
      st[45]: nx = ret1;
      st[46]: nx = ret0;
      st[47]: nx = 64'b1 << 48;
      st[48]: nx = ret0;
      st[49]: nx = ret1;
      st[50]: nx = ret0;
      st[51]: nx = ret0;
      st[52]: nx = ret0;
      st[53]: nx = ret0;
      st[54]: nx = ret0;
      st[55]: nx = take ? (64'b1 << 0) : (64'b1 << 62);
      st[56]: nx = 64'b1 << 57;
      st[57]: nx = take ? (64'b1 << 0) : (64'b1 << 0);
      st[58]: nx = ret1;
      st[59]: nx = 64'b1 << 60;
      st[60]: nx = 64'b1 << 61;
      st[61]: nx = ret1;
      st[62]: nx = 64'b1 << 63;
      st[63]: nx = take ? (64'b1 << 0) : (64'b1 << 6);
      default: nx = 64'b1 << 0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin st <= 64'b1 << 0; ret0 <= 64'b1 << 0; ret1 <= 64'b1 << 0; end
    else begin
      st <= nx;
      if (take) ret0 <= nx;
      if (!take) ret1 <= nx;
      case (1'b1)
      st[0]: d3 <= s7;
      st[1]: d1 <= s2;
      st[2]: d1 <= s1;
      st[3]: d2 <= s2;
      st[4]: d0 <= s6;
      st[5]: d1 <= s0;
      st[6]: d0 <= s0;
      st[7]: d1 <= s0;
      st[8]: d2 <= s7;
      st[9]: d1 <= s4;
      st[10]: d0 <= s1;
      st[11]: d2 <= s6;
      st[12]: d2 <= s5;
      st[13]: d2 <= s0;
      st[14]: d0 <= s6;
      st[15]: d2 <= s6;
      st[16]: d0 <= s0;
      st[17]: d1 <= s0;
      st[18]: d3 <= s6;
      st[19]: d0 <= s3;
      st[20]: d2 <= s1;
      st[21]: d2 <= s0;
      st[22]: d0 <= s2;
      st[23]: d0 <= s0;
      st[24]: d3 <= s7;
      st[25]: d1 <= s7;
      st[26]: d1 <= s6;
      st[27]: d0 <= s6;
      st[28]: d1 <= s0;
      st[29]: d2 <= s0;
      st[30]: d1 <= s6;
      st[31]: d0 <= s2;
      st[32]: d3 <= s4;
      st[33]: d2 <= s4;
      st[34]: d0 <= s1;
      st[35]: d1 <= s3;
      st[36]: d2 <= s5;
      st[37]: d1 <= s7;
      st[38]: d3 <= s2;
      st[39]: d2 <= s3;
      st[40]: d1 <= s2;
      st[41]: d3 <= s7;
      st[42]: d3 <= s0;
      st[43]: d0 <= s0;
      st[44]: d1 <= s6;
      st[45]: d3 <= s7;
      st[46]: d1 <= s1;
      st[47]: d1 <= s7;
      st[48]: d2 <= s3;
      st[49]: d0 <= s1;
      st[50]: d3 <= s7;
      st[51]: d0 <= s0;
      st[52]: d2 <= s5;
      st[53]: d0 <= s5;
      st[54]: d3 <= s5;
      st[55]: d0 <= s0;
      st[56]: d2 <= s4;
      st[57]: d0 <= s1;
      st[58]: d0 <= s4;
      st[59]: d1 <= s1;
      st[60]: d3 <= s5;
      st[61]: d1 <= s5;
      st[62]: d0 <= s7;
      st[63]: d3 <= s0;
      default: ;
      endcase
    end
  end
  assign q = d0 ^ d1 ^ d2 ^ d3;
endmodule
