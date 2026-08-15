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

# Always print the toolchain. With more than one Quartus installed, a table of
# ALM/Fmax numbers with no version attached is worse than no table: the M0 gate
# is measured on whatever happened to be on PATH, and 17.0.x and 24.1 do not
# fit identically.
ver=$(grep -m1 -i '^Quartus Prime Version' "$D/$M.fit.summary" 2>/dev/null \
      | sed 's/.*: *//')
printf '  %-24s %s\n' "Quartus" "${ver:-unknown}"

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
    /^; Slow .* Model Fmax Summary/ { inblk = 1; saw_blk = 1; next }
    inblk && /^; *[0-9.]+ MHz/ {
      # The row is "; <fmax> ; <restricted> ; <clock> ;" — split on the
      # separator, not on whitespace, or the clock name lands in whichever
      # field the column padding happens to put it.
      split($0, f, ";");
      fm = f[2]; ck = f[4];
      gsub(/^[ \t]+|[ \t]+$/, "", fm);
      gsub(/^[ \t]+|[ \t]+$/, "", ck);
      sub(/ MHz$/, "", fm);
      v = fm + 0;
      # Column 4 is the clock name. PER CLOCK, and worst corner within each:
      # collapsing a multi-clock design to one number reports the slowest clock
      # as if it were the whole design. m1_integrated runs its video side at
      # 119 MHz and its CPU at 25, and "24.46 MHz" was the entire answer this
      # printed — which is the number that decides whether the video path is
      # viable, reported as though it were not.
      if (!(ck in best) || v < best[ck]) best[ck] = v;
      order[++n] = ck;
    }
    inblk && /^This panel reports FMAX/ { inblk = 0 }
    END {
      if (n > 0) {
        seen_count = 0;
        for (i = 1; i <= n; i++) {
          ck = order[i];
          if (ck in printed) continue;
          printed[ck] = 1;
          seen_count++;
          printf "  %-24s %.2f MHz\n", "Fmax " ck, best[ck];
        }
      }
      else if (saw_blk) printf "  %-24s %s\n", "Fmax", "n/a (no register-to-register paths)";
      else              printf "  %-24s %s\n", "Fmax", "NOT FOUND - check STA section names";
    }
  ' "$sta"

  # A virtual-pinned clock makes Fmax meaningless; surface it rather than
  # letting a distorted number reach the gate table.
  if grep -q 'Critical Warning (15725)' "$sta" 2>/dev/null; then
    echo "  WARNING: clock is virtual-pinned; Fmax may be distorted"
  fi
fi
