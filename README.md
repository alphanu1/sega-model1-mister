# Sega Model 1 — MiSTer core

Cyclone V (DE10-Nano), single SDRAM module.

Model 1 is unclaimed on MiSTer and software emulation of it is still incomplete, so this
is original work rather than a re-implementation of a solved problem. It is also the
hardest arcade target that plausibly fits the fabric: NEC V60 at 16 MHz, three Fujitsu
MB86233 floating-point DSPs on the board, a flat-shaded polygon rasterizer with no
texture unit and no Z-buffer, and 496x384 output at 24 kHz. The core implements one
MB86233, because MAME instantiates one and never executes the other two — decision D4,
reversed, with what that gives up stated there.

Six titles: Virtua Racing, Virtua Formula, Virtua Fighter, Wing War, Star Wars Arcade,
NetMerc.

## Status

| Milestone | State |
|---|---|
| M0 — MB86233 spike | **complete** — TGP verified, fits with margin, gate settled |
| M1 — V60, bus, 2D, boot | **boots real game code** — top level, rasterizer sizing and I/O board left |
| M2 — geometry pipeline | not started |
| M3 — rasterizer and video | fill path built and measured, early, to size it |
| M4 — sound, inputs, full set | not started |

`docs/HANDOFF.md` is the current state of play: what is built, what it measures,
what to do next, and the failure modes that have cost time.

### M1 progress

**Real Virtua Racing code boots and executes.** The V60 takes the architectural
reset vector, fetches through the packed ROM mapping, clears and tests NVRAM,
work RAM, both display lists and tile RAM, passes the ROM checksum, completes the
I/O board handshake, and runs game code out of work RAM. At the committed
`BOOT_CYCLES=20000000`: 236,367 instructions, 116,359 wide-port fetch line
fills, zero SDRAM protocol violations, `dbg_fp_trap` never asserted. Every
figure from that test scales with the run length, so quote the two together.

It also initialises the whole 2D path — 168,288 character RAM accesses, 53,673
to tile RAM, 40,960 to the colour translation tables and 8,433 real xBGR-555
palette entries — so the video block already built has content to display before
any of the 3D path exists.

| Block | ALM | Verification |
|---|---|---|
| `v60` (imported from s32, cast-fixed) | 20,000 | 29/29 unit tests |
| `m1_sdram` + `sdram_model` | 937 | 80,009 checks, 0 protocol violations |
| `m1_main` + `m1_mainram` + `m1_glue` | ~700 | boot, plus 25 glue checks |
| `m1_video` — the whole 2D path | 287 | 380,929 checks against MAME |
| `m1_rom_loader` / `m1_decode` | 319 | 1,675 / 466,714 checks |
| `bw_monitor` | 381 | 2 M checks, mutation-tested |
| `m1_raster_fill` + `m1_raster_div` (M3, early) | 2,113 | 152,025 quads / 31.6 M spans vs MAME |

`make quartus MOD=m1_integrated` builds the V60 side and the 2D side as one
design: **21,796 ALM, 332/553 M10K, 24.62 MHz**. Fmax is exactly the V60's
standalone figure, so the V60 is the critical path in context as well as alone.

**Budget: 27,400 ALM built of 41,910**, against MiSTer `sys/`, sound, the I/O
board and the rest of the rasterizer. It fits, with the pessimistic end
uncomfortably close. One lever is measured and unspent — the V60 without its FP
group, worth -1,987 ALM and Fmax 24.62 -> 45.54.

The quad filler was built out of M3 order because it was the widest unknown in
that budget: the fill path alone measures **2,113 ALM, 2 DSP, 0 M10K, 63.67
MHz** against a 3,000-6,000 estimate for the entire rasterizer, so binning, the
band buffer and scanout now carry the remaining uncertainty.
`docs/m3-rasterizer-spec.md` has the fill rules transcribed from MAME and the
two levers the measurement exposes.

### M0 progress

