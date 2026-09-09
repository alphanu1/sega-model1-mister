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

# EVERY TEMPORARY LANDS IN THIS PROJECT'S build/, NEVER IN /tmp.
#
# /tmp here is a quota'd tmpfs, and it is not the filesystem size: `df` reports
# gigabytes free while writes return EDQUOT. Two ways that bites, both measured
# on 2026-08-20:
#
#   * g++ writes assembler temporaries there, so a Verilator build dies partway
#     with "fatal error: error writing to /tmp/ccXXXX.s: Disk quota exceeded"
#   * Quartus and MAME put working files there too
#
# Exported, not passed per-target, so it cannot be forgotten. The directory is
# created by the targets that need it; `mkdir -p` costs nothing when it exists.
export TMPDIR := $(CURDIR)/build/tmp
$(shell mkdir -p $(CURDIR)/build/tmp)

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
SRCS_m1_cdc_port := rtl/mem/m1_cdc_port.sv
SRCS_m1_cdc_pulse := rtl/mem/m1_cdc_pulse.sv
# Everything the top level instantiates below emu, in dependency order.
SRCS_TOP_CORE = rtl/mem/m1_sdram.sv rtl/mem/m1_cdc_port.sv \
  rtl/mem/m1_cdc_pulse.sv rtl/mem/m1_fetch_bridge.sv rtl/mem/bw_monitor.sv \
  rtl/io/m1_decode.sv rtl/io/m1_glue.sv rtl/io/m1_ioboard.sv rtl/cpu/tv80/tv80_alu.v rtl/cpu/tv80/tv80_reg.v rtl/cpu/tv80/tv80_mcode.v rtl/cpu/tv80/tv80_core.v rtl/cpu/tv80/tv80s.v rtl/io/m1_ioz80.sv rtl/tgp/m1_copro_if.sv \
  rtl/tgp/m1_tgp.sv $(SRCS_mb86233_core) \
  rtl/io/m1_rom_loader.sv rtl/io/m1_speed_report.sv rtl/io/m1_uart_tx.sv \
  rtl/video/m1_tile_decode.sv rtl/video/m1_tile_fetch.sv \
  rtl/video/m1_tile_mixer.sv rtl/video/m1_video_timing.sv \
  rtl/video/m1_palette.sv rtl/video/m1_video.sv rtl/video/m1_diag.sv \
  rtl/video/m1_listctl.sv \
  rtl/mem/m1_tdp_ram.sv rtl/m1_mainram.sv $(SRCS_3D) \
  rtl/m1_main.sv rtl/m1_integrated.sv \
  rtl/cpu/v60/v60_bus.sv rtl/cpu/v60/v60.sv rtl/cpu/v60/v60_fp.sv rtl/cpu/v60/v60_ifetch.sv rtl/cpu/v60/v60_alu.sv rtl/cpu/v60/v60_shift.sv

# THE 3D LAYER IS PART OF m1_integrated, so every bench that elaborates it needs
# these. `make m1_frame` had been failing at elaboration with
# "Cannot find file containing module: 'm1_raster3d'" since the layer was wired
# in - the error names the instantiating file, not the missing source, so it
# reads as a fault in m1_integrated.
#
# WITHOUT fp_mul/fp_add/fp_div: SRCS_mb86233_core already carries them, and
# Verilator rejects the duplicate module rather than ignoring it.
SRCS_3D = rtl/video/m1_geometry.sv rtl/video/m1_geo_walk.sv rtl/video/m1_geo_clip.sv rtl/video/m1_geo_planes.sv \
  rtl/video/m1_geo_xform.sv rtl/video/m1_geo_project.sv rtl/video/m1_geo_recip.sv \
  rtl/video/m1_geo_det.sv rtl/video/m1_geo_norm.sv \
  rtl/video/m1_geo_rsqrt.sv rtl/video/m1_geo_color.sv \
  rtl/video/m1_fp_pool.sv rtl/video/fp_to_int.sv rtl/video/fp_from_int.sv \
  rtl/video/m1_lightbank.sv rtl/video/m1_listwalk.sv \
  rtl/video/m1_quad_store.sv rtl/video/m1_recip_rom.sv rtl/video/m1_raster_div.sv \
  rtl/video/m1_raster_fill.sv rtl/video/m1_raster_band.sv \
  rtl/video/m1_raster3d.sv
SRCS_m1_fetch_bridge := rtl/mem/m1_cdc_port.sv rtl/mem/m1_fetch_bridge.sv
SRCS_m1_rom_loader := rtl/io/m1_rom_loader.sv
SRCS_m1_decode := rtl/io/m1_decode.sv
SRCS_m1_glue := rtl/io/m1_glue.sv
SRCS_m1_ioboard := rtl/io/m1_ioboard.sv
SRCS_m1_uart_tx := rtl/io/m1_uart_tx.sv
SRCS_m1_copro_if := rtl/tgp/m1_copro_if.sv
# Deferred (=), not immediate (:=): SRCS_mb86233_core is defined further down,
# and := would expand it to nothing here.
SRCS_m1_tgp = rtl/tgp/m1_tgp.sv $(SRCS_mb86233_core)
# Standalone, for settling M10K INFERENCE on the band memory in seconds rather
# than after a 25-minute full build. CLAUDE.md: "Block RAM inference is silent
# when it fails. Quartus builds memories out of flip-flops and keeps going -
# that cost 28,816 ALM once."
#
# It earned its keep immediately: a clear-on-readout scheme, which would have
# removed a full-screen wipe per frame from the 3D path, turns the buffer into a
# dual-CLOCK true-dual-port RAM, and Quartus 17.0 will not infer that. Six
# seconds to find out, with Error (276003), instead of a full build.
#   make quartus MOD=m1_raster_band
SRCS_m1_raster_band := rtl/video/m1_raster_band.sv

