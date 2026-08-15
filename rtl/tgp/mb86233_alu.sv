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
// Behaviour transcribed from MAME's MB86233 device model:
//
//   src/devices/cpu/mb86233/mb86233.cpp   (alu_pre / alu_post_1 / alu_post_2)
//   SPDX-License-Identifier: BSD-3-Clause
//   Copyright-holders: Olivier Galibert
//
// That BSD-3-Clause attribution must be retained. See THIRD-PARTY.md.
//
// Fujitsu MB86233 "TGP" — ALU
//
// One FP multiplier and one FP adder, live in the same cycle. That structure
// is not a choice: ops 0x09/0x0a/0x0d specify `A*B -> P` concurrent with
// `D +/- P -> D`, so both units must exist and both must run together.
//
// Uniform latency 5: the FP units are 4, plus one for the registered operand
// mux in front of them. Integer results are computed combinationally and pushed
// through five stages to line up, so the consumer sees one timing regardless of op.
// The depth is not free to choose: it must equal the FP units' latency exactly,
// or FP and non-FP results retire on different cycles. The TGP retires ~5.3 M instructions/sec
// against a 50 MHz fabric clock; spending two cycles everywhere costs nothing
// and removes a whole class of alignment bug.
//
// fdvd (0x10) breaks the uniform latency. fp_mul and fp_add are fixed-latency-2
// and everything else is pushed through two stages to line up with them, but a
// radix-2 divider is 29 cycles. Rather than pipeline the divider — far more area
// than one opcode is worth — the ALU asserts `busy` and the caller waits.
//
// The divide runs beside the normal pipeline: its result is latched with the ST
// captured at issue, and the ordinary two-stage path is suppressed for this op
// so it cannot retire the instruction early with a stale result.

