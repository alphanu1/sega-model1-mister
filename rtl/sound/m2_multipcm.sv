//============================================================================
// Sega 315-5560 MultiPCM (Yamaha YMW-258-F GEW8)
//
// Register, descriptor, pitch and PCM semantics follow MAME multipcm.cpp and
// gew.cpp.  Envelope curves, interpolation and LFO modulation remain bounded
// approximations; the sample-selection/playback path is cycle deterministic.
//============================================================================

module m2_multipcm (
    input             clk,
    input             ce,
    input             rst,

    input             cs,
    input             we,
    input       [1:0] addr,
    input       [7:0] wdata,
    output      [7:0] rdata,

    output reg        rom_req,
    // WHICH VOICE THIS FETCH IS FOR. Added; nothing else in this file changed.
    // The chip round-robins 28 slots, so consecutive fetches come from 28
    // unrelated sample streams and a cache that does not know which voice it is
    // serving thrashes on every single access -- measured, no effect whatever.
    // play_slot and df_slot are both written before rom_req rises, so this is a
    // wire off existing state and changes no timing.
    output wire [4:0] rom_slot,
    // ONE STROBE PER OUTPUT SAMPLE. Added; the chip emits a stereo pair each
    // time it finishes a pass over its 28 slots, so counting these counts the
    // real sample rate -- 10 MHz / 224 = 44,643 Hz when it is keeping time. It
    // is the only honest measure of "the sound is slow", because amplitude
    // measures whatever the music is doing and moves the wrong way.
    output reg        sample_stb,
    output reg [21:0] rom_addr,
    input       [7:0] rom_data,
    input             rom_ack,

    // TWO BITS, one of four 1 MB pages -- see banked() below. It was a pair of
    // three-bit fields, which is System 32's scheme on the same chip.
    input       [1:0] bank_sel,

    output reg signed [15:0] out_l,
    output reg signed [15:0] out_r
);

assign rdata = 8'h00;
assign rom_slot = rom_is_desc ? df_slot : play_slot;

