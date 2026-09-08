// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE TELEMETRY LINE, DECODED OFF THE SERIAL PIN.
//
// This module had no testbench, and the cost of that is on record. The line is
// the only instrument the board has - the debug overlay is off - and it has
// been silently wrong twice for the same reason: the character index was too
// narrow for the line, so the terminator index wrapped and every report ended
// early and restarted. At six bits it repeated its middle; at seven bits, with
// a 141-byte line, 7'(NCH-1) truncated 140 to 12 and the board sent
// "F=003A S=001D" over and over. On the wire that reads as UART corruption
// rather than as an arithmetic width, and it cost a full build cycle to find.
//
// So this decodes the actual UART_TXD pin at the configured baud - not the
// internal character strobe - and checks the whole line end to end: the field
// count, every letter, every value against what was driven in, the separators,
// and exactly one CR LF. A truncated or repeating line fails here now instead
// of on Ben's screen.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include "Vm1_speed_report.h"
#include "verilated.h"

static Vm1_speed_report* dut;
static long checks = 0, fails = 0;

static void fail(const char* what, const std::string& got) {
    if (fails < 20) printf("  FAIL %s: got \"%s\"\n", what, got.c_str());
    fails++;
}

// vblank is driven from inside tick() so the report keeps being retriggered
// while the decoder is busy walking bits. Driving it from the outer loop
// instead starves the transmitter, which is what made the first version of
// this bench capture two thirds of a line and call it a failure.
static long tickno = 0;
static void tick() {
    // A line is 191 bytes and a byte is ten bits of ten cycles, so a report
    // needs 19,100 cycles to get out. With PERIOD=2 a vblank every 400 cycles
    // retriggers it every eight characters and the line restarts for ever -
    // which is a fair imitation of the bug this bench exists to catch, and it
    // fooled the first version of the bench itself.
    dut->vblank = ((tickno % 15000) == 0) ? 1 : 0;
    tickno++;
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}

// The DUT is built at a deliberately small CLK_HZ so a bit is a handful of
// cycles; decoding at the real 80 MHz would need 1.3 million cycles a line and
// say nothing extra.
static const int CLK_HZ = 11520;      // 10 cycles per bit at 1152 baud
static const int BAUD   = 1152;
static const int DIV    = CLK_HZ / BAUD;

// Sample the middle of each bit, which is what a real receiver does and what
// catches an off-by-one in the transmitter's own divider.
static std::vector<uint8_t> capture(int max_bytes, long max_cycles) {
    std::vector<uint8_t> out;
    long c = 0;
    while ((int)out.size() < max_bytes && c < max_cycles) {
        // Wait for a start bit.
        while (dut->tx && c < max_cycles) { tick(); c++; }
        if (c >= max_cycles) break;
        for (int i = 0; i < DIV / 2; i++) { tick(); c++; }   // middle of start
        uint8_t b = 0;
        for (int i = 0; i < 8; i++) {
            for (int k = 0; k < DIV; k++) { tick(); c++; }
            if (dut->tx) b |= (1 << i);
        }
        for (int k = 0; k < DIV; k++) { tick(); c++; }       // stop
        out.push_back(b);
    }
    return out;
}

struct Field { char letter; uint32_t value; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vm1_speed_report;

    dut->rst_n = 0;
    dut->list_sel = 0;
    for (int i = 0; i < 20; i++) tick();
    dut->rst_n = 1;

    // Distinct values per field, so a mux that returns the wrong one cannot
    // pass by coincidence. Anything that must survive a 16-bit path stays
    // inside it; the two PCs are 24-bit on purpose.
    dut->bands        = 0x1234;
    dut->passes       = 0x2345;
    dut->tgp_pc       = 0x3456;
    dut->tgp_retires  = 0x4567;
    dut->bands_pres   = 0x5678;
    dut->v60_pc       = 0xABCDEF;
    dut->stall_pc     = 0x123456;
    dut->pass_cycles  = 0x000A1200;   // reported >> 8
    dut->band_cycles  = 0x0000B300;   // reported >> 4
    dut->late         = 0x6789;
    dut->dropped      = 0x789A;
    dut->short_passes = 0x89AB;
    dut->view_x1      = 0x9ABC;
    dut->fetch_miss   = 0xABCD;
    dut->vert_oob     = 0xBCDE;
    dut->culled       = 0xEF01;
    dut->quads        = 0xF012;
    dut->hit_l        = 0x0123;
    dut->hit_r        = 0x1234;
    dut->plane_l      = 0xBF80;   // -1.0f's top half, a plausible plane
    dut->clip_in      = 0x1357;
    dut->clip_out     = 0x2468;
    dut->clip_drop    = 0x369C;
    dut->mat_race     = 0x4812;
    dut->plane_race   = 0x5A3B;
    dut->lw_stall_q   = 0x6C4D;
    dut->list_race    = 0x2B7E;
    dut->vx_q         = 0x7E5F;
    dut->xc_q         = 0x43C4;
    dut->zx_q         = 0x438C;
    dut->lw_bad_q     = 0x1A2B;
    dut->lw_over_q    = 0x3C4D;
    dut->ctrl_hi      = 0x2300;   // pair 2/3, window mode 1
    dut->ctrl_lo      = 0x0011;
    dut->hud_obj      = 0x0042;
    dut->px_left      = 0xCDEF;
    dut->px_right     = 0xDEF0;
    dut->mem_occ      = 0x5A;
    dut->mem_wait     = 0xA5;

