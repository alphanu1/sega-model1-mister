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
  wiring all ten blocks. **Directed harness only, 10 checks, zero failures** —
  this is deliberately not the lockstep of M0 exit criterion 2, which is still
  owed. `ldi`, `lipl`/`lia`/`lib`/`lid`, `stm`, `clr0`, `cfxd` rounding and PC
  advance are covered; `lab`, `ld/mov` transfers, branches and `rep` are wired
  but not yet exercised. `fdvd` works end to end.
- `mb86233_ref` — a whole-CPU `execute_run` reference model, with lockstep
  against the core. It has already found two real bugs. **One divergence is
  currently open, so `make test` is RED** — see below. FP ALU ops are still
  excluded pending the NaN-payload and denormal plumbing.

### Open divergence — `make test` is red

Lockstep diverges inside the `ld/mov` transfer forms. Narrowed to:

```
MEMDATA trial=35 instr=8 pc=0011 op=1c1da06a addr=0006a
        dut=26000000 | ref=00000000
```

A `mov mem, reg` (form 7/3) reads `data[0x6a]`. The **address is right**, the
per-instruction **write streams match**, and the **read addresses match** — but
the DUT's RAM holds `0x26000000` there where the model holds 0.

| Evidence | Conclusion |
|---|---|
| `7/6`, `7/3`, `7/0` each alone clean | no form individually wrong |
| `7/0` + `7/3` together diverge | an interaction |
| directed store/load passes | basic path correct |
| write streams identical | store side exonerated |
| read addresses identical | addressing exonerated |
| **read data differs** | **a write reached RAM outside the sampled window** |

So something writes `0x6a` that the per-instruction comparison does not see.
The likely candidates are a write asserted in a state the comparison window
misses, or `mem_we` glitching outside `S_DST`/`S_DST_W`. Next step is to log
*every* cycle where `dbg_mem_we` is high across a whole trial, rather than
per instruction, and find which cycle writes `0x26000000`.

Reproduce with `make test_core`; seeded at 20260814, deterministic.

Left red deliberately. A green suite over a known transfer bug would be worse.

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
