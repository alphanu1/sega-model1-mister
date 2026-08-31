// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The backface determinant, against MAME's view_determinant in host float.
//
// This decides whether a polygon is drawn at all, so its failure mode is not a
// wrong pixel - it is a missing surface, or an interior surface showing through
// one that should have hidden it. Both look like a geometry bug somewhere else.
//
// Bit-exact, for the same reason m1_geo_xform is: MAME evaluates in host float
// and the FP units are fuzzed against host float, so only the ASSOCIATION can
// differ. The expression has three places where it matters -
//
//     the six differences are formed BEFORE the products, not folded in
//     each cofactor is (a*b - c*d), not a*(b - c*d/a) or any rearrangement
//     the three terms sum LEFT TO RIGHT: (A + B) + C
//
// - and a refactor into a cross product plus a dot, which is what the expression
// obviously is, changes the last bit on ordinary inputs. So the fuzz compares
// bits, and the directed cases pin the sign.
//
// The sign is what the hardware acts on, so the boundary gets its own case: MAME
// culls on `> 0`, so a determinant of EXACTLY zero - an edge-on polygon - is
// drawn. `>= 0` would cull a sliver the reference keeps.

#include "Vm1_geo_det_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>

static long checks = 0, fails = 0, skipped = 0, printed = 0;
static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static bool is_denorm(uint32_t u) { return ((u >> 23) & 0xff) == 0 && (u & 0x7fffff); }
static bool bad(uint32_t u) {
    float f = u2f(u);
    return is_denorm(u) || std::isnan(f) || std::isinf(f);
}

struct P { float x, y, z; };

static float model(const P& p1, const P& p2, const P& p3) {
    volatile float x1 = p2.x - p1.x, y1 = p2.y - p1.y, z1 = p2.z - p1.z;
    volatile float x2 = p3.x - p1.x, y2 = p3.y - p1.y, z2 = p3.z - p1.z;
    volatile float a = y1 * z2 - y2 * z1;
    volatile float b = z1 * x2 - z2 * x1;
    volatile float c = x1 * y2 - x2 * y1;
    volatile float t0 = p1.x * a, t1 = p1.y * b, t2 = p1.z * c;
    return (t0 + t1) + t2;
}

