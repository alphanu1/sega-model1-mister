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
SRCS_fp_div := $(RTL)/fp_div.sv
SRCS_mb86233_alu := $(RTL)/mb86233_pkg.sv $(RTL)/fp_mul.sv $(RTL)/fp_add.sv \
                    $(RTL)/fp_div.sv $(RTL)/mb86233_alu.sv
SRCS_mb86233_agu := $(RTL)/mb86233_agu.sv
SRCS_mb86233_regs := $(RTL)/mb86233_pkg.sv $(RTL)/mb86233_regs.sv
SRCS_mb86233_mem := $(RTL)/mb86233_mem.sv
SRCS_mb86233_dec := $(RTL)/mb86233_dec.sv
SRCS_mb86233_xfer := $(RTL)/mb86233_pkg.sv $(RTL)/mb86233_xfer.sv
SRCS_bw_monitor := rtl/mem/bw_monitor.sv
SRCS_sdram_model := sim/mem/sdram_model.sv
SRCS_m1_sdram := rtl/mem/m1_sdram.sv
SRCS_m1_rom_loader := rtl/io/m1_rom_loader.sv
SRCS_m1_decode := rtl/io/m1_decode.sv
SRCS_m1_glue := rtl/io/m1_glue.sv
SRCS_m1_tile_decode := rtl/video/m1_tile_decode.sv
SRCS_m1_tile_mixer := rtl/video/m1_tile_mixer.sv
SRCS_m1_tile_fetch := rtl/video/m1_tile_decode.sv rtl/video/m1_tile_fetch.sv
SRCS_m1_video_timing := rtl/video/m1_video_timing.sv
SRCS_m1_palette := rtl/video/m1_palette.sv
SRCS_m1_video := rtl/video/m1_tile_decode.sv rtl/video/m1_tile_fetch.sv rtl/video/m1_tile_mixer.sv rtl/video/m1_video_timing.sv rtl/video/m1_palette.sv rtl/video/m1_video.sv
SRCS_m1_loader_harness := $(SRCS_m1_rom_loader) $(SRCS_m1_sdram) $(SRCS_sdram_model) sim/io/m1_loader_harness.sv
# Top module is s32_v60; the Quartus target keys off MOD, so the .qsf needs the
# module name to match. Built standalone for area only, not integrated yet.
SRCS_s32_v60 := rtl/cpu/v60/v60_bus.sv rtl/cpu/v60/v60.sv
SRCS_m1_sdram_harness := $(SRCS_m1_sdram) $(SRCS_sdram_model) $(SRCS_bw_monitor) sim/mem/m1_sdram_harness.sv
SRCS_mb86233_core := $(RTL)/mb86233_pkg.sv $(RTL)/fp_mul.sv $(RTL)/fp_add.sv \
                     $(RTL)/fp_div.sv \
                     $(RTL)/mb86233_alu.sv $(RTL)/mb86233_agu.sv $(RTL)/mb86233_seq.sv \
                     $(RTL)/mb86233_regs.sv $(RTL)/mb86233_mem.sv $(RTL)/mb86233_dec.sv \
                     $(RTL)/mb86233_xfer.sv $(RTL)/mb86233_core.sv
SRCS_mb86233_seq := $(RTL)/mb86233_pkg.sv $(RTL)/mb86233_seq.sv

.PHONY: all lint lint_v60 test test_bw_monitor test_sdram_model test_m1_sdram test_rom_loader test_decode test_glue test_tile_decode test_tile_mixer test_tile_fetch test_video_timing test_palette test_video test_fp_mul test_fp_add test_alu test_agu test_seq test_fp_div test_regs test_mem test_dec test_xfer test_core area quartus quartus_list quartus_report clean distclean

all: test

# ---------------------------------------------------------------- simulation

lint:
	verilator --lint-only -Wall $(VFLAGS) $(RTL)/mb86233_pkg.sv $(RTL)/fp_mul.sv --top-module fp_mul
	verilator --lint-only -Wall $(VFLAGS) $(RTL)/fp_add.sv --top-module fp_add
	verilator --lint-only -Wall $(VFLAGS) $(RTL)/fp_div.sv --top-module fp_div
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_mb86233_alu) --top-module mb86233_alu
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_mb86233_agu) --top-module mb86233_agu
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_mb86233_seq) --top-module mb86233_seq
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_mb86233_regs) --top-module mb86233_regs
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_mb86233_mem) --top-module mb86233_mem
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_mb86233_dec) --top-module mb86233_dec
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_mb86233_xfer) --top-module mb86233_xfer
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_mb86233_core) --top-module mb86233_core
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_bw_monitor) --top-module bw_monitor
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_sdram_model) --top-module sdram_model
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_sdram) --top-module m1_sdram
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_rom_loader) --top-module m1_rom_loader
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_decode) --top-module m1_decode
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_glue) --top-module m1_glue
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_tile_decode) --top-module m1_tile_decode
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_tile_mixer) --top-module m1_tile_mixer
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_tile_fetch) --top-module m1_tile_fetch
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_video_timing) --top-module m1_video_timing
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_palette) --top-module m1_palette
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_video) --top-module m1_video
	$(MAKE) --no-print-directory lint_v60

