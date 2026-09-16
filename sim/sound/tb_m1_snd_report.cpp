// Sega Model 1 core for MiSTer FPGA — m1_snd_report directed bench
//
// The module exists to answer "where between the samples arriving and the mix
// does the sound die", so a formatter that prints the wrong field, or prints a
// stale value, would send the next board trip after a fiction. This decodes the
// UART bit stream exactly as a terminal would and checks each field against
// what was driven.
#include <cstdio>
#include <cstdint>
#include <string>
#include <vector>
#include "Vm1_snd_report.h"
#include "verilated.h"

static long checks = 0, fails = 0;
static void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; printf("  FAIL %s\n", what); }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* d = new Vm1_snd_report;

    // CLK_HZ/BAUD are overridden small so a line costs thousands of cycles, not
    // hundreds of millions; the bit period is CLK_HZ/BAUD = 10 cycles.
    const int BITCYC = 10;

    // A PROPER UART RECEIVER. The first attempt sampled on a counter that
    // drifted and lost the leading and trailing byte of every line, which read
    // exactly like the formatter dropping characters -- it was not, the fields
    // were all correct. Sample in the MIDDLE of each bit, like real hardware.
    std::string line;
    enum { IDLE, START, DATA, STOP } st = IDLE;
    int cnt = 0, bit = 0, sh = 0;
    auto uart_sample = [&]() {
        switch (st) {
        case IDLE:
            if (!d->tx) { st = START; cnt = 0; }
            break;
        case START:
            if (++cnt >= BITCYC / 2) {          // middle of the start bit
                if (d->tx) st = IDLE;           // glitch, not a real start
                else { st = DATA; cnt = 0; bit = 0; sh = 0; }
            }
            break;
        case DATA:
            if (++cnt >= BITCYC) {              // one full bit on, so mid-bit
                cnt = 0;
                sh |= (d->tx ? 1 : 0) << bit;
                if (++bit == 8) st = STOP;
            }
            break;
        case STOP:
            if (++cnt >= BITCYC) { line.push_back((char)sh); st = IDLE; cnt = 0; }
            break;
        }
    };

    auto tick = [&]() {
        d->clk = 0; d->eval();
        d->clk = 1; d->eval();
        uart_sample();
    };

    d->rst_n = 0;
    d->v60_bytes = 0; d->insns = 0; d->ym_writes = 0; d->pcm_writes = 0;
    d->pcm_samples = 0; d->pcm_level = 0; d->pcm_under = 0; d->snd_l = 0;
    for (int i = 0; i < 40; i++) tick();
    d->rst_n = 1;

    // Distinct values per field so a mis-wired field cannot pass by luck.
    d->v60_bytes   = 0x1234;
    d->insns       = 0xabcd;
    d->ym_writes   = 0x00ef;
    d->pcm_writes  = 0x5a5a;
    d->pcm_samples = 0x0f0f;
    d->pcm_level   = 0x7e;   // still a port; the top level ties it off
    d->pcm_under   = 0x0042;
    d->snd_l       = -300;          // peak should report the MAGNITUDE, 0x012c

    printf("test: the line carries every field, as hex, in order\n");
    line.clear();
    for (int i = 0; i < 400000 && line.find('\n') == std::string::npos; i++) tick();

    check(line.find('\n') != std::string::npos, "no line was ever emitted");
    if (line.find('\n') == std::string::npos) {
        printf("m1_snd_report: checks=%ld fails=%ld\n", checks, fails);
        return 1;
    }
    std::string l = line.substr(0, line.find('\r'));
    printf("  got: \"%s\"\n", l.c_str());

    const char* want = "r=1234 i=abcd y=00ef p=5a5a s=0f0f v=7e u=0042 m=012c";
    check(l == want, "line text");
    if (l != want) printf("  want: \"%s\"\n", want);

    // The peak must be a WINDOW, not an all-time high: a burst that has passed
    // must stop being reported or every line after the first reads the same.
    printf("test: the peak is per-line, not an all-time high\n");
    d->snd_l = 0;
    // Two lines: the first still carries the peak from the window just ended.
    for (int pass = 0; pass < 2; pass++) {
        line.clear();
        for (int i = 0; i < 400000 && line.find('\n') == std::string::npos; i++) tick();
    }
    std::string l2 = line.substr(0, line.find('\r'));
    printf("  got: \"%s\"\n", l2.c_str());
    check(l2.find("m=0000") != std::string::npos,
          "peak did not fall back after the signal stopped");

    // And it must FOLLOW a new peak on the very next line.
    printf("test: a new peak appears on the next line\n");
    d->snd_l = 0x4000;
    line.clear();
    for (int i = 0; i < 400000 && line.find('\n') == std::string::npos; i++) tick();
    std::string l3 = line.substr(0, line.find('\r'));
    printf("  got: \"%s\"\n", l3.c_str());
    check(l3.find("m=4000") != std::string::npos, "new peak not reported");

    printf("m1_snd_report: checks=%ld fails=%ld\n", checks, fails);
    return fails ? 1 : 0;
}
