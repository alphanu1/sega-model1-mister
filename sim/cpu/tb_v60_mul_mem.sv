//============================================================================
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// V60: Virtua Fighter's ring-size computation, byte for byte (FCCA33-FCCA64).
// The rest of this header is tb_v60_in_mem's, whose harness this reuses.
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

module tb_v60_mul_mem #(
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

// A WRITE PATH, which tb_v60_cpi does not have because its program never
// stores. Byte-enabled, committed on the acknowledge, so a store that the CPU
// issues actually lands where the check looks for it.
always @(posedge clk) begin
    if (m_req && m_we && ack_r) begin
        if (m_be[0]) ram[m_addr[15:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[15:1]][15:8] <= m_wdata[15:8];
    end
end

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

localparam integer NOPS  = 6;      // MUL MULU DIV DIVU REM REMU
localparam integer NCASE = 60;     // per op and width: 1,080 cases
reg [31:0] ca [0:NOPS*3*NCASE-1];
reg [31:0] cb [0:NOPS*3*NCASE-1];
function [7:0] opc(input integer o, input integer d);
    case (o)
        0: opc = (d == 0) ? 8'h81 : (d == 1) ? 8'h83 : 8'h85;   // MUL
        1: opc = (d == 0) ? 8'h91 : (d == 1) ? 8'h93 : 8'h95;   // MULU
        2: opc = (d == 0) ? 8'ha1 : (d == 1) ? 8'ha3 : 8'ha5;   // DIV
        3: opc = (d == 0) ? 8'hb1 : (d == 1) ? 8'hb3 : 8'hb5;   // DIVU
        4: opc = (d == 0) ? 8'h50 : (d == 1) ? 8'h52 : 8'h54;   // REM
        default: opc = (d == 0) ? 8'h51 : (d == 1) ? 8'h53 : 8'h55;   // REMU
    endcase
endfunction
function [31:0] trunc(input [31:0] v, input integer d);
    trunc = (d == 0) ? {24'd0, v[7:0]} : (d == 1) ? {16'd0, v[15:0]} : v;
endfunction
function integer sext(input [31:0] v, input integer d);
    sext = (d == 0) ? $signed({{24{v[7]}}, v[7:0]}) : (d == 1) ? $signed({{16{v[15]}}, v[15:0]}) : $signed(v);
endfunction
function integer smin(input integer d);
    smin = (d == 0) ? -128 : (d == 1) ? -32768 : 32'h80000000;
endfunction
reg [31:0] lcg = 32'h1234_5678;
function [31:0] operand(input integer c, input integer which);
    // edge values first, an order of magnitude past the 70 x 10 that was wrong
    reg [31:0] edges [0:11];
    edges[0] = 0; edges[1] = 1; edges[2] = 32'hffffffff; edges[3] = 10;
    edges[4] = 70; edges[5] = 32'h7fffffff; edges[6] = 32'h80000000; edges[7] = 32'h7f;
    edges[8] = 32'h80; edges[9] = 32'h7fff; edges[10] = 32'h8000; edges[11] = 700;
    if (c < 12) operand = which ? edges[(c * 5 + 3) % 12] : edges[c];
    else begin lcg = lcg * 32'd1664525 + 32'd1013904223; operand = lcg ^ {lcg[15:0], lcg[31:16]}; end
endfunction
function [31:0] expect_of(input integer o, input integer d, input [31:0] a, input [31:0] b);
    // dest = dest OP src, at width d; MAME's C semantics (truncating divide,
    // remainder takes the dividend's sign)
    integer sa, sb; reg [31:0] ua, ub, r;
    sa = sext(a, d); sb = sext(b, d); ua = trunc(a, d); ub = trunc(b, d);
    case (o)
        0: r = sa * sb;
        1: r = ua * ub;
        2: r = sa / sb;
        3: r = ua / ub;
        4: r = sa % sb;
        default: r = ua % ub;
    endcase
    expect_of = trunc(r, d);
endfunction

integer i;
initial begin : init_program
    // THE GAME'S OWN SEQUENCE, from MAME's disassembler at FCCA33, with the
    // absolute addresses moved into this bench's 64 KB:
    //
    //   FCCA33  movz.bw FCC9F6(R0), 501276    table of 75,70,65,60 by setting
    //   FCCA40  mulu.w  #A, 501276            x10
    //   FCCA48  cvt.ws  501276, 501276        to float
    //   FCCA64  mov.w   501276, [R24]         pushed to the coprocessor
    //
    // MAME pushes 442f0000 (700.0) as the second argument of TGP command
    // 01000000; our core pushed 428c0000 (70.0). 0x501276 is two bytes off a
    // word boundary, so the multiply is a misaligned 32-bit read-modify-write.
    reg [7:0] p [0:32767];
    integer k;
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    for (i = 0; i < 32768; i = i + 1) p[i] = 8'h00;
    k = 0;
    // MOVW #1, R0
    p[k]=8'h2D; k=k+1; p[k]=8'h20; k=k+1; p[k]=8'hF4; k=k+1;
    p[k]=8'h01; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    // movz.bw 7000(R0), 7276
    p[k]=8'h0D; k=k+1; p[k]=8'hC0; k=k+1; p[k]=8'hC0; k=k+1; p[k]=8'hF3; k=k+1;
    p[k]=8'h00; k=k+1; p[k]=8'h70; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    p[k]=8'hF3; k=k+1; p[k]=8'h76; k=k+1; p[k]=8'h72; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    // mov.w 1276, 1300     (the byte as loaded)
    p[k]=8'h2D; k=k+1; p[k]=8'h80; k=k+1;
    p[k]=8'hF3; k=k+1; p[k]=8'h76; k=k+1; p[k]=8'h72; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    p[k]=8'hF3; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h73; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    // mulu.w #A, 1276
    p[k]=8'h95; k=k+1; p[k]=8'h80; k=k+1; p[k]=8'hEA; k=k+1;
    p[k]=8'hF3; k=k+1; p[k]=8'h76; k=k+1; p[k]=8'h72; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    // mov.w 1276, 1304     (after the multiply)
    p[k]=8'h2D; k=k+1; p[k]=8'h80; k=k+1;
    p[k]=8'hF3; k=k+1; p[k]=8'h76; k=k+1; p[k]=8'h72; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    p[k]=8'hF3; k=k+1; p[k]=8'h04; k=k+1; p[k]=8'h73; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    // cvt.ws 1276, 1276
    p[k]=8'h5F; k=k+1; p[k]=8'h80; k=k+1;
    p[k]=8'hF3; k=k+1; p[k]=8'h76; k=k+1; p[k]=8'h72; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    p[k]=8'hF3; k=k+1; p[k]=8'h76; k=k+1; p[k]=8'h72; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    // the same multiply on a 4-aligned word: mov.w #70, 1280 ; mulu.w #A, 1280
    p[k]=8'h2D; k=k+1; p[k]=8'h80; k=k+1; p[k]=8'hF4; k=k+1;
    p[k]=8'h46; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    p[k]=8'hF3; k=k+1; p[k]=8'h80; k=k+1; p[k]=8'h72; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    p[k]=8'h95; k=k+1; p[k]=8'h80; k=k+1; p[k]=8'hEA; k=k+1;
    p[k]=8'hF3; k=k+1; p[k]=8'h80; k=k+1; p[k]=8'h72; k=k+1; p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;
    // THE SWEEP: every multiply/divide/remainder opcode at every width, with
    // a MEMORY destination, NCASE operand pairs each - edge values first, then
    // an LCG. `mov.d #A, abs ; op.d #B, abs`, each case at its own address,
    // checked after HALT against the C semantics MAME implements.
    for (i = 0; i < NOPS*3*NCASE; i = i + 1) begin : gen
        integer o, dsz, c, nb, b;
        reg [31:0] av, bv, ad;
        o = i / (3*NCASE); dsz = (i / NCASE) % 3; c = i % NCASE;
        nb = (dsz == 0) ? 1 : (dsz == 1) ? 2 : 4;
        av = operand(c, 0); bv = operand(c, 1);
        av = trunc(av, dsz); bv = trunc(bv, dsz);
        // keep away from the cases MAME does not write: x/0 and min/-1
        if (o >= 2) begin
            if (bv == 0) bv = 32'd3;
            if (sext(av, dsz) == smin(dsz) && sext(bv, dsz) == -1) bv = 32'd7;
        end
        ca[i] = av; cb[i] = bv;
        ad = 32'h8000 + i * 4;
        // mov.d #av, ad
        p[k] = (dsz == 0) ? 8'h09 : (dsz == 1) ? 8'h1B : 8'h2D; k=k+1;
        p[k] = 8'h80; k=k+1; p[k] = 8'hF4; k=k+1;
        for (b = 0; b < nb; b = b + 1) begin p[k] = av[8*b +: 8]; k=k+1; end
        p[k] = 8'hF3; k=k+1;
        for (b = 0; b < 4; b = b + 1) begin p[k] = ad[8*b +: 8]; k=k+1; end
        // op.d #bv, ad
        p[k] = opc(o, dsz); k=k+1;
        p[k] = 8'h80; k=k+1; p[k] = 8'hF4; k=k+1;
        for (b = 0; b < nb; b = b + 1) begin p[k] = bv[8*b +: 8]; k=k+1; end
        p[k] = 8'hF3; k=k+1;
        for (b = 0; b < 4; b = b + 1) begin p[k] = ad[8*b +: 8]; k=k+1; end
    end
    // HALT
    p[k]=8'h00; k=k+1;
    if (k >= 32768 - 64) $display("V60 MUL_MEM FAIL: program overruns the bench RAM (%0d bytes)", k);
    for (i = 0; i < 16384; i = i + 1) ram[i] = {p[2*i+1], p[2*i]};
    // the table at 0x7000: 4B 46 41 3C
    ram[16'h3800] = 16'h464B; ram[16'h3801] = 16'h3C41;
end

integer cycles = 0;
integer ce_cycles = 0;
integer fails = 0;
function [31:0] w32(input integer byteaddr);   // byte address, 32-bit LE
    w32 = {ram[(byteaddr >> 1) + 1], ram[byteaddr >> 1]};
endfunction
initial begin
    repeat (8) @(posedge clk);
    rst = 0;
    while (!cpu.dbg_halted && cycles < 4000000) begin
        @(posedge clk);
        cycles = cycles + 1;
        if (ce) ce_cycles = ce_cycles + 1;
    end
    if (!cpu.dbg_halted) begin $display("V60 MUL_MEM FAIL: never halted"); fails = fails + 1; end
    if (w32(16'h7300) != 32'd70)  begin $display("V60 MUL_MEM FAIL: movz.bw loaded %08x (want 00000046)", w32(16'h7300)); fails = fails + 1; end
    if (w32(16'h7304) != 32'd700) begin $display("V60 MUL_MEM FAIL: mulu.w #A on the misaligned word gave %08x (want 000002bc)", w32(16'h7304)); fails = fails + 1; end
    if (w32(16'h7276) != 32'h442f0000) begin $display("V60 MUL_MEM FAIL: cvt.ws gave %08x (want 442f0000 = 700.0)", w32(16'h7276)); fails = fails + 1; end
    if (w32(16'h7280) != 32'd700) begin $display("V60 MUL_MEM FAIL: mulu.w #A on the aligned word gave %08x (want 000002bc)", w32(16'h7280)); fails = fails + 1; end
    begin : sweep
        integer o, d, n, shown;
        reg [31:0 ] got, want, mask;
        shown = 0;
        for (n = 0; n < NOPS*3*NCASE; n = n + 1) begin
            o = n / (3*NCASE); d = (n / NCASE) % 3;
            mask = (d == 0) ? 32'hff : (d == 1) ? 32'hffff : 32'hffffffff;
            got  = w32(32'h8000 + n * 4) & mask;
            want = expect_of(o, d, ca[n], cb[n]);
            if (got !== want) begin
                fails = fails + 1;
                if (shown < 12) begin
                    $display("V60 MUL_MEM FAIL: op %02x a=%08x b=%08x -> mem %08x, want %08x",
                             opc(o, d), ca[n], cb[n], got, want);
                    shown = shown + 1;
                end
            end
        end
    end
    $display("v60_mul_mem: checks=%0d fails=%0d  [7300]=%08x [7304]=%08x [7276]=%08x [7280]=%08x",
             4 + NOPS*3*NCASE, fails, w32(16'h7300), w32(16'h7304), w32(16'h7276), w32(16'h7280));
    $finish;
end

endmodule
