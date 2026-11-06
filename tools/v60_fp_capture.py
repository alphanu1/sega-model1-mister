#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Turn MAME's V60 floating-point capture into vectors for tb_v60_fp_replay.
#
# The capture is a MAME trace with one breakpoint per FP instruction and one
# on the instruction after it (tools/v60_fp_bp.py writes the debugscript):
#   FPA <pc> <mnemonic> <op1> <op2> <tkcw> <psw before>
#   FPR <pc> <destination after> <psw after>
# An FPR is only the one that follows its own FPA; the instruction after an FP
# op can also be reached from elsewhere, and those hits are dropped.
#
# Output, one op a line, hex:  pc op subop a b cw psw_before result psw_after
#   tools/v60_fp_capture.py <trace> > vectors.txt
import sys
OPS = {"cvt.ws": (0x5f, 0x00), "cvt.sw": (0x5f, 0x01), "cmpf.s": (0x5c, 0x00),
       "movf.s": (0x5c, 0x08), "negf.s": (0x5c, 0x09), "absf.s": (0x5c, 0x0a),
       "sclf.s": (0x5c, 0x10), "addf.s": (0x5c, 0x18), "subf.s": (0x5c, 0x19),
       "mulf.s": (0x5c, 0x1a), "divf.s": (0x5c, 0x1b)}
pend = None; n = 0; drop = 0
for line in open(sys.argv[1], errors="replace"):
    if line.startswith("FPA "):
        f = line.split()
        if pend: drop += 1
        pend = f
    elif line.startswith("FPR ") and pend:
        f = line.split()
        if f[1] != pend[1]: continue
        op, sub = OPS[pend[2]]
        print("%s %02x %02x %s %s %x %s %s %s" % (pend[1], op, sub, pend[3], pend[4],
              int(pend[5], 16) & 7, pend[6], f[2], f[3]))
        n += 1; pend = None
print("vectors %d, FPA without FPR %d" % (n, drop), file=sys.stderr)
