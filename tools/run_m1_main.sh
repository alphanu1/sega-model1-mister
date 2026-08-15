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

# Third configuration: no FP group. Whether Model 1 code executes V60
# floating point decides a ~2,000 ALM and near-doubled-Fmax build option, and a
# static ROM scan cannot settle it — it cannot tell code from data. The core
# raises dbg_fp_trap if it ever meets an FP opcode in that build, and the
# testbench fails on it, so running real code answers the question.
fail=0
run_one() {
  local name="$1" F="$2" extra="$3" inj="${4:-0}"
  local d="build/m1main_${name}"
  rm -rf "$d"
  if ! verilator $VF $extra -GFASTIF=$F -GINJFP=$inj --top-module tb_m1_main --Mdir "$d" -o m1main $SRC > "$d.log" 2>&1; then
    echo "BUILDFAIL $name (see $d.log)"; fail=1; return
  fi
  local out line
  out="$(timeout 300 "./$d/m1main" 2>&1)"
  line="$(echo "$out" | grep -E '^M1 MAIN:')"
  if echo "$out" | grep -qF "M1 MAIN PASS"; then
    printf 'PASS  %-16s %s\n' "$name" "$line"
  else
    printf 'FAIL  %-16s %s\n' "$name" "$line"
    echo "$out" | grep -E '  FAIL' | sed 's/^/        /'
    fail=1
  fi
  rm -rf "$d"
}

run_one "fast_ifetch"  1 ""
run_one "data_fetch"   0 ""
run_one "no_fp"        1 "+define+S32_V60_NO_FP"

# Proves the detector is not dead: the same build with an FP opcode planted in
# the program must raise it.
run_one "no_fp_injected" 1 "+define+S32_V60_NO_FP" 1
echo "======================================================"
[ $fail -eq 0 ] && echo "M1 MAIN INTEGRATION: all configurations pass" || echo "M1 MAIN INTEGRATION: FAILED"
exit $fail
