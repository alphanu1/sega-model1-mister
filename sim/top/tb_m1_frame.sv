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
// THE 3D IS HERE NOW, and the polygon field is no longer empty. This header
// used to say "no TGP and no rasterizer here, so the polygon field is empty by
// construction" - true when it was written, false since m1_integrated gained
// both, and it was the reason this bench showed a clean picture for a machine
// that on hardware was drawing dithered garbage over the whole screen.
//
// The ioctl download streams the V60 image only. The polygon models are
// sixteen megabytes and would take longer to push through ioctl than the run
// itself, so sdram_model BACKS the unwritten array from the same packed image
// the MRA loads (build/rom/vr_stream.bin, polygons at byte 0x840000). Anything
// the run writes still wins; only the moment the data arrived is unfaithful,
// and the 3D layer does not run until long after the download completes.
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
    // The whole packed SDRAM image, in words. Build it with
    //   python3 tools/build_rom_image.py vr <vr.zip> -o build/rom --bin
    // Set STREAM_WORDS to 0 to run without it, which is the old behaviour and
    // draws no 3D at all.
    parameter string  STREAMBIN  = "build/rom/vr_stream.bin",
    parameter longint STREAM_WORDS = 64'd12713984,   // build/rom/vr_stream.bin / 2
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
    // THE CAP IS A LIMIT ON THE COMPARISON WINDOW, so it is a parameter rather
    // than a literal. At 4,000,000 a run stops tracing after about 2.5 emulated
    // seconds however many cycles were asked for, and the diff then ends where
    // the TRACE stopped rather than where the run did - reported as
    // "IDENTICAL for N" with no hint that N was the cap. Measured 2026-08-30:
    // 3,965,222 kept plus 34,776 stripped is exactly 4,000,000.
    parameter longint PCTRACE_MAX = 4000000,

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
reg clk = 0, clk_cpu = 0, clk_3d = 0, rst_n = 0;
always #6.25 clk     = ~clk;      // 80 MHz
always #21.25 clk_cpu = ~clk_cpu;   // 23.529 MHz, matching the PLL (800/34)
// 47.059 MHz, the PLL's 800/17 and an exact double of clk_cpu. 10.625 ns is
// expressible at this timescale's 1 ps precision; rounding it to 10 or 11 would
// break the exact halving the CDC relies on.
always #10.625 clk_3d = ~clk_3d;

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

// SEVEN PORTS, NOT FIVE, AND THE SAME SEVEN Model1.sv HAS.
//
// p5 bursts the polygon models and p6 carries tgp_ram. This bench had five and
// left the 3D layer's two masters unconnected - which, with -Wno-PINMISSING,
// ties their acknowledges to zero. Every polygon read and every tgp_ram write
// then waits forever: the list walk hung in S_BODY on command 4, which is the
// colour-word upload, and the whole 3D layer stopped after 39 passes while the
// 2D carried on drawing a perfectly convincing picture.
//
// The bench and the top level having different port counts is exactly the
// divergence docs/mister-integration.md warns about, and it hid for as long as
// it did because the missing piece produced NO OUTPUT rather than wrong output.
wire        r3d_rom_req, r3d_tex_req, r3d_tex_we;
wire [24:1] r3d_rom_addr, r3d_tex_addr;
wire [15:0] r3d_tex_din;

// EIGHT PORTS, matching Model1.sv: p7 is the I/O board Z80's firmware fetch.
localparam logic [24:1] IOFW_BASE = 24'hD00000;
wire        iofw_req;
wire [12:0] iofw_word;

wire [6:0]       p_req, p_we, p_ack;
wire [6:0][24:1] p_addr;
wire [6:0][15:0] p_din;
wire [6:0][1:0]  p_be;
wire [6:0][63:0] p_dout;