- `fp_mul` — IEEE-754 single multiplier. **1,885,699 fuzz cases, zero mismatches.**
- `fp_add` — IEEE-754 single adder/subtractor. **1,968,564 fuzz cases, zero mismatches.**
- `mb86233_pkg` — opcode, register and flag constants transcribed from MAME.
- `mb86233_alu` — operand mux, integer/logical/shift, `cxfd`/`cfxd`, status flags and
  write-priority arbitration. **2,170,367 fuzz cases across all 24 decoded opcodes plus
  4 undecoded ones, zero mismatches.**
- `mb86233_agu` — `ea_pre`/`ea_post` for both banks, all four mode-3 sub-forms, the
  `+0x200` adder and both of its wrap behaviours. **3,000,000 fuzz cases, zero
  mismatches, every addressing mode covered.**
- `mb86233_seq` — PC, the 4-deep hardware PC stack, all ten decoded branch
  conditions and six subtypes, loop counters and the repeat register.
  **3,000,000 lockstep cases, zero mismatches.**
- `mb86233_regs` — the 0x00-0x3f register space, the 16-entry file at 0x20-0x2f,
  the `get_exp`/`set_exp`/`get_mant`/`set_mant` accessors, and the narrow-register
  truncation. **3,000,000 lockstep cases, zero mismatches, all 64 addresses
  covered.**
- `mb86233_mem` — both RAM banks and the data-space decode. **178,399 lockstep
  cases, zero mismatches.** Infers 3 M10K blocks, the first non-zero memory on
  the gate.
- `mb86233_dec` — instruction decoder for all six types plus the branch forms.
  **3,000,000 fuzz cases, zero mismatches**, every dispatch value and every
  `ld/mov` sub-op covered.
- `mb86233_xfer` — transfer routing: which space and addressing side each side of
  a `ld/mov` uses. **256 cases, exhaustive, zero mismatches.**
- `mb86233_core` — the top level. Fetch, decode, memory sequencing and retire,
  wiring all ten blocks. **23 directed checks plus 8,000 lockstep retires, zero
  failures and zero divergence.** `fdvd` works end to end. This is still
  deliberately **not** the lockstep of M0 exit criterion 2, which wants real
  microcode and remains owed — see `mb86233_ref` below for what the 8,000
  retires actually drive.
- `mb86233_ref` — a whole-CPU `execute_run` reference model, with lockstep
  against the core, including the `ld/mov` transfer forms: **8,000 retires x 7
  registers, **every decoded ALU op including floating point**, zero divergence.
  It has found two real core bugs — a truncated source register index, and the
  FP post path applied to instruction types that never reach it — plus three
  harness faults.

### Real device numbers — Quartus 17.0.0 Lite, 5CSEBA6U23I7

| Module | ALMs | DSP | M10K | Fmax |
|---|---|---|---|---|
| `fp_mul` | 161 | **1** | 0 | 136.56 MHz |
| `fp_add` | 406 | 0 | 0 | 129.08 MHz |
| `fp_div` | 263 | 0 | 0 | 113.96 MHz |
| `mb86233_agu` | 176 | 0 | 0 | combinational |
| `mb86233_seq` | 174 | 0 | 0 | 231.64 MHz |
| `mb86233_regs` | 644 | 0 | 0 | 827.81 MHz |
| `mb86233_mem` | 123 | 0 | **3** | n/a |
| `mb86233_dec` | 121 | 0 | 0 | combinational |
| `mb86233_xfer` | 28 | 0 | 0 | combinational |
| **`mb86233_core`** | **2554** | **1** | **3** | **72.17 MHz** |

Against the gate the whole TGP passes ALM (2554 vs < 4K), DSP (1 vs 1-2) and
M10K (3 vs < 6) with margin. **Fmax is 72.17 MHz** — inside the 60-80 MHz
"investigate" band, above the 60 MHz fail line, short of the 80 MHz pass mark.

Three retiming passes got it there, each aimed with `make quartus_paths`:

| Change | Fmax |
|---|---|
| baseline | 51.47 |
| register the decoded ALU op | 54.28 |
| split `fp_add` and `fp_mul` from 2 stages to 4 | 69.29 |
| register the FP operand mux | 72.17 |

