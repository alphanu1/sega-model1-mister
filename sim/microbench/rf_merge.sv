// MICROBENCH: the ACTUAL proposal - word writes with the mask merged in the
// datapath, which needs the old value and therefore two more read muxes.
//
// rf_word measured 1,256 ALM but cheated: a word write needs no read of the
// old contents, and the real change does. This arm pays for that.
module rf_merge (
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
  assign rdata_sp = r[31];

  wire collide = we0 && we1 && (waddr0 == waddr1);
  wire [31:0] old0 = r[waddr0];
  wire [31:0] old1 = r[waddr1];

  logic [31:0] new0, new1;
  always_comb begin
    // Port 0 first, then port 1 on a collision - the same order the per-bit
    // loop had, where port 1's nonblocking assignment came second and won.
    new0 = we0 ? ((old0 & ~wmask0) | (wdata0 & wmask0)) : old0;
    if (collide) new0 = (new0 & ~wmask1) | (wdata1 & wmask1);
    new1 = (old1 & ~wmask1) | (wdata1 & wmask1);
  end

  always_ff @(posedge clk) begin
    if (we0)              r[waddr0] <= new0;
    if (we1 && !collide)  r[waddr1] <= new1;
  end
endmodule
