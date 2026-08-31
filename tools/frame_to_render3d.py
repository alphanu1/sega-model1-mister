#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Build a render3d input directory out of OUR OWN frame, so the two halves of a
# wrong picture can be told apart.
#
# render3d renders the reference's captured frame 900 correctly, from real
# polygon data, through the same RTL the board runs. So when the board draws the
# wrong picture the difference is either what our V60 WRITES into the display
# list and the palette, or the plumbing between them and the rasterizer.
#
# This takes tb_m1_frame's dumps and assembles a directory render3d can be
# pointed at, filling anything the frame bench does not dump from the reference
# set. Swap one file at a time and the two cases separate:
#
#   python3 tools/frame_to_render3d.py build/ourframe --dlist
#   ./obj_render3d/tb_render3d build/ourframe
#
# --dlist alone answers "is it the list?". Adding --palette answers "is it the
# colours?".
import argparse, os, shutil, struct, sys

REF = "build/framedump/framedump"

def read_hex(path, words):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(int(line, 16) & 0xffff)
    if len(out) < words:
        out += [0] * (words - len(out))
    return out[:words]

def write_bin(path, vals):
    with open(path, "wb") as f:
        f.write(struct.pack("<%dH" % len(vals), *vals))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--dlist", action="store_true",
                    help="use our display list (which buffer comes from --sel)")
    ap.add_argument("--sel", type=int, default=None,
                    help="0 or 1; default is whichever buffer has more non-zero words")
    ap.add_argument("--palette", action="store_true", help="use our palette")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    # Start from the reference set, so exactly the files asked for differ.
    for name in ("dlist.bin", "palette.bin", "xlat.bin", "tgpram.bin",
                 "lightparams.txt"):
        src = os.path.join(REF, name)
        if os.path.exists(src):
            shutil.copy(src, os.path.join(args.out, name))
        else:
            print("missing reference file %s" % src, file=sys.stderr)

    if args.dlist:
        b0 = read_hex("build/frame_dlist0.hex", 0x8000)
        b1 = read_hex("build/frame_dlist1.hex", 0x8000)
        n0 = sum(1 for v in b0 if v)
        n1 = sum(1 for v in b1 if v)
        sel = args.sel if args.sel is not None else (1 if n1 > n0 else 0)
        print("dlist0 %d non-zero words, dlist1 %d -> using buffer %d" % (n0, n1, sel))
        write_bin(os.path.join(args.out, "dlist.bin"), b1 if sel else b0)

    if args.palette:
        pal = read_hex("build/frame_pal.hex", 0x2000)
        print("palette: %d non-zero of 8192" % sum(1 for v in pal if v))
        write_bin(os.path.join(args.out, "palette.bin"), pal)

    print("wrote %s" % args.out)

if __name__ == "__main__":
    sys.exit(main())
