// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The display-list walker, against a C model of tgp_render's interpreter.
//
// WHY THE COMPARISON IS THE WHOLE EVENT STREAM
//
// A display list has no framing: each command's length is implied by its type, so
// a single wrong stride desynchronises the walk and everything after it decodes
// as commands that were never written. The failure does not look like a failure -
// it looks like a longer list of plausible objects - so checking "did we see a
// viewport" or "how many objects" cannot catch it. Only the ordered stream of
// (kind, index, value) can, and only if it runs past the mistake.
//
// The model below is transcribed from model1_v.cpp:1451-1601 rather than derived
// from the RTL, so the two are independent descriptions of the same grammar.
//
// The cases that are here because they are the ones that go wrong:
//
//   * command 4's length is `readi(+4) + 1` and commands 5/6's is `readi(+4)`.
//     Getting the +1 wrong shifts every later command by two words.
//   * command 3 reads one 32-bit parameter then SIX 16-BIT ones at a two-word
//     pitch, leaving six words unread. Reading them as 32-bit values produces the
//     right stride and the wrong viewport - a bug that survives any test that
//     only checks synchronisation.
//   * command 2's length is data-dependent: sub-records of 12 or 20 words chosen
//     by their own flags, until one has type 0. It is the only command whose
//     length cannot be known without reading its body.
//   * a type word whose HIGH BITS are set ends the list, because the reference
//     switches on the full 32-bit value. 0x00010000 is not command 1.
//   * an unknown type ends the list too - `default:` falls into the same `goto`.

#include "Vm1_listwalk.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <random>

static long checks = 0, fails = 0, printed = 0;
static void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; if (printed++ < 20) printf("  FAIL %s\n", what); }
}

struct Ev { int kind, idx; uint32_t data; };
static bool operator!=(const Ev& a, const Ev& b) {
    return a.kind != b.kind || a.idx != b.idx || a.data != b.data;
}

// ---------------------------------------------------------------- the model
//
// tgp_render's loop, transcribed. Returns the events the walker should emit.
static std::vector<Ev> model(const std::vector<uint16_t>& m) {
    std::vector<Ev> ev;
    auto rd = [&](int a) { return (uint32_t)m[a & 0x7fff]; };
    auto readi = [&](int a) { return rd(a) | (rd(a + 1) << 16); };
    auto readi16 = [&](int a) { return (uint32_t)(int32_t)(int16_t)m[a & 0x7fff]; };

    int off = 0;
    for (int guard = 0; guard < 200000; guard++) {
        if (off >= 0x8000) break;          // the RTL's end-of-buffer terminator
        uint32_t type = readi(off);
        if (type == 1 || type == 0x41) {
            for (int i = 0; i < 3; i++) ev.push_back({(int)type, i, readi(off + 2 + 2 * i)});
            off += 8;
        } else if (type == 0) {
            off += 2;
        } else if (type == 2) {
            off += 18;
            while (true) {
                uint32_t flags = readi(off + 2);
                int t = flags & 3;
                if (!t) break;
                off += (t == 2) ? 12 : 20;
            }
            off += 4;
        } else if (type == 3) {
            ev.push_back({3, 0, readi(off + 2)});
            for (int i = 0; i < 6; i++) ev.push_back({3, i, readi16(off + 4 + 2 * i)});
            off += 16;
        } else if (type == 4 || type == 5 || type == 6) {
            ev.push_back({(int)type, 0, readi(off + 2)});
            uint32_t len = readi(off + 4);
            ev.push_back({(int)type, 1, len});
            int n = (int)((type == 4) ? (uint16_t)(len + 1) : (uint16_t)len);
            for (int i = 0; i < n; i++)
                ev.push_back({(int)type, i,
                              (type == 4) ? (uint32_t)m[(off + 6 + 2 * i) & 0x7fff]
                                          : readi(off + 6 + 2 * i)});
            off += 6 + n * 2;
        } else if (type == 7 || type == 8) {
            ev.push_back({(int)type, 0, readi(off + 2)}); off += 4;
        } else if (type == 9 || type == 0xc) {
            for (int i = 0; i < 2; i++) ev.push_back({(int)type, i, readi(off + 2 + 2 * i)});
            off += 6;
        } else if (type == 0xa) {
            for (int i = 0; i < 3; i++) ev.push_back({(int)type, i, readi(off + 2 + 2 * i)});
            off += 8;
        } else if (type == 0xb) {
            for (int i = 0; i < 12; i++) ev.push_back({(int)type, i, readi(off + 2 + 2 * i)});
            off += 26;
        } else {
            break;                      // 0x0f, and anything unrecognised
        }
    }
    return ev;
}

