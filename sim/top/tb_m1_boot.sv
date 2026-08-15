//============================================================================
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Booting real game code.
//
// Everything up to now has been checked against MAME's descriptions or against
// synthetic programs. This runs the actual ROM: the V60 starts at the
// architectural reset vector, fetches through m1_decode's packed mapping, and
// executes whatever Sega wrote. It is the first test that can be wrong in ways
// no amount of unit testing predicts.
//
// It answers several open questions at once:
//
//   - does the decode hold up on real code, rather than on 466k synthetic
//     addresses
//   - real-code cycles per instruction, which the 12-byte loop in tb_v60_cpi
//     cannot give and which the whole timing argument rests on
//   - whether dbg_fp_trap ever fires, which decides a ~2,000 ALM build option
//   - and when it stops making progress, dbg_pc says exactly where
//
// The SDRAM device model is preloaded directly rather than through the ROM
// loader. The loader is tested separately and pushing 1.5 MB through it would
// cost about 8 M cycles of simulation before the CPU had executed anything.
//
// ROM images are not in the repository. Build the preload with
//   python3 tools/build_rom_image.py vr ~/roms/vr.zip -o build/rom
//============================================================================
`timescale 1ns/1ps

module tb_m1_boot #(
    parameter integer RUN_CYCLES = 3000000,
    parameter string  ROMHEX     = "build/rom/vr_v60.hex",
    // Page whose individual addresses are logged. Defaults to the I/O board's
    // dual-port RAM, which is where boot used to stop.
    //
    // Every count this testbench prints scales with RUN_CYCLES. Quote the two
    // together — a set of figures recorded without its run length already read
    // as a regression once, and was not one.
    parameter [7:0]   WATCH_PAGE = 8'hC0
);

// Packed V60-visible ROM: ROMX at word 0, ROM0 at word 0x80000.
// ROMX, ROM0 and the banked data ROMs. The boot ROM checksums the data ROMs
// too, so preloading only the program leaves that sweep reading zeros.
localparam integer PRELOAD_WORDS = 32'h300000;

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

reg [1:0] cediv = 0;
wire ce = (cediv == 0);
always @(posedge clk) cediv <= (cediv == 2) ? 2'd0 : cediv + 2'd1;

wire        sdr_req, sdr_we;
wire [24:1] sdr_addr;
wire [15:0] sdr_din, sdr_dout;
wire  [1:0] sdr_be;
wire        sdr_ack;
wire        if_req, if_ack;
wire [23:0] if_addr;
wire [24:1] if_sdram_addr;
wire [63:0] if_data;
wire [23:0] dbg_pc;
wire        dbg_halted, dbg_fp_trap;
wire [15:0] dbg_io_replies;
wire        mem_ready;

m1_main main (
    .clk(clk), .ce(ce), .rst_n(rst_n), .rom_loaded(mem_ready),
    .sdr_req(sdr_req), .sdr_we(sdr_we), .sdr_addr(sdr_addr),
    .sdr_din(sdr_din), .sdr_be(sdr_be), .sdr_dout(sdr_dout), .sdr_ack(sdr_ack),
    .if_req(if_req), .if_addr(if_addr), .if_sdram_addr(if_sdram_addr),
    .if_data(if_data), .if_ack(if_ack),
    .vid_tram_addr(15'd0), .vid_tram_data(),
    .vid_pal_addr(12'd0),  .vid_pal_data(),
    .vblank_irq(vblank_pulse),
    .dbg_pc(dbg_pc), .dbg_halted(dbg_halted), .dbg_fp_trap(dbg_fp_trap), .dbg_io_replies(dbg_io_replies),
    .rom_bank()
);

// Vertical blanking at the real rate: 424 lines of 656 dot clocks at 16 MHz,
// and this runs at 100 MHz, so a frame is 656*424*100/16 core cycles.
localparam integer FRAME_CYCLES = 656*424*100/16;
integer vbl_cnt = 0;
reg vblank_pulse = 0;
always @(posedge clk) begin
    if (!rst_n) begin vbl_cnt <= 0; vblank_pulse <= 0; end
    else begin
        vblank_pulse <= 0;
        if (vbl_cnt == FRAME_CYCLES-1) begin vbl_cnt <= 0; vblank_pulse <= 1; end
        else vbl_cnt <= vbl_cnt + 1;
    end
end

wire [4:0]       p_req, p_we, p_ack;
wire [4:0][24:1] p_addr;
wire [4:0][15:0] p_din;
wire [4:0][1:0]  p_be;
wire [4:0][63:0] p_dout;

reg        ifp_req = 0;
reg [24:1] ifp_addr = 0;
assign p_req  = {2'b00, ifp_req, 1'b0, sdr_req};
assign p_we   = {4'b0000, sdr_we};
assign p_addr = {24'd0, 24'd0, ifp_addr, 24'd0, sdr_addr};
assign p_din  = {16'd0, 16'd0, 16'd0, 16'd0, sdr_din};
assign p_be   = {2'd0, 2'd0, 2'd0, 2'd0, sdr_be};
assign sdr_dout = p_dout[0][15:0];
assign sdr_ack  = p_ack[0];

wire        cke, cs_n, ras_n, cas_n, we_n;
wire [1:0]  ba, dqm;
wire [12:0] a;
wire [15:0] dq_c2m, dq_m2c;
wire        dq_oe_c, dq_oe_m;
wire [4:0]  dbg_req_v, dbg_grant_v;
wire [15:0] v_flags;

m1_sdram #(.NP(5), .INIT_NOP(600)) sdram (
    .clk(clk), .rst_n(rst_n), .ready(mem_ready),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n),
    .sd_we_n(we_n), .sd_ba(ba), .sd_a(a), .sd_dqm(dqm),
    .sd_dq_o(dq_c2m), .sd_dq_oe(dq_oe_c), .sd_dq_i(dq_m2c),
    .wr_req(1'b0), .wr_addr(24'd0), .wr_din(16'd0), .wr_be(2'b11), .wr_ack(),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack),
    .dbg_req(dbg_req_v), .dbg_grant(dbg_grant_v)
);

sdram_model #(.COL_BITS(9)) device (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .ba(ba), .a(a), .dqm(dqm),
    .dq_i(dq_c2m), .dq_oe_i(dq_oe_c), .dq_o(dq_m2c), .dq_oe_o(dq_oe_m),
    .violations(), .v_flags(v_flags), .reads_served(), .writes_served()
);

// Instruction fetch bridge: one 4-word burst per 8-byte line, acknowledged on
// the rising edge while our own request is outstanding.
reg [2:0] if_foff = 0;
reg       if_pending = 0, p2_ack_d = 0, if_served = 0;
reg [63:0] if_data_r = 0;
assign if_ack  = if_served;
assign if_data = if_data_r;
integer if_lines = 0;

always @(posedge clk) begin
    if (!rst_n) begin
        ifp_req <= 0; if_served <= 0; if_pending <= 0; p2_ack_d <= 0;
    end else begin
        ifp_req  <= 0;
        p2_ack_d <= p_ack[2];
        if (!if_req) begin if_served <= 0; if_pending <= 0; end
        else if (!if_served && !if_pending) begin
            ifp_addr <= if_sdram_addr; if_foff <= if_addr[2:0];
            ifp_req  <= 1'b1; if_pending <= 1'b1;
        end else if (if_pending && p_ack[2] && !p2_ack_d) begin
            if_pending <= 1'b0;
            if_data_r  <= p_dout[2] >> {if_foff, 3'b000};
            if_served  <= 1'b1;
            if_lines    = if_lines + 1;
        end
    end
end

// ------------------------------------------------------------------ preload
reg [15:0] rom [0:PRELOAD_WORDS-1];
integer i;
initial begin
    $readmemh(ROMHEX, rom);
    // sdram_model indexes by bank<<22 | row<<9 | col, and m1_sdram splits the
    // word address as bank=[23:22] row=[21:9] col=[8:0] — so the device index
    // IS the word address and this is a straight copy.
    for (i = 0; i < PRELOAD_WORDS; i = i + 1) device.mem[i] = rom[i];
    $display("preloaded %0d words", PRELOAD_WORDS);
end

// ------------------------------------------------- minimal I/O responder
//
// The handshake responder now lives in RTL — rtl/io/m1_ioboard.sv — and this
// testbench no longer pokes the DPRAM behind the design's back. That is the
// point of the change: the experiment established the protocol, and running
// boot against the real module is what proves the module implements it.
//
// m1_main instantiates it by default, so nothing is wired here. Its answer
// count comes out on dbg_io_replies, and boot reaching fe143d with three
// replies is the end-to-end check.

// ------------------------------------------------------- access histogram
// When the CPU stops making progress the question is what it is waiting for,
// and that is answered by which addresses it keeps reading. A histogram by
// 64 KB page names the region; the exact address names the register.
integer hist [0:255];
integer exact_addr [0:31];
integer exact_cnt  [0:31];
integer exact_wr   [0:31];
integer wr_addr [0:23];
integer wr_data [0:23];
integer wr_be   [0:23];
integer wr_cyc  [0:23];
integer nwr = 0;
integer rd_addr [0:31];
integer rd_cnt  [0:31];
integer nrd = 0;
integer nexact = 0;
integer hi, j, found;
reg [23:1] last_addr_seen = 0;
reg        m_req_d = 0;

always @(posedge clk) begin
    if (!rst_n) begin
        for (hi = 0; hi < 256; hi = hi + 1) hist[hi] = 0;
        for (hi = 0; hi < 32; hi = hi + 1) begin exact_addr[hi]=0; exact_cnt[hi]=0; exact_wr[hi]=0; end
        nwr = 0; nrd = 0;
        for (hi = 0; hi < 32; hi = hi + 1) begin rd_addr[hi]=0; rd_cnt[hi]=0; end
        nexact = 0;
    end else begin
        m_req_d <= main.m_req;
        if (main.m_req && !m_req_d) begin
            hist[main.m_addr[23:16]] = hist[main.m_addr[23:16]] + 1;
            // Exact addresses within one page of interest. A page histogram
            // says which device the CPU is talking to; this says which
            // register, which is what a high-level implementation of that
            // device has to get right.
            // Log every write to the watched page with its data. The
            // addresses alone said the V60 sends a four-byte command and then
            // polls one status byte; the command's CONTENT is what says what it
            // is asking for, and guessing a reply without reading the request
            // would be exactly the poking-until-it-boots this project avoids.
            // Reads matter now too. Once the handshake stops blocking, the
            // question is what the V60 READS out of the I/O board — controls,
            // DIP switches, coin and service inputs — because that decides
            // whether a small responder covers M1 or whether the real
            // 315-5338A has to exist behind it.
            if (main.m_addr[23:16] == WATCH_PAGE && !main.m_we && nrd < 32) begin
                found = 0;
                for (j = 0; j < nrd; j = j + 1)
                    if (rd_addr[j] == {main.m_addr, 1'b0}) begin
                        rd_cnt[j] = rd_cnt[j] + 1; found = 1;
                    end
                if (!found) begin
                    rd_addr[nrd] = {main.m_addr, 1'b0};
                    rd_cnt[nrd]  = 1;
                    nrd = nrd + 1;
                end
            end
            if (main.m_addr[23:16] == WATCH_PAGE && main.m_we && nwr < 24) begin
                wr_addr[nwr] = {main.m_addr, 1'b0};
                wr_data[nwr] = main.m_wdata;
                wr_be[nwr]   = main.m_be;
                wr_cyc[nwr]  = cycles;
                nwr = nwr + 1;
            end
            if (main.m_addr[23:16] == WATCH_PAGE) begin
                found = 0;
                for (j = 0; j < nexact; j = j + 1)
                    if (exact_addr[j] == {main.m_addr, 1'b0}) begin
                        exact_cnt[j] = exact_cnt[j] + 1; found = 1;
                    end
                if (!found && nexact < 32) begin
                    exact_addr[nexact] = {main.m_addr, 1'b0};
                    exact_cnt[nexact]  = 1;
                    exact_wr[nexact]   = main.m_we;
                    nexact = nexact + 1;
                end
            end
        end
    end
end

// ------------------------------------------------------------------- run
integer cycles, ce_cycles, last_pc, stuck, pcmin, pcmax, distinct;
integer instrs;
reg [23:0] seen_hi;
initial begin
    repeat (8) @(posedge clk);
    rst_n = 1;
    while (!mem_ready) @(posedge clk);
    $display("SDRAM ready, releasing V60 at the reset vector");

    cycles = 0; ce_cycles = 0; last_pc = -1; stuck = 0; instrs = 0;
    pcmin = 32'h7fffffff; pcmax = 0;
    while (cycles < RUN_CYCLES && !dbg_halted) begin
        @(posedge clk);
        cycles = cycles + 1;
        if (ce) ce_cycles = ce_cycles + 1;
        if (dbg_pc != last_pc) begin
            // dbg_pc advances once per retired instruction, so counting the
            // changes gives an instruction count and therefore real-code CPI —
            // the figure tb_v60_cpi's twelve-byte loop cannot provide.
            instrs = instrs + 1;
            last_pc = dbg_pc;
            stuck = 0;
            if (dbg_pc < pcmin) pcmin = dbg_pc;
            if (dbg_pc > pcmax) pcmax = dbg_pc;
        end else stuck = stuck + 1;
    end

    $display("");
    $display("BOOT: cycles=%0d ce=%0d halted=%0d fp_trap=%0d",
             cycles, ce_cycles, dbg_halted, dbg_fp_trap);
    $display("BOOT: pc now %06h, range visited %06h..%06h, ifetch lines %0d",
             dbg_pc, pcmin, pcmax, if_lines);
    // Cycles per instruction, with a caveat that matters more than the number:
    // the V60's block group (MOVC/CMPC and friends) is ONE instruction that
    // runs for as long as the block is large, and Model 1's boot ROM checksums
    // megabytes with it. Averaged across that, "cycles per instruction" says
    // nothing about instruction throughput — the 199 this first reported was a
    // single block instruction sweeping ROM, not a slow CPU.
    //
    // A real figure needs a window that excludes block instructions, or a
    // workload without them. Reported anyway, labelled, because it is still the
    // right measure over ordinary code and the label stops it being quoted as
    // if it were.
    if (instrs > 0)
        $display("BOOT: %0d instructions over %0d CPU cycles = %0d.%02d avg (INCLUDES block instructions)",
                 instrs, ce_cycles, ce_cycles/instrs,
                 ((ce_cycles % instrs) * 100) / instrs);
    $display("BOOT: io handshake replies=%0d (answered in RTL by m1_ioboard)",
             dbg_io_replies);
    $display("BOOT: sdram violations flags=%04h", v_flags);
    $display("BOOT: bus accesses by 64KB page:");
    for (i = 0; i < 256; i = i + 1)
        if (hist[i] != 0)
            $display("        %02h0000  %0d", i, hist[i]);
    $display("BOOT: reads from page %02h0000 (%0d distinct), busiest first:",
             WATCH_PAGE, nrd);
    for (i = 0; i < nrd; i = i + 1)
        if (rd_cnt[i] > 2)
            $display("        %06h  %0d", rd_addr[i], rd_cnt[i]);
    $display("BOOT: writes to page %02h0000, in order:", WATCH_PAGE);
    for (i = 0; i < nwr; i = i + 1)
        $display("        cyc %-10d %06h  be=%b  data=%04h", wr_cyc[i],
                 wr_addr[i], wr_be[i], wr_data[i]);
    $display("BOOT: addresses touched in page %02h0000 (%0d distinct):",
             WATCH_PAGE, nexact);
    for (i = 0; i < nexact; i = i + 1)
        $display("        %06h  %-9d %s", exact_addr[i], exact_cnt[i],
                 exact_wr[i] ? "(write seen)" : "(read only)");
    if (dbg_fp_trap)
        $display("BOOT: *** FP opcode executed — S32_V60_NO_FP is NOT safe ***");
    $finish;
end

endmodule
