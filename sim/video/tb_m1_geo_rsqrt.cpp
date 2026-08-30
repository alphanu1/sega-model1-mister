// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Reciprocal square root: a seed table and one Newton-Raphson step.
//
// THIS IS NOT HELD TO BIT-EXACTNESS, AND THE BOUND IS THE ONE THAT WAS MEASURED
//
// It replaces `1.0f/sqrtf(x)`, which no FP unit in this design can compute
// exactly - there is no square root unit, and building one to hold a value that
// ends up as six bits of luminance would be the wrong trade (docs/findings.md:
// at 16 bits of mantissa, 0.013% of polygons shift by one of 64 levels).
//
// So the bench holds it to RELATIVE ERROR, at the accuracy the measurement said
// was needed, and checks the two things a loose tolerance would miss:
//
//   * the error bound holds across the ENTIRE exponent range, not just near 1.0.
//     A seed table indexed on the exponent's parity is exactly where a halving
//     goes wrong, and it goes wrong by a factor of sqrt(2) - which is a 40% error
//     that a test sampling only [1,4) would never see.
//   * one Newton step converges from BOTH sides. The iteration is
//     y*(1.5 - x/2*y*y), which is self-correcting for a seed that is too large
//     and too small alike, but a mis-scaled seed diverges rather than converging,
//     and the worst case sits at the ends of each table interval.

#include "Vm1_geo_rsqrt_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>

static long checks = 0, fails = 0, printed = 0;
static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

struct Dut {
    Vm1_geo_rsqrt_top* d = new Vm1_geo_rsqrt_top;
    long cycles = 0;
    void tick() { cycles++; d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
    void reset() {
        d->rst_n = 0; d->in_valid = 0;
        for (int i = 0; i < 8; i++) tick();
        d->rst_n = 1;
        for (int i = 0; i < 8; i++) tick();
    }
    bool run(float x, float* y) {
        int guard = 0;
        while (!d->in_ready && ++guard < 2000) tick();
        d->in_valid = 1; d->in_x = f2u(x);
        tick();
        d->in_valid = 0;
        guard = 0;
        while (!d->out_valid && ++guard < 2000) tick();
        if (guard >= 2000) return false;
        *y = u2f(d->out_y);
        return true;
    }
};

// The accuracy the luminance measurement asked for, with margin: one Newton step
// from an 8-bit seed reaches about 16 bits, so 2^-14 is a bound it should clear
// everywhere while still failing loudly on a scaling mistake.
static const double TOL = 6.1e-5;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Dut t; t.reset();
    double worst = 0.0; float worst_at = 0.0f;

    auto one = [&](float x, const char* what) {
        float y;
        checks++;
        if (!t.run(x, &y)) {
            fails++;
            if (printed++ < 20) printf("  FAIL %s: no result for %g\n", what, x);
            return;
        }
        double ref = 1.0 / std::sqrt((double)x);
        double rel = std::fabs((double)y - ref) / ref;
        if (rel > worst) { worst = rel; worst_at = x; }
        if (rel > TOL) {
            fails++;
            if (printed++ < 20)
                printf("  FAIL %s: rsqrt(%g) = %g, want %g, relative error %.3e\n",
                       what, x, y, ref, rel);
        }
    };

    printf("test: exact powers of four, where the seed index is at an edge\n");
    for (int e = -60; e <= 60; e += 2) one(ldexpf(1.0f, e), "power of four");

    printf("test: exact powers of two - the ODD exponents, which halve differently\n");
    // 1/sqrt halves the exponent, so an odd one folds a factor of two into the
    // mantissa. Getting that wrong is a sqrt(2) error, and it appears ONLY here.
    for (int e = -59; e <= 59; e += 2) one(ldexpf(1.0f, e), "power of two, odd");

    printf("test: both ends of several table intervals\n");
    for (int i = 0; i < 128; i += 16) {
        for (double frac : {0.0, 0.001, 0.499, 0.999}) {
            float m = (float)(1.0 + (i + frac) / 128.0);
            one(m, "interval edge");
            one(m * 2.0f, "interval edge, odd exponent");
        }
    }

    printf("test: fuzz across the full exponent range\n");
    {
        std::mt19937 rng(0x5a11c0deu);
        for (int i = 0; i < 30000; i++) {
            int e = (int)(rng() % 100) - 50;
            float m = 1.0f + (float)(rng() % 1000000) / 1000000.0f;
            one(ldexpf(m, e), "fuzz");
        }
        printf("  worst relative error %.3e at x = %g (tolerance %.1e)\n",
               worst, worst_at, TOL);
    }

    printf("test: THROUGHPUT - once per record, budget 68 cycles\n");
    {
        float y;
        long c0 = t.cycles;
        const int N = 200;
        for (int i = 0; i < N; i++) t.run(2.0f + i * 0.01f, &y);
        double per = (double)(t.cycles - c0) / N;
        printf("  %.1f cycles per record\n", per);
        checks++;
        if (per > 68.0) { fails++; printf("  FAIL over the per-record budget\n"); }
    }

    printf("m1_geo_rsqrt: checks=%ld fails=%ld\n", checks, fails);
    return fails ? 1 : 0;
}
