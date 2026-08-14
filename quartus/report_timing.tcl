# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Print the worst setup paths with their endpoints. The STA summary gives a
# slack number and nothing else, which is enough to know a design misses its
# constraint and useless for knowing where to cut. Retiming against a slack
# figure alone is guesswork.
project_open [lindex $quartus(args) 0]
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 5 -detail path_only -panel_name "Worst Setup"
report_timing -setup -npaths 3 -detail full_path
project_close