// ---------------------------------------------------------------- the DUT
struct Dut {
    Vm1_listwalk* d = new Vm1_listwalk;
    std::vector<uint16_t> mem = std::vector<uint16_t>(0x8000, 0);
    std::vector<Ev> got;

    void tick() {
        // A one-cycle synchronous RAM: valid follows the request by a cycle.
        int req = d->mem_req; int addr = d->mem_addr;
        d->clk = 0; d->eval();
        d->clk = 1;
        d->mem_valid = req;
        d->mem_data  = req ? mem[addr & 0x7fff] : 0;
        d->eval();
        if (d->ev_valid) got.push_back({d->ev_kind, d->ev_idx, d->ev_data});
    }
    void reset() {
        d->rst_n = 0; d->start = 0; d->stall = 0; d->mem_valid = 0; d->mem_data = 0;
        for (int i = 0; i < 4; i++) tick();
        d->rst_n = 1;
        for (int i = 0; i < 4; i++) tick();
    }
    bool run() {
        got.clear();
        d->start = 1; tick(); d->start = 0;
        int guard = 0;
        while (!d->done && ++guard < 4000000) tick();
        return guard < 4000000;
    }
};

// A tiny builder, so each test reads as the list it is.
struct L {
    std::vector<uint16_t> m;
    void w32(uint32_t v) { m.push_back(v & 0xffff); m.push_back(v >> 16); }
    void w16(uint16_t v) { m.push_back(v); m.push_back(0); }   // 16-bit at 2-word pitch
    void raw(uint16_t v) { m.push_back(v); }
};

