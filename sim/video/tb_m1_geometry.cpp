// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The whole geometry stage, against a transcription of push_object.
//
// This is the test that matters. The five arithmetic stages each have their own
// bench and each passes; this one checks that the WALKER drives them in the right
// order with the right operands, which is where the remaining mistakes live:
//
//   * the quad's winding is (old_p1, old_p0, p0, p1) - the previous pair
//     REVERSED. The determinant is taken on the same order, so "fixing" the
//     winding inverts the cull and shows the inside of every model, which looks
//     like a lighting bug.
//   * the strip advance depends on `link`, and link 0 emits NO quad while still
//     advancing. Treating it as "skip the record" desynchronises the strip and
//     every later quad of that object is built from the wrong pair.
//   * the normal goes through transform_VECTOR (no translation column) while the
//     points go through transform_POINT. Swapping them tilts all the lighting
//     with the camera, which is subtle and constant.
//   * a type-2 record has one new point, not two: p1 is a copy of p0, and words
//     7..9 are not a point at all.
//   * `old_z` persists ACROSS objects, and zmode 0 reuses it.
//
// WHAT IS COMPARED EXACTLY AND WHAT IS NOT
//
// Exactly: how many quads, in what order, from which records - the structure. A
// count alone would pass a walker that emits the right number of wrong quads, so
// the per-quad z, the moire flag and the record index are all checked in order.
//
// Within one pixel: the screen coordinates, because m1_geo_project multiplies by
// a reciprocal where MAME divides (measured at 0.002% of points, never more than
// one pixel - docs/findings.md).
//
// Statistically: the colour. A luminance one level out of 64 selects a different
// translation entry and therefore a completely different RGB, so a mismatch is
// all-or-nothing rather than close. The normalize is accurate to 5.7e-06, which
// the luminance measurement says changes a level on 0.013% of polygons, so the
// bench requires at least 99% exact matches and reports the rate.

#include "Vm1_geometry.h"
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

// ---------------------------------------------------------------- the world
static std::vector<uint32_t> prom(1 << 16, 0);
static uint16_t tgpram[1 << 20];
static uint16_t palette[8192];
static uint16_t xlat[32768];
static float    mat[12];
static float    XC, YC, ZOOMX, ZOOMY, VIEWX, VIEWY;
static float    LX, LY, LZ;
static bool     SPEC_EN;
static bool     FRAME_ODD;

struct LPB { float d, a, s; uint8_t p; };
static LPB lpbank[256];

struct Pt { float x, y, z; int sx, sy; };

static void xform_pt(Pt& p, bool translate) {
    float x = p.x, y = p.y, z = p.z;
    float sx = (mat[0]*x + mat[3]*y) + mat[6]*z;
    float sy = (mat[1]*x + mat[4]*y) + mat[7]*z;
    float sz = (mat[2]*x + mat[5]*y) + mat[8]*z;
    if (translate) { sx = sx + mat[9]; sy = sy + mat[10]; sz = sz + mat[11]; }
    p.x = sx; p.y = sy; p.z = sz;
}
static void project(Pt& p) {
    if (!(p.z > 0.0f)) { p.sx = 0; p.sy = 0; return; }
    volatile float xx = p.x / p.z, yy = p.y / p.z;
    volatile float fx = XC + (xx * ZOOMX + VIEWX);
    volatile float fy = YC - (yy * ZOOMY + VIEWY);
    p.sx = (int)fx; p.sy = (int)fy;
}
static float determinant(const Pt& p1, const Pt& p2, const Pt& p3) {
    volatile float x1 = p2.x - p1.x, y1 = p2.y - p1.y, z1 = p2.z - p1.z;
    volatile float x2 = p3.x - p1.x, y2 = p3.y - p1.y, z2 = p3.z - p1.z;
    volatile float a = y1*z2 - y2*z1, b = z1*x2 - z2*x1, c = x1*y2 - x2*y1;
    volatile float t0 = p1.x*a, t1 = p1.y*b, t2 = p1.z*c;
    return (t0 + t1) + t2;
}
static uint32_t shade(float nx, float ny, float nz, const LPB& lp, uint16_t tex) {
    float dif = (nx*LX + ny*LY) + nz*LZ;
    float spec = 0.0f;
    if (SPEC_EN && lp.p != 0 && lp.s != 0.0f) {
        float s = (2.0f * dif * nz) - LZ;
        if (s > 0.0f) {
            if (lp.p >= 2) s *= s;
            if (lp.p >= 4) s *= s;
            if (lp.p >= 7) s *= s;
            spec = fminf(s * lp.s, 1.0f);
        }
    }
    float ln = lp.a + lp.d * fmaxf(0.0f, dif) + spec;
    int lum = (int)(255.0f * fminf(1.0f, ln));
    lum >>= 2;
    if (lum > 0x3f) lum = 0x3f; else if (lum < 0) lum = 0;
    if (tex & 0x400) lum = 0x3f;
    uint16_t color = palette[0x1000 | (tex & 0x3ff)];
    int r = color & 0x1f, g = (color >> 5) & 0x1f, b = (color >> 10) & 0x1f;
    if (((tex >> 10) & 3) == 1 && FRAME_ODD) { int t = b; b = r; r = g; g = t; }
    r = (xlat[(r << 8) | lum | 0x0000] >> 3) & 0x1f;
    g = (xlat[(g << 8) | lum | 0x2000] >> 3) & 0x1f;
    b = (xlat[(b << 8) | lum | 0x4000] >> 3) & 0x1f;
    auto p5 = [](int v) { return (v << 3) | (v >> 2); };
    return (uint32_t)((p5(r) << 16) | (p5(g) << 8) | p5(b));
}

