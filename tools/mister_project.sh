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
set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/m1_dcache.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/m1_cdc_pulse.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/m1_fetch_bridge.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/bw_monitor.sv

set_global_assignment -name SYSTEMVERILOG_FILE rtl/io/m1_decode.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/io/m1_glue.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/io/m1_ioboard.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/io/m1_uart_tx.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/io/m1_speed_report.sv
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
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_listctl.sv

# The 3D path. Every one of these was built and verified as a standalone module
# before any of it was in the hardware project, which is how a night's work ends
# up sitting BESIDE the core instead of in it. Listed here so that stops being
# possible: the staged .qsf names its sources explicitly, so a module absent from
# this list compiles in simulation and is simply not in the build.
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/fp_to_int.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_fp_pool.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_geo_xform.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_geo_project.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_geo_det.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_geo_rsqrt.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_geo_norm.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_geo_color.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_geo_walk.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_geo_planes.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_geo_clip.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_geometry.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_listwalk.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_quad_store.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_raster_div.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_raster_fill.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_raster_band.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/fp_from_int.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_lightbank.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/video/m1_raster3d.sv

set_global_assignment -name SYSTEMVERILOG_FILE rtl/mem/m1_tdp_ram.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/m1_mainram.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/m1_main.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/m1_integrated.sv

set_global_assignment -name SYSTEMVERILOG_FILE rtl/cpu/v60/v60_bus.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/cpu/v60/v60.sv
set_global_assignment -name SYSTEMVERILOG_FILE rtl/cpu/v60/v60_ifetch.sv

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
# CONSTRAINED BY DEFAULT NOW - it was opt-in and therefore never on.
#
# The interface had no generated clock on the port, no input delay and no output
# delay, in sys_top.sdc or here, which is why RD_LAT had to be found empirically
# on hardware rather than derived, and why a build whose only change was a debug
# counter once produced a garbage picture with +0.296 ns reported slack and no
# new warnings. The fitter was never told those paths matter.
#
# Structure taken from the Model 2 core, which reports it gave "better testing,
# probing and consistent boot":
#
#   * FENCED AWAY FROM quartus_map. Only the fitter and TimeQuest need I/O
#     constraints, and applying them in synthesis is what crashed a Model 1 build
#     inside quartus_map's scl_execute_syn on 2026-08-27 - written off at the time
#     as contention from three concurrent builds, which it was not.
#   * A CRITICAL WARNING IF THE COLLECTION IS EMPTY, because an empty collection
#     is a silent no-op and that is the exact failure this block exists to catch.
#   * The generated clock sourced from the PLL OUTPUT that drives the pin -
#     general[2], 80 MHz at 180 degrees - not from clk_sys with -invert, because
#     the inversion lives inside the PLL now.
#
# The read path is MULTI-CYCLE BY DESIGN: m1_sdram captures CL+N cycles after the
# device drives the bus, N selectable CL+2..CL+5, so a next-edge assumption
# describes a design this is not.
# M1_NO_SDRAM_SDC=1 skips the whole block.
#
# Quartus 17.0 segfaults AFTER A SUCCESSFUL FIT - in timing analysis - on some
# netlists with these constraints: reproducibly for a given netlist, and not at
# all for others. The build that first turned them on completed and reported
# SDRAM_CLK_pin at +0.323 ns; adding one RTL change to m1_main made every retry
# crash with the Fitter still reporting 0 errors. Until that is understood there
# has to be a way to get a testable .rbf out, and an unconstrained build is
# better than no build.
if {[info exists ::env(M1_NO_SDRAM_SDC)]} {
    post_message -type critical_warning \
      "Model1.sdc: SDRAM constraints SKIPPED by M1_NO_SDRAM_SDC -- the interface \
       is unconstrained and this build's memory timing is luck."
} else {
set sdc_exe ""
catch { set sdc_exe $::quartus(nameofexecutable) }
if {[string equal $sdc_exe "quartus_map"]} {
    # Deliberately constrained nowhere in synthesis; the fitter enforces it.
} else {

set sdram_clk_src [get_pins -nowarn {*|pll|pll_inst|altera_pll_i|general[2].*|divclk}]
set sdram_clk_prt [get_ports -nowarn {SDRAM_CLK}]

if {[llength $sdram_clk_src] == 0 || [llength $sdram_clk_prt] == 0} {
    post_message -type critical_warning \
      "Model1.sdc: SDRAM_CLK generated clock NOT created -- source pins \
       [llength $sdram_clk_src], ports [llength $sdram_clk_prt]. The SDRAM \
       interface is UNCONSTRAINED and this build's memory timing is luck."
} else {
    create_generated_clock -name SDRAM_CLK_pin -source $sdram_clk_src $sdram_clk_prt

    set_input_delay -clock SDRAM_CLK_pin -max 6.4 [get_ports {SDRAM_DQ[*]}]
    set_input_delay -clock SDRAM_CLK_pin -min 1.0 [get_ports {SDRAM_DQ[*]}]

    set sdram_out [get_ports -nowarn {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] \
                                      SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE \
                                      SDRAM_DQML SDRAM_DQMH SDRAM_CKE}]
    set_output_delay -clock SDRAM_CLK_pin -max  1.5 $sdram_out
    set_output_delay -clock SDRAM_CLK_pin -min -0.8 $sdram_out

    # THE MULTICYCLES ARE ON BY DEFAULT AS OF 2026-08-29, and the segfault they
    # were blamed for was not theirs.
    #
    # They were made opt-in after quartus_fit crashed three times. The crash is
    # in the Tcl TEARDOWN - freeing STA collections this script left in
    # variables, see the unset at the end of this file - and it happens with the
    # multicycles OFF, which is how it was caught: MODEL1_SDRAM_MCP was not set
    # on the build that crashed.
    #
    # Turning them off has a measured cost. With the constraints analysed and no
    # multicycles, clk_sys misses by 8.186 ns with TNS -127.5, and the failing
    # transfer is exactly SDRAM_CLK_pin -> clk_sys, 16 paths - the sixteen DQ
    # read-capture paths. TimeQuest assumes next-edge capture there and this
    # controller does not do that. The violation was invisible for as long as the
    # constraints were suppressed, which is what suppressing them bought.
    if {![info exists ::env(MODEL1_NO_SDRAM_MCP)]} {
    set_multicycle_path -setup -end 3 \
      -from [get_clocks SDRAM_CLK_pin] \
      -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]
    set_multicycle_path -hold -end 2 \
      -from [get_clocks SDRAM_CLK_pin] \
      -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]

    set_multicycle_path -setup -end 2 \
      -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}] \
      -to   [get_clocks SDRAM_CLK_pin]
    set_multicycle_path -hold -end 1 \
      -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}] \
      -to   [get_clocks SDRAM_CLK_pin]
    }
}

}

}

