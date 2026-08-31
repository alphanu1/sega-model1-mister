// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// One CPU port (read/write, byte-enabled) and one video read port, in ONE set
// of M10K blocks and on TWO clocks.
//
// THE PROBLEM, MEASURED HERE 2026-08-29. `m1_mainram` keeps two copies of the
// tile RAM and two of the palette -- `tram_c_*` for the CPU's read port and
// `tram_v_*` for the video read port -- written identically from `clk`. The
// fitter report:
//
//     tram_c_lo 32 + tram_c_hi 32 + tram_v_lo 32 + tram_v_hi 32 = 128 M10K
//     pram_c_lo  8 + pram_c_hi  8 + pram_v_lo  8 + pram_v_hi  8 =  32 M10K
//
// Half of each is duplication: 64 blocks on tile RAM and 16 on palette, 80 of a
// 553-block device, on a part already at 82%.
//
// QUARTUS 17.0 WILL NOT INFER THE SHARED MEMORY, tested both ways in
// `build/m10ktest`:
//
//   * one write and two reads on different clocks -- it silently REPLICATES
//     into two Simple Dual Port blocks, which is what the hand-written pair
//     already does, so merging the declarations saves nothing;
//   * the true dual-port template, both ports read and write -- refused
//     outright, `Error (276001): Cannot synthesize dual-port RAM logic`.
//
// So it needs an explicit altsyncram. The Model 2 core solves the identical
// problem the same way and its module is the reference for this one; what is
// different here is that our two ports are on DIFFERENT CLOCKS and our CPU port
// is byte-enabled.
//
// BOTH PORTS MUST BE THE SAME WIDTH or the M10K is replicated again -- mixed
// width is what forces that -- so this is 16 bits on both sides and the byte
// lanes become a `byteena` rather than two arrays.
//
// READ-DURING-WRITE IS "DONT_CARE", AND THAT IS A REAL DIFFERENCE from the
// inferred version, stated rather than glossed. The inferred arrays were
// non-blocking, so a read on the same edge as a write to the same address
// returned the value from BEFORE the write. That is "OLD_DATA", and Cyclone V
// M10K does not support it in bidirectional dual-port mode -- Quartus rejects
// it with Error 14000. The silicon cannot do read-first on a true dual-port.
//
// Where that can happen here and why it is acceptable:
//
//   * PORT A reads unconditionally every cycle, including write cycles, and
//     nothing consumes the read data of a write cycle -- the V60's reads and
//     writes are separate bus transactions.
//   * PORT B is the tile fetch reading a word the CPU writes on the same edge.
//     One word takes either the old or the new value for one cycle. The real
//     315-5313 arbitrates this in silicon and we do not know which it gives.
//
// SIMULATION USES THE INFERRED FORM, because Verilator has no altsyncram. The
// standing caveat applies either way: simulation cannot see memory inference,
// and only a Quartus build can say whether an array landed in M10K or in
// flip-flops. The two paths are written to the same semantics and the fitter
// report is the check.

`timescale 1ns/1ps

module m1_tdp_ram #(
  parameter int unsigned AW = 15,         // address width
  // WORDS IS NOT ALWAYS 2**AW, and on a device at 100% of its M10K that is the
  // difference between fitting and not. The colour translation table is
  // 24,576 words - MAME maps exactly 0x910000-0x91bfff - and a 15-bit address
  // rounded up to 32,768 wastes 8,192 words of block RAM, about 13 blocks, on
  // addresses the hardware never presents.
  parameter int unsigned WORDS = 1 << AW
) (
  // Port A: the CPU's, read and write, byte-enabled.
  input  logic          a_clk,
  input  logic [AW-1:0] a_addr,
  input  logic [15:0]   a_din,
  input  logic [1:0]    a_be,
  input  logic          a_we,
  output logic [15:0]   a_q,

  // Port B: the video side's, read only, on its own clock.
  input  logic          b_clk,
  input  logic [AW-1:0] b_addr,
  output logic [15:0]   b_q
);

`ifdef VERILATOR
  // NOT `synthesis translate_off`: Verilator honours that pragma too and would
  // skip the model entirely, which is the opposite of the intent and has cost a
  // session on this project before.
  (* ramstyle = "M10K" *) logic [7:0] mem_lo [WORDS];
  (* ramstyle = "M10K" *) logic [7:0] mem_hi [WORDS];
  always_ff @(posedge a_clk) begin
    if (a_we && a_be[0]) mem_lo[a_addr] <= a_din[7:0];
    if (a_we && a_be[1]) mem_hi[a_addr] <= a_din[15:8];
    a_q <= {mem_hi[a_addr], mem_lo[a_addr]};
  end
  always_ff @(posedge b_clk) b_q <= {mem_hi[b_addr], mem_lo[b_addr]};

  // Cleared for the simulator. The device powers up cleared and altsyncram is
  // told `power_up_uninitialized = FALSE`, so this is the simulation half of the
  // same contract. Chunked under Quartus 17.0's 5,000-iteration unroll cap even
  // though this arm is Verilator-only, so the shape stays copyable.
  integer zc, zi;
  initial
    for (zc = 0; zc < (WORDS + 4095) / 4096; zc = zc + 1)
      // Bounded by WORDS as well as by the chunk: a depth that is not a
      // multiple of 4096 would otherwise run off the end of the array.
      for (zi = zc*4096; zi < (zc+1)*4096 && zi < int'(WORDS); zi = zi + 1) begin
        mem_lo[zi] = 8'd0; mem_hi[zi] = 8'd0;
      end
`else
  altsyncram #(
    .operation_mode                     ("BIDIR_DUAL_PORT"),
    .ram_block_type                     ("M10K"),
    .width_a                            (16),
    .widthad_a                          (AW),
    .numwords_a                         (WORDS),
    .width_b                            (16),
    .widthad_b                          (AW),
    .numwords_b                         (WORDS),
    .width_byteena_a                    (2),
    .width_byteena_b                    (1),
    .byte_size                          (8),
    // TWO CLOCKS. Port A is clock0 and port B is clock1; the *_reg_b parameters
    // are what actually move port B onto the second clock, and leaving any of
    // them at CLOCK0 silently puts that part of port B back on the CPU's clock.
    .indata_reg_b                       ("CLOCK1"),
    .address_reg_b                      ("CLOCK1"),
    .wrcontrol_wraddress_reg_b          ("CLOCK1"),
    .byteena_reg_b                      ("CLOCK1"),
    .outdata_reg_a                      ("UNREGISTERED"),
    .outdata_reg_b                      ("UNREGISTERED"),
    .read_during_write_mode_port_a      ("DONT_CARE"),
    .read_during_write_mode_port_b      ("DONT_CARE"),
    .read_during_write_mode_mixed_ports ("DONT_CARE"),
    .power_up_uninitialized             ("FALSE"),
    .lpm_type                           ("altsyncram")
  ) u_ram (
    .clock0    (a_clk),
    .clock1    (b_clk),
    .clocken0  (1'b1),
    .clocken1  (1'b1),
    .address_a (a_addr),
    .data_a    (a_din),
    .byteena_a (a_be),
    .wren_a    (a_we),
    .q_a       (a_q),
    .address_b (b_addr),
    .data_b    (16'd0),
    .wren_b    (1'b0),
    .q_b       (b_q),
    // Everything this design does not use, tied off as the IP expects.
    .aclr0(1'b0), .aclr1(1'b0),
    .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(1'b1),
    .clocken2(1'b1), .clocken3(1'b1),
    .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
  );
`endif

endmodule
