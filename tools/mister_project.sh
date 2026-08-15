#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Stage a MiSTer core build in build/mister/.
#
# MiSTer cores normally keep a copy of sys/ in the repository. This one does
# not: third_party/ is gitignored and re-cloned by tools/bootstrap.sh, and
# vendoring a second copy of the framework would mean two things to keep in
# step and a GPL-2-or-later tree living inside a GPL-3 one for no benefit.
#
# So the project is assembled here instead. sys/ is symlinked rather than
# copied, because sys.tcl and sys_top.sdc use paths relative to it and a
# partial copy fails in ways that look like Quartus bugs.
#
# The top level Quartus builds is sys_top, from the framework. `emu` — our
# Model1.sv — is what sys_top instantiates.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
stage="$root/build/mister"
tpl="$root/third_party/template"

[ -d "$tpl/sys" ] || { echo "third_party/template missing — run ./tools/bootstrap.sh"; exit 1; }

mkdir -p "$stage"
ln -sfn "$tpl/sys"  "$stage/sys"
ln -sfn "$root/rtl" "$stage/rtl"
ln -sfn "$root/Model1.sv" "$stage/Model1.sv"

# Every source below emu, in the order Quartus wants nothing in particular but
# a human reading it does: memory, then I/O, then video, then the board.
cat > "$stage/files.qip" <<'EOF'
set_global_assignment -name SYSTEMVERILOG_FILE Model1.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/m1_pll.sv

set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/m1_sdram.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/m1_cdc_port.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/m1_cdc_pulse.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/m1_fetch_bridge.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/bw_monitor.sv

set_global_assignment -name SYSTEMVERILOG_FILE rtl/io/m1_decode.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/io/m1_glue.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/io/m1_ioboard.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/io/m1_rom_loader.sv

set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_tile_decode.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_tile_fetch.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_tile_mixer.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_video_timing.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_palette.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_video.sv

set_global_assignment -name SYSTEMVERILOG_FILE rtl/m1_mainram.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/m1_main.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/m1_integrated.sv

set_global_assignment -name SYSTEMVERILOG_FILE rtl/cpu/v60/v60_bus.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/cpu/v60/v60.sv

set_global_assignment -name SDC_FILE Model1.sdc
EOF

# The core's own timing. sys_top.sdc constrains the framework; this constrains
# what hangs off our PLL.
#
# The two core clocks are asynchronous to each other by design — everything
# crossing goes through m1_cdc_port, m1_fetch_bridge, m1_cdc_pulse or a
# dual-clock RAM — so they are cut here. Without the cut the fitter tries to
# close paths that the synchronisers exist to make meaningless, and either
# fails timing on them or wastes effort avoiding a problem that is not real.
cat > "$stage/Model1.sdc" <<'EOF'
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA - Copyright (C) 2026 alphanu1
#
# sys_top.sdc already puts every core PLL output into ONE group, decoupled from
# the framework's audio and HDMI PLLs:
#
#     -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
#
# which is why rtl/m1_pll.sv's instance names have to be exactly pll / pll_inst /
# altera_pll_i. They were not, once, and the core's clocks fell outside every
# group and got timed against the audio PLL: -87 ns of setup slack, a clean
# build, and nothing running on hardware.
#
# Being in one group means clk_sys and clk_cpu are timed against EACH OTHER,
# which is also wrong. They are asynchronous by construction - everything that
# crosses goes through m1_cdc_port, m1_fetch_bridge, m1_cdc_pulse or a
# dual-clock RAM - so they are cut here, by their real names.
#
# The names are checked rather than assumed: an empty get_clocks silently makes
# set_clock_groups a no-op, which is exactly how this went wrong the first time.

set sys_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]
set cpu_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[1].*|divclk}]

if {[llength $sys_clk] > 0 && [llength $cpu_clk] > 0} {
    set_clock_groups -asynchronous -group $sys_clk -group $cpu_clk
    post_message "Model1: clk_sys and clk_cpu cut from each other"
} else {
    post_message -type error \
        "Model1: core PLL clocks not found - check the pll/pll_inst/altera_pll_i names"
}
EOF

# Project settings: the template's, with the entity and the file list swapped.
sed -e 's/^source files.qip$/source files.qip/' \
    "$tpl/Template.qsf" > "$stage/Model1.qsf"

cat > "$stage/Model1.qpf" <<'EOF'
QUARTUS_VERSION = "17.0"
PROJECT_REVISION = "Model1"
EOF

echo "staged $stage"
echo "  build with: cd $stage && quartus_sh --flow compile Model1"
