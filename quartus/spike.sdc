# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
# M0 spike timing constraint.
#
# 50 MHz is the M0 gate floor from docs/m0-mb86233-spike.md. The TGP retires
# ~5.3 M instructions/sec at a 16 MHz part clock, so real-world headroom is
# large; this constraint exists to make the STA report a meaningful slack
# number, not because the design is speed-critical.

create_clock -name clk -period 20.000 [get_ports {clk}]

derive_clock_uncertainty

# Ports are virtual pins. I/O timing is meaningless here; cut it so the report
# reflects internal paths only.
set_false_path -from [all_inputs] -to [all_registers]
set_false_path -from [all_registers] -to [all_outputs]
