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
// GAME SPEED, MEASURED ON THE BOARD, OVER THE PRINTF CHANNEL.
//
// Simulation says the game runs at 65% of hardware speed and the instruction
// rate agrees at 67%. Ben times the MiSTer against real running time and reads
// about a third. Both cannot describe the same machine, and the two answers
// call for completely different work - at 65% it is memory latency, at 33%
// something is being waited on that simulation does not reproduce. So measure
// the board rather than infer it.
//
// THE METRIC IS THE DISPLAY-LIST SWAP, because it needs no modelling: the game
// flips listctl's buffer select once per completed logic frame, and the
// reference's rate is measured at exactly 2 video frames - 993 flips of 996,
// tools/mame_listctl_rate.lua. So frames-per-swap IS the speed ratio.
//
//     2.00 frames a swap   100% of hardware speed
//     3.04                  65%   (what simulation measures)
//     6.00                  33%   (what the board looks like)
//
// One line a second over rtl/io/m1_uart_tx.sv, which drives UART_TXD into the
// HPS's own ttyS1. Read it with the console's getty out of the way, since
// /proc/cmdline carries console=ttyS0,115200:
//
//     ssh root@<mister> "stty -F /dev/ttyS1 115200 raw -echo; cat /dev/ttyS1"
//
// IT IS ttyS1, NOT ttyS0, AND THERE IS NO GETTY TO KILL. Measured on the board
// 2026-09-01: /proc/tty/driver/serial shows port 0 (ttyS0, mmio FFC02000) is the
// console with rx:0, and port 1 (ttyS1, mmio FFC03000) carrying rx:460058 - our
// bytes. sys_top wires emu's UART_TXD into cyclonev_hps_interface_peripheral_uart,
// which is the HPS's SECOND uart; ttyS0 is the physical console header and never
// sees a byte of this. The old instruction also piped through `pgrep`, which does
// not exist on the MiSTer's BusyBox, so the kill was a silent no-op - and killing
// it was never needed, because nothing holds ttyS1.
//
// HEX, NOT DECIMAL. A binary-to-decimal conversion is a divider and a state
// machine for something a human reads once; a nibble to ASCII is four gates.
// 24 bytes a second against 11,520 is nothing, and m1_uart_tx drops rather than
// stalls, so a debug channel can never hold up the design.

