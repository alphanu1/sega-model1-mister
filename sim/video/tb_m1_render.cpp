// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Render one REAL frame through the real RTL, and write it out as an image.
//
// Everything the geometry stage reads comes from the reference: the display list,
// the palette, the colour-translation table, the colour words and the light banks
// are dumped out of MAME by tools/mame_dump_frame.lua, and the models come from
// the polygon ROM in the packed image. So a difference in the picture is the
// RTL's, not the input's.
//
// The chain is m1_geometry -> painter's sort -> m1_raster_fill -> framebuffer.
// Two pieces of it are C++ rather than RTL, and both are stated rather than
// hidden: the display-list interpretation (m1_listwalk is verified separately and
// drives the same commands) and the sort (the quad store is an SDRAM design
// decision that is not built yet, docs/findings.md). Everything between the
// object address and the spans is RTL.
//
//   make render        writes build/render/frame.ppm
//
// It is a bench, not a test: it has no pass criterion beyond "it produced a
// picture and reported what went into it". The numbers it prints - objects,
// quads, culled, spans, pixels - are the diagnostic. A black screen with 0 quads
// and a black screen with 40,000 quads are completely different faults.

#include "Vm1_render_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <algorithm>

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static const int SW = 496, SH = 384;

// ---------------------------------------------------------------- inputs
static std::vector<uint16_t> dlist, palette, xlat, tgpram;
static std::vector<uint32_t> prom;          // the polygon ROM, 32-bit words
static std::vector<uint32_t> pram(1 << 20); // poly RAM, from command 5
struct LPB { float d, a, s; uint8_t p; };
static LPB lpbank[256];

static bool load(const char* path, std::vector<uint16_t>& v, size_t words) {
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s\n", path); return false; }
    v.assign(words, 0);
    size_t n = fread(v.data(), 2, words, f);
    fclose(f);
    printf("  %-28s %zu words\n", path, n);
    return true;
}

// ---------------------------------------------------------------- framebuffer
static uint8_t fb[SH][SW][3];
static long painted = 0;

static void draw_span(int y, int x0, int x1, uint32_t col, bool moire) {
    if (y < 0 || y >= SH) return;
    if (x0 < 0) x0 = 0;
    if (x1 > SW - 1) x1 = SW - 1;
    for (int x = x0; x <= x1; x++) {
        if (moire && ((x ^ y) & 1)) continue;
        fb[y][x][0] = (col >> 16) & 0xff;
        fb[y][x][1] = (col >> 8) & 0xff;
        fb[y][x][2] = col & 0xff;
        painted++;
    }
}

// ---------------------------------------------------------------- the DUT
struct Quad {
    int32_t x[4], y[4];
    uint32_t col, z;
    bool moire;
    uint32_t seq;
    int lp;
    uint16_t tex;
};

struct Dut {
    Vm1_render_top* d = new Vm1_render_top;
    long cycles = 0;
    std::vector<Quad> quads;
    uint32_t seq = 0;

    void memories() {
        d->g_tex_data  = tgpram[d->g_tex_addr & 0xfffff];
        d->g_pal_data  = palette[d->g_pal_addr & 0x1fff];
        d->g_xlat_data = xlat[d->g_xlat_addr & 0x7fff];
        const LPB& lp = lpbank[d->g_lp_addr];
        d->g_lp_d = f2u(lp.d); d->g_lp_a = f2u(lp.a);
        d->g_lp_s = f2u(lp.s); d->g_lp_p = lp.p;
    }
    void tick() {
        int req = d->g_rom_req; uint32_t addr = d->g_rom_addr;
        int treq = d->g_tex_req; uint32_t taddr = d->g_tex_addr;
        memories();
        cycles++; d->clk = 0; d->eval();
        d->g_rom_valid = req;
        d->g_rom_data  = req ? (addr < prom.size() ? prom[addr] : 0) : 0;
        d->g_tex_valid = treq;
        d->g_tex_data  = tgpram[taddr & 0xfffff];
        memories();
        d->clk = 1; d->eval();
        if (d->g_q_valid) {
            Quad q;
            q.x[0] = d->g_q_x0; q.y[0] = d->g_q_y0;
            q.x[1] = d->g_q_x1; q.y[1] = d->g_q_y1;
            q.x[2] = d->g_q_x2; q.y[2] = d->g_q_y2;
            q.x[3] = d->g_q_x3; q.y[3] = d->g_q_y3;
            q.col = d->g_q_col; q.z = d->g_q_z; q.moire = d->g_q_moire;
            q.seq = seq++;
            q.lp = d->g_lp_addr;
            q.tex = tgpram[d->g_tex_addr & 0xfffff];
            quads.push_back(q);
        }
        if (d->f_span_valid)
            draw_span(d->f_span_y, d->f_span_x0, d->f_span_x1,
                      d->f_span_col, d->f_span_moire);
    }
    void reset() {
        d->rst_n = 0; d->g_start = 0; d->mat_we = 0; d->g_rom_valid = 0;
        d->f_in_valid = 0; d->f_span_ready = 1; d->g_tex_valid = 0;
        for (int i = 0; i < 8; i++) tick();
        d->rst_n = 1;
        for (int i = 0; i < 8; i++) tick();
    }
};

