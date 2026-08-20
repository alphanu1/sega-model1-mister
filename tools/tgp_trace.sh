#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Diff our TGP's instruction stream against MAME's, from reset, on REAL microcode.
#
# WHY THIS EXISTS
#
# M0 exit criterion 2 asks for microcode-driven lockstep and has never been met.
# What exists is sim/tgp/mb86233_ref.cpp, a whole-CPU reference in lockstep with the
# core over 8,000 retires of GENERATED instructions. That proves each instruction
# correct for the state it was handed; it cannot show that the machine reaches the
# right state running the decapped microcode. It does not:
#
#   the reference's TGP makes three io accesses in its first 30 frames —
#     W io 002e <- 00000010,  R io 8010 -> 00000030,  R io 8020 -> 00012e00
#   ours opens with FIVE reads of io 0000 that the reference never makes, then
#     reads 8000 where it reads 8010.
#
# Same shape as the V60 gap, and the same tool closes it. :tgp_copro traces exactly
# like maincpu, and tools/v60_collapse.py is agnostic about which CPU produced the
# stream.
#
#   make tgp_trace
#   make tgp_trace SECONDS_RUN=5 BOOT_CYCLES=200000000
#
# THE noloop FLAG IS NOT OPTIONAL — see tools/v60_trace.sh for what it cost to
# learn that. And the collapse is not optional either: microcode is full of tight
# wait loops on the input FIFO, which alternate addresses and so survive a
# consecutive-repeat filter untouched.
set -euo pipefail

# Temporaries in THIS project's build/, never /tmp: /tmp here is a quota'd tmpfs
# that reports free space and then refuses writes with EDQUOT, which stops a
# build mid-compile and kills the shell. The Makefile exports this too; these
# scripts are also run directly.
export TMPDIR="${TMPDIR:-$(cd "$(dirname "$0")/.." && pwd)/build/tmp}"
mkdir -p "$TMPDIR"

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${OUT:-$root/build/tgptrace}"
seconds="${SECONDS_RUN:-3}"
cycles="${BOOT_CYCLES:-40000000}"
game="${GAME:-vr}"
rompath="${ROMPATH:-$HOME/roms}"

command -v mame >/dev/null || { echo "mame not found in PATH"; exit 1; }
mkdir -p "$out"

echo "=== MAME reference TGP trace (${seconds}s, noloop, COLD nvram) ==="
cd "$out"
rm -rf "$out/nvram"
printf 'trace %s/tgp.tr,tgp_copro,noloop\ngo\n' "$out" > "$out/dbg.txt"
mame "$game" -rompath "$rompath" -skip_gameinfo -autoboot_delay 0 \
     -video none -sound none -nothrottle -debug -debugscript "$out/dbg.txt" \
     -seconds_to_run "$seconds" >/dev/null 2>&1 || true
[ -s "$out/tgp.tr" ] || { echo "MAME produced no TGP trace"; exit 1; }
collapsed=$(grep -c "loops for" "$out/tgp.tr" || true)
if [ "$collapsed" != "0" ]; then
    echo "WARNING: $collapsed collapsed loops in the trace — noloop did not take."
fi

# The TGP disassembler prints a 4-digit PC: "0010: set #0x0800".
awk -F: '/^[0-9A-F]{4}:/{print tolower($1)}' "$out/tgp.tr" > "$out/mame_raw.txt"
python3 "$root/tools/v60_collapse.py" "$out/mame_raw.txt" "$out/mame_pc.txt" \
  --counts "$out/mame_loops.txt"
echo "  $(wc -l < "$out/mame_pc.txt") instructions"

echo "=== our core (${cycles} cycles) ==="
cd "$root"
make m1_boot BOOT_CYCLES="$cycles" TGPTRACE=1 > "$out/ours.log" 2>&1 || true
grep '^TGPPC ' "$out/ours.log" | awk '{print tolower($2)}' > "$out/our_raw.txt"
[ -s "$out/our_raw.txt" ] || { echo "our core emitted no TGP retires — is the TGP running?"; exit 1; }
python3 "$root/tools/v60_collapse.py" "$out/our_raw.txt" "$out/our_pc.txt" \
  --counts "$out/our_loops.txt"
echo "  $(wc -l < "$out/our_pc.txt") instructions"

# WHAT THE COLLAPSE HID, STATED OUT LOUD — same contract as v60_trace.
python3 - "$out/mame_loops.txt" "$out/our_loops.txt" <<'PYEOF'
import sys
def load(p):
    d = {}
    for line in open(p):
        pos, n, period = line.split(None, 2)
        d[(int(pos), period.strip())] = int(n)
    return d
m, o = load(sys.argv[1]), load(sys.argv[2])
diffs = sorted(((abs(m[k]-o[k]), k, m[k], o[k]) for k in set(m) & set(o) if m[k] != o[k]),
               reverse=True)
print("--- loops collapsed on both sides: %d in common, %d with differing counts"
      % (len(set(m) & set(o)), len(diffs)))
for d, (pos, period), mv, ov in diffs[:8]:
    pct = 100.0*(ov-mv)/mv if mv else 0.0
    print("    at %-8d %-24s MAME %-8d ours %-8d (%+.1f%%)" % (pos, period, mv, ov, pct))
if not diffs:
    print("    every collapsed loop ran the same number of times on both sides")
PYEOF

n=$(wc -l < "$out/our_pc.txt")
head -"$n" "$out/mame_pc.txt" > "$out/mame_cut.txt"
if cmp -s "$out/mame_cut.txt" "$out/our_pc.txt"; then
    echo "tgp_trace: IDENTICAL for $n instructions"
    exit 0
fi
line=$( { cmp "$out/mame_cut.txt" "$out/our_pc.txt" || true; } 2>/dev/null \
        | sed 's/.*line //' | tr -dc '0-9')
[ -n "$line" ] || line=1
echo "tgp_trace: DIVERGES at instruction $line"
echo "--- MAME, collapsed, around the divergence (with disassembly):"
lo=$((line>6?line-6:1)); hi=$((line+6))
sed -n "${lo},${hi}p" "$out/mame_pc.txt" | while read -r pc; do
    up=$(printf '%s' "$pc" | tr 'a-f' 'A-F')
    dis=$(grep -m1 "^${up}:" "$out/tgp.tr" || true)
    echo "    ${dis:-$pc}"
done
echo "--- ours:"
sed -n "${lo},${hi}p" "$out/our_pc.txt" | tr '\n' ' '; echo
exit 1
