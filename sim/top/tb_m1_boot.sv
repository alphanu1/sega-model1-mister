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

// TWO CLOCK DOMAINS, which is what the core actually has: memory and video on
// the fast clock, the V60 on the slow one. 100/25 MHz here rather than the
// design's 96/24 because a 5 ns half-period keeps the trace arithmetic round;
// the ratio is the same 4:1 and that is what the crossings care about.
//
// This testbench is where the two-domain design gets its only functional test.
// The individual crossings are verified in isolation; boot is what proves they
// work together, in a design where a lost transaction shows up as a CPU that
// stops rather than as an assertion.
reg clk = 0, clk_cpu = 0, rst_n = 0;
always #5  clk     = ~clk;        // 100 MHz, memory and video
always #20 clk_cpu = ~clk_cpu;    // 25 MHz, the V60

// The V60 gets every slow edge. At 25 MHz that is above the ~17 MHz the CPI
// analysis says is needed to match a 16 MHz part, and under the 24.62 MHz the
// core closes at.
wire ce = 1'b1;

// Reset released separately into each domain.
reg [1:0] rs_sys = 0, rs_cpu = 0;
wire rst_n_sys = rs_sys[1];
wire rst_n_cpu = rs_cpu[1];
always @(posedge clk     or negedge rst_n) if (!rst_n) rs_sys <= 0; else rs_sys <= {rs_sys[0], 1'b1};
always @(posedge clk_cpu or negedge rst_n) if (!rst_n) rs_cpu <= 0; else rs_cpu <= {rs_cpu[0], 1'b1};

// rom_loaded crosses fast to slow; it only ever rises once, before the CPU runs.
reg [1:0] mem_ready_cpu = 0;
always @(posedge clk_cpu or negedge rst_n_cpu)
    if (!rst_n_cpu) mem_ready_cpu <= 0;
    else            mem_ready_cpu <= {mem_ready_cpu[0], mem_ready};

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
    .clk(clk_cpu), .ce(ce), .rst_n(rst_n_cpu), .rom_loaded(mem_ready_cpu[1]),
    // Idle-high: every control is active low, so zero means all held down.
    // At rest: digital bytes idle-high, the three ADC channels at their
    // measured released values — steering centred, both pedals up.
    .in_bytes({96'hffffffffffffffffffffffff, 8'h01, 8'h01, 8'h80}),
    .sdr_req(sdr_req), .sdr_we(sdr_we), .sdr_addr(sdr_addr),
    .sdr_din(sdr_din), .sdr_be(sdr_be), .sdr_dout(sdr_dout), .sdr_ack(sdr_ack),
    .if_req(if_req), .if_addr(if_addr), .if_sdram_addr(if_sdram_addr),
    .if_data(if_data), .if_ack(if_ack),
    .vid_clk(clk), .vid_tram_addr(15'd0), .vid_tram_data(),
    .vid_pal_addr(12'd0),  .vid_pal_data(),
    .vblank_irq(vblank_pulse),
    .dbg_pc(dbg_pc), .dbg_halted(dbg_halted), .dbg_fp_trap(dbg_fp_trap), .dbg_io_replies(dbg_io_replies),
    .rom_bank()
);

// Vertical blanking at the real rate: 424 lines of 656 dot clocks at 16 MHz,
// and this runs at 100 MHz, so a frame is 656*424*100/16 core cycles.
localparam integer FRAME_CYCLES = 656*424*100/16;
integer vbl_cnt = 0;
reg vblank_sys = 0;
wire vblank_pulse;
always @(posedge clk) begin
    if (!rst_n_sys) begin vbl_cnt <= 0; vblank_sys <= 0; end
    else begin
        vblank_sys <= 0;
        if (vbl_cnt == FRAME_CYCLES-1) begin vbl_cnt <= 0; vblank_sys <= 1; end
        else vbl_cnt <= vbl_cnt + 1;
    end
end

// One fast cycle wide, and the interrupt controller is in the slow domain.
m1_cdc_pulse vblank_cdc (
    .a_clk(clk), .a_rst_n(rst_n_sys), .a_pulse(vblank_sys),
    .b_clk(clk_cpu), .b_rst_n(rst_n_cpu), .b_pulse(vblank_pulse)
);

wire [4:0]       p_req, p_we, p_ack;
wire [4:0][24:1] p_addr;
wire [4:0][15:0] p_din;
wire [4:0][1:0]  p_be;
wire [4:0][63:0] p_dout;

wire        ifp_req;
wire [24:1] ifp_addr;
assign p_req  = {2'b00, ifp_req, 1'b0, m_sdr_req};
assign p_we   = {4'b0000, m_sdr_we};
assign p_addr = {24'd0, 24'd0, ifp_addr, 24'd0, m_sdr_addr};
assign p_din  = {16'd0, 16'd0, 16'd0, 16'd0, m_sdr_din};
assign p_be   = {2'd0, 2'd0, 2'd0, 2'd0, m_sdr_be};
// The V60's data port crosses here rather than being wired straight to the
// controller, which is the whole point of this configuration.
wire        m_sdr_req, m_sdr_we, m_sdr_ack, m_sdr_busy;
wire [24:1] m_sdr_addr;
wire [15:0] m_sdr_din;
wire  [1:0] m_sdr_be;

m1_cdc_port #(.AW(24), .DW(16), .BEW(2)) data_cdc (
    .a_clk(clk_cpu), .a_rst_n(rst_n_cpu),
    .a_req(sdr_req), .a_we(sdr_we), .a_addr(sdr_addr),
    .a_din(sdr_din), .a_be(sdr_be),
    .a_dout(sdr_dout), .a_ack(sdr_ack), .a_busy(m_sdr_busy),
    .b_clk(clk), .b_rst_n(rst_n_sys),
    .b_req(m_sdr_req), .b_we(m_sdr_we), .b_addr(m_sdr_addr),
    .b_din(m_sdr_din), .b_be(m_sdr_be),
    .b_dout(p_dout[0][15:0]), .b_ack(p_ack[0])
);

wire        cke, cs_n, ras_n, cas_n, we_n;
wire [1:0]  ba, dqm;
wire [12:0] a;
wire [15:0] dq_c2m, dq_m2c;
wire        dq_oe_c, dq_oe_m;
wire [4:0]  dbg_req_v, dbg_grant_v;
wire [15:0] v_flags;

m1_sdram #(.NP(5), .INIT_NOP(600)) sdram (
    .clk(clk), .rst_n(rst_n_sys), .ready(mem_ready),
    // CL+3: sdram_model answers on the same clock edge the controller uses.
    // The board wants CL+2 because its device is clocked on the inverse of
    // clk_sys and replies half a period away. Leaving this unconnected
    // defaults it to CL+2 and every burst arrives shifted by one word — the
    // V60 then halts after one instruction, which is exactly what this
    // testbench reported until the port was wired.
    .rd_lat_sel(2'd0),
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

// Instruction fetch now goes through the real module rather than a copy of it
// living here. That copy WAS the implementation for a while — every consumer
// wrote its own and none was tested — and replacing it is half the point of
// this configuration: boot is what proves m1_fetch_bridge works in a design,
// across two clocks, where a lost line shows up as a CPU that stops.
integer if_lines = 0;

m1_fetch_bridge fetch (
    .cpu_clk(clk_cpu), .cpu_rst_n(rst_n_cpu),
    .if_req(if_req), .if_off(if_addr[2:0]), .if_sdram_addr(if_sdram_addr),
    .if_data(if_data), .if_ack(if_ack),
    .mem_clk(clk), .mem_rst_n(rst_n_sys),
    .p_req(ifp_req), .p_addr(ifp_addr),
    .p_dout(p_dout[2]), .p_ack(p_ack[2])
);

// Count served lines the same way the old inline bridge did, so the figure
// stays comparable across this change.
reg p2_ack_d = 0, ifp_busy = 0;
always @(posedge clk) begin
    if (!rst_n_sys) begin p2_ack_d <= 0; ifp_busy <= 0; end
    else begin
        p2_ack_d <= p_ack[2];
        if (ifp_req) ifp_busy <= 1'b1;
        else if (ifp_busy && p_ack[2] && !p2_ack_d) begin
            ifp_busy <= 1'b0;
            if_lines  = if_lines + 1;
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
integer nrdlog = 0;
reg        pend_rd = 0;
reg [23:0] pend_addr = 0;
reg  [1:0] pend_be = 0;
reg  [1:0] rdlog_be [0:39];
integer    rdlog_cyc [0:39];
reg [23:0] rdlog_addr [0:39];
reg  [7:0] rdlog_data [0:39];
reg [23:0] rdlog_pc   [0:39];
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

        // WHAT CAME BACK, AND WHO ASKED.
        //
        // Counting reads says the V60 polls the flag 74 times and the window
        // three; it does not say what value came back, which is the actual
        // question — a program polling a byte that never changes is waiting to
        // be told something.
        //
        // The address is only valid at the REQUEST edge and the data only at
        // the ACKNOWLEDGE, which is the whole point of v60_bus.sv's handshake:
        // qualifying both on the same instant logs nothing at all, which is
        // what the first version of this probe did.
        if (pend_rd && main.m_ack) begin
            if (nrdlog < 40) begin
                // THE LANE MATTERS. v60_bus.sv works in 16-bit cycles and m_be
                // says which half carries the byte: an access on the high lane
                // returns m_rdata[15:8], and the byte address is odd. Logging
                // [7:0] with bit 0 forced to zero — which the first version did
                // — reports the wrong address AND the wrong half, and every
                // high-lane read reads as 00.
                rdlog_addr[nrdlog] = {pend_addr[23:1], pend_be[1] & ~pend_be[0]};
                rdlog_data[nrdlog] = pend_be[0] ? main.m_rdata[7:0]
                                                : main.m_rdata[15:8];
                rdlog_be[nrdlog]   = pend_be;
                rdlog_cyc[nrdlog]  = cycles;
                rdlog_pc[nrdlog]   = dbg_pc;
                nrdlog = nrdlog + 1;
            end
            pend_rd <= 1'b0;
        end

        if (main.m_req && !m_req_d) begin
            if (main.m_addr[23:16] == WATCH_PAGE && !main.m_we) begin
                pend_rd   <= 1'b1;
                pend_addr <= {main.m_addr, 1'b0};
                pend_be   <= main.m_be;
            end
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

// ------------------------------------------------------- interrupt probe
// The CPU is spinning on a work-RAM flag. If that flag is set by an interrupt
// service routine, then no interrupt means no flag means this loop forever —
// so the question is whether vblank reaches GLUE, whether GLUE raises the
// line, and whether the CPU ever vectors. Three counters separate those.
integer vbl_to_glue = 0, irq_asserted = 0, irq_edges = 0;
reg irq_n_d = 1;

always @(posedge clk_cpu) begin
    if (rst_n_cpu) begin
        if (main.vblank_irq) vbl_to_glue = vbl_to_glue + 1;
        if (!main.irq_n) irq_asserted = irq_asserted + 1;
        if (!main.irq_n && irq_n_d) irq_edges = irq_edges + 1;
        irq_n_d <= main.irq_n;
    end
end

// --------------------------------------------------------------- PC trace
// Where is it spinning? A page histogram says which region, and the watched
// page says which address, but neither says what the CPU is DOING. A rolling
// buffer of the last distinct PCs prints the loop body itself, which is the
// thing that identifies a wait — and whether it is waiting on memory, on an
// interrupt, or on a device that does not exist.
localparam integer PCBUF = 128;
integer pcbuf [0:PCBUF-1];
integer pcw = 0, pclast = -1;

always @(posedge clk_cpu) begin
    if (rst_n_cpu && dbg_pc != pclast) begin
        pcbuf[pcw % PCBUF] = dbg_pc;
        pcw = pcw + 1;
        pclast = dbg_pc;
    end
end

// ------------------------------------------------------------------- run
integer cycles, ce_cycles, last_pc, stuck, pcmin, pcmax, distinct;
integer instrs;

// Instruction counting belongs in the CPU's own domain now. Sampling dbg_pc on
// the fast clock counts each retire up to four times over and turns the CPI
// figure into fast-clock-cycles per instruction, which is not a number anyone
// wants.
always @(posedge clk_cpu) begin
    if (!rst_n_cpu) begin
        ce_cycles = 0; instrs = 0; last_pc = -1;
        pcmin = 32'h7fffffff; pcmax = 0; stuck = 0;
    end else begin
        if (ce) ce_cycles = ce_cycles + 1;
        if (dbg_pc != last_pc) begin
            instrs  = instrs + 1;
            last_pc = dbg_pc;
            stuck   = 0;
            if (dbg_pc < pcmin) pcmin = dbg_pc;
            if (dbg_pc > pcmax) pcmax = dbg_pc;
        end else stuck = stuck + 1;
    end
end
reg [23:0] seen_hi;
initial begin
    repeat (8) @(posedge clk);
    rst_n = 1;
    while (!mem_ready) @(posedge clk);
    $display("SDRAM ready, releasing V60 at the reset vector");

    cycles = 0; last_pc = -1; stuck = 0; instrs = 0;
    pcmin = 32'h7fffffff; pcmax = 0;
    while (cycles < RUN_CYCLES && !dbg_halted) begin
        @(posedge clk);
        cycles = cycles + 1;
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
        $display("BOOT: %0d instructions over %0d CPU-clock cycles = %0d.%02d avg (INCLUDES block instructions)",
                 instrs, ce_cycles, ce_cycles/instrs,
                 ((ce_cycles % instrs) * 100) / instrs);
    $display("BOOT: io handshake replies=%0d (answered in RTL by m1_ioboard)",
             dbg_io_replies);
    $display("BOOT: sdram violations flags=%04h", v_flags);
    $display("BOOT: bus accesses by 64KB page:");
    for (i = 0; i < 256; i = i + 1)
        if (hist[i] != 0)
            $display("        %02h0000  %0d", i, hist[i]);
    $display("BOOT: first %0d reads in page %02h0000, with data and PC:",
             nrdlog, WATCH_PAGE);
    for (i = 0; i < nrdlog; i = i + 1)
        $display("        cyc %9d  %06h -> %02h  be=%02b  pc=%06h",
                 rdlog_cyc[i], rdlog_addr[i], rdlog_data[i],
                 rdlog_be[i], rdlog_pc[i]);

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
    $display("BOOT: vblank pulses into GLUE=%0d, irq_n asserted cycles=%0d, irq_n falling edges=%0d",
             vbl_to_glue, irq_asserted, irq_edges);
    $display("BOOT: glue irq_status=%02h irq_mask=%02h",
             main.glue.irq_status, main.glue.irq_mask);
    $display("BOOT: last %0d distinct PCs, oldest first:", PCBUF);
    for (i = 0; i < PCBUF; i = i + 1)
        $write("%06h ", pcbuf[(pcw + i) % PCBUF]);
    $display("");

    if (dbg_fp_trap)
        $display("BOOT: *** FP opcode executed — S32_V60_NO_FP is NOT safe ***");
    $finish;
end

endmodule
