#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sega Model 1 core for MiSTer FPGA
# Copyright (C) 2026 alphanu1
#
# A Z80 disassembler, because the I/O board's protocol is only written down
# inside EPR-14869.
#
# WHY THIS EXISTS RATHER THAN A DEPENDENCY
#
# D9 chose an HLE for the I/O board, which means the protocol has to be read out
# of the Z80 ROM. Byte-pattern searching got as far as locating the access
# routines — about 60 bytes at 0x74c-0x7b4 — and then stopped, because the DPRAM
# address is held in a register across basic blocks and pattern matching cannot
# follow that.
#
# Ghidra would do it and is packaged for this distro, but it wants a JDK and
# about a gigabyte for a job whose entire input is 16 KB. This is a few hundred
# lines, has no dependencies, lives in the repository, and can be checked
# against facts already established by other means.
#
# NOTHING ROM-DERIVED IS COMMITTED. This reads a ROM the user already owns and
# prints to stdout; hard rule 2 means neither the image nor its disassembly
# enters the repository. What gets written down is the protocol, in prose, in
# docs/io-board.md — the interface an HLE has to reproduce, which is the same
# thing MAME's device models document.
#
# HOW IT DECODES
#
# Not a 256-entry table typed out by hand, which is where a disassembler's
# errors hide and which is unreviewable. Z80 opcodes decompose into bit fields —
# x = bits 7-6, y = bits 5-3, z = bits 2-0, with y further splitting into p and q
# — and the instruction set is regular in those fields. So the tables are small
# lists of register and condition names, and the structure is the published
# decomposition. A mistake in it shows up as a whole class of instructions being
# wrong rather than as one silent bad entry.
#
#   tools/z80dasm.py rom.bin                    whole file from 0x0000
#   tools/z80dasm.py rom.bin -s 0x740 -e 0x7c0  a range
#   tools/z80dasm.py rom.bin --self-test        decode checks, no ROM needed

import argparse, sys

R    = ['B', 'C', 'D', 'E', 'H', 'L', '(HL)', 'A']
RP   = ['BC', 'DE', 'HL', 'SP']
RP2  = ['BC', 'DE', 'HL', 'AF']
CC   = ['NZ', 'Z', 'NC', 'C', 'PO', 'PE', 'P', 'M']
ALU  = ['ADD A,', 'ADC A,', 'SUB ', 'SBC A,', 'AND ', 'XOR ', 'OR ', 'CP ']
ROT  = ['RLC', 'RRC', 'RL', 'RR', 'SLA', 'SRA', 'SLL', 'SRL']
IM   = ['0', '0/1', '1', '2', '0', '0/1', '1', '2']
BLK  = {(4, 0): 'LDI',  (5, 0): 'LDD',  (6, 0): 'LDIR', (7, 0): 'LDDR',
        (4, 1): 'CPI',  (5, 1): 'CPD',  (6, 1): 'CPIR', (7, 1): 'CPDR',
        (4, 2): 'INI',  (5, 2): 'IND',  (6, 2): 'INIR', (7, 2): 'INDR',
        (4, 3): 'OUTI', (5, 3): 'OUTD', (6, 3): 'OTIR', (7, 3): 'OTDR'}