    // Enough for a partial line, then two whole ones - the line checked below
    // is the second, so nothing about the first report after reset can flatter
    // the result.
    // Two lines' worth. Each field is 9 bytes and the count has grown from 29
    // to 38 (line 344 bytes), so 700 no longer guaranteed a COMPLETE line
    // between two newlines - the bench passed a header and failed to find one.
    std::vector<uint8_t> bytes = capture(1400, 300000000L);

    std::string all((const char*)bytes.data(), bytes.size());

    // ---------------------------------------------------------------- shape
    size_t nl = 0;
    for (char c : all) if (c == '\n') nl++;
    checks++;
    if (nl == 0) { fail("no complete line was transmitted", all.substr(0, 60)); }

    // Take the first complete line between a LF and the next LF, so a partial
    // first capture cannot skew the result.
    size_t a = all.find('\n');
    size_t b = (a == std::string::npos) ? std::string::npos : all.find('\n', a + 1);
    if (a == std::string::npos || b == std::string::npos) {
        printf("m1_speed_report: checks=%ld fails=%ld (no full line captured, %zu bytes)\n",
               checks, fails + 1, bytes.size());
        return 1;
    }
    std::string line = all.substr(a + 1, b - a - 1);

    // Strip the CR.
    checks++;
    if (line.empty() || line[line.size() - 1] != '\r')
        fail("line does not end with CR", line);
    else
        line = line.substr(0, line.size() - 1);

    // -------------------------------------------------------------- fields
    const Field want[] = {
        {'F', 0}, {'S', 0}, {'B', 0x1234}, {'P', 0x2345},
        {'C', 0x3456}, {'R', 0x4567}, {'N', 0x5678},
        {'V', 0xABCDEF}, {'X', 0x123456},
        {'L', 0x0A12}, {'T', 0x6789}, {'W', 0x0B30},
        {'D', 0x789A}, {'H', 0x89AB}, {'K', 0x9ABC}, {'M', 0xABCD},
        {'O', 0x5A}, {'Q', 0xA5},
        {'A', 0xCDEF}, {'Z', 0xDEF0}, {'G', 0xBCDE},
        {'E', 0xEF01}, {'U', 0xF012}, {'I', 0x0123}, {'J', 0x1234}, {'Y', 0xBF80}, {'w', 0x2300}, {'v', 0x0011},
        // The clipper's funnel, added 2026-09-09 for the left-side cut:
        // quads in, quads out, quads it discarded.
        {'c', 0x1357}, {'d', 0x2468}, {'e', 0x369C},
        {'f', 0x4812}, {'g', 0x5A3B}, {'i', 0x6C4D},
        {'j', 0x7E5F}, {'k', 0x43C4}, {'l', 0x438C}, {'m', 0x1A2B}, {'n', 0x3C4D},
        {'h', 0x0042},
        // The LIST race, added 2026-09-08: passes the game flipped out from
        // under the walker. f and g cover the matrix and plane races and both
        // read zero on the board; nothing had ever watched the list buffer.
        {'p', 0x2B7E},
    };
    const int NF = sizeof(want) / sizeof(want[0]);
    const int FW = 9;

    checks++;
    if ((int)line.size() != NF * FW) {
        char m[128];
        snprintf(m, sizeof m, "line is %zu bytes, expected %d", line.size(), NF * FW);
        fail(m, line);
    }

    for (int f = 0; f < NF && (f + 1) * FW <= (int)line.size(); f++) {
        std::string fs = line.substr(f * FW, FW);
        checks++;
        if (fs[0] != want[f].letter || fs[1] != '=' || fs[8] != ' ') {
            char m[128];
            snprintf(m, sizeof m, "field %d shape (expected '%c=...' and a space)",
                     f, want[f].letter);
            fail(m, fs);
            continue;
        }
        // F and S are a frame counter and a swap counter, free-running from
        // inputs this bench does not drive, so only their SHAPE is checked.
        if (want[f].letter == 'F' || want[f].letter == 'S') continue;
        uint32_t got = (uint32_t)strtoul(fs.substr(2, 6).c_str(), nullptr, 16);
        checks++;
        if (got != want[f].value) {
            char m[128];
            snprintf(m, sizeof m, "field %c is %06x, expected %06x",
                     want[f].letter, got, want[f].value);
            fail(m, fs);
        }
    }

    // ------------------------------------------------- the truncation guard
    // Both historic failures showed up as the line RESTARTING early, so the
    // same field letter appears twice. Assert directly on that.
    for (int f = 0; f < NF; f++) {
        int seen = 0;
        for (int g = 0; g + FW <= (int)line.size(); g += FW)
            if (line[g] == want[f].letter) seen++;
        checks++;
        if (seen != 1) {
            char m[128];
            snprintf(m, sizeof m, "field letter %c appears %d times - the line "
                     "restarted, which is the truncation bug",
                     want[f].letter, seen);
            fail(m, line);
        }
    }

    printf("m1_speed_report: checks=%ld fails=%ld line=%d bytes, %d fields\n",
           checks, fails, (int)line.size(), NF);
    delete dut;
    return fails ? 1 : 0;
}