SRCS_m1_mainram := rtl/mem/m1_tdp_ram.sv rtl/m1_mainram.sv
# Everything built so far as one design, for an integrated area figure. Not the
# core: no framework, no clocking, no I/O board, no TGP.
SRCS_m1_integrated := rtl/cpu/v60/v60_bus.sv rtl/cpu/v60/v60.sv rtl/cpu/v60/v60_fp.sv rtl/cpu/v60/v60_ifetch.sv rtl/cpu/v60/v60_alu.sv rtl/cpu/v60/v60_shift.sv \
  rtl/io/m1_decode.sv rtl/io/m1_glue.sv rtl/io/m1_rom_loader.sv \
  rtl/io/m1_ioboard.sv rtl/cpu/tv80/tv80_alu.v rtl/cpu/tv80/tv80_reg.v rtl/cpu/tv80/tv80_mcode.v rtl/cpu/tv80/tv80_core.v rtl/cpu/tv80/tv80s.v rtl/io/m1_ioz80.sv rtl/tgp/m1_copro_if.sv rtl/mem/bw_monitor.sv \
  rtl/mem/m1_cdc_port.sv rtl/mem/m1_cdc_pulse.sv rtl/mem/m1_fetch_bridge.sv rtl/video/m1_tile_decode.sv rtl/video/m1_tile_fetch.sv \
  rtl/video/m1_tile_mixer.sv rtl/video/m1_video_timing.sv \
  rtl/video/m1_palette.sv rtl/video/m1_video.sv rtl/mem/m1_tdp_ram.sv rtl/m1_mainram.sv \
  rtl/video/m1_listctl.sv \
  rtl/video/fp_to_int.sv rtl/video/fp_from_int.sv rtl/video/m1_fp_pool.sv \
  rtl/video/m1_geo_xform.sv rtl/video/m1_geo_project.sv rtl/video/m1_geo_recip.sv rtl/video/m1_geo_det.sv \
  rtl/video/m1_geo_rsqrt.sv rtl/video/m1_geo_norm.sv rtl/video/m1_geo_color.sv \
  rtl/video/m1_geo_walk.sv rtl/video/m1_geo_clip.sv rtl/video/m1_geo_planes.sv rtl/video/m1_geometry.sv rtl/video/m1_lightbank.sv \
  rtl/video/m1_listwalk.sv rtl/video/m1_quad_store.sv rtl/video/m1_recip_rom.sv rtl/video/m1_raster_div.sv \
  rtl/video/m1_raster_fill.sv rtl/video/m1_raster_band.sv rtl/video/m1_raster3d.sv \
  $(RTL)/fp_mul.sv $(RTL)/fp_add.sv $(RTL)/fp_div.sv \
  rtl/m1_main.sv rtl/m1_integrated.sv
SRCS_m1_tile_decode := rtl/video/m1_tile_decode.sv
SRCS_m1_tile_mixer := rtl/video/m1_tile_mixer.sv
SRCS_m1_tile_fetch := rtl/video/m1_tile_decode.sv rtl/video/m1_tile_fetch.sv
SRCS_m1_video_timing := rtl/video/m1_video_timing.sv
SRCS_m1_palette := rtl/video/m1_palette.sv
SRCS_m1_diag := rtl/video/m1_diag.sv
SRCS_m1_listctl := rtl/video/m1_listctl.sv
SRCS_m1_video := rtl/video/m1_tile_decode.sv rtl/video/m1_tile_fetch.sv rtl/video/m1_tile_mixer.sv rtl/video/m1_video_timing.sv rtl/video/m1_palette.sv rtl/video/m1_video.sv
# For `make quartus MOD=m1_quad_store` - the store is 91 M10K of the design's
# 501 and its packing is worth watching on its own, even though the standalone
# figure never predicts the in-core one.
SRCS_m1_geo_clip := rtl/video/m1_geo_clip.sv
SRCS_m1_quad_store := rtl/video/m1_quad_store.sv
SRCS_m1_raster_div := rtl/video/m1_recip_rom.sv rtl/video/m1_raster_div.sv
SRCS_m1_raster_fill := rtl/video/m1_recip_rom.sv rtl/video/m1_raster_div.sv rtl/video/m1_raster_fill.sv
GEO_SRCS := rtl/video/m1_geometry.sv rtl/video/m1_geo_walk.sv rtl/video/m1_geo_clip.sv rtl/video/m1_geo_planes.sv \
            rtl/video/m1_geo_xform.sv rtl/video/m1_geo_project.sv rtl/video/m1_geo_recip.sv \
            rtl/video/m1_geo_det.sv rtl/video/m1_geo_norm.sv \
            rtl/video/m1_geo_rsqrt.sv rtl/video/m1_geo_color.sv \
            rtl/video/m1_fp_pool.sv rtl/video/fp_to_int.sv \
            $(RTL)/fp_mul.sv $(RTL)/fp_add.sv $(RTL)/fp_div.sv

SRCS_m1_geo_xform   := rtl/video/m1_geo_xform.sv
SRCS_m1_geo_project := rtl/video/fp_to_int.sv rtl/video/m1_geo_project.sv rtl/video/m1_geo_recip.sv
SRCS_m1_geo_det     := rtl/video/m1_geo_det.sv
SRCS_m1_fp_pool     := $(RTL)/fp_mul.sv $(RTL)/fp_add.sv $(RTL)/fp_div.sv \
                       rtl/video/m1_fp_pool.sv
SRCS_m1_geometry    := $(GEO_SRCS)
SRCS_m1_geo_norm    := rtl/video/m1_geo_norm.sv rtl/video/m1_geo_rsqrt.sv
SRCS_m1_geo_color   := rtl/video/m1_geo_color.sv rtl/video/fp_to_int.sv
SRCS_m1_listwalk    := rtl/video/m1_listwalk.sv
SRCS_m1_loader_harness := $(SRCS_m1_rom_loader) $(SRCS_m1_sdram) $(SRCS_sdram_model) sim/io/m1_loader_harness.sv
# Top module is s32_v60; the Quartus target keys off MOD, so the .qsf needs the
# module name to match. Built standalone for area only, not integrated yet.
SRCS_s32_v60 := rtl/cpu/v60/v60_bus.sv rtl/cpu/v60/v60.sv rtl/cpu/v60/v60_fp.sv rtl/cpu/v60/v60_ifetch.sv rtl/cpu/v60/v60_alu.sv rtl/cpu/v60/v60_shift.sv
SRCS_m1_sdram_harness := $(SRCS_m1_sdram) $(SRCS_sdram_model) $(SRCS_bw_monitor) sim/mem/m1_sdram_harness.sv
SRCS_mb86233_core := $(RTL)/mb86233_pkg.sv $(RTL)/fp_mul.sv $(RTL)/fp_add.sv \
                     $(RTL)/fp_div.sv \
                     $(RTL)/mb86233_alu.sv $(RTL)/mb86233_agu.sv $(RTL)/mb86233_seq.sv \
                     $(RTL)/mb86233_regs.sv $(RTL)/mb86233_mem.sv $(RTL)/mb86233_dec.sv \
                     $(RTL)/mb86233_xfer.sv $(RTL)/mb86233_core.sv
