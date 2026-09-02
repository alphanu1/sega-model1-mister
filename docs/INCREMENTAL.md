# Incremental bring-up from the last known-good hardware build

**Rule: one change per build. Flash it. Confirm 2D AND 3D draw on the board.
Do not add the next change until the current one is confirmed.**

Two days were spent flashing images containing eight changes at once and
attributing each black screen to whichever piece had been touched most recently.
Five different "found it" moments all produced the same black screen, because the
experiment could not distinguish them.

## Base

`61e383e` — confirmed working on the board by Ben, 2026-09-02.
Binary and md5 in `known_good/`. Built with `M1_SEED=5`, closes at +0.061.

## The ladder

| # | change | commit | why it might break the board | status |
|---|---|---|---|---|
| 1 | display lists halved | `cc3b548` | 64 M10K freed; reads above the cap return zero | untested |
| 2 | SDRAM port 0 bursts 4 | part of `949c0a8` | changes bus occupancy for ALL seven masters | untested |
| 3 | CPU port return 16→64 bits | part of `949c0a8` | more data crossing clk_cpu↔clk_sys | untested |
| 4 | data cache | part of `949c0a8` | caches charram, wram, rom, nvram | untested |
| 5 | FP pipelining | `7418cfd` | −1,672 ALM, one extra cycle on FP arith | untested |
| 6 | SDRAM arbiter registered | uncommitted | −1,305 ALM, changes grant timing | untested |
| 7 | pixel census pipelined | uncommitted | telemetry off the critical path | untested |
| 8 | TGP at 2:1 + CDC | uncommitted | the coprocessor at the board's own ratio | untested |

Steps 2, 3 and 4 are one commit and may need splitting; the burst-length change
is one line in `m1_sdram.sv`'s `blen()` and is independently testable.

## Verify each step on the BOARD, not in simulation

Simulation has passed every one of these. It does not reproduce the failure.

    ssh root@192.168.1.105 "stty -F /dev/ttyS1 115200 raw -echo; cat /dev/ttyS1"

## The signature of a WORKING core, recorded on the board 2026-09-02

    F=003A S=000E B=011C P=0039     <- P NON-ZERO is the test

`P` is the 3D object count. A working core reports it non-zero. **Every one of
the two days' worth of failing captures had `P=0000`**, with `S` pinned between
23 and 29 and nothing on screen at all - neither 2D nor 3D. So "does it work" is
answerable from the telemetry alone, without anyone watching the television, and
a rung of this ladder can be judged in the six minutes it takes to capture.

Full reference: `known_good/uart_working_reference.txt`.

Capture five minutes minimum — the game needs about four to reach steady state.
`S` is only meaningful while `P` is non-zero. A healthy board draws both layers;
`S` pinned at 29 with `P=0000` is the failure signature seen throughout.
