// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// FROM THE MODEL 2 CORE, sega-model2-mister at 47ad2e2 (main), rtl/video/m2_fb_read.sv.
// Changed for Model 1: the module name, and the line buffers hold the band
// buffer's 17 bits (painted + RGB565) rather than Model 2's 25, so the
// picture out is the band buffer's bit for bit.
// The R-numbers below are entries in that project's design study
// (docs/model2a-design-study.md), where each failure mode is recorded.
//
// THE DDR3 FRAMEBUFFER, READ BACK A LINE AT A TIME.
//
// This replaces the read side of m2_raster_band. The interface is deliberately
// the same -- rd_x, rd_row -> rd_col, rd_hit -- so m2_tile_mixer composites the
// 3D over the tilemap exactly as it does today and does not know the pixels
// now come from DDR3.
//
// ONE BURST A LINE, ISSUED A LINE EARLY, AND THAT IS THE WHOLE SAFETY ARGUMENT.
// R347: this memory is ~200 ns typical and UNBOUNDED in the worst case because
// the bridge is shared with the ARM. Reading per pixel would put that in the
// beam's path. A line is 512 pixels at two per beat -- 256 beats, one command --
// and it is requested while the beam is still drawing the PREVIOUS line:
//
//     a line at 6 MHz pixel clock is ~30 us of slack
//     the burst itself is 256 beats, ~2.6 us at 100 MHz
//     the latency it amortises is ~200 ns -- under 8% of the transfer
//
// So the worst case has an order of magnitude of room before anything is late,
// where a per-pixel read would have none. The same arithmetic is why the
// Z80 and the sample fetchers are a HARDER problem than the framebuffer, not an
// easier one (R347).
//
// TWO LINE BUFFERS, IN M10K. 2 x 512 x 25 bits is about 26 Kbit, three blocks,
// against the twenty-four the three band buffers cost. The net is twenty-one
// blocks back on a device that reads 553 of 553.

