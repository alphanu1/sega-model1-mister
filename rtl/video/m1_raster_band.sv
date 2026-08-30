// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The rasterizer's band buffer: spans in, pixels out.
//
// WHY A BAND AND NOT A FRAME (decision D3, and the arithmetic that forces it)
//
// The active picture is 496x384. A full framebuffer at 16bpp is 3,047,424 bits,
// which is 372 M10K of a 553-block device with 181 free - it does not fit and
// never did. One 64-row band is 496x64x17 = 539,648 bits, 62 blocks, and 124
// double-buffered. That is what makes the design possible on this part, and it
// is why the quads have to be binned by band and walked once per band rather
// than drawn in one pass.
//
// SEVENTEEN BITS, NOT SIXTEEN. The 3D composites OVER the tilemaps, so "this
// pixel was painted" has to be distinguishable from "this pixel is black" - a
// colour cannot carry that, because 0x0000 is a legal colour the game uses. The
// extra bit costs nothing: an M10K is 10,240 bits and a x20 configuration uses
// all of it, so 496x64x17 and 496x64x16 both land on 62 blocks. Picking 16 to
// save memory would have saved none and lost the distinction.
//
// The colour is RGB565. m1_palette carries RGB888 and the source entries are
// xBGR-555, so 16bpp costs no fidelity - docs/m3-rasterizer-spec.md makes the
// same point about the band's pixel format being a resource decision.
//
// ORDERING IS THE CALLER'S JOB. Model 1 has no Z-buffer: it paints back to
// front, and the sort is in the rasterizer stage (model1_v.cpp:535, z
// descending with submission order as the tie-break). This module therefore
// paints unconditionally - the last write to a pixel wins - and a caller that
// feeds spans out of order gets a wrong picture with no complaint from here.
// That is the same contract MAME's fill_quad has.
//
// MOIRE is a stipple, not a blend: fill_quad's moired variant writes only where
// `!((x ^ y) & 1)`, so half the pixels are left showing whatever was behind.
// Reproduced exactly, including that it is tested against the SCREEN x and y,
// not against the span's own coordinates - a stipple keyed to the span would
// walk with the polygon instead of standing still on the screen.

