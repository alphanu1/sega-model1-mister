// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA -- the 15 kHz picture: a scan converter.
// Copyright (C) 2026 alphanu1. The converter is retrorepair's (GunCon 2 / CRT
// work), from retrorepair/sega-model2-mister branch guncon-scan15 at 57faad7,
// as the Model 2 core carries it: sega-model2-mister rtl/video/m2_scan15.sv at
// af76dde (its study R898, R939). See THIRD-PARTY.md.
//
// TAKEN UNCHANGED BUT FOR THE MODULE NAME AND THESE NOTES. Model 1 and Model 2
// declare the same picture - set_raw 16 MHz, 656 x 424, 496 x 384 visible -
// and Model 2's video timing was lifted from this core, so every constant
// below applies as it stands. What differs is the clock it runs on: clk_sys,
// 80 MHz, not Model 2's 100 MHz clk_mem, so Model1.sv makes ce_in one cycle in
// five and ce_out from 547/4240, 537/4240 or 4305/34768 of 80 MHz - the same
// rates, 5/4 of Model 2's ratios. The text below speaks in Model 2's clock
// where it quotes cycle counts; the pixel-domain figures are the same.
//
// The read below needs the two ring words on consecutive cycles after an
// output enable, and the sum before the next: four cycles. ce_out comes every
// 7.75 cycles at 80 MHz (Model 2: at least 9), so the margin holds.
//
// WHAT IT IS FOR
//
// The old 15 kHz mode (R682) showed the game's 384 lines one-to-one, two
// fields of 192 in a 262-274-line field: about a fifth of a TV's height black
// above and below, and every one-line detail in one field only. Filling a
// field's ~240 visible lines from 192 needs a vertical scale; no timing change
// can do it at the game's fixed 57.52 Hz.
//
// WHAT IT DOES
//
// The renderer stays on its native 24 kHz timing (the path proven since the
// start). This module sits between its finished pixels and the video pins:
//
//   in : the native 496 x 384 picture, one sample per `ce_in`, written into a
//        ring of RING lines (source row r in slot r mod RING, restarted at
//        each native frame).
//   out: its own 15 kHz interlaced timing -- a 656-pixel line, hsync 520..584,
//        fields of N0 and N0-1 lines (263/262, 269/268 or 274/273: 15.1, 15.4
//        or 15.7 kHz) -- 240 visible lines a field, 480 a frame. Output frame
//        row m samples the source at 4m/5: rows s = floor(4m/5) and s+1,
//        weights (5-r, r)/5 with r = 4m mod 5. 384 -> 480 is exactly 4:5, so
//        the weights repeat every five rows and nothing is dropped or doubled.
//
// NO FRAME OF DELAY, NO DRIFT
//
// A native frame is 656 x 424 pixels at 16/100 of clk: 1,738,400 cycles. Two
// output fields are 547 (537, 525) lines of 656 pixels at 547/5300 (537/5300,
// 861/8692) of clk: 3,476,800 cycles, exactly two native frames in every mode.
// Both enables are exact rationals of one clock, so once the output counters
// are aligned to a native frame they stay aligned; the alignment is repeated
// every second frame (a no-op once it holds). Each field shows ONE native
// frame: an even frame's read D_PX output pixels behind the frame's first
// visible pixel, an odd frame's D_PX + HT/2 (field 1) or D_PX - HT/2 (field 0,
// when the pairing has swapped the fields, R939). The output's lines never
// move once locked.
//
// THE RING, AND WHY 16 LINES (R898)
//
// A field reads its 384 source rows in 240 output lines; the native picture
// writes them in 384 native lines. Those take different times, so the read
// drifts against the write over a field and the ring must hold the difference:
//
//   262/263 (15.1 kHz): 240 x 66.23 us = 15.89 ms against 15.74: falls 3.6 rows behind
//   268/269 (15.4 kHz): 240 x 64.74 us = 15.54 ms: gains 5.0 rows
//   273/274 (15.7 kHz): 240 x 63.56 us = 15.25 ms: gains 12.0 rows
//
// At 15.7 kHz the read must start ~12 rows behind the write and end just
// behind it, and the ring holds those rows plus the two read and the one being
// written. 14 lines cannot be placed at any D_PX; 15 leave ~20 us both ways,
// 16 ~40 us (the bench measures both). retrorepair's 12-line ring was sized for
// 262/263 only and four taps (a vertical filter that is not built).
//
// Colour is stored as 24 bits because nothing narrower is exact: the 2D layers
// leave the palette through the game's colour-translation table and the gamma
// curve (m2_video / m2_palette), any 8-bit value per channel.
//
// 16 LINES COST NO MORE MEMORY THAN 15, AND LESS LOGIC. 16 x 512 x 24 is 2048 x 5
// blocks four deep: 20 M10K and a 4:1 read mux. 15 lines packed tighter (20 bits
// in 512 x 20 blocks, a line a block, plus 4 bits in 8192 x 1) took 19 M10K but
// a 15:1 read mux of 20 bits, 115 ALUTs in quartus_map (R898) -- at 99% ALM the
// logic is the scarcer resource. 16 also wraps the slot counters for free.
//
// CHANGES FROM retrorepair's 57faad7
//   * Two taps, not four: the vertical filter (filt) was built and rejected by
//     its author and tied off; the sharp table reads rows s-1 and s+2 with
//     weight 0. Without them the ring needs two lines less.
//   * RING 16 (was 12), and D_PX per line count, so 15.7 and 15.4 kHz work
//     (R840: most sets take only 15.7). retrorepair's build had 262/263 only.
//   * The beacon (light gun) and the field-order switch are not ported.
//   * PAIRING SWAPS FIELD LABELS, NOT THE OUTPUT'S PHASE (R939). Theirs re-aligned
//     the output to the other native frame, which moved the line timing half a
//     line in one step: a 15 kHz CRT tore the top of the picture at every swap,
//     and Virtua Cop's cadence slips often enough for ~27 a minute (GitHub #24).
//     Now a swap repeats one field label instead; the lines never move. And an
//     input, pair_en (OSD "15kHz pairing"), turns swapping off.
//
// GEOMETRY (as the 1:1 mode had it): 656-pixel line, 496 visible, hsync
// 520..584 (64 pixels); fields of N0 and N0-1 lines, field 1's vsync half a
// line early, which interlaces.

