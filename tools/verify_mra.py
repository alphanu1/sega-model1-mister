#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sega Model 1 core for MiSTer FPGA
# Copyright (C) 2026 alphanu1
#
# Expand an MRA into the byte stream the HPS would send, and diff it against
# the layout the core is actually verified against.
#
# WHY THIS EXISTS
#
# m1_rom_loader deliberately does no base-address arithmetic, so the MRA owns
# the ROM layout completely. That makes a misplaced region impossible to cause
# by accident in RTL and trivial to cause by accident in XML — and it does not
# fail at load time. It fails as a checksum error much later, on hardware,
# looking like a CPU bug.
#
# tools/build_rom_image.py already packs that layout for simulation, and the
# boot test and the frame test both run against its output. So the MRA is
# correct exactly when it produces those same bytes, and this checks that
# offline: no board, no bitstream, no ROM in the repository.
#
# It implements the subset of the MRA format this core uses — <part> with a
# name, <part repeat=N> with hex fill, and <interleave output="16"> with
# map="01"/"10" — and fails loudly on anything outside it rather than guessing.

import sys, os, zipfile, argparse
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_rom_image import pack_stream, load


def part_bytes(zf, el):
    """One <part>: either a named ROM from the zip or a repeated fill."""
    name = el.get('name')
    if name:
        return bytearray(load(zf, name))

    rep = el.get('repeat')
    if rep is None:
        raise SystemExit("a <part> has neither name nor repeat")
    text = (el.text or '').strip().replace(' ', '')
    if not text:
        raise SystemExit("a repeated <part> has no fill bytes")
    fill = bytearray.fromhex(text)
    return fill * int(rep)


def interleave_bytes(zf, el):
    """<interleave output="16">: two 8-bit halves into 16-bit words.

    map="01" means that part supplies the low byte of each word and "10" the
    high byte, which is MAME's ROM_LOAD16_BYTE with the .even file first.
    """
    if el.get('output') != '16':
        raise SystemExit(f"unsupported interleave output={el.get('output')}")

    lo = hi = None
    for p in el:
        if p.tag != 'part':
            raise SystemExit(f"unsupported element inside interleave: {p.tag}")
        m = p.get('map')
        data = part_bytes(zf, p)
        if m == '01':
            lo = data
        elif m == '10':
            hi = data
        else:
            raise SystemExit(f"unsupported map={m}; this core only uses 01 and 10")

    if lo is None or hi is None:
        raise SystemExit("interleave needs both a 01 and a 10 part")
    if len(lo) != len(hi):
        raise SystemExit(f"interleave halves differ: {len(lo)} vs {len(hi)}")

    out = bytearray(len(lo) * 2)
    out[0::2] = lo
    out[1::2] = hi
    return out


def expand(mra_path, zip_path):
    root = ET.parse(mra_path).getroot()
    rom = None
    for r in root.findall('rom'):
        if r.get('index') == '0':
            rom = r
    if rom is None:
        raise SystemExit("no <rom index=\"0\"> in the MRA")

    stream = bytearray()
    with zipfile.ZipFile(zip_path) as zf:
        for el in rom:
            if el.tag == 'part':
                stream += part_bytes(zf, el)
            elif el.tag == 'interleave':
                stream += interleave_bytes(zf, el)
            else:
                raise SystemExit(f"unsupported element in rom: {el.tag}")
    return stream


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mra')
    ap.add_argument('zip')
    ap.add_argument('game', nargs='?', default='vr')
    args = ap.parse_args()

    got = expand(args.mra, args.zip)
    want = pack_stream(args.zip, args.game)

    print(f"MRA expands to   {len(got):,} bytes")
    print(f"packer produces  {len(want):,} bytes")

    fails = 0
    if len(got) != len(want):
        print(f"FAIL length differs by {len(got) - len(want):+,} bytes")
        fails += 1

    n = min(len(got), len(want))
    bad = [i for i in range(n) if got[i] != want[i]]
    if bad:
        fails += 1
        print(f"FAIL {len(bad):,} bytes differ, first at 0x{bad[0]:06x}")
        # A region boundary is the likely culprit, so show where runs start.
        starts, prev = [], None
        for i in bad:
            if prev is None or i != prev + 1:
                starts.append(i)
            prev = i
        for s in starts[:8]:
            print(f"     run at 0x{s:06x}: mra {got[s]:02x} vs packer {want[s]:02x}")
        if len(starts) > 8:
            print(f"     ... and {len(starts) - 8} more runs")
    else:
        print("OK  every byte matches the layout the core is verified against")

    return 1 if fails else 0


sys.exit(main())
