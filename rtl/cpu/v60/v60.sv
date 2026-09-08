// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA - Copyright (C) 2026 alphanu1
//
// THIS FILE IS A MODIFIED VERSION OF SOMEONE ELSE'S WORK, AND SAYS SO HERE
// BECAUSE THE LICENCE REQUIRES IT.
//
// Imported from the Sega System 32 MiSTer core, https://github.com/meathax/s32,
// which is licensed GPL-3.0-or-later. This project is GPL-3.0-or-later too, so
// the copyleft obligation is met by publishing this source; GPLv3 section 5(a)
// additionally requires a modified file to carry prominent notice that it was
// changed, and a date. This block is that notice.
//
// There is no threshold of difference at which that stops being true. A
// derivative work carries its original licence however much of it is rewritten,
// and every change below is a rework of the upstream's own expression rather
// than an independent implementation.
//
// Modified for the Sega Model 1 between 2026-08 and 2026-09-02:
//   - imported and fixed for this project's SystemVerilog lint settings
//   - instruction fetch, the realign network, the loop cache and the prefetch
//     unit extracted into v60_ifetch.sv, so their area could be measured
//   - the floating-point normalise/round/exponent tail shared by fp_add,
//     fp_mul, fp_scale and cvt_w_s folded into one pipelined fp_pack stage
//   - MOVD reads the register pair through the register file's existing read
//     ports instead of indexing r[] directly, removing a 32:1 mux and an adder
//   - the group 6/7 scaled index computed once as ea_index rather than at seven
//     separate sites, each of which inferred its own 32-bit barrel shifter
//
//============================================================================
//  NEC V60 (uPD70616) / V70 (uPD70632) CPU core for the Sega System 32
//  MiSTer core.  DESIGN.md §5.
//
//  Instruction-accurate microsequenced implementation. Behavioral contract
//  is MAME's v60 core (BSD-3-Clause, Farfetch'd / R. Belmont): opcode
//  dispatch per optable.hxx, addressing modes per am1-3.hxx, exception
//  entry per v60.cpp.
//
//  Scope (per DESIGN.md §5.2/§5.3):
//   - Full integer ISA: F1/F2 two-operand ops, short-format ops, branches,
//     DBcc/TB, JMP/JSR/CALL/RET/RETIU/RETIS, PREPARE/DISPOSE, PUSH(M)/POP(M),
//     string ops incl. the fill/stop variants (MOVC*/CMPC*/SCHC*/SKPC*), TASI,
//     bit ops, GETPSW/UPDPSW, TRAP/TRAPFL/BRK/BRKV, CHLVL, task save/load,
//     privileged register moves (LDPR/STPR), and MAME-defined decimal/bit-
//     string/bit-field groups.
//   - Single-precision FP (0x5C/0x5F: CMPF/MOVFS/NEGFS/ABSFS/SCLFS/ADDFS/SUBFS/
//     MULFS/DIVFS/CVTWS/CVTSW): a binary32 unit (round-to-nearest-even, gradual
//     underflow) matching MAME's host-float contract; no System 32 game uses it.
//   - Not implemented (reserved-instruction exception, logged in sim): the
//     un-dispatched 0x5C/0x5F sub-opcodes (MAME UNHANDLED). MMU/TLB effects are
//     absent like MAME, but CLRTLB still decodes its complete operand. Address-
//     trap effects remain outside the S32 profile. IN/OUT-space accesses used to
//     as well, and that was a real fault on Model 1 rather than a scoping note —
//     see the IN/OUT exec cases: model1_io maps the coprocessor's registers, so a
//     faked IN left the CPU polling a constant forever. They are real bus
//     accesses now.
//     The V70 (IS_V70=1) 32-bit external bus is declared but s32_v60_bus still
//     issues 16-bit cycles; System 32 is V60 only, so the parameter is unused.
//
//  Bus: logical access port; unaligned/size handled by s32_v60_bus adapter.
//============================================================================

module s32_v60 #(
    parameter [31:0] START_PC = 32'hFFFFFFF0,   // V60/V70 reset PC (MAME m_start_pc; audit V60-21)
    parameter        IS_V70   = 1'b0,
    // FAST_IFETCH=1: the prefetch uses the dedicated wide instruction port (if_*)
    // served from the core's ROM icache (8 bytes/access, clk_sys latency),
    // instead of the ce-gated 16-bit data adapter.  This is what makes the
    // prefetch pay off on the production (gated-ce) build; the unit testbenches
    // run ce=1 (adapter already fast) and leave it 0 so if_* can stay unconnected.
    parameter        FAST_IFETCH = 1'b0
)(
    input             clk,
    input             ce,            // 16.108 MHz (V60) / 20 MHz (V70) enable
    input             rst,

    // dedicated instruction-fetch port (used only when FAST_IFETCH=1): request an
    // 8-byte line at if_addr; if_data/if_ack return it.  Left unconnected when
    // FAST_IFETCH=0 (the internal reads are forced to 0 so no X propagates).
    output logic      if_req,
    output     [23:0] if_addr,       // frontier byte address; s32_core reads the
                                     // containing 8-byte line and returns it already
                                     // aligned so byte0 == the frontier byte (the
                                     // >>foff shift lives there, off the CPU's tight
                                     // execution clock domain -- timing-closure guard)
    input      [63:0] if_data,
    input             if_ack,

    // logical bus (to s32_v60_bus adapter).  Externally one port; internally an
    // arbiter multiplexes the CPU's DATA accesses (dbus_*, priority) and the
    // instruction PREFETCH (pf_*) onto it.  Data path is unchanged: the 45 data
    // sites drive dbus_* and observe `dack`, which is the bus ack gated to the
    // data owner so a prefetch ack is never mistaken for a data completion.
    output            bus_req,
    output            bus_we,
    output     [31:0] bus_addr,
    output      [1:0] bus_size,      // 0=byte 1=half 2=word
    output     [31:0] bus_wdata,
    input      [31:0] bus_rdata,
    input             bus_ack,

    // interrupts
    input             irq_n,         // level, active low
    input       [7:0] irq_vector,    // external vector (s32_intc), +0x40 applied here
    output reg        irq_ack,       // pulses when vector consumed
    input             nmi_n,

    // debug/trace
    output reg [31:0] dbg_pc,
    output            dbg_halted,

    // Sticky: set the first time the S32_V60_NO_FP build takes the
    // reserved-instruction vector for a floating-point opcode, and never
    // cleared except by reset.
    //
    // Whether Model 1 code executes V60 FP is the open question behind
    // building without the FP group, which is worth ~2,000 ALM and nearly
    // doubles Fmax. Scanning the ROMs statically found no excess of FP-shaped
    // byte pairs above what each image's own byte distribution predicts, but a
    // byte scan cannot tell code from data or prove reachability. This turns
    // it into something a run can answer: silent means the build is safe,
    // asserted means it is not, and dbg_pc at that moment says where.
    //
    // Always present so the port list does not change with the define; in a
    // build with the FP group it simply never fires.
    output reg        dbg_fp_trap
);

// ---------------------------------------------------------------------------
// architectural state
// ---------------------------------------------------------------------------
reg [31:0] r[0:31];             // general registers, r[31]=active SP
integer init_reg_i;
// Deterministic FPGA cold power-up without changing the real V60 reset
// contract: subsequent reset assertions leave GPR contents untouched.
initial begin
    for (init_reg_i = 0; init_reg_i < 32; init_reg_i = init_reg_i + 1)
        r[init_reg_i] = 32'd0;
end
reg [31:0] pc;
reg [31:0] sbr, sycw, tkcw, pir, psw2;
reg [31:0] isp, l0sp, l1sp, l2sp, l3sp;   // shadow stacks (inactive copies)
reg [31:0] atbr0, atlr0, atbr1, atlr1, atbr2, atlr2, atbr3, atlr3;
reg [31:0] trmode;
reg [31:0] adtr0, adtr1, adtmr0, adtmr1;
reg [31:0] trr;                  // TR task register

// PSW fields (MAME bit layout: Z=b0,S=b1,OV=b2,CY=b3,IE=b18,EL=b25:24,IS=b28)
reg f_z, f_s, f_ov, f_cy;
reg [31:0] psw_rest;             // all non-flag PSW bits

wire [31:0] psw = {psw_rest[31:4], f_cy, f_ov, f_s, f_z};
wire        psw_ie = psw_rest[18];
wire  [1:0] psw_el = psw_rest[25:24];
wire        psw_is = psw_rest[28];

reg halted;
assign dbg_halted = halted;

// ---------------------------------------------------------------------------
// Data/prefetch bus arbiter.  The CPU's DATA accesses drive dbus_* and observe
// `dack`; the instruction prefetcher drives pf_* and observes `pf_ack`.  A
// single owner is granted per transaction with DATA priority, held until the
// adapter's ack, so a data request never starves and a prefetch ack is never
// mistaken for a data completion.  The mux is combinational, so a data access
// reaches the adapter with zero added latency (== the old direct drive).
reg        dbus_req, dbus_we;
reg [31:0] dbus_addr, dbus_wdata;
reg  [1:0] dbus_size;
wire       pf_req;               // instruction-prefetch bus request, from v60_ifetch
wire [31:0] pf_addr;   // driven by v60_ifetch
localparam [1:0] OWN_NONE = 2'd0, OWN_D = 2'd1, OWN_PF = 2'd2;
reg  [1:0] bus_owner;
reg        bus_req_d;   // bus_req delayed one ce: gates a fresh grant so bus_req
                        // always shows a 0->1 edge between transactions (the
                        // adapter starts on that edge).  Without it a prefetch->
                        // data owner switch keeps bus_req high and deadlocks.
