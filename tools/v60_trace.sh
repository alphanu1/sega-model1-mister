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
#   make v60_trace SECONDS_RUN=14 CYCLES=1120000000   # 14s both sides
#
# THE noloop FLAG IS NOT OPTIONAL. Without it MAME's tracer collapses loops and
# prints "(loops for 620 instructions)" instead of the instructions. Diffing
# against that reports phantom extras and reads as a CPU bug — it did exactly that
# here, and the false finding survived until the trace file was read by eye.
set -euo pipefail

# Temporaries in THIS project's build/, never /tmp: /tmp here is a quota'd tmpfs
# that reports free space and then refuses writes with EDQUOT, which stops a
# build mid-compile and kills the shell. The Makefile exports this too; these
# scripts are also run directly.
export TMPDIR="${TMPDIR:-$(cd "$(dirname "$0")/.." && pwd)/build/tmp}"
mkdir -p "$TMPDIR"

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${OUT:-$root/build/v60trace}"
seconds="${SECONDS_RUN:-2}"
cycles="${CYCLES:-80000000}"

# THE TWO WINDOWS HAVE TO MATCH, AND A WRONG VARIABLE NAME IS SILENT.
#
# The reference side takes SECONDS_RUN and our side takes CYCLES, which is our
# 80 MHz domain - so N seconds is N * 80,000,000. Passing BOOT_CYCLES (the name
# the boot and TGP benches use) is ignored here, and the run then compares 14
# emulated seconds of reference against 1 second of ours while reporting a clean
# "DIVERGES at ..." that is really just where the shorter trace stopped. That
# happened on 2026-08-30 and cost a 25-minute run.
if [ -n "${BOOT_CYCLES:-}" ] && [ -z "${CYCLES:-}" ]; then
    echo "v60_trace: BOOT_CYCLES is set and CYCLES is not - this script takes CYCLES." >&2
    echo "           Using BOOT_CYCLES=$BOOT_CYCLES so the window is not silently the default." >&2
    cycles="$BOOT_CYCLES"
fi
want=$(( seconds * 80000000 ))
if [ "$cycles" -lt $(( want / 2 )) ]; then
    echo "v60_trace: WARNING - CYCLES=$cycles is far short of ${seconds}s (${want} at 80 MHz)." >&2
    echo "           The diff will end where OUR trace stops, not at a real divergence." >&2
fi
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
# and reads exactly like a broken dbr; that false finding was made here.
#
# COLLAPSING CONSECUTIVE REPEATS IS NOT ENOUGH. A poll loop alternates two
# addresses — `test.b C00040` / `bne` — so no two consecutive lines are equal and
# the run survives intact. That cost a second false finding: the I/O board
# handshake spins 36,308 times in the reference and 41,147 times here, because our
# loop takes 18 CPU cycles an iteration against its 17 on a deadline that is
# correct in CYCLES to within 38. tools/v60_collapse.py finds the shortest
# repeating period instead, keeps one instance, and WRITES THE ITERATION COUNTS
# OUT so a real difference is reported rather than silently dropped.
awk -F: '/^[0-9A-F]{6}:/{print tolower($1)}' "$out/mame.tr" > "$out/mame_pc_raw.txt"
# THE INTERRUPT COMES OUT BEFORE THE LOOPS ARE COLLAPSED. It arrives on
# wall-clock time, so it lands at a different INSTRUCTION count on a machine with
# a different CPI, and the diff reports that as a divergence - which is what
# instruction 25,281 was. With it removed the same two traces agreed to the end
# of the shorter one. See tools/v60_strip_isr.py.
python3 "$root/tools/v60_strip_isr.py" "$out/mame_pc_raw.txt" "$out/mame_noisr.txt"
python3 "$root/tools/v60_collapse.py" "$out/mame_noisr.txt" "$out/mame_pc.txt" \
  --counts "$out/mame_loops.txt"
echo "  $(wc -l < "$out/mame_pc.txt") instructions"

echo "=== our core (${cycles} cycles) ==="
cd "$root"
make m1_frame FRAME_TRACE=0 FRAME_CYCLES="$cycles" V60_PCTRACE=1 \
     V60_PCTRACE_MAX="${PCTRACE_MAX:-40000000}" \
  > "$out/ours.log" 2>&1 || true
grep '^PCT ' "$out/ours.log" | awk '{print $2}' > "$out/our_pc_raw.txt"
# Align on the first ROM instruction; our trace starts at the reset vector.
first=$(head -1 "$out/mame_pc.txt")
awk -v f="$first" '$0==f{s=1} s' "$out/our_pc_raw.txt" > "$out/our_pc_aligned.txt"
python3 "$root/tools/v60_strip_isr.py" "$out/our_pc_aligned.txt" "$out/our_noisr.txt"
python3 "$root/tools/v60_collapse.py" "$out/our_noisr.txt" "$out/our_pc.txt" \
  --counts "$out/our_loops.txt"
echo "  $(wc -l < "$out/our_pc.txt") instructions (aligned on $first)"

# WHAT THE COLLAPSE HID, STATED OUT LOUD. A loop that ran a different number of
# times is real information; it is just not a divergence. Reporting it keeps the
# instrument honest about what it stopped comparing.
python3 - "$out/mame_loops.txt" "$out/our_loops.txt" <<'PYEOF'
import sys
def load(p):
    d = {}
    for line in open(p):
        pos, n, period = line.split(None, 2)
        d[(int(pos), period.strip())] = int(n)
    return d
m, o = load(sys.argv[1]), load(sys.argv[2])
diffs = []
for k in sorted(set(m) & set(o)):
    if m[k] != o[k]:
        diffs.append((abs(m[k] - o[k]), k, m[k], o[k]))
diffs.sort(reverse=True)
common = len(set(m) & set(o))
print("--- loops collapsed on both sides: %d in common, %d with differing counts"
      % (common, len(diffs)))
for d, (pos, period), mv, ov in diffs[:8]:
    pct = 100.0 * (ov - mv) / mv if mv else 0.0
    print("    at %-8d %-24s MAME %-8d ours %-8d (%+.1f%%)" % (pos, period, mv, ov, pct))
if not diffs:
    print("    every collapsed loop ran the same number of times on both sides")
PYEOF

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
# The line number is an index into the COLLAPSED stream, so the raw trace cannot
# be indexed by it. Show the collapsed PCs and look each one up in the raw trace
# for its disassembly instead — reporting the wrong instructions here is how two
# earlier false findings were made plausible.
echo "--- MAME, collapsed, around the divergence (with disassembly):"
lo=$((line>6?line-6:1)); hi=$((line+6))
sed -n "${lo},${hi}p" "$out/mame_pc.txt" | while read -r pc; do
    up=$(printf '%s' "$pc" | tr 'a-f' 'A-F')
    dis=$(grep -m1 "^${up}:" "$out/mame.tr" || true)
    echo "    ${dis:-$pc}"
done
echo "--- ours:"
sed -n "$((line>6?line-6:1)),$((line+6))p" "$out/our_pc.txt" | tr '\n' ' '; echo
exit 1