set sys_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]
set cpu_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[1].*|divclk}]
# general[3] is clk_3d, the 3D layer's 47.059 MHz domain.
set r3d_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[3].*|divclk}]

if {[llength $sys_clk] > 0 && [llength $cpu_clk] > 0 && [llength $r3d_clk] > 0} {
    # THREE GROUPS, NOT TWO. clk_3d was added to the design and not to this cut,
    # and the analyser then timed every crossing into and out of it as though it
    # were synchronous. What that reports is not a real failure - it is
    # m1_cdc_port's own x_addr -> b_addr transfer, which a toggle synchroniser
    # guards, and m1_raster3d's disp_band -> disp_band_s1 two-flop synchroniser.
    # Both are asynchronous crossings by construction and the tool cannot know it.
    #
    # Measured before the cut: -2.277 ns and -142 ns of total negative slack,
    # entirely from those two structures.
    # THE THREE-WAY CUT IS CORRECT AGAIN, because m1_copro_if is now a REAL
    # crossing: it synchronises the V60's request into the coprocessor's clock
    # domain with two flops, so these paths genuinely do not need timing.
    #
    # It was not always so, and that is the whole story of the 2:1 work:
    #   cut, interface not a CDC  -> unconstrained, board BLACK, P=0000
    #   clocks grouped            -> "Can't fit design in device"
    #   set_max_delay over the cut-> no effect, only 2 paths ever analysed
    #   interface made a real CDC -> cut is honest, and this is that build
    set_clock_groups -asynchronous -group $sys_clk -group $cpu_clk -group $r3d_clk
    set_false_path -from [get_registers -nowarn {*m1_copro_if*dbg_*}]
    set_false_path -from [get_registers -nowarn {*m1_tgp*dbg_*}]
    set_false_path -to   [get_registers -nowarn {*m1_speed_report*}]
    post_message "Model1: three-way cut; copro_if is a real CDC"
} elseif {[llength $sys_clk] > 0 && [llength $cpu_clk] > 0} {
    set_clock_groups -asynchronous -group $sys_clk -group $cpu_clk
    post_message -type warning \
        "Model1: clk_3d not found - cut only clk_sys from clk_cpu"
} else {
    post_message -type error \
        "Model1: core PLL clocks not found - check the pll/pll_inst/altera_pll_i names"
}

