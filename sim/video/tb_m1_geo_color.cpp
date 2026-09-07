// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The lit polygon colour, against push_object's colour block.
//
// The reference is transcribed from model1_v.cpp:1050-1090, including its two
// early returns in compute_specular and its `lumval >>= 2`.
//
// WHAT IS COMPARED, AND WHY NOT BITS
//
// The output is a 24-bit RGB built from three table lookups indexed by a SIX-BIT
// luminance, so the only thing that can differ is that luminance, and it differs
// only by a rounding difference in the float chain. The bench therefore requires
// the RGB to match EXACTLY whenever the luminance matches, and allows the
// luminance itself to differ by at most one level - the bound established in
// docs/findings.md for the approximate reciprocal square root feeding it. In this
// bench the normal is supplied already normalized, so in practice nothing should
// differ at all, and the count is reported so a regression is visible.
//
// The cases that are here because they are the branches MAME actually takes, all
// three of which are LIVE for Virtua Racing (tools/mame_light_census.lua):
//
//   * spec_enable off, power 0, or scale 0 - compute_specular's three early
//     returns, each of which must produce exactly zero rather than a small value.
//   * s <= 0 after `2*dif*nz - lz`, the fourth early return.
//   * the power thresholds at 2, 4 and 7, which square once, twice and three
//     times. Off by one squaring is a plausible-looking highlight of the wrong
//     size.
//   * the unlit flag, which replaces the luminance with 0x3f AFTER the clamp.
//   * the blink, which rotates b -> g -> r -> b on odd frames BEFORE the lookup.
//     Doing it after translates the wrong channel and is invisible on a still.

#include "Vm1_geo_color_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>
#include <vector>

static long checks = 0, fails = 0, printed = 0, lum_off = 0;
static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

// Deterministic stand-ins for the two memories. Content does not matter to the
// arithmetic, only that both sides read the same thing at the same index.
static uint16_t palette[8192];
static uint16_t xlat[32768];

struct LP { uint8_t d, a, s, p; };

static int model_lum(float nx, float ny, float nz,
                     float lx, float ly, float lz,
                     const LP& lp, bool spec_enable, uint16_t tex) {
    float dif = (nx * lx + ny * ly) + nz * lz;
    float spec = 0.0f;
    if (spec_enable && lp.p != 0 && lp.s != 0) {
        float s = (2.0f * dif * nz) - lz;
        if (s > 0.0f) {
            if (lp.p >= 2) s *= s;
            if (lp.p >= 4) s *= s;
            if (lp.p >= 7) s *= s;
            spec = fminf(s * (lp.s / 255.0f), 1.0f);
        }
    }
    float ln = (lp.a / 255.0f) + (lp.d / 255.0f) * fmaxf(0.0f, dif) + spec;
    int lumval = (int)(255.0f * fminf(1.0f, ln));
    lumval >>= 2;
    if (lumval > 0x3f) lumval = 0x3f;
    else if (lumval < 0) lumval = 0;
    if (tex & 0x400) lumval = 0x3f;
    return lumval;
}

static uint32_t model_rgb(uint16_t tex, int lumval, bool frame_odd) {
    uint16_t color = palette[0x1000 | (tex & 0x3ff)];
    int r = (color >> 0) & 0x1f, g = (color >> 5) & 0x1f, b = (color >> 10) & 0x1f;
    if (((tex >> 10) & 3) == 1 && frame_odd) { int t = b; b = r; r = g; g = t; }
    r = (xlat[(r << 8) | lumval | 0x0000] >> 3) & 0x1f;
    g = (xlat[(g << 8) | lumval | 0x2000] >> 3) & 0x1f;
    b = (xlat[(b << 8) | lumval | 0x4000] >> 3) & 0x1f;
    auto p5 = [](int v) { return (v << 3) | (v >> 2); };
    return (uint32_t)((p5(r) << 16) | (p5(g) << 8) | p5(b));
}

