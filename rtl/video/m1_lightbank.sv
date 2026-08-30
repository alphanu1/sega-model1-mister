// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// The light parameter banks, written by display-list command 6.
//
// MAME stores them divided: `set_lightparam(i, (v & 0xff)/255.0f, ...)`. Doing
// that division in hardware would need three fp_div results per bank entry, and
// fp_div is 29 blocking cycles - on the critical shared unit, for a value that
// changes once in thousands of polygons.
//
// So the division is a 256-entry TABLE of i/255.0f, computed at build time with
// the same IEEE division the reference uses, and therefore exact rather than
// approximate. It costs one M10K and no arithmetic at all.
//
// 256 banks because the lightmode is `((flags >> 17) & 15) | (bit22 ? 0x80 : 0)`
// - four bits plus a bank select, so 0..15 and 128..143. Sparse, and a full 256
// entries is simpler than decoding the two ranges.

`timescale 1ns/1ps

module m1_lightbank (
  input  logic        clk,
  input  logic        rst_n,

  // Write side: one packed word per entry, as command 6 delivers it.
  //   bits  7:0  diffuse    15:8  ambient    23:16 specular    31:24 power
  input  logic        we,
  input  logic [7:0]  waddr,
  input  logic [31:0] wdata,

  // Read side, registered.
  input  logic [7:0]  raddr,
  output logic [31:0] lp_d, lp_a, lp_s,
  output logic [7:0]  lp_p
);

  (* romstyle = "M10K" *)
  logic [31:0] div255 [256];
  initial begin
    div255 = '{
    32'h00000000, 32'h3b808081, 32'h3c008081, 32'h3c40c0c1,
    32'h3c808081, 32'h3ca0a0a1, 32'h3cc0c0c1, 32'h3ce0e0e1,
    32'h3d008081, 32'h3d109091, 32'h3d20a0a1, 32'h3d30b0b1,
    32'h3d40c0c1, 32'h3d50d0d1, 32'h3d60e0e1, 32'h3d70f0f1,
    32'h3d808081, 32'h3d888889, 32'h3d909091, 32'h3d989899,
    32'h3da0a0a1, 32'h3da8a8a9, 32'h3db0b0b1, 32'h3db8b8b9,
    32'h3dc0c0c1, 32'h3dc8c8c9, 32'h3dd0d0d1, 32'h3dd8d8d9,
    32'h3de0e0e1, 32'h3de8e8e9, 32'h3df0f0f1, 32'h3df8f8f9,
    32'h3e008081, 32'h3e048485, 32'h3e088889, 32'h3e0c8c8d,
    32'h3e109091, 32'h3e149495, 32'h3e189899, 32'h3e1c9c9d,
    32'h3e20a0a1, 32'h3e24a4a5, 32'h3e28a8a9, 32'h3e2cacad,
    32'h3e30b0b1, 32'h3e34b4b5, 32'h3e38b8b9, 32'h3e3cbcbd,
    32'h3e40c0c1, 32'h3e44c4c5, 32'h3e48c8c9, 32'h3e4ccccd,
    32'h3e50d0d1, 32'h3e54d4d5, 32'h3e58d8d9, 32'h3e5cdcdd,
    32'h3e60e0e1, 32'h3e64e4e5, 32'h3e68e8e9, 32'h3e6ceced,
    32'h3e70f0f1, 32'h3e74f4f5, 32'h3e78f8f9, 32'h3e7cfcfd,
    32'h3e808081, 32'h3e828283, 32'h3e848485, 32'h3e868687,
    32'h3e888889, 32'h3e8a8a8b, 32'h3e8c8c8d, 32'h3e8e8e8f,
    32'h3e909091, 32'h3e929293, 32'h3e949495, 32'h3e969697,
    32'h3e989899, 32'h3e9a9a9b, 32'h3e9c9c9d, 32'h3e9e9e9f,
    32'h3ea0a0a1, 32'h3ea2a2a3, 32'h3ea4a4a5, 32'h3ea6a6a7,
    32'h3ea8a8a9, 32'h3eaaaaab, 32'h3eacacad, 32'h3eaeaeaf,
    32'h3eb0b0b1, 32'h3eb2b2b3, 32'h3eb4b4b5, 32'h3eb6b6b7,
    32'h3eb8b8b9, 32'h3ebababb, 32'h3ebcbcbd, 32'h3ebebebf,
    32'h3ec0c0c1, 32'h3ec2c2c3, 32'h3ec4c4c5, 32'h3ec6c6c7,
    32'h3ec8c8c9, 32'h3ecacacb, 32'h3ecccccd, 32'h3ecececf,
    32'h3ed0d0d1, 32'h3ed2d2d3, 32'h3ed4d4d5, 32'h3ed6d6d7,
    32'h3ed8d8d9, 32'h3edadadb, 32'h3edcdcdd, 32'h3edededf,
    32'h3ee0e0e1, 32'h3ee2e2e3, 32'h3ee4e4e5, 32'h3ee6e6e7,
    32'h3ee8e8e9, 32'h3eeaeaeb, 32'h3eececed, 32'h3eeeeeef,
    32'h3ef0f0f1, 32'h3ef2f2f3, 32'h3ef4f4f5, 32'h3ef6f6f7,
    32'h3ef8f8f9, 32'h3efafafb, 32'h3efcfcfd, 32'h3efefeff,
    32'h3f008081, 32'h3f018182, 32'h3f028283, 32'h3f038384,
    32'h3f048485, 32'h3f058586, 32'h3f068687, 32'h3f078788,
    32'h3f088889, 32'h3f09898a, 32'h3f0a8a8b, 32'h3f0b8b8c,
    32'h3f0c8c8d, 32'h3f0d8d8e, 32'h3f0e8e8f, 32'h3f0f8f90,
    32'h3f109091, 32'h3f119192, 32'h3f129293, 32'h3f139394,
    32'h3f149495, 32'h3f159596, 32'h3f169697, 32'h3f179798,
    32'h3f189899, 32'h3f19999a, 32'h3f1a9a9b, 32'h3f1b9b9c,
    32'h3f1c9c9d, 32'h3f1d9d9e, 32'h3f1e9e9f, 32'h3f1f9fa0,
    32'h3f20a0a1, 32'h3f21a1a2, 32'h3f22a2a3, 32'h3f23a3a4,
    32'h3f24a4a5, 32'h3f25a5a6, 32'h3f26a6a7, 32'h3f27a7a8,
    32'h3f28a8a9, 32'h3f29a9aa, 32'h3f2aaaab, 32'h3f2babac,
    32'h3f2cacad, 32'h3f2dadae, 32'h3f2eaeaf, 32'h3f2fafb0,
    32'h3f30b0b1, 32'h3f31b1b2, 32'h3f32b2b3, 32'h3f33b3b4,
    32'h3f34b4b5, 32'h3f35b5b6, 32'h3f36b6b7, 32'h3f37b7b8,
    32'h3f38b8b9, 32'h3f39b9ba, 32'h3f3ababb, 32'h3f3bbbbc,
    32'h3f3cbcbd, 32'h3f3dbdbe, 32'h3f3ebebf, 32'h3f3fbfc0,
    32'h3f40c0c1, 32'h3f41c1c2, 32'h3f42c2c3, 32'h3f43c3c4,
    32'h3f44c4c5, 32'h3f45c5c6, 32'h3f46c6c7, 32'h3f47c7c8,
    32'h3f48c8c9, 32'h3f49c9ca, 32'h3f4acacb, 32'h3f4bcbcc,
    32'h3f4ccccd, 32'h3f4dcdce, 32'h3f4ececf, 32'h3f4fcfd0,
    32'h3f50d0d1, 32'h3f51d1d2, 32'h3f52d2d3, 32'h3f53d3d4,
    32'h3f54d4d5, 32'h3f55d5d6, 32'h3f56d6d7, 32'h3f57d7d8,
    32'h3f58d8d9, 32'h3f59d9da, 32'h3f5adadb, 32'h3f5bdbdc,
    32'h3f5cdcdd, 32'h3f5dddde, 32'h3f5ededf, 32'h3f5fdfe0,
    32'h3f60e0e1, 32'h3f61e1e2, 32'h3f62e2e3, 32'h3f63e3e4,
    32'h3f64e4e5, 32'h3f65e5e6, 32'h3f66e6e7, 32'h3f67e7e8,
    32'h3f68e8e9, 32'h3f69e9ea, 32'h3f6aeaeb, 32'h3f6bebec,
    32'h3f6ceced, 32'h3f6dedee, 32'h3f6eeeef, 32'h3f6feff0,
    32'h3f70f0f1, 32'h3f71f1f2, 32'h3f72f2f3, 32'h3f73f3f4,
    32'h3f74f4f5, 32'h3f75f5f6, 32'h3f76f6f7, 32'h3f77f7f8,
    32'h3f78f8f9, 32'h3f79f9fa, 32'h3f7afafb, 32'h3f7bfbfc,
    32'h3f7cfcfd, 32'h3f7dfdfe, 32'h3f7efeff, 32'h3f800000    };
  end

  // Three floats and a power byte per bank.
  (* ramstyle = "M10K" *) logic [31:0] bank_d [256];
  (* ramstyle = "M10K" *) logic [31:0] bank_a [256];
  (* ramstyle = "M10K" *) logic [31:0] bank_s [256];
  (* ramstyle = "M10K" *) logic [7:0]  bank_p [256];

  // The table read and the bank write are one cycle apart, so the packed word is
  // held while its three bytes are converted.
  logic        we_d;
  logic [7:0]  waddr_d;
  logic [7:0]  wp_d;
  logic [31:0] cd, ca, cs;

  always_ff @(posedge clk) begin
    cd      <= div255[wdata[7:0]];
    ca      <= div255[wdata[15:8]];
    cs      <= div255[wdata[23:16]];
    wp_d    <= wdata[31:24];
    waddr_d <= waddr;
    we_d    <= we;

    if (we_d) begin
      bank_d[waddr_d] <= cd;
      bank_a[waddr_d] <= ca;
      bank_s[waddr_d] <= cs;
      bank_p[waddr_d] <= wp_d;
    end

    lp_d <= bank_d[raddr];
    lp_a <= bank_a[raddr];
    lp_s <= bank_s[raddr];
    lp_p <= bank_p[raddr];
  end

  wire unused_rst = rst_n;   // the banks are written before they are read

endmodule
