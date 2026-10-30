// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m1_hmd_pose: NetMerc's head pose from the left stick, written into DPRAM
// 0x80-0x8b through the I/O side's byte port.
//
//   1. THE MAPPING, exhaustively: every one of the 65,536 stick values in each
//      of the four modes, against a reference written separately below.
//   2. NO TEARING. A model of the twelve bytes records which burst wrote each
//      one; a model V60 reads them as the game does (an ascending block, each
//      byte held on the bus for 2-5 cycles, 4-40 cycles apart, and now and then
//      an "interrupt" splitting the block for up to half the timeout), and
//      every complete block must come from ONE burst. Each byte must also be
//      stable for the whole of its read.
//   3. THE PORT: never a write in a Z80 cycle, never outside 0x80-0x8b, none
//      with the game id off, a byte retried until io_ack (random V60 writes
//      take the port).
//   4. THE VALUES a block reads: position 0,0,0, roll 25736, and yaw and pitch
//      equal to the reference for the stick of the moment whenever the stick
//      had settled before the burst.
//   5. FRESHNESS: the longest gap between bursts, and a block abandoned
//      part-way releases the writer.
//   6. THE SEED: during `seed` the forward pose is in place.
//
// Built twice (Makefile): TICK_W/TO_W at the hardware's 15/20, and narrow at
// 6/9 so the timeout and the tick wrap are reached thousands of times.