SRCS_mb86233_seq := $(RTL)/mb86233_pkg.sv $(RTL)/mb86233_seq.sv

.PHONY: all lint lint_v60 lint_top test m1_tgp test_bw_monitor test_sdram_model test_m1_sdram test_cdc_port test_cdc_pulse test_fetch_bridge test_rom_loader test_decode test_glue test_ioboard test_uart_tx test_speed_report test_copro_if test_tile_decode test_tile_mixer test_tile_fetch test_video_timing test_listctl test_palette test_diag test_video test_raster_fill test_fp_mul test_fp_add test_alu test_agu test_seq test_fp_div test_regs test_mem test_dec test_xfer test_core area quartus quartus_list quartus_report clean distclean v60_trace tgp_trace tgp_wrtrace

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
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_cdc_port) --top-module m1_cdc_port
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_cdc_pulse) --top-module m1_cdc_pulse
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_fetch_bridge) --top-module m1_fetch_bridge
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_rom_loader) --top-module m1_rom_loader
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_decode) --top-module m1_decode
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_glue) --top-module m1_glue
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_ioboard) --top-module m1_ioboard
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_uart_tx) --top-module m1_uart_tx
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_tile_decode) --top-module m1_tile_decode
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_tile_mixer) --top-module m1_tile_mixer
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_tile_fetch) --top-module m1_tile_fetch
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_video_timing) --top-module m1_video_timing
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_palette) --top-module m1_palette
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_diag) --top-module m1_diag
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_listctl) --top-module m1_listctl
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_video) --top-module m1_video
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_raster_div) --top-module m1_raster_div
	verilator --lint-only -Wall $(VFLAGS) $(SRCS_m1_raster_fill) --top-module m1_raster_fill
	$(MAKE) --no-print-directory lint_v60

# The MiSTer top level, checked against the real framework rather than in
# isolation — that is what catches a port-name or width mistake in the hps_io
# and emu_ports interfaces, which nothing else here would see until a Quartus
# build failed twenty minutes in.
#
# altera_pll is a device primitive and is the ONE module expected to be missing;
# Verilator cannot elaborate it and nothing simulates m1_pll. build_id.v is
# generated by Quartus at build time, so a stub stands in for it here.
#
# Needs third_party/, so it is not part of `make lint`.
#
# TWO CLASSES OF WIDTH WARNING FAIL THIS, NOT JUST ERRORS.
#
# This grepped for %Error alone and discarded every warning, which is how a
# debug-overlay port declared for 19 words but wired with only 15 passed as
# clean: a short pin connection is a WIDTHEXPAND warning, not an error. Four
# overlay rows read 00000000 on hardware and the fault was chased into the
# bitstream instead of the wiring. In the same file two rows were built 40 bits
# wide and assigned to 32, and Verilog truncation drops the HIGH bits — so those
# rows lost their own row tags and rendered under the wrong number.
#
# Both are caught, and only those two:
#
#   port connection   a module instantiated with a mis-sized connection
#   ASSIGNW           a continuous assignment whose RHS does not fit the LHS
#
# NOT all width warnings. `make lint` waives WIDTHEXPAND/WIDTHTRUNC project-wide
# and there are around fifty across rtl/, most of them in the imported V60, which
# lints under a deliberately relaxed flag set. Failing on all of them would mean
# either a large rewrite of working CPU code or — far more likely — someone
# switching the check back off. A check with no backlog is one that stays on.
#
# third_party/ is excluded: hps_io.sv has a dozen of its own and they are not
# ours to fix. Errors are still fatal wherever they come from.
lint_top:
	@mkdir -p build/lintinc
	@echo '`define BUILD_DATE "000000"' > build/lintinc/build_id.v
	@test -f third_party/template/sys/emu_ports.vh || { \
	  echo "third_party/template missing — run ./tools/bootstrap.sh"; exit 1; }
	@verilator --lint-only -Wno-fatal +incdir+third_party/template \
	  +incdir+build/lintinc --top-module emu \
	  Model1.sv $(SRCS_TOP_CORE) \
	  third_party/template/sys/hps_io.sv > build/lintinc/top.log 2>&1; \
	 grep "%Error" build/lintinc/top.log | grep -vE "altera_pll|'pll'" \
	   | grep -v "Exiting due to" > build/lintinc/real.log; \
	 grep "%Warning-WIDTH" build/lintinc/top.log \
	   | grep -vE "%Warning-WIDTH[A-Z]*: third_party/" \
	   | grep -E "port connection|ASSIGNW" >> build/lintinc/real.log; \
	 if [ -s build/lintinc/real.log ]; then cat build/lintinc/real.log; exit 1; \
	 else echo "lint_top: clean (only altera_pll unresolved, as expected)"; fi

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
	  rtl/cpu/v60/v60.sv rtl/cpu/v60/v60_fp.sv rtl/cpu/v60/v60_ifetch.sv rtl/cpu/v60/v60_alu.sv rtl/cpu/v60/v60_shift.sv --top-module s32_v60
	iverilog -g2012 -o /dev/null rtl/cpu/v60/v60.sv rtl/cpu/v60/v60_fp.sv rtl/cpu/v60/v60_ifetch.sv rtl/cpu/v60/v60_alu.sv rtl/cpu/v60/v60_shift.sv

test: test_v60_alu test_v60_shift test_bw_monitor test_sdram_model test_m1_sdram test_cdc_port test_cdc_pulse test_fetch_bridge test_rom_loader test_decode test_glue test_ioboard test_uart_tx test_speed_report test_copro_if test_tile_decode test_tile_mixer test_tile_fetch test_video_timing test_listctl test_palette test_diag test_video test_raster_fill test_fp_mul test_fp_add test_fp_div test_alu test_agu test_seq test_regs test_mem test_dec test_xfer test_core test_v60_in_mem test_raster_band test_listwalk test_geo_xform test_fp_to_int test_geo_project test_geo_det test_geo_rsqrt test_geo_recip test_geo_color test_geo_norm test_geo_clip test_geo_planes test_geometry test_quad_store test_lightbank

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

