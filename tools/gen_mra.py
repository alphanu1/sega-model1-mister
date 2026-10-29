#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sega Model 1 core for MiSTer FPGA
# Copyright (C) 2026 alphanu1
#
# Generate an MRA per Model 1 set, from MAME's own ROM definitions.
#
# WHY GENERATED RATHER THAN WRITTEN
#
# The sets do not share a layout. vr and wingwar put two 128 KB images at
# 0xfc0000 and 0xfe0000; swa puts one 512 KB image at 0xf80000; netmerc has no
# program pair at 0x200000 at all. Hand-writing ten MRAs from a pattern learned
# on vr would produce files that look right and place regions wrong — and a
# misplaced region does not fail at load, it fails as a checksum error much
# later, on hardware, looking like a CPU bug.
#
# So the ROM names, offsets and sizes come from model1.cpp, which hard rule 3
# already makes the oracle, and the packing comes from one place shared with
# tools/build_rom_image.py.
#
# WHAT IS AND IS NOT CHECKED
#
# tools/verify_mra.py diffs a generated MRA against build_rom_image.py's
# independently hand-written packing, which is a genuine cross-check for the
# sets that packer knows: vr and vf. For the rest there is no second source, so
# what can be checked is that every file exists in the ROM set at the size MAME
# says — which catches a wrong name or a wrong dump, and does not catch a wrong
# layout. Those MRAs are marked as untested in their own header rather than
# presented as equivalent.

import argparse, os, re, sys, zipfile

MODEL1 = 'third_party/mame/src/mame/sega/model1.cpp'

# The packed stream, as rtl/io/m1_decode.sv maps the V60's sparse address space.
# (stream offset, maincpu offset, length)
PACK = [
    (0x000000, 0x200000,  0x100000),   # ROMX, the program
    (0x100000, 0xf80000,  0x080000),   # ROM0, the boot vector
    (0x180000, 0x1000000, 0x100000),   # banked data 0
    (0x280000, 0x1100000, 0x100000),   # banked data 1
    (0x380000, 0x1200000, 0x100000),   # banked data 2
    (0x480000, 0x1300000, 0x100000),   # banked data 3
]
# THE COPROCESSOR'S READ-ONLY REGIONS, appended after the V60 image.
#
# These were absent for two sessions and it presented as a hardware bug. The TGP
# reads its data ROM through IO 0x8000-0xffff BEFORE any math unit, so without it
# the coprocessor stalls at microcode 0x49, never drains its command FIFO, the
# FIFO fills, and a full FIFO HALTS THE V60 — which is a screen that tears down
# and rebuilds every 0.45 s. tools/build_rom_image.py had both regions all along,
# so simulation worked and hardware did not.
#
# Kept as explicit tables rather than parsed out of model1.cpp, exactly as
# build_rom_image.py does, so the two sources stay directly comparable —
# tools/verify_mra.py diffs them byte for byte.
#
# Bases are COPRO_DAT_BASE and COPRO_TBL_BASE in rtl/m1_integrated.sv. They sit
# immediately after the V60 image on purpose, so no padding is needed to reach
# them.
COPRO_DATA = {                       # ROM_LOAD32_BYTE x4, 2 MB
    'vr':       ['mpr-14898.39', 'mpr-14899.40', 'mpr-14900.41', 'mpr-14901.42'],
    'vformula': ['mpr-14898.39', 'mpr-14899.40', 'mpr-14900.41', 'mpr-14901.42'],
    # swa and wingwar populate IC39-IC42 as vr does. netmerc's region is
    # ROMREGION_ERASE00 with "IC39-IC42 unpopulated", and vf has no copro_data
    # region at all - both still need the SPACE, because the polygon ROM sits at
    # a fixed stream offset after it. Skipping the region entirely, which is what
    # this table did for every game but vr, put the polygons 2.25 MB early and
    # the 3D read whatever happened to be there.
    'swa':      ['mpr-16472.39', 'mpr-16473.40', 'mpr-16474.41', 'mpr-16475.42'],
    'wingwar':  ['mpr-16741.39', 'mpr-16742.40', 'mpr-16739.41', 'mpr-16740.42'],
    # THE WING WAR CLONES CARRY THE PARENT'S copro_data (MAME lists the same
    # four files in wingwaru, wingwarj and wingwar360). Missing from this table
    # until 2026-10-29, which put each clone's polygon ROMs at 0x600000 where
    # the core reads the data ROM. The clone MRAs note it (CLONE_COPRO_NOTE).
    'wingwaru':   ['mpr-16741.39', 'mpr-16742.40', 'mpr-16739.41', 'mpr-16740.42'],
    'wingwarj':   ['mpr-16741.39', 'mpr-16742.40', 'mpr-16739.41', 'mpr-16740.42'],
    'wingwar360': ['mpr-16741.39', 'mpr-16742.40', 'mpr-16739.41', 'mpr-16740.42'],
    # swaj carries the parent's copro_data too (MAME lists the same four files).
    # Missing until 2026-10-29: the Wing War clones' fault again, polygons at
    # 0x600000. CLONE_COPRO_NOTE marks the MRA.
    'swaj':     ['mpr-16472.39', 'mpr-16473.40', 'mpr-16474.41', 'mpr-16475.42'],
}
# Clones whose copro blocks were added after their MRA first shipped, and the
# parent they share them with: the MRA says so above the blocks.
CLONE_COPRO_NOTE = {'wingwaru': 'wingwar', 'wingwarj': 'wingwar',
                    'wingwar360': 'wingwar', 'swaj': 'swa'}