`timescale 1ns/1ps

module tb_m1_hmd_pose;
  parameter int TICK_W = 15;
  parameter int TO_W   = 20;
  parameter int CYCLES = 4_000_000;

  logic clk = 1'b0;
  always #1 clk = ~clk;

  logic        en, seed;
  logic [15:0] stick;
  logic [1:0]  mode;
  logic        v60_rd;
  logic [10:0] v60_idx;
  logic        z_we;
  logic        v60_wr;            // a V60 write to the DPRAM: takes the port
  wire         io_ack;
  wire         we;
  wire  [10:0] addr;
  wire  [7:0]  din;
  wire  [15:0] dbg_yaw, dbg_pitch;

  // m1_mainram: io_ack = io_we && !v60_dp_write, io_we = pose ? 1 : z_we.
  assign io_ack = (we || z_we) && !v60_wr;

  m1_hmd_pose #(.TICK_W(TICK_W), .TO_W(TO_W)) dut (
    .clk(clk), .en(en), .seed(seed), .stick(stick), .mode(mode),
    .v60_rd(v60_rd), .v60_idx(v60_idx),
    .z_we(z_we), .io_ack(io_ack),
    .we(we), .addr(addr), .din(din),
    .dbg_yaw(dbg_yaw), .dbg_pitch(dbg_pitch)
  );

  // ------------------------------------------------------------ reference
  function automatic int rdz(input logic [7:0] v);
    int iv, r;
    iv = int'($signed(v));
    if (iv > 15)       r = iv - 15;
    else if (iv < -15) r = iv + 15;
    else               r = 0;
    if (r > 112)  r = 112;
    if (r < -112) r = -112;
    return r;
  endfunction
  function automatic logic [15:0] ryaw(input logic [15:0] s, input logic [1:0] m);
    if (m >= 2) return 16'd12868;
    return 16'(12868 + 115 * rdz(s[7:0]));
  endfunction
  function automatic logic [15:0] rpitch(input logic [15:0] s, input logic [1:0] m);
    int d;
    if (m >= 2) return 16'd12868;
    d = rdz(s[15:8]);
    if (m == 1) d = -d;
    return 16'(12868 + 57 * d);
  endfunction

  int fails = 0, checks = 0;
  task automatic fail(input string msg);
    if (fails < 20) $display("FAIL @%0t: %s", $time, msg);
    fails++;
  endtask

  // ------------------------------------------------- the twelve bytes
  logic [7:0] mem   [12];
  int         bid   [12];
  int         bursts = 0;
  longint     cyc = 0, last_burst = 0, max_gap = 0;
  int         port_writes = 0, port_retries = 0;
  // What each burst should carry, by burst number: known only when the stick
  // had settled well before the burst started.
  logic [15:0] exp_yaw   [int];
  logic [15:0] exp_pitch [int];
  logic        exp_known [int];
  longint      stick_chg = 0;
  logic [15:0] stick_q;            // the settled value the stick was set to
  logic        free_run = 0;       // phase 2: the gap check is meaningful

  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (we && z_we)  fail("writer drove the port in a Z80 cycle");
    if (we && !en)   fail("writer active with the game id off");
    if (we && (addr < 11'h080 || addr > 11'h08b))
      fail($sformatf("write outside the pose: %03x", addr));
    if (we && !io_ack) port_retries++;
    if (we && io_ack) begin
      port_writes++;
      if (addr == 11'h080) begin
        bursts++;
        if (free_run && !seed && cyc - last_burst > max_gap) max_gap = cyc - last_burst;
        last_burst = cyc;
        exp_known[bursts] = (cyc - stick_chg > 24);
        exp_yaw[bursts]   = ryaw(stick_q, mode);
        exp_pitch[bursts] = rpitch(stick_q, mode);
      end
      mem[addr[3:0]] <= din;
      bid[addr[3:0]] <= bursts;
    end
  end

  // ------------------------------------------------- the model V60
  int blocks = 0, blocks_known = 0, split = 0, abandoned = 0;
  longint max_block = 0;
  logic reader_on = 0;
  task automatic read_byte(input int k, output logic [7:0] v, output int b);
    int hold;
    hold = 2 + ($urandom % 4);
    v60_idx = 11'h080 + 11'(k);
    v60_rd  = 1'b1;
    // m1_main captures the byte at the FIRST edge of the request: the RAM
    // registers dpram[addr] there and B_LOCAL takes it on the next. Sampled
    // before that edge's writes land - old data on a same-edge write, the
    // pessimistic reading of an M10K's mixed-port behaviour.
    @(posedge clk);
    v = mem[k]; b = bid[k];
    for (int h = 1; h < hold; h++) begin
      @(posedge clk);
      if (mem[k] !== v || bid[k] != b)
        fail($sformatf("byte %0d changed during its read", k));
    end
    #0.1;
    v60_rd = 1'b0;
  endtask

  task automatic read_block();
    logic [7:0] v [12];
    int         b [12];
    int         stop;
    longint t0;
    t0   = cyc;
    stop = (($urandom % 50) == 0) ? ($urandom % 11) : 12;   // 2%: abandon part-way
    for (int k = 0; k < 12; k++) begin
      if (k == stop) begin abandoned++; return; end
      read_byte(k, v[k], b[k]);
      if (k < 11) begin
        int gap;
        if (($urandom % 40) == 0) begin
          gap = $urandom % (1 << (TO_W - 1));       // an interrupt mid-block
          split++;
        end else gap = 4 + ($urandom % 37);
        repeat (gap) @(posedge clk);
      end
    end
    blocks++;
    if (cyc - t0 > max_block) max_block = cyc - t0;
    for (int k = 1; k < 12; k++)
      if (b[k] != b[0]) begin
        fail($sformatf("TORN block: byte 0 from burst %0d, byte %0d from burst %0d", b[0], k, b[k]));
        break;
      end
    begin
      logic [15:0] w [6];
      for (int i = 0; i < 6; i++) w[i] = {v[2*i+1], v[2*i]};
      checks++;
      if (w[0] != 0 || w[1] != 0 || w[2] != 0) fail("position words not zero");
      if (w[4] != 16'd25736) fail($sformatf("roll %0d", w[4]));
      if ($signed(w[3]) < 16'sd12868 - 16'sd12880 || $signed(w[3]) > 16'sd12868 + 16'sd12880)
        fail($sformatf("yaw out of range: %0d", w[3]));
      if ($signed(w[5]) < 16'sd12868 - 16'sd6384 || $signed(w[5]) > 16'sd12868 + 16'sd6384)
        fail($sformatf("pitch out of range: %0d", w[5]));
      if (exp_known.exists(b[0]) && exp_known[b[0]]) begin
        blocks_known++;
        if (w[3] != exp_yaw[b[0]] || w[5] != exp_pitch[b[0]])
          fail($sformatf("block yaw/pitch %0d/%0d (burst %0d) wants %0d/%0d",
                         w[3], w[5], b[0], exp_yaw[b[0]], exp_pitch[b[0]]));
      end
    end
  endtask

  initial begin
    v60_rd = 0; v60_idx = 0;
    wait (reader_on);
    forever begin
      repeat ($urandom % (3 << TICK_W)) @(posedge clk);
      if (!reader_on) wait (reader_on);
      read_block();
    end
  end

  // ------------------------------------- Z80 writes and V60 writes, random
  logic noise_on = 0;
  always @(negedge clk) begin
    z_we   <= noise_on && (($urandom % 50) == 0);
    v60_wr <= noise_on && !v60_rd && (($urandom % 33) == 0);
  end

  // A stick change lands over two edges, half the bits on each, so the
  // synchroniser sees a mixed value for a cycle.
  task automatic set_stick(input logic [15:0] s);
    stick_chg = cyc;
    stick_q   = s;
    @(negedge clk) stick = {stick[15:8], s[7:0]};
    @(negedge clk) stick = s;
  endtask

  // --------------------------------------------------------------- main
  int map_checks = 0;
  initial begin
    void'($urandom(32'h5e9a_1993));
    en = 1; seed = 1; mode = 0; stick = 16'h0000; stick_q = 0; z_we = 0; v60_wr = 0;

    // 6. The seed: forward in place while held.
    repeat (64) @(posedge clk);
    begin
      logic [15:0] w [6];
      for (int i = 0; i < 6; i++) w[i] = {mem[2*i+1], mem[2*i]};
      checks++;
      if (w[0] != 0 || w[1] != 0 || w[2] != 0 || w[3] != 16'd12868 ||
          w[4] != 16'd25736 || w[5] != 16'd12868)
        fail($sformatf("seed: %0d %0d %0d %0d %0d %0d", w[0], w[1], w[2], w[3], w[4], w[5]));
    end

    // 1. The mapping, every stick value in every mode.
    seed = 0;
    for (int m = 0; m < 4; m++) begin
      mode = 2'(m);
      for (int s = 0; s < 65536; s++) begin
        @(negedge clk) stick = 16'(s);
        repeat (5) @(posedge clk);
        #0.1;
        map_checks++;
        if (dbg_yaw != ryaw(16'(s), 2'(m)) || dbg_pitch != rpitch(16'(s), 2'(m)))
          fail($sformatf("map: stick %04x mode %0d -> %0d/%0d, want %0d/%0d",
                         s, m, dbg_yaw, dbg_pitch, ryaw(16'(s), 2'(m)), rpitch(16'(s), 2'(m))));
      end
    end
    $display("mapping: %0d checks", map_checks);

    // 3. Off: no writes at all.
    en = 0;
    repeat (4 << TICK_W) @(posedge clk);
    en = 1;

    // 2/4/5. Random traffic, each mode in turn.
    noise_on = 1; reader_on = 1; free_run = 1; last_burst = cyc;
    for (int m = 0; m < 4; m++) begin
      mode = 2'(m);
      for (longint c = 0; c < CYCLES / 4; ) begin
        int hold;
        hold = 1 + ($urandom % (8 << TICK_W));
        set_stick({8'($urandom), 8'($urandom)});
        repeat (hold) @(posedge clk);
        c += hold + 2;
      end
    end
    reader_on = 0;
    repeat (2 << TO_W) @(posedge clk);

    $display("hmd_pose[tick=%0d,to=%0d]: checks=%0d fails=%0d map=%0d blocks=%0d known=%0d split=%0d abandoned=%0d bursts=%0d writes=%0d retries=%0d max_gap=%0d max_block=%0d",
             TICK_W, TO_W, checks + map_checks, fails, map_checks, blocks, blocks_known,
             split, abandoned, bursts, port_writes, port_retries, max_gap, max_block);
    // A rewrite waits at most for the tick, then for the block in progress:
    // its whole length, plus the timeout if it was abandoned.
    if (max_gap > (1 << TICK_W) + max_block + (1 << TO_W) + 64)
      $display("FAIL: max gap %0d (block %0d)", max_gap, max_block);
    if (blocks_known == 0) $display("FAIL: no block was checked against the reference");
    $finish;
  end
endmodule
