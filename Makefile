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

.PHONY: all lint test test_fp_mul test_fp_add test_alu test_agu test_seq area quartus quartus_list quartus_report clean distclean

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

# Toolchain selection. MiSTer's sys/ ships PLL IP pre-generated for Quartus
# 13.1 and 17.0 only (third_party/template/sys/pll_q13.qip, pll_q17.qip), so a
# real core build needs 17.0.x. The M0 spike has no sys/ and no IP, so any
# version that supports Cyclone V gives valid numbers — but the two must never
# be confused, which is why the version is recorded with every report.
#
#   make quartus MOD=fp_add              newest install found
#   make quartus MOD=fp_add QUARTUS=17.0 pick a specific one
#
# Auto-detects ~/intelFPGA*/<ver>/quartus/bin so the flow works without
# exporting PATH by hand.
QUARTUS ?=
QUARTUS_ROOTS := $(wildcard $(HOME)/intelFPGA_lite/*/quartus/bin $(HOME)/intelFPGA/*/quartus/bin /opt/intelFPGA_lite/*/quartus/bin /opt/intelFPGA/*/quartus/bin)
ifeq ($(QUARTUS),)
  QUARTUS_BIN := $(lastword $(sort $(QUARTUS_ROOTS)))
else
  QUARTUS_BIN := $(firstword $(foreach d,$(QUARTUS_ROOTS),$(if $(findstring /$(QUARTUS)/,$(d)),$(d))))
endif

.PHONY: quartus_list
quartus_list:
	@echo "Quartus installs found:"; \
	 for d in $(QUARTUS_ROOTS); do \
	   v=$$(echo $$d | sed 's|.*/intelFPGA[^/]*/||; s|/quartus/bin||'); \
	   printf "  %-10s %s\n" "$$v" "$$d"; done; \
	 echo "selected: $(QUARTUS_BIN)"

quartus:
	@test -n "$(QUARTUS_BIN)" || { echo "no Quartus install found. Looked in ~/intelFPGA_lite/*/quartus/bin and /opt. Use QUARTUS=<ver> or add to PATH; 'make quartus_list' shows what was found."; exit 1; }
	@test -x "$(QUARTUS_BIN)/quartus_map" || { echo "$(QUARTUS_BIN)/quartus_map not executable"; exit 1; }
	@echo "using $(QUARTUS_BIN)"
	@mkdir -p $(QDIR)
	@srcs=""; for f in $(SRCS_$(MOD)); do \
	  srcs="$$srcs\nset_global_assignment -name SYSTEMVERILOG_FILE ../../../$$f"; done; \
	  sed -e 's/@MODULE@/$(MOD)/g' -e "s|@SRCS@|$$srcs|" quartus/spike.qsf.in > $(QDIR)/$(MOD).qsf
	@cp quartus/spike.sdc $(QDIR)/spike.sdc
	@echo "PROJECT_REVISION = \"$(MOD)\"" > $(QDIR)/$(MOD).qpf
	cd $(QDIR) && PATH="$(QUARTUS_BIN):$$PATH" sh -c 'quartus_map $(MOD) && quartus_fit $(MOD) && quartus_sta $(MOD)'
	@$(MAKE) --no-print-directory quartus_report MOD=$(MOD)

quartus_report:
	@cd quartus && ./report.sh $(MOD)

clean:
	rm -rf obj_fpmul obj_fpadd obj_alu obj_agu obj_seq

distclean: clean
	rm -rf quartus/build
