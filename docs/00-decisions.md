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

**Reversed 2026-08-15, on different grounds: one instance, not three.**

Not because that condition was met — M0 measured 2,554 ALM at 72.17 MHz, well
inside it. Because the premise was wrong.

The board carries more than one MB86233. From model1.cpp's own header:

    315-5571      - Fujitsu MB86233 Geometrizer (IC57/IC58, QFP160)
    315-5572      - Fujitsu MB86233 Geometrizer (different code) (IC60/IC66)
    COPRO         - Fujitsu MB86233 Coprocessor (QFP160), differs per game

But **MAME instantiates exactly one**, the COPRO, and produces correct output.
The Geometrizer ROMs are dumped, declared as `ROM_REGION32_LE( 0x2000,
"315_5571" )` and `"315_5572"` — and referenced nowhere else in the entire
driver. They are loaded and never executed. What MAME does instead is
`tgp_render` in model1_v.cpp, which models the rasterizing hardware in C++
downstream of the single coprocessor's display list.

Hard rule 3 makes MAME the oracle and D6 makes lockstep against it the
verification model. One instance is therefore sufficient to match the thing
this project checks itself against; three would be matching a board detail the
oracle does not exercise, at 2,554 ALM each.

Frees **5,108 ALM**, which the measured budget needs — 30,395 built against
41,910, with 12,500-19,500 still to build.

What this gives up, stated plainly: if the Geometrizers do work on real silicon
that MAME approximates elsewhere, this core will match MAME and not the board.
That is an accepted consequence of choosing MAME as the oracle, not an
oversight, and it is why this entry records it rather than quietly dropping two
instances.

Reverses if: geometry output diverges from real hardware in a way traceable to
the missing Geometrizers — which needs a real board to observe, or a game whose
output MAME itself gets wrong. Restoring them costs 2,554 ALM each and the
design is not structured to prevent it.

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

See `THIRD-PARTY.md` for the component-by-component breakdown.

---

## D8 — Five SDRAM read ports, and work RAM goes external

Derived from MAME's `model1_mem` and the ROM regions in `model1.cpp`, not estimated.

What has to live in external RAM, because it cannot fit in 696 KB of M10K beside D3's
62 KB band buffer:

| Region | Size | Port |
|---|---|---|
| V60 ROM — ROMA, ROMO (banked), ROMX, ROM0 | ~3.5 MB | p0 |
| V60 work RAM, RAMA 64 KB + RAMB 256 KB | 320 KB | p0 |
| Tile character RAM, `0x780000-0x7fffff` | 512 KB | p1 |
| TGP data ROM + polygon ROM | 2 MB + 16 MB | p2 |
| Sound 68000 program | 768 KB | p3 |
| MultiPCM samples, two banks | 8 MB | p4 |

Roughly 31 MB, which fits a single 32 MB stick — so D2 survives contact with the real
region list rather than merely being asserted.

The split that matters is **work RAM external**. Putting the 320 KB of V60 RAM in M10K
would be more comfortable for the V60 and it is the obvious first instinct, but it
consumes 46% of the block RAM the band renderer depends on. D3 is load-bearing for D2:
if the band buffer has to shrink, framebuffer traffic goes back to SDRAM and the
bandwidth budget stops closing. Work RAM is the cheaper thing to make external because
it is latency-sensitive and small, which is what a cache fixes, while the band buffer is
bandwidth-sensitive and large, which caching does not fix.

Tile *map* RAM (64 KB) and palette (64 KB) stay internal. They are read every scanline
and are small enough not to threaten the band buffer.

Reverses if: M1 telemetry shows p0 wait cycles dominating with work RAM external, and a
V60 cache does not recover it. The fallback is work RAM in M10K and a smaller band, which
costs D3 before it costs D2.

## D9 — The I/O board is an HLE, not a Z80

