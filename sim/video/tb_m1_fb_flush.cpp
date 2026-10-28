// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// m1_fb_flush through m2_ddr3 against the hostile DDR3 model. A band buffer
// (modelled here: four banks, one registered read of a group of four pixels,
// a clear-behind write port) is filled with random words, painted and not;
// the flush copies it into DDR3; then every word of the band's eight lines in
// the right frame is checked against the buffer, the words of every OTHER line
// and frame are checked untouched (0xFFFF..., the model's unwritten value),
// and the buffer must come back all zero - each group cleared exactly once,
// and only after it was read.
#include "Vfb_flush_chain.h"
#include "verilated.h"
#include "../mem/ddr3_model.h"
#include <cstdio>
#include <cstdlib>
#include <random>
#include <cstring>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfb_flush_chain* d = new Vfb_flush_chain;
    std::mt19937 rng(0xf175);
    long checks = 0, fails = 0, cycles_total = 0, bands = 0;
    struct Cfg { long lat; int busy; int hold; };
    Cfg cfgs[] = { {10, 0, 0}, {40, 0, 0}, {40, 300, 20}, {200, 600, 40}, {1000, 900, 60} };
    for (const Cfg& c : cfgs) {
        Ddr3Model<Vfb_flush_chain> ddr; ddr.d = d;
        ddr.latency = c.lat; ddr.busy_pct = c.busy; ddr.hold_pct = c.hold;
        d->rst_n = 0; d->clk = 0; d->start = 0; d->DDRAM_BUSY = 0; d->DDRAM_DOUT_READY = 0;
        for (int i = 0; i < 4; i++) { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
        d->rst_n = 1;
        long cfg_cycles = 0;
        for (int run = 0; run < 6; run++) {
            int band = rng() % 48, sel = rng() % 2;
            // the band buffer: 8 rows x 124 groups x 4 pixels of 17 bits
            static uint32_t tile[8][124][4]; static int cleared[8][124], read_[8][124];
            for (int r = 0; r < 8; r++) for (int g = 0; g < 124; g++) {
                for (int k = 0; k < 4; k++) tile[r][g][k] = (rng() % 3) ? (0x10000 | (rng() & 0xffff)) : (rng() & 0xffff);
                cleared[r][g] = 0; read_[r][g] = 0;
            }
            uint32_t orig[8][124][4]; memcpy(orig, tile, sizeof orig);
            d->fb_sel = sel; d->band = band; d->start = 1;
            long cyc = 0; bool started = false;
            while (cyc < 2000000) {
                d->clk = 0; d->eval();
                ddr.pre();
                // read port sampled at the edge: data next cycle
                int rr = d->rd_row, rg = d->rd_x >> 2;
                bool wc = d->wc_en; int wr = d->wc_row, wg = d->wc_x >> 2;
                d->clk = 1; d->eval();
                ddr.post();
                // the edge: clear-behind write, then the read register
                if (wc) {
                    if (!read_[wr][wg]) { if (fails++ < 10) printf("cleared before read r%d g%d\n", wr, wg); }
                    cleared[wr][wg]++;
                    for (int k = 0; k < 4; k++) tile[wr][wg][k] = 0;
                }
                if (rr < 8 && rg < 124) {
                    // old data read on this edge (the write and the read are never the same group)
                    __uint128_t q = 0;
                    for (int k = 0; k < 4; k++) q |= (__uint128_t)(tile[rr][rg][k] & 0x1ffff) << (17 * k);
                    d->rd_q4[0] = (uint32_t)q; d->rd_q4[1] = (uint32_t)(q >> 32); d->rd_q4[2] = (uint32_t)(q >> 64) & 0xf;
                    read_[rr][rg] = 1;
                }
                if (started) d->start = 0;
                started = true;
                cyc++;
                if (!d->start && !d->busy && cyc > 4) break;
            }
            cfg_cycles += cyc; bands++;
            d->start = 0;
            for (int i = 0; i < c.lat + 50; i++) { d->clk = 0; d->eval(); ddr.pre(); d->clk = 1; d->eval(); ddr.post(); }
            // DDR3 contents
            for (int r = 0; r < 8; r++) {
                int line = band * 8 + r;
                // the line: 124 words of four RGB565 pixels, then 8 of painted bits
                for (int b = 0; b < 132; b++) {
                    uint32_t a = 0x06010000u + (uint32_t)(sel * 512 + line) * 256u + b;
                    auto it = ddr.mem.find(a);
                    uint64_t got = it != ddr.mem.end() ? it->second : ~0ull;
                    uint64_t want = 0;
                    if (b < 124) {
                        for (int k = 0; k < 4; k++) want |= (uint64_t)(orig[r][b][k] & 0xffff) << (16 * k);
                    } else {
                        for (int i = 0; i < 64; i++) { int x = 64 * (b - 124) + i;
                            if (x < 496 && ((orig[r][x >> 2][x & 3] >> 16) & 1)) want |= 1ull << i; }
                    }
                    checks++;
                    if (got != want) { if (fails++ < 10) printf("band %d line %d beat %d: got %016llx want %016llx\n",
                                                             band, line, b, (unsigned long long)got, (unsigned long long)want); }
                }
            }
            for (int r = 0; r < 8; r++) for (int g = 0; g < 124; g++) {
                checks++;
                if (cleared[r][g] != 1 || tile[r][g][0] | tile[r][g][1] | tile[r][g][2] | tile[r][g][3]) {
                    if (fails++ < 10) printf("group r%d g%d cleared %d times\n", r, g, cleared[r][g]); }
            }
            // nothing outside the band, in either frame (written only by this band - erase for the next run)
            for (auto it = ddr.mem.begin(); it != ddr.mem.end(); ++it) {
                uint32_t off = it->first - 0x06010000u; int fr = off / (512 * 256), line = (off / 256) % 512;
                checks++;
                if (fr != sel || line / 8 != band || (off % 256) >= 132) { if (fails++ < 10) printf("stray write at %08x\n", it->first); }
            }
            ddr.mem.clear();
        }
        printf("  lat %ld busy %d hold %d: %ld cycles a band, protocol errors %ld\n",
               c.lat, c.busy, c.hold, cfg_cycles / 6, ddr.protocol_errs);
        if (ddr.protocol_errs) fails++;
        cycles_total += cfg_cycles;
    }
    printf("m1_fb_flush: checks=%ld fails=%ld bands=%ld\n", checks, fails, bands);
    return fails ? 1 : 0;
}