`fp_add` went 76.35 to 129.08 MHz and `fp_mul` 116.85 to 136.56, so the FP
units are no longer the limit. The remaining path has left them entirely: it is
now `state.S_DST` to `src_val`, the core FSM's own source-capture mux.

Cost: 2493 to 2554 ALM and ALU latency 2 to 5, both cheap for a part retiring
~5.3 M instructions/sec against a 50 MHz fabric. Every result is bit-identical —
the FP harnesses report the same checked and skipped counts as before, and
lockstep 8,000 retires with zero divergence.


### Correction, 2026-08-14

The shift and integer opcodes were transcribed two slots high: `lsrd` at 0x18 through
`subd` at 0x1d, where MAME has 0x16-0x1b. Both MAME sources agree (`alu_pre` cases and
the disassembler), so per hard rule 3 the numbering was corrected in
`mb86233_pkg.sv` and the docs together. Nothing had been built on the wrong table yet.

### Open questions

**Denormal handling.** MAME evaluates the TGP with host C floats, which are fully IEEE
and honour denormals. Real silicon of this era commonly flushes to zero. Both FP units
expose `FLUSH_DENORM_IN`; neither implements denormal *outputs*. The current fuzz
harnesses exclude denormal inputs and results, so this is untested in both directions.
Resolve it against real microcode traces, not against the host.

**NaN payloads.** The FP units emit a canonical quiet NaN (`0x7fc00000`); the host
propagates the operand's payload, so `f2u(NaN_operand op x)` keeps the original low
bits and a possibly-set sign. All three harnesses exclude NaN results for values that
pass through an FP unit. This also reaches the *flags*: a canonical NaN has a clear
sign bit, so `fcpd` against a negative NaN sets SGD in MAME and not in the RTL. Same
resolution path as denormals — real traces, not the host.

## Layout

```
CLAUDE.md                       agent instructions — read first
LICENSE                         GPL-3.0
THIRD-PARTY.md                  component attribution and licence position
deps.lock                       pinned upstream revisions
docs/00-decisions.md            decision record, with reversal conditions
docs/m0-mb86233-spike.md        M0 specification and resource gate
docs/m1-m4-plan.md              M1-M4, and the measurements behind them
docs/HANDOFF.md                 current state: built, measured, owed, next
docs/rtl-conventions.md         coding rules, testbench shape, area baselines
rtl/m1_main.sv                  main board — bus, arbitration, memory map
rtl/m1_mainram.sv               on-chip memories (block RAM idiom matters here)
rtl/m1_integrated.sv            V60 side + 2D side as one design, for measurement
rtl/cpu/v60/                    NEC V60, imported from s32 and cast-fixed
rtl/mem/                        SDRAM controller, device model, bandwidth monitor
rtl/io/                         ROM loader, 315-5465 address decode, GLUE
rtl/video/                      2D path — timing, tilemaps, priority mixer, palette
rtl/tgp/                        MB86233 implementation
sim/                            Verilator harnesses, mirroring rtl/
sim/top/                        boot and integration testbenches
quartus/                        synthesis project template
tools/bootstrap.sh              vendors upstream deps into third_party/
tools/build_rom_image.py        builds a ROM image; output is never committed
third_party/                    NOT COMMITTED — run tools/bootstrap.sh
```

## Build

Two paths, deliberately separate.

### Simulation and proxy synthesis

No Quartus needed. Requires verilator and yosys.

```
make lint                  # verilator lint
make test                  # fuzz every module with a harness
make area                  # yosys proxy synthesis
```

Three suites sit outside `make test` because each builds the V60 and takes
minutes:

```
bash tools/run_v60_tests.sh                     # V60 unit suite, 29/29
make m1_main                                    # CPU + memory integration
make v60_cpi                                    # CPI against memory latency
make m1_boot                                    # boots real game code
make m1_boot WATCH_PAGE=0xC0                    # ...with one page traced in detail
```

`m1_boot` needs a ROM image, which is not in the repository and never will be:

```
python3 tools/build_rom_image.py vr ~/roms/vr.zip -o build/rom
```

`make area` uses generic 6-LUT mapping with no DSP inference and no device model. It is
useful for tracking relative change between edits. It does **not** settle the M0 gate.

