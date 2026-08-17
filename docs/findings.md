# Findings — what is established, and how

The durable record of **measured facts** about this hardware, separate from
`HANDOFF.md` (which is the state of play and changes weekly) and from the
per-topic investigations that produced them.

**Why this file exists.** Three findings have been re-derived from scratch after
being established once, and several conclusions were reached twice — the second
time correcting the first. A finding is only worth the measurement if the next
session can find it.

**Rules for entries here.** Every entry states what was measured, with what
instrument, and what it corrected. Anything not measured says so. When an entry
turns out to be wrong it is **corrected in place with the old reading kept
visible** — a doc that silently rewrites itself stops being trustworthy, and
knowing which way we were wrong is often the useful part.

Topic detail lives in: `io-board.md`, `2d-gap-analysis.md`,
`m2-tgp-integration.md`, `mister-integration.md`, `debug-overlay.md`.

---

## Reasoning has lost to measurement five times

Kept as a table because the pattern is the point, not the individual entries.

| Question | Reasoning said | Measurement said |
|---|---|---|
| where do the inputs live | a mailbox at DPRAM `0x100` | `0x00`-`0x0e`, polled every frame |
| why is most of the 2D missing | the row mask, then the window mode | neither — the V60 never gets that far |
| does the V60 read the coprocessor back | it must, to collect results | **never**, in 2,500 accesses |
| what blocks the coprocessor | the math units returning zero | the **data ROM**, read before any math unit |
| how deep are the coprocessor FIFOs | 64 seemed like sensible slack | **16**, and full halts the CPU |

Three cost a session or more. Every one was a plausible mechanism reasoned from
partial evidence that a five-minute instrument would have refuted. Hence the
rule: **when something is unknown, run MAME** — see `HANDOFF.md`.

---

## The I/O board

**The complete control map is measured**, not inferred. MAME running the real
Z80, one control held at a time.

| DPRAM | Contents |
|---|---|
| `0x00` | steering, centre `0x80`, full `00`-`ff` travel |
| `0x01` | accelerator, **released `0x01`**, floored `0xff` |
| `0x02` | brake, same shape |
| `0x03`-`0x07` | set to `0xff` at startup; contents unknown |
| `0x08` | IN.0 — coin 1, coin 2, test, service, start, VR1-3 |
| `0x09` | IN.1 — VR4 bit 0, shift down/up bits 4/5 |
| `0x0a` | IN.2 — drive-board RX, unused here |
| `0x0b`-`0x0d` | DSW1-3 |
| `0x0e` | chip port 6 |
| `0x0f`, `0x10` | read by the V60; **`0x0f` is also written by it** — not ours to publish |

Idle is **not** uniform: digital bytes rest at `0xff` (active low), a released
pedal at `0x01`. Publishing a blanket `0xff` is both pedals floored.

One row self-checks: the operator reported pressing F2 twice by accident, and
`0x08 -> fb` appears exactly twice in the log.

**A 128-byte identity block at DPRAM `0x100`-`0x17f` is what unblocked boot.** The
V60 block-reads all of it once, immediately after its first handshake is
answered, and will not poll its controls until it has. Nothing writes that window
beforehand, so the board supplies it. Contents in `io-board.md`.

**This is per-game, but barely.** The DPRAM addresses are board hardware — same
315-5338A, same `EPR-14869` in every cabinet. MAME carries six input maps across
ten Model 1 entries and the *system* half of IN.0 (coin 1, coin 2, test, service,
start) is bit-identical in all of them.

---

## The 2D path

**The missing 2D was never a rendering fault.** Our tile RAM at frame 71 matches
MAME at frame 71 exactly, including 370 category-1 tiles on map 0 — not a number
to match by chance. MAME writes the text, the scroll registers and the row-mask
table only between frames 150 and 300, and our V60 stops advancing before that.

Everything chased before that was a difference in **program state**, not in
pixels. Two real gaps were found on the way and both are worth keeping:

