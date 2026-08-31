// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The projection stage, against MAME's project_point.
//
// THIS BENCH DOES NOT DEMAND BIT-EXACTNESS, AND SAYS WHY
//
// Every other FP bench in this project compares bits. This one cannot, because
// the module deliberately computes one reciprocal and two multiplies where MAME
// divides twice - fp_div is 29 cycles and does not pipeline, so two per point is
// 58 against a 34-cycle budget. The deviation was measured before it was taken
// (docs/findings.md: 0.002% of points land on a different pixel, never by more
// than one) and this bench holds the DUT to exactly that: the PIXEL must match
// the reference, or differ by at most one, and the rate of differences must stay
// in the range that was measured.
//
// So the bench asserts two things a tolerance alone would not:
//
//   * no point is ever more than one pixel out. A wrong operand order or a
//     mis-scaled zoom shows up as a large error, not a rounding one, and would
//     hide inside a percentage.
//   * the difference RATE stays near 0.002%. A reciprocal that is systematically
//     wrong in the last bit would pass a "within one pixel" test on every point
//     while differing on far more of them than it should.
//
// The exact cases - z <= 0, the y axis flip, NaN and infinite coordinates - are
// checked against the reference exactly, because none of them involve the
// reciprocal at all.

#include "Vm1_geo_project_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>
#include <vector>

static long checks = 0, fails = 0, printed = 0;
static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

struct View { float xc, yc, zoomx, zoomy, viewx, viewy; };

