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
#include "Vm1_raster3d___024root.h"
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

static float u2f(uint32_t u){ float f; memcpy(&f,&u,4); return f; }
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
    // THE TWO CLOCKS ARE NOT THE SAME RATE, and modelling them as one made the
    // renderer look three times slower than it is.
    //
    // clk_3d is 47.059 MHz; the pixel clock is 656 x 424 x 57.52 = 15.996 MHz.
    // So the fill gets 2.94 cycles per pixel of raster, not one. A bench that
    // ticks both together hands it a third of its real budget and reports bands
    // missed that the hardware makes comfortably - which is exactly what this
    // one did.
    // THE POLYGON ROM CAN BE MADE SLOW. On the board it is SDRAM shared with
    // the V60, the tile fetch and the coprocessor; here it answers in a cycle.
    // ROM_LAT=<n> makes every word cost n extra cycles, which is how a pass is
    // pushed past one frame to exercise the producer's cadence - the case the
    // board is in and this bench, at one word a cycle, never reaches.
    const int rom_lat = getenv("ROM_LAT") ? atoi(getenv("ROM_LAT")) : 0;
    int rom_wait = 0;
    auto tick = [&](bool pixel_edge) {
        int dreq = d->dl_req, rreq = d->rom_req, treq = d->tex_req;
        uint32_t taddr = d->tex_addr;
        memories();
        cycles++; d->clk = 0; if (pixel_edge) d->scan_clk = 0; d->eval();
        int rvalid = 0;
        if (rreq) {
            if (rom_wait == 0) { rvalid = 1; rom_wait = rom_lat; }
            else               { rom_wait--; }
        }
        d->dl_valid = dreq; d->rom_valid = rvalid;
        // tgp_ram is READ/WRITE: display-list command 4 fills it. Modelling it
        // read-only would have hidden that the module never wrote it at all.
        if (treq && d->tex_we) tgpram[taddr & 0xfffff] = d->tex_wdata;
        d->tex_valid = treq; d->tex_data = tgpram[taddr & 0xfffff];
        memories();
        d->clk = 1; if (pixel_edge) d->scan_clk = 1; d->eval();
    };

    d->rst_n = 0; d->frame_start = 0; d->frame_odd = 0; d->dl_sel = 0;
    d->scan_clk = 0; d->scan_x = 0; d->scan_y = 0; d->dl_valid = 0; d->rom_valid = 0;
    d->tex_valid = 0;
    for (int i = 0; i < 8; i++) tick(true);
    d->rst_n = 1;
    for (int i = 0; i < 8; i++) tick(true);

    // ---- ONE CONTINUOUS RASTER, with frame_start at vblank, exactly as the
    // hardware runs.
    //
    // The 3D layer now waits for the beam before presenting a band, so nothing
    // in it completes unless the beam is moving. Driving it any other way - a
    // burst of cycles, then a capture - models a display that waits for the
    // renderer, and produced a bench that passed at 100.0% while the board
    // showed drifting horizontal stripes.
    //
    // The first frames walk a synthetic list that uploads the light banks and
    // some colour words, because both are FRAME-PERSISTENT state that frame
    // 900's list does not set. Then the real list is swapped in.
    // WHERE THE BAND TIME GOES. The fill is the larger half of the frame - 24
    // bands at 28,000 cycles against a frame of 818,133 - and "the fill is slow"
    // does not say whether it is the span painting, the per-quad setup or the
    // replay of quads that turn out not to be in the band. Those are three
    // different fixes.
    // Two sequencers now: the producer builds geometry into one store while
    // the consumer sweeps bands out of the other, so they are counted apart.
    static const char* PNAME[] = {
        "P_IDLE", "P_WALK", "P_OBJ", "P_OBJW", "P_SORT", "P_SORTW", "P_READY"
    };
    static const char* CNAME[] = {
        "C_IDLE", "C_CLR", "C_CLRW", "C_REPLAY", "C_FILL", "C_FILLW", "C_WAIT"
    };
    static long thist[16], chist[16];
    // WHERE THE FILL'S CYCLES GO. Ben's reading of the board is that the 3D is
    // not keeping up - a band whose fill overruns its slot is skipped, shows
    // the 2D through, and the ones that make it are the bars. So the question
    // is which part of the fill is expensive, and the divider is the obvious
    // suspect at up to eight 16-cycle divides a quad-band.
    static const char* FNAME[] = {
        "IDLE", "CLASSIFY", "FLAT", "START1", "START2", "LOADX",
        "DIVA", "DIVAW", "DIVB", "DIVBW", "DECIDE",
        "FS_ENTER", "FS_MULA", "FS_MULB", "FS_SWAP", "FS_WALK", "FS_END",
        "FINAL", "DONE"
    };
    static long fhist[32];

    const int H_TOTAL = 656, V_TOTAL = 424;
    // Derived, never written down: a band-time quoted as a constant has gone
    // stale three times on this design, once by a factor of the band height and
    // once by dividing the frame by the visible lines instead of the total.
    const int  BAND_H    = 16;
    const int  NBANDS    = (SH + BAND_H - 1) / BAND_H;
    const long CLK3D_HZ  = 47059000;
    const long PIXCLK_HZ = 15996000;     // 656 * 424 * 57.52
    const long BAND_TIME = CLK3D_HZ / 5752 * 100 / NBANDS;
    const uint32_t TEX_BASE = 0x40000 + 0x1234;

    std::vector<uint16_t> pro(0x8000, 0);
    {
        size_t w = 0;
        pro[w++] = 6; pro[w++] = 0;
        pro[w++] = 0; pro[w++] = 0;
        pro[w++] = 256; pro[w++] = 0;
        for (int i = 0; i < 256; i++) {
            const LPB& lp = lpbank[i];
            uint32_t packed = (uint32_t)lroundf(lp.d * 255.0f)
                            | ((uint32_t)lroundf(lp.a * 255.0f) << 8)
                            | ((uint32_t)lroundf(lp.s * 255.0f) << 16)
                            | ((uint32_t)lp.p << 24);
            pro[w++] = packed & 0xffff; pro[w++] = packed >> 16;
        }
        pro[w++] = 4; pro[w++] = 0;
        pro[w++] = TEX_BASE & 0xffff; pro[w++] = TEX_BASE >> 16;
        pro[w++] = 15; pro[w++] = 0;
        for (int i = 0; i < 16; i++) { pro[w++] = (uint16_t)(0xC000 + i * 7); pro[w++] = 0; }
        pro[w++] = 0x0f; pro[w++] = 0;
        printf("prologue list built (%zu words)\n", w);
    }
    std::vector<uint16_t> real_list = dlist;
    dlist = pro;

    // THE GAME FLIPS ITS LIST EVERY SECOND FRAME, by hand, at whatever point
    // in the frame it finishes writing (tools/mame_listctl_rate.lua: 993 of
    // 996 flips exactly two frames apart). The producer starts on that flip,
    // so the bench has to make one. FLIP=<n> flips every n frames, FLIP=0
    // never does and leaves the producer to its frame-pulse fallback - which
    // waits four frames for a flip first, so the prologue is longer there or
    // the light banks and colour words are never uploaded and 6.9% of the
    // picture paints.
    const int flip_every = getenv("FLIP") ? atoi(getenv("FLIP")) : 2;
    const int PROLOGUE_FRAMES = flip_every ? 3 : 7;
    const int TOTAL_FRAMES    = getenv("FRAMES") ? atoi(getenv("FRAMES")) : 14;
    // The producer's cadence, from its state: start (P_IDLE -> P_WALK), ready
    // (-> P_READY), swap (P_READY -> P_IDLE). Printed per pass in frames.
    const long FRAME_CYC = CLK3D_HZ * 100 / 5752;
    int  prev_pst = 0, pass_n = 0, pass_start_frame = 0, pass_ready_frame = 0, pass_start_line = 0;
    long pass_start = 0, pass_ready = 0, last_start = -1;
    int  cadence_hist[16] = {0};
    long hits = 0;
    unsigned bands_prev = 0;
    for (int f = 0; f < TOTAL_FRAMES; f++) {
        if (f == PROLOGUE_FRAMES) {
            dlist = real_list;
            // The colour words must have landed by now, through command 4.
            int bad = 0;
            for (int i = 0; i < 16; i++)
                if (tgpram[(0x1234 + i) & 0xfffff] != (uint16_t)(0xC000 + i * 7)) bad++;
            printf("after %d prologue frames: command 4 wrote %d of 16 colour words\n",
                   PROLOGUE_FRAMES, 16 - bad);
            memset(fb, 0, sizeof fb);
            memset(got_row, 0, sizeof got_row);
            hits = 0;
        }
        long acc = 0;
        // Cleared EVERY frame. Accumulating across frames reported 93.9% for a
        // renderer delivering a third of its bands per frame - the union of
        // three frames is not a frame.
        memset(fb, 0, sizeof fb);
        memset(got_row, 0, sizeof got_row);
        hits = 0;
        for (int y = 0; y < V_TOTAL; y++) {
            for (int x = 0; x < H_TOTAL; x++) {
                // vblank starts at the first non-visible line: one pulse a frame.
                d->frame_start = (y == SH && x == 0) ? 1 : 0;
                if (flip_every && y == SH && x == 0 && (f % flip_every) == 0) d->dl_sel ^= 1;
                d->scan_x = x; d->scan_y = y;
                // 2.94 3D cycles per pixel, carried as a fraction so the ratio
                // is the real one rather than a rounded 3.
                acc += CLK3D_HZ;
                bool first = true;
                while (acc >= PIXCLK_HZ) {
                    acc -= PIXCLK_HZ; tick(first); first = false;
                    // ONE CYCLE, as m1_cdc_pulse delivers it on the board. Held
                    // for the pixel's three ticks it counted three frames a
                    // frame and tripped the producer's no-flip fallback.
                    d->frame_start = 0;
                    thist[d->rootp->m1_raster3d__DOT__pst & 7]++;
                    chist[d->rootp->m1_raster3d__DOT__cst & 7]++;
                    {
                        int pp = d->rootp->m1_raster3d__DOT__pst & 7;
                        if (prev_pst == 0 && pp == 1) {
                            if (last_start >= 0) {
                                int cf = (int)((cycles - last_start + FRAME_CYC / 2) / FRAME_CYC);
                                cadence_hist[cf > 15 ? 15 : cf]++;
                            }
                            last_start = cycles;
                            pass_start = cycles; pass_start_frame = f; pass_start_line = y;
                        }
                        if (prev_pst != 6 && pp == 6) {
                            pass_ready = cycles; pass_ready_frame = f; pass_n++;
                        }
                        if (prev_pst == 6 && pp == 0) {
                            printf("  pass %2d: started frame %2d line %3d, ready after %.2f frames (frame %2d), swapped frame %2d\n",
                                   pass_n, pass_start_frame, pass_start_line,
                                   (double)(pass_ready - pass_start) / FRAME_CYC,
                                   pass_ready_frame, f);
                        }
                        prev_pst = pp;
                    }
                    fhist[d->rootp->m1_raster3d__DOT__u_fill__DOT__state & 31]++;
                }
                if (x < SW && y < SH && d->scan_hit) {
                    fb[y][x][0] = (d->scan_rgb >> 16) & 0xff;
                    fb[y][x][1] = (d->scan_rgb >> 8) & 0xff;
                    fb[y][x][2] = d->scan_rgb & 0xff;
                    got_row[y] = true;
                    hits++;
                }
            }
        }
        long fr_rows = 0;
        for (int y = 0; y < SH; y++) if (got_row[y]) fr_rows++;
        unsigned bands_now = d->dbg_bands;
        unsigned bands_this = bands_now - bands_prev;
        bands_prev = bands_now;
        if (f >= PROLOGUE_FRAMES)
            printf("  frame %2d: %6ld px, %3ld of %d rows, bands %2u of %u,"
                   " last fill %u of %ld\n",
                   f, hits, fr_rows, SH, bands_this, NBANDS,
                   (unsigned)d->dbg_band_cycles, BAND_TIME);
    }
    int frames_swept = TOTAL_FRAMES;

    {
        long tot = 0;
        for (int i = 0; i < 7; i++) tot += thist[i];
        printf("the producer, by state:\n");
        for (int i = 0; i < 7; i++)
            if (thist[i] > tot / 200)
                printf("  %-10s %9ld  %5.1f%%\n", PNAME[i], thist[i],
                       100.0 * thist[i] / tot);
        printf("the consumer, by state:\n");
        for (int i = 0; i < 7; i++)
            if (chist[i] > tot / 200)
                printf("  %-10s %9ld  %5.1f%%\n", CNAME[i], chist[i],
                       100.0 * chist[i] / tot);
    }
    {
        long tot = 0;
        for (int i = 1; i < 19; i++) tot += fhist[i];
        printf("the fill unit, by state (%ld busy cycles):\n", tot);
        for (int i = 1; i < 19; i++)
            if (fhist[i] * 200 > tot)
                printf("  %-9s %9ld  %5.1f%%\n", FNAME[i], fhist[i],
                       100.0 * fhist[i] / tot);
    }
    printf("producer cadence, start-to-start in frames:");
    for (int i = 0; i < 16; i++) if (cadence_hist[i]) printf(" %d:%d", i, cadence_hist[i]);
    printf("\n");
    printf("objects %u, quads %u, dropped %u, frames %u\n",
           (unsigned)d->dbg_objects, (unsigned)d->dbg_quads,
           (unsigned)d->dbg_dropped, (unsigned)d->dbg_frames);
    printf("swept %d frames, simulated %ld cycles = %.1f ms at 47.059 MHz\n",
           frames_swept, cycles, cycles / 47059.0);

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
    return (nz > 0) ? 0 : 1;
}
