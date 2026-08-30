// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The light parameter banks and their build-time /255 table.
//
// The whole point of this module is that the division is EXACT - the table is
// computed with the same IEEE division MAME uses, so the stored floats must be
// bit-identical to `(v & 0xff)/255.0f`, not merely close. A table generated with
// a different rounding, or indexed off by one, gives luminance values that are
// slightly wrong everywhere and look like a lighting bug in the colour unit.
//
// So every one of the 256 byte values is checked against the host for each of
// the three channels, and the packing is checked too: diffuse in bits 7:0,
// ambient 15:8, specular 23:16, power 31:24. Transposing two of those is a
// plausible-looking picture with the wrong contrast.

#include "Vm1_lightbank.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static long checks = 0, fails = 0, printed = 0;

struct Dut {
    Vm1_lightbank* d = new Vm1_lightbank;
    void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
    void reset() {
        d->rst_n = 0; d->we = 0; d->waddr = 0; d->wdata = 0; d->raddr = 0;
        for (int i = 0; i < 4; i++) tick();
        d->rst_n = 1;
        for (int i = 0; i < 4; i++) tick();
    }
    void write(int addr, uint8_t dd, uint8_t aa, uint8_t ss, uint8_t pp) {
        d->we = 1; d->waddr = addr;
        d->wdata = (uint32_t)dd | ((uint32_t)aa << 8) |
                   ((uint32_t)ss << 16) | ((uint32_t)pp << 24);
        tick();
        d->we = 0;
        for (int i = 0; i < 3; i++) tick();   // the table read is a cycle behind
    }
    void read(int addr) { d->raddr = addr; tick(); tick(); }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Dut t; t.reset();

    printf("test: every byte value converts exactly, on all three channels\n");
    for (int v = 0; v < 256; v++) {
        // A different value on each channel at once, so a transposed field shows.
        uint8_t dd = (uint8_t)v;
        uint8_t aa = (uint8_t)(255 - v);
        uint8_t ss = (uint8_t)((v * 7) & 0xff);
        uint8_t pp = (uint8_t)((v * 3) & 0xff);
        t.write(v & 0xff, dd, aa, ss, pp);
        t.read(v & 0xff);
        checks += 4;
        if (t.d->lp_d != f2u(dd / 255.0f)) {
            fails++;
            if (printed++ < 10) printf("  FAIL diffuse %d -> %08x, expected %08x\n",
                                       dd, t.d->lp_d, f2u(dd / 255.0f));
        }
        if (t.d->lp_a != f2u(aa / 255.0f)) {
            fails++;
            if (printed++ < 10) printf("  FAIL ambient %d -> %08x, expected %08x\n",
                                       aa, t.d->lp_a, f2u(aa / 255.0f));
        }
        if (t.d->lp_s != f2u(ss / 255.0f)) {
            fails++;
            if (printed++ < 10) printf("  FAIL specular %d -> %08x, expected %08x\n",
                                       ss, t.d->lp_s, f2u(ss / 255.0f));
        }
        if (t.d->lp_p != pp) {
            fails++;
            if (printed++ < 10) printf("  FAIL power %d -> %d\n", pp, t.d->lp_p);
        }
    }

    printf("test: the banks measured from the real display list\n");
    {
        // tools/mame_light_census.lua found exactly these, and bank 0 differs
        // from bank 1 in every field - so a stuck address shows up here.
        static const uint8_t raw[5][4] = {{63,7,255,7}, {255,255,255,7},
                                          {127,47,239,7}, {127,63,0,0}, {127,127,0,0}};
        for (int i = 0; i < 5; i++)
            t.write(i, raw[i][0], raw[i][1], raw[i][2], raw[i][3]);
        for (int i = 0; i < 5; i++) {
            t.read(i);
            checks += 4;
            if (t.d->lp_d != f2u(raw[i][0] / 255.0f) ||
                t.d->lp_a != f2u(raw[i][1] / 255.0f) ||
                t.d->lp_s != f2u(raw[i][2] / 255.0f) ||
                t.d->lp_p != raw[i][3]) {
                fails++;
                printf("  FAIL bank %d read back wrong\n", i);
            }
        }
        printf("  five measured banks stored and read back\n");
    }

    printf("test: banks are independent - writing one does not disturb another\n");
    {
        t.write(0x10, 10, 20, 30, 4);
        t.write(0x80, 200, 100, 50, 7);     // the bit-22 alternate bank
        t.read(0x10);
        checks++;
        if (t.d->lp_p != 4) { fails++; printf("  FAIL bank 0x10 was disturbed\n"); }
        t.read(0x80);
        checks++;
        if (t.d->lp_p != 7) { fails++; printf("  FAIL bank 0x80 wrong\n"); }
    }

    printf("m1_lightbank: checks=%ld fails=%ld\n", checks, fails);
    return fails ? 1 : 0;
}
