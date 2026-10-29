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
// THE I/O BOARD ON ITS OWN, RUNNING ITS REAL FIRMWARE, AGAINST THE V60'S BOOT
// HANDSHAKE AS MAME RECORDS IT.
//
// The full-system bench reaches this exchange only after streaming 25 MB
// through the loader and waiting out its one-second settle: about ten minutes
// a try. This drives m1_ioz80 directly, with the firmware served from an
// array and the dual-port RAM a plain array, and plays the V60's side of the
// boot exchange Wing War makes (MAME wingwar, cold nvram, V60 DPRAM tap,
// docs/findings.md 2026-10-29):
//
//   1. write 0x1a-0x1d = "SEGA", 0x21 = 0, flag 0x20 = 1
//   2. wait for the board to publish 0x21 = 0x40 and clear 0x20
//   3. command 3 (0x21 = 0, 0x20 = 3): the board copies its settings block
//      to 0x100-0x17f and clears 0x20
//   4. write a settings block to 0x100, command 2: the board stores it and
//      clears 0x20 (MAME: 2.2 s - an EEPROM write per word)
//   5. command 3 again: the block must read back as written
//   6. command 1 a few times: the input scan, 0x20 cleared each time
//
// The firmware is a ROM image and so is never in the repository (hard rule
// 2): FWHEX names a file the user builds, one hex byte per line. The run
// SKIPS with a message if it is absent, so a fresh clone's `make test` is
// unaffected. IO2 selects the board; the default is Wing War's.
//
// Times are in Z80 clocks of the modelled board, which is what the firmware's
// own delays are counted in, so the limits mean the same at any clk.