`timescale 1ns/1ps

module m1_speed_report #(
  parameter int unsigned CLK_HZ  = 80_000_000,
  parameter int unsigned BAUD    = 115_200,
  // Video frames between reports. 58 is about a second at 57.52 Hz, and the
  // exact figure does not matter because the count of frames is reported too.
  parameter int unsigned PERIOD  = 58
) (
  input  logic clk,
  input  logic rst_n,

  input  logic vblank,          // one pulse per video frame
  input  logic list_sel,        // listctl bit 6, the display-list buffer select
  // NOT BANDS. This is wired to m1_raster3d's dbg_frames, which increments once
  // per COMPLETED GEOMETRY PASS - at P_SORTW, after the sort - and says nothing
  // about how many of the 24 bands were drawn. The old comment claimed bands
  // and cost a wrong diagnosis: on hardware B advances ~20 a second against ~28
  // display-list swaps, which is 8 logic frames a second completing no new
  // geometry, and reading it as "bands" hides that completely.
  input  logic [15:0] bands,    // completed 3D geometry passes, free-running
  input  logic [15:0] passes,   // 3D geometry passes, free-running
  // THE COPROCESSOR'S OWN STATE, because the board keeps showing a black screen
  // with the 3D layer receiving nothing and the existing fields cannot say why.
  // Parked at microcode 0x004c means starved of commands; anywhere else means it
  // is executing; retires stuck at zero means it never left reset at all. Those
  // are different faults and five builds have been spent guessing between them.
  // BANDS ACTUALLY PRESENTED, which is the one thing the other counters cannot
  // distinguish. `bands` above counts completed GEOMETRY PASSES; this counts
  // ev_present, a band handed to the display. Expected is 24 x the video frame
  // rate, ~1,380 a second. If N is at rate while B is low, the passes are being
  // lost and the display is repeating a stale one; if N is short, bands are
  // genuinely not reaching the screen. Simulation shows 24 on 668 of 669
  // frames, so whatever Ben sees on the board is not reproduced there and this
  // is the instrument that says which of the two it is.
  // THE V60'S PC, because the crash needs it and the overlay cannot show a
  // sequence. On 2026-09-03 the five-minute fault was captured for the first
  // time: video timing alive, V60 swapping display lists at full rate, bands
  // still presented, and the screen entirely black - 2D as well as 3D. That
  // cannot be a dead coprocessor, since the tile path never touches the TGP.
  // Whether the GAME has crashed or the hardware has stopped drawing is one
  // reading of this value apart.
  // The V60's pc LATCHED at the instant the coprocessor stopped retiring, as
  // opposed to v60_pc which is sampled once a second and cannot catch a
  // transition. Zero until the first stall. See m1_integrated for the detector.
  input  logic [23:0] stall_pc,
  input  logic [23:0] v60_pc,
  input  logic [15:0] bands_pres,
  input  logic [15:0] tgp_pc,      // coprocessor program counter
  input  logic [15:0] tgp_retires, // free-running retire count
  // How long the last completed geometry pass took, in clk_3d cycles. Sent as
  // L=, in units of 256 cycles: a frame is 818,133 cycles = 0x0C7C, so a pass
  // that reads above that has run over a frame - which is the whole question
  // the field exists to answer on the board. See m1_raster3d.
  input  logic [31:0] pass_cycles,
  // The last band's fill in clk_3d cycles, and bands presented late. W= is the
  // WORST band fill seen in the reporting window, in 16-cycle units: a band's
  // beam slot is 34,089 cycles = 0x0853 in those units, and above it the band
  // went up after the beam had started on it. T= is the late count itself.
  input  logic [31:0] band_cycles,
  input  logic [15:0] late,
  // D= quads dropped by the store, summed over passes; H= passes that walked
  // fewer than half the previous pass's objects. Both free-running.
  input  logic [15:0] dropped,
  input  logic [15:0] short_passes,
  // THE 3D LAYER'S LEFT CLIP PLANE, as a screen coordinate.
  //
  // The left half of the 3D vanishes on corners and STAYS gone while the car
  // is parked, which is the shape of a latched register rather than a
  // per-frame effect: vx1 becomes the frustum's left plane and everything
  // left of it is clipped away before it is ever stored, which is also why
  // the dropped-quad counter reads zero throughout. Simulation cannot answer
  // this - 700 M cycles never reached gameplay - so it goes on the wire.
  input  logic [15:0] view_x1,
  // THE TILE FETCH'S DEADLINE MISSES, free-running.
  //
  // Ben sees the 2D tiles overrun as well as the 3D dropping out, and two
  // consumers of one memory controller failing together is a bandwidth
  // signature. This counter has always existed and has never reached the
  // wire - it was a row on the debug overlay, which is now off - so his
  // observation has had no number behind it. It is the direct measurement of
  // whether the 2D is starved, and it decides whether raising the SDRAM
  // clock is the answer or just a plausible story.
  input  logic [15:0] fetch_miss,

  // The memory's own occupancy and the tile port's wait, each 0x00 to 0xFF
  // over a 13 ms window. These separate the two explanations for a tile
  // overrun: a saturated controller, or an idle one that arbitrates badly.
  // Pixels the fill emitted into each half of the screen, in units of 1024
  // and free-running. A= is the left half, Z= the right. See m1_raster3d.
  // VERTICES THE QUAD STORE COULD NOT REPRESENT, free-running.
  //
  // The store keeps SIXTEEN BIT screen coordinates, and m1_geo_clip's header
  // says what happens when one does not fit: a road vertex projecting to
  // x = 100,000 truncates to -31,072 and the quad is drawn as a slab on the
  // opposite side of the screen. Objects that fit on screen never notice; the
  // road, which runs to the horizon and off both sides, always does.
  //
  // Ben sees exactly that - the road and the scenery gone from the left of the
  // screen while the cars stay. The counter that would confirm it has existed
  // all along and has never left the chip. G= is it.
  input  logic [15:0] vert_oob,

  // THE GEOMETRY FUNNEL'S TWO MISSING NUMBERS.
  //
  // E= backface culls over the whole run, U= quads standing in the store after
  // the last pass. Ben sees the road and the scenery vanish while the cars
  // stay, and that is what a facing test with the wrong sign does: a
  // single-sided ground plane culled wrongly disappears entirely, while a
  // closed object always keeps some faces pointing at the eye. If E spikes as
  // the road goes, the cull is the fault; if U falls with E flat, the quads are
  // lost somewhere after it.
  // Pixels SCANOUT read back as a hit, per screen half, units of 1024. Read
  // against A=/Z=, which count the same thing on the WRITE side: if the fill
  // writes the left half and scanout does not read it, the loss is in the band
  // memory rather than anywhere in the geometry.
  // The 3D frustum's LEFT CLIP PLANE, top 16 bits of the IEEE-754 value.
  // 0000 means it is still +0.0 - never computed - which puts the plane at
  // screen x = xc, about the middle of the screen, and cuts every polygon that
  // crosses it. See m1_geometry.
  input  logic [15:0] plane_l,
  // THE CLIPPER'S FUNNEL, c= in, d= out, e= discarded. Connected to
  // m1_geo_clip since it was written and routed nowhere until 2026-09-09, so
  // nobody had seen how many quads it eats. The left-side cut has now had the
  // store (D=0), the viewport (K=0), the left plane (Y stable at -0.88), the
  // out-of-range vertices (G=0) and the band memory (A=/Z= tracking I=/J=) all
  // cleared by measurement. This is what separates the clipper culling the left
  // side from the geometry never producing it.
  input  logic [15:0] clip_in, clip_out, clip_drop,
  // f= matrix words written while the geometry was mid-object, g= plane
  // recomputes started the same way. Both are supposed to be impossible:
  // lw_stall holds the walker outside P_WALK, and planes_wait gates
  // geo_start at P_OBJ. Those are readings of the source, never measured.
  // A torn matrix is the only mechanism found that fits the left-side
  // cut - six times the quads, displaced to one side, which no clip plane
  // or cull can produce. Nonzero and climbing means the race is real.
  input  logic [15:0] mat_race, plane_race,
  // Passes the game flipped out from under. See m1_raster3d's dbg_list_race.
  input  logic [15:0] list_race,
  // i= the list walker's stalled cycles, /16. Read against c=.
  input  logic [15:0] lw_stall_q,
  // THE PROJECTION STATE, top 16 bits of each IEEE-754 value.
  //   j= viewx   the view TRANSLATION in x
  //   k= xc      the screen centre
  //   l= zoomx   the horizontal scale
  // s.x = xc + (xx*zoomx + viewx), so a wrong value in any of them moves
  // every vertex sideways - the left half empties and the RIGHT half gains
  // pixels, which is what A=/Z= measured and what no clip plane, cull or
  // store overflow can do. All three are latched by display-list commands
  // and persist until rewritten, which is why the fault holds for minutes
  // when the car stops. They have been exported from m1_raster3d all along
  // and connected to nothing.
  input  logic [15:0] vx_q, xc_q, zx_q,
  // m= walks that ended on an unrecognised command, n= walks that ran off
  // the end of the buffer. The left-side cut is a five-fold drop in objects
  // walked with everything downstream clean, so this is where it ends.
  input  logic [15:0] lw_bad_q, lw_over_q,

  // THE TILEMAP PAIRS' CONTROL WORDS, read on hardware during real play.
  //
  // w= is pair 2/3's and v= is pair 0/1's. ctrl & 0x6000 picks the window mode:
  // 1 is a per-SCANLINE pick, which divides the screen horizontally, and 2 or 3
  // are a per-pixel COLUMN split, which divides it vertically. A hard vertical
  // boundary partway across the picture is what the column split draws, and
  // nothing else in the design draws one.
  //
  // The scroll census said pair 2/3 is always mode 1 - but that was MAME, in
  // attract, over 2,000 frames, and it is twice removed from the question. MAME
  // is the oracle for what the REFERENCE does; it says nothing about what our
  // V60 writes, and ours is known to diverge from MAME's at instruction
  // 197,251. Only the board can answer what our core does mid-race.
  //
  // Lowercase because every capital is already a field. The two cases are
  // distinct names, not the same one.
  // Objects the display list marks command 0x41, "drawn above the HUD". MAME
  // renders those in a SECOND pass through a stencil; we render one pass and
  // no stencil, so they are drawn like ordinary geometry. h= says whether a
  // game emits any - the flag that detects them has never been read.
  input  logic [15:0] hud_obj,     // h=

  input  logic [15:0] ctrl_hi,     // w= : pair 2/3
  input  logic [15:0] ctrl_lo,     // v= : pair 0/1

  input  logic [15:0] hit_l,
  input  logic [15:0] hit_r,

  input  logic [15:0] culled,
  input  logic [15:0] quads,

  input  logic [15:0] px_left,
  input  logic [15:0] px_right,

  input  logic [7:0]  mem_occ,
  input  logic [7:0]  mem_wait,

  output logic tx
);

  // ------------------------------------------------------------- counters
  logic [15:0] n_frame, n_swap;
  logic [15:0] period_cnt;
  logic        sel_d;
  logic [15:0] r_frame, r_swap, r_bands, r_pass;
  logic [15:0] r_tpc, r_tret, r_npres;
  logic [23:0] r_vpc, r_spc;
  logic [15:0] r_plen, r_late, r_wband, r_drop, r_short, r_vx1, r_miss;
  logic [7:0]  r_occ, r_wait;
  logic [15:0] r_pxl, r_pxr, r_oob, r_cull, r_quads, r_hl, r_hr, r_pl;
  logic [15:0] r_ci, r_co, r_cd, r_mr, r_pr, r_ls;
  logic [15:0] r_lr;
  logic [15:0] r_vx, r_xc, r_zx, r_lb, r_lo;
  logic [15:0] r_ch, r_cl, r_ho;
  logic [31:0] wband_max;
  logic        report_go;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      n_frame <= '0; n_swap <= '0; period_cnt <= '0; sel_d <= 1'b0;
      r_frame <= '0; r_swap <= '0; r_bands <= '0; r_pass <= '0;
      r_tpc <= '0; r_tret <= '0; r_npres <= '0; r_vpc <= '0; r_spc <= '0;
      r_plen <= '0; r_late <= '0; r_wband <= '0; wband_max <= '0;
      r_drop <= '0; r_short <= '0; r_vx1 <= '0; r_miss <= '0;
      r_occ <= '0; r_wait <= '0; r_pxl <= '0; r_pxr <= '0; r_oob <= '0;
      r_ci <= '0; r_co <= '0; r_cd <= '0; r_mr <= '0; r_pr <= '0; r_ls <= '0;
      r_lr <= '0;
      r_vx <= '0; r_xc <= '0; r_zx <= '0; r_lb <= '0; r_lo <= '0;
      r_cull <= '0; r_quads <= '0; r_hl <= '0; r_hr <= '0; r_pl <= '0;
      r_ch <= '0; r_cl <= '0; r_ho <= '0;
      report_go <= 1'b0;
    end else begin
      report_go <= 1'b0;
      sel_d <= list_sel;
      if (list_sel != sel_d) n_swap <= n_swap + 16'd1;
      if (band_cycles > wband_max) wband_max <= band_cycles;
      if (vblank) begin
        n_frame <= n_frame + 16'd1;
        if (period_cnt == 16'(PERIOD - 1)) begin
          // Snapshot and restart. The counters are cleared rather than left to
          // run, so a line is a rate and not a total anyone has to subtract.
          period_cnt <= '0;
          r_frame <= n_frame + 16'd1; n_frame <= '0;
          r_swap  <= n_swap;          n_swap  <= '0;
          r_bands <= bands;
          r_pass  <= passes;
          r_tpc   <= tgp_pc;
          r_tret  <= tgp_retires;
          r_npres <= bands_pres;
          r_vpc   <= v60_pc;
          r_spc   <= stall_pc;
          r_plen  <= pass_cycles[23:8];
          r_late  <= late;
          r_drop  <= dropped; r_short <= short_passes;
          r_vx1   <= view_x1;
          r_miss  <= fetch_miss;
          r_occ   <= mem_occ;
          r_wait  <= mem_wait;
          r_pxl   <= px_left;
          r_pxr   <= px_right;
          r_oob   <= vert_oob;
          r_ci    <= clip_in; r_co <= clip_out; r_cd <= clip_drop;
          r_mr    <= mat_race; r_pr <= plane_race; r_ls <= lw_stall_q;
          r_lr    <= list_race;
          r_vx    <= vx_q; r_xc <= xc_q; r_zx <= zx_q;
          r_lb    <= lw_bad_q; r_lo <= lw_over_q;
          r_cull  <= culled;
          r_quads <= quads;
          r_hl    <= hit_l;
          r_hr    <= hit_r;
          r_pl    <= plane_l;
          r_ch    <= ctrl_hi;
          r_cl    <= ctrl_lo;
          r_ho    <= hud_obj;
          r_wband <= wband_max[19:4]; wband_max <= '0;
          report_go <= 1'b1;
        end else period_cnt <= period_cnt + 16'd1;
      end
    end
  end

  // ------------------------------------------------------------- formatter
  // "F=00xxxx S=00xxxx ... G=00xxxx\r\n" - every field is EXACTLY EIGHT bytes:
  // a letter, '=', six hex digits. 16-bit values simply carry two leading
  // zeros.
  //
  // WHY UNIFORM, when ragged fields read a little better. The previous version
  // was one case with 137 arms selected by the character index, and it cost
  // real area: widening that index from seven bits to eight - forced when the
  // line passed 128 bytes - took the whole design from 40,160 ALM to 40,978,
  // because the tool then had to build the mux over a 256-entry space instead
  // of 128. Eight hundred ALM for a debug channel, on a design at 98%.
  //
  // Uniform fields make the index pure bit-slicing: ci[7:3] is the field and
  // ci[2:0] is the position within it. What is left is a 21-way mux over the
  // values and a 21-way mux over the letters, neither of which grows when the
  // index does.
  //
  // It also ends the truncation class of bug for good. NCH is computed from
  // the field count rather than hand-counted, so a new field cannot leave the
  // terminator behind - which is exactly what put "F=003A S=001D" on the wire
  // and cost a whole build cycle.
  // NINE bytes per field: a letter, '=', six hex digits, a space.
  //
  // The trailing space is NOT decoration. Five of the field letters - A, B, C,
  // D and F - are themselves hex digits, so without a separator "S=00001D"
  // followed by "B=0000B6" reads as a seven-digit value and the rest of the
  // line shifts. A format that a person cannot read back is not a debug
  // channel.
  //
  // Nine is not a power of two, so the field and position are COUNTERS rather
  // than slices of the character index. Two small counters cost less than the
  // divide would and far less than the 137-arm case they replace.
  // NINE BITS OF ci, AND THIS HAS NOW BITTEN THREE TIMES - at six, at seven,
  // and at eight the moment a 29th field took the line past 256 bytes. The
  // first two reached the board and read as UART corruption. The third was
  // caught by tb_m1_speed_report before it could be built, which is what that
  // bench exists for. Good to 511 bytes now.
  localparam int unsigned NF  = 41;             // fields
  localparam int unsigned FW  = 9;              // bytes per field
  localparam int unsigned NCH = NF * FW + 2;    // + CR + LF

  logic [8:0]  ci;
  logic        busy;
  logic [7:0]  ch;
  logic        wr;
  logic        full;
  // Named rather than left empty: a dropped byte means the line was truncated,
  // which is worth being able to see rather than silently reading a short line.
  logic        tx_overflow;

  function automatic [7:0] hexc(input logic [3:0] n);
    hexc = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
  endfunction

  // SIX BITS, not five: the field count passed 32 on 2026-09-09 and 5'd32
  // truncates to 5'd0, so the new fields silently aliased onto F= and S=.
  // The CASEOVERLAP warning caught it; widen this with any field added.
  logic [5:0] fld;
  logic [3:0] pos;

  logic [7:0]  f_letter;
  logic [23:0] f_value;
  always_comb begin
    case (fld)
      5'd0:  begin f_letter = "F"; f_value = {8'd0, r_frame};  end
      5'd1:  begin f_letter = "S"; f_value = {8'd0, r_swap};   end
      5'd2:  begin f_letter = "B"; f_value = {8'd0, r_bands};  end
      5'd3:  begin f_letter = "P"; f_value = {8'd0, r_pass};   end
      5'd4:  begin f_letter = "C"; f_value = {8'd0, r_tpc};    end
      5'd5:  begin f_letter = "R"; f_value = {8'd0, r_tret};   end
      5'd6:  begin f_letter = "N"; f_value = {8'd0, r_npres};  end
      5'd7:  begin f_letter = "V"; f_value = r_vpc;            end
      5'd8:  begin f_letter = "X"; f_value = r_spc;            end
      5'd9:  begin f_letter = "L"; f_value = {8'd0, r_plen};   end
      6'd10: begin f_letter = "T"; f_value = {8'd0, r_late};   end
      6'd11: begin f_letter = "W"; f_value = {8'd0, r_wband};  end
      6'd12: begin f_letter = "D"; f_value = {8'd0, r_drop};   end
      6'd13: begin f_letter = "H"; f_value = {8'd0, r_short};  end
      6'd14: begin f_letter = "K"; f_value = {8'd0, r_vx1};    end
      6'd15: begin f_letter = "M"; f_value = {8'd0, r_miss};   end
      6'd16: begin f_letter = "O"; f_value = {16'd0, r_occ};   end
      6'd17: begin f_letter = "Q"; f_value = {16'd0, r_wait};  end
      6'd18: begin f_letter = "A"; f_value = {8'd0, r_pxl};    end
      6'd19: begin f_letter = "Z"; f_value = {8'd0, r_pxr};    end
      6'd20: begin f_letter = "G"; f_value = {8'd0, r_oob};    end
      6'd21: begin f_letter = "E"; f_value = {8'd0, r_cull};   end
      6'd22: begin f_letter = "U"; f_value = {8'd0, r_quads}; end
      6'd23: begin f_letter = "I"; f_value = {8'd0, r_hl};    end
      6'd24: begin f_letter = "J"; f_value = {8'd0, r_hr};    end
      6'd25: begin f_letter = "Y"; f_value = {8'd0, r_pl};    end
      6'd26: begin f_letter = "w"; f_value = {8'd0, r_ch};    end
      6'd27: begin f_letter = "v"; f_value = {8'd0, r_cl};    end
      6'd28: begin f_letter = "c"; f_value = {8'd0, r_ci};  end
      6'd29: begin f_letter = "d"; f_value = {8'd0, r_co};  end
      6'd30: begin f_letter = "e"; f_value = {8'd0, r_cd};  end
      6'd31: begin f_letter = "f"; f_value = {8'd0, r_mr};  end
      6'd32: begin f_letter = "g"; f_value = {8'd0, r_pr};  end
      6'd33: begin f_letter = "i"; f_value = {8'd0, r_ls};  end
      6'd34: begin f_letter = "j"; f_value = {8'd0, r_vx};  end
      6'd35: begin f_letter = "k"; f_value = {8'd0, r_xc};  end
      6'd36: begin f_letter = "l"; f_value = {8'd0, r_zx};  end
      6'd37: begin f_letter = "m"; f_value = {8'd0, r_lb};  end
      6'd38: begin f_letter = "n"; f_value = {8'd0, r_lo};  end
      6'd39: begin f_letter = "h"; f_value = {8'd0, r_ho};  end
      // THE LIST RACE: passes the game flipped out from under the walker.
      default: begin f_letter = "p"; f_value = {8'd0, r_lr};  end
    endcase
  end

  // Position 0 is the letter, 1 the '=', 2..7 the six hex digits from the top
  // down, 8 the separating space.
  logic [3:0] nib;
  always_comb begin
    case (pos)
      4'd2:    nib = f_value[23:20];
      4'd3:    nib = f_value[19:16];
      4'd4:    nib = f_value[15:12];
      4'd5:    nib = f_value[11:8];
      4'd6:    nib = f_value[7:4];
      default: nib = f_value[3:0];
    endcase
  end

  always_comb begin
    if (ci >= 9'(NF * FW))
      ch = (ci == 9'(NF * FW)) ? 8'h0d : 8'h0a;
    else if (pos == 4'd0) ch = f_letter;
    else if (pos == 4'd1) ch = "=";
    else if (pos == 4'd8) ch = " ";
    else                  ch = hexc(nib);
  end

  assign wr = busy && !full;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; ci <= '0; fld <= '0; pos <= '0;
    end else begin
      // NOT WHILE A LINE IS STILL GOING OUT. This used to re-arm
      // unconditionally, so a trigger arriving mid-line reset ci and the line
      // never terminated - the reader saw one good line and then an endless
      // unterminated stream. It only became reachable when the line grew past
      // the trigger interval: 38 fields is 344 bytes, which at 115200 baud is
      // 29.9 ms against a 17.4 ms frame.
      //
      // Dropping the report is the right failure. This module already drops
      // rather than stalls, because a debug channel that can halt the design is
      // worse than none - and a dropped line costs one sample, while a
      // corrupted one costs the reader's trust in every number on it.
      if (report_go && !busy) begin
        busy <= 1'b1; ci <= '0; fld <= '0; pos <= '0;
      end else if (busy && !full) begin
        // The field and position counters walk in step with ci. They are what
        // keep the character mux small; ci itself only decides where the line
        // ends.
        if (pos == 4'(FW - 1)) begin
          pos <= '0;
          fld <= fld + 6'd1;
        end else begin
          pos <= pos + 4'd1;
        end
        // SEVEN BITS HERE TOO. Widening the declaration and the case items was
        // not enough: 6'(NCH-1) truncated 67 to 3, so every line ended after
        // "F=00" and restarted. On the wire that looks like UART corruption,
        // not an arithmetic width - which is exactly what the comment beside
        // NCH warned about, written while making this same mistake.
        if (ci == 9'(NCH - 1)) busy <= 1'b0;
        else                   ci <= ci + 9'd1;
      end
    end
  end

  m1_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .DEPTH(64)) u_tx (
    .clk(clk), .rst_n(rst_n),
    .wr(wr), .din(ch), .full(full), .overflow(tx_overflow),
    .tx(tx)
  );

endmodule