`timescale 1ns/1ps

module m1_fb_read #(
  parameter int unsigned WIDTH  = 496,
  parameter int unsigned STRIDE = 512,     // pixels a line in DDR3, a power of two
  // R655: HOW FAR AHEAD, AND ON THE BOARD IT MATTERS. Fetched one line ahead
  // into two buffers, a line had 41 us and no slack: the FB self-test (R653)
  // found 55-71 rows a frame shown with the data of the row two above --
  // each line's fetch landing after its display began -- clustered at the
  // top of the frame, where the writer floods DDR3 (the list-clear, the new
  // draw) and the reads queue behind those writes inside the HPS controller.
  // Four buffers, fetched LA lines ahead: LA-1 lines of slack.
  parameter int unsigned LA     = 3,
  parameter int unsigned V_TOTAL = 424
) (
  input  logic        clk,        // DDR3 side
  input  logic        rd_clk,     // video side -- the mixer reads here
  input  logic        rst_n,

  // Which buffer the scanout is showing. The fill writes the other.
  input  logic        fb_sel,

  // ---- fetch control: "the beam is about to need line N"
  input  logic        line_req,           // one pulse per scanline
  input  logic [8:0]  line_y,
  // R682: 15 kHz INTERLACED. line_y is then a DISPLAYED line of a field (0-191)
  // and line_f that field; the buffers, the order and the look-ahead all run in
  // displayed lines, and only the DDR3 address is {line, field}.
  input  logic        il,
  input  logic        line_f,
  output logic        line_ready,         // that line is in the buffer
  output logic        hungry,             // R655: a line is being fetched or is waiting to be

  // ---- DDR3
  output logic        m_req,
  output logic        m_we,
  output logic [24:0] m_addr,
  output logic [7:0]  m_blen,
  input  logic        m_rvalid,
  // Each 32-bit pixel is {7'd0, painted, col24}, so the pad bits are unread.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [63:0] m_dout,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic        m_ack,

  // ---- the mixer side, shaped exactly like m2_raster_band's
  // R354: WHICH LINE BUFFER, BY PARITY, so nothing crosses the clock boundary.
  // The obvious design has the DDR3 side toggle a "filling" flag and the video
  // side synchronise it -- but that flag must not change mid-line, and a
  // synchroniser gives no such guarantee. Line parity is derived independently
  // in each domain from a counter each already has: the fill puts line N in
  // buffer N[0], and the mixer drawing line N reads buffer N[0]. No CDC, and no
  // way for the two to disagree about which buffer is which.
  input  logic [1:0]  rd_buf,             // R655: the line being shown, mod 4
  input  logic [$clog2(WIDTH)-1:0] rd_x,
  output logic [15:0] rd_col,     // MODEL 1: RGB565, as m1_raster_band
  output logic        rd_hit,

  // R371: SIXTEEN BITS, because sixteen is what the debug stream reports.
  // A counter wider than its field is flip-flops nobody can ever read.
  output logic [15:0] dbg_lines,
  output logic [15:0] dbg_late,         // asked for a line that was not ready
  // R364: WHERE IT IS STUCK, not merely that it is. `lines 0` with nothing in
  // flight fits both "never asked" and "asked and never answered", and those
  // need opposite fixes. R_REQ means the request was issued and the first beat
  // never came back; R_FILL means beats came and the acknowledge did not.
  output logic [1:0]  dbg_st,
  output logic        dbg_busy,
  // R370: EVERY ACKNOWLEDGE THIS MODULE SEES, in whatever state it is in.
  // The board says m2_ddr3 issued 4 and this module completed 3 lines, so one
  // was lost -- and one is enough to wedge the port for ever. Counting them
  // where they ARRIVE, rather than only where they are acted on, splits the two
  // remaining possibilities: fewer here than m2_ddr3 issued means the arbiter
  // is not routing them; the same here but fewer lines means they arrive in a
  // state that ignores them.
  output logic [15:0] dbg_acks_seen
);

  // TWO PIXELS A BEAT, AND ONLY THE VISIBLE ONES. A 512-pixel stride is 256
  // beats and DDRAM_BURSTCNT IS EIGHT BITS -- 8'(256) is zero, so the burst
  // never ran and every line came back empty. 496 visible pixels are 248 beats,
  // inside the field with room. The stride stays a power of two because the
  // line ADDRESS is a shift; only the transfer is trimmed to what is shown.
  // MODEL 1: THE LINE IS 132 BEATS, NOT 248 (m1_fb_flush writes it): 124
  // words of RGB565, four pixels a word, then eight words of painted bits,
  // one a pixel. Half Model 2's 32-bit pixel's traffic, on the copy and here.
  localparam int unsigned GRPS  = (WIDTH + 3) / 4;      // 124
  localparam int unsigned FWDS  = (WIDTH + 63) / 64;    // 8
  localparam int unsigned BEATS = GRPS + FWDS;          // 132

  assign m_we = 1'b0;

  // Ping-pong: the mixer reads one while the other fills.
  //
  // R361: EVEN AND ODD PIXELS ARE SEPARATE MEMORIES, AND THAT IS NOT A
  // MICRO-OPTIMISATION -- IT IS THE DIFFERENCE BETWEEN M10K AND 6,495 ALUTS.
  //
  // A beat carries two pixels and they were written to one array in one cycle,
  // while the mixer read the same array on rd_clk. That is THREE ports on a
  // memory that has two, so Quartus inferred none of it and built 512 x 25 x 2
  // bits of flip-flops: the fit came back at 118% of the device with this
  // module alone accounting for the whole overrun. Splitting by the low address
  // bit gives each array one write port and one read port -- a simple dual
  // port, which is what M10K is -- and four of them cover both buffers.
  // m2_raster_band solved the identical problem with four banks; the pattern
  // was already in the tree and this module did not use it.
  // R655: four buffers, even and odd pixels still in separate memories (one
  // write port and one read port each), the buffer in the top address bits.
  // MODEL 1: the colour in four banks, pixel x in bank x mod 4 (a beat is
  // four pixels, one into each: one write port and one read port a memory,
  // R361's rule), and the painted bits a 64-bit word at a time.
  (* ramstyle = "M10K" *) logic [15:0] lbc0 [4*128];
  (* ramstyle = "M10K" *) logic [15:0] lbc1 [4*128];
  (* ramstyle = "M10K" *) logic [15:0] lbc2 [4*128];
  (* ramstyle = "M10K" *) logic [15:0] lbc3 [4*128];
  (* ramstyle = "M10K" *) logic [63:0] lbf  [4*8];
  logic [15:0] rd_q0, rd_q1, rd_q2, rd_q3;
  logic [63:0] rd_qf;
  wire  [1:0]  fill_buf = y_r[1:0];       // line N fills buffer N mod 4

  logic [8:0]  wp;                        // pixel being written
  logic [8:0]  y_r;
  logic        busy, have;

  // The video side reads in ITS OWN clock domain, as m2_raster_band does.
  // R361: THE EVEN/ODD SELECT IS DELAYED WITH THE DATA. The memory output is a
  // cycle behind rd_x, so choosing the half with the CURRENT rd_x[0] would pick
  // the wrong one on every pixel. rd_buf needs no such delay: it is the line
  // parity and changes once a line, not once a pixel.
  logic [5:0] rd_x_q;
  always_ff @(posedge rd_clk) begin
    rd_q0 <= lbc0[{rd_buf, rd_x[8:2]}];
    rd_q1 <= lbc1[{rd_buf, rd_x[8:2]}];
    rd_q2 <= lbc2[{rd_buf, rd_x[8:2]}];
    rd_q3 <= lbc3[{rd_buf, rd_x[8:2]}];
    rd_qf <= lbf[{rd_buf, rd_x[8:6]}];
    rd_x_q <= rd_x[5:0];
  end

  always_comb begin
    case (rd_x_q[1:0])
      2'd0:    rd_col = rd_q0;
      2'd1:    rd_col = rd_q1;
      2'd2:    rd_col = rd_q2;
      default: rd_col = rd_q3;
    endcase
  end
  assign rd_hit = rd_qf[rd_x_q];

  // A beat into the line buffers: a colour word to the four banks, or a word
  // of painted bits.
  task automatic put_beat(input logic [1:0] b, input logic [8:0] w, input logic [63:0] d);
    if (w < 9'(GRPS)) begin
      lbc0[{b, w[6:0]}] <= d[15:0];
      lbc1[{b, w[6:0]}] <= d[31:16];
      lbc2[{b, w[6:0]}] <= d[47:32];
      lbc3[{b, w[6:0]}] <= d[63:48];
    end else lbf[{b, 3'(w - 9'(GRPS))}] <= d;
  endtask

  // R360: THE BUFFER SELECT HAS TO SURVIVE THE MULTIPLY. This was
  // `{fb_sel, 24'(y_r)} * 25'(STRIDE/2)`, which places fb_sel at bit 24 and
  // then multiplies by 256 -- so it lands at bit 32 of a TWENTY-FIVE bit
  // address and is gone. Both buffers were the same memory, the double buffer
  // was not double, and the scanout read the frame being drawn. The line
  // number is nine bits because a buffer is 512 lines, so the select belongs
  // at bit 9 before the shift and bit 17 after it.
  logic       f_r, tgt_f;               // R682: the field of y_r, of tgt_y
  assign m_addr = {fb_sel, il ? {y_r[7:0], f_r} : 9'(y_r)} * 25'(STRIDE / 2);
  assign m_blen = 8'(BEATS);
  assign line_ready = have;

  // R655: LATE MEANS SHOWN BEFORE IT LANDED. The newest request (line_y) is
  // LA scanlines ahead of the line being shown; a line finishing when the
  // newest request is LA or more past it is being shown already. (The old
  // count -- a request arriving while busy -- missed every line that landed
  // part way through its own display, which is what the board was doing.)
  // R682: interlaced, the wrap is a field's lines (274 -- the longer field;
  // one line of slack on the shorter never makes a late line look early by 3)
  wire [9:0] vtot_e = il ? 10'd274 : 10'(V_TOTAL);
  wire [9:0] ahead = (10'(line_y) >= 10'(y_r)) ? 10'(line_y) - 10'(y_r)
                                               : 10'(line_y) + vtot_e - 10'(y_r);
  wire       landed_late = (ahead >= 10'(LA));
  // R655: the next line to fetch and the newest asked for; lines are the
  // visible ones, 0..SCR_LINES-1, in order and wrapping.
  localparam int unsigned SCR_LINES = 384;
  logic [8:0] next_y, tgt_y;
  wire  [8:0] last  = il ? 9'(SCR_LINES / 2 - 1) : 9'(SCR_LINES - 1);   // R682
  // >= , not ==: the reset target (383) is past a field's last line (191), and
  // chasing it fetched a whole field of lines after every switch into
  // interlace (tb_m2_raster3d M2_R3D_IL: 192 lines landed late at start)
  wire  [8:0] tgt_n = (tgt_y >= last) ? 9'd0 : tgt_y + 9'd1;
  wire        pend  = (next_y != tgt_n);
  assign hungry = pend || busy;
  typedef enum logic [1:0] { R_IDLE, R_REQ, R_FILL } st_t;
  st_t st;
  assign dbg_st = st;
  assign dbg_busy = busy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= R_IDLE; m_req <= 1'b0; wp <= 9'd0; y_r <= 9'd0;
      busy <= 1'b0; have <= 1'b0;
      next_y <= 9'd0; tgt_y <= 9'(SCR_LINES - 1); f_r <= 1'b0; tgt_f <= 1'b0;
      dbg_lines <= '0; dbg_late <= '0; dbg_acks_seen <= 16'd0;
    end else begin
      if (m_ack && !(&dbg_acks_seen)) dbg_acks_seen <= dbg_acks_seen + 16'd1;   // R370

      // R362: A LATE REQUEST IS DROPPED, NOT APPLIED. y_r was taken on every
      // line_req whether or not a burst was in flight, and m_addr is derived
      // from it -- so a late request moved the address of a transfer the bridge
      // was still counting beats for. Avalon requires it constant for the whole
      // burst. The master latches it now as well (R362), so this is belt and
      // braces; but taking a new line while the last has not landed was wrong
      // on its own terms too -- it abandons a fetch that is nearly done in
      // favour of one that cannot possibly arrive sooner.
      // R655: A REQUEST IS NEVER DROPPED. With lines asked for LA ahead and a
      // buffer each, a request arriving during a fetch is simply the next to
      // do: the newest line asked for is remembered and the lines are fetched
      // in order until the fetches catch up with it. (R362's drop lost the
      // line outright -- on the board the first lines of every frame, whose
      // requests come one a line while the writer is flooding the bridge.)
      if (line_req) begin tgt_y <= line_y; tgt_f <= line_f; have <= 1'b0; end

      case (st)
        R_IDLE: if (pend) begin
          y_r  <= next_y;
          // R682: a line up to the target is the target's field; past it (the
          // order wraps to reach the target) the field before
          f_r  <= il && ((next_y <= tgt_y) ? tgt_f : ~tgt_f);
          have <= 1'b0;
          m_req <= 1'b1; wp <= 9'd0; busy <= 1'b1; st <= R_REQ;
        end

        // Held until taken -- a pulsed request is lost to a busy bridge (R348).
        // The FIRST beat can arrive in this state, and it is a whole beat like
        // any other: an earlier draft wrote only its low half and did not
        // advance wp, which silently dropped pixel 1 of every line.
        // R368: AND THE ACKNOWLEDGE IS HANDLED HERE TOO.
        //
        // This state watched only `m_rvalid`. An acknowledge arriving while
        // still in R_REQ was dropped on the floor -- and that happens whenever
        // a burst's first beat is also its last, because rvalid and ack then
        // share a cycle. The reader would sit in R_FILL for ever, `busy` never
        // clears, every later line_req counts as late, and the arbiter keeps a
        // grant nobody will ever release. That is exactly the state phase 11
        // captured on the board: reader R_FILL, arbiter busy with owner=reader,
        // the master idle, and `dbg_lat_last` proving a transfer HAD completed
        // and issued an acknowledge that nothing acted on.
        //
        // A state that can receive a handshake must handle it in every state it
        // can arrive in, not only the one where it is expected.
        R_REQ: begin
          if (m_rvalid) begin
            m_req <= 1'b0;
            put_beat(fill_buf, wp, m_dout);   // R361: one write port each; R655
            wp <= wp + 9'd1;
            st <= R_FILL;
          end
          // Last, so a cycle carrying BOTH still retires the line: the beat is
          // written above and the transfer ends here.
          if (m_ack) begin
            m_req <= 1'b0;
            busy  <= 1'b0;
            have  <= 1'b1;
            if (!(&dbg_lines)) dbg_lines <= dbg_lines + 16'd1;
            if (landed_late && !(&dbg_late)) dbg_late <= dbg_late + 16'd1;   // R655
            next_y <= (y_r == last) ? 9'd0 : y_r + 9'd1;   // R655
            st    <= R_IDLE;
          end
        end

        default: begin
          if (m_rvalid) begin
            // Two pixels a beat, low half first.
            put_beat(fill_buf, wp, m_dout);   // R361: one write port each; R655
            wp <= wp + 9'd1;
          end
          if (m_ack) begin
            busy <= 1'b0;
            have <= 1'b1;
            if (!(&dbg_lines)) dbg_lines <= dbg_lines + 16'd1;
            if (landed_late && !(&dbg_late)) dbg_late <= dbg_late + 16'd1;   // R655
            next_y <= (y_r == last) ? 9'd0 : y_r + 9'd1;   // R655
            st       <= R_IDLE;
          end
        end
      endcase
    end
  end

endmodule