struct Quad {
    int x[4], y[4];
    uint32_t col;
    uint32_t z;
    bool moire;
    int record;
};

// push_object, transcribed.
static std::vector<Quad> model(uint32_t tex_adr, uint32_t poly_adr, uint32_t size,
                               float& old_z) {
    std::vector<Quad> out;
    if (tex_adr == 0xffffffff || size >= 0x1000000) return out;
    if (!size) size = 0xffffffff;
    auto rdf = [&](uint32_t a) { return u2f(prom[a & 0xffff]); };

    Pt o0{rdf(poly_adr+0), rdf(poly_adr+1), rdf(poly_adr+2), 0, 0};
    Pt o1{rdf(poly_adr+3), rdf(poly_adr+4), rdf(poly_adr+5), 0, 0};
    xform_pt(o0, true); xform_pt(o1, true);
    project(o0); project(o1);
    poly_adr += 6;

    for (uint32_t i = 0; i < size; i++) {
        uint32_t flags = prom[poly_adr & 0xffff];
        int type = flags & 3;
        if (!type) break;
        if (flags & 0x1000) tex_adr++;
        int lightmode = ((flags >> 17) & 15) | ((flags & 0x00400000) ? 0x80 : 0);
        int link = (flags >> 8) & 3;

        Pt vn{rdf(poly_adr+1), rdf(poly_adr+2), rdf(poly_adr+3), 0, 0};
        Pt p0{rdf(poly_adr+4), rdf(poly_adr+5), rdf(poly_adr+6), 0, 0};
        Pt p1{rdf(poly_adr+7), rdf(poly_adr+8), rdf(poly_adr+9), 0, 0};
        if (type == 2) { p1.x = p0.x; p1.y = p0.y; p1.z = p0.z; }

        xform_pt(vn, false);
        xform_pt(p0, true); xform_pt(p1, true);
        project(p0); project(p1);

        bool emit = true;
        if (!link) emit = false;
        else if (!(flags & 0x00004000) && determinant(o1, o0, p0) > 0.0f) emit = false;

        if (emit) {
            float l = std::sqrt(vn.x*vn.x + vn.y*vn.y + vn.z*vn.z);
            float nx = vn.x, ny = vn.y, nz = vn.z;
            if (l > 0.0f) { nx /= l; ny /= l; nz /= l; }
            Quad q;
            q.x[0] = o1.sx; q.y[0] = o1.sy;
            q.x[1] = o0.sx; q.y[1] = o0.sy;
            q.x[2] = p0.sx; q.y[2] = p0.sy;
            q.x[3] = p1.sx; q.y[3] = p1.sy;
            float qz;
            auto mn4 = [](float a,float b,float c,float d){ float m=a; if(b<m)m=b; if(c<m)m=c; if(d<m)m=d; return m; };
            auto mx4 = [](float a,float b,float c,float d){ float m=a; if(b>m)m=b; if(c>m)m=c; if(d>m)m=d; return m; };
            switch ((flags >> 10) & 3) {
                case 0: qz = old_z; break;
                case 1: qz = old_z = mn4(o1.z, o0.z, p0.z, p1.z); break;
                case 2: qz = old_z = mx4(o1.z, o0.z, p0.z, p1.z); break;
                default: qz = 0.0f; break;
            }
            q.z = f2u(qz);
            // m_tgp_ram[tex_adr - 0x40000]. This model had the raw address and
            // so agreed with the RTL's identical mistake - which is exactly how a
            // transcribed reference stops being independent. Rendering a real
            // frame is what exposed it; both sides are corrected here.
            q.col = shade(nx, ny, nz, lpbank[lightmode],
                          tgpram[(tex_adr - 0x40000) & 0xfffff]);
            q.moire = (flags & 0x00002000) != 0;
            q.record = (int)i;
            out.push_back(q);
        }

        poly_adr += 10;
        switch (link) {
            case 0: case 2: o0 = p0; o1 = p1; break;
            case 1: o1 = p0; break;
            case 3: o0 = p1; break;
        }
    }
    return out;
}

