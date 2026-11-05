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
// THE NVRAM FILE END TO END (the MRA's <nvram index="7" size="65672">),
// through the RTL the core builds: the framework's sys/hps_io.sv (WIDE),
// sys_top's acknowledge logic (copied: ioctl_wait holds the acknowledge),
// m1_rom_loader, m1_nv_port, m1_sdram on sdram_model (unwritten words read
// 0xFFFF), m1_cdc_port and m1_ioz80 - a real Z80 executing a program served
// from SDRAM that bit-bangs the 93C46 as the I/O firmware does.
//
// The HPS side is Main_MiSTer's word sequence: FIO_FILE_INDEX, FIO_FILE_TX
// 0xff / 0xaa, FIO_FILE_TX_DAT, FIO_FILE_TX 0; arcade_nvm_load sends a
// zero-filled buffer of the MRA's size with the file over it, and only when a
// file exists; the save polls UIO_CHK_UPLOAD after the OSD line.
//
// Each round, with random defaults (index 3's EEPROM, index 6's RAMA), random
// EEPROM writes by the Z80 and random RAMA writes on port 0 (the V60's role),
// and a strobe spacing drawn per round (log-uniform 1-400 cycles):
//   boot 1  no file: EEPROM and RAMA are the defaults; the game writes; a
//           game reset reloads the WRITTEN EEPROM (the write-through); the
//           save uploads tag + EEPROM + RAMA, checked byte for byte
//   boot 2  that file: EEPROM and every RAMA word are the saved ones; a
//           second save is the same file
//   boot 3  the 256-byte file an old MRA left, zero-padded by Main: defaults
//   boot 4  the saved file with one tag bit flipped: defaults
//   boot 5  no index 3 and no file, SDRAM still holding the last image: the
//           EEPROM is erased (FFFF), as MAME's part with no region
//
// +nowait (NOWAIT=1): the HPS ignores ioctl_wait - the negative control; the
// upload must then FAIL at a short spacing.