# The V60 is imported from meathax/s32 and lints under a relaxed flag set.
#
# BLKSEQ is suppressed, not fixed: the source uses blocking assignments for
# default-then-override signals inside always_ff blocks that also use
# non-blocking for state. Mixing the two in one sequential block is a real
# footgun, but this code carries 22 passing directed tests and a differential
# harness against a Python reference, so rewriting 4,500 lines to satisfy a
# lint flag would risk far more than it fixes. Flagged for review before M1
# integration rather than silently accepted — see docs/m1-m4-plan.md.
lint_v60:
	verilator --lint-only -Wall $(VFLAGS) -Wno-DECLFILENAME -Wno-VARHIDDEN \
	  -Wno-BLKSEQ -Wno-CASEINCOMPLETE -Wno-SYNCASYNCNET \
	  rtl/cpu/v60/v60.sv --top-module s32_v60
	iverilog -g2012 -o /dev/null rtl/cpu/v60/v60.sv

test: test_bw_monitor test_sdram_model test_m1_sdram test_rom_loader test_decode test_glue test_tile_decode test_tile_mixer test_tile_fetch test_video_timing test_palette test_video test_fp_mul test_fp_add test_fp_div test_alu test_agu test_seq test_regs test_mem test_dec test_xfer test_core

# Built twice. The narrow build is not a smaller version of the same test: at
# the real widths a 500 k-cycle run cannot wrap a 24-bit counter or saturate an
# 8-bit burst counter, so those two paths would ship untested. Shrinking the
# parameters is the only way to reach them without a run of billions of cycles.
# The device model is a verification component, so its own tests are fault
# injection: each JEDEC rule gets a targeted violation and must report that
# rule, not merely report something.
test_sdram_model:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module sdram_model \
	  $(SRCS_sdram_model) sim/mem/tb_sdram_model.cpp -o tb_sdmodel --Mdir obj_sdmodel
	./obj_sdmodel/tb_sdmodel
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module sdram_model \
	  -GT_RC=12 $(SRCS_sdram_model) sim/mem/tb_sdram_model.cpp \
	  -CFLAGS -DTB_T_RC=12 -o tb_sdmodel_rc --Mdir obj_sdmodel_rc
	./obj_sdmodel_rc/tb_sdmodel_rc

# Data integrity and protocol compliance in one run: the shadow memory catches
# address decode and burst ordering, the device model catches the timing
# faults that simulate perfectly and then fail on real silicon.
test_m1_sdram:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_sdram_harness \
	  $(SRCS_m1_sdram_harness) sim/mem/tb_m1_sdram.cpp \
	  -o tb_m1sdram --Mdir obj_m1sdram
	./obj_m1sdram/tb_m1sdram

# Loaded against the real SDRAM controller, not a stub write port: the
# download contract is one transaction per request rising edge, and a loader
# that holds req high writes exactly one word and silently loses the ROM.
# The reference is transcribed from MAME's model1_mem independently of the RTL.
# A reference written from the DUT agrees with the DUT's bugs.
# The reference decodes pixels through MAME's byte-level bit-address formula,
# not through the RTL's word-level simplification, so a wrong simplification
# fails rather than agreeing with itself.
# Exhaustive over the whole decision space (2^13), with the reference painting
# back-to-front as MAME's eight draw() calls do while the RTL resolves
# front-to-back. Equivalent only if the order is right.
# The retained character row is the risk: skipping a refetch is most of the
# layer's bandwidth on text screens and the easiest way to emit stale pixels.
# The frame rate is what is being protected: every downstream budget derives
# from MAME's 656 x 424 at 16 MHz.
# Exhaustive over all 65536 entry values, against MAME's handler line for line.
# The integration test: every earlier video test checks one stage against MAME,
# this checks that the wired-together stages still produce MAME's picture.
test_video:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_video \
	  $(SRCS_m1_video) sim/video/tb_m1_video.cpp -o tb_video --Mdir obj_video
	./obj_video/tb_video

test_palette:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_palette \
	  $(SRCS_m1_palette) sim/video/tb_m1_palette.cpp -o tb_pal --Mdir obj_pal
	./obj_pal/tb_pal

test_video_timing:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_video_timing \
	  $(SRCS_m1_video_timing) sim/video/tb_m1_video_timing.cpp \
	  -o tb_vtiming --Mdir obj_vtiming
	./obj_vtiming/tb_vtiming

