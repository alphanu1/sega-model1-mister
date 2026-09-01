#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Run MAME on `vr` with the device-ROM overlay this tree needs.
#
# MAME 0.289 will not start `vr` here at all:
#
#     epr-14869.25 NOT FOUND (tried in model1io vr)
#     epr-15112.17 NOT FOUND (tried in m1comm vr)
#     Fatal error: Required files are missing, the machine cannot be run.
#
# Those are DEVICE rom sets - the I/O board's 68000 firmware and the comm
# board's - and they are not in vr.zip. It is a fatal error, not the warning
# screen `-skip_gameinfo` leaves behind, so there is no key to press.
#
#   epr-14869.25   found in ~/roms/Model2/daytona93/
#   epr-15112.17   NOT ON THIS MACHINE. The overlay supplies the other m1comm
#                  bios, epr-15624.17, under that name; MAME warns WRONG
#                  CHECKSUMS and runs. The comm board is not linked in a
#                  standalone run and the V60 only touches 0xb00000-0xb01002,
#                  so this does not reach any measurement here - but SAY SO
#                  when reporting a result from a run made this way.
#
# Usage:
#   tools/mame_run.sh <script>.lua              # run an instrument
#   tools/mame_run.sh --seconds 4 -- -debug ... # anything else, args passed on
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
roms="${ROMPATH:-$HOME/roms}"
overlay="$here/build/roms"
export TMPDIR="$here/build/tmp"
mkdir -p "$TMPDIR" "$here/build/mamerun"

# Build the overlay if it is not there. Nothing is copied into the user's rom
# tree and nothing lands outside build/, which is gitignored - hard rule 2.
mk() {  # mk <set> <filename> <source path>
  [ -f "$overlay/$1/$2" ] && return 0
  if [ -f "$3" ]; then
    mkdir -p "$overlay/$1"; cp "$3" "$overlay/$1/$2"
    echo "overlay: $1/$2 <- $3" >&2
  else
    echo "overlay: MISSING $1/$2 (looked in $3)" >&2
  fi
}
mk model1io epr-14869.25 "$roms/Model2/daytona93/epr-14869.25"
mk m1comm   epr-15112.17 "$roms/vr/vformula/epr-15624.17"

if [ "${1:-}" = "--overlay-only" ]; then exit 0; fi
script=""
if [ $# -gt 0 ] && [ "${1##*.}" = "lua" ]; then script="$1"; shift; fi

cd "$here/build/mamerun"    # MAME drops cfg/, nvram/ and snap/ where it starts
set +e
mame vr -rompath "$roms;$overlay" \
        -skip_gameinfo -autoboot_delay 0 -sound none -nothrottle \
        ${script:+-autoboot_script "$here/$script"} \
        "$@"
rc=$?
set -e
exit $rc
