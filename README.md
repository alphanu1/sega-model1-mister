# Sega Model 1 — MiSTer core

Cyclone V (DE10-Nano), single SDRAM module.

Model 1 is unclaimed on MiSTer and software emulation of it is still incomplete, so this
is original work rather than a re-implementation of a solved problem. It is also the
hardest arcade target that plausibly fits the fabric: NEC V60 at 16 MHz, three Fujitsu
MB86233 floating-point DSPs, a flat-shaded polygon rasterizer with no texture unit and no
Z-buffer, and 496x384 output at 24 kHz.

Six titles: Virtua Racing, Virtua Formula, Virtua Fighter, Wing War, Star Wars Arcade,
NetMerc.

## Status

| Milestone | State |
|---|---|
| M0 — MB86233 spike | in progress: FP datapath, ALU, AGU and sequencer verified; top level not started |
| M1 — V60, bus, 2D, boot | not started |
| M2 — geometry pipeline | not started |
| M3 — rasterizer and video | not started |
| M4 — sound, inputs, full set | not started |

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
- Top level — not started.
- `fp_div` — not started, so `fdvd` (0x10) decodes but never writes D.

**Real device numbers, Quartus Prime Lite 24.1std, 5CSEBA6U23I7, 50 MHz constraint:**

| Module | ALMs | Registers | DSP | M10K | Fmax |
|---|---|---|---|---|---|
| `fp_mul` | 144 | 101 | **1** | 0 | 114.31 MHz |
| `fp_add` | 410 | 81 | 0 | 0 | 77.42 MHz |
| `mb86233_alu` | 1319 | 461 | **1** | 0 | 94.64 MHz |
| `mb86233_agu` | 176 | 0 | 0 | 0 | combinational |
| `mb86233_seq` | 175 | 106 | 0 | 0 | 244.20 MHz |

A TGP instance from what exists today is **1670 ALM, 1 DSP, 0 M10K at 94.64 MHz**
(`mb86233_alu` already includes one `fp_mul` and one `fp_add`). Every gate
threshold passes, and the 24x24 significand multiply does infer a DSP block —
the assumption D4 rests on. Three instances extrapolate to ~5.0K ALM and 3 DSP
against a 15K/8 budget.

Not the gate closed: there is no top level, so the register file, program store
and both RAM banks are absent and M10K reads 0; `fp_div` is unwritten; and this
is Quartus 24.1std rather than the 17.0.x MiSTer builds with. Details and
caveats in `docs/m0-mb86233-spike.md`.

Proxy synthesis (yosys 0.66, generic 6-LUT mapping with `-flatten`) is still used
for tracking relative change between edits:

| Module | LUT6 | FF |
|---|---|---|
| `fp_mul` | 1312 | 99 |
| `fp_add` | 690 | 80 |
| `mb86233_alu` | 2974 | 381 |
| `mb86233_agu` | 220 | 0 |
| `mb86233_seq` | 163 | 106 |

`mb86233_alu` includes one `fp_mul` and one `fp_add`, so it is the whole FP datapath
plus the integer side, not an increment on the two above. `mb86233_agu` is purely
combinational — no flops — because MAME's `ea_pre_*`/`ea_post_*` are functions of the
instruction field with no state of their own.

Read that as roughly 1600-2300 ALM and one DSP block per TGP instance for everything
built so far. Three physical instances still looks affordable, which is what decision
D4 rests on. Everything M0 specifies is now measured except `fp_div` and the top
level that ties these four together — and only Quartus settles the gate.

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
THIRD_PARTY.md                  component attribution and licence position
deps.lock                       pinned upstream revisions
docs/00-decisions.md            decision record, with reversal conditions
docs/m0-mb86233-spike.md        M0 specification and resource gate
docs/m1-m4-plan.md              M1-M4
docs/rtl-conventions.md         coding rules, testbench shape, area baselines
rtl/tgp/                        MB86233 implementation
sim/tgp/                        Verilator harnesses
quartus/                        M0 spike synthesis project template
tools/bootstrap.sh              vendors upstream deps into third_party/
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

`make area` uses generic 6-LUT mapping with no DSP inference and no device model. It is
useful for tracking relative change between edits. It does **not** settle the M0 gate.

### M0 spike — real device numbers

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

Does not exist yet. There is no top level until M1. When it does: fork
`MiSTer-devel/Template_MiSTer`, place RTL alongside `sys/`, and the template's post-module
script emits a dated `.rbf` into `releases/`. Headless that is
`quartus_sh --flow compile Model1.qpf`.

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

Full component breakdown in `THIRD_PARTY.md`. `tools/bootstrap.sh` prints a summary on
every run.

## Ground truth

- MAME `src/devices/cpu/mb86233/mb86233.cpp` — MB86233 behavioural model
- MAME `src/mame/sega/model1.cpp` — board layout, chip identification, clocks
- `frangarcj/geometrizer` — V60 and MB86233 validated against MAME by lockstep trace
  diffing and per-opcode fuzzing. Port this harness rather than rebuilding it.
- CAPS0ff — decapped MB86233 microcode ROMs

Pull current MAME ROM definitions. The 315-5711 copro dump carried two single-bit
corruptions until recently; an old set makes Wing War fail in ways that look like core
bugs.
