# Decision record

Decisions are locked unless a milestone exit produces measurements that contradict them.
Each entry records what was decided, why, and what would reverse it.

---

## D1 — Target is Sega Model 1

Unclaimed on MiSTer. Sits at the Cyclone V ceiling without being past it (no texture
mapping, no Z-buffer). Software emulation is still incomplete, so the work is ahead of
the state of the art rather than a re-implementation of a solved problem.

Reverses if: someone announces a Model 1 core with real progress.

---

## D2 — Single SDRAM module is a hard requirement

Dual-SDRAM installs are a minority. A core that requires two sticks strands most of its
audience before it ships.

Reverses if: M3 profiling of Virtua Fighter worst-case overdraw shows the band renderer
cannot close. Even then, prefer f2h DDR3 for the framebuffer over demanding a second stick.

---

## D3 — Band renderer, framebuffer traffic stays off external RAM

The TGP already depth-sorts the polygon list. Binning that sorted list into horizontal
bands is close to free. Render a 64-line band into M10K, stream it out, advance.

496 x 64 x 16bpp = 62 KB against 696 KB of M10K total.

This removes fill *and* clear traffic from SDRAM entirely, which is the single largest
term in the bandwidth budget. Naive full-framebuffer-in-SDRAM lands at 130-160 MB/s
against ~120-140 MB/s usable. Banding takes it to roughly 55-75 MB/s.

Reverses if: polygon ordering semantics turn out to require true full-frame state that
cannot be reconstructed per band. Fallback is framebuffer in DDR3 via f2h.

---

## D4 — Three physical TGP instances, not one multiplexed datapath

**This reverses my earlier estimate.** Reading MAME's `mb86233.cpp` changes the cost
picture substantially:

- The TGP is **IEEE-754 single precision**, not a proprietary float format.
  Standard 8-bit exponent, 24-bit significand.
- The fixed-point mode does not need implementing at all. MAME's own note: all Sega
  programs enable floating point at startup and stay there, and MAME does not implement
  fixed point.
- The FP datapath is one multiplier and one adder operating in parallel
  (`A*B -> P` concurrent with `D +/- P -> D`). Not a wide vector unit.
- A 24x24 mantissa multiply fits in **one** Cyclone V variable-precision DSP block
  (27x27 mode), not the 6-8 I assumed.
- `execute_clocks_to_cycles` is `clocks/3`: three input clocks per instruction cycle.
  At a 16 MHz part clock that is ~5.3 M instructions/sec. FP ops take a further cycle.
  Fmax pressure is close to nil.

Revised per-instance estimate: **2.5-4K ALM, 1-2 DSP blocks, 3-4 M10K**.
Three instances lands around 8-12K ALM and 3-6 DSP. That is affordable outright, and
physical instances keep the inter-TGP mailbox and FIFO semantics honest instead of
inventing arbitration that the real board does not have.

Reverses if: M0 measures a single instance above 6K ALM or below 60 MHz Fmax.

---

## D5 — Virtua Racing is the bring-up title

Its copro ROM (315-5573) is the best understood of the three, and the geometry path is
exercised heavily by the attract mode with no player input needed. Virtua Fighter is
last: highest tilemap load, worst-case overdraw, and the least-documented copro (315-5724).

---

## D6 — Verification is lockstep against MAME, not eyeballing

Every CPU-class block gets instruction-level trace diffing against MAME as an oracle
before it is integrated. frangarcj's `geometrizer` project already runs V60 and MB86233
in lockstep against MAME with per-opcode fuzzing; that harness gets ported to drive
Verilator rather than rebuilt.

Corollary: pull current MAME ROM definitions. The 315-5711 dump carried two single-bit
corruptions until recently. An old set makes Wing War fail in ways that look like core
bugs.

---

## D7 — Licence is GPL-3.0-or-later

Forced, not preferred.

The V60 comes from `meathax/s32`, which is GPL-3.0. GPL-3 cannot combine with GPL-2-only
code. MiSTer's `sys/` is GPL-2-**or-later** per its file headers, so it upgrades to GPL-3
and the combination is lawful.

Cost of this: most MiSTer cores are GPL-2-or-later. Code can flow *into* this repo from
them, but not back out. That is a real ecosystem cost, accepted in exchange for not
writing a 4.5k-line V60 from scratch.

Separate constraint, unrelated to the above: `frangarcj/geometrizer` ships **no licence
file**, so all rights are reserved. It may be run as an external oracle and read as a
behavioural reference. Its code may not be copied or adapted into this tree — harness
included. Reimplement against MAME's BSD-3-Clause device model instead, or get explicit
permission.

Reverses if: the s32 V60 is dropped for an independently written one, or meathax agrees
to dual-license. Nothing else in the tree blocks a move to GPL-2-or-later.

See `THIRD_PARTY.md` for the component-by-component breakdown.
