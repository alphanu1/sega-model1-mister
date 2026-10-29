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
// THE DSB'S MPEG SIDE: its port registers (e0-e9) and an MPEG-1 Layer II
// decoder, for Star Wars Arcade's Digital Sound Board.
//
// The reference is MAME: dsbz80.cpp for the registers and the play/loop/stop
// semantics, mpeg_audio.cpp for the decode. MAME decodes in doubles, so this
// is bit-exact against tools/dsb/dsb_fixmodel.h (24-bit samples, the widths
// Ben chose) and that model is within 1 LSB of MAME on every song
// (docs/findings.md, 2026-10-28 (c)).
//
// ONE FORMAT. All 7,281 frames in mpr-16514/16515 are MPEG-1 Layer II,
// 32 kHz, 128 kbit/s, stereo, no CRC -- allocation table 0, 27 subbands. The
// header's bitrate, rate and mode fields are therefore read and ignored, and
// the decoder always decodes table-0 stereo. The CRC flag is honoured, because
// it changes where the data starts.
//
// SMALL BY BEING SLOW. Output is 32 kHz; clk is ~29.5 MHz, so there are ~920
// cycles per stereo sample against ~90 needed. Everything is serial:
//   - the bitstream is read one bit per cycle from a one-word buffer;
//   - ONE multiplier (a DSP) and one 48-bit accumulator do every product:
//     requantisation (two per value), the 32-point matrixing and the window;
//   - the tables live in M10K: the window (512 x 18) in one, cos / scale
//     factor / requantisation constants and the 64-sample output FIFO in a
//     second, the side information and one granule's samples in a third, and
//     the 2 x 512 synthesis history in three (1,024 x 24).
//
// MAME's control flow, reproduced because it decides WHICH samples play:
//   - the sync scan is bit by bit, and resumes from where a frame's DATA
//     ended, not from the frame length;
//   - a frame whose data would cross the end address is dropped whole; on that
//     failure a looping stream restarts at the latched loop start (and takes
//     the latched loop end), and a non-looping one stops;
//   - the synthesis history is never cleared, between songs or on reset (it is
//     an M10K, zero from configuration, exactly as MAME's is zero from
//     construction);
//   - writes to start/end while playing go to the LOOP registers.
// Divergence, on purpose: MAME decodes a whole 1,152-sample frame before
// playing it; this is at most two 32-sample steps ahead. A play trigger that
// lands in the last 64 samples of a frame can therefore take effect one frame
// later than in MAME. The firmware always stops before it plays, which flushes,
// so the case does not arise from it.

`timescale 1ns/1ps

module dsb_mpeg #(
  // 32 kHz from clk, as a fraction: clk_cpu is 560/19 MHz, so 32 kHz is
  // 19 / 17,500 of it, exactly.
  parameter int unsigned TICK_NUM = 19,
  parameter int unsigned TICK_DEN = 17500
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- the Z80's ports 0xe0-0xe9, low nibble
  input  logic        reg_we,
  input  logic  [3:0] reg_a,
  input  logic  [7:0] reg_d,
  output logic  [7:0] reg_q,      // 0xe2-0xe4 read the play position
  // 1 = every write to 0xe8 is the volume, as MAME has it. 0 = a write with
  // bit 7 set is NOT the volume (see the note at the register).
  input  logic        vol_mame,

  // ---- the MPEG data, 16-bit words of the 4 MB region, little-endian bytes
  output logic        m_req,
  output logic [20:0] m_addr,
  input  logic        m_ack,
  input  logic [15:0] m_data,

  // ---- 32 kHz output, volume and pan applied
  output wire  signed [15:0] out_l,
  output wire  signed [15:0] out_r,
  output logic        out_stb,
  output logic        out_src,     // this out_stb came from the FIFO (else silence)

  // ---- for the benches: every decoded stereo sample as the FIFO takes it
  output logic        smp_stb,
  output logic [31:0] smp_lr,
  output logic [15:0] dbg_frames,
  output logic [15:0] dbg_fails
);

  // ================================================================ registers
  // dsbz80.cpp. m_start/m_end assemble byte by byte; the low byte commits to
  // mp_* when stopped and to lp_* while playing.
  logic [23:0] st_r, en_r, mp_start, mp_end, lp_start, lp_end;
  logic  [7:0] mp_state;
  logic  [6:0] vol;
  logic  [1:0] pan;
  logic [26:0] mp_pos;             // bit position
  logic        pos_set;            // a trigger moved mp_pos during this frame
  logic        stop_now;           // e0 <- 0: flush and abort

  // ================================================================ memories
  // Window, 512 x 18, read-only.
  (* ramstyle = "M10K" *) logic [17:0] win [512];
  // cos / scale factor / C, read-only (0..145).
  (* ramstyle = "M10K" *) logic [31:0] misc [256];
  // The output FIFO, 64 stereo samples. Its own block: a 32-bit port beside a
  // table port would make `misc` true-dual-port, which M10K does only to x20.
  // Each half written by its own channel's result: byte enables, no holding
  // register for the left sample.
  (* ramstyle = "M10K" *) logic [1:0][15:0] fifo [64];
`include "dsb_tables.svh"
  // Side information at t = 3 ({class, scfsi, scf0, scf1, scf2}) and one
  // granule's requantised samples at t = 0..2, addressed {ch, t, sb}.
  (* ramstyle = "M10K" *) logic [24:0] wram [256];
  // The synthesis history, {ch, 9-bit ring index}.
  (* ramstyle = "M10K" *) logic [23:0] vram [1024];

  logic  [8:0] win_a;   logic [17:0] win_q;
  logic  [7:0] misc_a;  logic [31:0] misc_q;
  logic [1:0][15:0] fifo_q;
  logic  [7:0] wram_a;  logic [24:0] wram_q, wram_d;  logic wram_we;
  logic  [9:0] vram_a;  logic [23:0] vram_q;  wire vram_we;

  always_ff @(posedge clk) win_q <= win[win_a];
  always_ff @(posedge clk) misc_q <= misc[misc_a];
  // written straight from the window's result in S_WN_O; read on a pop only,
  // so its output register holds the sample being played.
  wire fifo_we_l, fifo_we_r;
  always_ff @(posedge clk) begin
    if (fifo_we_l) fifo[f_wp][1] <= o_sat;
    if (fifo_we_r) fifo[f_wp][0] <= o_sat;
    if (f_pop) fifo_q <= fifo[f_rp];
  end
  always_ff @(posedge clk) begin
    if (wram_we) wram[wram_a] <= wram_d;
    wram_q <= wram[wram_a];
  end
