// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The geometry matrix transform, against MAME's transform_point in host float.
//
// WHY HOST FLOAT IS A LEGITIMATE ORACLE HERE
//
// MAME evaluates the whole geometry pipeline in host `float`, and fp_mul and
// fp_add are already fuzzed bit-exactly against host float (sim/tgp/tb_fp_mul.cpp:
// "reference is the host C float, matching MAME's evaluation model"). So the same
// operations in the same order must give the same bits, and this bench holds the
// DUT to that rather than to a tolerance. A tolerance would pass a transform that
// sums its products in the wrong order, and that is the bug most likely to be
// here: floating-point addition is not associative, so
//
//     ((a + b) + c) + d        as MAME does it
//     (a + b) + (c + d)        one cycle shorter, and a different number
//
// differ in the last place on ordinary inputs. The fuzz below is run on values
// chosen to make that difference REACH the result, and the directed case proves
// the bench can tell the two apart - a check that passes either way is not
// evidence.
//
// Denormal and NaN results are skipped, as everywhere else in this project: the
// FP units flush denormals and the question of what real silicon does is open
// (README.md, docs/m0-mb86233-spike.md). Widening that here would be answering it
// by accident.

#include "Vm1_geo_xform.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>
#include <vector>

static long checks = 0, fails = 0, skipped = 0, printed = 0;

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static bool is_denorm(uint32_t u) { return ((u >> 23) & 0xff) == 0 && (u & 0x7fffff); }
static bool bad(uint32_t u) {
    float f = u2f(u);
    return is_denorm(u) || std::isnan(f) || std::isinf(f);
}

struct Dut {
    Vm1_geo_xform* d = new Vm1_geo_xform;
    uint32_t m[12];
    long cycles = 0;

