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
    parameter string  PPMOUT     = "build/frame.ppm"
);

localparam integer PRELOAD_WORDS = 32'h300000;

// 100/25 MHz rather than the design's 96/19.2: the ratio is what the crossings
// care about and round half-periods keep the cycle arithmetic readable.
reg clk = 0, clk_cpu = 0, rst_n = 0;
always #5  clk     = ~clk;
always #20 clk_cpu = ~clk_cpu;

reg [1:0] rs_sys = 0, rs_cpu = 0;
wire rst_n_sys = rs_sys[1];
wire rst_n_cpu = rs_cpu[1];
always @(posedge clk     or negedge rst_n) if (!rst_n) rs_sys <= 0; else rs_sys <= {rs_sys[0], 1'b1};
always @(posedge clk_cpu or negedge rst_n) if (!rst_n) rs_cpu <= 0; else rs_cpu <= {rs_cpu[0], 1'b1};

// 100 MHz to a 16 MHz dot clock is not integral; /6 gives 16.67 MHz, which is
// close enough for a picture and keeps this identical to the real divider.
reg [2:0] pixdiv = 0;
reg       ce_pix = 0;
always @(posedge clk) begin
    ce_pix <= (pixdiv == 3'd5);
    pixdiv <= (pixdiv == 3'd5) ? 3'd0 : pixdiv + 3'd1;
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
assign p_addr = {24'd0, 24'd0, ifp_addr, {6'd0, char_addr}, sdr_addr};
assign p_din  = {16'd0, 16'd0, 16'd0,    16'd0,             sdr_din};
assign p_be   = {2'd0,  2'd0,  2'd0,     2'd0,              sdr_be};

wire        cke, cs_n, ras_n, cas_n, we_n;
wire [1:0]  ba, dqm;
wire [12:0] a;
wire [15:0] dq_c2m, dq_m2c;
wire        dq_oe_c, dq_oe_m;
wire [15:0] v_flags;
wire        mem_ready;

m1_sdram #(.NP(5), .INIT_NOP(600)) sdram (
    .clk(clk), .rst_n(rst_n_sys), .ready(mem_ready),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n),
    .sd_we_n(we_n), .sd_ba(ba), .sd_a(a), .sd_dqm(dqm),
    .sd_dq_o(dq_c2m), .sd_dq_oe(dq_oe_c), .sd_dq_i(dq_m2c),
    .wr_req(1'b0), .wr_addr(24'd0), .wr_din(16'd0), .wr_be(2'b11), .wr_ack(),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack),
    .dbg_req(), .dbg_grant()
);

sdram_model #(.COL_BITS(9)) device (
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

m1_integrated core (
    .clk_sys(clk), .ce_pix(ce_pix),
    .clk_cpu(clk_cpu), .ce_cpu(1'b1),
    .rst_n(rst_n), .rom_loaded(mem_ready),

    .sdr_req(sdr_req), .sdr_we(sdr_we), .sdr_addr(sdr_addr),
    .sdr_din(sdr_din), .sdr_be(sdr_be),
    .sdr_dout(p_dout[0][15:0]), .sdr_ack(p_ack[0]),

    .if_req(ifp_req), .if_addr(), .if_sdram_addr(ifp_addr),
    .if_data(p_dout[2]), .if_ack(p_ack[2]),

    .char_req(char_req), .char_addr(char_addr),
    .char_data(p_dout[1][31:0]), .char_ack(p_ack[1]),

    .ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0),
    .ioctl_addr(27'd0), .ioctl_dout(16'd0), .ioctl_wait(),
    .ldr_wr_req(), .ldr_wr_addr(), .ldr_wr_din(), .ldr_wr_be(),
    .ldr_wr_ack(1'b0),
    .tgp_wr(), .tgp_addr(), .tgp_din(),

    .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
    .vid_hs(vid_hs), .vid_vs(vid_vs), .vid_hb(vid_hb), .vid_vb(vid_vb),

    .mon_sel(3'd0), .mon_snap(1'b0),
    .mon_req(), .mon_grant(), .mon_wait(), .mon_bmax(), .mon_total(),
    .mon_req_in(5'd0), .mon_grant_in(5'd0),

    .dbg_pc(dbg_pc), .dbg_halted(dbg_halted), .dbg_fp_trap(dbg_fp_trap),
    .dbg_io_replies(dbg_io_replies),
    .rom_loaded_o(), .dbg_fetches()
);

// ----------------------------------------------------------------- preload
reg [15:0] rom [0:PRELOAD_WORDS-1];
integer i;
initial begin
    $readmemh(ROMHEX, rom);
    for (i = 0; i < PRELOAD_WORDS; i = i + 1) device.mem[i] = rom[i];
    $display("preloaded %0d words", PRELOAD_WORDS);
end

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
integer pv, tv;

always @(posedge clk) begin
    if (probe_on && ce_pix) begin
        pv = core.vid_pal_data;
        if (pal_seen[pv] == 0) begin
            pal_seen[pv] = 1;
            npal = npal + 1;
        end
        tv = core.vid_tram_data;
        if (tram_seen[tv] == 0) begin
            tram_seen[tv] = 1;
            ntram = ntram + 1;
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
    $display("SDRAM ready, releasing the V60");

    for (i = 0; i < 65536; i = i + 1) begin pal_seen[i] = 0; tram_seen[i] = 0; end
    cycles = 0;
    probe_on = 1;
    while (cycles < RUN_CYCLES && !dbg_halted) begin
        @(posedge clk);
        cycles = cycles + 1;
        // Progress, because this run is long enough that silence is
        // indistinguishable from a hang.
        if (cycles % 20000000 == 0)
            $display("  %0d M cycles: pc=%06h frames=%0d painted=%0d nonblack=%0d",
                     cycles/1000000, dbg_pc, frames, painted, nonblack);
    end

    $display("");
    $display("FRAME: cycles=%0d halted=%0d fp_trap=%0d", cycles, dbg_halted, dbg_fp_trap);
    $display("FRAME: pc=%06h io_replies=%0d sdram_violations=%04h",
             dbg_pc, dbg_io_replies, v_flags);
    $display("FRAME: %0d frames, %0d pixels painted, %0d non-black",
             frames, painted, nonblack);
    $display("PROBE: %0d distinct palette words, %0d distinct tile words seen by the renderer",
             npal, ntram);
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
