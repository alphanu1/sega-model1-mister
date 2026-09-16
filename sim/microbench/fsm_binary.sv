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

module fsm_binary (
  input  logic clk, rst, take,
  input  logic [31:0] s0,s1,s2,s3,s4,s5,s6,s7,
  output logic [31:0] q
);
  logic [5:0] st, ret0, ret1;
  logic [31:0] d0, d1, d2, d3;
  logic [5:0] nx;
  always_comb begin
    nx = st;
    case (st)
      6'd0: nx = take ? (6'd0) : (6'd7);
      6'd1: nx = take ? (6'd0) : (6'd8);
      6'd2: nx = take ? (6'd0) : (6'd9);
      6'd3: nx = 6'd4;
      6'd4: nx = take ? (6'd0) : (6'd11);
      6'd5: nx = 6'd6;
      6'd6: nx = ret0;
      6'd7: nx = take ? (6'd0) : (6'd14);
      6'd8: nx = ret0;
      6'd9: nx = take ? (6'd0) : (6'd16);
      6'd10: nx = take ? (6'd0) : (6'd17);
      6'd11: nx = 6'd12;
      6'd12: nx = ret0;
      6'd13: nx = 6'd14;
      6'd14: nx = 6'd15;
      6'd15: nx = 6'd16;
      6'd16: nx = ret0;
      6'd17: nx = take ? (6'd0) : (6'd24);
      6'd18: nx = take ? (6'd0) : (6'd25);
      6'd19: nx = ret1;
      6'd20: nx = ret1;
      6'd21: nx = take ? (6'd0) : (6'd28);
      6'd22: nx = ret0;
      6'd23: nx = 6'd24;
      6'd24: nx = ret0;
      6'd25: nx = ret0;
      6'd26: nx = take ? (6'd0) : (6'd33);
      6'd27: nx = take ? (6'd0) : (6'd34);
      6'd28: nx = ret1;
      6'd29: nx = ret0;
      6'd30: nx = 6'd31;
      6'd31: nx = ret0;
      6'd32: nx = 6'd33;
      6'd33: nx = take ? (6'd0) : (6'd40);
      6'd34: nx = 6'd35;
      6'd35: nx = 6'd36;
      6'd36: nx = take ? (6'd0) : (6'd43);
      6'd37: nx = ret0;
      6'd38: nx = ret0;
      6'd39: nx = ret0;
      6'd40: nx = ret0;
      6'd41: nx = 6'd42;
      6'd42: nx = 6'd43;
      6'd43: nx = ret1;
      6'd44: nx = ret1;
      6'd45: nx = ret1;
      6'd46: nx = ret0;
      6'd47: nx = 6'd48;
      6'd48: nx = ret0;
      6'd49: nx = ret1;
      6'd50: nx = ret0;
      6'd51: nx = ret0;
      6'd52: nx = ret0;
      6'd53: nx = ret0;
      6'd54: nx = ret0;
      6'd55: nx = take ? (6'd0) : (6'd62);
      6'd56: nx = 6'd57;
      6'd57: nx = take ? (6'd0) : (6'd0);
      6'd58: nx = ret1;
      6'd59: nx = 6'd60;
      6'd60: nx = 6'd61;
      6'd61: nx = ret1;
      6'd62: nx = 6'd63;
      6'd63: nx = take ? (6'd0) : (6'd6);
      default: nx = 6'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin st <= 6'd0; ret0 <= 6'd0; ret1 <= 6'd0; end
    else begin
      st <= nx;
      if (take) ret0 <= nx;
      if (!take) ret1 <= nx;
      case (st)
      6'd0: d3 <= s7;
      6'd1: d1 <= s2;
      6'd2: d1 <= s1;
      6'd3: d2 <= s2;
      6'd4: d0 <= s6;
      6'd5: d1 <= s0;
      6'd6: d0 <= s0;
      6'd7: d1 <= s0;
      6'd8: d2 <= s7;
      6'd9: d1 <= s4;
      6'd10: d0 <= s1;
      6'd11: d2 <= s6;
      6'd12: d2 <= s5;
      6'd13: d2 <= s0;
      6'd14: d0 <= s6;
      6'd15: d2 <= s6;
      6'd16: d0 <= s0;
      6'd17: d1 <= s0;
      6'd18: d3 <= s6;
      6'd19: d0 <= s3;
      6'd20: d2 <= s1;
      6'd21: d2 <= s0;
      6'd22: d0 <= s2;
      6'd23: d0 <= s0;
      6'd24: d3 <= s7;
      6'd25: d1 <= s7;
      6'd26: d1 <= s6;
      6'd27: d0 <= s6;
      6'd28: d1 <= s0;
      6'd29: d2 <= s0;
      6'd30: d1 <= s6;
      6'd31: d0 <= s2;
      6'd32: d3 <= s4;
      6'd33: d2 <= s4;
      6'd34: d0 <= s1;
      6'd35: d1 <= s3;
      6'd36: d2 <= s5;
      6'd37: d1 <= s7;
      6'd38: d3 <= s2;
      6'd39: d2 <= s3;
      6'd40: d1 <= s2;
      6'd41: d3 <= s7;
      6'd42: d3 <= s0;
      6'd43: d0 <= s0;
      6'd44: d1 <= s6;
      6'd45: d3 <= s7;
      6'd46: d1 <= s1;
      6'd47: d1 <= s7;
      6'd48: d2 <= s3;
      6'd49: d0 <= s1;
      6'd50: d3 <= s7;
      6'd51: d0 <= s0;
      6'd52: d2 <= s5;
      6'd53: d0 <= s5;
      6'd54: d3 <= s5;
      6'd55: d0 <= s0;
      6'd56: d2 <= s4;
      6'd57: d0 <= s1;
      6'd58: d0 <= s4;
      6'd59: d1 <= s1;
      6'd60: d3 <= s5;
      6'd61: d1 <= s5;
      6'd62: d0 <= s7;
      6'd63: d3 <= s0;
      default: ;
      endcase
    end
  end
  assign q = d0 ^ d1 ^ d2 ^ d3;
endmodule
