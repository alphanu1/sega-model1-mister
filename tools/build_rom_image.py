#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sega Model 1 core for MiSTer FPGA
# Copyright (C) 2026 alphanu1
#
# Packs a Model 1 ROM set into the layout m1_rom_loader expects, and emits the
# V60-visible portion as hex for simulation preload.
#
# This is what an MRA does on real hardware. Doing it here keeps one definition
# of the layout: if this and the MRA ever disagree the core boots in simulation
# and not on the board, which is the worst way to find out.
#
# The V60 region is the interesting part, because MAME's `maincpu` is sparse —
# 19.5 MB of address space holding 5.5 MB of ROM — and m1_decode maps it onto a
# packed layout:
#
#   V60 0x200000-0x2fffff  ROMX, the program     -> stream 0x000000
#   V60 0xf80000-0xffffff  ROM0, the boot vector -> stream 0x100000
#   V60 0x100000-0x1fffff  banked data, +bank    -> stream 0x180000 + bank*0x100000
#
# ROM images do NOT go in the repository (hard rule 2). This reads them from a
# path given on the command line and writes only to a build directory.

import sys, os, zipfile, argparse

# (file-or-pair, maincpu byte offset). A pair is ROM_LOAD16_BYTE and interleaves
# even/odd; a single name is ROM_LOAD and is already a 16-bit image.
SETS = {
  'vr': [
    (('epr-14882.14', 'epr-14883.15'), 0x200000),
    (('epr-14878a.4',),                0xfc0000),
    (('epr-14879a.5',),                0xfe0000),
    (('mpr-14880.6',  'mpr-14881.7'),  0x1000000),
    (('mpr-14884.8',  'mpr-14885.9'),  0x1100000),
    (('mpr-14886.10', 'mpr-14887.11'), 0x1200000),
    (('mpr-14888.12', 'mpr-14889.13'), 0x1300000),
  ],
  'vf': [
    (('epr-16082.14', 'epr-16083.15'), 0x200000),
    (('epr-16080.4',),                 0xfc0000),
    (('epr-16081.5',),                 0xfe0000),
    (('mpr-16084.6',  'mpr-16085.7'),  0x1000000),
    (('mpr-16086.8',  'mpr-16087.9'),  0x1100000),
    (('mpr-16088.10', 'mpr-16089.11'), 0x1200000),
    (('mpr-16090.12', 'mpr-16091.13'), 0x1300000),
  ],
}

# The coprocessor's read-only regions, from model1.cpp. copro_data is
# ROM_LOAD32_BYTE x4 and copro_tables is ROM_LOAD32_WORD x2 — different
# interleaves, and getting them the same way round produces a coprocessor that
# runs and computes rubbish.
COPRO_DATA = {
    'vr':       ['mpr-14898.39', 'mpr-14899.40', 'mpr-14900.41', 'mpr-14901.42'],
    'vformula': ['mpr-14898.39', 'mpr-14899.40', 'mpr-14900.41', 'mpr-14901.42'],
}
COPRO_TABLES = {
    'vr':       ['opr14742.bin', 'opr14743.bin'],
    'vformula': ['opr14742.bin', 'opr14743.bin'],
}


def load(zf, name):
    try:
        return zf.read(name)
    except KeyError:
        for n in zf.namelist():
            if n.lower().endswith(name.lower()):
                return zf.read(n)
        raise SystemExit(f"missing {name} in the archive")