# The polygon model ROMs: the 3D geometry, and by a long way the largest region.
# ROM_LOAD32_WORD in PAIRS - each pair is the low and high 16 bits of a 32-bit
# word - with successive pairs 4 MB apart. Eight files for vr/vf/wingwar (16 MB),
# six for swa and netmerc (12 MB), so the size follows the pair count.
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

# Sets whose coprocessor data ROM is EMPTY but whose space is still required.
# netmerc's region is ROMREGION_ERASE00 - "IC39-IC42 unpopulated" - and vf has no
# such region at all. Both still need the 2 MB reserved, because the polygon ROM
# sits at a fixed stream offset behind it. Zeros, not 0xFF, because that is what
# ERASE00 means and what the coprocessor would read off an unpopulated socket.
COPRO_DATA_ZERO = {'vf', 'netmerc'}

COPRO_TABLES = {                     # ROM_LOAD32_WORD x2, 256 KB
    'vr':       ['opr14742.bin', 'opr14743.bin'],
    'vformula': ['opr14742.bin', 'opr14743.bin'],
    # opr14742/opr14743 are MODEL1_CPU_BOARD ROMs, not per-set ones, which is
    # why no game's ROM_START lists them - and they are present in every game's
    # zip. Every set gets them.
    'swa':      ['opr14742.bin', 'opr14743.bin'],
    'swaj':     ['opr14742.bin', 'opr14743.bin'],
    'vf':       ['opr14742.bin', 'opr14743.bin'],
    'wingwar':  ['opr14742.bin', 'opr14743.bin'],
    'wingwaru':   ['opr14742.bin', 'opr14743.bin'],
    'wingwarj':   ['opr14742.bin', 'opr14743.bin'],
    'wingwar360': ['opr14742.bin', 'opr14743.bin'],
    'netmerc':  ['opr14742.bin', 'opr14743.bin'],
}
# THE TGP MICROCODE, on its own download index.
#
# m1_rom_loader routes index 1 to the coprocessor's program RAM rather than to
# SDRAM, so it needs no offset inside the main stream — putting it at the
# loader's old byte offset would have meant padding 25 MB of filler through the
# HPS to deliver 8 KB.
#
# THIS WAS MISSING FROM THE GENERATOR while being present in the checked-in MRA,
# so the first regeneration silently dropped it and the coprocessor lost its
# program entirely. With no microcode the TGP never drains the command FIFO, the
# FIFO fills at 16, and a full FIFO HALTS THE V60 — the overlay read
# `02 000000` and `03 010000`, a stopped CPU rather than a stalling one.
#
# verify_mra.py cannot catch this: it only expands index 0.
COPRO_PROG = {
    'vr':         '315-5573.bin',
    'vformula':   '315-5573.bin',
    'vf':         '315-5724.bin',
    'swa':        '315-5711.bin',
    'swaj':       '315-5711.bin',
    'wingwar':    '315-5711.bin',
    'wingwaru':   '315-5711.bin',
    'wingwarj':   '315-5711.bin',
    'wingwar360': '315-5711.bin',
    'netmerc':    '315-5711.bin',
}

COPRO_DAT_OFF = 0x600000
COPRO_TBL_OFF = 0x800000

STREAM_LEN = 0x600000

TITLES = {
    'vr':         ('Virtua Racing',            1992, 'Driving'),
    'vformula':   ('Virtua Formula',           1993, 'Driving'),
    'vf':         ('Virtua Fighter',           1993, 'Fighter'),
    'swa':        ('Star Wars Arcade',         1994, 'Shooter'),
    'swaj':       ('Star Wars Arcade (Japan)', 1994, 'Shooter'),
    'wingwar':    ('Wing War',                 1994, 'Simulation'),
    'wingwaru':   ('Wing War (US)',            1994, 'Simulation'),
    'wingwarj':   ('Wing War (Japan)',         1994, 'Simulation'),
    'wingwar360': ('Wing War R360',            1994, 'Simulation'),
    'netmerc':    ('Sega NetMerc',             1993, 'Shooter'),
}

# The sets tools/build_rom_image.py packs independently, so a generated MRA for
# them can be diffed against a second source rather than only against itself.
CROSS_CHECKED = ('vr', 'vf')

# ---------------------------------------------------------------------------
# EVERYTHING BELOW WAS ADDED BY HAND TO THE MRAs FIRST, AND IS GENERATED NOW.
#
# The game id (index 4), the I/O board's EEPROM (index 3), the sound board
# (index 5), the per-game buttons and Wing War's I/O board were all written
# into the MRAs directly, so regenerating them silently removed every one -
# the coprocessor microcode's lesson, repeated. Since 2026-10-29 this script
# reproduces the shipped MRAs byte for byte (diffed), and the [15kHz CRT]
# MRAs follow from them through tools/make_crt_mra.py.

# Model1.sv's game id: the input map, the I/O board and the DSB follow it.
GAME_ID = {'vr': 0, 'vformula': 0, 'vf': 1, 'swa': 2, 'swaj': 2,
           'wingwar': 3, 'wingwaru': 3, 'wingwarj': 3, 'wingwar360': 3,
           'netmerc': 4}

