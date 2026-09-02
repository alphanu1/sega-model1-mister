// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA - Copyright (C) 2026 alphanu1
//
// DERIVED FROM SOMEONE ELSE'S WORK. The behaviour here was lifted out of
// v60.sv, imported from the Sega System 32 MiSTer core,
// https://github.com/meathax/s32, GPL-3.0-or-later. Moving code into a new file
// does not detach it from its licence. See the note at the top of v60.sv.
// Split out 2026-09-02.
//
// ---------------------------------------------------------------------------
// THE V60'S SHARED SHIFT/ROTATE UNIT: SHL, SHA and ROT, all widths.
//
// WHY. These lived in three separate case arms calling five helper functions,
// and a function is INLINED at every call site, so the helpers were not shared
// at all. Counting only the genuinely variable-amount 32-bit shifters - not the
// `1 << n` decoders or the 0-or-1 amounts that most of v60.sv's shifts turn out
// to be - the arms carried seven of them: shl_res two, sha_res two, rot_res two
// and sha_left_ov one. Only ONE of the three arms can execute in a given
// instruction, so muxing the operands into a single left/right pair costs three
// small muxes and saves five barrel shifters. shl_lastout was inlined FOUR
// times on top of that.
//
// This is the same argument as v60_alu's single adder, and the same one
// ea_index demonstrated in miniature: Quartus will not share logic across case
// arms it cannot prove exclusive, so the sharing has to be written down.
//
// THE EDGE CASES ARE THE WHOLE RISK. These helpers were audited and corrected
// once already (R20 V60-7): a zero count must CLEAR carry rather than leave it;
// a count greater than the operand width is undefined in MAME's own macro, so
// ours defines it; and count == width uses the full-width overflow mask. A
// shared shifter that is right for ordinary counts and wrong at those
// boundaries would pass the 29-test suite and corrupt a game much later, which
// is why tb_v60_shift sweeps every count from -40 to +40 exhaustively rather
// than sampling random 8-bit values.
//
// ROTC is NOT here: it rotates through carry iteratively over multiple cycles
// and belongs to the sequencer, not to a combinational datapath.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module v60_shift (
    input  logic [7:0]  op,       // cur_op
    input  logic [1:0]  d,        // 0=byte 1=halfword 2=word
    input  logic [31:0] val,      // value to shift  (exec_op's `b`)
    input  logic [7:0]  cnt,      // shift count, SIGNED (exec_op's `a[7:0]`)

    output logic [31:0] result,
    output logic        cy,
    output logic        ov,
    output logic        z,
    output logic        s,
    output logic        valid
);

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

    wire is_shl = (op==8'ha9) || (op==8'hab) || (op==8'had);
    wire is_sha = (op==8'hb9) || (op==8'hbb) || (op==8'hbd);
    wire is_rot = (op==8'h89) || (op==8'h8b) || (op==8'h8d);
    assign valid = is_shl || is_sha || is_rot;

    wire signed [7:0] c   = cnt;
    wire              left = (c >= 0);
    wire        [7:0] mag  = left ? cnt : (8'h00 - cnt);
    wire        [6:0] w    = (d==2'd0) ? 7'd8 : (d==2'd1) ? 7'd16 : 7'd32;

    // Zero- and sign-extended forms of the operand.
    //
    // THE SIGN FILL IS EXPLICIT, NOT INHERITED. `wire signed` plus `>>>` is not
    // enough: a concatenation is always unsigned in SystemVerilog, so
    // {{24{val[7]}}, val[7:0]} makes the whole ternary unsigned and the
    // arithmetic shift silently becomes a logical one. tb_v60_shift caught it
    // on the first run - SHA.B of 0xffffffff by -31 returned 1 instead of
    // 0xffffffff - and nothing in the 29-test suite would have.
    wire        sfill = sgn(val, d);
    wire [31:0] xz    = dimext(val, d);
    wire [31:0] xs    = (d==2'd0) ? {{24{val[7]}},  val[7:0]}
                      : (d==2'd1) ? {{16{val[15]}}, val[15:0]}
                      :             val;

    wire [31:0] mask  = (d==2'd0) ? 32'h0000_00ff : (d==2'd1) ? 32'h0000_ffff : 32'hffff_ffff;

    // ----- THE SHARED PAIR -----
    //
    // One left shifter and one right shifter serve all three opcodes. SHL takes
    // the zero-extended operand, SHA the sign-extended one with the sign
    // filling the vacated bits; that is a choice of input and fill, not a
    // second shifter. Amounts of 32 or more are handled explicitly because a
    // 5-bit shift amount would otherwise wrap and rotate.
    wire [5:0] sh = (mag >= 8'd32) ? 6'd32 : {1'b0, mag[4:0]};
    wire       big = (sh >= 6'd32);

    wire [31:0] shl_left  = big ? 32'd0 : (xz << sh[4:0]);
    wire [31:0] shl_right = big ? 32'd0 : (xz >> sh[4:0]);
    wire [31:0] sha_left  = big ? 32'd0 : (xs << sh[4:0]);
    // arithmetic right: logical shift, then paint the vacated top bits with the
    // sign. `32'hffffffff >> 0` is all ones so the mask is empty at zero shift.
    wire [31:0] sha_right = big ? {32{sfill}}
                          : ((xs >> sh[4:0]) |
                             (sfill ? ~(32'hffff_ffff >> sh[4:0]) : 32'd0));

    // rotate distance, reduced modulo the width, exactly as rot_res does
    wire [5:0] rot_sh  = (d==2'd0) ? {3'b0, mag[2:0]}
                       : (d==2'd1) ? {2'b0, mag[3:0]}
                       :             {1'b0, mag[4:0]};
    wire [5:0] rot_amt = left ? rot_sh : (w[5:0] - rot_sh);

    wire [31:0] rot_r = (rot_sh == 0) ? (xz & mask)
                      : (((xz << rot_amt) | (xz >> (w[5:0] - rot_amt))) & mask);

    wire [31:0] shl_r = left ? shl_left : shl_right;
    wire [31:0] sha_r = left ? sha_left : sha_right;

    always_comb begin
        if (is_sha)      result = sha_r;
        else if (is_rot) result = rot_r;
        else             result = shl_r;
    end

    // ----- carry -----
    //
    // SHL and SHA: the last bit shifted out, which shl_lastout expressed as a
    // variable bit select - x[w-n] going left, x[n-1] going right, and 0 when
    // the count runs past the operand. ROT: the wrap bit after the rotate.
    // All three clear carry on a zero count (audit R20 V60-7).
    logic lastout;
    always_comb begin
        lastout = 1'b0;
        if (mag != 0) begin
            if (left)  lastout = (mag <= {1'b0, w}) ? xz[6'(w - {1'b0, mag[5:0]})] : 1'b0;
            else       lastout = (mag <= 8'd32)     ? xz[5'(mag - 8'd1)]           : 1'b0;
        end
    end

    always_comb begin
        if (mag == 0)         cy = 1'b0;
        else if (is_rot)      cy = left ? result[0] : sgn(result, d);
        else                  cy = lastout;
    end

    // ----- overflow: only SHA defines it, and only shifting left -----
    // Computed unconditionally so no path leaves them unassigned - a latch here
    // passed my own first lint and would have been a real one, not a warning.
    // SIX-BIT, because mag can legitimately equal 32 and mag[4:0] would make
    // that 0. The original leant on 32-bit wraparound - `32'd1 << 32` is 0, so
    // minus one gives 0xffffffff, the full-width mask - which is MAME's
    // count == bitsize case. Truncating to five bits produced an empty mask and
    // OV=0 where the reference gives OV=1; tb_v60_shift caught it at cnt=32.
    wire [5:0]  ovn      = (mag >= 8'd32) ? 6'd32 : {1'b0, mag[4:0]};
    wire [31:0] ov_ones  = (ovn >= 6'd32) ? 32'hffff_ffff
                                          : ((32'd1 << ovn[4:0]) - 32'd1);
    wire [5:0]  ovsh     = w[5:0] - ovn;
    wire [31:0] ov_field = ((ovsh >= 6'd32) ? 32'd0 : (xz >> ovsh[4:0])) & ov_ones;

    always_comb begin
        ov = 1'b0;
        if (is_sha) begin
            if (!left || mag == 0)      ov = 1'b0;
            else if (mag > {1'b0, w})   ov = (xz != 32'd0);
            else ov = sgn(val, d) ? (ov_field != ov_ones) : (ov_field != 32'd0);
        end
    end

    assign z = zer(result, d);
    assign s = sgn(result, d);

endmodule
