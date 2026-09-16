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

module mux_coded (
  input  logic        clk,
  input  logic        rst,
  input  logic [5:0]  jump,
  input  logic        take,
  input  logic [31:0] s0, s1, s2, s3, s4, s5, s6, s7,
  output logic [31:0] dbus_addr
);
  logic [5:0] st;
  always_ff @(posedge clk) if (rst) st <= 6'd0; else st <= take ? jump : (st + 6'd1);

  logic [2:0] code;
  always_comb begin
    case (st)
      6'd0: code = 3'd5;
      6'd1: code = 3'd2;
      6'd2: code = 3'd6;
      6'd3: code = 3'd0;
      6'd4: code = 3'd1;
      6'd5: code = 3'd1;
      6'd6: code = 3'd5;
      6'd7: code = 3'd0;
      6'd8: code = 3'd3;
      6'd9: code = 3'd0;
      6'd10: code = 3'd1;
      6'd11: code = 3'd6;
      6'd12: code = 3'd6;
      6'd13: code = 3'd1;
      6'd14: code = 3'd3;
      6'd15: code = 3'd1;
      6'd16: code = 3'd6;
      6'd17: code = 3'd0;
      6'd18: code = 3'd1;
      6'd19: code = 3'd3;
      6'd20: code = 3'd0;
      6'd21: code = 3'd6;
      6'd22: code = 3'd0;
      6'd23: code = 3'd3;
      6'd24: code = 3'd0;
      6'd25: code = 3'd2;
      6'd26: code = 3'd4;
      6'd27: code = 3'd6;
      6'd28: code = 3'd2;
      6'd29: code = 3'd1;
      6'd30: code = 3'd4;
      6'd31: code = 3'd2;
      6'd32: code = 3'd1;
      6'd33: code = 3'd3;
      6'd34: code = 3'd5;
      6'd35: code = 3'd1;
      6'd36: code = 3'd1;
      6'd37: code = 3'd0;
      6'd38: code = 3'd3;
      6'd39: code = 3'd7;
      6'd40: code = 3'd6;
      6'd41: code = 3'd5;
      6'd42: code = 3'd7;
      6'd43: code = 3'd7;
      6'd44: code = 3'd5;
      6'd45: code = 3'd4;
      6'd46: code = 3'd3;
      6'd47: code = 3'd2;
      6'd48: code = 3'd3;
      6'd49: code = 3'd1;
      6'd50: code = 3'd4;
      6'd51: code = 3'd7;
      6'd52: code = 3'd5;
      6'd53: code = 3'd7;
      6'd54: code = 3'd4;
      6'd55: code = 3'd1;
      6'd56: code = 3'd1;
      6'd57: code = 3'd6;
      6'd58: code = 3'd2;
      6'd59: code = 3'd5;
      6'd60: code = 3'd2;
      6'd61: code = 3'd7;
      6'd62: code = 3'd6;
      6'd63: code = 3'd0;
      default: code = 3'd0;
    endcase
  end
  logic [31:0] nxt;
  always_comb begin
    case (code)
      3'd0: nxt = s0;  3'd1: nxt = s1;  3'd2: nxt = s2;  3'd3: nxt = s3;
      3'd4: nxt = s4;  3'd5: nxt = s5;  3'd6: nxt = s6;  3'd7: nxt = s7;
    endcase
  end
  always_ff @(posedge clk) dbus_addr <= nxt;
endmodule
