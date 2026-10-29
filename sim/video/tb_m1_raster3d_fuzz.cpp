// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The 3D layer fed GARBAGE, then reset, then asked for a known frame.
//
// Two properties, and nothing else checks either of them:
//
//   1. NO DISPLAY LIST CAN WEDGE THE 3D LAYER. The game builds the list, but
//      a list read while it is being rewritten, a list run past its end, or a
//      list scribbled on by a runaway copy is still something this module has
//      to walk to the end and come back from. MAME walks the same garbage with
//      host floats and unbounded arrays and never stops; an RTL pipeline that
//      waits on a stage which never answers stops for ever. Model 2's core lost
//      its whole display-list walk to one NaN that way.
//
//   2. THE GAME RESET RECOVERS EVERYTHING. After any garbage, a reset (the
//      OSD's RESTART: rst_n low, the memory reset left alone) followed by the
//      real list must give the same picture, hash for hash, as a cold start.
//      Board report: after the freeze the 3D never returns, and RESTART does
//      not bring it back.
//
// It also counts colour uploads (display-list command 4) that land outside
// tgp_ram's 786,432 words. On the board that port reaches SDRAM, the region
// above tgp_ram holds the I/O board's firmware and EEPROM image, and nothing
// reloads either short of a new MRA load.
//
//   make render3d_fuzz [FUZZ_EPISODES=n] [FUZZ_SEED=s]
//
// Episode kinds, in rotation:
//   0  every word random
//   1  well-formed commands carrying hostile values: NaN, infinities,
//      denormals, 1e38, wild addresses and lengths
//   2  the real list with a few hundred words flipped
//   3  the real list, its terminator removed and the rest of the buffer random
//
// Prints one line per episode and PASS/FAIL at the end; the exit code is the
// verdict.

#include "Vm1_raster3d.h"
#include "Vm1_raster3d___024root.h"
#include "verilated.h"
#include "../mem/ddr3_model.h"
// The base RTL (before 2026-10-28) has no dbg_tex_drop; build it with
// -CFLAGS -DNO_TEX_DROP to measure where its colour uploads went.
#ifdef NO_TEX_DROP
#define TEX_DROP(d) 0u
#else
#define TEX_DROP(d) ((d)->dbg_tex_drop)
#endif
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <random>
#include <string>

static const int SW = 496, SH = 384;
static const int H_TOTAL = 656, V_TOTAL = 424;
static const long CLK3D_HZ = 58947368, PIXCLK_HZ = 15996000;
static const uint32_t TGPRAM_WORDS = 0xC0000;   // MAME: 0x100000 - 0x40000

static std::vector<uint16_t> dlist, palette, xlat, tgpram, tgpram_snap;
// The two display-list buffers. Every mode but the torn-list one keeps both
// equal to `dlist`; that mode lets the "game" rewrite the buffer it flipped
// away from while the walker may still be reading it.
static std::vector<uint16_t> dlbuf[2];
static bool torn_mode = false;
static std::vector<uint32_t> prom;
static uint8_t fb[SH][SW][3];

static Vm1_raster3d* d;
static Ddr3Model<Vm1_raster3d> ddr;
static long cycles = 0;
static long tex_escapes = 0, tex_writes = 0;
// Of the escapes, those landing on the I/O board's firmware (SDRAM word
// 0xD00000, tgp_ram offset 0xE0000) or its EEPROM image 16 KB above it.
static long tex_iofw = 0, tex_eeprom = 0;
static uint32_t tex_escape_first = 0;
static std::mt19937 rng;

static bool load(const char* path, std::vector<uint16_t>& v, size_t words) {
    FILE* f = fopen(path, "rb");
    if (!f) { printf("cannot open %s\n", path); return false; }
    v.assign(words, 0);
    size_t n = fread(v.data(), 2, words, f);
    fclose(f);
    printf("  %-40s %zu words\n", path, n);
    return true;
}

