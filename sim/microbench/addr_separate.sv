// MICROBENCH: does sharing an adder pay on Cyclone V?
//
// The V60's top level assigns 32-bit address registers from many sites, each
// with its own `+`. The proposed optimisation is to route them through one
// shared adder. On an FPGA that is not obviously a win: an adder is a carry
// chain and costs about half an ALM per bit, while every extra mux input costs
// LUTs. This is the "one adder per site" arm.
module addr_separate (
  input  logic        clk,
  input  logic [2:0]  sel,
  input  logic [31:0] a0, a1, a2, a3, a4, a5, a6, a7,
  input  logic [31:0] b0, b1, b2, b3, b4, b5, b6, b7,
  output logic [31:0] q
);
  always_ff @(posedge clk)
    case (sel)
      3'd0: q <= a0 + b0;
      3'd1: q <= a1 + b1;
      3'd2: q <= a2 + b2;
      3'd3: q <= a3 + b3;
      3'd4: q <= a4 + b4;
      3'd5: q <= a5 + b5;
      3'd6: q <= a6 + b6;
      3'd7: q <= a7 + b7;
    endcase
endmodule
