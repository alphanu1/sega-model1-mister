# Third-party code and licences

This project is GPL-3.0-or-later (see `docs/00-decisions.md` D7 for why that is
forced rather than preferred). Everything below is compatible with that, and
this file records what each dependency is and what its licence obliges.

`third_party/` is not in the repository. It is populated by `tools/bootstrap.sh`.

## In use

### meathax/s32 — GPL-3.0
`rtl/cpu/v60/v60.sv` and `v60_bus.sv` are meathax's V60 with explicit width
casts added so Icarus can elaborate them. `rtl/mem/m1_sdram.sv` follows the
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
Framework, HPS I/O and scaler. GPL-2-or-later upgrades to GPL-3, so the
combination is lawful. This is the direction that makes D7 necessary: code
flows in from GPL-2-or-later cores, and cannot flow back out to them.

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

## Not usable

### frangarcj/geometrizer — no licence
No licence file, therefore all rights reserved: no permission to copy **or to
adapt**. Hard rule 1. It may be run as an external oracle and read for
understanding. Porting its C to SystemVerilog would be an infringing derivative
— translation and restructuring are what "adapt" means, not a way around it.

## ROM images

Never committed, nor anything derived from them, including extracted microcode
baked into source (hard rule 2). `tools/build_rom_image.py` reads from a path
given on the command line and writes only under `build/`, which is gitignored.
