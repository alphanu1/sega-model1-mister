#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sega Model 1 core for MiSTer FPGA
# Copyright (C) 2026 alphanu1
#
# Make the "[15kHz CRT]" MRA for each MRA in mra/, from that MRA.
#
# A CRT MRA is its game's MRA with ONE byte changed: bit 7 of the game id on
# download index 4. Model1.sv reads bits 6:0 as the game and bit 7 as "this is
# a 15 kHz CRT", forces the 15 kHz picture on (m1_scan15) and shows the OSD's
# Video line as fixed, so a CRT is never handed 24 kHz by a saved setting.
# The convention is the Model 2 core's (its study R795, R898).
#
# Derived rather than written so the two files cannot drift: the ROM layout of
# a CRT MRA is its parent's, byte for byte, and re-running this after any MRA
# change carries the change across. Writes mra/<name> [15kHz CRT].mra beside
# each source and skips files that are already CRT MRAs.
#
#   python3 tools/make_crt_mra.py [mra-dir]

import os, re, sys

CRT = ' [15kHz CRT]'

def crt_of(text, path):
    m = re.search(r'(<rom index="4"[^>]*>\s*<part>)([0-9A-Fa-f]{2})( [0-9A-Fa-f]{2})?(</part>)', text)
    if not m:
        raise SystemExit(f'{path}: no game-id byte on index 4')
    gid = int(m.group(2), 16)
    if gid & 0x80:
        raise SystemExit(f'{path}: game id {gid:02x} already has bit 7 set')
    text = text[:m.start(2)] + f'{gid | 0x80:02x}' + text[m.end(2):]
    n = re.search(r'<name>(.*?)</name>', text)
    text = text[:n.start(1)] + n.group(1) + CRT + text[n.end(1):]
    note = ('    <!-- 15 kHz CRT: this is its parent MRA with bit 7 of the game id set\n'
            '         (index 4 below), which makes the core output 15 kHz interlaced\n'
            '         through its scan converter. Made by tools/make_crt_mra.py from\n'
            '         the parent; regenerate rather than edit. -->\n')
    i = text.index('<rom index="4"')
    i = text.rfind('\n', 0, i) + 1
    return text[:i] + note + text[i:]

def main():
    d = sys.argv[1] if len(sys.argv) > 1 else 'mra'
    made = 0
    for f in sorted(os.listdir(d)):
        if not f.endswith('.mra') or CRT in f:
            continue
        src = os.path.join(d, f)
        out = os.path.join(d, f[:-4] + CRT + '.mra')
        with open(src, encoding='utf-8') as fh:
            t = crt_of(fh.read(), src)
        with open(out, 'w', encoding='utf-8') as fh:
            fh.write(t)
        print(f'  {f} -> {os.path.basename(out)}')
        made += 1
    print(f'{made} written')

main()
