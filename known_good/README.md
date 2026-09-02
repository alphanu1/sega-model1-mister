# KNOWN GOOD — confirmed working on the board

**Commit:** `c9b0981` — rung 5, the V60 multiplexer reduction
**Built:** 2026-09-02, Quartus 17.0, `M1_SEED=4` (of four; 1 and 5 missed timing)
**Confirmed on hardware by Ben, 2026-09-02.**

    Model1.rbf      md5 fef3340c1d3d32ec3891bda7105699ad
    ALM             39,087 / 41,910 (93%)
    M10K            495 / 553 (90%)
    DSP             53 / 112 (47%)
    setup slack     +0.035 ns
    errors          0

Telemetry over /dev/ttyS1 while running, in uart_working_reference.txt:

    F=003A S=000E B=011C P=0039

**P non-zero is the pass signature.** Every failed image during the two-day
black-screen episode showed `P=0000`. F is video frames, NOT game speed - the
speed metric is frames-per-swap, F/S, where 2.00 is 100% of hardware. F/S near
4.0 is the ~50% the board currently runs at.

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

It does **not** contain the shared integer ALU (`f216513`), the rotate sharing
(`8defa69`) or the pixel-census timing fix (`075921c`). Those are committed and
verified in simulation; none has been confirmed on hardware yet.

It does **not** contain the data cache. That change breaks the board - `P=0000`,
no video - and is parked at `be22c31`, reverted.
