// SPDX-License-Identifier: GPL-3.0-or-later
//
// v60_shift against the five helper functions it replaces.
//
// THE REFERENCE IS THE OLD CODE, transcribed from v60.sv's shl_res, sha_res,
// shl_lastout, sha_left_ov and rot_res as they stood at b70c3ef, together with
// the three arms that called them.
//
// COUNTS ARE SWEPT EXHAUSTIVELY FROM -128 TO +127, not sampled. These helpers
// were audited and corrected once already (R20 V60-7) and every correction was
// at a boundary: a zero count must CLEAR carry rather than leave it; a count
// greater than the operand width is undefined in MAME's own macro so ours
// defines it; count == width uses the full-width overflow mask (SHA.B #8,-1
// gives OV=0). A shared shifter that is right for ordinary counts and wrong at
// those boundaries passes the 29-test suite and corrupts a game months later,
// so the bench must reach every one of them by construction.

`timescale 1ns/1ps

module tb_v60_shift;

    logic [7:0]  op;
    logic [1:0]  d;
    logic [31:0] val;
    logic [7:0]  cnt;
    logic [31:0] result;
    logic        cy, ov, z, s, valid;

    v60_shift dut (.op(op), .d(d), .val(val), .cnt(cnt),
                   .result(result), .cy(cy), .ov(ov), .z(z), .s(s), .valid(valid));

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

    // ---- the originals ----
    function automatic [31:0] r_shl(input [31:0] v, input [7:0] c8, input [1:0] dd);
        logic signed [7:0] c; logic [31:0] x;
        c = c8; x = dimext(v, dd);
        if (c >= 0) x = x << $unsigned(c);
        else        x = x >> $unsigned(-c);
        r_shl = x;
    endfunction

    function automatic [31:0] r_sha(input [31:0] v, input [7:0] c8, input [1:0] dd);
        logic signed [7:0] c; logic signed [31:0] x;
        c = c8;
        x = (dd==2'd0) ? {{24{v[7]}},v[7:0]} : (dd==2'd1) ? {{16{v[15]}},v[15:0]} : v;
        if (c >= 0) x = x <<< $unsigned(c);
        else        x = x >>> $unsigned(-c);
        r_sha = x;
    endfunction

    function automatic r_lastout(input [31:0] v, input [7:0] n, input [1:0] dd, input lft);
        logic [31:0] x; int w;
        x = dimext(v, dd);
        w = (dd==2'd0) ? 8 : (dd==2'd1) ? 16 : 32;
        if (n == 0) r_lastout = 1'b0;
        else if (lft) r_lastout = (n <= w) ? x[w - n] : 1'b0;
        else          r_lastout = (n <= 32) ? x[n - 1] : 1'b0;
    endfunction

    function automatic r_sha_ov(input [31:0] v, input [7:0] c8, input [1:0] dd);
        logic signed [7:0] c; integer w; logic [31:0] field, ones;
        c = c8;
        w = (dd==2'd0) ? 8 : (dd==2'd1) ? 16 : 32;
        if (c <= 0)     r_sha_ov = 1'b0;
        else if (c > w) r_sha_ov = (dimext(v,dd) != 0);
        else begin
            field = (dimext(v,dd) >> $unsigned(w - c)) & ((32'd1 << $unsigned(c)) - 1);
            ones  = (32'd1 << $unsigned(c)) - 1;
            r_sha_ov = sgn(v,dd) ? (field != ones) : (field != 32'd0);
        end
    endfunction

    function automatic [31:0] r_rot(input [31:0] v, input [7:0] c8, input [1:0] dd);
        logic signed [7:0] c; logic [31:0] x; logic [7:0] mg;
        logic [5:0] sh, w; logic [31:0] mask; logic [5:0] l;
        c = c8; x = dimext(v, dd);
        mg = c[7] ? (8'h00 - c8) : c8;
        case (dd)
            2'd0: begin w = 6'd8;  sh = {3'b0, mg[2:0]}; mask = 32'h0000_00ff; end
            2'd1: begin w = 6'd16; sh = {2'b0, mg[3:0]}; mask = 32'h0000_ffff; end
            default: begin w = 6'd32; sh = {1'b0, mg[4:0]}; mask = 32'hffff_ffff; end
        endcase
        if (sh == 0) r_rot = x & mask;
        else begin
            l = c[7] ? (w - sh) : sh;
            r_rot = ((x << l) | (x >> (w - l))) & mask;
        end
    endfunction

    task automatic ref_model(output logic [31:0] r_res, output logic e_cy, e_ov, e_z, e_s);
        logic signed [7:0] c;
        begin
            c = cnt; e_cy = 1'b0; e_ov = 1'b0; r_res = 32'd0;
            if (op==8'ha9 || op==8'hab || op==8'had) begin        // SHL
                r_res = r_shl(val, cnt, d);
                if (c > 0)      e_cy = r_lastout(val, cnt, d, 1'b1);
                else if (c < 0) e_cy = r_lastout(val, (8'h00-cnt), d, 1'b0);
                else            e_cy = 1'b0;
                e_ov = 1'b0;
            end
            else if (op==8'hb9 || op==8'hbb || op==8'hbd) begin   // SHA
                r_res = r_sha(val, cnt, d);
                if (c > 0)      e_cy = r_lastout(val, cnt, d, 1'b1);
                else if (c < 0) e_cy = r_lastout(val, (8'h00-cnt), d, 1'b0);
                else            e_cy = 1'b0;
                e_ov = r_sha_ov(val, cnt, d);
            end
            else begin                                            // ROT
                r_res = r_rot(val, cnt, d);
                if (c > 0)      e_cy = r_res[0];
                else if (c < 0) e_cy = sgn(r_res, d);
                else            e_cy = 1'b0;
                e_ov = 1'b0;
            end
            e_z = zer(r_res, d);
            e_s = sgn(r_res, d);
        end
    endtask

    localparam int NOPS = 9;
    logic [7:0] optab [NOPS];
    initial begin
        optab[0]=8'ha9; optab[1]=8'hab; optab[2]=8'had;  // SHL
        optab[3]=8'hb9; optab[4]=8'hbb; optab[5]=8'hbd;  // SHA
        optab[6]=8'h89; optab[7]=8'h8b; optab[8]=8'h8d;  // ROT
    end

    function automatic [31:0] pick(input int unsigned r);
        case (r % 10)
            0: pick = 32'h0000_0000;
            1: pick = 32'hffff_ffff;
            2: pick = 32'h8000_0000;
            3: pick = 32'h0000_0080;
            4: pick = 32'h0000_8000;
            5: pick = 32'h7fff_ffff;
            6: pick = 32'h0000_0001;
            7: pick = 32'hAAAA_AAAA;
            8: pick = 32'h5555_5555;
            default: pick = {$random};
        endcase
    endfunction

    int checks = 0, fails = 0;
    logic [31:0] e_res; logic e_cy, e_ov, e_z, e_s;

    initial begin
        for (int i = 0; i < NOPS; i++) begin
            op = optab[i];
            for (int dd = 0; dd < 3; dd++) begin
                d = dd[1:0];
                // EVERY count, not a sample. -128..127 covers zero, 1, the
                // width, width+1 and the far out-of-range cases in one sweep.
                for (int n = -128; n <= 127; n++) begin
                    cnt = n[7:0];
                    for (int k = 0; k < 10; k++) begin
                        val = pick(k);
                        #1;
                        ref_model(e_res, e_cy, e_ov, e_z, e_s);
                        #1;
                        checks++;
                        if (!valid) begin
                            fails++;
                            if (fails <= 20) $display("FAIL op=%02x: valid=0", op);
                        end
                        else if (result !== e_res || cy !== e_cy || ov !== e_ov ||
                                 z !== e_z || s !== e_s) begin
                            fails++;
                            if (fails <= 20)
                                $display("FAIL op=%02x d=%0d val=%08x cnt=%0d | got %08x cy=%b ov=%b z=%b s=%b | exp %08x cy=%b ov=%b z=%b s=%b",
                                         op, dd, val, $signed(cnt),
                                         result, cy, ov, z, s, e_res, e_cy, e_ov, e_z, e_s);
                        end
                    end
                end
            end
        end

        op = 8'h5c; d = 2'd2; val = 32'h1234_5678; cnt = 8'd4; #1;
        checks++;
        if (valid) begin fails++; $display("FAIL: valid high for unclaimed opcode 5c"); end

        $display("v60_shift: checks=%0d fails=%0d ops=%0d", checks, fails, NOPS);
        if (fails != 0) $fatal(1, "v60_shift MISMATCH");
        $finish;
    end

endmodule