# Zip lists where they are not the default ("set.zip" for index 0,
# "set.zip|set.7z" for indices 1 and 5). A clone names its parent's zip so a
# split set loads.
ZIPS = {
    'vformula':   {5: 'vformula.zip|vformula.7z|vr.zip'},
    'swaj':       {5: 'swaj.zip|swaj.7z|swa.zip'},
    'wingwaru':   {0: 'wingwaru.zip|wingwar.zip', 1: 'wingwaru.zip|wingwar.zip',
                   5: 'wingwaru.zip|wingwar.zip'},
    'wingwarj':   {0: 'wingwarj.zip|wingwar.zip', 1: 'wingwarj.zip|wingwar.zip',
                   5: 'wingwarj.zip|wingwar.zip'},
    'wingwar360': {0: 'wingwar360.zip|wingwar.zip', 1: 'wingwar360.zip|wingwar.zip',
                   5: 'wingwar360.zip|wingwar.zip'},
}

def zip_for(setname, index):
    default = f'{setname}.zip' if index == 0 else f'{setname}.zip|{setname}.7z'
    return ZIPS.get(setname, {}).get(index, default)

# The I/O board each game was built with, from model1.cpp: wingwar() fits
# SEGA_MODEL1IO2 with BIOS epr16891. NetMerc is a model1io2 game too
# (EPR-18021) but is still sent EPR-14869 until its own firmware has been run.
IO2_SETS = ('wingwar', 'wingwaru', 'wingwarj', 'wingwar360')

# Per-family buttons, in Model1.sv's joy0 bit order (see the note in emit()).
BUTTONS_DRIVE = ('Accelerate,Brake,Shift Up,Shift Down,VR1,VR2,VR3,VR4,'
                 'Start,Coin,Service,Test,Coin 2', 'R2,L2,R1,L1,A,B,X,Y,Start,Select')
BUTTONS = {
    'vf':  ('Punch,Kick,Guard,Unused 4,Unused 5,Unused 6,Unused 7,Unused 8,'
            'Start,Coin,Service,Test,Coin 2', 'A,B,X,Y,L1,R1,L2,R2,Start,Select'),
    'swa': ('Fire,Thumb,Button 3,Unused 4,Unused 5,Unused 6,Unused 7,Unused 8,'
            'Start,Coin,Service,Test,Coin 2', 'A,B,X,Y,L1,R1,L2,R2,Start,Select'),
    'wingwar': ('Machine Gun,Missile,Smoke,Unused 4,View 1,View 2,View 3,View 4,'
                'Start,Coin,Service,Test,Coin 2', 'A,B,X,Y,L1,R1,L2,R2,Start,Select'),
}
BUTTONS['swaj'] = BUTTONS['swa']
for _s in ('wingwaru', 'wingwarj', 'wingwar360'):
    BUTTONS[_s] = BUTTONS['wingwar']

# Notes carried inside the sound stream for one set's program ROM.
SND_PART_NOTE = {
    ('wingwaru', 'epr-16751.7'): 'wingwaru',
    ('wingwarj', 'epr-16751.7'): 'wingwarj',
}
# Virtua Racing's MRA carries the long note above its sound stream (it was the
# first); the others carry only the stream-shape note inside it.
SND_PRENOTE = ('vr',)

# MAME's sound regions, in stream order. The 68000 program is padded to
# 512 KB and each MultiPCM region to 4 MB with ZEROS (see the note in emit).
SND_REGIONS = [('M1AUDIO_CPU_REGION', 0x80000), ('M1AUDIO_MPCM1_REGION', 0x400000),
               ('M1AUDIO_MPCM2_REGION', 0x400000)]
# Star Wars' Digital Sound Board, appended unpadded after PCM2.
DSB_REGIONS = ['"dsbz80:mpegcpu"', '"dsbz80:mpeg"']


def parse_regions(path):
    """{setname: {region: [(offset, size, filename, loadtype)]}} for the
    regions outside maincpu that the MRAs carry: sound, DSB and EEPROM."""
    text = open(path, encoding='utf-8', errors='replace').read()
    out = {}
    for m in re.finditer(r'ROM_START\(\s*(\w+)\s*\)(.*?)ROM_END', text, re.S):
        name, body = m.group(1), m.group(2)
        regs = {}
        parts = re.split(r'(ROM_REGION\w*\([^)]*\))', body)
        for i in range(1, len(parts), 2):
            rm = re.match(r'ROM_REGION\w*\(\s*[^,]+,\s*([^,]+?)\s*,', parts[i])
            if not rm:
                continue
            loads = []
            for lm in re.finditer(r'ROM_LOAD(\w*)\(\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+|0)\s*,'
                                  r'\s*(0x[0-9a-fA-F]+)', parts[i + 1]):
                loads.append((int(lm.group(3), 0), int(lm.group(4), 16),
                              lm.group(2), lm.group(1)))
            regs[rm.group(1)] = sorted(loads)
        out[name] = regs
    return out


