#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
# Parse ALM / DSP / M10K / Fmax out of a completed spike build.
set -euo pipefail
M="${1:?usage: report.sh <module>}"
D="build/$M/output_files"

fit="$D/$M.fit.rpt"
sta="$D/$M.sta.rpt"

[ -f "$fit" ] || { echo "no fit report at $fit — run 'make quartus MOD=$M' first"; exit 1; }

echo "== $M"
grep -E "Logic utilization|ALMs needed|Total registers|Total DSP|Total block memory bits|Total RAM Blocks" "$fit" \
  | sed 's/^[ ;]*//; s/ *;*$//' | sort -u
if [ -f "$sta" ]; then
  echo -n "Fmax: "
  awk '/Slow 1100mV 85C Model Fmax Summary/{f=1;next} f&&/MHz/{print $2, $3; exit}' "$sta"
fi