# ~15 s and the longest single test here, which is the price of comparing 31 M
# spans rather than a painted bitmap. An extra or duplicated span fails even
# where it would paint identical pixels, and that is the class of bug — the
# half-open segment range, the per-segment left/right decision — that a bitmap
# comparison cannot see.
# The band buffer: spans in, pixels out, compared against a C model of the same
# rules after every span - so an extra write anywhere is caught, not just a wrong
# one on the span just sent.
test_raster_band:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_raster_band \
	  rtl/video/m1_raster_band.sv sim/video/tb_m1_raster_band.cpp -o tb_raster_band --Mdir obj_raster_band
	./obj_raster_band/tb_raster_band

render3d:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_raster3d \
	  -Irtl/tgp -Irtl/video $(GEO_SRCS) rtl/video/m1_raster3d.sv \
	  rtl/video/fp_from_int.sv rtl/video/m1_lightbank.sv \
	  rtl/video/m1_listwalk.sv rtl/video/m1_quad_store.sv \
	  $(SRCS_m1_raster_fill) rtl/video/m1_raster_band.sv \
	  sim/video/tb_m1_raster3d.cpp -o tb_render3d --Mdir obj_render3d
	./obj_render3d/tb_render3d

render:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_render_top \
	  -Irtl/tgp -Irtl/video $(GEO_SRCS) $(SRCS_m1_raster_fill) sim/video/render_top.sv \
	  sim/video/tb_m1_render.cpp -o tb_render --Mdir obj_render
	./obj_render/tb_render

test_lightbank:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_lightbank \
	  rtl/video/m1_lightbank.sv sim/video/tb_m1_lightbank.cpp \
	  -o tb_lightbank --Mdir obj_lightbank
	./obj_lightbank/tb_lightbank

test_quad_store:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_quad_store \
	  rtl/video/m1_quad_store.sv sim/video/tb_m1_quad_store.cpp \
	  -o tb_quad_store --Mdir obj_quad_store
	./obj_quad_store/tb_quad_store

test_geo_clip:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module tb_clip_top \
	  -Irtl/tgp -Irtl/video sim/video/tb_clip_top.sv rtl/video/m1_geo_clip.sv \
	  rtl/video/m1_geo_project.sv rtl/video/m1_geo_recip.sv rtl/video/m1_fp_pool.sv rtl/video/fp_to_int.sv \
	  $(RTL)/fp_mul.sv $(RTL)/fp_add.sv $(RTL)/fp_div.sv \
	  sim/video/tb_m1_geo_clip.cpp -o tb_geoclip --Mdir obj_geoclip
	./obj_geoclip/tb_geoclip

test_geometry:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_geometry \
	  -Irtl/tgp -Irtl/video $(GEO_SRCS) \
	  sim/video/tb_m1_geometry.cpp -o tb_geometry --Mdir obj_geometry
	./obj_geometry/tb_geometry

test_geo_norm:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_geo_norm_top \
	  -Irtl/tgp -Irtl/video rtl/video/m1_geo_norm.sv rtl/video/m1_geo_rsqrt.sv \
	  rtl/video/m1_fp_pool.sv rtl/tgp/fp_mul.sv rtl/tgp/fp_add.sv rtl/tgp/fp_div.sv \
	  sim/video/geo_wrappers.sv \
	  sim/video/tb_m1_geo_norm.cpp -o tb_geo_norm --Mdir obj_geo_norm
	./obj_geo_norm/tb_geo_norm

test_geo_color:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_geo_color_top \
	  -Irtl/tgp -Irtl/video rtl/video/m1_geo_color.sv rtl/video/fp_to_int.sv \
	  rtl/video/m1_fp_pool.sv rtl/tgp/fp_mul.sv rtl/tgp/fp_add.sv rtl/tgp/fp_div.sv \
	  sim/video/geo_wrappers.sv \
	  sim/video/tb_m1_geo_color.cpp -o tb_geo_color --Mdir obj_geo_color
	./obj_geo_color/tb_geo_color

test_geo_recip:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_geo_recip_top \
	  -Irtl/tgp -Irtl/video rtl/video/m1_geo_recip.sv sim/video/geo_wrappers.sv \
	  sim/video/tb_m1_geo_recip.cpp -o tb_geo_recip --Mdir obj_geo_recip
	./obj_geo_recip/tb_geo_recip

test_geo_rsqrt:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_geo_rsqrt_top \
	  -Irtl/tgp -Irtl/video rtl/video/m1_geo_rsqrt.sv \
	  rtl/tgp/fp_mul.sv rtl/tgp/fp_add.sv rtl/tgp/fp_div.sv sim/video/geo_wrappers.sv \
	  sim/video/tb_m1_geo_rsqrt.cpp -o tb_geo_rsqrt --Mdir obj_geo_rsqrt
	./obj_geo_rsqrt/tb_geo_rsqrt

test_geo_planes:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_geo_planes_top \
	  -Irtl/tgp -Irtl/video rtl/video/m1_geo_planes.sv rtl/video/m1_fp_pool.sv \
	  rtl/tgp/fp_mul.sv rtl/tgp/fp_add.sv rtl/tgp/fp_div.sv sim/video/geo_wrappers.sv \
	  sim/video/tb_m1_geo_planes.cpp -o tb_geo_planes --Mdir obj_geo_planes
	./obj_geo_planes/tb_geo_planes

test_geo_det:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_geo_det_top \
	  -Irtl/tgp -Irtl/video rtl/video/m1_geo_det.sv rtl/video/m1_fp_pool.sv \
	  rtl/tgp/fp_mul.sv rtl/tgp/fp_add.sv rtl/tgp/fp_div.sv sim/video/geo_wrappers.sv \
	  sim/video/tb_m1_geo_det.cpp -o tb_geo_det --Mdir obj_geo_det
	./obj_geo_det/tb_geo_det

test_geo_project:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_geo_project_top \
	  -Irtl/tgp -Irtl/video rtl/video/m1_geo_project.sv rtl/video/m1_geo_recip.sv rtl/video/fp_to_int.sv \
	  rtl/video/m1_fp_pool.sv rtl/tgp/fp_mul.sv rtl/tgp/fp_add.sv rtl/tgp/fp_div.sv \
	  sim/video/geo_wrappers.sv \
	  sim/video/tb_m1_geo_project.cpp -o tb_geo_project --Mdir obj_geo_project
	./obj_geo_project/tb_geo_project