def parse_sets(path):
    """{setname: [(maincpu_offset, size, filename, is16byte)]} from model1.cpp."""
    text = open(path, encoding='utf-8', errors='replace').read()
    sets = {}
    for m in re.finditer(r'ROM_START\(\s*(\w+)\s*\)(.*?)ROM_END', text, re.S):
        name, body = m.group(1), m.group(2)

        # Only the maincpu region: everything from its ROM_REGION to the next.
        rm = re.search(r'ROM_REGION\([^)]*"maincpu"[^)]*\)(.*?)(?:ROM_REGION|\Z)',
                       body, re.S)
        if not rm:
            continue

        loads = []
        for lm in re.finditer(
                r'ROM_LOAD(16_BYTE)?\(\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,'
                r'\s*(0x[0-9a-fA-F]+)', rm.group(1)):
            is16 = lm.group(1) is not None
            loads.append((int(lm.group(3), 16), int(lm.group(4), 16),
                          lm.group(2), is16))
        if loads:
            sets[name] = sorted(loads)
    return sets


def build_chunks(loads, setname=None):
    """Stream-ordered chunks.

    ('pad', n) | ('rom', name) | ('pair', lo, hi, sz)
    | ('quad', [4 names])  - ROM_LOAD32_BYTE, the coprocessor's data ROM
    | ('wpair', [2 names]) - ROM_LOAD32_WORD, the coprocessor's sincos tables
    """
    # Pair the 16-bit halves by their word address.
    byoff = {}
    for off, size, name, is16 in loads:
        if is16:
            byoff.setdefault(off & ~1, {})[off & 1] = (name, size)
        else:
            byoff[off] = {'single': (name, size)}

    chunks, warnings = [], []
    for s_off, m_off, length in PACK:
        pos = m_off
        end = m_off + length
        while pos < end:
            here = byoff.get(pos)
            if here is None:
                # Gap: run to the next load inside this region, or its end.
                nxt = min([o for o in byoff if pos < o < end], default=end)
                chunks.append(('pad', nxt - pos))
                pos = nxt
                continue

            if 'single' in here:
                name, size = here['single']
                chunks.append(('rom', name, size))
                pos += size
            else:
                if 0 not in here or 1 not in here:
                    warnings.append(f"unpaired 16-bit load at 0x{pos:x}")
                    return None, warnings
                (lo, lsz), (hi, hsz) = here[0], here[1]
                if lsz != hsz:
                    warnings.append(f"mismatched halves at 0x{pos:x}")
                    return None, warnings
                chunks.append(('pair', lo, hi, lsz))
                pos += lsz * 2

        if pos != end:
            warnings.append(f"region at 0x{m_off:x} overruns by {pos - end} bytes")
            return None, warnings

    total = sum(c[1] if c[0] == 'pad' else
                (c[2] if c[0] == 'rom' else c[3] * 2) for c in chunks)

    # The banked window runs to 0x580000 but the stream is 0x600000: the tail is
    # unpopulated on every set, and it is sent so the region reads as an absent
    # ROM rather than as whatever the SDRAM powered up holding.
    if total < STREAM_LEN:
        chunks.append(('pad', STREAM_LEN - total))
        total = STREAM_LEN

    if total != STREAM_LEN:
        warnings.append(f"stream is {total} bytes, expected {STREAM_LEN}")
        return None, warnings

    # The coprocessor's regions, for the sets that have them. A set without them
    # simply ends at STREAM_LEN as before.
    if setname in COPRO_DATA:
        chunks.append(('quad', COPRO_DATA[setname]))
        total = COPRO_TBL_OFF
    elif setname in COPRO_DATA_ZERO:
        chunks.append(('pad0', COPRO_TBL_OFF - total))
        total = COPRO_TBL_OFF
    if setname in COPRO_TABLES:
        if total != COPRO_TBL_OFF:
            warnings.append(f"tables would land at 0x{total:x}, not 0x{COPRO_TBL_OFF:x}")
            return None, warnings
        chunks.append(('wpair', COPRO_TABLES[setname]))
    if setname in POLYGONS:
        chunks.append(('wquad', POLYGONS[setname]))

    return chunks, warnings