`timescale 1ns/1ps

module m1_scan15 #(
  parameter int unsigned W     = 496,   // visible pixels per line
  parameter int unsigned HT    = 656,   // line length in output pixels
  parameter int unsigned HSS   = 520,   // hsync start
  parameter int unsigned HSE   = 584,   // hsync end (exclusive)
  parameter int unsigned VIS   = 240,   // visible lines per output field
  parameter int unsigned RING  = 16,    // ring lines, at most 16 (see above: 15 is the least 273/274 can use)
  // output pixels from the native frame's first visible pixel to the first visible output line, per line count,
  // each in the middle of its window (the bench's margins both ways): at RING 16, 273/274 works from 5430 to 6260
  parameter int unsigned DPX_I = 5840,  // 273/274
  parameter int unsigned DPX_M = 4310,  // 268/269
  parameter int unsigned DPX_N = 2490,  // 262/263
  parameter int unsigned PAIR_N = 8     // wrong-frame image changes running before the fields are swapped (1..8)
) (
  input  logic        clk,             // the video clock (clk_mem)
  input  logic        rst_n,
  input  logic        en,              // converter selected
  input  logic  [3:0] img_tag,         // names the image on show (the renderer's show_tag); asynchronous, changes in vertical blank
  input  logic        pair_en,         // swap the fields to a 2-frame image cadence (R939); 0 keeps the pairing as it is

  // the native picture, sampled on ce_in
  input  logic        ce_in,
  input  logic        de_in,           // picture sample is inside the 496 x 384 window
  input  logic        vb_in,           // the native vertical blank
  input  logic [23:0] rgb_in,

  // the 15 kHz output
  input  logic        ce_out,
  input  logic        nl,              // 262/263 lines a field
  input  logic        ml,              // 268/269 (else 273/274)
  output logic        o_hs,
  output logic        o_vs,
  output logic        o_de,
  output logic        o_field,
  output logic [23:0] o_rgb
);

  localparam int unsigned DEPTH = RING * 512;

  // Every ring address is {slot, x}: slots are counters that wrap at RING - 1 (up1 below, reset to 0) and x is at
  // most 495, so no address passes DEPTH - 1 (at RING 16 the array is the whole 13-bit range).
  // ------------------------------------------------------------ the ring
  (* ramstyle = "M10K", max_depth = 2048 *) logic [23:0] ram [0:DEPTH-1];
  logic        we_w;
  logic [12:0] wa_w;
  logic [23:0] wd_w;
  always_ff @(posedge clk) if (we_w) ram[wa_w] <= wd_w;

  wire  [12:0] ra;
  logic [23:0] rd;
  always_ff @(posedge clk) rd <= ram[ra];

  function automatic logic [3:0] up1(input logic [3:0] a);
    return (a == 4'(RING - 1)) ? 4'd0 : a + 4'd1;
  endfunction

  // ------------------------------------------------------------ source side
  logic        vb_d, de_d;
  logic [8:0]  wx;
  logic [3:0]  wslot;                  // ring slot of the line being written
  logic        par;                    // 1: the next native frame is an even one (E), 0: odd (O); never re-phased (R939)
  logic        fs_even;                // an even native frame has just started: the output is re-aligned to it

  // PAIRING (retrorepair; R939). Two output fields are two native frames, an even and an odd one (E, O). A game that shows
  // a new image every second frame (Virtua Cop, Desert Tank: 28.8 Hz) has every output frame made of two DIFFERENT images
  // if its images change on the frame that field 1 shows, and everything that moves is combed by a deinterlacer that
  // weaves field 0 then field 1 (the HDMI scaler does). So watch the image change: if for PAIR_N changes running each
  // fell on the frame field 1 shows, swap the fields -- `s`: 0 = the E frames are field 0, 1 = the O frames are.
  //
  // retrorepair re-paired by re-aligning the output to the other native frame: the output counters reloaded, the line
  // timing moved half a line in one step (a native frame is N0 - 1/2 lines). A CRT's line oscillator loses lock at that,
  // and the top of the picture tears for a few lines (GitHub #24, a 15 kHz CRT, Virtua Cop and Desert Tank only: their
  // cadence slips a frame now and then, and every slip re-paired). Now nothing ever moves the output's lines: a swap
  // only changes which field is which, one field repeated (field 0 twice, or field 1 twice) and its vsync half a line
  // off -- the field after it is half a line shorter or longer than the 1/2-line-offset fields around it. The O field
  // then starts one line earlier (field 0, D_PX - HT/2 behind its frame) or later (field 1, D_PX + HT/2) than a fixed E
  // field (D_PX); all three are inside the ring's window at every line count (the bench measures the margins).
  //
  // The swap is made at an O frame's start (the O field has not started; its label is set at the E field's start, and
  // the vsync before the next E field is placed for the E field's new label). A change seen on an E frame waits a frame.
  // The tag changes in the vertical blank, 1.6 ms before the frame start it is compared at, so one register is
  // synchroniser enough.
  logic [3:0]  tg_s, tg_p;
  logic [2:0]  bad;                    // wrong-frame changes running
  logic        s;                      // the pairing: which native frame is field 0
  logic        flip;                   // a swap decided on an E frame, made at the next frame start (an O frame)
  always_ff @(posedge clk) tg_s <= img_tag;

  wire         fs_now  = vb_d && !vb_in;                   // the vertical blank ended on this sample
  wire         rise    = de_in && !de_d;                   // first pixel of a line
  wire [3:0]   ws_base = fs_now ? 4'(RING - 1) : wslot;
  wire [3:0]   ws_n    = rise ? up1(ws_base) : ws_base;
  wire [8:0]   wx_n    = rise ? 9'd0 : wx;
  assign we_w = ce_in && de_in;
  assign wa_w = {ws_n, wx_n};
  assign wd_w = rgb_in;

  wire         chg     = tg_s != tg_p;
  wire         good    = par ^ s;                          // this frame is field 0's: E with s = 0, O with s = 1
  wire         trip    = chg && !good && (bad == 3'(PAIR_N - 1));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vb_d <= 1'b1; de_d <= 1'b0; wx <= '0; wslot <= '0; par <= 1'b0; fs_even <= 1'b0; tg_p <= '0; bad <= '0;
      s <= 1'b0; flip <= 1'b0;
    end else begin
      fs_even <= 1'b0;
      if (ce_in) begin
        vb_d <= vb_in;
        de_d <= de_in;
        wslot <= ws_n;
        if (fs_now) begin
          tg_p    <= tg_s;
          par     <= ~par;
          fs_even <= par;              // par was 1: this frame is an even one
          if (chg) bad <= (good || trip) ? 3'd0 : bad + 3'd1;
          // a swap is made at an O frame's start: this one if the evidence completed on it, else the next
          if (!par && (flip || (trip && pair_en))) begin
            s    <= ~s;
            flip <= 1'b0;
          end else if (par && trip && pair_en) flip <= 1'b1;
        end
        wx <= de_in ? wx_n + 9'd1 : 9'd0;
      end
    end
  end

  // ------------------------------------------------------------ output timing
  // `field` is the label of the field being counted (0: rows 0, 2, 4.., N0 lines; 1: rows 1, 3.., N0 - 1 lines),
  // `nxt` the label of the one after it, `ise` that this one shows an E frame. Labels alternate but at a swap (R939),
  // where one repeats: E's label is s and O's ~s, each taken at the start of the field before it.
  logic [9:0] hcnt, vcnt;
  logic       field, nxt, ise, s_e;

  wire [9:0] n0  = nl ? 10'd263 : ml ? 10'd269 : 10'd274;
  wire [9:0] vt  = field ? n0 - 10'd1 : n0;
  wire [9:0] vss = nl ? 10'd247 : ml ? 10'd250 : 10'd253;   // field 0's vsync start (3 lines), before a field 1
  wire [9:0] vse = vss + 10'd3;

  // The align loads the counters the free-running output holds D_PX pixels before an E field's first line: DL lines
  // before the end of the O field (N0 - 1 lines if it is field 1, N0 if field 0), DL * HT - D_PX pixels into that line.
  localparam int unsigned DL_I = (DPX_I + HT - 1) / HT;
  localparam int unsigned DL_M = (DPX_M + HT - 1) / HT;
  localparam int unsigned DL_N = (DPX_N + HT - 1) / HT;
  wire [9:0] v_ld = nl ? 10'(262 - DL_N) : ml ? 10'(268 - DL_M) : 10'(273 - DL_I);
  wire [9:0] h_ld = nl ? 10'(DL_N * HT - DPX_N) : ml ? 10'(DL_M * HT - DPX_M) : 10'(DL_I * HT - DPX_I);

  // The vsync is placed for the field after it: 1/2 line nearer that field's first line when it is field 0. A field 1
  // (one line shorter) holds its vsync a line earlier. Alternating labels give field 0's at vss and field 1's at
  // vss - 1/2, as before; a repeated label puts it on a whole line (two 1s) or a half line (two 0s).
  wire        hs_c  = (hcnt >= 10'(HSS)) && (hcnt < 10'(HSE));
  wire [19:0] vpos  = {vcnt, hcnt};
  wire [9:0]  vs_h  = nxt ? 10'd0 : 10'(HT >> 1);
  wire        vs_c  = (vpos >= {vss - 10'(field), vs_h}) && (vpos < {vse - 10'(field), vs_h});
  wire        de_c  = (hcnt < 10'(W)) && (vcnt < 10'(VIS));

  // The line on show is frame row m = 2 * vcnt + field: source rows s = floor(4m/5) and s + 1, fraction r = 4m mod 5.
  // Only the slot of row s, p, is tracked: one line on, m grows by 2, s by 1 + c (c = the carry of r + 3 past 5), and p
  // with it. Each field starts at s = 0 (m = 0, r = 0; m = 1, r = 4). Row s + 1 is past the picture only on the last line
  // of field 1 (m = 479, s = 383); it is then row s again.
  logic [3:0] p;
  logic [2:0] r_c;
  wire        lastb = (vcnt == 10'(VIS - 1)) && field;   // s = 383
  wire  [3:0] r3    = {1'b0, r_c} + 4'd3;
  wire        rc    = (r3 >= 4'd5);
  wire  [2:0] r_n   = rc ? 3'(r3 - 4'd5) : 3'(r3);
  wire  [3:0] p1    = up1(p);
  wire  [3:0] p_n   = rc ? up1(p1) : p1;

  wire        align = fs_even && en;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hcnt <= '0; vcnt <= '0; field <= 1'b0; nxt <= 1'b1; ise <= 1'b1; s_e <= 1'b0; p <= '0; r_c <= '0;
    end else if (align) begin
      // in the O field: its label was taken at the last E frame's start (s_e); the E field's is s
      field <= ~s_e;
      nxt   <= s;
      ise   <= 1'b0;
      s_e   <= s;
      vcnt  <= v_ld + 10'(s_e);
      hcnt  <= h_ld;
    end else if (ce_out) begin
      if (hcnt == 10'(HT - 1)) begin
        hcnt <= '0;
        if (vcnt == vt - 10'd1) begin
          vcnt  <= '0;
          field <= nxt;
          nxt   <= ise ? s : ~s;          // after an O field comes E (label s), after an E field O (~s)
          ise   <= ~ise;
          p     <= '0;
          r_c   <= nxt ? 3'd4 : 3'd0;     // the field about to start: field 1 starts on frame row 1 (4 mod 5)
        end else begin
          vcnt <= vcnt + 10'd1;
          if (vcnt < 10'(VIS) - 10'd1) begin
            p   <= p_n;
            r_c <= r_n;
          end
        end
      end else begin
        hcnt <= hcnt + 10'd1;
      end
    end
  end

  // ------------------------------------------------------------ read, blend, output
  // After each output pixel enable the next pixel's two source words are read on consecutive cycles (enables are at
  // least 9 cycles apart), weighted and summed as they arrive: in twentieths, (20 - 4r) and 4r, plus 10 to round, then
  // x 3277 / 65536 = / 20 (exact for every value up to 20 * 255 + 10). The output register takes it at the next enable.
  logic [3:0]  ph;
  logic [12:0] acc_r, acc_g, acc_b;       // at most 20 * 255 + 10
  wire  [4:0]  w0   = 5'd20 - {r_c, 2'b00};
  wire  [4:0]  w1   = {r_c, 2'b00};
  wire  [4:0]  wcur = (ph == 4'd2) ? w0 : w1;

  (* multstyle = "dsp" *) wire [24:0] mul_r = acc_r * 12'd3277;
  (* multstyle = "dsp" *) wire [24:0] mul_g = acc_g * 12'd3277;
  (* multstyle = "dsp" *) wire [24:0] mul_b = acc_b * 12'd3277;
  wire [23:0] blend = {mul_r[23:16], mul_g[23:16], mul_b[23:16]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ph <= 4'd0;
    else if (ce_out) ph <= 4'd1;
    else if (ph != 4'd0 && ph != 4'd15) ph <= ph + 4'd1;
  end

  // The ring address is not a register of its own (the M10K registers it): row s is read at the edge where ph is 1,
  // row s + 1 (row s again past the picture) where ph is 2, so the words are on rd in ph 2 and 3.
  assign ra = {(ph == 4'd2 && !lastb) ? p1 : p, hcnt[8:0]};

  // the datapath has no reset: it holds nothing that matters until the first line is read
  always_ff @(posedge clk) begin
    if (ph == 4'd2 || ph == 4'd3) begin
      acc_r <= ((ph == 4'd2) ? 13'd10 : acc_r) + 13'(rd[23:16] * wcur);
      acc_g <= ((ph == 4'd2) ? 13'd10 : acc_g) + 13'(rd[15:8]  * wcur);
      acc_b <= ((ph == 4'd2) ? 13'd10 : acc_b) + 13'(rd[7:0]   * wcur);
    end
  end

  // Not gated with `en`: at 24 kHz Model2.sv takes the native picture, and these are not looked at.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_hs <= 1'b0; o_vs <= 1'b0; o_de <= 1'b0; o_field <= 1'b0; o_rgb <= '0;
    end else if (ce_out) begin
      o_hs    <= hs_c;
      o_vs    <= vs_c;
      o_de    <= de_c;
      o_field <= field;
      o_rgb   <= de_c ? blend : 24'd0;
    end
  end

endmodule
