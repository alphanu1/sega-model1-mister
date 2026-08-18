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
set_global_assignment -name QIP_FILE rtl/pll.qip

set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/m1_sdram.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/m1_cdc_port.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/m1_cdc_pulse.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/m1_fetch_bridge.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/bw_monitor.sv

set_global_assignment -name SYSTEMVERILOG_FILE rtl/io/m1_decode.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/io/m1_glue.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/io/m1_ioboard.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/m1_copro_if.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/m1_tgp.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/mb86233_pkg.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/fp_mul.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/fp_add.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/fp_div.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/mb86233_alu.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/mb86233_agu.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/mb86233_seq.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/mb86233_regs.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/mb86233_mem.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/mb86233_dec.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/mb86233_xfer.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/tgp/mb86233_core.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/io/m1_rom_loader.sv

set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_tile_decode.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_tile_fetch.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_tile_mixer.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_video_timing.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_palette.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_video.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_diag.sv

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
# which is why the PLL comes from the generated IP in rtl/pll.qip, whose module
# and instance are both named `pll`. A hand-instantiated altera_pll produced the
# wrong hierarchy once, the clocks fell outside every group and got timed
# against the audio PLL: -87 ns of setup slack, a clean build, and nothing
# running on hardware.
#
# Being in one group means clk_sys and clk_cpu are timed against EACH OTHER,
# which is also wrong. They are asynchronous by construction - everything that
# crosses goes through m1_cdc_port, m1_fetch_bridge, m1_cdc_pulse or a
# dual-clock RAM - so they are cut here, by their real names.
#
# The names are checked rather than assumed: an empty get_clocks silently makes
# set_clock_groups a no-op, which is exactly how this went wrong the first time.

# ---------------------------------------------------------------- the SDRAM
#
# OPT-IN, DEFAULT OFF: export MODEL1_SDRAM_SDC=1 to emit these.
#
# They are correct as far as they go and they are NOT usable yet, because the read
# path cannot be modelled without a multicycle and Quartus 17.0's FITTER SEGFAULTS
# on one — "Fatal Error: Segment Violation", twice, in both the -from <ports> -to
# <registers> spelling and the conventional clock-to-clock one. Twenty-five minutes
# each to find out.
#
# Without the multicycle the build completes and reports clk_sys at -7.192 ns on
# SDRAM_DQ -> dq_r, which is a MIS-MODELLED path rather than a real failure: dq_r
# registers the pin every cycle and a tag pipeline picks the sample, at a depth
# selectable CL+2..CL+5 from the OSD. Leaving that in every report would bury a
# genuine regression under a known false alarm, so it is off by default.
#
# What IS worth having from it: with only the output side constrained, sdram_clk
# reported -0.150 ns. Small, real, and on the path the framework already tries to
# improve — Template.qsf asks for Fast Output Register=ON on SDRAM_*, and ours are
# REFUSED because sd_a is reset to '0 at m1_sdram.sv:449 while also being
# conditionally loaded, which a Cyclone V I/O register cannot do. Fixing that needs
# the pin registers split into their own always_ff without an async reset, which is
# a real change to a controller with a 74,729-check suite and was not attempted at
# the end of a long session.
#
# NOTHING CONSTRAINED THIS INTERFACE. Not sys_top.sdc, not this file — no
# generated clock on the port, no output delay, no input delay. The fitter was
# never told those paths matter and could never report them as bad, which is why
# RD_LAT had to be found empirically on hardware rather than derived, and why a
# build whose only change was a debug counter and a UART produced a garbage
# picture with +0.296 ns reported slack and no new warnings.
#
# Device numbers are for the -6 grade part MiSTer's SDRAM boards carry, with a
# little added for board trace. They are deliberately pessimistic: the point of
# the first constrained build is to find out how much margin actually exists, and
# an optimistic number would hide exactly that.
#
#   tSU  1.5 ns   address/command setup to the device's clock edge
#   tHD  0.8 ns   hold after it
#   tAC  6.0 ns   clock edge to read data valid
#   tOH  2.5 ns   read data held after the edge
#
# SDRAM_CLK is `~clk_sys` assigned to the pin in Model1.sv — combinational fabric
# driving an output — so -invert on the generated clock describes what the pin
# does. That the clock's own delay to the pin is a ROUTING RESULT is the deeper
# fault and constraints cannot fix it; see docs/findings.md. This step is here to
# measure the interface before changing how the clock is produced.
if {[info exists ::env(MODEL1_SDRAM_SDC)]} {
set sdram_src [get_pins -nowarn {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]
if {[llength $sdram_src] > 0 && [llength [get_ports -nowarn {SDRAM_CLK}]] > 0} {
    create_generated_clock -name sdram_clk -source $sdram_src -invert \
        [get_ports {SDRAM_CLK}]

    set sys_clk_for_sdram [get_clocks -nowarn \
        {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]

    set sdram_out [get_ports -nowarn {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] \
                                      SDRAM_DQML SDRAM_DQMH SDRAM_nCS \
                                      SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
    set_output_delay -clock sdram_clk -max  1.5 $sdram_out
    set_output_delay -clock sdram_clk -min -0.8 $sdram_out

    # Reads come back on the same forwarded clock.
    set sdram_in [get_ports -nowarn {SDRAM_DQ[*]}]
    set_input_delay -clock sdram_clk -max 6.0 $sdram_in
    set_input_delay -clock sdram_clk -min 2.5 $sdram_in

    # THE READ IS MULTICYCLE BY DESIGN, and leaving that out reported -7.192 ns on
    # a path with 2.4 ns of delay and one logic level.
    #
    # dq_r registers the pin EVERY cycle and a tag pipeline selects which sample to
    # use, at a depth of CL+2..CL+5 chosen from the OSD. That selectable depth IS
    # the read phase. So the data is not required to arrive by the next clk_sys
    # edge — it is allowed a further cycle, and the pipeline accounts for it.
    # Without a multicycle, STA analyses the very next edge and reports a failure
    # the design never intended to avoid.
    #
    # Two periods, not more: the capture register must still be stable at the edge
    # the tag depth expects, so this describes the real requirement rather than
    # relaxing it until the numbers look pleasant.
    # Expressed CLOCK TO CLOCK. The -from <ports> -to <registers> form made
    # Quartus 17.0's fitter die with "Fatal Error: Segment Violation at 0xc" —
    # a tool crash, not a constraint error, and it takes twenty-five minutes to
    # discover. Clock-to-clock is the conventional spelling and is what the STA
    # engine wants.
    if {[llength $sys_clk_for_sdram] > 0} {
        set_multicycle_path -setup 2 -from [get_clocks sdram_clk] \
                            -to $sys_clk_for_sdram
        set_multicycle_path -hold  1 -from [get_clocks sdram_clk] \
                            -to $sys_clk_for_sdram
        post_message "Model1: SDRAM read capture is multicycle 2 (tag depth CL+2..CL+5)"
    } else {
        post_message -type error "Model1: clk_sys not found - read path left single-cycle"
    }

    post_message "Model1: SDRAM interface constrained (tSU 1.5 / tHD 0.8 / tAC 6.0 / tOH 2.5)"
} else {
    post_message -type error "Model1: SDRAM_CLK or the core PLL not found - constraints NOT applied"
}
}

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
