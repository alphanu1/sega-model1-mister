//============================================================================
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The V60 executing out of SDRAM, through everything in between.
//
// This is the first test where the CPU, the ROM loader, the SDRAM controller,
// the protocol-checking device model and the 315-5465 decode all run together.
// Each has passed on its own; what has never been exercised is the path a real
// instruction fetch takes: loader writes a ROM image into SDRAM, the CPU asks
// for an address, the decode maps it into the packed ROM layout, the SDRAM
// controller serves it, and the V60 executes what comes back.
//
// The program is the fetch-loop from s32's tb_v60_fetch — MOVW an iteration
// count, then a loop of MOVW and DBR, then HALT — chosen because its finishing
// state is unambiguous: r0 must be zero and r1 must hold 0x12345678. A wrong
// byte anywhere in that path gives a different answer or no halt at all.
//
// It runs at the architectural reset vector's region but from 0xFC0000, where
// real boot ROMs live, rather than 0xFFFFFFF0: starting at the vector itself
// would need a branch encoded in the sixteen bytes above it, and this is
// testing the memory path rather than the reset sequence.
//============================================================================
`timescale 1ns/1ps

// INJFP=1 replaces the first instruction with a floating-point opcode, so the
// run is expected to trap rather than complete. Without it, fp_trap reading
// zero says nothing — the program has no FP in it, so a detector wired to
// nothing would look identical to a detector that works.
module tb_m1_main #(parameter integer FASTIF = 1, parameter integer INJFP = 0);

localparam integer ITERATIONS = 64;
localparam [31:0]  PROG_PC    = 32'h00FC0000;

// Stream offset of PROG_PC. m1_decode maps ROM0 (0xf80000-0xffffff) to packed
// word 0x080000 + (addr & 0x7ffff) >> 1, and the loader stream is byte
// addressed at twice the word address.
localparam integer PROG_STREAM = (32'h080000 + ((32'h00FC0000 & 32'h7FFFF) >> 1)) * 2;

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

// V60 clock enable: /3, the production cadence.
reg [1:0] cediv = 0;
wire ce = (cediv == 0);
always @(posedge clk) cediv <= (cediv == 2) ? 2'd0 : cediv + 2'd1;

// ---------------------------------------------------------------- loader
reg         ioctl_download = 0, ioctl_wr = 0;
reg  [26:0] ioctl_addr = 0;
reg  [15:0] ioctl_dout = 0;
wire        ioctl_wait, rom_loaded, ldr_overflow;

wire        ldr_req, ldr_ack;
wire [24:1] ldr_addr;
wire [15:0] ldr_din;
wire  [1:0] ldr_be;

m1_rom_loader loader (
    .clk(clk), .rst(~rst_n), .mem_ready(mem_ready),
    .ioctl_download(ioctl_download), .ioctl_index(16'd0),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .sdr_wr_req(ldr_req), .sdr_wr_addr(ldr_addr), .sdr_wr_din(ldr_din),
    .sdr_wr_be(ldr_be), .sdr_wr_ack(ldr_ack),
    .tgp_wr(), .tgp_addr(), .tgp_din(),
    .rom_loaded(rom_loaded), .overflow(ldr_overflow)
);

// ------------------------------------------------------------ main board
wire        sdr_req, sdr_we;
wire [24:1] sdr_addr;
wire [15:0] sdr_din;
wire  [1:0] sdr_be;
wire [15:0] sdr_dout;
wire        sdr_ack;

wire        if_req;
wire [23:0] if_addr;
wire [24:1] if_sdram_addr;
wire [63:0] if_data;
wire        if_ack;

wire [23:0] dbg_pc;
wire        dbg_halted;
wire        dbg_fp_trap;
wire [15:0] dbg_io_replies;

m1_main #(.START_PC(PROG_PC), .FAST_IFETCH(FASTIF[0])) main (
    .clk(clk), .ce(ce), .rst_n(rst_n), .rom_loaded(rom_loaded),
    .sdr_req(sdr_req), .sdr_we(sdr_we), .sdr_addr(sdr_addr),
    .sdr_din(sdr_din), .sdr_be(sdr_be), .sdr_dout(sdr_dout), .sdr_ack(sdr_ack),
    .if_req(if_req), .if_addr(if_addr), .if_sdram_addr(if_sdram_addr),
    .if_data(if_data), .if_ack(if_ack),
    .vid_tram_addr(15'd0), .vid_tram_data(),
    .vid_pal_addr(12'd0),  .vid_pal_data(),
    .vblank_irq(1'b0),
    .dbg_pc(dbg_pc), .dbg_halted(dbg_halted), .dbg_fp_trap(dbg_fp_trap), .dbg_io_replies(dbg_io_replies),
    .rom_bank()
);

// ---------------------------------------------------------------- SDRAM
// p0 is the CPU's data port; p2 serves the wide instruction fetch as a 4-word
// burst, which is exactly the 8-byte line FAST_IFETCH asks for.
wire [4:0]        p_req, p_we, p_ack;
wire [4:0][24:1]  p_addr;
wire [4:0][15:0]  p_din;
wire [4:0][1:0]   p_be;
wire [4:0][63:0]  p_dout;

reg  ifp_req = 0;
reg [24:1] ifp_addr = 0;

assign p_req  = {2'b00, ifp_req, 1'b0, sdr_req};
assign p_we   = {4'b0000, sdr_we};
assign p_addr = {24'd0, 24'd0, ifp_addr, 24'd0, sdr_addr};
assign p_din  = {16'd0, 16'd0, 16'd0, 16'd0, sdr_din};
assign p_be   = {2'd0, 2'd0, 2'd0, 2'd0, sdr_be};
assign sdr_dout = p_dout[0][15:0];
assign sdr_ack  = p_ack[0];

wire mem_ready;
wire        cke, cs_n, ras_n, cas_n, we_n;
wire [1:0]  ba, dqm;
wire [12:0] a;
wire [15:0] dq_c2m, dq_m2c;
wire        dq_oe_c, dq_oe_m;
wire [4:0]  dbg_req_v, dbg_grant_v;
wire int_unused;

m1_sdram #(.NP(5), .INIT_NOP(600)) sdram (
    .clk(clk), .rst_n(rst_n), .ready(mem_ready),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n),
    .sd_we_n(we_n), .sd_ba(ba), .sd_a(a), .sd_dqm(dqm),
    .sd_dq_o(dq_c2m), .sd_dq_oe(dq_oe_c), .sd_dq_i(dq_m2c),
    .wr_req(ldr_req), .wr_addr(ldr_addr), .wr_din(ldr_din), .wr_be(ldr_be),
    .wr_ack(ldr_ack),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack),
    .dbg_req(dbg_req_v), .dbg_grant(dbg_grant_v)
);

integer violations_i;
wire [15:0] v_flags;
sdram_model #(.COL_BITS(9)) device (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .ba(ba), .a(a), .dqm(dqm),
    .dq_i(dq_c2m), .dq_oe_i(dq_oe_c), .dq_o(dq_m2c), .dq_oe_o(dq_oe_m),
    .violations(), .v_flags(v_flags), .reads_served(), .writes_served()
);

// Instruction fetch: turn the V60's 8-byte line request into a p2 burst.
// if_ack is held until if_req drops, which is the handshake the core expects
// under a gated clock enable.
reg if_served = 0;
reg [63:0] if_data_r = 0;
assign if_ack  = if_served;
assign if_data = if_data_r;

// Matches s32's own model in verif/v60/tb_v60_fetch_wide.sv: serve the ALIGNED
// 8-byte line containing if_addr, shifted so byte 0 is the byte at if_addr.
// The top `foff` bytes are then don't-care — the core knows only 8-foff bytes
// are valid, exactly as its own icache hit path produces.
//
// The frontier offset is latched with the request because the core moves the
// address on while the burst is in flight.
// The acknowledge must be taken on its RISING edge while a request of ours is
// outstanding. m1_sdram stretches ack to two cycles so a slower requester
// cannot miss it; a bridge that samples the level instead sees the PREVIOUS
// transaction's ack still asserted when it issues the next request, and
// latches that transaction's data as the answer. The trace showed two
// different fetch addresses returning byte-identical lines.
reg [2:0] if_foff = 0;
reg       if_pending = 0;
reg       p2_ack_d = 0;

always @(posedge clk) begin
    if (!rst_n) begin ifp_req <= 0; if_served <= 0; if_pending <= 0; p2_ack_d <= 0; end
    else begin
        ifp_req  <= 0;
        p2_ack_d <= p_ack[2];
        if (!if_req) begin
            if_served  <= 0;
            if_pending <= 0;
        end else if (!if_served && !if_pending) begin
            ifp_addr   <= if_sdram_addr;
            if_foff    <= if_addr[2:0];
            ifp_req    <= 1'b1;
            if_pending <= 1'b1;
        end else if (if_pending && p_ack[2] && !p2_ack_d) begin
            if_pending <= 1'b0;
            if_data_r <= p_dout[2] >> {if_foff, 3'b000};
            if_served <= 1'b1;
            if (trace)
              $display("  IF addr=%06h sdram=%06h foff=%0d raw=%016h -> %016h",
                       if_addr, ifp_addr, if_foff, p_dout[2],
                       p_dout[2] >> {if_foff, 3'b000});
        end
    end
end

reg trace = 0;

// ---------------------------------------------------------- the program
reg [7:0] prog [0:31];
integer i, k;
initial begin : build
    for (i = 0; i < 32; i = i + 1) prog[i] = 8'h00;
    k = 0;
    if (INJFP != 0) begin
        // ADDFS: opcode 0x5c, subop 0x18. A build with the FP group executes
        // it; a build without takes the reserved-instruction vector.
        prog[k]=8'h5C; k=k+1; prog[k]=8'h18; k=k+1;
        prog[k]=8'h00; k=k+1; prog[k]=8'h00; k=k+1;
    end
    // MOVW #ITERATIONS, R0
    prog[k]=8'h2D; k=k+1; prog[k]=8'h20; k=k+1; prog[k]=8'hF4; k=k+1;
    prog[k]=ITERATIONS[7:0]; k=k+1; prog[k]=ITERATIONS[15:8]; k=k+1;
    prog[k]=8'h00; k=k+1; prog[k]=8'h00; k=k+1;
    // loop: MOVW #$12345678,R1 ; DBR R0,loop ; HALT
    prog[k]=8'h2D; k=k+1; prog[k]=8'h21; k=k+1; prog[k]=8'hF4; k=k+1;
    prog[k]=8'h78; k=k+1; prog[k]=8'h56; k=k+1;
    prog[k]=8'h34; k=k+1; prog[k]=8'h12; k=k+1;
    prog[k]=8'hC6; k=k+1; prog[k]=8'hA0; k=k+1;
    prog[k]=8'hF9; k=k+1; prog[k]=8'hFF; k=k+1;
    prog[k]=8'h00;
end

task automatic push(input [26:0] addr, input [15:0] data);
    begin
        @(posedge clk);
        while (ioctl_wait) @(posedge clk);
        ioctl_addr <= addr; ioctl_dout <= data; ioctl_wr <= 1'b1;
        @(posedge clk);
        ioctl_wr <= 1'b0;
    end
endtask

integer cycles;
integer fails;
initial begin
    fails = 0;
    repeat (8) @(posedge clk);
    rst_n = 1;

    // Wait for the controller's JEDEC bring-up before offering any data.
    while (!mem_ready) @(posedge clk);

    $display("loading %0d bytes at stream offset 0x%0h", 32, PROG_STREAM);
    ioctl_download = 1;
    for (i = 0; i < 16; i = i + 1)
        push(PROG_STREAM[26:0] + i[26:0]*2, {prog[2*i+1], prog[2*i]});
    ioctl_download = 0;

    while (!rom_loaded) @(posedge clk);
    $display("rom_loaded, releasing the CPU at PC=%08h", PROG_PC);

    cycles = 0;
    while (!dbg_halted && !(INJFP != 0 && dbg_fp_trap) && cycles < 2000000) begin
        @(posedge clk);
        cycles = cycles + 1;
    end

    if (ldr_overflow) begin
        $display("  FAIL loader overflowed"); fails = fails + 1;
    end
    if (INJFP != 0) begin
        // The only thing being asked here is whether the detector fires.
        if (!dbg_fp_trap) begin
            $display("  FAIL an FP opcode executed without raising dbg_fp_trap");
            fails = fails + 1;
        end
    end else if (!dbg_halted) begin
        $display("  FAIL never halted after %0d cycles (pc=%06h)", cycles, dbg_pc);
        fails = fails + 1;
    end else if (INJFP == 0) begin
        if (main.cpu.r[0] !== 32'd0) begin
            $display("  FAIL r0=%08h expected 0", main.cpu.r[0]); fails = fails + 1;
        end
        if (main.cpu.r[1] !== 32'h1234_5678) begin
            $display("  FAIL r1=%08h expected 12345678", main.cpu.r[1]);
            fails = fails + 1;
        end
    end
    // A build without the FP group must never meet an FP opcode. This is the
    // check that turns "the ROM scan found nothing" into something a run can
    // actually answer.
    if (dbg_fp_trap && INJFP == 0) begin
        $display("  FAIL V60 took the reserved-instruction vector for an FP opcode");
        fails = fails + 1;
    end
    if (v_flags != 0) begin
        $display("  FAIL SDRAM protocol violations, flags=%04h", v_flags);
        fails = fails + 1;
    end

    $display("M1 MAIN: cycles=%0d halted=%0d r0=%08h r1=%08h ifetch_lines=%0d fp_trap=%0d",
             cycles, dbg_halted, main.cpu.r[0], main.cpu.r[1], if_lines, dbg_fp_trap);
    if (fails == 0) $display("M1 MAIN PASS");
    else            $display("M1 MAIN FAIL (%0d)", fails);
    $finish;
end

integer if_lines = 0;
always @(posedge clk) if (p_ack[2] && !if_served) if_lines = if_lines + 1;

endmodule
