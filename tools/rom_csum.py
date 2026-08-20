#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Fold the packed ROM image exactly as m1_rom_loader folds what it hands to
# SDRAM, so the board's row 07 can be compared against the bytes on disk.
#
# WHY: the coprocessor reads different values from the math tables on hardware
# than the model returns, at every one of the four selectable capture phases.
# That leaves two possibilities — the data never reached SDRAM, or SDRAM does
# not return what was written — and only the write side separates them.
#
# The loader accumulates, per 16-bit word in stream order:
#     csum = rot_left_24(csum) ^ word
import sys, os

def fold(path):
    data = open(path, 'rb').read()
    csum = 0
    n = 0
    for i in range(0, len(data) - 1, 2):
        w = data[i] | (data[i + 1] << 8)          # little-endian, as ioctl delivers
        csum = ((csum << 1) | (csum >> 23)) & 0xffffff
        csum ^= w
        n += 1
    return csum, n

if len(sys.argv) < 2:
    print("usage: rom_csum.py <packed .bin>   (build/rom/*.bin)")
    sys.exit(2)
for p in sys.argv[1:]:
    if not os.path.exists(p):
        print("%-40s MISSING" % p); continue
    c, n = fold(p)
    print("%-40s csum=%06x words=%d (%06x)" % (os.path.basename(p), c, n, n & 0xffffff))
