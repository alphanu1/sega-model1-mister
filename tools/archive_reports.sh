#!/bin/bash
# Stash a build's Quartus reports under build/reports/<label>/ so they can be
# read after the next build overwrites them.
#
# WHY THIS EXISTS. Every build writes to the same output_files/ path, so a
# measurement is destroyed by the one after it. That has already caused two
# faults here: a stale s32_v60.fit.rpt was read as if it were current (the
# rotate figure standing in for the ALU's), and the standalone ALM series
# 19,368 -> 18,838 -> 18,667 -> 18,439 survived only in a chat transcript. The
# fit report also carries the per-entity M10K and ALM breakdowns, which are the
# only record of where the memory blocks go.
#
# Usage: tools/archive_reports.sh <label> [project-dir]
#   default project-dir is build/mister (the full core)
#   for a module build:  tools/archive_reports.sh alu quartus/build/s32_v60
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
label="${1:?usage: archive_reports.sh <label> [project-dir]}"
proj="${2:-$root/build/mister}"
case "$proj" in /*) ;; *) proj="$root/$proj" ;; esac

dst="$root/build/reports/$label"
mkdir -p "$dst"
n=0
for f in "$proj"/output_files/*.rpt "$proj"/output_files/*.summary; do
    [ -e "$f" ] || continue
    cp "$f" "$dst/" && n=$((n+1))
done
# the one-line headlines, so a directory listing is readable without opening
{
    echo "label:   $label"
    echo "project: $proj"
    echo "date:    $(date '+%Y-%m-%d %H:%M')"
    echo "commit:  $(cd "$root" && git rev-parse --short HEAD 2>/dev/null)"
    for f in "$proj"/output_files/*.fit.rpt; do
        [ -e "$f" ] || continue
        awk -F';' '/Logic utilization \(in ALMs\)|Total RAM Blocks|Total DSP Blocks|Total registers/ {
                 gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3);
                 if ($3 != "") printf "  %-32s %s\n", $2, $3 }' "$f" | head -4
    done
    for f in "$proj"/output_files/*.sta.rpt; do
        [ -e "$f" ] || continue
        awk '/Setup Summary/,/^$/' "$f" | grep -E "^; [a-z].*; -?[0-9]" \
          | awk -F';' '{gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); print "  slack "$3" on "substr($2,1,60)}'
    done
} > "$dst/SUMMARY.txt"
echo "archived $n reports to build/reports/$label"
cat "$dst/SUMMARY.txt"