# FREE EVERY STA COLLECTION BEFORE THE INTERPRETER GOES AWAY.
#
# quartus_fit SEGFAULTS AT EXIT OTHERWISE, after reporting success. Measured
# 2026-08-29: "Quartus Prime Fitter was successful. 0 errors, 45 warnings",
# then
#
#     *** Fatal Error: Segment Violation
#     Module: quartus_fit
#     0x32ee4f: STA_COLLECTION_ATCL_OBJ::~STA_COLLECTION_ATCL_OBJ()
#     0x2b0be:  ATCL_OBJ::tcl_freeInternalRepProc(Tcl_Obj*)
#     0x130ec1: UnsetVarStruct
#     0x131253: TclDeleteNamespaceVars
#     0x103fc0: TclTeardownNamespace
#     0x19d82:  atcl_exe_fini()
#
# The fit itself is fine - 30,099 ALM, 452 M10K, 0 errors. What dies is the
# teardown of the Tcl namespace, freeing collection objects that outlived the
# STA session. No fit report is written and the assembler never runs, so the
# build produces NO .rbf while claiming the fitter succeeded, and the flow
# reports only "Evaluation of Tcl script qsh_flow.tcl unsuccessful" - which
# names neither the stage nor the cause.
#
# THE MULTICYCLES WERE BLAMED FOR THIS AND ARE NOT THE CAUSE. They are opt-in
# behind MODEL1_SDRAM_MCP and were NOT set on the build that crashed. Three
# earlier crashes were attributed to them and the constraints were disabled in
# response; the trace says the collections are what matters.
unset -nocomplain sdram_clk_src sdram_clk_prt sdram_out sys_clk cpu_clk r3d_clk sdc_exe
EOF

# Project settings: the template's, with the entity and the file list swapped.
#
# OPTIMISATION TARGET IS OVERRIDABLE, because it is worth a lot of area here. The
# MiSTer template asks for HIGH PERFORMANCE EFFORT and OPTIMIZATION_TECHNIQUE
# SPEED. Measured on the V60 alone, Quartus 17.0:
#
#     Aggressive Performance   20,129 ALM   24.92 MHz
#     Aggressive Area          17,498 ALM   24.06 MHz
#
# 2,631 ALM - 13% - for 3.5% of Fmax, which is more than every RTL change made
# for area put together, and it cannot break correctness. Whether the full core
# keeps that ratio, and whether it still closes timing, is what
# M1_QOPT="Aggressive Area" is for.
sed -e 's/^source files.qip$/source files.qip/' \
    "$tpl/Template.qsf" > "$stage/Model1.qsf"