    void tick() { cycles++; d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
    void reset() {
        d->rst_n = 0; d->in_valid = 0; d->mat_we = 0;
        for (int i = 0; i < 8; i++) tick();
        d->rst_n = 1;
        for (int i = 0; i < 8; i++) tick();
    }
    void set_matrix(const uint32_t* mm) {
        memcpy(m, mm, 12 * 4);
        for (int i = 0; i < 12; i++) {
            d->mat_we = 1; d->mat_idx = i; d->mat_data = mm[i];
            tick();
        }
        d->mat_we = 0; tick();
    }
    // Returns false if the DUT never produced a result.
    bool xform(uint32_t x, uint32_t y, uint32_t z, bool translate,
               uint32_t* ox, uint32_t* oy, uint32_t* oz) {
        int guard = 0;
        while (!d->in_ready && ++guard < 1000) tick();
        d->in_valid = 1; d->in_x = x; d->in_y = y; d->in_z = z;
        d->in_translate = translate;
        tick();
        d->in_valid = 0;
        guard = 0;
        while (!d->out_valid && ++guard < 1000) tick();
        if (guard >= 1000) return false;
        *ox = d->out_x; *oy = d->out_y; *oz = d->out_z;
        return true;
    }
};

// MAME's transform_point / transform_vector, left to right.
static void model(const uint32_t* m, uint32_t xu, uint32_t yu, uint32_t zu,
                  bool translate, float* ox, float* oy, float* oz) {
    float x = u2f(xu), y = u2f(yu), z = u2f(zu);
    // Written as separate statements so the summation order is explicit and the
    // compiler cannot reassociate it (it may not anyway without -ffast-math).
    float ax = u2f(m[0]) * x, bx = u2f(m[3]) * y, cx = u2f(m[6]) * z;
    float ay = u2f(m[1]) * x, by = u2f(m[4]) * y, cy = u2f(m[7]) * z;
    float az = u2f(m[2]) * x, bz = u2f(m[5]) * y, cz = u2f(m[8]) * z;
    float sx = (ax + bx) + cx;
    float sy = (ay + by) + cy;
    float sz = (az + bz) + cz;
    if (translate) { sx = sx + u2f(m[9]); sy = sy + u2f(m[10]); sz = sz + u2f(m[11]); }
    *ox = sx; *oy = sy; *oz = sz;
}

static void one(Dut& t, const uint32_t* m, uint32_t x, uint32_t y, uint32_t z,
                bool translate, const char* what) {
    float ex, ey, ez;
    model(m, x, y, z, translate, &ex, &ey, &ez);
    if (bad(f2u(ex)) || bad(f2u(ey)) || bad(f2u(ez))) { skipped++; return; }
    uint32_t ox, oy, oz;
    checks++;
    if (!t.xform(x, y, z, translate, &ox, &oy, &oz)) {
        fails++;
        if (printed++ < 20) printf("  FAIL %s: no result\n", what);
        return;
    }
    if (ox != f2u(ex) || oy != f2u(ey) || oz != f2u(ez)) {
        fails++;
        if (printed++ < 20)
            printf("  FAIL %s: got %08x,%08x,%08x expected %08x,%08x,%08x"
                   "  (%g,%g,%g vs %g,%g,%g)\n",
                   what, ox, oy, oz, f2u(ex), f2u(ey), f2u(ez),
                   u2f(ox), u2f(oy), u2f(oz), ex, ey, ez);
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Dut t; t.reset();
    std::mt19937 rng(0x5eed1234u);

    printf("test: the identity matrix returns the point unchanged\n");
    {
        uint32_t m[12] = {f2u(1),f2u(0),f2u(0), f2u(0),f2u(1),f2u(0),
                          f2u(0),f2u(0),f2u(1), f2u(0),f2u(0),f2u(0)};
        t.set_matrix(m);
        uint32_t ox, oy, oz;
        t.xform(f2u(3.5f), f2u(-7.25f), f2u(100.0f), true, &ox, &oy, &oz);
        checks += 3;
        if (ox != f2u(3.5f)) { fails++; printf("  FAIL identity x: %g\n", u2f(ox)); }
        if (oy != f2u(-7.25f)) { fails++; printf("  FAIL identity y: %g\n", u2f(oy)); }
        if (oz != f2u(100.0f)) { fails++; printf("  FAIL identity z: %g\n", u2f(oz)); }
    }

    printf("test: the translation column is applied for a POINT\n");
    {
        uint32_t m[12] = {f2u(1),f2u(0),f2u(0), f2u(0),f2u(1),f2u(0),
                          f2u(0),f2u(0),f2u(1), f2u(10),f2u(20),f2u(30)};
        t.set_matrix(m);
        uint32_t ox, oy, oz;
        t.xform(f2u(1), f2u(2), f2u(3), true, &ox, &oy, &oz);
        checks += 3;
        if (u2f(ox) != 11.0f) { fails++; printf("  FAIL translate x: %g\n", u2f(ox)); }
        if (u2f(oy) != 22.0f) { fails++; printf("  FAIL translate y: %g\n", u2f(oy)); }
        if (u2f(oz) != 33.0f) { fails++; printf("  FAIL translate z: %g\n", u2f(oz)); }

        printf("test: and NOT applied for a VECTOR - a normal has no origin\n");
        t.xform(f2u(1), f2u(2), f2u(3), false, &ox, &oy, &oz);
        checks += 3;
        if (u2f(ox) != 1.0f) { fails++; printf("  FAIL vector x: %g\n", u2f(ox)); }
        if (u2f(oy) != 2.0f) { fails++; printf("  FAIL vector y: %g\n", u2f(oy)); }
        if (u2f(oz) != 3.0f) { fails++; printf("  FAIL vector z: %g\n", u2f(oz)); }
    }

    printf("test: summation is LEFT TO RIGHT, and the bench can prove it matters\n");
    {
        // Products chosen so (a+b)+c and a+(b+c) differ: a large value, then two
        // small ones that only survive the addition if they are summed together
        // first. If this case did not distinguish the two orders the check below
        // would be worthless, so it is asserted directly.
        float a = 1.0f, b = -1.0f, c = 1e-8f;
        float lr = (a + b) + c;      // 1e-8
        float rl = a + (b + c);      // 0, the small term lost against 1.0
        checks++;
        if (lr == rl) { fails++; printf("  FAIL the ordering probe does not discriminate\n"); }

        uint32_t m[12] = {f2u(a),f2u(0),f2u(0), f2u(b),f2u(0),f2u(0),
                          f2u(c),f2u(0),f2u(0), f2u(0),f2u(0),f2u(0)};
        t.set_matrix(m);
        uint32_t ox, oy, oz;
        t.xform(f2u(1), f2u(1), f2u(1), true, &ox, &oy, &oz);
        checks++;
        if (u2f(ox) != lr) {
            fails++;
            printf("  FAIL ordering: got %g, left-to-right is %g, right-to-left %g\n",
                   u2f(ox), lr, rl);
        } else {
            printf("  left-to-right %g, right-to-left %g, DUT %g\n", lr, rl, u2f(ox));
        }
    }

    printf("test: fuzz against host float, points and vectors\n");
    {
        for (int iter = 0; iter < 1200; iter++) {
            uint32_t m[12];
            for (int i = 0; i < 12; i++) {
                // Ordinary magnitudes, so results are neither denormal nor inf
                // for most draws - the skip counter reports how many escape.
                float v = ((float)(rng() % 200001) - 100000.0f) / 1000.0f;
                if ((rng() & 7) == 0) v *= 1e4f;
                m[i] = f2u(v);
            }
            t.set_matrix(m);
            for (int p = 0; p < 6; p++) {
                float px = ((float)(rng() % 200001) - 100000.0f) / 100.0f;
                float py = ((float)(rng() % 200001) - 100000.0f) / 100.0f;
                float pz = ((float)(rng() % 200001) - 100000.0f) / 100.0f;
                one(t, m, f2u(px), f2u(py), f2u(pz), (p & 1) != 0, "fuzz");
            }
        }
        printf("  %ld checked, %ld skipped as denormal/inf/NaN\n", checks, skipped);
    }

    printf("test: THROUGHPUT under streaming, and the results still in order\n");
    {
        // The point of the two-stage structure is that a new point's multiplies
        // run during the previous point's adds. Submitting one point and WAITING
        // for it measures latency and reports the pipeline as absent - which is
        // exactly what the first version of this test did, reporting 34 cycles
        // for a stage whose throughput is better than that. Stream instead.
        uint32_t m[12];
        for (int i = 0; i < 12; i++) m[i] = f2u(1.0f + 0.01f * i);
        t.set_matrix(m);

        const int N = 600;
        // Distinct points, so an out-of-order or duplicated result is visible.
        std::vector<float> vx(N), vy(N), vz(N);
        for (int i = 0; i < N; i++) {
            vx[i] = 1.0f + (float)i * 0.5f;
            vy[i] = 2.0f - (float)i * 0.25f;
            vz[i] = 3.0f + (float)i * 0.125f;
        }
        int sent = 0, recv = 0;
        long c0 = t.cycles;
        int guard = 0;
        while (recv < N && ++guard < 200000) {
            t.d->in_valid = (sent < N);
            if (sent < N) {
                t.d->in_x = f2u(vx[sent]); t.d->in_y = f2u(vy[sent]);
                t.d->in_z = f2u(vz[sent]); t.d->in_translate = 1;
            }
            bool take = t.d->in_valid && t.d->in_ready;
            t.tick();
            if (take) sent++;
            if (t.d->out_valid) {
                float ex, ey, ez;
                model(m, f2u(vx[recv]), f2u(vy[recv]), f2u(vz[recv]), true, &ex, &ey, &ez);
                checks++;
                if (t.d->out_x != f2u(ex) || t.d->out_y != f2u(ey) || t.d->out_z != f2u(ez)) {
                    fails++;
                    if (printed++ < 20)
                        printf("  FAIL streamed result %d out of order or wrong\n", recv);
                }
                recv++;
            }
        }
        t.d->in_valid = 0;
        checks++;
        if (recv != N) { fails++; printf("  FAIL streaming: %d of %d results\n", recv, N); }

        double per = (double)(t.cycles - c0) / N;
        printf("  %.1f cycles per transform streamed, %.1f per record (3 transforms)\n",
               per, per * 3);
        printf("  peak frame needs %.0f cycles of the 397,515 available (%.0f%%)\n",
               per * 3 * 5831, 100.0 * per * 3 * 5831 / 397515.0);
        checks++;
        if (per * 3 * 5831 > 397515.0) {
            fails++;
            printf("  FAIL OVER BUDGET by %.2fx\n", per * 3 * 5831 / 397515.0);
        }
    }

    printf("m1_geo_xform: checks=%ld fails=%ld skipped=%ld\n", checks, fails, skipped);
    return fails ? 1 : 0;
}
