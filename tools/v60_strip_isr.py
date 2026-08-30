#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Drop the interrupt handler from a V60 PC trace, so two traces that take the
# interrupt at different INSTRUCTION counts can still be compared.
#
# WHY, ON TOP OF v60_collapse.py
#
# The collapser handles loops that spin a different number of times. It cannot
# help with the interrupt, which arrives on WALL-CLOCK time: the vblank IRQ fires
# at the same rate on both machines, but ours executes fewer instructions between
# two of them, so the handler lands EARLIER in our instruction stream. The diff
# then reports a divergence at the handler entry, which is a statement about CPI,
# not about correctness.
#
# Measured: `make v60_trace` parted at instruction 25,281 on exactly this — MAME
# executing `jsr FF8ABC` where we entered `fe02bc`, an address our own trace
# reaches from five different predecessors, which is what an interrupt vector
# looks like. With the handler removed AND loops collapsed, the same two traces
# agree for **26,336 of our 26,338** collapsed instructions, i.e. to the end of
# the shorter one. There was no control-flow divergence in that window at all.
#
# The handler is fe02bc..fe0343 (`retis #0`), measured: 281 entries and 281
# retis in a five-second reference trace. Nested interrupts are not handled and
# do not occur here — the count matching exactly is the check.
import sys

ENTRY = "fe02bc"
EXIT  = "fe0343"

def main():
    if len(sys.argv) < 3:
        print("usage: v60_strip_isr.py <in> <out>", file=sys.stderr)
        return 2
    kept = dropped = entries = exits = 0
    inside = False
    with open(sys.argv[1]) as f, open(sys.argv[2], "w") as o:
        for line in f:
            pc = line.strip()
            if not pc:
                continue
            if not inside and pc == ENTRY:
                inside = True
                entries += 1
                dropped += 1
                continue
            if inside:
                dropped += 1
                if pc == EXIT:
                    inside = False
                    exits += 1
                continue
            o.write(pc + "\n")
            kept += 1
    # Report rather than discard silently: an entry count that does not match the
    # exit count means the handler's extent is wrong and the filter is eating
    # real code.
    print("v60_strip_isr: kept=%d dropped=%d entries=%d exits=%d%s"
          % (kept, dropped, entries, exits,
             "" if entries == exits else "  MISMATCH - handler extent is wrong"),
          file=sys.stderr)
    return 0

sys.exit(main())
