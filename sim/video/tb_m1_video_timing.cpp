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
// Video timing, checked against MAME's set_raw numbers.
//
// The frame rate is the thing being protected. model1.cpp asks for a 16 MHz
// dot clock over 656 x 424, which is 57.52 Hz, and every downstream budget --
// the tilemap's cycles per scanline, eventually the audio rate -- is derived
// from it. A core that renders a correct picture at the wrong rate has drifting
// audio and tearing that look like unrelated faults, so the counts are checked
// exactly rather than approximately.

#include "Vm1_video_timing.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vm1_video_timing;

  const int H_TOTAL = 656, H_VIS = 496, V_TOTAL = 424, V_VIS = 384;

  long checks = 0, fails = 0;
  auto FAIL = [&](const char* m) { printf("  FAIL %s\n", m); fails++; };

  d->clk = 0; d->rst_n = 0; d->ce_pix = 1;
  auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1;

  // Two full frames, so the wrap is exercised rather than just the first pass.
  long visible_px = 0, line_starts = 0, vblank_starts = 0;
  long hsync_px = 0, vsync_lines = 0;
  long frame_px = 0;
  // Seeded from the counter's actual value, not -1: starting at -1 counts the
  // very first sample as a transition and reports one line too many. The RTL
  // is right and line_starts already measures this precisely; this is the
  // looser cross-check and it was the thing that was wrong.
  int  prev_v = (int)d->vcnt;
  long lines_seen = 0;
  bool line_num_ok = true;

  const long TOTAL = (long)H_TOTAL * V_TOTAL * 2;
  for (long n = 0; n < TOTAL; n++) {
    tick();
    frame_px++;
    if (d->visible) visible_px++;
    if (d->hsync) hsync_px++;
    if (d->line_start) {
      line_starts++;
      // line_number must name the line about to be rendered, i.e. the next
      // one, wrapping at the end of the frame.
      int expect = (d->vcnt == V_TOTAL - 1) ? 0 : (int)d->vcnt + 1;
      if ((int)d->line_number != expect) line_num_ok = false;
    }
    if (d->vblank_start) vblank_starts++;
    if ((int)d->vcnt != prev_v) { prev_v = d->vcnt; lines_seen++; }
    if (d->vsync && d->hcnt == 0) vsync_lines++;
  }

  printf("test: counts match MAME's set_raw(16MHz, 656, 0, 496, 424, 0, 384)\n");
  checks++;
  if (visible_px != (long)H_VIS * V_VIS * 2)
    FAIL("visible pixel count");
  checks++;
  if (line_starts != (long)V_TOTAL * 2) FAIL("line_start once per line");
  checks++;
  if (vblank_starts != 2) FAIL("vblank_start once per frame");
  checks++;
  if (!line_num_ok) FAIL("line_number does not name the next line");
  checks++;
  if (lines_seen != (long)V_TOTAL * 2) {
    printf("  FAIL line count: saw %ld, want %ld\n", lines_seen, (long)V_TOTAL * 2);
    fails++;
  }

  printf("  %ld visible px over 2 frames (want %ld), %ld line starts, %ld vblanks\n",
         visible_px, (long)H_VIS * V_VIS * 2, line_starts, vblank_starts);

  // Frame rate follows from the totals, so state it explicitly: if someone
  // "fixes" a total to please a monitor, this number moves and the test says so.
  double fps = 16.0e6 / ((double)H_TOTAL * V_TOTAL);
  printf("  frame rate %.2f Hz\n", fps);
  checks++;
  if (fps < 57.4 || fps > 57.7) FAIL("frame rate outside MAME's");

  // Sync must sit entirely inside blanking, or the visible area is cut.
  printf("test: sync pulses lie inside blanking\n");
  d->rst_n = 0; tick(); d->rst_n = 1;
  bool sync_in_visible = false;
  for (long n = 0; n < (long)H_TOTAL * V_TOTAL; n++) {
    tick();
    if ((d->hsync || d->vsync) && d->visible) sync_in_visible = true;
  }
  checks++;
  if (sync_in_visible) FAIL("a sync pulse overlaps the visible area");

  printf("m1_video_timing: checks=%ld fails=%ld\n", checks, fails);
  delete d;
  return fails ? 1 : 0;
}
