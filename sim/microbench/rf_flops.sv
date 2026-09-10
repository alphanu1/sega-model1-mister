// MICROBENCH: what does the V60's register file cost as flops?
//
// r[0:31] x 32 bits, two async read ports built as 32-way muxes, and two write
// ports with PER-BIT write masks - which is what v60.sv actually has. The
// per-bit mask is the thing that makes this hard to put in a RAM: an MLAB has
// one write port and word-granular writes.
//
// This arm bounds the prize. Whatever an MLAB version could save is at most
// the difference between this and the storage alone.
module rf_flops (
  input  logic        clk,
  input  logic [4:0]  raddr_a, raddr_b,
  input  logic        we0, we1,
  input  logic [4:0]  waddr0, waddr1,
  input  logic [31:0] wdata0, wdata1, wmask0, wmask1,
  output logic [31:0] rdata_a, rdata_b, rdata_sp
);
  reg [31:0] r[0:31];
  always_comb rdata_a = r[raddr_a];
  always_comb rdata_b = r[raddr_b];
  assign rdata_sp = r[31];          // the constant-index read, 41 sites in v60.sv
  always_ff @(posedge clk) begin
    for (int b = 0; b < 32; b++) begin
      if (we0 && wmask0[b]) r[waddr0][b] <= wdata0[b];
      if (we1 && wmask1[b]) r[waddr1][b] <= wdata1[b];
    end
  end
endmodule