def pack_stream(zip_path, game):
    """The packed ioctl stream, exactly as m1_rom_loader expects to receive it.

    One definition, used by both the simulation preload and tools/verify_mra.py.
    If the MRA and this ever disagree the core boots in simulation and not on
    the board, which is the worst way to find out."""
    maincpu = bytearray(b'\xff' * 0x1400000)
    with zipfile.ZipFile(zip_path) as zf:
        for names, off in SETS[game]:
            if len(names) == 2:
                a, b = load(zf, names[0]), load(zf, names[1])
                inter = bytearray(len(a) * 2)
                inter[0::2] = a
                inter[1::2] = b
                maincpu[off:off+len(inter)] = inter
            else:
                d = load(zf, names[0])
                maincpu[off:off+len(d)] = d

    # The V60-visible portion, then the coprocessor's two read-only regions.
    #
    # THE THREE ARE CONTIGUOUS, WHICH IS NOT A COINCIDENCE. The V60 image ends at
    # byte 0x600000 = SDRAM word 0x300000, and the SDRAM map has 26 MB free
    # between there and WRAM at word 0xF80000. Placing copro_data at word
    # 0x300000 and copro_tables at word 0x400000 means both land immediately
    # after the ROM, so the MRA needs no padding — an earlier scheme put the TGP
    # microcode at word 0xF80000 and would have needed 25 MB of filler streamed
    # through the HPS to reach it.
    # 0x840000: 6 MB of V60 image, 2 MB of copro_data, 256 KB of copro_tables.
    # Sized explicitly — a short buffer would be silently RESIZED by the slice
    # assignments below, which works and hides the arithmetic.
    stream = bytearray(b'\xff' * 0x840000)
    stream[0x000000:0x100000] = maincpu[0x200000:0x300000]   # ROMX
    stream[0x100000:0x180000] = maincpu[0xf80000:0x1000000]  # ROM0
    for bank in range(4):                                    # banked data
        src = 0x1000000 + bank * 0x100000
        dst = 0x180000  + bank * 0x100000
        stream[dst:dst+0x100000] = maincpu[src:src+0x100000]

    with zipfile.ZipFile(zip_path) as zf:
        # copro_data: 2 MB from four ROM_LOAD32_BYTE parts, so byte-interleaved
        # four ways rather than the two-way interleave used above.
        parts = [load(zf, n) for n in COPRO_DATA[game]]
        n = len(parts[0])
        inter = bytearray(n * 4)
        for i, d in enumerate(parts):
            inter[i::4] = d
        stream[0x600000:0x600000+len(inter)] = inter

        # copro_tables: 256 KB from two ROM_LOAD32_WORD halves — the first
        # supplies bits 15:0 of each 32-bit entry, the second bits 31:16.
        lo, hi = (load(zf, n) for n in COPRO_TABLES[game])
        t = bytearray(len(lo) * 2)
        t[0::4] = lo[0::2]; t[1::4] = lo[1::2]
        t[2::4] = hi[0::2]; t[3::4] = hi[1::2]
        stream[0x800000:0x800000+len(t)] = t

    return stream


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('game', choices=sorted(SETS))
    ap.add_argument('zip')
    ap.add_argument('-o', '--out', default='build/rom')
    ap.add_argument('-w', '--words', type=lambda x: int(x,0), default=0x420000,
                    help='16-bit words of the packed image to emit; the default '
                         'covers ROMX, ROM0, the banked data ROMs the boot ROM '
                         'checksums, and the coprocessor regions above them')
    args = ap.parse_args()

    stream = pack_stream(args.zip, args.game)

    os.makedirs(args.out, exist_ok=True)
    # Simulation preload, covering everything a run can read: the V60 image to
    # word 0x300000, then copro_data at 0x300000 and copro_tables at 0x400000.
    #
    # The coprocessor regions are NOT optional in the preload. Its opening move
    # is two data-ROM reads whose values steer everything after them — measured,
    # see docs/findings.md — so a preload that stops at the V60 image leaves the
    # TGP reading 0xFFFF and going nowhere, which looks like a core fault.
    words = args.words
    hexp = os.path.join(args.out, f'{args.game}_v60.hex')
    with open(hexp, 'w') as f:
        for i in range(words):
            f.write('%04x\n' % (stream[i*2] | (stream[i*2+1] << 8)))
    print(f"{hexp}: {words} words ({len(stream)} bytes packed)")

    vec = 0x100000 + (0xfffff0 - 0xf80000)
    print("reset vector 0xfffffff0 -> stream 0x%06x -> bytes %s" %
          (vec, ' '.join('%02x' % b for b in stream[vec:vec+8])))

# Guarded so tools/verify_mra.py can import pack_stream without running the CLI.
if __name__ == '__main__':
    main()
