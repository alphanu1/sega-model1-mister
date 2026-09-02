# KNOWN GOOD — confirmed working on the board

**Commit:** `f422470` — rung 6: shared integer ALU, rotate sharing, census timing fix
**Built:** 2026-09-02, Quartus 17.0, `M1_SEED=7` (of ten seeds; ONLY 7 closed)
**Confirmed on hardware by Ben, 2026-09-02.**

    Model1.rbf      md5 4aa2cb6304c4b34d66cd272e84a39b1e
    ALM             38,875 / 41,910 (93%)
    M10K            495 / 553 (90%)
    DSP             53 / 112 (47%)
    setup slack     +0.005 ns
    errors          0

Telemetry over /dev/ttyS1 while running, in uart_working_reference.txt:

    F=003A S=000E B=04F4 P=0030

**P non-zero is the pass signature.** Every failed image during the two-day
black-screen episode showed `P=0000`. F is video frames, NOT game speed - the
speed metric is frames-per-swap, F/S, where 2.00 is 100% of hardware. This build
sits near 4.3, i.e. under half speed.

**THE SLACK IS +0.005 AND THAT IS NOT COMFORT.** The remaining critical path is
`ascal|o_hcpt[5]`, in the MiSTer framework's scaler, which this project does not
modify. Ten seeds spanned 0.60 ns on identical RTL and only seed 7 closed
(9: -0.596, 4: -0.150, 3: -0.144, 1: -0.098, 5: -0.047, 7: +0.005). Seed choice,
not our RTL, now decides whether a build closes.

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
