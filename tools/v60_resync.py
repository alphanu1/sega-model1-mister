#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Diff two collapsed V60 PC streams and KEEP GOING after a difference.
#
# WHY THIS EXISTS
#
# v60_trace.sh used cmp, which stops at the first differing line. That was fine
# while the streams diverged early and permanently. It is not fine now: the first
# difference is an INTERRUPT LANDING ONE INSTRUCTION LATER inside a poll loop —
#
#     MAME:  ... fe1435 fe143d fe1433 fe1435 fe143d | fe02bc (irq entry)
#     ours:  ... fe1435 fe143d fe1433 fe1435        | fe02bc (irq entry)
#
# — which is a phase difference, not a fault, and reporting it consumed two
# sessions' worth of attention while 79,000 further instructions went uncompared.
#
# This walks both streams, and on a mismatch looks ahead in each for a window of
# K consecutive instructions that agree. The skipped runs are reported with their
# lengths, and comparison continues. A phase difference shows up as a site with a
# one- or two-instruction skip on one side and zero on the other; a real
# divergence shows up as a site that never resyncs.
import sys

K      = 24     # consecutive matches required to call it resynchronised
WINDOW = 4000   # how far ahead to look on either side

def load(p):
    return [l.strip() for l in open(p) if l.strip()]

def matches(a, b, i, j, k):
    if i + k > len(a) or j + k > len(b):
        return False
    return a[i:i+k] == b[j:j+k]

def main():
    ref, ours = load(sys.argv[1]), load(sys.argv[2])
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 40

    i = j = 0
    sites = []
    while i < len(ref) and j < len(ours):
        if ref[i] == ours[j]:
            i += 1
            j += 1
            continue
        # Nearest resynchronisation point, measured by total skipped
        # instructions so a one-sided phase slip is preferred over a large
        # coincidental match further out.
        best = None
        for total in range(1, 2 * WINDOW):
            for di in range(0, min(total, WINDOW) + 1):
                dj = total - di
                if dj > WINDOW:
                    continue
                if matches(ref, ours, i + di, j + dj, K):
                    best = (di, dj)
                    break
            if best:
                break
        if not best:
            sites.append((i, j, None, None, ref[i:i+8], ours[j:j+8]))
            break
        di, dj = best
        sites.append((i, j, di, dj, ref[i:i+di] or ['-'], ours[j:j+dj] or ['-']))
        i += di
        j += dj

    print("--- compared %d/%d reference and %d/%d our instructions"
          % (i, len(ref), j, len(ours)))
    if not sites:
        print("--- IDENTICAL over the whole compared range")
        return 0
    phase = [s for s in sites if s[2] is not None and s[2] + s[3] <= 2]
    print("--- %d divergence sites (%d of them one-instruction phase slips)"
          % (len(sites), len(phase)))
    for n, (i0, j0, di, dj, rs, os_) in enumerate(sites[:limit]):
        if di is None:
            print("  site %d at ref %d / ours %d: NEVER RESYNCS" % (n, i0, j0))
            print("      reference: %s" % " ".join(rs))
            print("      ours:      %s" % " ".join(os_))
        else:
            tag = "phase slip" if di + dj <= 2 else "DIVERGENCE"
            print("  site %d at ref %d / ours %d: %s, ref +%d ours +%d"
                  % (n, i0, j0, tag, di, dj))
            if di + dj > 2:
                print("      reference only: %s" % " ".join(rs[:12]))
                print("      ours only:      %s" % " ".join(os_[:12]))
    if len(sites) > limit:
        print("  ... %d more sites" % (len(sites) - limit))
    return 0

sys.exit(main())
