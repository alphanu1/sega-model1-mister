// Does Quartus infer an MLAB for a COMBINATIONALLY read array?
//
// An MLAB is LUTRAM, and LUTRAM reads through the LUT rather than out of a
// register, so an asynchronous read should be native. Every conversion today
// has used a registered read and been costed as if the extra cycle were
// unavoidable - which ruled out the geometry arrays and all three CPU register
// files, because they are read combinationally into a datapath.
//
// If this infers MLAB, that objection is wrong and they all come back.
// Two read ports, one write, exactly the shape those arrays have.
module mlab_async (
  input  logic        clk,
  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [31:0] wdata,
  input  logic [4:0]  raddr_a, raddr_b,
  output logic [31:0] q_a, q_b
);
  (* ramstyle = "MLAB" *) logic [31:0] mem [32];
  always_ff @(posedge clk) if (we) mem[waddr] <= wdata;
  assign q_a = mem[raddr_a];     // asynchronous
  assign q_b = mem[raddr_b];     // asynchronous, second port
endmodule
