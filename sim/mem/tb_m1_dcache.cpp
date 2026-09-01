// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// V60 data cache: 16 KB, 4-word lines, direct-mapped, write-through.
//
// WHAT WOULD MAKE THIS TEST PASS AGAINST A BROKEN CACHE, and is therefore
// modelled the way the real endpoints behave:
//
//  * the requester pulses c_req for ONE cycle and takes data on the c_ack
//    pulse, which is what m1_main does;
//  * the memory serves one transaction per m_req RISING edge, after a VARIABLE
//    delay, and returns SIXTY-FOUR bits - the four words of the burst-aligned
//    line, not the one word asked for. A cache that ignored the alignment and
//    used m_dout[15:0] would pass a fixed-latency single-word model and fail
//    here, which is the bug m1_fetch_bridge documents.
//
// The reference is a flat memory. Every location holds a distinct value derived
// from its address, so a line fetched from the wrong address, a stale hit, or a
// lane written at the wrong offset shows up as WRONG DATA rather than as a
// count that still adds up.
//
// The hit rate is checked too, loosely. A cache that answered every access with
// a miss would be correct and useless, and would pass every data comparison in
// this file - so a sequential sweep must hit at least the 3-in-4 its 4-word
// lines imply, and the random-in-a-small-window phase must beat 50%.

#include "Vm1_dcache.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <map>

static long checks = 0, fails = 0, printed = 0;

static void fail(const char *what, uint32_t addr, uint32_t got, uint32_t exp) {
    fails++;
    if (printed++ < 20)
        fprintf(stderr, "  %s at addr %06x: got %04x expected %04x\n",
                what, addr, got, exp);
}

