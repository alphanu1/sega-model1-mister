//============================================================================
// THIS FILE IS A MODIFIED VERSION OF s32's verif/v60/tb_v60_divx.sv
// (https://github.com/meathax/s32 at 79053611, GPL-3.0-or-later), and says so
// because GPLv3 section 5(a) requires it. Modified 2026-11-12 for the Sega
// Model 1 core (GPL-3.0-or-later): the expectations moved from MAME's
// behaviour to NEC's uPD70616 Programmer's Reference Manual (1986), DIVX
// p.7-39, DIVUX p.7-40 and p.8-8 -
//   * a quotient that does not fit 32 bits (signed for DIVX, unsigned for
//     DIVUX) is an OVERFLOW: OV set and the register pair UNCHANGED. MAME,
//     and this test before, stored the low 32 bits of the quotient. Cases
//     1, 2, 5, 10, 11 and 12 are such overflows.
//   * a zero divisor takes the Integer Zero Divide exception (#21): OV set,
//     the pair unchanged, frame [SP]=next PC, PSW, 15000008, current PC.
//     The program therefore moved to 0x1000 so the SBT can sit at 0, with
//     SBT[21] -> RETIS #8, and the stack pointer is set.
// tools/run_v60_tests.sh runs this copy in place of the upstream file.
// The 64-iteration latency check is unchanged.
//============================================================================
// V60 DIVX/DIVUX directed oracle test.
//
// Runs real encoded instructions through the CPU and checks:
//   * unsigned and signed 64/32 quotient/remainder semantics
//   * quotients wider than the 32-bit destination: overflow, pair unchanged
//   * signed remainder follows the dividend (truncate toward zero)
//   * INT64_MIN edge cases
//   * register-pair write order, flags, and the zero-divide exception
//   * exactly 64 iterative clocks for every non-zero operation
//============================================================================
`timescale 1ns/1ps

module tb_v60_divx;

reg clk = 0, rst = 1;
always #10 clk = ~clk;

wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0]  c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire [1:0]  m_be;

s32_v60 #(.START_PC(32'h0000_1000)) cpu (
    .clk(clk), .ce(1'b1), .rst(rst),
    .if_req(), .if_addr(), .if_data(64'd0), .if_ack(1'b0),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(1'b1), .irq_vector(8'h00), .irq_ack(), .nmi_n(1'b1),
    .dbg_pc(), .dbg_halted()
);

s32_v60_bus adapter (
    .clk(clk), .ce(1'b1), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

reg [15:0] ram [0:32767];
reg ack_r;
assign m_rdata = ram[m_addr[15:1]];
assign m_ack = ack_r;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[15:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[15:1]][15:8] <= m_wdata[15:8];
    end
end

integer pc_a;
task ab(input [7:0] b);
    if (pc_a[0]) ram[pc_a>>1][15:8] = b;
    else         ram[pc_a>>1][7:0]  = b;
    pc_a = pc_a + 1;
endtask
task aw32(input [31:0] w);
    ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]);
endtask
task movw_imm_reg(input [31:0] v, input [4:0] rn);
    ab(8'h2d); ab(8'h20 | rn); ab(8'hf4); aw32(v);
endtask
task divx_imm_reg(input is_signed, input [31:0] divisor, input [4:0] rn);
    ab(is_signed ? 8'ha6 : 8'hb6);
    ab(8'h20 | rn);                 // F2 D=1: destination is register pair
    ab(8'hf4); aw32(divisor);       // full 32-bit immediate first operand
endtask

localparam integer NCASE = 15;
reg [63:0] nums [0:NCASE-1];
reg [31:0] dens [0:NCASE-1];
reg        signs[0:NCASE-1];

integer errors = 0;
integer i;
integer zd_pc, zd_next;
reg signed [63:0] sn, sd, sq, sr;
reg [63:0] uq, ur;
reg [31:0] want_q, want_r;
reg signed [63:0] sq_lim;

task check_case(input integer n);
begin
    if (dens[n] == 0) begin
        want_q = nums[n][31:0];
        want_r = nums[n][63:32];
    end
    else if (signs[n]) begin
        sn = nums[n];
        sd = {{32{dens[n][31]}}, dens[n]};
        if (sn == 64'sh8000_0000_0000_0000 && sd == -64'sd1) begin
            want_q = nums[n][31:0];                 // overflow: unchanged
            want_r = nums[n][63:32];
        end
        else begin
            sq = sn / sd;
            sr = sn % sd;
            if (sq > 64'sd2147483647 || sq < -64'sd2147483648) begin
                want_q = nums[n][31:0];             // overflow: unchanged
                want_r = nums[n][63:32];
            end
            else begin
                want_q = sq[31:0];
                want_r = sr[31:0];
            end
        end
    end
    else begin
        uq = nums[n] / dens[n];
        ur = nums[n] % dens[n];
        if (uq[63:32] != 0) begin
            want_q = nums[n][31:0];                 // overflow: unchanged
            want_r = nums[n][63:32];
        end
        else begin
            want_q = uq[31:0];
            want_r = ur[31:0];
        end
    end
    if (cpu.r[n*2] !== want_q || cpu.r[n*2+1] !== want_r) begin
        errors = errors + 1;
        $display("  FAIL case %0d %s: got q=%08x r=%08x want q=%08x r=%08x",
                 n, signs[n] ? "DIVX" : "DIVUX",
                 cpu.r[n*2], cpu.r[n*2+1], want_q, want_r);
    end
end
endtask

// Internal timing monitor: active covers exactly the 64 restoring steps.
integer active_clocks = 0;
integer completed = 0;
reg active_d = 0;
always @(posedge clk) begin
    if (rst) begin
        active_clocks = 0;
        completed = 0;
        active_d = 0;
    end
    else begin
        if (cpu.xdiv_active) active_clocks = active_clocks + 1;
        if (active_d && !cpu.xdiv_active) begin
            if (active_clocks != 64) begin
                errors = errors + 1;
                $display("  FAIL DIVX latency=%0d want=64", active_clocks);
            end
            completed = completed + 1;
            active_clocks = 0;
        end
        active_d = cpu.xdiv_active;
    end
end

initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    // SBT at 0: entry 21 (0x54) -> 0x800, which is RETIS #8
    ram[16'h54 >> 1] = 16'h0800; ram[(16'h54 >> 1) + 1] = 16'h0000;
    ram[16'h800 >> 1] = 16'hE8FA;

    nums[0]  = 64'h0000_0000_0000_0000; dens[0]  = 32'h0000_0001; signs[0]  = 0;
    nums[1]  = 64'hffff_ffff_ffff_ffff; dens[1]  = 32'h0000_0001; signs[1]  = 0;
    nums[2]  = 64'hffff_ffff_ffff_ffff; dens[2]  = 32'hffff_ffff; signs[2]  = 0;
    nums[3]  = 64'h1234_5678_9abc_def0; dens[3]  = 32'h1357_9bdf; signs[3]  = 0;
    nums[4]  = 64'h0000_0000_0012_3456; dens[4]  = 32'h1234_5678; signs[4]  = 0;
    nums[5]  = 64'hfedc_ba98_7654_3210; dens[5]  = 32'h8000_0000; signs[5]  = 0;
    nums[6]  =  64'sd123456789;         dens[6]  =  32'sd12345;    signs[6]  = 1;
    nums[7]  = -64'sd123456789;         dens[7]  =  32'sd12345;    signs[7]  = 1;
    nums[8]  =  64'sd123456789;         dens[8]  = -32'sd12345;    signs[8]  = 1;
    nums[9]  = -64'sd123456789;         dens[9]  = -32'sd12345;    signs[9]  = 1;
    nums[10] = 64'h8000_0000_0000_0000; dens[10] = 32'hffff_ffff; signs[10] = 1;
    nums[11] = 64'h8000_0000_0000_0000; dens[11] = 32'h8000_0000; signs[11] = 1;
    nums[12] = 64'h7fff_ffff_ffff_ffff; dens[12] = 32'h7fff_ffff; signs[12] = 1;
    nums[13] = -64'sd7;                 dens[13] =  32'sd3;        signs[13] = 1;
    nums[14] = 64'h89ab_cdef_0123_4567; dens[14] = 32'h0000_0000; signs[14] = 0;

    pc_a = 32'h1000;
    movw_imm_reg(32'h0000_8000, 5'd31);     // SP for the zero-divide frame
    for (i = 0; i < NCASE; i = i + 1) begin
        movw_imm_reg(nums[i][31:0], i*2);
        movw_imm_reg(nums[i][63:32], i*2+1);
        if (i == NCASE-1) zd_pc = pc_a;
        divx_imm_reg(signs[i], dens[i], i*2);
        if (i == NCASE-1) zd_next = pc_a;
    end
    ab(8'h00);                         // HALT

    repeat (8) @(posedge clk);
    rst = 0;
    wait (cpu.dbg_halted);
    repeat (3) @(posedge clk);          // observe final active falling edge

    for (i = 0; i < NCASE; i = i + 1) check_case(i);
    if (completed != NCASE-1) begin
        errors = errors + 1;
        $display("  FAIL iterative completions=%0d want=%0d", completed, NCASE-1);
    end
    // Case 14 is a zero divide: OV set, S/Z from the unchanged low word
    // (0x01234567), CY unchanged (0) - the PSW the exception pushed, which
    // RETIS restored. Case 13's q=-2 no longer shows: the exception wrote OV.
    if (cpu.f_z !== 1'b0 || cpu.f_s !== 1'b0 ||
        cpu.f_ov !== 1'b1 || cpu.f_cy !== 1'b0) begin
        errors = errors + 1;
        $display("  FAIL flags after zero divide Z=%b S=%b OV=%b CY=%b",
                 cpu.f_z, cpu.f_s, cpu.f_ov, cpu.f_cy);
    end

    // The zero-divide frame, below the SP of 0x8000: next PC, PSW, code|8, PC
    if ({ram[16'h3ff9], ram[16'h3ff8]} !== zd_next ||
        {ram[16'h3ffb], ram[16'h3ffa]} !== 32'h1000_0004 ||
        {ram[16'h3ffd], ram[16'h3ffc]} !== 32'h1500_0008 ||
        {ram[16'h3fff], ram[16'h3ffe]} !== zd_pc || cpu.r[31] !== 32'h0000_8000) begin
        errors = errors + 1;
        $display("  FAIL zero-divide frame next=%08x psw=%08x code=%08x pc=%08x sp=%08x (want %08x 10000004 15000008 %08x 00008000)",
                 {ram[16'h3ff9], ram[16'h3ff8]}, {ram[16'h3ffb], ram[16'h3ffa]},
                 {ram[16'h3ffd], ram[16'h3ffc]}, {ram[16'h3fff], ram[16'h3ffe]}, cpu.r[31],
                 zd_next, zd_pc);
    end

    if (errors == 0) $display("DIVX PASS (%0d cases, %0d iterative)", NCASE, completed);
    else             $display("DIVX FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #4000000;
    $display("DIVX FAIL (timeout, pc=%08x)", cpu.dbg_pc);
    $finish;
end

endmodule
