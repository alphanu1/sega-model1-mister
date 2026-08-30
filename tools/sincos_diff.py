#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Diff the coprocessor's sincos-unit traffic (io 0x20-0x23) against the reference's.
#
# Answer 767 (microcode 037c) differs from the reference on identical commands
# and is computed from a sincos lookup at 036F-0371. The unit matches MAME's
# copro_sincos_r line for line on paper, so this compares the VALUES: what each
# side writes to the base register and what each read returns. The first
# mismatch names the layer - a different base written means the arithmetic
# before the lookup differs; the same base with a different read means the
# table or the unit does.
#
#   ours:  build/frame_streams.txt      SCW aa vvvvvvvv / SCR aa vvvvvvvv
#   MAME:  build/dasm/mame_sincos.txt   SCW aa vvvvvvvv / SCR aa vvvvvvvv
import sys

def load(path, prefix_ok, base=0):
    # Our probe logs the unit-relative io address (0-3); MAME's tap logs the
    # absolute one (0x20-0x23). Normalise, or the first event "diverges" on the
    # address column with identical values - which is exactly what happened.
    out = []
    for line in open(path):
        p = line.split()
        if len(p) >= 3 and p[0] in prefix_ok:
            out.append((p[0], "%02x" % (int(p[1], 16) + base), p[2].lower()))
    return out

def main():
    ours = load("build/frame_streams.txt", ("SCW", "SCR"), base=0x20)
    mame = load("build/dasm/mame_sincos.txt", ("SCW", "SCR"))
    print("sincos events  ours=%d  MAME=%d" % (len(ours), len(mame)))
    n = min(len(ours), len(mame))
    for i in range(n):
        if ours[i] != mame[i]:
            print("first divergence at event %d" % i)
            lo = max(0, i - 6)
            print("  MAME:", "  ".join("%s %s=%s" % e for e in mame[lo:i + 3]))
            print("  ours:", "  ".join("%s %s=%s" % e for e in ours[lo:i + 3]))
            kind = ours[i][0]
            if kind == "SCW" and mame[i][0] == "SCW":
                print("  -> the BASE written differs: the fault is upstream of the unit")
            elif kind == "SCR" and mame[i][0] == "SCR":
                print("  -> same base, different read: the unit or its table")
            else:
                print("  -> the access SEQUENCE differs (read where the reference writes or vice versa)")
            return 0
    print("IDENTICAL over %d events" % n)
    return 0

if __name__ == "__main__":
    sys.exit(main())
