# KNOWN GOOD — confirmed working on the board

**Commit:** `7074377` — the 3D layer complete: flip-triggered pass, two fill
dividers, the reciprocal table, the 3,072-quad store, 16-bit vertices, and
band 0 given the last band's slot
**Built:** 2026-09-04, Quartus 17.0, `M1_SEED=11`, MISTER_DISABLE_YC + MISTER_DISABLE_ALSA
**Confirmed on hardware by Ben, 2026-09-04: "looking good. barely any band 0
overruns, 1 or 2 over a few minutes."**

    Model1.rbf      md5 79c69a2b7532f08ea9d9cf1eeed54f64
    ALM             ~39,300 / 41,910 (94%)
    M10K            536 / 553 (97%)
    setup slack     +0.325 ns
    errors          0

Telemetry over /dev/ttyS1, in uart_band0_seed11.txt:

    S=0019 P=001C L=1946 T=0452 W=099F   and the rest of the line

    B  completed geometry passes - equal to S now, was 2/3 of it
    L  pass length, 256-cycle units; a frame is 0C7C
    T  bands presented LATE. 10 a second here, and Ben sees band 0 drop only
       once or twice a minute, so these are OTHER bands and the buffer ring
       absorbs them. The commit after this splits T into band 0 and the rest
       so it need not be inferred again.
    W  worst band fill in the window, 16-cycle units; a slot is 0853
    D  quads the 3,072-quad store could not hold. Still nonzero in bursts
    H  was the store's out-of-range vertex count, now the band-0 late count

Five defects were found and fixed against the board to get here; see
docs/HANDOFF.md for the mechanisms and docs/findings.md for the measurements.

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