- **The row mask is implemented** and verified: segas24 masks each tilemap in
  8-pixel columns from tile RAM `0x6000` (maps 0/1) or `0x6800` (2/3), four words
  per scanline, and each tilemap is drawn twice with the mask inverted for the
  second pass — so a column shows whichever category matches its mask bit.
  Ignoring it equals `m = 0`, which MAME treats as "draw all 128 pixels".
- **`ctrl & 0x6000` window/split-scroll mode is NOT implemented.** Confirmed
  active in the reference (`ctrl = 0x2058`). The four tilemaps are two **pairs**,
  not four peers — odd maps are window maps, drawn only through their even
  partner — and `ctrl` is the pair's even `vscr`, not each map's own register.

**The mixer's draw order and opaque flags are confirmed** against
`model1_v.cpp`, not inferred: layers `6,4` opaque then `2,0`, then the 3D, then
`7,5,3,1`. Our `opaque_pass = (i >= 2)` and paint order match exactly.

Ruled out by measurement: fetch bandwidth (**zero** deadline misses; an overrun
repeats a scanline anyway, which is not the symptom) and the ROM set (29/29,
zero CRC mismatches).

---

## The coprocessor

**The V60 never reads back from it.** Over 2,500 logged accesses the reference
does 1,198 FIFO writes, 102 address-register writes, two status reads, and **zero
FIFO reads and zero copro RAM data accesses**. The TGP's output goes to the
renderer, not to the CPU. So a core showing "returns=0, pops=0" is behaving
correctly.

**Flow control is by halting a CPU, not by a status register.** `setup(16, ...)`
on both FIFOs, and `gen_fifo.h` names the callbacks: empty halts the TGP, full
halts the **V60**, un-empty and un-full release them. That is why
`fifoin_status_r` can be a constant `0xffff` nobody polls. **Depth is 16.** A
push into a full FIFO must stall, never drop — dropping loses geometry with no
counter moving anywhere.

**The data ROM is the coprocessor's first blocker, not the math units.** Its
opening move at frame 0:

```
W DATABASE 002e = 00000010      set the window base
R DATAROM  8010 = 00000030      read a word out of it
R DATAROM  8020 = 00012e00      and another — which becomes the NEXT base
```

Two data-ROM reads before any math unit is touched, and the second value is
itself a window base. **Those two words are a free test vector** for whatever
wires that memory up.

Nothing in the IO space is optional. To frame 400: DATAROM 70,119 reads, SINCOS
21,548/13,337, INV 11,072/5,536, ISQRT 9,332/4,666, ATAN 1,008/4,032.

**The two sides' copro RAM rules differ**, and both are on the same 8192x32 RAM:

| | V60 | TGP |
|---|---|---|
| address registers | one | **four**, selected by IO address bits 4:3 |
| increment | only when bit 15 set, by 1 | **always**, by **4** when bit 18 set else 1 |
| commit | on the **high** half of a 16-bit pair | whole 32-bit word |

**The four math units are table lookups**, not arithmetic: a 256 KB ROM in four
16K-word quadrants — sincos `0x0000`, atan `0x4000`, inv `0x8000`, isqrt
`0xc000` — each an index computation plus an exponent fixup. `atan` carries a
**deliberate table-bug correction** that MAME reproduces, with a comment saying
the hardware does something equivalent. Reproduce it; do not tidy it.

### Where the V60 diverges, located to one instruction

The two cores agree exactly at `pc=fed58f`, reading the copro RAM address
register and getting the same value:

```
ours   cyc 524303849  d00000 -> 00  be=11  pc=fed58f
MAME   f272           R d00000 = 0000     pc=fed58f
```

The reference then reaches `pc=fed5b9`, where it writes `0x8001` and reads it
back. Ours loops at `fed5a4`/`fed5a7`/`fed5a9` — **between** those two points.

**That loop takes no data reads.** A PC-filtered read tap over `fed580`-`fed5d0`
on the reference finds only the two `d00000` accesses above; nothing at
`fed5a4`-`fed5a9`. So it is compute and branch, not a poll — we are not failing to
supply something it waits for, our V60 is computing a different result and
branching differently.

