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
#include "Vm1_geometry___024root.h"
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
// THE POLYGON ROM, BIG ENOUGH FOR REAL MODELS.
//
// It was 65,536 words with every access masked to 16 bits, which is fine for
// the synthetic models this bench builds and useless for the real ones: Virtua
// Racing's objects sit at 0x1031c7, 0x12a822 and upwards. Every quad this
// bench has ever checked was a model it wrote itself, so a record shape that
// only occurs in the real data - a link pattern, a type-2 record, a flag
// combination - has never been compared against push_object at all. Ben's board
// draws most models correctly and some, mainly the road, wrong, which is the
// exact shape of that gap.
static const uint32_t PROM_WORDS = 4u << 20;      // 16 MB of 32-bit model words
static std::vector<uint32_t> prom(PROM_WORDS, 0);
static inline uint32_t PA(uint32_t a) { return a & (PROM_WORDS - 1); }
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

// ---------------------------------------------------------------- the clipper
//
// model1_v.cpp fclip_push_quad (:697) and the four clip/isclipped pairs at
// :635-:690, transcribed. Without it this model disagrees with any RTL that
// clips - and the RTL has to clip, because m1_quad_store keeps 16-bit screen
// coordinates and m1_raster_fill works in 16.16, so both require vertices
// inside +/-32768. MAME guarantees that by clipping; unclipped, a road vertex
// at x = 100,000 wraps to the other side of the screen.
// OFF UNTIL THE RTL CLIPS TOO. The module is written and wired and does not
// yet agree; with the model clipping and the RTL not, every quad that crosses a
// plane differs and the suite is red for a reason that is already understood.
// Turning it on is how the next session checks the RTL: set this, wire
// m1_geo_clip back into m1_geometry, and the 5 objects that differ are the
// target.
static const bool CLIP_ON = true;
static float VX1 = 0.0f, VX2 = 495.0f, VY1 = 0.0f, VY2 = 383.0f;
static float A_LEFT, A_RIGHT, A_BOTTOM, A_TOP;

static void set_planes() {
    A_LEFT   = ( VX1 - XC - VIEWX) / ZOOMX;
    A_RIGHT  = ( VX2 - XC - VIEWX) / ZOOMX;
    A_BOTTOM = (-VY1 + YC - VIEWY) / ZOOMY;
    A_TOP    = (-VY2 + YC - VIEWY) / ZOOMY;
}

static bool isc(int level, const Pt& p) {
    switch (level) {
        case 0:  return p.y > (p.z * A_BOTTOM);
        case 1:  return p.y < (p.z * A_TOP);
        case 2:  return p.x < (p.z * A_LEFT);
        default: return p.x > (p.z * A_RIGHT);
    }
}

static void project(Pt& p);
// HOW MUCH OF THIS SUITE ACTUALLY REACHES THE CLIPPER.
//
// The corpus agrees quad-for-quad with the model, and that proves nothing about
// clipping unless quads in it cross a plane. Ben sees the road and the scenery
// vanish from the left of the screen while cars stay - which is precisely the
// symptom m1_geo_clip's own header describes for geometry that is NOT clipped,
// so "the clipper agrees" needs to be qualified by how often it was asked.
//
// CLAUDE.md's rule, learned the expensive way: when a measurement says the
// behaviour is correct, check that the instrument could have seen it fail.
static long clip_edges = 0, clip_calls = 0, clip_split = 0;

static Pt clip_edge(int level, const Pt& p1, const Pt& p2) {
    clip_edges++;
    float a = (level == 0) ? A_BOTTOM : (level == 1) ? A_TOP
            : (level == 2) ? A_LEFT   : A_RIGHT;
    float v1 = (level >= 2) ? p1.x : p1.y;
    float v2 = (level >= 2) ? p2.x : p2.y;
    float t = (p2.z * a - v2) / ((p2.z - p1.z) * a - (v2 - v1));
    Pt r;
    r.x = p1.x * t + p2.x * (1 - t);
    r.y = p1.y * t + p2.y * (1 - t);
    r.z = p1.z * t + p2.z * (1 - t);
    project(r);
    return r;
}