class Dis:
    def __init__(self, data, org=0):
        self.d = data
        self.org = org

    def u8(self, p):
        return self.d[p] if 0 <= p < len(self.d) else 0

    def u16(self, p):
        return self.u8(p) | (self.u8(p + 1) << 8)

    def s8(self, p):
        v = self.u8(p)
        return v - 256 if v > 127 else v

    # Index-register substitution. DD and FD are the same instruction set with
    # HL replaced, and (HL) replaced by (IX+d) — which also makes the
    # instruction one byte longer, the detail that makes naive decoders drift.
    def _reg(self, i, idx, disp):
        if idx is None or i not in (4, 5, 6):
            return R[i]
        if i == 6:
            return f'({idx}{disp:+d})'
        return idx + ('H' if i == 4 else 'L')

    def decode(self, p):
        """Return (text, length) for the instruction at offset p."""
        start = p
        idx = None
        op = self.u8(p); p += 1

        if op in (0xDD, 0xFD):
            idx = 'IX' if op == 0xDD else 'IY'
            op = self.u8(p); p += 1
            if op == 0xCB:
                disp = self.s8(p); p += 1
                sub = self.u8(p); p += 1
                x, y, z = sub >> 6, (sub >> 3) & 7, sub & 7
                tgt = f'({idx}{disp:+d})'
                if x == 0:
                    t = f'{ROT[y]} {tgt}'
                elif x == 1:
                    t = f'BIT {y},{tgt}'
                elif x == 2:
                    t = f'RES {y},{tgt}'
                else:
                    t = f'SET {y},{tgt}'
                if x != 1 and z != 6:
                    t += f',{R[z]}'          # undocumented result copy
                return t, p - start

        if op == 0xCB:
            sub = self.u8(p); p += 1
            x, y, z = sub >> 6, (sub >> 3) & 7, sub & 7
            r = R[z]
            if x == 0:
                return f'{ROT[y]} {r}', p - start
            if x == 1:
                return f'BIT {y},{r}', p - start
            return (f'RES {y},{r}' if x == 2 else f'SET {y},{r}'), p - start

        if op == 0xED:
            sub = self.u8(p); p += 1
            x, y, z = sub >> 6, (sub >> 3) & 7, sub & 7
            q, pp = y & 1, y >> 1
            if x == 1:
                if z == 0:
                    return (f'IN {R[y]},(C)' if y != 6 else 'IN (C)'), p - start
                if z == 1:
                    return (f'OUT (C),{R[y]}' if y != 6 else 'OUT (C),0'), p - start
                if z == 2:
                    return f'{"ADC" if q else "SBC"} HL,{RP[pp]}', p - start
                if z == 3:
                    nn = self.u16(p); p += 2
                    return (f'LD {RP[pp]},({nn:04X}h)' if q
                            else f'LD ({nn:04X}h),{RP[pp]}'), p - start
                if z == 4:
                    return 'NEG', p - start
                if z == 5:
                    return ('RETN' if y != 1 else 'RETI'), p - start
                if z == 6:
                    return f'IM {IM[y]}', p - start
                return (['LD I,A', 'LD R,A', 'LD A,I', 'LD A,R',
                         'RRD', 'RLD', 'NOP', 'NOP'][y]), p - start
            if x == 2 and z <= 3 and y >= 4:
                return BLK[(y, z)], p - start
            return f'DB EDh,{sub:02X}h', p - start

        x, y, z = op >> 6, (op >> 3) & 7, op & 7
        q, pp = y & 1, y >> 1
        HL = idx if idx else 'HL'

        # An index displacement is fetched before the immediate, which is the
        # ordering DD 36 dd nn depends on.
        def disp():
            nonlocal p
            if idx is None:
                return 0
            v = self.s8(p); p += 1
            return v

        if x == 0:
            if z == 0:
                if y == 0: return 'NOP', p - start
                if y == 1: return "EX AF,AF'", p - start
                if y == 2:
                    e = self.s8(p); p += 1
                    return f'DJNZ {self.org + p + e:04X}h', p - start
                if y == 3:
                    e = self.s8(p); p += 1
                    return f'JR {self.org + p + e:04X}h', p - start
                e = self.s8(p); p += 1
                return f'JR {CC[y-4]},{self.org + p + e:04X}h', p - start
            if z == 1:
                if q == 0:
                    nn = self.u16(p); p += 2
                    return f'LD {idx if (pp == 2 and idx) else RP[pp]},{nn:04X}h', p - start
                return f'ADD {HL},{idx if (pp == 2 and idx) else RP[pp]}', p - start
            if z == 2:
                if q == 0:
                    if pp == 0: return 'LD (BC),A', p - start
                    if pp == 1: return 'LD (DE),A', p - start
                    nn = self.u16(p); p += 2
                    return (f'LD ({nn:04X}h),{HL}' if pp == 2
                            else f'LD ({nn:04X}h),A'), p - start
                if pp == 0: return 'LD A,(BC)', p - start
                if pp == 1: return 'LD A,(DE)', p - start
                nn = self.u16(p); p += 2
                return (f'LD {HL},({nn:04X}h)' if pp == 2
                        else f'LD A,({nn:04X}h)'), p - start
            if z == 3:
                r = idx if (pp == 2 and idx) else RP[pp]
                return f'{"DEC" if q else "INC"} {r}', p - start
            if z in (4, 5):
                dd = disp()
                r = self._reg(y, idx, dd)
                return f'{"DEC" if z == 5 else "INC"} {r}', p - start
            if z == 6:
                dd = disp()
                r = self._reg(y, idx, dd)
                n = self.u8(p); p += 1
                return f'LD {r},{n:02X}h', p - start
            return ['RLCA', 'RRCA', 'RLA', 'RRA',
                    'DAA', 'CPL', 'SCF', 'CCF'][y], p - start

        if x == 1:
            if y == 6 and z == 6:
                return 'HALT', p - start
            dd = disp() if (idx and (y == 6 or z == 6)) else 0
            # Only the (HL) operand becomes indexed; H/L stay H/L in that case.
            dst = f'({idx}{dd:+d})' if (idx and y == 6) else \
                  (self._reg(y, idx, dd) if not (idx and z == 6) else R[y])
            src = f'({idx}{dd:+d})' if (idx and z == 6) else \
                  (self._reg(z, idx, dd) if not (idx and y == 6) else R[z])
            return f'LD {dst},{src}', p - start

        if x == 2:
            dd = disp() if (idx and z == 6) else 0
            return f'{ALU[y]}{self._reg(z, idx, dd)}', p - start

        # x == 3
        if z == 0:
            return f'RET {CC[y]}', p - start
        if z == 1:
            if q == 0:
                return f'POP {idx if (pp == 2 and idx) else RP2[pp]}', p - start
            return ['RET', 'EXX', f'JP ({HL})', f'LD SP,{HL}'][pp], p - start
        if z == 2:
            nn = self.u16(p); p += 2
            return f'JP {CC[y]},{nn:04X}h', p - start
        if z == 3:
            if y == 0:
                nn = self.u16(p); p += 2
                return f'JP {nn:04X}h', p - start
            if y == 2:
                n = self.u8(p); p += 1
                return f'OUT ({n:02X}h),A', p - start
            if y == 3:
                n = self.u8(p); p += 1
                return f'IN A,({n:02X}h)', p - start
            return ['', '', '', '', f'EX (SP),{HL}', 'EX DE,HL',
                    'DI', 'EI'][y], p - start
        if z == 4:
            nn = self.u16(p); p += 2
            return f'CALL {CC[y]},{nn:04X}h', p - start
        if z == 5:
            if q == 0:
                return f'PUSH {idx if (pp == 2 and idx) else RP2[pp]}', p - start
            nn = self.u16(p); p += 2
            return f'CALL {nn:04X}h', p - start
        if z == 6:
            n = self.u8(p); p += 1
            return f'{ALU[y]}{n:02X}h', p - start
        return f'RST {y * 8:02X}h', p - start