def emit(setname, chunks, cross_checked, regions):
    title, year, cat = TITLES.get(setname, (setname, 0, ''))
    note = ("tools/verify_mra.py diffs this against build_rom_image.py's\n"
            "      independently written packing, so the layout has a second source."
            if cross_checked else
            "NOT CROSS-CHECKED. Generated from MAME's ROM definitions, and every\n"
            "      file is confirmed present at the size MAME states, but there is no\n"
            "      second description of this set's layout to diff against, and the game\n"
            "      has never been run. Treat a bad screen here as this file's fault\n"
            "      before the core's.")

    out = [
        '<misterromdescription>',
        f'    <name>{title}</name>',
        f'    <setname>{setname}</setname>',
        '    <rbf>Model1</rbf>',
        '    <mameversion>0261</mameversion>',
        f'    <year>{year}</year>',
        '    <manufacturer>Sega</manufacturer>',
        f'    <category>{cat}</category>',
        '',
        '    <!--',
        '      Generated by tools/gen_mra.py from MAME\'s model1.cpp. Do not hand-edit:',
        '      regenerate, so the layout keeps one source.',
        '',
        '      m1_rom_loader does no base-address arithmetic, so this file owns the ROM',
        '      layout completely. A misplaced region does not fail at load - it fails as',
        '      a checksum error much later, looking like a CPU bug.',
        '',
        f'      {note}',
        '',
        '      The V60 address space is sparse; rtl/io/m1_decode.sv maps it packed:',
        '        V60 0x200000-0x2fffff  ROMX, the program     -> stream 0x000000',
        '        V60 0xf80000-0xffffff  ROM0, the boot vector -> stream 0x100000',
        '        V60 0x100000-0x1fffff  banked data, +bank    -> stream 0x180000',
        '',
        '      The TGP microcode goes on index 1 and its data ROM and sincos tables',
        '      are appended to this stream. Not sent yet: the polygon ROMs and the',
        '      sound board. Those blocks do not exist in the core, so sending them would',
        '      only slow the load. They belong here as M2 and M4 land.',
        '    -->',
        '    <!-- WHICH GAME THIS IS. Six titles share one bitstream and they do not',
        '         agree about the input map, so the core has to be told. Ahead of',
        '         index 0 deliberately: the byte must arrive before the ROM.',
        '         0 Virtua Racing / Formula, 1 Virtua Fighter, 2 Star Wars,',
        '         3 Wing War, 4 NetMerc. -->',
        '    <rom index="4" md5="none">',
        f'        <part>{GAME_ID[setname]:02X} {GAME_ID[setname]:02X}</part>',
        '    </rom>',
        '',
        f'    <rom index="0" zip="{zip_for(setname, 0)}" md5="none">',
    ]

    off = 0
    for c in chunks:
        if c[0] == 'pad0':
            out.append(f'        <!-- stream 0x{off:06x}: the coprocessor\'s data ROM,')
            out.append('             2 MB of ZEROS. MAME marks this region ROMREGION_ERASE00 with')
            out.append('             IC39-IC42 unpopulated, so the sockets are empty - but the space')
            out.append('             is not optional: the polygon ROM sits at a fixed offset behind')
            out.append('             it, and omitting the region put the models 2.25 MB early. -->')
            out.append(f'        <part repeat="{c[1]}">00</part>')
            off += c[1]
        elif c[0] == 'pad':
            out.append(f'        <!-- stream 0x{off:06x}: {c[1]} bytes unpopulated -->')
            out.append(f'        <part repeat="{c[1]}">FF</part>')
            off += c[1]
        elif c[0] == 'rom':
            out.append(f'        <!-- stream 0x{off:06x} -->')
            out.append(f'        <part name="{c[1]}"/>')
            off += c[2]
        elif c[0] == 'quad':
            parent = CLONE_COPRO_NOTE.get(setname)
            if parent:
                out.append('        <!-- THE COPROCESSOR DATA ROM AND SINCOS TABLES WERE MISSING from this')
                out.append("             clone's MRA, and the polygon ROMs sat at 0x600000 where the")
                out.append(f"             core reads the data ROM. MAME's {setname} carries the same")
                nums = sorted(int(re.search(r'-(\d+)\.', n).group(1)) for n in COPRO_DATA[setname])
                out.append(f'             copro_data as {parent} (mpr-{nums[0]}..{nums[-1]}) and the same')
                out.append("             MODEL1_CPU_BOARD tables, so these blocks are the parent's.")
                out.append(f'             Untested - no {setname}.zip on the machine it was written on. -->')
            out.append(f'        <!-- stream 0x{off:06x}: the coprocessor\'s DATA ROM, 2 MB.')
            out.append("             MAME's copro_data. The TGP reads it through IO 0x8000-0xffff")
            out.append('             and it is read BEFORE any math unit, so without it the')
            out.append('             coprocessor stalls at microcode 0x49, never drains its command')
            out.append('             FIFO, and a full FIFO halts the V60 — a screen that tears down')
            out.append('             and rebuilds every 0.45 s. COPRO_DAT_BASE in m1_integrated.sv.')
            out.append('             ROM_LOAD32_BYTE x4 is a four-way byte interleave. -->')
            out.append('        <interleave output="32">')
            for i, n in enumerate(c[1]):
                m = ['0'] * 4
                m[4 - 1 - i] = '1'
                out.append(f'            <part name="{n}" map="{"".join(m)}"/>')
            out.append('        </interleave>')
            off = COPRO_TBL_OFF
        elif c[0] == 'wpair':
            out.append(f'        <!-- stream 0x{off:06x}: the sincos tables, 256 KB.')
            out.append("             MAME's copro_tables, from MODEL1_CPU_BOARD. COPRO_TBL_BASE in")
            out.append('             m1_integrated.sv. ROM_LOAD32_WORD x2 is a two-way 16-bit')
            out.append('             interleave into the same 32-bit words.')
            out.append('')
            out.append("             MAME's other_data — opr-14744..14747, the 1/x and 1/sqrt")
            out.append('             tables — is deliberately absent: this design computes those in')
            out.append('             fp_div rather than reading them, so there is no port for them')
            out.append('             and the files are not in the ROM set. -->')
            out.append('        <interleave output="32">')
            out.append(f'            <part name="{c[1][0]}" map="0021"/>')
            out.append(f'            <part name="{c[1][1]}" map="2100"/>')
            out.append('        </interleave>')
            off += 0x40000
        elif c[0] == 'wquad':
            names = c[1]
            out.append(f'        <!-- stream 0x{off:06x}: the polygon model ROMs, '
                       f'{len(names)//2 * 4} MB.')
            out.append("             MAME's `polygons` region. Pairs of ROM_LOAD32_WORD halves,")
            out.append('             each pair 4 MB apart, exactly as the sincos tables above but')
            out.append(f'             {len(names)//2} times over.')
            out.append('')
            out.append('             This region was ABSENT until 2026-08-30 and nothing noticed,')
            out.append('             because nothing read it: with no rasterizer a missing 16 MB')
            out.append('             looks identical to a working core. The coprocessor data ROM')
            out.append('             went missing the same way and cost two sessions. -->')
            for i in range(0, len(names), 2):
                out.append('        <interleave output="32">')
                out.append(f'            <part name="{names[i]}" map="0021"/>')
                out.append(f'            <part name="{names[i+1]}" map="2100"/>')
                out.append('        </interleave>')
                off += 0x400000
        else:
            _, lo, hi, sz = c
            out.append(f'        <!-- stream 0x{off:06x}, ROM_LOAD16_BYTE -->')
            out.append('        <interleave output="16">')
            out.append(f'            <part name="{lo}" map="01"/>')
            out.append(f'            <part name="{hi}" map="10"/>')
            out.append('        </interleave>')
            off += sz * 2

    out += ['    </rom>']

    prog = COPRO_PROG.get(setname)
    if prog:
        out += [
            '',
            '    <!-- Coprocessor microcode, on its own download index.',
            '         m1_rom_loader routes index 1 to the TGP\'s program RAM rather than to',
            '         SDRAM, so this needs no offset inside the main stream: putting it at the',
            '         loader\'s old byte offset would have meant padding 25 MB of filler',
            '         through the HPS to deliver 8 KB. 2048 words of 32 bits, little-endian,',
            '         which is exactly the file. -->',
            f'    <rom index="1" zip="{zip_for(setname, 1)}" md5="none">',
            f'        <part name="{prog}"/>',
            '    </rom>',
        ]

    # THE I/O BOARD'S FIRMWARE, FROM MAME'S BIOS SET.
    #
    # EPR-14869 is a ROM_SYSTEM_BIOS inside model1io.cpp's own set - the same
    # kind of thing as stvbios or neogeo - and MAME will not start `vr` at all
    # without it. It is in no game zip: checked by hash, no member of vr.zip
    # has its contents. So it comes from model1io.zip, which any complete set
    # has because MAME requires it.
    #
    # THE REVISION IS PER GAME, from model1.cpp: vf() and swa() both call
    # set_default_bios_tag("epr14869b") and everything else takes the default,
    # epr-14869. model1io.cpp's own comments name them - "Virtua Racing
    # (837-8950-01)" against "Virtua Fighter (837-8936), Star Wars Arcade".
    # Daytona's epr-14869c is a third revision and is NOT what a Model 1 board
    # runs, which is worth stating because it is the copy nearest to hand.
    iofw = 'epr-14869b.25' if setname.startswith(('vf', 'swa')) else 'epr-14869.25'
    if setname in IO2_SETS:
        out += [
            '',
            "    <!-- The I/O board Z80 firmware. WING WAR'S IS NOT THE OTHER GAMES':",
            "         model1.cpp's wingwar() fits SEGA_MODEL1IO2 with BIOS epr16891,",
            '         a TMPZ84C015 board, and the core becomes that board for game id 3',
            "         (Model1.sv io_board2). On EPR-14869 the game's V60 waits forever",
            '         for the I/O board to accept its settings block and never leaves',
            "         boot. EPR-16891 is in MAME's model1io2 device set, which MAME also",
            '         requires to run this game. Only its first 16 KB are sent. -->',
            '    <rom index="2" zip="model1io2.zip" md5="none">',
            '        <part name="epr-16891.6"/>',
            '    </rom>',
        ]
    else:
      out += [
        '',
        '    <!-- The I/O board Z80 firmware, from MAME\'s model1io BIOS set.',
        '         REQUIRED: the core runs the real Z80 and there is no',
        '         behavioural fallback. MAME will not start this game without',
        '         the same file, so a complete romset already has it. -->',
        # BOTH NAMES. model1io is MAME's own device set and the canonical
        # place for this file, but it is a BIOS set that many collections
        # fold into the games that need it - and daytona93.zip carries all
        # three revisions, which is where it is in practice. Naming both
        # means no one has to assemble a zip by hand, which is what Ben
        # objected to and rightly.
        f'    <rom index="2" zip="model1io.zip|daytona93.zip" md5="none">',
        f'        <part name="{iofw}"/>',
        '    </rom>',
      ]

    out += emit_eeprom(setname, regions)
    out += emit_sound(setname, regions)

    out += [
        '',
        '    <nvram index="255" size="256"/>',
        '',
        # THE NAMES FOLLOW Model1.sv's joy0 BITS, and the old ones did not.
        #
        # MiSTer names buttons from joystick bit 4 upward, bits 0-3 being the
        # d-pad. Model1.sv wires bit 4 to the accelerator, but this element
        # called it Start - so every button the OSD offered was mislabelled by
        # eight positions and the pedals were not offered at all. The core's
        # order, from Model1.sv:
        #
        #   4 accelerate   5 brake       6 shift up   7 shift down
        #   8 VR1          9 VR2        10 VR3       11 VR4
        #  12 start       13 coin       14 service   15 test      16 coin 2
        #
        # STEERING: d-pad left and right go to full lock, and the LEFT
        # ANALOGUE STICK steers proportionally when the d-pad is idle.
        #
        # THERE IS NO EIGHT-BUTTON LIMIT, which an earlier version of this
        # assumed and used to justify leaving the gearbox unmapped. hps_io
        # declares `joystick_0` as 32 bits - "buttons up to 32" in its own
        # comment - and the MRA default attribute takes far more than the
        # face buttons. Every token below appears in a working MRA on a real
        # MiSTer, which is where the list came from; the MiSTer MRA
        # documentation does not enumerate them:
        #
        #     A B C X Y Z  L R  L1 R1 L2 R2  Select Start
        #     Rup Rdown Rleft Rright   (the right stick as buttons)
        #
        # THE PEDALS ARE ON L2 AND R2, which is where a driving game puts
        # them: they are the analogue triggers on a PlayStation-style pad and
        # MiSTer accepts both as button tokens here. Bound this way they are
        # digital, full press - MiSTer cannot read a trigger's byte value as a
        # button. For ANALOGUE travel the core also reads two stick axes,
        # left-stick-down for the accelerator and right-stick-right for the
        # brake, which is the documented racing convention and where a player
        # binds a trigger in the OSD to get its full range. Whichever route is
        # mapped works, and the larger of the two wins.
        #
        # That frees the face buttons for the four VR views, and the gearbox
        # keeps the shoulders. The gearbox is ALSO on the d-pad's up and down
        # in the core, which costs nothing and is what a driving game does
        # anyway. Service and test stay named but unmapped, since both are
        # already on the OSD.
        f'    <buttons names="{BUTTONS.get(setname, BUTTONS_DRIVE)[0]}" '
        f'default="{BUTTONS.get(setname, BUTTONS_DRIVE)[1]}"/>',
        '</misterromdescription>',
        '',
    ]
    return '\n'.join(out)


