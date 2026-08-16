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
    parameter integer RUN_CYCLES = 120000000,
    parameter string  ROMHEX     = "build/rom/vr_v60.hex",
    parameter string  PPMOUT     = "build/frame.ppm",

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
    parameter bit     HOLD_CPU   = 0
);

localparam integer PRELOAD_WORDS = 32'h300000;

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

assign p_req  = {2'b00, ifp_req, char_req,          sdr_req};
assign p_we   = {2'b00, 1'b0,    1'b0,              sdr_we};
// Character RAM lives at CHAR_BASE in SDRAM, exactly where m1_main maps the
// CPU's writes to 0x780000-0x7fffff. The renderer emits an offset within that
// region, so the base has to be added here — without it the tilemap fetches
// from word 0, which is V60 program ROM, and every glyph decodes from the same
// wrong data. 31 distinct tile numbers then render identically and the screen
// is a uniform pattern that looks like a video bug rather than an address one.
assign p_addr = {24'd0, 24'd0, ifp_addr,
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
    .rd_lat_sel(2'd1),   // CL+3: sdram_model presents data on the same edge
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

    .sdr_req(sdr_req), .sdr_we(sdr_we), .sdr_addr(sdr_addr),
    .sdr_din(sdr_din), .sdr_be(sdr_be),
    .sdr_dout(p_dout[0][15:0]), .sdr_ack(p_ack[0]),

    .if_req(ifp_req), .if_addr(), .if_sdram_addr(ifp_addr),
    .if_data(p_dout[2]), .if_ack(p_ack[2]),

    .char_req(char_req), .char_addr(char_addr),
    .char_data(p_dout[1][31:0]), .char_ack(p_ack[1]),

    .ioctl_download(ioctl_download), .ioctl_index(16'd0), .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
    .ldr_wr_req(ldr_wr_req), .ldr_wr_addr(ldr_wr_addr),
    .ldr_wr_din(ldr_wr_din), .ldr_wr_be(ldr_wr_be), .ldr_wr_ack(ldr_wr_ack),
    .tgp_wr(), .tgp_addr(), .tgp_din(),

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

// ------------------------------------------------------------ frame capture
localparam integer W = 496;
localparam integer H = 384;

integer fb_r [0:H*W-1];
integer fb_g [0:H*W-1];
integer fb_b [0:H*W-1];
integer px = 0, py = 0;
integer frames = 0, painted = 0, nonblack = 0;
reg     prev_vb = 0;

always @(posedge clk) begin
    if (!rst_n_sys) begin
        px <= 0; py <= 0; prev_vb <= 0;
    end else if (ce_pix) begin
        // Frame boundary on the rising edge of vertical blanking, the same
        // convention tb_m1_video uses.
        if (vid_vb && !prev_vb) begin
            px <= 0; py <= 0;
            frames = frames + 1;
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
integer cycles, fd, x, y;
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
        while (!loader_done) @(posedge clk);
        $display("loader reports the ROM is in memory");
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
                $display("  %0d M cycles: pc=%06h frames=%0d painted=%0d nonblack=%0d",
                         cycles/1000000, dbg_pc, frames, painted, nonblack);
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
    end
    $finish;
end

endmodule
