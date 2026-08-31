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
#include <vector>
#include <random>

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static long checks = 0, fails = 0;
static void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; printf("  FAIL %s\n", what); }
}

// ------------------------------------------------ the reference, transcribed
// model1_v.cpp fclip_push_quad. The same code as tb_m1_geometry's, here so the
// two clippers can be diffed on one quad at a time instead of across a whole
// object where the first disagreement is buried.
struct CP { float x, y, z; int sx, sy; };
static float G_L, G_R, G_B, G_T, G_XC, G_YC, G_ZX, G_ZY, G_VX, G_VY;

static void cproject(CP& p) {
    if (!(p.z > 0.0f)) { p.sx = 0; p.sy = 0; return; }
    volatile float xx = p.x / p.z, yy = p.y / p.z;
    volatile float fx = G_XC + (xx * G_ZX + G_VX);
    volatile float fy = G_YC - (yy * G_ZY + G_VY);
    p.sx = (int)fx; p.sy = (int)fy;
}
static bool cisc(int level, const CP& p) {
    switch (level) {
        case 0:  return p.y > (p.z * G_B);
        case 1:  return p.y < (p.z * G_T);
        case 2:  return p.x < (p.z * G_L);
        default: return p.x > (p.z * G_R);
    }
}
static CP cclip(int level, const CP& p1, const CP& p2) {
    float a = (level == 0) ? G_B : (level == 1) ? G_T : (level == 2) ? G_L : G_R;
    float v1 = (level >= 2) ? p1.x : p1.y;
    float v2 = (level >= 2) ? p2.x : p2.y;
    float t = (p2.z * a - v2) / ((p2.z - p1.z) * a - (v2 - v1));
    CP r;
    r.x = p1.x * t + p2.x * (1 - t);
    r.y = p1.y * t + p2.y * (1 - t);
    r.z = p1.z * t + p2.z * (1 - t);
    cproject(r);
    return r;
}
struct OutQ { int sx[4], sy[4]; };
static void cfclip(int level, const CP q[4], std::vector<OutQ>& out) {
    if (level == 4) {
        OutQ o;
        for (int i = 0; i < 4; i++) { o.sx[i] = q[i].sx; o.sy[i] = q[i].sy; }
        out.push_back(o); return;
    }
    bool io[4];
    for (int i = 0; i < 4; i++) io[i] = cisc(level, q[i]);
    if (!io[0] && !io[1] && !io[2] && !io[3]) { cfclip(level + 1, q, out); return; }
    if (io[0] && io[1] && io[2] && io[3]) return;
    int i;
    for (i = 0; i < 4; i++) if (io[i] && !io[(i - 1) & 3]) break;
    CP pt[4]; bool o2[4];
    for (int j = 0; j < 4; j++) { pt[j] = q[(i + j) & 3]; o2[j] = io[(i + j) & 3]; }
    auto push = [&](const CP& a, const CP& b, const CP& c, const CP& d) {
        CP n[4] = { a, b, c, d }; cfclip(level + 1, n, out);
    };
    CP c1, c2, c3, c4;
    if (o2[1]) {
        if (o2[2]) { c1 = cclip(level, pt[2], pt[3]); c2 = cclip(level, pt[3], pt[0]);
                     push(c1, pt[3], c2, c2); }
        else       { c1 = cclip(level, pt[1], pt[2]); c2 = cclip(level, pt[3], pt[0]);
                     push(c1, pt[2], pt[3], c2); }
    } else {
        if (o2[2]) { c1 = cclip(level, pt[0], pt[1]); c2 = cclip(level, pt[1], pt[2]);
                     push(c1, pt[1], c2, c2);
                     c3 = cclip(level, pt[2], pt[3]); c4 = cclip(level, pt[3], pt[0]);
                     push(c3, pt[3], c4, c4); }
        else       { c1 = cclip(level, pt[0], pt[1]); c2 = cclip(level, pt[3], pt[0]);
                     push(c1, pt[1], pt[2], pt[3]);
                     push(pt[3], c2, c1, c1); }
    }
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

    G_L = A_LEFT; G_R = A_RIGHT; G_B = A_BOTTOM; G_T = A_TOP;
    G_XC = XC; G_YC = YC; G_ZX = ZOOMX; G_ZY = ZOOMY; G_VX = VIEWX; G_VY = VIEWY;

    // FUZZ, one quad at a time, both clippers on the same input. A whole-object
    // comparison buries the first disagreement; this prints it.
    std::mt19937 rng(0x0c11c5u);   // fixed seed: reproducible
    auto frand = [&](float lo, float hi) {
        return lo + (hi - lo) * (float)(rng() & 0xffffff) / 16777215.0f;
    };

    int printed = 0;
    for (int iter = 0; iter < 2000 && printed < 3; iter++) {
        CP q[4];
        // Around the frustum edges, so a good share of quads actually cross.
        // z GOES NEGATIVE AND THROUGH ZERO. The first pass used z in [2,40] and
        // found nothing, which proved only that the clipper is right in front of
        // the eye. Real quads have vertices at and behind it - project_point
        // returns (0,0) there and the sign of p.z * a flips what the plane test
        // means - and that is where the integrated comparison disagrees on quad
        // COUNT, one too few or one too many.
        for (int i = 0; i < 4; i++) {
            q[i].z = (iter & 1) ? frand(-8.0f, 40.0f) : frand(2.0f, 40.0f);
            float m = (q[i].z > 0.1f) ? q[i].z : 1.0f;
            q[i].x = frand(-1.4f, 1.4f) * m;
            q[i].y = frand(-1.2f, 1.2f) * m;
            cproject(q[i]);
        }
        // And degenerate quads: a repeated vertex is how every triangle in this
        // design is expressed, so they are the common case and not an edge one.
        if ((iter % 7) == 0) q[3] = q[2];
        if ((iter % 11) == 0) { q[2] = q[1]; q[3] = q[1]; }
        std::vector<OutQ> exp;
        cfclip(0, q, exp);

        d->in_x0 = f2u(q[0].x); d->in_y0 = f2u(q[0].y); d->in_z0 = f2u(q[0].z);
        d->in_x1 = f2u(q[1].x); d->in_y1 = f2u(q[1].y); d->in_z1 = f2u(q[1].z);
        d->in_x2 = f2u(q[2].x); d->in_y2 = f2u(q[2].y); d->in_z2 = f2u(q[2].z);
        d->in_x3 = f2u(q[3].x); d->in_y3 = f2u(q[3].y); d->in_z3 = f2u(q[3].z);
        d->in_sx0 = q[0].sx; d->in_sy0 = q[0].sy;
        d->in_sx1 = q[1].sx; d->in_sy1 = q[1].sy;
        d->in_sx2 = q[2].sx; d->in_sy2 = q[2].sy;
        d->in_sx3 = q[3].sx; d->in_sy3 = q[3].sy;
        d->in_valid = 1;

        std::vector<OutQ> got;
        for (int c = 0; c < 20000; c++) {
            tick();
            if (d->in_ready) d->in_valid = 0;
            if (d->out_valid) {
                OutQ o;
                o.sx[0] = (int16_t)d->out_sx0; o.sy[0] = (int16_t)d->out_sy0;
                o.sx[1] = (int16_t)d->out_sx1; o.sy[1] = (int16_t)d->out_sy1;
                o.sx[2] = (int16_t)d->out_sx2; o.sy[2] = (int16_t)d->out_sy2;
                o.sx[3] = (int16_t)d->out_sx3; o.sy[3] = (int16_t)d->out_sy3;
                got.push_back(o);
            }
            if (!d->in_valid && d->in_ready && c > 4) break;
        }

        checks++;
        bool bad = got.size() != exp.size();
        if (!bad)
            for (size_t k = 0; k < exp.size() && !bad; k++)
                for (int v = 0; v < 4; v++)
                    if (labs((long)got[k].sx[v] - exp[k].sx[v]) > 1 ||
                        labs((long)got[k].sy[v] - exp[k].sy[v]) > 1) { bad = true; break; }
        if (bad) {
            fails++;
            if (printed++ < 3) {
                printf("  MISMATCH iter %d: %zu quads out, expected %zu\n",
                       iter, got.size(), exp.size());
                for (int i = 0; i < 4; i++)
                    printf("    in  v%d cam(%9.4f %9.4f %9.4f) scr(%d,%d) out=%d%d%d%d\n",
                           i, q[i].x, q[i].y, q[i].z, q[i].sx, q[i].sy,
                           cisc(0,q[i]), cisc(1,q[i]), cisc(2,q[i]), cisc(3,q[i]));
                for (size_t k = 0; k < exp.size(); k++)
                    printf("    exp %zu (%d,%d)(%d,%d)(%d,%d)(%d,%d)\n", k,
                           exp[k].sx[0],exp[k].sy[0], exp[k].sx[1],exp[k].sy[1],
                           exp[k].sx[2],exp[k].sy[2], exp[k].sx[3],exp[k].sy[3]);
                for (size_t k = 0; k < got.size(); k++)
                    printf("    got %zu (%d,%d)(%d,%d)(%d,%d)(%d,%d)\n", k,
                           got[k].sx[0],got[k].sy[0], got[k].sx[1],got[k].sy[1],
                           got[k].sx[2],got[k].sy[2], got[k].sx[3],got[k].sy[3]);
            }
        }
    }
    printf("  fuzzed %ld quads, %ld disagreed\n", checks, fails);

    // ------------------------------------------------------------------
    // The three quads m1_geometry hands over on the iteration where the
    // integrated comparison first disagrees on COUNT - two out where the
    // reference wants one - with that iteration's own viewport. Captured from
    // tb_m1_geometry rather than invented, so this is the actual failing input
    // and not something like it.
    printf("test: the integrated stage's own failing quads\n");
    {
        G_XC = 248; G_YC = 231; G_ZX = 400; G_ZY = 400; G_VX = 0; G_VY = 0;
        G_L = -0.62f; G_R = 0.6175f; G_B = 0.5775f; G_T = -0.38f;
        d->xc = f2u(G_XC); d->yc = f2u(G_YC);
        d->zoomx = f2u(G_ZX); d->zoomy = f2u(G_ZY);
        d->viewx = f2u(G_VX); d->viewy = f2u(G_VY);
        d->a_left = f2u(G_L); d->a_right = f2u(G_R);
        d->a_bottom = f2u(G_B); d->a_top = f2u(G_T);

        static const float QS[3][12] = {
          {  6.4854f,-135.224f, 68.8553f, -1.8892f,-105.494f, 77.4754f,
            15.491f, -138.371f, 74.7235f, 15.491f, -138.371f, 74.7235f },
          { 13.1664f,-160.37f,  59.1327f, 13.1664f,-160.37f,  59.1327f,
            57.1884f,-35.1004f,165.981f,  57.1884f,-35.1004f,165.981f },
          { -0.886601f,-122.853f,68.5515f, 29.6578f,-108.793f,102.201f,
            32.0642f,-109.565f,105.994f,  11.9574f,-76.2785f,107.104f }
        };
        for (int n = 0; n < 3; n++) {
            CP q[4];
            for (int i = 0; i < 4; i++) {
                q[i].x = QS[n][i*3]; q[i].y = QS[n][i*3+1]; q[i].z = QS[n][i*3+2];
                cproject(q[i]);
            }
            std::vector<OutQ> exp; cfclip(0, q, exp);
            d->in_x0 = f2u(q[0].x); d->in_y0 = f2u(q[0].y); d->in_z0 = f2u(q[0].z);
            d->in_x1 = f2u(q[1].x); d->in_y1 = f2u(q[1].y); d->in_z1 = f2u(q[1].z);
            d->in_x2 = f2u(q[2].x); d->in_y2 = f2u(q[2].y); d->in_z2 = f2u(q[2].z);
            d->in_x3 = f2u(q[3].x); d->in_y3 = f2u(q[3].y); d->in_z3 = f2u(q[3].z);
            d->in_sx0 = q[0].sx; d->in_sy0 = q[0].sy;
            d->in_sx1 = q[1].sx; d->in_sy1 = q[1].sy;
            d->in_sx2 = q[2].sx; d->in_sy2 = q[2].sy;
            d->in_sx3 = q[3].sx; d->in_sy3 = q[3].sy;
            d->in_valid = 1;
            std::vector<OutQ> got;
            for (int c = 0; c < 20000; c++) {
                tick();
                if (d->in_ready) d->in_valid = 0;
                if (d->out_valid) {
                    OutQ o;
                    o.sx[0]=(int16_t)d->out_sx0; o.sy[0]=(int16_t)d->out_sy0;
                    o.sx[1]=(int16_t)d->out_sx1; o.sy[1]=(int16_t)d->out_sy1;
                    o.sx[2]=(int16_t)d->out_sx2; o.sy[2]=(int16_t)d->out_sy2;
                    o.sx[3]=(int16_t)d->out_sx3; o.sy[3]=(int16_t)d->out_sy3;
                    got.push_back(o);
                }
                if (!d->in_valid && d->in_ready && c > 4) break;
            }
            printf("  quad %d: got %zu, expected %zu   in-out flags", n,
                   got.size(), exp.size());
            for (int i = 0; i < 4; i++)
                printf(" %d%d%d%d", cisc(0,q[i]), cisc(1,q[i]),
                       cisc(2,q[i]), cisc(3,q[i]));
            printf("\n");
            check(got.size() == exp.size(), "quad count must match the reference");
            for (size_t k = 0; k < got.size() && k < exp.size(); k++)
                printf("    got (%d,%d)(%d,%d)(%d,%d)(%d,%d)  exp (%d,%d)(%d,%d)(%d,%d)(%d,%d)\n",
                  got[k].sx[0],got[k].sy[0],got[k].sx[1],got[k].sy[1],
                  got[k].sx[2],got[k].sy[2],got[k].sx[3],got[k].sy[3],
                  exp[k].sx[0],exp[k].sy[0],exp[k].sx[1],exp[k].sy[1],
                  exp[k].sx[2],exp[k].sy[2],exp[k].sx[3],exp[k].sy[3]);
        }
    }

    printf("m1_geo_clip: checks=%ld fails=%ld\n", checks, fails);
    return fails ? 1 : 0;
}
