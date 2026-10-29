#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sega Model 1 core for MiSTer FPGA
# Copyright (C) 2026 alphanu1
#
# One MultiPCM's 4 MB sample region, as MAME's model1.cpp loads it and as the
# MRA's sound stream lays it out in SDRAM: the .32/.33 sockets for chip 1, the
# .4/.5 sockets for chip 2, an empty socket as zeros. For the replay bench
# (make multipcm_replay). The output is ROM data: it goes in build/, never in
# the repository.
#
#   tools/mpcm_region.py netmerc 1 ~/roms/netmerc.zip -o build/netmerc_pcm1.bin
import argparse, os, sys, zipfile

LAYOUT = {   # game: (chip 1 sockets, chip 2 sockets), from model1.cpp
    'vr':      (['mpr-14873.32', None],           ['mpr-14876.4', None]),
    'vformula':(['mpr-14873.32', None],           ['mpr-14876.4', None]),
    'vf':      (['mpr-16122.32', 'mpr-16123.33'], ['mpr-16124.4', 'mpr-16125.5']),
    'swa':     (['mpr-16486.32', 'mpr-16487.33'], ['mpr-16484.4', 'mpr-16485.5']),
    'wingwar': (['mpr-16753.32', 'mpr-16754.33'], ['mpr-16755.4', 'mpr-16756.5']),
    'netmerc': (['mpr-18134.ic32', 'mpr-18135.ic33'], ['mpr-18136.ic4', None]),
}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('game', choices=sorted(LAYOUT))
    ap.add_argument('chip', type=int, choices=(1, 2))
    ap.add_argument('zip')
    ap.add_argument('-o', '--out', required=True)
    a = ap.parse_args()
    zf = zipfile.ZipFile(os.path.expanduser(a.zip))
    names = {os.path.basename(n): n for n in zf.namelist()}
    data = b''
    for part in LAYOUT[a.game][a.chip - 1]:
        if part is None:
            data += bytes(0x200000)
        elif part in names:
            data += zf.read(names[part])
        else:
            sys.exit(f'{part} not in {a.zip}')
    assert len(data) == 0x400000, len(data)
    open(a.out, 'wb').write(data)

if __name__ == '__main__':
    main()
