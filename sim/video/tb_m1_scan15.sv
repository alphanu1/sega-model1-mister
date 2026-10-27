// SPDX-License-Identifier: GPL-3.0-or-later
// Bench for m1_scan15, the 15 kHz scan converter. Ported from the Model 2 core's own bench for its converter
// (sega-model2-mister af76dde, R939), itself ported from retrorepair's (guncon-scan15 at 57faad7); see THIRD-PARTY.md.
//
// THE ONLY CHANGES ARE THE CLOCK AND THE SOURCE. Model 1's video runs on clk_sys at 80 MHz with ce_pix one cycle in
// five, where Model 2's ran on 100 MHz with 16/100; the native picture is the same 16 MHz, 656 x 424, 496 x 384 window,
// and the source here is Model 1's own m1_video_timing (Model 2's was lifted from it unchanged). The 15 kHz enables are
// the same output rates as exact rationals of 80 MHz: 547/4240 (273/274), 537/4240 (268/269), 4305/34768 (262/263) --
// Model 2's 547/5300, 537/5300 and 861/8692 of 100 MHz, times 5/4. Every check is the Model 2 bench's, unchanged: the
// vsync interval is still exactly one native frame, 17,384,000 ns, at either clock.
//
// own native timing module is the source, every pixel encodes (frame, row, column), and every output pixel is checked
// against a blend worked out here from first principles, not from the converter's tables.
//
//   sim/video/run_scan15.sh [mode] [frames] [cad] [ph]
// Plusargs: mode=0 273/274 lines, 1 = 268/269, 2 = 262/263; frames=N native frames (default 14); cad=N the game shows a
// new image every N native frames (0 = never), ph=P at the frames where frame mod N == P (the converter must pair the
// fields so each output frame holds one image).
//
// Checks:
//   * every output pixel against the 4:5 bilinear blend of ONE native frame's rows floor(4m/5) and the next;
//   * the two ring words read for each pixel are those rows, of that frame, and the row fraction steps through 4m mod 5;
//   * hsync 64 pixels, 496 visible pixels a line, 240 visible lines a field, every line HT pixels;
//   * every vsync-to-vsync interval exactly one native frame (17,384,000 ns), and field 1's picture half a line (328
//     pixels) lower after its vsync than field 0's -- what interlaces;
//   * once locked, the re-alignment every second native frame finds the counters where it would put them (a no-op);
//   * the ring's margins both ways: the smallest time between a word's write and its read, and between its last read
//     and the write that replaces it;
//   * pairing: with a new image every second frame, in either phase, no output frame is made of two images.
//   * R939: the output's lines never move -- no line other than HT pixels, ever, and the re-alignment never moves the
//     counters once locked -- and a vsync interval differs from one native frame only where a field label repeats
//     (the pairing swapping the fields), and then by exactly half a line.
//
// R939 adds a game whose cadence slips: +rnd=1 draws each image's length in native frames from an LCG (+seed=N):
// 1 frame with probability slip1/1000, 3 with slip3/1000, 4 with slip4/1000, else 2 (Virtua Cop on the board, s1381:
// ~95% 2, ~2% 3). +pe=0 turns the pairing off (the pair_en input). EVENTS lines count what a TV sees.