`timescale 1ns/1ps

module tb_m1_nv_save #(
  parameter int ROUNDS = 4,
  parameter int SEED   = 1,
  parameter int IO2    = 0,
  parameter int NOWAIT = 0,
  // A real saved file (the board's), loaded as Main loads it: index 2, index 3
  // erased, no index 6, then the file on index 7. Checked word for word in
  // SDRAM, for reset staying held while it streams, and saved back unchanged.
  parameter string NVFILE = ""
);
  localparam int NVSZ = 65672;
  localparam logic [25:1] NV_BASE = 25'hFA0000;

  // ------------------------------------------------------------- clocks
  logic clk = 0, clk_cpu = 0;
  always #6.25  clk = ~clk;       // 80 MHz clk_sys
  always #16.97 clk_cpu = ~clk_cpu;   // 29.47 MHz clk_cpu

  // ------------------------------------------------------- the HPS bus
  logic        fp_enable = 0, io_enable = 0, io_clk = 0;
  logic [15:0] io_din = 0;
  wire  [45:0] HPS_BUS;
  wire  [35:0] EXT_BUS;
  wire         ioctl_wait;
  // sys_top.v's handshake: the acknowledge is withheld while ioctl_wait
  logic rack = 0, io_ack = 0;
  wire  io_strobe = ~rack & io_clk;
  wire  hold = NOWAIT ? 1'b0 : HPS_BUS[37];
  always @(posedge clk) if (~hold | io_strobe) begin rack <= io_clk; io_ack <= rack; end
  assign HPS_BUS[35] = fp_enable;
  assign HPS_BUS[34] = io_enable;
  assign HPS_BUS[33] = io_strobe;
  assign HPS_BUS[31:16] = io_din;
  assign HPS_BUS[45:38] = 8'd0;
  assign EXT_BUS[32] = 1'b0;

  wire        ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd, nv_save_req;
  wire [15:0] ioctl_index, ioctl_dout, ioctl_din;
  wire [26:0] ioctl_addr;
  /* verilator lint_off PINMISSING */
  hps_io #(.CONF_STR("Model1;;"), .WIDE(1)) hps_io (
    .clk_sys(clk), .HPS_BUS(HPS_BUS), .EXT_BUS(EXT_BUS),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
    .ioctl_din(ioctl_din), .ioctl_upload(ioctl_upload), .ioctl_rd(ioctl_rd),
    .ioctl_upload_req(nv_save_req), .ioctl_upload_index(8'd7)
  );
  /* verilator lint_on PINMISSING */

  // ------------------------------------------------------------ the core
  logic por_n = 0, game_rst_n = 0, save_btn = 0;
  wire  mem_ready, rom_loaded, ee_img, ldr_overflow, ldr_wait, nv_wait;
  assign ioctl_wait = ldr_wait | nv_wait;

  logic        wr_req, wr_ack;
  logic [25:1] wr_addr;
  logic [15:0] wr_din;
  logic [1:0]  wr_be;
  m1_rom_loader #(.CPU_SETTLE(64)) loader (
    .clk(clk), .rst(~por_n), .mem_ready(mem_ready),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ldr_wait),
    .sdr_wr_req(wr_req), .sdr_wr_addr(wr_addr), .sdr_wr_din(wr_din),
    .sdr_wr_be(wr_be), .sdr_wr_ack(wr_ack),
    .tgp_wr(), .tgp_addr(), .tgp_din(),
    .rom_loaded(rom_loaded), .snd_loaded(), .ee_img(ee_img), .overflow(ldr_overflow),
    .ucode_words(), .ucode_csum(), .sdram_csum(), .sdram_words()
  );

  localparam int NP = 5;
  logic [NP-1:0]       p_req, p_we, p_ack;
  logic [NP-1:0][25:1] p_addr;
  logic [NP-1:0][15:0] p_din;
  logic [NP-1:0][1:0]  p_be;
  logic [NP-1:0][63:0] p_dout;
  // port 0: the bench, in the V60's role (RAMA writes and reads)
  logic        b_req = 0, b_we = 0;
  logic [25:1] b_addr = 0;
  logic [15:0] b_din = 0;
  // port 4: m1_nv_port
  wire         p4_req, p4_we;
  wire  [25:1] p4_addr;
  wire  [15:0] p4_din;
  assign p_req  = {p4_req, 3'b000, b_req};
  assign p_we   = {p4_we, 3'b000, b_we};
  assign p_addr = {p4_addr, {3{25'd0}}, b_addr};
  assign p_din  = {p4_din, {3{16'd0}}, b_din};
  assign p_be   = {2'b11, 6'd0, 2'b11};

  logic        cke, cs_n, ras_n, cas_n, we_n, dq_oe_c, dq_oe_m;
  logic [1:0]  ba, dqm;
  logic [12:0] a;
  logic [15:0] dq_c2m, dq_m2c;
  int unsigned violations;
  logic [15:0] v_flags;
  m1_sdram #(.NP(NP), .T_REFI(600), .INIT_NOP(600)) sdram (
    .clk(clk), .rst_n(por_n), .ready(mem_ready), .rd_lat_sel(3'd3),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n),
    .sd_we_n(we_n), .sd_ba(ba), .sd_a(a), .sd_dqm(dqm),
    .sd_dq_o(dq_c2m), .sd_dq_oe(dq_oe_c), .sd_dq_i(dq_m2c),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_din(wr_din), .wr_be(wr_be), .wr_ack(wr_ack),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack),
    .dbg_req(), .dbg_grant(), .dbg_occ(), .dbg_wait1()
  );
  sdram_model #(.COL_BITS(10), .T_REFI(781), .REFI_SLACK(9), .DEFAULT_DATA(16'hffff)) device (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .ba(ba), .a(a), .dqm(dqm),
    .dq_i(dq_c2m), .dq_oe_i(dq_oe_c), .dq_o(dq_m2c), .dq_oe_o(dq_oe_m),
    .violations(violations), .v_flags(v_flags), .reads_served(), .writes_served()
  );

  // the I/O board: m1_ioz80 on clk_cpu, through its clock crossing
  wire        z_rst_n = por_n & game_rst_n & rom_loaded;
  wire        fw_req, fw_we, fw_ack;
  wire [13:0] fw_word;
  wire [15:0] fw_wdata, fw_din;
  wire        io_req, io_we, io_ack4;
  wire [25:1] io_addr;
  wire [15:0] io_wd, io_dout4;
  logic [1:0] ee_img_s;
  always @(posedge clk_cpu) ee_img_s <= {ee_img_s[0], ee_img};
  wire [15:0] dbg_a;
  m1_ioz80 u_z80 (
    .clk(clk_cpu), .rst_n(z_rst_n), .io2(IO2 != 0),
    .fw_req(fw_req), .fw_word(fw_word), .fw_we(fw_we), .fw_wdata(fw_wdata),
    .fw_ack(fw_ack), .fw_din(fw_din), .ee_img(ee_img_s[1]),
    .in0(8'hff), .in1(8'hff), .in2(8'hff), .dsw1(8'hff), .dsw2(8'hff), .dsw3(8'hff),
    .dp_busy(1'b0), .adc0(8'h80), .adc1(8'h20), .adc2(8'h20), .adc3(8'hff),
    .z_we(), .z_addr(), .z_wdata(), .z_rdata(8'hff),
    .dbg_ee(), .dbg_wrcnt(), .dbg_wr_stb(), .dbg_dout(), .dbg_di(), .dbg_rd_end(),
    .dbg_ra(), .dbg_rdat(), .dbg_m1_n(), .dbg_a(dbg_a), .dbg_last_wr(), .dbg_pf(),
    .dbg_pa(), .dbg_seccnt()
  );
  m1_cdc_port #(.AW(25), .DW(16), .BEW(2)) u_cdc (
    .a_clk(clk_cpu), .a_rst_n(z_rst_n),
    .a_req(fw_req), .a_we(fw_we), .a_addr(25'hD00000 + {11'd0, fw_word}),
    .a_din(fw_wdata), .a_be(2'b11), .a_dout(fw_din), .a_ack(fw_ack), .a_busy(),
    .b_clk(clk), .b_rst_n(por_n & game_rst_n),
    .b_req(io_req), .b_we(io_we), .b_addr(io_addr), .b_din(io_wd), .b_be(),
    .b_dout(io_dout4), .b_ack(io_ack4)
  );
  m1_nv_port u_nv (
    .clk(clk), .rst_n(por_n), .save_btn(save_btn), .save_req(nv_save_req),
    .ioctl_upload(ioctl_upload), .ioctl_rd(ioctl_rd), .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr), .ioctl_din(ioctl_din), .ioctl_wait(nv_wait),
    .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_din(io_wd),
    .io_ack(io_ack4), .io_dout(io_dout4),
    .p_req(p4_req), .p_we(p4_we), .p_addr(p4_addr), .p_din(p4_din),
    .p_ack(p_ack[4]), .p_dout(p_dout[4][15:0])
  );

  // ------------------------------------------------------------- checks
  int fails = 0, checks = 0, spacing = 4;
  task automatic check(input bit ok, input string msg);
    checks++;
    if (!ok) begin
      fails++;
      if (fails <= 30) $display("  FAIL @%0t: %s", $time, msg);
    end
  endtask

  // ------------------------------------------------------------ the HPS
  task automatic spi_w(input logic [15:0] w, output logic [15:0] r);
    io_din = w; io_clk = 1;
    do @(posedge clk); while (!io_ack);
    io_clk = 0;
    do @(posedge clk); while (io_ack);
    r = HPS_BUS[15:0];
    repeat (spacing) @(posedge clk);
  endtask
  task automatic spi_wr(input logic [15:0] w);
    logic [15:0] r; spi_w(w, r);
  endtask
  task automatic fpga_en(input bit on); fp_enable = on; repeat (3) @(posedge clk); endtask
  task automatic io_en(input bit on);   io_enable = on; repeat (3) @(posedge clk); endtask
  task automatic set_index(input int i);
    fpga_en(1); spi_wr(16'h55); spi_wr(16'(i)); fpga_en(0);
  endtask
  task automatic download(input int idx, ref byte unsigned bf[$]);
    set_index(idx);
    fpga_en(1); spi_wr(16'h53); spi_wr(16'hff); fpga_en(0);
    check(ioctl_download, $sformatf("download %0d did not start", idx));
    fpga_en(1); spi_wr(16'h54);
    for (int k = 0; k + 1 < bf.size(); k += 2) spi_wr({bf[k + 1], bf[k]});
    fpga_en(0);
    fpga_en(1); spi_wr(16'h53); spi_wr(16'h00); fpga_en(0);
    check(!ioctl_download, "download did not end");
  endtask
  // arcade_nvm_load: only with a file; a zero-filled buffer of the MRA's size
  task automatic nvm_load(ref byte unsigned file[$]);
    byte unsigned bf[$];
    for (int k = 0; k < NVSZ; k++) bf.push_back(k < file.size() ? file[k] : 8'h00);
    download(7, bf);
  endtask
  task automatic osd_save(output byte unsigned f[$]);
    logic [15:0] r;
    io_en(1); spi_w(16'h3c, r); io_en(0);
    check(r == 0, $sformatf("UIO_CHK_UPLOAD answered %04x before the save line", r));
    save_btn = 1; repeat (8) @(posedge clk); save_btn = 0; repeat (8) @(posedge clk);
    io_en(1); spi_w(16'h3c, r); io_en(0);
    check(r == 16'h0701, $sformatf("UIO_CHK_UPLOAD answered %04x, not 0701", r));
    io_en(1); spi_w(16'h3c, r); io_en(0);
    check(r == 0, $sformatf("UIO_CHK_UPLOAD answered %04x twice for one save", r));
    // arcade_nvm_save
    set_index(7);
    fpga_en(1); spi_wr(16'h53); spi_wr(16'haa); fpga_en(0);
    check(ioctl_upload, "upload did not start");
    f.delete();
    fpga_en(1); spi_wr(16'h54);
    for (int k = 0; k < NVSZ; k += 2) begin spi_w(16'h0, r); f.push_back(r[7:0]); f.push_back(r[15:8]); end
    fpga_en(0);
    fpga_en(1); spi_wr(16'h53); spi_wr(16'h00); fpga_en(0);
    check(!ioctl_upload, "upload did not end");
  endtask

  // ------------------------------------------------- the V60's RAMA port
  task automatic p0(input bit we, input int word, input logic [15:0] d, output logic [15:0] q);
    @(posedge clk);
    b_req <= 1; b_we <= we; b_addr <= NV_BASE + 25'(word); b_din <= d;
    @(posedge clk); b_req <= 0;
    do @(posedge clk); while (!p_ack[0]);
    q = p_dout[0][15:0];
    while (p_ack[0]) @(posedge clk);
  endtask

  // ------------------------------------------------ the Z80's program
  // The 93C46 as the firmware drives it: board 1 on PA (8000h) CLK 7, CS 6,
  // DI 5; board 2 on PF (8005h) CLK 5, CS 4, DI 6.
  byte unsigned prog[$];
  int sled;
  function automatic logic [7:0] pin(input bit cs, input bit ck, input bit di);
    return IO2 ? {1'b0, di, ck, cs, 4'd0} : {ck, cs, di, 5'd0};
  endfunction
  task automatic st(input logic [7:0] v);
    prog.push_back(8'h3e); prog.push_back(v);                       // ld a,v
    prog.push_back(8'h32); prog.push_back(IO2 ? 8'h05 : 8'h00); prog.push_back(8'h80);   // ld (80xx),a
  endtask
  task automatic bitout(input bit b); st(pin(1, 0, b)); st(pin(1, 1, b)); endtask
  task automatic cmd9(input logic [8:0] c);
    st(pin(0, 0, 0)); st(pin(1, 0, 0));
    for (int i = 8; i >= 0; i--) bitout(c[i]);
  endtask
  task automatic make_prog(input int n, input int wa[64], input logic [15:0] wd[64]);
    prog.delete();
    prog.push_back(8'hf3);                                  // di
    cmd9(9'b1_00_110000); st(pin(0, 0, 0));                 // EWEN
    for (int k = 0; k < n; k++) begin
      cmd9({3'b1_01, 6'(wa[k])});
      for (int i = 15; i >= 0; i--) bitout(wd[k][i]);
      st(pin(0, 0, 0));
    end
    sled = prog.size();
    repeat (300) prog.push_back(8'h00);                      // a NOP sled: fetches
    prog.push_back(8'hc3); prog.push_back(8'(sled)); prog.push_back(8'(sled >> 8));
  endtask

  // ------------------------------------------------------------ helpers
  logic [15:0] ee_def[64], ee_exp[64];
  logic [15:0] ram_def[32768], ram_exp[32768];

  task automatic power_on(input bit send_ee, input bit send_ram, input bit has_file,
                          ref byte unsigned file[$]);
    byte unsigned bf[$];
    game_rst_n = 0; por_n = 0;
    repeat (20) @(posedge clk);
    por_n = 1;
    wait (mem_ready);
    bf = prog; download(2, bf);
    if (send_ee) begin
      bf.delete();
      for (int i = 0; i < 64; i++) begin bf.push_back(ee_def[i][7:0]); bf.push_back(ee_def[i][15:8]); end
      download(3, bf);
    end
    if (send_ram) begin
      bf.delete();
      for (int i = 0; i < 32768; i++) begin bf.push_back(ram_def[i][7:0]); bf.push_back(ram_def[i][15:8]); end
      download(6, bf);
    end
    if (has_file) nvm_load(file);
    game_rst_n = 1;
    wait (rom_loaded);
    fork : w
      wait (u_z80.ee_ready);
      begin repeat (2_000_000) @(posedge clk_cpu); check(0, "the EEPROM preload never finished"); end
    join_any
    disable w;
    repeat (10) @(posedge clk_cpu);
  endtask

  task automatic expect_ee(input logic [15:0] e[64], input string what);
    int miss = 0;
    for (int i = 0; i < 64; i++)
      if (u_z80.ee[i] !== e[i]) begin
        if (miss++ < 3) check(0, $sformatf("%s: EEPROM word %0d is %04x, expected %04x", what, i, u_z80.ee[i], e[i]));
      end else checks++;
    if (miss > 3) check(0, $sformatf("%s: %0d EEPROM words wrong", what, miss));
  endtask
  task automatic expect_ram(input logic [15:0] e[32768], input string what);
    int miss = 0;
    logic [15:0] q;
    for (int i = 0; i < 32768; i++) begin
      p0(0, i, 16'h0, q);
      if (q !== e[i]) begin
        if (miss++ < 3) check(0, $sformatf("%s: RAMA word %04x is %04x, expected %04x", what, i, q, e[i]));
      end else checks++;
    end
    if (miss > 3) check(0, $sformatf("%s: %0d RAMA words wrong", what, miss));
  endtask
  function automatic void build_file(output byte unsigned f[$]);
    byte unsigned tg[8] = '{8'h4d, 8'h31, 8'h4e, 8'h56, 8'h52, 8'h41, 8'h4d, 8'h31};   // M1NVRAM1
    f.delete();
    foreach (tg[i]) f.push_back(tg[i]);
    for (int i = 0; i < 64; i++) begin f.push_back(ee_exp[i][7:0]); f.push_back(ee_exp[i][15:8]); end
    for (int i = 0; i < 32768; i++) begin f.push_back(ram_exp[i][7:0]); f.push_back(ram_exp[i][15:8]); end
  endfunction
  task automatic expect_file(ref byte unsigned got[$], ref byte unsigned want[$], input string what);
    int miss = 0;
    check(got.size() == want.size(), $sformatf("%s: %0d bytes, expected %0d", what, got.size(), want.size()));
    for (int k = 0; k < want.size() && k < got.size(); k++)
      if (got[k] !== want[k]) begin
        if (miss++ < 4) check(0, $sformatf("%s: byte %05x is %02x, expected %02x", what, k, got[k], want[k]));
      end else checks++;
    if (miss > 4) check(0, $sformatf("%s: %0d bytes wrong", what, miss));
  endtask
  // A watchdog, so a Z80 held for good (a write-through that never completes)
  // is a FAIL rather than a bench that never ends.
  task automatic wait_sled();
    int seen = 0, n = 0;
    while (seen < 3 && n < 20_000_000) begin
      @(posedge clk_cpu); n++;
      if (dbg_a == 16'(sled)) begin seen++; while (dbg_a == 16'(sled)) @(posedge clk_cpu); end
    end
    check(seen == 3, "the Z80 never reached its loop: held, or lost");
  endtask

  // Nothing the loader holds in reset may run while a stream is arriving.
  int released_during_dl = 0;
  always @(posedge clk) if (ioctl_download && rom_loaded) released_during_dl++;

  task automatic run_file();
    byte unsigned f[$], got[$], none[$];
    int fd, c, miss, n;
    logic [15:0] q, w;
    fd = $fopen(NVFILE, "rb");
    if (fd == 0) begin $display("m1_nv_save: SKIPPED, no file %s", NVFILE); return; end
    while ((c = $fgetc(fd)) != -1) f.push_back(8'(c));
    $fclose(fd);
    check(f.size() == NVSZ, $sformatf("the file is %0d bytes", f.size()));
    $display("file %s: %0d bytes", NVFILE, f.size());
    for (int i = 0; i < 64; i++) ee_def[i] = 16'hffff;
    make_prog(0, '{default: 0}, '{default: 16'h0});
    power_on(1, 0, 1, f);
    // the EEPROM as the Z80 sees it, and as SDRAM holds it
    miss = 0;
    n = 64;
    for (int i = 0; i < n; i++) begin
      w = {f[8 + 2*i + 1], f[8 + 2*i]};
      if (u_z80.ee[i] !== w) begin if (miss++ < 4) check(0, $sformatf("EEPROM word %0d is %04x, the file %04x", i, u_z80.ee[i], w)); end
      else checks++;
    end
    // RAMA, every word, through the V60's port
    miss = 0;
    // A run-time bound and no declaration in the body. With a constant bound
    // the loop and its p0 call were expanded, and the build took 25 GB.
    n = 32768;
    for (int i = 0; i < n; i++) begin
      w = {f[32'h88 + 2*i + 1], f[32'h88 + 2*i]};
      p0(0, i, 16'h0, q);
      if (q !== w) begin if (miss++ < 4) check(0, $sformatf("RAMA word %04x is %04x, the file %04x", i, q, w)); end
      else checks++;
    end
    check(miss == 0, $sformatf("%0d RAMA words differ from the file", miss));
    check(released_during_dl == 0, $sformatf("reset released for %0d cycles while a stream was arriving", released_during_dl));
    wait_sled();
    osd_save(got);
    expect_file(got, f, "the board's file saved back");
    $display("m1_nv_save[file]: checks=%0d fails=%0d", checks, fails);
    $finish;
  endtask

  // ------------------------------------------------------------ the run
  initial begin
    int unsigned s = SEED;
    byte unsigned saved[$], got[$], none[$], old[$], bad[$];
    int wa[64];
    logic [15:0] wd[64], q;
    int nwr, nram;
    if ($test$plusargs("nowait") && NOWAIT == 0) $display("use -GNOWAIT=1");
    if (NVFILE != "") run_file();
    for (int r = 0; r < ROUNDS; r++) begin
      // spacing log-uniform 1..400 (round 0 the tightest the HPS can be)
      spacing = (r == 0) ? 1 : int'($exp($ln(1.0) + ($urandom(s + r) % 1000) / 1000.0 * $ln(400.0)));
      void'($urandom(s * 7 + r));
      for (int i = 0; i < 64; i++) ee_def[i] = 16'($urandom);
      for (int i = 0; i < 32768; i++) ram_def[i] = 16'($urandom);
      if (r == 1) for (int i = 0; i < 32768; i++) ram_def[i] = 16'hffff;   // the FF-filled default
      nwr = 1 + ($urandom % 24);
      for (int k = 0; k < nwr; k++) begin wa[k] = $urandom % 64; wd[k] = 16'($urandom); end
      make_prog(nwr, wa, wd);
      $display("round %0d: spacing %0d, %0d EEPROM writes, program %0d bytes", r, spacing, nwr, prog.size());

      // boot 1 -----------------------------------------------------------
      power_on(1, 1, 0, none);
      expect_ee(ee_def, "boot 1, before the game");
      ee_exp = ee_def; ram_exp = ram_def;
      for (int k = 0; k < nwr; k++) ee_exp[wa[k]] = wd[k];
      wait_sled();
      expect_ee(ee_exp, "boot 1, the firmware's writes");
      nram = 1 + ($urandom % 400);
      for (int k = 0; k < nram; k++) begin
        int w = $urandom % 32768;
        ram_exp[w] = 16'($urandom);
        p0(1, w, ram_exp[w], q);
      end
      // a game reset: the EEPROM comes back as the firmware left it
      game_rst_n = 0; repeat (40) @(posedge clk_cpu); game_rst_n = 1;
      wait (u_z80.ee_ready); repeat (10) @(posedge clk_cpu);
      // the program rewrites the same words, so the reload is checked before it does
      expect_ee(ee_exp, "boot 1, after a game reset");
      wait_sled();
      osd_save(got);
      build_file(saved);
      expect_file(got, saved, "boot 1 save");

      // boot 2 -----------------------------------------------------------
      power_on(1, 1, 1, saved);
      expect_ee(ee_exp, "boot 2, the saved EEPROM");
      expect_ram(ram_exp, "boot 2, the saved RAMA");
      // the program writes its words again; a save in the middle would hold an
      // earlier value of a word it writes twice, as a real one would
      wait_sled();
      osd_save(got);
      expect_file(got, saved, "boot 2 save");

      // boot 3 -----------------------------------------------------------
      old.delete(); for (int k = 0; k < 256; k++) old.push_back((r & 1) ? 8'($urandom) : 8'h00);
      power_on(1, 1, 1, old);
      expect_ee(ee_def, "boot 3, an old 256-byte file");
      expect_ram(ram_def, "boot 3, an old 256-byte file");

      // boot 4 -----------------------------------------------------------
      bad = saved; bad[$urandom % 8] ^= 8'(1 << ($urandom % 8));
      power_on(1, 1, 1, bad);
      expect_ee(ee_def, "boot 4, a damaged tag");
      expect_ram(ram_def, "boot 4, a damaged tag");

      // boot 5 -----------------------------------------------------------
      for (int i = 0; i < 64; i++) ee_exp[i] = 16'hffff;
      power_on(0, 1, 0, none);
      expect_ee(ee_exp, "boot 5, no index 3");
    end
    check(violations == 0, $sformatf("%0d SDRAM protocol violations (flags %04x)", violations, v_flags));
    check(!ldr_overflow, "loader buffer overflow");
    $display("m1_nv_save[io2=%0d%s]: checks=%0d fails=%0d", IO2, NOWAIT ? ",nowait" : "", checks, fails);
    $finish;
  end
endmodule