// Port 4 carries the I/O board's firmware fetch, not the read-back sweep -
// that fed the debug overlay's row 4, which is off. See Model1.sv.
assign p_req  = {r3d_tex_req, r3d_rom_req, iofw_req, tgp_mem_req, ifp_req, char_req, sdr_req};
assign p_we   = {r3d_tex_we,  1'b0,        1'b0,     1'b0,        1'b0,    1'b0,     sdr_we};
// Character RAM lives at CHAR_BASE in SDRAM, exactly where m1_main maps the
// CPU's writes to 0x780000-0x7fffff. The renderer emits an offset within that
// region, so the base has to be added here — without it the tilemap fetches
// from word 0, which is V60 program ROM, and every glyph decodes from the same
// wrong data. 31 distinct tile numbers then render identically and the screen
// is a uniform pattern that looks like a video bug rather than an address one.
// p5's address is aligned DOWN to its 4-word burst boundary, the same way p3's
// is; m1_integrated keeps bit 1 to pick which 32-bit half of the burst it
// wanted. Aligning it any earlier destroys that bit and every odd model word
// returns the even one's data.
assign p_addr = {r3d_tex_addr, {r3d_rom_addr[24:2], 1'b0},
                 IOFW_BASE + {11'd0, iofw_word},
                 {tgp_mem_addr[24:2], 1'b0}, ifp_addr,
                 24'hFA8000 + {6'd0, char_addr}, sdr_addr};
assign p_din  = {r3d_tex_din, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0, sdr_din};
assign p_be   = {2'b11,       2'd0,  2'd0,  2'd0,  2'd0,  2'd0,  sdr_be};

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

m1_sdram #(.NP(7), .INIT_NOP(600)) sdram (
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
// POLY_WORDS covers the whole packed image, not just the polygon field: the
// coprocessor's data ROM and tables sit below it and the same argument applies
// to them.
sdram_model #(.COL_BITS(9), .DEFAULT_DATA(DOWNLOAD ? 16'hFFFF : 16'h0000),
              .BACKING_FILE(STREAMBIN), .BACKING_BASE(0),
              .BACKING_WORDS(STREAM_WORDS)) device (
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
    // clk_3d WAS NOT CONNECTED, and this bench builds with -Wno-PINMISSING.
    //
    // The tool tied it to zero and said nothing, so the 3D layer has never
    // been clocked here since it was wired into m1_integrated - every frame
    // this bench has dumped shows a machine whose rasterizer is held still.
    // It looked exactly like a correct 2D picture, which is the worst way for
    // a missing clock to present.
    .clk_3d(clk_3d),

    // The 3D layer's SDRAM masters, wired exactly as Model1.sv wires them:
    // p5 for the polygon models, p6 for tgp_ram.
    .r3d_rom_req(r3d_rom_req), .r3d_rom_addr(r3d_rom_addr),
    .r3d_rom_dout(p_dout[5]), .r3d_rom_ack(p_ack[5]),
    .r3d_tex_req(r3d_tex_req), .r3d_tex_we(r3d_tex_we),
    .r3d_tex_addr(r3d_tex_addr), .r3d_tex_din(r3d_tex_din),
    .r3d_tex_dout(p_dout[6][15:0]), .r3d_tex_ack(p_ack[6]),
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
    .rb_req(rb_req), .rb_addr(rb_addr), .rb_dout(64'd0), .rb_ack(1'b0),
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

    .iofw_req(iofw_req), .iofw_word(iofw_word),
    .iofw_ack(p_ack[4]), .iofw_din(p_dout[4][15:0]),
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
// THE TGP'S COUNTERS SAMPLE ITS OWN CLOCK, NOT THE CPU'S.
//
// These were on posedge clk_cpu, which was right while the coprocessor shared
// that clock. It now runs on clk_3d at twice the rate, and `retire` is a
// one-cycle pulse - so sampling at clk_cpu sees only every OTHER retire and
// reported 6,007,498 -> 3,052,817 when the TGP was given twice the clock.
// Exactly half, which is the signature. It read as the coprocessor doing half
// the work at double the speed, and was very nearly acted on as a real defect.
always @(posedge clk_3d) begin
    if (core.main.rst_n) begin
        tgp_cycles <= tgp_cycles + 1;
        if (core.main.tgp.core.retire)  tgp_retires    <= tgp_retires + 1;
        if (core.main.tgp.core.mem_req) tgp_memwait    <= tgp_memwait + 1;
        if (core.main.tgp.fifo_rd)      tgp_fifordwait <= tgp_fifordwait + 1;
        if (core.main.tgp.fifo_wr)      tgp_fifowrwait <= tgp_fifowrwait + 1;
    end
end

always @(posedge clk_cpu) begin
    if (core.main.rst_n) begin
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

// DOES AN EMPTY RESULT-FIFO READ ACTUALLY STALL THE V60?
//
// m1_copro_if withholds the acknowledge when the V60 reads an EMPTY outbound
// FIFO - the fix made after the CPU span at fed5a4 on stale data. But the V60
// reads that FIFO ~2 times a frame while the coprocessor, parked, has pushed
// almost nothing, so most of those reads meet an empty FIFO and the machine
// plainly does not hang. Either they are the always-completing high half at
// offset 1, or the interlock is not doing what its comment says.
//
// Counted separately: reads at offset 0 (which should stall on empty) against
// reads at offset 1 (which must always complete), and how many of each were
// acknowledged while the FIFO was empty.
longint rd_lo = 0, rd_hi = 0, rd_lo_empty = 0, rd_lo_empty_acked = 0;
always @(posedge clk_cpu) begin
    if (core.main.rst_n && core.main.copro.st == 2'd0 && core.main.copro.v60_acc
        && !core.main.copro.we && core.main.copro.sel_fifo) begin
        if (!core.main.copro.a1) begin
            rd_lo <= rd_lo + 1;
            if (core.main.copro.fout_empty) begin
                rd_lo_empty <= rd_lo_empty + 1;
                if (core.main.copro.ack) rd_lo_empty_acked <= rd_lo_empty_acked + 1;
            end
        end else rd_hi <= rd_hi + 1;
    end
end

// THE GATE VALUES AT THE MOMENT OF THE BRANCH, not at rest.
//
// FF84A2 compares 0x5011B0 against 0x5011A0 and FF84AE branches to FF8582 -
// past every result read - on the wrong result. We divert on 390 of 452 visits
// where the reference falls through, yet sampling those two words at the END of
// the run gives 0 and 0x157c, identical to the reference. So they must differ
// WHILE the branch is being taken, and an end-of-run sample cannot see that.
//
// Latched when dbg_pc is at FF84AE, which is the cycle the decision is made.
// V60 byte B is device.mem word 0xF80000 + (B-0x500000)/2, so 0x5011A0 is word
// 0xF808D0 and 0x5011B0 is 0xF808D8.
logic [31:0] gate_a0_seen, gate_b0_seen;
longint gate_hits = 0, gate_a0_gt = 0;
always @(posedge clk_cpu) begin
    if (core.main.rst_n && core.dbg_pc == 24'hff84ae && core.dbg_pc != dbg_pc_d) begin
        gate_hits    <= gate_hits + 1;
        gate_a0_seen <= {device.mem['hF808D1], device.mem['hF808D0]};
        gate_b0_seen <= {device.mem['hF808D9], device.mem['hF808D8]};
        if ({device.mem['hF808D1], device.mem['hF808D0]}
          > {device.mem['hF808D9], device.mem['hF808D8]}) gate_a0_gt <= gate_a0_gt + 1;
    end
end

// DOES OUR V60 EVER EXECUTE THE ROUTINES THAT COMPUTE THE SCROLL VALUE?
//
// We write hscr[0x5002] 1.9 times a frame - MORE often than the reference's 1.0
// - but its VALUE changes on only 10% of frames against the reference's 67%. So
// the register is written faithfully with a value that is not being recomputed.
//
// The value comes from a table at wram 0x501408/0x50140a. We write that table
// from pc=fe1469 with data=0000, i.e. we CLEAR it; MAME writes it from fe48d5
// (163x) and fef3b5 (164x) over 600 frames with computed values - 2058, 2fce,
// 20a8 at frames 300/600/900. Counting whether we reach those PCs at all
// separates "the routine never runs" from "it runs and computes zero".
longint pc_fe48d5 = 0, pc_fef3b5 = 0, pc_fe1469 = 0;
// The reference's RESULT-READING block: an unrolled run of in.w at
// ff850c-ff8538 that reads the coprocessor FIFO back to back, 202 times a frame
// in a 300-frame window. It is what drains the outbound FIFO, and if our V60
// never reaches it the FIFO fills whatever the speed.
longint pc_ff850c = 0, pc_ff8510 = 0;
// Up the call chain from the result reads, to find where we leave the path:
//   FEFB40 jsr FF84A2  ->  FF84A2 cmp  ->  FF84AE bgt FF8582 (the skip)
//                                      ->  FF84B1 ... FF850C (the reads)
longint pc_fefb40 = 0, pc_ff84a2 = 0, pc_ff84ae = 0, pc_ff8582 = 0, pc_ff84b1 = 0;
// Several levels at once. FEFA25 is the geometry submission routine - it writes
// commands to [R24] and reads results with in.w [R23] - and it is called from a
// list walk at FEF9C6 that compares each entry against R17 and skips the call
// on a mismatch (FEF9CC bne FEF9D8).
// Upstream of the submit chain: FEEF14 cmp.b #0,501A35 / FEEF1C bne FEF047 is
// the entry, and FEF04E/FEF059 divert to FEF325 when 501A28 is 3 or 4.
// The DISPATCH that reaches the geometry routine:
//   FE1C09 test1 #1F, 0[R25]   - the object's enable bit
//   FE1C12 be    FE1C18        - skip when clear
//   FE1C15 jsr   [A[R25]]      - indirect call through a pointer at R25+0xA
//   FEEB10                     - the geometry routine itself
longint pc_fe1c09 = 0, pc_fe1c12 = 0, pc_fe1c15 = 0, pc_fe1c18 = 0, pc_feeb10 = 0;
// THE GEOMETRY SUBMISSION LOOP THE REFERENCE NEVER ENTERS.
//   FEB651 test1 #1A, 0[R22]   - bit 26 of the object
//   FEB65A be    FEB688        - skip when CLEAR; the reference ALWAYS skips
//   FEB661..FEB687             - the body, which writes to the coprocessor
//   FEB673                     - where our V60 pins when the FIFO fills
// FEB673 does not appear once in 14 emulated seconds of reference trace.
longint pc_feb651 = 0, pc_feb65a = 0, pc_feb661 = 0, pc_feb673 = 0, pc_feb688 = 0;
// WHO SETS BIT 26 OF OBJECT 0. Word 0 of the object at V60 0x400f80 reads
// 84000000 here and 80000000 in the reference, and FEB651 tests exactly that
// bit before falling into the geometry submission that deadlocks the pair.
// V60 byte 0x400f80 is word address 0x2007C0; the 32-bit word is the pair
// 0x2007C0 (low half) and 0x2007C1 (high half), and bit 26 lives in the HIGH
// half, bit 10.
longint ob_wr = 0, ob_wr_set = 0;
// WHAT OUR COPROCESSOR ANSWERS. The reference returns TWO words per 0x20800000
// command and the V60 tests BIT 31 OF THE FIRST, which is always 00000000 -
// "not visible". If ours has bit 31 set there, objects get marked, geometry
// floods the FIFO and the pair deadlocks. Captured at the FIFO itself rather
// than by PC, so it does not depend on the V60 reaching any particular
// instruction.
integer ans_n = 0, ans_f;
reg armed = 1'b1;   // capture the WHOLE command stream
initial ans_f = $fopen("build/frame_answers.txt", "w");
integer cmd_n = 0;
reg cmd_d = 1'b0;
integer ob_p = 0;
longint pc_feef14 = 0, pc_feef1c = 0, pc_fef047 = 0, pc_fef04e = 0, pc_fef325 = 0;
longint pc_fef9c6 = 0, pc_fef9cc = 0, pc_fef9d2 = 0, pc_fefa25 = 0,
        pc_fefa93 = 0, pc_fefad1 = 0, pc_fefb00 = 0, pc_fef9d8 = 0;
// EDGE-DETECTED. dbg_pc is a level, so `dbg_pc == X` is true for EVERY CYCLE
// the instruction at X occupies - these counted cycles, not executions. It
// showed up as FF84A2 (a ~25-cycle cmp) at 452 against the bgt immediately
// after it at 174: consecutive instructions cannot execute different numbers of
// times. Counting the TRANSITION to X gives executions.
reg [23:0] dbg_pc_d = 24'hffffff;
// THE FRAME TICK THE MAIN LOOP IS SUPPOSED TO DRAIN. The ISR does `inc.b
// 500501` at FE0320 once a frame and the main loop resets it at FE1406. The
// reference only ever holds 0, 1 or 2 - `cmp.b #3, 500501 / blt` always takes.
// If ours reaches 3 or more, the main loop is falling behind the interrupt,
// which is the speed deficit in the game's own terms rather than a logic fault.
// V60 byte 0x500501 is the HIGH byte of device.mem word 0xF80280.
longint tick_hist [8];
initial for (int th = 0; th < 8; th++) tick_hist[th] = 0;
reg [7:0] tick_prev = 8'hff;
// WHERE THE V60 ACTUALLY SPENDS ITS INSTRUCTIONS, by 256-byte bucket of the
// low 16 bits of PC. The per-frame geometry update runs ONCE in 526 frames and
// nothing gates it, so the interesting question is what is running instead.
longint pc_hist [256];
initial for (int hi = 0; hi < 256; hi++) pc_hist[hi] = 0;
always @(posedge clk_cpu) begin
    dbg_pc_d <= core.dbg_pc;
    if (core.main.rst_n && device.mem['hF80280][15:8] != tick_prev) begin
        tick_prev <= device.mem['hF80280][15:8];
        tick_hist[(device.mem['hF80280][15:8] > 8'd7) ? 7
                  : device.mem['hF80280][15:8]] <=
            tick_hist[(device.mem['hF80280][15:8] > 8'd7) ? 7
                      : device.mem['hF80280][15:8]] + 1;
    end
    cmd_d <= core.main.rst_n && core.main.copro.st == 2'd0 && core.main.copro.v60_acc
             && core.main.copro.we && core.main.copro.sel_fifo && core.main.copro.a1;
    // Commands in, answers out, in order.
    if (core.main.rst_n && core.main.copro.st == 2'd0 && core.main.copro.v60_acc
        && core.main.copro.we && core.main.copro.sel_fifo && core.main.copro.a1
        && !core.main.copro.fin_full && cmd_n < 4000) begin
        // ARMED BY THE VISIBILITY COMMAND. The first 400 commands are the
        // opening exchange and match the reference already; 0x20800000 is the
        // per-object test whose answer decides the deadlock, and it comes later.
        // ONE LINE PER COMMAND. v60_acc is asserted on both cycles of a held
        // access, so an ungated write logs every command twice - the same trap
        // as the result-FIFO read count. Edge-detect the access.
        if (!cmd_d) begin
            cmd_n = cmd_n + 1;
            $fwrite(ans_f, "%04h%04h\n", core.main.copro.wdata, core.main.copro.lat_lo);
        end
    end
    if (core.main.rst_n && armed && core.main.copro.fifo_out_push && ans_n < 400) begin
        ans_n = ans_n + 1;
        // WITH THE MICROCODE PC. Our first 17 answers are 00000000 where the
        // reference's first is 42520000, so every result the V60 reads after
        // that is shifted by 17. Naming the instruction that pushes them is the
        // whole question.
        $fwrite(ans_f, "ANS %08h pc=%04h\n", core.main.copro.fifo_out_data,
                core.main.tgp.core.seq_pc);
    end
    if (core.main.rst_n && core.main.m_we && core.main.m_ack
        && core.main.m_addr[23:1] == 23'h2007C1) begin
        ob_wr <= ob_wr + 1;
        if (core.main.m_wdata[10]) begin
            ob_wr_set <= ob_wr_set + 1;
            if (ob_p < 8) begin
                ob_p = ob_p + 1;
                $display("OBJBIT26 set by pc=%06h data=%04h", core.dbg_pc, core.main.m_wdata);
            end
        end
    end
    if (core.main.rst_n && core.dbg_pc != dbg_pc_d) begin
        pc_hist[core.dbg_pc[15:8]] <= pc_hist[core.dbg_pc[15:8]] + 1;
        if (core.dbg_pc == 24'hfe48d5) pc_fe48d5 <= pc_fe48d5 + 1;
        if (core.dbg_pc == 24'hfef3b5) pc_fef3b5 <= pc_fef3b5 + 1;
        if (core.dbg_pc == 24'hfe1469) pc_fe1469 <= pc_fe1469 + 1;
        if (core.dbg_pc == 24'hff850c) pc_ff850c <= pc_ff850c + 1;
        if (core.dbg_pc == 24'hff8510) pc_ff8510 <= pc_ff8510 + 1;
        if (core.dbg_pc == 24'hfefb40) pc_fefb40 <= pc_fefb40 + 1;
        if (core.dbg_pc == 24'hff84a2) pc_ff84a2 <= pc_ff84a2 + 1;
        if (core.dbg_pc == 24'hff84ae) pc_ff84ae <= pc_ff84ae + 1;
        if (core.dbg_pc == 24'hff84b1) pc_ff84b1 <= pc_ff84b1 + 1;
        if (core.dbg_pc == 24'hff8582) pc_ff8582 <= pc_ff8582 + 1;
        if (core.dbg_pc == 24'hfeb651) pc_feb651 <= pc_feb651 + 1;
        if (core.dbg_pc == 24'hfeb65a) pc_feb65a <= pc_feb65a + 1;
        if (core.dbg_pc == 24'hfeb661) pc_feb661 <= pc_feb661 + 1;
        if (core.dbg_pc == 24'hfeb673) pc_feb673 <= pc_feb673 + 1;
        if (core.dbg_pc == 24'hfeb688) pc_feb688 <= pc_feb688 + 1;
        if (core.dbg_pc == 24'hfe1c09) pc_fe1c09 <= pc_fe1c09 + 1;
        if (core.dbg_pc == 24'hfe1c12) pc_fe1c12 <= pc_fe1c12 + 1;
        if (core.dbg_pc == 24'hfe1c15) pc_fe1c15 <= pc_fe1c15 + 1;
        if (core.dbg_pc == 24'hfe1c18) pc_fe1c18 <= pc_fe1c18 + 1;
        if (core.dbg_pc == 24'hfeeb10) pc_feeb10 <= pc_feeb10 + 1;
        if (core.dbg_pc == 24'hfeef14) pc_feef14 <= pc_feef14 + 1;
        if (core.dbg_pc == 24'hfeef1c) pc_feef1c <= pc_feef1c + 1;
        if (core.dbg_pc == 24'hfef047) pc_fef047 <= pc_fef047 + 1;
        if (core.dbg_pc == 24'hfef04e) pc_fef04e <= pc_fef04e + 1;
        if (core.dbg_pc == 24'hfef325) pc_fef325 <= pc_fef325 + 1;
        if (core.dbg_pc == 24'hfef9c6) pc_fef9c6 <= pc_fef9c6 + 1;
        if (core.dbg_pc == 24'hfef9cc) pc_fef9cc <= pc_fef9cc + 1;
        if (core.dbg_pc == 24'hfef9d2) pc_fef9d2 <= pc_fef9d2 + 1;
        if (core.dbg_pc == 24'hfef9d8) pc_fef9d8 <= pc_fef9d8 + 1;
        if (core.dbg_pc == 24'hfefa25) pc_fefa25 <= pc_fefa25 + 1;
        if (core.dbg_pc == 24'hfefa93) pc_fefa93 <= pc_fefa93 + 1;
        if (core.dbg_pc == 24'hfefad1) pc_fefad1 <= pc_fefad1 + 1;
        if (core.dbg_pc == 24'hfefb00) pc_fefb00 <= pc_fefb00 + 1;
    end
end

// DOES THE V60 WRITE THE SCROLL REGISTERS AT ALL?
//
// The value census says hscr[0x5002] CHANGES on 86 of 1,460 frames where the
// reference changes it on ~982. Two very different faults produce that number
// and a value census cannot tell them apart:
//
//   * the V60 never executes the code that writes it   -> program state, and
//     downstream of the speed deficit;
//   * the V60 writes it and the write does not land    -> a write-path bug,
//     independent of speed and fixable now.
//
// Counting the WRITES separates them. A high write count with a low change
// count means the game is writing the same value repeatedly, which is a third
// answer again and also worth knowing.
longint tw_hscr2 = 0, tw_vscr2 = 0, tw_any_scroll = 0, tw_all_tram = 0, tw_all_acks = 0;
// Tile-RAM writes by region, so "we never write the scroll registers" can be
// separated from "we write them somewhere else". Regions per m1_main.sv:
//   [0] 0x0000-0x1fff maps 0/1   [1] 0x2000-0x3fff maps 2/3
//   [2] 0x4000-0x5fff scroll     [3] 0x6000-0x7fff row masks
longint tw_reg [4];
longint tw_5xxx = 0;
initial begin tw_reg[0]=0; tw_reg[1]=0; tw_reg[2]=0; tw_reg[3]=0; end
always @(posedge clk_cpu) begin
    // m_addr is declared [23:1] - byte address with bit 0 omitted - so the word
    // index inside the 64 KB page is m_addr[15:1]. BIT 0 DOES NOT EXIST: an
    // earlier version of this probe used m_addr[14:0], which selects a bit
    // outside the vector, never matched, and reported zero writes to the scroll
    // registers on a machine that writes them. The other probe in this file has
    // used m_addr[15:1] all along.
    if (core.main.rst_n && core.main.m_we && core.main.sel_tileram && core.main.m_ack) begin
        if (core.main.m_addr[15:1] == 15'h5002) tw_hscr2 <= tw_hscr2 + 1;
        if (core.main.m_addr[15:1] == 15'h5006) tw_vscr2 <= tw_vscr2 + 1;
        if (core.main.m_addr[15:1] >= 15'h5000 && core.main.m_addr[15:1] <= 15'h5007)
            tw_any_scroll <= tw_any_scroll + 1;
        tw_all_tram <= tw_all_tram + 1;
        tw_reg[core.main.m_addr[15:14]] <= tw_reg[core.main.m_addr[15:14]] + 1;
        if (core.main.m_addr[15:13] == 3'h2 && core.main.m_addr[13:12] == 2'h1) tw_5xxx <= tw_5xxx + 1;
    end
    // CONTROLS. A zero from a probe that cannot see anything reads exactly like
    // a zero from a machine that does nothing, and that mistake has been made
    // repeatedly here. tw_all_tram counts every tile-RAM write and tw_all_acks
    // every acknowledged bus write, so if the scroll counts are zero while these
    // are not, the zero is about the game rather than the probe.
    cmd_d <= core.main.rst_n && core.main.copro.st == 2'd0 && core.main.copro.v60_acc
             && core.main.copro.we && core.main.copro.sel_fifo && core.main.copro.a1;
    // Commands in, answers out, in order.
    if (core.main.rst_n && core.main.copro.st == 2'd0 && core.main.copro.v60_acc
        && core.main.copro.we && core.main.copro.sel_fifo && core.main.copro.a1
        && !core.main.copro.fin_full && cmd_n < 4000) begin
        // ARMED BY THE VISIBILITY COMMAND. The first 400 commands are the
        // opening exchange and match the reference already; 0x20800000 is the
        // per-object test whose answer decides the deadlock, and it comes later.
        // ONE LINE PER COMMAND. v60_acc is asserted on both cycles of a held
        // access, so an ungated write logs every command twice - the same trap
        // as the result-FIFO read count. Edge-detect the access.
        if (!cmd_d) begin
            cmd_n = cmd_n + 1;
            $fwrite(ans_f, "%04h%04h\n", core.main.copro.wdata, core.main.copro.lat_lo);
        end
    end
    if (core.main.rst_n && armed && core.main.copro.fifo_out_push && ans_n < 400) begin
        ans_n = ans_n + 1;
        // WITH THE MICROCODE PC. Our first 17 answers are 00000000 where the
        // reference's first is 42520000, so every result the V60 reads after
        // that is shifted by 17. Naming the instruction that pushes them is the
        // whole question.
        $fwrite(ans_f, "ANS %08h pc=%04h\n", core.main.copro.fifo_out_data,
                core.main.tgp.core.seq_pc);
    end
    if (core.main.rst_n && core.main.m_we && core.main.m_ack)
        tw_all_acks <= tw_all_acks + 1;
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
        if ({core.main.rams.u_tram.mem_hi['h5002], core.main.rams.u_tram.mem_lo['h5002]} != h_prev) begin
            h_changes = h_changes + 1;
            h_prev = {core.main.rams.u_tram.mem_hi['h5002], core.main.rams.u_tram.mem_lo['h5002]};
        end
        if ({core.main.rams.u_tram.mem_hi['h5006], core.main.rams.u_tram.mem_lo['h5006]} != v_prev) begin
            v_changes = v_changes + 1;
            v_prev = {core.main.rams.u_tram.mem_hi['h5006], core.main.rams.u_tram.mem_lo['h5006]};
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
    // The I/O board firmware, as bytes. $readmemh on a byte array wants one
    // hex byte per line; tools/build_rom_image.py --iofw writes it.
    for (i = 0; i < 65536; i = i + 1) iofw[i] = 8'hff;
    $readmemh("build/rom/vr_iofw.hex", iofw);
    iofw_ok = (iofw[0] !== 8'hff) || (iofw[1] !== 8'hff);
    if (!iofw_ok)
        $display("tb_m1_frame: *** no I/O board firmware (build/rom/vr_iofw.hex): the Z80 executes nothing and the V60 waits forever. Run tools/build_rom_image.py with --iofw ***");
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

// THE I/O BOARD'S FIRMWARE IS A THIRD DOWNLOAD, ON INDEX 2.
//
// EPR-14869, MAME's model1io BIOS set. Without it the Z80 executes an
// uninitialised array - ones under Verilator, which is a solid RST 38h loop -
// and the V60 waits forever for a board that never answers. That failure looks
// exactly like a dead handshake, which is why the bench says out loud whether
// it found the file.
//
// 16 KB is what the Z80 maps; the file is 64 KB and the loader drops the rest.
reg [7:0] iofw [0:65535];
integer   iofw_ok = 0;
task automatic run_iofw_download;
    integer w;
    begin
        @(posedge clk);
        ioctl_index    <= 16'd2;
        ioctl_download <= 1'b1;
        @(posedge clk);
        for (w = 0; w < 8192; w = w + 1) begin      // 16 KB as 16-bit words
            while (ioctl_wait) @(posedge clk);
            ioctl_wr   <= 1'b1;
            ioctl_addr <= w * 2;
            ioctl_dout <= {iofw[w*2 + 1], iofw[w*2]};
            @(posedge clk);
            ioctl_wr   <= 1'b0;
            @(posedge clk);
        end
        ioctl_download <= 1'b0;
        ioctl_index    <= 16'd0;
        $display("download: I/O board firmware streamed on index 2");
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
                w = {core.main.rams.u_tram.mem_hi[L * 'h1000 + i],
                     core.main.rams.u_tram.mem_lo[L * 'h1000 + i]};
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
          $write(" %04h", {core.main.rams.u_tram.mem_hi['h5000 + b],
                           core.main.rams.u_tram.mem_lo['h5000 + b]});
        $write("   ctrl_latched=%04h,%04h\n", f_ctrl[0], f_ctrl[1]);
        $write("  tram blocks:");
        for (b = 0; b < 8; b = b + 1) begin
            n = 0;
            for (i = 0; i < 'h1000; i = i + 1) begin
                w = {core.main.rams.u_tram.mem_hi[b * 'h1000 + i],
                     core.main.rams.u_tram.mem_lo[b * 'h1000 + i]};
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
               {core.main.rams.u_tram.mem_hi['h5006], core.main.rams.u_tram.mem_lo['h5006]});
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
integer w1400_n = 0, w1400_p = 0;
longint w1400_48d5 = 0, w1400_f3b5 = 0, w1400_1469 = 0, w1400_other = 0;
always @(posedge clk_cpu) begin
    if (core.main.m_req && core.main.m_we
        && (core.main.m_addr[23:1] == 23'h280A04
         || core.main.m_addr[23:1] == 23'h280A05)) begin
        // BY WRITING PC, not just the first eight. The first eight are all the
        // clear at fe1469, which hid that fe48d5/fef3b5 also write here - they
        // run 15x more often than the reference yet the value barely moves, so
        // what they WRITE is the question.
        if (core.dbg_pc == 24'hfe48d5)      w1400_48d5 <= w1400_48d5 + 1;
        else if (core.dbg_pc == 24'hfef3b5) w1400_f3b5 <= w1400_f3b5 + 1;
        else if (core.dbg_pc == 24'hfe1469) w1400_1469 <= w1400_1469 + 1;
        else                                w1400_other <= w1400_other + 1;
        // Its own counter: w1400_n counts EVERY write and the first ~19 are the
        // clear, so gating the print on it meant the computed writes - the ones
        // in question - were never shown.
        // ONLY the two computing routines. Filtering merely on "not the clear"
        // filled the print with fe6ab0, which is another zeroing path.
        if ((core.dbg_pc == 24'hfe48d5 || core.dbg_pc == 24'hfef3b5) && w1400_p < 12)
            w1400_p = w1400_p + 1;
        if ((core.dbg_pc == 24'hfe48d5 || core.dbg_pc == 24'hfef3b5) && w1400_p <= 12)
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
        if (PCTRACE && pctr < PCTRACE_MAX) $display("PCT %06h", core.dbg_pc);
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

// ------------------------------- WHAT THE Z80 WRITES TO THE 315-5338A
//
// The DPRAM is behind that chip, not memory-mapped: the firmware sets an
// address with commands 0x00/0x01, writes with 0x07, or uses the fast-write
// commands 0x70-0x77. So if the shared RAM never changes, the question is
// which of those the Z80 is issuing, and this is the only way to see it.
integer io5338_n = 0;
reg [3:0] io5338_a [0:63];
reg [7:0] io5338_d [0:63];
always @(posedge clk_cpu) begin
    if (core.main.g_ioboard.ioboard.rst_n
        && core.main.g_ioboard.ioboard.dbg_wr_stb && io5338_n < 64) begin
        io5338_a[io5338_n] = core.main.g_ioboard.ioboard.dbg_last_wr[11:8];
        io5338_d[io5338_n] = core.main.g_ioboard.ioboard.dbg_last_wr[7:0];
        io5338_n = io5338_n + 1;
    end
end

// -------------------------------------------- IS THE Z80 RUNNING AT ALL
integer z80_cen = 0, z80_miss = 0, z80_rstn = 0;
reg [15:0] z80_amax = 0;
reg [15:0] z80_atrace [0:31];
integer z80_at_n = 0;
reg [15:0] z80_aprev = 16'hffff;
always @(posedge clk) begin
    if (core.main.g_ioboard.ioboard.rst_n) begin
        z80_rstn = z80_rstn + 1;
        if (core.main.g_ioboard.ioboard.cen) z80_cen = z80_cen + 1;
        if (core.main.g_ioboard.ioboard.fw_miss) z80_miss = z80_miss + 1;
        if (core.main.g_ioboard.ioboard.dbg_a > z80_amax) z80_amax = core.main.g_ioboard.ioboard.dbg_a;
        if (core.main.g_ioboard.ioboard.dbg_a != z80_aprev && z80_at_n < 32) begin
            z80_atrace[z80_at_n] = core.main.g_ioboard.ioboard.dbg_a;
            z80_at_n = z80_at_n + 1;
            z80_aprev = core.main.g_ioboard.ioboard.dbg_a;
        end
    end
end

// ------------------------------- DID THE FIRMWARE REACH SDRAM, AND IS IT READ
//
// Two different failures look identical from outside: the loader putting the
// firmware somewhere else, and the fetch path returning the wrong words. So
// check the memory directly and watch the first fetches.
integer fwf_n = 0;
reg [12:0] fwf_a [0:15];
reg [15:0] fwf_d [0:15];
always @(posedge clk) begin
    if (rst_n_sys && core.iofw_req && p_ack[4] && fwf_n < 16) begin
        fwf_a[fwf_n] = core.iofw_word;
        fwf_d[fwf_n] = p_dout[4][15:0];
        fwf_n = fwf_n + 1;
    end
end

// ------------------------------------------- WHAT THE Z80 I/O BOARD WRITES
//
// The V60 sits at fe022c for 400 M cycles with the real board in, where the
// behavioural one got it to the main loop, so the Z80 runs but does not
// satisfy the handshake. The V60 waits on the status flag at 0xc00040, which
// is DPRAM byte 0x20, and the only way to tell "wrote the wrong thing" from
// "wrote nothing" is to watch the writes.
integer z80_wr_n = 0;
integer z80_seen [0:2047];
integer zw_i;
reg [10:0] z80_first [0:31];
reg  [7:0] z80_firstd [0:31];
integer z80_first_n = 0;
initial for (zw_i = 0; zw_i < 2048; zw_i = zw_i + 1) z80_seen[zw_i] = 0;
always @(posedge clk) begin
    if (rst_n_sys && core.main.io_we && core.main.io_ack) begin
        z80_wr_n = z80_wr_n + 1;
        z80_seen[core.main.io_addr] = z80_seen[core.main.io_addr] + 1;
        if (z80_first_n < 32) begin
            z80_first[z80_first_n]  = core.main.io_addr;
            z80_firstd[z80_first_n] = core.main.io_din;
            z80_first_n = z80_first_n + 1;
        end
    end
end

// ---------------------------------------------- BANDS PRESENTED PER FRAME
//
// The average is not the question. 24 bands a pass and a pass every two frames
// is the right RATE and can still leave any individual frame showing only part
// of the picture - which is exactly what Ben reads off the board: some bands
// missing, and the whole thing seeming to redraw about one frame in five. So
// count presentations per VIDEO FRAME and keep the distribution.
integer bpf_hist [0:31];
integer bands_this_frame = 0, bpf_i;
integer bands_prev_s = 0, bpf_frames = 0;
initial for (bpf_i = 0; bpf_i < 32; bpf_i = bpf_i + 1) bpf_hist[bpf_i] = 0;
always @(posedge clk) begin
    if (rst_n_sys) begin
        if (core.u_raster3d.dbg_bands != bands_prev_s) begin
            bands_this_frame = bands_this_frame
                             + (core.u_raster3d.dbg_bands - bands_prev_s);
            bands_prev_s = core.u_raster3d.dbg_bands;
        end
        if (core.video.vblank_start) begin
            bpf_hist[(bands_this_frame > 31) ? 31 : bands_this_frame] =
                bpf_hist[(bands_this_frame > 31) ? 31 : bands_this_frame] + 1;
            bands_this_frame = 0;
            bpf_frames = bpf_frames + 1;
        end
    end
end

// --------------------------------------------- GAME SPEED, END TO END
//
// Instruction rate is not what Ben is timing off the screen. The honest
// end-to-end metric is how often the game completes a LOGIC frame, and the
// display-list buffer swap is exactly that - one swap per finished list.
//
// The reference is measured: tools/mame_listctl_rate.lua, 2,000 frames, 996
// flips of which 993 are exactly 2 video frames apart. So every 2 frames is
// 100% of hardware speed, every 6 frames is 33%, and the ratio needs no
// modelling at all.
integer swap_gap [0:63];
integer swap_i, swap_n = 0, swap_since = 0;
longint swap_sum = 0;
reg     sel_d = 0;
initial for (swap_i = 0; swap_i < 64; swap_i = swap_i + 1) swap_gap[swap_i] = 0;
always @(posedge clk) begin
    if (rst_n_sys && core.video.vblank_start) begin
        swap_since = swap_since + 1;
        if (core.listctl_sel != sel_d) begin
            sel_d = core.listctl_sel;
            swap_gap[(swap_since > 63) ? 63 : swap_since] =
                swap_gap[(swap_since > 63) ? 63 : swap_since] + 1;
            swap_sum = swap_sum + swap_since;
            swap_n   = swap_n + 1;
            swap_since = 0;
        end
    end
end

// ------------------------------------- HOW LONG ONE DATA ACCESS ACTUALLY TAKES
//
// 2026-08-20 decomposed it exactly: every page cost the same 36 fast cycles -
// 9 CPU cycles - whether it was BRAM or SDRAM, because it is fixed handshake
// overhead and not memory latency. That figure predates the V60 moving to its
// own clock domain, so there is now a synchroniser round trip on top of it and
// the old number cannot be assumed. Measure it here, on the current design,
// with every master live - m_req rising to m_ack, in clk_sys cycles, split by
// whether the access went to SDRAM or stayed on chip.
integer blat_hist [0:127];
integer blat_i, blat_run = 0, blat_n = 0;
longint blat_sum = 0;
reg     blat_busy = 0;
initial for (blat_i = 0; blat_i < 128; blat_i = blat_i + 1) blat_hist[blat_i] = 0;
integer  rgn_n [0:4];
longint  rgn_sum [0:4];
integer  rgn_wr [0:4];
integer  blat_rgn = 4;
reg      blat_rgn_wr = 0;
initial for (blat_i = 0; blat_i < 5; blat_i = blat_i + 1) begin
    rgn_n[blat_i] = 0; rgn_sum[blat_i] = 0; rgn_wr[blat_i] = 0;
end
always @(posedge clk) begin
    if (rst_n_sys) begin
        if (core.main.m_req && !blat_busy) begin
            blat_busy = 1; blat_run = 1;
            blat_rgn = core.main.sel_rom     ? 0 :
                       core.main.sel_wram    ? 1 :
                       core.main.sel_nvram   ? 2 :
                       core.main.sel_charram ? 3 : 4;   // 4 = stayed on chip
            blat_rgn_wr = core.main.m_we;
            if (blat_rgn_wr) rgn_wr[blat_rgn] = rgn_wr[blat_rgn] + 1;
        end else if (blat_busy) begin
            blat_run = blat_run + 1;
            if (core.main.m_ack) begin
                blat_hist[(blat_run > 127) ? 127 : blat_run] =
                    blat_hist[(blat_run > 127) ? 127 : blat_run] + 1;
                blat_sum = blat_sum + blat_run;
                blat_n   = blat_n + 1;
                // WHICH REGION, not just how long. `to_sdram` is
                // sel_rom|sel_wram|sel_nvram|sel_charram, so the V60's WORK RAM
                // is off-chip at 0x500000-0x53ffff - 256 KB, far too big for
                // M10K - and a stall attributed to "ROM tables" may be nothing
                // of the kind. The split decides whether a cache is worth its
                // ALM and what it should cache.
                rgn_n[blat_rgn]   = rgn_n[blat_rgn] + 1;
                rgn_sum[blat_rgn] = rgn_sum[blat_rgn] + blat_run;
                blat_busy = 0;
            end
        end
    end
end

// ---------------------------------------------- WHERE THE CPU'S CYCLES GO
//
// tb_m1_boot carries these buckets already, and it instantiates m1_main - no 3D
// layer, no polygon ROM prefetch, no tgp_ram traffic. So its numbers describe a
// V60 that has the SDRAM controller mostly to itself, which since 2026-08-31 is
// not the machine we ship.
//
// The same three buckets, here, with every master live. A cycle can be in both
// stall buckets - the V60 arbitrates one bus between fetch and data - so the
// union is counted rather than the sum, which would overstate it.
// LONGINT. `integer` is 32-bit signed and the percentage print multiplies by
// 100 first, so 104,727,411 stalled cycles reported as 6% and the union as -3%.
// The raw counts were right and the arithmetic on them was not.
longint v_cyc = 0, v_dstall = 0, v_fstall = 0, v_anystall = 0;
always @(posedge clk_cpu) begin
    if (rs_cpu[1]) begin
        automatic bit ds = core.main.cpu.dbus_req && !core.main.cpu.dack;
        automatic bit fs = core.main.cpu.if_req && !core.main.cpu.u_ifetch.if_ack_i;
        v_cyc = v_cyc + 1;
        if (ds)       v_dstall   = v_dstall   + 1;
        if (fs)       v_fstall   = v_fstall   + 1;
        if (ds || fs) v_anystall = v_anystall + 1;
    end
end

// Retire to retire, in CPU-clock cycles, counted as PC changes. A uniform
// distribution means every instruction is genuinely multi-cycle; a bimodal one
// means a short average dragged by a few slow classes, and those want a targeted
// fix rather than a pipeline.
integer  cpi_hist [0:63];
longint  cpi_retires = 0, cpi_cycles = 0;
integer cpi_run = 0, cpi_i;
reg [23:0] cpi_last_pc = 24'hffffff;
initial for (cpi_i = 0; cpi_i < 64; cpi_i = cpi_i + 1) cpi_hist[cpi_i] = 0;
always @(posedge clk_cpu) begin
    if (rs_cpu[1]) begin
        if (core.dbg_pc != cpi_last_pc) begin
            if (cpi_last_pc != 24'hffffff) begin
                cpi_retires = cpi_retires + 1;
                cpi_cycles  = cpi_cycles + cpi_run;
                cpi_hist[(cpi_run > 63) ? 63 : cpi_run] =
                    cpi_hist[(cpi_run > 63) ? 63 : cpi_run] + 1;
            end
            cpi_last_pc = core.dbg_pc;
            cpi_run = 1;
        end else begin
            cpi_run = cpi_run + 1;
        end
    end
end

logic [31:0] worst_band = 0;

// ---------------------------------------------------------------------------
// WHERE A BAND SWEEP'S TIME ACTUALLY GOES.
//
// The consumer state cst is already public, so the whole breakdown comes from
// sampling it - no RTL change. What this answers:
//
//   - the per-sweep TOTAL, measured rather than extrapolated. The first pass at
//     this took worst-band x 24 and got 857,256 against a 818,133 budget, which
//     is pessimistic: not every band is the worst one.
//   - the split, so we know whether the 1,984-cycle clear is the only fat or
//     whether the paint has its own.
//   - how MANY sweeps overrun. A systematic 5% deficit and one frame in fifty
//     going long are different defects, and Ben sees the fault in busy scenes.
//
// BUDGET, AND MIND THE CLOCK. This bench samples `clk`, which is 80 MHz, so
// the per-frame budget here is 80,000,000/57.52 = 1,390,821 cycles. The band
// module's own dbg_band_cycles counts clk_3d at 47.059 MHz, where a frame is
// 818,133. Comparing an 80 MHz count against the 47 MHz budget said every
// sweep was 100% over when they all fit at 92%, and nearly bought a fourth
// band buffer - 14 M10K - to fix a problem that does not exist.
// ---------------------------------------------------------------------------
integer cst_cyc [0:6];              // cycles in each consumer state
integer sweep_cyc = 0;              // cycles in the sweep currently running
integer sweeps = 0, sweeps_over = 0;
integer sweep_max = 0;
longint unsigned sweep_total = 0;
integer cst_prev = 0;

// ---------------------------------------------------------------------------
// THE PRODUCER'S CADENCE, IN FRAMES - which is what B against S measures on
// the board.
//
// A pass is start (P_IDLE -> P_WALK), ready (-> P_READY) and swap (P_READY ->
// P_IDLE). The consumer restarts at the blanking edge every frame - 24 bands a
// frame, on the board too - so it is in C_IDLE at every edge and a missed swap
// can only be the producer NOT being in P_READY at that edge. That happens
// when a pass runs longer than a frame: it then starts on frame_start of
// frame k+1, is ready during k+2, swaps at the k+3 edge and restarts at k+4 -
// three frames a pass against the list's two, which is the board's 20 against
// 29. Measure how long a pass is and where it sits against the frame.
// ---------------------------------------------------------------------------
integer pst_prev = 0;
longint pass_t0 = 0, pass_t1 = 0, pass_t2 = 0, frame_t0 = 0;
integer pass_f0 = 0, pass_n = 0, pass_len_over = 0;
longint pass_len = 0, pass_wait = 0, pass_idle = 0, pass_cad = 0;
longint pass_len_sum = 0, pass_len_max = 0;
longint pass_wait_sum = 0, pass_wait_max = 0;
longint pass_idle_sum = 0, pass_idle_max = 0;
integer pass_lh = 0, pass_cf = 0, pass_i;
longint pass_off = 0;
integer pass_len_hist [0:31];   // tenths of a frame
integer cadence_hist  [0:15];   // start-to-start, whole frames
initial begin
    for (pass_i = 0; pass_i < 32; pass_i = pass_i + 1) pass_len_hist[pass_i] = 0;
    for (pass_i = 0; pass_i < 16; pass_i = pass_i + 1) cadence_hist[pass_i]  = 0;
end
// The 3D ROM port's wait, the same way the character fetch is measured:
// total cycles with rom_req up over the number of requests.
longint r3rom_wait = 0, r3rom_n = 0;
integer qmax = 0, qmin = 0, qoff = 0;
reg     d_r3rom = 0;
initial for (int i = 0; i < 7; i++) cst_cyc[i] = 0;

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
        if (iofw_ok) run_iofw_download();
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
        // WORST BAND, NOT LAST BAND. dbg_band_cycles holds the most recent
        // band's fill time, and the question is whether the filler EVER
        // overruns its slot in a busy scene - a single frame that misses the
        // handoff shows the previous geometry again, which is what "bands not
        // drawn" looks like. Sampling the last one in a quiet window reported
        // 5% of budget and said nothing about the busy case.
        if (core.u_raster3d.dbg_band_cycles > worst_band)
            worst_band <= core.u_raster3d.dbg_band_cycles;

        // The consumer's state histogram, and the per-sweep total. A sweep is
        // C_IDLE -> ... -> C_IDLE, i.e. all 24 bands.
        cst_cyc[core.u_raster3d.cst] = cst_cyc[core.u_raster3d.cst] + 1;
        if (core.u_raster3d.cst != 0) begin
            sweep_cyc = sweep_cyc + 1;
        end else if (cst_prev != 0) begin
            // just returned to C_IDLE: a sweep finished
            sweeps      = sweeps + 1;
            sweep_total = sweep_total + sweep_cyc;
            if (sweep_cyc > sweep_max) sweep_max = sweep_cyc;
            if (sweep_cyc > 1390821)   sweeps_over = sweeps_over + 1;   // 80 MHz frame
            sweep_cyc = 0;
        end
        cst_prev = core.u_raster3d.cst;

        // ---- the producer's cadence (see the declarations above)
        if (core.video.vblank_start) frame_t0 = cycles;
        if (pst_prev == 0 && core.u_raster3d.pst == 1) begin
            if (pass_n > 0) begin
                pass_cad = cycles - pass_t0;
                pass_cf  = (pass_cad + 1390821/2) / 1390821;
                cadence_hist[(pass_cf > 15) ? 15 : pass_cf] =
                    cadence_hist[(pass_cf > 15) ? 15 : pass_cf] + 1;
                pass_idle = cycles - pass_t2;
                pass_idle_sum = pass_idle_sum + pass_idle;
                if (pass_idle > pass_idle_max) pass_idle_max = pass_idle;
            end
            pass_t0 = cycles; pass_f0 = frames; pass_off = cycles - frame_t0;
        end
        if (pst_prev != 6 && core.u_raster3d.pst == 6) begin
            pass_t1  = cycles;
            pass_len = cycles - pass_t0;
            pass_n   = pass_n + 1;
            pass_len_sum = pass_len_sum + pass_len;
            if (pass_len > pass_len_max) pass_len_max = pass_len;
            if (pass_len > 1390821)      pass_len_over = pass_len_over + 1;
            pass_lh = (pass_len * 10) / 1390821;
            pass_len_hist[(pass_lh > 31) ? 31 : pass_lh] =
                pass_len_hist[(pass_lh > 31) ? 31 : pass_lh] + 1;
        end
        if (pst_prev == 6 && core.u_raster3d.pst == 0) begin
            pass_t2   = cycles;
            pass_wait = cycles - pass_t1;
            pass_wait_sum = pass_wait_sum + pass_wait;
            if (pass_wait > pass_wait_max) pass_wait_max = pass_wait;
            $display("PASS3D #%0d start=f%0d+%0d%% len=%0d.%02d fr wait=%0d.%02d fr obj=%0d q=%0d",
                     pass_n, pass_f0, (pass_off * 100) / 1390821,
                     pass_len / 1390821, ((pass_len % 1390821) * 100) / 1390821,
                     pass_wait / 1390821, ((pass_wait % 1390821) * 100) / 1390821,
                     core.r3_dbg_objects, core.r3_dbg_quads);
        end
        pst_prev = core.u_raster3d.pst;
        d_r3rom <= core.r3_rom_req;
        // How far off the screen vertices go, which sizes the store's record.
        if (core.u_raster3d.q_valid) begin
            if ($signed(core.u_raster3d.q_x0) > qmax) qmax = $signed(core.u_raster3d.q_x0);
            if ($signed(core.u_raster3d.q_x1) > qmax) qmax = $signed(core.u_raster3d.q_x1);
            if ($signed(core.u_raster3d.q_x2) > qmax) qmax = $signed(core.u_raster3d.q_x2);
            if ($signed(core.u_raster3d.q_x3) > qmax) qmax = $signed(core.u_raster3d.q_x3);
            if ($signed(core.u_raster3d.q_y0) > qmax) qmax = $signed(core.u_raster3d.q_y0);
            if ($signed(core.u_raster3d.q_y1) > qmax) qmax = $signed(core.u_raster3d.q_y1);
            if ($signed(core.u_raster3d.q_y2) > qmax) qmax = $signed(core.u_raster3d.q_y2);
            if ($signed(core.u_raster3d.q_y3) > qmax) qmax = $signed(core.u_raster3d.q_y3);
            if ($signed(core.u_raster3d.q_x0) < qmin) qmin = $signed(core.u_raster3d.q_x0);
            if ($signed(core.u_raster3d.q_x1) < qmin) qmin = $signed(core.u_raster3d.q_x1);
            if ($signed(core.u_raster3d.q_x2) < qmin) qmin = $signed(core.u_raster3d.q_x2);
            if ($signed(core.u_raster3d.q_x3) < qmin) qmin = $signed(core.u_raster3d.q_x3);
            if ($signed(core.u_raster3d.q_y0) < qmin) qmin = $signed(core.u_raster3d.q_y0);
            if ($signed(core.u_raster3d.q_y1) < qmin) qmin = $signed(core.u_raster3d.q_y1);
            if ($signed(core.u_raster3d.q_y2) < qmin) qmin = $signed(core.u_raster3d.q_y2);
            if ($signed(core.u_raster3d.q_y3) < qmin) qmin = $signed(core.u_raster3d.q_y3);
            if ($signed(core.u_raster3d.q_x0) < 0 || $signed(core.u_raster3d.q_x0) > 495 ||
                $signed(core.u_raster3d.q_y0) < 0 || $signed(core.u_raster3d.q_y0) > 383) qoff = qoff + 1;
        end
        if (core.r3_rom_req)            r3rom_wait = r3rom_wait + 1;
        if (core.r3_rom_req && !d_r3rom) r3rom_n   = r3rom_n + 1;

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
                $display("  %0d M cycles: pc=%06h frames=%0d misses=%0d  3d obj=%0d q=%0d f=%0d st=%0d b=%0d rb=%0d bands=%0d rv=%0b armed=%0b beam=%0d | lw st=%0d off=%0h cur=%0h cmd=%02h  fin=%0d/16 fout=%0d/16 v60_stall=%0b tgp_wr=%0b",
                         cycles/1000000, dbg_pc, frames, dbg_overruns,
                         core.r3_dbg_objects, core.r3_dbg_quads,
                         core.r3_dbg_frames,
                         core.u_raster3d.cst, core.u_raster3d.cur_band,
                         core.u_raster3d.ready_band, core.u_raster3d.dbg_bands,
                         core.u_raster3d.ready_valid, core.u_raster3d.frame_armed,
                         core.u_raster3d.beam_band_s2,
                         core.u_raster3d.u_walk.st,
                         core.u_raster3d.u_walk.off,
                         core.u_raster3d.u_walk.cur,
                         core.u_raster3d.u_walk.cmd,
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
    if (swap_n > 0) begin
        $display("FRAME: %0d display-list swaps, mean %0d.%02d frames apart (the board is 2.00 = 100%% speed, so this is %0d%%)",
                 swap_n, swap_sum/swap_n, ((swap_sum*100)/swap_n) % 100,
                 (200*swap_n)/(swap_sum ? swap_sum : 1));
        $write("FRAME: frames between swaps:");
        for (swap_i = 1; swap_i < 64; swap_i = swap_i + 1)
            if (swap_gap[swap_i] * 50 > swap_n)
                $write(" %0d:%0d%%", swap_i, (100*swap_gap[swap_i])/swap_n);
        $write("\n");
    end else
        $display("FRAME: NO display-list swaps at all - the game never finished a list");
    if (blat_n > 0) begin
        // THE DISPLAY-LIST CAP REPORTS ITSELF. m1_mainram sizes both buffers
        // to 16,384 words because MAME's V60 never writes above word 0x3fff in
        // 40 s. OUR V60 is not MAME's - the trace shows it spinning a different
        // number of times in the same wait loops - so "the reference never does"
        // is not a proof that we never do. Nonzero here means the cap is wrong.
        $display("FRAME: display-list writes above the 16,384-word cap: %0d",
                 core.main.rams.dbg_dl_oob);
        $display("FRAME: %0d data accesses, mean %0d.%02d clk_sys cycles req->ack",
                 blat_n, blat_sum/blat_n, ((blat_sum*100)/blat_n) % 100);
        for (blat_i = 0; blat_i < 5; blat_i = blat_i + 1)
            if (rgn_n[blat_i] > 0)
                $display("FRAME: region %0s: %0d accesses (%0d%% of all, %0d writes), mean %0d.%02d cycles",
                         (blat_i==0) ? "rom    " : (blat_i==1) ? "wram   " :
                         (blat_i==2) ? "nvram  " : (blat_i==3) ? "charram" : "on-chip",
                         rgn_n[blat_i], (100*rgn_n[blat_i])/blat_n, rgn_wr[blat_i],
                         rgn_sum[blat_i]/rgn_n[blat_i],
                         ((rgn_sum[blat_i]*100)/rgn_n[blat_i]) % 100);
        $write("FRAME: latency histogram:");
        for (blat_i = 1; blat_i < 128; blat_i = blat_i + 1)
            if (blat_hist[blat_i] * 200 > blat_n)
                $write(" %0d:%0d%%", blat_i, (100*blat_hist[blat_i])/blat_n);
        $write("\n");
    end
    // EVERY BUCKET, NOT JUST THE COMMON ONES. A frame that presents fewer than
    // all 24 bands is a visible horizontal band of stale or missing picture, and
    // Ben reports a couple of those still on the board (2026-09-01). At one
    // frame in a hundred the old `*100 > bpf_frames` threshold hid them
    // completely - the line read a clean "24:99%" and the 1% that is the actual
    // defect never printed. Which bands are short says whether it is the top of
    // the frame (the producer starting late) or the bottom (it running out of
    // time), and those are different bugs.
    $write("FRAME: bands presented per video frame, over %0d frames:", bpf_frames);
    for (bpf_i = 0; bpf_i < 32; bpf_i = bpf_i + 1)
        if (bpf_hist[bpf_i] != 0)
            $write(" %0d:%0d(%0d%%)", bpf_i, bpf_hist[bpf_i],
                   (100*bpf_hist[bpf_i])/bpf_frames);
    $write("\n");
    $display("FRAME: 3D layer: objects=%0d quads=%0d dropped=%0d passes=%0d",
             core.r3_dbg_objects, core.r3_dbg_quads,
             core.r3_dbg_dropped, core.r3_dbg_frames);
    // ---------------------------------------------------------------------
    // DOES THE BAND FILLER FIT INSIDE A FRAME?
    //
    // A completed geometry pass is only handed over when THREE things coincide
    // (m1_raster3d, `swap_now`): the producer is in P_READY, the consumer is in
    // C_IDLE, and the beam enters blanking. If the filler is still working when
    // blanking arrives the swap is MISSED and the pass waits a whole frame, so
    // the display keeps showing the previous geometry. On hardware that reads
    // as bands not being drawn in busy scenes.
    //
    // The budget: clk_3d is 47.059 MHz and a frame is 1/57.52 s, so 818,133
    // cycles, over 24 bands = 34,089 cycles a band. Over that and the filler
    // cannot keep up on a full frame.
    begin
        longint unsigned band_cyc, budget;
        band_cyc = core.u_raster3d.dbg_band_cycles;
        budget   = 34089;
        $display("FRAME: last band took %0d clk_3d cycles, budget %0d a band (%0d%% of it)",
                 band_cyc, budget, (band_cyc * 100) / budget);
        $display("FRAME: WORST band was %0d cycles (%0d%% of budget); 24 bands = %0d of %0d in a frame",
                 worst_band, (worst_band * 100) / budget,
                 worst_band * 24, 818133);
        $display("FRAME: sweeps=%0d  mean=%0d  worst=%0d  budget=1390821 (80 MHz frame)  OVER=%0d (%0d%%)",
                 sweeps, (sweeps > 0) ? int'(sweep_total / sweeps) : 0,
                 sweep_max, sweeps_over,
                 (sweeps > 0) ? (sweeps_over * 100) / sweeps : 0);
        $display("FRAME: consumer state cycles  IDLE=%0d CLR=%0d CLRW=%0d REPLAY=%0d FILL=%0d FILLW=%0d WAIT=%0d",
                 cst_cyc[0], cst_cyc[1], cst_cyc[2], cst_cyc[3],
                 cst_cyc[4], cst_cyc[5], cst_cyc[6]);
        $write("FRAME: Z80 writes to the 315-5338A (reg=data), first %0d:", io5338_n);
        for (zw_i = 0; zw_i < io5338_n; zw_i = zw_i + 1)
            $write(" %01h=%02h", io5338_a[zw_i], io5338_d[zw_i]);
        $write("\n");
        $display("FRAME: Z80 cache: cv=%0b ca=%04h req=%0b acks=%0d word=%04h data=%04h sel=%0b hit=%0b",
                 core.main.g_ioboard.ioboard.fw_cv,
                 core.main.g_ioboard.ioboard.fw_ca,
                 core.main.g_ioboard.ioboard.fw_req,
                 fwf_n,
                 core.main.g_ioboard.ioboard.fw_word,
                 core.main.g_ioboard.ioboard.fw_w,
                 core.main.g_ioboard.ioboard.fw_sel,
                 core.main.g_ioboard.ioboard.fw_hit);
        $display("FRAME: Z80 out of reset for %0d cycles, %0d cen ticks, %0d stalled on a fetch miss, highest address %04h",
                 z80_rstn, z80_cen, z80_miss, z80_amax);
        $write("FRAME: Z80 address trace:");
        for (zw_i = 0; zw_i < z80_at_n; zw_i = zw_i + 1) $write(" %04h", z80_atrace[zw_i]);
        $write("\n");
        $write("FRAME: firmware in SDRAM at D00000:");
        for (zw_i = 0; zw_i < 8; zw_i = zw_i + 1)
            $write(" %04h", device.mem[24'hD00000 + zw_i[23:0]]);
        $write("   (expect f3ed 3156 6000 21fd)\n");
        $write("FRAME: first firmware fetches:");
        for (zw_i = 0; zw_i < fwf_n; zw_i = zw_i + 1)
            $write(" [%04h]=%04h", fwf_a[zw_i], fwf_d[zw_i]);
        $write("\n");
        $write("FRAME: Z80 wrote the shared RAM %0d times; first 32:", z80_wr_n);
        for (zw_i = 0; zw_i < z80_first_n; zw_i = zw_i + 1)
            $write(" %03h=%02h", z80_first[zw_i], z80_firstd[zw_i]);
        $write("\n");
        $write("FRAME: Z80 write counts by address (non-zero):");
        for (zw_i = 0; zw_i < 2048; zw_i = zw_i + 1)
            if (z80_seen[zw_i] != 0) $write(" %03h:%0d", zw_i, z80_seen[zw_i]);
        $write("\n");
        $display("FRAME: bands filled = %0d, presented LATE = %0d, vertices out of the store's range = %0d",
                 core.u_raster3d.dbg_bands, core.u_raster3d.dbg_late, core.u_raster3d.dbg_oob);
        $display("FRAME: 3D passes=%0d  len mean=%0d.%02d fr max=%0d.%02d fr, over a frame=%0d | wait-for-swap mean=%0d.%02d max=%0d.%02d | idle mean=%0d.%02d max=%0d.%02d",
                 pass_n,
                 (pass_n > 0) ? (pass_len_sum / pass_n) / 1390821 : 0,
                 (pass_n > 0) ? (((pass_len_sum / pass_n) % 1390821) * 100) / 1390821 : 0,
                 pass_len_max / 1390821, ((pass_len_max % 1390821) * 100) / 1390821,
                 pass_len_over,
                 (pass_n > 0) ? (pass_wait_sum / pass_n) / 1390821 : 0,
                 (pass_n > 0) ? (((pass_wait_sum / pass_n) % 1390821) * 100) / 1390821 : 0,
                 pass_wait_max / 1390821, ((pass_wait_max % 1390821) * 100) / 1390821,
                 (pass_n > 1) ? (pass_idle_sum / (pass_n - 1)) / 1390821 : 0,
                 (pass_n > 1) ? (((pass_idle_sum / (pass_n - 1)) % 1390821) * 100) / 1390821 : 0,
                 pass_idle_max / 1390821, ((pass_idle_max % 1390821) * 100) / 1390821);
        $write("FRAME: 3D pass length, tenths of a frame:");
        for (pass_i = 0; pass_i < 32; pass_i = pass_i + 1)
            if (pass_len_hist[pass_i] != 0) $write(" %0d:%0d", pass_i, pass_len_hist[pass_i]);
        $write("\n");
        $write("FRAME: 3D pass cadence, start-to-start in frames:");
        for (pass_i = 0; pass_i < 16; pass_i = pass_i + 1)
            if (cadence_hist[pass_i] != 0) $write(" %0d:%0d", pass_i, cadence_hist[pass_i]);
        $write("\n");
        $display("FRAME: vertex coordinate range over the run: %0d .. %0d; quads with vertex 0 off-screen = %0d",
                 qmin, qmax, qoff);
        $display("FRAME: 3D ROM port: %0d requests, mean wait %0d clk_sys cycles",
                 r3rom_n, (r3rom_n > 0) ? r3rom_wait / r3rom_n : 0);
    end
    $display("FRAME: 3D state: st=%0d band=%0d bands=%0d fill=%0d ready=%0d disp=%0d rv=%0b armed=%0b dv=%0b sel=%0b",
             core.u_raster3d.cst, core.u_raster3d.cur_band,
             core.u_raster3d.dbg_bands, core.u_raster3d.fill_buf,
             core.u_raster3d.ready_buf, core.u_raster3d.disp_buf,
             core.u_raster3d.ready_valid, core.u_raster3d.frame_armed,
             core.u_raster3d.disp_valid, core.listctl_sel);
    if (v_cyc > 0)
        $display("FRAME: CPU %0d cycles: data stall %0d (%0d.%02d%%), fetch stall %0d (%0d.%02d%%), either %0d (%0d.%02d%%)",
                 v_cyc,
                 v_dstall,   (10000*v_dstall)/v_cyc/100,   ((10000*v_dstall)/v_cyc)%100,
                 v_fstall,   (10000*v_fstall)/v_cyc/100,   ((10000*v_fstall)/v_cyc)%100,
                 v_anystall, (10000*v_anystall)/v_cyc/100, ((10000*v_anystall)/v_cyc)%100);
    if (cpi_retires > 0) begin
        $display("FRAME: %0d retires in %0d CPU cycles = %0d.%02d CPI",
                 cpi_retires, cpi_cycles, cpi_cycles/cpi_retires,
                 ((cpi_cycles*100)/cpi_retires) % 100);
        $write("FRAME: retire-to-retire histogram:");
        for (cpi_i = 1; cpi_i < 64; cpi_i = cpi_i + 1)
            if (cpi_hist[cpi_i] * 200 > cpi_retires)
                $write(" %0d:%0d%%", cpi_i, (100*cpi_hist[cpi_i])/cpi_retires);
        $write("\n");
    end
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
    $display("FRAME: result-FIFO reads: offset0=%0d offset1=%0d  of offset0, empty=%0d and acked-while-empty=%0d",
             rd_lo, rd_hi, rd_lo_empty, rd_lo_empty_acked);
    $display("FRAME: W1400 writes by pc: fe48d5=%0d  fef3b5=%0d  fe1469=%0d  other=%0d",
             w1400_48d5, w1400_f3b5, w1400_1469, w1400_other);
    // THE GATE ON THE WHOLE GEOMETRY PATH.
    //   FEEF14 cmp.b #0, 501A35 / FEEF1C bne FEF047  - entered only when != 0
    //   FEF04E/FEF059 cmp.w #3/#4, 501A28            - diverted when 3 or 4
    // The reference holds 501A35 = 01 throughout and 501A28 = 0 then 1.
    // V60 byte B is device.mem word 0xF80000 + (B-0x500000)/2; 0x501A28 is word
    // 0xF80D14 and 0x501A35 is the HIGH byte of word 0xF80D1A.
    $display("FRAME: at FF84AE: hits=%0d  a0>b0 on %0d of them  last a0=%08h b0=%08h",
             gate_hits, gate_a0_gt, gate_a0_seen, gate_b0_seen);
    $display("FRAME: geometry gate: 501A35=%02h  501A28=%04h%04h   (reference: 01 and 00000001)",
             device.mem['hF80D1A][15:8], device.mem['hF80D15], device.mem['hF80D14]);
    begin
        integer hi, best, bi;
        longint tot;
        tot = 0;
        for (hi = 0; hi < 256; hi = hi + 1) tot = tot + pc_hist[hi];
        $display("FRAME: PC histogram, top buckets of %0d instructions:", tot);
        for (bi = 0; bi < 10; bi = bi + 1) begin
            best = 0;
            for (hi = 0; hi < 256; hi = hi + 1)
                if (pc_hist[hi] > pc_hist[best]) best = hi;
            if (pc_hist[best] > 0)
                $display("FRAME:   pc ??%02h.. : %0d  (%0d%%)", best, pc_hist[best],
                         (pc_hist[best]*100)/(tot == 0 ? 1 : tot));
            pc_hist[best] = 0;
        end
    end
    $display("FRAME: frame-tick 0x500501 values seen: 0=%0d 1=%0d 2=%0d 3=%0d 4=%0d 5=%0d 6=%0d 7+=%0d  (reference only ever 0/1/2)",
             tick_hist[0], tick_hist[1], tick_hist[2], tick_hist[3],
             tick_hist[4], tick_hist[5], tick_hist[6], tick_hist[7]);
    // THE OBJECT WORDS THE LOOP TESTS. FEB651 tests bit 26 of word 0 of each
    // object; the reference's are 0x80000000 or 0 and it always skips, ours has
    // one with bit 26 set and falls into the submission body. The array is at
    // V60 0x400f80 (pointer at 0x501324, count 15 at 0x501118); V60 byte B in
    // the 0x400000 region is device.mem word 0xFA0000 + (B-0x400000)/2, so
    // 0x400f80 is word 0xFA07C0.
    begin
        integer oi;
        $write("FRAME: object word0 at 0x400f80, stride 0x100:");
        for (oi = 0; oi < 6; oi = oi + 1)
            $write(" %04h%04h", device.mem['hFA07C0 + oi*128 + 1],
                                device.mem['hFA07C0 + oi*128]);
        $write("   (reference: 80000000 / 00000000, bit26 clear)\n");
    end
    $display("FRAME: object0 high-half writes=%0d, of which bit26 set=%0d", ob_wr, ob_wr_set);
    $display("FRAME: scroll chain: fe1c09=%0d fe1c15=%0d feeb10=%0d | feef14=%0d feef1c=%0d fef047=%0d fef2a3=%0d fef372=%0d",
             c_fe1c09, c_fe1c15, c_feeb10, c_feef14, c_feef1c, c_fef047, c_fef2a3, c_fef372);
    $display("FRAME: catch-up branch: fe13fb=%0d -> caught-up fe1406=%0d, BEHIND fe13fe=%0d | scroll fef372=%0d",
             t_cmp, t_ok, t_behind, t_scr);
    $display("FRAME: geometry loop: feb651=%0d feb65a=%0d -> body feb661=%0d feb673=%0d | skip feb688=%0d  (reference: body NEVER)",
             pc_feb651, pc_feb65a, pc_feb661, pc_feb673, pc_feb688);
    $display("FRAME: dispatch: fe1c09=%0d fe1c12=%0d -> fe1c15(call)=%0d fe1c18(skip)=%0d -> feeb10=%0d",
             pc_fe1c09, pc_fe1c12, pc_fe1c15, pc_fe1c18, pc_feeb10);
    $display("FRAME: upstream: feef14=%0d feef1c=%0d -> fef047=%0d fef04e=%0d fef325(divert)=%0d",
             pc_feef14, pc_feef1c, pc_fef047, pc_fef04e, pc_fef325);
    $display("FRAME: submit chain: fef9c6=%0d fef9cc=%0d -> fef9d2(call)=%0d fef9d8(skip)=%0d | fefa25=%0d fefa93=%0d fefad1=%0d fefb00=%0d",
             pc_fef9c6, pc_fef9cc, pc_fef9d2, pc_fef9d8,
             pc_fefa25, pc_fefa93, pc_fefad1, pc_fefb00);
    $display("FRAME: call chain: fefb40=%0d ff84a2=%0d ff84ae=%0d -> ff84b1(reads)=%0d ff8582(skip)=%0d ff850c=%0d",
             pc_fefb40, pc_ff84a2, pc_ff84ae, pc_ff84b1, pc_ff8582, pc_ff850c);
    // THE GATE ON THAT BLOCK. FF84A2 compares 5011B0 against 5011A0 and FF84AE
    // branches past every in.w if it goes the wrong way. The reference holds
    // 5011b0 = 0x157c and keeps 5011a0 below it, so it falls through and drains
    // the FIFO. V60 byte B maps to device.mem word 0xF80000 + (B-0x500000)/2,
    // so 0x5011a0 is word 0xF808D0 and 0x5011b0 is 0xF808D8.
    $display("FRAME: gate: 5011a0=%04h%04h  5011b0=%04h%04h  (reference: a0 < b0=0000157c)",
             device.mem['hF808D1], device.mem['hF808D0],
             device.mem['hF808D9], device.mem['hF808D8]);
    $display("FRAME: scroll-value routines reached: fe48d5=%0d  fef3b5=%0d  fe1469=%0d",
             pc_fe48d5, pc_fef3b5, pc_fe1469);
    $display("FRAME: scroll WRITES: hscr[5002]=%0d  vscr[5006]=%0d  all 5000-5007=%0d",
             tw_hscr2, tw_vscr2, tw_any_scroll);
    $display("FRAME:   controls: all tile-RAM writes=%0d  all acked bus writes=%0d",
             tw_all_tram, tw_all_acks);
    $display("FRAME:   tram writes by region: maps01=%0d maps23=%0d scroll4-5=%0d masks6-7=%0d  (of which 0x5xxx=%0d)",
             tw_reg[0], tw_reg[1], tw_reg[2], tw_reg[3], tw_5xxx);
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
            $fwrite(fd, "%04h\n", {core.main.rams.u_tram.mem_hi[i],
                                   core.main.rams.u_tram.mem_lo[i]});
        $fclose(fd);
        $display("FRAME: wrote %s (32768 tile-RAM words)", TRAMOUT);
    end

    // THE DISPLAY LIST OUR V60 WROTE, both buffers and the one selected.
    //
    // render3d already renders correctly from MAME's captured list and real
    // polygon data, so if the same rasterizer draws the wrong picture on the
    // board the difference is either what the V60 WRITES or the plumbing
    // between them. This is the half of that bisection the standalone bench
    // cannot supply: feed these to render3d and the two cases separate.
    fd = $fopen("build/frame_dlist0.hex", "w");
    if (fd != 0) begin
        for (i = 0; i < 32768; i = i + 1)
            $fwrite(fd, "%04h\n", {core.main.rams.u_dl0.mem_hi[i],
                                   core.main.rams.u_dl0.mem_lo[i]});
        $fclose(fd);
    end
    fd = $fopen("build/frame_dlist1.hex", "w");
    if (fd != 0) begin
        for (i = 0; i < 32768; i = i + 1)
            $fwrite(fd, "%04h\n", {core.main.rams.u_dl1.mem_hi[i],
                                   core.main.rams.u_dl1.mem_lo[i]});
        $fclose(fd);
    end
    $display("FRAME: wrote build/frame_dlist0.hex and _dlist1.hex, listctl_sel=%0d",
             core.listctl_sel);

    // THE COLOUR TRANSLATION TABLE, all three thirds.
    //
    // m1_geo_color looks a component up at (v << 8) | lum | base, with base
    // 0x0000 for red, 0x2000 for green and 0x4000 for BLUE - so blue lives in
    // the highest range and is the first thing lost if any part of the table is
    // missing. The board draws the 3D with no blue at all: a grey road comes out
    // olive and a white car comes out yellow, while red is unaffected because
    // its blue was already zero.
    fd = $fopen("build/frame_cxlat.hex", "w");
    if (fd != 0) begin
        for (i = 0; i < 24576; i = i + 1)
            $fwrite(fd, "%04h\n", {core.main.rams.u_cxlat.mem_hi[i],
                                   core.main.rams.u_cxlat.mem_lo[i]});
        $fclose(fd);
        $display("FRAME: wrote build/frame_cxlat.hex (24576 words)");
    end

    fd = $fopen(PALOUT, "w");
    if (fd == 0) $display("FRAME: could not open %s", PALOUT);
    else begin
        for (i = 0; i < 8192; i = i + 1)
            $fwrite(fd, "%04h\n", {core.main.rams.u_pram.mem_hi[i],
                                   core.main.rams.u_pram.mem_lo[i]});
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

// ---------------------------------------------------------------------------
// THE COPROCESSOR'S COMMAND AND ANSWER STREAMS, ONE LINE EACH, INSERTED ONCE.
//
// A previous version of this probe was inserted with a text replace whose
// anchor occurred TWICE in this file, so it landed in two always blocks and
// logged every command and answer twice - which read as "the V60 pushes each
// command twice" and nearly became a finding. Placed at a unique anchor and
// counted with grep before being believed.
//
// The command condition is exactly m1_copro_if's own push condition in S_IDLE,
// which fires once per access because `served` drops v60_acc the next cycle;
// fifo_out_push is a one-cycle pulse by construction (the `pushed` latch).
integer strm_n = 0, strm_f;
reg [23:0] tick_d = 24'hffffff;
longint t_cmp=0,t_ok=0,t_behind=0,t_scr=0;
reg mx_d = 1'b0, mx_d2 = 1'b0, mx_d3 = 1'b0, sc_w_d = 1'b0, sc_r_d = 1'b0, scr_d = 1'b0, sx_w_d = 1'b0, sx_r_d = 1'b0;
reg [15:0] sx_lo = 16'd0, sx_rlo = 16'd0;
reg [23:0] chain_d = 24'hffffff;
longint c_fe1c09=0,c_fe1c15=0,c_feeb10=0,c_feef14=0,c_feef1c=0,c_fef047=0,c_fef372=0,c_fef2a3=0;
reg [23:0] mxpc_d = 24'hffffff;
initial strm_f = $fopen("build/frame_streams.txt", "w");
always @(posedge clk_cpu) begin
    if (core.main.rst_n && strm_n < 20000) begin
        if (core.main.copro.st == 2'd0 && core.main.copro.v60_acc
            && core.main.copro.we && core.main.copro.sel_fifo && core.main.copro.a1
            && !core.main.copro.fin_full) begin
            strm_n = strm_n + 1;
            $fwrite(strm_f, "CMD %04h%04h f=%0d\n", core.main.copro.wdata, core.main.copro.lat_lo, frames);
        end
        // WRITES TO THE OPERAND MATRIX at V60 0x400d72..0x400da1 (72[R20] with
        // R20 = [0x40C900] = 0x400d00 in the reference), with the writing PC and
        // the frame. m_addr is [23:1], so byte 0x400d72 is 0x2006B9.
        if (core.main.m_we && core.main.m_ack
            && core.main.m_addr[23:1] >= 23'h2006B9 && core.main.m_addr[23:1] <= 23'h2006D0
            && !mx_d) begin
            strm_n = strm_n + 1;
            $fwrite(strm_f, "MXW %06h pc=%06h data=%04h f=%0d\n",
                    {core.main.m_addr[23:1], 1'b0}, core.dbg_pc, core.main.m_wdata, frames);
        end
        mx_d <= core.main.m_we && core.main.m_ack
             && core.main.m_addr[23:1] >= 23'h2006B9 && core.main.m_addr[23:1] <= 23'h2006D0;
        // EVERY acked data write issued from inside the matrix routine, whatever
        // its address. feda55/59/5d are `in.w [R23], [R4+]` - a read from the
        // coprocessor port with a MEMORY destination - and no write from them
        // reaches 0x400d72 here while the reference's do. Either R4 points
        // elsewhere or the instruction's memory write never happens.
        if (core.main.m_we && core.main.m_ack && !mx_d2
            && core.dbg_pc >= 24'hfeda50 && core.dbg_pc <= 24'hfedac0) begin
            strm_n = strm_n + 1;
            $fwrite(strm_f, "FEDW %06h pc=%06h data=%04h f=%0d\n",
                    {core.main.m_addr[23:1], 1'b0}, core.dbg_pc, core.main.m_wdata, frames);
        end
        mx_d2 <= core.main.m_we && core.main.m_ack;
        // and the READS those instructions make, to see the IN side happen at all
        if (core.main.m_req && !core.main.m_we && core.main.m_ack && !mx_d3
            && core.dbg_pc >= 24'hfeda50 && core.dbg_pc <= 24'hfedac0
            && core.main.m_addr[23:16] >= 8'hd8 && core.main.m_addr[23:16] <= 8'hd9) begin
            strm_n = strm_n + 1;
            $fwrite(strm_f, "FEDR %06h pc=%06h data=%04h f=%0d\n",
                    {core.main.m_addr[23:1], 1'b0}, core.dbg_pc, core.main.m_rdata, frames);
        end
        mx_d3 <= core.main.m_req && !core.main.m_we && core.main.m_ack;
        if (core.dbg_pc == 24'hfeda02 && core.dbg_pc != mxpc_d) begin
            strm_n = strm_n + 1;
            $fwrite(strm_f, "ENTER feda02 f=%0d\n", frames);
        end
        mxpc_d <= core.dbg_pc;
        // THE SINCOS UNIT'S TRAFFIC, io 0x20-0x23, values in and out. Answer 767
        // (microcode 037c) differs from the reference on identical commands and
        // is computed from a sincos lookup at 036F-0371. The unit matches MAME's
        // code on paper, so the values are compared instead; the reference side
        // is build/dasm/mame_sincos.txt from the same io addresses.
        if (core.main.tgp.io_wr && core.main.tgp.sel_math && core.main.tgp.io_addr[4:0] <= 5'h03
            && !sc_w_d) begin
            strm_n = strm_n + 1;
            $fwrite(strm_f, "SCW %02h %08h\n", {3'd0, core.main.tgp.io_addr[4:0]}, core.main.tgp.io_wdata);
        end
        sc_w_d <= core.main.tgp.io_wr && core.main.tgp.sel_math && core.main.tgp.io_addr[4:0] <= 5'h03;
        if (core.main.tgp.io_rd && core.main.tgp.sel_math && core.main.tgp.io_addr[4:0] <= 5'h03
            && core.main.tgp.io_ack && !sc_r_d) begin
            strm_n = strm_n + 1;
            $fwrite(strm_f, "SCR %02h %08h\n", {3'd0, core.main.tgp.io_addr[4:0]}, core.main.tgp.io_rdata);
        end
        sc_r_d <= core.main.tgp.io_rd && core.main.tgp.sel_math && core.main.tgp.io_addr[4:0] <= 5'h03
               && core.main.tgp.io_ack;
        // THE SCROLL REGISTER WRITE STREAM: every value the V60 writes to tile
        // RAM words 0x5002 (tilemap 2 hscr) and 0x5006 (pair 2/3 ctrl and vscr),
        // in order. "Is scrolling fixed" is answered by whether this sequence
        // matches the reference's, not by how often the register changes.
        // m_addr is [23:1]; tile RAM is 0x700000, so word W is m_addr 0x380000+W.
        if (core.main.m_we && core.main.m_ack && core.main.sel_tileram && !scr_d
            && (core.main.m_addr[15:1] == 15'h5002 || core.main.m_addr[15:1] == 15'h5006)) begin
            strm_n = strm_n + 1;
            $fwrite(strm_f, "SCROLL %04h %04h f=%0d\n", core.main.m_addr[15:1], core.main.m_wdata, frames);
        end
        scr_d <= core.main.m_we && core.main.m_ack && core.main.sel_tileram
              && (core.main.m_addr[15:1] == 15'h5002 || core.main.m_addr[15:1] == 15'h5006);
        // THE SCROLL EXCHANGE, per frame: the operand the V60 pushes at FEF37A
        // (movs.hw E5[R25]) and the answers it reads at FEF388. Ours writes 2064
        // and 2032 to 0x5006 on alternate frames where the reference advances;
        // this says whether the QUESTION alternates or the ANSWER does.
        if (core.main.m_we && core.main.m_ack && !sx_w_d
            && core.main.m_addr[23:16] >= 8'hd8 && core.main.m_addr[23:16] <= 8'hd9
            && core.dbg_pc == 24'hfef37a) begin
            strm_n = strm_n + 1;
            if (core.main.m_addr[1]) $fwrite(strm_f, "OPER %04h%04h f=%0d\n", core.main.m_wdata, sx_lo, frames);
            else sx_lo = core.main.m_wdata;
        end
        sx_w_d <= core.main.m_we && core.main.m_ack
               && core.main.m_addr[23:16] >= 8'hd8 && core.main.m_addr[23:16] <= 8'hd9;
        if (core.main.m_req && !core.main.m_we && core.main.m_ack && !sx_r_d
            && core.main.m_addr[23:16] >= 8'hd8 && core.main.m_addr[23:16] <= 8'hd9
            && core.dbg_pc == 24'hfef388) begin
            strm_n = strm_n + 1;
            if (core.main.m_addr[1]) $fwrite(strm_f, "ANSW %04h%04h f=%0d\n", core.main.m_rdata, sx_rlo, frames);
            else sx_rlo = core.main.m_rdata;
        end
        sx_r_d <= core.main.m_req && !core.main.m_we && core.main.m_ack
               && core.main.m_addr[23:16] >= 8'hd8 && core.main.m_addr[23:16] <= 8'hd9;
        // THE CALL CHAIN ABOVE THE SCROLL UPDATE, edge-detected (dbg_pc is a
        // level; comparing it directly counts CYCLES, which has caught me twice).
        //   FE1C09 object dispatch loop -> FE1C15 indirect call
        //   FEEB10 the object's handler -> FEEF14 gate -> FEF047 -> FEF372 scroll
        // The reference runs the scroll exchange every 2 frames; we manage 3 in
        // a whole run, and 1.25x slower does not explain 40x.
        if (core.dbg_pc != chain_d) begin
            if (core.dbg_pc == 24'hfe1c09) c_fe1c09 <= c_fe1c09 + 1;
            if (core.dbg_pc == 24'hfe1c15) c_fe1c15 <= c_fe1c15 + 1;
            if (core.dbg_pc == 24'hfeeb10) c_feeb10 <= c_feeb10 + 1;
            if (core.dbg_pc == 24'hfeef14) c_feef14 <= c_feef14 + 1;
            if (core.dbg_pc == 24'hfeef1c) c_feef1c <= c_feef1c + 1;
            if (core.dbg_pc == 24'hfef047) c_fef047 <= c_fef047 + 1;
            if (core.dbg_pc == 24'hfef372) c_fef372 <= c_fef372 + 1;
            if (core.dbg_pc == 24'hfef2a3) c_fef2a3 <= c_fef2a3 + 1;
        end
        chain_d <= core.dbg_pc;
        // THE GAME'S CATCH-UP BRANCH. FE13F3 compares the frame tick against 3
        // and FE13FB takes FE1406 when caught up; falling through to FE13FE is
        // the behind path. If we take the behind path often, the frame's work -
        // including the scroll update - is skipped, which turns a modest speed
        // deficit into a large rate deficit. Edge-detected: dbg_pc is a level.
        if (core.dbg_pc != tick_d) begin
            if (core.dbg_pc == 24'hfe13fb) t_cmp   <= t_cmp   + 1;
            if (core.dbg_pc == 24'hfe1406) t_ok    <= t_ok    + 1;
            if (core.dbg_pc == 24'hfe13fe) t_behind<= t_behind+ 1;
            if (core.dbg_pc == 24'hfef372) t_scr   <= t_scr   + 1;
        end
        tick_d <= core.dbg_pc;
        if (core.main.copro.fifo_out_push) begin
            strm_n = strm_n + 1;
            $fwrite(strm_f, "ANS %08h pc=%04h\n", core.main.copro.fifo_out_data,
                    core.main.tgp.core.seq_pc);
        end
    end
end

endmodule
