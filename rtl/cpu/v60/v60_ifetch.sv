// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// V60 instruction fetch: the 24-byte window, its realign network, the loop
// cache and the prefetch unit.
//
// EXTRACTED FROM v60.sv TO MEASURE IT. The V60 is 17,771 ALM of a 30,227-ALM
// core and completely flat, so nothing could report where that goes - the
// rasterizer and the whole sound board still have to fit in 11,683 free ALM,
// and every area figure so far has been a guess about a block with no internal
// visibility.
//
// This is a pure refactor: the logic below is moved verbatim, not rewritten.
// The proof is that instruction counts and CPI must be identical before and
// after, on top of the 29-test unit suite, m1_main and v60_trace.
//
// The window is exposed as a flat vector and unpacked on the far side, so the
// ~70 places the decoder reads fb[] are untouched.

module v60_ifetch #(
    parameter logic [31:0] START_PC    = 32'hFFFF_FFF0,
    parameter logic [4:0]  FB_THRESH   = 5'd20,
    parameter logic [4:0]  PF_HIGH     = 5'd20,
    parameter bit          FAST_IFETCH = 1'b1
)(
    input  logic        clk,
    input  logic        rst_n,        // active-low, SYNCHRONOUS - see the always block
    input  logic        ce,

    input  logic [31:0] pc,
    input  logic        fill_active,     // the FSM is in S_FILL this cycle
    output logic        fill_ready,      // aligned with enough bytes: dispatch

    output logic [191:0] fb_flat,        // the 24-byte window, byte 0 in [7:0]
    output logic [31:0]  fb_base,
    output logic [4:0]   fb_valid,
    output logic [4:0]   fb_need,
    output logic [4:0]   fb_wr,

    // Dedicated 8-byte line port (FAST_IFETCH) and the legacy shared-bus port.
    output logic        if_req,
    output logic [23:0] if_addr,
    input  logic [63:0] if_data_i,
    input  logic        if_ack,
    output logic        pf_req,
    output logic [31:0] pf_addr_o,   // for the shared-bus mux when FAST_IFETCH=0
    input  logic        pf_ack,
    input  logic [31:0] bus_rdata,

    // Self-modifying-code guard: a completing data write that overlaps the live
    // or retained window invalidates it.
    input  logic        dbus_req,
    input  logic        dbus_we,
    input  logic        dack,
    input  logic [31:0] dbus_addr,
    input  logic [1:0]  dbus_size
);

    reg [7:0]  fb[0:23];
    reg [31:0] fb_base_r;
    reg [4:0]  fb_valid_r, fb_wr_r;
    reg        fb_realigning;
`ifndef V60_NO_LOOP_CACHE
    reg [7:0]  fb_prev[0:23];
    reg [31:0] fb_prev_base;
    reg [4:0]  fb_prev_valid;
`else
    wire [7:0]  fb_prev[0:23] = '{default: 8'd0};
    wire [31:0] fb_prev_base  = 32'd0;
    wire [4:0]  fb_prev_valid = 5'd0;
`endif
    reg [31:0] pf_addr;
    reg        pf_busy, pf_suppress;
    reg [3:0]  pf_epoch, pf_iss_epoch;

    assign fb_base  = fb_base_r;
    assign fb_valid = fb_valid_r;
    assign fb_wr    = fb_wr_r;
    assign if_addr   = pf_addr[23:0];
    assign pf_addr_o = pf_addr;
    always_comb for (int i = 0; i < 24; i++) fb_flat[i*8 +: 8] = fb[i];

    wire        if_ack_i  = FAST_IFETCH ? if_ack : 1'b0;
    wire        fetch_ack = FAST_IFETCH ? if_ack_i : pf_ack;
    wire [63:0] if_data   = if_data_i;

    // Early-decode threshold, unchanged from v60.sv.
    always_comb begin
        fb_need = FB_THRESH;
        if (fb_valid_r != 0) begin
            casez (fb[0])
                8'h00, 8'hc8, 8'hc9, 8'hca, 8'hcd: fb_need = 5'd1;
                8'b0110_????:                      fb_need = 5'd2;
                8'b0111_????, 8'h48:               fb_need = 5'd3;
                8'hc6, 8'hc7:                      fb_need = 5'd4;
                8'h2d: begin
                    if (fb_valid_r < 3) fb_need = 5'd3;
                    else if (fb[1][7:5] == 3'b001 && fb[2] == 8'hf4) fb_need = 5'd11;
                end
                default: ;
            endcase
        end
    end

    assign fill_ready = (fb_base_r == pc) && (fb_valid_r >= fb_need);

    // SYNCHRONOUS RESET, GATED BY ce - matching v60.sv's own main block exactly
    // (`always @(posedge clk)` / `if (rst)` / `else if (ce)`). The first version
    // of this module used an asynchronous reset and failed 27 of the 29 unit
    // tests: the window then resets on a different edge from the FSM that reads
    // it.
    always @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 24; i++) fb[i] <= 8'd0;
        fb_base_r <= START_PC;
        fb_valid_r <= 5'd0;
        fb_wr_r <= 5'd0;
`ifndef V60_NO_LOOP_CACHE
        fb_prev_base <= START_PC;
        fb_prev_valid <= 5'd0;
