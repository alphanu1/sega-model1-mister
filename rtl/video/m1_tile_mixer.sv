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
// Tilemap priority mixer.
//
// Transcribed from model1_v.cpp's screen_update, which draws in this order:
//
//   m_tiles->draw(..., 6, 0, TILEMAP_DRAW_OPAQUE);
//   m_tiles->draw(..., 4, 0, TILEMAP_DRAW_OPAQUE);
//   m_tiles->draw(..., 2, 0, 0);
//   m_tiles->draw(..., 0, 0, 0);
//        ... the 3D image is composited here ...
//   m_tiles->draw(..., 7, 0, 0);
//   m_tiles->draw(..., 5, 0, 0);
//   m_tiles->draw(..., 3, 0, 0);
//   m_tiles->draw(..., 1, 0, 0);
//
// EACH TILEMAP IS DRAWN TWICE, AND THAT IS THE WHOLE DESIGN
//
// There are eight draw calls but only four tilemaps. In draw_common the layer
// argument splits: `layer >> 1` selects the tilemap and `tpri = layer & 1`
// selects which of its tiles that pass draws. So layer 6 is tilemap 3's
// category-0 tiles and layer 7 is tilemap 3's category-1 tiles — the same
// tilemap, filtered by the per-tile category bit, which is bit 15 of the tile
// word and arrives here as `prio`.
//
// The consequence is that a single tilemap straddles the 3D image: its
// category-0 tiles sit behind the polygons and its category-1 tiles sit in
// front. That is how the hardware puts a cockpit frame over the 3D view while
// the same layer's background sits behind it. Treating each tilemap as
// occupying one depth would render the 3D either entirely over or entirely
// under it, which looks plausible in a static screenshot and is wrong the
// moment anything moves.
//
// Front-to-back, then, the nine slots are:
//
//   tm0.cat1, tm1.cat1, tm2.cat1, tm3.cat1, [3D], tm0.cat0, tm1.cat0,
//   tm2.cat0, tm3.cat0
//
// OPACITY
//
// Layers 6 and 4 — tilemaps 3 and 2, category 0 — are drawn with
// TILEMAP_DRAW_OPAQUE, so pen 0 is written rather than skipped. Everything
// else treats pen 0 as transparent. Without that the backdrop never gets
// filled and whatever the framebuffer held last frame shows through.

`timescale 1ns/1ps

module m1_tile_mixer (
  // Per tilemap, straight from four m1_tile_decode instances.
  input  logic [3:0][11:0] pal_index,
  input  logic [3:0]       transparent,
  input  logic [3:0]       prio,        // tile category bit
  input  logic [3:0]       disabled,    // layer disable, from vscr bit 15

  // The 3D image. Not generated until M2, so `poly_valid` is tied low for now
  // and the slot is kept because inserting a depth later would silently change
  // every layer's relationship to it.
  input  logic [11:0]      poly_index,
  input  logic             poly_valid,

  // Backdrop, used when nothing at all is opaque.
  input  logic [11:0]      backdrop,

  output logic [11:0]      pixel,
  output logic [3:0]       source       // one-hot-ish debug: which slot won
);

  // A tilemap contributes to the category-1 pass when its tile says so, and to
  // the category-0 pass otherwise. `disabled` removes it from both.
  logic [3:0] hit_cat1, hit_cat0;

  always_comb begin
    for (int i = 0; i < 4; i++) begin
      // Tilemaps 2 and 3 draw their category-0 pass opaque, so pen 0 counts as
      // a hit there and nowhere else.
      automatic logic opaque_pass = (i >= 2);
      hit_cat1[i] = !disabled[i] &&  prio[i] && !transparent[i];
      hit_cat0[i] = !disabled[i] && !prio[i] && (!transparent[i] || opaque_pass);
    end
  end

  always_comb begin
    // Front to back. The first hit wins, which is the same result as painting
    // back to front and letting later writes overwrite earlier ones.
    if      (hit_cat1[0]) begin pixel = pal_index[0]; source = 4'd0; end
    else if (hit_cat1[1]) begin pixel = pal_index[1]; source = 4'd1; end
    else if (hit_cat1[2]) begin pixel = pal_index[2]; source = 4'd2; end
    else if (hit_cat1[3]) begin pixel = pal_index[3]; source = 4'd3; end
    else if (poly_valid)  begin pixel = poly_index;   source = 4'd8; end
    else if (hit_cat0[0]) begin pixel = pal_index[0]; source = 4'd4; end
    else if (hit_cat0[1]) begin pixel = pal_index[1]; source = 4'd5; end
    else if (hit_cat0[2]) begin pixel = pal_index[2]; source = 4'd6; end
    else if (hit_cat0[3]) begin pixel = pal_index[3]; source = 4'd7; end
    else                  begin pixel = backdrop;     source = 4'd15; end
  end

endmodule
