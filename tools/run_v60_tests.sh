#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sega Model 1 core for MiSTer FPGA
# Copyright (C) 2026 alphanu1
#
# Runs s32's V60 unit suite against OUR copy of the core in rtl/cpu/v60/.
#
# WHY THIS EXISTS SEPARATELY FROM s32's OWN RUNNER
#
# s32's runner builds third_party/s32/rtl/cpu/v60/s32_v60.sv. That is not the
# file this project ships: our copy carries the explicit-width casts that let
# Icarus elaborate it, and it is the one that will diverge further as the V60
# is worked on. Running their runner would test their file and tell us nothing
# about ours — the failure mode being that it passes right up until the moment
# it matters.
#
# The testbenches themselves are reused unchanged from third_party/s32/verif/,
# which is gitignored and populated by tools/bootstrap.sh.
#
# BUILD ARTEFACTS DO NOT GO IN /tmp
#
# The first version of this script built into /tmp, which on this machine is a
# 16 GB tmpfs — RAM, not disk. Twenty-eight Verilator --binary builds of a
# 4,500-line CPU filled it, every build after that died with "Disk quota
# exceeded" while looking exactly like a compile error, and with the tmpfs
# still full the machine could no longer fork at all. Builds now go under the
# repo, and each test's tree is deleted as soon as it has run rather than all
# twenty-eight being kept alive at once.
#
# Usage: bash tools/run_v60_tests.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
S32="$ROOT/third_party/s32"
VERIF="$S32/verif/v60"

[ -d "$VERIF" ] || { echo "third_party/s32/verif/v60 missing - run tools/bootstrap.sh"; exit 1; }

CPU="$ROOT/rtl/cpu/v60/v60_bus.sv $ROOT/rtl/cpu/v60/v60.sv $ROOT/rtl/cpu/v60/v60_fp.sv rtl/cpu/v60/v60_ifetch.sv $ROOT/rtl/cpu/v60/v60_alu.sv $ROOT/rtl/cpu/v60/v60_shift.sv"
# -j is capped rather than 0 (unlimited). Verilator fans out one g++ per
# translation unit; across a CPU this size that was 32 concurrent compilers,
# which is how a few hundred MB of build became several GB in flight.
VJOBS="${VJOBS:-8}"
VFLAGS="--binary --timing -j $VJOBS -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH +define+SIMULATION ${VDEFS:-}"

declare -A TB=(
  [tb_v60_smoke]="SMOKE PASS"                 [tb_v60_directed]="DIRECTED PASS"
  [tb_v60_fetch]="FETCH PERF PASS"            [tb_v60_smc]="V60 SMC PASS"
  [tb_v60_long_ea]="LONG EA PASS"             [tb_v60_fetch_wide]="V60 FETCH WIDE PASS"
  [tb_v60_bus_lanes]="V60 BUS LANES PASS"     [tb_v60_divx]="DIVX PASS"
  [tb_v60_divxmem]="V60 DIVXMEM PASS"         [tb_v60_flags]="V60 FLAGS PASS"
  [tb_v60_ga2_bossbar]="V60 GA2 BOSSBAR PASS" [tb_v60_incdecmem]="V60 INCDECMEM PASS"
  [tb_v60_rotate]="V60 ROTATE PASS"           [tb_v60_shaov]="V60 SHAOV PASS"
  [tb_v60_xch]="V60 XCH PASS"                 [tb_v60_audit]="AUDIT PASS"
  [tb_v60_bits]="BITS PASS"                   [tb_v60_decimal]="DECIMAL PASS"
  [tb_v60_search]="V60 SEARCH PASS"           [tb_v60_cmpc]="V60 CMPC PASS"
  [tb_v60_movcd]="V60 MOVCD PASS"             [tb_v60_schd]="V60 SCHD PASS"
  [tb_v60_strfs]="V60 STRFS PASS"             [tb_v60_fp]="V60 FP PASS"
  [tb_v60_fpdecode]="V60 FPDECODE PASS"       [tb_v60_spidman_xchh]="SPIDMAN XCH.H PASS"
  [tb_v60_spidman_window]="SPIDMAN WINDOW PASS"
  [tb_v60_spidman_gate]="SPIDMAN GATE PASS"
)

# Verilator cannot elaborate testbenches that poke the internal enum FSM state
# (EnumItemRef will not deref back to an Enum), so those go through Icarus.
ICARUS_ONLY="tb_v60_search tb_v60_cmpc tb_v60_movcd tb_v60_schd tb_v60_strfs tb_v60_fp"

