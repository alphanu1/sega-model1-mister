#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# VALUE-LEVEL lockstep for the TGP: diff the data-memory WRITE streams.
#
# WHY THIS EXISTS, WHEN tgp_trace ALREADY DIFFS THE INSTRUCTION STREAM
#
# A PC diff only catches a wrong value once that value changes control flow. On
# 2026-08-19 tgp_trace stopped at `0731 brif ged`, where the reference falls through
# and we branch — but the error is upstream in the FP chain at 06EE-070C, and no
# amount of PC comparison can point at it. The values have to be compared.
#
# Per-instruction REGISTERS out of MAME did not work, three ways:
#   * install_read_tap on a CPU's PROGRAM space never fires — instruction fetches
#     use the direct path and bypass taps;
#   * `trace f.tr,cpu,noloop,{tracelog "x=%04X",x1}` writes the instruction lines and
#     NO action text, with a constant format as well as with registers;
#   * `bpset <addr>,1,{tracelog ...}` after `focus` never fired.
# Data-space WRITE taps DO work, and the microcode stores its results to data memory,
# so the write stream is the quantity that matters and the one both sides can emit.
#
#   make tgp_wrtrace
#   make tgp_wrtrace SECONDS_RUN=12 BOOT_CYCLES=2000000000
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${OUT:-$root/build/tgpwr}"
seconds="${SECONDS_RUN:-8}"
cycles="${BOOT_CYCLES:-1500000000}"
game="${GAME:-vr}"
rompath="${ROMPATH:-$HOME/roms}"

command -v mame >/dev/null || { echo "mame not found in PATH"; exit 1; }
mkdir -p "$out"

echo "=== reference TGP data writes (${seconds}s, COLD nvram) ==="
cd "$out"
rm -rf "$out/nvram"
mame "$game" -rompath "$rompath" -skip_gameinfo -autoboot_delay 0 \
     -sound none -nothrottle -video none -seconds_to_run "$seconds" \
     -autoboot_script "$root/tools/mame_tgp_wrtrace.lua" > "$out/mame_raw.txt" 2>&1 || true
grep '^TW ' "$out/mame_raw.txt" > "$out/mame_tw.txt" || true
[ -s "$out/mame_tw.txt" ] || { echo "MAME produced no write trace"; exit 1; }
echo "  $(wc -l < "$out/mame_tw.txt") writes"

echo "=== our TGP (${cycles} cycles) ==="
cd "$root"
make m1_boot BOOT_CYCLES="$cycles" TGPTRACE=1 > "$out/ours_raw.txt" 2>&1 || true
grep '^TW ' "$out/ours_raw.txt" > "$out/our_tw.txt" || true
[ -s "$out/our_tw.txt" ] || { echo "our core emitted no data writes"; exit 1; }
echo "  $(wc -l < "$out/our_tw.txt") writes"

n=$(wc -l < "$out/our_tw.txt")
head -"$n" "$out/mame_tw.txt" > "$out/mame_cut.txt"
if cmp -s "$out/mame_cut.txt" "$out/our_tw.txt"; then
    echo "tgp_wrtrace: IDENTICAL for $n writes"
    exit 0
fi
line=$( { cmp "$out/mame_cut.txt" "$out/our_tw.txt" || true; } 2>/dev/null \
        | sed 's/.*line //' | tr -dc '0-9')
[ -n "$line" ] || line=1
echo "tgp_wrtrace: DIVERGES at write $line"
lo=$((line>5?line-5:1)); hi=$((line+5))
echo "--- reference (addr value) ---"
sed -n "${lo},${hi}p" "$out/mame_tw.txt" | nl -ba -v"$lo"
echo "--- ours ---"
sed -n "${lo},${hi}p" "$out/our_tw.txt" | nl -ba -v"$lo"
exit 1