static uint32_t rom_word(uint32_t a) {
    if (a < prom.size()) return prom[a];
    // Past the polygon region the board reads whatever SDRAM holds there:
    // tgp_ram, the I/O firmware, the sound samples. Not zero, not constant.
    uint32_t h = a * 2654435761u; h ^= h >> 15; h *= 2246822519u; h ^= h >> 13;
    return h;
}

static void memories() {
    d->dl_data   = torn_mode ? dlbuf[d->dl_sel_q & 1][d->dl_addr & 0x7fff]
                             : dlist[d->dl_addr & 0x7fff];
    d->rom_data  = rom_word(d->rom_addr);
    d->tex_data  = tgpram[d->tex_addr & 0xfffff];
    d->pal_data  = palette[d->pal_addr & 0x1fff];
    d->xlat_data = xlat[d->xlat_addr & 0x7fff];
}

static int rom_lat = 0, rom_wait = 0;

// The game's writer, for the torn-list mode: after each flip it writes the
// next list into the buffer it flipped away from, one word every WR_EVERY
// clk_3d cycles (the V60 at ~29 MHz storing a word every few instructions).
static std::vector<std::vector<uint16_t>> torn_lists;
static int  wr_buf = -1, wr_list = 0, wr_every = 40, wr_tick = 0;
static size_t wr_pos = 0, wr_len = 0;
static long torn_ahead = 0, torn_any = 0;
static size_t list_len(const std::vector<uint16_t>& l) {
    for (size_t i = 0; i + 1 < l.size(); i += 2) if (l[i] == 0x0f && l[i+1] == 0) return i + 2;
    return l.size();
}
static void writer_step() {
    if (wr_buf < 0 || wr_pos >= wr_len) return;
    if (++wr_tick < wr_every) return;
    wr_tick = 0;
    const std::vector<uint16_t>& src = torn_lists[wr_list];
    if (d->rootp->m1_raster3d__DOT__u_walk__DOT__st != 0 && (d->dl_sel_q & 1) == wr_buf) {
        torn_any++;
        if (wr_pos >= d->rootp->m1_raster3d__DOT__u_walk__DOT__cur) torn_ahead++;
    }
    dlbuf[wr_buf][wr_pos] = src[wr_pos];
    wr_pos++;
}
static void tick(bool pixel_edge) {
    int rreq = d->rom_req, treq = d->tex_req;
    uint32_t taddr = d->tex_addr;
    memories();
    cycles++; d->clk = 0; if (pixel_edge) d->scan_clk = 0; d->eval();
    int rvalid = 0;
    if (rreq) {
        if (rom_wait == 0) { rvalid = 1; rom_wait = rom_lat; }
        else               { rom_wait--; }
    }
    d->dl_valid = d->dl_req; d->rom_valid = rvalid;
    if (treq && d->tex_we) {
        tex_writes++;
        if (taddr >= TGPRAM_WORDS) {
            if (tex_escapes++ == 0) tex_escape_first = taddr;
            if (taddr >= 0xE0000 && taddr < 0xE2000) tex_iofw++;
            if (taddr >= 0xE2000 && taddr < 0xE2040) tex_eeprom++;
        }
        tgpram[taddr & 0xfffff] = d->tex_wdata;
    }
    d->tex_valid = treq; d->tex_data = tgpram[taddr & 0xfffff];
    if (torn_mode) writer_step();
    memories();
    ddr.pre();
    d->clk = 1; if (pixel_edge) d->scan_clk = 1; d->eval();
    ddr.post();
}

