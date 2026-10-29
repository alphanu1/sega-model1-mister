#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Which Z80 opcodes can the DSB's program (epr-16471.2) execute? Traced
# statically from MAME's own disassembly of it: from the reset vector and the
# IM 1 vector, following every branch, call and fall-through. A JP (HL), JP (IX)
# or anything else whose target cannot be known statically fails the census
# rather than being skipped.
#
# Then every reached opcode is checked against dsb_z80's dispatch table
# (tools/dsb/gen_z80_ucode.py): one missing is a FAIL, which is what lets
# dsb_z80 implement those and nothing else.
#
#   the disassembly, headless (tools/dsb/prepare.sh does this with MAME=1):
#     mame swa -debug -debugger none -video none -sound none ... and the
#     debugger command  dasm <file>,0,8000,1,:dsbz80:mpegcpu
#   python3 tools/dsb/z80_census.py build/rom/dsb/z80.asm
import os, re, sys, importlib.util

ins = {}
for l in open(sys.argv[1]):
    m = re.match(r'([0-9A-F]{4}): ((?:[0-9A-F]{2} )+)\s*(.*)', l.rstrip())
    if m:
        ins[int(m.group(1), 16)] = (m.group(2).split(), m.group(3).strip())

seen, work, ops, bad = set(), [0x0000, 0x0038], {}, 0
while work:
    a = work.pop()
    while a not in seen:
        if a not in ins:
            print(f'FAIL: no instruction at {a:04x} (misaligned trace)'); bad += 1; break
        seen.add(a)
        b, t = ins[a]
        if b[0] in ('DD', 'FD'):
            print(f'FAIL: IX/IY at {a:04x}: {t}'); bad += 1
        key = (1 if b[0] == 'CB' else 2 if b[0] == 'ED' else 0,
               int(b[1] if b[0] in ('CB', 'ED') else b[0], 16))
        ops.setdefault(key, set()).add(re.sub(r'\$[0-9A-F]+', 'n', t))
        mn = t.split()[0]
        if '(' in t and mn == 'jp':
            print(f'FAIL: indirect jump at {a:04x}: {t}'); bad += 1; break
        tgt = re.search(r'\$([0-9A-F]{4})$', t)
        if mn in ('jp', 'jr', 'call', 'djnz') and tgt:
            work.append(int(tgt.group(1), 16))
        if mn in ('jp', 'jr') and ',' not in t: break
        if mn in ('ret', 'reti', 'retn') and len(t.split()) == 1: break
        if mn == 'rst':
            work.append(int(t.split()[1].lstrip('$'), 16))
        a += len(b)

spec = importlib.util.spec_from_file_location('g', os.path.join(os.path.dirname(__file__), 'gen_z80_ucode.py'))
src = open(spec.origin).read().split('# ---- assemble')[0]   # the tables, not the output
g = {}
exec(compile(src, spec.origin, 'exec'), g)
entry = g['entry']
pfx = ['', 'CB ', 'ED ']
for k in sorted(ops):
    have = k in entry
    if not have: bad += 1
    print(f"{'ok  ' if have else 'FAIL'} {pfx[k[0]]}{k[1]:02X}  {sorted(ops[k])[0]}")
print(f'{len(seen)} instructions reachable, {len(ops)} distinct opcodes, '
      f'{len(entry)} implemented, {bad} problems')
sys.exit(1 if bad else 0)
