// MICROBENCH: the mask is never arbitrary - it is a LANE PATTERN.
//
// Every write reaches the file through queue_reg_write, and every caller passes
// one of exactly three masks: 0x000000ff, 0x0000ffff or 0xffffffff (setreg's
// three dim cases, plus 55 literal full-word writes). So the 32-bit per-bit
// mask carries two bits of information.
//
// Replacing it with a 2-bit size gives three lane enables per register instead
// of thirty-two bit enables, and - unlike merging in the datapath - it needs no
// read of the old contents, so it adds no read muxes.
//
// Port 1 is still applied second, so it still wins on an overlapping bit,
// exactly as the per-bit loop's nonblocking ordering did.
module rf_lane (
  input  logic        clk,
  input  logic [4:0]  raddr_a, raddr_b,
  input  logic        we0, we1,
  input  logic [4:0]  waddr0, waddr1,
  input  logic [31:0] wdata0, wdata1,
  input  logic [1:0]  wsz0, wsz1,        // 0 = byte, 1 = halfword, 2/3 = word
  output logic [31:0] rdata_a, rdata_b, rdata_sp
);
  reg [31:0] r[0:31];
  always_comb rdata_a = r[raddr_a];
  always_comb rdata_b = r[raddr_b];
  assign rdata_sp = r[31];

  always_ff @(posedge clk) begin
    if (we0) begin
                          r[waddr0][7:0]   <= wdata0[7:0];
      if (wsz0 >= 2'd1)   r[waddr0][15:8]  <= wdata0[15:8];
      if (wsz0 >= 2'd2)   r[waddr0][31:16] <= wdata0[31:16];
    end
    if (we1) begin
                          r[waddr1][7:0]   <= wdata1[7:0];
      if (wsz1 >= 2'd1)   r[waddr1][15:8]  <= wdata1[15:8];
      if (wsz1 >= 2'd2)   r[waddr1][31:16] <= wdata1[31:16];
    end
  end
endmodule
