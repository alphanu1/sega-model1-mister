// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The quad store and the painter's sort.
//
// The order is the whole product of this module, and a wrong order does not look
// like an error - it looks like polygons poking through each other, which reads
// as a geometry or a depth bug somewhere else entirely. So the bench compares the
// ENTIRE replayed sequence against std::stable_sort with MAME's comparator, and
// covers the cases where a float sort goes wrong:
//
//   * NEGATIVE z. IEEE floats compare as sign-magnitude, so a raw integer sort
//     puts -1.0 above +1.0 and reverses the whole negative half. Camera-space
//     depths are positive for visible geometry, but zmode 3 writes a literal
//     zero and zmode 0 reuses whatever the previous object left, so negatives do
//     reach here.
//   * EQUAL z, which MAME breaks by submission order. A radix sort is stable, so
//     starting in submission order is enough - but only if it really is stable,
//     and a scatter that walks backwards is not. The bench feeds long runs of
//     identical z on purpose.
//   * zero and negative zero, which are equal as floats and different as bits.
//   * a replay repeated several times, because the band architecture walks the
//     same sorted list once per band and a store that consumes itself would draw
//     the first band and nothing else.

#include "Vm1_quad_store.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>
#include <vector>
#include <algorithm>

static long checks = 0, fails = 0, printed = 0;
static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

struct Q { int16_t x0, y0, x1, y1, x2, y2, x3, y3; uint32_t col, z; bool moire; int seq; };

