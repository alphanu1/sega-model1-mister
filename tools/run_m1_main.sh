#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sega Model 1 core for MiSTer FPGA
# Copyright (C) 2026 alphanu1
#
# Runs the main-board integration test in both fetch configurations.
#
# Both matter. FAST_IFETCH=1 is what the core ships with; FAST_IFETCH=0 routes
# instruction fetch back through the data bus, which is slower but exercises
# one path instead of two. Having both is what told a fetch-bridge fault from a
# CPU fault when this first came up: the same program passed through the data
# bus and failed through the wide port, which localised the bug immediately.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VF="--binary --timing -j 8 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH +define+SIMULATION"
SRC="rtl/cpu/v60/v60_bus.sv rtl/cpu/v60/v60.sv rtl/io/m1_decode.sv rtl/io/m1_glue.sv rtl/io/m1_rom_loader.sv rtl/mem/m1_sdram.sv sim/mem/sdram_model.sv rtl/m1_main.sv sim/top/tb_m1_main.sv"

fail=0
for F in 1 0; do
  d=build/m1main_$F
  rm -rf "$d"
  if ! verilator $VF -GFASTIF=$F --top-module tb_m1_main --Mdir "$d" -o m1main $SRC > "$d.log" 2>&1; then
    echo "BUILDFAIL FAST_IFETCH=$F (see $d.log)"; fail=1; continue
  fi
  out="$(timeout 300 "./$d/m1main" 2>&1)"
  line="$(echo "$out" | grep -E '^M1 MAIN:')"
  if echo "$out" | grep -qF "M1 MAIN PASS"; then
    printf 'PASS  FAST_IFETCH=%s  %s\n' "$F" "$line"
  else
    printf 'FAIL  FAST_IFETCH=%s  %s\n' "$F" "$line"
    echo "$out" | grep -E '  FAIL' | sed 's/^/        /'
    fail=1
  fi
  rm -rf "$d"
done
echo "======================================================"
[ $fail -eq 0 ] && echo "M1 MAIN INTEGRATION: both fetch paths pass" || echo "M1 MAIN INTEGRATION: FAILED"
exit $fail
