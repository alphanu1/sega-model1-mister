// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA - Copyright (C) 2026 alphanu1
//
// DERIVED FROM SOMEONE ELSE'S WORK. The behaviour here was lifted out of
// v60.sv, which was imported from the Sega System 32 MiSTer core,
// https://github.com/meathax/s32, GPL-3.0-or-later. Moving code into a new file
// does not detach it from its licence. See the note at the top of v60.sv.
// Split out 2026-09-02.
//
// ---------------------------------------------------------------------------
// THE V60'S SHARED INTEGER ALU: ONE ADDER FOR THIRTY OPCODES.
//
// WHY THIS EXISTS. The V60 is microsequenced in name only. Its arithmetic lived
// in fifteen separate arms of one 3,800-line always block, and Quartus will not
// share logic across arms it cannot prove exclusive, so each arm built its own
// datapath. ADD alone inferred THREE adders - the 33-bit sum, plus a 9-bit and
// a 17-bit adder used for nothing but the carry flag at the narrow widths - and
// SUB, SUBC and NEG each added a second comparator on top of their subtract.
//
// Measured on the whole CPU before this change: 27,754 combinational ALUTs
// against 4,224 registers, a ratio of 6.6 where a CPU normally sits near 1-2,
// and a critical path 32.9 LUTs deep. The register count is right for 32 GPRs
// plus PC, flags, state and the fetch buffer; it is the combinational cloud
// around them that is three times too big. The Model 2 core's i960 - a more
// capable CPU - fits in 7,200 ALM because it instantiates ONE i960_alu, ONE
// i960_agu and ONE i960_regs and lets its sequencer choose the operands. This
// module is that pattern applied here.
//
// ONE ADDER, DERIVED NOT GUESSED. dimext ZERO-extends, so for a byte operation
// the carry out of bit 7 is simply bit 8 of the full 33-bit sum, and for a
// halfword it is bit 16. That makes ADD's three width-specific carry
// expressions three bit-selects of one sum, and ADDC's `res[8]` / `res[16]`
// are literally the same bits of the same sum. Subtraction reuses the adder as
// b + ~a + 1, where the carry-out is the complement of the borrow, which
// reproduces `dimext(b,d) < dimext(a,d)` exactly because both operands are
// zero-extended. SUBC is b + ~a + ~cy_in, whose borrow is `b < a + cy_in` over
// 33 bits - the audited R20 V60-16 behaviour, not the 32-bit compare that
// wrapped. NEG is the same subtract with b forced to zero, and its carry
// condition `a != 0` is exactly the absence of a carry-out.
//
// THE QUIRKS ARE REPRODUCED, NOT TIDIED. Logic ops take the RAW operands, not
// the size-extended ones, because that is what the original did; the width only
// reaches them through the Z and S masks. CMP shares SUB's datapath and is
// distinguished solely by op[4], which separates 0xa8/aa/ac from 0xb8/ba/bc.
//
// `valid` says whether this unit implements the opcode. The caller keeps its
// own arm for anything valid does not claim, so an opcode can never fall
// through to a silently wrong result.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module v60_alu (
    input  logic [7:0]  op,      // cur_op
    input  logic [1:0]  d,       // operand size: 0=byte 1=halfword 2=word
    input  logic [31:0] a,       // source operand (op1)
    input  logic [31:0] b,       // destination operand (op2)
    input  logic        cy_in,   // carry/borrow in, for ADDC and SUBC

    output logic [31:0] result,
    output logic        cy,
    output logic        ov,
    output logic        z,
    output logic        s,
    output logic        writes,  // 0 for CMP, which sets flags only
    output logic        cy_we,   // 0 for AND/OR/XOR, which leave carry ALONE
    output logic        valid    // this unit implements `op`
);

    // ----- the size helpers, identical to v60.sv's -----
    function automatic [31:0] dimext(input [31:0] v, input [1:0] dd);
        case (dd)
            2'd0: dimext = {24'b0, v[7:0]};
            2'd1: dimext = {16'b0, v[15:0]};
            default: dimext = v;
        endcase
    endfunction

    function automatic sgn(input [31:0] v, input [1:0] dd);
        case (dd) 2'd0: sgn = v[7]; 2'd1: sgn = v[15]; default: sgn = v[31]; endcase
    endfunction

    function automatic zer(input [31:0] v, input [1:0] dd);
        case (dd) 2'd0: zer = v[7:0]==0; 2'd1: zer = v[15:0]==0; default: zer = v==0; endcase
    endfunction

    // ----- opcode classification -----
    logic is_add, is_addc, is_sub, is_cmp, is_subc;
    logic is_not, is_neg, is_and, is_or, is_xor;

    always_comb begin
        is_add  = (op==8'h80) || (op==8'h82) || (op==8'h84);
        is_addc = (op==8'h90) || (op==8'h92) || (op==8'h94);
        is_sub  = (op==8'ha8) || (op==8'haa) || (op==8'hac);
        is_cmp  = (op==8'hb8) || (op==8'hba) || (op==8'hbc);
        is_subc = (op==8'h98) || (op==8'h9a) || (op==8'h9c);
        is_not  = (op==8'h38) || (op==8'h3a) || (op==8'h3c);
        is_neg  = (op==8'h39) || (op==8'h3b) || (op==8'h3d);
        is_and  = (op==8'ha0) || (op==8'ha2) || (op==8'ha4);
        is_or   = (op==8'h88) || (op==8'h8a) || (op==8'h8c);
        is_xor  = (op==8'hb0) || (op==8'hb2) || (op==8'hb4);
    end

    wire is_sublike = is_sub || is_cmp || is_subc || is_neg;
    wire is_addlike = is_add || is_addc;

    // ----- THE ONE ADDER -----
    //
    // b + a            for ADD
    // b + a + cy       for ADDC
    // b + ~a + 1       for SUB and CMP
    // b + ~a + ~cy     for SUBC
    // 0 + ~a + 1       for NEG
    wire [31:0] ae = dimext(a, d);
    wire [31:0] be = is_neg ? 32'd0 : dimext(b, d);

    logic [31:0] addend;
    logic        cin;
    always_comb begin
        addend = is_sublike ? ~ae : ae;
        cin    = is_subc ? ~cy_in
               : is_sublike ? 1'b1
               : is_addc ? cy_in
               : 1'b0;
    end

    wire [32:0] sum = {1'b0, be} + {1'b0, addend} + {32'b0, cin};

    // ----- result -----
    logic [31:0] logic_res;
    always_comb begin
        // RAW operands, not size-extended - see the header note.
        logic_res = is_and ? (b & a)
                  : is_or  ? (b | a)
                  : is_xor ? (b ^ a)
                  :          ~ae;              // NOT
    end

    assign result = (is_not || is_and || is_or || is_xor) ? logic_res : sum[31:0];

    // ----- carry -----
    //
    // Add: the carry out of the operand's top bit, which for zero-extended
    // operands is sum[8] / sum[16] / sum[32]. Subtract: borrow is the
    // complement of the carry-out. Logic ops clear it; AND/OR/XOR leave it
    // alone in the original, so they are excluded from cy_we below.
    wire cy_add = (d==2'd0) ? sum[8] : (d==2'd1) ? sum[16] : sum[32];

    always_comb begin
        if (is_addlike)      cy = cy_add;
        else if (is_sublike) cy = ~sum[32];
        else                 cy = 1'b0;        // NOT
    end

    // ----- overflow -----
    logic sa, sb, sr;
    always_comb begin
        sa = sgn(a, d);
        sb = sgn(b, d);
        sr = sgn(result, d);
        if (is_addlike)      ov = ~(sb ^ sa) & (sb ^ sr);
        else if (is_neg)     ov = sa & sr;
        else if (is_sub || is_cmp || is_subc) ov = (sb ^ sa) & (sb ^ sr);
        else                 ov = 1'b0;
    end

    assign z = zer(result, d);
    assign s = sgn(result, d);

    // AND/OR/XOR DO NOT ASSIGN CARRY AT ALL in the original - they are the only
    // arms here that leave a flag untouched rather than clearing it. NOT does
    // clear it, so it keeps cy_we with cy driven to 0.
    assign cy_we  = !(is_and || is_or || is_xor);
    assign writes = !is_cmp;
    assign valid  = is_add || is_addc || is_sub || is_cmp || is_subc
                 || is_not || is_neg || is_and || is_or  || is_xor;

endmodule
