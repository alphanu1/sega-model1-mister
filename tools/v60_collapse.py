#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Collapse periodic wait loops in a PC trace, so two traces that spin a different
# number of times can still be compared.
#
# WHY THIS IS NEEDED
#
# Collapsing consecutive REPEATS handles a branch-to-self (`dbr R0, FFA6BD[PC]`),
# which was the first artifact this tool hit. It does nothing for a two-address
# poll loop:
#
#   FE022C: test.b C00040
#   FE0232: bne    FE022C
#
# The addresses alternate, so no two consecutive lines are equal and the run
# survives collapsing intact. The I/O board handshake spins here for 36,308
# iterations in the reference and 41,147 in our core — not because either is
# wrong, but because our poll loop takes 18 CPU cycles an iteration against the
# reference's 17, on a deadline that is correct in CYCLES to within 38. The diff
# then reports a divergence at whichever side leaves the loop first, which is a
# statement about CPI in three instructions, not about correctness.
#
# So: find the shortest repeating period at each point, keep ONE instance, and
# REPORT the iteration counts instead of discarding them silently. A difference in
# how many times a loop ran is real information — it just is not a divergence, and
# hiding it entirely is how an instrument starts lying.
#
#   v60_collapse.py <in> <out> [--counts <file>]

import sys

MAX_PERIOD = 8      # a wait loop is a handful of instructions; beyond that a
                    # repeating block is more likely real work worth comparing.

def collapse(lines):
    out = []
    # loops[i] = (period_tuple, iterations) for the cycle that ends at out[i]
    counts = []
    for x in lines:
        out.append(x)
        while True:
            hit = False
            for p in range(1, MAX_PERIOD + 1):
                if len(out) >= 2 * p and out[-p:] == out[-2 * p:-p]:
                    del out[-p:]
                    key = (len(out) - p, tuple(out[-p:]))
                    if counts and counts[-1][0] == key:
                        counts[-1][1] += 1
                    else:
                        counts.append([key, 2])
                    hit = True
                    break
            if not hit:
                break
    return out, counts

def main():
    src, dst = sys.argv[1], sys.argv[2]
    cfile = None
    if "--counts" in sys.argv:
        cfile = sys.argv[sys.argv.index("--counts") + 1]
    lines = [l.strip() for l in open(src) if l.strip()]
    out, counts = collapse(lines)
    with open(dst, "w") as f:
        f.write("\n".join(out) + ("\n" if out else ""))
    if cfile:
        with open(cfile, "w") as f:
            for (pos, period), n in counts:
                f.write("%d %d %s\n" % (pos, n, ",".join(period)))
    sys.stderr.write("  collapsed %d -> %d lines, %d loops\n"
                     % (len(lines), len(out), len(counts)))

main()
