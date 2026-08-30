#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Diff the SEQUENCE OF VALUES the V60 writes to the tile scroll registers against
# the reference's. "Is scrolling fixed" is this comparison, not a change count:
# the value at word 0x5006 is 0x2000 | (split line) and 0x5002 is tilemap 2's
# hscr, both derived from coprocessor answers, and if the written sequence
# matches the reference's in order then the background moves as the board's.
#
# Compared per register, in write order, and ALSO as the sequence of DISTINCT
# values (consecutive repeats collapsed) - the game rewrites both registers
# once a frame whether or not they changed, so at 1.25x slower we make fewer
# writes per unit of game progress and a raw diff would report that as a
# divergence. The distinct-value sequence is what the picture actually shows.
#
#   ours:  build/frame_streams.txt      SCROLL wwww vvvv f=N
#   MAME:  build/dasm/mame_scrollw.txt  SCROLL wwww vvvv f=N
import sys

def load(path):
    per = {"5002": [], "5006": []}
    for line in open(path):
        p = line.split()
        if len(p) >= 3 and p[0] == "SCROLL" and p[1] in per:
            per[p[1]].append((p[2].lower(), p[3] if len(p) > 3 else ""))
    return per

def distinct(seq):
    out = []
    for v, f in seq:
        if not out or out[-1][0] != v:
            out.append((v, f))
    return out

def first_diff(a, b):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i][0] != b[i][0]:
            return i
    return None

def report(name, a, b):
    d = first_diff(a, b)
    n = min(len(a), len(b))
    if d is None:
        print("  %s: IDENTICAL over %d (ours %d, MAME %d)" % (name, n, len(a), len(b)))
    else:
        print("  %s: first divergence at %d of %d compared" % (name, d, n))
        lo = max(0, d - 5)
        print("    MAME:", " ".join("%s@%s" % (v, f) for v, f in b[lo:d + 4]))
        print("    ours:", " ".join("%s@%s" % (v, f) for v, f in a[lo:d + 4]))

def main():
    ours = load("build/frame_streams.txt")
    mame = load("build/dasm/mame_scrollw.txt")
    for reg in ("5002", "5006"):
        print("register %s, raw write order:" % reg)
        report(reg, ours[reg], mame[reg])
        print("register %s, distinct values in order:" % reg)
        report(reg, distinct(ours[reg]), distinct(mame[reg]))
    return 0

if __name__ == "__main__":
    sys.exit(main())
