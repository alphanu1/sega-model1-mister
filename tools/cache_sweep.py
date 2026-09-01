#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# HOW BIG A CACHE, AND WHAT SHAPE? Measured from the program, not guessed.
#
# The V60's SDRAM accesses cost 33 clk against 7.8 for on-chip block RAM (see
# docs/findings.md 2026-09-01) and are 72% of its data traffic, so a cache is
# worth ALM. What it is worth depends on the HIT RATE, which is a property of
# Virtua Racing's working set rather than of the RTL - so measure it on the real
# access stream before committing a geometry to silicon.
#
# Reads only. Writes are 21% of SDRAM traffic and a write-through cache does not
# make them faster; a posted write buffer is a separate lever and is reported
# separately here.
#
#   build/cache_trace.txt : "<word-address-hex> <is_write>" per SDRAM access
import sys, collections

path = sys.argv[1] if len(sys.argv) > 1 else "build/cache_trace.txt"
acc = []
with open(path) as f:
    for line in f:
        a, w = line.split()
        acc.append((int(a, 16), w == "1"))
reads  = sum(1 for _, w in acc if not w)
writes = len(acc) - reads
print(f"{len(acc):,} SDRAM accesses: {reads:,} reads ({100*reads/len(acc):.0f}%), "
      f"{writes:,} writes ({100*writes/len(acc):.0f}%)\n")

def sweep(kb, line_words, ways):
    total_words = kb * 512                     # kb KiB of 16-bit words
    lines = total_words // line_words
    sets  = lines // ways
    if sets == 0: return None
    tags = [collections.OrderedDict() for _ in range(sets)]
    hits = miss = 0
    for a, w in acc:
        ln  = a // line_words
        idx = ln % sets
        tag = ln // sets
        d   = tags[idx]
        if tag in d:
            if not w: hits += 1
            d.move_to_end(tag)
        else:
            if not w: miss += 1
            # A write allocates too: the line is fetched to merge, and the next
            # read of it then hits. No-write-allocate is a separate question.
            d[tag] = True
            if len(d) > ways: d.popitem(last=False)
    return 100.0 * hits / (hits + miss)

print(f"{'size':>6} {'line':>6} {'ways':>5} {'read hit':>9}   M10K data+tag (approx)")
for kb in (4, 8, 16, 32, 64):
    for lw in (4, 8, 16):
        for ways in (1, 2, 4):
            h = sweep(kb, lw, ways)
            if h is None: continue
            data_bits = kb * 1024 * 8
            lines = (kb * 512) // lw
            tagbits = max(1, 24 - (lw.bit_length() - 1) - ((lines // ways).bit_length() - 1))
            tag_bits = lines * (tagbits + 1)
            m10k = -(-data_bits // 10240) + -(-tag_bits // 10240)
            print(f"{kb:>4}KB {lw:>4}w {ways:>4}w {h:>8.1f}%   ~{m10k} M10K")
