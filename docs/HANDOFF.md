# Handoff — 2026-08-15

State of the Sega Model 1 core at the end of the M1 memory/CPU/video work.
Everything below is committed and pushed; the tree is clean and the full suite
is green.

`CLAUDE.md` and `README.md` were brought back into agreement with this document
on 2026-08-15 — both still described M0 as the current milestone, and CLAUDE.md's
"expected output, exactly" block predated eight harnesses. If those three ever
disagree again, this file is where the measurements are.

## Where it is

**Real Virtua Racing code boots and executes.** The V60 takes the architectural
reset vector, fetches through the packed ROM mapping, clears and tests NVRAM,
work RAM, both display lists and tile RAM, passes the ROM checksum, completes
the I/O board handshake, and runs game code out of work RAM — 5,304,880
instruction fetches, zero SDRAM protocol violations, `dbg_fp_trap` never
asserted.

Two boot runs get cited in this document and they are not the same run. The
**post-handshake run** is the current one: 20 M cycles, 5.3 M fetches, execution
at `fe143d` out of work RAM. The **pre-handshake run** stopped at `fe095a`
polling the I/O board, and is where the 7.8 M-instruction CPI and FP-trap
figures come from — that one was mostly `MOVC` sweeping memory, so it is the
weaker evidence of the two about what game code does.

Built, tested and area-measured:

| block | ALM | verification |
|---|---|---|
| `s32_v60` (imported, cast-fixed) | 20,000 | 29/29 unit tests |
| `m1_sdram` + `sdram_model` | 937 | 80,009 checks, 0 protocol violations |
| `m1_main` + `m1_mainram` + `m1_glue` | ~700 | boot + 25 glue checks |
| `m1_video` (whole 2D path) | 287 | 380,929 checks vs MAME |
| `m1_rom_loader` / `m1_decode` | 319 | 1,675 / 466,714 checks |
| `bw_monitor` | 381 | 2M checks, mutation-tested |
| `mb86233_core` (TGP, not yet wired) | 2,554 | ~16.7M fuzz + lockstep |

**Integrated** (`make quartus MOD=m1_integrated`): 21,796 ALM, 332/553 M10K,
24.62 MHz — Fmax is the V60's, which is the critical path in context too.

The table is per-block standalone measurements, and several of those blocks are
already inside the integrated figure. The budget total is composed differently
and does not double-count: **21,796 (integrated) + 2,554 (TGP) + 937 (m1_sdram)
= 25,287 ALM.**

## How to run things

On a fresh clone, first:

    chmod +x tools/bootstrap.sh quartus/report.sh   # zip transport drops exec bits
    ./tools/bootstrap.sh                            # populates third_party/

`third_party/` is gitignored, so without that there is no MAME reference source,
no V60 upstream and no `sys/`, and nothing below works.

    make test                  # full Verilator suite, must be all fails=0
    make lint                  # must be clean
    bash tools/run_v60_tests.sh    # V60 unit suite, 29/29
    make m1_main               # CPU+memory integration, 4 configurations
    make m1_boot               # boots real ROM; needs the image below
    make m1_boot WATCH_PAGE=0xC0   # ...with one page traced address by address
    make v60_cpi               # CPI vs memory latency sweep
    make area                  # yosys proxy area, for tracking between edits
    make quartus MOD=<module>  # real ALM/Fmax; defaults to Quartus 17.0
    make quartus_list          # which Quartus installs were found, and which won
    make quartus_paths         # worst timing paths of the last build

    python3 tools/build_rom_image.py vr ~/roms/vr.zip -o build/rom

ROM images and anything derived from them never enter the repository.

`make test` prints a fixed set of counts — the harnesses seed mt19937 with a
constant, so they do not drift with host or toolchain. `CLAUDE.md` carries the
expected block; when a change legitimately moves a count, update it in the same
commit.

## What to do next

**1. Size the rasterizer.** This is the outstanding measurement and nothing is
blocked behind it. Build the fill path far enough to synthesise and run `make
quartus` on it. It closes a ±3,000 ALM uncertainty, decides whether `NO_FP`
needs spending, and tests whether D3's band-buffer arithmetic survives an
implementation. Not throwaway: the datapath is the real one.

`docs/m3-rasterizer-spec.md` has the fill rules transcribed from MAME, written
2026-08-15. It corrects what this section used to say. The primitive is a
**quad**, always four vertices — the frustum clipper emits triangles as quads
with a repeated vertex, so there is no triangle path and no primitive decode.
The filler is an **edge-walking DDA** in 16.16 fixed point, not an
edge-function rasterizer: the cost is an integer divide per edge event and two
adds per scanline, with no per-pixel arithmetic at all. So the area question is
dividers and band buffer, not a fill ALU.

The same read turned up that MAME performs the depth sort in the rasterizer
stage rather than receiving a sorted list, which is D3's premise. That is not a
measurement meeting D3's reversal condition, so the decision stands as written;
the quad count per frame from the M2 capture is what settles it.

**2. `emu.sv` + MRA.** There is still no top level. Everything beneath it is
built and tested; this is what puts the core on a DE10-Nano.