// Emits into `out`, which the caller has primed with the quad's attributes.
static void fclip(int level, const Pt q[4], const Quad& attrs,
                  std::vector<Quad>& out) {
    if (level == 4) {
        Quad e = attrs;
        for (int i = 0; i < 4; i++) { e.x[i] = q[i].sx; e.y[i] = q[i].sy; }
        out.push_back(e);
        return;
    }
    bool is_out[4];
    for (int i = 0; i < 4; i++) is_out[i] = isc(level, q[i]);
    if (!is_out[0] && !is_out[1] && !is_out[2] && !is_out[3]) {
        fclip(level + 1, q, attrs, out); return;
    }
    if (is_out[0] && is_out[1] && is_out[2] && is_out[3]) return;

    int i;
    for (i = 0; i < 4; i++) if (is_out[i] && !is_out[(i - 1) & 3]) break;
    Pt pt[4]; bool o2[4];
    for (int j = 0; j < 4; j++) { pt[j] = q[(i + j) & 3]; o2[j] = is_out[(i + j) & 3]; }

    Pt c[4];
    auto push = [&](const Pt& a, const Pt& b, const Pt& cc, const Pt& d) {
        Pt n[4] = { a, b, cc, d };
        fclip(level + 1, n, attrs, out);
    };
    if (o2[1]) {
        if (o2[2]) {                                  // 0,1,2 out: a triangle
            c[0] = clip_edge(level, pt[2], pt[3]);
            c[1] = clip_edge(level, pt[3], pt[0]);
            push(c[0], pt[3], c[1], c[1]);
        } else {                                      // 0,1 out: a quad
            c[0] = clip_edge(level, pt[1], pt[2]);
            c[1] = clip_edge(level, pt[3], pt[0]);
            push(c[0], pt[2], pt[3], c[1]);
        }
    } else {
        if (o2[2]) {                                  // 0,2 out: two triangles
            c[0] = clip_edge(level, pt[0], pt[1]);
            c[1] = clip_edge(level, pt[1], pt[2]);
            push(c[0], pt[1], c[1], c[1]);
            c[2] = clip_edge(level, pt[2], pt[3]);
            c[3] = clip_edge(level, pt[3], pt[0]);
            push(c[2], pt[3], c[3], c[3]);
        } else {                                      // 0 out: a quad and a tri
            c[0] = clip_edge(level, pt[0], pt[1]);
            c[1] = clip_edge(level, pt[3], pt[0]);
            push(c[0], pt[1], pt[2], pt[3]);
            push(pt[3], c[1], c[0], c[0]);
        }
    }
}