static Dut* T;

// ---------------------------------------------------------------- list walk
static uint32_t rd16(int a) { return dlist[a & 0x7fff]; }
static uint32_t rdi(int a)  { return rd16(a) | (rd16(a + 1) << 16); }
static float    rdf(int a)  { return u2f(rdi(a)); }
static int16_t  rds(int a)  { return (int16_t)rd16(a); }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* dir = (argc > 1) ? argv[1] : "build/framedump/framedump";
    const char* romp = (argc > 2) ? argv[2] : "build/rom/vr_stream.bin";
    char p[512];

    printf("loading the reference's own frame state:\n");
    snprintf(p, sizeof p, "%s/dlist.bin", dir);   if (!load(p, dlist, 0x8000)) return 1;
    snprintf(p, sizeof p, "%s/palette.bin", dir); if (!load(p, palette, 0x2000)) return 1;
    snprintf(p, sizeof p, "%s/xlat.bin", dir);    if (!load(p, xlat, 0x6000)) return 1;
    xlat.resize(0x8000, 0);   // the mask is 15 bits; keep the array that big

    // tgp_ram is sparse: a count, then (index, value) pairs.
    tgpram.assign(1 << 20, 0);
    snprintf(p, sizeof p, "%s/tgpram.bin", dir);
    {
        FILE* f = fopen(p, "rb");
        if (!f) { printf("cannot open %s\n", p); return 1; }
        uint32_t n = 0; size_t rd = fread(&n, 4, 1, f); (void)rd;
        for (uint32_t i = 0; i < n; i++) {
            uint32_t idx; uint16_t v;
            if (fread(&idx, 4, 1, f) != 1) break;
            if (fread(&v, 2, 1, f) != 1) break;
            if (idx < tgpram.size()) tgpram[idx] = v;
        }
        fclose(f);
        printf("  %-28s %u entries\n", p, n);
    }
    snprintf(p, sizeof p, "%s/lightparams.txt", dir);
    {
        FILE* f = fopen(p, "r");
        if (!f) { printf("cannot open %s\n", p); return 1; }
        int i, dd, aa, ss, pp;
        while (fscanf(f, "%d %d %d %d %d", &i, &dd, &aa, &ss, &pp) == 5)
            if (i >= 0 && i < 256) lpbank[i] = {dd/255.0f, aa/255.0f, ss/255.0f, (uint8_t)pp};
        fclose(f);
        printf("  %-28s 256 banks\n", p);
    }

    // The polygon ROM: 16 MB at 0x840000 of the packed image, as 32-bit words.
    {
        FILE* f = fopen(romp, "rb");
        if (!f) { printf("cannot open %s - run build_rom_image.py first\n", romp); return 1; }
        fseek(f, 0, SEEK_END); long sz = ftell(f);
        const long POLY_OFF = 0x840000;
        if (sz < POLY_OFF + 0x1000000) {
            printf("  %s is %ld bytes - no polygon region (needs %ld)\n",
                   romp, sz, POLY_OFF + 0x1000000);
            return 1;
        }
        prom.assign(0x400000, 0);
        fseek(f, POLY_OFF, SEEK_SET);
        size_t n = fread(prom.data(), 4, prom.size(), f);
        fclose(f);
        printf("  %-28s %zu words of polygon models\n", romp, n);
    }

    Dut t; t.reset(); T = &t;
    memset(fb, 0, sizeof fb);

    // ---------------------------------------------------------- walk the list
    float xc = 0, yc = 0, x1 = 0, x2 = 0, y1v = 0, y2v = 0;
    float zoomx = 1, zoomy = 1, viewx = 0, viewy = 0;
    float old_z = 0.0f;
    int objs = 0, skipped_ram = 0, vps = 0;
    long total_records = 0, total_culled = 0, total_nolink = 0;

    t.d->frame_odd = 0;
    t.d->spec_enable = 1;

    int off = 0, guard = 0;
    bool done = false;
    while (!done && guard++ < 40000) {
        if (off >= 0x8000) break;
        uint32_t type = rdi(off);
        switch (type) {
        case 0: off += 2; break;
        case 1: case 0x41: {
            uint32_t tex = rdi(off + 2), padr = rdi(off + 4), size = rdi(off + 6);
            if (padr & 0x800000) { skipped_ram++; off += 8; break; }
            objs++;
            t.d->g_old_z_in = f2u(old_z);
            t.d->g_tex_adr = tex; t.d->g_poly_adr = padr; t.d->g_size = size;
            t.d->g_start = 1; t.tick(); t.d->g_start = 0;
            int gg = 0;
            while (!t.d->g_done && ++gg < 8000000) t.tick();
            old_z = u2f(t.d->g_old_z_out);
            total_records += t.d->g_dbg_records;
            total_culled  += t.d->g_dbg_culled;
            total_nolink  += t.d->g_dbg_nolink;
            off += 8;
            break;
        }
        case 2: {
            off += 18;
            while (true) {
                uint32_t st = rdi(off + 2) & 3;
                if (!st) break;
                off += (st == 2) ? 12 : 20;
            }
            off += 4;
            break;
        }
        case 3: {
            // MAME's own transformation of the viewport words.
            xc  = rds(off + 4);
            yc  = 383 - (rds(off + 6) - 39);
            x1  = rds(off + 8);
            y2v = 383 - (rds(off + 10) - 39);
            x2  = rds(off + 12);
            y1v = 383 - (rds(off + 14) - 39);
            t.d->xc = f2u(xc); t.d->yc = f2u(yc);
            vps++;
            off += 16;
            break;
        }
        case 4: off += 6 + ((rdi(off + 4) + 1) & 0xffff) * 2; break;
        case 5: {
            uint32_t adr = rdi(off + 2), len = rdi(off + 4) & 0xffff;
            for (uint32_t i = 0; i < len; i++)
                pram[(adr - 0x800000 + i) & 0xfffff] = rdi(off + 2 * i + 6);
            off += 6 + len * 2;
            break;
        }
        case 6: off += 6 + (rdi(off + 4) & 0xffff) * 2; break;
        case 7: t.d->spec_enable = rdi(off + 2) & 1; off += 4; break;
        case 8: off += 4; break;
        case 9:
            zoomx = rdf(off + 2) * 4.0f; zoomy = rdf(off + 4) * 4.0f;
            t.d->zoomx = f2u(zoomx); t.d->zoomy = f2u(zoomy);
            off += 6; break;
        case 0xa: {
            float lx = rdf(off + 2), ly = rdf(off + 4), lz = rdf(off + 6);
            float l = std::sqrt(lx*lx + ly*ly + lz*lz);
            if (l > 0) { lx /= l; ly /= l; lz /= l; }
            t.d->light_x = f2u(lx); t.d->light_y = f2u(ly); t.d->light_z = f2u(lz);
            off += 8; break;
        }
        case 0xb:
            for (int i = 0; i < 12; i++) {
                t.d->mat_we = 1; t.d->mat_idx = i; t.d->mat_data = rdi(off + 2 + 2 * i);
                t.tick();
            }
            t.d->mat_we = 0; t.tick();
            off += 26; break;
        case 0xc:
            viewx = rdf(off + 2); viewy = rdf(off + 4);
            t.d->viewx = f2u(viewx); t.d->viewy = f2u(viewy);
            off += 6; break;
        default: done = true; break;
        }
    }

    printf("\ndisplay list: %d objects, %d viewports, %d objects in poly RAM (skipped)\n",
           objs, vps, skipped_ram);
    printf("viewport xc=%g yc=%g  x %g..%g  y %g..%g  zoom %g,%g  view %g,%g\n",
           xc, yc, x1, x2, y1v, y2v, zoomx, zoomy, viewx, viewy);
    printf("records %ld, culled %ld, link-0 %ld, quads emitted %zu\n",
           total_records, total_culled, total_nolink, t.quads.size());
    {
        long nzcol = 0;
        for (const Quad& q : t.quads) if (q.col) nzcol++;
        printf("quad colours: %ld of %zu non-black\n", nzcol, t.quads.size());
        long lph[256] = {0}, lph_black[256] = {0};
        for (const Quad& q : t.quads) { lph[q.lp & 0xff]++; if (!q.col) lph_black[q.lp & 0xff]++; }
        printf("light bank usage (bank: quads, of which black):\n   ");
        for (int i = 0; i < 256; i++) if (lph[i]) printf(" %d:%ld/%ld", i, lph[i], lph_black[i]);
        printf("\n");
        for (size_t i = 0; i < t.quads.size() && i < 6; i++)
            printf("  quad %zu col %06x tex %04x lp %d z %g  (%d,%d)(%d,%d)(%d,%d)(%d,%d)\n",
                   i, t.quads[i].col, t.quads[i].tex, t.quads[i].lp, u2f(t.quads[i].z),
                   t.quads[i].x[0], t.quads[i].y[0], t.quads[i].x[1], t.quads[i].y[1],
                   t.quads[i].x[2], t.quads[i].y[2], t.quads[i].x[3], t.quads[i].y[3]);
    }

    // How many quads would not survive a 16-bit store? m1_raster3d truncates
    // screen coordinates to 16 bits, and a coordinate outside that range wraps
    // rather than clipping - so this is the first thing to rule in or out when
    // the two renders disagree on pixels while agreeing on quads.
    {
        long oob = 0, worst = 0;
        for (const Quad& q : t.quads)
            for (int v = 0; v < 4; v++) {
                long ax = labs((long)q.x[v]), ay = labs((long)q.y[v]);
                if (ax > 32767 || ay > 32767) { oob++; break; }
                if (ax > worst) worst = ax;
                if (ay > worst) worst = ay;
            }
        printf("quads with a coordinate outside +/-32767: %ld of %zu (largest in range %ld)\n",
               oob, t.quads.size(), worst);
    }

    // ---------------------------------------------------------- painter's sort
    // z DESCENDING, ties by submission order - quad_t::compare exactly.
    std::stable_sort(t.quads.begin(), t.quads.end(), [](const Quad& a, const Quad& b) {
        float za = u2f(a.z), zb = u2f(b.z);
        if (za != zb) return za > zb;
        return a.seq < b.seq;
    });

    // ---------------------------------------------------------- fill
    t.d->f_view_x1 = (int32_t)x1;  t.d->f_view_x2 = (int32_t)x2;
    t.d->f_view_y1 = (int32_t)y1v; t.d->f_view_y2 = (int32_t)y2v;
    long spans_before = painted;
    int filled = 0, lines = 0;
    for (const Quad& q : t.quads) {
        int g2 = 0;
        while (!t.d->f_in_ready && ++g2 < 100000) t.tick();
        t.d->f_in_valid = 1;
        t.d->f_in_x0 = q.x[0]; t.d->f_in_y0 = q.y[0];
        t.d->f_in_x1 = q.x[1]; t.d->f_in_y1 = q.y[1];
        t.d->f_in_x2 = q.x[2]; t.d->f_in_y2 = q.y[2];
        t.d->f_in_x3 = q.x[3]; t.d->f_in_y3 = q.y[3];
        t.d->f_in_col = q.col; t.d->f_in_moire = q.moire;
        t.tick();
        t.d->f_in_valid = 0;
        g2 = 0;
        while (!t.d->f_quad_done && ++g2 < 200000) t.tick();
        if (t.d->f_line_case) lines++;
        filled++;
    }
    for (int i = 0; i < 64; i++) t.tick();

    printf("filled %d quads (%d were wireframes), %ld pixels painted\n",
           filled, lines, painted - spans_before);
    printf("simulated %ld cycles = %.1f ms of a 23.53 MHz clock\n",
           t.cycles, t.cycles / 23529.412);

    // ---------------------------------------------------------- write it out
    system("mkdir -p build/render");
    FILE* out = fopen("build/render/frame.ppm", "wb");
    if (!out) { printf("cannot write build/render/frame.ppm\n"); return 1; }
    fprintf(out, "P6\n%d %d\n255\n", SW, SH);
    fwrite(fb, 1, sizeof fb, out);
    fclose(out);
    printf("\nwrote build/render/frame.ppm  (%dx%d)\n", SW, SH);
    return 0;
}
