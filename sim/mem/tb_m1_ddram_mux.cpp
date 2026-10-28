// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// m1_ddram_mux: two masters of different shapes on one DDRAM port, against
// the hostile DDR3 model (latency, BUSY in runs, withheld reply beats, the
// Avalon checks). Each master writes its own region and reads it back; every
// read must return what THAT master last wrote there (or the model's 0xFFFF..
// for a word never written), every beat must reach the master that asked,
// and the model must see no protocol error - a command changed under BUSY
// is what a careless grant switch would produce.
//
//   A  shaped like m2_ddr3: one transaction at a time - a read burst of 1..248
//      beats waits for its last beat; a write burst of 1..16 beats
//   B  shaped like m1_ddram_payload: two-beat reads, up to 16 in flight, and
//      two-beat writes - and REGISTERED like it: B changes what it presents
//      only after a cycle in which it saw !BUSY, so it raises `want` to be
//      granted at all
#include "Vm1_ddram_mux.h"
#include "verilated.h"
#include "../mem/ddr3_model.h"
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <unordered_map>

struct M { int rd = 0, we = 0; uint32_t addr = 0; int bc = 1; uint64_t din = 0; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vm1_ddram_mux* d = new Vm1_ddram_mux;
    std::mt19937 rng(0x5eed);
    long checks = 0, fails = 0, a_rd_n = 0, b_rd_n = 0, a_wr_n = 0, b_wr_n = 0, stray = 0;
    int cfg_n = 0;
    struct Cfg { long lat; int busy; int hold; int holdb; };
    Cfg cfgs[] = { {10, 0, 0, 0}, {40, 300, 20, 0}, {200, 600, 50, 30}, {1000, 900, 60, 10} };
    for (const Cfg& c : cfgs) {
        Ddr3Model<Vm1_ddram_mux> ddr; ddr.d = d;
        ddr.latency = c.lat; ddr.busy_pct = c.busy; ddr.hold_pct = c.hold; ddr.busy_max = 24;
        ddr.seed = 777 + cfg_n++;
        std::unordered_map<uint32_t, uint64_t> ref;   // what each master last wrote
        // master A
        M a; int a_st = 0; int a_left = 0; uint32_t a_base = 0x01000000; std::deque<uint64_t> a_exp;
        // master B
        M b; int b_wr_open = 0; std::deque<uint64_t> b_exp; int b_out = 0; uint32_t b_base = 0x02000000;
        uint64_t b_wdata[2];
        struct Op { int rd; uint32_t addr; uint64_t w0, w1; };
        std::deque<Op> b_q;                 // queued, not yet presented
        d->rst_n = 0; d->clk = 0; d->eval(); d->clk = 1; d->eval(); d->rst_n = 1;
        long b_rd_pending_exp = 0; (void)b_rd_pending_exp;
        auto val = [&](uint32_t ad) { auto it = ref.find(ad); return it == ref.end() ? 0xFFFFFFFFFFFFFFFFull : it->second; };
        for (long cyc = 0; cyc < 400000; cyc++) {
            // ---- drive the masters' commands for this cycle
            if (a_st == 0 && (rng() % 4) == 0) {
                a.addr = a_base + (rng() % 4096);
                if (rng() % 2) { a.rd = 1; a.we = 0; a.bc = 1 + rng() % 248; a_st = 1; a_rd_n++;
                    for (int i = 0; i < a.bc; i++) a_exp.push_back(val(a.addr + i)); }
                else { a.rd = 0; a.we = 1; a.bc = 1 + rng() % 16; a_left = a.bc; a.din = rng() * 0x100000001ull; a_st = 3; a_wr_n++; }
            }
            if (b_q.size() < 4) {
                int r = rng() % 8;
                if (r < 3) b_q.push_back({1, b_base + 2 * (uint32_t)(rng() % 2048), 0, 0});
                else if (r == 3) b_q.push_back({0, b_base + 2 * (uint32_t)(rng() % 2048),
                                                ((uint64_t)rng() << 32) | rng(), ((uint64_t)rng() << 32) | rng()});
            }
            d->b_want = !b_q.empty() || b.rd || b.we;
            d->a_rd = a.rd; d->a_we = a.we; d->a_addr = a.addr; d->a_burstcnt = a.bc; d->a_din = a.din; d->a_be = 0xff;
            d->b_rd = b.rd; d->b_we = b.we; d->b_addr = b.addr; d->b_burstcnt = b.bc; d->b_din = b.din; d->b_be = 0xff;
            d->hold_b = (c.holdb && (int)(rng() % 100) < c.holdb);
            d->clk = 0; d->eval();
            ddr.pre();
            // ---- what this cycle did, seen before the edge
            bool a_take = (a.rd || a.we) && !d->a_busy;
            if (b.rd && !d->b_busy) { b_exp.push_back(val(b.addr)); b_exp.push_back(val(b.addr + 1)); }
            if (d->a_dout_ready) {
                checks++;
                if (a_exp.empty()) { stray++; fails++; }
                else { if (d->dout != a_exp.front()) { if (fails++ < 10) printf("A read wrong at %ld\n", cyc); } a_exp.pop_front();
                       if (a_exp.empty() && a_st == 2) a_st = 0; }
            }
            if (d->b_dout_ready) {
                checks++;
                if (b_exp.empty()) { stray++; fails++; }
                else { if (d->dout != b_exp.front()) { if (fails++ < 10) printf("B read wrong at %ld\n", cyc); } b_exp.pop_front();
                       if ((b_exp.size() % 2) == 0) b_out--; }
            }
            // commit writes to the reference as the beats are taken
            if (a_take && a.we) { ref[a.addr + (a.bc - a_left)] = a.din; a_left--; a.din += 0x1234567;
                                  if (a_left == 0) { a.we = 0; a_st = 0; } }
            if (a_take && a.rd) { a.rd = 0; a_st = a_exp.empty() ? 0 : 2; }
            // B moves only on a cycle it saw !BUSY: what it presented was taken,
            // and it registers the next thing to present.
            if (!d->b_busy) {
                if (b.we) { ref[b.addr + (2 - b_wr_open)] = b.din; b_wr_open--; }
                if (b.we && b_wr_open == 1) { b.din = b_wdata[1]; }
                else {
                    b.rd = 0; b.we = 0;
                    if (!b_q.empty() && !(b_q.front().rd && b_out >= 16)) {
                        Op o = b_q.front(); b_q.pop_front();
                        b.addr = o.addr; b.bc = 2;
                        if (o.rd) { b.rd = 1; b_rd_n++; b_out++; }
                        else { b.we = 1; b_wr_open = 2; b_wdata[0] = o.w0; b_wdata[1] = o.w1; b.din = o.w0; b_wr_n++; }
                    }
                }
            }
            d->clk = 1; d->eval();
            ddr.post();
        }
        printf("  lat %ld busy %d hold %d hold_b %d: protocol errors %ld, queue max %u, overflow %u\n",
               c.lat, c.busy, c.hold, c.holdb, ddr.protocol_errs, (unsigned)d->dbg_q_max, (unsigned)d->dbg_q_ovf);
        if (ddr.protocol_errs || d->dbg_q_ovf) fails++;
    }
    printf("m1_ddram_mux: checks=%ld fails=%ld stray=%ld readsA=%ld readsB=%ld writesA=%ld writesB=%ld\n",
           checks, fails, stray, a_rd_n, b_rd_n, a_wr_n, b_wr_n);
    return fails ? 1 : 0;
}
