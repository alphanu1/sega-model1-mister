#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Diff the coprocessor's COMMAND and ANSWER streams against the reference's.
#
# Two streams, compared independently, because they answer different questions:
#
#   commands  what the V60 pushes into the inbound FIFO. A divergence here is
#             the V60's doing - either its instruction stream or its data.
#   answers   what the coprocessor pushes into the outbound FIFO. A divergence
#             here with IDENTICAL commands up to that point is the coprocessor's
#             doing, and it names the handler by the microcode pc logged with it.
#
# Whichever diverges FIRST, in command-count terms, is the cause; the other is
# downstream of it. An extra or missing ANSWER with matching commands is how the
# outbound FIFO fills early, which is the shape of the deadlock.
#
#   ours:  build/frame_streams.txt      CMD xxxxxxxx / ANS xxxxxxxx pc=xxxx
#   MAME:  build/dasm/mame_push2.txt     "  n program val=xxxxxxxx"
#          build/dasm/mame_answers.txt   "ANS xxxxxxxx  bit31=n"
import sys

def load_ours(path):
    cmds, ans = [], []
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == "CMD":
            cmds.append(p[1])
        elif p[0] == "ANS":
            ans.append((p[1], p[2] if len(p) > 2 else ""))
    return cmds, ans

def load_mame_cmds(path):
    out = []
    for line in open(path):
        if "val=" in line:
            out.append(line.split("val=")[1].strip())
    return out

def load_mame_ans(path):
    return [line.split()[1] for line in open(path) if line.startswith("ANS")]

def first_diff(a, b):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return None

def show(label, a, b, i, width=6):
    lo = max(0, i - width)
    print("  %-5s %s" % ("MAME", " ".join(b[lo:i + 4])))
    print("  %-5s %s" % ("ours", " ".join(a[lo:i + 4])))

def main():
    ours_c, ours_a = load_ours("build/frame_streams.txt")
    mame_c = load_mame_cmds("build/dasm/mame_push2.txt")
    mame_a = load_mame_ans("build/dasm/mame_answers.txt")
    oa = [v for v, _ in ours_a]

    print("commands  ours=%d  MAME=%d" % (len(ours_c), len(mame_c)))
    print("answers   ours=%d  MAME=%d" % (len(oa), len(mame_a)))

    dc = first_diff(ours_c, mame_c)
    da = first_diff(oa, mame_a)

    print("\ncommands: first divergence at %s"
          % ("NONE over %d" % min(len(ours_c), len(mame_c)) if dc is None else dc))
    if dc is not None:
        show("cmd", ours_c, mame_c, dc)

    print("\nanswers: first divergence at %s"
          % ("NONE over %d" % min(len(oa), len(mame_a)) if da is None else da))
    if da is not None:
        show("ans", oa, mame_a, da)
        print("  our answer %d was pushed by microcode pc=%s" % (da, ours_a[da][1]))

    # Which came first? Answers are produced in response to commands, so relate
    # the answer index back to how many commands had been pushed by then.
    if da is not None:
        n_cmd_at = 0
        seen_a = 0
        for line in open("build/frame_streams.txt"):
            p = line.split()
            if not p:
                continue
            if p[0] == "CMD":
                n_cmd_at += 1
            elif p[0] == "ANS":
                if seen_a == da:
                    break
                seen_a += 1
        print("  at that point %d commands had been pushed; commands %s"
              % (n_cmd_at,
                 "were still identical" if dc is None or dc >= n_cmd_at
                 else "had ALREADY diverged at %d" % dc))

    # Answers-per-command is the deadlock's arming condition.
    if len(ours_c) and len(mame_c):
        print("\nanswers per command   ours=%.3f  MAME(first %d cmds)=%.3f"
              % (len(oa) / len(ours_c), min(len(mame_c), 4000),
                 len(mame_a) / max(1, min(len(mame_c), 4000))))

if __name__ == "__main__":
    sys.exit(main())
