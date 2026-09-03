// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The reciprocal table the fill's two dividers share: recip[d] = ceil(2^32/d).
//
// ONE TABLE, TWO READ PORTS. Each m1_raster_div held its own copy, which is
// 1,024 x 32 bits twice - 8 M10K of the 553, on a design that reached 540 and
// then lost three seeds in a row to routing congestion on the framework's
// scaler. An M10K is true dual-port, so one table answers both dividers in the
// same cycle and costs 4.
//
// Both ports are registered reads with no write port, which is what Quartus
// needs to infer a ROM; a gated read with a computed address builds the whole
// thing out of logic instead, silently. That cost 1,300 ALM once already.
`timescale 1ns/1ps

module m1_recip_rom #(
  parameter int unsigned TN = 1024
) (
  input  logic        clk,
  input  logic [$clog2(TN)-1:0] a_addr,
  output logic [31:0] a_data,
  input  logic [$clog2(TN)-1:0] b_addr,
  output logic [31:0] b_data
);

  (* ramstyle = "M10K" *) logic [31:0] recip [TN];

  // ceil(2^32/d). Entry 0 is never read - a zero denominator is trapped by the
  // divider - and entry 1 would be 2^32, which the divider special-cases.
  initial begin
    for (int d = 1; d < int'(TN); d++)
      recip[d] = 32'((({32'd0, 32'h8000_0000} << 1) + longint'(d) - 1) / longint'(d));
  end

  always_ff @(posedge clk) begin
    a_data <= recip[a_addr];
    b_data <= recip[b_addr];
  end

endmodule