`timescale 1ns/1ps

module tb_m1_ioz80 #(
  parameter string FWHEX = "build/rom/wingwar_iofw_16891.hex",
  parameter bit    IO2   = 1'b1,
  // Ten times what MAME needs for the slowest step (the settings write).
  parameter longint LIMIT = 64'd400_000_000,
  parameter longint PROGRESS = 0,
  parameter int     PCTRACE  = 0
);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // ------------------------------------------------------------ firmware
  logic [7:0]  fw [65536];
  logic        fw_req, fw_ack;
  logic [13:0] fw_word;
  logic [15:0] fw_din;
  // Unwritten memory reads 0xFFFF (the SDRAM model's convention), which is
  // also what the EEPROM block above the firmware holds here.
  initial for (int i = 0; i < 65536; i++) fw[i] = 8'hff;
  // A few cycles of latency, held ack, like the SDRAM port.
  int fw_lat;
  always_ff @(posedge clk) begin
    fw_ack <= 1'b0;
    if (fw_req && !fw_ack) begin
      if (fw_lat == 6) begin
        fw_ack <= 1'b1; fw_lat <= 0;
        fw_din <= (fw_word < 14'h2000) ? {fw[{fw_word[12:0], 1'b1}], fw[{fw_word[12:0], 1'b0}]}
                                       : 16'hffff;
      end else fw_lat <= fw_lat + 1;
    end else fw_lat <= 0;
  end

  // ------------------------------------------------------------ DPRAM
  logic [7:0]  dp [2048];
  logic        z_we;
  logic [10:0] z_addr;
  logic [7:0]  z_wdata, z_rdata;
  initial for (int i = 0; i < 2048; i++) dp[i] = 8'h00;
  always_ff @(posedge clk) begin
    if (z_we) dp[z_addr] <= z_wdata;
    z_rdata <= dp[z_addr];
  end

  logic [15:0] dbg_a;
  logic        dbg_m1_n;
  m1_ioz80 dut (
    .clk(clk), .rst_n(rst_n), .io2(IO2),
    .fw_req(fw_req), .fw_word(fw_word), .fw_ack(fw_ack), .fw_din(fw_din),
    .in0(8'hff), .in1(8'hff), .in2(8'hff),
    .dsw1(8'hff), .dsw2(8'hff), .dsw3(8'hff),
    .dp_busy(1'b0),
    .adc0(8'h80), .adc1(8'h80), .adc2(8'h01), .adc3(8'hff),
    .z_we(z_we), .z_addr(z_addr), .z_wdata(z_wdata), .z_rdata(z_rdata),
    .dbg_ee(), .dbg_wrcnt(), .dbg_wr_stb(), .dbg_dout(), .dbg_di(),
    .dbg_rd_end(), .dbg_ra(), .dbg_rdat(), .dbg_m1_n(dbg_m1_n), .dbg_a(dbg_a),
    .dbg_last_wr(), .dbg_pf(), .dbg_pa(), .dbg_seccnt()
  );

  // Z80 clocks, from the board's own pacing, so limits are in board time.
  longint zclk = 0;
  always_ff @(posedge clk) if (dut.cen) zclk <= zclk + 1;

  int checks = 0, fails = 0;
  task automatic chk(input bit ok, input string what);
    checks++;
    if (!ok) begin fails++; $display("  FAIL %s (z80 pc~%04h, zclk %0d)", what, last_pc, zclk); end
  endtask

  logic [15:0] last_pc;
  always_ff @(posedge clk) if (!dbg_m1_n) last_pc <= dbg_a;
  // PCTRACE=<n>: the first n opcode-fetch addresses, and every firmware word
  // the fetch port returns. /M1 is sampled on a read's FIRST clock: tv80's /M1
  // rises a clock before its /RD does (see m1_ioz80's notes on the strobes).
  int pct_n = 0, fwt_n = 0;
  logic rd_d;
  always_ff @(posedge clk) begin
    rd_d <= !dut.mreq_n && !dut.rd_n;
    if (PCTRACE != 0 && pct_n < PCTRACE && !dut.mreq_n && !dut.rd_n && !rd_d && !dbg_m1_n) begin
      $display("  PC %04h", dbg_a);
      pct_n <= pct_n + 1;
    end
    if (PCTRACE != 0 && fw_ack && fw_word < 14'h2000 && fwt_n < PCTRACE) begin
      $display("  FW word %04h -> %04h (A=%04h)", fw_word, fw_din, dbg_a);
      fwt_n <= fwt_n + 1;
    end
  end
  // PROGRESS=<n>: print where the firmware is every n board clocks.
  always_ff @(posedge clk)
    if (PROGRESS != 0 && dut.cen && zclk % PROGRESS == 0 && zclk != 0)
      $display("  .. zclk %0d pc~%04h 20=%02h 21=%02h int=%0d ius=%b",
               zclk, last_pc, dp[12'h020], dp[12'h021], dut.ctc_int, dut.ctc.ius);

  // Wait, in board clocks, for a DPRAM byte to hold a value.
  task automatic wait_dp(input int a, input logic [7:0] v, input string what,
                         output longint took);
    longint t0 = zclk;
    while (dp[a] !== v && (zclk - t0) < LIMIT) @(posedge clk);
    took = zclk - t0;
    chk(dp[a] === v, what);
  endtask

  task automatic v60_wr(input int a, input logic [7:0] v);
    // The V60's side of the DPRAM: no port of its own here, it just lands.
    @(posedge clk); dp[a] = v;
  endtask

  longint t;
  logic [7:0] blk [128];
  int bad;
  initial begin
    int fd;
    fd = $fopen(FWHEX, "r");
    if (fd == 0) begin
      $display("m1_ioz80[io2=%0d]: SKIPPED, no firmware at %s", IO2, FWHEX);
      $finish;
    end
    $fclose(fd);
    $readmemh(FWHEX, fw);

    repeat (8) @(posedge clk);
    rst_n = 1'b1;

    // 1. the V60's opening move
    v60_wr(12'h01a, 8'h53); v60_wr(12'h01b, 8'h45);
    v60_wr(12'h01c, 8'h47); v60_wr(12'h01d, 8'h41);
    v60_wr(12'h021, 8'h00); v60_wr(12'h020, 8'h01);
    wait_dp(12'h021, 8'h40, "board publishes 0x21 = 40h", t);
    $display("  board ready after %0d z80 clocks (MAME: ~2.15 s = %0d at 9.8304 MHz)",
             t, longint'(2.15 * 9830400.0));
    wait_dp(12'h020, 8'h00, "board clears the flag", t);

    // 3. command 3: read the settings block
    v60_wr(12'h021, 8'h00); v60_wr(12'h020, 8'h03);
    wait_dp(12'h020, 8'h00, "command 3 acknowledged", t);
    $display("  command 3 took %0d z80 clocks; block[0..7] = %02h %02h %02h %02h %02h %02h %02h %02h",
             t, dp[12'h100], dp[12'h101], dp[12'h102], dp[12'h103],
             dp[12'h104], dp[12'h105], dp[12'h106], dp[12'h107]);

    // 4. write a block, command 2
    for (int i = 0; i < 128; i++) begin
      blk[i] = 8'(i * 7 + 3);
      v60_wr(12'h100 + i, blk[i]);
    end
    wait_dp(12'h021, 8'h40, "0x21 = 40h before command 2", t);
    v60_wr(12'h020, 8'h02);
    wait_dp(12'h020, 8'h00, "command 2 acknowledged", t);
    $display("  command 2 took %0d z80 clocks (MAME cold boot: ~2.2 s)", t);
    wait_dp(12'h021, 8'h40, "0x21 = 40h after command 2", t);

    // 5. read it back
    for (int i = 0; i < 128; i++) v60_wr(12'h100 + i, 8'h00);
    v60_wr(12'h021, 8'h00); v60_wr(12'h020, 8'h03);
    wait_dp(12'h020, 8'h00, "command 3 after the write", t);
    bad = 0;
    for (int i = 0; i < 128; i++) if (dp[12'h100 + i] !== blk[i]) bad++;
    chk(bad == 0, "the settings block reads back as written");
    if (bad) $display("  %0d of 128 bytes differ", bad);

    // 6. the per-frame input scan
    for (int k = 0; k < 4; k++) begin
      v60_wr(12'h00f, 8'h00); v60_wr(12'h020, 8'h01);
      wait_dp(12'h020, 8'h00, "command 1 acknowledged", t);
    end
    chk(dp[12'h000] == 8'h80 && dp[12'h001] == 8'h80 && dp[12'h002] == 8'h01,
        "analog channels published at 0x00-0x02");
    chk(dp[12'h008] == 8'hff, "IN.0 published at 0x08");
    $display("  inputs: 00=%02h 01=%02h 02=%02h 08=%02h 09=%02h 0a=%02h 0e=%02h (MAME: 80 80 01 ff ff ff 0f)",
             dp[0], dp[1], dp[2], dp[8], dp[9], dp[10], dp[14]);

    $display("m1_ioz80[io2=%0d]: checks=%0d fails=%0d", IO2, checks, fails);
    $finish;
  end
endmodule
