// MICROBENCH: the V60's `dbus_addr` mux, both ways.
//
// The fitter attributes 16,015 combinational ALUTs to v60.sv's own logic and
// the yosys census counted 14,798 $mux cells against 140 $add. `dbus_addr` is
// the widest of them: 62 assignment sites, 32 bits, inside one 95-state case.
//
// Arm A assigns one of eight source registers directly in each state -- a
// 64-way 32-bit mux. Arm B assigns a 3-bit SOURCE CODE in each state and muxes
// the eight sources once -- a 64-way 3-bit mux feeding an 8-way 32-bit one.
// Same cycle behaviour, same sources, same states.

module mux_wide (
  input  logic        clk,
  input  logic        rst,
  input  logic [5:0]  jump,
  input  logic        take,
  input  logic [31:0] s0, s1, s2, s3, s4, s5, s6, s7,
  output logic [31:0] dbus_addr
);
  logic [5:0] st;
  always_ff @(posedge clk) if (rst) st <= 6'd0; else st <= take ? jump : (st + 6'd1);

  logic [31:0] nxt;
  always_comb begin
    case (st)
      6'd0: nxt = s5;
      6'd1: nxt = s2;
      6'd2: nxt = s6;
      6'd3: nxt = s0;
      6'd4: nxt = s1;
      6'd5: nxt = s1;
      6'd6: nxt = s5;
      6'd7: nxt = s0;
      6'd8: nxt = s3;
      6'd9: nxt = s0;
      6'd10: nxt = s1;
      6'd11: nxt = s6;
      6'd12: nxt = s6;
      6'd13: nxt = s1;
      6'd14: nxt = s3;
      6'd15: nxt = s1;
      6'd16: nxt = s6;
      6'd17: nxt = s0;
      6'd18: nxt = s1;
      6'd19: nxt = s3;
      6'd20: nxt = s0;
      6'd21: nxt = s6;
      6'd22: nxt = s0;
      6'd23: nxt = s3;
      6'd24: nxt = s0;
      6'd25: nxt = s2;
      6'd26: nxt = s4;
      6'd27: nxt = s6;
      6'd28: nxt = s2;
      6'd29: nxt = s1;
      6'd30: nxt = s4;
      6'd31: nxt = s2;
      6'd32: nxt = s1;
      6'd33: nxt = s3;
      6'd34: nxt = s5;
      6'd35: nxt = s1;
      6'd36: nxt = s1;
      6'd37: nxt = s0;
      6'd38: nxt = s3;
      6'd39: nxt = s7;
      6'd40: nxt = s6;
      6'd41: nxt = s5;
      6'd42: nxt = s7;
      6'd43: nxt = s7;
      6'd44: nxt = s5;
      6'd45: nxt = s4;
      6'd46: nxt = s3;
      6'd47: nxt = s2;
      6'd48: nxt = s3;
      6'd49: nxt = s1;
      6'd50: nxt = s4;
      6'd51: nxt = s7;
      6'd52: nxt = s5;
      6'd53: nxt = s7;
      6'd54: nxt = s4;
      6'd55: nxt = s1;
      6'd56: nxt = s1;
      6'd57: nxt = s6;
      6'd58: nxt = s2;
      6'd59: nxt = s5;
      6'd60: nxt = s2;
      6'd61: nxt = s7;
      6'd62: nxt = s6;
      6'd63: nxt = s0;
      default: nxt = s0;
    endcase
  end
  always_ff @(posedge clk) dbus_addr <= nxt;
endmodule