test_fp_from_int:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module fp_from_int \
	  rtl/video/fp_from_int.sv sim/video/tb_fp_from_int.cpp \
	  -o tb_fp_from_int --Mdir obj_fp_from_int
	./obj_fp_from_int/tb_fp_from_int

test_fp_to_int:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module fp_to_int \
	  rtl/video/fp_to_int.sv sim/video/tb_fp_to_int.cpp -o tb_fp_to_int --Mdir obj_fp_to_int
	./obj_fp_to_int/tb_fp_to_int

test_geo_xform:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_geo_xform_top \
	  -Irtl/tgp rtl/video/m1_geo_xform.sv rtl/video/m1_fp_pool.sv \
	  rtl/tgp/fp_mul.sv rtl/tgp/fp_add.sv rtl/tgp/fp_div.sv sim/video/geo_wrappers.sv \
	  sim/video/tb_m1_geo_xform.cpp -o tb_geo_xform --Mdir obj_geo_xform
	./obj_geo_xform/tb_geo_xform

test_listwalk:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_listwalk \
	  rtl/video/m1_listwalk.sv sim/video/tb_m1_listwalk.cpp -o tb_listwalk --Mdir obj_listwalk
	./obj_listwalk/tb_listwalk

test_raster_fill:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_raster_fill \
	  $(SRCS_m1_raster_fill) sim/video/tb_m1_raster_fill.cpp \
	  -o tb_raster --Mdir obj_raster
	./obj_raster/tb_raster

test_palette:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_palette \
	  $(SRCS_m1_palette) sim/video/tb_m1_palette.cpp -o tb_pal --Mdir obj_pal
	./obj_pal/tb_pal

# Built TWICE, at 12 words and at 24. The row index is only as wide as NWORDS
# needs, so a build at or below sixteen rows cannot reach the truncation that
# made words 16+ alias onto rows 0-2 — the twelve-word build passed with seven
# of the real instrument's nineteen rows wrong. 24 is what the top level
# instantiates; keep them equal.
test_diag:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_diag \
	  -GNWORDS=12 -CFLAGS -DNWORDS_CFG=12 \
	  $(SRCS_m1_diag) sim/video/tb_m1_diag.cpp -o tb_diag --Mdir obj_diag
	./obj_diag/tb_diag
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_diag \
	  -GNWORDS=24 -CFLAGS -DNWORDS_CFG=24 \
	  $(SRCS_m1_diag) sim/video/tb_m1_diag.cpp -o tb_diag24 --Mdir obj_diag24
	./obj_diag24/tb_diag24

# The display-list control register. Its own module and suite because it is not a
# plain latch — the video hardware maintains bit 6 — and because it had no read
# handler at all until v60_trace found the game testing that bit.
test_listctl:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_listctl \
	  $(SRCS_m1_listctl) sim/video/tb_m1_listctl.cpp -o tb_listctl --Mdir obj_listctl
	./obj_listctl/tb_listctl

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

# No MAME oracle: MAME runs the real Z80. The reference is the protocol the
# boot trace established, tested as properties — including the two that have
# already gone wrong for real, a second handshake with a different code and a
# poll being mistaken for a request.
# The coprocessor on REAL microcode. Outside `make test` because it needs
# 315-5573.bin extracted, the same way m1_boot needs a ROM image:
#   python3 tools/build_tgp_rom.py vr ~/roms/vr ~/roms/vr.zip -o build/rom
# BUILT WITH EMPTY_FIFO_READS_ZERO=1, which is NOT the hardware default.
# The zero-on-empty behaviour is what MAME does and what the microcode's idle
# dispatch needs, so it is what this suite verifies. It is off in the shipped
# build because it deadlocks against our too-slow V60 - see the parameter's
# comment in m1_tgp.sv. Flip both when the V60 keeps up.
m1_tgp:
	verilator --cc --exe --build -O2 -Wno-fatal $(VFLAGS) --top-module m1_tgp \
	  -GEMPTY_FIFO_READS_ZERO=1 \
	  -CFLAGS "-O2 -std=c++17" \
	  $(SRCS_m1_tgp) sim/tgp/tb_m1_tgp.cpp -o tb_m1_tgp --Mdir obj_m1_tgp
	./obj_m1_tgp/tb_m1_tgp

test_copro_if:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_copro_if \
	  -CFLAGS "-O2 -std=c++17" \
	  $(SRCS_m1_copro_if) sim/tgp/tb_m1_copro_if.cpp -o tb_copro_if \
	  --Mdir obj_copro_if
	./obj_copro_if/tb_copro_if

# BUILT TWICE, at LATENCY 64 and at the measured 881,760 — the same reason
# bw_monitor and m1_diag are built twice. The narrow build cannot reach the 20-bit
# deadline counter the real figure needs, and it cannot express the property the
# measurement establishes at all: a doorbell arriving every 333,913 cycles only
# outruns a deadline that is longer than that. Keep -GLATENCY and -DLATENCY_CFG
# equal, and keep the wide one equal to the module's default.
test_ioboard:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_ioboard \
	  -GPUBLISH_INPUTS=0 -GLATENCY=64 -CFLAGS -DLATENCY_CFG=64 \
	  $(SRCS_m1_ioboard) sim/io/tb_m1_ioboard.cpp -o tb_ioboard --Mdir obj_ioboard
	./obj_ioboard/tb_ioboard
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_ioboard \
	  -GPUBLISH_INPUTS=0 -GLATENCY=907694 -CFLAGS -DLATENCY_CFG=907694 \
	  $(SRCS_m1_ioboard) sim/io/tb_m1_ioboard.cpp -o tb_ioboard_slow \
	  --Mdir obj_ioboard_slow
	./obj_ioboard_slow/tb_ioboard_slow
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_ioboard \
	  -GPUBLISH_INPUTS=1 -GLATENCY=64 -CFLAGS -DLATENCY_CFG=64 \
	  $(SRCS_m1_ioboard) sim/io/tb_m1_iopublish.cpp -o tb_iopublish \
	  --Mdir obj_iopublish
	./obj_iopublish/tb_iopublish

# WIRED IN LATE. This module and its testbench were written during the UART
# investigation and never given a target, so `make test` did not run them and
# `make lint` did not see them — while CLAUDE.md's baseline listed their results
# as though it had. An untested module that looks tested is the worst of the three
# states, so the target exists even though nothing instantiates m1_uart_tx yet.
test_uart_tx:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_uart_tx \
	  $(SRCS_m1_uart_tx) sim/io/tb_m1_uart_tx.cpp -o tb_uart_tx --Mdir obj_uart_tx
	./obj_uart_tx/tb_uart_tx