`timescale 1ns/1ps

// The parameters default to the design's (Model1.sv instantiates m1_scan15 with its defaults); -G overrides them for a
// sweep, and the report says whether the run was at the design's values.
module tb_m1_scan15 #(parameter int RING = 16, parameter int DPX_I = 5840, parameter int DPX_M = 4310,
                      parameter int DPX_N = 2490);
  logic clk = 1'b0;
  always #6.25 clk = ~clk;                  // 80 MHz, clk_sys
  logic rst_n = 1'b0;

  int mode, nframes, cad, cph, rnd, slip1, slip3, slip4, pe;
  int unsigned seed;
  logic nl, ml;
  initial begin
    if (!$value$plusargs("mode=%d", mode)) mode = 0;
    if (!$value$plusargs("frames=%d", nframes)) nframes = 14;
    if (!$value$plusargs("cad=%d", cad)) cad = 2;
    if (!$value$plusargs("ph=%d", cph)) cph = 0;
    if (!$value$plusargs("rnd=%d", rnd)) rnd = 0;
    if (!$value$plusargs("slip1=%d", slip1)) slip1 = 0;
    if (!$value$plusargs("slip3=%d", slip3)) slip3 = 20;
    if (!$value$plusargs("slip4=%d", slip4)) slip4 = 0;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("pe=%d", pe)) pe = 1;
    nl = (mode == 2);
    ml = (mode == 1);
  end

  // ---- the two pixel enables, exactly as Model1.sv makes them
  logic [19:0] acc_i = 0, acc_o = 0;
  logic        ce_in = 0, ce_out = 0;
  wire  [19:0] on = nl ? 20'd4305 : ml ? 20'd537 : 20'd547;
  wire  [19:0] od = nl ? 20'd34768 : 20'd4240;
  always @(posedge clk) begin
    if (acc_i >= 20'd5) acc_i <= 20'd0;
    else if (acc_i + 20'd1 >= 20'd5) begin acc_i <= acc_i + 20'd1 - 20'd5; ce_in <= 1'b1; end
    else begin acc_i <= acc_i + 20'd1; ce_in <= 1'b0; end
    if (acc_o >= od) acc_o <= 20'd0;
    else if (acc_o + on >= od) begin acc_o <= acc_o + on - od; ce_out <= 1'b1; end
    else begin acc_o <= acc_o + on; ce_out <= 1'b0; end
  end

  // ---- the native source
  logic [9:0] thc, tvc;
  logic       thb, tvb;
  m1_video_timing tm (.clk(clk), .ce_pix(ce_in), .rst_n(rst_n), .hcnt(thc), .vcnt(tvc), .hblank(thb), .vblank(tvb),
                      .hsync(), .vsync(), .visible(), .line_start(), .line_number(), .vblank_start());

  int          frame = 0;
  logic [3:0]  tag = 4'd0;                  // the renderer's show_tag: changes in the vertical blank before a new image
  logic [3:0]  imgid [16];                  // the tag of each native frame, by frame mod 16
  logic        vb_prev = 1'b1;
  logic        de_s, vb_s;
  logic [23:0] rgb_s;

  function automatic logic [23:0] pat(input logic [7:0] f, input int y, input int x);
    return {y[7:0], x[7:0], f[3:0], y[8], x[8], 2'b00};
  endfunction

  // the slipping cadence: the image's length in native frames, from an LCG (the Python model draws the same sequence)
  int cdn = 2, nimg = 0, nlen [5];
  function automatic int draw_len();
    int r;
    seed = seed * 32'd1103515245 + 32'd12345;
    r = int'((seed >> 16) & 32'h7FFF) % 1000;
    return (r < slip1) ? 1 : (r < slip1 + slip3) ? 3 : (r < slip1 + slip3 + slip4) ? 4 : 2;
  endfunction

  always @(posedge clk) if (ce_in) begin
    de_s  <= ~(thb | tvb);
    vb_s  <= tvb;
    vb_prev <= tvb;
    if (vb_prev && !tvb) begin frame <= frame + 1; imgid[(frame + 1) & 15] = tag; end
    if (!vb_prev && tvb) begin
      if (rnd != 0) begin
        if (cdn <= 1) begin tag <= tag + 4'd1; cdn = draw_len(); nimg++; nlen[cdn]++; end
        else cdn--;
      end else if (cad != 0 && ((frame + 1) % cad) == cph) tag <= tag + 4'd1;
    end
    rgb_s <= pat(8'((vb_prev && !tvb) ? frame + 1 : frame), int'(tvc), int'(thc));
  end

  // ---- the device under test
  logic o_hs, o_vs, o_de, o_field;
  logic [23:0] o_rgb;
  m1_scan15 #(.RING(RING), .DPX_I(DPX_I), .DPX_M(DPX_M), .DPX_N(DPX_N)) dut (.clk(clk), .rst_n(rst_n), .en(1'b1), .img_tag(tag),
`ifndef OLD_RTL
                 .pair_en(pe != 0),
