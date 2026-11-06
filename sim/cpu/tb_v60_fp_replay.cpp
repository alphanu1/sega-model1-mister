// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// THE V60'S FLOATING POINT, REPLAYED AGAINST MAME'S OWN OPERANDS.
//
// Every FP instruction MAME's V60 executed in a window of real game code -
// operands, TKCW, the PSW before and the destination and PSW after - is fed,
// in the order MAME ran them, through v60_fp, and the result and the four
// flags are compared bit for bit, the flags as v60.sv applies them: the ones
// the instruction writes (o_fmask) from the unit, the rest kept from the PSW
// before. Before o_fmask existed the CPU copied all four on every FP
// instruction, and CVTSW's CY came out of whatever FP op ran last.
//
//   tb_v60_fp_replay <vectors.txt>     (tools/v60_fp_capture.py)
#include "Vv60_fp.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { printf("usage: %s vectors.txt\n", argv[0]); return 2; }
    FILE* f = fopen(argv[1], "r");
    if (!f) { printf("SKIP: %s not found\n", argv[1]); return 0; }
    Vv60_fp* d = new Vv60_fp;
    auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };
    d->ce = 1; d->rst = 1; d->start = 0; tick(); tick(); d->rst = 0; tick();
    char pc[16];
    unsigned op, sub, a, b, cw, pswb, res, pswa;
    long n = 0, bad_res = 0, bad_flag = 0, shown = 0;
    std::map<std::string, long> by_kind;
    const char* fl = "ZSVC";
    while (fscanf(f, "%15s %x %x %x %x %x %x %x %x", pc, &op, &sub, &a, &b, &cw, &pswb, &res, &pswa) == 9) {
        d->op = op; d->subop = sub; d->a = a; d->b = b; d->cw = cw;
        d->start = 1; tick(); d->start = 0;
        int guard = 0;
        while (!d->done && guard++ < 200) tick();
        if (!d->done) { printf("FAIL: %s op %02x/%02x never finished\n", pc, op, sub); return 1; }
        // As v60.sv applies them: a flag the instruction does not write
        // (o_fmask) keeps the PSW it had before, which is MAME's PSW before.
        unsigned unit_f = (d->o_z ? 1 : 0) | (d->o_s ? 2 : 0) | (d->o_ov ? 4 : 0) | (d->o_cy ? 8 : 0);
        unsigned mask = d->o_fmask;
        unsigned ours_f = (unit_f & mask) | (pswb & 0xf & ~mask);
        unsigned mame_f = pswa & 0xf;
        bool writes = d->writes;
        bool rbad = writes && (d->result != res);
        bool fbad = ours_f != mame_f;
        tick();   // F_DONE -> F_IDLE
        n++;
        if (rbad) bad_res++;
        if (fbad) bad_flag++;
        if (rbad || fbad) {
            char k[64]; snprintf(k, sizeof k, "%s %02x/%02x %s%s", pc, op, sub, rbad ? "result " : "", fbad ? "flags" : "");
            by_kind[k]++;
            if (shown++ < 20) {
                printf("  #%ld %s op %02x/%02x a=%08x b=%08x cw=%x psw_before=%x | MAME %08x flags ", n, pc, op, sub, a, b, cw, pswb & 0xf, res);
                for (int i = 0; i < 4; i++) putchar(mame_f >> i & 1 ? fl[i] : '-');
                printf(" | ours %08x flags ", writes ? (unsigned)d->result : 0u);
                for (int i = 0; i < 4; i++) putchar(ours_f >> i & 1 ? fl[i] : '-');
                printf("\n");
            }
        }
    }
    fclose(f);
    for (auto& kv : by_kind) printf("  %-40s %ld\n", kv.first.c_str(), kv.second);
    printf("v60_fp_replay: ops=%ld result_differs=%ld flags_differ=%ld\n", n, bad_res, bad_flag);
    delete d;
    return (bad_res || bad_flag) ? 1 : 0;
}
