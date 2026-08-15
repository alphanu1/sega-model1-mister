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

def load(zf, name):
    try:
        return zf.read(name)
    except KeyError:
        for n in zf.namelist():
            if n.lower().endswith(name.lower()):
                return zf.read(n)
        raise SystemExit(f"missing {name} in the archive")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('game', choices=sorted(SETS))
    ap.add_argument('zip')
    ap.add_argument('-o', '--out', default='build/rom')
    ap.add_argument('-w', '--words', type=lambda x: int(x,0), default=0x300000,
                    help='16-bit words of the packed image to emit; the default '
                         'covers ROMX, ROM0 and the banked data ROMs, which the '
                         'boot ROM checksums')
    args = ap.parse_args()

    # maincpu as MAME lays it out, sparse, then packed below.
    maincpu = bytearray(b'\xff' * 0x1400000)
    with zipfile.ZipFile(args.zip) as zf:
        for names, off in SETS[args.game]:
            if len(names) == 2:
                a, b = load(zf, names[0]), load(zf, names[1])
                inter = bytearray(len(a) * 2)
                inter[0::2] = a
                inter[1::2] = b
                maincpu[off:off+len(inter)] = inter
            else:
                d = load(zf, names[0])
                maincpu[off:off+len(d)] = d

    stream = bytearray(b'\xff' * 0x600000)
    stream[0x000000:0x100000] = maincpu[0x200000:0x300000]   # ROMX
    stream[0x100000:0x180000] = maincpu[0xf80000:0x1000000]  # ROM0
    for bank in range(4):                                    # banked data
        src = 0x1000000 + bank * 0x100000
        dst = 0x180000  + bank * 0x100000
        stream[dst:dst+0x100000] = maincpu[src:src+0x100000]

    os.makedirs(args.out, exist_ok=True)
    # Simulation preload. Only ROMX and ROM0 by default — the program and the
    # boot vector, 0xc0000 words. The banked data ROMs live above them and are
    # not touched until the game is running, and emitting all 3.1M words makes
    # $readmemh take longer than the simulation it is feeding.
    words = args.words
    hexp = os.path.join(args.out, f'{args.game}_v60.hex')
    with open(hexp, 'w') as f:
        for i in range(words):
            f.write('%04x\n' % (stream[i*2] | (stream[i*2+1] << 8)))
    print(f"{hexp}: {words} words ({len(stream)} bytes packed)")

    vec = 0x100000 + (0xfffff0 - 0xf80000)
    print("reset vector 0xfffffff0 -> stream 0x%06x -> bytes %s" %
          (vec, ' '.join('%02x' % b for b in stream[vec:vec+8])))

main()