// The memory behind the cache. Word-addressed, 24-bit word address.
struct Mem {
    std::map<uint32_t, uint16_t> m;
    // Distinct per address, and NOT a function of the low bits alone, so a line
    // read from the wrong place cannot accidentally match.
    uint16_t initial(uint32_t a) const { return (uint16_t)((a * 2654435761u) >> 13); }
    uint16_t rd(uint32_t a) {
        auto it = m.find(a);
        return it == m.end() ? initial(a) : it->second;
    }
    void wr(uint32_t a, uint16_t d, int be) {
        uint16_t cur = rd(a);
        if (be & 1) cur = (uint16_t)((cur & 0xFF00) | (d & 0x00FF));
        if (be & 2) cur = (uint16_t)((cur & 0x00FF) | (d & 0xFF00));
        m[a] = cur;
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vm1_dcache *dut = new Vm1_dcache;
    Mem mem;
    std::mt19937 rng(0x5E6A1234u);

    // --- memory-side service model -------------------------------------------
    bool     busy = false;
    int      left = 0;
    uint32_t saddr = 0;
    bool     swe = false;
    uint16_t sdin = 0;
    int      sbe = 0;

    auto tick = [&](void) {
        // Serve the memory side BEFORE the clock edge the DUT will sample.
        dut->m_ack = 0;
        if (!busy && dut->m_req) {
            busy  = true;
            saddr = dut->m_addr;
            swe   = dut->m_we;
            sdin  = dut->m_din;
            sbe   = dut->m_be;
            // Deliberately variable: a cache that assumed a fixed latency would
            // pass a constant one.
            left  = 1 + (int)(rng() % 12);
        }
        if (busy && --left <= 0) {
            if (swe) {
                mem.wr(saddr, sdin, sbe);
            } else {
                // SIXTY-FOUR BITS, from the BURST-ALIGNED base of whatever
                // address the cache asked for. If the cache did not align, this
                // returns the wrong four words and the comparison catches it.
                uint32_t base = saddr & ~3u;
                uint64_t d = 0;
                for (int i = 0; i < 4; i++)
                    d |= (uint64_t)mem.rd(base + i) << (16 * i);
                dut->m_dout = d;
            }
            dut->m_ack = 1;
            busy = false;
        }
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    };

    dut->rst_n = 0; dut->flush = 0; dut->c_req = 0;
    dut->c_we = 0; dut->c_addr = 0; dut->c_din = 0; dut->c_be = 3;
    dut->m_ack = 0; dut->m_dout = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->rst_n = 1;
    // The array walk is LINES cycles; nothing may be issued during it.
    for (int i = 0; i < 4200; i++) tick();

    // One transaction, returning the cache's data and whether it was a hit.
    auto access = [&](uint32_t addr, bool we, uint16_t din, int be) -> uint16_t {
        uint32_t h0 = dut->dbg_hits;
        dut->c_req = 1; dut->c_we = we; dut->c_addr = addr;
        dut->c_din = din; dut->c_be = be;
        tick();
        dut->c_req = 0;
        uint16_t got = 0;
        for (int i = 0; i < 200; i++) {
            tick();
            if (dut->c_ack) { got = dut->c_dout; break; }
        }
        (void)h0;
        return got;
    };

    // --- phase 1: sequential sweep. 4-word lines must hit 3 of every 4. ------
    {
        uint32_t h0 = dut->dbg_hits, m0 = dut->dbg_misses;
        for (uint32_t a = 0x1000; a < 0x1000 + 4096; a++) {
            uint16_t got = access(a, false, 0, 3);
            checks++;
            if (got != mem.rd(a)) fail("seq read", a, got, mem.rd(a));
        }
        uint32_t hits = dut->dbg_hits - h0, miss = dut->dbg_misses - m0;
        double rate = 100.0 * hits / (hits + miss);
        printf("  sequential sweep: %.1f%% hit (4-word lines imply 75%%)\n", rate);
        checks++;
        if (rate < 74.0) { fails++; fprintf(stderr, "  hit rate too low: %.1f%%\n", rate); }
    }

    // --- phase 2: write-through, and a write hit must update the line -------
    {
        for (int i = 0; i < 2000; i++) {
            uint32_t a = 0x1000 + (rng() % 512);
            uint16_t d = (uint16_t)rng();
            int be = 1 + (int)(rng() % 3);
            access(a, true, d, be);
            mem.wr(a, d, be);
            // Read it straight back: if the write hit did not update the cached
            // line, this returns the pre-write value from a stale hit.
            uint16_t got = access(a, false, 0, 3);
            checks++;
            if (got != mem.rd(a)) fail("write-through readback", a, got, mem.rd(a));
        }
    }

    // --- phase 3: random over a window that thrashes the index --------------
    {
        uint32_t h0 = dut->dbg_hits, m0 = dut->dbg_misses;
        for (int i = 0; i < 20000; i++) {
            uint32_t a = 0x20000 + (rng() % 2048);
            if (rng() % 4 == 0) {
                uint16_t d = (uint16_t)rng();
                int be = 1 + (int)(rng() % 3);
                access(a, true, d, be);
                mem.wr(a, d, be);
            } else {
                uint16_t got = access(a, false, 0, 3);
                checks++;
                if (got != mem.rd(a)) fail("random read", a, got, mem.rd(a));
            }
        }
        uint32_t hits = dut->dbg_hits - h0, miss = dut->dbg_misses - m0;
        double rate = 100.0 * hits / (hits + miss);
        printf("  random in a 2048-word window: %.1f%% hit\n", rate);
        checks++;
        if (rate < 50.0) { fails++; fprintf(stderr, "  hit rate too low: %.1f%%\n", rate); }
    }

    // --- phase 4: aliasing. Two addresses sharing an index must not alias ---
    {
        // LINES=2048, 4 words per line: index repeats every 8192 words.
        for (int i = 0; i < 2000; i++) {
            uint32_t a = 0x40000 + (rng() % 64) * 4;
            uint32_t b = a + 8192;              // same index, different tag
            uint16_t ga = access(a, false, 0, 3);
            checks++; if (ga != mem.rd(a)) fail("alias A", a, ga, mem.rd(a));
            uint16_t gb = access(b, false, 0, 3);
            checks++; if (gb != mem.rd(b)) fail("alias B", b, gb, mem.rd(b));
            uint16_t ga2 = access(a, false, 0, 3);
            checks++; if (ga2 != mem.rd(a)) fail("alias A again", a, ga2, mem.rd(a));
        }
    }

    // --- phase 4b: posted-write hazard --------------------------------------
    // A write MISS does not allocate, so the line is not in the cache and a
    // following read of it must go to memory - which must already have the
    // write. Writes are posted (the CPU is acked before SDRAM has taken the
    // data), so this is the ordering that posting can break. Each address is
    // touched once, cold, to guarantee the write misses.
    {
        for (int i = 0; i < 4000; i++) {
            uint32_t a = 0x60000 + i * 7;      // stride 7: never the same line
            uint16_t d = (uint16_t)(rng() | 1);
            access(a, true, d, 3);
            mem.wr(a, d, 3);
            uint16_t got = access(a, false, 0, 3);
            checks++;
            if (got != mem.rd(a)) fail("posted write then read", a, got, mem.rd(a));
        }
    }

    // --- phase 5: flush must not leave a stale line -------------------------
    {
        uint32_t a = 0x50000;
        access(a, false, 0, 3);                 // cache it
        mem.m[a] = 0xBEEF;                      // change it behind the cache's back
        dut->flush = 1;
        for (int i = 0; i < 4200; i++) tick();
        dut->flush = 0;
        // NO SETTLING TIME. The real design drops flush on the same edge that
        // releases the V60 from reset, so the CPU's first access lands in
        // whatever is left of the init walk. This test used to wait 4,200
        // cycles here and passed against a cache that dropped that request -
        // m1_main sat in B_SDRAM forever and it presented as a dead CPU.
        uint16_t got = access(a, false, 0, 3);
        checks++;
        if (got != 0xBEEF) fail("post-flush", a, got, 0xBEEF);
        checks++;
        if (dut->dbg_dropped != 0) {
            fails++;
            fprintf(stderr, "  %u requests DROPPED - the CPU would hang here\n",
                    dut->dbg_dropped);
        }

        // And again with the request arriving at every possible offset into the
        // walk, since one sample proves only that one phase works.
        for (int ph = 0; ph < 64; ph++) {
            dut->flush = 1;
            for (int i = 0; i < 4200; i++) tick();
            dut->flush = 0;
            for (int i = 0; i < ph; i++) tick();
            uint32_t aa = 0x51000 + ph * 4;
            uint16_t g = access(aa, false, 0, 3);
            checks++;
            if (g != mem.rd(aa)) fail("post-flush phase", aa, g, mem.rd(aa));
        }
        checks++;
        if (dut->dbg_dropped != 0) {
            fails++;
            fprintf(stderr, "  %u requests dropped across flush phases\n",
                    dut->dbg_dropped);
        }
    }

    printf("m1_dcache: checks=%ld fails=%ld hits=%u misses=%u writes=%u dropped=%u\n",
           checks, fails, dut->dbg_hits, dut->dbg_misses, dut->dbg_writes,
           dut->dbg_dropped);
    delete dut;
    return fails ? 1 : 0;
}
