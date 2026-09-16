// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// v60_ifetch: the 24-byte instruction window, its realign network, the loop
// cache and the prefetch unit.
//
// WHY THIS EXISTS. v60_ifetch is 937 ALM and every instruction the CPU executes
// comes through it, and it had NO bench of its own - hard rule 5 says every RTL
// module ships with one. It was split out of v60.sv as a pure refactor and has
// been covered only indirectly, by the 29-test V60 unit suite and by running
// real game code. Both are end-to-end: they say the CPU works, not that the
// fetch window is correct, and neither can be pointed at a specific hazard.
//
// WHAT IS CHECKED, AND IT NEEDS NO REFERENCE MODEL. The fetch window has one
// complete correctness statement:
//
//     for every i < fb_valid:  fb_flat byte i == memory[fb_base + i]
//
// That is the whole contract. It must hold on EVERY cycle, not just when
// fill_ready - a window that is briefly wrong is a window the decoder can read.
// Checking an invariant against a golden memory is stronger than diffing
// against a second implementation, because it cannot be wrong in the same
// direction as the DUT.
//
// Plus LIVENESS, which an invariant alone misses entirely: a window that never
// becomes ready satisfies the invariant vacuously, so the bench also fails if
// fill_ready has not asserted within a bounded number of cycles. A fetch unit
// that deadlocks is the failure mode that reads as a dead CPU, and this repo
// has been bitten by exactly that shape twice (see CLAUDE.md on held acks).
//
// NOT COVERED, AND SAYING SO RATHER THAN IMPLYING OTHERWISE: the
// self-modifying-code guard. dbus_req is held low throughout, so the
// invalidate-on-overlapping-write path is untested here. It needs the golden
// memory to be mutated in step with the DUT's view of the write, which is a
// race this bench does not yet resolve. The guard is exercised by tb_v60_smc in
// the unit suite.

