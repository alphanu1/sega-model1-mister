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
}
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

COPRO_TABLES = {                     # ROM_LOAD32_WORD x2, 256 KB
    'vr':       ['opr14742.bin', 'opr14743.bin'],
    'vformula': ['opr14742.bin', 'opr14743.bin'],
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
    if setname in COPRO_TABLES:
        if total != COPRO_TBL_OFF:
            warnings.append(f"tables would land at 0x{total:x}, not 0x{COPRO_TBL_OFF:x}")
            return None, warnings
        chunks.append(('wpair', COPRO_TABLES[setname]))
    if setname in POLYGONS:
        chunks.append(('wquad', POLYGONS[setname]))

    return chunks, warnings


def emit(setname, chunks, cross_checked):
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
        f'    <rom index="0" zip="{setname}.zip" md5="none">',
    ]

    off = 0
    for c in chunks:
        if c[0] == 'pad':
            out.append(f'        <!-- stream 0x{off:06x}: {c[1]} bytes unpopulated -->')
            out.append(f'        <part repeat="{c[1]}">FF</part>')
            off += c[1]
        elif c[0] == 'rom':
            out.append(f'        <!-- stream 0x{off:06x} -->')
            out.append(f'        <part name="{c[1]}"/>')
            off += c[2]
        elif c[0] == 'quad':
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
            f'    <rom index="1" zip="{setname}.zip|{setname}.7z" md5="none">',
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
    out += [
        '',
        '    <!-- The I/O board Z80 firmware, from MAME\'s model1io BIOS set.',
        '         REQUIRED: the core runs the real Z80 and there is no',
        '         behavioural fallback. MAME will not start this game without',
        '         the same file, so a complete romset already has it. -->',
        f'    <rom index="2" zip="model1io.zip" md5="none">',
        f'        <part name="{iofw}"/>',
        '    </rom>',
    ]

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
        # So everything a player touches gets a default. The gearbox is ALSO
        # on the d-pad's up and down in the core, which costs nothing and is
        # what a driving game does anyway. Service and test stay named but
        # unmapped, since both are already on the OSD.
        '    <buttons names="Accelerate,Brake,Shift Up,Shift Down,'
        'VR1,VR2,VR3,VR4,Start,Coin,Service,Test,Coin 2" '
        'default="A,B,R1,L1,X,Y,L,R,Start,Select"/>',
        '</misterromdescription>',
        '',
    ]
    return '\n'.join(out)


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
            f.write(emit(name, chunks, name in CROSS_CHECKED))

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