# Verbatim note texts, as the MRAs carry them.
EEPROM_NOTE = [
    "    <!-- The I/O board's 93C46 settings EEPROM, 128 bytes, from the GAME set",
    '         rather than the model1io BIOS set. Its first word is the "SEGA"',
    '         signature the V60 checks at FE078E before deciding the board has been',
    '         configured; without it the firmware publishes an identity block that',
    '         fails that check and the game takes its uninitialised-board branch,',
    '         which walks a much shorter display list. Its own index because',
    '         m1_ioz80 preloads its array from SDRAM before releasing the Z80. -->',
]
SND_PRENOTE_TEXT = [
    "    <!-- THE SOUND BOARD, index 5. Its own index for the same reason the TGP's",
    '         microcode has one: the bases are at 26 MB and beyond, so carrying this',
    '         on index 0 would mean padding ~26 MB of filler through the HPS.',
    '         Index 4 is the game-id byte, not free.',
    '',
    "         One stream, three destinations, split by m1_rom_loader's SND_*",
    "         parameters because the bases are not contiguous - the 68000's 64 KB of",
    '         work RAM sits between the program and PCM1:',
    '',
    '           0x000000  epr-14870a.7   0x20000   68000 program  -> 0xD10000',
    '           0x020000  mpr-14873.32  0x200000   MultiPCM 1     -> 0xD40000',
    '           0x220000  mpr-14876.4   0x200000   MultiPCM 2     -> 0xE40000',
    '',
    '         The 68000 ROM is ROM_LOAD16_WORD_SWAP in MAME, so it is byte-swapped',
    '         here with map="12" on a 16-bit interleave - the same form Model 2 uses',
    '         for its own sound 68000. The sample ROMs are byte streams and go in',
    '         plain. -->',
]
SND_SHAPE_NOTE = [
    '        <!--',
    '             FOUR MB PER MULTIPCM, 2026-09-16. One stream shape for every game:',
    '',
    '               0x000000  68000 program   512 KB',
    '               0x080000  MultiPCM 1        4 MB',
    '               0x480000  MultiPCM 2        4 MB',
    '',
    "             512 KB for the program because NetMerc's is a SINGLE 512 KB ROM;",
    '             Virtua Fighter and Wing War have two 128 KB ones and Virtua Racing',
    '             has one. Short sets are zero-padded so every game presents the same',
    '             shape.',
    '',
    '             These regions live ABOVE 32 MB, which only became addressable when',
    '             the SDRAM controller went to ten column bits. Nothing below 32 MB',
    '             moved, so the polygon ROM and copro tables stay exactly where the',
    '             packer has always written them - an earlier attempt to find this',
    '             space by sliding those regions down broke the 3D on hardware.',
    '',
    '             PADS ARE 00, NOT FF. Model1.sv used to mask MultiPCM reads above',
    '             2 MB to zero, matching MAME, which gives each chip a 4 MB region',
    '             and may load less into it. That mask is gone now the space is real,',
    '             so the zeros must be in the data: FF would be full-scale noise',
    '             exactly where the reference is silent.',
    '',
    '             68000 ROMs are ROM_LOAD16_WORD_SWAP in MAME, so each is byte-',
    '             swapped with map="12" on a 16-bit interleave; samples go in plain.',
    '        -->',
]
DSB_NOTE = [
    '        <!--',
    "             STAR WARS' DIGITAL SOUND BOARD, 2026-10-28: the music. Appended to",
    '             the same stream, which the loader maps linearly on past PCM2 into',
    '             free SDRAM (nothing else moves):',
    '',
    '               0x880000  DSB Z80 program, epr-16471.2   128 KB',
    '               0x8A0000  DSB MPEG data, mpr-16514 + 16515  4 MB',
    '               0xCA0000  end',
    '',
    '             Plain bytes, as MAME loads them (ROM_LOAD, no swap).',
    '        -->',
]


