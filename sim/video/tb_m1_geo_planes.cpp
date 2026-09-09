// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The four frustum plane ratios, against model1_v.cpp's set_viewport:
//
//     a_left = (x1 - xc - viewx) / zoomx    a_right = (x2 - xc - viewx) / zoomx
//     a_bottom = (yc - y1 - viewy) / zoomy  a_top   = (yc - y2 - viewy) / zoomy
//
// THIS MODULE HAD NO BENCH UNTIL 2026-09-08, and that is how the left-side cut
// survived four sessions. a_left decides where the left clip plane lands, and a
// wrong one puts a hard vertical edge across the picture:
//
//     screen_x = xc + a_left*zoomx + viewx
//
// Measured on the board with xc=248, zoomx=280, viewx=0: the healthy a_left is
// -0.8828 (screen_x = 0.8, the left edge) and during the cut it reads -0.0571,
// which is screen_x = 232 of 496 - the 47% cut. Same viewport in both states.
//
// The cause is the case `mid_set_request` covers below. `recompute` is a
// ONE-CYCLE pulse and was only sampled in S_IDLE, but a set is four planes of
// two adds and a divide through a shared pool. The frustum follows THREE display
// list commands - viewport, zoom and view translation - which the game sends
// together, so the later ones landed mid-set and were DROPPED. The operands are
// combinational, so the in-flight set was computed from a mix and then never
// recomputed, and the wrong plane LATCHED until some later command happened to
// arrive while the module was idle. That is the "it lasts minutes" symptom.

#include "Vm1_geo_planes_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>

static long checks = 0, fails = 0, printed = 0;
static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static Vm1_geo_planes_top *dut;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

static void fail(const char *what, float got, float want) {
    fails++;
    if (printed++ < 20)
        fprintf(stderr, "  FAIL %s: got %.7g (%08x) want %.7g (%08x)\n",
                what, got, f2u(got), want, f2u(want));
}

// Drive a viewport and run to completion. Returns cycles taken.
static int settle(int limit = 20000) {
    int n = 0;
    while (n < limit) { tick(); n++; if (!dut->busy) break; }
    return n;
}

static void set_vp(float xc, float yc, float zx, float zy,
                   float vx, float vy, float x1, float x2, float y1, float y2) {
    dut->xc = f2u(xc); dut->yc = f2u(yc);
    dut->zoomx = f2u(zx); dut->zoomy = f2u(zy);
    dut->viewx = f2u(vx); dut->viewy = f2u(vy);
    dut->x1 = f2u(x1); dut->x2 = f2u(x2);
    dut->y1 = f2u(y1); dut->y2 = f2u(y2);
}