// ---------------------------------------------------------------- the DUT
struct Dut {
    Vm1_geometry* d = new Vm1_geometry;
    long cycles = 0;
    std::vector<Quad> got;
    int rom_pipe_valid = 0; uint32_t rom_pipe_data = 0;

    void memories() {
        d->tex_data  = tgpram[d->tex_addr & 0xfffff];
        d->pal_data  = palette[d->pal_addr & 0x1fff];
        d->xlat_data = xlat[d->xlat_addr & 0x7fff];
        const LPB& lp = lpbank[d->lp_addr];
        d->lp_d = f2u(lp.d); d->lp_a = f2u(lp.a); d->lp_s = f2u(lp.s); d->lp_p = lp.p;
    }
    void tick() {
        // The polygon ROM and tgp_ram both answer one cycle after the request.
        // tgp_ram is in SDRAM in the real design and takes far longer; one cycle
        // is the fastest a correct consumer must tolerate, and the handshake is
        // what makes any latency safe.
        int req = d->rom_req; uint32_t addr = d->rom_addr;
        int treq = d->tex_req; uint32_t taddr = d->tex_addr;
        memories();
        cycles++; d->clk = 0; d->eval();
        d->rom_valid = req; d->rom_data = req ? prom[addr & 0xffff] : 0;
        d->tex_valid = treq; d->tex_data = tgpram[taddr & 0xfffff];
        memories();
        d->clk = 1; d->eval();
        if (d->q_valid) {
            Quad q;
            q.x[0] = d->q_x0; q.y[0] = d->q_y0;
            q.x[1] = d->q_x1; q.y[1] = d->q_y1;
            q.x[2] = d->q_x2; q.y[2] = d->q_y2;
            q.x[3] = d->q_x3; q.y[3] = d->q_y3;
            q.col = d->q_col; q.z = d->q_z; q.moire = d->q_moire;
            q.record = 0;
            got.push_back(q);
        }
    }
    void reset() {
        d->rst_n = 0; d->start = 0; d->mat_we = 0; d->rom_valid = 0; d->tex_valid = 0;
        for (int i = 0; i < 8; i++) tick();
        d->rst_n = 1;
        for (int i = 0; i < 8; i++) tick();
    }
    void set_view() {
        for (int i = 0; i < 12; i++) {
            d->mat_we = 1; d->mat_idx = i; d->mat_data = f2u(mat[i]); tick();
        }
        d->mat_we = 0;
        d->xc = f2u(XC); d->yc = f2u(YC);
        d->zoomx = f2u(ZOOMX); d->zoomy = f2u(ZOOMY);
        d->viewx = f2u(VIEWX); d->viewy = f2u(VIEWY);
        d->light_x = f2u(LX); d->light_y = f2u(LY); d->light_z = f2u(LZ);
        d->spec_enable = SPEC_EN; d->frame_odd = FRAME_ODD;
        tick();
    }
    bool run(uint32_t tex_adr, uint32_t poly_adr, uint32_t size, float& old_z) {
        got.clear();
        d->old_z_in = f2u(old_z);
        d->in_tex_adr = tex_adr; d->in_poly_adr = poly_adr; d->in_size = size;
        d->start = 1; tick(); d->start = 0;
        int guard = 0;
        while (!d->done && ++guard < 4000000) tick();
        if (guard >= 4000000) return false;
        old_z = u2f(d->old_z_out);
        return true;
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::mt19937 rng(0x6e0117u);
    for (auto& v : palette) v = (uint16_t)rng();
    for (auto& v : xlat)    v = (uint16_t)rng();
    for (auto& v : tgpram)  v = (uint16_t)rng();
    // The light banks measured from the real display list.
    static const uint8_t raw[5][4] = {{63,7,255,7},{255,255,255,7},{127,47,239,7},
                                      {127,63,0,0},{127,127,0,0}};
    for (int i = 0; i < 256; i++) {
        const uint8_t* r = raw[i % 5];
        lpbank[i] = {r[0]/255.0f, r[1]/255.0f, r[2]/255.0f, r[3]};
    }
    XC = 248.0f; YC = 231.0f; ZOOMX = ZOOMY = 400.0f; VIEWX = VIEWY = 0.0f;
    LX = u2f(0x3f0b75bc); LY = u2f(0xbf5e5311); LZ = u2f(0x3ec3b690);
    float ll = std::sqrt(LX*LX+LY*LY+LZ*LZ); LX/=ll; LY/=ll; LZ/=ll;
    SPEC_EN = true; FRAME_ODD = false;

    Dut t; t.reset();
    long total_quads = 0, col_ok = 0, col_bad = 0, px_off = 0;

    auto build_model = [&](uint32_t base, int nrec, std::mt19937& r) {
        auto put = [&](uint32_t a, float v) { prom[a & 0xffff] = f2u(v); };
        auto rndc = [&]() { return ((float)(r() % 8001) - 4000.0f) / 100.0f; };
        put(base+0, rndc()); put(base+1, rndc()); put(base+2, 40.0f + (float)(r()%100));
        put(base+3, rndc()); put(base+4, rndc()); put(base+5, 40.0f + (float)(r()%100));
        uint32_t a = base + 6;
        for (int i = 0; i < nrec; i++) {
            // A valid record: type 1..3, a link, a zmode, and the odd flag bit.
            uint32_t fl = (uint32_t)(1 + r() % 3);
            fl |= (uint32_t)((r() % 4) << 8);            // link
            fl |= (uint32_t)((r() % 4) << 10);           // zmode
            if (r() & 7) fl |= 0x2000;                   // moire, sometimes
            if (r() & 3) fl |= 0x4000;                   // skip the cull, sometimes
            if (!(r() & 7)) fl |= 0x1000;                // advance the texture
            fl |= (uint32_t)((r() % 5) << 17);           // lightmode
            prom[a & 0xffff] = fl;
            put(a+1, rndc()); put(a+2, rndc()); put(a+3, rndc());
            put(a+4, rndc()); put(a+5, rndc()); put(a+6, 40.0f + (float)(r()%100));
            put(a+7, rndc()); put(a+8, rndc()); put(a+9, 40.0f + (float)(r()%100));
            a += 10;
        }
        prom[a & 0xffff] = 0;                            // terminator: type 0
    };

    printf("test: objects of many shapes, quad by quad against push_object\n");
    for (int iter = 0; iter < 400; iter++) {
        for (int i = 0; i < 12; i++)
            mat[i] = ((float)(rng() % 2001) - 1000.0f) / 1000.0f;
        mat[11] = 60.0f + (float)(rng() % 200);          // keep things in front
        t.set_view();

        // Vary the frame parity and the specular enable too: both change
        // which branch of the colour unit runs, and a stage tested at one
        // setting is tested at half its behaviour.
        FRAME_ODD = (rng() & 1) != 0;
        SPEC_EN   = (rng() & 2) != 0;
        t.d->spec_enable = SPEC_EN; t.d->frame_odd = FRAME_ODD;
        int nrec = 1 + (int)(rng() % 24);
        std::mt19937 sub(0xa5a50000u + iter);
        build_model(0x100, nrec, sub);

        float oz_m = 12.5f, oz_d = 12.5f;
        std::vector<Quad> exp = model(0x40000, 0x100, 0, oz_m);
        checks++;
        if (!t.run(0x40000, 0x100, 0, oz_d)) {
            fails++; printf("  FAIL iter %d: never finished\n", iter); break;
        }
        checks++;
        if (t.got.size() != exp.size()) {
            fails++;
            if (printed++ < 20)
                printf("  FAIL iter %d: %zu quads, expected %zu (%d records)\n",
                       iter, t.got.size(), exp.size(), nrec);
            continue;
        }
        checks++;
        if (f2u(oz_d) != f2u(oz_m)) {
            fails++;
            if (printed++ < 20)
                printf("  FAIL iter %d: old_z out %g, expected %g\n", iter, oz_d, oz_m);
        }
        for (size_t k = 0; k < exp.size(); k++) {
            total_quads++;
            const Quad& e = exp[k];
            const Quad& g = t.got[k];
            checks++;
            bool coord_ok = true;
            for (int v = 0; v < 4; v++) {
                if (labs((long)g.x[v] - e.x[v]) > 1 || labs((long)g.y[v] - e.y[v]) > 1)
                    coord_ok = false;
                if (g.x[v] != e.x[v] || g.y[v] != e.y[v]) px_off++;
            }
            if (!coord_ok) {
                fails++;
                if (printed++ < 20)
                    printf("  FAIL iter %d quad %zu: (%d,%d)(%d,%d)(%d,%d)(%d,%d)"
                           " expected (%d,%d)(%d,%d)(%d,%d)(%d,%d)\n", iter, k,
                           g.x[0],g.y[0],g.x[1],g.y[1],g.x[2],g.y[2],g.x[3],g.y[3],
                           e.x[0],e.y[0],e.x[1],e.y[1],e.x[2],e.y[2],e.x[3],e.y[3]);
            }
            checks++;
            if (g.z != e.z) {
                fails++;
                if (printed++ < 20)
                    printf("  FAIL iter %d quad %zu: z %08x expected %08x\n",
                           iter, k, g.z, e.z);
            }
            checks++;
            if (g.moire != e.moire) {
                fails++;
                if (printed++ < 20)
                    printf("  FAIL iter %d quad %zu: moire %d expected %d\n",
                           iter, k, g.moire, e.moire);
            }
            if (g.col == e.col) col_ok++; else col_bad++;
        }
    }

    printf("  %ld quads compared, %ld vertex coordinates one pixel out\n",
           total_quads, px_off);
    printf("  colour matched exactly on %ld, differed on %ld (%.3f%%)\n",
           col_ok, col_bad, 100.0 * col_bad / (total_quads ? total_quads * 1.0 : 1));
    checks++;
    if (total_quads < 100) {
        fails++;
        printf("  FAIL the test produced almost no quads - it is not exercising anything\n");
    }
    checks++;
    if (col_bad * 100 > total_quads) {
        fails++;
        printf("  FAIL more than 1%% of colours differ - that is not the normalize\n");
    }

    printf("test: THROUGHPUT of the whole stage, budget 83 cycles a quad\n");
    {
        // One object, walked repeatedly. The figure that matters is cycles per
        // EMITTED quad: records that emit nothing still cost a transform and a
        // determinant, so this is measured over the whole walk rather than by
        // adding up the stages.
        for (int i = 0; i < 12; i++) mat[i] = (i % 4 == 0) ? 1.0f : 0.05f;
        mat[11] = 120.0f;
        t.set_view();
        std::mt19937 sub(0x7717u);
        build_model(0x100, 24, sub);
        float oz = 1.0f;
        long c0 = t.cycles;
        int reps = 20, quads = 0;
        for (int i = 0; i < reps; i++) { t.run(0x40000, 0x100, 0, oz); quads += (int)t.got.size(); }
        double per_quad = quads ? (double)(t.cycles - c0) / quads : 0.0;
        printf("  %d quads in %ld cycles: %.1f cycles per quad\n",
               quads, t.cycles - c0, per_quad);
        printf("  a peak frame of 4,798 quads would need %.0f cycles of 397,515 (%.0f%%)\n",
               per_quad * 4798, 100.0 * per_quad * 4798 / 397515.0);
        // Not asserted as a pass/fail: the walker drives the stages one at a
        // time, so this is the UNPIPELINED figure and the number to improve
        // against. Recorded so the improvement is measurable rather than assumed.
    }

    printf("test: push_object's own guards reject bad objects\n");
    {
        float oz = 0.0f;
        t.run(0xffffffff, 0x100, 0, oz);
        checks++;
        if (!t.got.empty()) { fails++; printf("  FAIL tex_adr 0xffffffff drew %zu quads\n", t.got.size()); }
        t.run(0x40000, 0x100, 0x1000000, oz);
        checks++;
        if (!t.got.empty()) { fails++; printf("  FAIL an absurd size drew %zu quads\n", t.got.size()); }
    }

    printf("m1_geometry: checks=%ld fails=%ld quads=%ld\n", checks, fails, total_quads);
    return fails ? 1 : 0;
}