# The telemetry line, decoded off the serial pin. Built at a small CLK_HZ and
# BAUD so a bit is ten cycles - at the real 80 MHz a line is 1.3 M cycles and
# the decode says nothing extra. PERIOD 2 so a report comes out promptly.
test_speed_report:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_speed_report \
	  -GCLK_HZ=11520 -GBAUD=1152 -GPERIOD=2 \
	  rtl/io/m1_uart_tx.sv rtl/io/m1_speed_report.sv \
	  sim/io/tb_m1_speed_report.cpp -o tb_speed_report --Mdir obj_speed_report
	./obj_speed_report/tb_speed_report

test_decode:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_decode \
	  $(SRCS_m1_decode) sim/io/tb_m1_decode.cpp -o tb_decode --Mdir obj_decode
	./obj_decode/tb_decode

# Two clocks, driven from a scheduler rather than a fixed ratio: the failure
# this is aimed at is a transaction lost at some particular phase relationship,
# which a pretty 4:1 ratio never produces. Deliberately awkward ratios included.
test_cdc_port:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_cdc_port \
	  $(SRCS_m1_cdc_port) sim/mem/tb_m1_cdc_port.cpp -o tb_cdc --Mdir obj_cdc
	./obj_cdc/tb_cdc

# vblank is one clk_sys cycle — 10 ns at 96 MHz against a 42 ns slow clock, so
# it can fall between two destination edges and vanish. The property is exact
# conservation, and the documented merging limit is asserted rather than avoided.
test_cdc_pulse:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_cdc_pulse \
	  $(SRCS_m1_cdc_pulse) sim/mem/tb_m1_cdc_pulse.cpp -o tb_pulse --Mdir obj_pulse
	./obj_pulse/tb_pulse

# The V60 side is a held level and the memory side is an edge, and the line has
# to be rotated to the byte the core asked for. Both endpoints are modelled the
# way the real ones behave; a pulsed ack is invisible to a clock-enabled core and
# has looked like a dead CPU twice, so ack persistence is checked explicitly.
test_fetch_bridge:
	verilator --cc --exe --build -O2 $(VFLAGS) --top-module m1_fetch_bridge \
	  $(SRCS_m1_fetch_bridge) sim/mem/tb_m1_fetch_bridge.cpp \
	  -o tb_fetch --Mdir obj_fetch
	./obj_fetch/tb_fetch

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
AREA_MODULES := bw_monitor m1_copro_if m1_sdram m1_cdc_port m1_cdc_pulse m1_fetch_bridge m1_rom_loader m1_decode m1_glue m1_ioboard m1_mainram m1_tile_decode m1_tile_mixer m1_tile_fetch m1_video_timing m1_palette m1_video m1_raster_div m1_raster_fill fp_mul fp_add fp_div mb86233_alu mb86233_agu mb86233_seq mb86233_regs mb86233_mem mb86233_dec mb86233_xfer mb86233_core

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

.PHONY: render render3d quartus_list quartus_paths v60_cpi test_v60_in_mem test_raster_band test_listwalk test_geo_xform test_fp_to_int test_geo_project test_geo_det test_geo_rsqrt test_geo_color test_geo_norm test_geo_clip test_geometry test_quad_store test_lightbank m1_main m1_boot m1_frame rbf mra verify_mra
# Optimisation target. Every figure so far was taken at Aggressive Performance,
# so that stays the default and the numbers remain comparable. An area question
# wants QOPT="Aggressive Area" — for combinational-heavy designs the two differ
# by enough that quoting one without saying which is misleading.
QOPT ?= Aggressive Performance

# Preprocessor defines passed to synthesis, e.g. QDEFS=S32_V60_NO_FP=1 to build
# the V60 without its floating-point group.
# Time limit on synthesis. A design whose memories fail to infer as block RAM
# does not error — Quartus builds them from flip-flops and keeps going, and a
# few megabits of that consumes every byte of RAM in the machine and never
# finishes. That happened twice here. A timeout bounds it so the mistake costs
# a failed build rather than the workstation.
#
# Deliberately NOT `ulimit -v`: Quartus reserves far more virtual address space
# than it uses, so a virtual-memory cap kills healthy builds during
# elaboration. Watch RSS if a build looks wrong; cap wall clock, not VA.
QUARTUS_TIMEOUT ?= 1200

QDEFS ?=

# V60 executing out of SDRAM through the loader, decode and controller. Not in
# `make test`: it builds the CPU twice and takes a couple of minutes.
m1_main:
	@bash tools/run_m1_main.sh

# Boots real game code. Needs a ROM image, which is not in the repository:
#   python3 tools/build_rom_image.py vr ~/roms/vr.zip -o build/rom
# Not part of `make test` for that reason.
#
# WATCH_PAGE selects the address page the trace reports in detail — per-address
# read counts, and writes in order with their data. That trace is the tool that
# has found every boot blocker so far, so it is a variable rather than an edit:
#   make m1_boot WATCH_PAGE=0xC0    # the I/O board
#
# Every count this prints scales with BOOT_CYCLES, so quote the two together or
# the figure cannot be reproduced. A set of numbers recorded without their run
# length already read as a regression once, and was not one.
m1_boot:
	@test -f build/rom/$(GAME)_v60.hex || { \
	  echo "build/rom/$(GAME)_v60.hex missing — run:"; \
	  echo "  python3 tools/build_rom_image.py vr <path-to>/vr.zip -o build/rom"; \
	  exit 1; }
	verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
	  -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN \
	  -Wno-INITIALDLY -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH \
	  +define+SIMULATION $(BOOT_DEFS) --top-module tb_m1_boot -GRUN_CYCLES=$(BOOT_CYCLES) \
	  -GWATCH_PAGE=$(WATCH_PAGE) -GTGPTRACE=$(TGPTRACE) -GMATH_ZERO=$(MATH_ZERO) \
	  --Mdir build/m1boot -o m1boot \
	  rtl/cpu/v60/v60_bus.sv rtl/cpu/v60/v60.sv rtl/cpu/v60/v60_fp.sv rtl/cpu/v60/v60_ifetch.sv rtl/cpu/v60/v60_alu.sv rtl/cpu/v60/v60_shift.sv rtl/io/m1_decode.sv \
	  rtl/io/m1_glue.sv rtl/io/m1_ioboard.sv rtl/tgp/m1_copro_if.sv \
	  rtl/cpu/tv80/tv80_alu.v rtl/cpu/tv80/tv80_reg.v rtl/cpu/tv80/tv80_mcode.v \
	  rtl/cpu/tv80/tv80_core.v rtl/cpu/tv80/tv80s.v rtl/io/m1_ioz80.sv \
	  rtl/tgp/m1_tgp.sv $(SRCS_mb86233_core) rtl/mem/m1_tdp_ram.sv rtl/m1_mainram.sv rtl/mem/m1_sdram.sv \
	  rtl/mem/m1_cdc_port.sv rtl/mem/m1_cdc_pulse.sv rtl/mem/m1_fetch_bridge.sv \
	  rtl/video/m1_listctl.sv \
	  sim/mem/sdram_model.sv rtl/m1_main.sv sim/top/tb_m1_boot.sv
	./build/m1boot/m1boot

