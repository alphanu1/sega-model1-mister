// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The whole 3D layer, driven from a real frame, captured band by band.
//
// m1_raster3d is the block the core will instantiate, so this is the test that
// matters for hardware: it drives only the ports the core drives - a frame pulse
// and five memories - and reads only the pixel the mixer will read. Nothing is
// orchestrated from C++ the way tb_m1_render orchestrates it. The list walk, the
// per-object geometry, the sort, the band sequencing and the scanout are all the
// module's own.
//
// The picture is captured the only way the hardware can present it: each band is
// read out through scan_x/scan_y while it is the displayable buffer, exactly as
// the video path will. A module that filled the bands correctly but presented the
// wrong one - which is a real hazard, since the read buffer always holds SOME
// band - produces a scrambled frame here and a perfect one in any test that
// reaches into the buffers directly.
//
//   make render3d      writes build/render/frame3d.ppm
//
// Compared against build/render/frame.ppm, the picture the C++-orchestrated
// render produces from the same inputs. They should agree except where the band
// architecture legitimately differs: the band buffer is RGB565 and the reference
// framebuffer is RGB888, so each channel loses its low bits.

#include "Vm1_raster3d.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <cmath>

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

static const int SW = 496, SH = 384, BAND_H = 32;

static std::vector<uint16_t> dlist, palette, xlat, tgpram;
static std::vector<uint32_t> prom;
struct LPB { float d, a, s; uint8_t p; };
static LPB lpbank[256];
static uint8_t fb[SH][SW][3];
static bool    got_row[SH];