> **SUPERSEDED 2026-09-09: it is a real Z80 running the real BIOS.** This entry
> named its own revisit condition - "when M2, M3 and M4 are built and the real
> number is known, if there is ALM room then the LLE is worth taking on its
> merits" - and that is what happened. `rtl/io/m1_ioz80.sv` holds a tv80 and is
> instantiated unconditionally at `rtl/m1_main.sv:515`, `m1_ioboard`'s ports did
> not change as the entry predicted, and the BIOS comes in through the MRA:
> `epr-14869.25` for Virtua Racing, `epr-14869b.25` for both Star Wars MRAs.
>
> The entry's closing argument is what settled it, and it is worth restating
> because it generalises: an HLE reproduces the protocol someone read out of the
> ROM, and a Z80 running that ROM *is* the protocol. Star Wars is the case that
> proves it - a different BIOS revision and a different analogue channel map
> (0,1,2,4,5 for two sticks and a throttle, with a gap at 3) that the HLE would
> have had to be taught, and the LLE gets for nothing.
>
> The area argument it was decided on has also moved: the budget then was
> estimates, and the measured figure now is 39,825 ALM of 41,910 with the
> framework macros off.
>
> Kept in full below because the reasoning is sound and the revisit worked
> exactly as it was written to.


Deferred three times because nothing needed it: across a full boot the V60 reads
exactly one address in the DPRAM region more than twice — the status flag at
`0xc00040`, forty times — and no input data at all. The core has now reached the
service menu on hardware, so that evidence has run out and the choice has to be
made.

Both options were re-costed in `docs/m1-m4-plan.md` and both are more work than
the first estimate:

| | ALM | What it actually needs |
|---|---|---|
| HLE | ~300 | The protocol, which exists only inside the Z80 ROM — disassembling it, not inferring it |
| LLE | ~2,000 | A Z80 **and** the 315-5338A, because the DPRAM is reached through the custom chip |

**HLE, for area.** The measured budget after M1 is 15,443 ALM free, against
10,900-15,900 for everything still to build. The LLE spends about 1,700 of that
margin on the one block whose behaviour is fully observable from the outside:
the V60 only ever sees the shared RAM, so an HLE that produces the right bytes
there is indistinguishable from the real chip by construction. That is not true
of the TGP or the rasterizer, which is where the margin should be kept.

It is the more work of the two — the protocol has to be read out of the Z80 ROM
rather than obtained by running it — and that trade is the point: more effort in
exchange for room.

One correction this entry carries: the plan's summary line costs the Z80 option
at "3,000-2,500 ALM", which disagrees with its own detailed section at ~2,000.
The ~2,000 figure is the one with reasoning attached.

**Revisit when the resource count is final, which is not the same as reversing.**
The HLE is chosen here on an area budget that is still made of estimates: sound
at 5,000-7,000 ALM and the rasterizer at 3,000-6,000 are ranges, not
measurements. When M2, M3 and M4 are built and the real number is known, if
there is ALM room then the LLE is worth taking on its merits — a Z80 running
`EPR-14869` plus the 315-5338A is the real board's behaviour by construction,
including whatever the HLE turned out to approximate. The HLE is the right call
under uncertainty; it is not automatically the right call once the uncertainty
is gone.

Two things make that revisit cheap rather than a rewrite. The V60 only ever sees
the shared RAM, so HLE and LLE are interchangeable behind the same interface —
`m1_ioboard`'s ports do not change. And the ROM is already in `vr.zip`, so the
LLE needs no new asset, only the two blocks.

Reverses if: the protocol turns out not to be recoverable from the ROM by
disassembly — an undocumented handshake with the 315-5338A, or behaviour that
depends on Z80 timing rather than on the bytes in the shared RAM. The fallback
is tv80 plus the custom chip, and it costs ~1,700 ALM that would then have to
come from `S32_V60_NO_FP` (-1,987 ALM, measured, held in reserve; re-measured
on the full core 2026-08-16 at **-2,984 ALM** — the larger design gives the
lever more to remove).
