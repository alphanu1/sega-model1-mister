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
// The V60's single-precision floating-point group (0x5C / 0x5F), lifted out of
// the CPU's monolithic instruction FSM.
//
// WHY IT MOVED
//
// v60.sv is ~4,600 lines with essentially ONE always block spanning 47 case
// arms, and that shape is why this CPU is twice the size of Model 2's i960 for
// FEWER registers: one giant block makes every destination register a selection
// tree over every arm. Measured, Quartus 17.0, standalone:
//
//     V60 with FP      18,048 ALM
//     V60 without FP   16,301 ALM     so the group is 1,747
//
// docs/HANDOFF.md records 2,984 for that same measurement; that figure predates
// the FP unpack pipelining and is stale. Measure it, do not quote it.
//
// The group CANNOT be removed - docs/findings.md 2026-09-01 has dbg_fp_trap
// firing at 00fed52b on a real cvt.sw sine-table lookup in gameplay - so the
// lever is to move it out and then make it compute less per cycle.
//
// WHAT MOVED AND WHAT DID NOT
//
// Moved: the arithmetic, the operand pipeline, the restoring divider, the
// per-subop dispatch and the flag computation. Three states leave with it -
// S_FP_EXEC2, S_FP_PACK and S_FP_DIV are gone from the CPU's state machine.
//
// Stayed: operand fetch, writeback routing, and the four small predicates
// (fp_valid, fp_dim1, fp_op2_value, fp_op2_rmw) that decode and the operand
// setup need before this unit is ever started.
//
// The CPU hands over {op, subop, a, b, cw} with `start` and takes back a
// result, the four flags, and whether the instruction writes back at all -
// CMPF does not. Multi-cycle work sequences itself in here.
//
// SPENDING CYCLES IS CHEAP HERE. The V60 stalls on the bus for 65-93% of its
// cycles (docs/HANDOFF.md), so trading combinational depth for clocks costs
// almost nothing in real throughput. That is what makes the sequencing
// affordable, and what the i960 comparison says to do everywhere.


module v60_fp (
    input             clk,
    input             ce,
    input             rst,

    input             start,
    input      [7:0]  op,          // 8'h5c or 8'h5f
    input      [4:0]  subop,
    input      [31:0] a, b,        // op1, op2 bit patterns
    input      [2:0]  cw,          // task control word rounding mode, for CVTSW

    output            done,
    output reg        writes,      // 0 for CMPF, which sets flags only
    output reg [31:0] result,
    output reg        o_z, o_s, o_ov, o_cy
);

// ---------------------------------------------------------------- pipeline
reg [76:0] fp_pk;              // add/multiply intermediate, before normalise
reg [40:0] fp_ux, fp_uy;       // pre-unpacked {sign, exp[15:0], mant[23:0]}
reg [31:0] fp_rx, fp_ry;       // the raw operands, for the NaN/inf/zero cases
reg        fp_kind;            // 0 = add, 1 = mul
reg [49:0] fdiv_rem;           // FDIV restoring-division partial remainder
reg [26:0] fdiv_qacc;          // FDIV quotient accumulator (27 bits, MSB=int bit)
reg [23:0] fdiv_den;           // FDIV divisor mantissa (normalized, bit23=1)
reg [5:0]  fdiv_cnt;           // FDIV bit counter
reg        fdiv_sign;          // FDIV result sign
reg signed [15:0] fdiv_exp;    // FDIV result exponent (unbiased)