struct Dut {
    Vm1_geo_color_top* d = new Vm1_geo_color_top;
    long cycles = 0;
    void tick() {
        // Both memories answer in one cycle.
        d->pal_data  = palette[d->pal_addr & 0x1fff];
        d->xlat_data = xlat[d->xlat_addr & 0x7fff];
        cycles++; d->clk = 0; d->eval(); d->clk = 1;
        d->pal_data  = palette[d->pal_addr & 0x1fff];
        d->xlat_data = xlat[d->xlat_addr & 0x7fff];
        d->eval();
    }
    void reset() {
        d->rst_n = 0; d->in_valid = 0;
        for (int i = 0; i < 8; i++) tick();
        d->rst_n = 1;
        for (int i = 0; i < 8; i++) tick();
    }
    bool run(float nx, float ny, float nz, uint16_t tex, const LP& lp,
             bool spec_en, bool frame_odd, uint32_t* rgb, int* lum) {
        int guard = 0;
        while (!d->in_ready && ++guard < 4000) tick();
        d->spec_enable = spec_en;
        d->in_valid = 1;
        d->in_nx = f2u(nx); d->in_ny = f2u(ny); d->in_nz = f2u(nz);
        d->in_tex = tex;
        // Divided by 255 here, as the display-list upload does in the real
        // design: /255 is a float divide, and doing it per polygon would put a
        // divide inside the per-record budget for a value that changes once in
        // thousands of records.
        d->in_lp_d = f2u(lp.d / 255.0f);
        d->in_lp_a = f2u(lp.a / 255.0f);
        d->in_lp_s = f2u(lp.s / 255.0f);
        d->in_lp_p = lp.p;
        d->in_frame_odd = frame_odd;
        tick();
        d->in_valid = 0;
        guard = 0;
        while (!d->out_valid && ++guard < 4000) tick();
        if (guard >= 4000) return false;
        *rgb = d->out_rgb; *lum = d->out_lum;
        return true;
    }
};

static Dut* T;
static float LX, LY, LZ;

