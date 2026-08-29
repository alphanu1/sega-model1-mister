//============================================================================
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
// Real game code through the real video path, captured as an image.
//
// WHY THIS EXISTS
//
// Two things are verified and one thing between them is not. m1_video is
// checked against MAME at 380,929 pixels — driven by synthetic tile data.
// Boot is checked against real ROM — with the video absent, because
// tb_m1_boot does not instantiate it. m1_integrated is what connects them and
// has never been simulated at all.
//
// So "real boot code fills tile RAM and the renderer turns that into a
// picture" has been an inference from two separate results. This observes it.
// The alternative was to find out on hardware after a Quartus compile, where
// a black screen has a dozen possible causes and no visibility into any of
// them.
//
// It runs the whole design: both clock domains, the SDRAM controller against
// the device model, the ROM stream preloaded, the CPU booting, the tilemap
// engine fetching characters through the same arbiter the CPU is using. The
// framebuffer is overwritten every frame and dumped at the end, so whatever
// state the machine reached is what comes out.
//
// NO 3D. There is no TGP and no rasterizer here, so the polygon field is
// empty by construction. What should appear is whatever the 2D tilemap layers
// hold — boot text, a test screen, or the game's HUD.
//============================================================================
`timescale 1ns/1ps

module tb_m1_frame #(
    // LONGINT, NOT INTEGER. `integer` is 32-bit signed, so a request beyond
    // 2,147,483,647 cycles wraps negative and the run ends immediately while
    // reporting a perfectly normal $finish — a 3.6e9 request produced 32 frames
    // and looked like a completed 2,400-frame run. Reaching the state the board
    // is actually in needs about 3.6e9, so this has to be 64-bit.
    parameter longint RUN_CYCLES = 120000000,
    parameter string  ROMHEX     = "build/rom/vr_v60.hex",
    parameter string  PPMOUT     = "build/frame.ppm",
    parameter string  TRAMOUT    = "build/frame_tram.hex",
    parameter string  DPRAMOUT   = "build/frame_dpram.hex",
    parameter string  PALOUT     = "build/frame_pal.hex",

    // One line per frame: backdrop share, per-tilemap census, window control and
    // the V60's PC. Off by default because a long run prints hundreds of lines.
    parameter integer TRACE_FRAMES = 0,

    // HOW THE ROM GETS INTO MEMORY, WHICH IS NOT A DETAIL
    //
    // DOWNLOAD=0 pokes the image straight into the SDRAM model before the run.
    // That is fast and it isolates the CPU and video path, but it means the
    // memory is already correct at the instant the V60 is released — a
    // condition hardware never provides.
    //
    // DOWNLOAD=1 streams the same image through ioctl into m1_rom_loader,
    // which writes it to SDRAM through the controller's download port, exactly
    // as MiSTer does. Everything unwritten reads 0xFFFF rather than zero, so a
    // CPU that starts early reads what an empty SDRAM really looks like
    // instead of a convenient field of zeros.
    parameter bit     DOWNLOAD   = 1,

    // Kept only so the deadlock this test was written to catch can still be
    // recreated deliberately. HOLD_CPU=1 feeds the core's mem_ready with
    // `mem_ready & <the loader's own done>`, which is the wiring that froze
    // "Assembling ROM" at zero bytes on hardware: the loader holds ioctl_wait
    // until SDRAM is ready, and SDRAM is not reported ready until the loader
    // has finished. The V60's gate is derived inside m1_integrated now, so
    // HOLD_CPU=0 is both the default and the correct wiring.
    parameter bit     HOLD_CPU   = 0,

    // A control to hold down for the whole run, as the byte the I/O board
    // publishes at DPRAM 0x08 (IN.0). Idle is 0xFF and a press is a bit going
    // low: 0xEF holds START, 0xFE COIN, 0xFB TEST. Whether the menu reacts is
    // the only test of the recovered layout that means anything.
    parameter logic [7:0] PRESS_IN0 = 8'hff,

    // Emit one line per retired instruction, for tools/v60_trace.sh to diff
    // against MAME's own debugger trace. Off by default: it is a firehose.
    parameter bit     PCTRACE    = 0,

    // Every CPU write, in order, with the PC that made it — the counterpart to
    // PCTRACE. Identical instruction streams with different memory means a write
    // went somewhere different, and this is what finds it.
    parameter bit     WRTRACE    = 0
);

// Covers the coprocessor's regions as well: copro_data at word 0x300000 and the
// math tables at 0x400000. Stopping at the V60 image leaves the TGP reading
// 0xFFFF and the V60 stalls, which is a picture of the wrong machine.
localparam integer PRELOAD_WORDS = 32'h420000;

// THE CLOCKS ARE THE BOARD'S, NOT ROUND NUMBERS.
//
// This used to run 100/25 MHz on the reasoning that "the ratio is what the
// crossings care about". That reasoning is untested: the two domains are cut
// with set_clock_groups -asynchronous, so nothing in the fitter ever times a
// path between them, and a crossing that depends on the ratio would pass every
// simulation at 4.000 and fail on hardware at 4.167.
//
// 80 MHz is 12.5 ns and 19.2 MHz is 52.0833... ns, which does not land on the
// 1 ns timescale — so the CPU half period is 26 ns, giving 19.23 MHz. The error
// is 0.16%, and what matters is that the edges drift against each other the way
// the real ones do instead of lining up every fourth cycle forever.
reg clk = 0, clk_cpu = 0, rst_n = 0;
always #6.25 clk     = ~clk;      // 80 MHz
always #26   clk_cpu = ~clk_cpu;  // 19.23 MHz

