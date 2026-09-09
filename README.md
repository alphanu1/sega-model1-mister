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

## Releases

`releases/` holds the staged MiSTer release: the bitstream, the MRA, and a
README with the copy instructions and the md5 to check against.

**Only Virtua Racing is released.** The other five have MRAs in `mra/` and are
candidates, not releases — an MRA ships only for a game somebody has played on
hardware.

**There is no sound.** None at all, in any game. The Model 1's audio is a
separate PCB — a 68000, a YM3438 and two MultiPCMs — reached over the main
board's uPD71051C USART, and none of it is implemented. That is milestone M4 and
it has not been started. The core outputs silence, and that is expected rather
than a fault in anyone's setup.

**Two ROM zips are needed, not one.** `vr.zip` carries the game, the coprocessor
microcode and `93c45.bin` (the I/O board's settings EEPROM). The I/O board's Z80
firmware, `epr-14869.25`, is in a **separate BIOS set — `model1io.zip` or
`daytona93.zip`**, either of which the MRA accepts. The core runs the real I/O
board Z80 with no behavioural fallback, so without that firmware the game does
not boot; MAME will not start Virtua Racing without the same file either.

## Status

| Milestone | State |
|---|---|
| M0 — MB86233 spike | **complete** — TGP verified, fits with margin, gate settled |
| M1 — V60, bus, 2D, boot | **runs on hardware** — boots, renders, reads its controls through a real Z80 I/O board, window/split-scroll mode implemented and verified |
| M2 — geometry pipeline | **running real microcode on hardware, for five games.** FIFOs, copro RAM, microcode over the MRA and the data/table regions in SDRAM are built. A register-sourced `rep` read the wrong register until 2026-09-05, which hung Virtua Fighter on its first frame |
| M3 — rasterizer and video | **the 3D layer runs on hardware**: geometry, sort, band buffers and scanout are built, and the geometry agrees with MAME quad-for-quad across a full rotation. Two defects open — see below |
| M4 — sound | not started — 68000, YM3438 and two MultiPCMs on a separate sound PCB, reached through the main board's **uPD71051C serial port at `0xC40000`** rather than through the I/O board |

`docs/HANDOFF.md` is the current state of play: what is built, what it measures,
what to do next, and the failure modes that have cost time.
`docs/findings.md` is the durable record of measured facts about the hardware —
each with the instrument that produced it and what it corrected.

### Games

Five Model 1 titles, all packed by `tools/gen_mra.py` and verified byte-for-byte
against an independently written packer with `make verify_mra`.

| Game | On hardware | In MAME (the oracle) |
|---|---|---|
| Virtua Racing | boots, plays, 2D and 3D | yes |
| Virtua Fighter | runs; geometry judders and the quad store overflows | yes |
| Sega NetMerc | runs, 2D and 3D | reaches its title screen |
| Star Wars Arcade | ROM packs correctly, untested on hardware | yes |
| Wing War | ROM packs correctly, untested on hardware | yes |

`vf` and `netmerc` are marked `MACHINE_NOT_WORKING` in MAME and both run
correctly — that flag is a curation stance about their `BAD_DUMP` coprocessor
microcode, not a statement that the machine fails. Every game therefore has an
instruction-level oracle: `make tgp_trace GAME=<set>` diffs our coprocessor
against MAME's on that game's own microcode.

Only Virtua Racing's microcode is a good dump; the other four are flagged
`BAD_DUMP` and run anyway.

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

`make rbf` builds the real core — `sys_top` plus `emu` — and that is the number
that counts. **Measured 2026-09-05: 40,057 ALM (96%), 546/553 M10K (99%), 61 DSP
(54%)**, worst-case slack +0.036 ns on the framework's HDMI clock and +0.718 ns
on `clk_sys`, where our own logic lives.

Where it goes: **the V60 is 15,358 ALM**, the 3D layer 11,280 (geometry 7,580 of
it), the TGP 2,434, the Z80 I/O board 1,485, and the MiSTer framework about
6,000 — of which `ascal` alone is 2,135 and the audio chain ~1,700 for sound
that does not exist yet.

**M10K is the binding resource, not ALM.** Seven blocks are free, and two large
regions are provably not reducible: the display list buffers take ~104 M10K and
Wing War uses every word of both (measured across all five games), while the
quad store costs 211 bits a quad and cannot grow — see `docs/findings.md`,
2026-09-05.

One ALM lever was measured and is **spent**: removing the V60's FP group is
worth −2,984 ALM, but `dbg_fp_trap` fires at 421.7 M cycles on a real
angle-to-sine lookup, so the game genuinely uses it.

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

**Virtua Racing loses the left ~48% of its 3D.** Road and scenery vanish there;
cars on the same side draw normally. Eight candidate causes have been eliminated
by measurement on the board — SDRAM contention, coordinate wrapping, spans not
reaching the left, the band memory losing them, culling, clipping, projection,
and the frustum's left plane. The mixer is the last unexamined stage. Virtua
Fighter and NetMerc both draw balanced, so it is VR-specific.
`docs/findings.md`, 2026-09-05.

**Virtua Fighter discards geometry and judders.** The quad store saturates at
3,072 and drops 8,072 quads a capture, and the geometry pass takes 1.5 frames so
the 3D updates around 37 times a second against 57.5. The costed cure is binning
quads by band into SDRAM — measured at 1.11 bands touched per quad, so about
17 MB/s — which removes the capacity limit, collapses the 24x band replay to 1x,
and returns M10K. Not built.

**The 2D tile fetch misses scanline deadlines.** Not memory: the port is served
in 18 cycles while the controller sits ~29% busy. It is the engine's own line
budget — four dense layers need about 6,456 cycles against 3,936 available. A
two-port fetch was built, measured at 1,614 -> 568 cycles a layer, and reverted
because it broke the 2D on hardware while every bench stayed green.

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

`make rbf` builds it. `Model1.sv` is the top level and `mra/` holds a `.mra` per
game; `tools/mister_project.sh` stages the build in `build/mister` with `sys/`
symlinked rather than vendored, then runs `quartus_sh --flow compile Model1`.
The `.rbf` lands in `build/mister/output_files/`.

Deploy is a copy and a command: the `.rbf` to `/media/fat/_Arcade/cores/`, the
`.mra` to `/media/fat/_Arcade/`, then
`echo "load_core /media/fat/_Arcade/<name>.mra" > /dev/MiSTer_cmd`. **Reboot the
board before each load test** — a failed load leaves it stalled and every result
after that reports the stalled state. `/tmp/CORENAME` is the reliable indicator
of what is running; the FPGA manager state and the per-core config file are not.

`make quartus MOD=m1_integrated` remains a measurement vehicle — the V60 side and
the 2D side without the framework — and is the faster build when the question is
resource cost rather than behaviour.

## Bootstrap

**`quartus/` IS NOT PUBLISHED.** It is gitignored by choice, so a fresh clone
does not have it and has no `make quartus` or `make quartus_paths` — the targets
that measure ALM, M10K, DSP and Fmax. Restore those four files by hand if you
need the resource gates. `make rbf`, `make lint` and `make test` are unaffected;
`make rbf` stages its own project through `tools/mister_project.sh`.

```
chmod +x tools/bootstrap.sh     # if unpacked from a zip
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
  device model instead. `THIRD-PARTY.md` records the licence position.
- CAPS0ff — decapped MB86233 microcode ROMs

Pull current MAME ROM definitions. The 315-5711 copro dump carried two single-bit
corruptions until recently; an old set makes Wing War fail in ways that look like core
bugs.
