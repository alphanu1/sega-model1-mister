#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# WHICH V60 INSTRUCTIONS DO OUR GAMES ACTUALLY EXECUTE?
#
# The V60 is the largest block on the die and ALM is the binding constraint, so
# instructions no game uses are the obvious thing to stub. This measures which
# those are, rather than guessing - MAME's tracer prints a disassembly beside
# every retired instruction, so a census is a sort and a uniq.
#
# READ THIS BEFORE ACTING ON THE OUTPUT.
#
# "Not seen in this window" is NOT "never executed". That mistake has already
# been made here and is on record: the V60's FP group was measured unused
# through boot and attract, `dbg_fp_trap` had never fired, and removing it was
# worth 2,984 ALM and 21 MHz. Run to 421.7 M cycles it DID fire, on a real
# `cvt.sw` in an angle-to-sine lookup. The lever was spent and the census was
# the thing that misled.
#
# So the output here is a list of CANDIDATES. Anything stubbed on the strength
# of it must trap and report when executed - see dbg_fp_trap for the pattern -
# never fail silently, and the comment on the stub must say what the
# instruction did so it can be put back.
#
# Usage:  tools/v60_opcensus.sh [seconds]        # censuses vr and vf
#         GAMES="vf" tools/v60_opcensus.sh 20
#
# netmerc is worth including: Ben reports it boots and runs like vf but with 3D
# faults of its own, and it is a different code base, so it reaches instructions
# the two Sega racers never touch.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
seconds="${1:-10}"
games="${GAMES:-vr vf netmerc}"
out="$root/build/opcensus"
rompath="${ROMPATH:-$HOME/roms;$root/build/roms}"
export TMPDIR="$root/build/tmp"
mkdir -p "$out" "$TMPDIR"

command -v mame >/dev/null || { echo "mame not found in PATH"; exit 1; }

for g in $games; do
    echo "=== $g: ${seconds}s ===" >&2
    rm -rf "$out/nvram" "$out/$g.tr"
    printf 'trace %s/%s.tr,maincpu,noloop\ngo\n' "$out" "$g" > "$out/dbg.txt"
    ( cd "$out" && mame "$g" -rompath "$rompath" -skip_gameinfo -autoboot_delay 0 \
        -video none -sound none -nothrottle -debug -debugscript "$out/dbg.txt" \
        -seconds_to_run "$seconds" >/dev/null 2>&1 )
    if [ ! -s "$out/$g.tr" ]; then
        echo "  MAME produced no trace for $g - a missing device ROM set exits" >&2
        echo "  before the debugscript loads. Skipping." >&2
        continue
    fi
    # "FE033C: rsr" -> "rsr". The mnemonic is the token after the address.
    # MAME's disassembler does not always put a space between a long mnemonic
    # and its first operand, so a raw token can come out as "movcfu.b502500".
    # Cut at the width suffix when a digit follows it, or the same instruction
    # is counted under a dozen different names.
    grep -oE "^[0-9A-F]{6}: [a-z0-9._]+" "$out/$g.tr" \
      | awk '{print $2}' \
      | sed -E 's/^([a-z0-9]+\.[bhwsd])[0-9].*$/\1/' \
      | sort | uniq -c | sort -rn > "$out/$g.ops"
    echo "  $(wc -l < "$out/$g.ops") distinct mnemonics, $(du -h "$out/$g.tr" | cut -f1) trace" >&2
    # The trace is large and derived from a ROM: it does not survive the run.
    rm -f "$out/$g.tr"
done

# The union across games is what the core must keep.
cat "$out"/*.ops 2>/dev/null | awk '{print $2}' | sort -u > "$out/used.txt"
echo
echo "USED by at least one game ($(wc -l < "$out/used.txt")):"
tr '\n' ' ' < "$out/used.txt"; echo