`endif
        fb_realigning <= 1'b0;
        pf_addr <= 32'd0; pf_busy <= 1'b0; pf_suppress <= 1'b0;
        pf_epoch <= 4'd0; pf_iss_epoch <= 4'd0;
        if_req <= 1'b0; pf_req <= 1'b0;
    end else if (ce) begin

    // ---- window realign / rebase / restore, from S_FILL --------------------
    if (fill_active) begin
        if (fb_base_r != pc) begin
            logic [31:0] delta;
            delta = pc - fb_base_r;
            if (delta < {27'b0, fb_valid_r}) begin
                // Consume min(delta,4) bytes this cycle.
                //
                // WIDENED TO 8 ON 2026-08-22 AND REVERTED ON 2026-08-23, ON
                // MEASUREMENTS RATHER THAN THE ORIGINAL GUESS. Each of the 24
                // bytes in fb[] needs a mux selecting fb[i..i+s], so 4 is a 5:1
                // mux per byte and 8 is a 9:1, multiplied by 24 bytes of 8 bits.
                // Built both, Quartus 17.0, the V60 alone:
                //
                //     shift 8   20,614 ALM        STANDALONE
                //     shift 4   20,129 ALM        485 ALM apart
                //
                // AND THAT 485 IS A STANDALONE ARTEFACT. Measured again in the
                // full core, which is the only number that decides anything:
                //
                //     shift 8   17,817 ALM   +0.331 ns slack
                //     shift 4   17,771 ALM   +0.639 ns slack
                //
                // FORTY-SIX ALM, inside fit-to-fit noise. What the narrower shift
                // really buys is TIMING - the 9:1 mux was on the critical path,
                // and 0.3 ns of slack on a design that has been down to +0.024 ns
                // is worth more than 2% of CPU speed. That is the reason it is 4;
                // the area argument this comment first gave was wrong.
                //
                // and it bought 1.7% - mean CPI 17.9 -> 17.6 - because the
                // shifting bucket was already only 1.0 cycle an instruction. A
                // state census puts S_FILL at 33% of all CPU cycles but splits it
                //
                //     shifting  1.0/instruction     dispatch 1.0/instruction
                //     starved-aligned 3.3/instruction
                //
                // so the win was never in the shift width. With the core at 72%
                // of the device and a rasterizer still to fit, 485 ALM for 1.7%
                // is the wrong trade.
                //
                // The note this replaces said "Revisit only with a real STA
                // report" and that has now been done: the core closes at
                // +0.331 ns, so the timing objection has gone - the AREA one
                // has not.
                logic [4:0] s;
                s = (delta >= 32'd4) ? 5'd4 : delta[4:0];
`ifndef V60_NO_LOOP_CACHE
                if (!fb_realigning) begin
                    for (int i = 0; i < 24; i++) fb_prev[i] <= fb[i];
                    fb_prev_base  <= fb_base_r;
                    fb_prev_valid <= fb_valid_r;
                end
`endif
                for (int i = 0; i < 24; i++)
                    if (i + s < 24) fb[i] <= fb[i + s];
                fb_base_r  <= fb_base_r + {27'b0, s};
                fb_valid_r <= fb_valid_r - s;
                fb_wr_r    <= fb_wr_r - s;   // frontier shifts down with the window
                fb_realigning <= (delta > 32'd4);
            end
            else begin
                fb_realigning <= 0;
                // window rebased (branch out of window / loop-cache restore):
                // void any prefetch already in flight for the old window.
                pf_epoch <= pf_epoch + 4'd1;
                if (fb_prev_valid != 0 && pc == fb_prev_base) begin
                    for (int i = 0; i < 24; i++) fb[i] <= fb_prev[i];
                    fb_valid_r <= fb_prev_valid;
                    fb_wr_r    <= fb_prev_valid;   // restored window: frontier = restored count
                    fb_base_r  <= fb_prev_base;
                    pf_suppress <= 1'b1;         // loop-cache hit: let the cache serve it
                end
                else begin
                    fb_valid_r <= 0;
                    fb_wr_r    <= 0;
                    fb_base_r  <= pc;
`ifndef V60_NO_LOOP_CACHE
                    fb_prev_valid <= 0;
