// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// m1_drive_inputs against two references:
//
//   STANDARD, against the expressions Model1.sv carried before the module
//   existed (b7d... main, 0b5d04f), transcribed here and frozen. Standard must
//   be what a player had before, for every input.
//
//   WHEEL A / WHEEL B, against a model written from the request (the Model 2
//   core's R958, in this core's 0x01..0xff pedal range), not from the RTL.
//
// Exhaustive over every axis value a mode reads, with every switch and button
// combination; random over the rest. Then properties: the wheel is the same in
// every mode with no dead zone (every left-X value maps to a distinct ADC
// value), pedals are monotonic in their axis, endpoints land where the request
// says, and the axes a mode does not read are inert.

#include "Vm1_drive_inputs.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>

static long checks = 0, fails = 0;
static void chk(bool ok, const char* what, int a = 0, int b = 0) {
  checks++;
  if (!ok && fails++ < 20) printf("  FAIL %s (%d, %d)\n", what, a, b);
}

struct In { int mode, swap, sl, sr, ab, bb; uint16_t ls, rs; };
struct Out { int wheel, accel, brake; };

// ---- Standard: Model1.sv at 0b5d04f, lines "wheel_stick" .. "io_brake"
static Out ref_std(const In& i) {
  Out o;
  int wheel_stick = ((~i.ls >> 7) & 1) << 7 | (i.ls & 0x7f);
  o.wheel = i.sl ? 0x00 : i.sr ? 0xff : wheel_stick;
  int ax = (i.rs >> 8) & 0xff;                       // pedal_ax, signed byte
  int sign = (ax >> 7) & 1;
  int mag = sign ? ((~ax + 1) & 0x7f) : (ax & 0x7f);
  int an = (mag << 1) | 1;
  int up = i.swap ? !sign : sign;
  int acc = up ? an : 0x01, brk = up ? 0x01 : an;
  o.accel = i.ab ? 0xff : (acc > 1 ? acc : 1);
  o.brake = i.bb ? 0xff : (brk > 1 ? brk : 1);
  return o;
}

// ---- the wheel modes, from the request
static int up_half(int v) {          // v: signed -128..127
  if (v == -128) return 127;
  return v < 0 ? -v : 0;
}
static int full_travel(int v) {
  if (v == -128) return 0;
  return (v + 127) / 2;
}
static Out ref_whl(const In& i) {
  Out o = ref_std(i);                // the wheel is unchanged
  bool b = (i.mode == 2);
  int ly = (int8_t)(i.ls >> 8), ry = (int8_t)(i.rs >> 8), rx = (int8_t)(i.rs & 0xff);
  int a = b ? full_travel(ly) : up_half(ly);
  int k = b ? full_travel(rx) : up_half(ry);
  int acc = ((i.swap ? k : a) << 1) | 1, brk = ((i.swap ? a : k) << 1) | 1;
  o.accel = i.ab ? 0xff : acc;
  o.brake = i.bb ? 0xff : brk;
  return o;
}
static Out ref(const In& i) { return (i.mode == 1 || i.mode == 2) ? ref_whl(i) : ref_std(i); }