**3. The I/O responder as RTL.** It currently lives in `sim/top/tb_m1_boot.sv`
as an experiment, not an implementation.

## What is owed

Neither of these blocks the three tasks above, and neither is visible in a green
`make test`. Both are recorded here so they are not quietly lost.

**Microcode-driven lockstep for the TGP — M0 exit criterion 2, not met.** What
exists is `sim/tgp/mb86233_ref.cpp`, a whole-CPU `execute_run` reference running
in lockstep with the core over 8,000 retires of *generated* instructions across
every decoded ALU op. It has already caught two real core bugs. The criterion
asks for real microcode, and the suite line says so: `mb86233_core: checks=23
fails=0 lockstep_regs=8000 diverged=0 (microcode-driven lockstep still owed)`.

**Denormal and NaN-payload semantics.** The FP harnesses skip denormal inputs,
denormal results and NaN results, and the gap reaches the flags too — `fcpd`
against a negative NaN sets SGD in MAME and not in the RTL, because the units
emit a canonical quiet NaN. MAME evaluates with host C floats; silicon of this
era commonly flushes to zero. `README.md` states both questions in full.
Resolve against real microcode traces, not against the host, and do not widen
the harness coverage before that is settled.

## Budget

25,287 ALM built of 41,910. **16,623 left** against 12,500-19,500 still to
build (MiSTer `sys/`, sound, I/O board, rasterizer). It fits, with the
pessimistic end uncomfortably close.

M10K is now a constraint too: 332 of 553 before the band buffer, sound or
sprites.

One lever is measured and unspent: **V60 without the FP group, -1,987 ALM and
Fmax 24.62 -> 45.54**.

## Open decisions

**tv80 vs HLE for the I/O board — deferred, not settled.** The evidence is that
nothing has needed a Z80 *yet*: the V60 reads only the status byte, never input
data. But attract mode and the service menu have not run, and that is where
controls, coin, service and DIP switches get read. Licensing is clear either
way — tv80 is MIT and Verilog (simulatable), T80 is BSD-3 but VHDL (Quartus
only), MAME's 315-5338A is BSD-3 and not yet in the sparse checkout. See
`THIRD-PARTY.md`.

**`NO_FP`.** `dbg_fp_trap` never asserted on either boot run — 7.8 M
instructions pre-handshake, and 5.3 M fetches of real game code after it — and
the ROMs of 2 of 8 sets show no excess of FP-shaped byte pairs. The
post-handshake run is the evidence that matters, since the earlier one was
largely `MOVC` sweeping memory. Good evidence, not conclusive: attract mode and
gameplay have not run. `make m1_main` runs a configuration with an FP opcode
injected, which must trap, so the detector is known live.

## Things that bite, learned the hard way

**Block RAM inference is silent when it fails.** Quartus builds memories out of
flip-flops and keeps going. Two separate incidents: the video line buffers cost
28,816 ALM before being fixed, and the main-board memories consumed 15 GB and
never finished synthesising. Quartus 17.0 does **not** infer RAM from
`mem[a][7:0] <= d[7:0]` byte-enables — use two byte-wide arrays with plain
write enables, and put an explicit `ramstyle` on anything that matters.
Simulation cannot see any of this; only `make quartus` can.

**Test the idiom small.** The RAM question was settled in 30 seconds by
synthesising both forms at 1024 entries, after hours of full-size builds
answered nothing.

**Acknowledges must be held, not pulsed.** Anything talking to a `ce`-gated
requester must hold `ack` until the request drops. A one-cycle pulse is missed
and the CPU waits forever. This bit twice — `m1_main`'s bus and the fetch
bridge — and both times looked like a dead CPU rather than a handshake fault.

**The boot trace is the best debugging tool here.** A histogram of bus accesses
by page, plus per-address counts and write data for one watched page, has found
five blockers in a row. The watched page is a make variable: `make m1_boot
WATCH_PAGE=0xC0`, defaulting to the I/O board. `BOOT_CYCLES` shortens the run.

**Watch the machine.** Quartus with un-inferrable RAM will eat all system
memory; `make quartus` now runs under a timeout. Do not use `ulimit -v` —
Quartus reserves far more virtual address space than it uses. Also: `/tmp` here
is a 16 GB tmpfs, so build artefacts must not go there.

**Quartus parses `// synthesis <word>` as a pragma** — do not start a comment
sentence with it.

**A file list outside `make test` rots silently.** `m1_boot` kept its own
verilator source list and lost `rtl/m1_mainram.sv` when the on-chip memories
were split out of `m1_main.sv`; `run_m1_main.sh` and `SRCS_m1_integrated` were
updated and it was not. Because it is not in `make test`, nine commits went by
green while the target would not elaborate — including the two that quote its
output. Anything with a hand-maintained
source list needs running after a file moves — or its list needs to stop being
hand-maintained.

## Method note

Every significant finding this session came from measuring rather than
reasoning, and several came after an assertion turned out to be wrong: the V60
CPI figure was stale, the budget did not justify what I claimed, the I/O board
did not need per-variant work, the handshake reply was not a signature. Where
an estimate has a wide spread, measure it — it has consistently been cheaper
than the argument about it.
