// The same thing as plain flip-flops, for comparison.
module mlab_flops (
  input  logic        clk,
  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [31:0] wdata,
  input  logic [4:0]  raddr_a, raddr_b,
  output logic [31:0] q_a, q_b
);
  logic [31:0] mem [32];
  always_ff @(posedge clk) if (we) mem[waddr] <= wdata;
  assign q_a = mem[raddr_a];
  assign q_b = mem[raddr_b];
endmodule
