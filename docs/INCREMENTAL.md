# Incremental bring-up from the last known-good hardware build

**Rule: one change per build. Flash it. Confirm on the board. ONE COMMIT PER
ADDITION, on this branch, recording the hardware result. Do not add the next
change until the current one is confirmed and committed.**

Each rung's commit message carries: what was added, the build's slack and ALM,
and the telemetry from the board - `P` non-zero (works) or `P=0000` (broken),
with the swap rate. That way the branch history IS the bisect record, and a
future session can see exactly which change was on the board when.

Two days were spent flashing images containing eight changes at once and
attributing each black screen to whichever piece had been touched most recently.
Five different "found it" moments all produced the same black screen, because the
experiment could not distinguish them.

## ALWAYS `rm -rf build/mister` BEFORE A BUILD

`tools/mister_project.sh` does not fully refresh the staging directory, so files
from a previous build survive into the next one. Measured 2026-09-02: after
switching to this branch, `build/mister/Model1.sv` still carried `dbg_dc_dropped`
from the data-cache work and the build failed with 102 errors naming a port that
does not exist on this branch.

Worse than the failure is the case where it does NOT fail: a stale file that
still elaborates produces a build from a MIXTURE of branches, which is
unattributable. Some builds over the preceding two days did not clear staging.

## Base

`61e383e` — confirmed working on the board by Ben, 2026-09-02.
Binary and md5 in `known_good/`. Built with `M1_SEED=5`, closes at +0.061.

## The ladder

| # | change | commit | why it might break the board | status |
|---|---|---|---|---|
| 1 | display lists halved | `cc3b548` | 64 M10K freed; reads above the cap return zero | **WORKS** - 41,310 ALM, 495 M10K, +0.340 |
| 2 | data cache, WITH its burst and crossing changes | `949c0a8` | caches charram, wram, rom, nvram; changes bus occupancy for all seven masters | untested |
| 3 | FP pipelining | `7418cfd` | −1,672 ALM, one extra cycle on FP arith | untested |
| 4 | SDRAM arbiter registered | uncommitted | −1,305 ALM, changes grant timing | untested |
| 5 | pixel census pipelined | uncommitted | telemetry off the critical path | untested |
| 6 | TGP at 2:1 + CDC | uncommitted | the coprocessor at the board's own ratio | untested |

**Rungs 2-4 of the original plan are ONE change and must not be split.** Making
port 0 burst four words requires the requester to send burst-aligned addresses
and select the wanted word from the 64-bit return - which is precisely what
m1_dcache does. Split apart, `m1_main` would send unaligned addresses and take
`p_dout[15:0]`, reading the wrong word. The widened crossing exists for the same
reason: so a 4-word line arrives in one transaction. Testing them separately
would be testing something that was never meant to work.

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


## Open question: the FP cut's area saving

The first FP pipeline cut was recorded as **-1,672 ALM** (41,372 -> 39,700),
measured on the full stack. Measured alone on this branch it is **-276**
(41,310 -> 41,034).

Both builds should have used the default `Aggressive Area` optimisation, but that
was not verified at the time, so the two figures are not known to be comparable.
Ben's recollection is that the larger figure may have been taken with aggressive
area explicitly enabled.

Worth settling, because area is what blocks the 2:1 coprocessor: `tools/mister_project.sh`
now takes `M1_QOPT`, `M1_QTECH` and `M1_QDUP` independently, so the same RTL can
be built both ways and compared directly.

## The design has almost no timing margin

Step 3, identical RTL, four seeds:

    SEED 5   -0.187
    SEED 3   -0.523
    SEED 1   +0.026    <- the only one that closed
    SEED 4   -0.420

Half a nanosecond of spread from placement alone. Single-seed builds are a
lottery at this occupancy, which is why `build/tmp/seeds_par.sh` runs four at
once - Quartus only exploits about five of 32 cores per build, so four
concurrent builds cost nothing and turn an 80-minute sweep into 25.