function automatic fp_isnan(input [31:0] x);
    fp_isnan = (x[30:23] == 8'hff) && (x[22:0] != 0);
endfunction

function automatic fp_isinf(input [31:0] x);
    fp_isinf = (x[30:23] == 8'hff) && (x[22:0] == 0);
endfunction

function automatic fp_iszero(input [31:0] x);
    fp_iszero = (x[30:0] == 31'd0);
endfunction

function automatic [4:0] fp_clz28(input [27:0] v);
    integer i; logic done;
    fp_clz28 = 5'd28; done = 1'b0;
    for (i = 27; i >= 0; i = i - 1)
        if (!done && v[i]) begin fp_clz28 = 5'(27 - i); done = 1'b1; end
endfunction

function automatic [40:0] fp_unpack(input [31:0] x);
    logic s; logic signed [15:0] e; logic [23:0] m;
    logic [7:0] ef; logic [22:0] mf; logic [4:0] lz;
    s = x[31]; ef = x[30:23]; mf = x[22:0];
    if (ef == 8'd0) begin
        if (mf == 23'd0) begin e = 16'sd0; m = 24'd0; end
        else begin
            // shift {0,mf} left so its leading 1 reaches bit 23.  clz28({5'd0,mf})
            // counts zeros above bit 22, which is (shift + 4); subtract 4.
            lz = fp_clz28({5'd0, mf}) - 5'd4;
            m  = {1'b0, mf} << lz;
            e  = -16'sd126 - $signed({11'd0, lz});
        end
    end
    else begin
        m = {1'b1, mf};
        e = $signed({8'd0, ef}) - 16'sd127;
    end
    fp_unpack = {s, e, m};
endfunction

function automatic [31:0] fp_pack(input logic sign, input logic signed [15:0] E,
                                  input logic [26:0] sg);
    logic signed [15:0] e;
    logic [24:0] m;
    logic g, r, s, rup, lost;
    logic [15:0] sh;
    logic [26:0] shd;
    logic [31:0] res;
    e = E;
    if (sg[26:3] == 24'd0 && sg[2:0] == 3'd0) res = {sign, 31'd0};
    else if (e > 16'sd127) res = {sign, 8'hff, 23'd0};
    else if (e >= -16'sd126) begin
        m = {1'b0, sg[26:3]};
        g = sg[2]; r = sg[1]; s = sg[0];
        rup = g & (r | s | m[0]);
        m = m + (rup ? 25'd1 : 25'd0);
        if (m[24]) begin m = m >> 1; e = e + 16'sd1; end
        if (e > 16'sd127) res = {sign, 8'hff, 23'd0};
        else res = {sign, (e[7:0] + 8'd127), m[22:0]};
    end
    else begin
        sh  = 16'((-16'sd126) - e);              // positive denormal shift
        shd = (sh >= 16'd27) ? 27'd0 : (sg >> sh);
        lost = (sh >= 16'd27) ? (sg != 27'd0)
                              : ((sg & ((27'd1 << sh) - 27'd1)) != 27'd0);
        m = {1'b0, shd[26:3]};
        g = shd[2]; r = shd[1]; s = shd[0] | lost;
        rup = g & (r | s | m[0]);
        m = m + (rup ? 25'd1 : 25'd0);
        res = {sign, (m[23] ? 8'd1 : 8'd0), m[22:0]};   // m[23] -> smallest normal
    end
    fp_pack = res;
endfunction

function automatic [76:0] fp_add(input [31:0] x, input [31:0] y,
                                input [40:0] ux, input [40:0] uy);
    logic sx, sy, sr; logic signed [15:0] ex, ey, er, d;
    logic [23:0] mx, my;
    logic [26:0] bx, by, sm, res27; logic [27:0] sum;
    logic sticky; logic [4:0] lz; logic [76:0] out;
    if (fp_isnan(x) || fp_isnan(y)) out = {1'b1, 32'h7fc00000, 1'b0, 16'd0, 27'd0};
    else if (fp_isinf(x) && fp_isinf(y))
        out = {1'b1, (x[31] == y[31]) ? x : 32'h7fc00000, 1'b0, 16'd0, 27'd0};     // inf-inf = NaN
    else if (fp_isinf(x)) out = {1'b1, x, 1'b0, 16'd0, 27'd0};
    else if (fp_isinf(y)) out = {1'b1, y, 1'b0, 16'd0, 27'd0};
    else begin
        // Pre-unpacked by S_FP_EXEC a cycle earlier; fp_unpack's clz28 is
        // what made this path long.
        {sx, ex, mx} = ux;
        {sy, ey, my} = uy;
        if (mx == 0 && my == 0) out = {1'b1, {sx & sy, 31'd0}, 1'b0, 16'd0, 27'd0};        // (+/-0)+(+/-0)
        else if (mx == 0) out = {1'b1, y, 1'b0, 16'd0, 27'd0};
        else if (my == 0) out = {1'b1, x, 1'b0, 16'd0, 27'd0};
        else begin
            // order so (ex,mx) is the larger magnitude
            if ((ey > ex) || (ey == ex && my > mx)) begin
                {sx, sy} = {sy, sx}; {ex, ey} = {ey, ex}; {mx, my} = {my, mx};
            end
            bx = {mx, 3'b000};
            d  = ex - ey;
            if (d >= 16'sd27) begin by = 27'd0; sticky = (my != 0); end
            else begin
                by     = {my, 3'b000} >> $unsigned(d);
                sticky = (({my, 3'b000} &
                          ((27'd1 << $unsigned(d)) - 27'd1)) != 27'd0);
            end
            by[0] = by[0] | sticky;
            if (sx == sy) begin
                sum = {1'b0, bx} + {1'b0, by};
                sr  = sx;
                if (sum[27]) begin er = ex + 16'sd1; res27 = sum[27:1]; res27[0] = res27[0] | sum[0]; end
                else         begin er = ex;          res27 = sum[26:0]; end
                out = {1'b0, 32'd0, sr, 16'(er), res27};
            end
            else begin
                res27 = bx - by;                        // bx >= by (x is larger)
                sr = sx;
                if (res27 == 27'd0) out = {1'b1, 32'd0, 1'b0, 16'd0, 27'd0};        // exact cancellation -> +0
                else begin
                    // shift the leading 1 back to bit 26; fp_clz28({0,res27})
                    // returns 27-p for a leading 1 at bit p, so shift = that - 1.
                    lz = fp_clz28({1'b0, res27}) - 5'd1;
                    er = ex - $signed({11'd0, lz});
                    out = {1'b0, 32'd0, sr, 16'(er), res27 << lz};
                end
            end
        end
    end
    fp_add = out;
endfunction

function automatic [76:0] fp_mul(input [31:0] x, input [31:0] y,
                                input [40:0] ux, input [40:0] uy);
    logic sx, sy, sr; logic signed [15:0] ex, ey, er;
    logic [23:0] mx, my; logic [47:0] p; logic [26:0] sg; logic [76:0] out;
    sr = x[31] ^ y[31];
    if (fp_isnan(x) || fp_isnan(y)) out = {1'b1, 32'h7fc00000, 1'b0, 16'd0, 27'd0};
    else if (fp_isinf(x) || fp_isinf(y)) begin
        if (fp_iszero(x) || fp_iszero(y)) out = {1'b1, 32'h7fc00000, 1'b0, 16'd0, 27'd0};   // inf*0 = NaN
        else out = {1'b1, {sr, 8'hff, 23'd0}, 1'b0, 16'd0, 27'd0};
    end
    else if (fp_iszero(x) || fp_iszero(y)) out = {1'b1, {sr, 31'd0}, 1'b0, 16'd0, 27'd0};
    else begin
        // Pre-unpacked by S_FP_EXEC a cycle earlier; fp_unpack's clz28 is
        // what made this path long.
        {sx, ex, mx} = ux;
        {sy, ey, my} = uy;
        p = mx * my;                       // 48-bit, leading 1 at bit 47 or 46
        if (p[47]) begin
            er = ex + ey + 16'sd1;
            sg = {p[47:24], p[23], p[22], (|p[21:0])};
        end
        else begin
            er = ex + ey;
            sg = {p[46:23], p[22], p[21], (|p[20:0])};
        end
        out = {1'b0, 32'd0, sr, 16'(er), sg};
    end
    fp_mul = out;
endfunction

function automatic [31:0] fp_scale(input [31:0] x, input signed [15:0] n);
    logic s; logic [23:0] m; logic [31:0] out;
    logic signed [15:0] e; logic signed [17:0] esum;
    if (fp_isnan(x) || fp_isinf(x) || fp_iszero(x)) out = x;
    else begin
        {s, e, m} = fp_unpack(x);
        // value = 1.m * 2^e; scaled exponent e+n; mantissa is 24-bit at
        // bit23.  Widened sum: an int16 e+n wraps for |n| near 32768 and
        // would turn a huge scale into the wrong extreme.
        esum = 18'(e) + 18'(n);
        if (esum > 18'sd254)       out = {s, 8'hff, 23'd0};   // overflow: inf
        else if (esum < -18'sd180) out = {s, 31'd0};          // deep underflow: 0
        else                       out = fp_pack(s, 16'(esum), {m, 3'b000});
    end
    fp_scale = out;
endfunction

function automatic [31:0] cvt_w_s(input [31:0] iv);
    logic sign; logic [31:0] mag; logic [4:0] lz; logic [5:0] p;
    logic signed [15:0] e; logic [26:0] sg;
    logic [5:0] sh; logic [31:0] shifted; logic lost; logic done; integer i;
    if (iv == 32'd0) cvt_w_s = 32'd0;
    else begin
        sign = iv[31];
        mag  = sign ? (~iv + 32'd1) : iv;
        lz = 5'd0; done = 1'b0;
        for (i = 31; i >= 0; i = i - 1)
            if (!done && mag[i]) begin lz = 5'(31 - i); done = 1'b1; end
        p = 6'd31 - {1'b0, lz};                         // position of leading 1
        e = $signed({10'd0, p});                        // exponent = p
        if (p <= 6'd26)
            sg = 27'(mag << (6'd26 - p));               // exact, guard bits 0
        else begin
            sh = p - 6'd26;
            shifted = mag >> sh;
            lost = ((mag & ((32'd1 << sh) - 32'd1)) != 32'd0);
            sg = {shifted[26:3], shifted[2], shifted[1], shifted[0] | lost};
        end
        cvt_w_s = fp_pack(sign, e, sg);
    end
endfunction

function automatic fp_lt(input [31:0] a, input [31:0] b);
    logic za, zb;
    za = fp_iszero(a); zb = fp_iszero(b);
    if (za && zb) fp_lt = 1'b0;                  // +/-0 equal
    else if (a[31] != b[31]) fp_lt = a[31] & ~(za & zb); // neg < pos
    else if (a[31] == 1'b0) fp_lt = (a[30:0] < b[30:0]); // both +: bit compare
    else fp_lt = (a[30:0] > b[30:0]);            // both -: reversed
endfunction

function automatic fp_eq(input [31:0] a, input [31:0] b);
    if (fp_iszero(a) && fp_iszero(b)) fp_eq = 1'b1;
    else fp_eq = (a == b);
endfunction

function automatic [31:0] fdiv_finish(input [26:0] q, input [49:0] rem);
    logic [23:0] mant; logic g, r, s; logic signed [15:0] e;
    if (q[26]) begin                        // quotient in [1,2)
        mant = q[26:3]; g = q[2]; r = q[1]; s = q[0] | (rem != 0);
        e = fdiv_exp;
    end
    else begin                              // quotient in [0.5,1): shift up one
        mant = q[25:2]; g = q[1]; r = q[0]; s = (rem != 0);
        e = fdiv_exp - 16'sd1;
    end
    fdiv_finish = fp_pack(fdiv_sign, e, {mant, g, r, s});
endfunction

function automatic [31:0] fp_pk_result(input [76:0] b);
    fp_pk_result = b[76] ? b[75:44] : fp_pack(b[43], $signed(b[42:27]), b[26:0]);
endfunction
task automatic cvt_s_w(input [31:0] x, input [2:0] mode,
                       output logic [31:0] iv, output logic ov);
    logic s; logic signed [15:0] e; logic [23:0] m;
    logic [63:0] big; logic [31:0] intp; logic frac_nz; logic [31:0] fracbits;
    logic roundup; logic signed [15:0] sh;
    iv = 32'd0; ov = 1'b0;
    if (fp_isnan(x) || fp_isinf(x)) begin
        // Pinned MAME converts (uint32_t)(int64_t)val on its x86 host: NaN
        // and out-of-int64-range saturate the hardware convert to INT64_MIN,
        // whose low 32 bits are 0.  OV = (!S && val <= -1.0f) -> -inf only.
        iv = 32'd0; ov = fp_isinf(x) & x[31];
    end
    else if (fp_iszero(x)) iv = 32'd0;
    else begin
        {s, e, m} = fp_unpack(x);        // value = m * 2^(e-23), m in [2^23,2^24)
        if (e < 16'sd0) begin
            // |value| < 1 : integer part 0, fraction = whole value
            intp = 32'd0; frac_nz = 1'b1;
            // magnitude < 1 -> rounding may make it 0 or +/-1
            roundup = 1'b0;
            case (mode)
                3'd0: roundup = (e == -16'sd1);            // >=0.5 rounds away
                3'd1: roundup = s;                          // floor: -x -> -1
                3'd2: roundup = ~s;                         // ceil: +x -> +1
                default: roundup = 1'b0;                    // trunc -> 0
            endcase
            intp = roundup ? 32'd1 : 32'd0;
            iv = s ? (~intp + 32'd1) : intp;
        end
        else if (e >= 16'sd31) begin
            // MAME stores the LOW 32 BITS of the int64 truncation, not a
            // clamp: well-defined in C for e in [31,62]; e >= 63 saturates
            // the x86 convert to INT64_MIN (low 32 = 0).  |val| >= 2^31 here
            // and integral, so no rounding is involved.
            if (e >= 16'sd63) intp = 32'd0;
            else begin
                big  = {40'd0, m} << $unsigned(e - 16'sd23);
                intp = big[31:0];
            end
            iv = s ? (~intp + 32'd1) : intp;
            // OV = stored sign bit disagrees with the true value's sign
            // (MAME: (_S && val>=0) || (!_S && val<=-1); |val| >= 1 here).
            // Note exactly -2^31 stores 0x80000000 with OV=0.
            ov = (iv[31] & ~s) | (~iv[31] & s);
        end
        else begin
            sh = 16'sd23 - e;                               // fraction bit count
            if (sh <= 0) begin intp = m << $unsigned(-sh); fracbits = 32'd0; frac_nz = 1'b0; end
            else begin
                intp = 32'({24'd0, m} >> $unsigned(sh));
                fracbits = ({8'd0, m} << $unsigned(16'sd32 - sh)); // fractional bits in high part
                frac_nz = (fracbits != 32'd0);
            end
            roundup = 1'b0;
            case (mode)
                3'd0: roundup = fracbits[31];               // half-away: top frac bit
                3'd1: roundup = s & frac_nz;                // floor
                3'd2: roundup = (~s) & frac_nz;             // ceil
                default: roundup = 1'b0;                    // trunc
            endcase
            intp = intp + (roundup ? 32'd1 : 32'd0);
            iv = s ? (~intp + 32'd1) : intp;
            ov = (~s & iv[31]) | (s & ~iv[31] & (iv != 0));
        end
    end
endtask

typedef enum logic [2:0] { F_IDLE, F_EXEC2, F_PACK, F_DIV, F_DONE } fst_t;
fst_t fst;

// One cycle wide: the caller starts an operation and waits for this.
assign done = (fst == F_DONE);

task automatic fp_div_start(input [31:0] x, input [31:0] y);
    logic sx, sy; logic signed [15:0] ex, ey; logic [23:0] mx, my; logic [31:0] out;
    logic done;
    done = 1'b1; out = 32'd0;
    if (fp_isnan(x) || fp_isnan(y)) out = 32'h7fc00000;
    else if (fp_isinf(x) && fp_isinf(y)) out = 32'h7fc00000;
    else if (fp_isinf(x)) out = {x[31]^y[31], 8'hff, 23'd0};
    else if (fp_isinf(y)) out = {x[31]^y[31], 31'd0};
    else if (fp_iszero(y)) out = fp_iszero(x) ? 32'h7fc00000
                                              : {x[31]^y[31], 8'hff, 23'd0};
    else if (fp_iszero(x)) out = {x[31]^y[31], 31'd0};
    else done = 1'b0;
    if (done) begin
        result <= out;
        o_ov <= 1'b0; o_cy <= 1'b0; o_s <= out[31]; o_z <= (out == 32'd0);
        begin writes <= 1'b1; fst <= F_DONE; end
    end
    else begin
        {sx, ex, mx} = fp_unpack(x);
        {sy, ey, my} = fp_unpack(y);
        fdiv_sign <= sx ^ sy;
        fdiv_exp  <= ex - ey;
        fdiv_den  <= my;
        fdiv_rem  <= {26'd0, mx};
        fdiv_qacc <= 27'd0;
        fdiv_cnt  <= 6'd26;                  // 27 quotient bits
        fst <= F_DIV;
    end

endtask

always @(posedge clk) begin
if (rst) begin
    fst <= F_IDLE;
    result <= 32'd0; writes <= 1'b0;
    o_z <= 1'b0; o_s <= 1'b0; o_ov <= 1'b0; o_cy <= 1'b0;
    fp_pk <= '0; fp_ux <= '0; fp_uy <= '0; fp_rx <= '0; fp_ry <= '0;
    fp_kind <= 1'b0;
    fdiv_rem <= '0; fdiv_qacc <= '0; fdiv_den <= '0; fdiv_cnt <= '0;
    fdiv_sign <= 1'b0; fdiv_exp <= '0;
end
else if (ce) begin
    case (fst)
    F_IDLE: if (start) begin
        logic [31:0] r; logic [31:0] iv; logic ov;
        r = 32'd0; iv = 32'd0; ov = 1'b0;

    if (op == 8'h5f) begin
        if (subop == 5'h00) begin              // CVTWS int->float
            r = cvt_w_s(a);
            o_ov <= 1'b0;
            o_cy <= a[31] & (a != 32'd0);     // val < 0
            o_s  <= r[31];
            o_z  <= (a == 32'd0);                // val == 0 iff int == 0
            begin result <= r; writes <= 1'b1; fst <= F_DONE; end
        end
        else begin                                  // CVTSW float->int
            cvt_s_w(a, cw, iv, ov);
            o_s  <= iv[31];
            o_ov <= ov;
            o_z  <= (iv == 32'd0);
            begin result <= iv; writes <= 1'b1; fst <= F_DONE; end
        end
    end
    else begin                                       // 0x5c group
        case (subop)
        5'h00: begin                                 // CMPF: appf = f(op2)-f(op1)
            logic un;
            // MAME materializes the subtraction: same-signed infinities give
            // inf-inf = NaN, so they compare Z=0/S=0 like unordered operands.
            un = fp_isnan(a) | fp_isnan(b) |
                 (fp_isinf(a) & fp_isinf(b) & (a[31] == b[31]));
            o_z  <= un ? 1'b0 : fp_eq(b, a);
            o_s  <= un ? 1'b0 : fp_lt(b, a);
            o_ov <= 1'b0; o_cy <= 1'b0;
            begin writes <= 1'b0; fst <= F_DONE; end                             // no writeback
        end
        5'h08: begin r = a; begin result <= r; writes <= 1'b1; fst <= F_DONE; end end   // MOVFS (no flags)
        5'h09: begin                                 // NEGFS
            r = a ^ 32'h8000_0000;
            o_ov <= 1'b0;
            o_cy <= r[31] & !fp_isnan(r) & ((a & 32'h7fffffff) != 0);
            o_s  <= r[31];
            o_z  <= (a & 32'h7fffffff) == 0;
            begin result <= r; writes <= 1'b1; fst <= F_DONE; end
        end
        5'h0a: begin                                 // ABSFS
            logic neg;
            neg = a[31] & ((a & 32'h7fffffff) != 0) & !fp_isnan(a);
            r = neg ? (a ^ 32'h8000_0000) : a;
            o_ov <= 1'b0; o_cy <= 1'b0;
            o_s  <= r[31];
            o_z  <= (a & 32'h7fffffff) == 0;
            begin result <= r; writes <= 1'b1; fst <= F_DONE; end
        end
        5'h10: begin                                 // SCLFS: op1=int16 scale, op2=float
            r = fp_scale(b, $signed(a[15:0]));
            begin o_ov <= 1'b0; o_cy <= 1'b0; o_s <= r[31]; o_z <= (r == 32'd0); end begin result <= r; writes <= 1'b1; fst <= F_DONE; end
        end
        // ADDFS/SUBFS/MULFS unpack here; the arithmetic is in S_FP_EXEC2.
        5'h18: begin fp_rx <= b; fp_ry <= a;
                     fp_ux <= fp_unpack(b); fp_uy <= fp_unpack(a);
                     fp_kind <= 1'b0; fst <= F_EXEC2; end            // ADDFS
        5'h19: begin fp_rx <= b; fp_ry <= a ^ 32'h8000_0000;
                     fp_ux <= fp_unpack(b);
                     fp_uy <= fp_unpack(a ^ 32'h8000_0000);
                     fp_kind <= 1'b0; fst <= F_EXEC2; end            // SUBFS
        5'h1a: begin fp_rx <= b; fp_ry <= a;
                     fp_ux <= fp_unpack(b); fp_uy <= fp_unpack(a);
                     fp_kind <= 1'b1; fst <= F_EXEC2; end            // MULFS
        5'h1b: fp_div_start(b, a);             // DIVFS (iterative)
        default: begin writes <= 1'b0; fst <= F_DONE; end
        endcase
    end

    end

    // Second cycle of an add or a multiply. BOTH are still built here and one
    // is discarded - that is the next thing to fix, and the reason this split
    // is a separate commit from the optimisation.
    F_EXEC2: begin
        fp_pk <= fp_kind ? fp_mul(fp_rx, fp_ry, fp_ux, fp_uy)
                         : fp_add(fp_rx, fp_ry, fp_ux, fp_uy);
        fst <= F_PACK;
    end

    // Normalise, round, adjust the exponent, set flags.
    F_PACK: begin
        logic [31:0] rp;
        rp = fp_pk_result(fp_pk);
        o_ov <= 1'b0; o_cy <= 1'b0; o_s <= rp[31]; o_z <= (rp == 32'd0);
        result <= rp; writes <= 1'b1; fst <= F_DONE;
    end

    // FDIV restoring mantissa division: one quotient bit per enabled clock.
    F_DIV: begin
        logic [49:0] r2;
        logic ge;
        ge = (fdiv_rem >= {26'd0, fdiv_den});
        r2 = ge ? (fdiv_rem - {26'd0, fdiv_den}) : fdiv_rem;
        fdiv_qacc <= {fdiv_qacc[25:0], ge};
        if (fdiv_cnt == 6'd0) begin
            logic [31:0] q;
            q = fdiv_finish({fdiv_qacc[25:0], ge}, r2);   // r2 != 0 -> sticky
            result <= q;
            o_ov <= 1'b0; o_cy <= 1'b0;
            o_s  <= q[31];
            o_z  <= (q == 32'd0);
            begin writes <= 1'b1; fst <= F_DONE; end
        end
        else begin
            fdiv_rem  <= {r2[48:0], 1'b0};                // remainder << 1
            fdiv_cnt  <= fdiv_cnt - 6'd1;
        end
    end

    F_DONE: fst <= F_IDLE;
    default: fst <= F_IDLE;
    endcase
end
end

endmodule