static bool compare(const char* what, Dut& t, const std::vector<uint16_t>& list) {
    // Reset first: a walker left mid-command by a previous failure ignores
    // `start`, and every later case then fails for a reason that is not its own.
    t.reset();
    t.mem.assign(0x8000, 0);
    for (size_t i = 0; i < list.size() && i < 0x8000; i++) t.mem[i] = list[i];
    if (!t.run()) { printf("  FAIL %s: walker never finished\n", what); fails++; checks++; return false; }
    std::vector<Ev> exp = model(t.mem);
    checks++;
    if (exp.size() != t.got.size()) {
        fails++;
        if (printed++ < 20)
            printf("  FAIL %s: %zu events, expected %zu\n", what, t.got.size(), exp.size());
        return false;
    }
    for (size_t i = 0; i < exp.size(); i++) {
        checks++;
        if (exp[i] != t.got[i]) {
            fails++;
            if (printed++ < 20)
                printf("  FAIL %s: event %zu got (k=%02x i=%d %08x) expected (k=%02x i=%d %08x)\n",
                       what, i, t.got[i].kind, t.got[i].idx, t.got[i].data,
                       exp[i].kind, exp[i].idx, exp[i].data);
            return false;
        }
    }
    return true;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Dut t; t.reset();

    printf("test: an empty list ends immediately\n");
    { L l; l.w32(0x0f); compare("empty", t, l.m);
      check(t.d->dbg_objects == 0, "no objects in an empty list");
      check(t.d->dbg_bad_type == 0, "0x0f is a clean end, not a bad type"); }

    printf("test: one object, and its three parameters in order\n");
    { L l; l.w32(1); l.w32(0x11111111); l.w32(0x22222222); l.w32(0x33333333); l.w32(0x0f);
      compare("object", t, l.m);
      check(t.d->dbg_objects == 1, "one object counted"); }

    printf("test: 0x41 is an object too, and keeps its own kind\n");
    { L l; l.w32(0x41); l.w32(0xaaaa); l.w32(0xbbbb); l.w32(0xcccc); l.w32(0x0f);
      compare("object above hud", t, l.m);
      check(t.d->dbg_objects == 1, "0x41 counts as an object"); }

    printf("test: the viewport's six 16-bit parameters, sign-extended\n");
    { L l; l.w32(3); l.w32(0x1234);
      l.w16(0xfff0); l.w16(40); l.w16(0); l.w16(383); l.w16(495); l.w16(0xff00);
      l.w32(0x0f);
      compare("viewport", t, l.m); }

    printf("test: command 4 draws ONE MORE item than its length states\n");
    { L l; l.w32(4); l.w32(0x40000); l.w32(3);
      l.w16(0x1111); l.w16(0x2222); l.w16(0x3333); l.w16(0x4444);   // len+1 = 4
      l.w32(1); l.w32(7); l.w32(8); l.w32(9);                        // must still decode
      l.w32(0x0f);
      compare("colour write +1", t, l.m);
      check(t.d->dbg_objects == 1, "the object AFTER command 4 must still be found"); }

    printf("test: commands 5 and 6 use their length as stated\n");
    { L l; l.w32(5); l.w32(0x800000); l.w32(2); l.w32(0xdead); l.w32(0xbeef);
      l.w32(6); l.w32(0); l.w32(1); l.w32(0x01020304);
      l.w32(1); l.w32(5); l.w32(6); l.w32(7);
      l.w32(0x0f);
      compare("poly/light upload", t, l.m);
      check(t.d->dbg_objects == 1, "the object after two uploads must still be found"); }

    printf("test: a zero-length upload is not an infinite loop\n");
    { L l; l.w32(5); l.w32(0x800000); l.w32(0); l.w32(1); l.w32(1); l.w32(2); l.w32(3);
      l.w32(0x0f);
      compare("zero-length upload", t, l.m); }

    printf("test: the direct command's data-dependent walk\n");
    { L l;
      l.w32(2);
      for (int i = 0; i < 16; i++) l.raw(0);          // 18-word header (2 + 16)
      l.w32(0); l.w32(1);                              // sub-record: flags type 1 -> 20
      for (int i = 0; i < 16; i++) l.raw(0);
      l.w32(0); l.w32(2);                              // flags type 2 -> 12
      for (int i = 0; i < 8; i++) l.raw(0);
      l.w32(0); l.w32(0);                              // flags type 0 -> stop
      l.w32(0);                                        // the trailing 4 words
      l.w32(1); l.w32(0xa1); l.w32(0xa2); l.w32(0xa3); // must be found after it
      l.w32(0x0f);
      compare("direct walk", t, l.m);
      check(t.d->dbg_objects == 1, "the object after a direct block must be found"); }

    printf("test: a type word with HIGH BITS set ends the list\n");
    { L l; l.w32(0x00010000); l.w32(1); l.w32(1); l.w32(2); l.w32(3); l.w32(0x0f);
      compare("high bits in type", t, l.m);
      check(t.d->dbg_objects == 0, "0x00010000 is not command 1 and not a nop");
      check(t.d->dbg_bad_type == 1, "and it is flagged as a bad type"); }

    printf("test: an unknown type ends the list and is flagged\n");
    { L l; l.w32(0x1e); l.w32(1); l.w32(1); l.w32(2); l.w32(3); l.w32(0x0f);
      compare("unknown type", t, l.m);
      check(t.d->dbg_bad_type == 1, "an unknown type must be flagged"); }

    printf("test: nops advance two words, not four\n");
    { L l; l.w32(0); l.w32(0); l.w32(0); l.w32(1); l.w32(1); l.w32(2); l.w32(3); l.w32(0x0f);
      compare("nops", t, l.m);
      check(t.d->dbg_objects == 1, "the object after three nops must be found"); }

    printf("test: fuzz, random lists compared event by event\n");
    {
        std::mt19937 rng(0x11577aeu);              // fixed seed: reproducible
        long objs = 0, longest = 0;
        int kinds[] = {0, 1, 0x41, 2, 3, 4, 5, 6, 7, 8, 9, 0xa, 0xb, 0xc};
        for (int iter = 0; iter < 3000; iter++) {
            L l;
            int ncmd = 1 + (int)(rng() % 12);
            for (int c = 0; c < ncmd && l.m.size() < 0x7000; c++) {
                int k = kinds[rng() % 14];
                l.w32(k);
                switch (k) {
                case 0: break;
                case 1: case 0x41: case 0xa:
                    for (int i = 0; i < 3; i++) l.w32(rng()); break;
                case 2: {
                    for (int i = 0; i < 16; i++) l.raw(rng());
                    int nrec = (int)(rng() % 4);
                    for (int r = 0; r < nrec; r++) {
                        int tt = 1 + (int)(rng() % 3);      // 1, 2 or 3
                        l.w32(rng()); l.w32(tt);
                        int body = (tt == 2) ? 8 : 16;
                        for (int i = 0; i < body; i++) l.raw(rng());
                    }
                    l.w32(rng()); l.w32(0);                 // terminator record
                    l.w32(rng());                           // trailing 4 words
                    break;
                }
                case 3:
                    l.w32(rng());
                    for (int i = 0; i < 6; i++) l.w16((uint16_t)rng());
                    break;
                case 4: case 5: case 6: {
                    uint32_t len = rng() % 6;
                    l.w32(rng()); l.w32(len);
                    int n = (k == 4) ? (int)len + 1 : (int)len;
                    for (int i = 0; i < n; i++) {
                        if (k == 4) l.w16((uint16_t)rng()); else l.w32(rng());
                    }
                    break;
                }
                case 7: case 8: l.w32(rng()); break;
                case 9: case 0xc: for (int i = 0; i < 2; i++) l.w32(rng()); break;
                case 0xb: for (int i = 0; i < 12; i++) l.w32(rng()); break;
                }
            }
            l.w32(0x0f);
            if (!compare("fuzz", t, l.m)) break;
            objs += t.d->dbg_objects;
            if (t.d->dbg_cmds > longest) longest = t.d->dbg_cmds;
        }
        printf("  %ld objects decoded, longest list %ld commands\n", objs, longest);
        check(objs > 500, "the fuzz must actually decode objects");
    }

    printf("test: a list of nothing but nops TERMINATES instead of wedging\n");
    {
        // MAME loops forever on this: readi masks with 0x7fff, so the walk wraps
        // to word 0 and never leaves. The RTL stops at the end of the buffer,
        // which is the one deliberate difference from the reference.
        std::vector<uint16_t> zeros(0x8000, 0);
        t.reset();
        t.mem = zeros;
        check(t.run(), "an all-nop list must still finish");
        check(t.d->dbg_overrun == 1, "and must report that it ran off the end");
        printf("  walked %u commands before the end of the buffer\n",
               (unsigned)t.d->dbg_cmds);
    }

    printf("test: STALLING pauses the walk without losing anything\n");
    {
        // The consumer needs thousands of cycles per object and this module has
        // no output backpressure, so a stall is the only thing that stops it
        // walking to the end of the list and emitting into a consumer that is
        // not listening. Measured before it existed: 136 quads of an expected
        // 2,001, and a `done` that arrived while nobody was watching.
        L l;
        for (int i = 0; i < 5; i++) { l.w32(1); l.w32(0x100 + i); l.w32(0x200 + i); l.w32(3); }
        l.w32(0x0f);
        t.reset();
        t.mem.assign(0x8000, 0);
        for (size_t i = 0; i < l.m.size(); i++) t.mem[i] = l.m[i];
        std::vector<Ev> exp = model(t.mem);

        t.got.clear();
        t.d->start = 1; t.tick(); t.d->start = 0;
        int guard = 0;
        size_t before_stall = 0;
        while (!t.d->done && ++guard < 200000) {
            // Stall for a long stretch part way through, as a consumer drawing
            // an object would.
            if (t.got.size() >= 4 && before_stall == 0) {
                before_stall = t.got.size();
                t.d->stall = 1;
                for (int k = 0; k < 500; k++) t.tick();
                checks++;
                if (t.got.size() != before_stall) {
                    fails++;
                    printf("  FAIL events were emitted while stalled (%zu -> %zu)\n",
                           before_stall, t.got.size());
                }
                checks++;
                if (t.d->done) { fails++; printf("  FAIL done asserted while stalled\n"); }
                t.d->stall = 0;
            }
            t.tick();
        }
        checks++;
        if (t.got.size() != exp.size()) {
            fails++;
            printf("  FAIL stalled walk produced %zu events, expected %zu\n",
                   t.got.size(), exp.size());
        } else {
            bool ok = true;
            for (size_t i = 0; i < exp.size(); i++) if (exp[i] != t.got[i]) ok = false;
            checks++;
            if (!ok) { fails++; printf("  FAIL a stalled walk produced different events\n"); }
            else printf("  paused 500 cycles mid-walk, %zu events, all identical\n", t.got.size());
        }
    }

    printf("test: fuzz on RANDOM GARBAGE - the walk must match the model exactly\n");
    {
        // Not well-formed lists: whole buffers of random words. Both sides have
        // to agree on where the garbage stops being decodable, which is the
        // property that matters when our V60 writes a list we do not expect.
        std::mt19937 rng(0x9e3779b9u);
        long ended_bad = 0, ended_clean = 0, overran = 0;
        for (int iter = 0; iter < 400; iter++) {
            std::vector<uint16_t> junk(0x8000);
            // Mostly small values, so the type word lands on real commands often
            // enough to walk somewhere rather than ending on the first word.
            for (auto& w : junk)
                w = (rng() & 7) ? (uint16_t)(rng() % 0x10) : (uint16_t)rng();
            t.reset();
            t.mem = junk;
            if (!t.run()) { printf("  FAIL garbage fuzz: never finished\n"); fails++; checks++; break; }
            std::vector<Ev> exp = model(t.mem);
            checks++;
            bool ok = exp.size() == t.got.size();
            for (size_t i = 0; ok && i < exp.size(); i++) ok = !(exp[i] != t.got[i]);
            if (!ok) {
                fails++;
                if (printed++ < 20)
                    printf("  FAIL garbage fuzz iter %d: %zu events, expected %zu\n",
                           iter, t.got.size(), exp.size());
                break;
            }
            if (t.d->dbg_overrun) overran++;
            else if (t.d->dbg_bad_type) ended_bad++;
            else ended_clean++;
        }
        printf("  %ld ended on a bad type, %ld on 0x0f, %ld ran off the end\n",
               ended_bad, ended_clean, overran);
        check(ended_bad > 50, "garbage must mostly end on an unrecognised type");
    }

    printf("m1_listwalk: checks=%ld fails=%ld\n", checks, fails);
    return fails ? 1 : 0;
}