`endif
                 .ce_in(ce_in), .de_in(de_s), .vb_in(vb_s),
                 .rgb_in(rgb_s), .ce_out(ce_out), .nl(nl), .ml(ml), .o_hs(o_hs), .o_vs(o_vs), .o_de(o_de),
                 .o_field(o_field), .o_rgb(o_rgb));
  // the design's own values, from an instance at its defaults (inputs idle)
  m1_scan15 dflt (.clk(1'b0), .rst_n(1'b0), .en(1'b0), .img_tag(4'd0),
`ifndef OLD_RTL
                  .pair_en(1'b1),
`endif
                  .ce_in(1'b0), .de_in(1'b0), .vb_in(1'b1),
                  .rgb_in(24'd0), .ce_out(1'b0), .nl(1'b0), .ml(1'b0), .o_hs(), .o_vs(), .o_de(), .o_field(), .o_rgb());
  wire design_vals = (RING == dflt.RING) && (DPX_I == dflt.DPX_I) && (DPX_M == dflt.DPX_M) && (DPX_N == dflt.DPX_N);

  initial begin #200 rst_n = 1'b1; end

  // ---- the expected picture, from first principles
  // B(m): the source sampled at row 4m/5 with a linear blend, as five times its value: (5 - f) R[row] + f R[row + 1],
  // rows clamped to the picture; the pixel is B(m) / 5 rounded half up, i.e. floor((4 B + 10) / 20).
  function automatic int clampr(input int r);
    return (r < 0) ? 0 : (r > 383) ? 383 : r;
  endfunction

  function automatic int chan(input logic [23:0] p, input int ch);
    return (ch == 0) ? int'(p[23:16]) : (ch == 1) ? int'(p[15:8]) : int'(p[7:0]);
  endfunction

  function automatic logic [7:0] expect8(input logic [7:0] f, input int m, input int x, input int ch);
    int row, fr, b;
    row = (4 * m) / 5;
    fr  = 4 * m - 5 * row;
    b   = (5 - fr) * chan(pat(f, clampr(row), x), ch) + fr * chan(pat(f, clampr(row + 1), x), ch);
    return 8'((4 * b + 10) / 20);
  endfunction

  // ---- monitors
  int       fails = 0, checked = 0, ring_fails = 0, step_fails = 0;
  longint   wt    [RING][512];               // when each ring word was last written
  longint   lastrd[RING][512];               // and last read since
  longint   min_avail = 64'h7FFFFFFFFFFFFFFF, min_over = 64'h7FFFFFFFFFFFFFFF;
  logic [7:0] exp_r, exp_g, exp_b;
  logic       exp_vis = 0;
  logic       ce_out_d = 0;
  logic [7:0] pr, pg, pb;
  logic       pvis = 0;
  logic [7:0] cur_f = 8'd0;
  int         pairs = 0, pair_bad = 0;
  logic [3:0] last_a = 4'd0;
  logic       a_ok = 1'b0;
  int         al_n = 0, al_moved = 0, relock_frame = -1, skip_vs = 0;

  // output timing structure
  int  de_lines = 0, vs_seen = 0, hs_w = 0, hs_max = 0, hs_min = 9999, de_w = 0, de_max = 0, de_min = 9999, nint = 0;
  int  hs_per_bad = 0, field_lines_bad = 0, vs_bad = 0;
  longint vs_prev = 0, hs_prev = 0, px = 0, vs_px = 0;
  longint to_de [2];                         // pixels from a vsync to the next visible line, by the field that follows
  logic   to_de_ok [2];
  longint vs_int [64];
  // R939: what a TV sees, over the whole run (after the first lock)
  logic   pend_dev = 1'b0;
  int     ev_hs = 0, ev_rep = 0, ev_vsd = 0, ev_vsd_norep = 0, ev_vsd_big = 0, vsd_hist [-4:4], n_vsi = 0;
  longint ipx_nat;
  longint unsigned ohash = 64'd0;           // every output sample from reset, for a before / after comparison
  logic o_hs_d = 0, o_vs_d = 0, o_de_d = 0;
  logic waiting_de = 0;
  logic vs_field = 0;

  always @(posedge clk) begin
    automatic logic warm = (frame >= 3);
    automatic int nh, nv;
    ce_out_d <= ce_out;

    // the re-alignment: once locked, it must find the counters where it puts them
    if (dut.align && frame >= 5) begin
      al_n++;
      // what the free-running counters would hold after this cycle (the load replaces that state)
      nh = int'(dut.hcnt); nv = int'(dut.vcnt);
      if (ce_out) begin
        if (nh == 655) begin nh = 0; nv = nv + 1; end else nh = nh + 1;
      end
`ifdef OLD_RTL
      if (nv != int'(dut.v_ld) || nh != int'(dut.h_ld) || dut.field != 1'b1) begin
`else
      if (nv != int'(dut.v_ld) + int'(dut.s_e) || nh != int'(dut.h_ld) || dut.field != !dut.s_e) begin
`endif
        // R939: nothing may move the output once locked (retrorepair's pairing lock did, by half a line); counted, and
        // the timing checks run straight through it
        al_moved++;
        relock_frame = frame;
        if (al_moved <= 3) $display("ALIGN moved the output at native frame %0d: v %0d h %0d f %0d ce_out %0d -> v %0d h %0d",
                                    frame, dut.vcnt, dut.hcnt, dut.field, ce_out, dut.v_ld, dut.h_ld);
      end
    end

    // source writes: how long after its last read was this word overwritten?
    if (dut.we_w) begin
      automatic int slot = int'(dut.wa_w[12:9]);
      automatic int x    = int'(dut.wa_w[8:0]);
      if (warm && lastrd[slot][x] != 0) begin
        automatic longint sl = $time - lastrd[slot][x];
        if (sl < min_over) min_over = sl;
      end
      wt[slot][x]     = $time;
      lastrd[slot][x] = 0;
    end

    // reads: the RAM is read at the edges where ph is 1 (row s) and 2 (row s + 1)
    if ((dut.ph == 4'd1 || dut.ph == 4'd2) && dut.de_c) begin
      automatic int slot = int'(dut.ra[12:9]);
      automatic int x    = int'(dut.ra[8:0]);
      lastrd[slot][x] = $time;
      if (warm) begin
        automatic longint av = $time - wt[slot][x];
        if (av < min_avail) min_avail = av;
      end
    end

    // the two words are on rd in ph 2 and 3: rows s, s + 1 (clamped) of ONE native frame
    if ((dut.ph == 4'd2 || dut.ph == 4'd3) && dut.de_c && warm) begin
      automatic int k  = int'(dut.ph) - 2;
      automatic int m  = 2 * int'(dut.vcnt) + int'(dut.field);
      automatic int s  = (4 * m) / 5;
      automatic int x  = int'(dut.hcnt[8:0]);
      automatic int row = clampr(s + k);
      automatic logic [7:0] f = {4'd0, dut.rd[7:4]};
      if (k == 0) begin
        cur_f = f;
        if (dut.vcnt == 10'd0 && dut.hcnt == 10'd0 && frame >= 40) begin
          if (dut.field == 1'b0) begin last_a = imgid[f[3:0]]; a_ok = 1'b1; end
          else if (a_ok) begin
            pairs++;
            if (imgid[f[3:0]] != last_a) begin
              pair_bad++;
              if (pair_bad <= 3) $display("PAIRBAD at native frame %0d", frame);
            end
          end
        end
        if (int'(dut.r_c) != (4 * m) % 5) begin
          step_fails++;
          if (step_fails <= 5) $display("STEP  m=%0d r=%0d want r=%0d at %0t", m, int'(dut.r_c), (4 * m) % 5, $time);
        end
      end
      if (dut.rd !== pat(f, row, x) || f != cur_f) begin
        ring_fails++;
        if (ring_fails <= 5) $display("RING  tap %0d x=%0d s=%0d want row %0d: rd=%h (frame %0d, wanted %0d) at %0t", k, x, s, row, dut.rd, f, cur_f, $time);
      end
    end

    // both words are in: the expected pixel
    if (dut.ph == 4'd6 && dut.de_c && warm) begin
      automatic int m = 2 * int'(dut.vcnt) + int'(dut.field);
      automatic int x = int'(dut.hcnt[8:0]);
      exp_r   = expect8(cur_f, m, x, 0);
      exp_g   = expect8(cur_f, m, x, 1);
      exp_b   = expect8(cur_f, m, x, 2);
      exp_vis = 1'b1;
    end

    // the output latches the pixel prepared in the previous period on every enable
    if (ce_out) begin pr = exp_r; pg = exp_g; pb = exp_b; pvis = exp_vis; exp_vis = 1'b0; end
    if (ce_out_d) begin
      px++;
      ohash = ohash * 64'd1099511628211 ^ {29'd0, o_hs, o_vs, o_de, o_field, o_rgb, 7'd0};
      if (o_de && warm) begin
        checked++;
        if (!pvis || o_rgb !== {pr, pg, pb}) begin
          fails++;
          if (fails <= 5) $display("PIXEL got %h want %h (prepared %0d) at %0t", o_rgb, {pr, pg, pb}, pvis, $time);
        end
      end
      o_hs_d <= o_hs; o_vs_d <= o_vs; o_de_d <= o_de;
      if (o_hs) hs_w++; else if (hs_w != 0) begin
        if (hs_w > hs_max) hs_max = hs_w;
        if (hs_w < hs_min) hs_min = hs_w;
        hs_w = 0;
      end
      if (o_de) de_w++; else if (de_w != 0) begin
        if (de_w > de_max) de_max = de_w;
        if (de_w < de_min) de_min = de_w;
        de_w = 0;
      end
      if (o_hs && !o_hs_d) begin
        if (warm && hs_prev != 0 && px - hs_prev != 656) begin
          hs_per_bad++;
          if (frame >= 5) ev_hs++;
          if (hs_per_bad <= 3) $display("HSYNC period %0d px at native frame %0d", px - hs_prev, frame);
        end
        hs_prev = px;
      end
      if (o_de && !o_de_d) begin
        de_lines++;
        if (waiting_de) begin
          to_de[o_field] = px - vs_px;            // by the field that follows the vsync
          to_de_ok[o_field] = 1'b1;
          waiting_de = 0;
        end
      end
      if (o_vs && !o_vs_d) begin
        if (vs_prev != 0 && nint < 64) begin vs_int[nint] = $time - vs_prev; nint++; end
        // R939: the interval in output pixels against one native frame (N0 - 1/2 lines), in half lines; and whether the
        // field label repeated (the pairing swapping the fields). The vsync placed for a repeated label is the one in
        // the field before it, so an interval off one native frame must be followed by a repeat at the next vsync.
        if (vs_seen >= 4 && frame >= 5) begin
          automatic longint d = (px - vs_px) - ipx_nat;
          automatic logic   rp = (o_field == vs_field);
          n_vsi++;
          if (rp) ev_rep++;
          if (pend_dev && !rp) ev_vsd_norep++;
          pend_dev = (d != 0);
          if (d != 0) begin
            ev_vsd++;
            if (d % 328 != 0 || d / 328 > 1 || d / 328 < -1) ev_vsd_big++;
            if (d % 328 == 0 && d / 328 >= -4 && d / 328 <= 4) vsd_hist[int'(d / 328)]++;
            if (ev_vsd <= 4) $display("VSYNC interval %0d px (%0d half lines from a native frame), label %0d after %0d, native frame %0d",
                                      px - vs_px, d / 328, o_field, vs_field, frame);
          end
        end
        if (skip_vs > 0) skip_vs--;
        else if (vs_seen >= 4 && de_lines != 240) begin
          field_lines_bad++;
          if (field_lines_bad <= 3) $display("FIELD with %0d visible lines", de_lines);
        end
        vs_prev = $time;
        vs_px = px;
        vs_field = o_field;
        waiting_de = 1;
        vs_seen++;
        de_lines = 0;
      end
    end
  end

  // ---- run, then report
  initial begin
    for (int i = -4; i <= 4; i++) vsd_hist[i] = 0;
    for (int i = 0; i < 5; i++) nlen[i] = 0;
    #1 ipx_nat = nl ? 64'd172200 : ml ? 64'd176136 : 64'd179416;   // (N0 - 1/2) x 656
    wait (rst_n);
    wait (frame >= nframes);
    $display("mode %0d (%s), ring %0d lines, D_PX %0d: %0d native frames (%s)", mode, nl ? "262/263" : ml ? "268/269" : "273/274",
             RING, nl ? DPX_N : ml ? DPX_M : DPX_I, frame, design_vals ? "the design's values" : "OVERRIDDEN, not the design's");
    $display("  pixels checked %0d, blend mismatches %0d, ring mismatches %0d, row-step mismatches %0d", checked, fails, ring_fails, step_fails);
    $display("  hsync %0d..%0d px, visible %0d..%0d px a line, line period faults %0d, fields not 240 lines %0d, vsyncs %0d",
             hs_min, hs_max, de_min, de_max, hs_per_bad, field_lines_bad, vs_seen);
    $display("  image cadence %0d phase %0d: output frames %0d, made of two images %0d", cad, cph, pairs, pair_bad);
    for (int i = 4; i < nint; i++) if (vs_int[i] != 64'd17384000) begin
      vs_bad++;
      if (vs_bad <= 3) $display("  vsync interval %0d: %0d ns (native frame = 17384000 ns)", i, vs_int[i]);
    end
    $display("  vsync intervals checked %0d, not one native frame %0d", nint > 4 ? nint - 4 : 0, vs_bad);
    $display("  output hash %016h over %0d output pixels", ohash, px);
    $display("EVENTS over %0d native frames (%.1f s): line period faults %0d, re-alignments that moved the output %0d,",
             frame - 5, real'(frame - 5) / 57.524, ev_hs, al_moved);
    $display("EVENTS   vsync intervals %0d: off one native frame %0d (by -1/2 line %0d, +1/2 line %0d, other %0d), repeated field labels %0d, off and not followed by a repeat %0d",
             n_vsi, ev_vsd, vsd_hist[-1], vsd_hist[1], ev_vsd_big, ev_rep, ev_vsd_norep);
    if (rnd != 0)
      $display("EVENTS   cadence: %0d images, lengths 1/2/3/4 frames %0d/%0d/%0d/%0d; pairing %s; output frames %0d, of two images %0d (%.1f%%)",
               nimg, nlen[1], nlen[2], nlen[3], nlen[4], (pe != 0) ? "on" : "off", pairs, pair_bad,
               pairs > 0 ? 100.0 * real'(pair_bad) / real'(pairs) : 0.0);
    $display("  vsync to the first visible line: before field 0 %0d px, before field 1 %0d px (difference %0d, want 328)",
             to_de[0], to_de[1], to_de[1] - to_de[0]);
    $display("  re-alignments %0d, of which moved the output %0d (the pairing lock, at native frame %0d)", al_n, al_moved, relock_frame);
    $display("  margin before the data is written (smallest, ns): %0d   margin before it is overwritten (smallest, ns): %0d",
             min_avail, min_over);
    if (fails == 0 && ring_fails == 0 && step_fails == 0 && checked > 100000 && hs_max == 64 && hs_min == 64 &&
        de_max == 496 && de_min == 496 && hs_per_bad == 0 && field_lines_bad == 0 && nint > 6 &&
        to_de_ok[0] && to_de_ok[1] && to_de[1] - to_de[0] == 328 && al_n > 0 &&
        // R939: the output never moves once locked; a vsync interval is off one native frame only where a field label
        // repeats, and then by half a line; a steady cadence repeats a label at most once (the pairing lock)
        al_moved == 0 && ev_vsd == ev_rep && ev_vsd_norep == 0 && ev_vsd_big == 0 &&
        (rnd != 0 || ev_rep <= ((cad == 2) ? 1 : 0)) && (rnd != 0 || vs_bad <= ((cad == 2) ? 1 : 0)) &&
        min_avail > 1000 && min_over > 1000 &&
        !(rnd == 0 && pe != 0 && cad == 2 && nframes >= 70 && (pairs < 10 || pair_bad != 0))) $display("PASS");
    else $display("FAIL");
    $finish;
  end

  initial begin
    wait (rst_n);
    #(longint'(nframes + 5) * 64'd17384000);
    $display("TIMEOUT");
    $finish;
  end
endmodule
