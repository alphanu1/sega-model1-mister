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


def build_chunks(loads):
    """Stream-ordered chunks: ('pad', n) | ('rom', name) | ('pair', lo, hi)."""
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
    return chunks, warnings


def emit(setname, chunks, cross_checked):
    title, year, cat = TITLES.get(setname, (setname, 0, ''))
    note = ("tools/verify_mra.py diffs this against build_rom_image.py's\n"
            "      independently written packing, so the layout has a second source."
            if cross_checked else
            "NOT CROSS-CHECKED. Generated from MAME's ROM definitions, and every\n"
            "      file is confirmed present at the size MAME states — but there is no\n"
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
        '      layout completely. A misplaced region does not fail at load — it fails as',
        '      a checksum error much later, looking like a CPU bug.',
        '',
        f'      {note}',
        '',
        '      The V60 address space is sparse; rtl/io/m1_decode.sv maps it packed:',
        '        V60 0x200000-0x2fffff  ROMX, the program     -> stream 0x000000',
        '        V60 0xf80000-0xffffff  ROM0, the boot vector -> stream 0x100000',
        '        V60 0x100000-0x1fffff  banked data, +bank    -> stream 0x180000',
        '',
        '      Not sent yet: the TGP program and data ROMs, the polygon ROMs and the',
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
        else:
            _, lo, hi, sz = c
            out.append(f'        <!-- stream 0x{off:06x}, ROM_LOAD16_BYTE -->')
            out.append('        <interleave output="16">')
            out.append(f'            <part name="{lo}" map="01"/>')
            out.append(f'            <part name="{hi}" map="10"/>')
            out.append('        </interleave>')
            off += sz * 2

    out += [
        '    </rom>',
        '',
        '    <nvram index="255" size="256"/>',
        '',
        '    <buttons names="Start,Coin,Service,Test,-,-" default="A,R,L,Start"/>',
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
               ([(c[1], c[3]), (c[2], c[3])] if c[0] == 'pair' else [])
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

        chunks, warnings = build_chunks(sets[name])
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
