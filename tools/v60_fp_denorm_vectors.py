#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA - Copyright (C) 2026 alphanu1
#
# DIRECTED DENORMAL VECTORS FOR v60_fp, in tb_v60_fp_replay's format:
#
#   <label> <op> <subop> <a> <b> <cw> <psw_before> <result> <psw_after>
#
# Since 2026-11-12 the V60's FP handles denormals as IEEE 754 requires (NEC's
# uPD70616 Programmer's Reference Manual, p.1-12: "floating point data types
# and operations conform to the IEEE 754 standard"; p.8-8: underflow with the
# trap off places "a denormal result ... in the destination"). Results here
# are numpy.float32 (IEEE, round to nearest even, gradual underflow); flags
# follow MAME's op2.hxx rules, which are what the replay bench compares
# against. a = op1 (source), b = op2 (destination), as v60_fp takes them.
#
# The operand set is denormal-heavy: the smallest and largest denormals, the
# smallest normals, values whose products, quotients, sums and scalings land
# in the denormal range or just either side of it, and further out - down
# past the bottom of the denormal range (results that round to zero or to
# the smallest denormal) and up to values that cancel to a denormal. NaN
# results are not generated: the NaN question is separate and still open
# (the TGP harnesses skip NaN results for the same reason).
#
#   python3 tools/v60_fp_denorm_vectors.py > sim/cpu/v60_fp_denorm.txt
#   make v60_fp_denorm
import math
import random
import struct
import sys

import numpy as np

f32 = np.float32


def b2f(u):
    return np.frombuffer(struct.pack('<I', u), dtype=np.float32)[0]


def f2b(x):
    return struct.unpack('<I', np.float32(x).tobytes())[0]


def fl(z, s, ov, cy):
    return (1 if z else 0) | (2 if s else 0) | (4 if ov else 0) | (8 if cy else 0)


rng = random.Random(0x5EED_0611)
out = []


def emit(label, op, sub, a, b, cw, pswb, res, pswa):
    out.append('%s %02x %02x %08x %08x %x %08x %08x %08x' % (label, op, sub, a, b, cw, pswb, res, pswa))


def arith_flags(r):
    return fl(r == 0, r & 0x80000000, 0, 0)


def is_nan_bits(u):
    return (u & 0x7f800000) == 0x7f800000 and (u & 0x007fffff) != 0


denorms = [0x00000001, 0x00000002, 0x00000003, 0x00000004, 0x00000007, 0x000003ff,
           0x00000400, 0x00001000, 0x00080000, 0x00200000, 0x003fffff, 0x00400000,
           0x00400001, 0x00555555, 0x007ffffe, 0x007fffff]
denorms += [rng.randrange(1, 0x00800000) for _ in range(16)]
normals = [0x00800000, 0x00800001, 0x00ffffff, 0x01000000, 0x01000001, 0x017fffff,
           0x01800000, 0x02000000, 0x0c800000, 0x1f800000, 0x20000000, 0x33800000,
           0x34000000, 0x3e800000, 0x3f000000, 0x3f800000, 0x3fc00000, 0x40000000,
           0x4b000000, 0x5f000000, 0x7e800000, 0x7f000000, 0x7f7fffff, 0x00000000]
base = denorms + normals
vals = base + [v | 0x80000000 for v in base]

