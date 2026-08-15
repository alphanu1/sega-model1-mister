//============================================================================
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// V60 cycles-per-instruction against memory latency and clock-enable cadence.
//
// WHY THE EXISTING NUMBERS DO NOT ANSWER THIS
//
// s32's tb_v60_fetch reports cycles=3128 for this same program, and
// BASELINE.md's pre-prefetch capture reported 3129. Read side by side those
// suggest the prefetch redesign achieved nothing. It cannot have: that test
// runs ce=1 with FAST_IFETCH=0, where the data adapter already acks in one
// cycle. There is no fetch latency to hide, so a prefetch has nothing to do.
//
// tb_v60_fetch_wide does exercise FAST_IFETCH=1, but serves the 8-byte line
// with zero latency, which is the opposite error — it assumes away the thing
// the prefetch exists to survive.
//
// Neither is the production configuration. On the real board the core runs on
// a gated clock enable and fetches from SDRAM, and m1_sdram measured a
// worst-case latency of 86 cycles under concurrent load from five masters.
// Whether the V60 keeps up depends entirely on how CPI behaves as that latency
// grows, which is what this sweeps.
//
// Parameters are elaboration-time, so the sweep is done by building this
// several times with -G rather than by plusargs.
//
//   FAST   FAST_IFETCH: 0 = fetch through the data adapter, 1 = wide if_* port
//   CEDIV  clock enable cadence; 1 = free running, 3 = production /3
//   LAT    memory acknowledge latency in clk cycles, both ports
//============================================================================
`timescale 1ns/1ps

module tb_v60_cpi #(
    parameter integer FAST  = 0,
    parameter integer CEDIV = 1,
    parameter integer LAT   = 0
);

localparam integer ITERATIONS = 256;
// MOVW #n,R0 once, then MOVW #imm,R1 and DBR per iteration, then HALT.
localparam integer INSTRS = 2 * ITERATIONS + 2;

reg clk = 0, rst = 1;
always #10 clk = ~clk;

// ---------------------------------------------------------------- clock enable
reg [7:0] cediv_cnt = 0;
reg       ce = 1'b1;
always @(posedge clk) begin
    if (CEDIV <= 1) ce <= 1'b1;
    else begin
        if (cediv_cnt == CEDIV[7:0] - 8'd1) begin cediv_cnt <= 0; ce <= 1'b1; end
        else begin cediv_cnt <= cediv_cnt + 8'd1; ce <= 1'b0; end
    end
end

wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0]  c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire [1:0]  m_be;

wire        if_req;
wire [23:0] if_addr;
reg  [63:0] if_data;
reg         if_served = 1'b0;
wire        if_ack = if_served;

s32_v60 #(.START_PC(32'h0000_0000), .FAST_IFETCH(FAST[0])) cpu (
    .clk(clk), .ce(ce), .rst(rst),
    .if_req(if_req), .if_addr(if_addr), .if_data(if_data), .if_ack(if_ack),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(1'b1), .irq_vector(8'h00), .irq_ack(), .nmi_n(1'b1),
    .dbg_pc(), .dbg_halted()
);

s32_v60_bus adapter (
    .clk(clk), .ce(ce), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

reg [15:0] ram [0:32767];

// ------------------------------------------------------------ data memory
// LAT cycles of latency before the acknowledge, so the sweep can ask what
// happens as memory gets slower rather than assuming it is free.
reg [15:0] lat_cnt = 0;
reg        ack_r = 0;
assign m_rdata = ram[m_addr[15:1]];
assign m_ack   = ack_r;

integer read_txns = 0;
always @(posedge clk) begin
    if (rst) begin ack_r <= 0; lat_cnt <= 0; end
    else if (ack_r) begin
        ack_r <= 1'b0; lat_cnt <= 0;
    end else if (m_req) begin
        if (lat_cnt >= LAT[15:0]) begin
            ack_r <= 1'b1;
            if (!m_we) read_txns = read_txns + 1;
        end else lat_cnt <= lat_cnt + 16'd1;
    end else lat_cnt <= 0;
end

// ------------------------------------------------- wide instruction fetch
// Serves the 8-byte line containing if_addr, pre-aligned so byte 0 is the
// frontier byte — the same contract s32_core provides. The ack is held until
// if_req drops, which is what makes it safe under a gated clock enable.
reg [15:0] if_lat = 0;
integer if_txns = 0;
always @(posedge clk) begin : ifsrv
    reg [127:0] line;
    integer     b;
    if (rst) begin if_served <= 1'b0; if_lat <= 0; end
    else if (!if_req) begin if_served <= 1'b0; if_lat <= 0; end
    else if (!if_served) begin
        if (if_lat >= LAT[15:0]) begin
            for (b = 0; b < 8; b = b + 1)
                line[b*16 +: 16] = ram[((if_addr[23:1] & ~23'd3) + b[22:0])];
            if_data   <= line >> {if_addr[2:0], 3'b000};
            if_served <= 1'b1;
            if_txns   = if_txns + 1;
        end else if_lat <= if_lat + 16'd1;
    end
end

integer i;
initial begin : init_program
    reg [7:0] p [0:31];
    integer k;
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    for (i = 0; i < 32; i = i + 1) p[i] = 8'h00;
    k = 0;
    // MOVW #ITERATIONS, R0
    p[k]=8'h2D; k=k+1; p[k]=8'h20; k=k+1; p[k]=8'hF4; k=k+1;
    p[k]=ITERATIONS[7:0]; k=k+1; p[k]=ITERATIONS[15:8]; k=k+1;
    p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    // loop: MOVW #$12345678,R1 ; DBR R0,loop ; HALT
    p[k]=8'h2D; k=k+1; p[k]=8'h21; k=k+1; p[k]=8'hF4; k=k+1;
    p[k]=8'h78; k=k+1; p[k]=8'h56; k=k+1;
    p[k]=8'h34; k=k+1; p[k]=8'h12; k=k+1;
    p[k]=8'hC6; k=k+1; p[k]=8'hA0; k=k+1;
    p[k]=8'hF9; k=k+1; p[k]=8'hFF; k=k+1;
    p[k]=8'h00;
    for (i = 0; i < 16; i = i + 1) ram[i] = {p[2*i+1], p[2*i]};
end

integer cycles = 0;
integer ce_cycles = 0;
initial begin
    repeat (8) @(posedge clk);
    rst = 0;
    while (!cpu.dbg_halted && cycles < 4000000) begin
        @(posedge clk);
        cycles = cycles + 1;
        if (ce) ce_cycles = ce_cycles + 1;
    end

    if (!cpu.dbg_halted) begin
        $display("V60 CPI FAIL: never halted");
    end else if (cpu.r[0] != 0 || cpu.r[1] != 32'h1234_5678) begin
        $display("V60 CPI FAIL: wrong result r0=%08x r1=%08x", cpu.r[0], cpu.r[1]);
    end else begin
        // clk cycles per instruction is the honest figure: it is what costs
        // wall-clock time. ce cycles per instruction is the CPU's own view and
        // is what BASELINE.md's 22.7 is measured in.
        $display("V60 CPI: fast=%0d cediv=%0d lat=%0d instrs=%0d clk=%0d ce=%0d clk_cpi=%0d.%02d ce_cpi=%0d.%02d dreads=%0d ifetch=%0d",
                 FAST, CEDIV, LAT, INSTRS, cycles, ce_cycles,
                 cycles / INSTRS, ((cycles * 100) / INSTRS) % 100,
                 ce_cycles / INSTRS, ((ce_cycles * 100) / INSTRS) % 100,
                 read_txns, if_txns);
        $display("V60 CPI PASS");
    end
    $finish;
end

endmodule
