#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
# Parse ALM / DSP / M10K / Fmax out of a completed spike build.
#
# Report format is Quartus-version-sensitive. Verified against 24.1std.
#
# The Fmax section name embeds the temperature corner, and the corner depends
# on the part's temperature grade — 5CSEBA6U23I7 is an industrial device, so
# its slow models are 100C and -40C, not the 85C a commercial part reports.
# Matching one fixed corner name silently produced an empty Fmax field. This
# now scans every slow-corner Fmax table and reports the worst, which is the
# number the resource gate actually wants.
set -euo pipefail
M="${1:?usage: report.sh <module>}"
D="build/$M/output_files"

fit="$D/$M.fit.rpt"
sta="$D/$M.sta.rpt"

[ -f "$fit" ] || { echo "no fit report at $fit — run 'make quartus MOD=$M' first"; exit 1; }

echo "== $M"

# The fit report repeats each metric across several tables with different
# spacing and different denominators, so a plain grep prints each one two or
# three times in inconsistent formats. Take the first occurrence of each.
metric() { # label regex
  local v
  v=$(grep -m1 -E "^; *$2 " "$fit" 2>/dev/null | sed 's/^; *//; s/ *;* *$//' \
      | awk -F';' '{gsub(/^ +| +$/,"",$2); print $2}')
  printf '  %-24s %s\n' "$1" "${v:-n/a}"
}

metric "ALMs"        "Logic utilization \(ALMs needed / total ALMs on device\)"
metric "Registers"   "Total registers"
metric "DSP blocks"  "Total DSP Blocks"
metric "M10K blocks" "Total RAM Blocks"
metric "Memory bits" "Total block memory bits"

regs=$(grep -m1 -E "^; *Total registers " "$fit" | awk -F';' '{gsub(/ /,"",$3); print $3}')

if [ "${regs:-0}" = "0" ]; then
  # No registers means no clocked paths and therefore no Fmax table at all.
  # Reporting that as a parse failure sends you hunting for a broken regex.
  printf '  %-24s %s\n' "Fmax" "n/a (combinational)"
elif [ -f "$sta" ]; then
  awk '
    /^; Slow .* Model Fmax Summary/ { inblk = 1; next }
    inblk && /^; *[0-9.]+ MHz/ {
      line = $0; sub(/^; */, "", line); split(line, a, " ");
      v = a[1] + 0;
      if (best == "" || v < best) best = v;
    }
    inblk && /^This panel reports FMAX/ { inblk = 0 }
    END {
      if (best != "") printf "  %-24s %.2f MHz\n", "Fmax (worst corner)", best;
      else            printf "  %-24s %s\n", "Fmax", "not found - check STA section names";
    }
  ' "$sta"

  # A virtual-pinned clock makes Fmax meaningless; surface it rather than
  # letting a distorted number reach the gate table.
  if grep -q 'Critical Warning (15725)' "$sta" 2>/dev/null; then
    echo "  WARNING: clock is virtual-pinned; Fmax may be distorted"
  fi
fi
