# The sound board

Brought over whole from Model 2's `rtl/sound/`, because **it already is the
Model 1 board**: `model2.cpp` instantiates `SEGAM1AUDIO` for `model2o`, the same
device `model1.cpp` uses, so `m2_sound_board` is a Model 1 sound PCB hanging off
a Model 2 main board. Reusing it was Ben's call and the right one — it is
measured, tested against MAME, and its quirks are known there rather than
rediscovered here.

Files keep their `m2_` names for now so the next pull from Model 2 is a copy
rather than a merge. Rename when the interface stops moving.

`fx68k/` and `jt12/` are upstream third-party cores, byte for byte:
`-Wno-BLKANDNBLK` is what keeps fx68k unmodified rather than editing a
cycle-exact CPU. `microrom.mem` and `nanorom.mem` are `$readmemb`'d by RELATIVE
path, so they must sit in the simulator's working directory.

## What changed for Model 1

The 64 KB work RAM at `F00000-F0FFFF` was two byte-wide `M10K` arrays —
524,288 bits, 64 blocks, and Model 1 has none free. It cannot go to MLABs
either (640 bits apiece is 819 of them, ~8,190 ALM, more than the whole board),
so it is an external request/acknowledge port like the program ROM already was,
and the 68000 waits on DTACK exactly as it already did. Measured: 82 -> 18
M10K, ALM unchanged.

## What it still needs

- the three ROMs added to the MRA and given SDRAM bases. They are already in
  `vr.zip` and unused: `epr-14870a.7` (68000 program, 128 KB),
  `mpr-14873.32` and `mpr-14876.4` (2 MB of PCM each). 4.125 MB total, and
  there is ~6 MB free above `IOFW_BASE` — no SDRAM widening required.
- the byte link wired to `m1_sound_usart` (the main board's uPD71051C at
  0xc40000, built 2026-09-10)
- SDRAM ports for the program ROM, the work RAM and the two sample ROMs
- **~5,000 ALM.** Measured standalone at 6,154 (standalone inflates; Model 2's
  in-design figure is 4,891) against 3,427 spare. This is the whole obstacle.

## Residual block RAM: 14 blocks

`fx68k`'s microcode and nanocode ROMs and `jt12`'s sine/exp tables. These are
read EVERY cycle by the sequencer and the operator slots, so they cannot go to
external memory at any latency. Forcing them to MLABs costs ~1,100 ALM;
finding 14 M10K elsewhere is cheaper. `m1_video`'s 32 line buffers are 1,920
bits each in a whole block apiece and are the obvious source.