def emit_eeprom(setname, regions):
    """Index 3: the I/O board's 93C46 image, for a set whose MAME definition
    has an ioboard:eeprom region (only vr)."""
    loads = regions.get('"ioboard:eeprom"')
    if not loads:
        return []
    out = [''] + EEPROM_NOTE + [f'    <rom index="3" zip="{zip_for(setname, 3)}" md5="none">']
    out += [f'        <part name="{n}"/>' for _, _, n, _ in loads]
    return out + ['    </rom>']


def _region_parts(setname, loads, length, pad):
    """Parts for one region: each load in offset order, gaps and the tail
    filled with `pad` bytes up to `length` (no fill when length is None)."""
    out, pos = [], 0
    for off, size, name, kind in loads:
        if off > pos:
            out.append(f'        <part repeat="{off - pos}">{pad}</part>')
        if kind == '16_WORD_SWAP':
            out.append('        <interleave output="16">')
            who = SND_PART_NOTE.get((setname, name))
            if who:
                out.append(f"            <!-- {name}, not the World set's epr-17126.7: MAME's wingwaru and")
                out.append('                 wingwarj both load 16751 here. -->')
            out.append(f'            <part name="{name}" map="12"/>')
            out.append('        </interleave>')
        else:
            out.append(f'        <part name="{name}"/>')
        pos = off + size
    if length is not None and pos < length:
        out.append(f'        <part repeat="{length - pos}">{pad}</part>')
    return out


