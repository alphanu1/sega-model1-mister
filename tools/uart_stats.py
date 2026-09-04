#!/usr/bin/env python3
"""Summarise the core's telemetry line from a captured UART log.

The line the core emits once a second is 127 bytes of hex fields, and reading
it by eye across a few minutes of gameplay does not show which fields moved
together. This turns a capture into per-field ranges and the deltas that
matter, so a claim like "the memory is the constraint" gets a number.

Usage: tools/uart_stats.py <capture.log>
       ssh root@mister "stty -F /dev/ttyS1 115200 raw -echo; cat /dev/ttyS1" | tools/uart_stats.py -
"""
import re, sys

FIELDS = "F S B P C R N V X L T W D H K M O Q A Z G E U".split()
LINE = re.compile(r"\b([A-Z])=([0-9A-Fa-f]+)")

# Fields that free-run and are only meaningful as a rate; the rest are levels.
COUNTERS = {"F", "S", "B", "P", "C", "R", "N", "T", "D", "H", "M", "G", "A", "Z", "E"}


def main(path):
    src = sys.stdin if path == "-" else open(path, errors="replace")
    rows = []
    for line in src:
        d = dict(LINE.findall(line))
        if len(d) >= 10:
            rows.append({k: int(v, 16) for k, v in d.items()})
    if not rows:
        print("no telemetry lines found")
        return 1
    print(f"{len(rows)} samples\n")
    print(f"{'':4} {'min':>10} {'max':>10} {'last':>10} {'per second':>12}")
    for f in FIELDS:
        vals = [r[f] for r in rows if f in r]
        if not vals:
            continue
        if f in COUNTERS and len(vals) > 1:
            # Free-running and 16 bits, so wraps are expected over a long run.
            steps = [(b - a) % 0x10000 for a, b in zip(vals, vals[1:])]
            rate = sum(steps) / len(steps)
            print(f"{f:4} {min(vals):10} {max(vals):10} {vals[-1]:10} {rate:12.1f}")
        else:
            print(f"{f:4} {min(vals):10} {max(vals):10} {vals[-1]:10} {'':>12}")

    # O and Q are fractions of 0xFF, which is not readable as hex.
    for f, what in (("O", "SDRAM busy"), ("Q", "tile port waiting")):
        vals = [r[f] for r in rows if f in r]
        if vals:
            pc = [100.0 * v / 255 for v in vals]
            print(f"\n{what}: mean {sum(pc)/len(pc):.1f}%  peak {max(pc):.1f}%")

    # The left/right span census, which is the whole point of a capture taken
    # while the road is missing from one side.
    la = [r["A"] for r in rows if "A" in r]
    ra = [r["Z"] for r in rows if "Z" in r]
    if len(la) > 1 and len(ra) > 1:
        dl = sum((b - a) % 0x10000 for a, b in zip(la, la[1:]))
        dr = sum((b - a) % 0x10000 for a, b in zip(ra, ra[1:]))
        tot = dl + dr
        if tot:
            print(f"\nspans: left {100.0*dl/tot:.1f}%  right {100.0*dr/tot:.1f}%"
                  f"   ({dl} vs {dr} in units of 1024 px)")
            if dl < dr / 4:
                print("  -> the LEFT HALF is starved: the spans are never emitted")
            elif abs(dl - dr) < tot * 0.2:
                print("  -> both halves are drawn; the loss is after the fill")
    # The geometry funnel. A facing test with the wrong sign takes single-sided
    # geometry - the road, the ground, the scenery - and leaves closed objects
    # like cars untouched, which is the shape of what Ben sees.
    ea = [r["E"] for r in rows if "E" in r]
    ua = [r["U"] for r in rows if "U" in r]
    if len(ea) > 1:
        de = [(b - a) % 0x10000 for a, b in zip(ea, ea[1:])]
        print(f"\nbackface culls: mean {sum(de)/len(de):.0f}/s  "
              f"min {min(de)}  max {max(de)}")
        if max(de) > 3 * (sum(de) / len(de) + 1):
            print("  -> the cull rate SPIKES; watch whether it lines up with the loss")
    if ua:
        print(f"quads in the store: min {min(ua)}  max {max(ua)}  last {ua[-1]}")

    ga = [r["G"] for r in rows if "G" in r]
    if len(ga) > 1:
        dg = sum((b - a) % 0x10000 for a, b in zip(ga, ga[1:]))
        print(f"\nvertices out of the quad store's 16-bit range: {dg} over the capture")
        if dg:
            print("  -> coordinates ARE wrapping, which is the road/scenery symptom")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "-"))
