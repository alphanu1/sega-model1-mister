// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// float -> int32 truncation, against the host's own conversion.
//
// The host IS the reference here and not merely a convenience: MAME assigns the
// projected float straight into an int member, so whatever x86 does is what
// reaches MAME's rasterizer, including the 0x80000000 it returns for NaN,
// infinity and anything too large. This bench therefore compares against
// `(int32_t)f` directly, and covers the ranges where the two could differ:
//
//   * every exponent from denormal to infinity, at several mantissas
//   * both sides of every power of two, where the shift amount changes
//   * the int32 boundaries, where saturation and indefinite differ
//   * negative zero, denormals, NaN payloads, both infinities
//
// Built with -fno-fast-math semantics: the conversion must not be optimised into
// something else, so the reference value is computed through a volatile.

#include "Vfp_to_int.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>

static long checks = 0, fails = 0, printed = 0;
static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static Vfp_to_int* d;

static void one(uint32_t u, const char* what) {
    volatile float vf = u2f(u);
    int32_t ref = (int32_t)vf;
    d->f = u; d->eval();
    int32_t got = (int32_t)d->i;
    checks++;
    if (got != ref) {
        fails++;
        if (printed++ < 25)
            printf("  FAIL %s: %08x (%g) -> got %d (%08x), host %d (%08x)\n",
                   what, u, u2f(u), got, (uint32_t)got, ref, (uint32_t)ref);
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    d = new Vfp_to_int;

    printf("test: small values truncate toward zero, not to nearest\n");
    for (float v : {0.0f, 0.5f, 0.9999f, 1.0f, 1.5f, 1.9999f, 2.5f,
                    -0.5f, -0.9999f, -1.0f, -1.5f, -1.9999f, -2.5f})
        one(f2u(v), "small");

    printf("test: negative zero, denormals and the smallest normals\n");
    one(0x80000000u, "negative zero");
    one(0x00000001u, "smallest denormal");
    one(0x807fffffu, "largest negative denormal");
    one(0x00800000u, "smallest normal");

    printf("test: NaN and both infinities give INT32_MIN, not a saturation\n");
    one(0x7f800000u, "+inf");
    one(0xff800000u, "-inf");
    one(0x7fc00001u, "quiet NaN");
    one(0xffbfffffu, "signalling NaN");

    printf("test: both sides of every power of two\n");
    for (int e = -2; e <= 32; e++) {
        float base = ldexpf(1.0f, e);
        for (float d2 : {-1.0f, -0.5f, 0.0f, 0.5f, 1.0f}) {
            one(f2u(base + d2), "power of two");
            one(f2u(-(base + d2)), "power of two, negative");
        }
    }

    printf("test: the int32 boundaries, where indefinite and saturation differ\n");
    one(f2u(2147483520.0f),  "largest float below 2^31");
    one(f2u(2147483648.0f),  "exactly 2^31");
    one(f2u(-2147483648.0f), "exactly -2^31");
    one(f2u(-2147483904.0f), "just below -2^31");
    one(f2u(4e9f),           "well past the range");
    one(f2u(-4e9f),          "well past the range, negative");

    printf("test: fuzz over the whole encoding\n");
    {
        std::mt19937 rng(0xf2117u);
        for (int i = 0; i < 400000; i++) one(rng(), "fuzz uniform");
        // Uniform 32-bit draws are almost all huge; bias hard toward the range
        // that actually reaches a screen coordinate.
        for (int i = 0; i < 400000; i++) {
            float v = ((float)(rng() % 4000001) - 2000000.0f) / 1000.0f;
            one(f2u(v), "fuzz screen-scale");
        }
        for (int i = 0; i < 200000; i++) {
            // Exponents around the shift boundary at e == 23.
            int e = (int)(rng() % 40) - 4;
            float v = ldexpf(1.0f + (float)(rng() % 1000) / 1000.0f, e);
            if (rng() & 1) v = -v;
            one(f2u(v), "fuzz exponent sweep");
        }
    }

    printf("fp_to_int: checks=%ld fails=%ld\n", checks, fails);
    return fails ? 1 : 0;
}