`timescale 1ns/1ps

module mb86233_alu #(
  parameter bit FLUSH_DENORM_IN = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        in_valid,
  input  logic [4:0]  op,

  input  logic [31:0] reg_a,
  input  logic [31:0] reg_b,
  input  logic [31:0] reg_d,
  input  logic [31:0] reg_p,
  input  logic [7:0]  sft,      // SFT is a u8 in MAME; only [4:0] are used
  input  logic [15:0] m,        // cfxd rounding mode lives in M[2:1]
  input  logic [31:0] st_in,

  // A transfer targeting D issued in the same instruction. The write-priority
  // quirk is resolved here rather than left to the caller.
  input  logic        xfer_d_valid,
  input  logic [31:0] xfer_d_data,

  // Whether this instruction reaches alu_post_2, the floating-point post path.
  // MAME's case 0x0f (rep/clr0/clr1/set) calls alu_pre and alu_post_1 and then
  // STOPS — it never calls alu_post_2 — so an FP op encoded there computes its
  // result and discards it. Types 0x00 and 0x07 do call it. Applying the FP
  // writeback unconditionally makes every FP op in the 0x0f group write D or P
  // when the hardware does not.
  input  logic        fp_post_en,

  output logic        out_valid,
  output logic [31:0] d_out,
  output logic        d_we,
  output logic [31:0] p_out,
  output logic        p_we,
  output logic [31:0] st_out,
  output logic        extra_cycle,     // this op burns one more cycle
  output logic        busy             // a divide is in flight; hold the caller
);

  // ==================================================================
  // Stage 0 — decode and operand routing
  // ==================================================================

  // fp_add operand mux. Every FP add/sub form in the table reduces to one of
  // three operand pairs, and the subtract flag carries the rest.
  logic [31:0] add_a, add_b;
  logic        add_sub;

  always_comb begin
    unique case (op)
      mb86233_pkg::ALU_FCPD: begin add_a = reg_d; add_b = reg_a; add_sub = 1'b1; end
      mb86233_pkg::ALU_FADD: begin add_a = reg_d; add_b = reg_a; add_sub = 1'b0; end
      mb86233_pkg::ALU_FSBD: begin add_a = reg_d; add_b = reg_a; add_sub = 1'b1; end
      mb86233_pkg::ALU_FMSD: begin add_a = reg_d; add_b = reg_p; add_sub = 1'b0; end
      mb86233_pkg::ALU_FMRD: begin add_a = reg_d; add_b = reg_p; add_sub = 1'b1; end
      mb86233_pkg::ALU_FSMD: begin add_a = reg_d; add_b = reg_p; add_sub = 1'b0; end
      mb86233_pkg::ALU_BAPA: begin add_a = reg_b; add_b = reg_a; add_sub = 1'b0; end
      mb86233_pkg::ALU_BSPA: begin add_a = reg_b; add_b = reg_a; add_sub = 1'b1; end
      default:  begin add_a = reg_d; add_b = reg_a; add_sub = 1'b0; end
    endcase
  end

  // The operand mux is REGISTERED before the FP units. It selects fp_add's
  // inputs from the ALU op, and leaving it combinational put it in front of
  // fp_add's align stage — measured as
  //   From alu_op_r[4]  To fp_add|sA_sticky
  // holding the core to 69 MHz once the FP units themselves were retimed.
  //
  // This costs one more cycle of ALU latency, which is why ALU_LAT is 5 while
  // the FP units are 4.
  logic [31:0] opr_add_a, opr_add_b, opr_mul_a, opr_mul_b;
  logic        opr_sub, opr_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) opr_valid <= 1'b0;
    else begin
      opr_valid <= in_valid;
      opr_add_a <= add_a;  opr_add_b <= add_b;  opr_sub <= add_sub;
      opr_mul_a <= reg_a;  opr_mul_b <= reg_b;
    end
  end

  // The multiplier only ever computes A*B. No mux needed.
  logic [31:0] mul_result, add_result;

  // ------------------------------------------------------------- divider

  logic        div_start, div_busy_i, div_done;
  logic [31:0] div_result;
  logic        div_ovf, div_unf, div_dvz, div_inv;

  logic        div_inflight;
  logic [31:0] div_st_hold;      // ST as it was when the divide was issued

  // Numerator is D, denominator is A: MAME evaluates f2u(u2f(m_d) / u2f(m_a)).
  fp_div #(.FLUSH_DENORM_IN(FLUSH_DENORM_IN)) u_div (
    .clk(clk), .rst_n(rst_n),
    .in_valid(div_start), .a(reg_d), .b(reg_a),
    .busy(div_busy_i), .out_valid(div_done), .result(div_result),
    .overflow(div_ovf), .underflow(div_unf),
    .div_by_zero(div_dvz), .invalid(div_inv)
  );

  assign div_start = in_valid & (op == mb86233_pkg::ALU_FDVD) & ~div_inflight & ~div_busy_i;
  assign busy      = div_inflight | div_busy_i;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_inflight <= 1'b0;
      div_st_hold  <= 32'd0;
    end else begin
      if (div_start) begin
        div_inflight <= 1'b1;
        div_st_hold  <= st_in;
      end else if (div_done) begin
        div_inflight <= 1'b0;
      end
    end
  end

  // Deliberately unused. MAME's flag model never sets OVD, UND or DVZD from
  // anywhere: alu_pre puts them in the clear-mask and stset_set_sz_* only ever
  // sets ZRD or SGD. So the FP units' exception outputs have no architectural
  // destination. Named rather than left empty so that stays visible.
  logic mul_ovalid, mul_ovf, mul_unf, mul_inv;
  logic add_ovalid, add_ovf, add_unf, add_inv;

  fp_mul #(.FLUSH_DENORM_IN(FLUSH_DENORM_IN)) u_mul (
    .clk(clk), .rst_n(rst_n),
    .in_valid(opr_valid), .a(opr_mul_a), .b(opr_mul_b),
    .out_valid(mul_ovalid), .result(mul_result),
    .overflow(mul_ovf), .underflow(mul_unf), .invalid(mul_inv)
  );

  fp_add #(.FLUSH_DENORM_IN(FLUSH_DENORM_IN)) u_add (
    .clk(clk), .rst_n(rst_n),
    .in_valid(opr_valid), .a(opr_add_a), .b(opr_add_b), .sub(opr_sub),
    .out_valid(add_ovalid), .result(add_result),
    .overflow(add_ovf), .underflow(add_unf), .invalid(add_inv)
  );

  // ------------------------------------------------------------------
  // cxfd — float(int32(D))
  // ------------------------------------------------------------------

  logic [31:0] cxf_mag;
  logic        cxf_sign;

  // Negating 0x80000000 in 32 bits yields 0x80000000, which is the correct
  // magnitude 2^31. No special case needed.
  assign cxf_sign = reg_d[31];
  assign cxf_mag  = reg_d[31] ? (~reg_d + 32'd1) : reg_d;

  logic [5:0] cxf_lzc;
  always_comb begin
    cxf_lzc = 6'd32;
    for (int i = 0; i < 32; i++)
      if (cxf_mag[i]) cxf_lzc = 6'(31 - i);
  end

  logic [31:0] cxf_norm;
  logic [7:0]  cxf_exp;
  logic [22:0] cxf_frac;
  logic        cxf_g, cxf_s, cxf_up;
  logic [23:0] cxf_frac_rnd;
  logic [31:0] cxf_result;

  always_comb begin
    // Leading one to bit 31, so the fraction lands at [30:8].
    cxf_norm = cxf_mag << cxf_lzc;
    cxf_exp  = 8'd127 + 8'd31 - 8'(cxf_lzc);
    cxf_frac = cxf_norm[30:8];
    cxf_g    = cxf_norm[7];
    cxf_s    = |cxf_norm[6:0];
    // Round to nearest, ties to even — the host FPU default that MAME's
    // f2u(s32) inherits.
    cxf_up       = cxf_g & (cxf_s | cxf_frac[0]);
    cxf_frac_rnd = {1'b0, cxf_frac} + {23'd0, cxf_up};

    if (cxf_mag == 32'd0)
      cxf_result = 32'd0;                       // float(0) is +0, never -0
    else if (cxf_frac_rnd[23])
      cxf_result = {cxf_sign, cxf_exp + 8'd1, 23'd0};
    else
      cxf_result = {cxf_sign, cxf_exp, cxf_frac_rnd[22:0]};
  end

  // ------------------------------------------------------------------
  // cfxd — int32(D), rounding per M[2:1]
  // ------------------------------------------------------------------
  //
  // Modes are MAME's, and mode 0 is C's roundf: half away from zero, NOT the
  // half-to-even the FP units use for their own rounding. Getting these two
  // confused is the obvious way to be off by one ULP on .5 boundaries.
  //
  //   0 roundf   1 ceilf   2 floorf   3 C cast (truncate toward zero)

  logic [1:0]  cfx_mode;
  logic        cfx_sign;
  logic [7:0]  cfx_exp;
  logic [23:0] cfx_sig;
  logic signed [9:0] cfx_e;

  assign cfx_mode = m[2:1];
  assign cfx_sign = reg_d[31];
  assign cfx_exp  = reg_d[30:23];
  assign cfx_sig  = {1'b1, reg_d[22:0]};
  assign cfx_e    = $signed({2'b00, cfx_exp}) - 10'sd127;

  // Q32.32: q = sig << (e + 9) puts the integer part in q[63:32] and the
  // fraction in q[31:0]. e+9 spans 0..40 for every input that can produce an
  // in-range int32, so one 64-bit left shift covers the whole domain.
  logic signed [9:0] cfx_shl;
  logic [63:0]       cfx_q;
  logic              cfx_tiny;      // |D| < 2^-9: integer part 0, fraction set

  assign cfx_shl  = cfx_e + 10'sd9;
  assign cfx_tiny = (cfx_shl < 10'sd0);

  always_comb begin
    if (cfx_tiny) cfx_q = 64'd0;
    else          cfx_q = {40'd0, cfx_sig} << cfx_shl[5:0];
  end

  logic [31:0] cfx_int;
  logic        cfx_half, cfx_freq;

  assign cfx_int  = cfx_q[63:32];
  assign cfx_half = cfx_q[31];                       // fraction >= 0.5
  assign cfx_freq = (|cfx_q[31:0]) | cfx_tiny;       // fraction != 0

  logic cfx_bump;
  always_comb begin
    unique case (cfx_mode)
      2'd0: cfx_bump = cfx_half;                     // half away from zero
      2'd1: cfx_bump = cfx_freq & ~cfx_sign;         // ceil: up only if +ve
      2'd2: cfx_bump = cfx_freq &  cfx_sign;         // floor: away only if -ve
      2'd3: cfx_bump = 1'b0;                         // truncate toward zero
    endcase
  end

  logic [31:0] cfx_mag, cfx_result;
  assign cfx_mag = cfx_int + {31'd0, cfx_bump};

  // exp==0 covers zero and denormals. Denormals are out of scope for the same
  // reason they are in fp_add/fp_mul, and are skipped by the harness.
  always_comb begin
    if (cfx_exp == 8'd0) cfx_result = 32'd0;
    else                 cfx_result = cfx_sign ? (~cfx_mag + 32'd1) : cfx_mag;
  end

  // ------------------------------------------------------------------
  // integer / logical / shift
  // ------------------------------------------------------------------
  //
  // SFT is a u8 but MAME evaluates `m_d >> m_sft` directly, which is undefined
  // in C++ above 31 and masks to 5 bits on x86. Model the x86 behaviour; the
  // harness constrains SFT to 0-31 rather than chase undefined behaviour.
  logic [4:0] shamt;
  assign shamt = sft[4:0];

  logic [31:0] int_result;
  always_comb begin
    unique case (op)
      mb86233_pkg::ALU_ANDD: int_result = reg_d & reg_a;
      mb86233_pkg::ALU_ORAD: int_result = reg_d | reg_a;
      mb86233_pkg::ALU_EORD: int_result = reg_d ^ reg_a;
      mb86233_pkg::ALU_NOTD: int_result = ~reg_d;
      mb86233_pkg::ALU_ADDD: int_result = reg_d + reg_a;
      mb86233_pkg::ALU_SUBD: int_result = reg_d - reg_a;
      mb86233_pkg::ALU_LSRD: int_result = reg_d >> shamt;
      // asld and lsld are the same operation on the bit pattern. MAME keeps
      // them as separate cases computing identical expressions; so do we.
      mb86233_pkg::ALU_LSLD: int_result = reg_d << shamt;
      mb86233_pkg::ALU_ASLD: int_result = reg_d << shamt;
      mb86233_pkg::ALU_ASRD: int_result = 32'($signed(reg_d) >>> shamt);
      mb86233_pkg::ALU_CXFD: int_result = cxf_result;
      mb86233_pkg::ALU_CFXD: int_result = cfx_result;
      default:  int_result = 32'd0;
    endcase
  end

  // Results that need no arithmetic unit at all.
  logic [31:0] bit_result;
  always_comb begin
    unique case (op)
      mb86233_pkg::ALU_FABD: bit_result = reg_d & 32'h7fffffff;
      // fned leaves +0 alone rather than producing -0: MAME writes
      // `m_d ? m_d ^ 0x80000000 : 0`, so the test is on the whole word.
      mb86233_pkg::ALU_FNED: bit_result = (reg_d != 32'd0) ? (reg_d ^ 32'h80000000) : 32'd0;
      mb86233_pkg::ALU_FSPD: bit_result = reg_p;
      default:  bit_result = 32'd0;
    endcase
  end

  // Which source supplies r1 (the D-bound result) for this op.
  typedef enum logic [1:0] { SRC_INT, SRC_BIT, SRC_ADD, SRC_NONE } r1_src_e;
  r1_src_e r1_src;

  always_comb begin
    unique case (op)
      mb86233_pkg::ALU_FCPD, mb86233_pkg::ALU_FADD, mb86233_pkg::ALU_FSBD,
      mb86233_pkg::ALU_FMSD, mb86233_pkg::ALU_FMRD, mb86233_pkg::ALU_FSMD,
      mb86233_pkg::ALU_BAPA, mb86233_pkg::ALU_BSPA:            r1_src = SRC_ADD;
      mb86233_pkg::ALU_FABD, mb86233_pkg::ALU_FNED, mb86233_pkg::ALU_FSPD:  r1_src = SRC_BIT;
      mb86233_pkg::ALU_ANDD, mb86233_pkg::ALU_ORAD, mb86233_pkg::ALU_EORD, mb86233_pkg::ALU_NOTD,
      mb86233_pkg::ALU_ADDD, mb86233_pkg::ALU_SUBD,
      mb86233_pkg::ALU_LSRD, mb86233_pkg::ALU_LSLD, mb86233_pkg::ALU_ASRD, mb86233_pkg::ALU_ASLD,
      mb86233_pkg::ALU_CXFD, mb86233_pkg::ALU_CFXD:            r1_src = SRC_INT;
      default:                       r1_src = SRC_NONE;
    endcase
  end

  // ==================================================================
  // Stages 1-2 — align the non-FP paths with fp_add/fp_mul latency
  // ==================================================================

  // A four-deep shift of everything the final stage needs. Written as arrays so
  // the depth is one constant rather than a chain of hand-written stages that
  // must all be edited together if the FP latency changes again.
  // 4 for the FP units plus 1 for the registered operand mux above.
  localparam int ALU_LAT = 5;

  logic        pv   [1:ALU_LAT];
  logic [4:0]  pop  [1:ALU_LAT];
  logic [31:0] pint [1:ALU_LAT];
  logic [31:0] pbit [1:ALU_LAT];
  logic [31:0] pst  [1:ALU_LAT];
  logic        pxv  [1:ALU_LAT];
  logic [31:0] pxd  [1:ALU_LAT];
  r1_src_e     psrc [1:ALU_LAT];

  integer pi;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (pi = 1; pi <= ALU_LAT; pi = pi + 1) pv[pi] <= 1'b0;
    end else begin
      pv[1] <= in_valid;   pop[1]  <= op;
      pint[1] <= int_result; pbit[1] <= bit_result;
      pst[1] <= st_in;     psrc[1] <= r1_src;
      pxv[1] <= xfer_d_valid; pxd[1] <= xfer_d_data;
      for (pi = 2; pi <= ALU_LAT; pi = pi + 1) begin
        pv[pi]   <= pv[pi-1];   pop[pi]  <= pop[pi-1];
        pint[pi] <= pint[pi-1]; pbit[pi] <= pbit[pi-1];
        pst[pi]  <= pst[pi-1];  psrc[pi] <= psrc[pi-1];
        pxv[pi]  <= pxv[pi-1];  pxd[pi]  <= pxd[pi-1];
      end
    end
  end

  // The final stage reads the deepest entry; the names below are unchanged so
  // the rest of the module did not have to move.
  logic        s2_valid, s2_xv;
  logic [4:0]  s2_op;
  logic [31:0] s2_int, s2_bit, s2_st, s2_xd;
  r1_src_e     s2_src;

  assign s2_valid = pv[ALU_LAT];   assign s2_op  = pop[ALU_LAT];
  assign s2_int   = pint[ALU_LAT]; assign s2_bit = pbit[ALU_LAT];
  assign s2_st    = pst[ALU_LAT];  assign s2_src = psrc[ALU_LAT];
  assign s2_xv    = pxv[ALU_LAT];  assign s2_xd  = pxd[ALU_LAT];

  // ==================================================================
  // Stage 2 — result select, flags, write arbitration
  // ==================================================================

  logic [31:0] r1;
  always_comb begin
    unique case (s2_src)
      SRC_ADD:  r1 = add_result;
      SRC_BIT:  r1 = s2_bit;
      SRC_INT:  r1 = s2_int;
      SRC_NONE: r1 = 32'd0;
    endcase
  end

  // Flags. Only ZRD and SGD are ever set; CPD/OVD/DVZD sit in the mask so they
  // are cleared and never restored. stset_set_sz_int and _fp differ only in
  // whether the sign bit alone counts as nonzero.
  // Divide result flags. Computed from the ST captured when the divide was
  // issued, not the current one: ST can move on during the ~29 cycles it runs.
  // fdvd is an FP op, so this is stset_set_sz_fp.
  logic        div_flag_zero;
  logic [31:0] div_st_set, div_st_next;
  always_comb begin
    div_flag_zero = ((div_result & 32'h7fffffff) == 32'd0);
    if (div_flag_zero)       div_st_set = 32'd1 << mb86233_pkg::F_ZRD;
    else if (div_result[31]) div_st_set = 32'd1 << mb86233_pkg::F_SGD;
    else                     div_st_set = 32'd0;
    div_st_next = (div_st_hold
                   & ~mb86233_pkg::alu_st_mask(mb86233_pkg::ALU_FDVD))
                | div_st_set;
  end

  logic        flag_zero;
  logic [31:0] st_set, st_mask, st_next;

  always_comb begin
    if (mb86233_pkg::alu_flags_int(s2_op)) flag_zero = (r1 == 32'd0);
    else                      flag_zero = ((r1 & 32'h7fffffff) == 32'd0);

    // Both the mask and the set value must be suppressed for ops that never
    // reach alu_update_st. Gating only the mask still ORs ZRD in — a zeroed r1
    // reads as "result was zero" — so nop, fml and every undecoded opcode
    // would set ZRD on an instruction MAME leaves ST completely alone for.
    if (!mb86233_pkg::alu_touches_st(s2_op)) st_set = 32'd0;
    else if (flag_zero)         st_set = 32'd1 << mb86233_pkg::F_ZRD;
    else if (r1[31])            st_set = 32'd1 << mb86233_pkg::F_SGD;
    else                        st_set = 32'd0;

    st_mask = mb86233_pkg::alu_st_mask(s2_op);
    st_next = (s2_st & ~st_mask) | st_set;
  end

  // Write-priority arbitration, from MAME's own comment: with two writes to
  // one register in a single instruction, transfers beat integer ops but FP
  // ops beat transfers. Attributed to the FP ALU taking more than one cycle.
  // Software depends on it; do not simplify it into a single priority.
  logic alu_d_fp, alu_d_int, alu_d_any;
  assign alu_d_fp  = mb86233_pkg::alu_is_fp_d(s2_op);
  assign alu_d_int = mb86233_pkg::alu_is_int_d(s2_op);
  assign alu_d_any = alu_d_fp | alu_d_int;

  logic fdvd;
  assign fdvd = (s2_op == mb86233_pkg::ALU_FDVD);

  always_comb begin
    // The divide retires on its own completion, not on the pipeline. While it
    // is in flight the normal path must not write D at all.
    if (div_done) begin
      d_out = div_result;
      d_we  = fp_post_en;                  // FP result beats a transfer
    end else if (fdvd) begin
      d_out = s2_xd;
      d_we  = 1'b0;                        // suppressed until the divide lands
    end else if (alu_d_fp) begin
      d_out = r1;                          // FP beats a concurrent transfer
      d_we  = s2_valid & fp_post_en;
    end else if (s2_xv) begin
      d_out = s2_xd;                       // transfer beats an integer op
      d_we  = s2_valid;
    end else begin
      d_out = r1;
      d_we  = s2_valid & alu_d_any;
    end
  end

  assign p_out       = mul_result;
  // No P writes while a divide is in flight: the pipeline behind it is not
  // this instruction's.
  // P is written only from alu_post_2, so it follows the same gate.
  assign p_we        = s2_valid & mb86233_pkg::alu_writes_p(s2_op)
                     & ~div_inflight & fp_post_en;
  assign st_out      = div_done ? div_st_next : st_next;
  // fdvd retires when the divider finishes; every other op on the pipeline.
  assign out_valid   = div_done | (s2_valid & ~fdvd);
  assign extra_cycle = s2_valid & mb86233_pkg::alu_is_fp_post(s2_op);

endmodule