`timescale 1ns/1ps

module m1_raster_band #(
  parameter int unsigned WIDTH  = 496,   // active pixels per line
  parameter int unsigned HEIGHT = 64,    // rows in one band
  parameter int unsigned AW     = 15     // ceil(log2(WIDTH*HEIGHT))
) (
  input  logic                   clk,
  input  logic                   rst_n,

  // The band's top row on screen. Spans are addressed in SCREEN coordinates and
  // this is what maps them into the buffer, so the caller never computes a
  // buffer address and cannot get the mapping wrong in two places.
  input  logic signed [15:0]     band_y0,

  // Clear the whole band. Held until clear_busy drops.
  input  logic                   clear_req,
  output logic                   clear_busy,

  // Span input, in SCREEN coordinates, x0..x1 INCLUSIVE - the fill unit's
  // contract (docs/m3-rasterizer-spec.md: "span emit [x1>>16, x2>>16]
  // inclusive"). A span outside the band, or entirely off-screen, is accepted
  // and dropped: the binning pass is allowed to be approximate, and making the
  // buffer reject them would push exactness up into the caller for no gain.
  input  logic                   span_valid,
  output logic                   span_ready,
  input  logic signed [15:0]     span_y,
  input  logic signed [15:0]     span_x0,
  input  logic signed [15:0]     span_x1,
  input  logic [15:0]            span_col,   // RGB565
  input  logic                   span_moire,

  // Scanout read port. Registered, one pixel per cycle, independent of the
  // write side so the caller can read while the next band fills.
  input  logic [$clog2(WIDTH)-1:0]  rd_x,
  input  logic [$clog2(HEIGHT)-1:0] rd_row,
  output logic [15:0]            rd_col,
  output logic                   rd_hit,     // 0 = nothing painted, show the 2D

  // Counted, for the bench and the overlay: spans taken, spans dropped as
  // out-of-band, and pixels written. A span count alone cannot tell "the
  // binning is wrong" from "the geometry is empty".
  output logic [15:0]            dbg_spans,
  output logic [15:0]            dbg_dropped,
  output logic [31:0]            dbg_pixels
);

  localparam int unsigned XW = $clog2(WIDTH);
  localparam int unsigned YW = $clog2(HEIGHT);

  // 17 bits: {hit, RGB565}. One write port and one read port, which is a Simple
  // Dual Port M10K and infers cleanly - unlike the tile RAM's case, the two
  // ports here are on the SAME clock, so no altsyncram is needed. See
  // rtl/mem/m1_tdp_ram.sv for when that stops being true.
  (* ramstyle = "M10K" *) logic [16:0] mem [WIDTH*HEIGHT];

  logic [AW-1:0] wr_addr;
  logic [16:0]   wr_data;
  logic          wr_en;

  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
    // Widths stated rather than inferred: rd_row * WIDTH is a 32-bit product and
    // rd_x is 9 bits, and letting the tool reconcile them is how an address
    // silently truncates on a geometry change.
    {rd_hit, rd_col} <= mem[AW'(rd_row) * AW'(WIDTH) + AW'(rd_x)];
  end

  // ------------------------------------------------------------ paint FSM
  typedef enum logic [1:0] { S_IDLE, S_PAINT, S_CLEAR } state_t;
  state_t st;

  logic signed [15:0] cur_x, cur_x1, cur_y;
  logic [15:0]        cur_col;
  logic               cur_moire;
  logic [YW-1:0]      cur_row;
  logic [AW-1:0]      clr_addr;

  // In-band and on-screen tests, both in screen coordinates.
  //
  // The signed compare is kept for clarity, NOT because an unsigned one is
  // wrong here: at 16 bits a negative y_rel reads as >= 32768, fails `< HEIGHT`
  // and is dropped either way. That was checked by mutating this line to
  // `$unsigned(y_rel) < HEIGHT` and finding the bench unchanged at 825,351
  // checks - the two forms are equivalent at this width, and an earlier comment
  // claiming the unsigned form "paints the wrong line" was wrong. They diverge
  // only if the subtraction itself overflows 16 bits, which needs |span_y| and
  // |band_y0| summing past 32767 and cannot happen for a 384-line screen.
  wire signed [15:0] y_rel   = span_y - band_y0;
  wire               in_band = (y_rel >= 0) && (y_rel < $signed(16'(HEIGHT)));
  wire               on_scr  = (span_x1 >= 0) && (span_x0 < $signed(16'(WIDTH)))
                            && (span_x1 >= span_x0);
  wire               takeable = in_band && on_scr;

  // Clipped to the visible width. The fill unit emits screen coordinates that
  // can lie off either edge; clamping here rather than rejecting keeps a
  // partially visible span visible, which is what MAME's viewport clip does.
  wire signed [15:0] clip_x0 = (span_x0 < 0) ? 16'sd0 : span_x0;
  wire signed [15:0] clip_x1 = (span_x1 > $signed(16'(WIDTH-1))) ? $signed(16'(WIDTH-1))
                                                                 : span_x1;

  assign span_ready = (st == S_IDLE) && !clear_req;
  assign clear_busy = (st == S_CLEAR);

  always_comb begin
    wr_en   = 1'b0;
    wr_addr = '0;
    wr_data = '0;
    if (st == S_CLEAR) begin
      wr_en   = 1'b1;
      wr_addr = clr_addr;
      wr_data = 17'd0;                      // hit = 0: show the 2D
    end else if (st == S_PAINT) begin
      // The stipple is tested against SCREEN x and y, per fill_quad's
      // draw_hline_moired: `if(!((x1 ^ y) & 1))`.
      wr_en   = !cur_moire || !((cur_x[0] ^ cur_y[0]));
      wr_addr = AW'(cur_row * WIDTH + XW'(cur_x));
      wr_data = {1'b1, cur_col};
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st          <= S_IDLE;
      cur_x       <= '0; cur_x1 <= '0; cur_y <= '0;
      cur_col     <= '0; cur_moire <= 1'b0; cur_row <= '0;
      clr_addr    <= '0;
      dbg_spans   <= '0; dbg_dropped <= '0; dbg_pixels <= '0;
    end else begin
      case (st)
        S_IDLE: begin
          if (clear_req) begin
            clr_addr <= '0;
            st       <= S_CLEAR;
          end else if (span_valid) begin
            if (takeable) begin
              cur_x     <= clip_x0;
              cur_x1    <= clip_x1;
              cur_y     <= span_y;
              cur_row   <= YW'(y_rel);
              cur_col   <= span_col;
              cur_moire <= span_moire;
              st        <= S_PAINT;
              if (dbg_spans != 16'hffff) dbg_spans <= dbg_spans + 16'd1;
            end else begin
              // Dropped, and counted. Silence here would make an empty picture
              // and a mis-binned one look identical.
              if (dbg_dropped != 16'hffff) dbg_dropped <= dbg_dropped + 16'd1;
            end
          end
        end

        S_PAINT: begin
          if (wr_en) dbg_pixels <= dbg_pixels + 32'd1;
          if (cur_x >= cur_x1) st <= S_IDLE;
          else                 cur_x <= cur_x + 16'sd1;
        end

        S_CLEAR: begin
          if (clr_addr == AW'(WIDTH*HEIGHT - 1)) st <= S_IDLE;
          else                                   clr_addr <= clr_addr + AW'(1);
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
