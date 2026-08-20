//============================================================================
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Booting real game code.
//
// Everything up to now has been checked against MAME's descriptions or against
// synthetic programs. This runs the actual ROM: the V60 starts at the
// architectural reset vector, fetches through m1_decode's packed mapping, and
// executes whatever Sega wrote. It is the first test that can be wrong in ways
// no amount of unit testing predicts.
//
// It answers several open questions at once:
//
//   - does the decode hold up on real code, rather than on 466k synthetic
//     addresses
//   - real-code cycles per instruction, which the 12-byte loop in tb_v60_cpi
//     cannot give and which the whole timing argument rests on
//   - whether dbg_fp_trap ever fires, which decides a ~2,000 ALM build option
//   - and when it stops making progress, dbg_pc says exactly where
//
// The SDRAM device model is preloaded directly rather than through the ROM
// loader. The loader is tested separately and pushing 1.5 MB through it would
// cost about 8 M cycles of simulation before the CPU had executed anything.
//
// ROM images are not in the repository. Build the preload with
//   python3 tools/build_rom_image.py vr ~/roms/vr.zip -o build/rom
//============================================================================
`timescale 1ns/1ps

module tb_m1_boot #(
    parameter integer RUN_CYCLES = 3000000,
    parameter string  ROMHEX     = "build/rom/vr_v60.hex",
    // Page whose individual addresses are logged. Defaults to the I/O board's
    // dual-port RAM, which is where boot used to stop.
    //
    // Every count this testbench prints scales with RUN_CYCLES. Quote the two
    // together — a set of figures recorded without its run length already read
    // as a regression once, and was not one.
    parameter [7:0]   WATCH_PAGE = 8'hC0,

    // Emit one line per TGP instruction retired, for tools/tgp_trace.sh to diff
    // against MAME's own tracer on :tgp_copro. The counterpart of PCTRACE on the
    // V60 side, and the thing M0 exit criterion 2 has always owed: what exists is
    // a whole-CPU reference in lockstep over GENERATED instructions, which cannot
    // catch the coprocessor running REAL microcode differently — and it is.
    //
    // retire/retire_pc come straight out of mb86233_core and are already what the
    // core considers an instruction boundary, so this is not a new definition of
    // "retired" invented for the trace.
    parameter bit     TGPTRACE   = 0,

    // Forces the TGP's unimplemented math-unit reads to 0 instead of table-base
    // data. See m1_tgp's io_rdata mux: an experiment, not a feature. The question
    // it answers is whether the V60's wait at FED5A4 is the only thing between
    // here and the per-frame 2D setup.
    parameter bit     MATH_ZERO  = 0
);

// Packed V60-visible ROM: ROMX at word 0, ROM0 at word 0x80000.
// ROMX, ROM0 and the banked data ROMs — the boot ROM checksums the data ROMs
// too, so preloading only the program leaves that sweep reading zeros — plus the
// coprocessor's two read-only regions above them: copro_data at word 0x300000
// and copro_tables at 0x400000, ending at 0x420000.
//
// Sized to the hex the packer emits. It grew when the coprocessor regions were
// added and $readmemh failed with "file address beyond bounds of array", which is
// at least a loud failure — a short array that silently truncated would have left
// the TGP reading zeros and looked like a coprocessor fault.
localparam integer PRELOAD_WORDS = 32'h420000;

// TWO CLOCK DOMAINS, which is what the core actually has: memory and video on
// the fast clock, the V60 on the slow one. 100/25 MHz here rather than the
// design's 96/24 because a 5 ns half-period keeps the trace arithmetic round;
// the ratio is the same 4:1 and that is what the crossings care about.
//
// This testbench is where the two-domain design gets its only functional test.
// The individual crossings are verified in isolation; boot is what proves they
// work together, in a design where a lost transaction shows up as a CPU that
// stops rather than as an assertion.
reg clk = 0, clk_cpu = 0, rst_n = 0;
always #5  clk     = ~clk;        // 100 MHz, memory and video
always #20 clk_cpu = ~clk_cpu;    // 25 MHz, the V60

// The V60 gets every slow edge. At 25 MHz that is above the ~17 MHz the CPI
// analysis says is needed to match a 16 MHz part, and under the 24.62 MHz the
// core closes at.
wire ce = 1'b1;

// Reset released separately into each domain.
reg [1:0] rs_sys = 0, rs_cpu = 0;
wire rst_n_sys = rs_sys[1];
// HELD UNTIL THE MICROCODE IS LOADED, which is what the hardware does and what this
// bench did not. m1_integrated's comment states the contract — "Complete before the CPU
// is released, so there is no crossing to handshake" — and on the board that holds
// because m1_rom_loader streams during the ioctl download and the CPU waits on
// rom_loaded. Here the loader ran concurrently with execution.
//
// It advances four addresses per CPU cycle (100 MHz against 25 MHz), so the whole image
// takes 512 CPU cycles — and the coprocessor reached microcode address 0x07e6 while the
// loader was still at 0x07c6. prog[0x07e6] was therefore genuinely zero AT THAT MOMENT,
// which is why the UCODE CHECK — which runs after the load — always passed while the
// core fetched nothing. A zero word decodes as `lab`, so `ldi #0x8000, b0` never wrote
// b0, and every downstream symptom followed from that.
wire rst_n_cpu = rs_cpu[1] & uc_done;
always @(posedge clk     or negedge rst_n) if (!rst_n) rs_sys <= 0; else rs_sys <= {rs_sys[0], 1'b1};

// Streamed in while reset is asserted, one word per fast cycle.
//
// THIS LOADER SHIFTED THE WHOLE MICROCODE IMAGE BY ONE WORD. It read
//
//     uc_data <= ucode[uc_addr];
//     if (uc_we) uc_addr <= uc_addr + 11'd1;
//
// with both assignments non-blocking, so during any cycle uc_addr was already A
// while uc_data still held ucode[A-1], and m1_tgp wrote prog[A] = ucode[A-1].
// Address 0 came out right BY ACCIDENT — the address does not advance on the
// first cycle, because uc_we is still low — which is why the first instruction
// executed correctly and every one after it came from the wrong word.
//
// It cost real time: `make tgp_trace` reported our coprocessor branching to
// 0x07e2 one instruction late, and the microcode ROM on disk was byte-for-byte
// identical to the reference, so the fault looked like a `bsif` bug in
// mb86233_seq. The instruction at what we called 0x3f WAS the bsif; it had been
// loaded one word high.
//
// uc_data is now combinational on uc_addr, so the word presented is always the
// word for the address presented.
// AND IT MUST STOP AFTER ONE PASS. `uc_addr` is 11 bits, so incrementing past 2047
// WRAPS IT TO 0 — at which point `uc_addr != 2047` is true again and the loader
// restarts, streaming for ever. With `uc_data` combinational that mostly rewrites the
// same words, which is why it went unnoticed; but the write port is shared with the
// core's instruction fetch inside m1_tgp, and a fetch colliding with a write to the
// same address returns undefined data. That is how `prog[0x07e6]` verified as
// 40008000 immediately after the load and read back as ZERO when the core fetched it,
// which cost the whole afternoon: `ldi #0x8000, b0` fetched as 00000000 decodes as
// `lab`, so b0 was never written and every downstream conclusion was about a
// consequence.
//
// `uc_done` latches at the end of the single pass and is never cleared except by reset.
reg uc_done = 1'b0;
always @(posedge clk) begin
    if (!rst_n) begin
        uc_we <= 1'b0; uc_addr <= '0; uc_done <= 1'b0;
    end else if (!uc_done) begin
        uc_we <= 1'b1;
        if (uc_we) uc_addr <= uc_addr + 11'd1;
        if (uc_addr == 11'd2047 && uc_we) begin
            uc_we   <= 1'b0;
            uc_done <= 1'b1;
        end
    end
end
always @(posedge clk_cpu or negedge rst_n) if (!rst_n) rs_cpu <= 0; else rs_cpu <= {rs_cpu[0], 1'b1};

// rom_loaded crosses fast to slow; it only ever rises once, before the CPU runs.
reg [1:0] mem_ready_cpu = 0;
always @(posedge clk_cpu or negedge rst_n_cpu)
    if (!rst_n_cpu) mem_ready_cpu <= 0;
    else            mem_ready_cpu <= {mem_ready_cpu[0], mem_ready};

wire        sdr_req, sdr_we;
wire [24:1] sdr_addr;
wire [15:0] sdr_din, sdr_dout;
wire  [1:0] sdr_be;
wire        sdr_ack;
wire        if_req, if_ack;
wire [23:0] if_addr;
wire [24:1] if_sdram_addr;
wire [63:0] if_data;
wire [23:0] dbg_pc;
wire        dbg_halted, dbg_fp_trap;
wire [15:0] dbg_io_replies;
wire        mem_ready;
wire [15:0] dbg_tgp_retires, dbg_tgp_pc;
wire [15:0] tio_addr;
wire        tio_rd, tio_wr, tio_ack, tfifo_rd, tfifo_wr;

// Log the coprocessor's first IO accesses, and how long each waited. An access
// that never acks is the difference between a decode gap and a dead core, and
// they look identical from a frozen retire count.
integer tio_n = 0, tio_wait = 0;
reg     tio_seen = 0;
always @(posedge clk_cpu) begin
    if ((tio_rd || tio_wr) && !tio_seen) begin
        tio_seen <= 1'b1; tio_wait = 0;
    end
    if ((tio_rd || tio_wr) && tio_seen) tio_wait = tio_wait + 1;
    if (tio_ack && tio_seen) begin
        tio_seen <= 1'b0;
        tio_n = tio_n + 1;
        // COMPARE THIS LIST AGAINST THE REFERENCE'S, WHICH IS THREE LINES LONG:
        // W 002e, R 8010, R 8020, and nothing else in 30 frames. Ours opens with
        // five reads of io 0000 — copro_ramadr — that the reference never makes,
        // and then reads 8000 where it reads 8010. So our TGP is running the
        // microcode differently from its first accesses, which is the concrete
        // form of the microcode-driven lockstep M0 exit criterion 2 still owes.
        if (tio_n <= 14)
            $display("BOOT:   TGP io %0d: %s %04h  waited %0d", tio_n,
                     tio_wr ? "W" : "R", tio_addr, tio_wait);
    end
end

// ------------------------------------------------------ WHERE THE CPI GOES
//
// The V60 measures ~6 CPI in isolation (tools/v60_cpi_sweep.sh at the shipped
// ce=1, across memory latencies 0..64) and ~20 CPI running real code here. The
// sweep cannot explain the difference: its workload is 514 instructions producing
// FOUR instruction fetches — the test code sits inside the fetch window and loops,
// so it never stresses fetch, which is why latency barely moves its number.
//
// Neither figure says where the cycles actually go, so count them. Three buckets,
// in the CPU's own clock domain:
//
//   data stall   — a data-side bus request outstanding and unacknowledged
//   fetch stall  — an instruction fetch outstanding and unacknowledged
//   running      — everything else
//
// A cycle can be in both stall buckets; they are counted independently rather than
// forced to partition, because the V60 arbitrates one bus between them and
// pretending otherwise would hide the arbitration.
// The union is counted too, because the two buckets CAN overlap and adding them
// would overstate the total — the sort of arithmetic that turns a measurement into
// a claim.
integer v_cyc = 0, v_dstall = 0, v_fstall = 0, v_anystall = 0;
always @(posedge clk_cpu) begin
    if (rst_n_cpu && ce) begin
        automatic bit ds = main.cpu.dbus_req && !main.cpu.dack;
        automatic bit fs = main.cpu.if_req  && !main.cpu.if_ack_i;
        v_cyc = v_cyc + 1;
        if (ds)       v_dstall   = v_dstall   + 1;
        if (fs)       v_fstall   = v_fstall   + 1;
        if (ds || fs) v_anystall = v_anystall + 1;
    end
end

// ---------------------------------------- PROOF THE MICROCODE IS ACTUALLY LOADED
//
// The core fetched 00000000 at 0x07e6 where the hex holds 40008000, and an all-zero
// word decodes as `lab` — which is why three separate conclusions about decoding and
// register writes were consequences rather than causes. Sampling one address cannot
// tell a loader fault from a file fault from an early-execution race, so compare ALL
// 2048 words of program RAM against what $readmemh put in `ucode`, once the stream has
// finished, and report the first mismatches with a total.
//
// Reported as a count and examples rather than a pass/fail: "how many and where" tells
// you which of the three it is, where "FAIL" would not.
integer uc_i2, uc_bad;
reg     uc_checked = 1'b0;
reg     uc_we_d    = 1'b0;
always @(posedge clk) begin
    // Trigger on uc_we FALLING, not on uc_addr == 2047: uc_addr is 11 bits and wraps
    // to 0 when it increments past 2047, so that value is not still there afterwards.
    uc_we_d <= uc_we;
    if (rst_n && uc_we_d && !uc_we && !uc_checked) begin
        uc_checked <= 1'b1;
        uc_bad = 0;
        for (uc_i2 = 0; uc_i2 < 2048; uc_i2 = uc_i2 + 1) begin
            if (main.tgp.prog[uc_i2] !== ucode[uc_i2]) begin
                if (uc_bad < 8)
                    $display("UCODE MISMATCH @%04h: prog=%08h ucode=%08h",
                             uc_i2[15:0], main.tgp.prog[uc_i2], ucode[uc_i2]);
                uc_bad = uc_bad + 1;
            end
        end
        $display("UCODE CHECK: %0d of 2048 words differ; prog[07e6]=%08h ucode[07e6]=%08h hex should be 40008000",
                 uc_bad, main.tgp.prog[16'h07e6], ucode[16'h07e6]);
    end
end

// WHERE AN IO-SOURCED VALUE IS LOST. tgp_wrtrace puts the first value divergence at
// write 22: data[0x69] should get 00000030, the coprocessor data ROM's word, and gets
// zero — while the io read itself returns 00000030 correctly (the boot trace prints
// it). So the loss is between io_rdata and the store. Print the capture.
integer sv_n = 0;
reg     sv_armed = 1'b0;
always @(posedge clk_cpu) begin
    // EVERY CYCLE IN A WINDOW, NOT A FILTERED SUBSET.
    //
    // Filtering to `io_rd && io_addr[15]` printed only the cycles DURING an io read,
    // hiding S_DST, S_RETIRE, S_FETCH and S_DECODE — which are exactly the cycles
    // where src_val changed. The result was a trace showing a transition it never
    // covered, and three mechanisms were invented to explain the gap.
    //
    // So: arm on the first acknowledged read of io 0x8010, then print EVERY cycle for
    // the next 40, unfiltered. That covers the capture, the store, and everything
    // between.
    // ARM ON THE INSTRUCTION, NOT ON A SYMPTOM OF THE WORKING CASE.
    //
    // The previous version armed on `io_addr == 0x8010 && io_ack`, which is the
    // address the SECOND execution of 07E7 uses. The operand is (bx0) = b0 + x0 with
    // b0 = 0x8000 from 07E6, so the first execution reads a different address — and
    // the trace therefore showed only the pass that works, which is why the capture
    // and store looked perfect while the stored value was wrong.
    // Arm one instruction EARLIER, on 07E6 (`ldi #0x8000, b0`), so the trace covers
    // the write that should set b0 as well as the read that uses it. Arming on 07E7
    // showed b0 already wrong with no way to tell whether 07E6 had run at all.
    // Arm on 07E5 so S_FETCH of 07E6 is visible. Every trace before this armed one
    // cycle late — their first line is st=1, S_FETCH_W — so the fetch itself, which is
    // the thing in question, has never actually been shown.
    if (rst_n_cpu && !sv_armed && main.tgp.core.seq_pc == 16'h07e5)
        sv_armed <= 1'b1;
    if (rst_n_cpu && sv_armed && sv_n < 40) begin
        // mem_rdata and mem_stall too. The three candidates for src_val taking the
        // io ADDRESS rather than the io DATA are: the wrong mux leg (x_src_sp not
        // EP_IO at the capturing edge, selecting a stale mem_rdata), a guard that
        // lets the state advance early, or a print sampling the wrong clock. These
        // fields separate all three.
        $display("W%0d pc=%04h ir=%08h st=%0d paddr=%04h prd=%08h ucwe=%b ucaddr=%04h ucdone=%b pr7e6=%08h",
                 sv_n, main.tgp.core.seq_pc, main.tgp.core.ir,
                 main.tgp.core.state,
                 main.tgp.core.prog_addr, main.tgp.core.prog_rdata,
                 uc_we, {5'd0, uc_addr}, uc_done,
                 main.tgp.prog[16'h07e6]);
        sv_n = sv_n + 1;
    end
end

// ------------------------- VALUE-LEVEL TRACE: EVERY TGP DATA-MEMORY WRITE
//
// The PC-stream lockstep (make tgp_trace) can only catch a wrong value once it
// changes control flow, which is why it stops at `0731 brif ged` while the error is
// upstream in the FP chain at 06EE-070C. This is the value trace that localises it.
//
// One line per write, in the same shape tools/mame_tgp_wrtrace.lua emits for the
// reference, so the two diff directly. That Lua tap works where three attempts at
// per-instruction REGISTERS did not: program-space taps never fire, `trace`'s
// {tracelog} action emits nothing, and bpset actions never fired. Data writes are
// what the microcode stores its results into, so they are the quantity that matters.
//
// EDGE-DETECTED. mb86233_core asserts mem_req in both S_DST and S_DST_W — it must,
// because the address has to hold across a registered access — so a write appears on
// two consecutive cycles and would be logged twice. That is the same shape as the
// FIFO double-push fixed on 2026-08-18; here it only affects the trace.
reg  tw_req_d = 0;
wire tw_wr = main.tgp.core.u_mem.req && main.tgp.core.u_mem.we
          && (main.tgp.core.u_mem.sel_ram0 || main.tgp.core.u_mem.sel_ram1);
integer tw_n = 0;
always @(posedge clk_cpu) begin
    if (!rst_n_cpu) begin
        tw_req_d <= 1'b0;
    end else begin
        tw_req_d <= tw_wr;
        if (TGPTRACE && tw_wr && !tw_req_d && tw_n < 60000) begin
            // PC with every write — see the Lua tap's comment. A write-stream
            // divergence without it says the streams differ but not which
            // instruction differs, and write 22 turned out to be an extra store
            // rather than a wrong value.
            $display("TW %04h %08h pc=%04h x0=%04h a=%08h d=%08h",
                     main.tgp.core.u_mem.addr[15:0], main.tgp.core.u_mem.wdata,
                     main.tgp.core.seq_pc,
                     main.tgp.core.u_regs.x0,
                     main.tgp.core.u_regs.reg_a, main.tgp.core.u_regs.reg_d);
            tw_n = tw_n + 1;
        end
    end
end

// WHO WRITES COPRO RAM? dbg_ram_writes counts only the V60's writes (we && a1 in
// S_V60_RAM); the S_TGP path has its own `ram_we = tgp_we` that the counter never
// sees. So "copro RAM writes=0" never meant "nobody writes it" — the same
// counter-name trap as dbg_fifo_pops. The array is confirmed zeroed at time 0
// (CRAM INIT prints ram[0]=00000000) and later reads ffffffff, so someone writes it.
integer rw_n = 0;
always @(posedge clk_cpu) begin
    if (rst_n_cpu && main.copro.ram_we && rw_n < 16) begin
        $display("CRAM WR: st=%0d addr=%04h din=%08h  tgp_we=%b tgp_addr=%04h v60_we=%b a1=%b",
                 main.copro.st, main.copro.ram_addr, main.copro.ram_din,
                 main.copro.tgp_we, main.copro.tgp_addr, main.copro.we, main.copro.a1);
        rw_n = rw_n + 1;
    end
end

// -------------------------------- WHY A COPRO RAM READ RETURNS 0xff, NOT ram[adr]
//
// The V60 spins at FED5A4 on `in.w [R1], R0` / `test.b` / `bne`, which the reference
// leaves after ~32 iterations when the low byte reads ZERO. Ours reads ff, 1.1 M
// times. 0xff is the unmapped default, so the read is not returning ram[adr] — and
// m1_main's routing, m1_decode's select, m1_copro_if's S_IDLE ordering and
// S_V60_RAM's assignment ALL read as correct. Print the internals instead of
// reading them again.
integer cram_n = 0;
always @(posedge clk_cpu) begin
    if (rst_n_cpu && main.m_req && !main.m_we && main.sel_copro_ram && cram_n < 12) begin
        $display("CRAM rd: st=%0d adr=%04h a1=%b ram_addr=%04h ram_q=%08h q=%04h ack=%b served=%b",
                 main.copro.st, main.copro.adr, main.copro.a1,
                 main.copro.ram_addr, main.copro.ram_q, main.copro.q,
                 main.copro.ack, main.copro.served);
        cram_n = cram_n + 1;
    end
end

// ------------------------------------------- THE COMMAND PROTOCOL, BOTH SIDES
//
// The V60 stalls at ff9754 after 4 pushes while the TGP stalls at 0x00a5 wanting
// more, so the two disagree about how long a command is. The reference's answer is
// measured — tools/mame_tgp_fifo.lua, five words in and one out:
//
//     0x100 ->  04000000 00000000 01000000 3f400000 428c0000
//     0x400 <-  42520000
//
// Print what each side actually moves rather than inferring it from counters. Two
// counters have been misread as missing features already.
reg [15:0] pushes_prev = 0;
reg [15:0] pops_prev   = 0;
always @(posedge clk_cpu) begin
    if (rst_n_cpu) begin
        if (main.copro.dbg_fifo_pushes != pushes_prev) begin
            $display("COPRO PUSH %0d: %04h_%04h",
                     main.copro.dbg_fifo_pushes, main.m_wdata, main.copro.lat_lo);
            pushes_prev <= main.copro.dbg_fifo_pushes;
        end
        if (main.tgp.fifo_in_pop && main.tgp.fifo_in_valid)
            $display("COPRO POP      : %08h  (tgp pc %04h)",
                     main.tgp.fifo_in_data, main.tgp.core.seq_pc);
        if (main.tgp.fifo_out_push)
            $display("COPRO RESULT   : %08h", main.tgp.fifo_out_data);
    end
end

// ONE LINE PER TGP RETIRE. m1_tgp runs on `clk` in m1_main, which this bench
// drives as clk_cpu, so the retire strobe is sampled in its own domain.
integer tgptr_n = 0;
// THE ADDRESS THE INSTRUCTION WAS ACTUALLY FETCHED FROM. retire_pc publishes
// seq_pc, which is not necessarily the address `ir` came from — that is exactly
// what is in question here, so capture it independently at S_FETCH (state 0)
// rather than trusting either signal.
reg [15:0] tgp_fetch_pc = 16'hffff;
always @(posedge clk_cpu)
    if (main.tgp.core.state == 4'd0) tgp_fetch_pc <= main.tgp.core.seq_pc;

always @(posedge clk_cpu) begin
    if (TGPTRACE && rst_n && main.tgp.retire && tgptr_n < 4000000) begin
        // Extra fields after the PC on purpose: tgp_trace.sh takes field 2 as the
        // PC and ignores the rest, so the diff still works while a bare eyeball
        // gets the opcode and the branch decode that produced it.
        // a/b/d as well: the command-dispatch loop at 0x44-0x49 compares a FIFO
        // word against data RAM 0xb, and which of the two is wrong is not
        // decidable from the PC stream. tgp_trace reads field 2 only, so extra
        // fields cost nothing.
        // ST too, and ZRD broken out (bit 1). The dispatch loop at 0x44-0x49 ends
        // in `brif !zrd`, and our core takes that branch with d == 0 — so either
        // ZRD is not set when it should be, or the condition is misread. Printing
        // both settles which without reading any more RTL.
        // x0/x1 as well. The divergence at 0730 `fadd` takes its operands from
        // them — `$0x43` and `$3` are read_reg 0x03 = x1, `$0x42` is 0x02 = x0 —
        // and CLAUDE.md names x0/x1 as shared state: they live in the register file
        // but the AGU's post-increment wins. So the operands are the likelier
        // suspect than the FP flag, and this prints both.
        $display("TGPPC %04h ir=%08h a=%08h d=%08h st=%08h x0=%04h x1=%04h",
                 main.tgp.retire_pc, main.tgp.core.ir,
                 main.tgp.core.dbg_a, main.tgp.core.dbg_d,
                 main.tgp.core.dbg_st,
                 main.tgp.core.u_regs.x0, main.tgp.core.u_regs.x1);
        tgptr_n = tgptr_n + 1;
    end
end

// The coprocessor's read-only SDRAM regions. m1_main is in the CPU domain here
// and the SDRAM model in the fast one, so this crosses the same way the CPU's
// data port does. One port for both regions: the TGP holds its request until
// ack, so it can only have one outstanding.
localparam [24:1] COPRO_DAT_BASE = 24'h300000;
localparam [24:1] COPRO_TBL_BASE = 24'h400000;
wire        t_tbl_req, t_dat_req;
wire [15:0] t_tbl_addr;
wire [18:0] t_dat_addr;
wire        t_mem_ack;
wire [31:0] t_mem_rdata;
wire        t_tbl_ack = t_mem_ack &&  t_tbl_req;
wire        t_dat_ack = t_mem_ack && !t_tbl_req && t_dat_req;
// ONE REQUEST LINE, TWO MASTERS: FORCE A DEAD CYCLE WHEN THE OWNER CHANGES.
//
// t_mem_req is the OR of both requesters, so when a table read ends and a data
// read begins on the SAME cycle the line never falls. The CDC port sees one
// continuous request, keeps its acknowledge asserted, and the new master
// captures the PREVIOUS transaction's data - a stale read that looks exactly
// like a wrong value from the ROM.
//
// Measured: tgp_wrtrace write 455, data[0x305], where the reference reads
// 41b39db2 and we read 41f00000, which is the word our PREVIOUS read returned.
// One word in four thousand, because it needs a table access immediately
// followed by a data access with no gap - which is a sequence the math units
// only started producing once they were implemented.
//
// Suppressing the request for the cycle in which the owner changes costs one
// cycle of latency on a master switch and guarantees the port sees a clean
// boundary. The alternative - latching the owner when the transaction starts -
// needs to know the CDC port's accept semantics, and a dead cycle needs to know
// nothing.
reg         t_prev_tbl = 1'b0;
always @(posedge clk_cpu) t_prev_tbl <= t_tbl_req;
wire        t_owner_change = (t_tbl_req != t_prev_tbl);
wire        t_mem_req  = (t_tbl_req || t_dat_req) && !t_owner_change;
wire [24:1] t_mem_addr = t_tbl_req ? (COPRO_TBL_BASE + {7'd0, t_tbl_addr, 1'b0})
                                   : (COPRO_DAT_BASE + {4'd0, t_dat_addr, 1'b0});
wire        tgp_mem_req;
wire [24:1] tgp_mem_addr;

// Are the coprocessor's reads actually being served, and with the right data?
// The first two data-ROM words are a free check against the reference — see
// docs/findings.md — so capture them rather than inferring from behaviour.
integer     tgp_dat_reads = 0, tgp_tbl_reads = 0;
reg [31:0]  first_dat0 = 32'hxxxxxxxx, first_dat1 = 32'hxxxxxxxx;
// Sampled the cycle AFTER the acknowledge. a_dout is registered and updates on
// the same edge as a_ack, so a non-blocking capture at that edge takes the
// PREVIOUS value — which produced a half-right pair and read exactly like a data
// path fault.
reg         dat_ack_d = 0;
reg [24:1]  dat_addr_d = 0;
always @(posedge clk_cpu) begin
    dat_ack_d  <= t_dat_ack;
    if (t_dat_ack) dat_addr_d <= t_mem_addr;
    if (dat_ack_d) begin
        tgp_dat_reads = tgp_dat_reads + 1;
        if (tgp_dat_reads == 1) first_dat0 <= t_mem_rdata;
        if (tgp_dat_reads == 2) first_dat1 <= t_mem_rdata;
        if (tgp_dat_reads <= 6)
            $display("BOOT:   TGP data read %0d: sdram word %06h -> %08h",
                     tgp_dat_reads, dat_addr_d, t_mem_rdata);
    end
    if (t_tbl_ack) tgp_tbl_reads = tgp_tbl_reads + 1;
end

// And prove the preload itself, independently of the coprocessor's path: what
// does the ROM image actually hold at those two indices?
initial begin
    #1;
    $display("BOOT: preload check: word 0x300020/21 = %04h %04h, 0x300040/41 = %04h %04h",
             rom[24'h300020], rom[24'h300021], rom[24'h300040], rom[24'h300041]);
end

// 32 bits wide: a coprocessor fetch is one 32-bit word and the SDRAM burst's
// low 32 bits are exactly that. a_dout is the requester's data; b_dout is the
// input from the far side. Connecting those the wrong way round returned zero on
// every read while the accesses completed normally.
m1_cdc_port #(.AW(24), .DW(32), .BEW(2)) tgp_mem_cdc (
    .a_clk(clk_cpu), .a_rst_n(rst_n_cpu),
    .a_req(t_mem_req), .a_we(1'b0), .a_addr(t_mem_addr),
    .a_din(32'd0), .a_be(2'b11),
    .a_dout(t_mem_rdata), .a_ack(t_mem_ack), .a_busy(),
    .b_clk(clk), .b_rst_n(rst_n_sys),
    .b_req(tgp_mem_req), .b_we(tgp_unused_we), .b_addr(tgp_mem_addr),
    .b_din(tgp_unused_din), .b_be(tgp_unused_be),
    .b_dout(tgp_mem_addr[1] ? p_dout[3][63:32] : p_dout[3][31:0]),
    .b_ack(p_ack[3])
);
wire        tgp_unused_we;
wire [31:0] tgp_unused_din;
wire [1:0]  tgp_unused_be;
wire        dbg_tgp_unimpl;

// ------------------------------------------------ coprocessor microcode
// Loaded from the extracted 315-5573.bin. Absent, the TGP executes zeros and
// this test cannot say anything about the coprocessor — so it says so loudly
// rather than reporting a clean run that measured nothing.
localparam string UCODEHEX = "build/rom/vr_tgp_prog.hex";
reg [31:0] ucode [0:2047];
reg        uc_we = 0;
reg [10:0] uc_addr = 0;
// COMBINATIONAL, NOT REGISTERED. It used to be a reg assigned non-blockingly
// alongside uc_addr, which shifted the whole microcode image by one word — see
// the loader below.
wire [31:0] uc_data = ucode[uc_addr];
integer    uc_i;
initial begin
    for (uc_i = 0; uc_i < 2048; uc_i = uc_i + 1) ucode[uc_i] = 32'h0;
    $readmemh(UCODEHEX, ucode);
    if (ucode[0] === 32'h0)
        $display("BOOT: *** no TGP microcode at %s — run tools/build_tgp_rom.py ***",
                 UCODEHEX);
end

m1_main #(.TGP_MATH_ZERO(MATH_ZERO)) main (
    .clk(clk_cpu), .ce(ce), .rst_n(rst_n_cpu), .rom_loaded(mem_ready_cpu[1]),
    // Idle-high: every control is active low, so zero means all held down.
    // At rest: digital bytes idle-high, the three ADC channels at their
    // measured released values — steering centred, both pedals up.
    .in_bytes({96'hffffffffffffffffffffffff, 8'h01, 8'h01, 8'h80}),
    // The coprocessor's microcode, streamed in before reset is released — the
    // same order the MRA path uses on hardware. THIS is what makes the boot
    // trace able to answer whether the V60 gets past its wait at fed5a4.
    .ucode_clk(clk), .ucode_we(uc_we), .ucode_addr(uc_addr), .ucode_data(uc_data),
    // Tables and the 2 MB data window are not wired yet; acknowledged with zero
    // so the coprocessor runs. Nothing it computes is correct until the math
    // units exist — see docs/m2-tgp-integration.md.
    // The coprocessor's read-only regions, served from the SDRAM model like
    // everything else. copro_data at word 0x300000, tables at 0x400000 — the
    // same bases the packer uses, and the preload now covers both.
    .tgp_tbl_req(t_tbl_req), .tgp_tbl_addr(t_tbl_addr),
    .tgp_tbl_rdata(t_mem_rdata), .tgp_tbl_ack(t_tbl_ack),
    .tgp_dat_req(t_dat_req), .tgp_dat_addr(t_dat_addr),
    .tgp_dat_rdata(t_mem_rdata), .tgp_dat_ack(t_dat_ack),
    .dbg_tgp_retires(dbg_tgp_retires), .dbg_tgp_pc(dbg_tgp_pc),
    .dbg_tgp_unimpl(dbg_tgp_unimpl),
    .dbg_tgp_io_addr(tio_addr), .dbg_tgp_io_rd(tio_rd),
    .dbg_tgp_io_wr(tio_wr), .dbg_tgp_io_ack(tio_ack),
    .dbg_tgp_fifo_rd(tfifo_rd), .dbg_tgp_fifo_wr(tfifo_wr),
    .sdr_req(sdr_req), .sdr_we(sdr_we), .sdr_addr(sdr_addr),
    .sdr_din(sdr_din), .sdr_be(sdr_be), .sdr_dout(sdr_dout), .sdr_ack(sdr_ack),
    .if_req(if_req), .if_addr(if_addr), .if_sdram_addr(if_sdram_addr),
    .if_data(if_data), .if_ack(if_ack),
    .vid_clk(clk), .vid_tram_addr(15'd0), .vid_tram_data(),
    .vid_pal_addr(12'd0),  .vid_pal_data(),
    .vblank_irq(vblank_pulse),
    .dbg_pc(dbg_pc), .dbg_halted(dbg_halted), .dbg_fp_trap(dbg_fp_trap), .dbg_io_replies(dbg_io_replies),
    .rom_bank()
);

// Vertical blanking at the real rate: 424 lines of 656 dot clocks at 16 MHz,
// and this runs at 100 MHz, so a frame is 656*424*100/16 core cycles.
localparam integer FRAME_CYCLES = 656*424*100/16;
integer vbl_cnt = 0;
reg vblank_sys = 0;
wire vblank_pulse;
always @(posedge clk) begin
    if (!rst_n_sys) begin vbl_cnt <= 0; vblank_sys <= 0; end
    else begin
        vblank_sys <= 0;
        if (vbl_cnt == FRAME_CYCLES-1) begin vbl_cnt <= 0; vblank_sys <= 1; end
        else vbl_cnt <= vbl_cnt + 1;
    end
end

// One fast cycle wide, and the interrupt controller is in the slow domain.
m1_cdc_pulse vblank_cdc (
    .a_clk(clk), .a_rst_n(rst_n_sys), .a_pulse(vblank_sys),
    .b_clk(clk_cpu), .b_rst_n(rst_n_cpu), .b_pulse(vblank_pulse)
);

wire [4:0]       p_req, p_we, p_ack;
wire [4:0][24:1] p_addr;
wire [4:0][15:0] p_din;
wire [4:0][1:0]  p_be;
wire [4:0][63:0] p_dout;

wire        ifp_req;
wire [24:1] ifp_addr;
assign p_req  = {1'b0, tgp_mem_req, ifp_req, 1'b0, m_sdr_req};
assign p_we   = {4'b0000, m_sdr_we};   // every added port is read-only
// p3 aligned down to its burst boundary, as at the top level.
assign p_addr = {24'd0, {tgp_mem_addr[24:2], 1'b0}, ifp_addr, 24'd0, m_sdr_addr};
assign p_din  = {16'd0, 16'd0, 16'd0, 16'd0, m_sdr_din};
assign p_be   = {2'd0, 2'd0, 2'd0, 2'd0, m_sdr_be};
// The V60's data port crosses here rather than being wired straight to the
// controller, which is the whole point of this configuration.
wire        m_sdr_req, m_sdr_we, m_sdr_ack, m_sdr_busy;
wire [24:1] m_sdr_addr;
wire [15:0] m_sdr_din;
wire  [1:0] m_sdr_be;

m1_cdc_port #(.AW(24), .DW(16), .BEW(2)) data_cdc (
    .a_clk(clk_cpu), .a_rst_n(rst_n_cpu),
    .a_req(sdr_req), .a_we(sdr_we), .a_addr(sdr_addr),
    .a_din(sdr_din), .a_be(sdr_be),
    .a_dout(sdr_dout), .a_ack(sdr_ack), .a_busy(m_sdr_busy),
    .b_clk(clk), .b_rst_n(rst_n_sys),
    .b_req(m_sdr_req), .b_we(m_sdr_we), .b_addr(m_sdr_addr),
    .b_din(m_sdr_din), .b_be(m_sdr_be),
    .b_dout(p_dout[0][15:0]), .b_ack(p_ack[0])
);

wire        cke, cs_n, ras_n, cas_n, we_n;
wire [1:0]  ba, dqm;
wire [12:0] a;
wire [15:0] dq_c2m, dq_m2c;
wire        dq_oe_c, dq_oe_m;
wire [4:0]  dbg_req_v, dbg_grant_v;
wire [15:0] v_flags;

m1_sdram #(.NP(5), .INIT_NOP(600)) sdram (
    .clk(clk), .rst_n(rst_n_sys), .ready(mem_ready),
    // CL+3: sdram_model answers on the same clock edge the controller uses.
    // The board wants CL+2 because its device is clocked on the inverse of
    // clk_sys and replies half a period away. Leaving this unconnected
    // defaults it to CL+2 and every burst arrives shifted by one word — the
    // V60 then halts after one instruction, which is exactly what this
    // testbench reported until the port was wired.
    .rd_lat_sel(2'd0),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n),
    .sd_we_n(we_n), .sd_ba(ba), .sd_a(a), .sd_dqm(dqm),
    .sd_dq_o(dq_c2m), .sd_dq_oe(dq_oe_c), .sd_dq_i(dq_m2c),
    .wr_req(1'b0), .wr_addr(24'd0), .wr_din(16'd0), .wr_be(2'b11), .wr_ack(),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack),
    .dbg_req(dbg_req_v), .dbg_grant(dbg_grant_v)
);

sdram_model #(.COL_BITS(9)) device (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .ba(ba), .a(a), .dqm(dqm),
    .dq_i(dq_c2m), .dq_oe_i(dq_oe_c), .dq_o(dq_m2c), .dq_oe_o(dq_oe_m),
    .violations(), .v_flags(v_flags), .reads_served(), .writes_served()
);

// Instruction fetch now goes through the real module rather than a copy of it
// living here. That copy WAS the implementation for a while — every consumer
// wrote its own and none was tested — and replacing it is half the point of
// this configuration: boot is what proves m1_fetch_bridge works in a design,
// across two clocks, where a lost line shows up as a CPU that stops.
integer if_lines = 0;

m1_fetch_bridge fetch (
    .cpu_clk(clk_cpu), .cpu_rst_n(rst_n_cpu),
    .if_req(if_req), .if_off(if_addr[2:0]), .if_sdram_addr(if_sdram_addr),
    .if_data(if_data), .if_ack(if_ack),
    .mem_clk(clk), .mem_rst_n(rst_n_sys),
    .p_req(ifp_req), .p_addr(ifp_addr),
    .p_dout(p_dout[2]), .p_ack(p_ack[2])
);

// Count served lines the same way the old inline bridge did, so the figure
// stays comparable across this change.
reg p2_ack_d = 0, ifp_busy = 0;
always @(posedge clk) begin
    if (!rst_n_sys) begin p2_ack_d <= 0; ifp_busy <= 0; end
    else begin
        p2_ack_d <= p_ack[2];
        if (ifp_req) ifp_busy <= 1'b1;
        else if (ifp_busy && p_ack[2] && !p2_ack_d) begin
            ifp_busy <= 1'b0;
            if_lines  = if_lines + 1;
        end
    end
end

// ------------------------------------------------------------------ preload
reg [15:0] rom [0:PRELOAD_WORDS-1];
integer i;
initial begin
    $readmemh(ROMHEX, rom);
    // sdram_model indexes by bank<<22 | row<<9 | col, and m1_sdram splits the
    // word address as bank=[23:22] row=[21:9] col=[8:0] — so the device index
    // IS the word address and this is a straight copy.
    for (i = 0; i < PRELOAD_WORDS; i = i + 1) device.mem[i] = rom[i];
    $display("preloaded %0d words", PRELOAD_WORDS);
end

// ------------------------------------------------- minimal I/O responder
//
// The handshake responder now lives in RTL — rtl/io/m1_ioboard.sv — and this
// testbench no longer pokes the DPRAM behind the design's back. That is the
// point of the change: the experiment established the protocol, and running
// boot against the real module is what proves the module implements it.
//
// m1_main instantiates it by default, so nothing is wired here. Its answer
// count comes out on dbg_io_replies, and boot reaching fe143d with three
// replies is the end-to-end check.

// ------------------------------------------------------- access histogram
// When the CPU stops making progress the question is what it is waiting for,
// and that is answered by which addresses it keeps reading. A histogram by
// 64 KB page names the region; the exact address names the register.
integer hist [0:255];
// The watch-page tables were 32 entries, which silently filled: a run that
// touched more addresses reported exactly 32 distinct and dropped the rest,
// so "the V60 never reads 0x08" was a table limit rather than a finding.
localparam integer TRACKN = 256;

integer exact_addr [0:TRACKN-1];
integer exact_cnt  [0:TRACKN-1];
integer exact_wr   [0:TRACKN-1];
integer wr_addr [0:23];
integer wr_data [0:23];
integer wr_be   [0:23];
integer wr_cyc  [0:23];
integer nwr = 0;
integer rd_addr [0:TRACKN-1];
integer rd_cnt  [0:TRACKN-1];
integer nrd = 0;
integer nrdlog = 0;
reg        pend_rd = 0;
reg [23:0] pend_addr = 0;
reg  [1:0] pend_be = 0;
reg  [1:0] rdlog_be [0:39];
integer    rdlog_cyc [0:39];
reg [23:0] rdlog_addr [0:39];
reg  [7:0] rdlog_data [0:39];
reg [23:0] rdlog_pc   [0:39];
integer nexact = 0;
integer hi, j, found;
reg [23:1] last_addr_seen = 0;
reg        m_req_d = 0;

always @(posedge clk) begin
    if (!rst_n) begin
        for (hi = 0; hi < 256; hi = hi + 1) hist[hi] = 0;
        for (hi = 0; hi < TRACKN; hi = hi + 1) begin exact_addr[hi]=0; exact_cnt[hi]=0; exact_wr[hi]=0; end
        nwr = 0; nrd = 0;
        for (hi = 0; hi < TRACKN; hi = hi + 1) begin rd_addr[hi]=0; rd_cnt[hi]=0; end
        nexact = 0;
    end else begin
        m_req_d <= main.m_req;

        // WHAT CAME BACK, AND WHO ASKED.
        //
        // Counting reads says the V60 polls the flag 74 times and the window
        // three; it does not say what value came back, which is the actual
        // question — a program polling a byte that never changes is waiting to
        // be told something.
        //
        // The address is only valid at the REQUEST edge and the data only at
        // the ACKNOWLEDGE, which is the whole point of v60_bus.sv's handshake:
        // qualifying both on the same instant logs nothing at all, which is
        // what the first version of this probe did.
        if (pend_rd && main.m_ack) begin
            if (nrdlog < 40) begin
                // THE LANE MATTERS. v60_bus.sv works in 16-bit cycles and m_be
                // says which half carries the byte: an access on the high lane
                // returns m_rdata[15:8], and the byte address is odd. Logging
                // [7:0] with bit 0 forced to zero — which the first version did
                // — reports the wrong address AND the wrong half, and every
                // high-lane read reads as 00.
                rdlog_addr[nrdlog] = {pend_addr[23:1], pend_be[1] & ~pend_be[0]};
                rdlog_data[nrdlog] = pend_be[0] ? main.m_rdata[7:0]
                                                : main.m_rdata[15:8];
                rdlog_be[nrdlog]   = pend_be;
                rdlog_cyc[nrdlog]  = cycles;
                rdlog_pc[nrdlog]   = dbg_pc;
                nrdlog = nrdlog + 1;
            end
            pend_rd <= 1'b0;
        end

        if (main.m_req && !m_req_d) begin
            if (main.m_addr[23:16] == WATCH_PAGE && !main.m_we) begin
                pend_rd   <= 1'b1;
                pend_addr <= {main.m_addr, 1'b0};
                pend_be   <= main.m_be;
            end
            hist[main.m_addr[23:16]] = hist[main.m_addr[23:16]] + 1;
            // Exact addresses within one page of interest. A page histogram
            // says which device the CPU is talking to; this says which
            // register, which is what a high-level implementation of that
            // device has to get right.
            // Log every write to the watched page with its data. The
            // addresses alone said the V60 sends a four-byte command and then
            // polls one status byte; the command's CONTENT is what says what it
            // is asking for, and guessing a reply without reading the request
            // would be exactly the poking-until-it-boots this project avoids.
            // Reads matter now too. Once the handshake stops blocking, the
            // question is what the V60 READS out of the I/O board — controls,
            // DIP switches, coin and service inputs — because that decides
            // whether a small responder covers M1 or whether the real
            // 315-5338A has to exist behind it.
            if (main.m_addr[23:16] == WATCH_PAGE && !main.m_we && nrd < TRACKN) begin
                found = 0;
                for (j = 0; j < nrd; j = j + 1)
                    if (rd_addr[j] == {main.m_addr, 1'b0}) begin
                        rd_cnt[j] = rd_cnt[j] + 1; found = 1;
                    end
                if (!found) begin
                    rd_addr[nrd] = {main.m_addr, 1'b0};
                    rd_cnt[nrd]  = 1;
                    nrd = nrd + 1;
                end
            end
            if (main.m_addr[23:16] == WATCH_PAGE && main.m_we && nwr < 24) begin
                wr_addr[nwr] = {main.m_addr, 1'b0};
                wr_data[nwr] = main.m_wdata;
                wr_be[nwr]   = main.m_be;
                wr_cyc[nwr]  = cycles;
                nwr = nwr + 1;
            end
            if (main.m_addr[23:16] == WATCH_PAGE) begin
                found = 0;
                for (j = 0; j < nexact; j = j + 1)
                    if (exact_addr[j] == {main.m_addr, 1'b0}) begin
                        exact_cnt[j] = exact_cnt[j] + 1; found = 1;
                    end
                if (!found && nexact < TRACKN) begin
                    exact_addr[nexact] = {main.m_addr, 1'b0};
                    exact_cnt[nexact]  = 1;
                    exact_wr[nexact]   = main.m_we;
                    nexact = nexact + 1;
                end
            end
        end
    end
end

// ------------------------------------------------------- interrupt probe
// The CPU is spinning on a work-RAM flag. If that flag is set by an interrupt
// service routine, then no interrupt means no flag means this loop forever —
// so the question is whether vblank reaches GLUE, whether GLUE raises the
// line, and whether the CPU ever vectors. Three counters separate those.
integer vbl_to_glue = 0, irq_asserted = 0, irq_edges = 0;
reg irq_n_d = 1;

always @(posedge clk_cpu) begin
    if (rst_n_cpu) begin
        if (main.vblank_irq) vbl_to_glue = vbl_to_glue + 1;
        if (!main.irq_n) irq_asserted = irq_asserted + 1;
        if (!main.irq_n && irq_n_d) irq_edges = irq_edges + 1;
        irq_n_d <= main.irq_n;
    end
end

// --------------------------------------------------------------- PC trace
// Where is it spinning? A page histogram says which region, and the watched
// page says which address, but neither says what the CPU is DOING. A rolling
// buffer of the last distinct PCs prints the loop body itself, which is the
// thing that identifies a wait — and whether it is waiting on memory, on an
// interrupt, or on a device that does not exist.
localparam integer PCBUF = 128;
integer pcbuf [0:PCBUF-1];
integer pcw = 0, pclast = -1;

// --------------------------------------------- per-page data-bus latency
// 13.2 M data accesses cost 155 M stall cycles - 11.8 cycles each - against a
// bus FSM whose local path is three. The page histogram says WHERE the accesses
// go and says nothing about what they COST, and those are different questions:
// 4.3 M cheap accesses and 1 M expensive ones look identical in a count.
//
// Measured from m_req rising to m_ack, which is exactly the window the CPU is
// stalled in.
integer lat_tot [0:255];
integer lat_cnt [0:255];
integer lat_pg, lat_start, lat_i;
reg     lat_busy = 1'b0;
reg     lat_req_d = 1'b0;

initial for (lat_i = 0; lat_i < 256; lat_i = lat_i + 1) begin
    lat_tot[lat_i] = 0; lat_cnt[lat_i] = 0;
end

always @(posedge clk_cpu) begin
    lat_req_d <= main.m_req;
    if (rst_n_cpu) begin
        if (main.m_req && !lat_req_d) begin
            lat_busy  <= 1'b1;
            lat_start  = cycles;
            lat_pg     = main.m_addr[23:16];
        end
        if (lat_busy && main.m_ack) begin
            lat_busy <= 1'b0;
            lat_tot[lat_pg] = lat_tot[lat_pg] + (cycles - lat_start);
            lat_cnt[lat_pg] = lat_cnt[lat_pg] + 1;
        end
    end
end

// ------------------------------------------------- text writes census
// The routine at FF8AC3 copies a NUL-terminated string out as 16-bit tile codes:
//
//   FF8AC3: mov.b  [R0+], R2
//   FF8AC6: test.b R2
//   FF8AC8: be     FF8ACF
//   FF8ACA: mov.h  R2, [R1+]     <- the write
//   FF8ACD: br     FF8AC3
//
// The reference writes twenty characters a string and we write six to fourteen,
// so capture what each side actually stores. Shaped to match
// tools/mame_text_writes.lua exactly so the two can be decoded by one script.
//
// Our dbg_pc is the CURRENT instruction; MAME's GENPC is the NEXT one, which is
// why the reference script matches FF8ACD and this matches FF8ACA. Getting that
// backwards produces an empty log that looks like "the routine never runs".
integer mi, mj;   // tilemap dump indices
localparam integer TXN = 4000;
integer tx_addr [0:TXN-1];
integer tx_data [0:TXN-1];
integer tx_n = 0;
reg     tx_req_d = 1'b0;

always @(posedge clk_cpu) begin
    tx_req_d <= main.m_req;
    if (rst_n_cpu && main.m_req && !tx_req_d && main.m_we
        && main.m_addr[23:16] >= 8'h70 && main.m_addr[23:16] <= 8'h73
        && dbg_pc == 24'hff8aca && tx_n < TXN) begin
        tx_addr[tx_n] = {main.m_addr, 1'b0};
        tx_data[tx_n] = main.m_wdata;
        tx_n = tx_n + 1;
    end
end

// ------------------------------------------ copro RAM sync-word census
// FED5A4 spins on `in.w [R1], R0` with R1 = 0xD20000 and leaves when the low
// byte of the coprocessor RAM word is zero. MAME's own tap on the maincpu IO
// space, 8 seconds, returns 0000ffff 64,696 times and 00000000 3,738 times: the
// TGP parks ffff in that word while it works and clears it when it is done, and
// the V60 goes round the loop until it does.
//
// Ours never leaves, so the value being read is the whole question, and neither
// the page histogram nor the watched-page log can answer it - the histogram
// counts accesses without data, and the watched-page log keeps only the first
// forty, which are from a different routine hours of simulated time earlier.
//
// `in.w` is an IO-SPACE access. A tap on the program space sees nothing and
// reads as "the V60 never touches the coprocessor" - that exact mistake is on
// record in CLAUDE.md, made against MAME and believed for two months.
localparam integer D20N = 12;
integer d20_val [0:D20N-1];
integer d20_cnt [0:D20N-1];
integer d20_dist = 0, d20_reads = 0, d20_lowzero = 0;
reg     d20_pend = 1'b0;
reg     d20_req_d = 1'b0;
integer dj, dfound;

always @(posedge clk_cpu) begin
    d20_req_d <= main.m_req;
    if (!rst_n_cpu) begin
        d20_pend <= 1'b0;
    end else begin
        if (main.m_req && !d20_req_d && !main.m_we
            && main.m_addr[23:16] == 8'hd2)
            d20_pend <= 1'b1;
        if (d20_pend && main.m_ack) begin
            d20_pend  <= 1'b0;
            d20_reads  = d20_reads + 1;
            if (main.m_rdata[7:0] == 8'h00) d20_lowzero = d20_lowzero + 1;
            dfound = -1;
            for (dj = 0; dj < d20_dist; dj = dj + 1)
                if (d20_val[dj] == main.m_rdata) dfound = dj;
            if (dfound >= 0)
                d20_cnt[dfound] = d20_cnt[dfound] + 1;
            else if (d20_dist < D20N) begin
                d20_val[d20_dist] = main.m_rdata;
                d20_cnt[d20_dist] = 1;
                d20_dist          = d20_dist + 1;
            end
        end
    end
end

// ------------------------------------------- first entry into a watched page
// The rolling buffer above answers "where did it END UP"; it cannot answer "how
// did it GET there", because by the time the run finishes the approach has been
// overwritten by millions of iterations of the loop it ended in. This freezes a
// copy of the buffer at the FIRST instruction in a watched page, so the call
// that reached it is still in the window.
//
// It exists because the V60 ends at fed5a4 and MAME never executes fed5xx AT
// ALL - a 4-second reference trace with cold nvram has zero instructions in that
// page - so the question is which branch left the reference's path, and no
// end-of-run print can show that.
`ifndef TRAP_HI
`define TRAP_HI 16'hfed5
`endif
integer trapbuf [0:PCBUF-1];
integer trapw = -1;
time    trap_time = 0;
integer ti;

always @(posedge clk_cpu) begin
    if (rst_n_cpu && dbg_pc != pclast) begin
        // SNAPSHOT BEFORE THE RING MOVES, AND IN THIS BLOCK. The first version
        // of this trap lived in its own always block and tested
        // `dbg_pc != pclast` there too. Both blocks run on the same edge, the
        // ring block won, and pclast already equalled dbg_pc by the time the
        // trap looked - so the guard was false on every cycle and the trap
        // never fired. It reported "page fed5 never executed" in the same run
        // whose final line was "pc now fed5a4".
        if (trapw < 0 && dbg_pc[23:8] == `TRAP_HI) begin
            for (ti = 0; ti < PCBUF; ti = ti + 1) trapbuf[ti] = pcbuf[ti];
            trapw     = pcw;
            trap_time = $time;
        end
        pcbuf[pcw % PCBUF] = dbg_pc;
        pcw = pcw + 1;
        pclast = dbg_pc;
    end
end


// ------------------------------------------------------------------- run
integer cycles, ce_cycles, last_pc, stuck, pcmin, pcmax, distinct;
integer instrs;

// Instruction counting belongs in the CPU's own domain now. Sampling dbg_pc on
// the fast clock counts each retire up to four times over and turns the CPI
// figure into fast-clock-cycles per instruction, which is not a number anyone
// wants.
always @(posedge clk_cpu) begin
    if (!rst_n_cpu) begin
        ce_cycles = 0; instrs = 0; last_pc = -1;
        pcmin = 32'h7fffffff; pcmax = 0; stuck = 0;
    end else begin
        if (ce) ce_cycles = ce_cycles + 1;
        if (dbg_pc != last_pc) begin
            instrs  = instrs + 1;
            last_pc = dbg_pc;
            stuck   = 0;
            if (dbg_pc < pcmin) pcmin = dbg_pc;
            if (dbg_pc > pcmax) pcmax = dbg_pc;
        end else stuck = stuck + 1;
    end
end
reg [23:0] seen_hi;
initial begin
    repeat (8) @(posedge clk);
    rst_n = 1;
    while (!mem_ready) @(posedge clk);
    $display("SDRAM ready, releasing V60 at the reset vector");

    cycles = 0; last_pc = -1; stuck = 0; instrs = 0;
    pcmin = 32'h7fffffff; pcmax = 0;
    while (cycles < RUN_CYCLES && !dbg_halted) begin
        @(posedge clk);
        cycles = cycles + 1;
    end

    $display("");
    $display("BOOT: cycles=%0d ce=%0d halted=%0d fp_trap=%0d",
             cycles, ce_cycles, dbg_halted, dbg_fp_trap);
    $display("BOOT: pc now %06h, range visited %06h..%06h, ifetch lines %0d",
             dbg_pc, pcmin, pcmax, if_lines);
    // Cycles per instruction, with a caveat that matters more than the number:
    // the V60's block group (MOVC/CMPC and friends) is ONE instruction that
    // runs for as long as the block is large, and Model 1's boot ROM checksums
    // megabytes with it. Averaged across that, "cycles per instruction" says
    // nothing about instruction throughput — the 199 this first reported was a
    // single block instruction sweeping ROM, not a slow CPU.
    //
    // A real figure needs a window that excludes block instructions, or a
    // workload without them. Reported anyway, labelled, because it is still the
    // right measure over ordinary code and the label stops it being quoted as
    // if it were.
    if (instrs > 0)
        $display("BOOT: %0d instructions over %0d CPU-clock cycles = %0d.%02d avg (INCLUDES block instructions)",
                 instrs, ce_cycles, ce_cycles/instrs,
                 ((ce_cycles % instrs) * 100) / instrs);
    $display("BOOT: io handshake replies=%0d (answered in RTL by m1_ioboard)",
             dbg_io_replies);
    $display("BOOT: sdram violations flags=%04h", v_flags);
    if (v_cyc > 0)
        // DIVIDE BEFORE MULTIPLYING. `count * 100` overflows a 32-bit signed
        // integer above ~21.5 M, and these counters reach 40 M on a 600 M-cycle
        // run — the first version printed "data-stalled 40234185 (-1%)". The
        // 100 M-cycle numbers happened to fit, which is worse than failing.
        $display("BOOT: CPU cycles %0d: data-stalled %0d (%0d%%), fetch-stalled %0d (%0d%%), either %0d (%0d%%)",
                 v_cyc, v_dstall, v_dstall / (v_cyc / 100),
                 v_fstall, v_fstall / (v_cyc / 100),
                 v_anystall, v_anystall / (v_cyc / 100));
    // ------------------------------------------------------ tile RAM census
    //
    // Is the missing 2D even IN the tile RAM? The picture on hardware shows the
    // background and none of the text, and it looked identical before and after
    // the row mask went in — so either the render drops it or the V60 never
    // wrote it. Those need separating before any more video RTL is touched.
    //
    // MAME at its attract frame reports, per 4096-word map:
    //   map 0: 4096 nonzero, 4096 category-1, commonest colour 00
    //   map 1: 4096 nonzero,  648 category-1, commonest colour 00
    //   map 2: 4096 nonzero,    0 category-1, commonest colour 7c
    //   map 3: 4096 nonzero,    0 category-1, commonest colour 60
    // A map that reads all zeros here is a CPU-side question, not a video one.
    begin : tram_census
        integer m, i, nz, cat1, w;
        for (m = 0; m < 4; m = m + 1) begin
            nz = 0; cat1 = 0;
            for (i = 0; i < 4096; i = i + 1) begin
                w = {main.rams.tram_c_hi[m*4096 + i], main.rams.tram_c_lo[m*4096 + i]};
                if (w[13:0] != 0) nz = nz + 1;
                if (w[15])        cat1 = cat1 + 1;
            end
            $display("BOOT: tilemap %0d: %0d/4096 nonzero, %0d category-1", m, nz, cat1);
        end
        $write("BOOT: scroll/ctrl:");
        for (i = 0; i < 8; i = i + 1)
            $write(" [%04h]=%04h", 15'h5000 + i,
                   {main.rams.tram_c_hi[15'h5000 + i], main.rams.tram_c_lo[15'h5000 + i]});
        $display("");
        nz = 0;
        for (i = 0; i < 2048; i = i + 1)
            if ({main.rams.tram_c_hi[15'h6000 + i], main.rams.tram_c_lo[15'h6000 + i]} != 0)
                nz = nz + 1;
        // THE REFERENCE WRITES NO MASK CONTENT UNTIL FRAME 276, measured with
        // tools/mame_mask_writers.lua: the first non-zero write is pc=fc4076 into
        // word 0x6160, line 88. At BOOT_CYCLES=150000000 this run is 86 frames, so
        // a zero here says the run is short, NOT that the core is wrong — and it
        // was read as a defect for exactly that reason. 600000000 reaches frame
        // 345 and our core has 96 words; the reference has 528 by frame 900.
        // All four tilemaps, word for word, to diff against
        // tools/mame_tilemap0.lua. The census counts told us tilemap 0 is
        // entirely category-1 and told us nothing about whether the CONTENT
        // matches - and content is what decides whether the text is on screen.
        for (mi = 0; mi < 4; mi = mi + 1)
            for (i = 0; i < 4096; i = i + 16) begin
                $write("TM%0d %04h", mi[3:0], i[15:0]);
                for (mj = 0; mj < 16; mj = mj + 1)
                    $write(" %04h",
                           {main.rams.tram_c_hi[15'(mi*4096 + i + mj)],
                            main.rams.tram_c_lo[15'(mi*4096 + i + mj)]});
                $display("");
            end
        $display("BOOT: row mask 0x6000: %0d/2048 nonzero (reference: none before frame 276, 528 by frame 900)", nz);
        // The COUNT alone cannot say whether the mask is in the right place, and
        // a category-1 tile - which is what all of the text is - shows only where
        // its mask bit is 1. Dump the words so they can be diffed against
        // tools/mame_rowmask.lua's output line for line.
        for (i = 0; i < 2048; i = i + 1)
            if ({main.rams.tram_c_hi[15'h6000 + i], main.rams.tram_c_lo[15'h6000 + i]} != 0)
                $display("RM %04h %04h", i[15:0],
                         {main.rams.tram_c_hi[15'h6000 + i], main.rams.tram_c_lo[15'h6000 + i]});
    end

    // THE OLD EXPECTATION HERE WAS WRONG, AND IT ACCUSED THE PACKER.
    //
    // It read "(MAME: 00000030 00012e00)", so our 3f800000 looked like a broken
    // copro_data image. It is not: the four ROM files byte-interleaved exactly as
    // ROM_LOAD32_BYTE specifies give 3f800000 at word 0, which is what we read and
    // what the hardware holds.
    //
    // The reference gets 00000030 because IT READS A DIFFERENT WORD. Its TGP makes
    // exactly three io accesses in its first 30 frames (tools/mame_tgp_io.lua):
    //
    //     W io 002e <- 00000010        set copro_data_base
    //     R io 8010 -> 00000030        data word 0x10
    //     R io 8020 -> 00012e00        data word 0x20
    //
    // and copro_data_r does index = (base & ~0x7fff) | offset, where 0x10 & ~0x7fff
    // is 0 — so the base write does not even move the window. It simply reads word
    // 0x10. We read word 0x00. So the difference is the ADDRESS our TGP asks for,
    // not the data it gets back, and the value printed here is correct for the
    // address we used.
    $display("BOOT: TGP data reads=%0d tables=%0d  first two data words: %08h %08h",
             tgp_dat_reads, tgp_tbl_reads, first_dat0, first_dat1);
    $display("BOOT:   reference: W io 002e<-10, R io 8010->00000030, R io 8020->00012e00 (3 io accesses in 30 frames)");
    $display("BOOT: TGP stuck? io_rd=%0d io_wr=%0d io_ack=%0d io_addr=%04h fifo_rd=%0d fifo_wr=%0d  (io accesses completed=%0d)",
             tio_rd, tio_wr, tio_ack, tio_addr, tfifo_rd, tfifo_wr, tio_n);
    $display("BOOT: TGP retires=%0d pc=%04h unimplemented=%0d",
             dbg_tgp_retires, dbg_tgp_pc, dbg_tgp_unimpl);
    $display("BOOT: copro RAM writes=%0d  V60->TGP pushes=%0d  TGP->V60 returns=%0d  V60 pops=%0d",
             main.dbg_copro_ram_writes, main.dbg_copro_fifo_pushes,
             main.dbg_copro_returns, main.dbg_copro_pops);
    $display("BOOT: bus accesses by 64KB page:");
    for (i = 0; i < 256; i = i + 1)
        if (hist[i] != 0)
            $display("        %02h0000  %0d", i, hist[i]);
    $display("BOOT: first %0d reads in page %02h0000, with data and PC:",
             nrdlog, WATCH_PAGE);
    for (i = 0; i < nrdlog; i = i + 1)
        $display("        cyc %9d  %06h -> %02h  be=%02b  pc=%06h",
                 rdlog_cyc[i], rdlog_addr[i], rdlog_data[i],
                 rdlog_be[i], rdlog_pc[i]);

    $display("BOOT: reads from page %02h0000 (%0d distinct), busiest first:",
             WATCH_PAGE, nrd);
    for (i = 0; i < nrd; i = i + 1)
        if (rd_cnt[i] > 2)
            $display("        %06h  %0d", rd_addr[i], rd_cnt[i]);
    $display("BOOT: writes to page %02h0000, in order:", WATCH_PAGE);
    for (i = 0; i < nwr; i = i + 1)
        $display("        cyc %-10d %06h  be=%b  data=%04h", wr_cyc[i],
                 wr_addr[i], wr_be[i], wr_data[i]);
    $display("BOOT: addresses touched in page %02h0000 (%0d distinct):",
             WATCH_PAGE, nexact);
    for (i = 0; i < nexact; i = i + 1)
        $display("        %06h  %-9d %s", exact_addr[i], exact_cnt[i],
                 exact_wr[i] ? "(write seen)" : "(read only)");
    $display("BOOT: vblank pulses into GLUE=%0d, irq_n asserted cycles=%0d, irq_n falling edges=%0d",
             vbl_to_glue, irq_asserted, irq_edges);
    $display("BOOT: glue irq_status=%02h irq_mask=%02h",
             main.glue.irq_status, main.glue.irq_mask);
    // loop indices for the tilemap dump
    $display("BOOT: data-bus latency by page (page, accesses, total stall cycles, avg):");
    for (lat_i = 0; lat_i < 256; lat_i = lat_i + 1)
        if (lat_cnt[lat_i] > 10000)
            $display("BOOT:   %02h0000  n=%0d  cycles=%0d  avg=%0d",
                     lat_i[7:0], lat_cnt[lat_i], lat_tot[lat_i],
                     lat_tot[lat_i] / lat_cnt[lat_i]);
    $display("BOOT: text writes from FF8ACA: %0d", tx_n);
    for (i = 0; i < tx_n; i = i + 1)
        $display("TX %0d %06h %04h", i + 1, tx_addr[i][23:0], tx_data[i][15:0]);
    $display("BOOT: copro RAM data port: %0d 16-bit reads, %0d with low byte zero, %0d distinct values",
             d20_reads, d20_lowzero, d20_dist);
    for (i = 0; i < d20_dist; i = i + 1)
        $display("BOOT:   value %04h  x%0d", d20_val[i][15:0], d20_cnt[i]);
    $display("BOOT:   reference (MAME io tap, 8 s): 0000ffff x64696, 00000000 x3738");
    $display("BOOT: copro adr register = %04h (FED587 sets it to 0 before the poll)",
             main.copro.adr);
    if (trapw >= 0) begin
        $display("BOOT: FIRST entry into page %04h at t=%0t; the %0d distinct PCs before it:",
                 `TRAP_HI, trap_time, PCBUF);
        for (i = 0; i < PCBUF; i = i + 1) begin
            if (i % 16 == 0) $write("BOOT:   ");
            $write("%06h ", trapbuf[(trapw + i) % PCBUF]);
            if (i % 16 == 15) $display("");
        end
    end else
        $display("BOOT: page %04h never executed", `TRAP_HI);
    $display("BOOT: last %0d distinct PCs, oldest first:", PCBUF);
    for (i = 0; i < PCBUF; i = i + 1) begin
        if (i % 16 == 0) $write("BOOT:   ");
        $write("%06h ", pcbuf[(pcw + i) % PCBUF]);
        if (i % 16 == 15) $display("");
    end

    if (dbg_fp_trap)
        $display("BOOT: *** FP opcode executed — S32_V60_NO_FP is NOT safe ***");
    $finish;
end

endmodule
