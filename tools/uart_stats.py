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

FIELDS = "F S B P C R N V X L T W D H K M O Q".split()
LINE = re.compile(r"\b([A-Z])=([0-9A-Fa-f]+)")

# Fields that free-run and are only meaningful as a rate; the rest are levels.
COUNTERS = {"F", "S", "B", "P", "C", "R", "N", "T", "D", "H", "M"}


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
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "-"))