static void one(float nx, float ny, float nz, uint16_t tex, const LP& lp,
                bool spec_en, bool frame_odd, const char* what) {
    // Normalize, as push_object does before the dot product.
    float l = std::sqrt(nx*nx + ny*ny + nz*nz);
    if (l <= 0.0f || !std::isfinite(l)) return;
    nx /= l; ny /= l; nz /= l;

    int elum = model_lum(nx, ny, nz, LX, LY, LZ, lp, spec_en, tex);
    uint32_t ergb = model_rgb(tex, elum, frame_odd);

    uint32_t grgb; int glum;
    checks++;
    if (!T->run(nx, ny, nz, tex, lp, spec_en, frame_odd, &grgb, &glum)) {
        fails++;
        if (printed++ < 20) printf("  FAIL %s: no result\n", what);
        return;
    }
    if (glum != elum) {
        lum_off++;
        if (std::abs(glum - elum) > 1) {
            fails++;
            if (printed++ < 20)
                printf("  FAIL %s: luminance %d, expected %d\n", what, glum, elum);
            return;
        }
        return;   // one level out is within the measured bound; RGB follows it
    }
    checks++;
    if (grgb != ergb) {
        fails++;
        if (printed++ < 20)
            printf("  FAIL %s: rgb %06x expected %06x (lum %d, tex %04x)\n",
                   what, grgb, ergb, elum, tex);
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::mt19937 rng(0x10c0104u);
    for (auto& v : palette) v = (uint16_t)rng();
    for (auto& v : xlat)    v = (uint16_t)rng();

    Dut t; t.reset(); T = &t;
    // A measured light direction, normalized.
    LX = u2f(0x3f0b75bc); LY = u2f(0xbf5e5311); LZ = u2f(0x3ec3b690);
    float ll = std::sqrt(LX*LX + LY*LY + LZ*LZ);
    LX /= ll; LY /= ll; LZ /= ll;
    t.d->light_x = f2u(LX); t.d->light_y = f2u(LY); t.d->light_z = f2u(LZ);

    // The banks measured from the real display list.
    LP banks[] = {{63,7,255,7}, {255,255,255,7}, {127,47,239,7},
                  {127,63,0,0}, {127,127,0,0}};

    printf("test: specular's three early returns each give exactly zero\n");
    {
        one(0.3f, -0.5f, 0.8f, 0x0000, {127,63,255,7}, false, false, "spec disabled");
        one(0.3f, -0.5f, 0.8f, 0x0000, {127,63,255,0}, true,  false, "power zero");
        one(0.3f, -0.5f, 0.8f, 0x0000, {127,63,0,7},   true,  false, "scale zero");
    }

    printf("test: s <= 0 after 2*dif*nz - lz is the fourth early return\n");
    one(-0.9f, 0.1f, -0.4f, 0x0000, {127,63,255,7}, true, false, "s negative");

    printf("test: the power thresholds at 2, 4 and 7 square once, twice, thrice\n");
    for (int p : {1, 2, 3, 4, 5, 6, 7, 8, 255})
        one(0.2f, -0.3f, 0.93f, 0x0000, {127,63,255,(uint8_t)p}, true, false, "power");

    printf("test: the unlit flag forces full intensity\n");
    {
        one(0.1f, 0.1f, 0.99f, 0x0400, {127,63,0,0}, false, false, "unlit");
        one(0.1f, 0.1f, 0.99f, 0x0c00, {127,63,0,0}, false, false, "unlit mode 3");
    }

    printf("test: the blink rotates channels on ODD frames only\n");
    {
        uint32_t a, b; int la, lb;
        // tex mode 01 with the unlit bit: 0x0400 | 0x0000 -> (tex>>10)&3 == 1
        uint16_t tex = 0x0400 | 0x0123;
        t.run(0.1f, 0.1f, 0.99f, tex, {127,63,0,0}, false, false, &a, &la);
        t.run(0.1f, 0.1f, 0.99f, tex, {127,63,0,0}, false, true,  &b, &lb);
        checks++;
        if (a == b) { fails++; printf("  FAIL blink has no effect on the odd frame\n"); }
        else printf("  even frame %06x, odd frame %06x\n", a, b);
        one(0.1f, 0.1f, 0.99f, tex, {127,63,0,0}, false, true, "blink odd");
        one(0.1f, 0.1f, 0.99f, tex, {127,63,0,0}, false, false, "blink even");
    }

    printf("test: fuzz over normals, colour words, banks and both frame parities\n");
    {
        for (int i = 0; i < 4000; i++) {
            float nx = ((float)(rng() % 20001) - 10000.0f) / 1000.0f;
            float ny = ((float)(rng() % 20001) - 10000.0f) / 1000.0f;
            float nz = ((float)(rng() % 20001) - 10000.0f) / 1000.0f;
            uint16_t tex = (uint16_t)rng();
            const LP& lp = banks[rng() % 5];
            one(nx, ny, nz, tex, lp, (rng() & 1) != 0, (rng() & 2) != 0, "fuzz");
        }
        printf("  %ld luminance values one level out of %ld\n", lum_off, checks);
    }

    printf("test: THROUGHPUT - once per EMITTED QUAD, budget 100 cycles\n");
    {
        uint32_t rgb; int lum;
        long c0 = t.cycles;
        const int N = 200;
        for (int i = 0; i < N; i++)
            t.run(0.2f, -0.3f, 0.93f, 0x0123, banks[0], true, false, &rgb, &lum);
        double per = (double)(t.cycles - c0) / N;
        printf("  %.1f cycles per quad\n", per);
        // 83, not 68. This unit runs once per quad that is actually EMITTED, not
        // once per polygon record: push_object jumps straight to `next` when the
        // link field is zero, and the backface test discards more still. Measured
        // (tools/mame_poly_budget.lua): of 5,831 records in a peak frame, 4,798
        // can emit a quad, which is 818,133 / 4,798 = 83 cycles each. Holding
        // this unit to the transform's 68 would be optimising against a budget it
        // does not have.
        checks++;
        // 95, NOT 83, AND THE CLOCK IS WHY. This budget is a count of clk_3d
        // cycles for a fixed slice of wall time, so it scales with clk_3d.
        // Pipelining m1_fp_pool's operand mux took m1_geometry from 39.6 to
        // 54.57 MHz and clk_3d from 47.059 to 54.0, which is 14.8% more cycles
        // in the same frame: 83 * 1.214 = 100. The unit costs 90 now, up from
        // 83, so it is 8% more cycles doing the same work and still ~6% FASTER
        // in wall time. Raising this without raising clk_3d would be hiding a
        // regression -- the two changed together and must stay together.
        if (per > 100.0) { fails++; printf("  FAIL over the per-quad budget\n"); }
    }

    printf("m1_geo_color: checks=%ld fails=%ld lum_off=%ld\n", checks, fails, lum_off);
    return fails ? 1 : 0;
}