### Real device numbers

Synthesis-only project against `5CSEBA6U23I7`. Not a MiSTer core project: no `sys/`
framework, no pin assignments, no `.rbf`. All ports are virtual-pinned, since a spike has
far more ports than the package has pins and the fitter otherwise dies before reporting
anything.

```
make quartus MOD=fp_add    # map + fit + sta, then report
make quartus_report MOD=fp_add
```

Quartus is auto-detected from `~/intelFPGA_lite/*/quartus/bin` — no PATH export
needed. `make quartus_list` shows what was found and which was picked; newest
wins by default, and `QUARTUS=17.0` selects a specific one. Every report prints
the version that produced it.

**Which Quartus.** The spike has no `sys/` and no IP, so any version supporting
Cyclone V gives valid numbers; it was first run on 24.1std. A real core build
from M1 onwards needs **17.0.x**, because MiSTer's `sys/` ships pre-generated
PLL IP for Quartus 13.1 and 17.0 only (`sys/pll_q13.qip`, `sys/pll_q17.qip`) and
a newer Quartus forces an IP upgrade that regenerates the video PLLs. Install it
alongside with `tools/install-quartus17.sh <installer>`; versions coexist in
separate trees. The installer must be downloaded by hand — Altera's CDN returns
403 to unauthenticated requests. Reports ALMs, DSP blocks, memory bits and Fmax
against the gate table in `docs/m0-mb86233-spike.md`. Timing constraint is a flat 50 MHz
in `quartus/spike.sdc` with I/O paths cut.

Adding a module to the spike flow means adding one `SRCS_<module>` line to the Makefile.

### Core build

Does not exist yet: no `emu.sv`, no MRA, no `sys/` in the project. `make quartus
MOD=m1_integrated` is the closest thing and is a measurement vehicle rather than a
core. When the top level lands: fork `MiSTer-devel/Template_MiSTer`, place RTL
alongside `sys/`, and the template's post-module script emits a dated `.rbf` into
`releases/`. Headless that is `quartus_sh --flow compile Model1.qpf`.

## Bootstrap

```
chmod +x tools/bootstrap.sh quartus/report.sh   # if unpacked from a zip
./tools/bootstrap.sh            # read-only clones into third_party/
tools/bootstrap.sh --fork       # fork template + s32 to your account first (needs gh)
tools/bootstrap.sh --update     # re-pin deps.lock to current upstream HEADs
```

Pins land in `deps.lock`. `third_party/` is gitignored. The MAME checkout is a blobless
partial clone with a non-cone sparse filter, so it pulls ~5 MB of reference sources
rather than several GB.

## Licence

**GPL-3.0-or-later.** See `LICENSE`.

Forced by the s32 V60, which is GPL-3.0. MiSTer's `sys/` is GPL-2-or-later per its file
headers, so it upgrades and the combination is lawful — but the result is GPL-3 and code
cannot flow back into the GPL-2-or-later cores that make up most of the ecosystem.
Recorded as decision D7.

`frangarcj/geometrizer` has **no licence file**: all rights reserved. Run it as an
external oracle, read it as a reference, copy nothing from it.

Full component breakdown in `THIRD-PARTY.md`. `tools/bootstrap.sh` prints a summary on
every run.

## Ground truth

- MAME `src/devices/cpu/mb86233/mb86233.cpp` — MB86233 behavioural model
- MAME `src/mame/sega/model1.cpp` — board layout, chip identification, clocks
- `frangarcj/geometrizer` — V60 and MB86233 validated against MAME by lockstep trace
  diffing and per-opcode fuzzing. **No licence file, so all rights are reserved**: run
  it as an external oracle and read it for understanding, but copy nothing from it,
  its test harness included. The harnesses here are built from MAME's BSD-3-Clause
  device model instead. This is hard rule 1 in `CLAUDE.md`.
- CAPS0ff — decapped MB86233 microcode ROMs

Pull current MAME ROM definitions. The 315-5711 copro dump carried two single-bit
corruptions until recently; an old set makes Wing War fail in ways that look like core
bugs.
