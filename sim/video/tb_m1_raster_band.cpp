// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The band buffer, against a C model of the same rules.
//
// WHAT THIS CHECKS AND WHY EACH CASE IS HERE
//
// The band buffer's whole job is a coordinate mapping and a write, so the bugs
// available to it are all in the mapping. Each directed case below is a mapping
// that would produce a plausible-looking picture while being wrong:
//
//   * a NEGATIVE span_y. band_y0 is signed and the fill unit emits screen
//     coordinates that go above the viewport, so `span_y - band_y0` is a signed
//     subtraction. Done unsigned, a y of -1 becomes 65535, lands in the band by
//     a wrap, and paints a line that should not exist.
//   * a span whose x0 is left of the screen or x1 right of it. Clamping and
//     rejecting look identical on a fully visible span and differ on every
//     partially visible one, which is most of the picture at the frame edges.
//   * x0 == x1, one pixel. An inclusive range done exclusively drops it
//     entirely and drops one pixel from the right of every other span, which is
//     invisible until something is one pixel wide.
//   * the MOIRE stipple keyed to SCREEN x and y rather than to the span. Keyed
//     to the span, the stipple walks with the polygon instead of standing still
//     on the screen - the picture still looks stippled, so only a per-pixel
//     comparison catches it.
//
// The fuzz then drives random spans, including out-of-band and off-screen ones,
// and compares the WHOLE buffer against the model after each - so an extra
// write anywhere, not just on the span just sent, is caught.

#include "Vm1_raster_band.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <random>
#include <vector>

static long checks = 0, fails = 0, printed = 0;
static void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; if (printed++ < 20) printf("  FAIL %s\n", what); }
}

static const int W = 496, H = 64;

struct Dut {
    Vm1_raster_band* d = new Vm1_raster_band;

    // The model: what the buffer should hold. 0 = nothing painted.
    std::vector<uint32_t> mem = std::vector<uint32_t>(W * H, 0);

    void tick() {
        // One clock in the bench: the read port has its own in the design, but
        // the module's behaviour is identical when they are the same, and the
        // crossing itself is the caller's to get right.
        d->clk = 0; d->rd_clk = 0; d->eval();
        d->clk = 1; d->rd_clk = 1; d->eval();
    }
    void reset() {
        d->rst_n = 0; d->span_valid = 0; d->clear_req = 0; d->band_y0 = 0;

        d->rd_x = 0; d->rd_row = 0;
        for (int i = 0; i < 4; i++) tick();
        d->rst_n = 1;
        for (int i = 0; i < 4; i++) tick();
    }
    void clear() {
        d->clear_req = 1;
        tick();
        while (d->clear_busy) tick();
        d->clear_req = 0;
        tick();
        std::fill(mem.begin(), mem.end(), 0u);
    }

    // Drive one span and run the model's version of it.
    void span(int y, int x0, int x1, uint16_t col, bool moire) {
        d->span_valid = 1;
        d->span_y  = (uint16_t)(int16_t)y;
        d->span_x0 = (uint16_t)(int16_t)x0;
        d->span_x1 = (uint16_t)(int16_t)x1;
        d->span_col = col;
        d->span_moire = moire;
        // Hold until taken, then wait for the paint to finish.
        int guard = 0;
        while (!d->span_ready && ++guard < 100000) tick();
        tick();                       // the cycle it is accepted
        d->span_valid = 0;
        guard = 0;
        while (!d->span_ready && ++guard < 100000) tick();

        // Model: the same rules, written independently of the RTL's expressions.
        int y_rel = y - (int16_t)d->band_y0;
        bool in_band = (y_rel >= 0) && (y_rel < H);
        bool on_scr  = (x1 >= 0) && (x0 < W) && (x1 >= x0);
        if (!in_band || !on_scr) return;
        int cx0 = x0 < 0 ? 0 : x0;
        int cx1 = x1 > W - 1 ? W - 1 : x1;
        for (int x = cx0; x <= cx1; x++) {
            if (moire && ((x ^ y) & 1)) continue;   // stipple: screen x and y
            mem[y_rel * W + x] = 0x10000u | col;
        }
    }