# FITTER SEED, pinned rather than re-rolled.
#
# From the Kaneko16 core's findings: "SEED 1 to SEED 3 closed it: -0.084 to
# +0.344, with the same logic and the same memory", and - the part that matters
# for deciding whether to touch RTL - "the build immediately before it had MORE
# logic, 12,401 ALMs against 12,018, and closed at zero, which is what identifies
# placement rather than capacity as the cause."
#
# That is our shape too: the flat V60 build has MORE ALM (30,227) and closes at
# +0.639 ns, while the split has less (29,992) and closes at +0.143. Changing RTL
# to fix a placement result would be the wrong lever.
# SEED 5 IS THE ONE THAT CLOSES as of 2026-09-01, and it is the second time the
# note below has paid for itself. With the frustum clipper in, the default seed
# put clk_sys at -0.142 ns with the design at 99% of its ALMs - a single failing
# endpoint whose TNS equalled the worst slack, which is placement and not logic.
# SEED 5 closes at +0.061 with every other corner positive, on the same RTL.
#
# SEED 3 was the one that closed as of 2026-08-30. Sharing the tile RAM and
# palette between the CPU and video ports (m1_tdp_ram) freed 80 M10K and cost a
# little placement luck: the default seed lands clk_sys at -0.010 ns, a 10 ps
# miss, and seed 3 puts it at +0.141 with no negative setup or hold slack
# anywhere. A marginal miss is a placement outcome, not a design fault - try a
# seed before changing logic.
M1_SEED="${M1_SEED:-5}"
if [ -n "${M1_SEED:-}" ]; then
    # The template's last line has no trailing newline, so append one first or
    # the assignment lands on the end of it and Quartus rejects the file.
    printf '\nset_global_assignment -name SEED %s\n' "$M1_SEED" >> "$stage/Model1.qsf"
    echo "  SEED = $M1_SEED"
fi

# AREA IS THE BINDING CONSTRAINT NOW, so the area settings are the DEFAULT and
# the speed ones are the opt-out. That is a reversal of the earlier judgement and
# it is deliberate: when Aggressive Area was measured it cost 0.272 ns of slack to
# save 469 ALM, which was a bad trade while ALM was not binding. The design has
# since failed to fit - 166,497 combinational nodes against 83,820 - so it is.
#
# The template ships three settings that actively TRADE AREA FOR SPEED, and they
# were left on through every build until now:
#
#   PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION      duplicates registers to shorten
#                                                fanout paths
#   ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION inserts LCELLs and duplicates
#                                                logic to help routing
#   OPTIMIZATION_TECHNIQUE SPEED                 the whole synthesis bias
#
# M1_QSPEED=1 puts all of it back, for when timing is the problem again.
M1_QOPT="${M1_QOPT:-Aggressive Area}"
# THE FOUR SETTINGS ARE INDEPENDENT, and coupling them under one switch hides a
# useful middle. The two DUPLICATION options are what spend ALM most directly -
# they replicate registers and insert logic cells - while MODE and TECHNIQUE
# bias the optimiser without necessarily inflating the netlist. So a balanced
# build with duplication still off is a real point on the curve, and it is the
# one worth trying when area mode misses timing but speed mode will not fit:
#
#   M1_QTECH=BALANCED M1_QOPT=Balanced make rbf
#
# Measured trade for reference: Aggressive Area saved 469 ALM for 0.272 ns.
M1_QTECH="${M1_QTECH:-AREA}"
M1_QDUP="${M1_QDUP:-OFF}"
if [ -n "${M1_QSPEED:-}" ]; then
    echo "  M1_QSPEED set: keeping the template's speed-biased settings"
else
    sed -i -e "s/^set_global_assignment -name OPTIMIZATION_MODE .*/set_global_assignment -name OPTIMIZATION_MODE \"$M1_QOPT\"/" \
           -e "s/^set_global_assignment -name OPTIMIZATION_TECHNIQUE .*/set_global_assignment -name OPTIMIZATION_TECHNIQUE $M1_QTECH/" \
           -e "s/^set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION .*/set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION $M1_QDUP/" \
           -e "s/^set_global_assignment -name ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION .*/set_global_assignment -name ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION $M1_QDUP/" \
           "$stage/Model1.qsf"
    echo "  OPTIMIZATION_MODE = $M1_QOPT, TECHNIQUE = $M1_QTECH"
    echo "  register duplication $M1_QDUP, router logic duplication $M1_QDUP"
fi

cat > "$stage/Model1.qpf" <<'EOF'
QUARTUS_VERSION = "17.0"
PROJECT_REVISION = "Model1"
EOF

echo "staged $stage"
echo "  build with: cd $stage && quartus_sh --flow compile Model1"