static void check_set(const char *tag, float xc, float yc, float zx, float zy,
                      float vx, float vy, float x1, float x2, float y1, float y2) {
    float wl = (x1 - xc - vx) / zx, wr = (x2 - xc - vx) / zx;
    float wb = (yc - y1 - vy) / zy, wt = (yc - y2 - vy) / zy;
    char m[128];
    checks++; if (u2f(dut->a_left)   != wl) { snprintf(m,sizeof m,"%s a_left",tag);   fail(m, u2f(dut->a_left), wl); }
    checks++; if (u2f(dut->a_right)  != wr) { snprintf(m,sizeof m,"%s a_right",tag);  fail(m, u2f(dut->a_right), wr); }
    checks++; if (u2f(dut->a_bottom) != wb) { snprintf(m,sizeof m,"%s a_bottom",tag); fail(m, u2f(dut->a_bottom), wb); }
    checks++; if (u2f(dut->a_top)    != wt) { snprintf(m,sizeof m,"%s a_top",tag);    fail(m, u2f(dut->a_top), wt); }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vm1_geo_planes_top;
    dut->rst_n = 0; dut->recompute = 0;
    set_vp(248, 192, 280, 280, 0, 0, 0, 496, 0, 384);
    for (int i = 0; i < 8; i++) tick();
    dut->rst_n = 1;
    for (int i = 0; i < 4; i++) tick();

    // ---- 1. the board's own viewport, the one the capture measured
    dut->recompute = 1; tick(); dut->recompute = 0;
    int cyc = settle();
    check_set("board", 248, 192, 280, 280, 0, 0, 0, 496, 0, 384);
    // and the screen_x the healthy capture showed
    float sx = 248.0f + u2f(dut->a_left) * 280.0f;
    checks++;
    if (!(std::fabs(sx) < 1.0f)) {
        fails++;
        fprintf(stderr, "  FAIL board: left plane lands at screen_x %.2f, want ~0\n", sx);
    }

    // ---- 2. THE REGRESSION. A request arriving mid-set must not be lost.
    //
    // Start a set on one viewport, then change the viewport and pulse recompute
    // while it is still busy. The planes must end up describing the SECOND
    // viewport. Before the `pend` fix the pulse was dropped and they described
    // the first, or a mix of both, and stayed that way.
    int mid_seen = 0;
    for (int trial = 0; trial < 64; trial++) {
        set_vp(248, 192, 280, 280, 0, 0, 0, 496, 0, 384);
        dut->recompute = 1; tick(); dut->recompute = 0;
        // land the second request part-way through the set
        // A full set is ~172 cycles with an uncontended pool, so keep the
        // second request inside that window. In the design six other clients
        // share the pool and a set takes considerably longer, which is why the
        // game's viewport/zoom/translate burst lands mid-set so readily.
        int delay = 3 + (trial * 5) % 150;
        for (int i = 0; i < delay && dut->busy; i++) tick();
        if (!dut->busy) continue;              // set already finished; not this test
        mid_seen++;
        set_vp(248, 192, 280, 280, 0, 0, 232, 496, 0, 384);
        dut->recompute = 1; tick(); dut->recompute = 0;
        settle();
        check_set("mid_set_request", 248, 192, 280, 280, 0, 0, 232, 496, 0, 384);
    }
    checks++;
    if (mid_seen < 60) { fails++; fprintf(stderr, "  FAIL only %d mid-set trials landed\n", mid_seen); }

    // ---- 3. busy must cover the redo, or an object is clipped on mixed planes
    set_vp(248, 192, 280, 280, 0, 0, 0, 496, 0, 384);
    dut->recompute = 1; tick(); dut->recompute = 0;
    for (int i = 0; i < 50 && dut->busy; i++) tick();
    set_vp(248, 192, 280, 280, 0, 0, 100, 496, 0, 384);
    dut->recompute = 1; tick(); dut->recompute = 0;
    // From here to the end of the redo, busy must never drop.
    int lowbusy = 0, guard = 0;
    while (guard++ < 20000) {
        tick();
        if (!dut->busy) { lowbusy++; break; }
    }
    checks++;
    if (lowbusy) {
        // busy dropped - legal only if the planes are already the final ones
        check_set("busy_drop_final", 248, 192, 280, 280, 0, 0, 100, 496, 0, 384);
    }
    settle();
    check_set("after_redo", 248, 192, 280, 280, 0, 0, 100, 496, 0, 384);

    // ---- 4. fuzz ordinary viewports
    std::mt19937 rng(0x9E3779B9u);
    std::uniform_real_distribution<float> ed(-512, 512), zd(16, 512), vd(-64, 64);
    for (int i = 0; i < 400; i++) {
        float xc = ed(rng), yc = ed(rng), zx = zd(rng), zy = zd(rng);
        float vx = vd(rng), vy = vd(rng);
        float x1 = ed(rng), x2 = ed(rng), y1 = ed(rng), y2 = ed(rng);
        set_vp(xc, yc, zx, zy, vx, vy, x1, x2, y1, y2);
        dut->recompute = 1; tick(); dut->recompute = 0;
        settle();
        check_set("fuzz", xc, yc, zx, zy, vx, vy, x1, x2, y1, y2);
    }

    printf("m1_geo_planes: checks=%ld fails=%ld set=%d cycles mid=%d\n",
           checks, fails, cyc, mid_seen);
    delete dut;
    return fails ? 1 : 0;
}