def emit_sound(setname, regions):
    """Index 5: the sound board's stream - the 68000 program padded to 512 KB,
    each MultiPCM region padded to 4 MB, then Star Wars' DSB (Z80 program and
    MPEG data) appended unpadded, which m1_rom_loader maps on past PCM2."""
    if 'M1AUDIO_CPU_REGION' not in regions:
        return []
    out = ['']
    if setname in SND_PRENOTE:
        out += SND_PRENOTE_TEXT
    out.append(f'    <rom index="5" zip="{zip_for(setname, 5)}">')
    out += SND_SHAPE_NOTE
    for reg, length in SND_REGIONS:
        out += _region_parts(setname, regions.get(reg, []), length, '00')
    dsb = [l for r in DSB_REGIONS for l in regions.get(r, [])]
    if dsb:
        out += DSB_NOTE
        for r in DSB_REGIONS:
            out += _region_parts(setname, regions.get(r, []), None, '00')
    return out + ['    </rom>']


def check_zip(zip_path, chunks):
    """Every referenced file present at the size MAME states."""
    if not os.path.exists(zip_path):
        return None
    sizes = {}
    with zipfile.ZipFile(zip_path) as zf:
        for i in zf.infolist():
            sizes[os.path.basename(i.filename).lower()] = i.file_size

    problems = []
    for c in chunks:
        want = [(c[1], c[2])] if c[0] == 'rom' else \
               ([(c[1], c[3]), (c[2], c[3])] if c[0] == 'pair' else
                [(n, 0x200000) for n in c[1]] if c[0] == 'wquad' else [])
        for name, size in want:
            got = sizes.get(name.lower())
            if got is None:
                problems.append(f"missing {name}")
            elif got != size:
                problems.append(f"{name} is {got} bytes, MAME says {size}")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-o', '--out', default='mra')
    ap.add_argument('-r', '--roms', default=os.path.expanduser('~/roms'),
                    help='directory of ROM sets, checked when present')
    args = ap.parse_args()

    if not os.path.exists(MODEL1):
        raise SystemExit(f"{MODEL1} missing — run ./tools/bootstrap.sh")

    sets = parse_sets(MODEL1)
    regions = parse_regions(MODEL1)
    os.makedirs(args.out, exist_ok=True)

    made = skipped = 0
    for name in sorted(TITLES):
        if name not in sets:
            print(f"  {name:11s} not in model1.cpp, skipped")
            skipped += 1
            continue

        chunks, warnings = build_chunks(sets[name], name)
        if chunks is None:
            print(f"  {name:11s} SKIPPED: {'; '.join(warnings)}")
            skipped += 1
            continue

        title = TITLES[name][0]
        path = os.path.join(args.out, f'{title}.mra')
        with open(path, 'w') as f:
            f.write(emit(name, chunks, name in CROSS_CHECKED, regions.get(name, {})))

        zp = os.path.join(args.roms, f'{name}.zip')
        problems = check_zip(zp, chunks)
        if problems is None:
            state = 'no local set to check'
        elif problems:
            state = 'ROM CHECK FAILED: ' + '; '.join(problems[:3])
        else:
            state = 'files present at the stated sizes'
        tag = 'cross-checked' if name in CROSS_CHECKED else 'untested'
        print(f"  {name:11s} -> {title}.mra  [{tag}] {state}")
        made += 1

    print(f"\n{made} written, {skipped} skipped")
    return 0


sys.exit(main())