That is a different class of problem from everything above, and the instrument
for it is instruction-level lockstep against the reference, not bus archaeology.

**A number to distrust:** "510 accesses to `0xd00000`" appears in earlier commit
messages and was measured before the coprocessor interface existed, when that
region read `0xFFFF`. It is now **2**. Wiring the interface changed the V60's
behaviour materially, and that was initially mis-read as no change.

---

## Instruments, and what each cannot do

- **A read tap and a memory watch are different tools.** A read leaves no trace
  in memory, so watching contents cannot find where something is *read*. Not
  knowing this cost a day.
- **A saturating counter that reports its cap as a value is worse than no
  instrument**, because it produces a confident number. The boot trace's
  watch-page tables held 32 entries and filled silently, so "the V60 touches 32
  addresses and none is `0x08`" was a table limit reported as a finding. They
  hold 256 now.
- **A cumulative counter is not a rate.** 6,849 deadline misses over 103 frames
  read as "one line in six"; every miss was before frame 31 and 72 consecutive
  frames were clean.
- **A test comparing two empty sets passes and proves nothing.** The loader test
  reported "0 program words, 0 mismatches" and went green when a helper was
  overriding the download index. Assert there is something to check.
- **A guard test must fail if it stops measuring.** The single-cycle strobe test
  asserts both that one strobe advances one word *and* that three advance three.
- **`make area` is not `make quartus`.** Generic 6-LUT mapping built
  `m1_copro_if`'s 256 Kbit RAM out of logic and reported 17,737 LUTs against the
  real 1,244 ALM and 33 M10K — a 14x disagreement, and only one of them measures
  the thing.
- **"Non-black pixels" is not a liveness metric.** 15.7 M non-black was one flat
  blue field.
- **Verify against data that can distinguish the fault.** The SDRAM word-late bug
  survived a session because it was checked at word 0, where the ROM is
  `000d 000d 000d 000d` — the one address where a one-word shift cannot show.

### MAME harness details, each of which cost a run

`-skip_gameinfo` or the warning screen blocks autoboot and the script silently
never loads. `-autoboot_delay 0` or a tap installs after the exchange it was
meant to capture. Assign every notifier and tap to a **global** or the
subscription is collected and the callback stops with no error. Wrap notifier
bodies in `pcall` — errors inside them vanish. Run from a scratch directory:
MAME drops `cfg/`, `nvram/` and `snap/` wherever it starts.

**Audit every ROM source MAME searches**, not the one that is easiest to open.
MAME resolves a set from the zip *and* from a directory named after it; auditing
only `vr.zip` produced a confident wrong claim that three files were missing,
and a theory built on top of it.

---

## Measured resource costs

Quartus 17.0, 5CSEBA6U23I7, on the real core unless stated.

| | ALM | M10K | note |
|---|---|---|---|
| whole core, before M2 | 26,663 | 409 | timing +0.401 ns |
| **`s32_v60` alone** | **17,691** | — | **67% of the design** |
| `ascal` + framework | ~3,600 | 54 | not ours |
| everything we wrote | <1,000 | — | before M2 |
| `m1_copro_if` | 1,244 | 33 | `RAM_BLOCK_TYPE = M10K` confirmed |
| row mask | +204 | 0 | line-buffer word 14 -> 15 bits was free |
| debug overlay | 307 | 0 | |
| `S32_V60_NO_FP` | **-2,984** | 0 | unspent; `-1,987` recorded earlier on a smaller design |

**The V60 being 67% of the design is the fact that decides where optimisation is
worth any effort.** Squeezing our own code cannot matter.

M10K is the binding resource. Reserves, in order of value: tile RAM and palette
are each held **twice** (80 blocks of pure redundancy, and the video side has 5:1
clock slack to interleave a CPU read); display lists to SDRAM (128 blocks,
sequential access, consumer not yet built); line buffers to MLAB (12 blocks for
~480 ALM — they use 17% of each block).