wire sel_d  = (bus_owner == OWN_D)  || (bus_owner == OWN_NONE && dbus_req && !bus_req_d);
wire sel_pf = (bus_owner == OWN_PF) || (bus_owner == OWN_NONE && !dbus_req && pf_req && !bus_req_d);
assign bus_req   = sel_d ? dbus_req   : (sel_pf ? pf_req : 1'b0);
assign bus_we    = sel_d ? dbus_we    : 1'b0;      // prefetch is read-only
assign bus_addr  = sel_d ? dbus_addr  : pf_addr;
assign bus_size  = sel_d ? dbus_size  : 2'd2;      // prefetch is 32-bit
assign bus_wdata = sel_d ? dbus_wdata : 32'd0;
wire dack   = bus_ack && (bus_owner == OWN_D);
wire pf_ack = bus_ack && (bus_owner == OWN_PF);

// ---------------------------------------------------------------------------
// Instruction Prefetch Unit (PFU).  The real µPD70616 has a 16-byte prefetch
// queue the PFU loads "during idle bus periods", reducing fetch latency to zero
// on a hit (Programmer's Ref Manual p.1-18; docs/v60-authenticity-from-manual.md).
// We model it: a single 32-bit fetch in flight on pf_*, filling fb[] ahead of
// the decode-visible fb_valid while the EXU executes.  A rebased or shifted
// window discards a stale ack via an epoch tag; the data port keeps priority.
// ---------------------------------------------------------------------------
// pf_busy and pf_addr live in v60_ifetch now.
reg  [3:0] pf_epoch;          // bumped on every window rebase/flush
reg  [3:0] pf_iss_epoch;      // epoch captured when the in-flight fetch issued
localparam [4:0] PF_HIGH = 5'd20;   // lookahead fill target, passed to v60_ifetch
// if_addr, if_req and the FAST_IFETCH port muxing live in v60_ifetch, which owns
// the prefetch state that drives them.

// ---------------------------------------------------------------------------
// fetch buffer: 16 bytes from PC, filled before each decode
// ---------------------------------------------------------------------------
// THE FETCH WINDOW LIVES IN v60_ifetch NOW. It is exposed flat and unpacked
// here, so the ~70 places the decoder reads fb[] are unchanged.
wire [191:0] fb_flat;
wire [7:0]   fb[0:23];
generate
    genvar fbi;
    for (fbi = 0; fbi < 24; fbi = fbi + 1) begin : g_fb
        assign fb[fbi] = fb_flat[fbi*8 +: 8];
    end
endgenerate
wire [31:0] fb_base;
wire [4:0]  fb_valid, fb_need, fb_wr;
wire        fill_ready;

localparam [4:0] FB_THRESH = 5'd20;   // max instruction length
wire [7:0] opcode = fb[0];

// The window accessors stay here with the decoder that uses them; only the
// storage and its fill logic moved.
function automatic [31:0] fb32(input [4:0] o);
    fb32 = {fb[o+3], fb[o+2], fb[o+1], fb[o]};
endfunction
function automatic [15:0] fb16(input [4:0] o);
    fb16 = {fb[o+1], fb[o]};
endfunction

reg        ea_want_addr;    // 0 = ReadAM (value), 1 = ReadAMAddress
reg [1:0]  ea_dim;          // 0=B 1=H 2=W
reg        ea_modm;
reg [4:0]  ea_ofs;          // mode byte offset within fetch buffer
reg [31:0] ea_out;          // value or address result
reg        ea_flag;         // 1 = out is register number (address of reg)
reg [4:0]  ea_len;          // consumed extension length (incl mode bytes)
reg [31:0] ea_addr;         // scratch: computed address
reg [2:0]  ea_ret;          // return phase selector

// operand results
reg [31:0] op1, op2;
reg        flag1, flag2;
reg [4:0]  len1, len2;

reg [7:0]  instflags;
reg [7:0]  subop;

// exec scratch
reg [31:0] alu_r;
reg [63:0] mdacc;           // mul/div accumulator
reg [5:0]  mdcnt;
reg [31:0] mdop;
reg [31:0] movd_lo, movd_hi;     // MOVD 64-bit transfer buffer
reg        divx_mem;             // DIVX/DIVUX: op2 dividend/result is in memory
reg [31:0] md_savb;              // MUL: second operand, kept for overflow flag
reg        md_sign;
reg        md_qsign, md_rsign;   // divide result signs
reg        md_divov;             // DIV: signed min/-1 overflow (dest unchanged)
// DIVX/DIVUX use a 64-bit dividend.  Keeping this path separate from the
// 32-bit MUL/DIV accumulator avoids a 96-bit combined remainder/quotient
// register and, critically, avoids synthesizing a combinational 64/32 divide.
reg [63:0] xdiv_shift;
reg [32:0] xdiv_rem;
reg [31:0] xdiv_den;
reg  [5:0] xdiv_cnt;
reg  [4:0] xdiv_dst;
reg        xdiv_qneg, xdiv_rneg;
reg        xdiv_active;
reg [31:0] exc_pushval;
reg [7:0]  exc_vector;
reg [31:0] exc_code;      // code+size word for trap/brkv-class frames (A2/A3)
reg [31:0] exc_retpc;     // return PC pushed by the frame
reg        exc_has_code;  // 1 = 3-word frame (code,PSW,PC); 0 = IRQ 2-word
reg        exc_has_extra; // BRKV adds the fault PC ahead of its 3-word frame
reg [31:0] exc_extra;
reg [1:0]  exc_target_level;
reg        exc_is_interrupt;
reg [31:0] wb_val;
reg [31:0] op2val;          // loaded value of a memory op2 (V60-1)
reg        ea_isval;        // EA mode was an immediate: result is a pure
                            // value, no address exists (quick + full imm)
reg signed [7:0] rotc_cnt;
reg [31:0] rotc_val;
reg        op2val_v;
reg [2:0]  rmw_kind;   // 0=INC 1=DEC 2=SET1 3=CLR1 4=NOT1 5=TEST1
reg [1:0]  rmw_dim;
reg [31:0] xch_addr;
reg [31:0] task_mask, task_addr;
reg [5:0]  task_phase;
reg        task_reloaded;
// V60 F1 encodings can carry two nine-byte effective-address operands:
// opcode/flags + 9 + 9 = 20 bytes.  Four bits silently wrapped those legal
// instruction lengths and advanced PC into the middle of the instruction.
reg [4:0]  total_len;
reg [4:0]  reg_ptr;         // PUSHM/POPM iterator
reg [31:0] str_cnt;
reg [31:0] str_src, str_dst;   // string op source/dest addresses (A1)
reg [31:0] str_len1, str_len2; // string op operand lengths
// CMPC/MOVC fill+stop variants (CMPCF/CMPCS/MOVCFU/MOVCFD/MOVCSU, op7a.hxx).
// The fill phase writes R26 to the shorter operand's tail; str_fi counts the
// remaining fill elements, str_faddr walks them (+/- one element per step),
// and str_fill_after selects the post-fill state (compare vs done).
reg [31:0] str_fi;             // remaining fill elements
reg [31:0] str_faddr;          // current fill write address
reg [31:0] str_fdelta;         // per-element address step (two's-complement for down)
reg [31:0] str_fr27;           // R27 to publish when a MOVC fill completes
reg        str_fill_after;     // 0 = CMPC pre-fill -> compare; 1 = MOVC post-fill -> done
reg [7:0]  dec_pat;            // 0x59 decimal group: F7c pattern byte
reg [7:0]  dec_cur;            // current destination byte (BCD ops)
reg [15:0] dec_res;            // result awaiting memory write-back

// single-precision FP group (0x5C/0x5F: CMPF/MOVFS/NEGFS/ABSFS/SCLFS/ADDFS/
// SUBFS/MULFS/DIVFS/CVTWS/CVTSW).  op7a-style F2 decode: op1 = ReadAM value,
// op2 = ReadAM (CMPF) / WriteAM (MOVFS/CVTWS/CVTSW) / ReadAMAddress RMW (rest).
`ifndef S32_V60_NO_FP
reg [31:0] fp_a, fp_b;         // operand float bit patterns (a=op1, b=op2)
reg [31:0] fp_res;             // packed binary32 result awaiting writeback
reg        fp_op2_reg;         // op2 destination is a register (else memory)

// THE FP GROUP IS ITS OWN MODULE. rtl/cpu/v60/v60_fp.sv owns the arithmetic,
// the restoring divider and the per-subop dispatch; this file keeps only the
// operand fetch and the writeback routing, which are bus work and belong to
// the CPU. Moving it took S_FP_EXEC2, S_FP_PACK and S_FP_DIV out of the
// 106-state machine - the point is fewer arms in the one giant always block,
// not tidiness. See that file's header for the measurement.
reg         fp_start;          // one-cycle pulse
reg         fp_busy;
wire        fp_done, fp_writes;
wire [31:0] fp_result;
wire        fp_o_z, fp_o_s, fp_o_ov, fp_o_cy;
`endif

// 0x5B/0x5D bit string / bit field state (V60-10)
reg [31:0] bam_base;           // BAM: byte base address
reg [31:0] bam_off;            // BAM: bit offset (full, before &7 fold)
reg        bam_second;         // decoding the second BAM operand
reg [1:0]  bam_flow;           // 0=EXTBF 1=INSBF 2=SCHBS 3=MOVBS
reg [31:0] bit_len;            // field/string length
reg [31:0] bit_val;            // op1 value / dword scratch
reg [31:0] bs_base1, bs_off1;  // MOVBS first-operand result
reg [2:0]  bs_soff, bs_doff;   // bit positions in current bytes
reg [7:0]  bs_sdata, bs_ddata; // current source/dest bytes
reg [1:0]  bs_ph;              // MOVB per-bit micro-phase
reg        bs_adv_done;        // MOVS: pointer advance already applied

// ---------------------------------------------------------------------------
// sequencer
// ---------------------------------------------------------------------------
typedef enum logic [6:0] {
    S_RESET, S_FILL, S_FILLW, S_DECODE,
    S_IF2,                       // have instflags, plan F12 operands
    S_EA_MODE, S_EA_IND, S_EA_IND2, S_EA_VAL, S_EA_DONE,
    S_EXEC, S_OP2_LD, S_MULDIV, S_DIVX, S_WB_MEM, S_NEXT, S_RMW_RD, S_RMW_EX, S_XCH1, S_XCH2, S_ROTC,
    S_MOVD_RL, S_MOVD_RH, S_MOVD_WL, S_MOVD_WH,   // MOVD qword read/write phases
    S_IN_RD, S_OUT_WR,                            // IN/OUT: real I/O-space access
    S_DIVXM_RH,                                   // DIVX memory dividend high-word read
    S_BR_TAKE,
    S_PUSH, S_POP, S_PUSHM, S_POPM,
    S_JSR1, S_RET1, S_RET2, S_RETI1, S_RETI2, S_RETI3, S_CALL1, S_CALL1b, S_RSR,
    S_STR_OP1, S_STR_OP2, S_STR_RD, S_STR_WR, S_STR_NEXT, S_STR_FILL,
    S_DEC_OP1, S_DEC_OP2, S_DEC_RD, S_DEC_EX, S_DEC_WR,
    S_BAM_MODE, S_BAM_IND, S_BAM_VAL,
    S_BF_EXT1, S_BF_EXTW,
    S_BF_INS1, S_BF_INS2, S_BF_INSRD, S_BF_INSWR,
    S_BS_SCH1, S_BS_SCHRD, S_BS_SCHB, S_BS_SCHW,
    S_BS_MOV1, S_BS_MOV2, S_BS_MOVS, S_BS_MOVD, S_BS_MOVB, S_BS_MOVF,
`ifndef S32_V60_NO_FP
    S_FP_OP2, S_FP_LD, S_FP_EXEC, S_FP_WB,
`endif
    S_EXC_PUSH1, S_EXC_EXTRA, S_EXC_CODE, S_EXC_PUSH2, S_EXC_VEC, S_EXC_JMP,
    S_TASK_LD_NEXT, S_TASK_LD_ACK, S_TASK_ST_NEXT, S_TASK_ST_ACK,
    S_TASI1, S_TASI2,
    S_PREP1, S_DISP1,
    S_HALT
} st_t;

st_t st, st_after_ea, st_after_fill;

// One restoring-division bit per enabled CPU clock.  The 33-bit trial value
// is the only compare/subtract datapath used for all 64 dividend bits.
wire [32:0] xdiv_trial = {xdiv_rem[31:0], xdiv_shift[63]};
wire        xdiv_take = xdiv_trial >= {1'b0, xdiv_den};
wire [32:0] xdiv_rem_next = xdiv_take
                            ? xdiv_trial - {1'b0, xdiv_den} : xdiv_trial;
wire [63:0] xdiv_shift_next = {xdiv_shift[62:0], xdiv_take};
wire [31:0] xdiv_qresult = xdiv_qneg
                           ? (~xdiv_shift_next[31:0] + 1'b1)
                           : xdiv_shift_next[31:0];
wire [31:0] xdiv_rresult = xdiv_rneg
                           ? (~xdiv_rem_next[31:0] + 1'b1)
                           : xdiv_rem_next[31:0];

// which operand the EA engine is filling
reg ea_target2;

// instruction class latched at decode
typedef enum logic [4:0] {
    C_NONE, C_F12, C_BR8, C_BR16, C_DBCC, C_JMP, C_JSR, C_RET, C_RETI,
    C_PUSH, C_POP, C_PUSHM, C_POPM, C_PREPARE, C_DISPOSE, C_TRAP, C_BRK,
    C_STRING, C_CLR1GRP, C_SHORT, C_MISC
} cls_t;
cls_t cls;

reg [7:0] cur_op;

// Consolidate every dynamic general-register read onto two explicit ports.
// The architectural register array remains flip-flop based with its existing
// nonblocking write semantics; these selectors only remove duplicated 32:1
// read muxes inferred at each use site.
function automatic [4:0] pushm_index(input [31:0] mask);
    integer i;
    begin
        pushm_index = 5'd31;
        for (i = 0; i < 32; i = i + 1)
            if (mask[i]) pushm_index = i[4:0];
    end
endfunction

// condition codes (V60 order used by Bcc/DBcc): V,NV,C/L,NC/NL,Z/E,NZ/NE,NH,H,N,P,R(always),-,LT,GE,LE,GT
function automatic cond_true(input [3:0] cc);
    case (cc)
        4'h0: cond_true = f_ov;
        4'h1: cond_true = ~f_ov;
        4'h2: cond_true = f_cy;
        4'h3: cond_true = ~f_cy;
        4'h4: cond_true = f_z;
        4'h5: cond_true = ~f_z;
        4'h6: cond_true = f_cy | f_z;
        4'h7: cond_true = ~(f_cy | f_z);
        4'h8: cond_true = f_s;
        4'h9: cond_true = ~f_s;
        4'ha: cond_true = 1'b1;
        4'hb: cond_true = 1'b0;
        4'hc: cond_true = f_s ^ f_ov;
        4'hd: cond_true = ~(f_s ^ f_ov);
        4'he: cond_true = (f_s ^ f_ov) | f_z;
        4'hf: cond_true = ~((f_s ^ f_ov) | f_z);
    endcase
endfunction

// sign/zero helpers per dim
function automatic [7:0] bin2bcd(input [6:0] v);   // 0-99 -> packed BCD
    logic [6:0] q, r;
    q = v / 7'd10;
    r = v - (q * 7'd10);
    bin2bcd = {q[3:0], r[3:0]};
endfunction

// C-style truncating divide-by-8 of a signed bit offset (MAME bamoffset/8)
function automatic [31:0] bitdiv8(input [31:0] off);
    bitdiv8 = off[31] ? (32'h0 - ((32'h0 - off) >> 3)) : (off >> 3);
endfunction

function automatic [31:0] dimext(input [31:0] v, input [1:0] d);
    case (d)
        2'd0: dimext = {24'b0, v[7:0]};
        2'd1: dimext = {16'b0, v[15:0]};
        default: dimext = v;
    endcase
endfunction
function automatic sgn(input [31:0] v, input [1:0] d);
    case (d) 2'd0: sgn = v[7]; 2'd1: sgn = v[15]; default: sgn = v[31]; endcase
endfunction
function automatic zer(input [31:0] v, input [1:0] d);
    case (d) 2'd0: zer = v[7:0]==0; 2'd1: zer = v[15:0]==0; default: zer = v==0; endcase
endfunction

// Funnel every architectural-register update through two masked write ports.
// The V60 can retire at most two register writes in one FSM cycle.  Keeping
// the decoders here avoids rebuilding a 32-way write network at every
// syntactic assignment site in the monolithic instruction FSM.
reg        rf_we0, rf_we1;
reg [4:0]  rf_waddr0, rf_waddr1;
reg [31:0] rf_wdata0, rf_wdata1;
reg [31:0] rf_wmask0, rf_wmask1;

task automatic queue_reg_write(
    input [4:0] rn,
    input [31:0] v,
    input [31:0] mask
);
    if (!rf_we0) begin
        rf_we0 = 1'b1;
        rf_waddr0 = rn;
        rf_wdata0 = v;
        rf_wmask0 = mask;
    end
    else begin
        rf_we1 = 1'b1;
        rf_waddr1 = rn;
        rf_wdata1 = v;
        rf_wmask1 = mask;
    end
endtask

// merge result into register per dim (SETREG8/16 semantics)
task automatic setreg(input [4:0] rn, input [31:0] v, input [1:0] d);
    case (d)
        2'd0: queue_reg_write(rn, v, 32'h0000_00ff);
        2'd1: queue_reg_write(rn, v, 32'h0000_ffff);
        default: queue_reg_write(rn, v, 32'hffff_ffff);
    endcase
endtask

// stack-bank bookkeeping: swap active SP when PSW level/IS changes
task automatic save_stack(input [31:0] oldpsw);
    if (oldpsw[28]) isp <= r[31];
    else case (oldpsw[25:24])
        2'd0: l0sp <= r[31]; 2'd1: l1sp <= r[31];
        2'd2: l2sp <= r[31]; 2'd3: l3sp <= r[31];
    endcase
endtask
function automatic [31:0] pick_stack(input [31:0] newpsw);
    if (newpsw[28]) pick_stack = isp;
    else case (newpsw[25:24])
        2'd0: pick_stack = l0sp; 2'd1: pick_stack = l1sp;
        2'd2: pick_stack = l2sp; 2'd3: pick_stack = l3sp;
    endcase
endfunction

task automatic write_psw_after_sp(input [31:0] v, input [31:0] sp_now);
    if (((v ^ psw) & 32'h1000_0000) != 0 ||
        (!psw[28] && ((v ^ psw) & 32'h0300_0000) != 0)) begin
        if (psw[28]) isp <= sp_now;
        else case (psw[25:24])
            2'd0: l0sp <= sp_now; 2'd1: l1sp <= sp_now;
            2'd2: l2sp <= sp_now; 2'd3: l3sp <= sp_now;
        endcase
        queue_reg_write(5'd31, pick_stack(v), 32'hffff_ffff);
    end
    psw_rest <= v;
    f_z  <= v[0];
    f_s  <= v[1];
    f_ov <= v[2];
    f_cy <= v[3];
endtask

task automatic write_psw(input [31:0] v);
    // stack switch on IS change, or EL change while IS=0 (MAME v60WritePSW)
    if (((v ^ psw) & 32'h1000_0000) != 0 ||
        (!psw[28] && ((v ^ psw) & 32'h0300_0000) != 0)) begin
        save_stack(psw);
        queue_reg_write(5'd31, pick_stack(v), 32'hffff_ffff);
    end
    psw_rest <= v;
    f_z  <= v[0];
    f_s  <= v[1];
    f_ov <= v[2];
    f_cy <= v[3];
endtask

// ---------------------------------------------------------------------------
// EA engine (combinational mode/extension parse; sequential memory derefs)
//   Implements s_AMTable1/2/3 dispatch:
//   modm=0: 0..2 Disp8/16/32, 3 RegInd, 4..6 DispIndirect(deferred), 7 Group7
//   modm=1: 0..2 DoubleDisp,  3 Reg,    4 AutoInc, 5 AutoDec, 6 Group6(idx)
// ---------------------------------------------------------------------------
// SHARED STACK-POINTER ARITHMETIC.
//
// `r[31] - 4` is written out at eleven separate dbus_addr sites and `r[31] + 4`
// at more, in different branches of a 90-state case. Each is a 32-bit
// subtractor, and whether the synthesiser shares them across branches is its
// choice rather than ours. Naming them makes it structural.
//
// Safe against the write port: r[31] is only updated by non-blocking assignment
// in the register-file block, so a continuous assignment reads exactly what an
// inline expression in the same cycle would.
wire [31:0] sp_val  = r[31];
wire [31:0] sp_m4   = r[31] - 32'd4;
wire [31:0] sp_p4   = r[31] + 32'd4;

wire [7:0] modval  = fb[ea_ofs];
wire [4:0] modreg  = modval[4:0];
wire [2:0] modtop  = modval[7:5];
// THE TWO OFFSETS THE ADDRESSING PATH USES, EXTRACTED ONCE EACH.
// disp_of and fb32 were called about twenty times between them at exactly
// these two offsets, across S_EA_MODE and its near-duplicate S_BAM_MODE, and
// a Verilog function is inlined at every call site. Those states are arms of
// one case and so mutually exclusive; one extraction per offset serves all.
//
// WRITTEN AS CONCATENATIONS, NOT AS fb32(...) CALLS, AND THAT IS LOAD-BEARING.
// `wire [31:0] fbw_ea1 = fb32(ea_ofs + 1);` is textually the same thing and is
// WRONG: calling a `function automatic` that reads the unpacked array fb[]
// from a CONTINUOUS ASSIGNMENT silently yields bad data. tb_v60_search fails
// on "encoded GA2 SKPCUH R28" with the function form and passes with this one,
// every other line identical. It cost a long bisect. Do not "tidy" these back
// into fb32() calls.
wire [31:0] fbw_ea1 = {fb[ea_ofs+4], fb[ea_ofs+3], fb[ea_ofs+2], fb[ea_ofs+1]};
wire [31:0] fbw_ea2 = {fb[ea_ofs+5], fb[ea_ofs+4], fb[ea_ofs+3], fb[ea_ofs+2]};

wire [7:0] modval2 = fbw_ea1[7:0];

reg  [4:0] rf_raddr_a, rf_raddr_b;
// Keep the architectural register file in flops, but expose exactly two
// combinational read ports.  Constant-index case arms are intentional:
// Icarus can corrupt its runtime stack on a variable-index unpacked-array
// read, and a function which reaches out to r[] can miss value-only changes
// in its inferred sensitivity.  These explicit blocks are stable in all
// simulators and still synthesize as one 32:1 mux per port.
reg [31:0] rf_rdata_a, rf_rdata_b;
always @* begin
    case (rf_raddr_a)
        5'd0:  rf_rdata_a = r[0];   5'd1:  rf_rdata_a = r[1];
        5'd2:  rf_rdata_a = r[2];   5'd3:  rf_rdata_a = r[3];
        5'd4:  rf_rdata_a = r[4];   5'd5:  rf_rdata_a = r[5];
        5'd6:  rf_rdata_a = r[6];   5'd7:  rf_rdata_a = r[7];
        5'd8:  rf_rdata_a = r[8];   5'd9:  rf_rdata_a = r[9];
        5'd10: rf_rdata_a = r[10];  5'd11: rf_rdata_a = r[11];
        5'd12: rf_rdata_a = r[12];  5'd13: rf_rdata_a = r[13];
        5'd14: rf_rdata_a = r[14];  5'd15: rf_rdata_a = r[15];
        5'd16: rf_rdata_a = r[16];  5'd17: rf_rdata_a = r[17];
        5'd18: rf_rdata_a = r[18];  5'd19: rf_rdata_a = r[19];
        5'd20: rf_rdata_a = r[20];  5'd21: rf_rdata_a = r[21];
        5'd22: rf_rdata_a = r[22];  5'd23: rf_rdata_a = r[23];
        5'd24: rf_rdata_a = r[24];  5'd25: rf_rdata_a = r[25];
        5'd26: rf_rdata_a = r[26];  5'd27: rf_rdata_a = r[27];
        5'd28: rf_rdata_a = r[28];  5'd29: rf_rdata_a = r[29];
        5'd30: rf_rdata_a = r[30];  default: rf_rdata_a = r[31];
    endcase
end
always @* begin
    case (rf_raddr_b)
        5'd0:  rf_rdata_b = r[0];   5'd1:  rf_rdata_b = r[1];
        5'd2:  rf_rdata_b = r[2];   5'd3:  rf_rdata_b = r[3];
        5'd4:  rf_rdata_b = r[4];   5'd5:  rf_rdata_b = r[5];
        5'd6:  rf_rdata_b = r[6];   5'd7:  rf_rdata_b = r[7];
        5'd8:  rf_rdata_b = r[8];   5'd9:  rf_rdata_b = r[9];
        5'd10: rf_rdata_b = r[10];  5'd11: rf_rdata_b = r[11];
        5'd12: rf_rdata_b = r[12];  5'd13: rf_rdata_b = r[13];
        5'd14: rf_rdata_b = r[14];  5'd15: rf_rdata_b = r[15];
        5'd16: rf_rdata_b = r[16];  5'd17: rf_rdata_b = r[17];
        5'd18: rf_rdata_b = r[18];  5'd19: rf_rdata_b = r[19];
        5'd20: rf_rdata_b = r[20];  5'd21: rf_rdata_b = r[21];
        5'd22: rf_rdata_b = r[22];  5'd23: rf_rdata_b = r[23];
        5'd24: rf_rdata_b = r[24];  5'd25: rf_rdata_b = r[25];
        5'd26: rf_rdata_b = r[26];  5'd27: rf_rdata_b = r[27];
        5'd28: rf_rdata_b = r[28];  5'd29: rf_rdata_b = r[29];
        5'd30: rf_rdata_b = r[30];  default: rf_rdata_b = r[31];
    endcase
end

always @* begin
    rf_raddr_a = 5'd0;
    rf_raddr_b = 5'd0;
    case (st)
        S_DECODE:  rf_raddr_a = fb[1][4:0];
        S_IF2:     rf_raddr_a = instflags[4:0];
        S_EA_MODE: begin
            rf_raddr_a = modreg;
            rf_raddr_b = modval2[4:0];
        end
        S_PUSHM:   rf_raddr_a = pushm_index(op1);
        S_STR_OP1: rf_raddr_a = fb[5'd2 + len1][4:0];
        S_STR_OP2: rf_raddr_a = fb[5'd3 + len1 + len2][4:0];
        S_DEC_OP2: begin
            rf_raddr_a = fb[5'd2 + len1 + len2][4:0];
            rf_raddr_b = op2[4:0];
        end
        S_BAM_MODE: begin
            rf_raddr_a = modreg;
            rf_raddr_b = modval2[4:0];
        end
        S_BF_EXT1, S_BS_SCH1, S_BS_MOV1:
            rf_raddr_a = fb[5'd2 + len1][4:0];
        S_BF_INS2:
            rf_raddr_a = fb[5'd2 + len1 + len2][4:0];
        S_TASK_ST_NEXT:
            if (task_phase >= 6'd5) rf_raddr_a = task_phase[4:0] - 5'd5;
`ifndef S32_V60_NO_FP
        S_FP_LD:   rf_raddr_b = op2[4:0];   // FP RMW register-operand read
`endif
        S_EXEC: begin
            rf_raddr_a = ((cur_op == 8'ha6) || (cur_op == 8'hb6))
                         ? op2[4:0] + 5'd1 : op1[4:0];
            // MOVD reads the register PAIR op1 and op1+1. It used to index r[]
            // directly for both, and a variable index into a 32-entry file
            // infers a fresh 32:1 mux on 32 bits - about 175 ALM each, with an
            // adder in front of the second. The file already has two read
            // ports; MOVD only WRITES op2, so port b is free for it. The +1
            // now happens on a 5-bit address instead of behind a 32-bit mux.
            rf_raddr_b = (cur_op == 8'h3f) ? op1[4:0] + 5'd1 : op2[4:0];
        end
        default: ;
    endcase
end
// THE SCALED INDEX, COMPUTED ONCE. Group 6/7 addressing scales the index
// register by the operand size, and the expression `rf_rdata_a << ea_dim`
// appeared at eight separate sites in the state machine. Quartus will not share
// logic across case arms it cannot prove exclusive, so each site inferred its
// own 32-bit shifter. ea_dim is a register written in an earlier state and
// rf_rdata_a is combinational from rf_raddr_a, so one continuous assignment is
// exactly equivalent to the eight - and infers one shifter instead of eight.
//
// DECLARED HERE rather than beside ea_dim: Icarus binds strictly in source
// order and rejects a reference to rf_rdata_a above its declaration. Verilator
// accepts it, and six of the V60 tests are built with Icarus.
wire [31:0] ea_index = rf_rdata_a << ea_dim;


// extension displacement follows mode byte(s)
// A 20-byte F1 instruction can place the second double-displacement field at
// fetch-buffer offset 16.  Keep the full five-bit offset used by the buffer.
// ONE EXTRACTION, THEN SLICES. This used to select between three separate
// reads of the fetch buffer - a byte at `base`, fb16(base) and fb32(base) -
// so every one of its SIXTEEN call sites inlined a 4-byte 24:1 mux AND a
// 2-byte one AND a single-byte one. fb32's low slices already are the other
// two, so one extraction serves all three widths and the byte and half-word
// muxes disappear.
//
// The wider read is safe where the narrower one was: the upper bytes are
// discarded for sz 0 and 1, so an index past the end of fb contributes only
// to bits that are sliced away. `default` already read base+3 for sz 2.
function automatic [31:0] disp_from(input [31:0] w, input [1:0] sz);
    case (sz)
        2'd0: disp_from = {{24{w[7]}},  w[7:0]};
        2'd1: disp_from = {{16{w[15]}}, w[15:0]};
        default: disp_from = w;
    endcase
endfunction
function automatic [31:0] disp_of(input [4:0] base, input [1:0] sz);
    disp_of = disp_from(fb32(base), sz);
endfunction
function automatic [4:0] disp_len(input [1:0] sz);
    disp_len = (sz==2'd0) ? 5'd1 : (sz==2'd1) ? 5'd2 : 5'd4;
endfunction

// Total bytes consumed by the two same-width displacement fields plus the
// addressing-mode byte.  Explicit constants avoid constructing a six-bit
// intermediate only to truncate it back to the five-bit fetch-buffer length.
function automatic [4:0] double_disp_len(input [1:0] sz);
    double_disp_len = (sz==2'd0) ? 5'd3 : (sz==2'd1) ? 5'd5 : 5'd9;
endfunction

// immediate length by dim
function automatic [4:0] imm_len(input [1:0] d);
    imm_len = (d==2'd0) ? 5'd1 : (d==2'd1) ? 5'd2 : 5'd4;
endfunction

// autoinc step
function automatic [31:0] dim_step(input [1:0] d);
    dim_step = (d==2'd0) ? 32'd1 : (d==2'd1) ? 32'd2 : 32'd4;
endfunction

// ---------------------------------------------------------------------------
// main FSM
// ---------------------------------------------------------------------------

reg [3:0] fill_lo;
reg nmi_r, nmi_seen;

always @(posedge clk) begin
if (rst) begin
    st <= S_RESET;
    dbus_req <= 0; dbus_we <= 0; irq_ack <= 0;
    dbus_addr <= 0; dbus_size <= 0; dbus_wdata <= 0;
    halted <= 0;
    dbg_pc <= START_PC;
    dbg_fp_trap <= 1'b0;
    nmi_seen <= 0;
    nmi_r <= 0;
    xdiv_active <= 0;
`ifndef S32_V60_NO_FP
    fp_start <= 1'b0;
    fp_busy  <= 1'b0;
`endif
    bus_owner <= OWN_NONE;
    bus_req_d <= 0;
    // pf_req, if_req and the prefetch state reset inside v60_ifetch.
end
else if (ce) begin
    // bus ownership: grant per-transaction, data priority, hold until ack.  A
    // grant requires the bus to have been idle last cycle (!bus_req_d) so every
    // transaction begins with a clean 0->1 edge on bus_req.
    bus_req_d <= bus_req;
    if (bus_owner == OWN_NONE && !bus_req_d) begin
        if (dbus_req)    bus_owner <= OWN_D;
        else if (pf_req) bus_owner <= OWN_PF;
    end
    else if (bus_ack) bus_owner <= OWN_NONE;

    rf_we0 = 1'b0;
    rf_we1 = 1'b0;
    rf_waddr0 = 5'd0;
    rf_waddr1 = 5'd0;
    rf_wdata0 = 32'd0;
    rf_wdata1 = 32'd0;
    rf_wmask0 = 32'd0;
    rf_wmask1 = 32'd0;
    irq_ack <= 0;
    nmi_r <= ~nmi_n;
    if (~nmi_n & ~nmi_r) nmi_seen <= 1'b1;

    case (st)
    // ------------------------------------------------------------------
    S_RESET: begin
        pc       <= START_PC;
        psw_rest <= 32'h1000_0000;
        {f_z,f_s,f_ov,f_cy} <= 4'b0;
        sbr  <= 32'h0000_0000;
        sycw <= 32'h0000_0070;
        tkcw <= 32'h0000_e000;
        pir  <= IS_V70 ? 32'h0000_7000 : 32'h0000_6000;
        psw2 <= 32'h0000_f002;
        isp <= 0; l0sp <= 0; l1sp <= 0; l2sp <= 0; l3sp <= 0;
        trr <= 0;
        atbr0 <= 0; atlr0 <= 0; atbr1 <= 0; atlr1 <= 0;
        atbr2 <= 0; atlr2 <= 0; atbr3 <= 0; atlr3 <= 0;
        trmode <= 0;
        adtr0 <= 0; adtr1 <= 0; adtmr0 <= 0; adtmr1 <= 0;
        halted <= 0;
        // The fetch window resets inside v60_ifetch.
        st <= S_FILL;
        st_after_fill <= S_DECODE;
       
    end

    // ------------------------------------------------------------------
    // incremental fetch buffer (perf): keep bytes across sequential flow.
    //  - window realign: if pc moved forward within the valid window,
    //    shift out consumed bytes (4/cycle).  Save the pre-shift window so a
    //    branch back to the preceding instruction can restore it directly.
    //    Other misses invalidate normally.
    //  - top-up 4 bytes per 32-bit logical read until fb_need is valid.
    S_FILL: begin
        // The window lives in v60_ifetch now; this state only waits for it.
        if (fill_ready) st <= st_after_fill;
    end
    // S_FILLW is retained for the enum but no longer reached: the fetch is
    // asynchronous in v60_ifetch, which owns the window it used to write.
    S_FILLW: if (dack) begin
        dbus_req <= 0;
        st <= S_FILL;
    end

    // ------------------------------------------------------------------
    S_DECODE: begin
        // dbg_pc IS PUBLISHED ON DISPATCH, NOT ON ENTRY. It used to be assigned
        // here, above the interrupt check below — so when an interrupt preempted
        // an instruction, dbg_pc still advertised a PC that never executed.
        //
        // That produced a false CPU-bug report. `make v60_trace` logs dbg_pc on
        // change and diffs it against MAME's tracer, which only prints
        // instructions it actually retires; at `updpsw.w #FFFFFFFF, #40000` —
        // whose mask 0x40000 is bit 18, psw_ie — the reference vectors straight
        // to the handler and we appeared to execute one extra instruction first.
        // We did not; we only published its PC. See docs/differential-testing.md.
        //
        // Holding the previous value through an exception entry is also the more
        // useful reading for the overlay and for a parked CPU: dbg_pc then names
        // the last instruction that ran rather than the one that was about to.
        cur_op <= opcode;
        total_len <= 5'd2;      // default for F12 base
        // exception-frame defaults (A8): 2-word frame returning to current PC;
        // TRAP/BRKV override with a 3-word code frame and adjusted return PC.
        exc_has_code <= 1'b0;
        exc_has_extra <= 1'b0;
        exc_target_level <= 2'd0;
        exc_is_interrupt <= 1'b0;
        exc_retpc    <= pc;
        rmw_kind     <= 3'd7;   // sentinel: not an RMW writeback
        op2val_v     <= 1'b0;
        // interrupts sampled at instruction boundary
        if (nmi_seen) begin
            nmi_seen <= 0;
            exc_vector <= 8'd2;
            exc_pushval <= psw;
            exc_retpc <= pc;
            exc_has_code <= 1'b0;      // NMI: 2-word frame (v60_do_irq)
            exc_is_interrupt <= 1'b1;
            st <= S_EXC_PUSH1;
        end
        else if (!irq_n && psw_ie) begin
            irq_ack <= 1'b1;
            exc_vector <= irq_vector + 8'h40;
            exc_pushval <= psw;
            exc_retpc <= pc;
            exc_has_code <= 1'b0;      // IRQ: 2-word frame
            exc_is_interrupt <= 1'b1;
            st <= S_EXC_PUSH1;
        end
        else if (halted) st <= S_HALT;
        else begin
        dbg_pc <= pc;           // an instruction is really being dispatched now
        // primary dispatch (per MAME optable.hxx)
        casez (opcode)
        // ---- one-byte / special ----
        8'h00: begin halted <= 1'b1; st <= S_HALT; end                    // HALT
        8'hcd: begin pc <= pc + 1; st <= S_FILL; st_after_fill <= S_DECODE; end // NOP
        8'hc8: begin // BRK — MAME skips this opcode (A4)
            // synthesis translate_off
            $display("V60: BRK skipped at %08x", pc);
            // synthesis translate_on
            pc <= pc + 1; st <= S_FILL; st_after_fill <= S_DECODE;
        end
        8'hc9: begin // BRKV (A3): only if OV; 3-word frame code 0x1501, vector 21
            if (f_ov) begin
                exc_vector   <= 8'd21;
                exc_code     <= 32'h1501_0004;   // EXCEPTION_CODE_AND_SIZE(0x1501,4)
                exc_extra    <= pc;
                exc_pushval  <= psw;
                exc_retpc    <= pc + 1;
                exc_has_code <= 1'b1;
                exc_has_extra <= 1'b1;
                st <= S_EXC_PUSH1;
            end
            else begin pc <= pc + 1; st <= S_FILL; st_after_fill<=S_DECODE; end
        end

        // ---- Bcc disp8 (0x60-0x6a,0x6c-0x6f) / disp16 equivalent ----
        // 0x6B/0x7B are holes in MAME's authoritative primary dispatch
        // table, not branch-condition encodings.  Decode the holes inside the
        // corresponding family so the casez items remain mutually exclusive.
        8'b0110_????: begin
            if (opcode == 8'h6b) begin
                exc_vector <= 8'd8;
                exc_pushval <= psw;
                st <= S_EXC_PUSH1;
            end
            else begin
                if (cond_true(opcode[3:0]))
                     pc <= pc + {{24{fb[1][7]}}, fb[1]};
                else pc <= pc + 2;
                st <= S_FILL; st_after_fill <= S_DECODE;
            end
        end
        8'b0111_????: begin
            logic [15:0] bd16;
            if (opcode == 8'h7b) begin
                exc_vector <= 8'd8;
                exc_pushval <= psw;
                st <= S_EXC_PUSH1;
            end
            else begin
                bd16 = fb16(1);
                if (cond_true(opcode[3:0]))
                     pc <= pc + {{16{bd16[15]}}, bd16};
                else pc <= pc + 3;
                st <= S_FILL; st_after_fill <= S_DECODE;
            end
        end

        // ---- BSR disp16 (0x48): push return, branch ----
        8'h48: begin
            logic [15:0] bd16;
            bd16 = fb16(1);
            dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
            dbus_addr <= sp_m4;
            dbus_wdata <= pc + 3;
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
            wb_val <= pc + {{16{bd16[15]}}, bd16};
            st <= S_JSR1;
        end

        // ---- DBcc/TB (0xC6/0xC7): sub-op byte = {cc[2:0], reg[4:0]} ----
        8'hc6, 8'hc7: begin
            logic [3:0] cc4;
            case ({opcode[0], fb[1][7:5]})
                4'b0000: cc4 = 4'h0; 4'b0001: cc4 = 4'h2; 4'b0010: cc4 = 4'h4;
                4'b0011: cc4 = 4'h6; 4'b0100: cc4 = 4'h8; 4'b0101: cc4 = 4'ha; // DBR
                4'b0110: cc4 = 4'hc; 4'b0111: cc4 = 4'he;
                4'b1000: cc4 = 4'h1; 4'b1001: cc4 = 4'h3; 4'b1010: cc4 = 4'h5;
                4'b1011: cc4 = 4'h7; 4'b1100: cc4 = 4'h9; 4'b1101: cc4 = 4'hb; // TB: cond false = never -> only reg!=0? (TB tests true)
                4'b1110: cc4 = 4'hd; default: cc4 = 4'hf;
            endcase
            // MAME opDBcc: reg ALWAYS decrements; branch iff cond true and
            // decremented reg != 0. TB: branch iff reg == 0 (no decrement).
            begin
                logic [15:0] bd16;
                bd16 = fb16(2);
                if ({opcode[0], fb[1][7:5]} == 4'b1101) begin
                    if (rf_rdata_a == 0) pc <= pc + {{16{bd16[15]}}, bd16};
                    else pc <= pc + 4;
                end
                else begin
                    queue_reg_write(fb[1][4:0], rf_rdata_a - 1, 32'hffff_ffff);
                    if (cond_true(cc4) && (rf_rdata_a - 1) != 0)
                         pc <= pc + {{16{bd16[15]}}, bd16};
                    else pc <= pc + 4;
                end
            end
            st <= S_FILL; st_after_fill <= S_DECODE;
        end

        // ---- F12 two-operand groups ----
        // MOV/logic/arith B/H/W + friends: route through generic F12 engine
        8'h01,                                   // LDTASK
        8'h09, 8'h0a, 8'h0b, 8'h0c, 8'h0d,       // MOVB, MOVSBH, MOVZBH, MOVSBW, MOVZBW
        8'h19, 8'h1b, 8'h1c, 8'h1d,              // MOVTHB, MOVH, MOVSHW, MOVZHW
        8'h29, 8'h2b, 8'h2c, 8'h2d, 8'h08,       // MOVTWB, MOVTWH, RVBYT, MOVW, RVBIT
        8'h38, 8'h39, 8'h3a, 8'h3b, 8'h3c, 8'h3d,// NOT/NEG B/H/W
        8'h40, 8'h42, 8'h44,                     // MOVEA B/H/W
        8'h41, 8'h43, 8'h45,                     // XCH B/H/W
        8'h47,                                   // SETF
        8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55,// REM/REMU B/H/W
        8'h80, 8'h81, 8'h82, 8'h83, 8'h84, 8'h85,// ADD/MUL B/H/W
        8'h88, 8'h89, 8'h8a, 8'h8b, 8'h8c, 8'h8d,// OR/ROT B/H/W
        8'h90, 8'h91, 8'h92, 8'h93, 8'h94, 8'h95,// ADDC/MULU
        8'h98, 8'h99, 8'h9a, 8'h9b, 8'h9c, 8'h9d,// SUBC/ROTC
        8'ha0, 8'ha1, 8'ha2, 8'ha3, 8'ha4, 8'ha5,// AND/DIV
        8'ha7, 8'h97, 8'h87, 8'hb7,              // CLR1/SET1/TEST1/NOT1
        8'ha8, 8'ha9, 8'haa, 8'hab, 8'hac, 8'had,// SUB/SHL
        8'hb0, 8'hb1, 8'hb2, 8'hb3, 8'hb4, 8'hb5,// XOR/DIVU
        8'hb8, 8'hb9, 8'hba, 8'hbb, 8'hbc, 8'hbd,// CMP/SHA
        8'h86, 8'h96, 8'ha6, 8'hb6,              // MULX/MULUX/DIVX/DIVUX
        8'h3f: begin                             // MOVD (64-bit move)
            instflags <= fb[1];
            cls <= C_F12;
            st <= S_IF2;
        end

        // ---- single-operand format (opcode LSB = modm), operand at PC+1 ----
        8'hd0, 8'hd1, 8'hd2, 8'hd3, 8'hd4, 8'hd5,          // DEC B/H/W
        8'hd8, 8'hd9, 8'hda, 8'hdb, 8'hdc, 8'hdd,          // INC B/H/W
        8'hd6, 8'hd7,                                      // JMP
        8'he0, 8'he1,                                      // TASI
        8'he6, 8'he7,                                      // POP
        8'he8, 8'he9,                                      // JSR
        8'hee, 8'hef,                                      // PUSH
        8'he4, 8'he5, 8'hec, 8'hed,                        // POPM/PUSHM
        8'hf0, 8'hf1, 8'hf2, 8'hf3, 8'hf4, 8'hf5,          // TEST B/H/W
        8'hf6, 8'hf7,                                      // GETPSW
        8'hf8, 8'hf9,                                      // TRAP
        8'hfc, 8'hfd,                                      // STTASK
        8'hfe, 8'hff,                                      // CLRTLB (operand consumed; MMU absent)
        8'hde, 8'hdf,                                      // PREPARE
        8'he2, 8'he3,                                      // RET
        8'hea, 8'heb, 8'hfa, 8'hfb: begin                  // RETIU/RETIS
            cls <= C_SHORT;
            ea_modm  <= opcode[0];
            ea_ofs   <= 5'd1;
            ea_target2 <= 1'b0;
            // choose value vs address per op
            casez (opcode)
                // JMP/JSR/TASI: MAME sets moddim=0 — the dim scales INDEXED
                // modes' index register, and ga2's jump tables (3-byte BR
                // entries, `JMP [PC+d](rN)`) rely on the unscaled index
                // (found by real-ROM boot: dim=2 quadrupled the index and
                // jumped mid-table into a reserved-op trap)
                8'hd6, 8'hd7, 8'he8, 8'he9: begin ea_want_addr <= 1'b1; ea_dim <= 2'd0; end // JMP/JSR
                8'he0, 8'he1: begin ea_want_addr <= 1'b1; ea_dim <= 2'd0; end               // TASI (byte)
                8'hee, 8'hef: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end               // PUSH val
                // GETPSW writes PSW to its operand — decode as a destination
                // address so flag1 distinguishes reg vs memory.  Decoding it as
                // a value left flag1=0, so a register destination wrote PSW to
                // wild RAM and never updated the register (audit R20 V60-3).
                8'hf6, 8'hf7: begin ea_want_addr <= 1'b1; ea_dim <= 2'd2; end               // GETPSW dst addr
                8'he6, 8'he7: begin ea_want_addr <= 1'b1; ea_dim <= 2'd2; end               // POP dst addr
                8'hd0, 8'hd1, 8'hd8, 8'hd9: begin ea_want_addr <= 1'b1; ea_dim <= 2'd0; end // DEC/INC B (RMW)
                8'hd2, 8'hd3, 8'hda, 8'hdb: begin ea_want_addr <= 1'b1; ea_dim <= 2'd1; end
                8'hd4, 8'hd5, 8'hdc, 8'hdd: begin ea_want_addr <= 1'b1; ea_dim <= 2'd2; end
                8'hf0, 8'hf1: begin ea_want_addr <= 1'b0; ea_dim <= 2'd0; end               // TEST reads
                8'hf2, 8'hf3: begin ea_want_addr <= 1'b0; ea_dim <= 2'd1; end
                8'hf4, 8'hf5: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end
                8'hf8, 8'hf9: begin ea_want_addr <= 1'b0; ea_dim <= 2'd0; end               // TRAP vector operand
                8'hfc, 8'hfd: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end               // STTASK mask
                8'hfe, 8'hff: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end               // CLRTLB operand
                8'hde, 8'hdf: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end               // PREPARE imm
                8'he2, 8'he3: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end // RET adj (word)
                8'hea, 8'heb, 8'hfa, 8'hfb:
                              begin ea_want_addr <= 1'b0; ea_dim <= 2'd1; end // RETI adj (halfword, MAME moddim=1)
                8'he4, 8'he5, 8'hec, 8'hed:
                              begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end               // POPM/PUSHM mask (imm)
                default: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end
            endcase
            ea_ret <= 3'd0;
            st <= S_EA_MODE;
            st_after_ea <= S_EXEC;
        end

        // ---- GETPSW is a write op: handle as address ----
        // (covered above; exec handles)

        // ---- string groups (A1): F7a operand+length encoding ----
        //   subop @ fb[1]; op1 = source EA (modm=subop[6]) @ ofs2;
        //   len1 byte follows op1; op2 = dest EA (modm=subop[5]); len2 byte.
        8'h58, 8'h5a: begin  // byte/half string ops
            subop <= fb[1];
            case (fb[1][4:0])
            5'h00, 5'h01, 5'h02,
            5'h08, 5'h09, 5'h0a, 5'h0b, 5'h0c,
            5'h18, 5'h19, 5'h1a, 5'h1b: begin
                cls <= C_STRING;
                ea_want_addr <= 1'b1;
                // MAME F7a/F7b decode with dim 0 (0x58 byte) / 1 (0x5A half):
                // autoincrement/indexed AMs step and scale by the element
                // size, and F7b immediates size accordingly — not dword.
                ea_dim   <= fb[0][1] ? 2'd1 : 2'd0;
                ea_modm  <= fb[1][6];
                ea_ofs   <= 5'd2;
                ea_target2 <= 1'b0;
                ea_ret   <= 3'd0;
                st <= S_EA_MODE;
                st_after_ea <= S_STR_OP1;
            end
            default: begin
                exc_vector <= 8'd8;
                exc_pushval <= psw;
                st <= S_EXC_PUSH1;
            end
            endcase
        end
        8'h59: begin
            // decimal group (F7c): op1 = value, op2 = address, ext byte.
            // MAME implements ADDDC/SUBDC/SUBRDC/CVTDPZ/CVTDZP (radm timer);
            // remaining subops are reserved there too.
            subop <= fb[1];
            case (fb[1][4:0])
            5'h00, 5'h01, 5'h02, 5'h10, 5'h18: begin
                cls <= C_STRING;
                ea_want_addr <= 1'b0;                            // op1 value
                ea_dim  <= (fb[1][4:0] == 5'h18) ? 2'd1 : 2'd0;  // CVTDZP: half
                ea_modm <= fb[1][6];
                ea_ofs  <= 5'd2;
                ea_target2 <= 1'b0;
                ea_ret  <= 3'd0;
                st <= S_EA_MODE;
                st_after_ea <= S_DEC_OP1;
            end
            default: begin
                exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                // synthesis translate_off
                $display("V60: unimplemented 59 sub %02x at %08x", fb[1], pc);
                // synthesis translate_on
            end
            endcase
        end
        8'h5b: begin
            // bit strings: SCH0BSU(0)/SCH1BSU(2), MOVBSU(8)/MOVBSD(9)
            subop <= fb[1];
            case (fb[1][4:0])
            5'h00, 5'h02, 5'h08, 5'h09: begin
                cls <= C_STRING;
                bam_flow <= fb[1][3] ? 2'd3 : 2'd2;   // MOVBS : SCHBS
                bam_second <= 1'b0;
                ea_modm <= fb[1][6];
                ea_ofs  <= 5'd2;
                st <= S_BAM_MODE;
            end
            default: begin
                exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                // synthesis translate_off
                $display("V60: unimplemented 5B sub %02x at %08x", fb[1], pc);
                // synthesis translate_on
            end
            endcase
        end
        8'h5d: begin
            // bit fields: EXTBFS(8)/EXTBFZ(9)/EXTBFL(A), INSBFR(18)/INSBFL(19)
            subop <= fb[1];
            case (fb[1][4:0])
            5'h08, 5'h09, 5'h0a: begin              // EXTBF*: op1 = bit VALUE
                cls <= C_STRING;
                bam_flow <= 2'd0;
                bam_second <= 1'b0;
                ea_modm <= fb[1][6];
                ea_ofs  <= 5'd2;
                st <= S_BAM_MODE;
            end
            5'h18, 5'h19: begin                     // INSBF*: op1 = word value
                cls <= C_STRING;
                bam_flow <= 2'd1;
                ea_want_addr <= 1'b0;
                ea_dim  <= 2'd2;
                ea_modm <= fb[1][6];
                ea_ofs  <= 5'd2;
                ea_target2 <= 1'b0;
                ea_ret  <= 3'd0;
                st <= S_EA_MODE;
                st_after_ea <= S_BF_INS1;
            end
            default: begin
                exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                // synthesis translate_off
                $display("V60: unimplemented 5D sub %02x at %08x", fb[1], pc);
                // synthesis translate_on
            end
            endcase
        end
        8'h5c, 8'h5f: begin
`ifdef S32_V60_NO_FP
            // Golden Axe never executes the optional floating-point groups.
            //
            // That is a claim about GOLDEN AXE and says nothing about Virtua
            // Racing. It is the same shape as the "io space unused on S32"
            // comment that cost days on the IN/OUT path: accurate about its own
            // board, load-bearing, and silently wrong elsewhere. Before spending
            // this lever on Model 1, get Model 1's own evidence — dbg_fp_trap
            // under a build with the define, through attract and a race.
            // Keep their architectural fallback while removing the entire
            // decode/data path from this dedicated build.
            exc_vector <= 8'd8;
            exc_pushval <= psw;
            st <= S_EXC_PUSH1;
            dbg_fp_trap <= 1'b1;
            // synthesis translate_off
            $display("V60: reserved FP opcode %02x at %08x", opcode, pc);
            // synthesis translate_on
`else
            // single-precision FP group (op2.hxx / op5.hxx).  Second byte is the
            // sub-opcode; op1 is decoded as a value (ReadAM), op2 later per role.
            // Unhandled sub-opcodes still take the reserved-instruction vector
            // exactly as MAME's op5C/op5F UNHANDLED entries fatalerror.
            subop <= fb[1];
            if (fp_valid(opcode, fb[1][4:0])) begin
                ea_want_addr <= 1'b0;                    // op1 = value
                ea_dim   <= fp_dim1(opcode, fb[1][4:0]); // SCLFS op1 is half
                ea_modm  <= fb[1][6];
                ea_ofs   <= 5'd2;
                ea_target2 <= 1'b0;
                ea_ret   <= 3'd0;
                st <= S_EA_MODE;
                st_after_ea <= S_FP_OP2;
            end
            else begin
                exc_vector <= 8'd8;
                exc_pushval <= psw;
                st <= S_EXC_PUSH1;
                // synthesis translate_off
                $display("V60: unimplemented FP group %02x sub %02x at %08x", opcode, fb[1], pc);
                // synthesis translate_on
            end
`endif
        end

        // ---- privileged / system ----
        8'h02: begin // STPR: privileged reg -> operand : treat via F12-like short path
            instflags <= fb[1]; cls <= C_F12; st <= S_IF2;
        end
        8'h12: begin // LDPR
            instflags <= fb[1]; cls <= C_F12; st <= S_IF2;
        end
        8'h13, 8'h4a: begin // UPDPSW.W / UPDPSW.H
            instflags <= fb[1]; cls <= C_F12; st <= S_IF2;
        end
        8'h4b: begin instflags <= fb[1]; cls <= C_F12; st <= S_IF2; end // CHLVL
        8'h4d, 8'h4e, 8'h4f: begin instflags <= fb[1]; cls <= C_F12; st <= S_IF2; end // CHKA*
        8'h49: begin instflags <= fb[1]; cls <= C_F12; st <= S_IF2; end // CALL
        8'hcc: begin // DISPOSE: SP = FP (R30), pop FP
            queue_reg_write(5'd31, r[30], 32'hffff_ffff);
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2; dbus_addr <= r[30];
            st <= S_DISP1;
        end
        8'hca: begin // RSR (A9): pop PC ONLY (MAME opRSR: PC=[SP]; SP+=4)
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2; dbus_addr <= r[31];
            st <= S_RSR;
        end
        8'hcb: begin // TRAPFL
            // MAME/NEC floating-exception test: enabled TKCW causes are
            // intersected with the PSW floating-status field.  PSW.TP alone
            // is unrelated and must not spuriously vector here.
            if ((tkcw & 32'h0000_01f0) & ((psw & 32'h0000_1f00) >> 4)) begin
                exc_vector <= 8'd15; exc_pushval <= psw; st <= S_EXC_PUSH1;
            end else begin
                pc <= pc + 1; st <= S_FILL; st_after_fill<=S_DECODE;
            end
        end
        8'h10: begin // CLRTLBA: no MMU -> one-byte NOP
            pc <= pc + 1;
            st <= S_FILL; st_after_fill <= S_DECODE;
        end
        8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25: begin // IN/OUT -> F12 engine
            instflags <= fb[1]; cls <= C_F12; st <= S_IF2;
        end

        default: begin
            // reserved instruction
            // synthesis translate_off
            $display("V60: reserved opcode %02x at %08x", opcode, pc);
            // synthesis translate_on
            exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
        end
        endcase
        end
    end

    // ------------------------------------------------------------------
    // F12: plan operands per instflags (MAME F12DecodeOperands)
    S_IF2: begin
        // operand roles: for most ops op1=ReadAM(value), op2=addr(write) —
        // exceptions handled in S_EXEC via flags.
        if (instflags[7]) begin
            // F1: both operands have mode bytes
            ea_modm  <= instflags[6];
            ea_ofs   <= 5'd2;
            ea_target2 <= 1'b0;
            // MOVEA takes op1 as an ADDRESS (MAME ReadAMAddress) — decoding
            // it as a value loaded SP with a byte read instead of the EA and
            // sent ga2's boot stub off a cliff (found by real-ROM boot)
            ea_want_addr <= f12_op1_is_addr(cur_op);
            ea_dim   <= f12_dim1(cur_op);
            ea_ret   <= 3'd1;       // after op1 -> decode op2
            st <= S_EA_MODE;
            st_after_ea <= S_EXEC;  // will be overridden by ea_ret handling
        end
        else begin
            if (instflags[5]) begin
                // F2 D=1: op2 = reg, op1 = AM
                op2   <= {27'b0, instflags[4:0]};
                flag2 <= 1'b1;
                len2  <= 0;
                ea_modm <= instflags[6];
                ea_ofs  <= 5'd2;
                ea_target2 <= 1'b0;
                ea_want_addr <= f12_op1_is_addr(cur_op);
                ea_dim  <= f12_dim1(cur_op);
                ea_ret  <= 3'd0;
                st <= S_EA_MODE;
                st_after_ea <= S_EXEC;
            end
            else begin
                // F2 D=0: op1 = reg value, op2 = AM(write)
                // XCH.B/H/W exception: op1 is an LVALUE (the swap needs the
                // register NUMBER, not its value). The generic value path left
                // flag1=0, so XCH's exec (flag1&&flag2 fails) took the
                // register<->memory branch and wrote R[op1] to a bogus address
                // instead of swapping the two registers. This corrupted ga2's
                // char-select object spawn (xch.w R19,R20 at 0x063BEB/0x063BF1),
                // so the character objects never got their active flag/handler
                // and the on-scale character never rendered. f12_op1_is_addr
                // already classifies XCH op1 as an address for the F1/F2-D=1
                // paths; this closes the F2-D=0 gap. (encoding 45 53 74)
                if (cur_op == 8'h41 || cur_op == 8'h43 || cur_op == 8'h45) begin
                    op1   <= {27'b0, instflags[4:0]};
                    flag1 <= 1'b1;
                end
                else begin
                    op1   <= dimext(rf_rdata_a, f12_dim1(cur_op));
                    flag1 <= 1'b0;
                end
                len1  <= 0;
                ea_modm <= instflags[6];
                ea_ofs  <= 5'd2;
                ea_target2 <= 1'b1;
                ea_want_addr <= 1'b1;   // op2 as address for write
                ea_dim  <= f12_dim2(cur_op);
                ea_ret  <= 3'd0;
                st <= S_EA_MODE;
                st_after_ea <= S_EXEC;
            end
        end
    end

    // ------------------------------------------------------------------
    // EA engine.
    // NOTE: all fb-reading helper functions (disp_of/fb16/fb32) are hoisted
    // into blocking temporaries before use in nonblocking assignments —
    // the Verilator simulator (5.020) mis-evaluates such calls in an NBA RHS
    // inside this case tree (found by real-ROM boot: ga2's MOVEA PC-relative
    // displacement silently read as 0).
    S_EA_MODE: begin
        logic [31:0] d1t, d2t;
        ea_flag  <= 1'b0;
        ea_isval <= 1'b0;
        if (!ea_modm) begin
            case (modtop)
            3'd0, 3'd1, 3'd2: begin // Displacement
                d1t = disp_from(fbw_ea1, modtop[1:0]);
                ea_addr <= rf_rdata_a + d1t;
                ea_len  <= 5'd1 + disp_len(modtop[1:0]);
                st <= st_t'(ea_want_addr ? S_EA_DONE : S_EA_VAL);
            end
            3'd3: begin             // Register Indirect
                ea_addr <= rf_rdata_a;
                ea_len  <= 5'd1;
                st <= st_t'(ea_want_addr ? S_EA_DONE : S_EA_VAL);
            end
            3'd4, 3'd5, 3'd6: begin // Displacement Indirect (deferred)
                d1t = disp_from(fbw_ea1, modtop - 3'd4);
                dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
                dbus_addr <= rf_rdata_a + d1t;
                ea_len  <= 5'd1 + disp_len(modtop - 3'd4);
                st <= S_EA_IND;
            end
            default: begin          // Group 7
                casez (modreg)
                5'b0????: begin      // immediate quick
                    ea_out <= {28'b0, modreg[3:0]};
                    ea_len <= 5'd1;
                    ea_flag <= 1'b0;
                    ea_isval <= 1'b1;
                    st <= S_EA_DONE;  // value already
                end
                5'h10, 5'h11, 5'h12: begin // PC displacement
                    d1t = disp_from(fbw_ea1, modreg[1:0]);
                    ea_addr <= pc + d1t;
                    ea_len  <= 5'd1 + disp_len(modreg[1:0]);
                    st <= st_t'(ea_want_addr ? S_EA_DONE : S_EA_VAL);
                end
                5'h13: begin        // direct address
                    d1t = fbw_ea1;
                    ea_addr <= d1t;
                    ea_len  <= 5'd5;
                    st <= st_t'(ea_want_addr ? S_EA_DONE : S_EA_VAL);
                end
                5'h14: begin        // immediate full
                    d1t = fbw_ea1;
                    d2t = {16'b0, fbw_ea1[15:0]};
                    case (ea_dim)
                        2'd0: ea_out <= {24'b0, fb[ea_ofs+1]};
                        2'd1: ea_out <= d2t;
                        default: ea_out <= d1t;
                    endcase
                    ea_len <= 5'd1 + imm_len(ea_dim);
                    ea_isval <= 1'b1;
                    st <= S_EA_DONE;
                end
                5'h18, 5'h19, 5'h1a: begin // PC displacement indirect
                    d1t = disp_from(fbw_ea1, modreg[1:0]);
                    dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
                    dbus_addr <= pc + d1t;
                    ea_len  <= 5'd1 + disp_len(modreg[1:0]);
                    st <= S_EA_IND;
                end
                5'h1b: begin        // direct address deferred
                    d1t = fbw_ea1;
                    dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
                    dbus_addr <= d1t;
                    ea_len  <= 5'd5;
                    st <= S_EA_IND;
                end
                5'h1c, 5'h1d, 5'h1e: begin // PC double displacement
                    d1t = disp_from(fbw_ea1, modreg[1:0]);
                    d2t = disp_of(ea_ofs+1+disp_len(modreg[1:0]), modreg[1:0]);
                    dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
                    dbus_addr <= pc + d1t;
                    ea_addr <= d2t;      // second disp follows first
                    ea_len  <= double_disp_len(modreg[1:0]); // 1 + 2*len
                    st <= S_EA_IND2;
                end
                default: begin
                    exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                end
                endcase
            end
            endcase
        end
        else begin
            case (modtop)
            3'd0, 3'd1, 3'd2: begin // Double displacement: [[reg+d1]+d2]
                d1t = disp_from(fbw_ea1, modtop[1:0]);
                d2t = disp_of(ea_ofs+1+disp_len(modtop[1:0]), modtop[1:0]);
                dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
                dbus_addr <= rf_rdata_a + d1t;
                ea_addr  <= d2t;
                ea_len   <= double_disp_len(modtop[1:0]);
                st <= S_EA_IND2;
            end
            3'd3: begin             // Register direct
                if (ea_want_addr) begin
                    ea_out  <= {27'b0, modreg};
                    ea_flag <= 1'b1;
                end
                else ea_out <= dimext(rf_rdata_a, ea_dim);
                ea_len <= 5'd1;
                st <= S_EA_DONE;
            end
            3'd4: begin             // Autoincrement
                ea_addr <= rf_rdata_a;
                queue_reg_write(modreg, rf_rdata_a + dim_step(ea_dim), 32'hffff_ffff);
                ea_len <= 5'd1;
                st <= st_t'(ea_want_addr ? S_EA_DONE : S_EA_VAL);
            end
            3'd5: begin             // Autodecrement
                ea_addr <= rf_rdata_a - dim_step(ea_dim);
                queue_reg_write(modreg, rf_rdata_a - dim_step(ea_dim), 32'hffff_ffff);
                ea_len <= 5'd1;
                st <= st_t'(ea_want_addr ? S_EA_DONE : S_EA_VAL);
            end
            3'd6: begin             // Group 6: indexed, second mode byte
                case (modval2[7:5])
                3'd0, 3'd1, 3'd2: begin // Displacement indexed: [reg2+disp] + reg1*size
                    d1t = disp_from(fbw_ea2, modval2[6:5]);
                    ea_addr <= rf_rdata_b + d1t + ea_index;
                    ea_len  <= 5'd2 + disp_len(modval2[6:5]);
                    st <= st_t'(ea_want_addr ? S_EA_DONE : S_EA_VAL);
                end
                3'd3: begin            // Register indirect indexed
                    ea_addr <= rf_rdata_b + ea_index;
                    ea_len  <= 5'd2;
                    st <= st_t'(ea_want_addr ? S_EA_DONE : S_EA_VAL);
                end
                3'd4, 3'd5, 3'd6: begin // Displacement indirect indexed
                    d1t = disp_from(fbw_ea2, modval2[6:5]);
                    dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
                    dbus_addr <= rf_rdata_b + d1t;
                    ea_addr <= ea_index;  // index added after deref
                    ea_len  <= 5'd2 + disp_len(modval2[6:5]);
                    st <= S_EA_IND2;
                end
                default: begin // Group7a: PC/direct indexed
                    if (!modval2[4]) begin
                        exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                    end
                    else case (modval2[3:0])
                    4'h0, 4'h1, 4'h2: begin
                        d1t = disp_from(fbw_ea2, modval2[1:0]);
                        ea_addr <= pc + d1t + ea_index;
                        ea_len  <= 5'd2 + disp_len(modval2[1:0]);
                        st <= st_t'(ea_want_addr ? S_EA_DONE : S_EA_VAL);
                    end
                    4'h3: begin
                        d1t = fbw_ea2;
                        ea_addr <= d1t + ea_index;
                        ea_len  <= 5'd6;
                        st <= st_t'(ea_want_addr ? S_EA_DONE : S_EA_VAL);
                    end
                    4'h8, 4'h9, 4'ha: begin
                        d1t = disp_from(fbw_ea2, modval2[1:0]);
                        dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
                        dbus_addr <= pc + d1t;
                        ea_addr <= ea_index;
                        ea_len  <= 5'd2 + disp_len(modval2[1:0]);
                        st <= S_EA_IND2;
                    end
                    4'hb: begin
                        d1t = fbw_ea2;
                        dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
                        dbus_addr <= d1t;
                        ea_addr <= ea_index;
                        ea_len  <= 5'd6;
                        st <= S_EA_IND2;
                    end
                    default: begin
                        exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                    end
                    endcase
                end
                endcase
            end
            default: begin
                exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
            end
            endcase
        end
    end

    // deferred pointer fetched -> address is pointer (+0)
    S_EA_IND: if (dack) begin
        dbus_req <= 0;
        ea_addr <= bus_rdata;
        st <= st_t'(ea_want_addr ? S_EA_DONE : S_EA_VAL);
    end
    // deferred pointer fetched -> address = pointer + saved offset (double disp / indexed deferred)
    S_EA_IND2: if (dack) begin
        dbus_req <= 0;
        ea_addr <= bus_rdata + ea_addr;
        st <= st_t'(ea_want_addr ? S_EA_DONE : S_EA_VAL);
    end
    // load value at ea_addr
    S_EA_VAL: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0;
            dbus_size <= ea_dim;
            dbus_addr <= ea_addr;
        end
        else if (dack) begin
            dbus_req <= 0;
            ea_out <= dimext(bus_rdata, ea_dim);
            st <= S_EA_DONE;
        end
    end
    S_EA_DONE: begin
        if (ea_want_addr && !ea_flag && st == S_EA_DONE) begin
            // address results: pass ea_addr unless already produced (imm/reg)
        end
        // Immediate modes carry no address: the "address requested" path
        // must still hand back the value (MAME LDPR-quirk equivalent), and
        // op2 immediates pre-fill op2val so S_OP2_LD never dereferences a
        // stale ea_addr (found by real-ROM boot: ga2's `LDPR #imm, #5`
        // loaded SBR with garbage and the first vblank IRQ derailed).
        if (!ea_target2) begin
            op1   <= (ea_want_addr && !ea_isval) ? (ea_flag ? ea_out : ea_addr) : ea_out;
            flag1 <= ea_flag;
            len1  <= ea_len;
        end
        else begin
            op2   <= (ea_want_addr && !ea_isval) ? (ea_flag ? ea_out : ea_addr) : ea_out;
            flag2 <= ea_flag;
            len2  <= ea_len;
            if (ea_isval) begin
                op2val   <= ea_out;
                op2val_v <= 1'b1;
            end
        end
        // continuation: ea_ret==1 -> decode operand 2 (F1)
        if (ea_ret == 3'd1) begin
            ea_ret <= 3'd0;
            ea_modm <= instflags[5];
            ea_ofs  <= 5'd2 + ea_len;
            ea_target2 <= 1'b1;
            ea_want_addr <= 1'b1;    // op2 default = address (write target)
            ea_dim  <= f12_dim2(cur_op);
            st <= S_EA_MODE;
        end
        else st <= st_after_ea;
    end

    // ------------------------------------------------------------------
    // EXEC: per-opcode semantics on op1/op2
    S_EXEC: begin
        if (cls == C_F12 && !flag2 && !op2val_v && f12_reads_dest(cur_op)) begin
            st <= S_OP2_LD;   // V60-1: load memory destination before exec
        end
        else begin
            st <= S_NEXT;   // default: single-cycle exec, then advance
            total_len <= 5'd2 + len1 + len2;
            exec_op();      // task below sets wb / flags / possibly overrides st
        end
    end
    S_OP2_LD: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0;
            dbus_size <= f12_dim2(cur_op);
            dbus_addr <= op2;
        end
        else if (dack) begin
            dbus_req <= 0;
            op2val   <= dimext(bus_rdata, f12_dim2(cur_op));
            op2val_v <= 1'b1;
            st <= S_EXEC;
        end
    end

    // iterative multiply/divide
    S_MULDIV: begin
        if (mdcnt == 0) begin
            md_finish();
            st <= S_NEXT;
        end
        else begin
            md_step();
            mdcnt <= mdcnt - 1'd1;
        end
    end

    // DIVX/DIVUX: unsigned magnitude division followed by architectural sign
    // correction.  Sixty-four iterations preserve the old 64-bit expression,
    // including low-32 quotient truncation when the mathematical result is
    // wider than the destination register.
    S_DIVX: begin
        xdiv_shift <= xdiv_shift_next;
        xdiv_rem <= xdiv_rem_next;
        if (xdiv_cnt == 6'd63) begin
            f_z <= (xdiv_qresult == 0);
            f_s <= xdiv_qresult[31];
            // MAME opDIVX/opDIVUX set only S/Z and leave OV unchanged; do not clear it.
            xdiv_active <= 1'b0;
            if (divx_mem) begin
                // write quotient -> [op2], remainder -> [op2]+4 (audit V60-9)
                movd_lo <= xdiv_qresult;
                movd_hi <= xdiv_rresult;
                st <= S_MOVD_WL;
            end
            else begin
                queue_reg_write(xdiv_dst, xdiv_qresult, 32'hffff_ffff);
                queue_reg_write(xdiv_dst + 5'd1, xdiv_rresult, 32'hffff_ffff);
                st <= S_NEXT;
            end
        end
        else xdiv_cnt <= xdiv_cnt + 1'd1;
    end

    // ROTC: 1 bit/cycle through carry (V60-5)
    S_ROTC: begin
        if (rotc_cnt == 0) begin
            logic [1:0] d2l;
            d2l = f12_dim2(cur_op);
            set_zs(rotc_val, d2l);
            f_ov <= 0;
            wb_op2(rotc_val, d2l);
            // Same dropped-store pattern as S_IN_RD: the guard read the OLD st,
            // so a memory destination's S_WB_MEM was always overridden. Found by
            // scanning for the pattern after the IN fix, not by a failing test.
            if (flag2) st <= S_NEXT;
        end
        else if (rotc_cnt > 0) begin
            logic [1:0] d2l;
            logic msb;
            d2l = f12_dim2(cur_op);
            msb = sgn(rotc_val, d2l);
            // MAME opROTC*: the carry bit enters the active operand's LSB;
            // bits above a byte/halfword operand are not part of the ring.
            case (d2l)
                2'd0: rotc_val <= {24'b0, rotc_val[6:0], f_cy};
                2'd1: rotc_val <= {16'b0, rotc_val[14:0], f_cy};
                default: rotc_val <= {rotc_val[30:0], f_cy};
            endcase
            f_cy <= msb;
            rotc_cnt <= rotc_cnt - 8'sd1;
        end
        else begin
            logic [1:0] d2l;
            logic ls;
            d2l = f12_dim2(cur_op);
            ls = rotc_val[0];
            // Right rotate-through-carry enters at bit 7/15/31 according
            // to the destination width (op12.hxx opROTCB/H/W).
            case (d2l)
                2'd0: rotc_val <= {24'b0, f_cy, rotc_val[7:1]};
                2'd1: rotc_val <= {16'b0, f_cy, rotc_val[15:1]};
                default: rotc_val <= {f_cy, rotc_val[31:1]};
            endcase
            f_cy <= ls;
            rotc_cnt <= rotc_cnt + 8'sd1;
        end
    end

    // generic memory RMW: read op2 -> modify per rmw_kind -> write back
    S_RMW_RD: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= rmw_dim; dbus_addr <= op2;
        end
        else if (dack) begin
            dbus_req <= 0;
            alu_r <= bus_rdata;
            st <= S_RMW_EX;
        end
    end
    S_RMW_EX: begin
        logic [31:0] v;
        logic [4:0]  bi;
        v = alu_r;
        bi = wb_val[4:0];
        case (rmw_kind)
            3'd0: begin // INC
                v = dimext(alu_r, rmw_dim) + 1;
                f_cy <= zer(v, rmw_dim);        // carry when wrapped to 0
                f_ov <= ~sgn(alu_r, rmw_dim) & sgn(v, rmw_dim); // +max -> negative
                set_zs(v, rmw_dim);
            end
            3'd1: begin // DEC
                f_cy <= zer(alu_r, rmw_dim);    // borrow when was 0
                v = dimext(alu_r, rmw_dim) - 1;
                f_ov <= sgn(alu_r, rmw_dim) & ~sgn(v, rmw_dim); // -min -> positive
                set_zs(v, rmw_dim);
            end
            3'd2: begin f_z <= ~alu_r[bi]; f_cy <= alu_r[bi]; v[bi] = 1'b1; end // SET1
            3'd3: begin f_z <= ~alu_r[bi]; f_cy <= alu_r[bi]; v[bi] = 1'b0; end // CLR1
            3'd4: begin f_z <= ~alu_r[bi]; f_cy <= alu_r[bi]; v[bi] = ~alu_r[bi]; end // NOT1
            default: begin f_z <= ~alu_r[bi]; f_cy <= alu_r[bi]; end            // TEST1
        endcase
        if (rmw_kind == 3'd5) st <= S_NEXT;      // TEST1: no write
        else begin
            wb_val <= v;
            // write via S_WB_MEM but with rmw width
            st <= S_WB_MEM;
        end
    end

    // XCH reg<->mem: read mem, write reg value to mem, mem value to reg
    S_XCH1: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= rmw_dim; dbus_addr <= xch_addr;
        end
        else if (dack) begin
            // drop the request for one cycle — the bus adapter starts a new
            // transaction on a c_req RISING EDGE; re-asserting back-to-back
            // deadlocked ga2's XCH.W lock idiom (found by real-ROM boot)
            dbus_req <= 0;
            setreg(wb_val[4:0], bus_rdata, rmw_dim);   // mem -> reg
            st <= S_XCH2;
        end
    end
    S_XCH2: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1; dbus_size <= rmw_dim;
            dbus_addr <= xch_addr; dbus_wdata <= alu_r;  // reg -> mem
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            st <= S_NEXT;
        end
    end

    // DIVX/DIVUX memory dividend: read the high word at [op2]+4 (low word is in
    // op2val), set up the restoring divide, and mark the result for memory
    // writeback (audit V60-9).
    S_DIVXM_RH: begin
        if (!dbus_req) begin dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2; dbus_addr <= op2 + 32'd4; end
        else if (dack) begin
            logic [63:0] num, mag_num;
            logic [31:0] mag_den;
            dbus_req <= 0;
            num = {bus_rdata, op2val};   // {high, low}
            if (cur_op == 8'ha6) begin   // DIVX (signed)
                mag_num = num[63] ? (~num + 1'b1) : num;
                mag_den = op1[31] ? (~op1 + 1'b1) : op1;
                xdiv_qneg <= num[63] ^ op1[31];
                xdiv_rneg <= num[63];
            end
            else begin                   // DIVUX (unsigned)
                mag_num = num;
                mag_den = op1;
                xdiv_qneg <= 1'b0;
                xdiv_rneg <= 1'b0;
            end
            xdiv_shift  <= mag_num;
            xdiv_rem    <= 0;
            xdiv_den    <= mag_den;
            xdiv_cnt    <= 0;
            xdiv_active <= 1'b1;
            divx_mem    <= 1'b1;
            st <= S_DIVX;
        end
    end

    // MOVD 64-bit transfer (audit V60-10): read the source qword low/high, then
    // write the destination qword low/high.  Register ends are handled directly
    // in the exec; only memory ends use these states.
    // IN: read the I/O address in op1 and write the result to op2. Size comes
    // from the opcode's low bits, the same encoding the F12 engine uses.
    S_IN_RD: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= cur_op[2:1]; dbus_addr <= op1;
        end else if (dack) begin
            dbus_req <= 0;
            wb_op2(dimext(bus_rdata, cur_op[2:1]), cur_op[2:1]);
            // IN WITH A MEMORY DESTINATION NEVER STORED. This used to read
            //
            //     if (st == S_IN_RD) st <= S_NEXT;   // wb_op2 may divert to S_WB_MEM
            //
            // but wb_op2's `st <= S_WB_MEM` is non-blocking, so `st` still reads
            // S_IN_RD here, the guard is always true, and the later assignment
            // wins: the port was read correctly and the value was thrown away.
            // Register destinations were fine, which is why `in.w [R23], R0`
            // paths worked and `in.w [R23], [R4+]` paths - the FEDA55 matrix
            // fill, the FF850C result block into copro RAM - silently did not.
            //
            // Measured 2026-08-30 on the frame bench: the read at feda55 returned
            // c34e5382, the reference's exact matrix value, and no write to
            // 0x400d72 ever followed; the matrix stayed at its init zeros and was
            // pushed back to the coprocessor as 00000000 x4 at command 673.
            // No unit test covers IN with a memory destination.
            if (flag2) st <= S_NEXT;           // register dest: done
            // else wb_op2 has set S_WB_MEM, which issues the store
        end
    end

    // OUT: write op1's VALUE to the I/O address in op2. THE OPERANDS WERE SWAPPED.
    //
    // MAME, op12.hxx opOUTB:
    //     F12DecodeOperands(&ReadAM, 0, &ReadAMAddress, 2);
    //     m_io->write_byte(m_op2, (uint8_t)m_op1);
    //
    // Address is op2, data is op1 — and IN is the OTHER WAY ROUND, which is how
    // this was got wrong: opINB decodes its first operand with ReadAMAddress, so
    // for IN op1 IS the address. f12_op1_is_addr already encodes that difference
    // correctly and lists IN but not OUT, so op1 here has always held the value;
    // only this state used it as an address.
    //
    // Found by tools/v60_trace.sh. The instruction streams matched MAME for
    // 197,250 instructions, then memory diverged — `out.b #40, 10002[R0]` wrote to
    // address 0x000040, the immediate, instead of sending 0x40 to port 0xC10002.
    // Virtua Racing configures its I/O board through those ports during boot, so
    // every one of them was lost.
    S_OUT_WR: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1; dbus_size <= cur_op[2:1];
            dbus_addr <= op2; dbus_wdata <= op1;
        end else if (dack) begin
            dbus_req <= 0; dbus_we <= 0; st <= S_NEXT;
        end
    end

    S_MOVD_RL: begin
        if (!dbus_req) begin dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2; dbus_addr <= op1; end
        else if (dack) begin dbus_req <= 0; movd_lo <= bus_rdata; st <= S_MOVD_RH; end
    end
    S_MOVD_RH: begin
        if (!dbus_req) begin dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2; dbus_addr <= op1 + 32'd4; end
        else if (dack) begin
            dbus_req <= 0; movd_hi <= bus_rdata;
            if (flag2) begin
                queue_reg_write(op2[4:0],        movd_lo,    32'hffffffff);
                queue_reg_write(op2[4:0] + 5'd1, bus_rdata,  32'hffffffff);
                st <= S_NEXT;
            end
            else st <= S_MOVD_WL;
        end
    end
    S_MOVD_WL: begin
        if (!dbus_req) begin dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2; dbus_addr <= op2; dbus_wdata <= movd_lo; end
        else if (dack) begin dbus_req <= 0; dbus_we <= 0; st <= S_MOVD_WH; end
    end
    S_MOVD_WH: begin
        if (!dbus_req) begin dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2; dbus_addr <= op2 + 32'd4; dbus_wdata <= movd_hi; end
        else if (dack) begin dbus_req <= 0; dbus_we <= 0; st <= S_NEXT; end
    end

    // memory writeback of wb_val to op2 address (dim = f12_dim2)
    S_WB_MEM: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1;
            dbus_size <= (rmw_kind != 3'd7) ? rmw_dim : f12_dim2(cur_op);
            dbus_addr <= op2;
            dbus_wdata <= wb_val;
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            st <= S_NEXT;
        end
    end

    // advance PC and refill
    S_NEXT: begin
        pc <= pc + total_len;
        st <= S_FILL; st_after_fill <= S_DECODE;
    end

    // ------------------------------------------------------------------
    // JSR/BSR: return pushed, jump
    S_JSR1: if (dack) begin
        dbus_req <= 0; dbus_we <= 0;
        pc <= wb_val;
        st <= S_FILL; st_after_fill <= S_DECODE;
    end

    // CALL (A6): AP push completes here, then push return PC and jump.
    S_CALL1: begin
        if (dack) begin               // AP push done
            // one-cycle request gap: the adapter needs a c_req rising edge
            dbus_req <= 0; dbus_we <= 0;
            st <= S_CALL1b;
        end
    end
    S_CALL1b: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
            dbus_addr <= sp_m4;
            dbus_wdata <= wb_val;          // return PC
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
        end
        else if (dack) begin           // return-PC push done
            dbus_req <= 0; dbus_we <= 0;
            pc <= alu_r;                  // target
            st <= S_FILL; st_after_fill <= S_DECODE;
        end
    end

    // RET (A5): pop PC, then restore AP (R30), then skip frame (SP += operand)
    S_RET1: if (dack) begin
        dbus_req <= 0;
        pc <= bus_rdata;
        queue_reg_write(5'd31, r[31] + 4, 32'hffff_ffff);
        st <= S_RET2;
    end
    S_RET2: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
            dbus_addr <= r[31];
        end
        else if (dack) begin
            dbus_req <= 0;
            queue_reg_write(5'd29, bus_rdata, 32'hffff_ffff); // AP (R29)
            queue_reg_write(5'd31, r[31] + 4 + wb_val, 32'hffff_ffff);
            st <= S_FILL; st_after_fill <= S_DECODE;
        end
    end

    // RETIU/RETIS/RSR: pop PC then PSW
    S_RETI1: if (dack) begin
        dbus_req <= 0;
        wb_val <= bus_rdata;   // new PC
        st <= S_RETI2;
    end
    S_RETI2: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
            dbus_addr <= sp_p4;
        end
        else if (dack) begin
            dbus_req <= 0;
            st <= S_RETI3;
            alu_r <= bus_rdata;  // new PSW
        end
    end
    S_RETI3: begin
        // pops (8) + frame-destroy operand (MAME: SP += amout), then the
        // PSW write may bank-switch SP — order matters: adjust THEN switch.
        queue_reg_write(5'd31, r[31] + 8 + xch_addr, 32'hffff_ffff);
        write_psw_after_sp(alu_r, r[31] + 8 + xch_addr);
        pc <= wb_val;
        st <= S_FILL; st_after_fill <= S_DECODE;
    end

    // DISPOSE: FP fetched
    S_DISP1: if (dack) begin
        dbus_req <= 0;
        queue_reg_write(5'd30, bus_rdata, 32'hffff_ffff); // FP = R30
        queue_reg_write(5'd31, r[31] + 4, 32'hffff_ffff);
        pc <= pc + 1;
        st <= S_FILL; st_after_fill <= S_DECODE;
    end

    // RSR (A9): pop PC only, SP += 4
    S_RSR: if (dack) begin
        dbus_req <= 0;
        pc <= bus_rdata;
        queue_reg_write(5'd31, r[31] + 4, 32'hffff_ffff);
        st <= S_FILL; st_after_fill <= S_DECODE;
    end

    // PUSHM/POPM iterate register mask in op1
    S_PUSHM: begin
        if (reg_ptr == 5'd31 && !op1[31]) begin
            // done check handled in loop below
        end
        if (op1 == 0) st <= S_NEXT;
        else if (!dbus_req) begin
            // push highest set register first (MAME pushes from r31 down? actual: PUSHM pushes ascending list to stack)
            // idx = lowest set bit; push in increasing register order
            logic [4:0] idx;
            idx = pushm_index(op1);
            dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
            dbus_addr <= sp_m4;
            // Mask bit 31 pushes PSW, not r31 (audit R20 V60-11): the old code
            // pushed the SP value there and PSW save/restore was lost.
            dbus_wdata <= (idx == 5'd31) ? psw : rf_rdata_a;
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
            reg_ptr <= idx;
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            op1[reg_ptr] <= 1'b0;
        end
    end
    S_POPM: begin
        if (op1 == 0) st <= S_NEXT;
        else if (!dbus_req) begin
            logic [4:0] idx;
            idx = 5'd0;
            for (int i = 31; i >= 0; i--) if (op1[i]) idx = i[4:0];
            // pop lowest-numbered... (POPM restores in reverse of PUSHM)
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
            dbus_addr <= r[31];
            reg_ptr <= idx;
        end
        else if (dack) begin
            dbus_req <= 0;
            // Mask bit 31 pops into the PSW low half, not r31 (audit R20 V60-11);
            // the high half (incl. IS/EL) is preserved, so no stack switch and no
            // conflict with the SP increment below.
            if (reg_ptr == 5'd31)
                write_psw((psw & 32'hffff_0000) | (bus_rdata & 32'h0000_ffff));
            else
                queue_reg_write(reg_ptr, bus_rdata, 32'hffff_ffff);
            queue_reg_write(5'd31, r[31] + 4, 32'hffff_ffff);
            op1[reg_ptr] <= 1'b0;
        end
    end

    // TASI: read byte at addr, set flags, write 0xFF
    S_TASI1: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd0; dbus_addr <= op1;
        end
        else if (dack) begin
            // TASI sets flags as SUBB(old, 0xFF, 0) before writing 0xFF (MAME
            // opTASI).  The old code had Z=(old!=0), inverted CY, S from `old`
            // instead of old+1, and never set OV (audit R20 V60-12).
            logic [7:0] old, res8;
            dbus_req <= 0;
            old  = bus_rdata[7:0];
            res8 = old - 8'hff;               // == old + 1
            f_z  <= (res8 == 8'h00);          // old == 0xFF
            f_s  <= res8[7];                  // (old+1)[7]
            f_cy <= (old != 8'hff);           // borrow when old < 0xFF
            f_ov <= ~old[7] & (old[7] ^ res8[7]);
            st <= S_TASI2;
        end
    end
    S_TASI2: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd0;
            dbus_addr <= op1; dbus_wdata <= 32'hff;
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            st <= S_NEXT;
        end
    end

    // PREPARE: push FP, FP=SP, SP-=imm
    S_PREP1: if (dack) begin
        dbus_req <= 0; dbus_we <= 0;
        queue_reg_write(5'd30, r[31] - 4, 32'hffff_ffff); // FP = R30
        queue_reg_write(5'd31, r[31] - 4 - op1, 32'hffff_ffff);
        st <= S_NEXT;
    end

    // ------------------------------------------------------------------
    // string operations (A1): F7a operand+length decode.
    //   op1 (from S_EA_DONE, ea_target2=0) = source address.
    //   length byte at fb[2+len1]; op2 = dest address; length at fb[3+len1+len2].
    //   R27 (dst) / R28 (src) updated at completion (MAME MOVSTR).
    S_STR_OP1: begin
        // op1 = source address; read len1 byte then decode op2
        logic [7:0] lb;
        str_src <= op1;
        lb = fb[5'd2 + len1];
        str_len1 <= lb[7] ? rf_rdata_a : {24'b0, lb};
        // decode op2 at ofs = 3 + len1. F7a (MOVC/CMPC): address. F7b
        // (SCHC/SKPC 0x18-0x1B): search VALUE, and no len2 byte follows.
        // Element-size dim for both (MAME dim 0 byte / 1 half — see decode).
        ea_want_addr <= (subop[4:0] >= 5'h18) ? 1'b0 : 1'b1;
        ea_dim   <= cur_op[1] ? 2'd1 : 2'd0;
        ea_modm  <= subop[5];
        ea_ofs   <= 5'd3 + len1;
        ea_target2 <= 1'b1;
        ea_ret   <= 3'd0;
        st <= S_EA_MODE;
        st_after_ea <= S_STR_OP2;
    end
    S_STR_OP2: begin
        logic [7:0] lb;
        logic [31:0] l2;
        str_dst <= op2;                      // F7b: search value lives here
        if (subop[4:0] >= 5'h18) begin
            // F7b: single length; count = len1
            total_len <= 5'd3 + len1 + len2;
            // V60-15: down-direction search (subop[0]=1, MAME opSEARCHD*).
            // The up form scans op1..op1+len1 ascending (start op1, count len1).
            // The down form scans the range in descending order from MAME's
            // start index: byte reads op1+len1 down to op1 (len1+1 reads; the
            // first read is one past the buffer, exactly as opSEARCHDB does),
            // half reads op1+(len1-1)*2 down to op1 (len1 reads).  str_src still
            // holds op1 from S_STR_OP1; bias it to the top of the range here.
            if (subop[0]) begin
                str_cnt <= cur_op[1] ? str_len1 : (str_len1 + 32'd1);
                str_src <= cur_op[1] ? (str_src + ((str_len1 - 32'd1) << 1))
                                     : (str_src + str_len1);
            end
            else
                str_cnt <= str_len1;
            // SEARCH also finalizes Z/R27/R28 for a zero-length range.
            st <= S_STR_RD;
        end
        else begin
            logic [31:0] mn, off;
            logic [4:0]  shf1;
            lb = fb[5'd3 + len1 + len2];
            l2 = lb[7] ? rf_rdata_a : {24'b0, lb};
            str_len2 <= l2;
            mn  = (str_len1 < l2) ? str_len1 : l2;
            shf1 = cur_op[1] ? 5'd1 : 5'd0;
            str_cnt <= mn;
            total_len <= 5'd4 + len1 + len2;
            // MOVCD/MOVCFD (down copy) transfers the ascending range
            // base..base+min-1 in descending element order (MAME opMOVSTRD):
            // start at the TOP of that range and decrement, instead of walking
            // physically below the base as the old code did (audit R20 V60-14).
            if (subop[0] && subop[4:0] >= 5'h08 && subop[4:0] <= 5'h0c) begin
                off  = (mn - 32'd1) << shf1;                 // (min-1)*step
                str_src <= op1 + off;
                str_dst <= op2 + off;
            end
            // CMPCS (0x02): stop mode starts with CY=1, cleared when a fill
            // (R26) byte is met in the compare (MAME opCMPSTR bStop).
            if (subop[4:0] == 5'h02) f_cy <= 1'b1;
            // CMPCF (0x01): fill the SHORTER operand's tail with R26 BEFORE the
            // compare (MAME bFill); MOVC fill happens AFTER the copy.  The
            // compare still runs over min(len1,len2) elements afterwards.
            if (subop[4:0] == 5'h01 && str_len1 != l2) begin
                str_fill_after <= 1'b0;                      // resume into compare
                str_fdelta <= cur_op[1] ? 32'd2 : 32'd1;
                if (str_len1 < l2) begin
                    str_fi    <= l2 - str_len1;
                    str_faddr <= op1 + (str_len1 << shf1);
                end
                else begin
                    str_fi    <= str_len1 - l2;
                    str_faddr <= op2 + (l2 << shf1);
                end
                st <= S_STR_FILL;
            end
            // Everything else (incl. zero-length MOVC/CMPC) finalizes its tail
            // registers/flags in S_STR_RD's exhaustion branch.
            else st <= S_STR_RD;
        end
    end
    S_STR_RD: begin
        if (str_cnt == 0) begin
            // V60 SEARCH uses the opposite Z sense from the published
            // manual: Z=1 only when the whole range is exhausted.  R27 is
            // the element index and R28 is the address at that index.  GA2
            // exercises the upward form; downward pointer semantics remain
            // separate from this completion/flag correction.
            if (subop[4:0] >= 5'h18) begin
                // Up exhaustion: i=len1, Z=1, R27=len1.  Down exhaustion: the
                // scan ran off the bottom to i=-1 (MAME opSEARCHD*), so Z=0,
                // R27=0xFFFFFFFF, and str_src has already reached op1-step.
                if (subop[0]) begin
                    f_z <= 1'b0;
                    queue_reg_write(5'd27, 32'hffff_ffff, 32'hffff_ffff);
                end
                else begin
                    f_z <= 1'b1;
                    queue_reg_write(5'd27, str_len1, 32'hffff_ffff);
                end
                queue_reg_write(5'd28, str_src, 32'hffff_ffff);
                st <= S_NEXT;
            end
            else if (subop[4:0] <= 5'h02) begin
                // CMPC exhausted the common prefix (all min elements equal):
                // R28=len1+min*step, R27=len2+min*step, and S/Z from the length
                // compare (MAME opCMPSTR tail).  The index must be scaled by the
                // element size — halfword CMPC previously stored len+min (audit
                // V60-13 residual: byte was correct, halfword off by *2).
                logic [31:0] cmin;
                logic [4:0]  shf;
                shf  = cur_op[1] ? 5'd1 : 5'd0;
                cmin = (str_len1 < str_len2) ? str_len1 : str_len2;
                queue_reg_write(5'd28, str_len1 + (cmin << shf), 32'hffff_ffff);
                queue_reg_write(5'd27, str_len2 + (cmin << shf), 32'hffff_ffff);
                if (str_len1 > str_len2)      begin f_s <= 1'b1; f_z <= 1'b0; end
                else if (str_len2 > str_len1) begin f_s <= 1'b0; f_z <= 1'b0; end
                else                          begin f_s <= 1'b0; f_z <= 1'b1; end
                st <= S_NEXT;
            end
            else movc_finish(32'd0);   // zero-length MOVC/MOVCF tail registers
        end
        else if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0;
            dbus_size <= cur_op[1] ? 2'd1 : 2'd0;  // 0x58=byte, 0x5a=half
            dbus_addr <= str_src;
        end
        else if (dack) begin
            dbus_req <= 0;
            alu_r <= bus_rdata;
            case (subop[4:0])
            5'h08, 5'h09, 5'h0a, 5'h0b, 5'h0c: st <= S_STR_WR; // MOVC*
            5'h00, 5'h01, 5'h02: st <= S_STR_WR;                // CMPC* (2nd read)
            5'h18, 5'h19, 5'h1a, 5'h1b: begin                   // SCHC/SKPC
                logic eq;
                // compare element with the decoded search value (F7b op2)
                eq = (cur_op[1] ? (bus_rdata[15:0]==str_dst[15:0]) : (bus_rdata[7:0]==str_dst[7:0]));
                if (eq == (subop[1] ? 1'b0 : 1'b1)) begin
                    // Index i = len1-cnt (up) or cnt-1 (down); R28 is the
                    // current element address.  Z follows MAME's post-loop test
                    // i==len1: up never breaks at i==len1 (Z=0), down does so
                    // only at its one-past-the-top byte read (str_cnt==len1+1).
                    f_z <= subop[0] ? (str_cnt == (str_len1 + 32'd1)) : 1'b0;
                    queue_reg_write(5'd27, subop[0] ? (str_cnt - 32'd1)
                                                    : (str_len1 - str_cnt),
                                    32'hffff_ffff);
                    queue_reg_write(5'd28, str_src, 32'hffff_ffff);
                    st <= S_NEXT;
                end
                else begin
                    str_src <= subop[0] ? str_src - (cur_op[1]?2:1) : str_src + (cur_op[1]?2:1);
                    str_cnt <= str_cnt - 1;
                    st <= S_STR_RD;
                end
            end
            default: st <= S_NEXT;
            endcase
        end
    end
    S_STR_WR: begin
        if (!dbus_req) begin
            case (subop[4:0])
            5'h00, 5'h01, 5'h02: begin // CMPC second read (dest element)
                dbus_req <= 1; dbus_we <= 0;
                dbus_size <= cur_op[1] ? 2'd1 : 2'd0;
                dbus_addr <= str_dst;
            end
            default: begin             // MOVC write
                dbus_req <= 1; dbus_we <= 1;
                dbus_size <= cur_op[1] ? 2'd1 : 2'd0;
                dbus_addr <= str_dst;
                dbus_wdata <= alu_r;
            end
            endcase
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            if (subop[4:0] <= 5'h02) begin
                // CMPC (MAME opCMPSTR): compare source(op1) vs dest(op2).  On the
                // first difference S = (source > dest); R28/R27 hold len+index*step
                // (byte was correct, halfword previously dropped the *2).  CMPCS
                // (0x02, bStop) additionally breaks with CY=0 when either element
                // equals the R26 fill byte (audit V60-13 + fill/stop completion).
                logic [31:0] a, b, cmin, ci;
                logic [4:0]  shf;
                logic [31:0] fb26;
                shf  = cur_op[1] ? 5'd1 : 5'd0;
                a = cur_op[1] ? {16'b0,alu_r[15:0]} : {24'b0,alu_r[7:0]};
                b = cur_op[1] ? {16'b0,bus_rdata[15:0]} : {24'b0,bus_rdata[7:0]};
                fb26 = cur_op[1] ? {16'b0, r[26][15:0]} : {24'b0, r[26][7:0]};
                cmin = (str_len1 < str_len2) ? str_len1 : str_len2;
                ci   = cmin - str_cnt;               // index of this element (i)
                if (a != b) begin
                    f_z <= 1'b0;
                    f_s <= (a > b);
                    queue_reg_write(5'd28, str_len1 + (ci << shf), 32'hffff_ffff);
                    queue_reg_write(5'd27, str_len2 + (ci << shf), 32'hffff_ffff);
                    st <= S_NEXT;
                end
                else if (subop[4:0] == 5'h02 && (a == fb26 || b == fb26)) begin
                    // Equal AND matches the stop byte: MAME clears CY and breaks;
                    // S/Z stay 0 (i != dest), R28/R27 at the current index.
                    f_cy <= 1'b0;
                    f_z  <= 1'b0;
                    f_s  <= 1'b0;
                    queue_reg_write(5'd28, str_len1 + (ci << shf), 32'hffff_ffff);
                    queue_reg_write(5'd27, str_len2 + (ci << shf), 32'hffff_ffff);
                    st <= S_NEXT;
                end
                else st <= S_STR_NEXT;               // equal: tail flags set at exhaustion
            end
            else begin
                // MOVC write complete.  MOVCSU (0x0c, bStop) ends the copy when the
                // just-copied element equals the R26 stop byte (op7a bStop).
                logic [31:0] elem, fb26;
                elem = cur_op[1] ? {16'b0, alu_r[15:0]} : {24'b0, alu_r[7:0]};
                fb26 = cur_op[1] ? {16'b0, r[26][15:0]} : {24'b0, r[26][7:0]};
                if (subop[4:0] == 5'h0c && elem == fb26) begin
                    logic [31:0] cmin;
                    cmin = (str_len1 < str_len2) ? str_len1 : str_len2;
                    movc_finish(cmin - str_cnt);     // break index i
                end
                else st <= S_STR_NEXT;
            end
        end
    end
    // MOVC/CMPC R26 fill phase (bFill): write the fill byte to the remaining
    // tail elements, then resume into the compare (CMPCF) or finish (MOVCF).
    S_STR_FILL: begin
        if (str_fi == 0) begin
            if (str_fill_after) begin                // MOVCFU/MOVCFD tail done
                queue_reg_write(5'd27, str_fr27, 32'hffff_ffff);
                st <= S_NEXT;
            end
            else st <= S_STR_RD;                     // CMPCF: run the compare now
        end
        else if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1;
            dbus_size <= cur_op[1] ? 2'd1 : 2'd0;
            dbus_addr <= str_faddr;
            dbus_wdata <= r[26];
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            str_faddr <= str_faddr + str_fdelta;
            str_fi    <= str_fi - 32'd1;
            st <= S_STR_FILL;
        end
    end
    // ------------------------------------------------------------------
    // 0x59 decimal group (F7c): op1 value decoded; now op2 as address
    S_DEC_OP1: begin
        ea_want_addr <= 1'b1;
        ea_dim  <= (subop[4:0] == 5'h10) ? 2'd1 : 2'd0;  // CVTDPZ dest: half
        ea_modm <= subop[5];
        ea_ofs  <= 5'd2 + len1;
        ea_target2 <= 1'b1;
        ea_ret  <= 3'd0;
        st <= S_EA_MODE;
        st_after_ea <= S_DEC_OP2;
    end
    S_DEC_OP2: begin
        // trailing ext byte (pattern), same reg-or-literal coding as lengths
        logic [7:0] xb;
        xb = fb[5'd2 + len1 + len2];
        dec_pat <= xb[7] ? rf_rdata_a[7:0] : xb;
        total_len <= 5'd3 + len1 + len2;
        if (subop[4:0] <= 5'h02) begin            // ADDDC/SUBDC/SUBRDC: RMW
            if (flag2) begin
                dec_cur <= rf_rdata_b[7:0];
                st <= S_DEC_EX;
            end
            else st <= S_DEC_RD;
        end
        else st <= S_DEC_EX;                       // CVTD*: write-only dest
    end
    S_DEC_RD: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd0; dbus_addr <= op2;
        end
        else if (dack) begin
            dbus_req <= 0;
            dec_cur <= bus_rdata[7:0];
            st <= S_DEC_EX;
        end
    end
    S_DEC_EX: begin
        logic [6:0] srcv, dstv;
        logic signed [8:0] sum;
        logic [7:0]  resb;
        logic [15:0] resh;
        logic        cyo;
        srcv = ({3'b0, op1[7:4]} * 7'd10) + {3'b0, op1[3:0]};
        dstv = ({3'b0, dec_cur[7:4]} * 7'd10) + {3'b0, dec_cur[3:0]};
        case (subop[4:0])
        5'h00, 5'h01, 5'h02: begin
            case (subop[4:0])
            5'h00:   sum = $signed({2'b0, srcv}) + $signed({2'b0, dstv})
                           + (f_cy ? 9'sd1 : 9'sd0);              // ADDDC
            5'h01:   sum = $signed({2'b0, dstv}) - $signed({2'b0, srcv})
                           - (f_cy ? 9'sd1 : 9'sd0);              // SUBDC
            default: sum = $signed({2'b0, srcv}) - $signed({2'b0, dstv})
                           - (f_cy ? 9'sd1 : 9'sd0);              // SUBRDC
            endcase
            if (subop[4:0] == 5'h00) begin
                cyo = (sum >= 9'sd100);
                if (cyo) sum = sum - 9'sd100;
            end
            else begin
                cyo = (sum < 0);
                if (cyo) sum = sum + 9'sd100;
            end
            f_cy <= cyo;
            if (sum != 0 || cyo) f_z <= 1'b0;      // Z sticky-clears only
            resb = bin2bcd(sum[6:0]);
            if (flag2) begin
                queue_reg_write(op2[4:0], resb, 32'h0000_00ff);
                st <= S_NEXT;
            end
            else begin
                dec_res <= {8'b0, resb};
                st <= S_DEC_WR;
            end
        end
        5'h10: begin                               // CVTDPZ: packed -> zoned
            resh = {({4'b0, op1[3:0]} | dec_pat),
                    ({4'b0, op1[7:4]} | dec_pat)};
            if (op1[7:0] != 0) f_z <= 1'b0;
            if (flag2) begin
                queue_reg_write(op2[4:0], resh, 32'h0000_ffff);
                st <= S_NEXT;
            end
            else begin
                dec_res <= resh;
                st <= S_DEC_WR;
            end
        end
        default: begin                             // CVTDZP: zoned -> packed
            resb = {op1[3:0], op1[11:8]};
            if (resb != 0) f_z <= 1'b0;
            if (flag2) begin
                queue_reg_write(op2[4:0], resb, 32'h0000_00ff);
                st <= S_NEXT;
            end
            else begin
                dec_res <= {8'b0, resb};
                st <= S_DEC_WR;
            end
        end
        endcase
    end
    S_DEC_WR: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1;
            dbus_size <= (subop[4:0] == 5'h10) ? 2'd1 : 2'd0;
            dbus_addr <= op2;
            dbus_wdata <= {16'b0, dec_res};
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            st <= S_NEXT;
        end
    end

`ifndef S32_V60_NO_FP
    // ------------------------------------------------------------------
    // single-precision FP group (0x5C/0x5F).  op1 already decoded as a value;
    // set up op2 per its role, then load/compute/write.
    S_FP_OP2: begin
        fp_a <= op1;
        ea_want_addr <= fp_op2_value(cur_op, subop[4:0]) ? 1'b0 : 1'b1;
        ea_dim   <= 2'd2;
        ea_modm  <= subop[5];
        ea_ofs   <= 5'd2 + len1;
        ea_target2 <= 1'b1;
        ea_ret   <= 3'd0;
        st <= S_EA_MODE;
        st_after_ea <= S_FP_LD;
    end
    S_FP_LD: begin
        fp_op2_reg <= flag2;
        total_len  <= 5'd2 + len1 + len2;
        if (fp_op2_value(cur_op, subop[4:0])) begin      // CMPF: op2 = value
            fp_b <= op2val_v ? op2val : op2;
            st <= S_FP_EXEC;
        end
        else if (fp_op2_rmw(cur_op, subop[4:0])) begin   // NEG/ABS/SCLF/ADD/SUB/MUL/DIV
            if (flag2) begin fp_b <= rf_rdata_b; st <= S_FP_EXEC; end
            else if (!dbus_req) begin
                dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2; dbus_addr <= op2;
            end
            else if (dack) begin
                dbus_req <= 0; fp_b <= bus_rdata; st <= S_FP_EXEC;
            end
        end
        else st <= S_FP_EXEC;                            // MOVFS/CVTWS/CVTSW: write-only
    end
    // Hand the operands to v60_fp and wait. The unit owns the dispatch, the
    // multi-cycle add/multiply and the divider, and tells us whether the
    // instruction writes back at all - CMPF sets flags only.
    S_FP_EXEC: begin
        if (!fp_busy) begin
            fp_start <= 1'b1;
            fp_busy  <= 1'b1;
        end else begin
            fp_start <= 1'b0;
            if (fp_done) begin
                f_z  <= fp_o_z;  f_s  <= fp_o_s;
                f_ov <= fp_o_ov; f_cy <= fp_o_cy;
                fp_res  <= fp_result;
                fp_busy <= 1'b0;
                st      <= st_t'(fp_writes ? S_FP_WB : S_NEXT);
            end
        end
    end
    S_FP_WB: begin
        // flags were set by fp_exec (or the FDIV completion); just store fp_res.
        if (fp_op2_reg) begin
            queue_reg_write(op2[4:0], fp_res, 32'hffff_ffff);
            st <= S_NEXT;
        end
        else if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
            dbus_addr <= op2; dbus_wdata <= fp_res;
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0; st <= S_NEXT;
        end
    end
`endif

    // ------------------------------------------------------------------
    // BAM: bit addressing modes for the 0x5B/0x5D groups (MAME BAMTable1/2
    // implemented subset — everything MAME fatalerrors on traps here too).
    // Produces {bam_base (byte address), bam_off (bit offset)}.
    S_BAM_MODE: begin
        if (!ea_modm) begin
            case (modtop)
            3'd0, 3'd1, 3'd2: begin // displacement IS the bit offset
                logic [31:0] bdt;
                bdt = disp_from(fbw_ea1, modtop[1:0]);
                bam_base <= rf_rdata_a;
                bam_off  <= bdt;
                bam_fill_len(5'd1 + disp_len(modtop[1:0]));
                st <= bam_next();
            end
            3'd3: begin             // register indirect
                bam_base <= rf_rdata_a;
                bam_off  <= 32'd0;
                bam_fill_len(5'd1);
                st <= bam_next();
            end
            3'd4, 3'd5, 3'd6: begin // [reg + disp] deref -> base, off 0
                logic [31:0] bdt;
                bdt = disp_from(fbw_ea1, modtop - 3'd4);
                dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
                dbus_addr <= rf_rdata_a + bdt;
                bam_off <= 32'd0;
                bam_fill_len(5'd1 + disp_len(modtop - 3'd4));
                st <= S_BAM_IND;
            end
            default: begin          // group 7: direct forms only
                case (modreg)
                5'h13: begin
                    logic [31:0] bdt;
                    bdt = fbw_ea1;
                    bam_base <= bdt;
                    bam_off  <= 32'd0;
                    bam_fill_len(5'd5);
                    st <= bam_next();
                end
                5'h17: begin        // direct address deferred
                    logic [31:0] bdt;
                    bdt = fbw_ea1;
                    dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
                    dbus_addr <= bdt;
                    bam_off <= 32'd0;
                    bam_fill_len(5'd5);
                    st <= S_BAM_IND;
                end
                default: begin
                    exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                end
                endcase
            end
            endcase
        end
        else begin
            case (modtop)
            3'd0, 3'd1, 3'd2: begin // double displacement: deref d1, off = d2
                logic [31:0] bdt, bdt2;
                bdt  = disp_from(fbw_ea1, modtop[1:0]);
                bdt2 = disp_of(ea_ofs+1+disp_len(modtop[1:0]), modtop[1:0]);
                dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
                dbus_addr <= rf_rdata_a + bdt;
                bam_off  <= bdt2;
                bam_fill_len(double_disp_len(modtop[1:0]));
                st <= S_BAM_IND;
            end
            3'd4: begin             // autoincrement (+1 strings, +4 fields)
                bam_base <= rf_rdata_a;
                bam_off  <= 32'd0;
                queue_reg_write(
                    modreg,
                    rf_rdata_a + ((cur_op == 8'h5b) ? 32'd1 : 32'd4),
                    32'hffff_ffff
                );
                bam_fill_len(5'd1);
                st <= bam_next();
            end
            3'd5: begin             // autodecrement
                bam_base <= rf_rdata_a - ((cur_op == 8'h5b) ? 32'd1 : 32'd4);
                queue_reg_write(
                    modreg,
                    rf_rdata_a - ((cur_op == 8'h5b) ? 32'd1 : 32'd4),
                    32'hffff_ffff
                );
                bam_off  <= 32'd0;
                bam_fill_len(5'd1);
                st <= bam_next();
            end
            3'd6: begin             // group 6: register indirect indexed only
                if (modval2[7:5] == 3'd3) begin
                    bam_base <= rf_rdata_b;
                    bam_off  <= rf_rdata_a;
                    bam_fill_len(5'd2);
                    st <= bam_next();
                end
                else begin
                    exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                end
            end
            default: begin
                exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
            end
            endcase
        end
    end
    S_BAM_IND: if (dack) begin
        dbus_req <= 0;
        bam_base <= bus_rdata;
        st <= bam_next();
    end
    // bit-field VALUE form (BAM1): dword at base + off/8, fold off to &7
    S_BAM_VAL: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
            dbus_addr <= bam_base + bitdiv8(bam_off);
        end
        else if (dack) begin
            dbus_req <= 0;
            bit_val <= bus_rdata;
            bam_off <= {29'b0, bam_off[2:0]};
            st <= S_BF_EXT1;
        end
    end

    // ------------------------------------------------------------------
    // EXTBFS/EXTBFZ/EXTBFL: field extracted from bit_val; ext len byte,
    // then op2 (normal AM) receives the word result
    S_BF_EXT1: begin
        logic [7:0] lb;
        lb = fb[5'd2 + len1];
        bit_len <= lb[7] ? rf_rdata_a : {24'b0, lb};
        ea_want_addr <= 1'b1;
        ea_dim  <= 2'd2;
        ea_modm <= subop[5];
        ea_ofs  <= 5'd3 + len1;
        ea_target2 <= 1'b1;
        ea_ret  <= 3'd0;
        st <= S_EA_MODE;
        st_after_ea <= S_BF_EXTW;
    end
    S_BF_EXTW: begin
        logic [31:0] mask, v, res;
        mask = (32'h1 << bit_len[4:0]) - 32'h1;
        v = (bit_val >> bam_off[2:0]) & mask;
        if (bam_flow == 2'd2) res = bit_val;             // SCHBS result
        else case (subop[4:0])
            5'h08: res = (v & ((mask + 32'h1) >> 1)) ? (v | ~mask) : v; // S
            5'h09: res = v;                                             // Z
            default: res = v << (6'd32 - {1'b0, bit_len[4:0]});         // L
        endcase
        if (flag2) begin
            queue_reg_write(op2[4:0], res, 32'hffff_ffff);
            total_len <= 5'd3 + len1 + len2;
            st <= S_NEXT;
        end
        else if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
            dbus_addr <= op2; dbus_wdata <= res;
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            total_len <= 5'd3 + len1 + len2;
            st <= S_NEXT;
        end
    end

    // ------------------------------------------------------------------
    // INSBFR/INSBFL: op1 word value decoded; op2 = BAM address; ext len;
    // RMW the 32-bit field at the bit position
    S_BF_INS1: begin
        bam_second <= 1'b1;
        ea_modm <= subop[5];
        ea_ofs  <= 5'd2 + len1;
        st <= S_BAM_MODE;
    end
    S_BF_INS2: begin
        logic [7:0] lb;
        lb = fb[5'd2 + len1 + len2];
        bit_len <= lb[7] ? rf_rdata_a : {24'b0, lb};
        str_dst <= bam_base + bitdiv8(bam_off);
        bam_off <= {29'b0, bam_off[2:0]};
        total_len <= 5'd3 + len1 + len2;
        st <= S_BF_INSRD;
    end
    S_BF_INSRD: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
            dbus_addr <= str_dst;
        end
        else if (dack) begin
            dbus_req <= 0;
            bit_val <= bus_rdata;
            st <= S_BF_INSWR;
        end
    end
    S_BF_INSWR: begin
        logic [31:0] mask, v, neww;
        mask = (32'h1 << bit_len[4:0]) - 32'h1;
        v = subop[0] ? (op1 >> (6'd32 - {1'b0, bit_len[4:0]})) : op1;  // L pre-shifts
        neww = (bit_val & ~(mask << bam_off[2:0]))
             | ((v & mask) << bam_off[2:0]);
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
            dbus_addr <= str_dst; dbus_wdata <= neww;
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            st <= S_NEXT;
        end
    end

    // ------------------------------------------------------------------
    // SCH0BSU/SCH1BSU: scan bit string for first 0/1
    S_BS_SCH1: begin
        logic [7:0] lb;
        logic [31:0] l;
        lb = fb[5'd2 + len1];
        l = lb[7] ? rf_rdata_a : {24'b0, lb};
        bit_len <= l;
        str_src <= bam_base + bitdiv8(bam_off);
        bs_soff <= bam_off[2:0];
        str_cnt <= 0;
        if (l == 0) begin
            f_z <= 1'b1;
            bit_val <= 0;
            st <= S_BS_SCHW;
        end
        else st <= S_BS_SCHRD;
    end
    S_BS_SCHRD: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd0;
            dbus_addr <= str_src;
        end
        else if (dack) begin
            dbus_req <= 0;
            bs_sdata <= bus_rdata[7:0];
            st <= S_BS_SCHB;
        end
    end
    S_BS_SCHB: begin
        queue_reg_write(5'd28, str_src, 32'hffff_ffff);
        if (bs_sdata[bs_soff] == subop[1]) begin   // sub 0 finds 0, sub 2 finds 1
            f_z <= 1'b0;
            bit_val <= str_cnt;
            st <= S_BS_SCHW;
        end
        else if (str_cnt + 1 == bit_len) begin     // exhausted
            f_z <= 1'b1;
            bit_val <= bit_len;
            st <= S_BS_SCHW;
        end
        else begin
            str_cnt <= str_cnt + 1;
            if (bs_soff == 3'd7) begin
                bs_soff <= 3'd0;
                str_src <= str_src + 1;
                st <= S_BS_SCHRD;
            end
            else bs_soff <= bs_soff + 1'd1;
        end
    end
    S_BS_SCHW: begin
        // result goes to op2 via the shared writer
        ea_want_addr <= 1'b1;
        ea_dim  <= 2'd2;
        ea_modm <= subop[5];
        ea_ofs  <= 5'd3 + len1;
        ea_target2 <= 1'b1;
        ea_ret  <= 3'd0;
        st <= S_EA_MODE;
        st_after_ea <= S_BF_EXTW;   // bam_flow==2 writes bit_val
    end

    // ------------------------------------------------------------------
    // MOVBSU/MOVBSD: bit-string copy (subop bit0: 0=up, 1=down)
    S_BS_MOV1: begin
        logic [7:0] lb;
        lb = fb[5'd2 + len1];
        bit_len <= lb[7] ? rf_rdata_a : {24'b0, lb};
        bs_base1 <= bam_base;
        bs_off1  <= bam_off;
        bam_second <= 1'b1;
        ea_modm <= subop[5];
        ea_ofs  <= 5'd3 + len1;
        st <= S_BAM_MODE;
    end
    S_BS_MOV2: begin
        // resolve byte addresses / bit positions (down: offsets += len-1)
        logic [31:0] o1, o2;
        o1 = subop[0] ? bs_off1 + bit_len - 1 : bs_off1;
        o2 = subop[0] ? bam_off + bit_len - 1 : bam_off;
        str_src <= bs_base1 + bitdiv8(o1);
        str_dst <= bam_base + bitdiv8(o2);
        bs_soff <= o1[2:0];
        bs_doff <= o2[2:0];
        total_len <= 5'd3 + len1 + len2;
        bs_ph <= 2'd0;
        bs_adv_done <= 1'b0;
        if (bit_len == 0) st <= S_NEXT;
        else st <= S_BS_MOVS;
    end
    // source-byte load. bs_ph: 0 = initial (no advance; dst load follows),
    // 2 = mid-loop src reload (advance first; back to the bit loop),
    // 1 = src+dst reload after a dst flush (advance; dst load follows)
    S_BS_MOVS: begin
        if (bs_ph != 2'd0 && !bs_adv_done) begin
            str_src <= subop[0] ? str_src - 1 : str_src + 1;
            bs_soff <= subop[0] ? 3'd7 : 3'd0;
            bs_adv_done <= 1'b1;
        end
        else if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd0;
            dbus_addr <= str_src;
        end
        else if (dack) begin
            dbus_req <= 0;
            bs_sdata <= bus_rdata[7:0];
            bs_adv_done <= 1'b0;
            if (bs_ph == 2'd2) begin bs_ph <= 2'd0; st <= S_BS_MOVB; end
            else begin bs_ph <= 2'd0; st <= S_BS_MOVD; end
        end
    end
    S_BS_MOVD: begin
        // load destination byte (RMW base)
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd0;
            dbus_addr <= str_dst;
        end
        else if (dack) begin
            dbus_req <= 0;
            bs_ddata <= bus_rdata[7:0];
            st <= S_BS_MOVB;
        end
    end
    S_BS_MOVB: begin
        // copy one bit, then handle byte boundaries per direction
        logic [7:0] nd;
        logic wrap_s, wrap_d;
        nd = bs_ddata;
        nd[bs_doff] = bs_sdata[bs_soff];
        bs_ddata <= nd;
        queue_reg_write(5'd28, str_src, 32'hffff_ffff);
        queue_reg_write(5'd27, str_dst, 32'hffff_ffff);
        wrap_s = subop[0] ? (bs_soff == 3'd0) : (bs_soff == 3'd7);
        wrap_d = subop[0] ? (bs_doff == 3'd0) : (bs_doff == 3'd7);
        bit_len <= bit_len - 1;
        if (!wrap_s) bs_soff <= subop[0] ? bs_soff - 1'd1 : bs_soff + 1'd1;
        if (!wrap_d) bs_doff <= subop[0] ? bs_doff - 1'd1 : bs_doff + 1'd1;
        if (wrap_d) begin
            bs_ph <= wrap_s ? 2'd1 : 2'd0;   // remember pending src reload
            st <= S_BS_MOVF;                 // write out dst byte
        end
        else if (wrap_s) begin
            if (bit_len == 1) st <= S_BS_MOVF;  // done: flush partial dst byte
            else begin bs_ph <= 2'd2; st <= S_BS_MOVS; end
        end
        else if (bit_len == 1) st <= S_BS_MOVF;  // final partial flush
        else st <= S_BS_MOVB;
        // final-bit bookkeeping: when the last copied bit did NOT wrap the
        // dst byte, S_BS_MOVF performs the flush write and ends; when it
        // wrapped, S_BS_MOVF writes and (bit_len==1) ends without reload
    end
    S_BS_MOVF: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd0;
            dbus_addr <= str_dst;
            dbus_wdata <= {24'b0, bs_ddata};
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            if (bit_len == 0) st <= S_NEXT;          // string done
            else begin
                // advance dst to the next byte and reload it (src too when
                // its boundary coincided — bs_ph 1 routes through MOVS)
                str_dst <= subop[0] ? str_dst - 1 : str_dst + 1;
                bs_doff <= subop[0] ? 3'd7 : 3'd0;
                if (bs_ph == 2'd1) st <= S_BS_MOVS;
                else               st <= S_BS_MOVD;
            end
        end
    end

    S_STR_NEXT: begin
        logic [31:0] stp;
        stp = cur_op[1] ? 32'd2 : 32'd1;
        // down variants (MOVCD*) decrement; up variants increment
        if (subop[0] && (subop[4:0]>=5'h08)) begin
            str_src <= str_src - stp; str_dst <= str_dst - stp;
        end
        else begin
            str_src <= str_src + stp; str_dst <= str_dst + stp;
        end
        str_cnt <= str_cnt - 1;
        if (str_cnt == 1) begin
            // CMPC finishes through S_STR_RD's exhaustion branch so the MAME
            // length-tail flags/registers apply; MOVC finalizes R28/R27 from the
            // operand bases and the copied count via movc_finish (which also
            // scales by the element size and launches the MOVCF fill tail — the
            // old address-based completion was off by one step, audit V60-13/14).
            if (subop[4:0] <= 5'h02)
                st <= S_STR_RD;
            else
                movc_finish((str_len1 < str_len2) ? str_len1 : str_len2);
        end
        else st <= S_STR_RD;
    end

    // ------------------------------------------------------------------
    // LDTASK/STTASK task-block transfers. Phase 0 is TKCW, phases 1..4
    // are enabled L0SP..L3SP fields, and phases 5..35 are R0..R30.
    S_TASK_LD_NEXT: begin
        if (task_phase == 0) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
            dbus_addr <= task_addr;
            st <= S_TASK_LD_ACK;
        end
        else if (task_phase <= 4) begin
            if (sycw[7 + task_phase]) begin
                dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
                dbus_addr <= task_addr;
                st <= S_TASK_LD_ACK;
            end
            else task_phase <= task_phase + 1'd1;
        end
        else if (task_phase == 5 && !task_reloaded) begin
            // Stack fields loaded on prior cycles are now stable.
            queue_reg_write(5'd31, pick_stack(psw), 32'hffff_ffff);
            task_reloaded <= 1'b1;
        end
        else if (task_phase <= 35) begin
            if (task_mask[task_phase - 5]) begin
                dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
                dbus_addr <= task_addr;
                st <= S_TASK_LD_ACK;
            end
            else task_phase <= task_phase + 1'd1;
        end
        else st <= S_NEXT;
    end
    S_TASK_LD_ACK: if (dack) begin
        dbus_req <= 0;
        case (task_phase)
            0: tkcw <= bus_rdata;
            1: l0sp <= bus_rdata;
            2: l1sp <= bus_rdata;
            3: l2sp <= bus_rdata;
            4: l3sp <= bus_rdata;
            default: queue_reg_write(task_phase - 5, bus_rdata, 32'hffff_ffff);
        endcase
        task_addr <= task_addr + 4;
        task_phase <= task_phase + 1'd1;
        st <= S_TASK_LD_NEXT;
    end

    S_TASK_ST_NEXT: begin
        if (task_phase == 0) begin
            // v60SaveStack() after setting IS: r31 now names the interrupt
            // stack selected by write_psw() in the execute cycle.
            isp <= r[31];
            dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
            dbus_addr <= task_addr; dbus_wdata <= tkcw;
            st <= S_TASK_ST_ACK;
        end
        else if (task_phase <= 4) begin
            if (sycw[7 + task_phase]) begin
                dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
                dbus_addr <= task_addr;
                case (task_phase)
                    1: dbus_wdata <= l0sp; 2: dbus_wdata <= l1sp;
                    3: dbus_wdata <= l2sp; default: dbus_wdata <= l3sp;
                endcase
                st <= S_TASK_ST_ACK;
            end
            else task_phase <= task_phase + 1'd1;
        end
        else if (task_phase <= 35) begin
            if (task_mask[task_phase - 5]) begin
                dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
                dbus_addr <= task_addr; dbus_wdata <= rf_rdata_a;
                st <= S_TASK_ST_ACK;
            end
            else task_phase <= task_phase + 1'd1;
        end
        else st <= S_NEXT;
    end
    S_TASK_ST_ACK: if (dack) begin
        dbus_req <= 0; dbus_we <= 0;
        task_addr <= task_addr + 4;
        task_phase <= task_phase + 1'd1;
        st <= S_TASK_ST_NEXT;
    end

    // ------------------------------------------------------------------
    // exception / interrupt entry (MAME v60_do_irq):
    //   switch to interrupt context, push old PSW, push PC, PC = vector
    S_EXC_PUSH1: begin
        // Synchronous exceptions preserve IS; IRQ/NMI force the interrupt
        // stack. CHLVL supplies a nonzero target execution level.
        logic [31:0] newpsw;
        newpsw = exc_pushval;
        newpsw[25:24] = exc_target_level;
        newpsw[18] = 0; newpsw[16] = 0; newpsw[27] = 0; newpsw[17] = 0; newpsw[29] = 0;
        if (exc_is_interrupt) newpsw[28] = 1;
        newpsw[31] = 1;
        write_psw(newpsw);
        // BRKV has a leading fault-PC word; ordinary trap-class frames begin
        // with code+size, while IRQ/NMI frames begin with old PSW.
        st <= st_t'(exc_has_extra ? S_EXC_EXTRA
                            : exc_has_code ? S_EXC_CODE : S_EXC_PUSH2);
    end
    S_EXC_EXTRA: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
            dbus_addr <= sp_m4;
            dbus_wdata <= exc_extra;
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
            st <= S_EXC_CODE;
        end
    end
    S_EXC_CODE: begin         // push code+size word (trap-class only)
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
            dbus_addr <= sp_m4;
            dbus_wdata <= exc_code;
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
            st <= S_EXC_PUSH2;
        end
    end
    S_EXC_PUSH2: begin        // push old PSW
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
            dbus_addr <= sp_m4;
            dbus_wdata <= exc_pushval;
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
            st <= S_EXC_JMP;   // reused as "push PC" state
        end
    end
    S_EXC_JMP: begin          // push return PC (A2: PC+len for TRAP)
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
            dbus_addr <= sp_m4;
            dbus_wdata <= exc_retpc;
        end
        else if (dack) begin
            dbus_req <= 0; dbus_we <= 0;
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
            st <= S_EXC_VEC;
        end
    end
    S_EXC_VEC: begin
        if (!dbus_req) begin
            dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2;
            dbus_addr <= (sbr & ~32'hfff) + {22'b0, exc_vector, 2'b00};
        end
        else if (dack) begin
            dbus_req <= 0;
            pc <= bus_rdata;
            st <= S_FILL; st_after_fill <= S_DECODE;
        end
    end

    // PUSH/POP bus completion
    S_PUSH: if (dack) begin
        dbus_req <= 0; dbus_we <= 0;
        st <= S_NEXT;
    end
    S_POP: if (dack) begin
        dbus_req <= 0;
        if (flag1) begin
            queue_reg_write(op1[4:0], bus_rdata, 32'hffff_ffff);
            st <= S_NEXT;
        end
        else begin
            op2 <= op1; flag2 <= 0;
            wb_val <= bus_rdata;
            st <= S_WB_MEM;
        end
        queue_reg_write(5'd31, r[31] + 4, 32'hffff_ffff);
    end

    S_HALT: begin
        // Wake on interrupt and resume at the instruction AFTER the HALT, the
        // real-hardware resume point.  The old code left PC on the HALT, so the
        // interrupt frame's return PC was the HALT itself and RETI re-executed
        // it forever: interrupt handlers kept running while the main thread was
        // permanently parked (audit R20 V60-2 — the ga2 freeze signature).
        // Advancing only on wake keeps a no-interrupt HALT parked at its own PC,
        // so benches that use HALT as an end marker are unaffected.
        if (nmi_seen || (!irq_n && psw_ie)) begin
            halted <= 0;
            pc <= pc + 1;
            st <= S_DECODE;
        end
    end

    default: st <= S_RESET;
    endcase

    // The prefetch unit and the self-modifying-code guard live in v60_ifetch.

    // Port 1 is applied second so the final queued write retains the original
    // nonblocking-assignment priority when both ports address the same bit.
    for (int rf_wbit = 0; rf_wbit < 32; rf_wbit = rf_wbit + 1) begin
        if (rf_we0 && rf_wmask0[rf_wbit])
            r[rf_waddr0][rf_wbit] <= rf_wdata0[rf_wbit];
        if (rf_we1 && rf_wmask1[rf_wbit])
            r[rf_waddr1][rf_wbit] <= rf_wdata1[rf_wbit];
    end
end
end

// ---------------------------------------------------------------------------
// per-opcode dim helpers (operand sizes per MAME op12 handlers)
// ---------------------------------------------------------------------------
// F12 ops whose FIRST operand is an effective address, not a value
// (MAME F12DecodeFirstOperand(ReadAMAddress, ...)): MOVEA and IN
function automatic f12_op1_is_addr(input [7:0] op);
    case (op)
        8'h40, 8'h42, 8'h44,            // MOVEA.B/H/W
        8'h20, 8'h22, 8'h24,            // IN.B/H/W
        8'h41, 8'h43, 8'h45,            // XCH.B/H/W — both operands are lvalues
        8'h3f,                         // MOVD — 64-bit move, both operands lvalues
        8'h49,                         // CALL target
        8'h01: f12_op1_is_addr = 1'b1; // LDTASK register-mask operand
        default: f12_op1_is_addr = 1'b0;
    endcase
endfunction

function automatic [1:0] f12_dim1(input [7:0] op);
    casez (op)
        8'h09, 8'h0a, 8'h0b, 8'h0c, 8'h0d, 8'h40, 8'h41, 8'h20, 8'h21,
        8'h38, 8'h39, 8'h50, 8'h51, 8'h80, 8'h81, 8'h88,
        8'h90, 8'h91, 8'h98, 8'ha0, 8'ha1, 8'ha8, 8'hb0, 8'hb1,
        8'hb8, 8'h47, 8'h49, 8'h4b, 8'h4d, 8'h4e, 8'h4f:
            f12_dim1 = 2'd0;   // SETF/CHLVL/CHKA byte operands; CALL address
        // NOTE: ROTH (8b) / ROTCH (9b) must NOT appear here — their op1 is
        // the rotate COUNT, a byte (MAME ReadAM dim 0); listing them in the
        // half group made `ROT.H #imm8, r6` decode one byte long and holo's
        // EEPROM write loop entered mid-instruction (found by real-ROM boot)
        8'h19, 8'h1b, 8'h1c, 8'h1d, 8'h42, 8'h43, 8'h3a, 8'h3b, 8'h22, 8'h23,
        8'h52, 8'h53, 8'h82, 8'h83, 8'h8a, 8'h92, 8'h93,
        8'h9a, 8'ha2, 8'ha3, 8'haa, 8'hb2, 8'hb3, 8'hba:
            f12_dim1 = 2'd1;
        // A7: MULX/MULUX/DIVX/DIVUX first operand is word (64-bit datapath)
        8'h86, 8'h96, 8'ha6, 8'hb6: f12_dim1 = 2'd2;
        8'ha9, 8'hab, 8'had, 8'hb9, 8'hbb, 8'hbd, 8'h89, 8'h8b, 8'h8d,
        8'h99, 8'h9b, 8'h9d: f12_dim1 = 2'd0;  // shift/rot counts are byte
        default: f12_dim1 = 2'd2;
    endcase
endfunction
function automatic [1:0] f12_dim2(input [7:0] op);
    casez (op)
        8'h09, 8'h19, 8'h29, 8'h38, 8'h39, 8'h41, 8'h50, 8'h51,
        8'h80, 8'h81, 8'h88, 8'h90, 8'h91, 8'h98, 8'ha0, 8'ha1,
        8'ha8, 8'hb0, 8'hb1, 8'hb8, 8'h89, 8'h99, 8'ha9, 8'hb9,
        8'h47, 8'h4b, 8'h4d, 8'h4e, 8'h4f: f12_dim2 = 2'd0;
        8'h0a, 8'h0b, 8'h1b, 8'h2b, 8'h3a, 8'h3b, 8'h43, 8'h52, 8'h53,
        8'h82, 8'h83, 8'h8a, 8'h92, 8'h93, 8'h9a, 8'ha2, 8'ha3, 8'haa,
        8'hb2, 8'hb3, 8'hba, 8'h8b, 8'h9b, 8'hab, 8'hbb: f12_dim2 = 2'd1;
        default: f12_dim2 = 2'd2;
    endcase
endfunction

// RMW-class F12 ops: exec reads current op2 (dest) value
function automatic f12_reads_dest(input [7:0] op);
    casez (op)
        8'h8?, 8'h9?, 8'hA?, 8'hB?,          // ADD/MUL/OR/ROT/ADDC/SUBC/AND/DIV/SUB/SHL/XOR/CMP/SHA + bit ops
        8'h5?: f12_reads_dest = 1;           // REM group
        // These read op2 as a VALUE (MAME ReadAM), so a memory operand must be
        // loaded into op2val before exec; otherwise the exec fell back to the
        // effective address / a stale op2val (audit R20 V60-18).
        8'h01,                               // LDTASK task-block pointer
        8'h13, 8'h4a,                        // UPDPSW.W / UPDPSW.H mask
        8'h4b:  f12_reads_dest = 1;          // CHLVL level data
        default: f12_reads_dest = 0;
    endcase
endfunction

// ---------------------------------------------------------------------------
// EXEC task: implements per-opcode semantics
// ---------------------------------------------------------------------------
task automatic set_zs(input [31:0] v, input [1:0] d);
    f_z <= zer(v, d);
    f_s <= sgn(v, d);
endtask

task automatic wb_op2(input [31:0] v, input [1:0] d);
    // write result to op2 (register or memory)
    if (flag2) begin
        setreg(op2[4:0], v, d);
    end
    else begin
        wb_val <= v;
        st <= S_WB_MEM;
    end
endtask

// MOVC completion (MAME opMOVSTRU*/opMOVSTRD*): publish R28/R27 for the final
// element index `idx`, and — for the fill variants (MOVCFU/MOVCFD) with the
// source shorter than the destination — kick off the R26 tail-fill phase.
// `idx` is the break index for a stop hit, else the copied count `dest`.
task automatic movc_finish(input [31:0] idx);
    logic [4:0]  shf;
    logic [31:0] step, dest, r28, r27;
    logic        down, isfill;
    shf    = cur_op[1] ? 5'd1 : 5'd0;             // 0x58 byte / 0x5a half
    step   = cur_op[1] ? 32'd2 : 32'd1;
    dest   = (str_len1 < str_len2) ? str_len1 : str_len2;
    down   = subop[0];                            // 0x09 MOVCD / 0x0b MOVCFD
    isfill = (subop[4:0] == 5'h0a) || (subop[4:0] == 5'h0b);
    if (down) begin
        r28 = op1 + ((str_len1 - idx - 32'd1) << shf);
        r27 = op2 + ((str_len2 - idx - 32'd1) << shf);
    end
    else begin
        r28 = op1 + (idx << shf);
        r27 = op2 + (idx << shf);
    end
    queue_reg_write(5'd28, r28, 32'hffff_ffff);
    if (isfill && (str_len1 < str_len2)) begin
        // Stop is never set for a fill opcode, so idx == dest here.  MAME pads
        // the destination tail elements [idx, lenop2) with R26; the down form
        // uses op2+dest+(lenop2-j-1) for bytes and op2+(lenop2-j-1)*2 for halves.
        str_fill_after <= 1'b1;
        str_fi     <= str_len2 - idx;
        str_fdelta <= down ? (32'd0 - step) : step;
        if (down) begin
            str_faddr <= cur_op[1] ? (op2 + ((str_len2 - idx - 32'd1) << 1))
                                   : (op2 + dest + (str_len2 - idx - 32'd1));
            str_fr27  <= op2 - step;
        end
        else begin
            str_faddr <= op2 + (idx << shf);
            str_fr27  <= op2 + (str_len2 << shf);
        end
        st <= S_STR_FILL;
    end
    else begin
        queue_reg_write(5'd27, r27, 32'hffff_ffff);
        st <= S_NEXT;
    end
endtask

// BAM decode plumbing: record the AM length into len1/len2, and route to
// the flow's next state after the base/offset are resolved
task bam_fill_len(input [4:0] l);
    if (bam_second) len2 <= l; else len1 <= l;
endtask

function automatic st_t bam_next();
    // Quartus 17's Verific front-end crashes on a case statement inside an
    // enum-returning function used directly by a nonblocking assignment.
    // The equivalent if/else form avoids that compiler bug.
    if (!bam_second) begin
        if (bam_flow == 2'd0)      bam_next = S_BAM_VAL;   // EXTBF*: read dword
        else if (bam_flow == 2'd2) bam_next = S_BS_SCH1;   // SCHBS address form
        else                       bam_next = S_BS_MOV1;   // MOVBS op1
    end
    else if (bam_flow == 2'd1) bam_next = S_BF_INS2;
    else                       bam_next = S_BS_MOV2;
endfunction

// ---------------------------------------------------------------------------
// THE SHARED INTEGER ALU - ONE INSTANCE, thirty opcodes. See v60_alu.sv for why
// it exists and how one adder covers all of them.
//
// The operands are exactly what exec_op computed for itself, lifted to module
// scope because a task's locals cannot drive a module instance. They are pure
// functions of cur_op, op1, flag2, rf_rdata_b and op2val, all of which are
// stable while S_EXEC runs, so the unit sees the same values the inline code did.
// ---------------------------------------------------------------------------
wire [1:0]  alu_d2 = f12_dim2(cur_op);
wire [31:0] alu_a  = op1;
wire [31:0] alu_b  = flag2 ? dimext(rf_rdata_b, alu_d2) : op2val;

wire [31:0] alu_result;
wire        alu_cy, alu_ov, alu_z, alu_s, alu_writes, alu_valid, alu_cy_we;

v60_alu u_alu (
    .op(cur_op), .d(alu_d2), .a(alu_a), .b(alu_b), .cy_in(f_cy),
    .result(alu_result), .cy(alu_cy), .ov(alu_ov), .z(alu_z), .s(alu_s),
    .writes(alu_writes), .valid(alu_valid), .cy_we(alu_cy_we)
);

// THE SHARED SHIFT/ROTATE UNIT - ONE INSTANCE for SHL, SHA and ROT. See
// v60_shift.sv. Same operands as the ALU: the value is exec_op's `b` and the
// count is the low byte of `a`, signed. ROTC is NOT here - it rotates through
// carry over multiple cycles and stays in the sequencer.
wire [31:0] shf_result;
wire        shf_cy, shf_ov, shf_z, shf_s, shf_valid;

v60_shift u_shift (
    .op(cur_op), .d(alu_d2), .val(alu_b), .cnt(alu_a[7:0]),
    .result(shf_result), .cy(shf_cy), .ov(shf_ov),
    .z(shf_z), .s(shf_s), .valid(shf_valid)
);

task automatic exec_op;
    logic [31:0] a, b, res;
    logic [32:0] wide;
    logic [1:0]  d2;
    d2 = f12_dim2(cur_op);
    a = op1;                       // source (value)
    b = flag2 ? dimext(rf_rdata_b, d2) : op2val; // dest current value (V60-1)
    // Every consuming opcode assigns these before use.  Defaults make that
    // fact explicit to synthesis and prevent task-local latch inference.
    res  = 32'b0;
    wide = 33'b0;

    case (cur_op)
    // ------------ moves ------------
    8'h09, 8'h1b, 8'h2d: begin      // MOVB/MOVH/MOVW
        set_zs(a, d2);              // MAME MOV sets no flags? (MOV doesn't set flags on V60) -- MOV sets none; revert
        f_z <= f_z; f_s <= f_s;     // undo: MOV does not affect flags
        wb_op2(a, d2);
    end
    8'h0a: wb_op2({{24{a[7]}},  a[7:0]} & 32'hffff, 2'd1);   // MOVSBH
    8'h0b: wb_op2({24'b0, a[7:0]}, 2'd1);                    // MOVZBH
    8'h0c: wb_op2({{24{a[7]}},  a[7:0]}, 2'd2);              // MOVSBW
    8'h0d: wb_op2({24'b0, a[7:0]}, 2'd2);                    // MOVZBW
    8'h1c: wb_op2({{16{a[15]}}, a[15:0]}, 2'd2);             // MOVSHW
    8'h1d: wb_op2({16'b0, a[15:0]}, 2'd2);                   // MOVZHW
    // MOVT truncations set OV when the discarded high bits are not the sign
    // extension of the result — the only flag they define, previously left
    // unset so BV/BNV after a coordinate truncation misbranched (audit V60-17).
    8'h19: begin f_ov <= (a[15:8]  != {8{a[7]}});   wb_op2(a[7:0], 2'd0); end  // MOVTHB
    8'h29: begin f_ov <= (a[31:8]  != {24{a[7]}});  wb_op2(a[7:0], 2'd0); end  // MOVTWB
    8'h2b: begin f_ov <= (a[31:16] != {16{a[15]}}); wb_op2(a[15:0], 2'd1); end // MOVTWH
    8'h40, 8'h42, 8'h44: wb_op2(op1, 2'd2);                  // MOVEA: op1 decoded as addr in IF2? see note
    8'h2c: begin                                             // RVBYT: reverse bytes
        wb_op2({a[7:0], a[15:8], a[23:16], a[31:24]}, 2'd2);
    end
    8'h08: begin                                             // RVBIT
        logic [7:0] rv;
        for (int i=0;i<8;i++) rv[i] = a[7-i];
        wb_op2({24'b0, rv}, 2'd0);
    end
    8'h3f: begin  // MOVD: full 64-bit move (register pair or memory qword).
        // The old exec moved only 32 bits, losing the upper word (audit V60-10).
        // op1/op2 now decode as lvalues (f12_op1_is_addr): flagN=1 -> register
        // number, flagN=0 -> memory address of the low word.
        if (flag1) begin
            // register-pair source: capture the pair, then dispatch the write
            // Through the read ports, not a direct index - see rf_raddr_b's
            // note in the S_EXEC arm above. rf_rdata_a is already r[op1] here.
            movd_lo <= rf_rdata_a;
            movd_hi <= rf_rdata_b;
            if (flag2) begin
                queue_reg_write(op2[4:0],          rf_rdata_a,           32'hffffffff);
                queue_reg_write(op2[4:0] + 5'd1,   rf_rdata_b,           32'hffffffff);
                st <= S_NEXT;
            end
            else st <= S_MOVD_WL;   // register -> memory qword
        end
        else st <= S_MOVD_RL;       // memory qword source
    end

    // ------------ arith ------------
    // ------------ arith and logic: ONE SHARED UNIT ------------
    //
    // ADD ADDC SUB CMP SUBC NOT NEG AND OR XOR, all three operand widths, used
    // to be fifteen separate arms. Each built its own datapath because Quartus
    // cannot share logic across case arms it is unable to prove exclusive: ADD
    // alone inferred three adders, two of them existing purely to produce the
    // carry flag at byte and halfword width. v60_alu computes all of it from a
    // single 33-bit sum. tb_v60_alu checks the unit against the expressions
    // that stood here, 360,001 cases over all thirty opcodes, zero mismatches.
    //
    // AND/OR/XOR are the only arms that leave a flag ALONE rather than clearing
    // it, hence alu_cy_we; CMP is SUB without the writeback, hence alu_writes.
    8'h80, 8'h82, 8'h84,        // ADD
    8'h90, 8'h92, 8'h94,        // ADDC
    8'ha8, 8'haa, 8'hac,        // SUB
    8'hb8, 8'hba, 8'hbc,        // CMP
    8'h98, 8'h9a, 8'h9c,        // SUBC
    8'h38, 8'h3a, 8'h3c,        // NOT
    8'h39, 8'h3b, 8'h3d,        // NEG
    8'ha0, 8'ha2, 8'ha4,        // AND
    8'h88, 8'h8a, 8'h8c,        // OR
    8'hb0, 8'hb2, 8'hb4: begin  // XOR
        res  = alu_result;
        f_z  <= alu_z;
        f_s  <= alu_s;
        f_ov <= alu_ov;
        if (alu_cy_we) f_cy <= alu_cy;
        if (alu_writes) wb_op2(res, d2);
        else            st <= S_NEXT;   // CMP: flags only
    end
    8'hf0, 8'hf1, 8'hf2, 8'hf3, 8'hf4, 8'hf5: begin
        // TEST single operand
        set_zs(op1, cur_op[2:1] == 2'b00 ? 2'd0 : cur_op[2:1]==2'b01 ? 2'd1 : 2'd2);
        f_ov <= 0; f_cy <= 0;
        total_len <= 5'd1 + len1;
        st <= S_NEXT;
    end

    // ------------ shifts/rotates: count in op1 (byte, signed) ------------
    // ------------ shifts/rotates: ONE SHARED UNIT ------------
    //
    // SHL, SHA and ROT at all three widths were three arms calling five helper
    // functions, and a function is INLINED at every call site, so nothing was
    // shared: seven genuinely variable barrel shifters between them, plus four
    // inlined copies of shl_lastout. Only one arm can execute per instruction,
    // so muxing the operands into a single left/right pair costs three small
    // muxes and saves the rest. Same argument as v60_alu's single adder.
    //
    // tb_v60_shift sweeps every count from -128 to +127 at all three widths -
    // not a sample - because every correction this code has ever needed was at
    // a boundary (audit R20 V60-7). It found two bugs in the unit before it was
    // wired in here: an arithmetic right shift that was silently logical, and
    // an empty overflow mask at count == width. 69,121 checks, 0 fails.
    8'ha9, 8'hab, 8'had,        // SHL
    8'hb9, 8'hbb, 8'hbd,        // SHA
    8'h89, 8'h8b, 8'h8d: begin  // ROT
        res  = shf_result;
        f_cy <= shf_cy;
        f_ov <= shf_ov;
        f_z  <= shf_z;
        f_s  <= shf_s;
        wb_op2(res, d2);
    end
    8'h99, 8'h9b, 8'h9d: begin      // ROTC: rotate through carry, iterative
        // MAME clears CY for a zero count; nonzero counts retain the final
        // shifted-out bit, so only bypass the iterative state for zero.
        if ($signed(a[7:0]) == 0) begin
            f_cy <= 1'b0;
            f_ov <= 1'b0;
            set_zs(b, d2);
            wb_op2(b, d2);
        end
        else begin
            rotc_cnt <= a[7:0];
            rotc_val <= dimext(b, d2);
            st <= S_ROTC;
        end
    end

    // ------------ bit ops (register or memory dest in op2) ------------
    8'h87, 8'h97, 8'ha7, 8'hb7: begin
        // TEST1/SET1/CLR1/NOT1: op1 = bit number, op2 = dest (RMW)
        // memory case handled as RMW via S_EA-provided address in op2
        if (flag2) begin
            logic [4:0] bi;
            bi = op1[4:0];
            f_z  <= ~rf_rdata_b[bi];
            f_cy <=  rf_rdata_b[bi];
            case (cur_op)
                8'h97: queue_reg_write(op2[4:0], 32'hffff_ffff, 32'h1 << bi);
                8'ha7: queue_reg_write(op2[4:0], 32'h0000_0000, 32'h1 << bi);
                8'hb7: queue_reg_write(op2[4:0], ~rf_rdata_b, 32'h1 << bi);
                default: ;
            endcase
            st <= S_NEXT;
        end
        else begin
            // memory bit op: byte RMW at addr + bit#/8, bit = bit# % 8
            op2 <= op2 + {29'b0, op1[4:3]};     // byte offset from bit number
            rmw_kind <= (cur_op == 8'h97) ? 3'd2 :   // SET1
                        (cur_op == 8'ha7) ? 3'd3 :   // CLR1
                        (cur_op == 8'hb7) ? 3'd4 :   // NOT1
                                            3'd5;    // TEST1
            rmw_dim  <= 2'd0;
            wb_val   <= {29'b0, op1[2:0]};      // bit within byte
            st <= S_RMW_RD;
        end
    end

    // ------------ multiply / divide (iterative) ------------
    8'h81, 8'h83, 8'h85, 8'h91, 8'h93, 8'h95: begin // MUL/MULU
        mdop <= dimext(a, d2);
        mdacc <= {32'b0, dimext(b, d2)};
        md_savb <= dimext(b, d2);   // retained for the width-correct overflow flag
        md_sign <= !cur_op[4] ? 1'b0 : 1'b0;
        mdcnt <= 6'd32;
        st <= S_MULDIV;
    end
    8'ha1, 8'ha3, 8'ha5, 8'hb1, 8'hb3, 8'hb5,       // DIV/DIVU
    8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55: begin // REM/REMU
        if (dimext(a, d2) == 0) begin
            // MAME divide-by-zero: destination unchanged and no trap, but Z/S
            // are still set from the (unchanged) destination = the dividend, and
            // OV is cleared (audit R20 V60-8); the old code left flags stale.
            set_zs(dimext(b, d2), d2);
            f_ov <= 1'b0;
            st <= S_NEXT;
        end
        else begin
            // DIV/DIVU distinguished by bit4 (0xaX signed / 0xbX unsigned);
            // REM/REMU distinguished by bit0 (0x50/52/54 signed / 51/53/55 unsigned)
            logic is_signed, is_rem;
            logic [31:0] sa, sb, maga, magb;
            is_rem    = (cur_op[7:4] == 4'h5);
            is_signed = is_rem ? ~cur_op[0] : ~cur_op[4];
            // Signed DIV/REM sign-extend width-sized operands; unsigned
            // DIVU/REMU must zero-extend them.  Sign-extending an unsigned
            // halfword dividend with bit 15 set turned GA2's fixed-point
            // 0xC000 boss-meter numerator into 0xFFFFC000.
            sa = is_signed
               ? ((d2==2'd0) ? {{24{a[7]}},a[7:0]} :
                  (d2==2'd1) ? {{16{a[15]}},a[15:0]} : a)
               : dimext(a, d2);
            sb = is_signed
               ? ((d2==2'd0) ? {{24{b[7]}},b[7:0]} :
                  (d2==2'd1) ? {{16{b[15]}},b[15:0]} : b)
               : dimext(b, d2);
            maga = (is_signed && sa[31]) ? (~sa + 1'b1) : sa;
            magb = (is_signed && sb[31]) ? (~sb + 1'b1) : sb;
            mdop   <= maga;
            mdacc  <= {32'b0, magb};
            md_qsign <= is_signed & (sa[31] ^ sb[31]);
            md_rsign <= is_signed & sb[31];
            // Signed DIV overflow: dividend == min and divisor == -1 (quotient
            // would be +2^(w-1), which does not fit).  MAME sets OV and leaves
            // the destination unchanged (audit R20 V60-8); the old code always
            // cleared OV and wrote the wrapped quotient.
            md_divov <= is_signed & ~is_rem & sa[31] & (maga == 32'd1) &
                        (magb == (d2==2'd0 ? 32'h0000_0080 :
                                  d2==2'd1 ? 32'h0000_8000 : 32'h8000_0000));
            mdcnt  <= 6'd32;
            st <= S_MULDIV;
        end
    end
    8'h86, 8'h96: begin // MULX/MULUX: 32x32 -> 64 into reg pair (op2 = reg)
        logic [63:0] p;
        logic mul_signed;
        // Do not name this temporary "sgn": Quartus 17 treats block-local
        // declarations as task-wide and shadows the sgn() helper above.
        mul_signed = (cur_op == 8'h86);
        p = mul_signed ? $signed({{32{op1[31]}}, op1}) * $signed({{32{b[31]}}, b})
                       : {32'b0, op1} * {32'b0, b};
        f_z <= (p == 0); f_s <= p[63];   // MAME opMULX/opMULUX leave OV unchanged
        if (flag2) begin
            queue_reg_write(op2[4:0], p[31:0], 32'hffff_ffff);
            queue_reg_write(op2[4:0] + 5'd1, p[63:32], 32'hffff_ffff);
            st <= S_NEXT;
        end
        else begin
            // memory destination: store the 64-bit product as a qword.  The old
            // code computed flags but never wrote the result (audit R20 V60-9).
            movd_lo <= p[31:0];
            movd_hi <= p[63:32];
            st <= S_MOVD_WL;
        end
    end
    8'ha6, 8'hb6: begin // DIVX/DIVUX: (reg-pair 64) / op1 -> q in reg, r in reg+1
        if (op1 == 0) begin
            st <= S_NEXT;   // MAME: no zero-divide trap
        end
        else if (flag2) begin
            logic [63:0] num, mag_num;
            logic [31:0] mag_den;
            num = {rf_rdata_a, rf_rdata_b};
            if (cur_op == 8'ha6) begin
                mag_num = num[63] ? (~num + 1'b1) : num;
                mag_den = op1[31] ? (~op1 + 1'b1) : op1;
                xdiv_qneg <= num[63] ^ op1[31];
                xdiv_rneg <= num[63];
            end
            else begin
                mag_num = num;
                mag_den = op1;
                xdiv_qneg <= 1'b0;
                xdiv_rneg <= 1'b0;
            end
            xdiv_shift <= mag_num;
            xdiv_rem <= 0;
            xdiv_den <= mag_den;
            xdiv_cnt <= 0;
            xdiv_dst <= op2[4:0];
            xdiv_active <= 1'b1;
            divx_mem <= 1'b0;
            st <= S_DIVX;
        end
        // Memory op2: the qword dividend lives at [op2]; the low word is already
        // in op2val (f12_reads_dest), so read the high word then divide and write
        // the quotient/remainder back to memory.  The old code skipped the whole
        // operation for a memory operand (audit R20 V60-9).
        else st <= S_DIVXM_RH;
    end

    // ------------ XCH ------------
    8'h41, 8'h43, 8'h45: begin
        // Register-register completes here; one-memory and memory-memory forms
        // continue through the S_XCH microstates below.
        if (flag1 && flag2) begin
            logic [31:0] t;
            t = rf_rdata_a;
            setreg(op1[4:0], rf_rdata_b, d2);
            setreg(op2[4:0], t, d2);
            st <= S_NEXT;
        end
        else begin
            // XCH with memory operand(s): read mem side, swap, write back.
            //   flag1: op1 is reg, op2 is addr (or vice versa); mem-mem uses
            //   xch_addr for the second location.
            if (flag1 ^ flag2) begin
                // one register, one memory
                xch_addr <= flag1 ? op2 : op1;      // memory address
                alu_r    <= flag1 ? rf_rdata_a : rf_rdata_b; // register value
                wb_val   <= {27'b0, flag1 ? op1[4:0] : op2[4:0]}; // reg number
                rmw_dim  <= d2;
                st <= S_XCH1;
            end
            else begin
                // mem-mem (rare): read op1, read op2, cross-write
                xch_addr <= op1;
                wb_val   <= op2;
                rmw_dim  <= d2;
                st <= S_XCH2;
            end
        end
    end

    // ------------ SETF: store condition truth ------------
    8'h47: wb_op2({31'b0, cond_true(op1[3:0])}, 2'd0);

    // ------------ CALL (0x49) — A6: push AP, AP=op2, push retPC, PC=op1 -----
    8'h49: begin
        // MAME opCALL: SP-=4; [SP]=AP; AP=op2; SP-=4; [SP]=retPC; PC=op1.
        dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
        dbus_addr <= sp_m4;
        dbus_wdata <= r[29];          // push AP (R29) first
        queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
        queue_reg_write(5'd29, op2, 32'hffff_ffff); // AP (R29) = op2
        wb_val <= pc + 5'd2 + len1 + len2; // return PC, pushed in S_CALL1
        alu_r  <= op1;               // target
        st <= S_CALL1;
    end

    // ------------ PSW ops ------------
    8'h13, 8'h4a: begin   // UPDPSW: op1=value, op2=mask; width-limited
        logic [31:0] mask, val, lim;
        lim  = (cur_op == 8'h4a) ? 32'h0000_FFFF : 32'h00FF_FFFF;
        val  = op1 & lim;
        mask = (flag2 ? rf_rdata_b : op2val) & lim;
        write_psw((psw & ~mask) | (val & mask));
        st <= S_NEXT;
    end
    8'hf6, 8'hf7: begin   // GETPSW: WriteAM of PSW (reg or mem operand)
        total_len <= 5'd1 + len1;
        if (flag1) begin
            setreg(op1[4:0], psw, 2'd2);
            st <= S_NEXT;
        end
        else begin
            op2 <= op1; flag2 <= 0;
            rmw_kind <= 3'd6;   // width word via rmw_dim
            rmw_dim  <= 2'd2;
            wb_val <= psw;
            st <= S_WB_MEM;
        end
    end

    // ------------ TRAP/cc: 3-word frame, vector 48+(n&0xF) (A2) ------------
    8'hf8, 8'hf9: begin
        // MAME opTRAP: the operand's HIGH nibble is a Bcc-encoded condition
        // (cond 0xB never traps); only trap when it evaluates true, else fall
        // through.  The old code trapped unconditionally, so a compiler
        // TRAP/cc overflow/bounds check faulted every time (audit R20 V60-4).
        // vector = GETINTVECT(48 + (n&0xF)); code word = 0x3000 + 0x100*(n&0xF);
        // return PC = PC + amlength + 1.
        if (cond_true(op1[7:4])) begin
            exc_vector   <= 8'd48 + {4'b0, op1[3:0]};
            exc_code     <= {4'h3, op1[3:0], 8'h00, 16'h0004};
            exc_pushval  <= psw;
            exc_retpc    <= pc + 5'd1 + len1;
            exc_has_code <= 1'b1;
            st <= S_EXC_PUSH1;
        end
        else begin
            total_len <= 5'd1 + len1;
            st <= S_NEXT;
        end
    end

    // ------------ short-format ops decoded via C_SHORT ------------
    8'hd0, 8'hd1, 8'hd2, 8'hd3, 8'hd4, 8'hd5,   // DEC (RMW via addr in op1)
    8'hd8, 8'hd9, 8'hda, 8'hdb, 8'hdc, 8'hdd: begin // INC
        logic [1:0] d;
        logic inc;
        d = cur_op[2:1];
        inc = cur_op[3];
        if (flag1) begin
            // INC/DEC are ADDB/SUBB(dst,1,0): they produce the FULL add/sub
            // flags.  The old code set no overflow (so a signed branch after a
            // counter INC/DEC read a stale OV) and computed INC.W carry from a
            // constant-0 shift (audit R20 V60-5, the spidman enemy-attack path).
            res = dimext(rf_rdata_a, d) + (inc ? 32'd1 : 32'hffffffff);
            if (inc) begin
                f_cy <= zer(res, d);                       // carry: value wrapped
                f_ov <= ~sgn(rf_rdata_a, d) & sgn(res, d); // +max -> negative
            end
            else begin
                f_cy <= zer(rf_rdata_a, d);                // borrow: dst was 0
                f_ov <= sgn(rf_rdata_a, d) & ~sgn(res, d); // -min -> positive
            end
            set_zs(res, d);
            setreg(op1[4:0], res, d);
            total_len <= 5'd1 + len1;
            st <= S_NEXT;
        end
        else begin
            // memory RMW (ga2 path): read at op1, inc/dec, write back
            op2 <= op1; flag2 <= 0;
            rmw_kind <= inc ? 3'd0 : 3'd1;
            rmw_dim  <= d;
            total_len <= 5'd1 + len1;
            st <= S_RMW_RD;
        end
    end
    8'hd6, 8'hd7: begin // JMP
        pc <= op1;
        st <= S_FILL; st_after_fill <= S_DECODE;
    end
    8'he8, 8'he9: begin // JSR
        dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
        dbus_addr <= sp_m4;
        dbus_wdata <= pc + 5'd1 + len1;
        queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
        wb_val <= op1;
        st <= S_JSR1;
    end
    8'he2, 8'he3: begin // RET: adjustment in op1
        wb_val <= op1;
        dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2; dbus_addr <= r[31];
        st <= S_RET1;
    end
    8'hea, 8'heb, 8'hfa, 8'hfb: begin // RETIU/RETIS
        xch_addr <= op1;   // frame-destroy adjustment (added to SP at the end)
        dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2; dbus_addr <= r[31];
        st <= S_RETI1;
    end
    8'hee, 8'hef: begin // PUSH
        dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
        dbus_addr <= sp_m4;
        dbus_wdata <= op1;
        queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
        total_len <= 5'd1 + len1;
        st <= S_PUSH;
    end
    8'he6, 8'he7: begin // POP: op1 = dest addr/reg
        dbus_req <= 1; dbus_we <= 0; dbus_size <= 2'd2; dbus_addr <= r[31];
        total_len <= 5'd1 + len1;
        st <= S_POP;
    end
    8'hec, 8'hed: begin // PUSHM: op1 = mask
        total_len <= 5'd1 + len1;
        st <= S_PUSHM;
    end
    8'he4, 8'he5: begin // POPM
        total_len <= 5'd1 + len1;
        st <= S_POPM;
    end
    8'he0, 8'he1: begin // TASI
        total_len <= 5'd1 + len1;
        st <= S_TASI1;
    end
    8'hde, 8'hdf: begin // PREPARE: push FP (R30); FP=SP; SP -= imm
        dbus_req <= 1; dbus_we <= 1; dbus_size <= 2'd2;
        dbus_addr <= sp_m4;
        dbus_wdata <= r[30];
        total_len <= 5'd1 + len1;
        st <= S_PREP1;
    end
    8'hfc, 8'hfd: begin // STTASK: save selected task state at TR
        task_mask <= op1;
        task_addr <= trr;
        task_phase <= 0;
        task_reloaded <= 0;
        total_len <= 5'd1 + len1;
        write_psw(psw | 32'h1000_0000);
        st <= S_TASK_ST_NEXT;
    end
    8'hfe, 8'hff: begin // CLRTLB: consume the complete AM operand; no MMU state
        total_len <= 5'd1 + len1;
        st <= S_NEXT;
    end

    // string groups (0x58/0x5A) now set up entirely in decode + S_STR_OP1/OP2
    // (A1); they never reach exec_op.

    // ------------ privileged moves ------------
    8'h01: begin // LDTASK: load selected task state from operand-2 pointer
        logic [31:0] task_pointer;
        task_pointer = flag2 ? rf_rdata_b : (op2val_v ? op2val : op2);
        task_mask <= flag1 ? rf_rdata_a : op1;
        task_addr <= task_pointer;
        task_phase <= 0;
        task_reloaded <= 0;
        trr <= task_pointer;
        write_psw(psw & ~32'h1000_0000);
        st <= S_TASK_LD_NEXT;
    end
    8'h02: begin // STPR: op1 = priv reg #, op2 = dest
        logic [31:0] v;
        case (op1[4:0])
            5'd0: v = isp;  5'd1: v = l0sp; 5'd2: v = l1sp;
            5'd3: v = l2sp; 5'd4: v = l3sp; 5'd5: v = sbr;
            5'd6: v = trr;  5'd7: v = sycw; 5'd8: v = tkcw;
            5'd9: v = pir;  5'd15: v = psw2;
            5'd16: v = atbr0; 5'd17: v = atlr0;
            5'd18: v = atbr1; 5'd19: v = atlr1;
            5'd20: v = atbr2; 5'd21: v = atlr2;
            5'd22: v = atbr3; 5'd23: v = atlr3;
            5'd24: v = trmode;
            5'd25: v = adtr0; 5'd26: v = adtr1;
            5'd27: v = adtmr0; 5'd28: v = adtmr1;
            default: v = 0;
        endcase
        if (op1 <= 32'd28) wb_op2(v, 2'd2);
        else begin
            exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
        end
    end
    8'h12: begin // LDPR: op1 = value, op2 = priv reg #
        case (op2[4:0])
            5'd0: isp <= op1;  5'd1: l0sp <= op1; 5'd2: l1sp <= op1;
            5'd3: l2sp <= op1; 5'd4: l3sp <= op1; 5'd5: sbr <= op1;
            5'd6: trr <= op1;  5'd7: sycw <= op1; 5'd8: tkcw <= op1;
            5'd9: pir <= op1;  5'd15: psw2 <= op1;
            5'd16: atbr0 <= op1; 5'd17: atlr0 <= op1;
            5'd18: atbr1 <= op1; 5'd19: atlr1 <= op1;
            5'd20: atbr2 <= op1; 5'd21: atlr2 <= op1;
            5'd22: atbr3 <= op1; 5'd23: atlr3 <= op1;
            5'd24: trmode <= op1;
            5'd25: adtr0 <= op1; 5'd26: adtr1 <= op1;
            5'd27: adtmr0 <= op1; 5'd28: adtmr1 <= op1;
            default: ;
        endcase
        if (op2 <= 32'd28) st <= S_NEXT;
        else begin
            exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
        end
    end
    8'h4b: begin // CHLVL: level-specific synchronous exception
        logic [31:0] chlvl_data;
        chlvl_data = flag2 ? rf_rdata_b : (op2val_v ? op2val : op2);
        if (op1 > 32'd3) begin
            exc_vector <= 8'd8;
            exc_pushval <= psw;
            st <= S_EXC_PUSH1;
        end
        else begin
            exc_vector <= 8'd24 + op1[1:0];
            exc_code <= {8'h18 + op1[1:0], 8'h00, 16'h0008};
            exc_extra <= chlvl_data;
            exc_pushval <= psw;
            exc_retpc <= pc + 5'd2 + len1 + len2;
            exc_has_code <= 1'b1;
            exc_has_extra <= 1'b1;
            exc_target_level <= op1[1:0];
            exc_is_interrupt <= 1'b0;
            st <= S_EXC_PUSH1;
        end
    end
    8'h4d, 8'h4e, 8'h4f: begin // CHKA*: no MMU -> return address valid
        f_z <= 1; f_cy <= 0; f_s <= 0; st <= S_NEXT;
    end
    // IN/OUT — REAL ACCESSES, onto the ordinary data bus.
    //
    // These used to return a hardcoded 0xffffffff and discard writes, with the
    // comment "io space unused on S32". That is true of System 32 and false of
    // Model 1: model1_io maps the coprocessor's four registers — RAM address,
    // RAM data, the command FIFO and the FIFO status — at the SAME addresses as
    // model1_mem, so an IN or OUT there is a real transaction with real side
    // effects. Reading the FIFO pops it; writing the address register arms an
    // auto-increment.
    //
    // The consequence of faking it was total: the V60 sat in a three-instruction
    // poll at fed5a4 — INW, TESTB, BNE — reading a constant that never satisfied
    // the test, so attract mode never advanced. And because the I/O space carries
    // no bus traffic, a memory-side trace shows an empty loop and the fault looks
    // like a CPU bug rather than a missing address space.
    //
    // Routed to the same data bus because the two maps coincide on this board. A
    // machine that mapped them differently would need a separate space here.
    8'h20, 8'h22, 8'h24: begin  // IN.B/H/W
        st <= S_IN_RD;
    end
    8'h21, 8'h23, 8'h25: begin  // OUT.B/H/W
        st <= S_OUT_WR;
    end

    default: begin
        // synthesis translate_off
        $display("V60: exec fallthrough op %02x at %08x", cur_op, pc);
        // synthesis translate_on
        st <= S_NEXT;
    end
    endcase
endtask

// ---------------------------------------------------------------------------
// shift helpers (flags: CY = last bit out, Z/S from result)
// ---------------------------------------------------------------------------
function automatic shl_lastout(input [31:0] v, input [7:0] n, input [1:0] d, input left);
    logic [31:0] x;
    int w;
    x = dimext(v, d);
    w = (d==2'd0) ? 8 : (d==2'd1) ? 16 : 32;
    if (n == 0) shl_lastout = 1'b0;
    else if (left)  shl_lastout = (n <= w) ? x[w - n] : 1'b0;
    else            shl_lastout = (n <= 32) ? x[n - 1] : 1'b0;
endfunction

function automatic [31:0] shl_res(input [31:0] v, input [7:0] cnt, input [1:0] d);
    logic signed [7:0] c;
    logic [31:0] x;
    c = cnt;
    x = dimext(v, d);
    if (c >= 0) x = x << $unsigned(c);
    else        x = x >> $unsigned(-c);
    shl_res = x;
endfunction
function automatic [31:0] sha_res(input [31:0] v, input [7:0] cnt, input [1:0] d);
    logic signed [7:0] c;
    logic signed [31:0] x;
    c = cnt;
    x = (d==2'd0) ? {{24{v[7]}},v[7:0]} : (d==2'd1) ? {{16{v[15]}},v[15:0]} : v;
    if (c >= 0) x = x <<< $unsigned(c);
    else        x = x >>> $unsigned(-c);
    sha_res = x;
endfunction
// SHA left-shift overflow (MAME SHIFTLEFT_OV op12.hxx): OV is set when the top
// `count` bits of the width-sized value are not all equal to the sign bit —
// i.e. a bit different from the sign is shifted out through the top.  MAME masks
// exactly `count` bits (((1<<count)-1) << (bitsize-count)); using count+1 here
// spuriously set OV (e.g. SHA.B #1,0x40 gave OV=1 vs MAME OV=0), misbranching a
// following signed Bcc (S^OV).  audit V60-7 residual fixed.
function automatic sha_left_ov(input [31:0] v, input [7:0] cnt, input [1:0] d);
    logic signed [7:0] c;
    integer w;
    logic [31:0] field, ones;
    c = cnt;
    w = (d==2'd0) ? 8 : (d==2'd1) ? 16 : 32;
    if (c <= 0)      sha_left_ov = 1'b0;              // right shift / zero: no OV
    else if (c > w)  sha_left_ov = (dimext(v,d) != 0);// count > width: MAME's macro is UB here (bitsize-count<0); any nonzero value overflowed
    else begin       // 1 <= count <= width: exact MAME SHIFTLEFT_OV mask (count==width uses the full-width mask, matching MAME's count==bitsize case, e.g. SHA.B #8,-1 -> OV=0)
        field = (dimext(v,d) >> $unsigned(w - c)) &
                ((32'd1 << $unsigned(c)) - 1);  // top `count` bits
        ones  = (32'd1 << $unsigned(c)) - 1;
        sha_left_ov = sgn(v,d) ? (field != ones) : (field != 32'd0);
    end
endfunction
function automatic [31:0] rot_res(input [31:0] v, input [7:0] cnt, input [1:0] d);
    logic signed [7:0] c;
    logic [31:0] x;
    logic [7:0] mag;
    logic [5:0] sh, w;
    logic [31:0] mask;
    c = cnt;
    x = dimext(v, d);
    mag = c[7] ? (8'h00 - cnt) : cnt;
    case (d)
        2'd0: begin w = 6'd8;  sh = {3'b0, mag[2:0]}; mask = 32'h0000_00ff; end
        2'd1: begin w = 6'd16; sh = {2'b0, mag[3:0]}; mask = 32'h0000_ffff; end
        default: begin w = 6'd32; sh = {1'b0, mag[4:0]}; mask = 32'hffff_ffff; end
    endcase
    // ONE ROTATE, NOT TWO. A rotate RIGHT by sh is a rotate LEFT by w-sh, so
    // both directions are the same expression with a different amount. Written
    // as two branches it inferred FOUR 32-bit barrel shifters - the genuinely
    // variable kind, unlike the `1 << n` decoders and the 0-or-1 amounts
    // elsewhere in this file - because Quartus will not share logic across
    // branches it cannot prove exclusive. Now it infers two.
    //
    // sh is nonzero here (the first branch takes sh == 0) and is masked to
    // log2(w) bits, so sh and w-sh both lie in 1..w-1 and neither shift can
    // reach w. Checked for all three widths: for c[7], L = w-sh turns
    // (x >> sh)|(x << (w-sh)) into (x << (w-sh))|(x >> sh), the same two terms.
    if (sh == 0)     rot_res = x & mask;
    else begin
        logic [5:0] l;
        l = c[7] ? (w - sh) : sh;
        rot_res = ((x << l) | (x >> (w - l))) & mask;
    end
endfunction
// ---------------------------------------------------------------------------
// multiply/divide iterative engine
// ---------------------------------------------------------------------------
task automatic md_step;
    if (cur_op[5] == 1'b0 && (cur_op == 8'h81 || cur_op == 8'h83 || cur_op == 8'h85 ||
        cur_op == 8'h91 || cur_op == 8'h93 || cur_op == 8'h95)) begin
        // multiply: shift-add.  One full nonblocking assignment folds the
        // conditional partial-product add into the right shift; a separate
        // mdacc[63:32] write would be overwritten by this and was removed.
        mdacc <= {1'b0, (mdacc[0] ? mdacc[63:32] + mdop : mdacc[63:32]), mdacc[31:1]};
    end
    else begin
        // divide: non-restoring-ish simple restoring step
        logic [63:0] sh;
        sh = {mdacc[62:0], 1'b0};
        if (sh[63:32] >= mdop) begin
            sh[63:32] = sh[63:32] - mdop;
            sh[0] = 1'b1;
        end
        mdacc <= sh;
    end
endtask
task automatic md_finish;
    logic [1:0] d2;
    d2 = f12_dim2(cur_op);
    case (cur_op)
    8'h81, 8'h83, 8'h85, 8'h91, 8'h93, 8'h95: begin
        // Overflow was a constant-0 upper-word test (always false for byte/half)
        // and, for signed MUL, tested the unsigned product's high half (audit
        // R20 V60-6).  Compute the exact width-correct signed/unsigned product
        // overflow from the retained operands.
        logic [63:0] uprod;
        logic signed [63:0] sprod;
        logic signed [31:0] sa32, sb32;
        uprod = {32'b0, mdop} * {32'b0, md_savb};                 // unsigned product
        sa32  = (d2==2'd0) ? {{24{mdop[7]}},   mdop[7:0]}   :
                (d2==2'd1) ? {{16{mdop[15]}},  mdop[15:0]}  : mdop;
        sb32  = (d2==2'd0) ? {{24{md_savb[7]}},md_savb[7:0]}:
                (d2==2'd1) ? {{16{md_savb[15]}},md_savb[15:0]} : md_savb;
        sprod = $signed({{32{sa32[31]}}, sa32}) * $signed({{32{sb32[31]}}, sb32});
        set_zs(mdacc[31:0], d2);
        // MAME opMUL/opMULU: OV = (product >> width) != 0 on the product's
        // unsigned bit pattern (signed product for MUL, unsigned for MULU).
        // For byte/half MAME shifts the 32-bit value; for word, the 64-bit one.
        // A negative signed product therefore also sets OV (e.g. MUL.W -1*1).
        if (!cur_op[4])  // MUL (signed)
            f_ov <= (d2==2'd0) ? (sprod[31:8]  != 0) :
                    (d2==2'd1) ? (sprod[31:16] != 0) :
                                 (sprod[63:32] != 0);
        else             // MULU (unsigned)
            f_ov <= (d2==2'd0) ? (uprod[31:8]  != 0) :
                    (d2==2'd1) ? (uprod[31:16] != 0) :
                                 (uprod[63:32] != 0);
        wb_op2(mdacc[31:0], d2);
    end
    8'ha1, 8'ha3, 8'ha5, 8'hb1, 8'hb3, 8'hb5: begin // DIV: quotient (signed applied)
        logic [31:0] q;
        q = md_qsign ? (~mdacc[31:0] + 1'b1) : mdacc[31:0];
        set_zs(q, d2);
        f_ov <= md_divov;      // signed min/-1 overflow (audit R20 V60-8)
        wb_op2(q, d2);
    end
    8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55: begin // REM: remainder (sign of dividend)
        logic [31:0] rem;
        rem = md_rsign ? (~mdacc[63:32] + 1'b1) : mdacc[63:32];
        set_zs(rem, d2);
        f_ov <= 1'b0;          // MAME clears OV for REM/REMU (audit R20 V60-8)
        wb_op2(rem, d2);
    end
    default: ;
    endcase
endtask

`ifndef S32_V60_NO_FP
// Only the predicates DECODE and the operand setup need before v60_fp is ever
// started. Everything else - the arithmetic, the divider, the dispatch and the
// flag computation - moved to rtl/cpu/v60/v60_fp.sv.

function automatic fp_valid(input [7:0] op, input [4:0] sub);
    if (op == 8'h5f) fp_valid = (sub == 5'h00) || (sub == 5'h01);       // CVTWS/CVTSW
    else fp_valid = (sub == 5'h00) || (sub == 5'h08) || (sub == 5'h09)  // CMPF/MOVFS/NEGFS
                 || (sub == 5'h0a) || (sub == 5'h10) || (sub == 5'h18)  // ABSFS/SCLFS/ADDFS
                 || (sub == 5'h19) || (sub == 5'h1a) || (sub == 5'h1b); // SUBFS/MULFS/DIVFS
endfunction

function automatic [1:0] fp_dim1(input [7:0] op, input [4:0] sub);
    fp_dim1 = (op == 8'h5c && sub == 5'h10) ? 2'd1 : 2'd2;
endfunction

function automatic fp_op2_value(input [7:0] op, input [4:0] sub);
    fp_op2_value = (op == 8'h5c) && (sub == 5'h00);                     // CMPF
endfunction

function automatic fp_op2_rmw(input [7:0] op, input [4:0] sub);
    fp_op2_rmw = (op == 8'h5c) && (
                 (sub == 5'h10) || (sub == 5'h18) || (sub == 5'h19) ||  // SCLFS/ADDFS/SUBFS
                 (sub == 5'h1a) || (sub == 5'h1b));                     // MULFS/DIVFS
endfunction
`endif


// ---------------------------------------------------------------------------
// Instruction fetch: the 24-byte window, its realign network, the loop cache
// and the prefetch unit. Extracted so the area can be measured - the V60 was a
// single flat 17,771-ALM entity and nothing could report where that went.
// ---------------------------------------------------------------------------
v60_ifetch #(
    .START_PC(START_PC), .FB_THRESH(FB_THRESH),
    .PF_HIGH(PF_HIGH),   .FAST_IFETCH(FAST_IFETCH)
) u_ifetch (
    .clk(clk), .rst_n(~rst), .ce(ce),
    .pc(pc), .fill_active(st == S_FILL), .fill_ready(fill_ready),
    .fb_flat(fb_flat), .fb_base(fb_base), .fb_valid(fb_valid),
    .fb_need(fb_need), .fb_wr(fb_wr),
    .if_req(if_req), .if_addr(if_addr), .if_data_i(if_data), .if_ack(if_ack),
    .pf_req(pf_req), .pf_addr_o(pf_addr), .pf_ack(pf_ack), .bus_rdata(bus_rdata),
    .dbus_req(dbus_req), .dbus_we(dbus_we), .dack(dack),
    .dbus_addr(dbus_addr), .dbus_size(dbus_size)
);

`ifndef S32_V60_NO_FP
// The floating-point group. Declared late because it needs cur_op and subop,
// which the decode section further up introduces.
v60_fp u_fp (
    .clk(clk), .ce(ce), .rst(rst),
    .start(fp_start), .op(cur_op), .subop(subop[4:0]),
    .a(fp_a), .b(fp_b), .cw(tkcw[2:0]),
    .done(fp_done), .writes(fp_writes), .result(fp_result),
    .o_z(fp_o_z), .o_s(fp_o_s), .o_ov(fp_o_ov), .o_cy(fp_o_cy)
);
`endif

endmodule
