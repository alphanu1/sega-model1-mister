// MICROBENCH: the shared-adder arm. Identical function to addr_separate,
// one adder with the operands muxed in.
module addr_shared (
  input  logic        clk,
  input  logic [2:0]  sel,
  input  logic [31:0] a0, a1, a2, a3, a4, a5, a6, a7,
  input  logic [31:0] b0, b1, b2, b3, b4, b5, b6, b7,
  output logic [31:0] q
);
  logic [31:0] am, bm;
  always_comb begin
    case (sel)
      3'd0: begin am = a0; bm = b0; end
      3'd1: begin am = a1; bm = b1; end
      3'd2: begin am = a2; bm = b2; end
      3'd3: begin am = a3; bm = b3; end
      3'd4: begin am = a4; bm = b4; end
      3'd5: begin am = a5; bm = b5; end
      3'd6: begin am = a6; bm = b6; end
      3'd7: begin am = a7; bm = b7; end
    endcase
  end
  always_ff @(posedge clk) q <= am + bm;
endmodule