`endif
                    pf_suppress <= 1'b0;         // real branch out: resume lookahead
                end
            end
        end
        else begin
            // window aligned (fb_base_r==pc): dispatch once the PFU has fetched
            // enough bytes, else wait here while the prefetch fills the window.
            // The dispatch decision is the FSM's; this unit only reports
            // readiness through fill_ready.
            fb_realigning <= 0;
        end
    end

    // ---- Instruction Prefetch Unit ----------------------------------------
    // ---- Instruction Prefetch Unit (PFU) ------------------------------------
    // Concurrent with the main FSM: keep the fetch window full by issuing 32-bit
    // reads on the pf_* port (data has bus priority) while the window is aligned
    // and has room.  A single fetch is in flight at a time.  On ack the four
    // bytes are appended above the frontier fb_wr_r, UNLESS the window was rebased
    // meanwhile (epoch mismatch), the frontier address moved (branch), or the
    // main FSM is shifting/rebasing the window this very cycle (S_FILL realign) --
    // in those cases the bytes are discarded and the frontier is simply refetched.
    if (!pf_busy) begin
        // Issue while the window is aligned and either the current instruction
        // still lacks bytes (fb_wr_r < fb_need -- correctness, never starves) or we
        // want lookahead up to PF_HIGH.  Lookahead is skipped inside an
        // fb_prev-cached loop (pf_suppress): the loop cache already serves those
        // bytes with zero bus traffic, so prefetching them just thrashes SDRAM.
        // fb_wr_r<=20 keeps the append within the 24-byte window.
        if (fb_base_r == pc && !fb_realigning && fb_wr_r <= 5'd20
            && (fb_wr_r < fb_need || (fb_wr_r < PF_HIGH && !pf_suppress))) begin
            pf_addr      <= fb_base_r + {27'b0, fb_wr_r};
            pf_iss_epoch <= pf_epoch;
            pf_busy      <= 1'b1;
            if (FAST_IFETCH) if_req <= 1'b1;   // wide 8-byte icache line via if_addr
            else             pf_req <= 1'b1;    // 32-bit read via the shared adapter
        end
    end
    else if (fetch_ack) begin
        pf_req  <= 1'b0;
        if_req  <= 1'b0;
        pf_busy <= 1'b0;
        if (pf_iss_epoch == pf_epoch
            && pf_addr == fb_base_r + {27'b0, fb_wr_r}
            && !(fill_active && fb_base_r != pc)) begin
            if (FAST_IFETCH) begin
                // append the 8-byte line from the frontier offset to the line end
                // (1..8 bytes).  s32_core has ALREADY aligned if_data so byte 0 is
                // the frontier byte (the >>foff barrel shift lives there, off this
                // tight clock domain), so we only place bytes at the frontier fb_wr_r
                // -- the same simple (i-fb_wr_r)*8 index the legacy 4-byte path uses.
                // navail = bytes from the frontier to the line end (1..8).
                logic [4:0]  foff, navail, ncom;
                foff    = {2'b0, pf_addr[2:0]};
                navail  = 5'd8 - foff;
                ncom    = ((fb_wr_r + navail) > 5'd24) ? (5'd24 - fb_wr_r) : navail;
                for (int i = 0; i < 24; i++)
                    if (i >= fb_wr_r && i < fb_wr_r + ncom)
                        fb[i] <= if_data_i[(i - fb_wr_r)*8 +: 8];
                fb_wr_r    <= fb_wr_r + ncom;
                fb_valid_r <= fb_wr_r + ncom;
            end
            else begin
                for (int i = 0; i < 24; i++)
                    if (i >= fb_wr_r && i < fb_wr_r + 4)
                        fb[i] <= bus_rdata[(i - fb_wr_r)*8 +: 8];
                fb_wr_r    <= (fb_wr_r > 5'd20) ? 5'd24 : fb_wr_r + 5'd4;
                fb_valid_r <= (fb_wr_r > 5'd20) ? 5'd24 : fb_wr_r + 5'd4;
            end
        end
    end

    // ---- self-modifying-code guard ----------------------------------------
    // Self-modifying-code guard (audit R20 V60-19): a completing data write that
    // overlaps the live or retained fetch window invalidates it, so a subsequent
    // execution refetches instead of running stale bytes (e.g. a tight backward
    // loop that patches its own body, which the retained window would otherwise
    // serve forever).  A data write and a prefetch ack are mutually exclusive
    // (one bus owner), so this never races the prefetch commit above.
    if (dbus_req && dbus_we && dack) begin
        logic [31:0] wr_end, fb_end, pv_end;
        logic [2:0]  wr_sz;
        wr_sz  = (dbus_size == 2'd0) ? 3'd1 : (dbus_size == 2'd1) ? 3'd2 : 3'd4;
        wr_end = dbus_addr + {29'b0, wr_sz};
        // Guard the full FETCHED frontier (fb_wr_r), not just the decode-visible
        // count (fb_valid_r): prefetched-but-not-yet-decoded bytes must also be
        // dropped if a store overwrites them (fb_wr_r==fb_valid_r pre-prefetch, so
        // this is bit-identical today).
        fb_end = fb_base_r + {27'b0, fb_wr_r};
        pv_end = fb_prev_base + {27'b0, fb_prev_valid};
        if (fb_wr_r != 0 && dbus_addr < fb_end && wr_end > fb_base_r) begin
            fb_valid_r <= 5'd0;
            fb_wr_r    <= 5'd0;
            pf_epoch <= pf_epoch + 4'd1;  // void any in-flight prefetch too
        end
`ifndef V60_NO_LOOP_CACHE
        // Self-modifying code invalidates the cached window.
        if (fb_prev_valid != 0 && dbus_addr < pv_end && wr_end > fb_prev_base)
            fb_prev_valid <= 5'd0;
`endif
    end
    end
    end

endmodule
