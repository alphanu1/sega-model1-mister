# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
# Sega Model 1 MiSTer core
#
# Two build paths, deliberately separate:
#
#   lint / test / area   simulation and proxy synthesis. No Quartus needed.
#   quartus              M0 spike: one module, real device, real ALM/DSP/Fmax.
#   (core)               full MiSTer .rbf build. Does not exist until M1
#                        produces a top level. See docs/m1-m4-plan.md.

VFLAGS := -Wno-TIMESCALEMOD -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
RTL    := rtl/tgp

# Per-module source lists for the Quartus spike flow.
SRCS_fp_mul := $(RTL)/fp_mul.sv
SRCS_fp_add := $(RTL)/fp_add.sv
SRCS_mb86233_alu := $(RTL)/mb86233_pkg.sv $(RTL)/fp_mul.sv $(RTL)/fp_add.sv \
                    $(RTL)/mb86233_alu.sv
SRCS_mb86233_agu := $(RTL)/mb86233_agu.sv
SRCS_mb86233_seq := $(RTL)/mb86233_pkg.sv $(RTL)/mb86233_seq.sv

.PHONY: all lint test test_fp_mul test_fp_add test_alu test_agu test_seq area quartus quartus_report clean distclean

all: test

# ---------------------------------------------------------------- simulation

lint:
	verilator --lint-only -Wall $(VFLAGS) $(RTL)/mb86233_pkg.sv $(RTL)/fp_mul.sv --top-module fp_mul
	verilator --lint-only -Wall $(VFLAGS) $(RTL)/fp_add.sv --top-module fp_add
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_mb86233_alu) --top-module mb86233_alu
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_mb86233_agu) --top-module mb86233_agu
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_mb86233_seq) --top-module mb86233_seq

test: test_fp_mul test_fp_add test_alu test_agu test_seq

test_fp_mul:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module fp_mul \
	  $(RTL)/fp_mul.sv sim/tgp/tb_fp_mul.cpp -o tb_fp_mul --Mdir obj_fpmul
	./obj_fpmul/tb_fp_mul

test_fp_add:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module fp_add \
	  $(RTL)/fp_add.sv sim/tgp/tb_fp_add.cpp -o tb_fp_add --Mdir obj_fpadd
	./obj_fpadd/tb_fp_add

test_alu:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module mb86233_alu \
	  $(SRCS_mb86233_alu) sim/tgp/tb_mb86233_alu.cpp -o tb_alu --Mdir obj_alu
	./obj_alu/tb_alu

test_agu:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module mb86233_agu \
	  $(SRCS_mb86233_agu) sim/tgp/tb_mb86233_agu.cpp -o tb_agu --Mdir obj_agu
	./obj_agu/tb_agu

test_seq:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module mb86233_seq \
	  $(SRCS_mb86233_seq) sim/tgp/tb_mb86233_seq.cpp -o tb_seq --Mdir obj_seq
	./obj_seq/tb_seq

# Proxy only: generic 6-LUT mapping, no DSP inference, no device model.
# Useful for tracking relative change between edits. Does not settle the M0 gate.
# The stat block must be isolated with awk before grepping: yosys logs
# "Executing OPT_DFF pass" lines to stdout during synth, and a bare grep for
# DFF matches those first, so head consumes log noise and no numbers ever
# appear. Anchoring on "Printing statistics" is what makes this report real.
AREA_MODULES := fp_mul fp_add mb86233_alu mb86233_agu mb86233_seq

# Expanded by make, not the shell: $(SRCS_$(m)) has to resolve at make time,
# and a shell loop variable cannot index a make variable.
area:
	@$(foreach m,$(AREA_MODULES), \
	  echo "== $(m)"; \
	  yosys -p "read_verilog -sv $(SRCS_$(m)); hierarchy -top $(m); \
	            synth -top $(m) -lut 6 -flatten; stat" \
	    2>/dev/null | awk '/Printing statistics/,0' \
	    | grep -E '\$$lut|\$$_DFF' | awk '!seen[$$2]++'; )

# ------------------------------------------------------------- M0 spike flow
#
#   make quartus MOD=fp_add
#
# Builds a throwaway synthesis-only project against 5CSEBA6U23I7 and reports
# ALMs, DSP blocks, memory and Fmax. This is what the M0 resource gate reads.
# Requires Quartus Prime Lite 17.0.x on PATH (quartus_sh, quartus_map,
# quartus_fit, quartus_sta).

MOD ?= fp_add
QDIR := quartus/build/$(MOD)

quartus:
	@command -v quartus_map >/dev/null || { echo "quartus_map not on PATH"; exit 1; }
	@mkdir -p $(QDIR)
	@srcs=""; for f in $(SRCS_$(MOD)); do \
	  srcs="$$srcs\nset_global_assignment -name SYSTEMVERILOG_FILE ../../../$$f"; done; \
	  sed -e 's/@MODULE@/$(MOD)/g' -e "s|@SRCS@|$$srcs|" quartus/spike.qsf.in > $(QDIR)/$(MOD).qsf
	@cp quartus/spike.sdc $(QDIR)/spike.sdc
	@echo "PROJECT_REVISION = \"$(MOD)\"" > $(QDIR)/$(MOD).qpf
	cd $(QDIR) && quartus_map $(MOD) && quartus_fit $(MOD) && quartus_sta $(MOD)
	@$(MAKE) --no-print-directory quartus_report MOD=$(MOD)

quartus_report:
	@cd quartus && ./report.sh $(MOD)

clean:
	rm -rf obj_fpmul obj_fpadd obj_alu obj_agu obj_seq

distclean: clean
	rm -rf quartus/build
