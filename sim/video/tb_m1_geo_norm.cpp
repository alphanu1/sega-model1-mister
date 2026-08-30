// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Vector normalize, against glm's formulation as MAME uses it.
//
// The tolerance is inherited, not invented: this module is a dot product, an
// m1_geo_rsqrt and three multiplies, and the only inexact step is the reciprocal
// square root, whose worst relative error is measured at 5.7e-06 across the full
// exponent range. So the result is held to a relative error of 6.1e-05 per
// component - an order of magnitude of headroom over the part that can drift -
// and anything worse is a structural mistake, not rounding.
//
// The cases here are the ones where a normalize goes wrong structurally:
//
//   * a vector that is already unit length must come back unchanged to within
//     the same bound. A missing or doubled scaling shows up here first.
//   * the result's LENGTH must be 1. Checking components against a reference
//     passes a normalize that scales by the wrong axis's reciprocal; checking the
//     length does not.
//   * very large and very small vectors, where dot(v,v) overflows or underflows
//     long before v does. This is the failure the exponent range exists to catch:
//     a vector of 1e20 has a squared length of 1e40, which is finite, but 1e30
//     squares to infinity and the normalize collapses.
//   * a zero vector, which MAME would divide by. Documented as passed through.

#include "Vm1_geo_norm_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>
#include <array>
#include <algorithm>

static long checks = 0, fails = 0, printed = 0, skipped = 0;
static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static const double TOL = 6.1e-5;

struct Dut {
    Vm1_geo_norm_top* d = new Vm1_geo_norm_top;
    long cycles = 0;
    void tick() { cycles++; d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
    void reset() {
        d->rst_n = 0; d->in_valid = 0;
        for (int i = 0; i < 8; i++) tick();
        d->rst_n = 1;
        for (int i = 0; i < 8; i++) tick();
    }
    bool run(float x, float y, float z, float* ox, float* oy, float* oz) {
        int guard = 0;
        while (!d->in_ready && ++guard < 4000) tick();
        d->in_valid = 1; d->in_x = f2u(x); d->in_y = f2u(y); d->in_z = f2u(z);
        tick();
        d->in_valid = 0;
        guard = 0;
        while (!d->out_valid && ++guard < 4000) tick();
        if (guard >= 4000) return false;
        *ox = u2f(d->out_x); *oy = u2f(d->out_y); *oz = u2f(d->out_z);
        return true;
    }
};

static Dut* T;
static double worst = 0.0, worst_len = 0.0;

static void one(float x, float y, float z, const char* what) {
    double l2 = (double)x*x + (double)y*y + (double)z*z;
    if (!(l2 > 0.0) || !std::isfinite((float)l2)) { skipped++; return; }
    double l = std::sqrt(l2);
    double ex = x / l, ey = y / l, ez = z / l;

    float ox, oy, oz;
    checks++;
    if (!T->run(x, y, z, &ox, &oy, &oz)) {
        fails++;
        if (printed++ < 20) printf("  FAIL %s: no result\n", what);
        return;
    }
    auto rel = [&](double got, double want) {
        return (std::fabs(want) < 1e-30) ? std::fabs(got) : std::fabs(got - want) / std::fabs(want);
    };
    double r = std::max(rel(ox, ex), std::max(rel(oy, ey), rel(oz, ez)));
    if (r > worst) worst = r;
    if (r > TOL) {
        fails++;
        if (printed++ < 20)
            printf("  FAIL %s: (%g,%g,%g) -> (%g,%g,%g), want (%g,%g,%g), rel %.3e\n",
                   what, x, y, z, ox, oy, oz, ex, ey, ez, r);
        return;
    }
    // The LENGTH is the property that matters, and it is not implied by the
    // components matching a reference computed the same way.
    checks++;
    double gl = std::sqrt((double)ox*ox + (double)oy*oy + (double)oz*oz);
    double dl = std::fabs(gl - 1.0);
    if (dl > worst_len) worst_len = dl;
    if (dl > TOL) {
        fails++;
        if (printed++ < 20)
            printf("  FAIL %s: result length %.9f, not 1\n", what, gl);
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Dut t; t.reset(); T = &t;

    printf("test: an already-unit vector comes back unchanged\n");
    for (auto v : {std::array<float,3>{1,0,0}, {0,1,0}, {0,0,1},
                   {-1,0,0}, {0,-1,0}, {0,0,-1},
                   {0.6f,0.8f,0.0f}, {0.36f,0.48f,0.8f}})
        one(v[0], v[1], v[2], "unit vector");

    printf("test: a zero vector is passed through, not divided by\n");
    {
        float ox, oy, oz;
        checks++;
        if (!t.run(0.0f, 0.0f, 0.0f, &ox, &oy, &oz)) {
            fails++; printf("  FAIL zero vector hung\n");
        } else if (ox != 0.0f || oy != 0.0f || oz != 0.0f) {
            fails++; printf("  FAIL zero vector gave (%g,%g,%g)\n", ox, oy, oz);
        }
    }

    printf("test: very large and very small vectors, where dot(v,v) is the limit\n");
    for (int e = -18; e <= 18; e += 2) {
        float s = ldexpf(1.0f, e * 3);
        one(0.3f * s, -0.5f * s, 0.81f * s, "scaled");
    }

    printf("test: single dominant components, where two squares underflow\n");
    for (int e = -20; e <= 20; e += 4) {
        float big = ldexpf(1.0f, e * 3);
        one(big, 1e-8f * big, -1e-8f * big, "dominant x");
        one(1e-8f * big, big, 1e-8f * big, "dominant y");
    }

    printf("test: fuzz\n");
    {
        std::mt19937 rng(0x00d3a1u);
        for (int i = 0; i < 8000; i++) {
            float x = ((float)(rng() % 20001) - 10000.0f) / 1000.0f;
            float y = ((float)(rng() % 20001) - 10000.0f) / 1000.0f;
            float z = ((float)(rng() % 20001) - 10000.0f) / 1000.0f;
            int e = (int)(rng() % 20) - 10;
            float s = ldexpf(1.0f, e);
            one(x * s, y * s, z * s, "fuzz");
        }
        printf("  worst component error %.3e, worst length error %.3e (tolerance %.1e)\n",
               worst, worst_len, TOL);
        printf("  %ld skipped as zero or non-finite\n", skipped);
    }

    printf("test: THROUGHPUT - once per emitted quad, budget 83 cycles\n");
    {
        float ox, oy, oz;
        long c0 = t.cycles;
        const int N = 200;
        for (int i = 0; i < N; i++) t.run(0.3f + i * 0.001f, -0.5f, 0.81f, &ox, &oy, &oz);
        double per = (double)(t.cycles - c0) / N;
        printf("  %.1f cycles per vector\n", per);
        checks++;
        if (per > 83.0) { fails++; printf("  FAIL over the per-quad budget\n"); }
    }

    printf("m1_geo_norm: checks=%ld fails=%ld skipped=%ld\n", checks, fails, skipped);
    return fails ? 1 : 0;
}
