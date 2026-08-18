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
    """<interleave>: parts combined into wider words, by their map strings.

    A map string has one character per OUTPUT byte, most significant first, and
    each character says which byte of that part supplies it — 1-based, 0 for
    none. So for output="16", map="01" is the low byte and "10" the high, which
    is MAME's ROM_LOAD16_BYTE with the .even file first.

    output="32" is the same rule with four positions, and it is what the
    coprocessor's regions need: copro_data is four ROM_LOAD32_BYTE parts
    ("0001".."1000") and copro_tables two ROM_LOAD32_WORD halves ("0021",
    "2100"). Rejecting it outright is why this check could not see either region
    — and this check comparing the MRA against build_rom_image.py's packing is
    exactly what would have caught the data ROM being absent from the MRA for two
    sessions. It is a manual target and was never run.
    """
    if el.get('output') == '32':
        return interleave_generic(zf, el, 4)
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


def interleave_generic(zf, el, width):
    """Any output width, driven by the map strings rather than by special cases."""
    parts = []
    for p in el:
        if p.tag != 'part':
            raise SystemExit(f"unsupported element inside interleave: {p.tag}")
        m = p.get('map')
        if m is None or len(m) != width:
            raise SystemExit(f"map={m} is not {width} characters")
        parts.append((m, part_bytes(zf, p)))

    # Every part must cover the same number of output words.
    words = None
    for m, data in parts:
        taken = sum(1 for c in m if c != '0')
        if taken == 0:
            raise SystemExit(f"map={m} selects no bytes")
        if len(data) % taken:
            raise SystemExit(f"part length {len(data)} is not a multiple of {taken}")
        w = len(data) // taken
        if words is None:
            words = w
        elif words != w:
            raise SystemExit(f"interleave parts cover {words} and {w} words")

    out = bytearray(words * width)
    for m, data in parts:
        taken = sum(1 for c in m if c != '0')
        # Map characters run most-significant output byte first, and the DIGIT
        # names which byte of the part supplies it — 1-based. Using a running
        # counter instead is identical when a part supplies one byte and
        # inverted when it supplies two, which is exactly how copro_tables came
        # out byte-swapped while copro_data was right.
        for pos, c in enumerate(m):
            if c == '0':
                continue
            obyte = width - 1 - pos
            out[obyte::width] = data[int(c) - 1::taken]
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

    # INDEX 1, THE COPROCESSOR MICROCODE, checked separately because it is not
    # part of the stream and nothing else looks at it.
    #
    # The generator did not emit this element for a while, so regenerating a
    # hand-maintained MRA silently dropped it. With no microcode the TGP never
    # drains the command FIFO, the FIFO fills at 16, and a full FIFO halts the
    # V60 — a dead machine rather than a visibly broken one. Everything else here
    # passed while that was true, because everything else here reads index 0.
    root = ET.parse(args.mra).getroot()
    ucode = [r for r in root.iter('rom') if r.get('index') == '1']
    if not ucode:
        print("FAIL no <rom index=\"1\"> — the TGP microcode is not sent at all")
        return 1
    parts = [p for p in ucode[0] if p.tag == 'part']
    if len(parts) != 1:
        print(f"FAIL index 1 has {len(parts)} parts, expected exactly 1")
        return 1
    with zipfile.ZipFile(args.zip) as zf:
        u = load(zf, parts[0].get('name'))
    if len(u) != 0x2000:
        print(f"FAIL microcode is {len(u)} bytes, expected 8192")
        return 1
    print(f"index 1 microcode  {parts[0].get('name')}, {len(u):,} bytes  OK")

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
