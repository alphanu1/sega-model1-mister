#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Diff our tile RAM / palette against MAME's, word for word.
#
# EVERY MEASUREMENT ON THIS CORE HAS BEEN AN AGGREGATE - pixels won per layer,
# character writes, non-zero mask writes, scroll register values - and an
# aggregate cannot say WHICH WORD is wrong. The Model 2 core had this same
# symptom, a menu with coloured values and no white labels, and named it in one
# step by diffing contents rather than counts:
#
#     tile RAM differs in 13 words of 32768
#     pal[1] <= ffff at instruction 1478810, <= 0000 at 1713595
#
# which located a CPU divergence past the window it had been verified to.
#
#   make m1_frame FRAME_CYCLES=1500000000          -> build/frame_tram.hex, frame_pal.hex
#   mame ... -autoboot_script tools/mame_m1_dump.lua -> mame_tram.hex, mame_pal.hex
#   tools/tram_diff.py build/frame_tram.hex mame_tram.hex
#
# THE TWO SIDES MUST BE AT THE SAME PLACE IN THE PROGRAM, not the same frame
# number. Our core runs at about 84% of real speed, so equal frame counts are
# different program states - that mistake produced a confident wrong finding on
# this project once already. Prefer a point the game holds still.
import sys, collections

def load(p):
    out = []
    for line in open(p):
        line = line.strip()
        if line:
            out.append(int(line, 16))
    return out

def main(ours_p, theirs_p, label="tile RAM"):
    a, b = load(ours_p), load(theirs_p)
    n = min(len(a), len(b))
    if len(a) != len(b):
        print("NOTE: lengths differ, %d vs %d; comparing the first %d" %
              (len(a), len(b), n))
    diffs = [(i, a[i], b[i]) for i in range(n) if a[i] != b[i]]
    print("%s: %d of %d words differ (%.2f%%)" %
          (label, len(diffs), n, 100.0 * len(diffs) / (n or 1)))
    if not diffs:
        print("  identical")
        return 0

    # A pattern in the addresses is usually the answer: a constant stride is a
    # loop, a contiguous run is a block copy, and one isolated entry is a single
    # store worth tracing.
    strides = collections.Counter()
    for j in range(1, min(len(diffs), 400)):
        strides[diffs[j][0] - diffs[j-1][0]] += 1
    if strides:
        print("  commonest address strides:",
              ", ".join("%d x%d" % (s, c) for s, c in strides.most_common(4)))

    zero_ours  = sum(1 for _, x, y in diffs if x == 0 and y != 0)
    zero_thei  = sum(1 for _, x, y in diffs if y == 0 and x != 0)
    print("  we hold 0000 where the reference does not: %d" % zero_ours)
    print("  the reference holds 0000 where we do not:  %d" % zero_thei)

    print("  first 20:")
    for i, x, y in diffs[:20]:
        print("    [%05x]  ours %04x   ref %04x" % (i, x, y))
    return 1

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__ or "usage: tram_diff.py <ours.hex> <theirs.hex> [label]")
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2],
                  sys.argv[3] if len(sys.argv) > 3 else "tile RAM"))
