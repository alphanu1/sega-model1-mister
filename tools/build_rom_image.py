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
# THE POLYGON MODEL ROMS - the 3D geometry, and the largest region by far.
#
# ROM_LOAD32_WORD in PAIRS: each pair supplies the low and high 16 bits of a
# 32-bit word, and successive pairs land 4 MB apart (0x000000, 0x400000,
# 0x800000, 0xc00000). Sets differ - vr/vf/wingwar have eight files (16 MB),
# swa and netmerc six (12 MB) - so the region is sized by the pair count rather
# than assumed.
#
# NOT LOADED BEFORE 2026-08-30, and nothing noticed because nothing read them:
# the rasterizer is unbuilt, so an absent 16 MB region looks exactly like a
# working core. The coprocessor's data ROM was missing the same way and cost two
# sessions; `make verify_mra` exists because of it.
POLYGONS = {
    'vr':         ['mpr-14890.26', 'mpr-14891.27', 'mpr-14892.28', 'mpr-14893.29',
                   'mpr-14894.30', 'mpr-14895.31', 'mpr-14896.32', 'mpr-14897.33'],
    'vformula':   ['mpr-14890.26', 'mpr-14891.27', 'mpr-14892.28', 'mpr-14893.29',
                   'mpr-14894.30', 'mpr-14895.31', 'mpr-14896.32', 'mpr-14897.33'],
    'vf':         ['mpr-16096.26', 'mpr-16097.27', 'mpr-16098.28', 'mpr-16099.29',
                   'mpr-16100.30', 'mpr-16101.31', 'mpr-16102.32', 'mpr-16103.33'],
    'wingwar':    ['mpr-16743.26', 'mpr-16744.27', 'mpr-16745.28', 'mpr-16746.29',
                   'mpr-16747.30', 'mpr-16748.31', 'mpr-16749.32', 'mpr-16750.33'],
    'wingwaru':   ['mpr-16743.26', 'mpr-16744.27', 'mpr-16745.28', 'mpr-16746.29',
                   'mpr-16747.30', 'mpr-16748.31', 'mpr-16749.32', 'mpr-16750.33'],
    'wingwarj':   ['mpr-16743.26', 'mpr-16744.27', 'mpr-16745.28', 'mpr-16746.29',
                   'mpr-16747.30', 'mpr-16748.31', 'mpr-16749.32', 'mpr-16750.33'],
    'wingwar360': ['mpr-16743.26', 'mpr-16744.27', 'mpr-16745.28', 'mpr-16746.29',
                   'mpr-16747.30', 'mpr-16748.31', 'mpr-16749.32', 'mpr-16750.33'],
    'swa':        ['mpr-16476.26', 'mpr-16477.27', 'mpr-16478.28', 'mpr-16479.29',
                   'mpr-16480.30', 'mpr-16481.31'],
    'swaj':       ['mpr-16476.26', 'mpr-16477.27', 'mpr-16478.28', 'mpr-16479.29',
                   'mpr-16480.30', 'mpr-16481.31'],
    'netmerc':    ['mpr-18128.ic26', 'mpr-18129.ic27', 'mpr-18130.ic28',
                   'mpr-18131.ic29', 'mpr-18132.ic30', 'mpr-18133.ic31'],
}
POLY_OFF = 0x840000          # immediately after copro_tables

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
    # Sized to include the polygon region when the set has one. Explicit, because
    # a short buffer is silently RESIZED by the slice assignments below - which
    # works, and hides the arithmetic.
    poly_pairs = len(POLYGONS.get(game, [])) // 2
    stream = bytearray(b'\xff' * (POLY_OFF + poly_pairs * 0x400000))
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

        # polygons: pairs of ROM_LOAD32_WORD halves, 4 MB apart. Same shape as
        # copro_tables above, four times over.
        for pair in range(poly_pairs):
            lo = load(zf, POLYGONS[game][pair*2])
            hi = load(zf, POLYGONS[game][pair*2 + 1])
            q = bytearray(len(lo) * 2)
            q[0::4] = lo[0::2]; q[1::4] = lo[1::2]
            q[2::4] = hi[0::2]; q[3::4] = hi[1::2]
            base = POLY_OFF + pair * 0x400000
            stream[base:base+len(q)] = q

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
    ap.add_argument('-b', '--bin', action='store_true',
                    help='also write the WHOLE packed stream as raw bytes. The '
                         'hex preload deliberately stops before the polygon '
                         'region - 16 MB of it as text is 60 MB - so anything '
                         'that needs the models reads the binary instead.')
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

    if args.bin:
        binp = os.path.join(args.out, f'{args.game}_stream.bin')
        with open(binp, 'wb') as f:
            f.write(stream)
        print(f"{binp}: {len(stream)} bytes, polygons at 0x840000")

    vec = 0x100000 + (0xfffff0 - 0xf80000)
    print("reset vector 0xfffffff0 -> stream 0x%06x -> bytes %s" %
          (vec, ' '.join('%02x' % b for b in stream[vec:vec+8])))

# Guarded so tools/verify_mra.py can import pack_stream without running the CLI.
if __name__ == '__main__':
    main()