with np.errstate(all='ignore'):
    # ---- two-operand arithmetic and compare, every pair of the set
    ops = [('DNADD', 0x18, lambda b, a: f32(b) + f32(a)),
           ('DNSUB', 0x19, lambda b, a: f32(b) - f32(a)),
           ('DNMUL', 0x1a, lambda b, a: f32(b) * f32(a)),
           ('DNDIV', 0x1b, lambda b, a: f32(b) / f32(a))]
    for label, sub, fn in ops:
        for a in vals:
            for b in vals:
                if sub == 0x1b and (a & 0x7fffffff) == 0:
                    continue                                # x/0: not a denormal question
                r = f2b(fn(b2f(b), b2f(a)))
                if is_nan_bits(r):
                    continue
                pswb = rng.randrange(16)
                emit(label, 0x5c, sub, a, b, 0, pswb, r, arith_flags(r))
    for a in vals:
        for b in vals:
            d = f32(b2f(b)) - f32(b2f(a))
            if math.isnan(d):
                continue
            pswb = rng.randrange(16)
            emit('DNCMP', 0x5c, 0x00, a, b, 0, pswb, 0, fl(d == 0, d < 0, 0, 0))

    # ---- results that land in, or fall out of, the denormal range: random
    # operands spread over exponents an order of magnitude past each edge
    def rnd_f(lo_e, hi_e):
        e = rng.randrange(lo_e, hi_e)
        m = rng.randrange(0, 1 << 23)
        s = rng.randrange(2)
        if e <= 0:                                           # denormal encodings
            return (s << 31) | (m >> min(23, -e + 1)) if m >> min(23, -e + 1) else (s << 31) | 1
        return (s << 31) | (e << 23) | m
    for _ in range(4000):
        a, b = rnd_f(1, 110), rnd_f(1, 110)                   # products ~2^-126 .. 2^-290
        r = f2b(f32(b2f(b)) * f32(b2f(a)))
        emit('DNMULR', 0x5c, 0x1a, a, b, 0, rng.randrange(16), r, arith_flags(r))
    for _ in range(4000):
        b, a = rnd_f(-20, 60), rnd_f(110, 250)                # quotients down past 2^-149
        r = f2b(f32(b2f(b)) / f32(b2f(a)))
        emit('DNDIVR', 0x5c, 0x1b, a, b, 0, rng.randrange(16), r, arith_flags(r))
    for _ in range(4000):
        b = rnd_f(-20, 30)                                    # cancellation to a denormal
        a = (b ^ 0x80000000) + rng.randrange(-4096, 4097)
        a &= 0xffffffff
        if (a & 0x7f800000) == 0x7f800000:
            continue
        r = f2b(f32(b2f(b)) + f32(b2f(a)))
        emit('DNADDR', 0x5c, 0x18, a, b, 0, rng.randrange(16), r, arith_flags(r))
        r = f2b(f32(b2f(b)) - f32(b2f(a ^ 0x80000000)))
        emit('DNSUBR', 0x5c, 0x19, a ^ 0x80000000, b, 0, rng.randrange(16), r, arith_flags(r))

    # ---- NEGF / ABSF on every value (MAME: CY = r < 0, Z = r == 0.0)
    for a in vals:
        r = -f32(b2f(a))
        rb = f2b(r)
        emit('DNNEG', 0x5c, 0x09, a, 0, 0, rng.randrange(16), rb, fl(r == 0, rb & 0x80000000, 0, r < 0))
        x = f32(b2f(a))
        r = -x if x < 0 else x
        rb = f2b(r)
        emit('DNABS', 0x5c, 0x0a, a, 0, 0, rng.randrange(16), rb, fl(r == 0, rb & 0x80000000, 0, 0))

    # ---- SCLF: scale every value by 2^n, n in [-30, 30] (MAME divides or
    # multiplies by the float of 1 << |n|; |n| = 31 is C undefined behaviour)
    for b in vals:
        for n in range(-30, 31):
            x = f32(b2f(b))
            r = x / f32(1 << -n) if n < 0 else x * f32(1 << n)
            rb = f2b(r)
            emit('DNSCL', 0x5c, 0x10, n & 0xffff, b, 0, rng.randrange(16), rb, arith_flags(rb))

    # ---- CVTSW of denormals and small values, all four rounding modes. CY is
    # not written (o_fmask), so the expected CY is the one before.
    small = denorms + [0x00800000, 0x33800000, 0x3e800000, 0x3f000000, 0x3f000001,
                       0x3f7fffff, 0x3f800000, 0x3fc00000, 0x40200000, 0x00000000]
    small = small + [v | 0x80000000 for v in small]
    for a in small:
        v = float(b2f(a))
        for cw in range(4):
            if cw == 0:
                r = math.copysign(math.floor(abs(v) + 0.5), v)   # roundf: half away
            elif cw == 1:
                r = math.floor(v)
            elif cw == 2:
                r = math.ceil(v)
            else:
                r = math.trunc(v)
            res = int(r) & 0xffffffff
            s = (res >> 31) & 1
            ov = (s and r >= 0) or ((not s) and r <= -1)
            pswb = rng.randrange(16)
            emit('DNCVSW', 0x5f, 0x01, a, a, cw, pswb, res, fl(res == 0, s, ov, pswb & 8))

sys.stdout.write('\n'.join(out) + '\n')
sys.stderr.write('v60_fp_denorm_vectors: %d vectors\n' % len(out))
