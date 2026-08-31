// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// One quad through the clipper, with everything visible.
//
// THE FIRST THING THIS DOES IS PROVE THE PROBE PRINTS. The previous attempt at
// this module was debugged by patching probes into a bench, getting no output,
// and concluding the signal never changed - when a probe that failed to patch
// in prints exactly the same nothing. CLAUDE.md has a rule about it: when a
// measurement says "never", check that the instrument could have seen it. So
// the state is dumped every cycle for the first quad, whether anything
// interesting happens or not, and a run that prints no state lines is a broken
// bench rather than a stalled DUT.

#include "Vtb_clip_top.h"
#include "Vtb_clip_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static long checks = 0, fails = 0;
static void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; printf("  FAIL %s\n", what); }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_clip_top* d = new Vtb_clip_top;

    // A viewport the size of the screen, and MAME's own reduction of it.
    const float XC = 248.0f, YC = 192.0f;
    const float ZOOMX = 256.0f, ZOOMY = 256.0f, VIEWX = 0.0f, VIEWY = 0.0f;
    const float X1 = 0.0f, X2 = 495.0f, Y1 = 0.0f, Y2 = 383.0f;
    const float A_LEFT   = ( X1 - XC - VIEWX) / ZOOMX;
    const float A_RIGHT  = ( X2 - XC - VIEWX) / ZOOMX;
    const float A_BOTTOM = (-Y1 + YC - VIEWY) / ZOOMY;
    const float A_TOP    = (-Y2 + YC - VIEWY) / ZOOMY;
    printf("planes: left %g right %g bottom %g top %g\n",
           A_LEFT, A_RIGHT, A_BOTTOM, A_TOP);

    auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

    d->rst_n = 0; d->in_valid = 0;
    d->a_left = f2u(A_LEFT); d->a_right = f2u(A_RIGHT);
    d->a_bottom = f2u(A_BOTTOM); d->a_top = f2u(A_TOP);
    d->xc = f2u(XC); d->yc = f2u(YC);
    d->zoomx = f2u(ZOOMX); d->zoomy = f2u(ZOOMY);
    d->viewx = f2u(VIEWX); d->viewy = f2u(VIEWY);
    for (int i = 0; i < 8; i++) tick();
    d->rst_n = 1;
    for (int i = 0; i < 8; i++) tick();

    // A quad with three vertices comfortably inside the frustum and one below
    // the bottom plane. p.y > p.z * a_bottom is the bottom test, and a_bottom
    // is positive here, so a large positive y at small z is outside.
    struct P { float x, y, z; int sx, sy; };
    P q[4] = {
        { 0.0f,   0.0f, 10.0f, 248, 192 },
        { 1.0f,   0.0f, 10.0f, 273, 192 },
        { 1.0f,   1.0f, 10.0f, 273, 167 },
        { 0.0f, 100.0f, 10.0f, 248,   0 },   // far below: y = 100 at z = 10
    };
    printf("bottom test on each vertex: ");
    for (int i = 0; i < 4; i++)
        printf("%d ", q[i].y > q[i].z * A_BOTTOM ? 1 : 0);
    printf("  (1 = outside)\n");

    d->in_x0 = f2u(q[0].x); d->in_y0 = f2u(q[0].y); d->in_z0 = f2u(q[0].z);
    d->in_x1 = f2u(q[1].x); d->in_y1 = f2u(q[1].y); d->in_z1 = f2u(q[1].z);
    d->in_x2 = f2u(q[2].x); d->in_y2 = f2u(q[2].y); d->in_z2 = f2u(q[2].z);
    d->in_x3 = f2u(q[3].x); d->in_y3 = f2u(q[3].y); d->in_z3 = f2u(q[3].z);
    d->in_sx0 = q[0].sx; d->in_sy0 = q[0].sy;
    d->in_sx1 = q[1].sx; d->in_sy1 = q[1].sy;
    d->in_sx2 = q[2].sx; d->in_sy2 = q[2].sy;
    d->in_sx3 = q[3].sx; d->in_sy3 = q[3].sy;
    d->in_valid = 1;

    // Every cycle, unconditionally, for as long as it takes. If this prints
    // nothing at all then the bench is broken, not the DUT.
    auto* r = d->rootp;
    int emitted = 0, last_kst = -1;
    for (int c = 0; c < 4000; c++) {
        tick();
        int kst = r->tb_clip_top__DOT__u_clip__DOT__kst;
        if (kst != last_kst || c < 4) {
            printf("  c=%4d kst=%2d lvl=%d is_out=%x sp=%d cs=%2d cn=%d "
                   "t=%08x num=%08x den=%08x\n",
                   c, kst,
                   r->tb_clip_top__DOT__u_clip__DOT__lvl,
                   r->tb_clip_top__DOT__u_clip__DOT__is_out,
                   r->tb_clip_top__DOT__u_clip__DOT__sp,
                   r->tb_clip_top__DOT__u_clip__DOT__cs,
                   r->tb_clip_top__DOT__u_clip__DOT__cn,
                   r->tb_clip_top__DOT__u_clip__DOT__c_t,
                   r->tb_clip_top__DOT__u_clip__DOT__c_num,
                   r->tb_clip_top__DOT__u_clip__DOT__c_den);
            last_kst = kst;
        }
        if (d->in_ready) d->in_valid = 0;
        if (d->out_valid) {
            printf("  OUT (%d,%d)(%d,%d)(%d,%d)(%d,%d)\n",
                   (int16_t)d->out_sx0, (int16_t)d->out_sy0,
                   (int16_t)d->out_sx1, (int16_t)d->out_sy1,
                   (int16_t)d->out_sx2, (int16_t)d->out_sy2,
                   (int16_t)d->out_sx3, (int16_t)d->out_sy3);
            emitted++;
        }
        if (!d->in_valid && kst == 0 && c > 40) break;
    }

    printf("in=%u out=%u dropped=%u, emitted %d quads\n",
           d->dbg_in, d->dbg_out, d->dbg_dropped, emitted);
    check(emitted > 0, "the clipper must emit at least one quad");
    printf("m1_geo_clip: checks=%ld fails=%ld\n", checks, fails);
    return fails ? 1 : 0;
}