reg [7:0] sreg [0:27][0:7];
// THE FIVE REGISTER FIELDS THE CHIP READS ARE MLABs TOO (R221). The mixer
// reads pan (reg 0[7:4]) and level (reg 5[7:1]) at play_slot; the stepper
// reads pitch (reg 2[7:2]) and octave/pitch (reg 3) at `slot`; the
// descriptor pick reads sample (reg 1, reg 2[0]) at `picked`, an address
// that exists only in the cycle it is used, so those two stay in `sreg`
// -- as does anything never read, which synthesis drops. Each MLAB is
// written beside `sreg` by the CPU and read registered at its consumer's
// slot; a write to the slot being read is forwarded for the one cycle the
// registered read is behind it. 700 registers a chip and their 28:1 muxes.
(* ramstyle = "MLAB" *) reg [3:0] pan_ram [0:31];    // reg 0[7:4]
(* ramstyle = "MLAB" *) reg [6:0] lvl_ram [0:31];    // reg 5[7:1]
(* ramstyle = "MLAB" *) reg [5:0] pit_ram [0:31];    // reg 2[7:2]
(* ramstyle = "MLAB" *) reg [7:0] oct_ram [0:31];    // reg 3
reg [3:0] pan_rd, pan_fwd_d;
reg [6:0] lvl_rd, lvl_fwd_d;
reg [5:0] pit_rd, pit_fwd_d;
reg [7:0] oct_rd, oct_fwd_d;
reg       pan_fwd, lvl_fwd, pit_fwd, oct_fwd;
wire [3:0] pan_cur = pan_fwd ? pan_fwd_d : pan_rd;
wire [6:0] lvl_cur = lvl_fwd ? lvl_fwd_d : lvl_rd;
wire [5:0] pit_cur = pit_fwd ? pit_fwd_d : pit_rd;
wire [7:0] oct_cur = oct_fwd ? oct_fwd_d : oct_rd;
reg [4:0] cur_slot;
reg       cur_slot_valid;
reg [2:0] cur_reg;
wire       sreg_we = cs && we && (addr == 2'd0) && cur_slot_valid;

// THE PER-SLOT STEPPING STATE IS TWO MLAB RAMs, NOT 2,600 FLIP-FLOPS (R221).
// Each has one writer and one reader, so each is a simple dual-port memory
// and the two never need a true dual-port block:
//   desc_ram {end, loop, start}: written when a descriptor fetch completes
//            (key-on or sample change), read by the stepper.
//   pos_ram  the 38-bit position: written and read by the stepper alone.
// The stepper reads slot `slot`, and the read address moves to the next
// slot on the tick that advances it, so the word is on the RAM output by
// tick 0. Two things the flip-flop version did in place are done beside
// the RAMs: key-on zeroed the position -- now it sets pos_zero[slot], which
// reads as position 0 until the stepper's first write clears it; and a
// descriptor completing the cycle before the stepper uses that same slot
// would be read stale from the RAM -- the completed word is held one cycle
// in desc_fwd and used instead. s_active, s_fmt12 and s_release stay
// registers: the first two gate every use and must clear at reset, the
// last has a reset value.
(* ramstyle = "MLAB" *) reg [54:0] desc_ram [0:31];   // {end[16:0], loop[15:0], start[21:0]}
(* ramstyle = "MLAB" *) reg [37:0] pos_ram  [0:31];
reg [54:0] desc_rd;
reg [37:0] pos_rd;
reg [27:0] pos_zero;
reg        desc_fwd;
reg [54:0] desc_fwd_d;
wire [4:0]  slot_next  = (slot == 5'd27) ? 5'd0 : slot + 5'd1;
wire [4:0]  st_rd_addr = (!rom_req && tick == 3'd7) ? slot_next : slot;
wire [54:0] desc_cur   = desc_fwd ? desc_fwd_d : desc_rd;
wire [37:0] s_pos_cur   = pos_zero[slot] ? 38'd0 : pos_rd;
wire [21:0] s_start_cur = desc_cur[21:0];
wire [15:0] s_loop_cur  = desc_cur[37:22];
wire [16:0] s_end_cur   = desc_cur[54:38];
wire [54:0] desc_word   = {17'h10000 - {1'b0, df_buf[5], df_buf[6]},
                           {df_buf[3], df_buf[4]},
                           {df_buf[0][5:0], df_buf[1], df_buf[2]}};
always @(posedge clk) begin
    desc_rd <= desc_ram[st_rd_addr];
    pos_rd  <= pos_ram[st_rd_addr];
    pan_rd  <= pan_ram[play_slot];
    lvl_rd  <= lvl_ram[play_slot];
    pit_rd  <= pit_ram[st_rd_addr];
    oct_rd  <= oct_ram[st_rd_addr];
    // The forwards: a CPU write this edge to the slot a read is taking.
    pan_fwd <= sreg_we && (cur_reg == 3'd0) && (cur_slot == play_slot);
    lvl_fwd <= sreg_we && (cur_reg == 3'd5) && (cur_slot == play_slot);
    pit_fwd <= sreg_we && (cur_reg == 3'd2) && (cur_slot == st_rd_addr);
    oct_fwd <= sreg_we && (cur_reg == 3'd3) && (cur_slot == st_rd_addr);
    pan_fwd_d <= wdata[7:4];
    lvl_fwd_d <= wdata[7:1];
    pit_fwd_d <= wdata[7:2];
    oct_fwd_d <= wdata;
    if (sreg_we) case (cur_reg)
        3'd0: pan_ram[cur_slot] <= wdata[7:4];
        3'd5: lvl_ram[cur_slot] <= wdata[7:1];
        3'd2: pit_ram[cur_slot] <= wdata[7:2];
        3'd3: oct_ram[cur_slot] <= wdata;
        default: ;
    endcase
end
reg        s_fmt12 [0:27];
reg        s_active[0:27];
reg  [3:0] s_release [0:27];

// Descriptor work is queued by sample writes and key-on.  key_wait records
// that completion must start/retrigger the voice.
reg [27:0] desc_pending;
reg [27:0] key_wait;
reg [4:0]  df_slot;
reg [8:0]  df_sample;
reg [3:0]  df_idx;
reg        df_busy;
reg [7:0]  df_buf [0:11];

reg [2:0] tick;
reg [4:0] slot;
reg [4:0] play_slot;
reg       rom_is_desc;
reg signed [21:0] acc_l, acc_r;

integer ri;
integer rj;

// THE MODEL 1 BOARD'S BANKING, WHICH IS NOT SYSTEM 32's.
//
// This function is the one thing in this file that does not transfer between
// the two boards, and getting it from the wrong one is audible as a foghorn.
// segam1audio.cpp gives each MULTIPCM a TWO megabyte space:
//
//     map(0x000000, 0x0fffff).rom();                 // first 1 MB, direct
//     map(0x100000, 0x1fffff).bankr(m_mpcmbank1);    // second 1 MB, banked
//     m_mpcmbank1->configure_entries(0, 4, region->base(), 0x100000);
//
// so the upper megabyte is a window onto one of FOUR one-megabyte pages of the
// 4 MB region. System 32 banks in 512 KB pages with a three-bit selector split
// across two fields, and with Daytona's bank value of 0x01 that scheme sends
// everything above 1 MB into the wrong place entirely -- 0x100000 reads from
// 0x080000 and anything above 0x180000 reads from the first 512 KB.
//
// Daytona's music sits below 1 MB and was therefore correct throughout; the
// voice samples sit above it, which is why the words came out as a whine while
// the music was already right.
function automatic [21:0] banked(input [21:0] a);
    if (a < 22'h100000) banked = a;
    else                banked = {bank_sel, a[19:0]};
endfunction

// MAME update_step: base=(1+pitch/1024), exponent=(signed octave-1).
// This RTL position uses sixteen fractional bits instead of MAME's TL_SHIFT.
function automatic [24:0] pitch_step(input [3:0] oct_bits, input [9:0] pitch);
    reg signed [4:0] oct;
    reg [24:0] base;
begin
    oct = oct_bits[3] ? $signed({1'b1, oct_bits}) : $signed({1'b0, oct_bits});
    base = {8'b0, 1'b1, pitch, 6'b0};
    if (oct >= 1) pitch_step = base << (oct - 1);
    else          pitch_step = base >> (1 - oct);
end
endfunction

function automatic signed [15:0] pan_sample(
    input signed [15:0] sample,
    input [3:0] pan,
    input is_left
);
    reg [3:0] distance;
begin
    if (pan == 4'h8) begin
        pan_sample = 16'sd0;
    end
    else if (pan == 4'h0) begin
        pan_sample = sample;
    end
    else if (!pan[3]) begin
        // 1..7 attenuate left; 7 is hard-left mute.
        if (!is_left) pan_sample = sample;
        else if (pan == 4'h7) pan_sample = 16'sd0;
        else pan_sample = sample >>> ((pan + 1'b1) >> 1);
    end
    else begin
        // 9..15 attenuate right using MAME's inverted distance.
        distance = 4'd0 - pan;
        if (is_left) pan_sample = sample;
        else if (distance == 4'h7) pan_sample = 16'sd0;
        else pan_sample = sample >>> ((distance + 1'b1) >> 1);
    end
end
endfunction

function automatic signed [15:0] clamp16(input signed [21:0] value);
begin
    if (value > 22'sd32767)       clamp16 = 16'sh7fff;
    else if (value < -22'sd32768) clamp16 = -16'sh8000;
    else                          clamp16 = value[15:0];
end
endfunction

always @(posedge clk) begin
    if (rst) begin
        cur_slot <= 0;
        cur_slot_valid <= 1'b1;
        cur_reg <= 0;
        rom_req <= 0;
        sample_stb <= 1'b0;
        rom_addr <= 0;
        rom_is_desc <= 0;
        desc_pending <= 0;
        key_wait <= 0;
        pos_zero <= 0;
        desc_fwd <= 0;
        df_slot <= 0;
        df_sample <= 0;
        df_idx <= 0;
        df_busy <= 0;
        tick <= 0;
        slot <= 0;
        play_slot <= 0;
        acc_l <= 0;
        acc_r <= 0;
        out_l <= 0;
        out_r <= 0;
        for (ri = 0; ri < 28; ri = ri + 1) begin
            s_fmt12[ri] <= 0;
            s_active[ri] <= 0;
            s_release[ri] <= 4'hf;
            for (rj = 0; rj < 8; rj = rj + 1)
                sreg[ri][rj] <= 0;
        end
        for (ri = 0; ri < 12; ri = ri + 1)
            df_buf[ri] <= 0;
    end
    else begin
        desc_fwd <= 1'b0;                 // R221: the forwarded word lives one cycle
        // Register writes are on the Z80 clock domain represented by clk and
        // must not be dropped merely because the audio sample CE is low.
        if (cs && we) begin
            case (addr)
                2'd1: begin
                    // VALUE_TO_CHANNEL: every eighth selector is a hole.
                    cur_slot_valid <= (wdata[2:0] != 3'd7);
                    if (wdata[2:0] != 3'd7)
                        cur_slot <= wdata[4:0] - {3'b000, wdata[4:3]};
                end
                2'd2: cur_reg <= (wdata > 8'd7) ? 3'd7 : wdata[2:0];
                2'd0: if (cur_slot_valid) begin
                    sreg[cur_slot][cur_reg] <= wdata;
                    if (cur_reg == 3'd1) begin
                        // Sample index is nine bits; bit 8 lives in pitch reg2.
                        desc_pending[cur_slot] <= 1'b1;
                        if (s_active[cur_slot]) begin
                            s_active[cur_slot] <= 1'b0;
                            key_wait[cur_slot] <= 1'b1;
                        end
                    end
                    if (cur_reg == 3'd4) begin
                        if (wdata[7]) begin
                            // Fetch current metadata before starting so no
                            // uninitialized start/end state can be sampled.
                            s_active[cur_slot] <= 1'b0;
                            key_wait[cur_slot] <= 1'b1;
                            desc_pending[cur_slot] <= 1'b1;
                        end
                        else begin
                            // Release curves are not yet modeled. Immediate
                            // stop is exact for release=F and bounded otherwise.
                            s_active[cur_slot] <= 1'b0;
                            key_wait[cur_slot] <= 1'b0;
                        end
                    end
                end
                default: ;
            endcase
        end

        // ROM acknowledgements are sampled every clk, not only on ce.  The
        // SDRAM/cache response is a clk-domain pulse and may fall between CEs.
        if (rom_req && rom_ack) begin
            rom_req <= 1'b0;
            if (rom_is_desc) begin
                df_buf[df_idx] <= rom_data;
                if (df_idx == 4'd11) begin
                    df_busy <= 1'b0;
                    desc_ram[df_slot] <= desc_word;                 // R221
                    desc_fwd   <= (df_slot == st_rd_addr);
                    desc_fwd_d <= desc_word;
                    s_fmt12[df_slot] <= df_buf[0][6];
                    s_release[df_slot] <= df_buf[10][3:0];
                    // Hardware copies descriptor defaults into LFO registers.
                    sreg[df_slot][6] <= df_buf[7];
                    sreg[df_slot][7] <= {4'b0000, rom_data[3:0]};
                    if (key_wait[df_slot]) begin
                        s_active[df_slot] <= 1'b1;
                        pos_zero[df_slot] <= 1'b1;                  // R221: position 0 until stepped
                        key_wait[df_slot] <= 1'b0;
                    end
                end
                else begin
                    df_idx <= df_idx + 1'b1;
                end
            end
            else begin
                reg signed [15:0] sample;
                reg signed [15:0] attenuated;
                reg signed [15:0] panned_l;
                reg signed [15:0] panned_r;
                reg [6:0] tl;
                // MultiPCM 8-bit samples are signed two's-complement, not
                // unsigned/offset-binary.  Byte 80h therefore means -32768.
                sample = {rom_data, 8'h00};
                tl = lvl_cur;
                attenuated = sample >>> (tl >> 4);
                panned_l = pan_sample(attenuated, pan_cur, 1'b1);
                panned_r = pan_sample(attenuated, pan_cur, 1'b0);
                acc_l <= acc_l + {{6{panned_l[15]}}, panned_l};
                acc_r <= acc_r + {{6{panned_r[15]}}, panned_r};
            end
        end

        sample_stb <= 1'b0;
        if (ce) begin
            if (!df_busy && desc_pending != 0) begin
                reg found;
                reg [4:0] picked;
                found = 1'b0;
                picked = 0;
                for (ri = 0; ri < 28; ri = ri + 1) begin
                    if (desc_pending[ri] && !found) begin
                        found = 1'b1;
                        picked = ri[4:0];
                    end
                end
                df_slot <= picked;
                df_sample <= {sreg[picked][2][0], sreg[picked][1]};
                df_idx <= 0;
                df_busy <= 1'b1;
                desc_pending[picked] <= 1'b0;
            end
            else if (df_busy) begin
                if (!rom_req) begin
                    rom_req <= 1'b1;
                    rom_is_desc <= 1'b1;
                    rom_addr <= (df_sample * 22'd12) + {18'd0, df_idx};
                end
            end
            else if (!rom_req) begin
                tick <= tick + 1'b1;
                if (tick == 3'd7) begin
                    tick <= 0;
                    if (slot == 5'd27) begin
                        slot <= 0;
                        sample_stb <= 1'b1;
                        out_l <= clamp16(acc_l >>> 2);
                        out_r <= clamp16(acc_r >>> 2);
                        acc_l <= 0;
                        acc_r <= 0;
                    end
                    else slot <= slot + 1'b1;
                end

                if (tick == 0 && s_active[slot]) begin
                    reg [9:0] pitch;
                    reg [24:0] step;
                    reg [37:0] next_pos;
                    reg [33:0] loop_span;
                    pitch = {oct_cur[3:0], pit_cur};
                    step = pitch_step(oct_cur[7:4], pitch);
                    next_pos = s_pos_cur + {13'd0, step};
                    loop_span = ({17'd0, s_end_cur} - {18'd0, s_loop_cur}) << 16;
                    if (next_pos >= ({21'd0, s_end_cur} << 16) && loop_span != 0)
                        next_pos = next_pos - {4'd0, loop_span};
                    pos_ram[slot]  <= next_pos;                     // R221
                    pos_zero[slot] <= 1'b0;
                    play_slot <= slot;
                    rom_req <= 1'b1;
                    rom_is_desc <= 1'b0;
                    // 12-bit packed samples are identified and retained in
                    // state, but the bounded v1 datapath still fetches 8-bit.
                    rom_addr <= banked(s_start_cur + s_pos_cur[37:16]);
                end
            end
        end
    end
end

endmodule
