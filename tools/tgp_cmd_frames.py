#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Frame a coprocessor command stream into COMMANDS.
#
# tb_tgp_replay's CMDLOG lists every word the TGP pops with the frame and the
# core's pc. The dispatcher's pop is the command (pc 02a on Virtua Fighter's
# microcode - the instruction before the computed jump; the retire pc lags the
# pop by one); every other pop up to the next one is an argument. So this
# turns a pop log into one line per command:
#
#   <frame> <command> <arg> <arg> ...
#
# and with --sig prints, per frame, just the sequence of command words, which
# is what lines two runs up when their timing differs: the same game state
# issues the same commands whatever frame it happens on.
#
#   tools/tgp_cmd_frames.py build/cmd_vf_mame.txt [--pc 02a] [--sig] [--cmd 2f000000]
import argparse

ap = argparse.ArgumentParser()
ap.add_argument("log")
ap.add_argument("--pc", default="02a")
ap.add_argument("--sig", action="store_true", help="per-frame command signature")
ap.add_argument("--cmd", default=None, help="only commands with this word")
ap.add_argument("--from-frame", type=int, default=0)
ap.add_argument("--to-frame", type=int, default=1 << 30)
a = ap.parse_args()

cur = None
frames = {}
def flush():
    if cur is None:
        return
    f, c, args = cur
    if not (a.from_frame <= f <= a.to_frame):
        return
    if c == "00000000":
        return
    if a.sig:
        frames.setdefault(f, []).append(c[:4])
    elif a.cmd is None or c == a.cmd:
        print(f, c, " ".join(args))

for line in open(a.log):
    p = line.split()
    if len(p) < 3:
        continue
    f, pc, w = int(p[0]), p[1], p[2]
    if pc == a.pc:
        flush()
        cur = (f, w, [])
    elif cur is not None:
        cur[2].append(w)
flush()
if a.sig:
    for f in sorted(frames):
        print(f, " ".join(frames[f]))
