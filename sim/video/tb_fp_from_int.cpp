// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// int16 to IEEE-754 single, EXHAUSTIVELY.
//
// The input space is 65,536 values and the conversion is exact for every one of
// them - a float's significand is 24 bits and the input is 16 - so there is no
// reason to sample. Every value is checked against the host's own conversion and
// must match bit for bit.
//
// Exhaustive also means the awkward ones are covered without having to think of
// them: -32768, which negates to a value that does not fit in sixteen bits;
// negative zero, which the input cannot express but the output could; and every
// power of two, where the shift amount changes.

#include "Vfp_from_int.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfp_from_int* d = new Vfp_from_int;
    long checks = 0, fails = 0, printed = 0;

    for (int v = -32768; v <= 32767; v++) {
        d->i = (int16_t)v;
        d->eval();
        uint32_t ref = f2u((float)v);
        checks++;
        if (d->f != ref) {
            fails++;
            if (printed++ < 20)
                printf("  FAIL %d -> %08x, expected %08x\n", v, d->f, ref);
        }
    }
    printf("  checked every value from -32768 to 32767\n");

    // And the two the viewport actually uses, named so a regression says which.
    struct { int v; const char* what; } named[] = {
        {248, "xc, the measured viewport centre"},
        {191, "yc, after MAME's 383 - (word - 39)"},
        {0, "zero"}, {-1, "minus one"}, {383, "the bottom row"}, {495, "the right edge"},
    };
    for (auto& n : named) {
        d->i = (int16_t)n.v; d->eval();
        checks++;
        if (d->f != f2u((float)n.v)) {
            fails++;
            printf("  FAIL %s (%d) -> %08x\n", n.what, n.v, d->f);
        }
    }

    printf("fp_from_int: checks=%ld fails=%ld (exhaustive)\n", checks, fails);
    return fails ? 1 : 0;
}