struct Dut {
    Vm1_quad_store* d = new Vm1_quad_store;
    long cycles = 0;
    void tick() { cycles++; d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
    void reset() {
        d->rst_n = 0; d->clear = 0; d->in_valid = 0;
        d->sort_start = 0; d->replay_start = 0; d->out_ready = 1;
        d->replay_band = 0;
        for (int i = 0; i < 6; i++) tick();
        d->rst_n = 1;
        for (int i = 0; i < 6; i++) tick();
    }
    void load(const std::vector<Q>& qs) {
        d->clear = 1; tick(); d->clear = 0; tick();
        for (const Q& q : qs) {
            d->in_valid = 1;
            d->in_x0 = q.x0; d->in_y0 = q.y0; d->in_x1 = q.x1; d->in_y1 = q.y1;
            d->in_x2 = q.x2; d->in_y2 = q.y2; d->in_x3 = q.x3; d->in_y3 = q.y3;
            d->in_col = q.col; d->in_z = q.z; d->in_moire = q.moire;
            tick();
        }
        d->in_valid = 0; tick();
    }
    void sort() {
        d->sort_start = 1; tick(); d->sort_start = 0;
        int g = 0;
        while (d->sort_busy && ++g < 4000000) tick();
    }
    std::vector<Q> replay() {
        std::vector<Q> out;
        d->replay_start = 1; tick(); d->replay_start = 0;
        int g = 0;
        while (++g < 4000000) {
            if (d->out_valid) {
                Q q;
                q.x0 = (int16_t)d->out_x0; q.y0 = (int16_t)d->out_y0;
                q.x1 = (int16_t)d->out_x1; q.y1 = (int16_t)d->out_y1;
                q.x2 = (int16_t)d->out_x2; q.y2 = (int16_t)d->out_y2;
                q.x3 = (int16_t)d->out_x3; q.y3 = (int16_t)d->out_y3;
                q.col = d->out_col; q.moire = d->out_moire; q.z = 0; q.seq = 0;
                out.push_back(q);
            }
            tick();
            if (!d->replay_busy && !d->out_valid) break;
        }
        return out;
    }
};

// quad_t::compare: z descending, ties by submission order.
static std::vector<Q> model(std::vector<Q> qs) {
    std::stable_sort(qs.begin(), qs.end(), [](const Q& a, const Q& b) {
        float za = u2f(a.z), zb = u2f(b.z);
        if (za != zb) return za > zb;
        return a.seq < b.seq;
    });
    return qs;
}

static void compare(Dut& t, std::vector<Q>& qs, const char* what) {
    t.load(qs);
    t.sort();
    std::vector<Q> got = t.replay();
    std::vector<Q> exp = model(qs);
    checks++;
    if (got.size() != exp.size()) {
        fails++;
        if (printed++ < 20)
            printf("  FAIL %s: replayed %zu, expected %zu\n", what, got.size(), exp.size());
        return;
    }
    for (size_t i = 0; i < exp.size(); i++) {
        checks++;
        // x0 carries the identity in these tests, so a wrong order shows there.
        if (got[i].x0 != exp[i].x0 || got[i].col != exp[i].col ||
            got[i].y3 != exp[i].y3 || got[i].moire != exp[i].moire) {
            fails++;
            if (printed++ < 20)
                printf("  FAIL %s: position %zu is quad %d (z %g), expected %d (z %g)\n",
                       what, i, got[i].x0, u2f(qs[got[i].x0 & 0x7ff].z),
                       exp[i].x0, u2f(exp[i].z));
            return;
        }
    }
}

// The default quad sits entirely inside band 0 (rows 0..63) so the ordering
// tests are not also testing the band filter. The filter has its own case below.
static Q mk(int id, float z, bool moire = false) {
    Q q;
    q.x0 = (int16_t)id; q.y0 = 1; q.x1 = (int16_t)(id + 1);
    q.y1 = 2; q.x2 = (int16_t)(id + 3); q.y2 = 3;
    q.x3 = (int16_t)(id + 5); q.y3 = (int16_t)(id % 30);
    q.col = (uint32_t)(id * 0x010203) & 0xffffff;
    q.z = f2u(z); q.moire = moire; q.seq = id;
    return q;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Dut t; t.reset();

    printf("test: a plain descending sort\n");
    { std::vector<Q> q; for (int i = 0; i < 20; i++) q.push_back(mk(i, (float)(i * 3 % 17)));
      compare(t, q, "descending"); }

    printf("test: NEGATIVE z, where a raw integer sort reverses the wrong half\n");
    { std::vector<Q> q;
      for (int i = 0; i < 40; i++) q.push_back(mk(i, ((float)(i % 20) - 10.0f) * 1.5f));
      compare(t, q, "negative z"); }

    printf("test: zero and negative zero are EQUAL as floats\n");
    { std::vector<Q> q;
      q.push_back(mk(0, 0.0f)); q.push_back(mk(1, -0.0f));
      q.push_back(mk(2, 0.0f)); q.push_back(mk(3, 1.0f)); q.push_back(mk(4, -1.0f));
      compare(t, q, "signed zero"); }

    printf("test: long runs of EQUAL z keep submission order\n");
    { std::vector<Q> q;
      for (int i = 0; i < 60; i++) q.push_back(mk(i, (float)(i / 20)));
      compare(t, q, "stable ties"); }

    printf("test: every quad the same z - the sort must be a no-op, not a reversal\n");
    { std::vector<Q> q; for (int i = 0; i < 50; i++) q.push_back(mk(i, 7.0f));
      compare(t, q, "all equal");
      std::vector<Q> got = t.replay();
      checks++;
      bool inorder = true;
      for (size_t i = 0; i < got.size(); i++) if (got[i].x0 != (int)i) inorder = false;
      if (!inorder) { fails++; printf("  FAIL identical z did not keep submission order\n"); } }

    printf("test: the list REPLAYS repeatedly - the band walk needs it once per band\n");
    { std::vector<Q> q; for (int i = 0; i < 30; i++) q.push_back(mk(i, (float)(30 - i)));
      t.load(q); t.sort();
      std::vector<Q> first = t.replay();
      for (int b = 0; b < 6; b++) {
          std::vector<Q> again = t.replay();
          checks++;
          if (again.size() != first.size()) {
              fails++; printf("  FAIL replay %d gave %zu, first gave %zu\n",
                              b, again.size(), first.size()); break;
          }
          for (size_t i = 0; i < first.size(); i++) {
              checks++;
              if (again[i].x0 != first[i].x0) {
                  fails++; printf("  FAIL replay %d differs at %zu\n", b, i); break;
              }
          }
      } }

    printf("test: an empty frame replays nothing and does not hang\n");
    { std::vector<Q> q; compare(t, q, "empty"); }

    printf("test: OVERFLOW is dropped and counted, not wrapped\n");
    { std::vector<Q> q;
      for (int i = 0; i < 2100; i++) q.push_back(mk(i & 0x7ff, (float)(i % 97)));
      t.load(q);
      checks++;
      if (t.d->dbg_count != 2048) { fails++; printf("  FAIL stored %d, expected 2048\n", (int)t.d->dbg_count); }
      checks++;
      if (t.d->dbg_dropped != 2100 - 2048) {
          fails++; printf("  FAIL dropped %d, expected %d\n", (int)t.d->dbg_dropped, 2100-2048);
      } else printf("  stored %d, dropped %d\n", (int)t.d->dbg_count, (int)t.d->dbg_dropped); }

    printf("test: the BAND FILTER replays only quads whose rows touch the band\n");
    {
        // TWELVE bands of 32 rows, not six of 64 - the height was halved to free
        // M10K for the sound section, and this test is the one that notices when
        // the mask, the select and the row-to-band divide are not all updated
        // together. They were not: the frame stopped dead after band 3.
        const int NB = 12, BH = 32;
        std::vector<Q> q;
        auto band_quad = [&](int id, int y0, int y1) {
            Q a = mk(id, (float)(1000 - id));
            a.y0 = (int16_t)y0; a.y1 = (int16_t)y0;
            a.y2 = (int16_t)y1; a.y3 = (int16_t)y1;
            return a;
        };
        for (int b = 0; b < NB; b++)
            q.push_back(band_quad(b, b * BH + 4, b * BH + 20));
        q.push_back(band_quad(NB,     70, 200));   // bands 2..6
        q.push_back(band_quad(NB + 1, -500, -400));// above the screen
        q.push_back(band_quad(NB + 2, 900, 1000)); // below it
        t.load(q); t.sort();

        int seen_total = 0;
        for (int b = 0; b < NB; b++) {
            t.d->replay_band = b;
            std::vector<Q> got = t.replay();
            int want = 1 + ((b >= 2 && b <= 6) ? 1 : 0);
            checks++;
            if ((int)got.size() != want) {
                fails++;
                printf("  FAIL band %d replayed %zu quads, expected %d\n",
                       b, got.size(), want);
            }
            seen_total += (int)got.size();
        }
        // 12 single-band quads + one spanning 5 bands = 17 replays; without the
        // filter it would be 15 quads x 12 bands = 180.
        printf("  15 quads stored, %d quad-replays across %d bands (%d without binning)\n",
               seen_total, NB, 15 * NB);
        checks++;
        if (seen_total != NB + 5) {
            fails++;
            printf("  FAIL total replays %d, expected %d\n", seen_total, NB + 5);
        }
        checks++;
        // The two off-screen quads must be in NO band at all.
        if (seen_total > NB + 5) { fails++; printf("  FAIL off-screen quads were replayed\n"); }
        t.d->replay_band = 0;
    }

    printf("test: fuzz\n");
    {
        std::mt19937 rng(0x9a1735u);
        for (int iter = 0; iter < 120; iter++) {
            std::vector<Q> q;
            int n = 1 + (int)(rng() % 300);
            for (int i = 0; i < n; i++) {
                float z;
                switch (rng() % 4) {
                    case 0: z = (float)((int)(rng() % 200) - 100); break;
                    case 1: z = ((float)(rng() % 100000) - 50000.0f) / 128.0f; break;
                    case 2: z = (float)(rng() % 3); break;          // many ties
                    default: z = ldexpf(1.0f, (int)(rng() % 60) - 30); break;
                }
                q.push_back(mk(i, z, (rng() & 1) != 0));
            }
            compare(t, q, "fuzz");
        }
    }

    printf("test: THROUGHPUT - the sort must fit inside a frame\n");
    {
        std::vector<Q> q;
        for (int i = 0; i < 2000; i++) q.push_back(mk(i & 0x7ff, (float)(i % 811)));
        t.load(q);
        long c0 = t.cycles;
        t.sort();
        long sc = t.cycles - c0;
        printf("  sorting 2000 quads took %ld cycles (%.1f%% of a 397,515-cycle frame)\n",
               sc, 100.0 * sc / 397515.0);
        checks++;
        if (sc > 397515) { fails++; printf("  FAIL the sort does not fit in a frame\n"); }
    }

    printf("m1_quad_store: checks=%ld fails=%ld\n", checks, fails);
    return fails ? 1 : 0;
}