static bool load(const char* path, std::vector<uint16_t>& v, size_t words) {
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s\n", path); return false; }
    v.assign(words, 0);
    size_t n = fread(v.data(), 2, words, f);
    fclose(f);
    printf("  %-36s %zu words\n", path, n);
    return true;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* dir = (argc > 1) ? argv[1] : "build/framedump/framedump";
    const char* romp = (argc > 2) ? argv[2] : "build/rom/vr_stream.bin";
    char p[512];

    printf("loading the reference's own frame state:\n");
    snprintf(p, sizeof p, "%s/dlist.bin", dir);   if (!load(p, dlist, 0x8000)) return 1;
    snprintf(p, sizeof p, "%s/palette.bin", dir); if (!load(p, palette, 0x2000)) return 1;
    snprintf(p, sizeof p, "%s/xlat.bin", dir);    if (!load(p, xlat, 0x6000)) return 1;
    xlat.resize(0x8000, 0);
    tgpram.assign(1 << 20, 0);
    snprintf(p, sizeof p, "%s/tgpram.bin", dir);
    { FILE* f = fopen(p, "rb"); if (!f) { printf("cannot open %s\n", p); return 1; }
      uint32_t n = 0; if (fread(&n, 4, 1, f) != 1) n = 0;
      for (uint32_t i = 0; i < n; i++) { uint32_t idx; uint16_t v;
        if (fread(&idx, 4, 1, f) != 1) break; if (fread(&v, 2, 1, f) != 1) break;
        if (idx < tgpram.size()) tgpram[idx] = v; }
      fclose(f); printf("  %-36s %u entries\n", p, n); }
    snprintf(p, sizeof p, "%s/lightparams.txt", dir);
    { FILE* f = fopen(p, "r"); if (!f) { printf("cannot open %s\n", p); return 1; }
      int i, dd, aa, ss, pp;
      while (fscanf(f, "%d %d %d %d %d", &i, &dd, &aa, &ss, &pp) == 5)
        if (i >= 0 && i < 256) lpbank[i] = {dd/255.0f, aa/255.0f, ss/255.0f, (uint8_t)pp};
      fclose(f); printf("  %-36s 256 banks\n", p); }
    { FILE* f = fopen(romp, "rb"); if (!f) { printf("cannot open %s\n", romp); return 1; }
      fseek(f, 0, SEEK_END); long sz = ftell(f);
      if (sz < 0x840000 + 0x1000000) { printf("  %s has no polygon region\n", romp); return 1; }
      prom.assign(0x400000, 0); fseek(f, 0x840000, SEEK_SET);
      size_t n = fread(prom.data(), 4, prom.size(), f); fclose(f);
      printf("  %-36s %zu words of models\n", romp, n); }

    Vm1_raster3d* d = new Vm1_raster3d;
    long cycles = 0;
    memset(fb, 0, sizeof fb);
    memset(got_row, 0, sizeof got_row);

    auto memories = [&]() {
        d->dl_data   = dlist[d->dl_addr & 0x7fff];
        d->rom_data  = (d->rom_addr < prom.size()) ? prom[d->rom_addr] : 0;
        d->tex_data  = tgpram[d->tex_addr & 0xfffff];
        d->pal_data  = palette[d->pal_addr & 0x1fff];
        d->xlat_data = xlat[d->xlat_addr & 0x7fff];
        // The light banks are INTERNAL now, filled by the module's own walk of
        // display-list command 6. Nothing to drive - and that is the point: the
        // bench no longer supplies state the hardware would have to derive.
    };
    auto tick = [&]() {
        int dreq = d->dl_req, rreq = d->rom_req, treq = d->tex_req;
        uint32_t taddr = d->tex_addr;
        memories();
        cycles++; d->clk = 0; d->eval();
        d->dl_valid = dreq; d->rom_valid = rreq;
        d->tex_valid = treq; d->tex_data = tgpram[taddr & 0xfffff];
        memories();
        d->clk = 1; d->eval();
    };

    d->rst_n = 0; d->frame_start = 0; d->frame_odd = 0; d->dl_sel = 0;
    d->scan_x = 0; d->scan_y = 0; d->dl_valid = 0; d->rom_valid = 0;
    d->tex_valid = 0;
    for (int i = 0; i < 8; i++) tick();
    d->rst_n = 1;
    for (int i = 0; i < 8; i++) tick();

    // ---- prologue: upload the light banks through the module's own walk
    //
    // The light parameter banks are FRAME-PERSISTENT state. The reference
    // uploads them with display-list command 6 at some earlier point and they
    // survive; frame 900's list contains no command 6 at all, which is why the
    // dump accumulates them across 900 frames. Feeding them in through the
    // module's port would be supplying state the hardware has to derive, so
    // instead a synthetic list is walked first that uploads them exactly as the
    // game does - which also makes command 6 the only path they can arrive by,
    // and therefore tested.
    {
        std::vector<uint16_t> pro(0x8000, 0);
        size_t w = 0;
        pro[w++] = 6; pro[w++] = 0;             // type 6, 32-bit
        pro[w++] = 0; pro[w++] = 0;             // base address 0
        pro[w++] = 256; pro[w++] = 0;           // 256 entries
        for (int i = 0; i < 256; i++) {
            const LPB& lp = lpbank[i];
            uint32_t packed = (uint32_t)lroundf(lp.d * 255.0f)
                            | ((uint32_t)lroundf(lp.a * 255.0f) << 8)
                            | ((uint32_t)lroundf(lp.s * 255.0f) << 16)
                            | ((uint32_t)lp.p << 24);
            pro[w++] = packed & 0xffff; pro[w++] = packed >> 16;
        }
        pro[w++] = 0x0f; pro[w++] = 0;          // end
        std::vector<uint16_t> real = dlist;
        dlist = pro;
        d->frame_start = 1; tick(); d->frame_start = 0;
        long g = 0;
        while (++g < 20000000 && !(d->dbg_frames)) tick();
        // Let the band passes finish so the sequencer returns to idle.
        g = 0;
        while (++g < 20000000 && d->dbg_frames == 1 && !d->disp_valid) tick();
        for (int k = 0; k < 200000; k++) tick();
        printf("light banks uploaded through command 6 (%zu words)\n", w);
        dlist = real;
    }

    printf("\nrunning one frame through m1_raster3d...\n");
    d->frame_start = 1; tick(); d->frame_start = 0;

    // Capture each band the moment it becomes displayable. In hardware the beam
    // does this; here we sweep the band's rows as soon as disp_band changes.
    // Milestones, because "it is slow" is not a finding and "the geometry is
    // 96% of it" is. dbg_frames rises when the sort completes, which separates
    // the geometry from the band fills.
    long t_sort = 0, t_band[16] = {0};
    // START FROM WHATEVER IS ALREADY PRESENTED, not from -1. The prologue walk
    // leaves disp_band at 11, so a capture loop that begins at -1 sees an
    // immediate "change", records the prologue's empty band 11, and then takes
    // bands 0..10 of the real frame - twelve captures, one of them stale, and
    // the real band 11 never read. That is exactly one band of black at the
    // bottom of the frame and a count that says twelve.
    int last_band = d->disp_valid ? (int)d->disp_band : -1;
    int captured = 0;
    long guard = 0;
    const long LIMIT = 3000000000L;
    while (++guard < LIMIT) {
        tick();
        if (!t_sort && d->dbg_frames) t_sort = cycles;
        if (d->disp_valid && (int)d->disp_band != last_band) {
            if (captured < 16) t_band[captured] = cycles;
            last_band = d->disp_band;
            int y0 = last_band * BAND_H;
            for (int r = 0; r < BAND_H; r++) {
                int y = y0 + r;
                if (y >= SH) break;
                for (int x = 0; x < SW; x++) {
                    d->scan_x = x; d->scan_y = y;
                    tick();
                    if (d->scan_hit) {
                        fb[y][x][0] = (d->scan_rgb >> 16) & 0xff;
                        fb[y][x][1] = (d->scan_rgb >> 8) & 0xff;
                        fb[y][x][2] = d->scan_rgb & 0xff;
                    }
                    got_row[y] = true;
                }
            }
            captured++;
            if (captured >= (SH + BAND_H - 1) / BAND_H) break;
        }
    }

    // The C++-orchestrated render prints xc=248 yc=191 zoom 210,280 view 0,-30
    // from the same list. Any difference here is the RTL's decode of it.
    {
        auto u2f_ = [](uint32_t u){ float f; memcpy(&f,&u,4); return f; };
        printf("view state: xc=%g yc=%g zoom=%g,%g view=%g,%g\n",
               u2f_(d->dbg_xc), u2f_(d->dbg_yc),
               u2f_(d->dbg_zoomx), u2f_(d->dbg_zoomy),
               u2f_(d->dbg_viewx), u2f_(d->dbg_viewy));
    }
    printf("objects %u, quads %u, dropped %u, frames %u\n",
           (unsigned)d->dbg_objects, (unsigned)d->dbg_quads,
           (unsigned)d->dbg_dropped, (unsigned)d->dbg_frames);
    printf("captured %d bands, simulated %ld cycles = %.1f ms at 47.059 MHz\n",
           captured, cycles, cycles / 47059.0);
    printf("  geometry + sort: %ld cycles (%.0f%% of the run)\n",
           t_sort, 100.0 * t_sort / (cycles ? cycles : 1));
    for (int i = 0; i < captured && i < 6; i++)
        printf("  band %d ready at %ld cycles (+%ld)\n",
               i, t_band[i], t_band[i] - (i ? t_band[i-1] : t_sort));
    if (t_sort)
        printf("  that is %.0f cycles per quad through the geometry\n",
               (double)t_sort / (d->dbg_quads ? d->dbg_quads : 1));
    if (guard >= LIMIT) printf("WARNING: hit the cycle limit before finishing\n");

    long nz = 0, rows = 0;
    for (int y = 0; y < SH; y++) { if (got_row[y]) rows++;
        for (int x = 0; x < SW; x++) if (fb[y][x][0] | fb[y][x][1] | fb[y][x][2]) nz++; }
    printf("%ld of %d pixels painted (%.1f%%), %ld of %d rows scanned\n",
           nz, SW * SH, 100.0 * nz / (SW * SH), rows, SH);

    system("mkdir -p build/render");
    FILE* out = fopen("build/render/frame3d.ppm", "wb");
    if (!out) { printf("cannot write build/render/frame3d.ppm\n"); return 1; }
    fprintf(out, "P6\n%d %d\n255\n", SW, SH);
    fwrite(fb, 1, sizeof fb, out);
    fclose(out);
    printf("wrote build/render/frame3d.ppm\n");
    return (captured > 0 && nz > 0) ? 0 : 1;
}
