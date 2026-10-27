#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build and run the m1_scan15 bench (Verilator 5). From anywhere:
#   sim/video/run_scan15.sh [mode] [frames] [cad] [ph]     mode 0 = 273/274, 1 = 268/269, 2 = 262/263
# OBJ_DIR sets where the model is built (default build/scan15_obj -- this project keeps temporaries out of /tmp);
# VFLAGS adds Verilator options (e.g. -GRING=14); PLUS adds plusargs (e.g. PLUS="+rnd=1 +slip3=20 +seed=7", a
# cadence that slips; "+pe=0" pairing off). Ported from the Model 2 core's script of the same name.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mode="${1:-0}"; frames="${2:-14}"; cad="${3:-2}"; ph="${4:-0}"
obj="${OBJ_DIR:-$root/build/scan15_obj}"
cd "$root"
if [ ! -x "$obj/tb" ] || [ rtl/video/m1_scan15.sv -nt "$obj/tb" ] || [ sim/video/tb_m1_scan15.sv -nt "$obj/tb" ]; then
  rm -rf "$obj"; mkdir -p "$obj"
  verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_m1_scan15 ${VFLAGS:-} --Mdir "$obj" \
    sim/video/tb_m1_scan15.sv rtl/video/m1_scan15.sv rtl/video/m1_video_timing.sv -o tb > "$obj/build.log" 2>&1 \
    || { tail -30 "$obj/build.log"; exit 1; }
fi
"$obj/tb" "+mode=$mode" "+frames=$frames" "+cad=$cad" "+ph=$ph" ${PLUS:-} 2>&1 \
  | grep -E "output hash|EVENTS|VSYNC|ALIGN|PAIRBAD|image cadence|mode |pixels checked|hsync|vsync|re-align|margin|FIELD|PASS|FAIL|TIMEOUT|RING|PIXEL|STEP|HSYNC" | head -40
