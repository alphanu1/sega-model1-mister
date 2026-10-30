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
#include "../mem/ddr3_model.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <string>
#include <cmath>

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

static const int SW = 496, SH = 384;

static std::vector<uint16_t> dlist, palette, xlat, tgpram;
// SEQ mode: the two display-list buffers, as the game double-buffers them.
static std::vector<uint16_t> dbuf[2];
static bool seq_mode = false;
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
      // swa's polygon region is 12 MB against vr's 16: take what is there,
      // and leave the rest reading as unwritten SDRAM does.
      if (sz <= 0x840000) { printf("  %s has no polygon region\n", romp); return 1; }
      prom.assign(0x400000, 0xffffffffu); fseek(f, 0x840000, SEEK_SET);
      size_t n = fread(prom.data(), 4, prom.size(), f); fclose(f);
      printf("  %-36s %zu words of models\n", romp, n); }

    // POLYGON RAM lives in SDRAM beside tgp_ram (m1_integrated PRAM_BASE), so
    // the tex port writes it and the model port reads it. Modelled as that one
    // memory: a model read in its window returns the two tex words. A dump that
    // carries polyram.bin preloads it - Wing War uploads it only at boot.
    static const uint32_t PRAM_TEX = 0xD0000, PRAM_MODEL = 0x468000, PRAM_WORDS = 0x8000;
    snprintf(p, sizeof p, "%s/polyram.bin", dir);
    { FILE* f = fopen(p, "rb");
      if (f) { uint32_t w, n = 0;
        while (n < PRAM_WORDS && fread(&w, 4, 1, f) == 1) {
          tgpram[PRAM_TEX + 2*n] = w & 0xffff; tgpram[PRAM_TEX + 2*n + 1] = w >> 16; n++; }
        fclose(f); printf("  %-36s %u words\n", p, n); }
      else printf("  %-36s absent, polygon RAM starts empty\n", p); }
    // PRAM_VIA_LIST=1: do not preload the polygon RAM; instead put the dump's
    // polygon RAM in front of the list as one command 5, so the module writes
    // it itself through the tex port - two 16-bit writes a word - before the
    // objects that read it. The picture must equal the preloaded one.
    if (getenv("PRAM_VIA_LIST")) {
        std::vector<uint32_t> pw;
        for (uint32_t i = 0; i < PRAM_WORDS; i++)
            pw.push_back(tgpram[PRAM_TEX + 2*i] | ((uint32_t)tgpram[PRAM_TEX + 2*i + 1] << 16));
        while (!pw.empty() && pw.back() == 0) pw.pop_back();
        for (uint32_t i = 0; i < 2*PRAM_WORDS; i++) tgpram[PRAM_TEX + i] = 0;
        std::vector<uint16_t> l = {5, 0, 0x0000, 0x0080, (uint16_t)pw.size(), 0};
        for (uint32_t w : pw) { l.push_back(w & 0xffff); l.push_back(w >> 16); }
        size_t tail = 0;      // the original list's unused tail must absorb the shift
        for (size_t i = dlist.size(); i > 0 && dlist[i-1] == 0; i--) tail++;
        printf("  PRAM_VIA_LIST: command 5 of %zu words in front of the list (%zu words; tail %zu free)\n",
               pw.size(), l.size(), tail);
        if (tail < l.size()) { printf("  the list would overflow its buffer\n"); return 1; }
        l.insert(l.end(), dlist.begin(), dlist.end() - l.size());
        dlist = l;
    }
    auto model_word = [&](uint32_t a) -> uint32_t {
        if (a >= PRAM_MODEL && a < PRAM_MODEL + PRAM_WORDS) {
            uint32_t k = PRAM_TEX + 2*(a - PRAM_MODEL);
            return tgpram[k] | ((uint32_t)tgpram[k+1] << 16);
        }
        return (a < prom.size()) ? prom[a] : 0;
    };

    Vm1_raster3d* d = new Vm1_raster3d;
    long cycles = 0;
    memset(fb, 0, sizeof fb);
    memset(got_row, 0, sizeof got_row);

    auto memories = [&]() {
        d->dl_data   = seq_mode ? dbuf[d->dl_sel_q & 1][d->dl_addr & 0x7fff] : dlist[d->dl_addr & 0x7fff];
        d->rom_data  = model_word(d->rom_addr);
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
    // THE QUAD PAYLOAD IS IN DDR3 (m1_raster3d PAY_DDR3), so the bench carries
    // a hostile DDR3: DDR_LAT cycles of latency, BUSY started on DDR_BUSY per
    // mille of idle cycles in runs of up to DDR_BUSYMAX, DDR_HOLD % of reply
    // beats withheld. The picture must not change with any of them; only the
    // band timing may.
    Ddr3Model<Vm1_raster3d> ddr; ddr.d = d;
    ddr.latency  = getenv("DDR_LAT")     ? atol(getenv("DDR_LAT"))     : 40;
    ddr.busy_pct = getenv("DDR_BUSY")    ? atoi(getenv("DDR_BUSY"))    : 0;
    ddr.busy_max = getenv("DDR_BUSYMAX") ? atoi(getenv("DDR_BUSYMAX")) : 24;
    ddr.hold_pct = getenv("DDR_HOLD")    ? atoi(getenv("DDR_HOLD"))    : 0;
    printf("DDR3 model: latency %ld, busy %d/1000 (runs to %d), %d%% of beats withheld\n",
           ddr.latency, ddr.busy_pct, ddr.busy_max, ddr.hold_pct);
    // How densely the geometry posts payload writes: the shortest gap between
    // two quads and the most quads in any 1,024-cycle window. The DDR3 client
    // posts them through a 256-deep queue, so this is its margin.
    long q_last = -1, q_min_gap = 1L << 40;
    std::vector<long> q_times;
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
        ddr.pre();
        if (d->rootp->m1_raster3d__DOT__q_valid) {
            if (q_last >= 0 && cycles - q_last < q_min_gap) q_min_gap = cycles - q_last;
            q_last = cycles; q_times.push_back(cycles);
        }
        d->clk = 1; if (pixel_edge) d->scan_clk = 1; d->eval();
        ddr.post();
    };

    d->fb_go = 1;   // the ROM is "loaded" from the start here
    d->mem_rst_n = 0; d->DDRAM_BUSY = 0; d->DDRAM_DOUT_READY = 0; d->DDRAM_DOUT = 0;
    d->rst_n = 0; d->frame_start = 0; d->frame_odd = 0; d->dl_sel = 0;
    d->scan_clk = 0; d->scan_x = 0; d->scan_y = 0; d->dl_valid = 0; d->rom_valid = 0;
    d->tex_valid = 0;
    for (int i = 0; i < 8; i++) tick(true);
    d->mem_rst_n = 1;
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
    // 8 since 2026-09-09 (m1_raster3d BAND_H); the 16 that stood here made
    // every "% of a slot" figure half what it was.
    const int  BAND_H    = 8;
    const int  NBANDS    = (SH + BAND_H - 1) / BAND_H;
    // CLK3D=<Hz>. The board runs clk_3d at 58.947 MHz (rtl/pll.v, 800/13.57);
    // 47.059 is the old PLL output this bench was written for, and still the
    // default so that earlier logs compare. The higher clock gives the fill
    // 25% more cycles per raster line.
    const long CLK3D_HZ  = getenv("CLK3D") ? atol(getenv("CLK3D")) : 47059000;
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
    std::vector<std::string> seq_dirs; size_t seq_i = 0;
    const bool seq_race = getenv("SEQ_RACE") && atoi(getenv("SEQ_RACE"));
    const int  seq_race_line = getenv("SEQ_RACE_LINE") ? atoi(getenv("SEQ_RACE_LINE")) : 346;
    if (getenv("SEQ")) {
        FILE* sf = fopen(getenv("SEQ"), "r");
        char ln[512];
        while (sf && fgets(ln, sizeof ln, sf)) { ln[strcspn(ln, "\r\n")] = 0; if (ln[0]) seq_dirs.push_back(ln); }
        if (sf) fclose(sf);
        seq_mode = !seq_dirs.empty();
        dbuf[0] = dlist; dbuf[1] = dlist;     // the prologue list, until the real ones
        printf("SEQ: %zu lists\n", seq_dirs.size());
    }
    // PUB_BUILD=<lines>: THE GAME'S OWN PUBLISH, as Star Wars does it in the
    // automatic double buffer (listctl bit 2). At PUB_TERM_LINE of every odd
    // frame (default 392: 0.98 of a frame before the flip, as the full system
    // measures it) the hidden buffer is terminated - 000f at word 0x38 - and
    // PUB_BUILD lines later the finished list is published into it. The flips
    // stay on the hardware's schedule whether or not it has been, so a build
    // longer than ~416 lines is still unpublished when it is shown. MAME walks
    // it at the vblank after the flip, which gives the build ~2 frames.
    const int pub_build = getenv("PUB_BUILD") ? atoi(getenv("PUB_BUILD")) : -1;
    const int pub_term_line = getenv("PUB_TERM_LINE") ? atoi(getenv("PUB_TERM_LINE")) : 392;
    long pub_at = -1; int pub_buf = 0;
    if (pub_build >= 0) { seq_mode = true; dbuf[0] = dlist; dbuf[1] = dlist; }
    // FLIP TO SCREEN, per list: from the flip that selects it to the first
    // scanline of the frame that shows it (the publish at line 416 is seen
    // from line 0, 8 lines later). MAME, for a flip at vblank: rendered at the
    // next vblank and shown after it, 1 + 40/424 = 1.094 frames.
    std::vector<long> flip_cyc_q;              // flip times of passes drawn, in order
    long last_flip_cyc = -1, pass_flip_cyc = -1;
    unsigned prev_show = 0; int empty_frames = 0, shown_lists = 0; bool seen_picture = false;
    double lat_sum = 0, lat_max = 0, lat_min = 1e9;
    const int PROLOGUE_FRAMES = flip_every ? 3 : 7;
    const int TOTAL_FRAMES    = getenv("FRAMES") ? atoi(getenv("FRAMES")) : 14;
    // The producer's cadence, from its state: start (P_IDLE -> P_WALK), ready
    // (-> P_READY), swap (P_READY -> P_IDLE). Printed per pass in frames.
    const long FRAME_CYC = CLK3D_HZ * 100 / 5752;
    int  prev_pst = 0, pass_n = 0, pass_start_frame = 0, pass_ready_frame = 0, pass_start_line = 0;
    long pass_start = 0, pass_ready = 0, last_start = -1;
    int  cadence_hist[16] = {0};
    unsigned worst_fill_frame = 0, last_bands_seen = 0;
    std::vector<std::pair<unsigned,int>> obj_list, last_pass_objs;
    int32_t max_coord = 0, min_coord = 0;
    int  prev_cst = 0; long band_cyc = 0, worst_band_cyc = 0; int band_quads = 0, worst_band_quads = 0;
    long band_fh[32] = {0}, worst_fh[32] = {0}, band_cst_cyc[8] = {0}, worst_cst[8] = {0};
    int  worst_band_idx = -1, worst_band_frame = -1;
    long hits = 0;
    unsigned bands_prev = 0;
    double min_slack = 1e9, fr_min_slack = 1e9; int min_slack_band = -1, min_slack_frame = -1;
    long slack_hist[49] = {0};
    for (int f = 0; f < TOTAL_FRAMES; f++) {
        if (f == PROLOGUE_FRAMES) {
            dlist = real_list;
            if (seq_mode) { dbuf[0] = real_list; dbuf[1] = real_list; }
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
                if (flip_every && y == SH && x == 0 && (f % flip_every) == 0) {
                    d->dl_sel ^= 1;
                    last_flip_cyc = cycles;
                    // SEQ=<file of dump directories>: from the prologue on, every
                    // flip shows the next list of a real run in the buffer it
                    // selects, so state carried from list to list (light banks,
                    // the geometry pipeline, the store, the frame buffer) is
                    // exercised the way a running game exercises it.
                    if (seq_mode && !seq_race && f >= PROLOGUE_FRAMES && seq_i < seq_dirs.size()) {
                        char sp2[512];
                        snprintf(sp2, sizeof sp2, "%s/dlist.bin", seq_dirs[seq_i].c_str());
                        std::vector<uint16_t> nl;
                        if (load(sp2, nl, 0x8000)) dbuf[d->dl_sel & 1] = nl;
                        snprintf(sp2, sizeof sp2, "%s/palette.bin", seq_dirs[seq_i].c_str());
                        load(sp2, palette, 0x2000);
                        snprintf(sp2, sizeof sp2, "%s/xlat.bin", seq_dirs[seq_i].c_str());
                        if (load(sp2, xlat, 0x6000)) xlat.resize(0x8000, 0);
                        printf("SEQ frame %d: list %zu (%s) into buffer %d\n", f, seq_i, seq_dirs[seq_i].c_str(), d->dl_sel & 1);
                        seq_i++;
                    }
                }
                // SEQ_RACE=1: the list goes into the buffer NOT shown, at the
                // point in the frame the game writes it - Star Wars (automatic
                // double buffer, listctl bit 2) terminates and rebuilds the hidden
                // buffer about 0.91 of a frame after a flip and finishes it at
                // once (MAME, V60 cycles), 1.09 frames before the flip that shows
                // it. A pass still walking that buffer when it is rewritten reads
                // the new list from wherever it has got to.
                if (seq_mode && seq_race && f >= PROLOGUE_FRAMES && seq_i < seq_dirs.size()
                    && (f % 2) == 1 && y == seq_race_line && x == 0) {
                    char sp2[512];
                    snprintf(sp2, sizeof sp2, "%s/dlist.bin", seq_dirs[seq_i].c_str());
                    std::vector<uint16_t> nl;
                    if (load(sp2, nl, 0x8000)) dbuf[(d->dl_sel & 1) ^ 1] = nl;
                    printf("SEQ frame %d line %d: list %zu written into hidden buffer %d (pass walking %d, pst %d)\n",
                           f, y, seq_i, (d->dl_sel & 1) ^ 1, d->dl_sel_q & 1, d->rootp->m1_raster3d__DOT__pst & 7);
                    seq_i++;
                }
                if (pub_build >= 0 && f >= PROLOGUE_FRAMES && x == 0) {
                    long ln = (long)f * V_TOTAL + y;
                    if ((f % 2) == 1 && y == pub_term_line) {
                        pub_buf = (d->dl_sel & 1) ^ 1;
                        dbuf[pub_buf][0x38] = 0x000f; dbuf[pub_buf][0x39] = 0x0000;
                        pub_at = ln + pub_build;
                    }
                    if (ln == pub_at) { dbuf[pub_buf] = real_list; pub_at = -1; }
                }
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
                    // The WORST band's own breakdown: which fill states, and
                    // how many quads replayed, in the band that took longest.
                    {
                        int cs = d->rootp->m1_raster3d__DOT__cst & 7;
                        if (cs == 1 && prev_cst != 1) {           // C_CLR: a band begins
                            memset(band_fh, 0, sizeof band_fh); band_cyc = 0; band_quads = 0; band_cst_cyc[0]=band_cst_cyc[1]=band_cst_cyc[2]=band_cst_cyc[3]=band_cst_cyc[4]=band_cst_cyc[5]=band_cst_cyc[6]=0;
                        }
                        if (cs != 0 && cs != 6) {                  // filling, not idle/waiting
                            band_cyc++;
                            band_cst_cyc[cs]++;
                            if (cs == 5) band_fh[d->rootp->m1_raster3d__DOT__u_fill__DOT__state & 31]++;
                            if (cs == 4 && prev_cst == 5) band_quads++;   // FILLW -> FILL: a quad done
                        }
                        if (cs == 6 && prev_cst != 6 && band_cyc > worst_band_cyc) {   // C_WAIT: band done
                            worst_band_cyc = band_cyc; worst_band_quads = band_quads;
                            memcpy(worst_fh, band_fh, sizeof band_fh);
                            memcpy(worst_cst, band_cst_cyc, sizeof band_cst_cyc);
                            worst_band_idx = d->rootp->m1_raster3d__DOT__cur_band; worst_band_frame = f;
                        }
                        // BAND SLACK: when a band is handed to the ready slot,
                        // how far the beam still is from its first row, in
                        // lines. Negative is a late band. Band 0's deadline is
                        // the top of the next frame.
                        if (prev_cst == 6 && cs != 6 && f >= PROLOGUE_FRAMES) {
                            int k = d->rootp->m1_raster3d__DOT__cur_band - (cs == 1 ? 1 : 0);
                            if (cs == 0) k = NBANDS - 1;
                            double pos = y + (double)x / H_TOTAL;
                            double sl;
                            if (k == 0) sl = (pos >= SH) ? (V_TOTAL - pos) : -pos;
                            else        sl = k * BAND_H - pos;
                            if (sl < -(double)V_TOTAL / 2) sl += V_TOTAL;   // wrapped
                            if (sl < min_slack) { min_slack = sl; min_slack_band = k; min_slack_frame = f; }
                            if (sl < fr_min_slack) fr_min_slack = sl;
                            int bkt = (int)floor(sl); if (bkt < -8) bkt = -8; if (bkt > 40) bkt = 40;
                            slack_hist[bkt + 8]++;
                        }
                        prev_cst = cs;
                    }
                    if (d->dbg_bands != last_bands_seen) {
                        last_bands_seen = d->dbg_bands;
                        if (d->dbg_band_cycles > worst_fill_frame) worst_fill_frame = d->dbg_band_cycles;
                    }
                    // Quads per OBJECT in the last complete pass, against MAME's
                    // polygon count per object: which objects come out empty.
                    {
                        int pp = d->rootp->m1_raster3d__DOT__pst & 7;
                        if (pp == 1 && prev_pst == 0) { obj_list.clear(); }
                        if (pp == 2 && prev_pst != 2) { obj_list.push_back({(unsigned)d->rootp->m1_raster3d__DOT__obj_poly, 0}); }
                        if (d->rootp->m1_raster3d__DOT__q_valid && !obj_list.empty()) obj_list.back().second++;
                        if (d->rootp->m1_raster3d__DOT__q_valid) {
                            // How wide the stored coordinates need to be, after the clipper.
                            int32_t c[8] = {(int32_t)d->rootp->m1_raster3d__DOT__q_x0, (int32_t)d->rootp->m1_raster3d__DOT__q_y0,
                                            (int32_t)d->rootp->m1_raster3d__DOT__q_x1, (int32_t)d->rootp->m1_raster3d__DOT__q_y1,
                                            (int32_t)d->rootp->m1_raster3d__DOT__q_x2, (int32_t)d->rootp->m1_raster3d__DOT__q_y2,
                                            (int32_t)d->rootp->m1_raster3d__DOT__q_x3, (int32_t)d->rootp->m1_raster3d__DOT__q_y3};
                            for (int k = 0; k < 8; k++) { if (c[k] > max_coord) max_coord = c[k]; if (c[k] < min_coord) min_coord = c[k]; }
                        }
                        if (pp == 6 && prev_pst != 6) { last_pass_objs = obj_list; }
                    }
                    {
                        int pp = d->rootp->m1_raster3d__DOT__pst & 7;
                        if (prev_pst == 0 && pp == 1) {
                            if (last_start >= 0) {
                                int cf = (int)((cycles - last_start + FRAME_CYC / 2) / FRAME_CYC);
                                cadence_hist[cf > 15 ? 15 : cf]++;
                            }
                            last_start = cycles;
                            pass_start = cycles; pass_start_frame = f; pass_start_line = y;
                            pass_flip_cyc = last_flip_cyc;
                        }
                        if (prev_pst != 6 && pp == 6) {
                            pass_ready = cycles; pass_ready_frame = f; pass_n++;
                        }
                        if (prev_pst == 6 && pp == 0) {
                            flip_cyc_q.push_back(pass_flip_cyc);
                            printf("  pass %2d: started frame %2d line %3d, ready after %.2f frames (frame %2d), swapped frame %2d\n",
                                   pass_n, pass_start_frame, pass_start_line,
                                   (double)(pass_ready - pass_start) / FRAME_CYC,
                                   pass_ready_frame, f);
                        }
                        prev_pst = pp;
                    }
                    fhist[d->rootp->m1_raster3d__DOT__u_fill__DOT__state & 31]++;
                    // RACE MARGIN (frame buffer). What a publish that did NOT
                    // wait for the whole frame would have risked: published
                    // at the first publish line after the swap, line y is
                    // fetched FB_LA lines before it is shown; how many lines
                    // before that fetch was the band holding it in DDR3? The
                    // least over a draw is printed; negative means a line
                    // would have been shown before it was drawn.
                    {
                        static long sw_t = -1, pub_t = 0; static double minm = 1e9; static int sw_y = 0;
                        static int busy_prev = 0, pst_p = 0;
                        const double LINE = (double)CLK3D_HZ / (57.52 * V_TOTAL);   // clk_3d cycles a line
                        int pp = d->rootp->m1_raster3d__DOT__pst & 7;
                        if (pst_p == 6 && pp == 0) {           // the swap: a draw begins
                            sw_t = cycles; sw_y = y;
                            int lines_to_pub = (416 - y + V_TOTAL) % V_TOTAL;
                            pub_t = cycles + (long)(lines_to_pub * LINE);
                            minm = 1e9;
                        }
                        pst_p = pp;
                        int fb = d->rootp->m1_raster3d__DOT__fl_busy;
                        if (sw_t >= 0 && busy_prev && !fb) {   // a band's copy is done
                            int k = d->rootp->m1_raster3d__DOT__fl_band;
                            double fetch = pub_t + (8 + 8 * k - 3) * LINE;
                            double m = (fetch - cycles) / LINE;
                            if (m < minm) minm = m;
                            if (k == NBANDS - 1 && f >= PROLOGUE_FRAMES)
                                printf("  draw: swap at line %d, whole %.1f lines later, race margin %.1f lines\n",
                                       sw_y, (cycles - sw_t) / LINE, minm);
                        }
                        busy_prev = fb;
                    }
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
        // DUMPALL=1: every frame's picture, build/render/f<NN>.ppm, so a
        // fault that comes and goes can be told from one that stays.
        if (getenv("DUMPALL")) {
            char nm[64]; snprintf(nm, sizeof nm, "build/render/f%04d.ppm", f);
            system("mkdir -p build/render");
            FILE* o = fopen(nm, "wb");
            if (o) { fprintf(o, "P6\n%d %d\n255\n", SW, SH); fwrite(fb, 1, sizeof fb, o); fclose(o); }
        }
        long fr_rows = 0;
        for (int y = 0; y < SH; y++) if (got_row[y]) fr_rows++;
        unsigned bands_now = d->dbg_bands;
        unsigned bands_this = bands_now - bands_prev;
        bands_prev = bands_now;
        if (f >= PROLOGUE_FRAMES)
            printf("  frame %2d: %6ld px, %3ld of %d rows, bands %2u of %u,"
                   " last fill %u of %ld, worst fill this frame %u (%.0f%% of a slot), late so far %u\n",
                   f, hits, fr_rows, SH, bands_this, NBANDS,
                   (unsigned)d->dbg_band_cycles, BAND_TIME,
                   worst_fill_frame, 100.0 * worst_fill_frame / BAND_TIME,
                   (unsigned)d->dbg_late);
        if (f >= PROLOGUE_FRAMES)
            printf("  frame %2d: least band slack %.2f lines, late0 so far %u\n",
                   f, fr_min_slack, (unsigned)d->dbg_late0);
        // The frame buffer's figures (FB_DDR3): frames shown so far (show_tag),
        // frames held because the draw was not whole (dbg_late0), the last
        // draw's length (dbg_band_cycles), scanout lines landed late (dbg_late).
        if (f >= PROLOGUE_FRAMES)
            printf("  frame %2d: FB shown %u, held %u, last draw %u cycles (%.2f frames), late lines %u\n",
                   f, (unsigned)d->show_tag, (unsigned)d->dbg_late0, (unsigned)d->dbg_band_cycles,
                   (double)d->dbg_band_cycles / (CLK3D_HZ * 100.0 / 5752), (unsigned)d->dbg_late);
        if (f >= PROLOGUE_FRAMES && (unsigned)d->show_tag != prev_show) {
            // show_tag counts publishes (mod 16); the list shown is the oldest
            // drawn one. The publish was at line 416 of this frame.
            unsigned n = ((unsigned)d->show_tag - prev_show) & 15;
            while (n-- && !flip_cyc_q.empty()) {
                long fc = flip_cyc_q.front(); flip_cyc_q.erase(flip_cyc_q.begin());
                if (n == 0 && fc >= 0) {
                    double fr_cyc = CLK3D_HZ * 100.0 / 5752;
                    // the frame's end in cycles is `cycles`; line 0 of the next
                    // frame is where the publish at 416 is first scanned
                    double lat = (double)(cycles - fc) / fr_cyc;
                    if (f >= PROLOGUE_FRAMES + 2) {
                        shown_lists++; lat_sum += lat;
                        if (lat > lat_max) lat_max = lat; if (lat < lat_min) lat_min = lat;
                    }
                    printf("  frame %2d: LIST SHOWN flip->screen %.3f frames\n", f, lat);
                }
            }
            prev_show = (unsigned)d->show_tag;
        }
        // Empty frames once the first picture has been seen: the frames before
        // it are the pipeline filling, not the fault.
        if (hits > 0) seen_picture = true;
        else if (seen_picture) empty_frames++;
        fr_min_slack = 1e9;
        worst_fill_frame = 0;
    }
    printf("LATENCY: %d lists shown, flip->screen mean %.3f min %.3f max %.3f frames; "
           "empty frames %d; walks discarded (relist) %u\n",
           shown_lists, shown_lists ? lat_sum / shown_lists : 0.0, shown_lists ? lat_min : 0.0, lat_max,
           empty_frames, (unsigned)d->rootp->m1_raster3d__DOT__dbg_relist);
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
    printf("the WORST band: band %d of frame %d, %ld cycles (%.0f%% of a slot), %d quads replayed into it\n",
           worst_band_idx, worst_band_frame, worst_band_cyc, 100.0 * worst_band_cyc / BAND_TIME, worst_band_quads);
    printf("  consumer:");
    for (int i = 1; i < 6; i++) printf(" %s %ld", CNAME[i], worst_cst[i]);
    printf("\n  fill unit:");
    for (int i = 1; i < 19; i++) if (worst_fh[i] * 100 > worst_band_cyc) printf(" %s %ld", FNAME[i], worst_fh[i]);
    printf("\n");
    if (getenv("OBJTABLE")) {
        FILE* ot = fopen(getenv("OBJTABLE"), "w");
        for (size_t i = 0; i < last_pass_objs.size(); i++)
            fprintf(ot, "%zu %06x %d\n", i, last_pass_objs[i].first & 0xffffff, last_pass_objs[i].second);
        fclose(ot);
        printf("wrote %s: %zu objects of the last pass\n", getenv("OBJTABLE"), last_pass_objs.size());
    }
    printf("BAND SLACK: least %.2f lines (band %d, frame %d); late %u, late band 0 %u; "
           "clk_3d %ld Hz\n", min_slack, min_slack_band, min_slack_frame,
           (unsigned)d->dbg_late, (unsigned)d->dbg_late0, CLK3D_HZ);
    printf("slack histogram, lines:");
    for (int i = 0; i < 49; i++) if (slack_hist[i]) printf(" %d:%ld", i - 8, slack_hist[i]);
    printf("\n");
    printf("post-clip vertex coordinates: min %d, max %d\n", min_coord, max_coord);
    printf("producer cadence, start-to-start in frames:");
    for (int i = 0; i < 16; i++) if (cadence_hist[i]) printf(" %d:%d", i, cadence_hist[i]);
    printf("\n");
    printf("objects %u, quads %u, dropped %u, frames %u\n",
           (unsigned)d->dbg_objects, (unsigned)d->dbg_quads,
           (unsigned)d->dbg_dropped, (unsigned)d->dbg_frames);
    printf("swept %d frames, simulated %ld cycles = %.1f ms at 47.059 MHz\n",
           frames_swept, cycles, cycles / 47059.0);

    {
        // the densest 1,024-cycle window of payload writes
        long dense = 0; size_t lo = 0;
        for (size_t hi = 0; hi < q_times.size(); hi++) {
            while (q_times[hi] - q_times[lo] >= 1024) lo++;
            if ((long)(hi - lo + 1) > dense) dense = hi - lo + 1;
        }
        printf("DDR3: %ld reads, %ld writes, busy %ld cycles, worst reply wait %u cycles, "
               "writes lost %u, reads refused %u, protocol errors %ld\n",
               ddr.reads, ddr.writes, ddr.busy_cycles, (unsigned)d->dbg_pay_wait,
               (unsigned)d->dbg_pay_ovf, (unsigned)d->dbg_pay_refused, ddr.protocol_errs);
        printf("payload writes: shortest gap %ld cycles, at most %ld in any 1,024 cycles\n",
               q_min_gap, dense);
        if (ddr.protocol_errs || d->dbg_pay_ovf || d->dbg_pay_refused) { printf("FAIL: DDR3 protocol or lost write\n"); return 1; }
    }

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