// One raster frame, frame_start at vblank, the list flipped every second frame
// as the game does. Returns a hash of the scanned-out 3D picture.
static int frame_no = 0;
static uint64_t run_frame() {
    long acc = 0;
    memset(fb, 0, sizeof fb);
    for (int y = 0; y < V_TOTAL; y++) {
        for (int x = 0; x < H_TOTAL; x++) {
            d->frame_start = (y == SH && x == 0) ? 1 : 0;
            if (y == SH && x == 0 && (torn_mode || (frame_no % 2) == 0)) {
                d->dl_sel ^= 1;
                if (torn_mode) {
                    // The buffer just flipped away from is the game's again.
                    wr_buf  = (d->dl_sel ^ 1) & 1;
                    wr_list = (wr_list + 1) % (int)torn_lists.size();
                    wr_pos  = 0; wr_len = list_len(torn_lists[wr_list]); wr_tick = 0;
                }
            }
            d->scan_x = x; d->scan_y = y;
            acc += CLK3D_HZ;
            bool first = true;
            while (acc >= PIXCLK_HZ) {
                acc -= PIXCLK_HZ; tick(first); first = false;
                d->frame_start = 0;
            }
            if (x < SW && y < SH && d->scan_hit) {
                fb[y][x][0] = (d->scan_rgb >> 16) & 0xff;
                fb[y][x][1] = (d->scan_rgb >> 8) & 0xff;
                fb[y][x][2] = d->scan_rgb & 0xff;
            }
        }
    }
    frame_no++;
    uint64_t h = 1469598103934665603ull;
    const uint8_t* p = &fb[0][0][0];
    for (size_t i = 0; i < sizeof fb; i++) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}

static void reset_game(int n) {
    // RESTART: the game reset only. mem_rst_n (PLL lock) stays high, so the
    // DDR3 client keeps running and is FLUSHED, as on the board.
    d->rst_n = 0;
    for (int i = 0; i < n; i++) tick(true);
    d->rst_n = 1;
    for (int i = 0; i < 8; i++) tick(true);
}

// ---------------------------------------------------------------- garbage
static uint32_t hostile_float() {
    static const uint32_t pool[] = {
        0x7fc00000u, 0xffc00000u, 0x7f800001u, 0x7fbfffffu,   // NaNs
        0x7f800000u, 0xff800000u,                             // infinities
        0x00000000u, 0x80000000u,                             // zeros
        0x00000001u, 0x007fffffu, 0x80000001u, 0x807fffffu,   // denormals
        0x7f7fffffu, 0xff7fffffu, 0x00800000u, 0x80800000u,   // extremes
        0x7e967699u, 0x0da24260u,                             // 1e38, 1e-30
    };
    switch (rng() % 4) {
    case 0: return pool[rng() % (sizeof pool / sizeof pool[0])];
    case 1: return rng();                                     // any bit pattern
    case 2: { float f = (float)((int)(rng() % 4001) - 2000) / 7.0f;
              uint32_t u; memcpy(&u, &f, 4); return u; }
    default: { float f = ldexpf((float)(rng() % 1000) / 1000.0f,
                                (int)(rng() % 200) - 100);
               if (rng() & 1) f = -f; uint32_t u; memcpy(&u, &f, 4); return u; }
    }
}
static uint32_t hostile_int() {
    switch (rng() % 5) {
    case 0: return rng();
    case 1: return rng() & 0xffff;
    case 2: return 0xffffffffu - (rng() % 4);
    case 3: return rng() % 64;
    default: return 0x40000u + (rng() & 0xfffff);
    }
}

static void put32(std::vector<uint16_t>& l, size_t& w, uint32_t v) {
    if (w + 1 < l.size()) { l[w] = v & 0xffff; l[w+1] = v >> 16; }
    w += 2;
}

