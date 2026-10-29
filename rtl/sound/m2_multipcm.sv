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
// REGISTER 1 (THE SAMPLE NUMBER) IS AN MLAB (2026-10-28). The descriptor pick
// reads only reg 1 and reg 2 bit 0 of `sreg`, at `picked`; everything else in
// it is never read and synthesis drops it. Reg 1 was 224 flip-flops and a 28:1
// mux a chip. Reset is kept with a valid bit per slot (an unwritten slot reads
// 0, as the cleared flip-flop did - a key-on can pick a slot whose reg 1 was
// never written), and the write of the previous clock is bypassed: a reg 1
// write sets desc_pending, so the very next enabled cycle can read it back.
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] smp1_ram [0:31];
reg [27:0] smp1_v;
reg        smp1_bw_v;
reg [4:0]  smp1_bw_a;
reg [7:0]  smp1_bw_d;
// THE FIVE REGISTER FIELDS THE CHIP READS ARE MLABs TOO (R221). The mixer
// reads pan (reg 0[7:4]) and level (reg 5[7:1]) at play_slot; the stepper
// reads pitch (reg 2[7:2]) and octave/pitch (reg 3) at `slot`; the
// descriptor pick reads sample (reg 1, reg 2[0]) at `picked`, an address
// that exists only in the cycle it is used, so those two stay in `sreg`
// -- as does anything never read, which synthesis drops. Each MLAB is
// written beside `sreg` by the CPU and read registered at its consumer's
// slot; a write to the slot being read is forwarded for the one cycle the
// registered read is behind it. 700 registers a chip and their 28:1 muxes.
// M10K, NOT MLAB, AS OF 2026-10-27. The MLAB was chosen when M10K was 553 of
// 553; the quad payload's move to DDR3 handed back ~70 blocks, and an MLAB
// is ALMs - about ten per 640 bits - where ALM is now the binding resource.
// The read was already registered, so the RTL's behaviour is unchanged.
(* ramstyle = "M10K" *) reg [3:0] pan_ram [0:31];    // reg 0[7:4]
(* ramstyle = "M10K" *) reg [6:0] lvl_ram [0:31];    // reg 5[7:1]
(* ramstyle = "M10K" *) reg [5:0] pit_ram [0:31];    // reg 2[7:2]
(* ramstyle = "M10K" *) reg [7:0] oct_ram [0:31];    // reg 3
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
//   pos_ram  the position: written and read by the stepper alone. 32 bits
//            with 12 fractional, gew.cpp's m_offset exactly (2026-10-29;
//            it was 38 bits with 16), because the loop arithmetic wraps
//            modulo 2^32 there and a descriptor with its loop past its end
//            - every one of NetMerc's - goes wherever that wrap sends it.
//   prev_ram the previous sample, for the interpolation; written by tick 4.
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
// M10K, NOT MLAB, AS OF 2026-10-27. The MLAB was chosen when M10K was 553 of
// 553; the quad payload's move to DDR3 handed back ~70 blocks, and an MLAB
// is ALMs - about ten per 640 bits - where ALM is now the binding resource.
// The read was already registered, so the RTL's behaviour is unchanged.
// {eg rates[27:0], end[16:0], loop[15:0], start[21:0]}. The envelope's four
// rate indices and its decay level ride in the descriptor word, because MAME
// computes them at the same moment the descriptor takes effect (retrigger)
// and the word already has a forward for the cycle it is written.
(* ramstyle = "M10K" *) reg [82:0] desc_ram [0:31];
(* ramstyle = "M10K" *) reg [31:0] pos_ram  [0:31];
(* ramstyle = "M10K" *) reg [15:0] prev_ram [0:31];
reg [82:0] desc_rd;
reg [31:0] pos_rd;
reg [15:0] prev_rd;
reg [27:0] pos_zero;
reg        desc_fwd;
reg [82:0] desc_fwd_d;
wire [4:0]  slot_next  = (slot == 5'd27) ? 5'd0 : slot + 5'd1;
wire [4:0]  st_rd_addr = (!rom_req && tick == 3'd7) ? slot_next : slot;
wire [82:0] desc_cur   = desc_fwd ? desc_fwd_d : desc_rd;
// pos_zero is the retrigger: position 0 and gew.cpp's m_prev_sample = 0.
wire [31:0] s_pos_cur   = pos_zero[slot] ? 32'd0 : pos_rd;
wire [15:0] s_prev_cur  = pos_zero[slot] ? 16'd0 : prev_rd;
wire [21:0] s_start_cur = desc_cur[21:0];
wire [15:0] s_loop_cur  = desc_cur[37:22];
wire [16:0] s_end_cur   = desc_cur[54:38];
wire [27:0] s_egr_cur   = desc_cur[82:55];
wire [82:0] desc_word   = {eg_rates(df_buf[8], df_buf[9], df_buf[10], kon_op[df_slot]),
                           17'h10000 - {1'b0, df_buf[5], df_buf[6]},
                           {df_buf[3], df_buf[4]},
                           {df_buf[0][5:0], df_buf[1], df_buf[2]}};
always @(posedge clk) begin
    desc_rd <= desc_ram[st_rd_addr];
    pos_rd  <= pos_ram[st_rd_addr];
    prev_rd <= prev_ram[st_rd_addr];
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
// THE ENVELOPE GENERATOR (2026-10-29), MAME gew.cpp's, per slot per sample.
//
// There was none. A voice played at full level from key-on to key-off, so a
// sample whose descriptor says "decay to nothing in 6 ms" sustained instead.
// NetMerc is where that is loud: its first sample ROM (mpr-18134) is a known
// bad dump, all 0xFF, so every one of chip 1's descriptors reads as
// attack F, decay F, decay level 0 - a 6 ms click in MAME - pointing at
// address 0x3FFFFF with a loop past its own end, which walks the whole ROM
// at random. Without the envelope those clicks became continuous noise:
// the hiss. Measured with tb_multipcm_replay on MAME's own register traffic
// (docs/findings.md 2026-10-29).
//
// Per slot, in eg_ram {state, volume}: volume is MAME's 10.16 linear value;
// the step for the state comes from a 128-entry ROM of MAME's attack and
// decay steps, and the gain from MAME's 1024-entry linear->exponential
// table, both generated from multipcm_ref.h (sim/sound/gen_mpcm_tables.cpp).
// The four rate indices and the decay level are fixed at retrigger, as MAME
// does, and live in the descriptor word.
//
// Pipeline, all inside the slot's eight ticks:
//   tick 0  position step and sample fetch (as before); the envelope's
//           state and volume are snapshotted and the step ROM addressed
//   tick 2  volume and state advanced and written back; gain ROM addressed
//   tick 4  sample x gain, then level and pan as before, into the mix
// Two ticks apart because each ROM is registered: a tick can be the very
// next clock, and the ROM's output is one clock behind its address.
localparam [1:0] EG_ATTACK = 2'd0, EG_DECAY1 = 2'd1, EG_DECAY2 = 2'd2, EG_RELEASE = 2'd3;
(* ramstyle = "M10K" *) reg [27:0] eg_ram [0:31];   // {state[1:0], volume[25:0]}
reg [27:0] eg_rd;
reg [27:0] eg_zero;     // retriggered: reads as ATTACK, volume 0, until written
reg [27:0] rel_pend;    // keyed off: enter RELEASE at the next update
reg        eg_p_valid;  // tick 0 -> tick 2
reg [4:0]  eg_p_slot;
reg [1:0]  eg_p_state;
reg [25:0] eg_p_vol;
reg [3:0]  eg_p_dl;
reg        eg_p_zero, eg_p_rel;
reg  [6:0] egs_addr;
wire [26:0] egs_q;
reg  [9:0] gain_addr;
wire [12:0] gain_q;
reg        mac_pend;    // tick 0 fetched a sample; tick 4 mixes it
// THE SAMPLE, gew.cpp's sound_stream_update (2026-10-29). Up to two bytes a
// sample: 8-bit voices read one; 12-bit voices (descriptor bit 22) read the
// packed pair - even samples {b[0], b[1][3:0]}, odd {b[2], b[1][7:4]} - as
// tick 0 and tick 1 fetches. Then MAME's linear interpolation against the
// previous sample, by the 12-bit fraction of the position.
reg  [7:0] smp_hi, smp_lo;  // fetched bytes, held for tick 4
reg        f_ph;            // the fetch in flight is the second byte
reg        f2_pend;         // a 12-bit voice still owes its tick 1 fetch
reg        f2_valid;
reg [21:0] f2_addr;
reg        m_fmt12, m_odd, m_chg;
reg [11:0] m_fpart;
reg [15:0] m_prev;
// The stepper's enable, as the slot loop below decides it: descriptor work
// first, then nothing while a fetch is out.
wire step_en  = ce && !df_busy && (desc_pending == 28'd0) && !rom_req;
// A retrigger completing between this slot's tick 0 and its update makes the
// snapshot stale: eg_zero is left standing (and the voice is not stopped), so
// the next tick 0 starts the new note from ATTACK at zero whatever the RAM
// was given. tb_multipcm_replay MIDPASS=1 drives that window.
wire eg_stale = eg_zero[eg_p_slot] && !eg_p_zero;
always @(posedge clk) begin
    eg_rd <= eg_ram[st_rd_addr];
    if (step_en && tick == 3'd2 && eg_p_valid)
        eg_ram[eg_p_slot] <= {eg_next_state, eg_next_vol};
end
m2_mpcm_egstep  u_egstep  (.clk(clk), .a(egs_addr),  .q(egs_q));
m2_mpcm_lin2exp u_lin2exp (.clk(clk), .a(gain_addr), .q(gain_q));

// The update, as gew.cpp's envelope_generator_update(). The step for the
// state was addressed at tick 0 and is on egs_q.
reg  [1:0]  eg_next_state;
reg  [25:0] eg_next_vol;
reg         eg_next_dead;   // release reached zero: the voice stops
always @* begin
    reg signed [27:0] v;
    eg_next_state = eg_p_state;
    eg_next_dead  = 1'b0;
    v = 28'sd0;
    case (eg_p_state)
    EG_ATTACK: begin
        v = $signed({2'b00, eg_p_vol}) + $signed({1'b0, egs_q});
        if (v >= 28'sh3FF_0000) begin
            // MAME skips DECAY1 when its step is at least 0x400<<16; no
            // decay step reaches that (the largest is ~236,000), so never.
            eg_next_state = EG_DECAY1;
            v = 28'sh3FF_0000;
        end
    end
    EG_DECAY1: begin
        v = $signed({2'b00, eg_p_vol}) - $signed({1'b0, egs_q});
        if (v <= 0) v = 28'sd0;
        if ({2'b00, v[25:22]} <= {2'b00, eg_p_dl}) eg_next_state = EG_DECAY2;
    end
    EG_DECAY2: begin
        v = $signed({2'b00, eg_p_vol}) - $signed({1'b0, egs_q});
        if (v <= 0) v = 28'sd0;
    end
    default: begin   // RELEASE
        v = $signed({2'b00, eg_p_vol}) - $signed({1'b0, egs_q});
        if (v <= 0) begin v = 28'sd0; eg_next_dead = 1'b1; end
    end
    endcase
    eg_next_vol = v[25:0];
end

// gew.cpp's get_rate() index, fixed at retrigger: 0 never moves, F is the
// fastest, anything else 4*val plus the key-rate offset, clamped.
function automatic [5:0] eg_idx(input [3:0] val, input signed [7:0] r);
    reg signed [7:0] t;
begin
    t = $signed({2'b00, val, 2'b00}) + r;
    if (val == 4'h0)       eg_idx = 6'd0;
    else if (val == 4'hf)  eg_idx = 6'd63;
    else if (t < 0)        eg_idx = 6'd0;
    else if (t > 63)       eg_idx = 6'd63;
    else                   eg_idx = t[5:0];
end
endfunction
// {ar, d1r, d2r, rr, decay level}. b8 = {AR, D1R}, b9 = {DL, D2R},
// b10 = {KRS, RR}; op = reg 3's {octave, pitch bit 9} at the moment it takes
// effect.
function automatic [27:0] eg_rates(input [7:0] b8, input [7:0] b9, input [7:0] b10, input [4:0] op);
    reg signed [7:0] oct, r;
begin
    oct = {{4{op[4]}}, op[4:1]};
    r = (b10[7:4] != 4'hf) ? ((oct + $signed({4'b0, b10[7:4]})) <<< 1) + $signed({7'b0, op[0]}) : 8'sd0;
    eg_rates = {eg_idx(b8[7:4], r), eg_idx(b8[3:0], r), eg_idx(b9[3:0], r),
                eg_idx(b10[3:0], r), 4'hf - b9[7:4]};
end
endfunction

// Reg 3's {octave, pitch bit 9} as it stood at the key-on or sample write
// that retriggers the voice: MAME fixes the key-rate scaling there, and a
// pitch write later in the same burst - before the descriptor fetch is
// done - must not move it.
reg  [4:0] kon_op [0:27];
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
//
// AND NOTHING ABOVE 2 MB (2026-10-29). The chip drives 22 address bits and
// the map stops at 0x1FFFFF, so MAME reads 0x200000-0x3FFFFF as unmapped:
// zero. This aliased them into the bank window, which no good descriptor
// ever reaches - but NetMerc's bad-dump descriptors start at 0x3FFFFF, and
// there the alias played real sample data as noise where MAME is silent.
// {valid, address}: invalid reads as 0 and is not fetched.
function automatic [22:0] mpcm_map(input [21:0] a);
    if (a < 22'h100000)      mpcm_map = {1'b1, a};
    else if (a < 22'h200000) mpcm_map = {1'b1, bank_sel, a[19:0]};
    else                     mpcm_map = 23'd0;
endfunction

// gew.cpp update_step: (1 + pitch/1024) << (octave - 1), in 12 fractional
// bits, with MAME's own octave arithmetic - (octave - 1) & 0xF, a right
// shift by 16 - that when bit 3 is set - so octave 8 shifts LEFT by 7 there
// as here. MAME builds the base from a float table and its step can be one
// LSB (1/4096 of a sample, 0.4 cent) lower; this is the exact value.
function automatic [31:0] pitch_step(input [3:0] octave, input [9:0] pitch);
    reg [3:0] oct;
    reg [31:0] base;
begin
    oct  = octave - 4'd1;
    base = {19'd0, 1'b1, pitch, 2'b00};
    if (oct[3]) pitch_step = base >> (5'd16 - {1'b0, oct});
    else        pitch_step = base << oct;
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

// The pick, as a wire: the lowest pending slot (the loop below finds the same).
function automatic [4:0] pick_low(input [27:0] p);
    integer k;
    pick_low = 5'd0;
    for (k = 27; k >= 0; k = k - 1) if (p[k]) pick_low = k[4:0];
endfunction
wire [4:0] pick_w  = pick_low(desc_pending);
wire [7:0] smp1_q  = (smp1_bw_v && smp1_bw_a == pick_w) ? smp1_bw_d :
                     smp1_v[pick_w] ? smp1_ram[pick_w] : 8'd0;
// rst gates the write exactly as the reset branch below pre-empted it.
wire smp1_we = !rst && cs && we && (addr == 2'd0) && cur_slot_valid && (cur_reg == 3'd1);
always @(posedge clk) begin
    if (smp1_we) smp1_ram[cur_slot] <= wdata;
    smp1_bw_v <= smp1_we;
    smp1_bw_a <= cur_slot;
    smp1_bw_d <= wdata;
end

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
        smp1_v <= 0;
        key_wait <= 0;
        pos_zero <= 0;
        eg_zero <= 0;
        rel_pend <= 0;
        eg_p_valid <= 1'b0;
        eg_p_slot <= 0; eg_p_state <= 0; eg_p_vol <= 0; eg_p_dl <= 0;
        eg_p_zero <= 1'b0; eg_p_rel <= 1'b0;
        egs_addr <= 0;
        gain_addr <= 0;
        mac_pend <= 1'b0;
        smp_hi <= 0; smp_lo <= 0;
        f_ph <= 1'b0; f2_pend <= 1'b0; f2_valid <= 1'b0; f2_addr <= 0;
        m_fmt12 <= 1'b0; m_odd <= 1'b0; m_chg <= 1'b0; m_fpart <= 0; m_prev <= 0;
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
            kon_op[ri] <= 5'd0;
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
                    if (cur_reg == 3'd1) smp1_v[cur_slot] <= 1'b1;
                    if (cur_reg == 3'd1 || (cur_reg == 3'd4 && wdata[7]))
                        kon_op[cur_slot] <= sreg[cur_slot][3][7:3];
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
                        else if (s_active[cur_slot] && s_release[cur_slot] != 4'hf) begin
                            // gew.cpp: a playing voice with a release rate
                            // goes to RELEASE and stops when it reaches zero.
                            rel_pend[cur_slot] <= 1'b1;
                        end
                        else begin
                            // Release F, or not playing: stop at once.
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
                        eg_zero[df_slot]  <= 1'b1;                  // retrigger: ATTACK from 0
                        rel_pend[df_slot] <= 1'b0;
                        key_wait[df_slot] <= 1'b0;
                    end
                end
                else begin
                    df_idx <= df_idx + 1'b1;
                end
            end
            else begin
                // Held for tick 4, where the envelope's gain is ready.
                if (f_ph) smp_lo <= rom_data;
                else      smp_hi <= rom_data;
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
                df_sample <= {sreg[picked][2][0], smp1_q};      // smp1_q: reg 1 at picked
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

                if (tick == 3'd2 && eg_p_valid) begin
                    eg_p_valid <= 1'b0;
                    gain_addr  <= eg_next_vol[25:16];
                    if (!eg_stale) begin
                        if (eg_p_zero) eg_zero[eg_p_slot]  <= 1'b0;
                        if (eg_p_rel)  rel_pend[eg_p_slot] <= 1'b0;
                        if (eg_next_dead) s_active[eg_p_slot] <= 1'b0;
                    end
                end

                if (tick == 3'd1 && f2_pend) begin
                    // The 12-bit voice's second byte, the middle of the three.
                    f2_pend <= 1'b0;
                    f_ph    <= 1'b1;
                    if (f2_valid) begin
                        rom_req     <= 1'b1;
                        rom_is_desc <= 1'b0;
                        rom_addr    <= f2_addr;
                    end
                    else smp_lo <= 8'h00;
                end

                if (tick == 3'd4 && mac_pend) begin
                    reg signed [15:0] csmp;
                    reg signed [16:0] diff;
                    /* verilator lint_off UNUSEDSIGNAL */
                    reg signed [29:0] lerp;
                    reg signed [28:0] enved;
                    /* verilator lint_on UNUSEDSIGNAL */
                    /* verilator lint_off UNUSEDSIGNAL */
                    reg signed [16:0] sum17;
                    /* verilator lint_on UNUSEDSIGNAL */
                    reg signed [15:0] sample;
                    reg signed [15:0] env_s;
                    reg signed [15:0] attenuated;
                    reg signed [15:0] panned_l;
                    reg signed [15:0] panned_r;
                    reg [6:0] tl;
                    mac_pend <= 1'b0;
                    // MultiPCM samples are signed two's-complement, not
                    // offset-binary: byte 80h is -32768.
                    if (m_fmt12) csmp = {smp_hi, (m_odd ? smp_lo[7:4] : smp_lo[3:0]), 4'h0};
                    else         csmp = {smp_hi, 8'h00};
                    // (cs*f + prev*(4096-f)) >> 12 is prev + ((cs-prev)*f >> 12)
                    // exactly: prev*4096 is a whole multiple of the divisor.
                    diff   = $signed({csmp[15], csmp}) - $signed({m_prev[15], m_prev});
                    lerp   = diff * $signed({1'b0, m_fpart});
                    sum17  = $signed({m_prev[15], m_prev}) + lerp[28:12];
                    sample = sum17[15:0];   // between prev and cs, so in range
                    // MAME takes the new previous sample when the integer
                    // position moved, before its loop wrap.
                    prev_ram[play_slot] <= m_chg ? csmp : m_prev;
                    // gew.cpp scales by gain >> 10 and its pan table by a
                    // further quarter; here the gain is >> 12 and the level
                    // and pan below keep the shifts they always had.
                    enved = sample * $signed({1'b0, gain_q});
                    env_s = enved[27:12];
                    tl = lvl_cur;
                    attenuated = env_s >>> (tl >> 4);
                    panned_l = pan_sample(attenuated, pan_cur, 1'b1);
                    panned_r = pan_sample(attenuated, pan_cur, 1'b0);
                    acc_l <= acc_l + {{6{panned_l[15]}}, panned_l};
                    acc_r <= acc_r + {{6{panned_r[15]}}, panned_r};
                end

                if (tick == 0 && s_active[slot]) begin
                    reg [9:0] pitch;
                    reg [31:0] next_pos;
                    /* verilator lint_off UNUSEDSIGNAL */
                    reg [31:0] loop_span;   // (end - loop) modulo 2^32; << 12 keeps 20 bits
                    /* verilator lint_on UNUSEDSIGNAL */
                    reg [19:0] spos;
                    reg [21:0] base, a1;
                    reg [22:0] m1, m2;
                    pitch = {oct_cur[3:0], pit_cur};
                    spos = s_pos_cur[31:12];
                    // gew.cpp, in its order: offset += step; prev follows a
                    // change of integer position; then the loop, modulo 2^32.
                    next_pos = s_pos_cur + pitch_step(oct_cur[7:4], pitch);
                    m_chg <= (next_pos[31:12] != spos);
                    loop_span = {15'd0, s_end_cur} - {16'd0, s_loop_cur};
                    if (next_pos >= {3'd0, s_end_cur, 12'd0})
                        next_pos = next_pos - {loop_span[19:0], 12'd0};
                    pos_ram[slot]  <= next_pos;                     // R221
                    pos_zero[slot] <= 1'b0;
                    m_fpart <= s_pos_cur[11:0];
                    m_prev  <= s_prev_cur;
                    m_fmt12 <= s_fmt12[slot];
                    m_odd   <= spos[0];
                    play_slot <= slot;
                    mac_pend <= 1'b1;
                    // The address, 22 bits wrapping as the chip's do.
                    base = s_start_cur + {1'b0, spos[19:1], 1'b0} + {2'b0, spos[19:1]};
                    if (!s_fmt12[slot])  a1 = s_start_cur + {2'b0, spos};
                    else if (spos[0])    a1 = base + 22'd2;
                    else                 a1 = base;
                    m1 = mpcm_map(a1);
                    m2 = mpcm_map(base + 22'd1);
                    f_ph     <= 1'b0;
                    f2_pend  <= s_fmt12[slot];
                    f2_valid <= m2[22];
                    f2_addr  <= m2[21:0];
                    if (m1[22]) begin
                        rom_req     <= 1'b1;
                        rom_is_desc <= 1'b0;
                        rom_addr    <= m1[21:0];
                    end
                    else smp_hi <= 8'h00;
                    // The envelope's snapshot, and the step for its state.
                    begin
                        reg [1:0] st0;
                        st0 = eg_zero[slot] ? EG_ATTACK : eg_rd[27:26];
                        if (rel_pend[slot]) st0 = EG_RELEASE;
                        eg_p_valid <= 1'b1;
                        eg_p_slot  <= slot;
                        eg_p_state <= st0;
                        eg_p_vol   <= eg_zero[slot] ? 26'd0 : eg_rd[25:0];
                        eg_p_dl    <= s_egr_cur[3:0];
                        eg_p_zero  <= eg_zero[slot];
                        eg_p_rel   <= rel_pend[slot];
                        case (st0)
                        EG_ATTACK:  egs_addr <= {1'b0, s_egr_cur[27:22]};
                        EG_DECAY1:  egs_addr <= {1'b1, s_egr_cur[21:16]};
                        EG_DECAY2:  egs_addr <= {1'b1, s_egr_cur[15:10]};
                        default:    egs_addr <= {1'b1, s_egr_cur[9:4]};
                        endcase
                    end
                end
            end
        end
    end
end

endmodule


//============================================================================
// THE ENVELOPE'S TWO ROMs, generated from sim/sound/multipcm_ref.h by
// sim/sound/gen_mpcm_tables.cpp - MAME gew.cpp's own float arithmetic, so the
// constants are the reference's, not a second derivation. Regenerate rather
// than edit. Registered, one clock behind the address.
//============================================================================

// {decay, rate index}: gew.cpp's m_attack_step (decay = 0) and
// m_decay_release_step (decay = 1), in 10.16 volume units per sample.
module m2_mpcm_egstep (
    input             clk,
    input       [6:0] a,
    output reg [26:0] q
);
always @(posedge clk) begin
    case (a)
      7'd0: q <= 27'd0;
      7'd1: q <= 27'd0;
      7'd2: q <= 27'd0;
      7'd3: q <= 27'd0;
      7'd4: q <= 27'd244;
      7'd5: q <= 27'd305;
      7'd6: q <= 27'd366;
      7'd7: q <= 27'd427;
      7'd8: q <= 27'd489;
      7'd9: q <= 27'd611;
      7'd10: q <= 27'd733;
      7'd11: q <= 27'd855;
      7'd12: q <= 27'd978;
      7'd13: q <= 27'd1222;
      7'd14: q <= 27'd1467;
      7'd15: q <= 27'd1711;
      7'd16: q <= 27'd1956;
      7'd17: q <= 27'd2445;
      7'd18: q <= 27'd2934;
      7'd19: q <= 27'd3423;
      7'd20: q <= 27'd3912;
      7'd21: q <= 27'd4890;
      7'd22: q <= 27'd5868;
      7'd23: q <= 27'd6846;
      7'd24: q <= 27'd7825;
      7'd25: q <= 27'd9779;
      7'd26: q <= 27'd11736;
      7'd27: q <= 27'd13689;
      7'd28: q <= 27'd15650;
      7'd29: q <= 27'd19554;
      7'd30: q <= 27'd23465;
      7'd31: q <= 27'd27369;
      7'd32: q <= 27'd31298;
      7'd33: q <= 27'd39109;
      7'd34: q <= 27'd46923;
      7'd35: q <= 27'd54738;
      7'd36: q <= 27'd62597;
      7'd37: q <= 27'd78198;
      7'd38: q <= 27'd93703;
      7'd39: q <= 27'd109320;
      7'd40: q <= 27'd125246;
      7'd41: q <= 27'd156076;
      7'd42: q <= 27'd187406;
      7'd43: q <= 27'd218014;
      7'd44: q <= 27'd250286;
      7'd45: q <= 27'd310559;
      7'd46: q <= 27'd372976;
      7'd47: q <= 27'd436029;
      7'd48: q <= 27'd500573;
      7'd49: q <= 27'd611141;
      7'd50: q <= 27'd714433;
      7'd51: q <= 27'd800917;
      7'd52: q <= 27'd884734;
      7'd53: q <= 27'd1079250;
      7'd54: q <= 27'd1289612;
      7'd55: q <= 27'd1463214;
      7'd56: q <= 27'd1672245;
      7'd57: q <= 27'd2084579;
      7'd58: q <= 27'd2579225;
      7'd59: q <= 27'd3043486;
      7'd60: q <= 27'd3381651;
      7'd61: q <= 27'd3381651;
      7'd62: q <= 27'd3381651;
      7'd63: q <= 27'd67108864;
      7'd64: q <= 27'd0;
      7'd65: q <= 27'd0;
      7'd66: q <= 27'd0;
      7'd67: q <= 27'd0;
      7'd68: q <= 27'd17;
      7'd69: q <= 27'd21;
      7'd70: q <= 27'd25;
      7'd71: q <= 27'd29;
      7'd72: q <= 27'd34;
      7'd73: q <= 27'd42;
      7'd74: q <= 27'd51;
      7'd75: q <= 27'd59;
      7'd76: q <= 27'd68;
      7'd77: q <= 27'd85;
      7'd78: q <= 27'd102;
      7'd79: q <= 27'd119;
      7'd80: q <= 27'd136;
      7'd81: q <= 27'd170;
      7'd82: q <= 27'd204;
      7'd83: q <= 27'd238;
      7'd84: q <= 27'd273;
      7'd85: q <= 27'd341;
      7'd86: q <= 27'd409;
      7'd87: q <= 27'd477;
      7'd88: q <= 27'd546;
      7'd89: q <= 27'd682;
      7'd90: q <= 27'd819;
      7'd91: q <= 27'd955;
      7'd92: q <= 27'd1092;
      7'd93: q <= 27'd1364;
      7'd94: q <= 27'd1637;
      7'd95: q <= 27'd1910;
      7'd96: q <= 27'd2184;
      7'd97: q <= 27'd2729;
      7'd98: q <= 27'd3274;
      7'd99: q <= 27'd3820;
      7'd100: q <= 27'd4368;
      7'd101: q <= 27'd5457;
      7'd102: q <= 27'd6539;
      7'd103: q <= 27'd7629;
      7'd104: q <= 27'd8741;
      7'd105: q <= 27'd10892;
      7'd106: q <= 27'd13079;
      7'd107: q <= 27'd15215;
      7'd108: q <= 27'd17467;
      7'd109: q <= 27'd21674;
      7'd110: q <= 27'd26030;
      7'd111: q <= 27'd30431;
      7'd112: q <= 27'd34935;
      7'd113: q <= 27'd42652;
      7'd114: q <= 27'd49861;
      7'd115: q <= 27'd55897;
      7'd116: q <= 27'd61747;
      7'd117: q <= 27'd75322;
      7'd118: q <= 27'd90004;
      7'd119: q <= 27'd102120;
      7'd120: q <= 27'd116709;
      7'd121: q <= 27'd145486;
      7'd122: q <= 27'd180008;
      7'd123: q <= 27'd212410;
      7'd124: q <= 27'd236011;
      7'd125: q <= 27'd236011;
      7'd126: q <= 27'd236011;
      7'd127: q <= 27'd236011;
    default: q <= 27'd0;
    endcase
end
endmodule

// gew.cpp's m_linear_to_exp_volume: envelope volume [25:16] to a 12-bit
// fraction, 96 dB across the range.
module m2_mpcm_lin2exp (
    input             clk,
    input       [9:0] a,
    output reg [12:0] q
);
always @(posedge clk) begin
    case (a)
      10'd0: q <= 13'd0; 10'd1: q <= 13'd0; 10'd2: q <= 13'd0; 10'd3: q <= 13'd0; 10'd4: q <= 13'd0; 10'd5: q <= 13'd0; 10'd6: q <= 13'd0; 10'd7: q <= 13'd0;
      10'd8: q <= 13'd0; 10'd9: q <= 13'd0; 10'd10: q <= 13'd0; 10'd11: q <= 13'd0; 10'd12: q <= 13'd0; 10'd13: q <= 13'd0; 10'd14: q <= 13'd0; 10'd15: q <= 13'd0;
      10'd16: q <= 13'd0; 10'd17: q <= 13'd0; 10'd18: q <= 13'd0; 10'd19: q <= 13'd0; 10'd20: q <= 13'd0; 10'd21: q <= 13'd0; 10'd22: q <= 13'd0; 10'd23: q <= 13'd0;
      10'd24: q <= 13'd0; 10'd25: q <= 13'd0; 10'd26: q <= 13'd0; 10'd27: q <= 13'd0; 10'd28: q <= 13'd0; 10'd29: q <= 13'd0; 10'd30: q <= 13'd0; 10'd31: q <= 13'd0;
      10'd32: q <= 13'd0; 10'd33: q <= 13'd0; 10'd34: q <= 13'd0; 10'd35: q <= 13'd0; 10'd36: q <= 13'd0; 10'd37: q <= 13'd0; 10'd38: q <= 13'd0; 10'd39: q <= 13'd0;
      10'd40: q <= 13'd0; 10'd41: q <= 13'd0; 10'd42: q <= 13'd0; 10'd43: q <= 13'd0; 10'd44: q <= 13'd0; 10'd45: q <= 13'd0; 10'd46: q <= 13'd0; 10'd47: q <= 13'd0;
      10'd48: q <= 13'd0; 10'd49: q <= 13'd0; 10'd50: q <= 13'd0; 10'd51: q <= 13'd0; 10'd52: q <= 13'd0; 10'd53: q <= 13'd0; 10'd54: q <= 13'd0; 10'd55: q <= 13'd0;
      10'd56: q <= 13'd0; 10'd57: q <= 13'd0; 10'd58: q <= 13'd0; 10'd59: q <= 13'd0; 10'd60: q <= 13'd0; 10'd61: q <= 13'd0; 10'd62: q <= 13'd0; 10'd63: q <= 13'd0;
      10'd64: q <= 13'd0; 10'd65: q <= 13'd0; 10'd66: q <= 13'd0; 10'd67: q <= 13'd0; 10'd68: q <= 13'd0; 10'd69: q <= 13'd0; 10'd70: q <= 13'd0; 10'd71: q <= 13'd0;
      10'd72: q <= 13'd0; 10'd73: q <= 13'd0; 10'd74: q <= 13'd0; 10'd75: q <= 13'd0; 10'd76: q <= 13'd0; 10'd77: q <= 13'd0; 10'd78: q <= 13'd0; 10'd79: q <= 13'd0;
      10'd80: q <= 13'd0; 10'd81: q <= 13'd0; 10'd82: q <= 13'd0; 10'd83: q <= 13'd0; 10'd84: q <= 13'd0; 10'd85: q <= 13'd0; 10'd86: q <= 13'd0; 10'd87: q <= 13'd0;
      10'd88: q <= 13'd0; 10'd89: q <= 13'd0; 10'd90: q <= 13'd0; 10'd91: q <= 13'd0; 10'd92: q <= 13'd0; 10'd93: q <= 13'd0; 10'd94: q <= 13'd0; 10'd95: q <= 13'd0;
      10'd96: q <= 13'd0; 10'd97: q <= 13'd0; 10'd98: q <= 13'd0; 10'd99: q <= 13'd0; 10'd100: q <= 13'd0; 10'd101: q <= 13'd0; 10'd102: q <= 13'd0; 10'd103: q <= 13'd0;
      10'd104: q <= 13'd0; 10'd105: q <= 13'd0; 10'd106: q <= 13'd0; 10'd107: q <= 13'd0; 10'd108: q <= 13'd0; 10'd109: q <= 13'd0; 10'd110: q <= 13'd0; 10'd111: q <= 13'd0;
      10'd112: q <= 13'd0; 10'd113: q <= 13'd0; 10'd114: q <= 13'd0; 10'd115: q <= 13'd0; 10'd116: q <= 13'd0; 10'd117: q <= 13'd0; 10'd118: q <= 13'd0; 10'd119: q <= 13'd0;
      10'd120: q <= 13'd0; 10'd121: q <= 13'd0; 10'd122: q <= 13'd0; 10'd123: q <= 13'd0; 10'd124: q <= 13'd0; 10'd125: q <= 13'd0; 10'd126: q <= 13'd0; 10'd127: q <= 13'd0;
      10'd128: q <= 13'd0; 10'd129: q <= 13'd0; 10'd130: q <= 13'd0; 10'd131: q <= 13'd0; 10'd132: q <= 13'd0; 10'd133: q <= 13'd0; 10'd134: q <= 13'd0; 10'd135: q <= 13'd0;
      10'd136: q <= 13'd0; 10'd137: q <= 13'd0; 10'd138: q <= 13'd0; 10'd139: q <= 13'd0; 10'd140: q <= 13'd0; 10'd141: q <= 13'd0; 10'd142: q <= 13'd0; 10'd143: q <= 13'd0;
      10'd144: q <= 13'd0; 10'd145: q <= 13'd0; 10'd146: q <= 13'd0; 10'd147: q <= 13'd0; 10'd148: q <= 13'd0; 10'd149: q <= 13'd0; 10'd150: q <= 13'd0; 10'd151: q <= 13'd0;
      10'd152: q <= 13'd0; 10'd153: q <= 13'd0; 10'd154: q <= 13'd0; 10'd155: q <= 13'd0; 10'd156: q <= 13'd0; 10'd157: q <= 13'd0; 10'd158: q <= 13'd0; 10'd159: q <= 13'd0;
      10'd160: q <= 13'd0; 10'd161: q <= 13'd0; 10'd162: q <= 13'd0; 10'd163: q <= 13'd0; 10'd164: q <= 13'd0; 10'd165: q <= 13'd0; 10'd166: q <= 13'd0; 10'd167: q <= 13'd0;
      10'd168: q <= 13'd0; 10'd169: q <= 13'd0; 10'd170: q <= 13'd0; 10'd171: q <= 13'd0; 10'd172: q <= 13'd0; 10'd173: q <= 13'd0; 10'd174: q <= 13'd0; 10'd175: q <= 13'd0;
      10'd176: q <= 13'd0; 10'd177: q <= 13'd0; 10'd178: q <= 13'd0; 10'd179: q <= 13'd0; 10'd180: q <= 13'd0; 10'd181: q <= 13'd0; 10'd182: q <= 13'd0; 10'd183: q <= 13'd0;
      10'd184: q <= 13'd0; 10'd185: q <= 13'd0; 10'd186: q <= 13'd0; 10'd187: q <= 13'd0; 10'd188: q <= 13'd0; 10'd189: q <= 13'd0; 10'd190: q <= 13'd0; 10'd191: q <= 13'd0;
      10'd192: q <= 13'd0; 10'd193: q <= 13'd0; 10'd194: q <= 13'd0; 10'd195: q <= 13'd0; 10'd196: q <= 13'd0; 10'd197: q <= 13'd0; 10'd198: q <= 13'd0; 10'd199: q <= 13'd0;
      10'd200: q <= 13'd0; 10'd201: q <= 13'd0; 10'd202: q <= 13'd0; 10'd203: q <= 13'd0; 10'd204: q <= 13'd0; 10'd205: q <= 13'd0; 10'd206: q <= 13'd0; 10'd207: q <= 13'd0;
      10'd208: q <= 13'd0; 10'd209: q <= 13'd0; 10'd210: q <= 13'd0; 10'd211: q <= 13'd0; 10'd212: q <= 13'd0; 10'd213: q <= 13'd0; 10'd214: q <= 13'd0; 10'd215: q <= 13'd0;
      10'd216: q <= 13'd0; 10'd217: q <= 13'd0; 10'd218: q <= 13'd0; 10'd219: q <= 13'd0; 10'd220: q <= 13'd0; 10'd221: q <= 13'd0; 10'd222: q <= 13'd0; 10'd223: q <= 13'd0;
      10'd224: q <= 13'd0; 10'd225: q <= 13'd0; 10'd226: q <= 13'd0; 10'd227: q <= 13'd0; 10'd228: q <= 13'd0; 10'd229: q <= 13'd0; 10'd230: q <= 13'd0; 10'd231: q <= 13'd0;
      10'd232: q <= 13'd0; 10'd233: q <= 13'd0; 10'd234: q <= 13'd0; 10'd235: q <= 13'd0; 10'd236: q <= 13'd0; 10'd237: q <= 13'd0; 10'd238: q <= 13'd0; 10'd239: q <= 13'd0;
      10'd240: q <= 13'd0; 10'd241: q <= 13'd0; 10'd242: q <= 13'd0; 10'd243: q <= 13'd0; 10'd244: q <= 13'd0; 10'd245: q <= 13'd0; 10'd246: q <= 13'd0; 10'd247: q <= 13'd0;
      10'd248: q <= 13'd0; 10'd249: q <= 13'd0; 10'd250: q <= 13'd0; 10'd251: q <= 13'd0; 10'd252: q <= 13'd0; 10'd253: q <= 13'd0; 10'd254: q <= 13'd1; 10'd255: q <= 13'd1;
      10'd256: q <= 13'd1; 10'd257: q <= 13'd1; 10'd258: q <= 13'd1; 10'd259: q <= 13'd1; 10'd260: q <= 13'd1; 10'd261: q <= 13'd1; 10'd262: q <= 13'd1; 10'd263: q <= 13'd1;
      10'd264: q <= 13'd1; 10'd265: q <= 13'd1; 10'd266: q <= 13'd1; 10'd267: q <= 13'd1; 10'd268: q <= 13'd1; 10'd269: q <= 13'd1; 10'd270: q <= 13'd1; 10'd271: q <= 13'd1;
      10'd272: q <= 13'd1; 10'd273: q <= 13'd1; 10'd274: q <= 13'd1; 10'd275: q <= 13'd1; 10'd276: q <= 13'd1; 10'd277: q <= 13'd1; 10'd278: q <= 13'd1; 10'd279: q <= 13'd1;
      10'd280: q <= 13'd1; 10'd281: q <= 13'd1; 10'd282: q <= 13'd1; 10'd283: q <= 13'd1; 10'd284: q <= 13'd1; 10'd285: q <= 13'd1; 10'd286: q <= 13'd1; 10'd287: q <= 13'd1;
      10'd288: q <= 13'd1; 10'd289: q <= 13'd1; 10'd290: q <= 13'd1; 10'd291: q <= 13'd1; 10'd292: q <= 13'd1; 10'd293: q <= 13'd1; 10'd294: q <= 13'd1; 10'd295: q <= 13'd1;
      10'd296: q <= 13'd1; 10'd297: q <= 13'd1; 10'd298: q <= 13'd1; 10'd299: q <= 13'd1; 10'd300: q <= 13'd1; 10'd301: q <= 13'd1; 10'd302: q <= 13'd1; 10'd303: q <= 13'd1;
      10'd304: q <= 13'd1; 10'd305: q <= 13'd1; 10'd306: q <= 13'd1; 10'd307: q <= 13'd1; 10'd308: q <= 13'd1; 10'd309: q <= 13'd1; 10'd310: q <= 13'd1; 10'd311: q <= 13'd1;
      10'd312: q <= 13'd1; 10'd313: q <= 13'd1; 10'd314: q <= 13'd1; 10'd315: q <= 13'd1; 10'd316: q <= 13'd1; 10'd317: q <= 13'd1; 10'd318: q <= 13'd2; 10'd319: q <= 13'd2;
      10'd320: q <= 13'd2; 10'd321: q <= 13'd2; 10'd322: q <= 13'd2; 10'd323: q <= 13'd2; 10'd324: q <= 13'd2; 10'd325: q <= 13'd2; 10'd326: q <= 13'd2; 10'd327: q <= 13'd2;
      10'd328: q <= 13'd2; 10'd329: q <= 13'd2; 10'd330: q <= 13'd2; 10'd331: q <= 13'd2; 10'd332: q <= 13'd2; 10'd333: q <= 13'd2; 10'd334: q <= 13'd2; 10'd335: q <= 13'd2;
      10'd336: q <= 13'd2; 10'd337: q <= 13'd2; 10'd338: q <= 13'd2; 10'd339: q <= 13'd2; 10'd340: q <= 13'd2; 10'd341: q <= 13'd2; 10'd342: q <= 13'd2; 10'd343: q <= 13'd2;
      10'd344: q <= 13'd2; 10'd345: q <= 13'd2; 10'd346: q <= 13'd2; 10'd347: q <= 13'd2; 10'd348: q <= 13'd2; 10'd349: q <= 13'd2; 10'd350: q <= 13'd2; 10'd351: q <= 13'd2;
      10'd352: q <= 13'd2; 10'd353: q <= 13'd2; 10'd354: q <= 13'd2; 10'd355: q <= 13'd2; 10'd356: q <= 13'd3; 10'd357: q <= 13'd3; 10'd358: q <= 13'd3; 10'd359: q <= 13'd3;
      10'd360: q <= 13'd3; 10'd361: q <= 13'd3; 10'd362: q <= 13'd3; 10'd363: q <= 13'd3; 10'd364: q <= 13'd3; 10'd365: q <= 13'd3; 10'd366: q <= 13'd3; 10'd367: q <= 13'd3;
      10'd368: q <= 13'd3; 10'd369: q <= 13'd3; 10'd370: q <= 13'd3; 10'd371: q <= 13'd3; 10'd372: q <= 13'd3; 10'd373: q <= 13'd3; 10'd374: q <= 13'd3; 10'd375: q <= 13'd3;
      10'd376: q <= 13'd3; 10'd377: q <= 13'd3; 10'd378: q <= 13'd3; 10'd379: q <= 13'd3; 10'd380: q <= 13'd3; 10'd381: q <= 13'd3; 10'd382: q <= 13'd4; 10'd383: q <= 13'd4;
      10'd384: q <= 13'd4; 10'd385: q <= 13'd4; 10'd386: q <= 13'd4; 10'd387: q <= 13'd4; 10'd388: q <= 13'd4; 10'd389: q <= 13'd4; 10'd390: q <= 13'd4; 10'd391: q <= 13'd4;
      10'd392: q <= 13'd4; 10'd393: q <= 13'd4; 10'd394: q <= 13'd4; 10'd395: q <= 13'd4; 10'd396: q <= 13'd4; 10'd397: q <= 13'd4; 10'd398: q <= 13'd4; 10'd399: q <= 13'd4;
      10'd400: q <= 13'd4; 10'd401: q <= 13'd4; 10'd402: q <= 13'd4; 10'd403: q <= 13'd5; 10'd404: q <= 13'd5; 10'd405: q <= 13'd5; 10'd406: q <= 13'd5; 10'd407: q <= 13'd5;
      10'd408: q <= 13'd5; 10'd409: q <= 13'd5; 10'd410: q <= 13'd5; 10'd411: q <= 13'd5; 10'd412: q <= 13'd5; 10'd413: q <= 13'd5; 10'd414: q <= 13'd5; 10'd415: q <= 13'd5;
      10'd416: q <= 13'd5; 10'd417: q <= 13'd5; 10'd418: q <= 13'd5; 10'd419: q <= 13'd5; 10'd420: q <= 13'd6; 10'd421: q <= 13'd6; 10'd422: q <= 13'd6; 10'd423: q <= 13'd6;
      10'd424: q <= 13'd6; 10'd425: q <= 13'd6; 10'd426: q <= 13'd6; 10'd427: q <= 13'd6; 10'd428: q <= 13'd6; 10'd429: q <= 13'd6; 10'd430: q <= 13'd6; 10'd431: q <= 13'd6;
      10'd432: q <= 13'd6; 10'd433: q <= 13'd6; 10'd434: q <= 13'd7; 10'd435: q <= 13'd7; 10'd436: q <= 13'd7; 10'd437: q <= 13'd7; 10'd438: q <= 13'd7; 10'd439: q <= 13'd7;
      10'd440: q <= 13'd7; 10'd441: q <= 13'd7; 10'd442: q <= 13'd7; 10'd443: q <= 13'd7; 10'd444: q <= 13'd7; 10'd445: q <= 13'd7; 10'd446: q <= 13'd7; 10'd447: q <= 13'd8;
      10'd448: q <= 13'd8; 10'd449: q <= 13'd8; 10'd450: q <= 13'd8; 10'd451: q <= 13'd8; 10'd452: q <= 13'd8; 10'd453: q <= 13'd8; 10'd454: q <= 13'd8; 10'd455: q <= 13'd8;
      10'd456: q <= 13'd8; 10'd457: q <= 13'd9; 10'd458: q <= 13'd9; 10'd459: q <= 13'd9; 10'd460: q <= 13'd9; 10'd461: q <= 13'd9; 10'd462: q <= 13'd9; 10'd463: q <= 13'd9;
      10'd464: q <= 13'd9; 10'd465: q <= 13'd9; 10'd466: q <= 13'd9; 10'd467: q <= 13'd10; 10'd468: q <= 13'd10; 10'd469: q <= 13'd10; 10'd470: q <= 13'd10; 10'd471: q <= 13'd10;
      10'd472: q <= 13'd10; 10'd473: q <= 13'd10; 10'd474: q <= 13'd10; 10'd475: q <= 13'd10; 10'd476: q <= 13'd11; 10'd477: q <= 13'd11; 10'd478: q <= 13'd11; 10'd479: q <= 13'd11;
      10'd480: q <= 13'd11; 10'd481: q <= 13'd11; 10'd482: q <= 13'd11; 10'd483: q <= 13'd11; 10'd484: q <= 13'd12; 10'd485: q <= 13'd12; 10'd486: q <= 13'd12; 10'd487: q <= 13'd12;
      10'd488: q <= 13'd12; 10'd489: q <= 13'd12; 10'd490: q <= 13'd12; 10'd491: q <= 13'd12; 10'd492: q <= 13'd13; 10'd493: q <= 13'd13; 10'd494: q <= 13'd13; 10'd495: q <= 13'd13;
      10'd496: q <= 13'd13; 10'd497: q <= 13'd13; 10'd498: q <= 13'd14; 10'd499: q <= 13'd14; 10'd500: q <= 13'd14; 10'd501: q <= 13'd14; 10'd502: q <= 13'd14; 10'd503: q <= 13'd14;
      10'd504: q <= 13'd14; 10'd505: q <= 13'd15; 10'd506: q <= 13'd15; 10'd507: q <= 13'd15; 10'd508: q <= 13'd15; 10'd509: q <= 13'd15; 10'd510: q <= 13'd15; 10'd511: q <= 13'd16;
      10'd512: q <= 13'd16; 10'd513: q <= 13'd16; 10'd514: q <= 13'd16; 10'd515: q <= 13'd16; 10'd516: q <= 13'd17; 10'd517: q <= 13'd17; 10'd518: q <= 13'd17; 10'd519: q <= 13'd17;
      10'd520: q <= 13'd17; 10'd521: q <= 13'd17; 10'd522: q <= 13'd18; 10'd523: q <= 13'd18; 10'd524: q <= 13'd18; 10'd525: q <= 13'd18; 10'd526: q <= 13'd18; 10'd527: q <= 13'd19;
      10'd528: q <= 13'd19; 10'd529: q <= 13'd19; 10'd530: q <= 13'd19; 10'd531: q <= 13'd20; 10'd532: q <= 13'd20; 10'd533: q <= 13'd20; 10'd534: q <= 13'd20; 10'd535: q <= 13'd20;
      10'd536: q <= 13'd21; 10'd537: q <= 13'd21; 10'd538: q <= 13'd21; 10'd539: q <= 13'd21; 10'd540: q <= 13'd22; 10'd541: q <= 13'd22; 10'd542: q <= 13'd22; 10'd543: q <= 13'd22;
      10'd544: q <= 13'd23; 10'd545: q <= 13'd23; 10'd546: q <= 13'd23; 10'd547: q <= 13'd23; 10'd548: q <= 13'd24; 10'd549: q <= 13'd24; 10'd550: q <= 13'd24; 10'd551: q <= 13'd24;
      10'd552: q <= 13'd25; 10'd553: q <= 13'd25; 10'd554: q <= 13'd25; 10'd555: q <= 13'd25; 10'd556: q <= 13'd26; 10'd557: q <= 13'd26; 10'd558: q <= 13'd26; 10'd559: q <= 13'd27;
      10'd560: q <= 13'd27; 10'd561: q <= 13'd27; 10'd562: q <= 13'd27; 10'd563: q <= 13'd28; 10'd564: q <= 13'd28; 10'd565: q <= 13'd28; 10'd566: q <= 13'd29; 10'd567: q <= 13'd29;
      10'd568: q <= 13'd29; 10'd569: q <= 13'd30; 10'd570: q <= 13'd30; 10'd571: q <= 13'd30; 10'd572: q <= 13'd31; 10'd573: q <= 13'd31; 10'd574: q <= 13'd31; 10'd575: q <= 13'd32;
      10'd576: q <= 13'd32; 10'd577: q <= 13'd32; 10'd578: q <= 13'd33; 10'd579: q <= 13'd33; 10'd580: q <= 13'd33; 10'd581: q <= 13'd34; 10'd582: q <= 13'd34; 10'd583: q <= 13'd35;
      10'd584: q <= 13'd35; 10'd585: q <= 13'd35; 10'd586: q <= 13'd36; 10'd587: q <= 13'd36; 10'd588: q <= 13'd37; 10'd589: q <= 13'd37; 10'd590: q <= 13'd37; 10'd591: q <= 13'd38;
      10'd592: q <= 13'd38; 10'd593: q <= 13'd39; 10'd594: q <= 13'd39; 10'd595: q <= 13'd39; 10'd596: q <= 13'd40; 10'd597: q <= 13'd40; 10'd598: q <= 13'd41; 10'd599: q <= 13'd41;
      10'd600: q <= 13'd42; 10'd601: q <= 13'd42; 10'd602: q <= 13'd43; 10'd603: q <= 13'd43; 10'd604: q <= 13'd44; 10'd605: q <= 13'd44; 10'd606: q <= 13'd44; 10'd607: q <= 13'd45;
      10'd608: q <= 13'd45; 10'd609: q <= 13'd46; 10'd610: q <= 13'd46; 10'd611: q <= 13'd47; 10'd612: q <= 13'd47; 10'd613: q <= 13'd48; 10'd614: q <= 13'd49; 10'd615: q <= 13'd49;
      10'd616: q <= 13'd50; 10'd617: q <= 13'd50; 10'd618: q <= 13'd51; 10'd619: q <= 13'd51; 10'd620: q <= 13'd52; 10'd621: q <= 13'd52; 10'd622: q <= 13'd53; 10'd623: q <= 13'd54;
      10'd624: q <= 13'd54; 10'd625: q <= 13'd55; 10'd626: q <= 13'd55; 10'd627: q <= 13'd56; 10'd628: q <= 13'd57; 10'd629: q <= 13'd57; 10'd630: q <= 13'd58; 10'd631: q <= 13'd58;
      10'd632: q <= 13'd59; 10'd633: q <= 13'd60; 10'd634: q <= 13'd60; 10'd635: q <= 13'd61; 10'd636: q <= 13'd62; 10'd637: q <= 13'd62; 10'd638: q <= 13'd63; 10'd639: q <= 13'd64;
      10'd640: q <= 13'd64; 10'd641: q <= 13'd65; 10'd642: q <= 13'd66; 10'd643: q <= 13'd67; 10'd644: q <= 13'd67; 10'd645: q <= 13'd68; 10'd646: q <= 13'd69; 10'd647: q <= 13'd70;
      10'd648: q <= 13'd70; 10'd649: q <= 13'd71; 10'd650: q <= 13'd72; 10'd651: q <= 13'd73; 10'd652: q <= 13'd73; 10'd653: q <= 13'd74; 10'd654: q <= 13'd75; 10'd655: q <= 13'd76;
      10'd656: q <= 13'd77; 10'd657: q <= 13'd77; 10'd658: q <= 13'd78; 10'd659: q <= 13'd79; 10'd660: q <= 13'd80; 10'd661: q <= 13'd81; 10'd662: q <= 13'd82; 10'd663: q <= 13'd83;
      10'd664: q <= 13'd84; 10'd665: q <= 13'd85; 10'd666: q <= 13'd85; 10'd667: q <= 13'd86; 10'd668: q <= 13'd87; 10'd669: q <= 13'd88; 10'd670: q <= 13'd89; 10'd671: q <= 13'd90;
      10'd672: q <= 13'd91; 10'd673: q <= 13'd92; 10'd674: q <= 13'd93; 10'd675: q <= 13'd94; 10'd676: q <= 13'd95; 10'd677: q <= 13'd96; 10'd678: q <= 13'd97; 10'd679: q <= 13'd98;
      10'd680: q <= 13'd99; 10'd681: q <= 13'd101; 10'd682: q <= 13'd102; 10'd683: q <= 13'd103; 10'd684: q <= 13'd104; 10'd685: q <= 13'd105; 10'd686: q <= 13'd106; 10'd687: q <= 13'd107;
      10'd688: q <= 13'd108; 10'd689: q <= 13'd110; 10'd690: q <= 13'd111; 10'd691: q <= 13'd112; 10'd692: q <= 13'd113; 10'd693: q <= 13'd115; 10'd694: q <= 13'd116; 10'd695: q <= 13'd117;
      10'd696: q <= 13'd118; 10'd697: q <= 13'd120; 10'd698: q <= 13'd121; 10'd699: q <= 13'd122; 10'd700: q <= 13'd124; 10'd701: q <= 13'd125; 10'd702: q <= 13'd126; 10'd703: q <= 13'd128;
      10'd704: q <= 13'd129; 10'd705: q <= 13'd130; 10'd706: q <= 13'd132; 10'd707: q <= 13'd133; 10'd708: q <= 13'd135; 10'd709: q <= 13'd136; 10'd710: q <= 13'd138; 10'd711: q <= 13'd139;
      10'd712: q <= 13'd141; 10'd713: q <= 13'd142; 10'd714: q <= 13'd144; 10'd715: q <= 13'd145; 10'd716: q <= 13'd147; 10'd717: q <= 13'd149; 10'd718: q <= 13'd150; 10'd719: q <= 13'd152;
      10'd720: q <= 13'd153; 10'd721: q <= 13'd155; 10'd722: q <= 13'd157; 10'd723: q <= 13'd159; 10'd724: q <= 13'd160; 10'd725: q <= 13'd162; 10'd726: q <= 13'd164; 10'd727: q <= 13'd166;
      10'd728: q <= 13'd167; 10'd729: q <= 13'd169; 10'd730: q <= 13'd171; 10'd731: q <= 13'd173; 10'd732: q <= 13'd175; 10'd733: q <= 13'd177; 10'd734: q <= 13'd179; 10'd735: q <= 13'd180;
      10'd736: q <= 13'd182; 10'd737: q <= 13'd184; 10'd738: q <= 13'd186; 10'd739: q <= 13'd188; 10'd740: q <= 13'd191; 10'd741: q <= 13'd193; 10'd742: q <= 13'd195; 10'd743: q <= 13'd197;
      10'd744: q <= 13'd199; 10'd745: q <= 13'd201; 10'd746: q <= 13'd203; 10'd747: q <= 13'd206; 10'd748: q <= 13'd208; 10'd749: q <= 13'd210; 10'd750: q <= 13'd212; 10'd751: q <= 13'd215;
      10'd752: q <= 13'd217; 10'd753: q <= 13'd219; 10'd754: q <= 13'd222; 10'd755: q <= 13'd224; 10'd756: q <= 13'd227; 10'd757: q <= 13'd229; 10'd758: q <= 13'd231; 10'd759: q <= 13'd234;
      10'd760: q <= 13'd237; 10'd761: q <= 13'd239; 10'd762: q <= 13'd242; 10'd763: q <= 13'd244; 10'd764: q <= 13'd247; 10'd765: q <= 13'd250; 10'd766: q <= 13'd252; 10'd767: q <= 13'd255;
      10'd768: q <= 13'd258; 10'd769: q <= 13'd261; 10'd770: q <= 13'd264; 10'd771: q <= 13'd266; 10'd772: q <= 13'd269; 10'd773: q <= 13'd272; 10'd774: q <= 13'd275; 10'd775: q <= 13'd278;
      10'd776: q <= 13'd281; 10'd777: q <= 13'd284; 10'd778: q <= 13'd287; 10'd779: q <= 13'd291; 10'd780: q <= 13'd294; 10'd781: q <= 13'd297; 10'd782: q <= 13'd300; 10'd783: q <= 13'd303;
      10'd784: q <= 13'd307; 10'd785: q <= 13'd310; 10'd786: q <= 13'd313; 10'd787: q <= 13'd317; 10'd788: q <= 13'd320; 10'd789: q <= 13'd324; 10'd790: q <= 13'd327; 10'd791: q <= 13'd331;
      10'd792: q <= 13'd334; 10'd793: q <= 13'd338; 10'd794: q <= 13'd342; 10'd795: q <= 13'd345; 10'd796: q <= 13'd349; 10'd797: q <= 13'd353; 10'd798: q <= 13'd357; 10'd799: q <= 13'd361;
      10'd800: q <= 13'd365; 10'd801: q <= 13'd369; 10'd802: q <= 13'd373; 10'd803: q <= 13'd377; 10'd804: q <= 13'd381; 10'd805: q <= 13'd385; 10'd806: q <= 13'd389; 10'd807: q <= 13'd393;
      10'd808: q <= 13'd397; 10'd809: q <= 13'd402; 10'd810: q <= 13'd406; 10'd811: q <= 13'd411; 10'd812: q <= 13'd415; 10'd813: q <= 13'd420; 10'd814: q <= 13'd424; 10'd815: q <= 13'd429;
      10'd816: q <= 13'd433; 10'd817: q <= 13'd438; 10'd818: q <= 13'd443; 10'd819: q <= 13'd448; 10'd820: q <= 13'd453; 10'd821: q <= 13'd457; 10'd822: q <= 13'd462; 10'd823: q <= 13'd467;
      10'd824: q <= 13'd472; 10'd825: q <= 13'd478; 10'd826: q <= 13'd483; 10'd827: q <= 13'd488; 10'd828: q <= 13'd493; 10'd829: q <= 13'd499; 10'd830: q <= 13'd504; 10'd831: q <= 13'd510;
      10'd832: q <= 13'd515; 10'd833: q <= 13'd521; 10'd834: q <= 13'd526; 10'd835: q <= 13'd532; 10'd836: q <= 13'd538; 10'd837: q <= 13'd544; 10'd838: q <= 13'd550; 10'd839: q <= 13'd556;
      10'd840: q <= 13'd562; 10'd841: q <= 13'd568; 10'd842: q <= 13'd574; 10'd843: q <= 13'd580; 10'd844: q <= 13'd586; 10'd845: q <= 13'd593; 10'd846: q <= 13'd599; 10'd847: q <= 13'd606;
      10'd848: q <= 13'd612; 10'd849: q <= 13'd619; 10'd850: q <= 13'd626; 10'd851: q <= 13'd633; 10'd852: q <= 13'd639; 10'd853: q <= 13'd646; 10'd854: q <= 13'd653; 10'd855: q <= 13'd660;
      10'd856: q <= 13'd668; 10'd857: q <= 13'd675; 10'd858: q <= 13'd682; 10'd859: q <= 13'd690; 10'd860: q <= 13'd697; 10'd861: q <= 13'd705; 10'd862: q <= 13'd712; 10'd863: q <= 13'd720;
      10'd864: q <= 13'd728; 10'd865: q <= 13'd736; 10'd866: q <= 13'd744; 10'd867: q <= 13'd752; 10'd868: q <= 13'd760; 10'd869: q <= 13'd768; 10'd870: q <= 13'd777; 10'd871: q <= 13'd785;
      10'd872: q <= 13'd794; 10'd873: q <= 13'd802; 10'd874: q <= 13'd811; 10'd875: q <= 13'd820; 10'd876: q <= 13'd829; 10'd877: q <= 13'd838; 10'd878: q <= 13'd847; 10'd879: q <= 13'd856;
      10'd880: q <= 13'd865; 10'd881: q <= 13'd875; 10'd882: q <= 13'd884; 10'd883: q <= 13'd894; 10'd884: q <= 13'd903; 10'd885: q <= 13'd913; 10'd886: q <= 13'd923; 10'd887: q <= 13'd933;
      10'd888: q <= 13'd943; 10'd889: q <= 13'd953; 10'd890: q <= 13'd964; 10'd891: q <= 13'd974; 10'd892: q <= 13'd985; 10'd893: q <= 13'd996; 10'd894: q <= 13'd1006; 10'd895: q <= 13'd1017;
      10'd896: q <= 13'd1028; 10'd897: q <= 13'd1040; 10'd898: q <= 13'd1051; 10'd899: q <= 13'd1062; 10'd900: q <= 13'd1074; 10'd901: q <= 13'd1085; 10'd902: q <= 13'd1097; 10'd903: q <= 13'd1109;
      10'd904: q <= 13'd1121; 10'd905: q <= 13'd1133; 10'd906: q <= 13'd1146; 10'd907: q <= 13'd1158; 10'd908: q <= 13'd1171; 10'd909: q <= 13'd1183; 10'd910: q <= 13'd1196; 10'd911: q <= 13'd1209;
      10'd912: q <= 13'd1222; 10'd913: q <= 13'd1236; 10'd914: q <= 13'd1249; 10'd915: q <= 13'd1263; 10'd916: q <= 13'd1276; 10'd917: q <= 13'd1290; 10'd918: q <= 13'd1304; 10'd919: q <= 13'd1318;
      10'd920: q <= 13'd1333; 10'd921: q <= 13'd1347; 10'd922: q <= 13'd1362; 10'd923: q <= 13'd1376; 10'd924: q <= 13'd1391; 10'd925: q <= 13'd1407; 10'd926: q <= 13'd1422; 10'd927: q <= 13'd1437;
      10'd928: q <= 13'd1453; 10'd929: q <= 13'd1469; 10'd930: q <= 13'd1485; 10'd931: q <= 13'd1501; 10'd932: q <= 13'd1517; 10'd933: q <= 13'd1533; 10'd934: q <= 13'd1550; 10'd935: q <= 13'd1567;
      10'd936: q <= 13'd1584; 10'd937: q <= 13'd1601; 10'd938: q <= 13'd1618; 10'd939: q <= 13'd1636; 10'd940: q <= 13'd1654; 10'd941: q <= 13'd1672; 10'd942: q <= 13'd1690; 10'd943: q <= 13'd1708;
      10'd944: q <= 13'd1727; 10'd945: q <= 13'd1746; 10'd946: q <= 13'd1764; 10'd947: q <= 13'd1784; 10'd948: q <= 13'd1803; 10'd949: q <= 13'd1823; 10'd950: q <= 13'd1842; 10'd951: q <= 13'd1862;
      10'd952: q <= 13'd1883; 10'd953: q <= 13'd1903; 10'd954: q <= 13'd1924; 10'd955: q <= 13'd1945; 10'd956: q <= 13'd1966; 10'd957: q <= 13'd1987; 10'd958: q <= 13'd2009; 10'd959: q <= 13'd2030;
      10'd960: q <= 13'd2052; 10'd961: q <= 13'd2075; 10'd962: q <= 13'd2097; 10'd963: q <= 13'd2120; 10'd964: q <= 13'd2143; 10'd965: q <= 13'd2166; 10'd966: q <= 13'd2190; 10'd967: q <= 13'd2213;
      10'd968: q <= 13'd2237; 10'd969: q <= 13'd2262; 10'd970: q <= 13'd2286; 10'd971: q <= 13'd2311; 10'd972: q <= 13'd2336; 10'd973: q <= 13'd2362; 10'd974: q <= 13'd2387; 10'd975: q <= 13'd2413;
      10'd976: q <= 13'd2439; 10'd977: q <= 13'd2466; 10'd978: q <= 13'd2493; 10'd979: q <= 13'd2520; 10'd980: q <= 13'd2547; 10'd981: q <= 13'd2575; 10'd982: q <= 13'd2603; 10'd983: q <= 13'd2631;
      10'd984: q <= 13'd2659; 10'd985: q <= 13'd2688; 10'd986: q <= 13'd2717; 10'd987: q <= 13'd2747; 10'd988: q <= 13'd2777; 10'd989: q <= 13'd2807; 10'd990: q <= 13'd2837; 10'd991: q <= 13'd2868;
      10'd992: q <= 13'd2899; 10'd993: q <= 13'd2931; 10'd994: q <= 13'd2963; 10'd995: q <= 13'd2995; 10'd996: q <= 13'd3027; 10'd997: q <= 13'd3060; 10'd998: q <= 13'd3093; 10'd999: q <= 13'd3127;
      10'd1000: q <= 13'd3161; 10'd1001: q <= 13'd3195; 10'd1002: q <= 13'd3230; 10'd1003: q <= 13'd3265; 10'd1004: q <= 13'd3300; 10'd1005: q <= 13'd3336; 10'd1006: q <= 13'd3372; 10'd1007: q <= 13'd3409;
      10'd1008: q <= 13'd3446; 10'd1009: q <= 13'd3483; 10'd1010: q <= 13'd3521; 10'd1011: q <= 13'd3559; 10'd1012: q <= 13'd3598; 10'd1013: q <= 13'd3637; 10'd1014: q <= 13'd3676; 10'd1015: q <= 13'd3716;
      10'd1016: q <= 13'd3757; 10'd1017: q <= 13'd3797; 10'd1018: q <= 13'd3839; 10'd1019: q <= 13'd3880; 10'd1020: q <= 13'd3922; 10'd1021: q <= 13'd3965; 10'd1022: q <= 13'd4008; 10'd1023: q <= 13'd4052;
    default: q <= 13'd0;
    endcase
end
endmodule