static Vm1_drive_inputs* d;
static Out run(const In& i) {
  d->mode = i.mode; d->swap = i.swap; d->steer_l = i.sl; d->steer_r = i.sr;
  d->accel_b = i.ab; d->brake_b = i.bb; d->lstick = i.ls; d->rstick = i.rs;
  d->eval();
  return {d->wheel, d->accel, d->brake};
}
static void cmp(const In& i, const char* what) {
  Out g = run(i), e = ref(i);
  bool ok = g.wheel == e.wheel && g.accel == e.accel && g.brake == e.brake;
  checks++;
  if (!ok && fails++ < 20)
    printf("  FAIL %s: mode %d swap %d ls %04x rs %04x btn %d%d dpad %d%d: got %02x %02x %02x want %02x %02x %02x\n",
           what, i.mode, i.swap, i.ls, i.rs, i.ab, i.bb, i.sl, i.sr,
           g.wheel, g.accel, g.brake, e.wheel, e.accel, e.brake);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm1_drive_inputs;
  std::mt19937 rng(0xd21e);

  printf("test: every mode, switch and button, exhaustive over the axes it reads\n");
  for (int mode = 0; mode < 4; mode++)
    for (int sw = 0; sw < 2; sw++)
      for (int btn = 0; btn < 4; btn++)
        for (int dp = 0; dp < 3; dp++) {
          // the axis pair this mode reads for its pedals, exhaustive; the rest random
          for (int a = 0; a < 256; a++)
            for (int b = 0; b < 256; b++) {
              In i{mode, sw, dp == 1, dp == 2, btn & 1, btn >> 1, 0, 0};
              uint16_t r1 = rng(), r2 = rng();
              if (mode == 2)      { i.ls = (a << 8) | (r1 & 0xff); i.rs = (r2 & 0xff00) | b; }
              else if (mode == 1) { i.ls = (a << 8) | (r1 & 0xff); i.rs = (b << 8) | (r2 & 0xff); }
              else                { i.ls = (r1 & 0xff00) | a;      i.rs = (b << 8) | (r2 & 0xff); }
              cmp(i, "exhaustive");
            }
        }

  printf("test: random everything\n");
  for (int n = 0; n < 2000000; n++) {
    In i{(int)(rng() & 3), (int)(rng() & 1), 0, 0, (int)(rng() & 1), (int)(rng() & 1),
         (uint16_t)rng(), (uint16_t)rng()};
    int dp = rng() % 4; i.sl = dp == 1 || dp == 3; i.sr = dp == 2;
    cmp(i, "random");
  }

  printf("test: properties\n");
  for (int mode = 0; mode < 3; mode++) {
    // no dead zone: 256 left-X values, 256 distinct wheel values, centre 0x80
    bool seen[256] = {};
    int distinct = 0;
    for (int x = 0; x < 256; x++) {
      Out o = run({mode, 0, 0, 0, 0, 0, (uint16_t)x, 0});
      if (!seen[o.wheel]) { seen[o.wheel] = true; distinct++; }
    }
    chk(distinct == 256, "wheel: every left-X value distinct (no dead zone)", mode, distinct);
    chk(run({mode, 0, 0, 0, 0, 0, 0x0000, 0}).wheel == 0x80, "wheel: centre is 0x80", mode);
    chk(run({mode, 0, 0, 0, 0, 0, 0x0001, 0}).wheel == 0x81, "wheel: one count right moves it", mode);
    chk(run({mode, 0, 0, 0, 0, 0, 0x00ff, 0}).wheel == 0x7f, "wheel: one count left moves it", mode);
  }
  // pedals: released and full, per mode
  auto P = [&](int mode, int sw, uint16_t ls, uint16_t rs) { return run({mode, sw, 0, 0, 0, 0, ls, rs}); };
  // Wheel A: up half of left Y / right Y
  chk(P(1, 0, 0x0000, 0x0000).accel == 0x01 && P(1, 0, 0x0000, 0x0000).brake == 0x01, "A: centred is released");
  chk(P(1, 0, 0x8100, 0).accel == 0xff, "A: left Y -127 is full accelerator");
  chk(P(1, 0, 0x8000, 0).accel == 0xff, "A: left Y -128 is full accelerator");
  chk(P(1, 0, 0x7f00, 0).accel == 0x01, "A: left Y down half reads released");
  chk(P(1, 0, 0xff00, 0).accel == 0x03, "A: one count of travel moves the accelerator (no dead zone)");
  chk(P(1, 0, 0, 0x8100).brake == 0xff, "A: right Y -127 is full brake");
  chk(P(1, 0, 0, 0x0081).brake == 0x01, "A: right X does not brake");
  // Wheel B: full travel, -128 released
  chk(P(2, 0, 0x8000, 0x0080).accel == 0x01 && P(2, 0, 0x8000, 0x0080).brake == 0x01, "B: -128 is released");
  chk(P(2, 0, 0x8100, 0).accel == 0x01, "B: -127 is released");
  chk(P(2, 0, 0x7f00, 0).accel == 0xff, "B: +127 is full accelerator");
  chk(P(2, 0, 0x0000, 0).accel == 0x7f, "B: centre is half travel");
  chk(P(2, 0, 0x8000, 0x007f).brake == 0xff, "B: right X +127 is full brake");
  chk(P(2, 0, 0x8000, 0x7f80).brake == 0x01, "B: right Y does not brake");
  // Pedals swaps them in the wheel modes
  chk(P(1, 1, 0x8100, 0).brake == 0xff && P(1, 1, 0x8100, 0).accel == 0x01, "A: Pedals=swapped swaps");
  // monotonic in their axis
  for (int mode = 1; mode < 3; mode++) {
    int prev = -1; bool mono = true;
    for (int v = (mode == 1 ? 0 : -127); (mode == 1 ? v >= -128 : v <= 127); v += (mode == 1 ? -1 : 1)) {
      int a = P(mode, 0, (uint16_t)((v & 0xff) << 8), 0).accel;
      if (a < prev) mono = false;
      prev = a;
    }
    chk(mono, "pedal monotonic in its axis", mode);
  }
  // the buttons win
  chk(run({1, 0, 0, 0, 1, 1, 0, 0}).accel == 0xff && run({2, 0, 0, 0, 1, 1, 0, 0}).brake == 0xff, "buttons give full travel");
  // the d-pad wins at full lock in every mode
  for (int mode = 0; mode < 3; mode++)
    chk(run({mode, 0, 1, 0, 0, 0, 0x007f, 0}).wheel == 0x00 && run({mode, 0, 0, 1, 0, 0, 0x0081, 0}).wheel == 0xff,
        "d-pad wins at full lock", mode);

  printf("m1_drive_inputs: checks=%ld fails=%ld\n", checks, fails);
  delete d;
  return fails ? 1 : 0;
}