test_tile_fetch:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_tile_fetch \
	  $(SRCS_m1_tile_fetch) sim/video/tb_m1_tile_fetch.cpp \
	  -o tb_tilefetch --Mdir obj_tilefetch
	./obj_tilefetch/tb_tilefetch

test_tile_mixer:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_tile_mixer \
	  $(SRCS_m1_tile_mixer) sim/video/tb_m1_tile_mixer.cpp \
	  -o tb_tilemix --Mdir obj_tilemix
	./obj_tilemix/tb_tilemix

test_tile_decode:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_tile_decode \
	  $(SRCS_m1_tile_decode) sim/video/tb_m1_tile_decode.cpp \
	  -o tb_tiledec --Mdir obj_tiledec
	./obj_tiledec/tb_tiledec

# The interrupt mask was implemented as an enable once and nothing caught it:
# the integration program never enables an interrupt.
test_glue:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_glue \
	  $(SRCS_m1_glue) sim/io/tb_m1_glue.cpp -o tb_glue --Mdir obj_glue
	./obj_glue/tb_glue

test_decode:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_decode \
	  $(SRCS_m1_decode) sim/io/tb_m1_decode.cpp -o tb_decode --Mdir obj_decode
	./obj_decode/tb_decode

test_rom_loader:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_loader_harness \
	  $(SRCS_m1_loader_harness) sim/io/tb_m1_rom_loader.cpp \
	  -o tb_loader --Mdir obj_loader
	./obj_loader/tb_loader

test_bw_monitor:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module bw_monitor \
	  $(SRCS_bw_monitor) sim/mem/tb_bw_monitor.cpp -o tb_bwmon --Mdir obj_bwmon
	./obj_bwmon/tb_bwmon
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module bw_monitor \
	  -GCW=12 -GBW=4 $(SRCS_bw_monitor) sim/mem/tb_bw_monitor.cpp \
	  -CFLAGS "-DTB_CW=12 -DTB_BW=4" -o tb_bwmon_n --Mdir obj_bwmon_n
	./obj_bwmon_n/tb_bwmon_n

test_fp_mul:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module fp_mul \
	  $(RTL)/fp_mul.sv sim/tgp/tb_fp_mul.cpp -o tb_fp_mul --Mdir obj_fpmul
	./obj_fpmul/tb_fp_mul

test_fp_add:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module fp_add \
	  $(RTL)/fp_add.sv sim/tgp/tb_fp_add.cpp -o tb_fp_add --Mdir obj_fpadd
	./obj_fpadd/tb_fp_add

test_fp_div:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module fp_div \
	  $(RTL)/fp_div.sv sim/tgp/tb_fp_div.cpp -o tb_fp_div --Mdir obj_fpdiv
	./obj_fpdiv/tb_fp_div

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

test_regs:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module mb86233_regs \
	  $(SRCS_mb86233_regs) sim/tgp/tb_mb86233_regs.cpp -o tb_regs --Mdir obj_regs
	./obj_regs/tb_regs

test_mem:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module mb86233_mem \
	  $(SRCS_mb86233_mem) sim/tgp/tb_mb86233_mem.cpp -o tb_mem --Mdir obj_mem
	./obj_mem/tb_mem

test_dec:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module mb86233_dec \
	  $(SRCS_mb86233_dec) sim/tgp/tb_mb86233_dec.cpp -o tb_dec --Mdir obj_dec
	./obj_dec/tb_dec

test_xfer:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module mb86233_xfer \
	  $(SRCS_mb86233_xfer) sim/tgp/tb_mb86233_xfer.cpp -o tb_xfer --Mdir obj_xfer
	./obj_xfer/tb_xfer

test_core:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module mb86233_core \
	  $(SRCS_mb86233_core) sim/tgp/tb_mb86233_core.cpp sim/tgp/mb86233_ref.cpp \
	  -CFLAGS -Isim/tgp -o tb_core --Mdir obj_core
	./obj_core/tb_core

