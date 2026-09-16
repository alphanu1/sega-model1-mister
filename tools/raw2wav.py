#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Wrap tb_m1_frame's raw audio dump as a WAV.

The bench writes signed 16-bit little-endian stereo frames, already decimated
to 44,100 Hz. This only adds the 44-byte header -- keeping the RTL side to a
plain $fwrite avoids building a WAV writer in SystemVerilog, where getting the
header length wrong produces a file that plays as noise and looks like an audio
fault rather than a tooling one.
"""
import struct, sys, os

src = sys.argv[1] if len(sys.argv) > 1 else "build/frame_snd.raw"
dst = sys.argv[2] if len(sys.argv) > 2 else "build/frame_snd.wav"
rate = 44100
data = open(src, "rb").read()
# Whole stereo frames only: a truncated tail would shift the channels.
data = data[: len(data) - (len(data) % 4)]
with open(dst, "wb") as f:
    f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
    f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * 4, 4, 16))
    f.write(b"data" + struct.pack("<I", len(data)))
    f.write(data)
secs = len(data) / 4 / rate
print(f"{dst}: {len(data)//4:,} stereo frames, {secs:.2f} s at {rate} Hz")
if len(data) == 0:
    print("  WARNING: empty -- the run produced no audio frames at all")
