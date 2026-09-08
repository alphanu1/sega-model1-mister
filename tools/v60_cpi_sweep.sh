#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sega Model 1 core for MiSTer FPGA
# Copyright (C) 2026 alphanu1
#
# Sweeps V60 cycles-per-instruction against memory latency, with and without
# the wide instruction-fetch port, at the production /3 clock enable.
#
# The question this answers is whether the V60 can tolerate SDRAM latency.
# m1_sdram measures a worst case of 86 cycles under load from five masters,
# and neither of s32's fetch tests can say anything about that: one runs at
# ce=1 with fetch through the data adapter (no latency to hide), the other
# serves the wide port with zero latency (assumes the problem away).
#
# Builds are deleted as they go — see the note in tools/run_v60_tests.sh about
# what twenty-eight live Verilator trees did to this machine.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
VF="--binary --timing -j 8 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH +define+SIMULATION"
# CEDIV WAS HARDCODED TO 3 AND THAT IS NOT WHAT WE SHIP.
#
# Model1.sv passes `.ce_cpu(1'b1)` — the V60 gets EVERY cycle of clk_cpu at
# 19.2 MHz, with no throttle. This sweep hardcoded -GCEDIV=3, so every number it
# ever produced described a core getting one cycle in three: CPI inflated by up to
# 3x, and the contribution of memory latency correspondingly understated. The
# header's "at the production /3 clock enable" was true of an earlier design and
# was never revisited.
#
# Default is 1 now. Override to compare: CEDIV=3 bash tools/v60_cpi_sweep.sh
CEDIV="${CEDIV:-1}"
echo "=== V60 CPI sweep, CEDIV=$CEDIV (1 = what Model1.sv ships) ==="
for FAST in 0 1; do
  for LAT in 0 4 8 16 32 64; do
    d=build/cpi/f${FAST}_l${LAT}
    rm -rf $d
    printf 'FAST=%s LAT=%-3s ' "$FAST" "$LAT"
    verilator $VF -GFAST=$FAST -GCEDIV=$CEDIV -GLAT=$LAT --top-module tb_v60_cpi \
      --Mdir $d -o run rtl/cpu/v60/v60_bus.sv rtl/cpu/v60/v60.sv rtl/cpu/v60/v60_fp.sv rtl/cpu/v60/v60_ifetch.sv rtl/cpu/v60/v60_alu.sv rtl/cpu/v60/v60_shift.sv sim/cpu/tb_v60_cpi.sv \
      > $d.log 2>&1 && ./$d/run 2>&1 | grep -E '^V60 CPI:' 
    rm -rf $d
  done
done