# Proxy only: generic 6-LUT mapping, no DSP inference, no device model.
# Useful for tracking relative change between edits. Does not settle the M0 gate.
# The stat block must be isolated with awk before grepping: yosys logs
# "Executing OPT_DFF pass" lines to stdout during synth, and a bare grep for
# DFF matches those first, so head consumes log noise and no numbers ever
# appear. Anchoring on "Printing statistics" is what makes this report real.
AREA_MODULES := bw_monitor m1_sdram m1_rom_loader m1_decode m1_glue m1_tile_decode m1_tile_mixer m1_tile_fetch m1_video_timing m1_palette m1_video fp_mul fp_add fp_div mb86233_alu mb86233_agu mb86233_seq mb86233_regs mb86233_mem mb86233_dec mb86233_xfer mb86233_core

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
#   make quartus MOD=fp_add              17.0, the reference toolchain
#   make quartus MOD=fp_add QUARTUS=24.1 pick a different one explicitly
#
# Auto-detects ~/intelFPGA*/<ver>/quartus/bin so the flow works without
# exporting PATH by hand.
#
# 17.0 IS THE DEFAULT, DELIBERATELY. The previous default was "newest install
# found", which silently selected 24.1std once that was installed alongside —
# so reports drifted between toolchains without anyone choosing it. 17.0.x is
# the version this project targets, so it is what gets picked unless a
# different one is named. If it is missing the build falls back to the newest
# and says so, rather than failing.
QUARTUS ?= 17.0
QUARTUS_ROOTS := $(wildcard $(HOME)/intelFPGA_lite/*/quartus/bin $(HOME)/intelFPGA/*/quartus/bin /opt/intelFPGA_lite/*/quartus/bin /opt/intelFPGA/*/quartus/bin)
QUARTUS_MATCH := $(firstword $(foreach d,$(QUARTUS_ROOTS),$(if $(findstring /$(QUARTUS)/,$(d)),$(d))))
ifeq ($(QUARTUS_MATCH),)
  QUARTUS_BIN := $(lastword $(sort $(QUARTUS_ROOTS)))
  QUARTUS_FELLBACK := 1
else
  QUARTUS_BIN := $(QUARTUS_MATCH)
endif

.PHONY: quartus_list quartus_paths v60_cpi m1_main
# Optimisation target. Every figure so far was taken at Aggressive Performance,
# so that stays the default and the numbers remain comparable. An area question
# wants QOPT="Aggressive Area" — for combinational-heavy designs the two differ
# by enough that quoting one without saying which is misleading.
QOPT ?= Aggressive Performance

# Preprocessor defines passed to synthesis, e.g. QDEFS=S32_V60_NO_FP=1 to build
# the V60 without its floating-point group.
QDEFS ?=

# V60 cycles-per-instruction against memory latency. Not part of `make test`:
# it builds the CPU a dozen times and takes minutes.
# V60 executing out of SDRAM through the loader, decode and controller. Not in
# `make test`: it builds the CPU twice and takes a couple of minutes.
m1_main:
	@bash tools/run_m1_main.sh

v60_cpi:
	@bash tools/v60_cpi_sweep.sh

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
	@test -z "$(QUARTUS_FELLBACK)" || echo "WARNING: Quartus $(QUARTUS) not found, fell back to $(QUARTUS_BIN). Reports will not match the reference toolchain." 
	@mkdir -p $(QDIR)
	@srcs=""; for f in $(SRCS_$(MOD)); do \
	  srcs="$$srcs\nset_global_assignment -name SYSTEMVERILOG_FILE ../../../$$f"; done; \
	  defs=""; for d in $(QDEFS); do \
	    defs="$$defs\nset_global_assignment -name VERILOG_MACRO \"$$d\""; done; \
	  sed -e 's/@MODULE@/$(MOD)/g' -e 's|@QOPT@|$(QOPT)|' -e "s|@DEFS@|$$defs|" -e "s|@SRCS@|$$srcs|" quartus/spike.qsf.in > $(QDIR)/$(MOD).qsf
	@cp quartus/spike.sdc $(QDIR)/spike.sdc
	@echo "PROJECT_REVISION = \"$(MOD)\"" > $(QDIR)/$(MOD).qpf
	cd $(QDIR) && PATH="$(QUARTUS_BIN):$$PATH" sh -c 'quartus_map $(MOD) && quartus_fit $(MOD) && quartus_sta $(MOD)'

# Where the critical path actually is. The STA summary reports slack and not
# endpoints, so this is what makes a retime targeted rather than speculative.
quartus_paths:
	@test -d $(QDIR) || { echo "run 'make quartus MOD=$(MOD)' first"; exit 1; }
	@cd $(QDIR) && PATH="$(QUARTUS_BIN):$$PATH" \
	  quartus_sta -t ../../report_timing.tcl $(MOD) 2>&1 \
	  | grep -vE '^Info \(1[0-9]{4}\)|^ *Info: (Copyright|Your use|and other|including|associated|to the terms|refer to|the sole|Altera|manufactured|programming|functions)' \
	  | sed -n '/Path #/,$$p' | head -60
	@$(MAKE) --no-print-directory quartus_report MOD=$(MOD)

quartus_report:
	@cd quartus && ./report.sh $(MOD)

clean:
	rm -rf obj_bwmon obj_fpmul obj_fpadd obj_fpdiv obj_alu obj_agu obj_seq obj_regs obj_mem obj_dec obj_xfer obj_core

distclean: clean
	rm -rf quartus/build