`timescale 1ns/1ps

module tb_v60_ifetch #(
    parameter int SEED   = 32'h5EED_1F37,
    parameter int CYCLES = 400000,
    parameter int CEDEN  = 3          // ce every CEDEN cycles, as the core runs it
);

    // ------------------------------------------------------------ golden memory
    // 64 KiB, addressed by the low bits. START_PC is 0xFFFFFFF0, so the window
    // wraps into the same array - which is fine: the DUT never inspects the top
    // bits for anything but comparing fb_base to pc.
    localparam int unsigned MEMSZ = 1 << 16;
    localparam int unsigned MEMMSK = MEMSZ - 1;
    logic [7:0] mem [MEMSZ];

    function automatic [7:0] memrd(input logic [31:0] a);
        memrd = mem[a & MEMMSK];
    endfunction

    // ------------------------------------------------------------------- clocks
    logic clk = 0, rst_n = 0, ce = 0;
    always #5 clk = ~clk;

    int cediv = 0;
    always_ff @(posedge clk) begin
        cediv <= (cediv == CEDEN - 1) ? 0 : cediv + 1;
        ce    <= (cediv == CEDEN - 1);
    end

    // ---------------------------------------------------------------------- DUT
    logic [31:0]  pc;
    logic         fill_active, fill_ready;
    logic [191:0] fb_flat;
    logic [31:0]  fb_base;
    logic [4:0]   fb_valid, fb_need, fb_wr;
    logic         if_req;
    logic [23:0]  if_addr;
    logic [63:0]  if_data_i;
    logic         if_ack;
    logic         pf_req, pf_ack;
    logic [31:0]  pf_addr_o;
    logic [31:0]  bus_rdata;

    v60_ifetch #(.FAST_IFETCH(1'b1)) dut (
        .clk(clk), .rst_n(rst_n), .ce(ce),
        .pc(pc), .fill_active(fill_active), .fill_ready(fill_ready),
        .fb_flat(fb_flat), .fb_base(fb_base),
        .fb_valid(fb_valid), .fb_need(fb_need), .fb_wr(fb_wr),
        .if_req(if_req), .if_addr(if_addr), .if_data_i(if_data_i), .if_ack(if_ack),
        .pf_req(pf_req), .pf_addr_o(pf_addr_o), .pf_ack(pf_ack),
        .bus_rdata(bus_rdata),
        // SMC guard held inactive - see the header note.
        .dbus_req(1'b0), .dbus_we(1'b0), .dack(1'b0),
        .dbus_addr(32'd0), .dbus_size(2'd0)
    );

    // ------------------------------------------------------- the memory servant
    // THE CALLER ALIGNS if_data, NOT THE DUT. v60_ifetch's comment is explicit:
    // "s32_core has ALREADY aligned if_data so byte 0 is the frontier byte".
    // So byte k of if_data_i is memory[if_addr + k]. Only the bytes up to the
    // end of the 8-byte line are consumed; supplying the rest costs nothing and
    // keeps the model simple.
    // THE ACK IS HELD UNTIL THE REQUEST DROPS. This is the protocol
    // m1_fetch_bridge documents in as many words ("if_ack must then stay high
    // until if_req drops") and it is not optional: the CPU is ce-gated at one
    // cycle in three, so a one-cycle ack pulse is simply missed.
    //
    // THE FIRST VERSION OF THIS BENCH PULSED IT, and the result was 73,584
    // window mismatches that looked exactly like a DUT bug - stale bytes in the
    // tail of the window, at a plausible depth, reproducible. The DUT was
    // correct and the bench was wrong. CLAUDE.md lists held-versus-pulsed acks
    // as the fault that has cost this project the most time; it has now cost it
    // once more, in the instrument rather than the design.
    typedef enum logic [1:0] { SV_IDLE, SV_WAIT, SV_ACK } sv_e;
    sv_e sv = SV_IDLE;
    int unsigned lat_ctr = 0, lat_want = 0;
    logic [31:0] serve_addr;

    // Random ack latency, so the bench covers a stalled memory as well as a fast
    // one. A fixed latency is the case a fetch unit is most likely to get right.
    int unsigned rnd_state;
    function automatic int unsigned rnd();
        rnd_state = rnd_state * 32'd1664525 + 32'd1013904223;
        rnd = rnd_state;
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            if_ack <= 1'b0; sv <= SV_IDLE; lat_ctr <= 0; if_data_i <= '0;
        end else begin
            case (sv)
                SV_IDLE: begin
                    if_ack <= 1'b0;
                    if (if_req) begin
                        serve_addr <= {8'd0, if_addr};
                        lat_want   <= rnd() % 6;   // 0..5 cycles
                        lat_ctr    <= 0;
                        sv         <= SV_WAIT;
                    end
                end
                SV_WAIT: begin
                    if (lat_ctr >= lat_want) begin
                        for (int k = 0; k < 8; k++)
                            if_data_i[k*8 +: 8] <= memrd(serve_addr + k);
                        if_ack <= 1'b1;
                        sv     <= SV_ACK;
                    end else lat_ctr <= lat_ctr + 1;
                end
                // Hold ack AND data until the requester drops its request.
                SV_ACK: begin
                    if (!if_req) begin
                        if_ack <= 1'b0;
                        sv     <= SV_IDLE;
                    end
                end
                default: sv <= SV_IDLE;
            endcase
        end
    end

    assign pf_ack    = 1'b0;   // FAST_IFETCH=1: the legacy shared-bus port is unused
    assign bus_rdata = 32'd0;

    // ------------------------------------------------------------- the consumer
    // Model the CPU's S_FILL: sit in fill_active, and when the window is ready
    // consume an instruction of random length and move pc on. Occasionally jump,
    // which is what exercises the realign network and the loop cache.
    assign fill_active = 1'b1;

    int unsigned n_ready = 0, n_jump = 0, n_seq = 0;
    int unsigned stall = 0, worst_stall = 0;
    int unsigned checks = 0, fails = 0;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc <= 32'hFFFF_FFF0;
            stall <= 0;
        end else if (ce) begin
            if (fill_ready) begin
                stall   <= 0;
                n_ready <= n_ready + 1;
                if ((rnd() % 100) < 12) begin
                    // A jump: anywhere in the memory, word-aligned half the time.
                    pc     <= rnd() & MEMMSK;
                    n_jump <= n_jump + 1;
                end else begin
                    // Sequential: advance by a plausible instruction length. Cap
                    // at fb_valid so we never claim to have consumed bytes the
                    // window did not hold.
                    automatic int unsigned l = 1 + (rnd() % 6);
                    if (l > fb_valid) l = (fb_valid == 0) ? 1 : fb_valid;
                    pc    <= pc + l;
                    n_seq <= n_seq + 1;
                end
            end else begin
                stall <= stall + 1;
                if (stall > worst_stall) worst_stall <= stall;
            end
        end
    end

    // -------------------------------------------------------------- the checker
    // EVERY CYCLE, not only on ce and not only when ready. The decoder reads
    // fb_flat combinationally, so a window that is wrong between ce pulses is
    // still a window that can be read wrong.
    int unsigned shown = 0;

    always_ff @(posedge clk) begin
        if (rst_n) begin
            checks <= checks + 1;
            for (int i = 0; i < 24; i++) begin
                if (i < int'(fb_valid)) begin
                    if (fb_flat[i*8 +: 8] !== memrd(fb_base + i)) begin
                        fails <= fails + 1;
                        if (shown < 20) begin
                            shown <= shown + 1;
                            $display("FAIL window: base=%08x valid=%0d byte %0d = %02x, memory = %02x  (pc=%08x wr=%0d need=%0d)",
                                     fb_base, fb_valid, i, fb_flat[i*8 +: 8],
                                     memrd(fb_base + i), pc, fb_wr, fb_need);
                        end
                    end
                end
            end

            // LIVENESS. A window that never fills satisfies the invariant above
            // vacuously - this is the half that catches a deadlocked handshake.
            //
            // THE BOUND IS MEASURED, NOT GUESSED. A jump, a full realign and a
            // run of 8-byte fills at up to 5 cycles of latency each, all on a ce
            // that is one cycle in CEDEN, comes to 17 ce cycles in this corpus.
            // The first version of this bench used 400, which is so far above
            // the real worst case that it would have passed a fetch unit that
            // had become twenty times slower. 100 keeps ~6x headroom against
            // arbitrary reshuffling and still fails long before a deadlock.
            if (stall > 100) begin
                fails <= fails + 1;
                if (shown < 20) begin
                    shown <= shown + 1;
                    $display("FAIL liveness: fill_ready has not asserted for %0d ce cycles (pc=%08x base=%08x valid=%0d need=%0d wr=%0d if_req=%b)",
                             stall, pc, fb_base, fb_valid, fb_need, fb_wr, if_req);
                end
            end
        end
    end

    // ------------------------------------------------------------------- driver
    initial begin
        rnd_state = SEED;
        for (int i = 0; i < MEMSZ; i++) mem[i] = 8'(rnd());
        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (CYCLES) @(posedge clk);

        $display("v60_ifetch: checks=%0d fails=%0d ready=%0d seq=%0d jumps=%0d worst_stall=%0d",
                 checks, fails, n_ready, n_seq, n_jump, worst_stall);
        if (n_ready < 1000)
            $display("FAIL coverage: only %0d fills completed - the bench is not exercising the DUT", n_ready);
        $finish;
    end

endmodule