static std::vector<uint16_t> garbage_list(int kind, const std::vector<uint16_t>& real) {
    std::vector<uint16_t> l(0x8000, 0);
    if (kind == 0) {
        for (auto& v : l) v = rng();
        return l;
    }
    if (kind == 2) {
        l = real;
        int n = 1 + rng() % 400;
        for (int i = 0; i < n; i++) l[rng() % 0x8000] = rng();
        return l;
    }
    if (kind == 3) {
        l = real;
        // find the terminator and remove it, and fill the rest with noise
        for (size_t i = 0; i + 1 < l.size(); i += 2)
            if (l[i] == 0x0f && l[i+1] == 0) {
                for (size_t j = i; j < l.size(); j++) l[j] = rng();
                break;
            }
        return l;
    }
    // kind 1: well-formed commands with hostile values
    size_t w = 0;
    while (w + 40 < l.size()) {
        static const int types[] = {0, 1, 1, 1, 0x41, 2, 3, 4, 5, 6, 7, 8, 9, 0xa, 0xb, 0xc};
        int t = types[rng() % 16];
        put32(l, w, t);
        switch (t) {
        case 0: break;
        case 1: case 0x41:
            put32(l, w, hostile_int());                       // tex address
            // poly address: mostly in the ROM, sometimes anywhere, bit 23 too
            put32(l, w, (rng() % 3) ? (rng() % 0x400000) : rng());
            put32(l, w, hostile_float());                     // size
            break;
        case 2: {                                             // direct polys
            for (int i = 0; i < 9; i++) put32(l, w, hostile_float());
            int n = rng() % 6;
            for (int k = 0; k < n; k++) for (int i = 0; i < 10; i++) put32(l, w, (i == 0) ? (rng() % 4) : hostile_float());
            put32(l, w, 0); put32(l, w, 0);
            break;
        }
        case 3:
            put32(l, w, hostile_int());
            for (int i = 0; i < 6; i++) put32(l, w, rng());    // int16 each
            break;
        case 4: case 5: case 6: {
            put32(l, w, hostile_int());                       // address
            uint32_t len = (rng() % 4) ? (rng() % 64) : hostile_int();
            put32(l, w, len);
            uint32_t items = (len & 0xffff) + (t == 4 ? 1 : 0);
            for (uint32_t i = 0; i < items && w + 40 < l.size(); i++) put32(l, w, rng());
            break;
        }
        case 7: case 8: put32(l, w, rng()); break;
        case 9: case 0xc: put32(l, w, hostile_float()); put32(l, w, hostile_float()); break;
        case 0xa: for (int i = 0; i < 3; i++) put32(l, w, hostile_float()); break;
        case 0xb: for (int i = 0; i < 12; i++) put32(l, w, hostile_float()); break;
        }
        if (rng() % 300 == 0) break;
    }
    if (rng() % 4) { size_t ww = w; put32(l, ww, 0x0f); }   // usually terminated
    return l;
}