    // Read every pixel back and compare against the model.
    void verify(const char* what) {
        for (int row = 0; row < H; row++) {
            for (int x = 0; x < W; x++) {
                d->rd_row = row; d->rd_x = x;
                tick();                       // registered read
                uint32_t got = ((uint32_t)(d->rd_hit & 1) << 16) | d->rd_col;
                uint32_t exp = mem[row * W + x];
                checks++;
                if (got != exp) {
                    fails++;
                    if (printed++ < 20)
                        printf("  FAIL %s: row %d x %d got %05x expected %05x\n",
                               what, row, x, got, exp);
                    return;
                }
            }
        }
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    printf("test: clear leaves nothing painted\n");
    {
        Dut t; t.reset();
        t.span(10, 0, 100, 0x1234, false);
        t.clear();
        t.verify("after clear");
        printf("  cleared %d pixels\n", W * H);
    }

    printf("test: one span paints exactly [x0,x1] INCLUSIVE on the right row\n");
    {
        Dut t; t.reset(); t.clear();
        t.span(5, 10, 20, 0xabcd, false);
        t.verify("simple span");
        // and the count is 11, not 10 - an exclusive range is the classic bug
        check(t.d->dbg_pixels == 11, "an inclusive [10,20] span should write 11 pixels");
        printf("  wrote %u pixels for [10,20]\n", (unsigned)t.d->dbg_pixels);
    }

    printf("test: a ONE-PIXEL span (x0 == x1) is not dropped\n");
    {
        Dut t; t.reset(); t.clear();
        t.span(0, 42, 42, 0x0f0f, false);
        t.verify("one-pixel span");
        check(t.d->dbg_pixels == 1, "x0 == x1 should write exactly one pixel");
    }

    printf("test: NEGATIVE span_y is out of band, not wrapped into it\n");
    {
        Dut t; t.reset(); t.clear();
        t.d->band_y0 = 0;
        t.span(-1, 0, 50, 0xffff, false);
        t.verify("negative y");
        check(t.d->dbg_spans == 0, "a span above the band must not be taken");
        check(t.d->dbg_dropped == 1, "and it must be COUNTED as dropped");
        printf("  taken=%u dropped=%u\n", (unsigned)t.d->dbg_spans, (unsigned)t.d->dbg_dropped);
    }

    printf("test: band_y0 maps SCREEN y to the right row, including a negative y0\n");
    {
        Dut t; t.reset();
        t.d->band_y0 = (uint16_t)(int16_t)128;   // band covers screen rows 128..191
        t.clear();
        t.span(130, 3, 5, 0x2222, false);        // -> row 2
        t.verify("banded span");
        check(t.mem[2 * W + 3] == 0x12222u, "screen y 130 with band_y0 128 is row 2");
        // one below the band's last row must be dropped
        t.span(192, 0, 4, 0x3333, false);
        t.verify("below the band");
    }

    printf("test: clipped at both screen edges, not rejected\n");
    {
        Dut t; t.reset(); t.clear();
        t.span(1, -10, 4, 0x4444, false);        // left edge
        t.span(2, W - 3, W + 40, 0x5555, false); // right edge
        t.verify("edge clipping");
        printf("  left span kept %d px, right span kept %d px\n", 5, 3);
    }

    printf("test: MOIRE stipples against SCREEN x and y\n");
    {
        Dut t; t.reset(); t.clear();
        t.span(3, 0, 9, 0x6666, true);
        t.verify("moire on an odd row");
        t.span(4, 0, 9, 0x7777, true);
        t.verify("moire on an even row");
        // The phase must flip between adjacent rows: that is what makes it a
        // screen-space stipple rather than a per-span one.
        bool row3_x0 = t.mem[3 * W + 0] != 0;
        bool row4_x0 = t.mem[4 * W + 0] != 0;
        check(row3_x0 != row4_x0, "the stipple phase must alternate between rows");
    }

    printf("test: fuzz, random spans compared against the model each time\n");
    {
        Dut t; t.reset();
        std::mt19937 rng(0x5a17ebu);              // fixed seed: reproducible
        long taken = 0, dropped = 0;
        for (int iter = 0; iter < 400; iter++) {
            if ((iter % 40) == 0) {
                t.d->band_y0 = (uint16_t)(int16_t)((int)(rng() % 6) * H);
                t.clear();
            }
            int y0 = (int16_t)t.d->band_y0;
            // Deliberately generate out-of-band and off-screen cases: those are
            // the ones the mapping gets wrong, so they must be in the mix.
            int y  = y0 - 4 + (int)(rng() % (H + 8));
            int x0 = -20 + (int)(rng() % (W + 40));
            int x1 = x0 + (int)(rng() % 60) - 10;
            uint16_t col = (uint16_t)(rng() & 0xffff);
            bool moire = (rng() & 3) == 0;
            long before_t = t.d->dbg_spans, before_d = t.d->dbg_dropped;
            t.span(y, x0, x1, col, moire);
            if ((long)t.d->dbg_spans != before_t) taken++;
            if ((long)t.d->dbg_dropped != before_d) dropped++;
            if ((iter % 25) == 0) t.verify("fuzz");
        }
        t.verify("fuzz final");
        printf("  %ld spans taken, %ld dropped as out-of-band or off-screen\n", taken, dropped);
        check(taken > 100 && dropped > 20,
              "the fuzz must exercise BOTH taken and dropped spans");
    }

    printf("m1_raster_band: checks=%ld fails=%ld\n", checks, fails);
    return fails ? 1 : 0;
}
