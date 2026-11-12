//============================================================================
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// V60 AGAINST NEC'S MANUAL: NOT, MUL/MULU, DIV/DIVU/REM/REMU, DIVX/DIVUX.
//
// The expectations here are the uPD70616 Programmer's Reference Manual (NEC,
// 1986), not MAME. They differ from MAME in exactly the places the 2026-11-12
// change moved the core (docs/findings.md 2026-11-12):
//
//   NOT     p.7-72  CY unchanged, OV cleared.
//   MUL     p.7-64  OV = the signed product does not fit the destination.
//   MULU    p.7-66  OV = the unsigned product does not fit (as before).
//   DIV     p.7-36  min / -1: OV set, destination unchanged.
//   DIVX    p.7-39  quotient outside signed 32 bits: OV set, pair unchanged;
//                   otherwise OV cleared.
//   DIVUX   p.7-40  the same, unsigned.
//   zero    p.8-8   a zero divisor in any divide or remainder sets OV, leaves
//   divide          the destination unmodified and takes exception #21:
//                   frame (p.8-17, code 1500h Table 8-1 p.8-19, count 8)
//                   [SP]=next PC, [SP+4]=PSW, [SP+8]=15000008, [SP+12]=PC.
//
// HOW. Each case is a short program: load the destination (register or
// memory) and the source, set the four flags with UPDPSW, run the one
// instruction, GETPSW, store the destination and the PSW. Cases run in
// batches; the CPU is reset between batches and halts at the end of each.
// SBT entry 21 points at RETIS #8, so a zero divide returns to the next
// instruction with the pushed PSW; every other SBT entry points at a HALT
// at 0x900, so an exception that should not happen is caught. The frame is
// captured from RAM when the CPU reads SBT[21], and checked against the
// instruction's own address and the one after it.
//
// THE SWEEP GOES PAST THE BOUNDARY, NOT JUST TO IT. MUL.B and MULU.B are
// exhaustive (65,536 pairs each). For halfword and word, every boundary
// (smax, smin, umax and one past each) is approached from a set of
// multipliers a with b = L/a + d for d in [-24, +24]: the obvious test is
// d = +-1, and this is an order of magnitude past it. DIVX/DIVUX sweep the
// dividend through q*D + k for quotients either side of 2^31 / 2^32 and
// k in [-40, +40], over a set of divisors, plus random operands.
//
// Harness: tb_v60_mul_mem's (FAST_IFETCH, LAT 4), with 256 KB of RAM.
//============================================================================
`timescale 1ns/1ps

module tb_v60_manual #(
    parameter integer FAST  = 1,
    parameter integer CEDIV = 1,
    parameter integer LAT   = 4
);

reg clk = 0, rst = 1;
always #10 clk = ~clk;

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
wire [31:0] dbg_pc;
wire        dbg_halted;

localparam [31:0] PROG = 32'h0000_1000;

s32_v60 #(.START_PC(PROG), .FAST_IFETCH(FAST[0])) cpu (
    .clk(clk), .ce(ce), .rst(rst),
    .if_req(if_req), .if_addr(if_addr), .if_data(if_data), .if_ack(if_ack),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(1'b1), .irq_vector(8'h00), .irq_ack(), .nmi_n(1'b1),
    .dbg_pc(dbg_pc), .dbg_halted(dbg_halted)
);

s32_v60_bus adapter (
    .clk(clk), .ce(ce), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

localparam integer RAMW = 131072;            // 16-bit words: 256 KB
reg [15:0] ram [0:RAMW-1];

reg [15:0] lat_cnt = 0;
reg        ack_r = 0;
assign m_rdata = ram[m_addr[17:1]];
assign m_ack   = ack_r;
always @(posedge clk) begin
    if (m_req && m_we && ack_r) begin
        if (m_be[0]) ram[m_addr[17:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[17:1]][15:8] <= m_wdata[15:8];
    end
end
always @(posedge clk) begin
    if (rst) begin ack_r <= 0; lat_cnt <= 0; end
    else if (ack_r) begin ack_r <= 1'b0; lat_cnt <= 0; end
    else if (m_req) begin
        if (lat_cnt >= LAT[15:0]) ack_r <= 1'b1;
        else lat_cnt <= lat_cnt + 16'd1;
    end else lat_cnt <= 0;
end
reg [15:0] if_lat = 0;
always @(posedge clk) begin : ifsrv
    reg [127:0] line;
    integer     b;
    if (rst) begin if_served <= 1'b0; if_lat <= 0; end
    else if (!if_req) begin if_served <= 1'b0; if_lat <= 0; end
    else if (!if_served) begin
        if (if_lat >= LAT[15:0]) begin
            for (b = 0; b < 8; b = b + 1)
                line[b*16 +: 16] = ram[(((if_addr[23:1] & ~23'd3) + b[22:0]) & 23'(RAMW-1))];
            if_data   <= line >> {if_addr[2:0], 3'b000};
            if_served <= 1'b1;
        end else if_lat <= if_lat + 16'd1;
    end
end

// ------------------------------------------------------------ memory map
localparam [31:0] SBT_HANDLER = 32'h0000_0800;   // SBT[21]: RETIS #8
localparam [31:0] BAD_HANDLER = 32'h0000_0900;   // every other SBT entry: HALT
localparam [31:0] PROG_END    = 32'h0001_F000;   // program must stay below
localparam [31:0] RES         = 32'h0002_0000;   // 16 bytes per case
localparam [31:0] STACK       = 32'h0002_F000;
localparam [31:0] MEMDST      = 32'h0003_0000;   // 8 bytes per case
localparam integer BATCH_MAX  = 1500;            // RES/MEMDST room: 4096

function [31:0] rd32(input [31:0] a);
    rd32 = {ram[((a >> 1) + 1) & (RAMW-1)], ram[(a >> 1) & (RAMW-1)]};
endfunction

// ------------------------------------------------------------ the cases
localparam integer K_NOT = 0, K_MUL = 1, K_MULU = 2, K_DIV = 3, K_DIVU = 4,
                   K_REM = 5, K_REMU = 6, K_DIVX = 7, K_DIVUX = 8;
localparam integer MAXC = 300000;
reg [3:0]  ck  [0:MAXC-1];     // kind
reg [1:0]  cw  [0:MAXC-1];     // width 0/1/2
reg        cm  [0:MAXC-1];     // 1 = memory destination
reg [31:0] cdl [0:MAXC-1];     // destination (low word)
reg [31:0] cdh [0:MAXC-1];     // DIVX/DIVUX high word
reg [31:0] cs  [0:MAXC-1];     // source
reg [3:0]  cf  [0:MAXC-1];     // flags before {CY,OV,S,Z}
integer ncase = 0;
integer per_kind [0:8];
integer exc_expected_total = 0;

reg [31:0] lcg = 32'h2468_ace1;
function [31:0] rnd();
    lcg = lcg * 32'd1664525 + 32'd1013904223;
    rnd = lcg ^ {lcg[15:0], lcg[31:16]};
endfunction

task add(input integer k, input integer w, input integer m,
         input [31:0] dl, input [31:0] dh, input [31:0] s);
    reg [31:0] r;
    if (ncase >= MAXC) begin $display("tb_v60_manual: MAXC exceeded"); $finish; end
    r = rnd();
    ck[ncase] = k[3:0]; cw[ncase] = w[1:0]; cm[ncase] = m[0];
    cdl[ncase] = dl; cdh[ncase] = dh; cs[ncase] = s; cf[ncase] = r[11:8];
    per_kind[k] = per_kind[k] + 1;
    ncase = ncase + 1;
endtask

function [31:0] wmask(input integer w);
    wmask = (w == 0) ? 32'hff : (w == 1) ? 32'hffff : 32'hffff_ffff;
endfunction
function longint sx(input [31:0] v, input integer w);
    sx = (w == 0) ? longint'($signed(v[7:0])) : (w == 1) ? longint'($signed(v[15:0])) : longint'($signed(v));
endfunction
function longint ux(input [31:0] v, input integer w);
    ux = longint'({32'd0, v & wmask(w)});
endfunction
function msbw(input [31:0] v, input integer w);
    msbw = (w == 0) ? v[7] : (w == 1) ? v[15] : v[31];
endfunction

// THE MANUAL'S SEMANTICS. dst OP= src; flags {CY,OV,S,Z}; exc = zero divide.
task automatic ref_model(input integer k, input integer w, input [31:0] dl, input [31:0] dh,
                         input [31:0] s, input [3:0] fpre,
                         output reg exc, output reg [31:0] rl, output reg [31:0] rh,
                         output reg [3:0] f);
    longint smax, smin, p, a, b, q, r;
    reg [63:0] up, un, uq, ur;
    reg [31:0] mk, res;
    reg cy, ov;
    mk = wmask(w);
    smax = (w == 0) ? 64'sd127 : (w == 1) ? 64'sd32767 : 64'sd2147483647;
    smin = -smax - 1;
    cy = fpre[3];
    exc = 1'b0; rl = dl; rh = dh; ov = 1'b0; res = dl & mk;
    case (k)
    K_NOT: begin res = ~s & mk; ov = 1'b0; end
    K_MUL: begin
        p = sx(dl, w) * sx(s, w);
        res = p[31:0] & mk;
        ov = (p > smax) || (p < smin);
    end
    K_MULU: begin
        up = 64'(ux(dl, w)) * 64'(ux(s, w));
        res = up[31:0] & mk;
        ov = (up > {32'd0, mk});
    end
    K_DIV, K_DIVU, K_REM, K_REMU: begin
        if ((s & mk) == 0) begin exc = 1'b1; ov = 1'b1; res = dl & mk; end
        else if (k == K_DIV && sx(dl, w) == smin && sx(s, w) == -1) begin
            ov = 1'b1; res = dl & mk;              // p.7-36: unchanged
        end
        else begin
            a = (k == K_DIV || k == K_REM) ? sx(dl, w) : ux(dl, w);
            b = (k == K_DIV || k == K_REM) ? sx(s, w)  : ux(s, w);
            q = (k == K_DIV || k == K_DIVU) ? (a / b) : (a % b);
            res = q[31:0] & mk;
            ov = 1'b0;
        end
    end
    K_DIVX, K_DIVUX: begin
        if (s == 0) begin exc = 1'b1; ov = 1'b1; end
        else if (k == K_DIVX) begin
            a = {dh, dl}; b = longint'($signed(s));
            if (a == 64'sh8000_0000_0000_0000 && b == -1) ov = 1'b1;
            else begin
                q = a / b; r = a % b;
                ov = (q > 64'sd2147483647) || (q < -64'sd2147483648);
                if (!ov) begin rl = q[31:0]; rh = r[31:0]; end
            end
        end
        else begin
            un = {dh, dl};
            uq = un / {32'd0, s}; ur = un % {32'd0, s};
            ov = (uq[63:32] != 0);
            if (!ov) begin rl = uq[31:0]; rh = ur[31:0]; end
        end
        // S/Z: the quotient, or the unchanged low word on overflow / zero
        res = rl;
    end
    default: ;
    endcase
    if (k != K_DIVX && k != K_DIVUX) rl = (dl & ~mk) | res;
    f = {cy, ov, msbw(res, w), (res & mk) == 0};
endtask

// ------------------------------------------------------------ assembler
integer pa;
task ab(input [7:0] b);
    if (pa[0]) ram[(pa >> 1) & (RAMW-1)][15:8] = b;
    else       ram[(pa >> 1) & (RAMW-1)][7:0]  = b;
    pa = pa + 1;
endtask
task aw(input [31:0] w); ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]); endtask
task movw_imm_reg(input [4:0] rn, input [31:0] v);      // mov.w #v, Rn
    ab(8'h2D); ab(8'h20 | rn); ab(8'hF4); aw(v);
endtask
task mov_imm_abs(input integer w, input [31:0] v, input [31:0] a);   // mov.x #v, /a
    ab((w == 0) ? 8'h09 : (w == 1) ? 8'h1B : 8'h2D); ab(8'h80); ab(8'hF4);
    ab(v[7:0]); if (w >= 1) ab(v[15:8]); if (w == 2) begin ab(v[23:16]); ab(v[31:24]); end
    ab(8'hF3); aw(a);
endtask
task movw_reg_abs(input [4:0] rn, input [31:0] a);      // mov.w Rn, /a
    ab(8'h2D); ab(8'hC0); ab(8'h60 | rn); ab(8'hF3); aw(a);
endtask
task movw_abs_abs(input [31:0] s, input [31:0] d);      // mov.w /s, /d
    ab(8'h2D); ab(8'h80); ab(8'hF3); aw(s); ab(8'hF3); aw(d);
endtask
function [7:0] opc(input integer k, input integer w);
    case (k)
        K_NOT:  opc = (w == 0) ? 8'h38 : (w == 1) ? 8'h3A : 8'h3C;
        K_MUL:  opc = (w == 0) ? 8'h81 : (w == 1) ? 8'h83 : 8'h85;
        K_MULU: opc = (w == 0) ? 8'h91 : (w == 1) ? 8'h93 : 8'h95;
        K_DIV:  opc = (w == 0) ? 8'hA1 : (w == 1) ? 8'hA3 : 8'hA5;
        K_DIVU: opc = (w == 0) ? 8'hB1 : (w == 1) ? 8'hB3 : 8'hB5;
        K_REM:  opc = (w == 0) ? 8'h50 : (w == 1) ? 8'h52 : 8'h54;
        K_REMU: opc = (w == 0) ? 8'h51 : (w == 1) ? 8'h53 : 8'h55;
        K_DIVX: opc = 8'hA6;
        default: opc = 8'hB6;
    endcase
endfunction

// ------------------------------------------------------------ exception capture
// The CPU reads SBT[21] (0x54) after pushing the whole frame; take it then.
localparam integer MAXE = 4096;
reg [31:0] ex_sp [0:MAXE-1];
reg [31:0] ex_w  [0:MAXE-1][0:3];
integer nexc = 0;
integer bad_vec = 0;
reg     vec_seen = 1'b0;
always @(posedge clk) begin
    if (!rst && c_req && !c_we && c_ack && c_addr[31:8] == 24'd0 && c_addr[1:0] == 2'd0 && !vec_seen) begin
        vec_seen <= 1'b1;
        if (c_addr == 32'h54) begin
            if (nexc < MAXE) begin
                ex_sp[nexc]   = cpu.r[31];
                ex_w[nexc][0] = rd32(cpu.r[31]);
                ex_w[nexc][1] = rd32(cpu.r[31] + 4);
                ex_w[nexc][2] = rd32(cpu.r[31] + 8);
                ex_w[nexc][3] = rd32(cpu.r[31] + 12);
            end
            nexc = nexc + 1;
        end
        else bad_vec = bad_vec + 1;           // no program here reads the SBT
    end
    if (!c_req) vec_seen <= 1'b0;
end

// ------------------------------------------------------------ run
integer checks = 0, fails = 0, shown = 0;
integer exc_cases = 0, ov_set = 0, ov_clear = 0, cy_kept1 = 0, cy_kept0 = 0;
integer cycles_total = 0;
reg [31:0] op_pc   [0:BATCH_MAX-1];
reg [31:0] next_pc [0:BATCH_MAX-1];

task fail_case(input integer n, input [255:0] what, input [31:0] got, input [31:0] want);
    fails = fails + 1;
    if (shown < 30 || $test$plusargs("SHOWALL")) begin
        $display("FAIL #%0d %0s: op %02x w%0d %s dst=%08x_%08x src=%08x fl=%x | got %08x want %08x",
                 n, what, opc(ck[n], cw[n]), cw[n], cm[n] ? "mem" : "reg",
                 cdh[n], cdl[n], cs[n], cf[n], got, want);
        shown = shown + 1;
    end
endtask

task run_batch(input integer first, input integer count);
    integer i, n, j, cyc, ei;
    reg exc; reg [31:0] rl, rh, mk, got_lo, got_hi, got_psw; reg [3:0] f;
    rst = 1'b1;
    repeat (4) @(posedge clk);
    for (i = 0; i < RAMW; i = i + 1) ram[i] = 16'hFFFF;
    // SBT at 0 (SBR resets to 0): every entry -> BAD_HANDLER, 21 -> SBT_HANDLER
    for (i = 0; i < 64; i = i + 1) begin
        ram[i*2]   = (i == 21) ? SBT_HANDLER[15:0] : BAD_HANDLER[15:0];
        ram[i*2+1] = 16'h0000;
    end
    pa = SBT_HANDLER; ab(8'hFA); ab(8'hE8);      // RETIS #8: pop PC, PSW, +8
    pa = BAD_HANDLER; ab(8'h00);                 // HALT
    for (i = 0; i < count; i = i + 1) begin
        ram[((RES + i*16) >> 1) + 0] = 16'hA5A5; ram[((RES + i*16) >> 1) + 1] = 16'h5A5A;
        ram[((RES + i*16) >> 1) + 2] = 16'hA5A5; ram[((RES + i*16) >> 1) + 3] = 16'h5A5A;
        ram[((RES + i*16) >> 1) + 4] = 16'hA5A5; ram[((RES + i*16) >> 1) + 5] = 16'h5A5A;
    end
    pa = PROG;
    movw_imm_reg(5'd31, STACK);
    for (i = 0; i < count; i = i + 1) begin
        n = first + i;
        if (cm[n]) begin
            if (ck[n] == K_DIVX || ck[n] == K_DIVUX) begin
                mov_imm_abs(2, cdl[n], MEMDST + i*8);
                mov_imm_abs(2, cdh[n], MEMDST + i*8 + 4);
            end
            else mov_imm_abs(cw[n], cdl[n], MEMDST + i*8);
        end
        else begin
            movw_imm_reg(5'd1, cdl[n]);
            if (ck[n] == K_DIVX || ck[n] == K_DIVUX) movw_imm_reg(5'd2, cdh[n]);
        end
        movw_imm_reg(5'd3, cs[n]);
        // updpsw.w #flags, #0000000F
        ab(8'h13); ab(8'h80); ab(8'hF4); aw({28'd0, cf[n]}); ab(8'hF4); aw(32'h0000_000F);
        op_pc[i] = pa;
        ab(opc(ck[n], cw[n]));
        if (cm[n]) begin ab(8'hC0); ab(8'h63); ab(8'hF3); aw(MEMDST + i*8); end
        else       begin ab(8'h61); ab(8'h63); end
        next_pc[i] = pa;
        ab(8'hF7); ab(8'h64);                    // getpsw R4
        if (cm[n]) begin
            movw_abs_abs(MEMDST + i*8, RES + i*16);
            if (ck[n] == K_DIVX || ck[n] == K_DIVUX) movw_abs_abs(MEMDST + i*8 + 4, RES + i*16 + 8);
        end
        else begin
            movw_reg_abs(5'd1, RES + i*16);
            if (ck[n] == K_DIVX || ck[n] == K_DIVUX) movw_reg_abs(5'd2, RES + i*16 + 8);
        end
        movw_reg_abs(5'd4, RES + i*16 + 4);
        if (pa >= PROG_END) begin $display("tb_v60_manual: batch overruns the program area"); $finish; end
    end
    ab(8'h00);                                   // HALT
    nexc = 0; bad_vec = 0;
    rst = 1'b0;
    cyc = 0;
    while (!dbg_halted && cyc < 8000000) begin @(posedge clk); cyc = cyc + 1; end
    repeat (4) @(posedge clk);
    cycles_total = cycles_total + cyc;
    checks = checks + 1;
    if (!dbg_halted) begin
        fails = fails + 1; $display("FAIL batch at case %0d: never halted (pc=%08x)", first, dbg_pc);
    end
    else if (dbg_pc == BAD_HANDLER || bad_vec != 0) begin
        fails = fails + 1;
        $display("FAIL batch at case %0d: an unexpected exception (halted at %08x, bad vectors %0d)", first, dbg_pc, bad_vec);
    end
    ei = 0;
    for (i = 0; i < count; i = i + 1) begin
        n = first + i;
        ref_model(ck[n], cw[n], cdl[n], cdh[n], cs[n], cf[n], exc, rl, rh, f);
        got_lo  = rd32(RES + i*16);
        got_psw = rd32(RES + i*16 + 4);
        got_hi  = rd32(RES + i*16 + 8);
        mk = wmask(cw[n]);
        if (cm[n] && !(ck[n] == K_DIVX || ck[n] == K_DIVUX))
            rl = {16'hFFFF, 16'hFFFF} & ~mk | (rl & mk);    // bytes beside a narrow mem dst are the fill
        checks = checks + 3;
        if (got_lo !== rl) fail_case(n, "dst", got_lo, rl);
        if ((ck[n] == K_DIVX || ck[n] == K_DIVUX) && got_hi !== rh) fail_case(n, "dst hi", got_hi, rh);
        if (got_psw[3:0] !== f) fail_case(n, "flags {CY,OV,S,Z}", {28'd0, got_psw[3:0]}, {28'd0, f});
        if (got_psw[31:4] !== 28'h100_0000) fail_case(n, "PSW high", got_psw, {28'h100_0000, f});
        if (f[2]) ov_set = ov_set + 1; else ov_clear = ov_clear + 1;
        if (ck[n] == K_NOT || ck[n] == K_MUL || ck[n] == K_MULU) begin
            if (f[3]) cy_kept1 = cy_kept1 + 1; else cy_kept0 = cy_kept0 + 1;
        end
        if (exc) begin
            exc_cases = exc_cases + 1;
            checks = checks + 5;
            if (ei >= nexc) fail_case(n, "no zero-divide exception", 32'd0, 32'd21);
            else begin
                // [SP]=next PC, [SP+4]=PSW, [SP+8]=code|count, [SP+12]=current PC
                if (ex_sp[ei] !== STACK - 16) fail_case(n, "frame SP", ex_sp[ei], STACK - 16);
                if (ex_w[ei][0] !== next_pc[i]) fail_case(n, "frame next PC", ex_w[ei][0], next_pc[i]);
                if (ex_w[ei][1] !== {28'h100_0000, f}) fail_case(n, "frame PSW", ex_w[ei][1], {28'h100_0000, f});
                if (ex_w[ei][2] !== 32'h1500_0008) fail_case(n, "frame code", ex_w[ei][2], 32'h1500_0008);
                if (ex_w[ei][3] !== op_pc[i]) fail_case(n, "frame current PC", ex_w[ei][3], op_pc[i]);
            end
            ei = ei + 1;
        end
    end
    checks = checks + 1;
    if (ei != nexc) begin
        fails = fails + 1;
        $display("FAIL batch at case %0d: %0d zero-divide exceptions taken, %0d expected", first, nexc, ei);
    end
endtask

// ------------------------------------------------------------ case generation
task gen_cases;
    integer w, a, b, d, k, i, j, l, nb;
    longint L, la, lb, q;
    reg [31:0] edges [0:15];
    reg [31:0] v, hi, lo, D;
    reg [63:0] N;
    longint lims [0:5];
    longint mults [0:39];
    for (k = 0; k < 9; k = k + 1) per_kind[k] = 0;

    // ---- NOT: every width, edges x edges, CY before random (both values seen)
    edges[0] = 0; edges[1] = 1; edges[2] = 32'hffffffff; edges[3] = 32'h7f; edges[4] = 32'h80;
    edges[5] = 32'hff; edges[6] = 32'h7fff; edges[7] = 32'h8000; edges[8] = 32'hffff;
    edges[9] = 32'h7fffffff; edges[10] = 32'h80000000; edges[11] = 32'h12345678;
    edges[12] = 32'hfffffffe; edges[13] = 32'h00ff00ff; edges[14] = 32'hff00ff00; edges[15] = 32'h55aa55aa;
    for (w = 0; w < 3; w = w + 1)
        for (i = 0; i < 16; i = i + 1)
            for (j = 0; j < 16; j = j + 1) add(K_NOT, w, 0, edges[j], 0, edges[i]);
    for (i = 0; i < 600; i = i + 1) add(K_NOT, i % 3, 0, rnd(), 0, rnd());

    // ---- MUL.B / MULU.B: exhaustive
    for (a = 0; a < 256; a = a + 1)
        for (b = 0; b < 256; b = b + 1) begin
            add(K_MUL,  0, 0, {rnd() & 32'hffffff00} | a, 0, {rnd() & 32'hffffff00} | b);
            add(K_MULU, 0, 0, {rnd() & 32'hffffff00} | a, 0, {rnd() & 32'hffffff00} | b);
        end

    // ---- MUL/MULU .H and .W: approach every boundary from many multipliers
    mults[0] = 1; mults[1] = 2; mults[2] = 3; mults[3] = 5; mults[4] = 7; mults[5] = 10;
    mults[6] = 16; mults[7] = 100; mults[8] = 127; mults[9] = 128; mults[10] = 181; mults[11] = 182;
    mults[12] = 255; mults[13] = 256; mults[14] = 257; mults[15] = 1000; mults[16] = 4096;
    mults[17] = 32767; mults[18] = 32768; mults[19] = 46340; mults[20] = 46341; mults[21] = 65535;
    mults[22] = 65536; mults[23] = 65537; mults[24] = 1000003; mults[25] = 16777216;
    mults[26] = 2147483647; mults[27] = 33; mults[28] = 99; mults[29] = 12345;
    for (j = 30; j < 40; j = j + 1) mults[j] = longint'(rnd() & 32'h0000_ffff) + 1;
    for (w = 1; w < 3; w = w + 1) begin
        L = (w == 1) ? 64'sd32768 : 64'sd2147483648;          // 2^(n-1)
        lims[0] = L - 1;  lims[1] = -L;  lims[2] = 2*L - 1;   // smax, smin, umax
        lims[3] = L;      lims[4] = -L - 1; lims[5] = 2*L;    // one past each
        for (l = 0; l < 6; l = l + 1)
            for (j = 0; j < 40; j = j + 1) begin
                la = mults[j];
                if (la >= 2*L) la = L - 1;
                for (d = -24; d <= 24; d = d + 1) begin
                    lb = lims[l] / la + d;
                    // both signs of each factor, both orders; MULU at the
                    // unsigned limits (l = 2, 5), MUL at all six
                    add(K_MUL,  w, 0, la[31:0], 0, lb[31:0]);
                    add(K_MUL,  w, 0, (-la), 0, (-lb));
                    add(K_MUL,  w, 0, lb[31:0], 0, (-la));
                    if (l == 2 || l == 5) begin
                        add(K_MULU, w, 0, la[31:0], 0, lb[31:0]);
                        add(K_MULU, w, 0, lb[31:0], 0, la[31:0]);
                    end
                end
            end
        for (i = 0; i < 3000; i = i + 1) begin
            v = rnd(); add(K_MUL, w, 0, rnd(), 0, (i & 1) ? (v >> (i % 31)) : v);
            v = rnd(); add(K_MULU, w, 0, rnd() >> (i % 29), 0, v >> (i % 23));
        end
    end
    // the named cases, every width, both CY states (cf is random; add both)
    for (w = 0; w < 3; w = w + 1)
        for (i = 0; i < 4; i = i + 1) begin
            add(K_MUL, w, 0, 1, 0, 32'hffffffff);                       // 1 x -1
            add(K_MUL, w, 0, 32'hffffffff, 0, 32'hffffffff);            // -1 x -1
            add(K_MUL, w, 0, wmask(w) >> 1, 0, 2);                      // max x 2
            add(K_MUL, w, 0, (wmask(w) >> 1) + 1, 0, 1);                // min x 1
            add(K_MUL, w, 0, (wmask(w) >> 1) + 1, 0, 32'hffffffff);     // min x -1
            add(K_MUL, w, 0, wmask(w) >> 1, 0, 1);                      // max x 1
            add(K_MULU, w, 0, wmask(w), 0, 1);                          // umax x 1
            add(K_MULU, w, 0, wmask(w), 0, 2);                          // umax x 2
            add(K_MULU, w, 0, 32'hffffffff, 0, 32'hffffffff);
            add(K_MULU, w, 0, wmask(w) >> 1, 0, 2);                     // fits unsigned
        end

    // ---- DIV/DIVU/REM/REMU: zero divisors, min/-1, and the ordinary range
    for (k = K_DIV; k <= K_REMU; k = k + 1)
        for (w = 0; w < 3; w = w + 1) begin
            for (i = 0; i < 16; i = i + 1) begin
                add(k, w, 0, edges[i], 0, 32'h0);                       // x / 0
                add(k, w, 0, edges[i], 0, rnd() & ~wmask(w));            // zero at width only
            end
            for (i = 0; i < 6; i = i + 1) begin
                add(k, w, 1, edges[i*2], 0, 32'h0);                     // memory dst / 0
                add(k, w, 1, (wmask(w) >> 1) + 1, 0, 32'hffffffff);      // memory min / -1
            end
            for (i = 0; i < 8; i = i + 1) begin
                v = rnd();
                add(k, w, 0, (v & ~wmask(w)) | ((wmask(w) >> 1) + 1), 0, 32'hffffffff); // min / -1
                add(k, w, 0, (v & ~wmask(w)) | ((wmask(w) >> 1) + 1), 0, 1);           // min / 1
                add(k, w, 0, (v & ~wmask(w)) | (wmask(w) >> 1), 0, 32'hffffffff);      // max / -1
                add(k, w, 0, (v & ~wmask(w)) | ((wmask(w) >> 1) + 2), 0, 32'hffffffff); // min+1 / -1
            end
            for (i = 0; i < 16; i = i + 1)
                for (j = 1; j < 16; j = j + 1) add(k, w, 0, edges[i], 0, edges[j]);
            for (i = 0; i < 300; i = i + 1) begin
                v = rnd(); if ((v & wmask(w)) == 0) v = 32'd3;
                add(k, w, (i % 5) == 0, rnd(), 0, (i & 1) ? (v >> (i % 31)) | 1 : v);
            end
        end

    // ---- DIVX/DIVUX: zero, the quotient boundaries swept, the old 15 cases
    for (k = K_DIVX; k <= K_DIVUX; k = k + 1) begin
        for (i = 0; i < 16; i = i + 1) begin
            add(k, 2, 0, edges[i], edges[15 - i], 32'h0);
            add(k, 2, (i % 2), rnd(), rnd(), 32'h0);
        end
        for (j = 0; j < 40; j = j + 1) begin
            D = (j < 30) ? mults[j][31:0] : rnd();
            if (D == 0) D = 1;
            for (l = 0; l < 4; l = l + 1)
                for (d = -40; d <= 40; d = d + 1) begin
                    if (k == K_DIVUX) begin
                        // N = D * 2^32 + d, and D*(2^32-1) + d: q either side of 2^32
                        N = (l[0] ? ({32'd0, D} << 32) : ({32'd0, D} * 64'hffff_ffff)) + 64'(longint'(d));
                        if (l[1]) N = N + {32'd0, D} - 1;
                        add(k, 2, (d % 7) == 0, N[31:0], N[63:32], D);
                    end
                    else begin
                        // q in {2^31-1, 2^31, -2^31, -2^31-1} x divisor of either sign
                        la = longint'($signed(D)) & 64'sh7fff_ffff; if (la == 0) la = 1;
                        lb = l[1] ? -la : la;
                        q = (l[0] ? -64'sd2147483648 : 64'sd2147483647);
                        N = 64'(q * lb + longint'(d));
                        add(k, 2, (d % 7) == 0, N[31:0], N[63:32], lb[31:0]);
                        N = 64'((q + (l[0] ? -1 : 1)) * lb + longint'(d));
                        add(k, 2, 0, N[31:0], N[63:32], lb[31:0]);
                    end
                end
        end
        // tb_v60_divx's fifteen, at both signs
        add(k, 2, 0, 32'h0, 32'h0, 1);
        add(k, 2, 0, 32'hffffffff, 32'hffffffff, 1);
        add(k, 2, 0, 32'hffffffff, 32'hffffffff, 32'hffffffff);
        add(k, 2, 0, 32'h9abcdef0, 32'h12345678, 32'h13579bdf);
        add(k, 2, 0, 32'h00123456, 32'h0, 32'h12345678);
        add(k, 2, 0, 32'h76543210, 32'hfedcba98, 32'h80000000);
        add(k, 2, 0, 32'd123456789, 32'h0, 32'd12345);
        add(k, 2, 0, -32'sd123456789, 32'hffffffff, 32'd12345);
        add(k, 2, 0, 32'd123456789, 32'h0, -32'sd12345);
        add(k, 2, 0, -32'sd123456789, 32'hffffffff, -32'sd12345);
        add(k, 2, 0, 32'h0, 32'h80000000, 32'hffffffff);
        add(k, 2, 0, 32'h0, 32'h80000000, 32'h80000000);
        add(k, 2, 0, 32'hffffffff, 32'h7fffffff, 32'h7fffffff);
        add(k, 2, 0, -32'sd7, 32'hffffffff, 32'd3);
        add(k, 2, 0, 32'h80000000, 32'hffffffff, 32'hffffffff);   // int32 min / -1
        add(k, 2, 1, 32'h80000000, 32'hffffffff, 32'hffffffff);
        add(k, 2, 1, 32'd100, 32'h0, 32'd7);                         // tb_v60_divxmem's
        for (i = 0; i < 800; i = i + 1) begin
            hi = rnd(); lo = rnd(); D = rnd();
            if (i % 3 == 0) hi = hi >> (i % 32);
            if (i % 3 == 1) hi = {32{lo[31]}};
            if (D == 0) D = 5;
            add(k, 2, (i % 4) == 0, lo, hi, D);
        end
    end
endtask

initial begin : main
    integer first, cnt;
    gen_cases();
    first = 0;
    while (first < ncase) begin
        cnt = (ncase - first > BATCH_MAX) ? BATCH_MAX : (ncase - first);
        run_batch(first, cnt);
        first = first + cnt;
    end
    $display("v60_manual: checks=%0d fails=%0d cases=%0d (not=%0d mul=%0d mulu=%0d div=%0d divu=%0d rem=%0d remu=%0d divx=%0d divux=%0d) zero_divides=%0d ov_set=%0d ov_clear=%0d cy_kept=%0d/%0d",
             checks, fails, ncase, per_kind[0], per_kind[1], per_kind[2], per_kind[3], per_kind[4],
             per_kind[5], per_kind[6], per_kind[7], per_kind[8], exc_cases, ov_set, ov_clear, cy_kept0, cy_kept1);
    $finish;
end

endmodule