ORDER="tb_v60_smoke tb_v60_directed tb_v60_fetch tb_v60_smc tb_v60_long_ea \
tb_v60_fetch_wide tb_v60_bus_lanes tb_v60_divx tb_v60_divxmem tb_v60_flags \
tb_v60_ga2_bossbar tb_v60_incdecmem tb_v60_rotate tb_v60_shaov tb_v60_xch \
tb_v60_audit tb_v60_bits tb_v60_decimal tb_v60_search tb_v60_cmpc \
tb_v60_movcd tb_v60_schd tb_v60_strfs tb_v60_fp tb_v60_fpdecode \
tb_v60_spidman_xchh tb_v60_spidman_window tb_v60_spidman_gate"

is_icarus() { case " $ICARUS_ONLY " in *" $1 "*) return 0;; *) return 1;; esac; }

OUT="$ROOT/build/v60ut"
mkdir -p "$OUT"
pass=0; fail=0; skip=0; failed=""
for tb in $ORDER; do
  src="$VERIF/${tb}.sv"
  [ -f "$src" ] || { echo "SKIP  $tb (no file)"; skip=$((skip+1)); continue; }
  bdir="$OUT/$tb"; rm -rf "$bdir"; mkdir -p "$bdir"

  # THE FETCH WINDOW MOVED INTO A SUBMODULE, AND TWO TESTS POKE IT DIRECTLY.
  #
  # tb_v60_movcd and tb_v60_strfs inject an instruction byte with
  # `cpu.fb[3] = ...`, which was a register in v60.sv and is now a wire fed from
  # v60_ifetch. That is a hierarchy change, not a behaviour change, and the fix
  # belongs to the test.
  #
  # Rewritten on the way in rather than edited in place: third_party/ is not in
  # the repository - tools/bootstrap.sh populates it - so an edit there would be
  # silently undone on the next clean checkout, which is exactly the kind of
  # change that comes back as a mystery failure months later.
  # Both the fetch window and the register file are submodules now, and the
  # tests reach into them: `cpu.fb[3] = ...` to inject an instruction byte, and
  # `cpu.r[31]` to set up and check the stack pointer.
  if grep -q 'cpu\.fb\[' "$src"; then
      sed -e 's/cpu\.fb\[/cpu.u_ifetch.fb[/g' "$src" > "$bdir/${tb}.sv"
      src="$bdir/${tb}.sv"
  fi
  if is_icarus "$tb"; then
    if ! iverilog -g2012 -Wno-timescale ${IDEFS:-} -o "$bdir/$tb.vvp" -s "$tb" $CPU "$src" > "$bdir.log" 2>&1; then
      echo "BUILDFAIL $tb (icarus)  (see $bdir.log)"; fail=$((fail+1)); failed="$failed $tb"; continue
    fi
    out="$(cd "$bdir" && timeout 300 vvp "$tb.vvp" 2>&1)"
  else
    if ! verilator $VFLAGS --top-module "$tb" --Mdir "$bdir" -o "$tb" $CPU "$src" > "$bdir.log" 2>&1; then
      echo "BUILDFAIL $tb  (see $bdir.log)"; fail=$((fail+1)); failed="$failed $tb"; continue
    fi
    out="$(timeout 300 "$bdir/$tb" 2>&1)"
  fi
  if echo "$out" | grep -qF "${TB[$tb]}"; then
    extra="$(echo "$out" | grep -E 'FETCH PERF:|LANES|cycles=' | head -1)"
    printf 'PASS  %-26s %s\n' "$tb" "$extra"
    pass=$((pass+1))
  else
    echo "FAIL  $tb   (expected '${TB[$tb]}')"
    echo "$out" | tail -3 | sed 's/^/        /'
    fail=$((fail+1)); failed="$failed $tb"
  fi
  # Reclaim immediately. Keeping every tree alive is what filled the disk, and
  # a failed build's log is preserved separately so nothing needed is lost.
  [ "$tb" = tb_v60_smc ] || rm -rf "$bdir"
done

# Production cadence re-run: the core runs on a /3 clock enable on the real
# board, and prefetch ack-sampling bugs hide completely at ce=1. This is why
# tb_v60_smc's build tree is the one kept above.
if [ -x "$OUT/tb_v60_smc/tb_v60_smc" ]; then
  if "$OUT/tb_v60_smc/tb_v60_smc" +CEDIV=3 2>&1 | grep -qF "V60 SMC PASS"; then
    echo "PASS  tb_v60_smc(ce=/3)"; pass=$((pass+1))
  else
    echo "FAIL  tb_v60_smc(ce=/3)"; fail=$((fail+1)); failed="$failed tb_v60_smc(ce/3)"
  fi
fi

echo "======================================================"
echo "V60 UNIT (our rtl/cpu/v60): $pass passed, $fail failed, $skip skipped${failed:+ -> FAILED:$failed}"
[ "$fail" -eq 0 ]

rm -rf "$OUT/tb_v60_smc"
