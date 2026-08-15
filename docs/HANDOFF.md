# Handoff — 2026-08-15

State of the Sega Model 1 core at the end of the M1 memory/CPU/video work.
Everything below is committed and pushed; the tree is clean and the full suite
is green.

## Where it is

**Real Virtua Racing code boots and executes.** The V60 takes the architectural
reset vector, fetches through the packed ROM mapping, clears and tests NVRAM,
work RAM, both display lists and tile RAM, passes the ROM checksum, completes
the I/O board handshake, and runs game code out of work RAM — 5.3M instruction
fetches, zero SDRAM protocol violations, `dbg_fp_trap` never asserted.

Built, tested and area-measured:

| block | ALM | verification |
|---|---|---|
| `s32_v60` (imported, cast-fixed) | 20,000 | 29/29 unit tests |
| `m1_sdram` + `sdram_model` | 937 | 80,009 checks, 0 protocol violations |
| `m1_main` + `m1_mainram` + `m1_glue` | ~700 | boot + 25 glue checks |
| `m1_video` (whole 2D path) | 287 | 380,928 pixels vs MAME |
| `m1_rom_loader` / `m1_decode` | 319 | 1,675 / 466,714 checks |
| `bw_monitor` | 381 | 2M checks, mutation-tested |
| `mb86233_core` (TGP, not yet wired) | 2,554 | ~16.7M fuzz + lockstep |

**Integrated** (`make quartus MOD=m1_integrated`): 21,796 ALM, 332/553 M10K,
24.62 MHz — Fmax is the V60's, which is the critical path in context too.

## How to run things

    make test                  # full Verilator suite, must be all fails=0
    make lint                  # must be clean
    bash tools/run_v60_tests.sh    # V60 unit suite, 29/29
    make m1_main               # CPU+memory integration, 4 configurations
    make m1_boot               # boots real ROM; needs the image below
    make v60_cpi               # CPI vs memory latency sweep
    make quartus MOD=<module>  # real ALM/Fmax; defaults to Quartus 17.0

    python3 tools/build_rom_image.py vr ~/roms/vr.zip -o build/rom

ROM images and anything derived from them never enter the repository.

## What to do next

**1. Size the rasterizer.** This is the outstanding measurement and nothing is
blocked behind it. Build a flat-shaded triangle path far enough to synthesise —
setup, edge functions, span fill into the band buffer — and run `make quartus`
on it. It closes a ±3,000 ALM uncertainty, decides whether `NO_FP` needs
spending, and tests whether D3's band-buffer arithmetic survives an
implementation. Not throwaway: the datapath is the real one.

**2. `emu.sv` + MRA.** There is still no top level. Everything beneath it is
built and tested; this is what puts the core on a DE10-Nano.

**3. The I/O responder as RTL.** It currently lives in `sim/top/tb_m1_boot.sv`
as an experiment, not an implementation.

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

**`NO_FP`.** No trap across 7.8M instructions of real boot code, and no excess
of FP-shaped byte pairs in the ROMs of 2 of 8 sets. Good evidence, not
conclusive — attract mode and gameplay have not run. `make m1_main` runs a
configuration with an FP opcode injected, which must trap, so the detector is
known live.

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
five blockers in a row. `WATCH_PAGE` is a parameter.

**Watch the machine.** Quartus with un-inferrable RAM will eat all system
memory; `make quartus` now runs under a timeout. Do not use `ulimit -v` —
Quartus reserves far more virtual address space than it uses. Also: `/tmp` here
is a 16 GB tmpfs, so build artefacts must not go there.

**Quartus parses `// synthesis <word>` as a pragma** — do not start a comment
sentence with it.

## Method note

Every significant finding this session came from measuring rather than
reasoning, and several came after an assertion turned out to be wrong: the V60
CPI figure was stale, the budget did not justify what I claimed, the I/O board
did not need per-variant work, the handshake reply was not a signature. Where
an estimate has a wide spread, measure it — it has consistently been cheaper
than the argument about it.
