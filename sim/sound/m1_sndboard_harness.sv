// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
//
// THE SOUND BOARD, BOOTED IN SIMULATION, BECAUSE THE BOARD CANNOT BE ASKED.
//
// Ported from Model 2's m2_sndboard_harness.sv, which already boots this same
// board design -- Model 1 and Model 2 share it, and MAME confirms the decode is
// identical (ROM 000000, RAM F00000, PCM1 C40000, PCM2 C60000, YM D00000).
//
// TWO THINGS DIFFER HERE AND BOTH ARE OURS:
//
//   1. THE WORK RAM IS EXTERNAL. Model 2 keeps the 68000's 64 KB in M10K; this
//      core moved it to SDRAM to fit, so the harness has to serve ram_req with
//      LATENCY. The 68000 touches RAM within a few instructions of reset, so a
//      broken handshake here is a board that never starts -- silently.
//
//   2. THE FM IS STUBBED (m1_ym_timer, timers and status only). MAME measures
//      the firmware reading D00000 985,000 times in 240 frames, about 4,100 a
//      frame, so whatever that register returns is load-bearing.
//
// dbg_pc is the oracle. MAME's :m1audio:sndcpu settles in its main loop at
// PC 0x1100 and drives both MultiPCMs; anything else is a hang, and where it
// stops names the cause.