def self_test():
    """Decode checks against instructions whose encoding is not in dispute.

    Includes the two the I/O board analysis already established by byte-pattern
    search, so the tool is checked against a fact obtained a different way
    rather than only against itself.
    """
    cases = [
        (b'\x00',             'NOP'),
        (b'\xFD\x21\x00\x80', 'LD IY,8000h'),      # found by pattern search
        (b'\xFD\x36\x09\x07', 'LD (IY+9),07h'),    # ditto
        (b'\xFD\x36\x08\x4E', 'LD (IY+8),4Eh'),
        (b'\xFD\x7E\x0D',     'LD A,(IY+13)'),
        (b'\xFD\x77\x00',     'LD (IY+0),A'),
        (b'\x32\x0A\x80',     'LD (800Ah),A'),
        (b'\x3A\x0C\x80',     'LD A,(800Ch)'),
        (b'\x21\x34\x12',     'LD HL,1234h'),
        (b'\xCD\x87\x07',     'CALL 0787h'),
        (b'\xC9',             'RET'),
        (b'\x76',             'HALT'),
        (b'\x7E',             'LD A,(HL)'),
        (b'\x36\x42',         'LD (HL),42h'),
        (b'\xCB\x47',         'BIT 0,A'),
        (b'\xCB\x1E',         'RR (HL)'),
        (b'\xED\xB0',         'LDIR'),
        (b'\xED\x53\x00\x40', 'LD (4000h),DE'),
        (b'\xDD\xCB\x02\x46', 'BIT 0,(IX+2)'),
        (b'\xE6\x0F',         'AND 0Fh'),
        (b'\xD3\xFE',         'OUT (FEh),A'),
        (b'\xC7',             'RST 00h'),
        (b'\xF9',             'LD SP,HL'),
        (b'\xDD\xF9',         'LD SP,IX'),
        (b'\xEB',             'EX DE,HL'),
        (b'\x18\xFE',         'JR 0000h'),          # branch to itself
        (b'\x10\xFE',         'DJNZ 0000h'),
    ]
    bad = 0
    for enc, want in cases:
        got, n = Dis(enc, 0).decode(0)
        ok = (got == want and n == len(enc))
        if not ok:
            bad += 1
            print(f'  FAIL {enc.hex():12s} got {got!r} ({n}b), want {want!r} '
                  f'({len(enc)}b)')
    print(f'z80dasm self-test: {len(cases)} cases, {bad} failures')
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rom', nargs='?')
    ap.add_argument('-o', '--org', type=lambda v: int(v, 0), default=0)
    ap.add_argument('-s', '--start', type=lambda v: int(v, 0), default=0)
    ap.add_argument('-e', '--end', type=lambda v: int(v, 0), default=None)
    ap.add_argument('--self-test', action='store_true')
    a = ap.parse_args()

    if a.self_test:
        return self_test()
    if not a.rom:
        ap.error('a ROM is required unless --self-test')

    data = open(a.rom, 'rb').read()
    end = a.end if a.end is not None else len(data)
    d = Dis(data, a.org)

    p = a.start
    while p < end:
        text, n = d.decode(p)
        raw = ' '.join(f'{b:02X}' for b in data[p:p + n])
        print(f'{a.org + p:04X}  {raw:<12s}  {text}')
        p += n
    return 0


sys.exit(main())
