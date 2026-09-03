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
// Behavioural contract is MAME's model1_v.cpp (BSD-3-Clause, Olivier
// Galibert) — fill_quad, fill_slope, fill_line and draw_hline. Rules and line
// references are written up in docs/m3-rasterizer-spec.md.
//
// Quad filler: one quad in, a stream of horizontal spans out.
//
// The primitive is always a quad. The frustum clipper upstream emits a clipped
// triangle as a quad with a repeated vertex, so there is no triangle path and
// no primitive-type input — degeneracy is data. Two edges walk down from the
// topmost vertex in 16.16 fixed point, one span per scanline, and there is no
// per-pixel arithmetic at all: the cost of this block is the slope divider and
// the accumulators, which is why it is worth measuring before the band buffer
// is designed around it.
//
// Things here that look wrong and are not:
//
//  * x is 32-bit and carries s.x << 16, which **overflows for |s.x| >= 32768**.
//    MAME's spoint_t is int32_t and it does exactly this, so a vertex far off
//    screen wraps rather than saturating. Reproduced, not fixed.
//
//  * The left/right decision is made once per segment, not per scanline. If the
//    two edges cross inside a segment the span stays in the original order and
//    goes empty. That is fill_slope's behaviour.
//
//  * fill_slope covers [y_top, y_bottom) — the bottom scanline belongs to the
//    next segment, and the last scanline of the whole quad is emitted by the
//    fill_line tail. Making the range inclusive double-draws every internal
//    vertex row, which with MOIRE stipple is visible.
//
//  * MAME guards the span with `xx1 <= view->x2 || xx2 >= view->x1`, where && was
//    plainly meant. It is harmless — when the guard is the only thing that would
//    reject, the clamped span is already empty — so only the clamp is
//    implemented here. Behaviour identical, one comparison cheaper.
//
// Not handled here: a quad with exactly two distinct screen vertices is a
// wireframe, which MAME rasterizes with a clipped Bresenham line instead of
// filling. That is a separate unit; this block flags the case on `line_case`
// and retires the quad without emitting. See the spec for why that path is
// MAME improving on the filler rather than known silicon behaviour.
module m1_raster_fill (
  input  logic               clk,
  input  logic               rst_n,

  // Quad in. Screen-space integer vertices, a finished RGB888 colour (lighting
  // and the palette lookup happen upstream in the geometry stage) and the
  // moire stipple flag.
  input  logic               in_valid,
  output logic               in_ready,
  input  logic signed [31:0] in_x0, in_y0,
  input  logic signed [31:0] in_x1, in_y1,
  input  logic signed [31:0] in_x2, in_y2,
  input  logic signed [31:0] in_x3, in_y3,
  input  logic [23:0]        in_col,
  input  logic               in_moire,

  // Viewport, inclusive on all four edges.
  input  logic signed [31:0] view_x1, view_x2, view_y1, view_y2,

  // Span out, inclusive and already clamped. Empty spans are never emitted.
  // Backpressure is real here and not decoration: the band buffer writer runs a
  // pixel loop, so it stalls the walk.
  output logic               span_valid,
  input  logic               span_ready,
  output logic signed [31:0] span_y,
  output logic signed [31:0] span_x0,
  output logic signed [31:0] span_x1,
  output logic [23:0]        span_col,
  output logic               span_moire,

  // One cycle. Note quad_done can land in the same cycle as the quad's last
  // span, and in_ready can rise with that span still in flight — the next quad
  // is accepted and simply stalls at its first emit until the pending one is
  // taken. span_valid is the only authority on span delivery; a consumer that
  // stops listening at quad_done loses the last scanline.
  output logic               quad_done,
  output logic               line_case    // that quad was a wireframe, not filled
);

  localparam logic [4:0] S_IDLE     = 5'd0;
  localparam logic [4:0] S_CLASSIFY = 5'd1;
  localparam logic [4:0] S_FLAT     = 5'd2;
  localparam logic [4:0] S_START1   = 5'd3;
  localparam logic [4:0] S_START2   = 5'd4;
  localparam logic [4:0] S_LOADX    = 5'd5;
  localparam logic [4:0] S_DIVA     = 5'd6;
  localparam logic [4:0] S_DIVAW    = 5'd7;
  localparam logic [4:0] S_DIVB     = 5'd8;
  localparam logic [4:0] S_DIVBW    = 5'd9;
  localparam logic [4:0] S_DECIDE   = 5'd10;
  localparam logic [4:0] S_FS_ENTER = 5'd11;
  localparam logic [4:0] S_FS_MULA  = 5'd12;
  localparam logic [4:0] S_FS_MULB  = 5'd13;
  localparam logic [4:0] S_FS_SWAP  = 5'd14;
  localparam logic [4:0] S_FS_WALK  = 5'd15;
  localparam logic [4:0] S_FS_END   = 5'd16;
  localparam logic [4:0] S_FINAL    = 5'd17;
  localparam logic [4:0] S_DONE     = 5'd18;

  localparam logic [1:0] EM_WALK = 2'd0;   // swapf-ordered edge pair
  localparam logic [1:0] EM_RAW  = 2'd1;   // xa, xb in chain order (fill_line tail)
  localparam logic [1:0] EM_FLAT = 2'd2;   // the flat-quad min/max pair

  logic [4:0] state /* verilator public_flat_rd */;

  // Latched quad. sx/sy are the raw screen coordinates: the wireframe test
  // compares them whole, so the pre-shift value has to survive.
  logic signed [31:0] sx [0:3];
  logic signed [31:0] sy [0:3];
  logic [23:0]        col;
  logic               moire;

  // 16.16 x, exactly as fill_quad forms it: an int32 left shift that discards
  // everything above bit 15.
  logic signed [31:0] px [0:3];
  always_comb begin
    for (int i = 0; i < 4; i++) px[i] = $signed({sx[i][15:0], 16'h0000});
  end

  // Chain state. Edge A walks ps1 downward, edge B walks ps2 upward, both from
  // the top vertex. The doubled 8-entry array in MAME exists to let them run in
  // opposite directions without wrapping logic; here the index is 3 bits and
  // the array read masks to 2.
  logic [2:0]         ps1, ps2;
  logic signed [31:0] xa, xb;     // 16.16 accumulators
  logic signed [31:0] sla, slb;   // 16.16 per scanline
  logic signed [31:0] cury, limy;
  logic               need_a, need_b;

  // Segment state.
  logic signed [31:0] seg_y1;     // exclusive bottom of this segment
  logic signed [31:0] walk_y, walk_end;
  logic               swapf;
  logic               skip_only;  // segment is entirely above the viewport
  logic [1:0]         emit_mode;
  logic signed [31:0] flat_lo, flat_hi;

  logic [2:0]         ps1m1, ps2p1;
  logic signed [31:0] ya_next, yb_next;
  always_comb begin
    ps1m1   = ps1 - 3'd1;
    ps2p1   = ps2 + 3'd1;
    ya_next = sy[ps1m1[1:0]];
    yb_next = sy[ps2p1[1:0]];
  end

  // ---------------------------------------------------------------- dividers
  // TWO, because the two edge slopes are independent and the fill needs both
  // before it can decide anything. Issued one after the other through a single
  // divider they were 49% of the fill unit's time on the reference's peak frame
  // (tb_m1_raster3d, frame 1020: DIVAW+DIVBW 49%, the span walk 31%), and on
  // the board the slowest band each second ran 1.3-1.7 beam slots and went up
  // late - a bar with no 3D across the screen. Issuing both at once halves
  // that wait for a divider's worth of ALM.
  logic               div_start, divb_start;
  logic signed [31:0] div_num, div_den, divb_num, divb_den;
  logic               div_ready, div_valid, div0_unused;
  logic               divb_ready, divb_valid, div0b_unused;
  logic signed [31:0] div_quo, divb_quo;
  logic               got_a, got_b;   // which slopes have come back this segment

  m1_raster_div u_div (
    .clk       (clk),
    .rst_n     (rst_n),
    .in_valid  (div_start),
    .num       (div_num),
    .den       (div_den),
    .ready     (div_ready),
    .out_valid (div_valid),
    .quo       (div_quo),
    .div0      (div0_unused)
  );

  m1_raster_div u_divb (
    .clk       (clk),
    .rst_n     (rst_n),
    .in_valid  (divb_start),
    .num       (divb_num),
    .den       (divb_den),
    .ready     (divb_ready),
    .out_valid (divb_valid),
    .quo       (divb_quo),
    .div0      (div0b_unused)
  );

  // ------------------------------------------------------------- multiplier
  // Shared by the two viewport-skip paths in fill_slope, which advance an edge
  // by delta scanlines in one step. Only the low 32 bits are kept, which is
  // what the C does on int32 and is also what makes an iterative skip and this
  // multiply agree bit for bit.
  logic signed [31:0] mul_delta, mul_sl;
  logic signed [63:0] mul_prod;
  always_comb mul_prod = mul_delta * mul_sl;

  // ------------------------------------------------------- vertex selection
  // Tournaments, arranged so the lowest index wins every tie. MAME scans
  // linearly with a strict comparison, which has the same effect, and the tie
  // rule decides which vertex a degenerate quad starts from.
  logic [1:0] pmin01, pmin23, pmin_c, pmax01, pmax23, pmax_c;
  always_comb begin
    pmin01 = (sy[1] < sy[0]) ? 2'd1 : 2'd0;
    pmin23 = (sy[3] < sy[2]) ? 2'd3 : 2'd2;
    pmin_c = (sy[pmin23] < sy[pmin01]) ? pmin23 : pmin01;
    pmax01 = (sy[1] > sy[0]) ? 2'd1 : 2'd0;
    pmax23 = (sy[3] > sy[2]) ? 2'd3 : 2'd2;
    pmax_c = (sy[pmax23] > sy[pmax01]) ? pmax23 : pmax01;
  end

  logic signed [31:0] xlo01, xlo23, xlo_c, xhi01, xhi23, xhi_c;
  always_comb begin
    xlo01 = (px[1] < px[0]) ? px[1] : px[0];
    xlo23 = (px[3] < px[2]) ? px[3] : px[2];
    xlo_c = (xlo23 < xlo01) ? xlo23 : xlo01;
    xhi01 = (px[1] > px[0]) ? px[1] : px[0];
    xhi23 = (px[3] > px[2]) ? px[3] : px[2];
    xhi_c = (xhi23 > xhi01) ? xhi23 : xhi01;
  end

  // Wireframe test: exactly two distinct screen vertices. All four identical is
  // *not* a wireframe — it falls through to the flat path and paints one pixel.
  logic [3:1] eq_a;
  logic [1:0] b_idx;
  logic       all_eq, two_distinct;
  always_comb begin
    for (int i = 1; i < 4; i++)
      eq_a[i] = (sx[i] == sx[0]) && (sy[i] == sy[0]);

    // Lowest-index-wins priority encoder, written as an overwriting loop
    // because yosys rejects a loop with a break.
    b_idx = 2'd0;
    for (int i = 3; i >= 1; i--)
      if (!eq_a[i]) b_idx = 2'(i);

    all_eq = eq_a[1] && eq_a[2] && eq_a[3];

    two_distinct = !all_eq;
    for (int i = 1; i < 4; i++)
      if (!eq_a[i] && ((sx[i] != sx[b_idx]) || (sy[i] != sy[b_idx])))
        two_distinct = 1'b0;
  end

  // ------------------------------------------------------------- span clamp
  logic signed [31:0] emit_l, emit_r, emit_xl, emit_xr, emit_cl, emit_cr;
  logic               emit_ok;
  always_comb begin
    case (emit_mode)
      EM_FLAT: begin emit_l = flat_lo;              emit_r = flat_hi;              end
      EM_RAW:  begin emit_l = xa;                   emit_r = xb;                   end
      default: begin emit_l = swapf ? xb : xa;      emit_r = swapf ? xa : xb;      end
    endcase

    emit_xl = emit_l >>> 16;
    emit_xr = emit_r >>> 16;
    emit_cl = (emit_xl < view_x1) ? view_x1 : emit_xl;
    emit_cr = (emit_xr > view_x2) ? view_x2 : emit_xr;
    emit_ok = (emit_cl <= emit_cr);
  end

  // ------------------------------------------------------------------- FSM
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      ps1        <= 3'd0;
      ps2        <= 3'd0;
      xa         <= 32'sd0;
      xb         <= 32'sd0;
      sla        <= 32'sd0;
      slb        <= 32'sd0;
      cury       <= 32'sd0;
      limy       <= 32'sd0;
      seg_y1     <= 32'sd0;
      walk_y     <= 32'sd0;
      walk_end   <= 32'sd0;
      swapf      <= 1'b0;
      skip_only  <= 1'b0;
      need_a     <= 1'b0;
      need_b     <= 1'b0;
      emit_mode  <= EM_WALK;
      flat_lo    <= 32'sd0;
      flat_hi    <= 32'sd0;
      col        <= 24'd0;
      moire      <= 1'b0;
      mul_delta  <= 32'sd0;
      mul_sl     <= 32'sd0;
      div_start  <= 1'b0;
      div_num    <= 32'sd0;
      div_den    <= 32'sd0;
      divb_start <= 1'b0;
      divb_num   <= 32'sd0;
      divb_den   <= 32'sd0;
      got_a      <= 1'b0;
      got_b      <= 1'b0;
      span_valid <= 1'b0;
      span_y     <= 32'sd0;
      span_x0    <= 32'sd0;
      span_x1    <= 32'sd0;
      span_col   <= 24'd0;
      span_moire <= 1'b0;
      quad_done  <= 1'b0;
      line_case  <= 1'b0;
      for (int i = 0; i < 4; i++) begin
        sx[i] <= 32'sd0;
        sy[i] <= 32'sd0;
      end
    end else begin
      div_start  <= 1'b0;
      divb_start <= 1'b0;
      quad_done  <= 1'b0;
      line_case <= 1'b0;
      if (span_valid && span_ready) span_valid <= 1'b0;

      case (state)
        S_IDLE: begin
          if (in_valid) begin
            sx[0] <= in_x0; sy[0] <= in_y0;
            sx[1] <= in_x1; sy[1] <= in_y1;
            sx[2] <= in_x2; sy[2] <= in_y2;
            sx[3] <= in_x3; sy[3] <= in_y3;
            col   <= in_col;
            moire <= in_moire;
            state <= S_CLASSIFY;
          end
        end

        // One cycle of pure comparison: wireframe, top and bottom vertices, and
        // the three whole-quad rejects. Order matters — the flat case is taken
        // before the viewport rejects, because fill_line does its own y test.
        S_CLASSIFY: begin
          if (two_distinct) begin
            line_case <= 1'b1;
            quad_done <= 1'b1;
            state     <= S_IDLE;
          end else if (sy[pmin_c] == sy[pmax_c]) begin
            flat_lo   <= xlo_c;
            flat_hi   <= xhi_c;
            cury      <= sy[pmin_c];
            emit_mode <= EM_FLAT;
            state     <= S_FLAT;
          end else if ((sy[pmin_c] > view_y2) || (sy[pmax_c] <= view_y1)) begin
            quad_done <= 1'b1;
            state     <= S_IDLE;
          end else begin
            cury   <= sy[pmin_c];
            limy   <= (sy[pmax_c] > view_y2) ? view_y2 : sy[pmax_c];
            ps1    <= {1'b1, pmin_c};      // pmin + 4
            ps2    <= {1'b0, pmin_c};
            need_a <= 1'b1;
            need_b <= 1'b1;
            state  <= S_START1;
          end
        end

        S_FLAT: begin
          if (!span_valid || span_ready) begin
            if ((cury <= view_y2) && (cury >= view_y1) && emit_ok) begin
              span_valid <= 1'b1;
              span_y     <= cury;
              span_x0    <= emit_cl;
              span_x1    <= emit_cr;
              span_col   <= col;
              span_moire <= moire;
            end
            quad_done <= 1'b1;
            state     <= S_IDLE;
          end
        end

        // The two startup loops: skip every vertex sharing the current y, so
        // the slope denominator below is strictly nonzero.
        S_START1: begin
          if (need_a && (ya_next == cury)) ps1 <= ps1 - 3'd1;
          else                             state <= S_START2;
        end

        S_START2: begin
          if (need_b && (yb_next == cury)) ps2 <= ps2 + 3'd1;
          else                             state <= S_LOADX;
        end

        // Reloading x from the vertex rather than keeping the walked value is
        // what snaps an edge back onto the polygon at each vertex event.
        S_LOADX: begin
          if (need_a) xa <= px[ps1[1:0]];
          if (need_b) xb <= px[ps2[1:0]];
          state <= S_DIVA;
        end

        // Both slopes at once. A side that does not need a new slope is
        // marked collected up front; both dividers are idle here because the
        // previous segment waited for both.
        S_DIVA: begin
          if (div_ready && !div_start && divb_ready && !divb_start) begin
            if (need_a) begin
              div_num   <= xa - px[ps1m1[1:0]];
              div_den   <= cury - ya_next;
              div_start <= 1'b1;
            end
            if (need_b) begin
              divb_num   <= xb - px[ps2p1[1:0]];
              divb_den   <= cury - yb_next;
              divb_start <= 1'b1;
            end
            got_a <= !need_a;
            got_b <= !need_b;
            state <= S_DIVAW;
          end
        end

        S_DIVAW: begin
          if (div_valid)  begin sla <= div_quo;  got_a <= 1'b1; end
          if (divb_valid) begin slb <= divb_quo; got_b <= 1'b1; end
          if ((got_a || div_valid) && (got_b || divb_valid)) state <= S_DECIDE;
        end

        // Which chain reaches its next vertex first decides how far this
        // segment runs and which side gets reloaded afterwards.
        S_DECIDE: begin
          if (ya_next == yb_next) begin
            seg_y1 <= ya_next;
            need_a <= 1'b1;
            need_b <= 1'b1;
          end else if (ya_next < yb_next) begin
            seg_y1 <= ya_next;
            need_a <= 1'b1;
            need_b <= 1'b0;
          end else begin
            seg_y1 <= yb_next;
            need_a <= 1'b0;
            need_b <= 1'b1;
          end
          state <= S_FS_ENTER;
        end

        // fill_slope, pre-clip. Note the first case returns without touching
        // the accumulators at all, which is why the caller's edges survive a
        // segment that starts below the viewport.
        S_FS_ENTER: begin
          if (cury > view_y2) begin
            state <= S_FS_END;
          end else if (seg_y1 <= view_y1) begin
            mul_delta <= seg_y1 - cury;
            mul_sl    <= sla;
            skip_only <= 1'b1;
            state     <= S_FS_MULA;
          end else begin
            walk_end <= (seg_y1 > view_y2) ? (view_y2 + 32'sd1) : seg_y1;
            if (cury < view_y1) begin
              mul_delta <= view_y1 - cury;
              mul_sl    <= sla;
              skip_only <= 1'b0;
              walk_y    <= view_y1;
              state     <= S_FS_MULA;
            end else begin
              walk_y <= cury;
              state  <= S_FS_SWAP;
            end
          end
        end

        S_FS_MULA: begin
          xa     <= xa + mul_prod[31:0];
          mul_sl <= slb;
          state  <= S_FS_MULB;
        end

        S_FS_MULB: begin
          xb    <= xb + mul_prod[31:0];
          state <= skip_only ? S_FS_END : S_FS_SWAP;
        end

        // Left/right is decided here, once, and held for the whole segment.
        S_FS_SWAP: begin
          swapf     <= (xa > xb) || ((xa == xb) && (sla > slb));
          emit_mode <= EM_WALK;
          state     <= S_FS_WALK;
        end

        S_FS_WALK: begin
          if (walk_y >= walk_end) begin
            state <= S_FS_END;
          end else if (!span_valid || span_ready) begin
            if (emit_ok) begin
              span_valid <= 1'b1;
              span_y     <= walk_y;
              span_x0    <= emit_cl;
              span_x1    <= emit_cr;
              span_col   <= col;
              span_moire <= moire;
            end
            xa     <= xa + sla;
            xb     <= xb + slb;
            walk_y <= walk_y + 32'sd1;
          end
        end

        S_FS_END: begin
          cury      <= seg_y1;
          skip_only <= 1'b0;
          if (seg_y1 >= limy) begin
            emit_mode <= EM_RAW;
            state     <= S_FINAL;
          end else begin
            if (need_a) ps1 <= ps1 - 3'd1;
            if (need_b) ps2 <= ps2 + 3'd1;
            state <= S_START1;
          end
        end

        // The last scanline of the quad, drawn unordered: fill_line does not
        // sort its two x values, so a crossed pair emits nothing.
        S_FINAL: begin
          if (!span_valid || span_ready) begin
            if ((cury == limy) && (cury <= view_y2) && (cury >= view_y1) && emit_ok) begin
              span_valid <= 1'b1;
              span_y     <= cury;
              span_x0    <= emit_cl;
              span_x1    <= emit_cr;
              span_col   <= col;
              span_moire <= moire;
            end
            state <= S_DONE;
          end
        end

        default: begin // S_DONE
          quad_done <= 1'b1;
          emit_mode <= EM_WALK;
          state     <= S_IDLE;
        end
      endcase
    end
  end

  always_comb in_ready = (state == S_IDLE);

endmodule
