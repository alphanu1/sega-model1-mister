# KNOWN GOOD — confirmed working on the board

**Commit:** `a207c47` — flip-triggered geometry pass, two dividers in the fill
**Built:** 2026-09-03, Quartus 17.0, `M1_SEED=3`, MISTER_DISABLE_YC + MISTER_DISABLE_ALSA
**Confirmed on hardware by Ben, 2026-09-03 evening: "no missing bands".**

    Model1.rbf      md5 f2e0be6e039602f968fefd4e0252ec2c
    ALM             ~38,700 / 41,910 (93%)
    M10K            496 / 553 (90%)
    setup slack     +0.183 ns
    errors          0

Telemetry over /dev/ttyS1, in uart_twodiv_seed3.txt (copied from build/):

    F=003A S=001B B=+1D P=005F L=16FB T=0000 W=07D2 D=777F H=0003

    B  now advances one per swap - the geometry pass starts on the game's list
       flip and no longer loses a frame between the swap and the frame pulse
    L  pass length, 256-cycle units; 0C7C is a frame. 1.35-2.15 frames here
    T  bands presented LATE - zero for 110 s; the two dividers did that
    W  worst band fill in the second, 16-cycle units; a slot is 0853
    D  quads the 2,048-quad store could not hold, summed - THOUSANDS a second
       in the attract pit stop; the grandstand is what falls off. Open.
    H  passes shorter than half the previous one - rare, the walk is complete

The previous known-good (`284d872`, rung 8) is superseded; its notes on
uptime and recovery below still apply.

Telemetry over /dev/ttyS1, in uart_working_reference.txt:

    F=003A S=001D B=01C5 P=0030 C=004C R=3C1D

**THIS BUILD RUNS AT ~97% OF HARDWARE SPEED.** The metric is frames-per-swap,
F/S, where 2.00 is 100%. S went from 13-14 to 27-29 when the coprocessor moved
to 2:1, taking F/S from 4.30 to 2.05 - the board had been at ~46%.

    F  video frames in the reporting window (58 = ~1 s, NOT game speed)
    S  display-list swaps: one per completed logic frame
    B  completed 3D GEOMETRY PASSES, free-running - NOT bands, whatever the
       old comment said. On rung 8 it advances ~20 a second against ~28 swaps,
       so ~8 logic frames a second finish no new geometry and the display holds
       the previous pass. That is the "bands not drawn in busy scenes" symptom
    P  objects, NON-ZERO IS THE PASS SIGNATURE - every failed image during the
       two-day black-screen episode showed P=0000
    C  TGP program counter. 004C is the idle dispatch, where it waits, so
       sampling once a second usually catches it there
    R  TGP retire count, free-running 16-bit. It WRAPS between samples here,
       which is what a busy coprocessor looks like

## UPTIME CAN LOOK EXACTLY LIKE AN RTL BUG

scp the .rbf, verify the md5 on both sides, then reboot and load. A warm reboot
is normally fine.

But on 2026-09-03 rung 8 came up with wildly wrong colours, a stretched band
across the middle of both the 2D and 3D layers, and the picture pushed off the
bottom - while every telemetry counter read healthy. Fetch-deadline misses were
ruled out by measurement and it was about to be chased as a window-mode
rendering bug newly reachable at the higher speed. **A cold boot fixed it, and
the cause was four days of MiSTer uptime, not the flash.**

So if the picture is wrong in a way the telemetry contradicts, ask how long the
machine has been up before touching the RTL. And start a crash hunt or any
timing-sensitive observation from a cold boot, so uptime is not a variable.

## RECOVERING THIS FILE IF IT IS LOST

The .rbf is gitignored, so only this README and the .md5 are in the repository.
The image itself lives in two places: here, and
`/media/fat/_Arcade/cores/Model1.rbf` on the MiSTer. If the local copy is
deleted, check the md5 on the board against the .md5 file and scp it back.

That is not hypothetical. This directory held a STALE image for a whole session
after rung 5 passed - the seed worktree that built it was deleted during
cleanup, and the only surviving copy was the one on the board. **Update this
directory at the moment a hardware test passes, not afterwards.**

## What it contains

Everything up to and including rung 5: the V60 with its multiplexer reduction
(MOVD through the register file's read ports, the shared ea_index shifter), the
SDRAM controller, the whole 2D path with window mode and the row mask, the TGP
at 1:1, the geometry pipeline, the band rasterizer, the display-list cap and the
FP pipelining.

It contains the shared integer ALU (`f216513`), the rotate sharing (`8defa69`),
the pixel-census timing fix (`075921c`), the shared shift/rotate unit
(`4bf8434`) and the 2:1 coprocessor (`284d872`) - all confirmed on hardware.

It does **not** contain the data cache. That change breaks the board - `P=0000`,
no video - and is parked at `be22c31`, reverted.

It does **not** contain the data cache. That change breaks the board - `P=0000`,
no video - and is parked at `be22c31`, reverted.
