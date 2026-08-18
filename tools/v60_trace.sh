#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Diff our V60's instruction stream against MAME's, from reset.
#
# WHY THIS EXISTS
#
# The V60 came from the s32 project with a 29/29 unit suite and this core is the
# first thing to run Virtua Racing's code through it. Per-opcode fuzzing proves
# each instruction correct FOR THE STATE IT WAS HANDED; it cannot show that the
# machine reaches the right state when a real program runs. That gap is how a
# divergence survived to instruction 197,250 unnoticed.
#
# Two commands and a diff localise in one run what hours of hand-comparing memory
# access sequences did not.
#
#   make v60_trace                  # default 2 emulated seconds
#   make v60_trace SECONDS=5 CYCLES=200000000
#
# THE noloop FLAG IS NOT OPTIONAL. Without it MAME's tracer collapses loops and
# prints "(loops for 620 instructions)" instead of the instructions. Diffing
# against that reports phantom extras and reads as a CPU bug — it did exactly that
# here, and the false finding survived until the trace file was read by eye.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${OUT:-$root/build/v60trace}"
seconds="${SECONDS_RUN:-2}"
cycles="${CYCLES:-80000000}"
game="${GAME:-vr}"
rompath="${ROMPATH:-$HOME/roms}"

command -v mame >/dev/null || { echo "mame not found in PATH"; exit 1; }
mkdir -p "$out"

echo "=== MAME reference trace (${seconds}s, noloop, COLD nvram) ==="
cd "$out"

# COLD NVRAM, EVERY TIME. MAME saves nvram/ on exit and reloads it on the next
# run, so a directory that has been used before boots the game with WARM
# battery-backed RAM while our core always starts cold. That difference alone
# produced a "divergence at instruction 197,251" that was chased as a CPU bug:
# 0x40e8fe read 0x0000 in MAME and 0xffff here, and with the file deleted MAME
# reads 0xffff too — the same as us. The V60 was correct all along.
rm -rf "$out/nvram"
printf 'trace %s/mame.tr,maincpu,noloop\ngo\n' "$out" > "$out/dbg.txt"
mame "$game" -rompath "$rompath" -skip_gameinfo -autoboot_delay 0 \
     -video none -sound none -nothrottle -debug -debugscript "$out/dbg.txt" \
     -seconds_to_run "$seconds" >/dev/null 2>&1 || true
[ -s "$out/mame.tr" ] || { echo "MAME produced no trace"; exit 1; }
collapsed=$(grep -c "loops for" "$out/mame.tr" || true)
if [ "$collapsed" != "0" ]; then
    echo "WARNING: $collapsed collapsed loops in the trace — noloop did not take."
    echo "         Diffing against this reports phantom extra instructions."
fi
# COLLAPSE CONSECUTIVE REPEATS ON BOTH SIDES.
#
# Our trace logs the PC when it CHANGES, so a branch-to-self delay loop —
# `dbr R0, FFA6BD[PC]`, 5,000 iterations at one address — appears once. MAME logs
# every iteration. Comparing them raw reports a divergence at the first such loop
# and reads exactly like a broken dbr; that false finding was made here. Collapsing
# runs on both sides compares the same quantity. It costs the ability to see an
# iteration-count difference, which a register check catches instead.
awk -F: '/^[0-9A-F]{6}:/{print tolower($1)}' "$out/mame.tr" \
  | awk 'NR==1||$0!=p{print} {p=$0}' > "$out/mame_pc.txt"
echo "  $(wc -l < "$out/mame_pc.txt") instructions"

echo "=== our core (${cycles} cycles) ==="
cd "$root"
make m1_frame FRAME_TRACE=0 FRAME_CYCLES="$cycles" V60_PCTRACE=1 \
  > "$out/ours.log" 2>&1 || true
grep '^PCT ' "$out/ours.log" | awk '{print $2}' > "$out/our_pc_raw.txt"
# Align on the first ROM instruction; our trace starts at the reset vector.
first=$(head -1 "$out/mame_pc.txt")
awk -v f="$first" '$0==f{s=1} s' "$out/our_pc_raw.txt" \
  | awk 'NR==1||$0!=p{print} {p=$0}' > "$out/our_pc.txt"
echo "  $(wc -l < "$out/our_pc.txt") instructions (aligned on $first)"

n=$(wc -l < "$out/our_pc.txt")
head -"$n" "$out/mame_pc.txt" > "$out/mame_cut.txt"
if cmp -s "$out/mame_cut.txt" "$out/our_pc.txt"; then
    echo "v60_trace: IDENTICAL for $n instructions"
    exit 0
fi
# cmp exits 1 on difference and pipefail would kill the script here.
line=$( { cmp "$out/mame_cut.txt" "$out/our_pc.txt" || true; } 2>/dev/null | sed 's/.*line //' | tr -dc '0-9')
[ -n "$line" ] || line=1
echo "v60_trace: DIVERGES at instruction $line"
echo "--- MAME, with disassembly, around the divergence:"
grep -E "^[0-9A-F]{6}:" "$out/mame.tr" | sed -n "$((line>6?line-6:1)),$((line+6))p"
echo "--- ours:"
sed -n "$((line>6?line-6:1)),$((line+6))p" "$out/our_pc.txt" | tr '\n' ' '; echo
exit 1
