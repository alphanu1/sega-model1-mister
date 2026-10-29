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

### jt12 (Jose Tejada, jotego) — GPL-3.0-or-later
`rtl/sound/jt12/` is JT12, Jose Tejada's YM2612/YM3438 implementation, used
unmodified as the sound board's FM chip. Every file carries its own GPL-3.0-or-
later header naming him as author.

GPL-3 to GPL-3, so reuse is direct. Copyright remains his on those files.

### fx68k (Jorge Cwik / ijor) — GPL-3.0
`rtl/sound/fx68k/` is fx68k, the sound board's 68000. Cycle accurate, and the
usual MiSTer choice; it was the option identified when M4 was first costed (see
*Evaluated for M4 sound* below) and it is the one that shipped.

Its microcode tables are loaded by `$readmemb` from `.mem` files at
elaboration, by bare filename — so a bench must run from a directory where
those files resolve, or the 68000 executes nothing and reports no instructions
with no error.

**Modified here (2026-10-28), one change, marked in the file:** the register
file (`regs68L`/`regs68H` in `excUnit`) is built in MLAB as a live-value table
- a bank per write port, a copy per read address, one bit per register and
lane naming the newest bank, the previous clock's writes bypassed - instead of
576 flip-flops and their read muxes. Same values on the same cycles; the flat
arrays remain in simulation as a mirror and every read is checked against
them. Worth about 500 ALM on the full design. The sound board bench's WAV and
the frame bench's audio are byte-identical before and after.

GPL-3 to GPL-3. Copyright remains theirs on those files.

### The 15 kHz scan converter — retrorepair, via the Model 2 core — GPL-3.0-or-later
`rtl/video/m1_scan15.sv`, `sim/video/tb_m1_scan15.sv` and `sim/video/run_scan15.sh`
are the Model 2 core's 15 kHz scan converter and its bench, taken from
**sega-model2-mister at `af76dde`** (`rtl/video/m2_scan15.sv`,
`sim/video/tb_m2_scan15.sv`, `sim/video/run_scan15.sh`; its study R898 and
R939). That is in turn retrorepair's design, from
**retrorepair/sega-model2-mister branch `guncon-scan15` at `57faad7`**, with the
Model 2 core's changes recorded in that project's THIRD_PARTY.md (two taps, a
16-line ring, all three line counts, the R939 pairing fix).

Licence: both repositories are GPL-3.0 and the files carry
`SPDX-License-Identifier: GPL-3.0-or-later` — the same licence as this project.
Copyright remains with their authors.

Changed here: the module renamed `m1_scan15` and its header notes, nothing in
the logic — Model 1 and Model 2 declare the same 16 MHz, 656 x 424, 496 x 384
picture. The bench runs at 80 MHz with ce_pix one cycle in five, as `clk_sys`
does here, against `m1_video_timing`; the output enables are the same rates as
exact rationals of 80 MHz (547/4240, 537/4240, 4305/34768). The `[15kHz CRT]`
MRAs follow the Model 2 core's convention (game id bit 7), made by
`tools/make_crt_mra.py`, which is original here.

### The 3D frame buffer in DDR3 — from the Model 2 core — GPL-3.0-or-later
Taken from **sega-model2-mister at `47ad2e2`** (branch `main`), the same
author's core:

| here | there | changed |
|---|---|---|
| `rtl/mem/m2_ddr3.sv` | `rtl/mem/m2_ddr3.sv` | nothing but the header |
| `rtl/mem/m2_ddr3_arb.sv` | `rtl/mem/m2_ddr3_arb.sv` | nothing but the header |
| `rtl/video/m1_fb_read.sv` | `rtl/video/m2_fb_read.sv` | renamed; the line buffers hold Model 1's 17-bit pixel ({painted, RGB565}) |
| `sim/mem/tb_m2_ddr3.cpp`, `sim/mem/tb_m2_ddr3_arb.cpp` | the same | unwritten memory reads 0xFFFF... in `tb_m2_ddr3` |
| `sim/video/tb_m1_fb_read.cpp` | `sim/video/tb_m2_fb_read.cpp` | the 17-bit pixel; unwritten memory reads 0xFFFF... |

The publish / show / hold control in `m1_raster3d` (FB_DDR3) follows
`m2_raster3d`'s (fb_draw, fb_show, fb_complete; its study R359, R650,
R655-R657). The writer is NOT Model 2's: `m2_fb_write` (a DDR3 command per
span) was ported first and measured too slow for Model 1's polygon rows, so
the band buffer is the write combiner and `rtl/video/m1_fb_flush.sv`,
original here, copies each filled band into DDR3. `rtl/mem/m1_ddram_mux.sv`,
which shares the one DDRAM port with the quad payload, is original here too.

### The wheel modes — idea from the Model 2 core
`rtl/io/m1_drive_inputs.sv` is written here. Its Wheel A / Wheel B pedal
mapping follows the Model 2 core's `rtl/io/m2_cab_inputs.sv` (sega-model2-mister
R958, itself modelled on the Analog control option of Jotego's OutRun core),
rescaled to Virtua Racing's 0x01..0xff pedal range; no code was copied.

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

**Star Wars' Digital Sound Board (2026-10-28)** follows `dsbz80.cpp` (BSD-3-Clause,
R. Belmont and Olivier Galibert) for the board's ports and its play / loop /
stop logic, and `mpeg_audio.cpp` (BSD-3-Clause, Olivier Galibert) for the
Layer II decode -- `rtl/sound/dsb_mpeg.sv` reproduces `decode_buffer`'s sync
scan, limit rule and output rounding, and says so in its header. The synthesis
window in `rtl/sound/dsb_tables.svh` is ISO/IEC 11172-3's table as that file
prints it, generated by `tools/dsb/gen_tables.py` with the attribution in the
generated header. `tools/dsb/dsb_cmp.cpp` compiles against `mpeg_audio.cpp`
from a MAME tree and does not copy it. Nothing else was reused: no
open-source MPEG-1 Layer II decoder in HDL was found (the nearest are an
OpenCores Layer III VHDL project and Maintech's commercial core), and the
board's Z80 (`dsb_z80.sv`) is written here, not taken from tv80 -- see
docs/findings.md, 2026-10-29.

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