// ---------------------------------------------------------------- probes
static unsigned st_pst() { return d->rootp->m1_raster3d__DOT__pst & 7; }
static unsigned st_cst() { return d->rootp->m1_raster3d__DOT__cst & 7; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* dir  = getenv("FUZZ_DUMP") ? getenv("FUZZ_DUMP") : "build/framedump/framedump";
    const char* romp = "build/rom/vr_stream.bin";
    const int EPISODES = getenv("FUZZ_EPISODES") ? atoi(getenv("FUZZ_EPISODES")) : 40;
    const unsigned SEED = getenv("FUZZ_SEED") ? atoi(getenv("FUZZ_SEED")) : 1;
    const int GARBAGE_FRAMES = getenv("FUZZ_GFRAMES") ? atoi(getenv("FUZZ_GFRAMES")) : 4;
    rom_lat = getenv("ROM_LAT") ? atoi(getenv("ROM_LAT")) : 0;
    rng.seed(SEED);
    char p[512];

    printf("tb_m1_raster3d_fuzz: seed %u, %d episodes\n", SEED, EPISODES);
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
      fclose(f); }
    std::vector<uint32_t> lp(256, 0);
    snprintf(p, sizeof p, "%s/lightparams.txt", dir);
    { FILE* f = fopen(p, "r"); if (!f) { printf("cannot open %s\n", p); return 1; }
      int i, dd, aa, ss, pp;
      while (fscanf(f, "%d %d %d %d %d", &i, &dd, &aa, &ss, &pp) == 5)
        if (i >= 0 && i < 256) lp[i] = dd | (aa << 8) | (ss << 16) | ((uint32_t)pp << 24);
      fclose(f); }
    { FILE* f = fopen(romp, "rb"); if (!f) { printf("cannot open %s\n", romp); return 1; }
      prom.assign(0x400000, 0); fseek(f, 0x840000, SEEK_SET);
      size_t n = fread(prom.data(), 4, prom.size(), f); fclose(f);
      printf("  %-40s %zu words of models\n", romp, n); }
    tgpram_snap = tgpram;

    // The light banks are frame-persistent state uploaded by command 6; the
    // captured list does not carry them, so a prologue list does, as the game
    // does at the start of a scene.
    std::vector<uint16_t> pro(0x8000, 0);
    { size_t w = 0;
      put32(pro, w, 6); put32(pro, w, 0); put32(pro, w, 256);
      for (int i = 0; i < 256; i++) put32(pro, w, lp[i]);
      put32(pro, w, 0x0f); }
    const std::vector<uint16_t> real = dlist;

    d = new Vm1_raster3d;
    ddr.d = d;
    ddr.latency  = getenv("DDR_LAT")  ? atol(getenv("DDR_LAT"))  : 40;
    ddr.busy_pct = getenv("DDR_BUSY") ? atoi(getenv("DDR_BUSY")) : 0;

    // fb_go is "the ROM is loaded" (render3d sets it the same way). Left at 0
    // the frame buffer never starts, nothing is scanned out, and every hash is
    // the empty picture's - which is how this bench passed vacuously once the
    // 3D moved into DDR3 (findings 2026-10-29, test-all).
    d->fb_go = 1;
    d->mem_rst_n = 0; d->DDRAM_BUSY = 0; d->DDRAM_DOUT_READY = 0; d->DDRAM_DOUT = 0;
    d->rst_n = 0; d->frame_start = 0; d->frame_odd = 0; d->dl_sel = 0;
    d->scan_clk = 0; d->scan_x = 0; d->scan_y = 0; d->dl_valid = 0; d->rom_valid = 0;
    d->tex_valid = 0;
    for (int i = 0; i < 8; i++) tick(true);
    d->mem_rst_n = 1;
    d->rst_n = 1;
    for (int i = 0; i < 8; i++) tick(true);

    // The known frame: prologue, then the real list until the picture holds
    // still. That hash is what every recovery must reproduce.
    const int PRO_FRAMES = 3, REAL_FRAMES = 5;
    auto known_frame = [&](uint64_t* last2) -> uint64_t {
        dlist = pro;
        for (int i = 0; i < PRO_FRAMES; i++) run_frame();
        dlist = real;
        uint64_t h = 0, prev = 0;
        for (int i = 0; i < REAL_FRAMES; i++) { prev = h; h = run_frame(); }
        if (last2) *last2 = prev;
        return h;
    };
    // ---- TORN=n: the game rewriting the list the walker is still reading.
    //
    // Flip every frame, and after each flip write the next real list into
    // the buffer just flipped away from, as the game does. Any pass longer
    // than the flip interval then walks a list being rewritten under it.
    if (getenv("TORN")) {
        const int TF = atoi(getenv("TORN"));
        const char* dumps[] = {"build/framedump/frame2500", "build/framedump/frame5460"};
        torn_lists.push_back(real);
        for (const char* dd : dumps) {
            std::vector<uint16_t> l; snprintf(p, sizeof p, "%s/dlist.bin", dd);
            if (!load(p, l, 0x8000)) return 1;
            torn_lists.push_back(l);
        }
        wr_every = getenv("WR_EVERY") ? atoi(getenv("WR_EVERY")) : 40;
        dlist = pro;
        for (int i = 0; i < PRO_FRAMES; i++) run_frame();
        torn_mode = true;
        dlbuf[0] = real; dlbuf[1] = real;
        unsigned bad0 = d->dbg_lw_bad, over0 = d->dbg_lw_over, pass0 = d->dbg_frames;
        unsigned tex0 = TEX_DROP(d);
        for (int i = 0; i < TF; i++) run_frame();
        printf("render3d_fuzz TORN: frames=%d rom_lat=%d wr_every=%d passes=%u "
               "writes into the walked buffer=%ld (ahead of the walker %ld) "
               "walks ended on garbage=%u run off the buffer=%u colour uploads dropped=%u \n",
               TF, rom_lat, wr_every, (unsigned)(uint16_t)(d->dbg_frames - pass0),
               torn_any, torn_ahead,
               (unsigned)(uint16_t)(d->dbg_lw_bad - bad0), (unsigned)(uint16_t)(d->dbg_lw_over - over0),
               (unsigned)(uint16_t)(TEX_DROP(d) - tex0));
        return 0;
    }

    uint64_t golden_prev = 0;
    uint64_t golden = known_frame(nullptr);
    golden_prev = run_frame();     // one more frame of the same list: must not move
    long nz = 0;
    for (int y = 0; y < SH; y++) for (int x = 0; x < SW; x++)
        if (fb[y][x][0] | fb[y][x][1] | fb[y][x][2]) nz++;
    printf("cold start: frame hash %016llx (previous %016llx), %ld pixels painted, passes %u\n",
           (unsigned long long)golden, (unsigned long long)golden_prev, nz,
           (unsigned)d->dbg_frames);
    if (golden != golden_prev || nz < 1000) {
        printf("FAIL: the known frame is not stable or not drawn\n");
        return 1;
    }

    int wedges = 0, unrecovered_noreset = 0, unrecovered_reset = 0;
    unsigned long tex_dropped_total = 0;
    long esc_total = 0;
    for (int e = 0; e < EPISODES; e++) {
        int kind = e % 4;
        dlist = garbage_list(kind, real);
        long esc0 = tex_escapes;

        // ---- the garbage itself. Progress = completed passes.
        unsigned passes0 = d->dbg_frames, bands0 = d->dbg_bands;
        for (int i = 0; i < GARBAGE_FRAMES; i++) run_frame();
        unsigned g_passes = (unsigned)(uint16_t)(d->dbg_frames - passes0);
        unsigned g_bands  = (unsigned)(uint16_t)(d->dbg_bands - bands0);
        unsigned pst_g = st_pst(), cst_g = st_cst();
        unsigned tex_drop_g = TEX_DROP(d);   // cleared by the reset below
        bool wedged = (g_passes == 0);
        if (wedged) wedges++;

        // ---- the real list again, no reset: does it come back by itself?
        dlist = real;
        tgpram = tgpram_snap;
        unsigned passes1 = d->dbg_frames;
        for (int i = 0; i < 4; i++) run_frame();
        unsigned r_passes = (unsigned)(uint16_t)(d->dbg_frames - passes1);
        if (r_passes == 0) unrecovered_noreset++;

        // ---- RESTART, then the known frame
        reset_game(64);
        tgpram = tgpram_snap;
        uint64_t h = known_frame(nullptr);
        bool ok = (h == golden);
        if (!ok) unrecovered_reset++;
        long esc = tex_escapes - esc0;
        tex_dropped_total += tex_drop_g;
        esc_total += esc;

        printf("episode %3d kind %d: garbage passes %u bands %u (pst %u cst %u)%s | "
               "unreset passes %u%s | after RESTART %s | tex escapes %ld\n",
               e, kind, g_passes, g_bands, pst_g, cst_g, wedged ? " WEDGED" : "",
               r_passes, r_passes ? "" : " STUCK",
               ok ? "identical" : "DIFFERENT", esc);
        fflush(stdout);
    }

    printf("render3d_fuzz: episodes=%d wedged=%d stuck_without_reset=%d "
           "unrecovered_after_reset=%d tex_escapes=%ld (first at word %05x; onto the I/O firmware %ld, its EEPROM image %ld) "
           "tex_dropped=%u ddr3_protocol_errors=%ld\n",
           EPISODES, wedges, unrecovered_noreset, unrecovered_reset, esc_total,
           tex_escape_first, tex_iofw, tex_eeprom, (unsigned)tex_dropped_total, ddr.protocol_errs);
    bool pass = (unrecovered_reset == 0) && (unrecovered_noreset == 0) &&
                (esc_total == 0) && (ddr.protocol_errs == 0);
    printf("%s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
