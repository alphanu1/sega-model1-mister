// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m1_geo_recip against an exact reciprocal.
//
// THE ACCEPTANCE TEST IS PIXELS, NOT MANTISSA BITS, and that is deliberate.
// This unit is knowingly not bit-exact -- it is a seed table plus one Newton
// step -- so a tolerance on the float would be an arbitrary line. What the
// value is FOR is a screen coordinate: x * recip * zoom, floored to an integer.
// So the test measures what the design actually cares about, the same way
// m1_geo_rsqrt's tolerance was set by the six-bit luminance it feeds.
//
// The bound: the reciprocal that ships today is itself not exact -- x*(1/z)
// already lands on a different pixel from x/z for 0.078% of points -- and the
// rule this unit must keep is the one already accepted, NEVER MORE THAN ONE
// PIXEL. The rate is allowed to roughly double; a two-pixel error is a failure.
#include "Vm1_geo_recip_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <random>
#include <cstring>

static Vm1_geo_recip_top* dut;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static void tick() {
  dut->clk = 0; dut->eval();
  dut->clk = 1; dut->eval();
  main_time++;
}

static float u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vm1_geo_recip_top;

  dut->rst_n = 0; dut->in_valid = 0; dut->in_x = 0;
  for (int i = 0; i < 8; i++) tick();
  dut->rst_n = 1;

  std::mt19937 rng(0xC0FFEE);
  std::uniform_real_distribution<double> dec(0.0, 6.0);    // six decades of depth
  std::uniform_real_distribution<double> xs(-4096.0, 4096.0);
  const float ZOOM = 256.0f;

  long checks = 0, fails = 0, differ = 0, cyc_total = 0;
  int worst_px = 0;
  double worst_rel = 0.0;

  const long N = 200000;
  for (long n = 0; n < N; n++) {
    float z = (float)std::pow(10.0, dec(rng));
    float x = (float)xs(rng);

    // present one operand and wait for its result
    while (!dut->in_ready) tick();
    dut->in_valid = 1; dut->in_x = f2u(z);
    long c0 = (long)main_time;
    tick();
    dut->in_valid = 0;
    int guard = 0;
    while (!dut->out_valid && guard++ < 2000) tick();
    cyc_total += (long)main_time - c0;
    if (!dut->out_valid) { printf("TIMEOUT at n=%ld\n", n); fails++; break; }

    float got = u2f(dut->out_y);
    float ref = 1.0f / z;
    double rel = std::fabs((double)got - (double)ref) / (double)ref;
    if (rel > worst_rel) worst_rel = rel;

    // What it is FOR: the screen coordinate.
    long px_got = (long)std::floor((double)x * (double)got * (double)ZOOM);
    long px_ref = (long)std::floor((double)x / (double)z * (double)ZOOM);
    long d = std::labs(px_got - px_ref);
    if (d) differ++;
    if (d > worst_px) worst_px = (int)d;
    if (d > 1) {
      if (fails < 10)
        printf("  OVER ONE PIXEL: z=%g x=%g got=%g ref=%g  %ld px\n",
               z, x, got, ref, d);
      fails++;
    }
    checks++;
    tick();
  }

  printf("test: reciprocal against an exact divide, six decades of depth\n");
  printf("  worst relative error %.3e (= %.1f correct bits)\n",
         worst_rel, worst_rel > 0 ? -std::log2(worst_rel) : 24.0);
  printf("  pixels differing %.4f%%, worst %d pixel(s)\n",
         100.0 * (double)differ / (double)checks, worst_px);
  if (worst_px > 1) { printf("  FAIL over the one-pixel bound\n"); }

  // THE POINT OF THE UNIT. fp_div is 29 cycles and does not pipeline; the
  // geometry bench puts that at 425% of a frame budget.
  printf("  %.1f cycles per reciprocal, against 29 for fp_div\n",
         (double)cyc_total / (double)checks);
  printf("m1_geo_recip: checks=%ld fails=%ld\n", checks, fails);
  delete dut;
  return fails ? 1 : 0;
}