// push_object, transcribed.
static std::vector<Quad> model(uint32_t tex_adr, uint32_t poly_adr, uint32_t size,
                               float& old_z) {
    std::vector<Quad> out;
    // The plane ratios follow the viewport and the zoom, so they are derived
    // here rather than cached - set_viewport does the same on every change.
    set_planes();
    if (tex_adr == 0xffffffff || size >= 0x1000000) return out;
    if (!size) size = 0xffffffff;
    auto rdf = [&](uint32_t a) { return u2f(prom[PA(a)]); };

    Pt o0{rdf(poly_adr+0), rdf(poly_adr+1), rdf(poly_adr+2), 0, 0};
    Pt o1{rdf(poly_adr+3), rdf(poly_adr+4), rdf(poly_adr+5), 0, 0};
    xform_pt(o0, true); xform_pt(o1, true);
    project(o0); project(o1);
    poly_adr += 6;

    for (uint32_t i = 0; i < size; i++) {
        uint32_t flags = prom[PA(poly_adr)];
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
            // fclip_push_quad(0, cquad) - the quad goes to the clipper, not
            // straight out, and may become none, one or several.
            if (CLIP_ON) {
                Pt cq[4] = { o1, o0, p0, p1 };
                fclip(0, cq, q, out);
            } else out.push_back(q);
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

// ------------------------------------------------------ where the cycles go
//
// WHY A HISTOGRAM AND NOT A TOTAL. The stage is 566 cycles a quad against 68 of
// arithmetic, and "the geometry is slow" is not something to act on: the fix for
// waiting on the polygon ROM (prefetch the next record) and the fix for
// serialising three transforms that could overlap (issue them back to back) are
// different pieces of work, and one of them is wasted if the other dominates.
//
// So the walker's state is sampled every cycle and bucketed. The names below are
// m1_geo_walk's own enum, in order.
static const char* WNAME[] = {
    "IDLE",
    "HDR_W", "HDR_XF", "HDR_XFW", "HDR_PJ", "HDR_PJW",
    "REC_W", "REC_DEC", "REC",
    "EMIT", "NEXT", "DONE"
};
static const int NW = sizeof(WNAME) / sizeof(WNAME[0]);
static long whist[32];
// Inside the record state everything overlaps, so "which stage is slow" is not
// the question - the question is which one is STILL OUTSTANDING when nothing
// else is. Those are the cycles that would disappear if that stage were free.
static long wout[6], wonly[6];
static long pj_recip = 0, pj_scale = 0, pj_hold = 0, pj_idle = 0;
// One multiplier and one adder serve seven clients. If the pipeline asks
// for more of either per quad than the 83-cycle budget has cycles, the
// pass is bandwidth-bound and no amount of latency work can reach budget.
static long fp_mul_issued = 0, fp_add_issued = 0;
// DEAD TIME: cycles inside the record walk where NOTHING anywhere in the
// stage is asking either shared unit for work. Those cycles are not
// contention and not arithmetic - they are the dependency chain, and they
// are the only ones that overlapping records can recover.
static long fp_dead = 0, fp_dead_rec = 0;
// Dead cycles bucketed by what the record is still WAITING for. Overlapping
// the next record's transforms only recovers dead time that sits behind the
// tail; dead time behind the transforms themselves needs something else.
static long dead_by[6] = {0,0,0,0,0,0}, dead_none = 0;
static const char* ONAME[6] = { "xform", "project", "determinant",
                                "normalize", "colour", "tgp_ram" };

// The polygon ROM and tgp_ram are both in SDRAM on the real design. One cycle
// is the bench's default because the handshake must be correct at any latency;
// GEO_ROM_LAT models a realistic one, and the difference between the two runs
// is exactly what a prefetch would recover.
static int ROM_LAT = 1, TEX_LAT = 1;

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
    int rom_wait = 0, tex_wait = 0;
    void tick() {
        // A held request answered after ROM_LAT cycles. The counter restarts
        // whenever the request drops, so a new request pays the latency again -
        // which is what makes ten separate word reads cost ten round trips.
        int req = d->rom_req; uint32_t addr = d->rom_addr;
        int treq = d->tex_req; uint32_t taddr = d->tex_addr;
        rom_wait = req ? (rom_wait + 1) : 0;
        tex_wait = treq ? (tex_wait + 1) : 0;
        int rom_ans = req && (rom_wait >= ROM_LAT);
        int tex_ans = treq && (tex_wait >= TEX_LAT);
        if (rom_ans) rom_wait = 0;
        if (tex_ans) tex_wait = 0;
        memories();
        cycles++; d->clk = 0; d->eval();
        {
            auto* r = d->rootp;
            int cur = r->m1_geometry__DOT__u_walk__DOT__st & 31;
            whist[cur]++;
            if (cur == 8) {                     // W_REC
                bool o[6];
                o[0] = r->m1_geometry__DOT__u_walk__DOT__xf_col < 3;
                o[1] = r->m1_geometry__DOT__u_walk__DOT__pj_col < 2;
                o[2] = r->m1_geometry__DOT__u_walk__DOT__dt_iss
                    && !r->m1_geometry__DOT__u_walk__DOT__dt_col;
                o[3] = r->m1_geometry__DOT__u_walk__DOT__nm_iss
                    && !r->m1_geometry__DOT__u_walk__DOT__nm_col;
                o[4] = r->m1_geometry__DOT__u_walk__DOT__cl_iss
                    && !r->m1_geometry__DOT__u_walk__DOT__cl_col;
                o[5] = !r->m1_geometry__DOT__u_walk__DOT__tx_col;
                int n = 0;
                for (int i = 0; i < 6; i++) if (o[i]) { wout[i]++; n++; }
                if (n == 1) for (int i = 0; i < 6; i++) if (o[i]) wonly[i]++;

                // WHERE PROJECTION'S OWN TIME GOES, split by its two stages.
                //
                // "project is outstanding 90.9% and the sole cause 36.8%" was
                // read as "short of dividers", and a second divider measured
                // WORSE - it is never used, because the reciprocal stage takes
                // one vertex at a time. So decompose it rather than guess a
                // third time: R_BUSY is waiting on the divide, S_* is the
                // dependent multiply/add chain, and both idle means projection
                // is waiting to be HANDED a vertex.
                {
                    int rs = r->m1_geometry__DOT__u_project__DOT__rst_st;
                    int ss = r->m1_geometry__DOT__u_project__DOT__sst;
                    if (r->m1_geometry__DOT__u_pool__DOT__mul_any) fp_mul_issued++;
                    if (r->m1_geometry__DOT__u_pool__DOT__add_any) fp_add_issued++;
                    if (!r->m1_geometry__DOT__u_pool__DOT__mul_any
                     && !r->m1_geometry__DOT__u_pool__DOT__add_any) {
                        fp_dead++;
                        if (cur == 8) {                // W_REC
                            fp_dead_rec++;
                            // SOLE cause only. "Outstanding" stays true from the
                            // start of a record until a stage finishes, so it
                            // marks stages that are merely unfinished as well as
                            // stages that are blocking. Only a dead cycle with
                            // exactly one stage outstanding names something that
                            // overlapping work could actually fill.
                            int n = 0, w = -1;
                            for (int b = 0; b < 6; b++) if (o[b]) { n++; w = b; }
                            if (n == 1) dead_by[w]++;
                            else        dead_none++;
                        }
                    }
                    if (rs == 1)      pj_recip++;      // R_BUSY: in the divide
                    else if (rs == 2) pj_hold++;       // R_FULL: waiting to hand over
                    if (ss != 0)      pj_scale++;      // the mul/add chain
                    if (rs == 0 && ss == 0) pj_idle++; // nothing to do
                }
            }
        }
        d->rom_valid = rom_ans; d->rom_data = rom_ans ? prom[PA(addr)] : 0;
        d->tex_valid = tex_ans; d->tex_data = tgpram[taddr & 0xfffff];
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
        // The viewport RECTANGLE now, not the ratios: m1_geo_planes derives
        // those the way set_viewport does, so the DUT does the arithmetic the
        // model does rather than being handed the answer.
        set_planes();
        d->vp_x1 = f2u(VX1); d->vp_x2 = f2u(VX2);
        d->vp_y1 = f2u(VY1); d->vp_y2 = f2u(VY2);
        d->vp_dirty = 1; tick(); d->vp_dirty = 0;
        // The derivation is four divides; give it room before the first quad.
        for (int i = 0; i < 400; i++) tick();
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
        auto put = [&](uint32_t a, float v) { prom[PA(a)] = f2u(v); };
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
            prom[PA(a)] = fl;
            put(a+1, rndc()); put(a+2, rndc()); put(a+3, rndc());
            put(a+4, rndc()); put(a+5, rndc()); put(a+6, 40.0f + (float)(r()%100));
            put(a+7, rndc()); put(a+8, rndc()); put(a+9, 40.0f + (float)(r()%100));
            a += 10;
        }
        prom[PA(a)] = 0;                            // terminator: type 0
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
            fails++; printf("  FAIL iter %d: never finished\n", iter);
            {
                auto* r = t.d->rootp;
                printf("    st=%u xf %u/%u  pj %u/%u  dt %u/%u  nm %u/%u"
                       "  cl %u/%u  tx=%u z_done=%u\n",
                       r->m1_geometry__DOT__u_walk__DOT__st,
                       r->m1_geometry__DOT__u_walk__DOT__xf_iss,
                       r->m1_geometry__DOT__u_walk__DOT__xf_col,
                       r->m1_geometry__DOT__u_walk__DOT__pj_iss,
                       r->m1_geometry__DOT__u_walk__DOT__pj_col,
                       r->m1_geometry__DOT__u_walk__DOT__dt_iss,
                       r->m1_geometry__DOT__u_walk__DOT__dt_col,
                       r->m1_geometry__DOT__u_walk__DOT__nm_iss,
                       r->m1_geometry__DOT__u_walk__DOT__nm_col,
                       r->m1_geometry__DOT__u_walk__DOT__cl_iss,
                       r->m1_geometry__DOT__u_walk__DOT__cl_col,
                       r->m1_geometry__DOT__u_walk__DOT__tx_col,
                       r->m1_geometry__DOT__u_walk__DOT__z_done);
            } break;
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
        memset(whist, 0, sizeof whist);
        memset(wout, 0, sizeof wout); memset(wonly, 0, sizeof wonly);
        // These four accumulate from the moment the DUT starts running, so
        // without this they cover the whole bench while `busy` covers only the
        // loop below - which printed "recip 425%" and made the reciprocal look
        // like four frames of work. Every inside-projection percentage recorded
        // before 2026-09-08 was inflated that way. The RATIOS between them were
        // always sound, because all four shared the same wrong window.
        pj_recip = pj_scale = pj_hold = pj_idle = 0;
        fp_mul_issued = fp_add_issued = 0;
        fp_dead = fp_dead_rec = 0;
        for (int b = 0; b < 6; b++) dead_by[b] = 0;
        dead_none = 0;
        for (int i = 0; i < reps; i++) { t.run(0x40000, 0x100, 0, oz); quads += (int)t.got.size(); }
        long busy = t.cycles - c0;
        double per_quad = quads ? (double)busy / quads : 0.0;
        printf("  %d quads in %ld cycles: %.1f cycles per quad\n",
               quads, busy, per_quad);
        printf("  a peak frame of 4,798 quads would need %.0f cycles of 818,133 (%.0f%%)\n",
               per_quad * 4798, 100.0 * per_quad * 4798 / 818133.0);

        // WHERE THE CYCLES GO. Grouped the way the fixes are: waiting on memory,
        // waiting on an arithmetic stage that could have been issued alongside
        // the previous one, and the walker's own bookkeeping.
        // The record path is a single state now: everything overlaps inside it,
        // so a per-stage split is no longer meaningful and what matters is how
        // much of the walk is spent WAITING for the polygon ROM instead.
        for (int i = 1; i < NW; i++)
            if (whist[i] > busy / 100)
                printf("  %-8s %6ld cycles  %5.1f%%\n",
                       WNAME[i], whist[i], 100.0 * whist[i] / busy);
        printf("  inside projection: recip %ld (%.1f%%)  scale %ld (%.1f%%)  "
               "handover %ld (%.1f%%)  idle %ld (%.1f%%)\n",
               pj_recip, 100.0 * pj_recip / busy, pj_scale, 100.0 * pj_scale / busy,
               pj_hold,  100.0 * pj_hold  / busy, pj_idle,  100.0 * pj_idle  / busy);
        // THE FLOOR. One multiplier and one adder serve seven clients and both
        // accept an operation every cycle, so a perfectly pipelined pass still
        // cannot run a quad in fewer cycles than it issues multiplies. That is
        // the wall no amount of latency work can pass, and the distance between
        // it and the measured figure is pure serialisation.
        double mq = (double)fp_mul_issued / quads, aq = (double)fp_add_issued / quads;
        double floor_q = mq > aq ? mq : aq;
        printf("  dead time: %.0f%% of all cycles ask NEITHER unit for work "
               "(%.0f%% of them inside the record walk)\n"
               "    that is the dependency chain, and it is what overlapping "
               "records recovers\n",
               100.0 * fp_dead / busy, 100.0 * fp_dead_rec / (fp_dead ? fp_dead : 1));
        printf("  pool demand: %.1f multiplies and %.1f adds a quad\n"
               "    one mul + one add, 7 clients -> floor %.0f cycles a quad "
               "(%.0f%% of a frame); measured %.1f, so %.1fx is serialisation\n",
               mq, aq, floor_q, 100.0 * floor_q * 4798 / 818133.0,
               per_quad, per_quad / floor_q);
        printf("  DEAD cycles in the record, by what is still outstanding:\n");
        for (int b = 0; b < 6; b++)
            printf("    %-12s %6ld  %4.1f%% of dead\n", ONAME[b], dead_by[b],
                   100.0 * dead_by[b] / (fp_dead_rec ? fp_dead_rec : 1));
        printf("    %-12s %6ld  %4.1f%% of dead   (two or more, or none)\n", "shared", dead_none,
               100.0 * dead_none / (fp_dead_rec ? fp_dead_rec : 1));
        printf("  inside the record, outstanding / sole cause:\n");
        for (int i = 0; i < 6; i++)
            printf("    %-12s %6ld  %5.1f%%   alone %6ld  %5.1f%%\n",
                   ONAME[i], wout[i], 100.0 * wout[i] / busy,
                   wonly[i], 100.0 * wonly[i] / busy);

        // THE SAME WALK WITH A REAL MEMORY BEHIND IT. Both the polygon ROM and
        // tgp_ram are in SDRAM; the read crosses into clk_sys, arbitrates
        // against six other ports and crosses back. One cycle is what the rest
        // of this bench uses, because the handshake has to be right at any
        // latency - but it is not what the hardware pays, and the walker asks
        // for TEN SEPARATE WORDS per record.
        ROM_LAT = 12; TEX_LAT = 12;
        long c1 = t.cycles; int quads2 = 0;
        for (int i = 0; i < reps; i++) { t.run(0x40000, 0x100, 0, oz); quads2 += (int)t.got.size(); }
        double pq2 = quads2 ? (double)(t.cycles - c1) / quads2 : 0.0;
        printf("  at a 12-cycle memory: %.1f cycles per quad (%.1fx), %.0f%% of a frame\n",
               pq2, pq2 / per_quad, 100.0 * pq2 * 4798 / 818133.0);
        ROM_LAT = 1; TEX_LAT = 1;
        // Not asserted as a pass/fail: the walker drives the stages one at a
        // time, so this is the UNPIPELINED figure and the number to improve
        // against. Recorded so the improvement is measurable rather than assumed.
    }

    // ------------------------------------------------------------------
    // REAL MODELS OUT OF THE POLYGON ROM.
    //
    // Everything above walks models this bench built. Ben's board draws most
    // objects right and some - mainly the road - wrong, which no synthetic
    // corpus can reproduce: a link pattern, a type-2 record or a flag
    // combination that only occurs in Sega's data has never been compared
    // against push_object here.
    //
    // build/real_objects.txt is the distinct (tex, poly, size) triples our own
    // V60 put in its display list, and build/rom/vr_stream.bin is the packed
    // ROM image with the models at byte 0x840000. Both are build artefacts and
    // neither is in the repository - hard rule 2.
    printf("test: REAL models from the polygon ROM, against push_object\n");
    {
        FILE* rf = fopen("build/rom/vr_stream.bin", "rb");
        FILE* of = fopen("build/real_objects.txt", "r");
        if (!rf || !of) {
            printf("  skipped: need build/rom/vr_stream.bin (build_rom_image.py --bin)\n");
            printf("           and build/real_objects.txt (see tools/dlist_objects.py)\n");
        } else {
            fseek(rf, 0x840000, SEEK_SET);
            size_t got = fread(prom.data(), 4, PROM_WORDS, rf);
            printf("  polygon ROM: %zu model words from byte 0x840000\n", got);

            // The DUT's plane inputs follow the viewport, and this test never
            // set one - so it was comparing against a model that recomputes the
            // planes from the current globals while the DUT still held the
            // previous test's. Same view on both sides now.
            t.set_view();
            unsigned cmd, tex, poly, size;
            int nobj = 0, bad_obj = 0;
            long rq = 0, rpx = 0, rcol_ok = 0, rcol_bad = 0;
            std::vector<Quad> bt_quads;
            float oz_m = 0.0f, oz_d = 0.0f;
            // A YAW SWEEP, because one orientation proves one orientation.
            //
            // This test walked real models under a single near-identity matrix,
            // which is the same trap the clipper's coverage was in: a corpus
            // that agrees with the model says nothing about a case it never
            // reaches. On the board the road and the scenery vanish WHEN THE
            // VIEW TURNS and stay gone while it is held at that angle, so the
            // orientation is the variable, and it was the one thing held fixed.
            //
            // Sixteen yaws around the full circle, each with the same objects
            // and the same running old_z discipline. If any part of the
            // pipeline - the facing test's sign, the clipper's planes, the
            // projection - is wrong for some rotation, it differs from
            // push_object here rather than on Ben's screen.
            for (int yaw = 0; yaw < 16; yaw++) {
            const float th = (float)yaw * 6.2831853f / 16.0f;
            const float cs = cosf(th), sn = sinf(th);
            // Column-major as xform_pt reads it: mat[0,3,6] is the first row.
            mat[0] =  cs; mat[3] = 0.0f; mat[6] =  sn;
            mat[1] = 0.0f; mat[4] = 1.0f; mat[7] = 0.0f;
            mat[2] = -sn; mat[5] = 0.0f; mat[8] =  cs;
            mat[9] = 0.0f; mat[10] = 0.0f; mat[11] = 120.0f;
            t.set_view();
            rewind(of);
            oz_m = 0.0f; oz_d = 0.0f;
            while (fscanf(of, "%x %x %x %x", &cmd, &tex, &poly, &size) == 4) {
                nobj++;
                // old_z carries ACROSS objects, as push_object requires, so both
                // sides keep their own running value exactly as the walk does.
                std::vector<Quad> exp = model(tex, poly, size, oz_m);
                checks++;
                if (!t.run(tex, poly, size, oz_d)) {
                    fails++; bad_obj++;
                    if (printed++ < 20)
                        printf("  FAIL object %d (poly %06x): never finished\n", nobj, poly);
                    continue;
                }
                checks++;
                if (t.got.size() != exp.size()) {
                    fails++; bad_obj++;
                    if (printed++ < 20)
                        printf("  FAIL object %d (poly %06x): %zu quads, expected %zu\n",
                               nobj, poly, t.got.size(), exp.size());
                    continue;
                }
                for (size_t k = 0; k < exp.size(); k++) {
                    const Quad& e = exp[k]; const Quad& g = t.got[k];
                    bt_quads.push_back(g);
                    rq++;
                    checks++;
                    for (int v = 0; v < 4; v++) {
                        if (g.x[v] != e.x[v] || g.y[v] != e.y[v]) rpx++;
                        if (labs((long)g.x[v] - e.x[v]) > 1 ||
                            labs((long)g.y[v] - e.y[v]) > 1) {
                            fails++;
                            if (printed++ < 20)
                                printf("  FAIL object %d (poly %06x) quad %zu vertex %d:"
                                       " (%d,%d) expected (%d,%d)\n",
                                       nobj, poly, k, v, g.x[v], g.y[v], e.x[v], e.y[v]);
                            break;
                        }
                    }
                    checks++;
                    if (g.z != e.z) {
                        fails++;
                        if (printed++ < 20)
                            printf("  FAIL object %d (poly %06x) quad %zu: z %08x expected %08x\n",
                                   nobj, poly, k, g.z, e.z);
                    }
                    if (g.col == e.col) rcol_ok++; else rcol_bad++;
                }
            }
            }   // yaw
            fclose(rf); fclose(of);
            // BAND TOUCHES PER QUAD, on real models from the polygon ROM.
            //
            // The band renderer replays every quad for every one of the 24
            // bands, which is why the store must hold a whole frame and why
            // Virtua Fighter discards 8,072 quads against a 3,072 capacity.
            // Binning per band instead stores and re-reads total band-TOUCHES
            // rather than quads, so this ratio is what decides whether that
            // cure is affordable in SDRAM. "About three" was a guess.
            //
            // CAVEAT: these are real models under this bench's viewport, not
            // the game's. The shape of the geometry is real; the vertical
            // spread depends on a camera the bench chose.
            {
                const int BANDH = 16, SCRH = 384;
                long touches = 0, counted = 0, offscr = 0;
                for (const Quad& q : bt_quads) {
                    int lo = q.y[0], hi = q.y[0];
                    for (int v = 1; v < 4; v++) {
                        if (q.y[v] < lo) lo = q.y[v];
                        if (q.y[v] > hi) hi = q.y[v];
                    }
                    if (hi < 0 || lo > SCRH - 1) { offscr++; continue; }
                    if (lo < 0) lo = 0;
                    if (hi > SCRH - 1) hi = SCRH - 1;
                    touches += (hi / BANDH) - (lo / BANDH) + 1;
                    counted++;
                }
                if (counted)
                    printf("  band touches: %ld over %ld on-screen quads = %.2f a quad"
                           " (%ld off screen)\n",
                           touches, counted, (double)touches / counted, offscr);
            }
            printf("  %d real objects over 16 yaw angles, %d that did not match at all\n",
                   nobj, bad_obj);
            printf("  %ld quads, %ld vertex coordinates differing, colour exact on %ld of %ld\n",
                   rq, rpx, rcol_ok, rcol_ok + rcol_bad);
        }
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

    printf("  clipper: %ld edge vertices created over %ld quads\n",
           clip_edges, total_quads);
    if (clip_edges == 0)
        printf("  WARNING the corpus never crosses a frustum plane, so this "
               "suite says NOTHING about the clipper\n");
    printf("m1_geometry: checks=%ld fails=%ld quads=%ld\n", checks, fails, total_quads);
    return fails ? 1 : 0;
}