`ifdef DSB_TRACE
  always_ff @(posedge clk) begin
    if (vram_we) $display("V %0d %0d %0d", vram_a[9], vram_a[8:0], $signed(v_sat));
    if (wram_we && wram_a[6:5] == 2'd3) $display("P %0d %0d %0d %0d %0d %0d %0d", wram_a[7], wram_a[4:0], wram_d[24:20], wram_d[19:18], wram_d[17:12], wram_d[11:6], wram_d[5:0]);
    if (wram_we && wram_a[6:5] != 2'd3) $display("S %0d %0d %0d %0d", wram_a[7], wram_a[6:5], wram_a[4:0], $signed(wram_d[23:0]));
  end
`endif
  always_ff @(posedge clk) begin
    if (vram_we) vram[vram_a] <= v_sat;
    vram_q <= vram[vram_a];
  end

  // ================================================================ bit reader
  // One 16-bit word buffered. Bytes are little-endian in the word (the loader
  // writes ioctl's byte pairs that way); bits are MSB-first within a byte.
  // No address tag: the word is dropped when the position leaves it, and a
  // fetch in flight when the position is reloaded comes back stale.
  //
  // remb = limit - rd_pos, the bits left before the frame's end, kept as a
  // down-counter beside rd_pos so every limit test is a sign or a small
  // compare. The limit is LATCHED per frame: the firmware stops, writes a new
  // end and plays while a stopped frame is still being finished muted (see
  // `mute`), and that frame must keep the end it started with, as in MAME.
  logic [26:0] rd_pos;
  logic signed [27:0] remb;
  logic [15:0] wbuf;
  logic        wvalid, stale;
  wire         whit    = wvalid;
  wire         cur_bit = wbuf[{rd_pos[3], ~rd_pos[2:0]}];
  wire         w_issue = !m_req && !wvalid;
  wire signed [27:0] start_rem = $signed({1'b0, mp_end, 3'b000}) - $signed({1'b0, mp_pos});
  wire         rem_le0  = remb[27] || (remb == 28'sd0);          // rd_pos >= limit
  wire         rem_lem3 = remb[27] && !(&remb[27:1]);            // rd_pos >= limit + 3

  // ================================================================ tables
  // nbal and the class mapping for allocation table 0.
  function automatic logic [2:0] nbal(input logic [4:0] sb);
    nbal = (sb < 5'd11) ? 3'd4 : (sb < 5'd23) ? 3'd3 : 3'd2;
  endfunction
  function automatic logic [4:0] cls(input logic [4:0] sb, input logic [3:0] idx);
    if (sb < 5'd3)       cls = (idx < 4'd2) ? 5'(idx) : (idx == 4'd2) ? 5'd3 : 5'(idx) + 5'd2;
    else if (sb < 5'd11) cls = (idx == 4'd15) ? 5'd17 : 5'(idx);
    else if (sb < 5'd23) cls = (idx == 4'd7)  ? 5'd17 : 5'(idx);
    else                 cls = (idx == 4'd3)  ? 5'd17 : 5'(idx);
  endfunction
  // Per class: sample bits b, grouped, bits of a grouped code, its modulus,
  // the addend that centres a value (see requantise), and 12 x the bits one
  // granule spends on a triplet of this class.
  logic [4:0] c_class;
  logic [4:0] c_bits;  logic c_grp;  logic [3:0] c_cube;  logic [3:0] c_mod;
  logic [2:0] c_add;   logic [9:0] c_g12;
  always_comb begin
    c_grp = 1'b0; c_cube = 4'd0; c_mod = 4'd0; c_add = 3'd1;
    case (c_class)
      5'd0:  c_bits = 5'd0;
      5'd1:  begin c_bits = 5'd2; c_grp = 1'b1; c_cube = 4'd5;  c_mod = 4'd3; c_add = 3'd1; end
      5'd2:  begin c_bits = 5'd3; c_grp = 1'b1; c_cube = 4'd7;  c_mod = 4'd5; c_add = 3'd2; end
      5'd3:  c_bits = 5'd3;
      5'd4:  begin c_bits = 5'd4; c_grp = 1'b1; c_cube = 4'd10; c_mod = 4'd9; c_add = 3'd4; end
      default: c_bits = c_class - 5'd1;      // 5 -> 4 bits ... 17 -> 16 bits
    endcase
    c_g12 = (c_class == 5'd0) ? 10'd0 : c_grp ? 10'(c_cube) * 10'd12 : 10'(c_bits) * 10'd36;
  end

  // ================================================================ MAC
  // acc <= (load ? base : acc) +/- A * B. A MAC is ISSUED in the same cycle
  // as its memory addresses; the address registers reach the RAMs the next
  // cycle and their registered outputs are valid the cycle after, so the
  // controls travel two stages (p_* then q_*) and the product is taken then.
  logic signed [47:0] acc;
  logic        p_en, p_load, p_sub, p_rnd;
  logic  [1:0] p_asel;              // 0 Nal, 1 p1, 2 wram (S), 3 vram (V)
  logic        p_bsel;              // 0 misc, 1 window
  logic        p_neg_b;             // cos with k[6] set
  logic signed [23:0] ma;
  logic signed [24:0] mb, mbn;
  logic        q_en, q_load, q_sub, q_rnd, q_bsel, q_neg_b;
  logic  [1:0] q_asel;
  always_ff @(posedge clk) begin
    q_en <= p_en; q_load <= p_load; q_sub <= p_sub; q_rnd <= p_rnd;
    q_asel <= p_asel; q_bsel <= p_bsel; q_neg_b <= p_neg_b;
  end
  wire mac_busy = p_en || q_en;
  always_comb begin
    case (q_asel)
      2'd0: ma = {{7{x16m2[1]}}, x16m2, x[14:0]};     // Nal = x - 2^15
      2'd1: ma = acc[32:9];                            // p1 = (Nal x C) >> 9
      2'd2: ma = wram_q[23:0];
      default: ma = vram_q;
    endcase
    mb  = q_bsel ? {{7{win_q[17]}}, win_q} : $signed(misc_q[24:0]);
    mbn = (q_sub ^ q_neg_b) ? -mb : mb;
  end
  // In this exact shape -- operand muxes, the negation on one operand, a
  // constant load -- Quartus puts the accumulator inside the DSP block.
  always_ff @(posedge clk) begin
    if (q_en)
      acc <= (q_load ? (q_rnd ? 48'sd131072 : 48'sd0) : acc) + ma * mbn;
  end

  // V = sat24(acc >>> 20); output = round-half-up-toward-zero of acc / 2^18
  // with the 2^17 already loaded (MAME: int(x*32768 + 0.5)), clamped.
  wire [27:0] v_hi = acc[47:20];
  wire signed [23:0] v_sat = (v_hi[27:23] == 5'b00000 || v_hi[27:23] == 5'b11111)
                             ? v_hi[23:0] : (v_hi[27] ? 24'sh800000 : 24'sh7fffff);
  // Only acc[34:18] can land in range; the rest must be its sign extension.
  wire        o_hi_ok = (acc[47:34] == {14{acc[47]}});
  wire [17:0] o_q18   = {acc[34], acc[34:18]} + 18'((acc[47] && acc[17:0] != 18'd0) ? 1 : 0);
  wire        o_ok    = o_hi_ok && (o_q18[17:15] == {3{o_q18[17]}});
  wire signed [15:0] o_sat = o_ok ? o_q18[15:0] : (acc[47] ? 16'sh8000 : 16'sh7fff);

  // ================================================================ FIFO
  logic [5:0] f_wp, f_rp;
  logic [6:0] f_cnt;
  logic       f_push, f_pop;

  // ================================================================ sequencer
  typedef enum logic [5:0] {
    S_IDLE, S_START, S_SCAN0, S_SCAN, S_HDR, S_CRC,
    S_ALLOC, S_SFSI_R, S_SFSI_D, S_SFSI_W, S_SCF_R, S_SCF_D, S_SCF_G, S_SCF_W,
    S_CHECK, S_GR_R, S_GR_D, S_GR_Z, S_GR_V, S_GR_DIV, S_GR_X, S_GR_AL,
    S_RQ1W, S_RQ2W, S_NEXT, S_W1,
    S_SY_WAIT, S_ID_RUN, S_ID_DR, S_ID_W, S_WN_RUN, S_WN_DR, S_WN_O,
    S_STEP_END, S_DONE, S_FAIL, S_GB
  } st_t;
  st_t st, ret, wnext;

  // get-bits: gb_n bits into gb_v, checking the limit, then back to `ret`.
  logic  [4:0] gb_n;
  logic [15:0] gb_v;

  logic        prot;
  logic  [4:0] sb;  logic ch;  logic [1:0] t;  logic [3:0] gr;
  logic  [4:0] ii;  logic [4:0] jj; logic [3:0] kk; logic [6:0] ck;
  logic  [3:0] slot;               // ring position, in 32-word slots
  logic [14:0] g12;                // 12 x the data bits of one granule
  logic [24:0] prm;                // the side-information word being built
  logic  [1:0] fld;                // scale-factor field counter
  logic  [5:0] f0, f1;
  logic  [9:0] code;               // a grouped code, then its quotient
  logic  [3:0] rem;
  logic  [3:0] dcnt;               // restoring division, quotient shifts into `code`
  logic [16:0] x;                  // value + addend, then aligned
  wire  [1:0] x16m2 = x[16:15] - 2'd1;
  logic  [4:0] alc;
  logic  [5:0] scf_cur;
  logic signed [15:0] o_l;
  // A STOP DOES NOT UNDO SYNTHESIS. MAME decodes a whole frame before it
  // plays it, so when a stop lands, the frame playing has already advanced
  // the synthesis history to its end. To leave the same history behind, a
  // frame whose synthesis has begun is finished MUTED -- matrixing only, no
  // window, nothing pushed -- and one that has not begun is abandoned.
  logic        synth_begun, mute;

  // the side-information word's fields
  wire [4:0] w_class = wram_q[24:20];
  wire [5:0] w_s0 = wram_q[17:12], w_s1 = wram_q[11:6], w_s2 = wram_q[5:0];

  // the allocation index, gb_v holding exactly nbal(sb) bits (it is cleared
  // on every entry to S_GB)
  wire [3:0] idx_m = gb_v[3:0];
  wire [1:0] part = (gr < 4'd4) ? 2'd0 : (gr < 4'd8) ? 2'd1 : 2'd2;

  // window term addressing: term 1 (kk[0]=0) and term 2 (kk[0]=1) of tap kk[3:1]
  wire        i_le16 = (ii <= 5'd16);
  wire  [5:0] i32m   = 6'd32 - 6'(ii);
  wire  [8:0] tap    = {kk[3:1], 6'd0};
  wire  [5:0] v_off  = (kk[0] ^ i_le16) ? 6'(ii) : i32m;   // term1: i<=16 ? i : 32-i
  wire  [8:0] w_off  = kk[0] ? 9'(6'd32 + 6'(ii)) : 9'(ii);
  wire        w_sub  = kk[0] ? 1'b1 : !(ii < 5'd16);

  // positions

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; ret <= S_IDLE;
      st_r <= '0; en_r <= '0; mp_start <= '0; mp_end <= '0;
      lp_start <= '0; lp_end <= '0; mp_state <= '0; vol <= 7'h7f; pan <= '0;
      mp_pos <= '0; pos_set <= 1'b0; stop_now <= 1'b0;
      rd_pos <= '0; remb <= '0; slot <= '0;
      m_req <= 1'b0; m_addr <= '0; wbuf <= '0; wvalid <= 1'b0; stale <= 1'b0;
      p_en <= 1'b0; p_load <= 1'b0; p_sub <= 1'b0; p_rnd <= 1'b0;
      p_asel <= '0; p_bsel <= 1'b0; p_neg_b <= 1'b0;
      wram_we <= 1'b0;
      f_push <= 1'b0; dbg_frames <= '0; dbg_fails <= '0;
      synth_begun <= 1'b0; mute <= 1'b0;
      smp_stb <= 1'b0; smp_lr <= '0;
    end else begin
      p_en <= 1'b0; wram_we <= 1'b0;
      f_push <= 1'b0; smp_stb <= 1'b0; stop_now <= 1'b0;

      // ------------------------------------------------------- word fetch
      // Held until acknowledged: the SDRAM port's rule.
      if (w_issue) begin m_req <= 1'b1; m_addr <= rd_pos[24:4]; stale <= 1'b0; end
      if (m_req && m_ack) begin
        m_req <= 1'b0;
        if (!stale) begin wbuf <= m_data; wvalid <= 1'b1; end
      end

      // ------------------------------------------------------- port writes
      if (reg_we) begin
        case (reg_a)
          4'h0: begin
            mp_state <= reg_d;
            if (reg_d == 8'd0) stop_now <= 1'b1;
            else if (reg_d == 8'd1 || reg_d == 8'd2) begin
              mp_pos  <= {mp_start, 3'b000};
              pos_set <= 1'b1;
            end
          end
          4'h2: st_r[23:16] <= reg_d;
          4'h3: st_r[15:8]  <= reg_d;
          4'h4: begin
            st_r[7:0] <= reg_d;
            if (mp_state == 8'd0) mp_start <= {st_r[23:8], reg_d};
            else                  lp_start <= {st_r[23:8], reg_d};
          end
          4'h5: en_r[23:16] <= reg_d;
          4'h6: en_r[15:8]  <= reg_d;
          4'h7: begin
            en_r[7:0] <= reg_d;
            if (mp_state == 8'd0) mp_end <= {en_r[23:8], reg_d};
            else                  lp_end <= {en_r[23:8], reg_d};
          end
          // THE VOLUME QUIRK. The firmware writes 0x80 and then 0xc5 after
          // every volume it sets, and 0xc4 every 256 passes of its main loop.
          // MAME takes all of them as volume (~d & 0x7f), which pins the music
          // at 0x3b/0x7f nearly all the time and makes the firmware's fades
          // and per-song levels inaudible. The firmware masks every level it
          // computes with 0x7e, so bit 7 is never set in a real level; read
          // that way, bit-7 writes are some other control and are not volume.
          // vol_mame selects MAME's behaviour.
          4'h8: if (vol_mame || !reg_d[7]) vol <= ~reg_d[6:0];
          4'h9: pan <= reg_d[1:0];
          default: ;
        endcase
      end

      // ------------------------------------------------------- sequencer
      // A write to e0 decides the cycle: a stop aborts at once, and a play
      // holds the sequencer so that nothing it does this cycle (S_START,
      // S_DONE, S_FAIL) can overwrite the position the write sets.
      if (reg_we && reg_a == 4'h0) begin
        if (reg_d == 8'd0) begin
          if (synth_begun) mute <= 1'b1;
          else st <= S_IDLE;
        end
      end else case (st)
        S_IDLE: if (mp_state != 8'd0) st <= S_START;

        S_START: begin
          // decode_buffer(): limit - pos < 16 fails before anything is read.
          rd_pos  <= mp_pos;
          remb    <= start_rem;
          wvalid  <= 1'b0;
          if (m_req || w_issue) stale <= 1'b1;
          synth_begun <= 1'b0;
          pos_set <= 1'b0;
          if (start_rem < 28'sd16)
            st <= S_FAIL;
          else begin
            gb_n <= 5'd15; ret <= S_SCAN0; st <= S_SCAN;   // first 15 bits, unchecked
            gb_v <= '0;
          end
        end

        // The scan, as a 15-bit window over bits [c-12, c+2] with
        // rd_pos = c + 3 (see docs/findings.md for the derivation from
        // decode_buffer's loop). During the first 15 reads gb_n counts down.
        S_SCAN: if (whit) begin
          gb_v   <= {gb_v[14:0], cur_bit};    // gb_v[14:0] is the scan window
          rd_pos <= rd_pos + 27'd1; remb <= remb - 28'sd1;
          if (rd_pos[3:0] == 4'hf) wvalid <= 1'b0;
          if (gb_n != 5'd0) gb_n <= gb_n - 5'd1;
          if (gb_n == 5'd1) st <= S_SCAN0;
        end
        S_SCAN0: begin
          if (gb_v[14:3] == 12'hfff) begin
            if (rem_le0)                      st <= S_FAIL;
            else if (gb_v[2:0] == 3'b110)    begin gb_n <= 5'd17; ret <= S_HDR; st <= S_GB; gb_v <= '0; end
            else                              begin gb_n <= 5'd1; st <= S_SCAN; end
          end else begin
            if (rem_lem3)                     st <= S_FAIL;
            else                              begin gb_n <= 5'd1; st <= S_SCAN; end
          end
        end

        S_HDR: begin
          // gb_v[16] would be prot: 17 bits read, MSB first, into 16 -- so
          // prot is captured on the way in (see S_GB) as `prot`.
          if (!prot) begin gb_n <= 5'd16; ret <= S_CRC; st <= S_GB; gb_v <= '0; end
          else       st <= S_CRC;
          sb <= 5'd0; ch <= 1'b0; g12 <= '0;
        end
        S_CRC: begin
          gb_n <= 5'(nbal(5'd0)); ret <= S_ALLOC; st <= S_GB; gb_v <= '0;
        end

        // ---- allocation: sb 0..26, ch 0..1
        S_ALLOC: begin
          wram_we <= 1'b1;
          wram_a  <= {ch, 2'd3, sb};
          wram_d  <= {cls(sb, idx_m), 20'd0};
          g12     <= g12 + 15'(c_g12);
          if (ch) begin
            ch <= 1'b0;
            if (sb == 5'd26) begin sb <= 5'd0; st <= S_SFSI_R; end
            else begin sb <= sb + 5'd1; gb_n <= 5'(nbal(sb + 5'd1)); ret <= S_ALLOC; st <= S_GB; gb_v <= '0; end
          end else begin
            ch <= 1'b1; gb_n <= 5'(nbal(sb)); ret <= S_ALLOC; st <= S_GB; gb_v <= '0;
          end
        end

        // ---- scfsi, then scale factors: read the side word, fill, write back
        S_SFSI_R: begin wram_a <= {ch, 2'd3, sb}; wnext <= S_SFSI_D; st <= S_W1; end
        S_SFSI_D: begin
          prm <= wram_q;
          if (w_class != 5'd0) begin gb_n <= 5'd2; ret <= S_SFSI_W; st <= S_GB; gb_v <= '0; end
          else st <= S_SFSI_W;
        end
        S_SFSI_W: begin
          if (prm[24:20] != 5'd0) begin
            wram_we <= 1'b1; wram_d <= {prm[24:20], gb_v[1:0], 18'd0};
          end
          if (ch) begin
            ch <= 1'b0;
            if (sb == 5'd26) begin sb <= 5'd0; st <= S_SCF_R; end
            else begin sb <= sb + 5'd1; st <= S_SFSI_R; end
          end else begin ch <= 1'b1; st <= S_SFSI_R; end
        end

        S_SCF_R: begin wram_a <= {ch, 2'd3, sb}; wnext <= S_SCF_D; st <= S_W1; end
        S_SCF_D: begin
          prm <= wram_q; fld <= 2'd0;
          if (w_class != 5'd0) begin gb_n <= 5'd6; ret <= S_SCF_G; st <= S_GB; gb_v <= '0; end
          else st <= S_SCF_W;
        end
        S_SCF_G: begin
          // fields per scfsi: 0 -> 3, 1 -> 2, 2 -> 1, 3 -> 2
          if (fld == 2'd0) f0 <= gb_v[5:0];
          if (fld == 2'd1) f1 <= gb_v[5:0];
          if ((prm[19:18] == 2'd2) ||
              (prm[19:18] != 2'd0 && fld == 2'd1) || (fld == 2'd2)) begin
            st <= S_SCF_W;
          end else begin
            fld <= fld + 2'd1; gb_n <= 5'd6; ret <= S_SCF_G; st <= S_GB; gb_v <= '0;
          end
        end
        S_SCF_W: begin
          if (prm[24:20] != 5'd0) begin
            wram_we <= 1'b1;
            case (prm[19:18])
              2'd0: wram_d <= {prm[24:18], f0, f1, gb_v[5:0]};
              2'd1: wram_d <= {prm[24:18], f0, f0, gb_v[5:0]};
              2'd2: wram_d <= {prm[24:18], gb_v[5:0], gb_v[5:0], gb_v[5:0]};
              2'd3: wram_d <= {prm[24:18], f0, gb_v[5:0], gb_v[5:0]};
            endcase
          end
          if (ch) begin
            ch <= 1'b0;
            if (sb == 5'd26) begin sb <= 5'd0; st <= S_CHECK; end
            else begin sb <= sb + 5'd1; st <= S_SCF_R; end
          end else begin ch <= 1'b1; st <= S_SCF_R; end
        end

        // ---- a frame whose data crosses the end is NOT heard, but MAME
        // synthesises its granules one at a time as it reads them, so every
        // granule that fits still advances the history before the read that
        // crosses the end fails the frame. Same here: decode it muted.
        S_CHECK: begin
          gr <= 4'd0;
          if (remb[27] || (remb[26:15] == 12'd0 && 15'(g12) > remb[14:0])) mute <= 1'b1;
          st <= S_GR_R;
        end

        // ---- one granule: sb 0..26, ch 0..1, three values each
        S_GR_R: begin wram_a <= {ch, 2'd3, sb}; t <= 2'd0; wnext <= S_GR_D; st <= S_W1; end
        S_W1: st <= wnext;
        S_GR_D: begin
          prm <= wram_q;
          case (part)
            2'd0: scf_cur <= w_s0;
            2'd1: scf_cur <= w_s1;
            default: scf_cur <= w_s2;
          endcase
          if (w_class == 5'd0) st <= S_GR_Z;
          else begin
            gb_n <= c_grp ? 5'(c_cube) : c_bits;
            ret <= S_GR_V; st <= S_GB; gb_v <= '0;
          end
        end
        S_GR_Z: begin
          wram_we <= 1'b1; wram_a <= {ch, t, sb}; wram_d <= '0;
          if (t == 2'd2) st <= S_NEXT; else t <= t + 2'd1;
        end
        S_GR_V: begin
          if (c_grp) begin
            if (t == 2'd0) code <= gb_v[9:0];
            rem <= '0; dcnt <= 4'd9;
            st <= S_GR_DIV;
          end else begin
            x <= 17'(gb_v) + 17'(c_add); alc <= 5'd16 - c_bits; st <= S_GR_AL;
          end
        end
        // restoring division of `code` by the modulus: remainder is the digit
        S_GR_DIV: begin
          logic [4:0] r2;
          r2 = {rem, code[9]};
          if (r2 >= 5'(c_mod)) begin rem <= 4'(r2 - 5'(c_mod)); code <= {code[8:0], 1'b1}; end
          else begin rem <= r2[3:0]; code <= {code[8:0], 1'b0}; end
          if (dcnt == 4'd0) st <= S_GR_X; else dcnt <= dcnt - 4'd1;
        end
        S_GR_X: begin
          x <= 17'(rem) + 17'(c_add); alc <= 5'd16 - c_bits; st <= S_GR_AL;
        end
        S_GR_AL: begin
          if (alc == 5'd0) begin
            // Nal = x - 2^15; issue Nal x C
            misc_a <= 8'd128 + 8'(prm[24:20]);
            p_en <= 1'b1; p_load <= 1'b1; p_rnd <= 1'b0; p_sub <= 1'b0;
            p_asel <= 2'd0; p_bsel <= 1'b0; p_neg_b <= 1'b0;
            st <= S_RQ1W;
          end else begin x <= {x[15:0], 1'b0}; alc <= alc - 5'd1; end
        end
        S_RQ1W: if (!mac_busy) begin
          // p1 = (Nal x C) >> 9, then issue p1 x 2^(1-s/3)
          misc_a <= 8'd64 + 8'(scf_cur);
          p_en <= 1'b1; p_load <= 1'b1; p_asel <= 2'd1;
          st <= S_RQ2W;
        end
        S_RQ2W: if (!mac_busy) begin
          // S = (p1 x scf) >> 24
          wram_we <= 1'b1; wram_a <= {ch, t, sb}; wram_d <= {1'b0, acc[47:24]};
          if (t == 2'd2) st <= S_NEXT;
          else begin
            t <= t + 2'd1;
            if (c_grp) begin rem <= '0; dcnt <= 4'd9; st <= S_GR_DIV; end
            else begin gb_n <= c_bits; ret <= S_GR_V; st <= S_GB; gb_v <= '0; end
          end
        end
        S_NEXT: begin
          if (ch) begin
            ch <= 1'b0;
            if (sb == 5'd26) begin t <= 2'd0; st <= S_SY_WAIT; end
            else begin sb <= sb + 5'd1; st <= S_GR_R; end
          end else begin ch <= 1'b1; st <= S_GR_R; end
        end

        // ---- synthesis of step t: matrixing both channels, then the window
        // <= 31, not 32: a push in flight has not reached f_cnt yet.
        S_SY_WAIT: if (f_cnt <= 7'd31 || mute) begin
          slot <= slot - 4'd1; ch <= 1'b0; ii <= 5'd0; jj <= 5'd0; ck <= 7'd0;
          st <= S_ID_RUN;
        end
        S_ID_RUN: begin
          wram_a <= {ch, t, jj};
          vram_a <= {ch, slot, ii};          // where S_ID_W will write
          misc_a <= {2'b00, ck[5:0]};
          p_en <= 1'b1; p_load <= (jj == 5'd0); p_rnd <= 1'b0; p_sub <= 1'b0;
          p_asel <= 2'd2; p_bsel <= 1'b0; p_neg_b <= ck[6];
          ck <= ck + {ii, 1'b0};
          if (jj == 5'd26) st <= S_ID_DR; else jj <= jj + 5'd1;
        end
        S_ID_DR: if (!mac_busy) st <= S_ID_W;
        S_ID_W: begin
          synth_begun <= 1'b1;
          jj <= 5'd0;
          if (ii == 5'd31) begin
            ii <= 5'd0; ck <= 7'd0;
            if (ch) begin ch <= 1'b0; kk <= 4'd0; st <= mute ? S_STEP_END : S_WN_RUN; end
            else begin ch <= 1'b1; st <= S_ID_RUN; end
          end else begin
            ii <= ii + 5'd1; ck <= 7'(ii + 5'd1); st <= S_ID_RUN;
          end
        end
        S_WN_RUN: begin
          // b = slot*32 + 16; V index (b + v_off + tap) & 511
          vram_a <= {ch, 9'({slot, 5'd16}) + 9'(v_off) + tap};
          win_a  <= w_off + tap;
          // i == 16 has no first term: issue nothing for it
          p_en <= !(ii == 5'd16 && !kk[0]);
          p_load <= (kk == 4'd0) || (ii == 5'd16 && kk == 4'd1);
          p_rnd <= 1'b1; p_sub <= w_sub; p_asel <= 2'd3; p_bsel <= 1'b1; p_neg_b <= 1'b0;
          if (kk == 4'd15) st <= S_WN_DR; else kk <= kk + 4'd1;
        end
        S_WN_DR: if (!mac_busy) st <= S_WN_O;
        S_WN_O: begin
          kk <= 4'd0;
          if (!ch) begin o_l <= o_sat; ch <= 1'b1; st <= S_WN_RUN; end   // o_l: benches only
          else begin
            // a stop that lands inside a step's window: the rest of it is not heard
            f_push <= !mute; smp_stb <= !mute; smp_lr <= {o_l, o_sat};
            ch <= 1'b0;
            if (ii == 5'd31) begin ii <= 5'd0; st <= S_STEP_END; end
            else begin ii <= ii + 5'd1; st <= S_WN_RUN; end
          end
        end
        S_STEP_END: begin
          if (t == 2'd2) begin
            t <= 2'd0;
            if (gr == 4'd11) st <= S_DONE;
            else begin gr <= gr + 4'd1; sb <= 5'd0; st <= S_GR_R; end
          end else begin t <= t + 2'd1; st <= S_SY_WAIT; end
        end

        S_DONE: begin
          if (!pos_set) mp_pos <= rd_pos;
          mute <= 1'b0; synth_begun <= 1'b0;
          dbg_frames <= dbg_frames + 16'd1;
          st <= S_IDLE;
        end

        // decode_buffer() returned false
        S_FAIL: begin
          dbg_fails <= dbg_fails + 16'd1;
          mute <= 1'b0; synth_begun <= 1'b0;
          if (!pos_set) begin
            if (mp_state == 8'd2) begin
              if (mp_pos == {lp_start, 3'b000}) mp_state <= 8'd0;
              mp_pos <= {lp_start, 3'b000};
              if (lp_end != 24'd0) mp_end <= lp_end;
            end else mp_state <= 8'd0;
          end
          st <= S_IDLE;
        end

        // get-bits, limit-checked bit by bit (MAME's gb() checks the field;
        // either way nothing of the frame is played)
        S_GB: begin
          if (rem_le0) st <= S_FAIL;
          else if (whit) begin
            gb_v   <= {gb_v[14:0], cur_bit};
            rd_pos <= rd_pos + 27'd1; remb <= remb - 28'sd1;
            if (rd_pos[3:0] == 4'hf) wvalid <= 1'b0;
            if (ret == S_HDR && gb_n == 5'd17) prot <= cur_bit;
            if (gb_n == 5'd1) st <= ret;
            gb_n <= gb_n - 5'd1;
          end
        end

        default: st <= S_IDLE;
      endcase
    end
  end

  // The class decoder's input: the side word being worked on.
  always_comb begin
    case (st)
      S_ALLOC: c_class = cls(sb, idx_m);
      S_GR_D:  c_class = w_class;
      default: c_class = prm[24:20];
    endcase
  end

  // ================================================================ output
  // 32 kHz: pop one stereo sample, apply pan and volume (dsbz80.cpp
  // sound_stream_update: sample * vol / 128; pan 3 plays nothing).
  logic [15:0] tick_acc;
  logic        tick, ovalid;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tick_acc <= '0; tick <= 1'b0; ovalid <= 1'b0;
      f_wp <= '0; f_rp <= '0; f_cnt <= '0;
      out_stb <= 1'b0; out_src <= 1'b0;
    end else begin
      tick <= 1'b0;
      if (tick_acc + 16'(TICK_NUM) >= 16'(TICK_DEN)) begin
        tick_acc <= tick_acc + 16'(TICK_NUM) - 16'(TICK_DEN); tick <= 1'b1;
      end else tick_acc <= tick_acc + 16'(TICK_NUM);

      // the sample shown is fifo_q, loaded by the pop; with nothing decoded
      // MAME emits silence, so an empty tick clears ovalid
      out_stb <= tick;
      out_src <= f_pop;
      if (tick) ovalid <= f_pop;

      if (stop_now) begin
        f_rp <= f_wp; f_cnt <= '0;
      end else begin
        if (f_push) f_wp <= f_wp + 6'd1;
        if (f_pop)  f_rp <= f_rp + 6'd1;
        f_cnt <= f_cnt + 7'(f_push) - 7'(f_pop);
      end
    end
  end
  wire signed [15:0] sl = (pan == 2'd2) ? fifo_q[0] : fifo_q[1];
  wire signed [15:0] sr = (pan == 2'd1) ? fifo_q[1] : fifo_q[0];
  wire signed [23:0] pl = {{8{sl[15]}}, sl} * $signed({17'd0, vol});
  wire signed [23:0] pr = {{8{sr[15]}}, sr} * $signed({17'd0, vol});
  assign out_l = (ovalid && pan != 2'd3) ? pl[22:7] : 16'sd0;
  assign out_r = (ovalid && pan != 2'd3) ? pr[22:7] : 16'sd0;
  assign vram_we = (st == S_ID_W) && !(reg_we && reg_a == 4'h0);
  assign fifo_we_l = (st == S_WN_O) && !ch && !mute && !(reg_we && reg_a == 4'h0);
  assign fifo_we_r = (st == S_WN_O) &&  ch && !mute && !(reg_we && reg_a == 4'h0);
  assign f_pop  = tick && (f_cnt != 7'd0) && !stop_now;

  // the play position, as dsbz80's mpeg_pos_r
  always_comb begin
    case (reg_a)
      4'h2:    reg_q = mp_pos[26:19];
      4'h3:    reg_q = mp_pos[18:11];
      4'h4:    reg_q = mp_pos[10:3];
      default: reg_q = 8'h00;
    endcase
  end

endmodule
