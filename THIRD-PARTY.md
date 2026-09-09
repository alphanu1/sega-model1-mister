# Third-party code and licences

This project is GPL-3.0-or-later (see `docs/00-decisions.md` D7 for why that is
forced rather than preferred). Everything below is compatible with that, and
this file records what each dependency is and what its licence obliges.

`third_party/` is not in the repository. It is populated by `tools/bootstrap.sh`.

**Merged 2026-08-15 from a duplicate.** This file and a `THIRD_PARTY.md` with an
underscore existed side by side for a day, with different content — the second
was added as a new file rather than an edit of the first, and a later change
repointed every reference at this one without noticing the other was still
there. The underscore version is gone and its unique material is below: the
relicensing path, the per-file SPDX warning about MAME, what is original here,
and the release checklist.

## In use

### meathax/s32 — GPL-3.0
`rtl/cpu/v60/v60.sv` and `v60_bus.sv` are meathax's V60 implementation with
explicit width casts added so Icarus can elaborate them. `rtl/mem/m1_sdram.sv` follows the
state machine of their `sdram.sv`, deliberately: it encodes request-edge
latching and pend-clear ordering hazards that are invisible from a datasheet.
Their V60 unit tests are reused unchanged via `tools/run_v60_tests.sh`.

GPL-3 to GPL-3, so reuse is direct. Copyright remains theirs on those files.

### MAME — BSD-3-Clause
Used as the behavioural oracle throughout (hard rule 3). `mb86233.cpp` and
`mb86233d.cpp` for the TGP, `model1.cpp` for the board and memory map,
`segaic24.cpp` for the tilemap, `model1_v.cpp` for video, `model1io.cpp` for
the I/O board.

Several files here are derivative of it to varying degrees — `m1_decode.sv` is
a transcription of `model1_mem`, and `sim/tgp/mb86233_ref.cpp` is C++ derived
from C++ with no translation step at all. BSD-3 permits that outright. The
obligation is to retain the copyright notice and licence text and not to use
contributors' names as endorsement, which this file discharges.

Note that behaviour of the original Sega and NEC silicon is fact, not MAME's
expression, and reimplementing hardware behaviour is not derivative of the
program that documents it. The distinction matters for structure rather than
function: where MAME made a decomposition choice that alternatives existed for,
mirroring it is a different question from reproducing what the chip does.

### MiSTer template / sys — GPL-2.0-or-later
Framework, HPS I/O and scaler. The repository LICENSE carries the GPLv2 text,
but every source file header reads "either version 2 of the License, or (at your
option) any later version". That or-later clause is the only reason this
combination is lawful: it permits upgrading `sys/` to GPL-3.

This is the direction that makes D7 necessary: code flows in from
GPL-2-or-later cores, and cannot flow back out to them.

**To relicense this repo as GPL-2-or-later**, the s32 V60 would have to be
removed and replaced with an independently written one, or meathax would have to
agree to dual-license. Nothing else in the tree blocks it.

### A warning about reading MAME
MAME is GPL-2.0 **as a whole**, and individual files carry their own SPDX
headers — many are BSD-3-Clause, and the ones this project depends on are.
Check the header of every file you read. Do not rely on the repository-level
licence in either direction.

Two files are flagged for use but not yet verified: `mb8421.*` (the dual-port
RAM the I/O board reaches through) and `multipcm.*` (M4 sound). Check their
headers before either is used as a reference.

## Evaluated for the I/O board, 2026-08-15

The Model 1 I/O board is a Z80 running `epr-14869` that reaches the V60's
dual-port RAM through a Sega 315-5338A. Emulating it needs a Z80 core and that
custom chip's behaviour.

| | licence | language | GPL-3 compatible | note |
|---|---|---|---|---|
| **tv80** (hutch31) | MIT | Verilog | yes | simulatable in Verilator |
| **T80** (Daniel Wallner, via s32) | BSD-3-Clause | VHDL | yes | Quartus only — Verilator cannot simulate it |
| MAME 315-5338A | BSD-3-Clause | C++ | yes | reference only; not in the sparse checkout yet |

All three are clear, so the choice is an engineering one rather than a legal
one. tv80 is the only option that can run inside the boot test, which is where
every recent bug has been found; T80 would synthesise but could not be
simulated alongside the rest of the design.

## Evaluated for M4 sound, 2026-08-16

The sound board is a 68000 at 10 MHz, a YM3438 and two MultiPCM 315-5560. The
CPU is the part best served by existing work; nobody should write a 68000.

| | licence | language | GPL-3 compatible | note |
|---|---|---|---|---|
| **fx68k** (Jorge Cwik / ijor) | GPL-3.0 | SystemVerilog | yes | cycle accurate; the usual MiSTer choice |

**Reported figures, not measured here:** roughly 5,100 LE, about 5 KB of
internal RAM, and up to ~40 MHz. Two notes before either number is relied on:

- The LE-to-ALM conversion doing the rounds is 2:1, which is the *theoretical*
  packing — one ALM holds two adaptive LUTs. Real designs rarely reach it, so
  5,100 LE is more likely 2,800-3,500 ALM on this device than the ~2,550 the
  straight division gives. Treat it as measured only after `make quartus`.
- ~5 KB of internal RAM is 4-5 M10K, and **M10K is the binding resource on this
  device now** — 409 of 553 spent, with the rasterizer's band buffer wanting
  ~51 of what is left. Small, but track it from the start rather than at the end.

40 MHz against a 10 MHz sound CPU is four times the headroom needed, which is
one constraint this project does not have to think about.

**Still to confirm before this is a decision**, and it is the criterion that
decided the I/O board: does it simulate under Verilator? A core that cannot run
inside the boot and frame tests cannot be verified the way everything else here
is. Fully synchronous SystemVerilog is a good sign and not an answer.

Licence terms are as reported by the project; confirm against the repository's
own LICENSE when it is fetched, the same way `tools/bootstrap.sh` does for
everything else in `third_party/`.

GPL-3.0 combines with this project's GPL-3.0-or-later without friction. The
combined work is distributable under GPL-3.0; our own files keep their
"or later" option.

## Not usable

### frangarcj/geometrizer — no licence
No licence file, therefore all rights reserved: no permission to copy **or to
adapt**. Hard rule 1. It may be run as an external oracle and read for
understanding. Porting its C to SystemVerilog would be an infringing derivative
— translation and restructuring are what "adapt" means, not a way around it.

## Originally written here

Everything under `rtl/`, `sim/`, `tools/`, `quartus/` and `docs/` except where a
file header says otherwise. GPL-3.0-or-later.

Files that transcribe from MAME carry the BSD-3-Clause attribution to Olivier
Galibert in their own headers: `rtl/tgp/mb86233_pkg.sv` for opcode numbering,
status flag positions and the exponent/mantissa accessors, and the video and
rasterizer modules for the behaviour they reproduce.

## ROM images

Never committed, nor anything derived from them, including extracted microcode
baked into source (hard rule 2). `tools/build_rom_image.py` reads from a path
given on the command line and writes only under `build/`, which is gitignored.

## Release checklist

Before publishing a build:

- [ ] `LICENSE` present and unmodified
- [ ] SPDX header on every source file
- [ ] This file lists every vendored component actually used
- [ ] `deps.lock` pins the exact upstream revisions built against
- [ ] Olivier Galibert's BSD-3-Clause notice retained wherever MAME-derived
- [ ] No `geometrizer` code present anywhere in the tree
- [ ] ROM images are not distributed. Ever.
