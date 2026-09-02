// SPDX-License-Identifier: GPL-3.0-or-later
//
// v60_alu against the expressions it replaces.
//
// THE REFERENCE HERE IS THE OLD CODE ITSELF, transcribed from v60.sv's arith
// arms as they stood at commit c9b0981, quirks included: the width-specific
// carry expressions, ADDC's res[8]/res[16], SUBC's 33-bit borrow (audit R20
// V60-16), NEG's `a != 0` carry, and logic ops taking RAW operands rather than
// size-extended ones. If the shared unit and the transcription disagree on any
// input, one of them is wrong and the test says which opcode and width.
//
// This is what makes the refactor safe to make at all: the 29-test V60 suite
// covers these opcodes but not densely, and a shared adder that is subtly wrong
// at one width would pass it and then corrupt a game months later.

`timescale 1ns/1ps

module tb_v60_alu;

    logic [7:0]  op;
    logic [1:0]  d;
    logic [31:0] a, b;
    logic        cy_in;

    logic [31:0] result;
    logic        cy, ov, z, s, writes, valid, cy_we;

    v60_alu dut (.op(op), .d(d), .a(a), .b(b), .cy_in(cy_in),
                 .result(result), .cy(cy), .ov(ov), .z(z), .s(s),
                 .writes(writes), .valid(valid), .cy_we(cy_we));

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

    // The op table, exactly the arms v60_alu claims.
    localparam int NOPS = 30;
    logic [7:0] optab [NOPS];
    initial begin
        optab[0]=8'h80; optab[1]=8'h82; optab[2]=8'h84;   // ADD
        optab[3]=8'h90; optab[4]=8'h92; optab[5]=8'h94;   // ADDC
        optab[6]=8'ha8; optab[7]=8'haa; optab[8]=8'hac;   // SUB
        optab[9]=8'hb8; optab[10]=8'hba; optab[11]=8'hbc; // CMP
        optab[12]=8'h98; optab[13]=8'h9a; optab[14]=8'h9c;// SUBC
        optab[15]=8'h38; optab[16]=8'h3a; optab[17]=8'h3c;// NOT
        optab[18]=8'h39; optab[19]=8'h3b; optab[20]=8'h3d;// NEG
        optab[21]=8'ha0; optab[22]=8'ha2; optab[23]=8'ha4;// AND
        optab[24]=8'h88; optab[25]=8'h8a; optab[26]=8'h8c;// OR
        optab[27]=8'hb0; optab[28]=8'hb2; optab[29]=8'hb4;// XOR
    end

    int checks = 0, fails = 0;
    int cover_op [NOPS];

    // The ORIGINAL expressions, transcribed.
    task automatic ref_model(output logic [31:0] r_res,
                             output logic r_cy, r_ov, r_z, r_s, r_wr, r_cywe);
        logic [32:0] wide;
        logic [31:0] res;
        begin
            r_cy = 1'b0; r_ov = 1'b0; r_wr = 1'b1; res = 32'd0; r_cywe = 1'b1;
            case (op)
            8'h80, 8'h82, 8'h84: begin // ADD
                wide = {1'b0, dimext(b,d)} + {1'b0, dimext(a,d)};
                res  = wide[31:0];
                r_cy = (d==2'd0) ? ((({1'b0,b[7:0]}+{1'b0,a[7:0]}) >> 8) != 0) :
                       (d==2'd1) ? ((({1'b0,b[15:0]}+{1'b0,a[15:0]}) >> 16) != 0) :
                       wide[32];
                r_ov = (d==2'd0) ? (~(b[7]^a[7]) & (b[7]^res[7])) :
                       (d==2'd1) ? (~(b[15]^a[15]) & (b[15]^res[15])) :
                                   (~(b[31]^a[31]) & (b[31]^res[31]));
            end
            8'h90, 8'h92, 8'h94: begin // ADDC
                wide = {1'b0, dimext(b,d)} + {1'b0, dimext(a,d)} + {32'b0, cy_in};
                res  = wide[31:0];
                r_cy = (d==2'd2) ? wide[32] : (d==2'd1) ? res[16] : res[8];
                r_ov = (d==2'd0) ? (~(b[7]^a[7]) & (b[7]^res[7])) :
                       (d==2'd1) ? (~(b[15]^a[15]) & (b[15]^res[15])) :
                                   (~(b[31]^a[31]) & (b[31]^res[31]));
            end
            8'ha8, 8'haa, 8'hac, 8'hb8, 8'hba, 8'hbc: begin // SUB / CMP
                res  = dimext(b,d) - dimext(a,d);
                r_cy = (dimext(b,d) < dimext(a,d));
                r_ov = (d==2'd0) ? ((b[7]^a[7]) & (b[7]^res[7])) :
                       (d==2'd1) ? ((b[15]^a[15]) & (b[15]^res[15])) :
                                   ((b[31]^a[31]) & (b[31]^res[31]));
                r_wr = !op[4];   // CMP does not store
            end
            8'h98, 8'h9a, 8'h9c: begin // SUBC
                res  = dimext(b,d) - dimext(a,d) - {31'b0, cy_in};
                r_cy = ({1'b0, dimext(b,d)} < ({1'b0, dimext(a,d)} + {32'b0, cy_in}));
                r_ov = (d==2'd0) ? ((b[7]^a[7]) & (b[7]^res[7])) :
                       (d==2'd1) ? ((b[15]^a[15]) & (b[15]^res[15])) :
                                   ((b[31]^a[31]) & (b[31]^res[31]));
            end
            8'h38, 8'h3a, 8'h3c: begin // NOT
                res = ~dimext(a,d); r_ov = 1'b0; r_cy = 1'b0;
            end
            8'h39, 8'h3b, 8'h3d: begin // NEG
                res  = 32'd0 - dimext(a,d);
                r_cy = (dimext(a,d) != 0);
                r_ov = sgn(a,d) & sgn(res,d);
            end
            // these three leave CY untouched in the original
            8'ha0, 8'ha2, 8'ha4: begin res = b & a; r_ov = 1'b0; r_cywe = 1'b0; end // AND
            8'h88, 8'h8a, 8'h8c: begin res = b | a; r_ov = 1'b0; r_cywe = 1'b0; end // OR
            8'hb0, 8'hb2, 8'hb4: begin res = b ^ a; r_ov = 1'b0; r_cywe = 1'b0; end // XOR
            default: ;
            endcase
            r_res = res;
            r_z   = zer(res, d);
            r_s   = sgn(res, d);
        end
    endtask

    logic [31:0] e_res; logic e_cy, e_ov, e_z, e_s, e_wr, e_cywe;

    // Operand pool that actually reaches the corners: zero, the width
    // boundaries, the signs, and random. A uniform 32-bit random almost never
    // produces a byte carry boundary, and the carry logic is the whole point.
    function automatic [31:0] pick(input int unsigned r);
        case (r % 12)
            0: pick = 32'h0000_0000;
            1: pick = 32'h0000_00ff;
            2: pick = 32'h0000_0080;
            3: pick = 32'h0000_007f;
            4: pick = 32'h0000_ffff;
            5: pick = 32'h0000_8000;
            6: pick = 32'hffff_ffff;
            7: pick = 32'h8000_0000;
            8: pick = 32'h7fff_ffff;
            9: pick = 32'h0000_0001;
           10: pick = {$random, $random};
            default: pick = $random;
        endcase
    endfunction

    initial begin
        for (int i = 0; i < NOPS; i++) cover_op[i] = 0;
        for (int i = 0; i < NOPS; i++) begin
            op = optab[i];
            for (int dd = 0; dd < 3; dd++) begin
                d = dd[1:0];
                for (int k = 0; k < 4000; k++) begin
                    a = pick(k);
                    b = pick(k/12 + k*7);
                    cy_in = k[0];
                    #1;
                    ref_model(e_res, e_cy, e_ov, e_z, e_s, e_wr, e_cywe);
                    #1;
                    checks++;
                    cover_op[i]++;
                    if (!valid) begin
                        fails++;
                        if (fails <= 20)
                            $display("FAIL op=%02x d=%0d: valid=0, unit does not claim it", op, dd);
                    end
                    else if (result !== e_res || ov !== e_ov || cy_we !== e_cywe ||
                             z !== e_z || s !== e_s || writes !== e_wr ||
                             (e_cywe && (cy !== e_cy))) begin
                        fails++;
                        if (fails <= 20)
                            $display("FAIL op=%02x d=%0d a=%08x b=%08x ci=%b | got res=%08x cy=%b ov=%b z=%b s=%b wr=%b | exp res=%08x cy=%b ov=%b z=%b s=%b wr=%b",
                                     op, dd, a, b, cy_in,
                                     result, cy, ov, z, s, writes,
                                     e_res, e_cy, e_ov, e_z, e_s, e_wr);
                    end
                end
            end
        end

        // An opcode the unit must NOT claim, so `valid` cannot be stuck high.
        op = 8'h5c; d = 2'd2; a = 32'h1234_5678; b = 32'h9abc_def0; #1;
        checks++;
        if (valid) begin
            fails++;
            $display("FAIL: valid asserted for unclaimed opcode 5c");
        end

        for (int i = 0; i < NOPS; i++)
            if (cover_op[i] == 0) begin
                fails++;
                $display("FAIL: opcode %02x never exercised", optab[i]);
            end

        $display("v60_alu: checks=%0d fails=%0d ops=%0d", checks, fails, NOPS);
        if (fails != 0) $fatal(1, "v60_alu MISMATCH");
        $finish;
    end

endmodule