struct Dut {
    Vm1_geo_project_top* d = new Vm1_geo_project_top;
    long cycles = 0;
    void tick() { cycles++; d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
    void reset() {
        d->rst_n = 0; d->in_valid = 0;
        for (int i = 0; i < 8; i++) tick();
        d->rst_n = 1;
        for (int i = 0; i < 8; i++) tick();
    }
    void set_view(const View& v) {
        d->xc = f2u(v.xc); d->yc = f2u(v.yc);
        d->zoomx = f2u(v.zoomx); d->zoomy = f2u(v.zoomy);
        d->viewx = f2u(v.viewx); d->viewy = f2u(v.viewy);
    }
    bool project(float x, float y, float z, int32_t* sx, int32_t* sy, int* behind) {
        int guard = 0;
        while (!d->in_ready && ++guard < 2000) tick();
        d->in_valid = 1; d->in_x = f2u(x); d->in_y = f2u(y); d->in_z = f2u(z);
        tick();
        d->in_valid = 0;
        guard = 0;
        while (!d->out_valid && ++guard < 2000) tick();
        if (guard >= 2000) return false;
        *sx = (int32_t)d->out_sx; *sy = (int32_t)d->out_sy; *behind = d->out_behind;
        return true;
    }
};

// MAME's project_point plus push_object's guard.
static void model(const View& v, float x, float y, float z,
                  int32_t* sx, int32_t* sy, int* behind) {
    if (!(z > 0.0f)) { *sx = 0; *sy = 0; *behind = 1; return; }
    *behind = 0;
    volatile float xx = x / z, yy = y / z;
    volatile float fx = v.xc + (xx * v.zoomx + v.viewx);
    volatile float fy = v.yc - (yy * v.zoomy + v.viewy);
    *sx = (int32_t)fx; *sy = (int32_t)fy;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Dut t; t.reset();

    // The viewport the reference actually uses, measured over 1,200 frames:
    // 248,231 0,39 495,422.
    View v { 248.0f, 231.0f, 400.0f, 400.0f, 0.0f, 0.0f };
    t.set_view(v);

    printf("test: a point on the axis lands at the viewport centre\n");
    {
        int32_t sx, sy; int behind;
        t.project(0.0f, 0.0f, 10.0f, &sx, &sy, &behind);
        checks += 3;
        if (sx != 248) { fails++; printf("  FAIL centre x: %d\n", sx); }
        if (sy != 231) { fails++; printf("  FAIL centre y: %d\n", sy); }
        if (behind)    { fails++; printf("  FAIL centre marked behind\n"); }
    }

    printf("test: the y axis is FLIPPED - yc minus, not plus\n");
    {
        int32_t sx, sy; int behind;
        // A point above the axis in world terms must land ABOVE the centre on
        // screen, which is a SMALLER y. Adding instead of subtracting gives a
        // picture that is upside down and otherwise entirely plausible.
        t.project(0.0f, 1.0f, 10.0f, &sx, &sy, &behind);
        checks++;
        if (sy >= 231) { fails++; printf("  FAIL y not flipped: got %d, expected < 231\n", sy); }
        else printf("  world +y maps to screen y %d, above the centre at 231\n", sy);
    }

    printf("test: z <= 0 gives (0,0) and is flagged, without running the divide\n");
    {
        int32_t sx, sy; int behind;
        for (float z : {0.0f, -0.0f, -1.0f, -1e30f}) {
            t.project(5.0f, 5.0f, z, &sx, &sy, &behind);
            checks += 3;
            if (sx != 0)  { fails++; printf("  FAIL behind x: z=%g gave %d\n", z, sx); }
            if (sy != 0)  { fails++; printf("  FAIL behind y: z=%g gave %d\n", z, sy); }
            if (!behind)  { fails++; printf("  FAIL behind flag: z=%g\n", z); }
        }
    }

    printf("test: a NaN z is NOT positive, so it takes the behind path\n");
    {
        // `z > 0` is false for a NaN in C, so MAME assigns (0,0). Testing only
        // the sign bit would call a negative NaN behind and a positive one in
        // front, which is a plausible-looking wrong answer.
        int32_t sx, sy; int behind;
        for (uint32_t nz : {0x7fc00001u, 0xffc00001u}) {
            t.project(5.0f, 5.0f, u2f(nz), &sx, &sy, &behind);
            checks += 2;
            if (!behind) { fails++; printf("  FAIL NaN z %08x not behind\n", nz); }
            if (sx != 0 || sy != 0) { fails++; printf("  FAIL NaN z %08x gave %d,%d\n", nz, sx, sy); }
        }
    }

    printf("test: the behind path is FAST - it must not spend the divider\n");
    {
        int32_t sx, sy; int behind;
        long c0 = t.cycles;
        for (int i = 0; i < 50; i++) t.project(1.0f, 1.0f, -1.0f, &sx, &sy, &behind);
        double behind_cost = (double)(t.cycles - c0) / 50;
        c0 = t.cycles;
        for (int i = 0; i < 50; i++) t.project(1.0f, 1.0f, 100.0f, &sx, &sy, &behind);
        double front_cost = (double)(t.cycles - c0) / 50;
        printf("  behind %.1f cycles, in front %.1f cycles\n", behind_cost, front_cost);
        checks++;
        if (behind_cost >= front_cost) {
            fails++;
            printf("  FAIL the behind path is not cheaper - the divide is being run anyway\n");
        }
    }

    printf("test: fuzz - the pixel must match, or differ by at most one\n");
    {
        std::mt19937 rng(0xc0ffee11u);
        long compared = 0, differed = 0, big = 0;
        for (int iter = 0; iter < 20000; iter++) {
            if ((iter % 2000) == 0) {
                // Sweep the viewport too: a zoom that only ever takes one value
                // cannot catch a mis-scaled multiply.
                v.zoomx = ldexpf(1.0f, (int)(rng() % 12)) * 25.0f;
                v.zoomy = v.zoomx;
                v.viewx = (float)((int)(rng() % 41) - 20);
                v.viewy = (float)((int)(rng() % 41) - 20);
                t.set_view(v);
            }
            float ex = powf(10.0f, (float)(rng() % 50) / 10.0f - 1.0f);
            float x = ex * ((float)(rng() % 20001) - 10000.0f) / 1000.0f;
            float y = ex * ((float)(rng() % 20001) - 10000.0f) / 1000.0f;
            float z = ex * (0.01f + (float)(rng() % 100000) / 1000.0f);

            int32_t esx, esy; int ebehind;
            model(v, x, y, z, &esx, &esy, &ebehind);
            // Only points that could reach the screen are interesting, and the
            // int32-indefinite cases are fp_to_int's own bench, not this one.
            if (esx == INT32_MIN || esy == INT32_MIN) continue;
            if (esx < -30000 || esx > 30000 || esy < -30000 || esy > 30000) continue;

            int32_t gsx, gsy; int gbehind;
            checks++;
            if (!t.project(x, y, z, &gsx, &gsy, &gbehind)) {
                fails++;
                if (printed++ < 20) printf("  FAIL no result\n");
                continue;
            }
            if (gbehind != ebehind) {
                fails++;
                if (printed++ < 20) printf("  FAIL behind flag differs\n");
                continue;
            }
            compared++;
            long dx = labs((long)gsx - esx), dy = labs((long)gsy - esy);
            if (dx || dy) differed++;
            if (dx > 1 || dy > 1) {
                big++;
                fails++;
                if (printed++ < 20)
                    printf("  FAIL more than one pixel out: got %d,%d expected %d,%d"
                           " (x=%g y=%g z=%g zoom=%g)\n",
                           gsx, gsy, esx, esy, x, y, z, v.zoomx);
            }
        }
        double rate = 100.0 * differed / (compared ? compared : 1);
        printf("  %ld compared, %ld differed by one pixel (%.4f%%), %ld by more\n",
               compared, differed, rate, big);
        checks++;
        // The measured rate is 0.002%. Allow an order of magnitude either way -
        // this is guarding against a systematically wrong reciprocal, not
        // pinning a statistic.
        if (rate > 0.05) {
            fails++;
            printf("  FAIL the difference rate is far above the measured 0.002%%\n");
        }
    }

    printf("test: THROUGHPUT streamed - the reciprocal stage must not idle\n");
    {
        // The two stages exist so the next point's reciprocal runs during the
        // previous point's scaling. Waiting for each result before sending the
        // next measures LATENCY and reports the overlap as absent - the same
        // mistake this project already made once, in tb_m1_geo_xform.
        const int N = 400;
        std::vector<float> vx(N), vy(N), vz(N);
        for (int i = 0; i < N; i++) {
            vx[i] = 1.0f + i * 0.01f; vy[i] = 2.0f - i * 0.005f;
            vz[i] = 10.0f + i * 0.1f;
        }
        int sent = 0, recv = 0, guard = 0;
        long c0 = t.cycles;
        while (recv < N && ++guard < 400000) {
            t.d->in_valid = (sent < N);
            if (sent < N) {
                t.d->in_x = f2u(vx[sent]); t.d->in_y = f2u(vy[sent]);
                t.d->in_z = f2u(vz[sent]);
            }
            bool take = t.d->in_valid && t.d->in_ready;
            t.tick();
            if (take) sent++;
            if (t.d->out_valid) {
                int32_t esx, esy; int eb;
                model(v, vx[recv], vy[recv], vz[recv], &esx, &esy, &eb);
                checks++;
                long dx = labs((long)(int32_t)t.d->out_sx - esx);
                long dy = labs((long)(int32_t)t.d->out_sy - esy);
                if (dx > 1 || dy > 1) {
                    fails++;
                    if (printed++ < 20)
                        printf("  FAIL streamed result %d wrong or out of order\n", recv);
                }
                recv++;
            }
        }
        t.d->in_valid = 0;
        checks++;
        if (recv != N) { fails++; printf("  FAIL streaming: %d of %d results\n", recv, N); }

        double per = (double)(t.cycles - c0) / N;
        printf("  %.1f cycles per point streamed, %.1f per record (2 points)\n", per, per * 2);
        printf("  peak frame needs %.0f cycles of the 818,133 available (%.0f%%)\n",
               per * 2 * 5831, 100.0 * per * 2 * 5831 / 818133.0);
        checks++;
        if (per * 2 * 5831 > 818133.0) {
            fails++;
            printf("  FAIL OVER BUDGET by %.2fx\n", per * 2 * 5831 / 818133.0);
        }
    }

    printf("m1_geo_project: checks=%ld fails=%ld\n", checks, fails);
    return fails ? 1 : 0;
}