module m1_sndboard_harness #(
  parameter int unsigned ROM_LAT = 6,     // clk_sys cycles, ~ an SDRAM burst
  parameter bit PCM_CACHE = 1'b1,
  parameter bit PCM_RATE  = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,

  // The testbench's view of the ROM port.
  output logic        rom_req,
  output logic [17:1] rom_addr,
  input  logic        rom_ack,
  input  logic [15:0] rom_data,

  // The externalised 68000 work RAM -- this core's change, served with latency.
  output logic        ram_req,
  output logic [15:1] ram_addr,
  output logic        ram_we,
  // THE WORK RAM IS ON-CHIP AGAIN (2026-09-16), so the bench can no longer see
  // it on the external port -- that port is tied off. Count the writes inside
  // the board instead, or the "never wrote work RAM" check fails on a CPU that
  // is working perfectly.
  output logic [31:0] dbg_wram_writes,
  output logic  [1:0] ram_be,
  output logic [15:0] ram_wdata,
  input  logic        ram_ack,
  input  logic [15:0] ram_data,

  // The link, so the board can be talked to.
  input  logic  [7:0] rx_data,
  input  logic        rx_valid,
  output logic        rx_ack,
  output logic  [7:0] tx_data,
  output logic        tx_valid,
  input  logic        tx_ack,

  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_insns,
  output logic [15:0] dbg_ym_writes,
  output logic [15:0] dbg_pcm_writes,
  // THE SAMPLE RATE, which this harness's own header says is "the thing that
  // is actually wrong" and which nothing was reading. One stereo sample per
  // pass over 28 slots against the chip's 10 MHz / 224 = 44,643 Hz says
  // outright whether the chip is keeping time -- amplitude does not.
  output logic [31:0] dbg_pcm_samples,
  output logic [15:0] dbg_pcm_under,
  // WHERE THE CHIP'S TIME GOES. A sample period is 28 slots x 8 ticks = 224 ce
  // nominal and measures ~990, so it spends most of its time not advancing --
  // but the counters above cannot say WHY. m2_multipcm's slot loop is
  //     else if (df_busy) ... else if (!rom_req) <advance>
  // so there are exactly three states and these count ce cycles in each.
  // Without the split, "the chip is slow" is as far as the diagnosis goes, and
  // a descriptor storm and a sample-fetch stall need different fixes.
  output logic [31:0] dbg_ce_adv,
  output logic [31:0] dbg_ce_romreq,
  output logic [31:0] dbg_ce_dfbusy,
  // STARTS vs COMPLETIONS. df_busy is high 70.8% of the time and the existing
  // completion log is EMPTY, which cannot both be incidental: either the
  // fetches never finish, or they finish and restart immediately. Counting
  // both ends separates those two, and they need opposite fixes.
  output logic [31:0] dbg_df_starts,
  output logic [31:0] dbg_df_done,
  // THE REGISTER TRAFFIC ITSELF, so it can be diffed against MAME's.
  // tools/mame_pcm_tap.lua taps segam1audio's 68000 and prints the real
  // sequence; if ours differs the driver or the bus is wrong, and if it
  // matches then m2_multipcm's interpretation is. Nothing compared them.
  output logic        dbg_pw_stb,
  output logic  [1:0] dbg_pw_addr,
  output logic  [7:0] dbg_pw_data,
  output logic        dbg_pw_chip,     // 0 = MULTIPCM 1, 1 = MULTIPCM 2
  output logic        dbg_bw_stb,      // a bank-select write
  // WHAT THE CHIP DECIDES, not just what it is told. A descriptor fetch and
  // the start address it yields -- MAME's init_sample reads index*12 and takes
  // start from bytes 0..2 big-endian. If the indices or the starts are wrong
  // every voice plays from the wrong place, which is a drone.
  // Does the YM timer ever actually interrupt? IRQ4 is the driver's sequencer
  // heartbeat; wiring it achieved nothing, so the question is whether
  // m1_ym_timer ever asserts it at all.
  // WHICH YM REGISTERS THE DRIVER WRITES. The timer is armed by 0x27 (load and
  // enable_irq bits) with the period in 0x24/0x25. If 0x27 never arrives with
  // those bits the sequencer can never tick, whatever the timer does.
  output logic        dbg_yw_stb,
  output logic  [7:0] dbg_yw_reg,
  output logic  [7:0] dbg_yw_val,
  output logic [15:0] dbg_irq4_n,
  output logic [15:0] dbg_irq2_n,
  output logic        dbg_df_stb,
  output logic  [8:0] dbg_df_sample,
  output logic [21:0] dbg_df_start,
  output logic  [7:0] dbg_bw_data,

  // Bus observation, so the testbench can follow instruction fetches without
  // reaching inside the CPU.
  output logic        pcm1_req, output logic [21:3] pcm1_addr,
  input  logic [63:0] pcm1_data, input  logic        pcm1_ack,
  output logic        pcm2_req, output logic [21:3] pcm2_addr,
  input  logic [63:0] pcm2_data, input  logic        pcm2_ack,

  output logic signed [15:0] snd_l,
  output logic signed [15:0] snd_r,

  // THE OUTPUT SAMPLE RATE, WHICH IS THE THING THAT IS ACTUALLY WRONG.
  //
  // Amplitude in the last tenth of a run measures whatever the music happens to
  // be playing and moves non-monotonically with fetch latency, which makes it
  // useless for the question at hand. The MULTIPCM emits one stereo sample per
  // pass over its 28 slots, so counting slot wraps counts samples, and
  // samples-per-second against the chip's own 10 MHz / 224 = 44,643 Hz says
  // outright whether it is keeping time. Taken by hierarchical reference so
  // nothing upstream is modified.
  output logic [15:0] obs_under,
  output logic  [4:0] obs_pcm_slot,

  // THE CACHE'S ANSWERS, so they can be checked against the ROM itself. A cache
  // was added for speed and never tested for CORRECTNESS, which is the wrong
  // way round: a cache that returns the wrong byte does not sound slow, it
  // sounds broken, and every measurement of the sample RATE would still look
  // fine while it did.
  output logic        obs_p1_req,
  output logic        obs_p1_ack,
  output logic [21:0] obs_p1_addr,
  output logic  [7:0] obs_p1_data,

  output logic        obs_as,
  output logic [23:0] obs_addr,
  output logic        obs_we
);

  // TICK_DEN MUST MATCH THE BENCH'S CLOCK, and it did not.
  //
  // m2_sound_board defaults to TICK_NUM 20 / TICK_DEN 50 because Model 2's
  // clk_sys is 50 MHz. This bench clocks at 80 MHz and passed neither, so it
  // ran the board at 80 x 20/50 = 32 MHz of enables against the 20 MHz it
  // should get -- 1.6x fast. The MULTIPCM then reported 71,456 samples/s
  // against its own 44,643 Hz, and that 1.60 ratio is exactly 80/50.
  //
  // Model1.sv passes TICK_NUM(20)/TICK_DEN(80). Any bench that does not match
  // the top level is measuring a machine nobody builds.
  m2_sound_board #(.PCM_CACHE(PCM_CACHE), .PCM_RATE(PCM_RATE),
                   .TICK_NUM(20), .TICK_DEN(80)) u_board (
    .clk(clk), .rst_n(rst_n),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ack(rx_ack),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ack(tx_ack),
    .rom_req(rom_req), .rom_addr(rom_addr),
    .ram_req(ram_req), .ram_addr(ram_addr), .ram_we(ram_we),
    .ram_be(ram_be), .ram_wdata(ram_wdata),
    .ram_ack(ram_ack), .ram_data(ram_data),
    .rom_ack(rom_ack), .rom_data(rom_data),
    .pcm1_rom_req(pcm1_req), .pcm1_rom_addr(pcm1_addr),
    .pcm1_rom_data(pcm1_data), .pcm1_rom_ack(pcm1_ack),
    .pcm2_rom_req(pcm2_req), .pcm2_rom_addr(pcm2_addr),
    .pcm2_rom_data(pcm2_data), .pcm2_rom_ack(pcm2_ack),
    .snd_l(snd_l), .snd_r(snd_r),
    .dbg_pc(dbg_pc), .dbg_insns(dbg_insns),
    .dbg_ym_writes(dbg_ym_writes), .dbg_pcm_writes(dbg_pcm_writes),
    .dbg_pcm_samples(dbg_pcm_samples), .dbg_pcm_lat(), .dbg_pcm_miss(),
    .dbg_pcm_under(dbg_pcm_under), .dbg_pcm_level()
  );

  assign obs_pcm_slot = u_board.u_pcm1.slot;
  assign obs_p1_req   = u_board.p1_creq;
  assign obs_p1_ack   = u_board.p1_cack;
  assign obs_p1_addr  = u_board.p1_caddr;
  assign obs_p1_data  = u_board.p1_cdata;
  assign obs_as   = u_board.as;
  assign obs_addr = u_board.addr;
  assign obs_we   = u_board.we;

  // Hierarchical, read-only, simulation only.
  //
  // The EDGE OF `as`, matching how m2_sound_board counts these itself. A first
  // attempt gated on `ds` and captured NOTHING while dbg_pcm_writes read 479 --
  // the counter and the trace disagreeing is how that showed up.
  logic as_dly;
  always_ff @(posedge clk) as_dly <= u_board.as;
  wire   acc_stb = u_board.as && !as_dly;
  assign dbg_pw_stb  = acc_stb && (u_board.sel_pcm1 || u_board.sel_pcm2) && u_board.we;
  assign dbg_pw_chip = u_board.sel_pcm2;
  assign dbg_pw_addr = u_board.addr[2:1];
  assign dbg_pw_data = u_board.oedb[7:0];
  assign dbg_bw_stb  = acc_stb && (u_board.sel_bnk1 || u_board.sel_bnk2) && u_board.we;
  assign dbg_bw_data = u_board.oedb[7:0];

  // A descriptor fetch completes when the chip leaves df_busy.
  logic dfb_d;
  // Counted on ce, because ce is what the slot loop advances on -- counting
  // clk would fold the 4:1 enable ratio into the answer and make every bucket
  // look four times bigger than it is.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dbg_ce_adv <= '0; dbg_ce_romreq <= '0; dbg_ce_dfbusy <= '0;
    end else if (u_board.ce_pcm1) begin
      if      (u_board.u_pcm1.df_busy) dbg_ce_dfbusy <= dbg_ce_dfbusy + 32'd1;
      else if (u_board.u_pcm1.rom_req) dbg_ce_romreq <= dbg_ce_romreq + 32'd1;
      else                             dbg_ce_adv    <= dbg_ce_adv    + 32'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin dbg_df_starts <= '0; dbg_df_done <= '0; end
    else begin
      if (!dfb_d &&  u_board.u_pcm1.df_busy) dbg_df_starts <= dbg_df_starts + 32'd1;
      if ( dfb_d && !u_board.u_pcm1.df_busy) dbg_df_done   <= dbg_df_done   + 32'd1;
    end
  end

  always_ff @(posedge clk) dfb_d <= u_board.u_pcm1.df_busy;
  assign dbg_df_stb    = dfb_d && !u_board.u_pcm1.df_busy;
  assign dbg_df_sample = u_board.u_pcm1.df_sample;
  assign dbg_df_start  = u_board.u_pcm1.desc_ram[u_board.u_pcm1.df_slot][21:0];

  always_ff @(posedge clk) begin
    if (!rst_n) dbg_wram_writes <= '0;
    else if (u_board.sel_ram && u_board.we && (!u_board.udsn || !u_board.ldsn))
      dbg_wram_writes <= dbg_wram_writes + 32'd1;
  end

  // TRACKED HERE, NOT READ OUT OF THE CHIP.
  //
  // This used to be `u_board.u_ym.reg_sel`, an internal of m1_ym_timer - so the
  // harness stopped compiling the moment jt12 went back in (2026-09-15), with
  // an error naming a dotted path rather than the swap that caused it.
  //
  // The register number is not the chip's secret: the 68000 writes it to the
  // ADDRESS port (A0 = 0, which is u_board.addr[1] here) and the value to the
  // DATA port (A0 = 1). Latching the address-port write reconstructs it from
  // the bus alone, so the probe works against m1_ym_timer, against jt12, and
  // against anything else with the same interface.
  logic [7:0] yreg_track;
  always_ff @(posedge clk) begin
    if (!rst_n) yreg_track <= 8'd0;
    else if (acc_stb && u_board.sel_ym && u_board.we && !u_board.addr[1])
      yreg_track <= u_board.oedb[7:0];
  end
  assign dbg_yw_stb = acc_stb && u_board.sel_ym && u_board.we && u_board.addr[1];
  assign dbg_yw_reg = yreg_track;
  assign dbg_yw_val = u_board.oedb[7:0];

  logic y_d, u_d;
  always_ff @(posedge clk) begin
    if (!rst_n) begin dbg_irq4_n <= 0; dbg_irq2_n <= 0; y_d <= 1'b1; u_d <= 1'b0; end
    else begin
      y_d <= u_board.ym_irq_n; u_d <= u_board.uart_irq_rx;
      if ( y_d && !u_board.ym_irq_n   && !(&dbg_irq4_n)) dbg_irq4_n <= dbg_irq4_n + 1;
      if (!u_d &&  u_board.uart_irq_rx && !(&dbg_irq2_n)) dbg_irq2_n <= dbg_irq2_n + 1;
    end
  end

  wire _unused = &{1'b0, ROM_LAT, 1'b0};
  wire _unused2 = &{1'b0, obs_under, 1'b0};

endmodule
