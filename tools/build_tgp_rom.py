#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sega Model 1 core for MiSTer FPGA
# Copyright (C) 2026 alphanu1
#
# Extract the coprocessor's microcode and math tables as hex, for simulation
# preload only.
#
# Per hard rule 2 nothing this produces goes in the repository — it writes to
# build/, which is gitignored, and on hardware these regions arrive over the MRA
# path like every other ROM.
#
# WHY THIS SEARCHES MORE THAN THE ZIP
#
# MAME resolves a set from the zip AND from a directory named after it, and on
# this machine `315-5573.bin` is in the loose `vr/` directory rather than in
# `vr.zip`. An audit that opened only the zip reported three files missing and a
# whole afternoon was spent reasoning about their absence. Search every source
# MAME would.

import sys, os, zipfile, argparse, zlib

# From model1.cpp's ROM_START(vr) and MODEL1_CPU_BOARD. CRCs are checked because
# these are the two regions whose contents nothing downstream can sanity-check:
# wrong microcode is a coprocessor that runs and computes nonsense.
REGIONS = {
    'vr': {
        # tgp_copro: 0x2000 bytes = 2048 words of 32 bits, AS_PROGRAM 0x000-0x7ff
        'prog':   [('315-5573.bin', 0x3335a19b, 0x2000)],
        # copro_tables: 0x40000 bytes = 65536 words, interleaved as 32-bit LE
        # from two 0x20000 halves. Four 16K-word quadrants: sincos, atan, inv,
        # isqrt — see docs/m2-tgp-integration.md.
        'tables': [('opr14742.bin', 0x446a1085, 0x20000),
                   ('opr14743.bin', 0xe8953554, 0x20000)],
    },
}


def find(name, roots):
    """Every source MAME would search: the loose directory first, then the zip."""
    for r in roots:
        if os.path.isdir(r):
            for dirpath, _, files in os.walk(r):
                for f in files:
                    if f.lower() == name.lower():
                        with open(os.path.join(dirpath, f), 'rb') as fh:
                            return fh.read()
        elif zipfile.is_zipfile(r):
            with zipfile.ZipFile(r) as z:
                for n in z.namelist():
                    if os.path.basename(n).lower() == name.lower():
                        return z.read(n)
    raise SystemExit(f"missing {name} — searched {', '.join(roots)}")


def get(name, want_crc, want_len, roots):
    data = find(name, roots)
    crc = zlib.crc32(data) & 0xffffffff
    if len(data) != want_len:
        raise SystemExit(f"{name}: {len(data)} bytes, expected {want_len}")
    if crc != want_crc:
        raise SystemExit(f"{name}: CRC {crc:08x}, expected {want_crc:08x}")
    return data


def write_hex(path, words):
    with open(path, 'w') as f:
        for w in words:
            f.write(f"{w:08x}\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('game', choices=sorted(REGIONS))
    ap.add_argument('roots', nargs='+',
                    help='directories and/or zips to search, as MAME would')
    ap.add_argument('-o', '--out', default='build/rom')
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    r = REGIONS[args.game]

    # Microcode: 32-bit little-endian words, straight through.
    data = get(*r['prog'][0], args.roots)
    prog = [int.from_bytes(data[i:i+4], 'little') for i in range(0, len(data), 4)]
    p = os.path.join(args.out, f'{args.game}_tgp_prog.hex')
    write_hex(p, prog)
    print(f"{p}: {len(prog)} words of microcode")

    # Tables: ROM_LOAD32_WORD interleaves two halves as 16-bit words — the first
    # file supplies bits 15:0 of each 32-bit entry and the second bits 31:16.
    lo = get(*r['tables'][0], args.roots)
    hi = get(*r['tables'][1], args.roots)
    n = len(lo) // 2
    tables = [int.from_bytes(lo[2*i:2*i+2], 'little') |
              (int.from_bytes(hi[2*i:2*i+2], 'little') << 16) for i in range(n)]
    p = os.path.join(args.out, f'{args.game}_tgp_tables.hex')
    write_hex(p, tables)
    print(f"{p}: {len(tables)} table words "
          f"(sincos/atan/inv/isqrt at 0x0000/0x4000/0x8000/0xc000)")


if __name__ == '__main__':
    main()