# MICROCODE-DRIVEN LOCKSTEP FOR THE TGP — M0 exit criterion 2, finally armed.
# Diffs our coprocessor's instruction stream against MAME's on the real decapped
# microcode. Outside `make test` because it builds the whole boot bench and runs
# MAME. See tools/tgp_trace.sh for what it already found.
tgp_trace:
	bash tools/tgp_trace.sh

# VALUE-LEVEL lockstep for the TGP: the data-memory write streams, diffed. tgp_trace
# compares PCs and so can only catch a wrong value once it changes control flow; this
# catches it where it is produced. See tools/tgp_wrtrace.sh for the three ways of
# getting registers out of MAME that do NOT work.
tgp_wrtrace:
	bash tools/tgp_wrtrace.sh

# Extra defines for the boot bench. The one that matters:
#
#   make m1_boot BOOT_DEFS=+define+S32_V60_NO_FP
#
# builds the V60 without its floating-point group and traps any FP opcode that
# executes. Measured standalone, that group costs 1,942 ALM AND HALVES THE Fmax -
# 20,614 ALM at 24.92 MHz against 18,672 at 45.98 - so it is on the critical path
# as well as being 6% of the core. dbg_fp_trap has never fired, but it is inert by
# construction in a build that HAS the group, so only a run under this define is
# evidence.
BOOT_CYCLES ?= 20000000
TGPTRACE    ?= 0
MATH_ZERO   ?= 0
WATCH_PAGE  ?= 0xC0

# Real boot code through the real video path, dumped as an image. This is the
# one thing neither existing test covers: m1_video is verified against MAME on
# synthetic tiles, boot is verified with no video instantiated, and
# m1_integrated joins them. A black screen on hardware has a dozen causes and no
# visibility into any of them; here it has a trace.
#
# Long by necessity — boot has to fill tile RAM before there is anything to
# draw, and that took ~2.3 M cycles single-domain and more like four times that
# now. FRAME_CYCLES is generous; watch the progress lines.
m1_frame:
	@test -f build/rom/$(GAME)_v60.hex || { \
	  echo "build/rom/$(GAME)_v60.hex missing — run:"; \
	  echo "  python3 tools/build_rom_image.py vr <path-to>/vr.zip -o build/rom"; \
	  exit 1; }
	@mkdir -p build
	verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
	  -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN \
	  -Wno-INITIALDLY -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH \
	  +define+SIMULATION $(FRAME_DEFS) --top-module tb_m1_frame \
	  -GROMHEX='"build/rom/$(GAME)_v60.hex"' \
	  -GUCODEHEX='"build/rom/$(GAME)_tgp_prog.hex"' \
	  -GIOFWHEX='"build/rom/$(GAME)_iofw.hex"' \
	  -GEEHEX='"build/rom/$(GAME)_ee.hex"' \
	  -GSTREAMBIN='"build/rom/$(GAME)_stream.bin"' \
	  -GRUN_CYCLES="64'd$(FRAME_CYCLES)" \
	  -GDOWNLOAD=$(FRAME_DOWNLOAD) -GHOLD_CPU=$(FRAME_HOLD_CPU) \
	  -GPRESS_IN0=$(FRAME_PRESS) -GCOIN_AT="64'd$(FRAME_COIN)" -GTRACE_FRAMES=$(FRAME_TRACE) \
	  -GPCTRACE=$(V60_PCTRACE) -GPCTRACE_MAX="64'd$(V60_PCTRACE_MAX)" -GWRTRACE=$(V60_WRTRACE) \
	  --Mdir build/m1frame -o m1frame \
	  $(SRCS_TOP_CORE) sim/mem/sdram_model.sv sim/top/tb_m1_frame.sv
	./build/m1frame/m1frame

# PASSED AS A 64-BIT LITERAL. Verilator's -G parses a bare decimal as 32 bits
# whatever the parameter is declared as, so -GRUN_CYCLES=3600000000 wrapped
# negative and the run finished having executed ZERO cycles — while printing a
# normal $finish and a frame summary. Declaring the parameter longint was not
# enough; the literal needs its width. Reaching the attract state the board is
# actually in takes about 3.6e9.
FRAME_CYCLES ?= 120000000

# FRAME_TRACE=1 prints one line per frame: what share of the frame fell through
# to the backdrop, the per-tilemap census, the window control registers and the
# PC. This is how an alternating picture is diagnosed — a single captured frame
# shows one side of a flash and looks either perfect or completely broken.
FRAME_TRACE ?= 0

# One line per retired V60 instruction, for tools/v60_trace.sh. A firehose; off
# unless that script asks for it.
V60_PCTRACE ?= 0
# Raise for a longer comparison window; 4 M stops at ~2.5 emulated seconds.
V60_PCTRACE_MAX ?= 4000000
# Extra defines for the FRAME bench, mirroring BOOT_DEFS. Without this,
# `make m1_frame FRAME_DEFS=...` was silently ignored and the run reported a
# clean result for a build that never had the define.
FRAME_DEFS ?=
V60_WRTRACE ?= 0

# The ROM arrives over ioctl by default, because that is what hardware does and
# a preloaded memory hides an entire class of fault. FRAME_DOWNLOAD=0 restores
# the old poke-it-into-the-model behaviour when the CPU and video path are what
# is being isolated.
#
# FRAME_HOLD_CPU=0 releases the V60 on the SDRAM controller's `ready` instead of
# on the loader's `rom_loaded` — which is what Model1.sv did until the white
# screen on hardware was traced to it. Kept as a switch so the failure can be
# reproduced rather than only described.
FRAME_DOWNLOAD ?= 1
FRAME_HOLD_CPU ?= 0

