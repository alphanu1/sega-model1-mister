# KNOWN GOOD — confirmed working on the board

**Commit:** `284d872` — rung 8, the coprocessor at 2:1
**Built:** 2026-09-03, Quartus 17.0, `M1_SEED=13` (3 of 3 seeds closed)
**Confirmed on hardware by Ben, 2026-09-03.**

    Model1.rbf      md5 af8e98446b153c03b82e0f3b0e4f5847
    ALM             39,022 / 41,910 (93%)
    M10K            495 / 553 (90%)
    DSP             53 / 112 (47%)
    setup slack     +0.386 ns
    errors          0

Telemetry over /dev/ttyS1, in uart_working_reference.txt:

    F=003A S=001D B=01C5 P=0030 C=004C R=3C1D

**THIS BUILD RUNS AT ~97% OF HARDWARE SPEED.** The metric is frames-per-swap,
F/S, where 2.00 is 100%. S went from 13-14 to 27-29 when the coprocessor moved
to 2:1, taking F/S from 4.30 to 2.05 - the board had been at ~46%.

    F  video frames in the reporting window (58 = ~1 s, NOT game speed)
    S  display-list swaps: one per completed logic frame
    B  3D bands presented, free-running
    P  objects, NON-ZERO IS THE PASS SIGNATURE - every failed image during the
       two-day black-screen episode showed P=0000
    C  TGP program counter. 004C is the idle dispatch, where it waits, so
       sampling once a second usually catches it there
    R  TGP retire count, free-running 16-bit. It WRAPS between samples here,
       which is what a busy coprocessor looks like

## FLASHING: COLD-BOOT AFTER A NEW BITSTREAM

scp the .rbf, verify the md5 on both sides, then **power-cycle the MiSTer** -
not `reboot`. A warm reboot is fine for reloading a core that is already known
good, but a NEW bitstream can leave the fabric in a state a soft reset does not
clear.

Measured 2026-09-03: rung 8 came up after a warm reboot with wildly wrong
colours, a stretched band across the middle of both the 2D and 3D layers, and
the picture pushed off the bottom - while every telemetry counter read healthy.
Fetch-deadline misses were ruled out by measurement and it was about to be
chased as a window-mode rendering bug newly reachable at the higher speed. A
cold boot fixed it completely.

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