reg [1:0] rs_sys = 0, rs_cpu = 0;
wire rst_n_sys = rs_sys[1];
wire rst_n_cpu = rs_cpu[1];
always @(posedge clk     or negedge rst_n) if (!rst_n) rs_sys <= 0; else rs_sys <= {rs_sys[0], 1'b1};
always @(posedge clk_cpu or negedge rst_n) if (!rst_n) rs_cpu <= 0; else rs_cpu <= {rs_cpu[0], 1'b1};

// 80 MHz to the 16 MHz dot clock, exactly /5 — the same divider Model1.sv uses.
reg [2:0] pixdiv = 0;
reg       ce_pix = 0;
always @(posedge clk) begin
    ce_pix <= (pixdiv == 3'd4);
    pixdiv <= (pixdiv == 3'd4) ? 3'd0 : pixdiv + 3'd1;
end

// ------------------------------------------------------------------ memory
wire        sdr_req, sdr_we;
wire [24:1] sdr_addr;
wire [15:0] sdr_din;
wire  [1:0] sdr_be;
wire        ifp_req;
wire [24:1] ifp_addr;
wire        char_req;
wire [17:0] char_addr;

wire [4:0]       p_req, p_we, p_ack;
wire [4:0][24:1] p_addr;
wire [4:0][15:0] p_din;
wire [4:0][1:0]  p_be;
wire [4:0][63:0] p_dout;

assign p_req  = {rb_req, tgp_mem_req, ifp_req, char_req, sdr_req};
assign p_we   = {2'b00, 1'b0,    1'b0,              sdr_we};
// Character RAM lives at CHAR_BASE in SDRAM, exactly where m1_main maps the
// CPU's writes to 0x780000-0x7fffff. The renderer emits an offset within that
// region, so the base has to be added here — without it the tilemap fetches
// from word 0, which is V60 program ROM, and every glyph decodes from the same
// wrong data. 31 distinct tile numbers then render identically and the screen
// is a uniform pattern that looks like a video bug rather than an address one.
assign p_addr = {rb_addr, {tgp_mem_addr[24:2], 1'b0}, ifp_addr,
                 24'hFA8000 + {6'd0, char_addr}, sdr_addr};
assign p_din  = {16'd0, 16'd0, 16'd0,    16'd0,             sdr_din};
assign p_be   = {2'd0,  2'd0,  2'd0,     2'd0,              sdr_be};

// ROM download, wired exactly as Model1.sv wires it.
wire        ioctl_wait;
reg         ioctl_download = 0, ioctl_wr = 0;
reg  [26:0] ioctl_addr = 0;
reg  [15:0] ioctl_dout = 0;
wire        ldr_wr_req, ldr_wr_ack;
wire [24:1] ldr_wr_addr;
wire [15:0] ldr_wr_din;
wire  [1:0] ldr_wr_be;
wire        loader_done;

wire        cke, cs_n, ras_n, cas_n, we_n;
wire [1:0]  ba, dqm;
wire [12:0] a;
wire [15:0] dq_c2m, dq_m2c;
wire        dq_oe_c, dq_oe_m;
wire [15:0] v_flags;
wire        mem_ready;

m1_sdram #(.NP(5), .INIT_NOP(600)) sdram (
    .clk(clk), .rst_n(rst_n_sys), .ready(mem_ready),
    .rd_lat_sel(2'd0),   // CL+3: sdram_model presents data on the same edge
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n),
    .sd_we_n(we_n), .sd_ba(ba), .sd_a(a), .sd_dqm(dqm),
    .sd_dq_o(dq_c2m), .sd_dq_oe(dq_oe_c), .sd_dq_i(dq_m2c),
    .wr_req(ldr_wr_req), .wr_addr(ldr_wr_addr), .wr_din(ldr_wr_din),
    .wr_be(ldr_wr_be), .wr_ack(ldr_wr_ack),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack),
    .dbg_req(), .dbg_grant()
);

// Unwritten memory reads all ones when the ROM has to arrive over ioctl, which
// is what an SDRAM the loader has not reached actually looks like. With a
// preloaded image every location is written before the run, so the default
// never shows.
sdram_model #(.COL_BITS(9), .DEFAULT_DATA(DOWNLOAD ? 16'hFFFF : 16'h0000)) device (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .ba(ba), .a(a), .dqm(dqm),
    .dq_i(dq_c2m), .dq_oe_i(dq_oe_c), .dq_o(dq_m2c), .dq_oe_o(dq_oe_m),
    .violations(), .v_flags(v_flags), .reads_served(), .writes_served()
);

// ------------------------------------------------------------------- core
wire [7:0] vid_r, vid_g, vid_b;
wire       vid_hs, vid_vs, vid_hb, vid_vb;
wire [23:0] dbg_pc;
wire        dbg_halted, dbg_fp_trap;
wire [15:0] dbg_io_replies;
wire [15:0] dbg_overruns;

// mem_rst_n is the memory subsystem's own reset and must not follow the game
// reset: the loader holds ioctl_wait until SDRAM is ready, so a loader held in
// reset stalls the host that would release it. Model1.sv splits them for the
// same reason.
wire cpu_release = HOLD_CPU ? (mem_ready & loader_done) : mem_ready;

m1_integrated core (
    .clk_sys(clk), .ce_pix(ce_pix),
    .clk_cpu(clk_cpu), .ce_cpu(1'b1),
    .rst_n(rst_n), .mem_rst_n(rst_n), .mem_ready(cpu_release),
    // The control region as the board presents it at rest, with one byte
    // overridden. Not uniformly idle-high: the three ADC channels at 0x00-0x02
    // rest at 0x80 (steering centred) and 0x01 (each pedal released).
    .in_bytes({48'hffffffffffff,   // 0x0e..0x09
               PRESS_IN0,          // 0x08  IN.0
               40'hffffffffff,     // 0x07..0x03
               8'h01, 8'h01,       // 0x02, 0x01  pedals released
               8'h80}),            // 0x00        steering centred
    // m1_integrated's own ports: the microcode arrives through the loader on
    // index 1, and the coprocessor's read-only regions come off SDRAM port 3.
    .tgp_mem_req(tgp_mem_req), .tgp_mem_addr(tgp_mem_addr),
    .tgp_mem_dout(p_dout[3]), .tgp_mem_ack(p_ack[3]),
    // The read-back sweep, on the port that was tied off. Same logic the board
    // runs, so the printed value IS the expected value for row 0C.
    .rb_req(rb_req), .rb_addr(rb_addr), .rb_dout(p_dout[4]), .rb_ack(p_ack[4]),
    .dbg_rb_csum(f_rb_csum), .dbg_rb_csum0(f_rb_csum0), .dbg_rb_n(f_rb_n),
    .dbg_tgp_retires(f_tgp_retires), .dbg_tgp_pc(f_tgp_pc),
    .dbg_tgp_unimpl(f_tgp_unimpl),
    .dbg_copro_pushes(f_pushes), .dbg_copro_returns(f_returns),
    .dbg_copro_pops(f_pops),
    .dbg_layer_px(f_layer_px), .dbg_ctrl(f_ctrl),
    .dbg_layer_have(f_have_rtl),
    .dbg_tram_writes(f_tram_wr),
    .dbg_ucode_ram_csum(f_uc_csum), .dbg_ucode_ram_ok(f_uc_ok),
    .dbg_tgp_ram_writes(f_tgp_ramwr), .dbg_sync_word(f_sync_word),
    .dbg_tm0_writes(f_tm0_wr), .dbg_mask_writes(f_mask_wr),
    .dbg_tm0_text_writes(f_tm0_text), .dbg_tm0_first_pc(f_tm0_pc),
    .dbg_mask_nz_writes(f_mask_nz),
    .dbg_copro_rd_csum(f_rd_csum),
    .dbg_rd_a0(f_rd_a0), .dbg_rd_a1(f_rd_a1),
    .dbg_rd_a2(f_rd_a2), .dbg_rd_a3(f_rd_a3),
    .dbg_sdram_csum(f_sd_csum), .dbg_sdram_words(f_sd_words),

    .sdr_req(sdr_req), .sdr_we(sdr_we), .sdr_addr(sdr_addr),
    .sdr_din(sdr_din), .sdr_be(sdr_be),
    .sdr_dout(p_dout[0][15:0]), .sdr_ack(p_ack[0]),

    .if_req(ifp_req), .if_addr(), .if_sdram_addr(ifp_addr),
    .if_data(p_dout[2]), .if_ack(p_ack[2]),

    .char_req(char_req), .char_addr(char_addr),
    .char_data(p_dout[1][31:0]), .char_ack(p_ack[1]),

    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
    .ldr_wr_req(ldr_wr_req), .ldr_wr_addr(ldr_wr_addr),
    .ldr_wr_din(ldr_wr_din), .ldr_wr_be(ldr_wr_be), .ldr_wr_ack(ldr_wr_ack),

    .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
    .vid_hs(vid_hs), .vid_vs(vid_vs), .vid_hb(vid_hb), .vid_vb(vid_vb),

    .mon_sel(3'd0), .mon_snap(1'b0),
    .mon_req(), .mon_grant(), .mon_wait(), .mon_bmax(), .mon_total(),
    .mon_req_in(5'd0), .mon_grant_in(5'd0),

    .dbg_pc(dbg_pc), .dbg_halted(dbg_halted), .dbg_fp_trap(dbg_fp_trap),
    .dbg_io_replies(dbg_io_replies),
    .rom_loaded_o(loader_done), .dbg_fetches(), .dbg_overruns(dbg_overruns)
);

// ----------------------------------------------------- getting the ROM in
reg [15:0] rom [0:PRELOAD_WORDS-1];
reg [31:0] ucode [0:2047];

wire        tgp_mem_req;
wire [24:1] tgp_mem_addr;
wire [15:0] f_tgp_retires, f_tgp_pc, f_pushes, f_returns;
// WHAT THE COPROCESSOR POPS FROM THE COMMAND FIFO.
//
// tgp_trace parts at instruction 75,175 on `0052 brul alw d`, because
// d = get_exp(b) + 0x53 differs - 0x53 there, 0x64 here. b is loaded three
// instructions earlier by `004D: mov (x1), b` with x1 = 0x100, and 0x100 is not
// RAM: copro_data_map has map(0x0100,0x0100).r(m_copro_fifo_in), so that load is
// POPPING A COMMAND. Our decode matches - sel_fifo_in = (addr == 0x100) && !we -
// and our FIFO stalls correctly when empty, so the difference is the DATA the
// V60 pushed.
//
// The reference's first pops, captured with tools/tgp_x1.lua, alternate
// 00000000 and 01000000. get_exp(0) is 0x00, which is what MAME has at the
// divergence; ours gives 0x11, so the sequences part somewhere before it.
integer pop_n = 0, push_n = 0;
integer pop_f, push_f;
initial pop_f  = $fopen("build/frame_pops.txt",  "w");
initial push_f = $fopen("build/frame_pushes.txt", "w");
always @(posedge clk_cpu) begin
    // UNFILTERED, AND COMPARED AGAINST THE REFERENCE'S PUSHES.
    //
    // This capture was filtered to seq_pc == 0x004d to match tools/tgp_x1.lua,
    // which recorded pops only where GENPC == 0x4e. Both filters were then
    // dropped and the sequences compared again - and the reference's UNFILTERED
    // pops turn out to carry extra 00000000 entries that are not commands at
    // all: MAME's read tap fires on a read of an EMPTY fifo, which returns 0 and
    // is retried. We stall instead, so we never log those. Two instruments at
    // different levels, which is how "diverges at the first pop" was read out of
    // agreeing streams.
    //
    // The PUSH stream is the artefact-free comparator: v60_copro_fifo_w pushes
    // once per pair of 16-bit writes, so MAME's pushes are exactly the command
    // sequence, and every word pushed must be popped once in the same order.
    if (core.main.tgp.fifo_in_pop && pop_n < 300) begin
        pop_n = pop_n + 1;
        // pop_data is a REGISTER - `pop_data <= fifo_in_data` on this very
        // edge - so sampling it here yields the PREVIOUS pop, and the log came
        // out led by the reset value 00000000 and shifted one word behind. That
        // read as a phantom command and very nearly became a third false
        // finding in this same investigation. fifo_in_data is the head itself.
        $fwrite(pop_f, "%4d val=%08h\n", pop_n, core.main.tgp.fifo_in_data);
    end
    if (core.main.copro.st == 2'd0 && core.main.copro.v60_acc
        && core.main.copro.we && core.main.copro.sel_fifo
        && core.main.copro.a1 && !core.main.copro.fin_full
        && push_n < 300) begin
        push_n = push_n + 1;
        $fwrite(push_f, "%4d val=%04h%04h\n", push_n,
                core.main.copro.wdata, core.main.copro.lat_lo);
    end
end

// WHERE THE COPROCESSOR'S CYCLES ACTUALLY GO.
//
// In comparable windows - 15s of simulated time here against MAME's 16s - our
// TGP retires 395,631 instructions where the reference retires 11,367,862. Only
// 2.08x of that 29x gap is the clock (ours runs at clk_cpu's 19.2 MHz, the board
// runs the TGP at 40 MHz against a 16 MHz V60). The rest is stall, and these
// counters say WHICH stall rather than leaving it to be inferred.
//
// 64-bit, because dbg_retires inside m1_tgp is a 16-bit counter that WRAPS with
// no saturation - "retires=57660" out of that port is 57,660 + 65,536k and
// cannot be divided by a cycle count.
longint tgp_cycles = 0, tgp_retires = 0, tgp_memwait = 0, tgp_fifordwait = 0,
        tgp_fifowrwait = 0, v60_fifo_reads = 0, v60_fifo_pushed = 0;
always @(posedge clk_cpu) begin
    if (core.main.rst_n) begin
        tgp_cycles <= tgp_cycles + 1;
        if (core.main.tgp.core.retire)  tgp_retires    <= tgp_retires + 1;
        if (core.main.tgp.core.mem_req) tgp_memwait    <= tgp_memwait + 1;
        if (core.main.tgp.fifo_rd)      tgp_fifordwait <= tgp_fifordwait + 1;
        if (core.main.tgp.fifo_wr)      tgp_fifowrwait <= tgp_fifowrwait + 1;
        // AND WHAT THE V60 DOES ABOUT IT. The outbound FIFO is 16 deep and full
        // halts the producer, so if the V60 does not drain it the TGP stalls on
        // the push - which is what fifo_wr at 69% of cycles says is happening.
        // The reference's V60 reads the FIFO about 1,185 times a FRAME (710,722
        // over 600 frames, in I/O space via in.w). dbg_fifo_pops in the RTL is
        // 16 bits and WRAPS, so it cannot answer this; count it here instead.
        if (core.main.copro.st == 2'd0 && core.main.copro.v60_acc
            && !core.main.copro.we && core.main.copro.sel_fifo
            && !core.main.copro.a1)
          v60_fifo_reads <= v60_fifo_reads + 1;
        if (core.main.copro.fifo_out_push) v60_fifo_pushed <= v60_fifo_pushed + 1;
    end
end

// HOW OFTEN EACH SCROLL REGISTER CHANGES.
//
// The board scrolls the background VERTICALLY and flickers, where the reference
// drifts it horizontally: a MAME census over 2,000 frames found tilemap 2's hscr
// changing on 1,344 of them while vscr crept slowly. If ours is the other way
// round, the game is writing the axes we think it is and something else is
// wrong; if it matches, the difference is downstream.
//
// Counted per frame on the pair that draws the horizon: [5002] is its hscr and
// [5006] its vscr, which is also the ctrl word.
integer h_changes = 0, v_changes = 0, fr_seen = 0;
reg [15:0] h_prev = 16'hffff, v_prev = 16'hffff;
reg vbl_d = 0;
always @(posedge clk) begin
    vbl_d <= core.video.vblank_start;
    if (core.video.vblank_start && !vbl_d) begin
        fr_seen = fr_seen + 1;
        if ({core.main.rams.tram_v_hi['h5002], core.main.rams.tram_v_lo['h5002]} != h_prev) begin
            h_changes = h_changes + 1;
            h_prev = {core.main.rams.tram_v_hi['h5002], core.main.rams.tram_v_lo['h5002]};
        end
        if ({core.main.rams.tram_v_hi['h5006], core.main.rams.tram_v_lo['h5006]} != v_prev) begin
            v_changes = v_changes + 1;
            v_prev = {core.main.rams.tram_v_hi['h5006], core.main.rams.tram_v_lo['h5006]};
        end
    end
end

// Cumulative tile-RAM init writes, to compare directly against the board's row 05.
wire [11:0] f_tm0_wr, f_mask_wr;
wire [11:0] f_tm0_text;
wire [11:0] f_mask_nz;
wire [23:0] f_tm0_pc;   // board rows 0E and 0C
wire [11:0] f_tgp_ramwr;
wire [23:0] f_uc_csum;
wire        f_uc_ok;
wire [15:0] f_sync_word;   // board row 0D
wire [23:0] f_rd_csum;   // board row 06
wire [23:0] f_rd_a0, f_rd_a1, f_rd_a2, f_rd_a3;   // board rows 0C 0E 07 0B
wire [23:0] f_sd_csum, f_sd_words;   // board rows 07 and 0B
wire        rb_req;
wire [24:1] rb_addr;
wire [23:0] f_rb_csum;               // board row 0C
wire [23:0] f_rb_csum0;              // board row 0E, the control sweep
wire [12:0] f_rb_n;
// POPS is the question: on hardware the V60 pushes and the TGP never takes one,
// and a full 16-deep FIFO halts the CPU. m1_tgp's own suite pops 11 of 11 on this
// microcode, so if the whole system pops here the fault is hardware-only.
wire [15:0] f_pops;
wire        f_tgp_unimpl;
wire [17:0] f_layer_px [4];
wire [15:0] f_ctrl [2];
// The RTL's own content census, printed beside the testbench's direct read of
// tile RAM. They measure different things on purpose — the RTL counts words
// FETCHED on the displayed span, the testbench counts words PRESENT in the whole
// map — so they will not be equal. What matters is that they agree about zero,
// because zero is the reading the hardware instrument exists to give.
wire [11:0] f_have_rtl [4];
wire [11:0] f_tram_wr  [4];
integer i;
initial begin
    // Progress, flushed. stdout is block buffered when this is redirected to a
    // file, so a run that hangs prints nothing at all and is indistinguishable
    // from a run that is merely slow — which cost an hour of staring at an
    // empty log.
    $display("tb_m1_frame: DOWNLOAD=%0d HOLD_CPU=%0d, reading %s",
             DOWNLOAD, HOLD_CPU, ROMHEX);
    $fflush;
    $readmemh(ROMHEX, rom);
    for (i = 0; i < 2048; i = i + 1) ucode[i] = 32'h0;
    $readmemh("build/rom/vr_tgp_prog.hex", ucode);
    if (ucode[0] === 32'h0)
        $display("tb_m1_frame: *** no TGP microcode — run tools/build_tgp_rom.py ***");
    $display("tb_m1_frame: ROM image read");
    $fflush;
    if (!DOWNLOAD) begin
        for (i = 0; i < PRELOAD_WORDS; i = i + 1) device.mem[i] = rom[i];
        $display("preloaded %0d words", PRELOAD_WORDS);
    end else begin
        // Nothing to do: the model's storage is sparse and DEFAULT_DATA above
        // already makes every location the loader has not reached read as all
        // ones.
        $display("ROM will arrive over ioctl; unwritten SDRAM reads FFFF");
    end
end

// The HPS side of the download. hps_io is built WIDE, so this is one 16-bit
// word per write with ioctl_addr counting bytes.
//
// ioctl_wait IS OBSERVED, and that is the point of streaming it here rather
// than poking memory: the loader's flow control, the write port's one-at-a-time
// contract and the arbiter that the video path is also using are all in the
// path, at the same time, exactly as on hardware.
reg [15:0] ioctl_index = 16'd0;

integer dl_words = 0;
task automatic run_download;
    integer w;
    begin
        @(posedge clk);
        ioctl_download <= 1'b1;
        @(posedge clk);
        for (w = 0; w < PRELOAD_WORDS; w = w + 1) begin
            while (ioctl_wait) @(posedge clk);
            ioctl_wr   <= 1'b1;
            ioctl_addr <= w * 2;
            ioctl_dout <= rom[w];
            @(posedge clk);
            ioctl_wr   <= 1'b0;
            dl_words    = dl_words + 1;
            if ((dl_words % 262144) == 0) begin
                $display("  download: %0d/%0d words", dl_words, PRELOAD_WORDS);
                $fflush;
            end
            // The host does not issue back to back; one idle cycle between
            // words is the closest simple model of it.
            @(posedge clk);
        end
        ioctl_download <= 1'b0;
        $display("download: %0d words streamed", dl_words);
        $fflush;
    end
endtask

// THE MICROCODE IS A SECOND DOWNLOAD, ON INDEX 1.
//
// m1_rom_loader routes index 1 to the coprocessor's program RAM instead of to
// SDRAM. Without this pass the TGP executes zeros, and the V60 then stalls
// exactly as it did before the IN/OUT fix — so a frame rendered without it is a
// picture of the wrong machine.
task automatic run_ucode_download;
    integer w;
    begin
        @(posedge clk);
        ioctl_index    <= 16'd1;
        ioctl_download <= 1'b1;
        @(posedge clk);
        for (w = 0; w < 4096; w = w + 1) begin      // 2048 words x 2 halves
            while (ioctl_wait) @(posedge clk);
            ioctl_wr   <= 1'b1;
            ioctl_addr <= w * 2;
            ioctl_dout <= (w[0] == 1'b0) ? ucode[w >> 1][15:0]
                                         : ucode[w >> 1][31:16];
            @(posedge clk);
            ioctl_wr   <= 1'b0;
            @(posedge clk);
        end
        ioctl_download <= 1'b0;
        ioctl_index    <= 16'd0;
        $display("download: microcode streamed on index 1");
        $fflush;
    end
endtask

// ------------------------------------------------------------ frame capture
// Reported at the end: which tilemaps reached the screen, and whether the
// coprocessor ran. This is the whole point of rendering locally — it replaces
// photographing an overlay and guessing which row is which.
task automatic report_census;
    begin
        // 190464 = 496 x 384, a whole screen. A layer at or near that is
        // covering everything; the previous 16-bit counters pinned at 65535 and
        // could not say so.
        $display("FRAME: layer px per frame  tm0=%0d tm1=%0d tm2=%0d tm3=%0d  (full screen = %0d)",
                 f_layer_px[0], f_layer_px[1], f_layer_px[2], f_layer_px[3],
                 496 * 384);
        $display("FRAME: window ctrl  pair01=%04h pair23=%04h", f_ctrl[0], f_ctrl[1]);
        $display("FRAME: TGP cycles=%0d retires=%0d (%0d cyc/instr)  mem_req=%0d fifo_rd=%0d fifo_wr=%0d",
                 tgp_cycles, tgp_retires,
                 tgp_retires ? tgp_cycles / tgp_retires : 0,
                 tgp_memwait, tgp_fifordwait, tgp_fifowrwait);
        $display("FRAME: V60 read the result FIFO %0d times (%0d/frame; reference does ~1185), TGP pushed %0d results",
                 v60_fifo_reads, v60_fifo_reads / (frames ? frames : 1), v60_fifo_pushed);
        $display("FRAME: TGP retires=%0d pc=%04h unimpl=%0d  pushes=%0d pops=%0d returns=%0d",
                 f_tgp_retires, f_tgp_pc, f_tgp_unimpl, f_pushes, f_pops, f_returns);
    end
endtask

localparam integer W = 496;
localparam integer H = 384;

integer fb_r [0:H*W-1];
integer fb_g [0:H*W-1];
integer fb_b [0:H*W-1];
integer px = 0, py = 0;
integer frames = 0, painted = 0, nonblack = 0;
reg     prev_vb = 0;

// PER-FRAME, NOT JUST AT THE END.
//
// One frame captured at one cycle cannot see an alternation, and the fault being
// chased is exactly that: hardware showing a picture that flashes to a flat
// colour and back. A single end-of-run census reported whichever frame the run
// happened to stop on, which is how "the simulation renders correctly" and "the
// board flashes" were both true at once and neither explained the other.
//
// The backdrop count is the discriminator. m1_tile_mixer emits source 15 when NO
// layer wins a pixel, and the backdrop is palette entry 0 — so a frame that is
// uniformly the palette's first colour is not a rendering fault at all, it is
// every layer declining to draw. The per-tilemap census cannot say this: it only
// counts sources below 8, so a fully-backdrop frame and a frame the renderer
// never ran both read as four zeros.
integer bd_cnt = 0, vis_cnt = 0;
always @(posedge clk) begin
    if (rst_n_sys && ce_pix && !vid_hb && !vid_vb) begin
        vis_cnt = vis_cnt + 1;
        if (core.video.mix_src == 4'd15) bd_cnt = bd_cnt + 1;
    end
end

// INTERRUPTS TAKEN, PER FRAME.
//
// Scroll registers are animated from the vblank handler, so a picture with the
// right content that never moves is what a vblank interrupt that never reaches
// the CPU looks like — the main loop keeps running and the frame flag is never
// set. m1_glue's own header records that this failed once already, silently,
// from having the mask backwards.
//
// Counted at the acknowledge rather than the raise: a raise that nothing consumes
// is exactly the failure being looked for, so counting raises would report the
// interrupt system as healthy in the case that matters.
// CONTENT, NOT JUST WINS.
//
// The census counts which tilemap WON a pixel. That cannot distinguish "this
// layer holds nothing" from "this layer holds text and something is stopping it
// reaching the screen", and those need completely different fixes. This counts
// non-blank tile words per map straight out of tile RAM, by exactly the rule the
// MAME script uses — non-zero, and not tile 0x20, which is the space character —
// so the two numbers are directly comparable.
//
// Sampling every fourth word of the map's 0x1000, as the MAME script does. It is
// a presence check, not an inventory.
integer tm_have [0:3];
task automatic tram_content_census;
    integer L, i;
    reg [15:0] w;
    begin
        for (L = 0; L < 4; L = L + 1) begin
            tm_have[L] = 0;
            for (i = 0; i < 'h1000; i = i + 4) begin
                w = {core.main.rams.tram_v_hi[L * 'h1000 + i],
                     core.main.rams.tram_v_lo[L * 'h1000 + i]};
                if (w != 16'h0000 && (w & 16'h3fff) != 16'h0020)
                    tm_have[L] = tm_have[L] + 1;
            end
        end
    end
endtask

// EVERY word of tile RAM, in 0x1000-word blocks, presupposing no layout at all.
//
// The census above reads the four tilemap bases this design believes in. That
// makes it useless for the one question it was asked — "is there data in the
// tilemaps at all?" — because a wrong base reads zeros out of a populated array
// and looks exactly like an empty one. This walks all 32,768 words and reports
// where the content actually is, so the layout comes out as a result rather than
// going in as an assumption. Full stride, no sampling; it runs once per frame.
task automatic tram_block_census;
    integer b, i, n;
    reg [15:0] w;
    begin
        // What tile RAM ACTUALLY holds in the scroll region, read directly,
        // against what the renderer latched as ctrl. They should agree; the
        // renderer reports ctrl[1]=0x2000 while the CPU writes 0x5006 exactly
        // once, with 0x0000.
        $write("  scrollregs:");
        for (b = 0; b < 8; b = b + 1)
          $write(" %04h", {core.main.rams.tram_v_hi['h5000 + b],
                           core.main.rams.tram_v_lo['h5000 + b]});
        $write("   ctrl_latched=%04h,%04h\n", f_ctrl[0], f_ctrl[1]);
        $write("  tram blocks:");
        for (b = 0; b < 8; b = b + 1) begin
            n = 0;
            for (i = 0; i < 'h1000; i = i + 1) begin
                w = {core.main.rams.tram_v_hi[b * 'h1000 + i],
                     core.main.rams.tram_v_lo[b * 'h1000 + i]};
                if (w != 16'h0000 && (w & 16'h3fff) != 16'h0020)
                    n = n + 1;
            end
            if (n != 0) $write(" %04h:%0d", b * 'h1000, n);
        end
        $write("\n");
    end
endtask

// WHO WRITES pair 2/3's ctrl, and with what.
//
// The board latches the PC when the RENDERER observes ctrl change, which is up to
// a frame after the CPU wrote it — so the captured PC scatters and names nothing.
// This catches the CPU's own write instead, in the CPU's own domain, which is the
// event that matters. tile_ram word 0x5006 is pair 2/3's ctrl and also tilemap 2's
// vscr; bits 14:13 select the window mode, and the teardown is that field going to
// zero.
reg [15:0] ctrl23_prev = 16'hffff;
reg [14:0] last_w = 15'h7fff;
always @(posedge clk_cpu) begin
    if (core.main.m_req && core.main.m_we && core.main.sel_tileram
        && core.main.m_addr[15:1] >= 15'h4000) begin
        if (core.main.m_wdata !== ctrl23_prev
            || core.main.m_addr[15:1] !== last_w) begin
            if (1'b0 && core.main.m_addr[15:1] == 15'h5006)
              $display("W5006 pc=%06h data=%04h", core.dbg_pc, core.main.m_wdata);
            ctrl23_prev <= core.main.m_wdata;
            last_w      <= core.main.m_addr[15:1];
        end
    end
end

// THE GAME STATE THE CTRL VALUE COMES FROM, at frames matching the MAME dump.
//
// MAME holds the animating value at wram 0x50140a — 2058, 2fce, 20a8 at frames
// 300/600/900 — with a companion at 0x501408. We write only 0x0000/0x2000, so
// whatever computes it differs. V60 0x500000 is SDRAM word WRAM_BASE 0xF80000, so
// byte B maps to word 0xF80000 + (B - 0x500000)/2.
task automatic dump_wram(input integer fr);
    integer k;
    begin
        $write("=== SIM frame %0d  ctrl=%04h\n", fr,
               {core.main.rams.tram_v_hi['h5006], core.main.rams.tram_v_lo['h5006]});
        $write("  wram1400 501400:");
        for (k = 0; k < 20; k = k + 1) $write(" %04h", device.mem['hF80A00 + k]);
        $write("\n  wram1480 501480:");
        for (k = 0; k < 6;  k = k + 1) $write(" %04h", device.mem['hF80A40 + k]);
        $write("\n  wram0500 500500:");
        for (k = 0; k < 6;  k = k + 1) $write(" %04h", device.mem['hF80280 + k]);
        $write("\n  nvr ff5a 40ff5a:");
        for (k = 0; k < 10; k = k + 1) $write(" %04h", device.mem['hFA7FAD + k]);
        $write("\n");
    end
endtask

// DOES OUR V60 EVER FILL THE SCROLL TABLE? MAME writes wram 0x501408/0x50140a from
// pc=fe48d5 (163x) and pc=fef3b5 (164x) over 600 frames — roughly once every four.
// Ours leaves the whole 0x501400 table at zero. V60 byte 0x501408 is word 0x280a04.
integer w1400_n = 0;
always @(posedge clk_cpu) begin
    if (core.main.m_req && core.main.m_we
        && (core.main.m_addr[23:1] == 23'h280A04
         || core.main.m_addr[23:1] == 23'h280A05)) begin
        if (w1400_n < 8)
            $display("W1400 w=%06h pc=%06h data=%04h", core.main.m_addr[23:1],
                     core.dbg_pc, core.main.m_wdata);
        w1400_n = w1400_n + 1;
    end
end

// WHAT IS THE fe14xx LOOP POLLING? Our V60 writes wram 0x501408 only from
// pc=fe1469, 2,607 times by frame 600, while the reference executes that address
// exactly twice and fills the table from fe48d5/fef3b5 — which we never reach. So
// we are stuck in a loop the reference passes through. This logs what the CPU
// READS while its PC is in that region, which names the value we answer wrongly.
integer lp_n = 0;
always @(posedge clk_cpu) begin
    if (core.main.m_req && !core.main.m_we && core.main.m_ack
        && core.dbg_pc[23:8] == 16'hFE14) begin
        if (lp_n < 0)
            $display("SEQ %0d R pc=%06h a=%06h d=%04h", lp_n, core.dbg_pc,
                     {core.main.m_addr[23:1], 1'b0}, core.main.m_rdata);
        lp_n = lp_n + 1;
    end
end

// V60 INSTRUCTION TRACE, to diff against MAME's own debugger trace.
//
// MAME's `trace <file>,maincpu` emits a disassembled instruction stream. This
// emits the same PC stream from our core, so the FIRST DIVERGENT PC names the
// instruction that behaves differently — which per-opcode fuzzing cannot find,
// because it proves each instruction correct only for the state it was handed.
//
// The V60 arrived from the s32 project with a 29/29 unit suite and has never been
// checked against the oracle on real code. Today's bug has the exact signature
// that gap would produce: 400 consecutive identical memory accesses, then a branch
// taken the other way.
integer pctr = 0;
reg [23:0] pc_prev = 24'hffffff;
always @(posedge clk_cpu) begin
    if (core.main.ce && core.dbg_pc !== pc_prev) begin
        pc_prev <= core.dbg_pc;
        if (PCTRACE && pctr < 4000000) $display("PCT %06h", core.dbg_pc);
        pctr = pctr + 1;
    end
end

// THE COMPARE THAT DIVERGES. MAME and our core run 197,250 identical instructions,
// then at FE0DCC `cmp.h R0, FE[R11]` the reference branches and we do not. R11 is
// 0x40e800, so the operand is 0x40e8fe in NVRAM, and MAME reads 0x0000 there.
// A different value here means a DATA divergence; the same value means the compare
// or its flags are wrong in our V60.
integer cmpn = 0;
always @(posedge clk_cpu) begin
    if (core.main.m_req && !core.main.m_we && core.main.m_ack
        && core.dbg_pc == 24'hFE0DCC && cmpn < 8) begin
        $display("CMPOP #%0d a=%06h d=%04h", cmpn,
                 {core.main.m_addr[23:1], 1'b0}, core.main.m_rdata);
        cmpn = cmpn + 1;
    end
end

integer wtn = 0;
always @(posedge clk_cpu) begin
    if (WRTRACE && core.main.m_req && core.main.m_we && core.main.m_ack
        && wtn < 300000) begin
        $display("WRT %06h %04h %02h %06h", {core.main.m_addr[23:1], 1'b0},
                 core.main.m_wdata, core.main.m_be, core.dbg_pc);
        wtn = wtn + 1;
    end
end

// The GLUE irq_mask read that returns 0 where the reference returns 0xff.
// The DPRAM handshake at 0xC00040. The V60 writes 1 and waits for the I/O board
// to clear it; ours reads 0 immediately. Word index is addr[11:1] = 0x20.
integer dp_n = 0;
always @(posedge clk_cpu) begin
    if (core.main.m_req && core.main.m_ack && core.main.sel_dpram
        && core.main.m_addr[11:1] == 11'h020 && dp_n < 10) begin
        $display("DPRAM %s pc=%06h be=%02h wdata=%04h rdata=%04h lo=%02h",
                 core.main.m_we ? "WR" : "RD", core.dbg_pc, core.main.m_be,
                 core.main.m_wdata, core.main.m_rdata,
                 core.main.rams.dpram_lo['h020]);
        dp_n = dp_n + 1;
    end
end

integer gw_n = 0;
reg [7:0] gw_prev = 8'h00;
always @(posedge clk_cpu) begin
    // Every CHANGE of irq_mask, with the PC — it reaches 0xff and is zero by the
    // time the game reads it back.
    if (core.main.glue.irq_mask !== gw_prev && gw_n < 20) begin
        $display("IRQMASK %02h -> %02h at pc=%06h (sel_glue=%0d we=%0d a=%0d be=%02h)",
                 gw_prev, core.main.glue.irq_mask, core.dbg_pc,
                 core.main.sel_glue, core.main.m_we, core.main.m_addr[3:1],
                 core.main.m_be);
        gw_n = gw_n + 1;
    end
    gw_prev <= core.main.glue.irq_mask;
end

integer g_n = 0;
always @(posedge clk_cpu) begin
    if (core.main.m_req && !core.main.m_we && core.main.m_ack
        && core.main.m_addr[23:1] == 23'h700001 && g_n < 8) begin
        $display("GLUERD pc=%06h rdata=%04h irq_mask=%02h",
                 core.dbg_pc, core.main.m_rdata, core.main.glue.irq_mask);
        g_n = g_n + 1;
    end
end

integer irq_acks = 0, irq_raises = 0;
reg irq_n_d = 1;
// The V60 takes an interrupt only when PSW bit 18, IE, is set — it resets clear
// and software must set it, on this CPU through UPDPSW rather than any dedicated
// enable instruction. So "interrupt never acknowledged" has two very different
// causes: the line never asserted, or the CPU never enabled them. Tracked as
// "ever", because a single frame's sample during boot proves nothing: interrupts
// being off early is correct.
reg ie_ever = 0;
always @(posedge clk) begin
    if (rst_n_cpu && core.main.ce) begin
        if (core.main.cpu_irq_ack) irq_acks = irq_acks + 1;
        if (irq_n_d && !core.main.irq_n) irq_raises = irq_raises + 1;
        irq_n_d <= core.main.irq_n;
        if (core.main.cpu.psw[18]) ie_ever <= 1'b1;
    end
end

always @(posedge clk) begin
    if (!rst_n_sys) begin
        px <= 0; py <= 0; prev_vb <= 0;
    end else if (ce_pix) begin
        // Frame boundary on the rising edge of vertical blanking, the same
        // convention tb_m1_video uses.
        if (vid_vb && !prev_vb) begin
            px <= 0; py <= 0;
            frames = frames + 1;
            // The census is latched inside m1_video on this same edge, so it
            // reads as the frame that just finished.
            if (frames == 300 || frames == 600) begin
                dump_wram(frames);
                $display("W1400 total writes so far: %0d", w1400_n);
            end
            if (TRACE_FRAMES) begin
                tram_content_census();
                $display("F%0d bd=%0d/%0d win=%0d,%0d,%0d,%0d have=%0d,%0d,%0d,%0d rtl_have=%0d,%0d,%0d,%0d wr=%0d,%0d,%0d,%0d tgp=%0d/%0d/%04h io=%04h/%0d%0d%0d tbl=%0d%0d dat=%0d%0d frd=%0d fwr=%0d ctrl=%04h,%04h irq=%0d/%0d psw=%08h ie_ever=%0d pc=%06h",
                         frames, bd_cnt, vis_cnt,
                         f_layer_px[0], f_layer_px[1], f_layer_px[2], f_layer_px[3],
                         tm_have[0], tm_have[1], tm_have[2], tm_have[3],
                         f_have_rtl[0], f_have_rtl[1], f_have_rtl[2], f_have_rtl[3],
                         f_tram_wr[0], f_tram_wr[1], f_tram_wr[2], f_tram_wr[3],
                         f_pushes, f_pops, f_tgp_pc,
                         // WHAT THE COPROCESSOR IS STUCK ON. It sits at pc=0049
                         // with a command queued and never pops, in simulation
                         // and on the board alike, so the question is which
                         // external access is not completing.
                         core.main.dbg_tgp_io_addr, core.main.dbg_tgp_io_rd,
                         core.main.dbg_tgp_io_wr,   core.main.dbg_tgp_io_ack,
                         core.main.tgp_tbl_req,     core.main.tgp_tbl_ack,
                         core.main.tgp_dat_req,     core.main.tgp_dat_ack,
                         // frd distinguishes the two ways pops can stay zero:
                         // the TGP not asking for a word, or asking and the
                         // handshake failing. fifo_in_valid is !fin_empty, so
                         // with a command queued it must be high.
                         core.main.dbg_tgp_fifo_rd, core.main.dbg_tgp_fifo_wr,
                         f_ctrl[0], f_ctrl[1], irq_raises, irq_acks,
                         core.main.cpu.psw, ie_ever, core.dbg_pc);
                // 32,768 reads, so not on every frame — EXCEPT on a frame
                // that came out mostly backdrop, which is the teardown this is
                // chasing. rtl_have is the FETCHER's census and this one reads
                // tile RAM directly, so the pair separates "the content was
                // cleared" from "the content is there and the fetch went
                // somewhere else". Those are different bugs.
                if (frames % 32 == 0 || bd_cnt > (vis_cnt / 2))
                    tram_block_census();
            end
            bd_cnt  = 0;
            vis_cnt = 0;
        end
        prev_vb <= vid_vb;

        if (!vid_hb && !vid_vb) begin
            if (px < W && py < H) begin
                fb_r[py*W + px] = vid_r;
                fb_g[py*W + px] = vid_g;
                fb_b[py*W + px] = vid_b;
                painted = painted + 1;
                if (vid_r != 0 || vid_g != 0 || vid_b != 0)
                    nonblack = nonblack + 1;
            end
            px <= px + 1;
        end else if (vid_hb && px != 0) begin
            px <= 0;
            py <= py + 1;
        end
    end
end

// ------------------------------------------------------------------- probe
// What is the renderer actually reading? Two colours out of a palette holding
// real xBGR-555 entries says the data reaching the video path is not the data
// the CPU wrote, and this says which of the two it is.
integer pal_seen [0:65535];
integer tram_seen [0:65535];
integer npal = 0, ntram = 0, probe_on = 0;
integer paddr_seen [0:4095];
integer npaddr = 0;
integer pv, tv, pa;

always @(posedge clk) begin
    if (probe_on && ce_pix) begin
        pv = core.vid_pal_data;
        if (pal_seen[pv] == 0) begin
            pal_seen[pv] = 1;
            npal = npal + 1;
        end
        // The index, not just the data: nine distinct palette words read over
        // 120 frames means the renderer is looking at almost the same place
        // every pixel, and that is an index problem rather than a data one.
        pa = core.vid_pal_addr;
        if (paddr_seen[pa] == 0) begin
            paddr_seen[pa] = 1;
            npaddr = npaddr + 1;
        end
        tv = core.vid_tram_data;
        if (tram_seen[tv] == 0) begin
            tram_seen[tv] = 1;
            ntram = ntram + 1;
        end
    end
end

// ------------------------------------------------- raw scanout sample
// 31 tile words of ASCII text should not render as a uniform stripe. Before
// blaming the core, look at what it actually emits per ce_pix — if the pixels
// are there and the capture is dropping them, that is a testbench bug and the
// image is lying about the design.
integer raw_n = 0;
reg raw_arm = 0;
always @(posedge clk) begin
    if (raw_arm && ce_pix && !vid_hb && !vid_vb && raw_n < 48) begin
        $display("   raw[%0d] rgb=%02h%02h%02h hb=%0d vb=%0d",
                 raw_n, vid_r, vid_g, vid_b, vid_hb, vid_vb);
        raw_n = raw_n + 1;
    end
end

// ------------------------------------------------- first instruction fetch
//
// The same measurement the overlay makes on hardware, so the two can be put
// side by side. The board reports the V60's first fetch landing at SDRAM word
// 0 rather than the boot vector; this says what it does here, on identical
// RTL, and a difference is the divergence worth chasing.
reg [24:1] if_addr_first;
reg [31:0] if_data_first;
reg        if_seen = 0, d_ifack = 0;
integer    ifetch_n = 0;
always @(posedge clk) begin
    d_ifack <= p_ack[2];
    if (p_ack[2] && !d_ifack && !if_seen) begin
        if_seen       <= 1'b1;
        if_addr_first <= ifp_addr;
        if_data_first <= p_dout[2][31:0];
        $display("FIRST IFETCH: sdram word addr=%06h data=%08h",
                 ifp_addr, p_dout[2][31:0]);
        $fflush;
    end
    // The board halts after SIX instruction fetches, so the whole divergence
    // is inside the first handful. Print them, with the PC that asked, so the
    // sequence can be compared line by line against what hardware did.
    if (p_ack[2] && !d_ifack) begin
        if (ifetch_n < 12) begin
            $display("  IFETCH[%0d] pc=%06h addr=%06h data=%016h",
                     ifetch_n, dbg_pc, ifp_addr, p_dout[2]);
            $fflush;
        end
        ifetch_n = ifetch_n + 1;
    end
end

// ------------------------------------------------ character fetch latency
//
// The unit test models char_ack coming back in 14 cycles, and on that basis
// pipelining the fetch engine should have removed the deadline misses. It
// removed nine of 6858, so the number the engine actually waits is not 14 —
// the CPU is competing for the same controller.
//
// Measured as total cycles with char_req asserted over the number of requests,
// NOT by timing each request individually. The per-request version mispaired
// once and produced a single 22-million-cycle sample that then dominated the
// mean — an average that is wrong in the direction of the hypothesis being
// tested is worse than no measurement.
integer cl_wait = 0, cl_n = 0;
reg     d_creq = 0;
always @(posedge clk) begin
    d_creq <= char_req;
    if (char_req)            cl_wait = cl_wait + 1;
    if (char_req && !d_creq) cl_n    = cl_n + 1;
end

// -------------------------------------------------------- stall detector
//
// A hang here used to be a test that never returned, which says only that
// something is wrong. This turns it into a diagnosis: if the host has been
// unable to place a word for long enough that no legitimate backpressure
// explains it, print every signal that could be holding the handshake and
// stop.
//
// The suspects are named explicitly because the answer is always one of them:
// the loader's buffer being full and not draining, or the controller never
// granting the download port.
integer stall_cnt  = 0;
integer last_words = -1;
always @(posedge clk) begin
    if (ioctl_download) begin
        if (dl_words != last_words) begin
            last_words = dl_words;
            stall_cnt  = 0;
        end else begin
            stall_cnt = stall_cnt + 1;
        end
        if (stall_cnt == 200000) begin
            $display("");
            $display("STALL: no word accepted for 200000 cycles at %0d/%0d words",
                     dl_words, PRELOAD_WORDS);
            $display("  loader: ioctl_wait=%0d level=%0d full=%0d overflow=%0d busy=%0d req=%0d",
                     ioctl_wait, core.loader.level, core.loader.fifo_full,
                     core.loader.overflow, core.loader.busy, ldr_wr_req);
            $display("  sdram : wr_pend=%0d wr_inflight=%0d pipe_busy=%0d ref_pend=%0d state=%0d ready=%0d",
                     sdram.wr_pend, sdram.wr_inflight, sdram.pipe_busy,
                     sdram.ref_pend, sdram.state, mem_ready);
            $display("  ports : p_req=%b p_ack=%b inflight=%b char_req=%0d",
                     p_req, p_ack, sdram.inflight, char_req);
            $fflush;
            // Fatal, not $finish: this is the shape of a real regression and a
            // run that stops quietly with a zero exit code is a test that
            // reports success for a core that cannot load a ROM.
            $fatal(1, "download stalled");
        end
    end
end

// ---------------------------------------------------------------- the run
longint cycles;
integer fd, x, y;
initial begin
    for (i = 0; i < H*W; i = i + 1) begin
        fb_r[i] = 0; fb_g[i] = 0; fb_b[i] = 0;
    end

    repeat (8) @(posedge clk);
    rst_n = 1;
    while (!mem_ready) @(posedge clk);
    $display("SDRAM ready (mem_ready), HOLD_CPU=%0d", HOLD_CPU);
    $fflush;

    if (DOWNLOAD) begin
        run_download();
        run_ucode_download();
        while (!loader_done) @(posedge clk);
        $display("loader reports the ROM is in memory");
        // READ THE MICROCODE BACK OUT OF THE COPROCESSOR.
        //
        // This bench drives the REAL m1_rom_loader, which is the path hardware
        // uses, while tb_m1_boot preloads. So a fault here is a HARDWARE fault
        // and a pass in tb_m1_boot is not evidence about it. The TGP retiring
        // four instructions and parking on a FIFO read is exactly what an empty
        // program RAM looks like.
        begin : ucode_check
            integer uw, ubad;
            ubad = 0;
            for (uw = 0; uw < 2048; uw = uw + 1)
                if (core.main.tgp.prog[uw] !== ucode[uw]) begin
                    if (ubad < 6)
                        $display("UCODE MISMATCH @%04h: loaded %08h want %08h",
                                 uw[15:0], core.main.tgp.prog[uw], ucode[uw]);
                    ubad = ubad + 1;
                end
            $display("UCODE CHECK: %0d of 2048 words wrong", ubad);
        end
        $fflush;
        // With HOLD_CPU=0 the V60 came out of reset back at mem_ready and has
        // been executing an SDRAM full of FFFF for the whole download. Nothing
        // resets it now, which is the point of the experiment.
        $display("V60 pc at end of download: %06h", dbg_pc);
    end

    for (i = 0; i < 65536; i = i + 1) begin pal_seen[i] = 0; tram_seen[i] = 0; end
    for (i = 0; i < 4096; i = i + 1) paddr_seen[i] = 0;
    cycles = 0;
    probe_on = 1;
    while (cycles < RUN_CYCLES && !dbg_halted) begin
        @(posedge clk);
        cycles = cycles + 1;
        // Progress, because this run is long enough that silence is
        // indistinguishable from a hang.
        if (cycles == RUN_CYCLES - 3000000) raw_arm = 1;
        if (cycles % 20000000 == 0)
            begin
                // Deadline misses printed as a running total: 6849 was
                // identical across three very different engine speeds, which
                // only makes sense if they all happen in a phase where the
                // engine is starved rather than slow. If it plateaus, they are
                // a boot transient and steady state is clean.
                // FIFO OCCUPANCY, because a pc that stops moving has two very
                // different explanations and they look identical from outside.
                // The coprocessor is blocked pushing results whenever the
                // outbound FIFO is full; if the V60 is simultaneously blocked
                // pushing COMMANDS into a full inbound FIFO, neither can drain
                // the other and the machine is DEADLOCKED rather than slow.
                // v60_stall is m1_copro_if's own `fin_full`.
                $display("  %0d M cycles: pc=%06h frames=%0d misses=%0d  fin=%0d/16 fout=%0d/16 v60_stall=%0b tgp_wr=%0b",
                         cycles/1000000, dbg_pc, frames, dbg_overruns,
                         core.main.copro.fin_wr - core.main.copro.fin_rd,
                         core.main.copro.fout_wr - core.main.copro.fout_rd,
                         core.main.copro.v60_stall, core.main.tgp.fifo_wr);
                $fflush;
            end
    end

    $display("");
    $display("FRAME: cycles=%0d halted=%0d fp_trap=%0d", cycles, dbg_halted, dbg_fp_trap);
    $display("FRAME: pc=%06h io_replies=%0d sdram_violations=%04h",
             dbg_pc, dbg_io_replies, v_flags);
    $display("FRAME: %0d frames, %0d pixels painted, %0d non-black",
             frames, painted, nonblack);
    $display("FRAME: fetch deadline misses = %0d", dbg_overruns);
    if (cl_n > 0)
        $display("FRAME: char fetch wait avg=%0d cycles over %0d fetches (%0d total)",
                 cl_wait / cl_n, cl_n, cl_wait);
    $display("PROBE: %0d distinct palette words, %0d distinct tile words, %0d distinct palette INDICES",
             npal, ntram, npaddr);
    tv = 0;
    for (i = 0; i < 4096; i = i + 1)
        if (paddr_seen[i] != 0 && tv < 16) begin
            $display("   pal_addr %03h", i[11:0]);
            tv = tv + 1;
        end
    for (i = 0; i < 65536; i = i + 1)
        if (pal_seen[i] != 0 && npal < 40) $display("   pal %04h", i[15:0]);
    $display("PROBE: sample tile words:");
    tv = 0;
    for (i = 0; i < 65536; i = i + 1)
        if (tram_seen[i] != 0 && tv < 12) begin
            $display("   tram %04h", i[15:0]);
            tv = tv + 1;
        end

    // The board's row 05, printed here so the two can be put side by side.
    $display("FRAME: tilemap0 init writes=%0d  row-mask init writes=%0d (board row 05)",
             f_tm0_wr, f_mask_wr);
    $display("FRAME: NON-ZERO row-mask writes=%0d (board row 05, right half)", f_mask_nz);
    $display("FRAME: tilemap0 CHARACTER writes=%0d  first at pc=%06h (board rows 0E, 0C)",
             f_tm0_text, f_tm0_pc);
    $display("FRAME: copro SDRAM read checksum=%06h (board row 06)", f_rd_csum);
    $display("FRAME: copro read addresses at 0/64/256/512 = %06h %06h %06h %06h (rows 0E 07 0B 1B)",
             f_rd_a0, f_rd_a1, f_rd_a2, f_rd_a3);
    $display("FRAME: loader SDRAM write checksum=%06h words=%06h (board rows 07, 0B)",
             f_sd_csum, f_sd_words);
    $display("FRAME: SDRAM read-back checksum=%06h (board row 0C, board reads 04fffb)",
             f_rb_csum);
    $display("FRAME: read-back bursts completed=%0d of 4096", f_rb_n);
    $display("FRAME: control sweep, V60 ROM at word 0 = %06h (board row 0E)", f_rb_csum0);
    $fclose(pop_f);
    $display("FRAME: captured %0d command-FIFO pops to build/frame_pops.txt", pop_n);
    $display("FRAME: scroll changes over %0d frames: hscr[5002]=%0d  vscr[5006]=%0d",
             fr_seen, h_changes, v_changes);
    $display("FRAME: microcode RAM read back = %06h, sweep done=%0b (board row 0C)",
             f_uc_csum, f_uc_ok);
    $display("FRAME: TGP writes to copro RAM=%0d  sync word=%04h (board row 0D)",
             f_tgp_ramwr, f_sync_word);
    // ------------------------------------------------ CONTENT DUMP
    //
    // WHAT COUNTS AND SHARES CANNOT SAY. Everything measured on this core so far
    // is an aggregate - pixels won per layer, character writes, non-zero mask
    // writes, scroll register values - and none of them can name WHICH WORD is
    // wrong. The Model 2 core had this same symptom, a menu with coloured values
    // and no white labels, and named it in one step by dumping the tile RAM and
    // palette its own CPU had built and diffing them against the reference:
    // "tile RAM differs in 13 words of 32768 ... pal[1] <= 0000 at instruction
    // 1713595", which located a CPU divergence past the window it had been
    // verified to.
    //
    // Written as plain hex, one word per line, so tools/tram_diff.py can compare
    // it against a MAME capture without either side parsing the other's format.
    // The DPRAM the I/O board writes and the V60 reads. MAME maps it at
    // 0xc00000-0xc00fff with umask16(0x00ff) - 2048 BYTES on the low lane, an
    // mb8421 dual-port RAM - so only the low byte of each word is real.
    //
    // WHY IT IS DUMPED: our I/O board is an HLE (D9), reproducing a protocol read
    // out of the Z80 ROM by disassembly rather than by running it, where MAME's
    // model is LLE and correct by construction. If the bytes the V60 reads differ,
    // that is a blocker and the ~1,700 ALM for a real Z80 stops being optional.
    // Cheaper to test than to build.
    fd = $fopen(DPRAMOUT, "w");
    if (fd == 0) $display("FRAME: could not open %s", DPRAMOUT);
    else begin
        for (i = 0; i < 2048; i = i + 1)
            $fwrite(fd, "%02h\n", core.main.rams.dpram_lo[i]);
        $fclose(fd);
        $display("FRAME: wrote %s (2048 DPRAM bytes)", DPRAMOUT);
    end

    fd = $fopen(TRAMOUT, "w");
    if (fd == 0) $display("FRAME: could not open %s", TRAMOUT);
    else begin
        for (i = 0; i < 32768; i = i + 1)
            $fwrite(fd, "%04h\n", {core.main.rams.tram_v_hi[i],
                                   core.main.rams.tram_v_lo[i]});
        $fclose(fd);
        $display("FRAME: wrote %s (32768 tile-RAM words)", TRAMOUT);
    end

    fd = $fopen(PALOUT, "w");
    if (fd == 0) $display("FRAME: could not open %s", PALOUT);
    else begin
        for (i = 0; i < 8192; i = i + 1)
            $fwrite(fd, "%04h\n", {core.main.rams.pram_v_hi[i],
                                   core.main.rams.pram_v_lo[i]});
        $fclose(fd);
        $display("FRAME: wrote %s (8192 palette entries)", PALOUT);
    end

    fd = $fopen(PPMOUT, "w");
    if (fd == 0) $display("FRAME: could not open %s", PPMOUT);
    else begin
        $fwrite(fd, "P3\n%0d %0d\n255\n", W, H);
        for (y = 0; y < H; y = y + 1) begin
            for (x = 0; x < W; x = x + 1)
                $fwrite(fd, "%0d %0d %0d\n",
                        fb_r[y*W + x], fb_g[y*W + x], fb_b[y*W + x]);
        end
        $fclose(fd);
        $display("FRAME: wrote %s", PPMOUT);
    report_census();
    end
    $finish;
end

endmodule