# A control held down for the whole run, as IN.0 would present it: 0xff none,
# 0xef START, 0xfe COIN, 0xfb TEST. See docs/io-board.md for the bit order.
FRAME_PRESS ?= 0xff

# Cycle at which the bench inserts a coin and then presses start, which is how
# a run reaches GAMEPLAY rather than stopping in attract. 0 never does it.
# Attract has settled by ~250 M, so 300000000 is a reasonable place.
FRAME_COIN ?= 0

# The MRA owns the ROM layout completely, because m1_rom_loader deliberately
# does no base-address arithmetic. That makes a misplaced region impossible to
# cause in RTL and easy to cause in XML — and it does not fail at load time, it
# fails as a checksum error much later on hardware, looking like a CPU bug.
#
# So it is checked rather than trusted: expand the MRA and diff it against the
# packed stream the boot and frame tests actually run against. Needs a ROM set,
# which is never in the repository.
#
#   make verify_mra ROMZIP=~/roms/vr.zip
# Regenerate every MRA from MAME's ROM definitions. The sets do not share a
# layout — swa has one 512 KB image where vr has two 128 KB, netmerc has no
# program pair at all — so these are generated rather than copied from each
# other. Reports which files are missing from any local ROM set as it goes.
mra:
	python3 tools/gen_mra.py

ROMZIP ?= $(HOME)/roms/vr.zip
# Defaults to Virtua Racing; override for any other set:
#   make verify_mra GAME=vf MRA="mra/Virtua Fighter.mra" ROMZIP=~/roms/vf.zip
#
# It was hardcoded to vr, which meant the other NINE .mra files in mra/ had
# never been checked against the packer at all.
GAME ?= vr
MRA  ?= mra/Virtua Racing.mra

verify_mra:
	@test -f "$(ROMZIP)" || { echo "set ROMZIP=<path to the game's zip>"; exit 1; }
	python3 tools/verify_mra.py "$(MRA)" "$(ROMZIP)" $(GAME)

# The real core: sys_top plus emu, compiled to a .rbf for the DE10-Nano.
#
# Staged in build/mister with sys/ symlinked rather than vendored — see
# tools/mister_project.sh for why. Long: this is the whole framework plus the
# whole core, not one module against a virtual-pinned harness.
rbf:
	@bash tools/mister_project.sh
	cd build/mister && PATH="$(QUARTUS_BIN):$$PATH" quartus_sh --flow compile Model1
	@ls -la build/mister/output_files/*.rbf 2>/dev/null || \
	  echo "no .rbf produced — check build/mister/output_files/"

# V60 cycles-per-instruction against memory latency. Not part of `make test`:
# it builds the CPU a dozen times and takes minutes.
# IN.W WITH A MEMORY DESTINATION. The V60 read the port and dropped the store
# (S_IN_RD overrode wb_op2's S_WB_MEM with a guard that read the old st). No
# suite test covered the form; this one FAILS on the pre-fix v60.sv and passes
# on the fix - checked both ways before it was added. Sources and flags follow
# tools/v60_cpi_sweep.sh, whose bench it clones with a write path added.
# The shared integer ALU against the fifteen inline arms it replaced. The
# reference in the bench is the OLD CODE, transcribed - quirks included - so a
# mismatch names the opcode and width rather than surfacing as a game bug
# months later. The 29-test V60 suite covers these opcodes but not densely.
test_v60_alu:
	verilator --binary --timing -j 8 -Wno-fatal $(VFLAGS) -Wno-DECLFILENAME \
	  -Wno-UNUSEDSIGNAL -Wno-WIDTH --top-module tb_v60_alu --Mdir obj_v60_alu -o run \
	  rtl/cpu/v60/v60_alu.sv rtl/cpu/v60/v60_shift.sv sim/cpu/tb_v60_alu.sv
	./obj_v60_alu/run | grep -E '^v60_alu:|FAIL'

# The shared shift/rotate unit against the five helpers it replaced. Counts are
# SWEPT -128..127 rather than sampled: every correction this code has needed was
# at a boundary (audit R20 V60-7), and sweeping found two bugs in the unit that
# random counts would have missed.
test_v60_shift:
	verilator --binary --timing -j 8 -Wno-fatal $(VFLAGS) -Wno-DECLFILENAME \
	  -Wno-UNUSEDSIGNAL -Wno-WIDTH --top-module tb_v60_shift --Mdir obj_v60_shift -o run \
	  rtl/cpu/v60/v60_shift.sv sim/cpu/tb_v60_shift.sv
	./obj_v60_shift/run | grep -E '^v60_shift:|FAIL'

test_v60_in_mem:
	verilator --binary --timing -j 8 -Wno-fatal $(VFLAGS) -Wno-BLKANDNBLK -Wno-MULTIDRIVEN \
	  -Wno-INITIALDLY -Wno-PINMISSING +define+SIMULATION \
	  -GFAST=1 -GCEDIV=1 -GLAT=4 --top-module tb_v60_in_mem --Mdir obj_v60_in_mem -o run \
	  rtl/cpu/v60/v60_bus.sv rtl/cpu/v60/v60.sv rtl/cpu/v60/v60_fp.sv rtl/cpu/v60/v60_ifetch.sv rtl/cpu/v60/v60_alu.sv rtl/cpu/v60/v60_shift.sv sim/cpu/tb_v60_in_mem.sv
	./obj_v60_in_mem/run | grep -E '^v60_in_mem:|FAIL'

v60_cpi:
	@bash tools/v60_cpi_sweep.sh

# Our V60's instruction stream against MAME's, from reset. See the script header;
# the short version is that per-opcode fuzzing cannot show the machine reaches the
# right state on real code, and this can.
v60_trace:
	@bash tools/v60_trace.sh

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
	cd $(QDIR) && PATH="$(QUARTUS_BIN):$$PATH" sh -c \
	   'timeout $(QUARTUS_TIMEOUT) quartus_map $(MOD) && \
	    timeout $(QUARTUS_TIMEOUT) quartus_fit $(MOD) && \
	    timeout $(QUARTUS_TIMEOUT) quartus_sta $(MOD)'

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
