# KNOWN GOOD — confirmed working on the board

**Commit:** `4bf8434` — rung 7, the shared shift/rotate unit
**Built:** 2026-09-03, Quartus 17.0, `M1_SEED=7` (4 of 6 seeds closed)
**Confirmed on hardware by Ben, 2026-09-03.**

    Model1.rbf      md5 1eb27a2f0fcb903db247a1d4b11fc4a9
    ALM             38,755 / 41,910 (92%)
    M10K            495 / 553 (90%)
    DSP             53 / 112 (47%)
    setup slack     +0.307 ns
    errors          0

Telemetry over /dev/ttyS1, in uart_working_reference.txt:

    F=003A S=000E B=021B P=001B

**P non-zero is the pass signature.** Every failed image during the two-day
black-screen episode showed `P=0000`. F is video frames, NOT game speed - the
speed metric is frames-per-swap, F/S, where 2.00 is 100% of hardware. This build
sits near 4.3, i.e. under half speed.

**THE TIMING IS HEALTHY NOW, AND IT WAS NOT AN ACCIDENT.** The previous image
closed at +0.005 with one seed in ten; this one closes at +0.307 with four in
six. What changed is 120 ALM of congestion: the failing path is
`ascal|o_hcpt`, a high-fanout counter in the MiSTer framework whose delay is
largely ROUTING, and routing is what congestion degrades. Per-clock here:

    pll_hdmi (-> ascal|o_hcpt)   +0.307
    emu|pll general[0]           +0.354   <- ours

Do not read a single build's per-clock margin as a property of the design. An
earlier placement gave our clock +0.964; the fitter optimises until constraints
are MET and then stops, so it spends whatever it does not need.

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
the pixel-census timing fix (`075921c`) and the shared shift/rotate unit
(`4bf8434`) - all now confirmed on hardware.

It does **not** contain the 2:1 coprocessor stack. That is extracted from the
`57ce77e` WIP bundle and staged in the working tree, lint clean, UNCOMMITTED and
untested on hardware.

It does **not** contain the data cache. That change breaks the board - `P=0000`,
no video - and is parked at `be22c31`, reverted.