struct Dut {
    Vm1_geo_det_top* d = new Vm1_geo_det_top;
    long cycles = 0;
    void tick() { cycles++; d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
    void reset() {
        d->rst_n = 0; d->in_valid = 0;
        for (int i = 0; i < 8; i++) tick();
        d->rst_n = 1;
        for (int i = 0; i < 8; i++) tick();
    }
    bool run(const P& p1, const P& p2, const P& p3, uint32_t* det, int* pos) {
        int guard = 0;
        while (!d->in_ready && ++guard < 2000) tick();
        d->in_valid = 1;
        d->p1x = f2u(p1.x); d->p1y = f2u(p1.y); d->p1z = f2u(p1.z);
        d->p2x = f2u(p2.x); d->p2y = f2u(p2.y); d->p2z = f2u(p2.z);
        d->p3x = f2u(p3.x); d->p3y = f2u(p3.y); d->p3z = f2u(p3.z);
        tick();
        d->in_valid = 0;
        guard = 0;
        while (!d->out_valid && ++guard < 2000) tick();
        if (guard >= 2000) return false;
        *det = d->out_det; *pos = d->out_positive;
        return true;
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Dut t; t.reset();

    printf("test: a degenerate triangle gives exactly zero, and is NOT culled\n");
    {
        // Three collinear points: zero volume, so the determinant is zero. MAME
        // culls on `> 0`, so this polygon is DRAWN.
        P p1{1, 1, 1}, p2{2, 2, 2}, p3{3, 3, 3};
        uint32_t det; int pos;
        t.run(p1, p2, p3, &det, &pos);
        checks += 2;
        if ((det & 0x7fffffffu) != 0) { fails++; printf("  FAIL degenerate det = %g\n", u2f(det)); }
        if (pos) { fails++; printf("  FAIL zero determinant reported positive - it would be culled\n"); }
    }

    printf("test: reversing the winding flips the sign\n");
    {
        P p1{0, 0, 1}, p2{1, 0, 1}, p3{0, 1, 1};
        uint32_t d1, d2; int s1, s2;
        t.run(p1, p2, p3, &d1, &s1);
        t.run(p1, p3, p2, &d2, &s2);
        checks += 2;
        if ((d1 >> 31) == (d2 >> 31)) {
            fails++;
            printf("  FAIL winding does not flip the sign: %g and %g\n", u2f(d1), u2f(d2));
        }
        if (s1 == s2) { fails++; printf("  FAIL cull decision identical for both windings\n"); }
        printf("  one winding %g (cull=%d), the other %g (cull=%d)\n",
               u2f(d1), s1, u2f(d2), s2);
    }

    printf("test: a NaN determinant is not positive, so it is not culled\n");
    {
        // `> 0` is false for a NaN in C, so MAME does not cull. Testing the sign
        // bit alone would cull a positive NaN and keep a negative one.
        P p1{u2f(0x7fc00001u), 1, 1}, p2{2, 2, 2}, p3{3, 1, 4};
        uint32_t det; int pos;
        t.run(p1, p2, p3, &det, &pos);
        checks++;
        if (pos) { fails++; printf("  FAIL NaN determinant reported positive\n"); }
    }

    printf("test: fuzz, bit-exact against host float\n");
    {
        std::mt19937 rng(0xd37e11au);
        long positive = 0, negative = 0, zero = 0;
        for (int iter = 0; iter < 6000; iter++) {
            auto rnd = [&]() {
                float v = ((float)(rng() % 200001) - 100000.0f) / 1000.0f;
                if ((rng() & 15) == 0) v *= 1e3f;
                return v;
            };
            P p1{rnd(), rnd(), rnd()}, p2{rnd(), rnd(), rnd()}, p3{rnd(), rnd(), rnd()};
            float ref = model(p1, p2, p3);
            if (bad(f2u(ref))) { skipped++; continue; }
            uint32_t det; int pos;
            checks++;
            if (!t.run(p1, p2, p3, &det, &pos)) {
                fails++;
                if (printed++ < 20) printf("  FAIL no result\n");
                continue;
            }
            if (det != f2u(ref)) {
                fails++;
                if (printed++ < 20)
                    printf("  FAIL det %08x (%g) expected %08x (%g)\n",
                           det, u2f(det), f2u(ref), ref);
            }
            checks++;
            int exp_pos = (ref > 0.0f) ? 1 : 0;
            if (pos != exp_pos) {
                fails++;
                if (printed++ < 20)
                    printf("  FAIL cull flag %d for det %g\n", pos, ref);
            }
            if (ref > 0) positive++; else if (ref < 0) negative++; else zero++;
        }
        printf("  %ld would be culled, %ld drawn, %ld exactly zero, %ld skipped\n",
               positive, negative, zero, skipped);
        checks++;
        if (positive < 500 || negative < 500) {
            fails++;
            printf("  FAIL the fuzz must produce BOTH cull decisions in quantity\n");
        }
    }

    printf("test: THROUGHPUT - once per record, budget 68 cycles\n");
    {
        P p1{1, 2, 3}, p2{4, 5, 6}, p3{7, 8, 10};
        uint32_t det; int pos;
        long c0 = t.cycles;
        const int N = 200;
        for (int i = 0; i < N; i++) t.run(p1, p2, p3, &det, &pos);
        double per = (double)(t.cycles - c0) / N;
        printf("  %.1f cycles per record\n", per);
        printf("  peak frame needs %.0f cycles of the 818,133 available (%.0f%%)\n",
               per * 5831, 100.0 * per * 5831 / 818133.0);
        checks++;
        if (per * 5831 > 818133.0) {
            fails++;
            printf("  FAIL OVER BUDGET by %.2fx\n", per * 5831 / 818133.0);
        }
    }

    printf("m1_geo_det: checks=%ld fails=%ld skipped=%ld\n", checks, fails, skipped);
    return fails ? 1 : 0;
}
