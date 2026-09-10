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
import os, sys

# PER GAME, and hardcoding it silently strips NOTHING for any other title.
#
# fe02bc is Virtua Racing's handler. Run against Virtua Fighter this reported
# "entries=0 exits=0 dropped=0" on both sides and carried on, so the streams
# being compared still had their interrupt handlers spliced in wherever the
# interrupt happened to land - which makes any divergence it reports untrustworthy.
#
# vf's is fe3ed4, found the same way vr's was: the address reached from the most
# distinct predecessors, which is what an interrupt vector looks like. It runs to
# a `retis` at fe3f59.
ENTRY_BY_GAME = {
    "vr":       "fe02bc",
    "vformula": "fe02bc",
    "vf":       "fe3ed4",
}
ENTRY = ENTRY_BY_GAME.get(os.environ.get("GAME", "vr"), "fe02bc")
# The EXIT is per game too, and getting it wrong is worse than getting the entry
# wrong: the tool enters the handler once, never leaves, and strips everything
# after it. Against Virtua Fighter that dropped 3,694,020 of 3,981,461
# instructions - 93% - and then cheerfully reported the surviving prefix as
# IDENTICAL. The entries==exits check is what catches it; it printed
# "entries=1 exits=0  MISMATCH" and the number is only trustworthy when that
# line says the counts agree.
EXIT_BY_GAME = {
    "vr":       "fe0343",
    "vformula": "fe0343",
    "vf":       "fe3f59",   # the `retis #0` at the end of fe3ed4's handler
}
EXIT  = EXIT_BY_GAME.get(os.environ.get("GAME", "vr"), "fe0343")

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
