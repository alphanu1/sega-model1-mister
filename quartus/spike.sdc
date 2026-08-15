# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
# M0 spike timing constraint.
#
# 50 MHz is the M0 gate floor from docs/m0-mb86233-spike.md. The TGP retires
# ~5.3 M instructions/sec at a 16 MHz part clock, so real-world headroom is
# large; this constraint exists to make the STA report a meaningful slack
# number, not because the design is speed-critical.

# Guarded: mb86233_agu is purely combinational and has no clk port at all, and
# an unguarded create_clock on an empty collection aborts the whole SDC, taking
# the false-path cuts below with it.
if {[llength [get_ports -nowarn {clk}]] > 0} {
    create_clock -name clk -period 20.000 [get_ports {clk}]
}

# The integrated design has two clocks and they are genuinely asynchronous:
# 96 MHz for memory, ROM loading and video, 24 MHz for the V60. Constraining
# only a port called "clk" left this design with NO clock constraint at all —
# the Fmax summary still reports per-clock figures, so the numbers were real,
# but nothing told the fitter what to aim for and nothing cut the paths between
# the domains. Those paths are handled by the synchronisers in m1_cdc_port,
# m1_cdc_pulse and the dual-clock RAMs, and must not be timed as if synchronous.
if {[llength [get_ports -nowarn {clk_sys}]] > 0} {
    create_clock -name clk_sys -period 10.417 [get_ports {clk_sys}]
}
if {[llength [get_ports -nowarn {clk_cpu}]] > 0} {
    create_clock -name clk_cpu -period 41.667 [get_ports {clk_cpu}]
}
if {[llength [get_clocks -nowarn {clk_sys}]] > 0 && [llength [get_clocks -nowarn {clk_cpu}]] > 0} {
    set_clock_groups -asynchronous -group {clk_sys} -group {clk_cpu}
}

derive_clock_uncertainty

# Ports are virtual pins. I/O timing is meaningless here; cut it so the report
# reflects internal paths only.
set_false_path -from [all_inputs] -to [all_registers]
set_false_path -from [all_registers] -to [all_outputs]
