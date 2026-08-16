#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sega Model 1 core for MiSTer FPGA
# Copyright (C) 2026 alphanu1
#
# What should be at an SDRAM word address, according to the ROM image.
#
# The debug overlay reports the address and data of the V60's first and last
# instruction fetches as raw SDRAM word addresses. Deciding whether the board
# fetched the right thing means comparing that against the packed stream, and
# doing it by hand — halving a byte offset, counting lines in a 3 million line
# hex file — is exactly the sort of arithmetic that produces a confident wrong
# answer at two in the morning.
#
#   tools/rom_at.py 0xbfff8            what is at that word address
#   tools/rom_at.py 0xbfff8 -n 8       ...and the seven words after it
#   tools/rom_at.py 0xbfff8 -e 000d    ...and whether it matches what the board
#                                      reported, as a pass or fail
#
# The stream layout is m1_decode's, documented in tools/gen_mra.py: the V60's
# sparse address space packed into one image. This prints the V60 address the
# word came from as well, because the fetch address alone does not say whether
# the CPU was in the boot ROM, the program or a data bank.

import argparse, os, sys

HEX = 'build/rom/vr_v60.hex'

# (stream word base, V60 byte base, length in words) — PACK from gen_mra.py,
# in words rather than bytes.
REGIONS = [
    (0x000000, 0x200000, 0x080000),   # ROMX, the program
    (0x080000, None,     0x000000),   # (ROMX is 1 MB = 0x80000 words)
    (0x080000, 0xf80000, 0x040000),   # ROM0, the boot vector
    (0x0c0000, 0x100000, 0x080000),   # banked data 0
    (0x140000, 0x100000, 0x080000),   # banked data 1
    (0x1c0000, 0x100000, 0x080000),   # banked data 2
    (0x240000, 0x100000, 0x080000),   # banked data 3
]


def v60_address(word):
    """Best-effort V60 byte address for a stream word, or None."""
    byte = word * 2
    if byte < 0x100000:
        return 0x200000 + byte
    if byte < 0x180000:
        return 0xf80000 + (byte - 0x100000)
    # The banked window aliases four times; report the first.
    if byte < 0x580000:
        return 0x100000 + ((byte - 0x180000) % 0x100000)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('addr', help='SDRAM word address, e.g. 0xbfff8')
    ap.add_argument('-n', '--count', type=int, default=4)
    ap.add_argument('-e', '--expect', default=None,
                    help='hex word the board reported, checked against the image')
    ap.add_argument('-f', '--file', default=HEX)
    args = ap.parse_args()

    if not os.path.exists(args.file):
        raise SystemExit(f"{args.file} missing — build it with tools/build_rom_image.py")

    base = int(args.addr, 0)
    words = []
    with open(args.file) as f:
        for i, line in enumerate(f):
            if i < base:
                continue
            if i >= base + args.count:
                break
            words.append(line.strip())

    if not words:
        raise SystemExit(f"word 0x{base:x} is past the end of the image")

    for i, w in enumerate(words):
        va = v60_address(base + i)
        va_s = f"V60 0x{va:06x}" if va is not None else "V60 unmapped"
        print(f"  word 0x{base+i:06x}  = {w}   ({va_s})")

    if args.expect is not None:
        want = words[0].lower()
        got = args.expect.lower().lstrip('0x').rjust(4, '0')[-4:]
        ok = (got == want)
        print(f"\n  board reported {got}, image has {want}: "
              f"{'MATCH' if ok else 'MISMATCH'}")
        return 0 if ok else 1
    return 0


sys.exit(main())
