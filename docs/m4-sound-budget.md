# M4 — the sound board, and where the ALM comes from

The Model 1 sound section is not a design problem: it is three well-understood
chips with open implementations, and **one of this project's sibling cores
already has all three fitted and working**. What it is, is a *budget* problem —
and this document is the budget, measured rather than estimated.

Read `docs/00-decisions.md` D5 first. Moving a CPU's work RAM to SDRAM is a
decision this project has already taken once, for the V60, and the same move is
what makes the sound section's memory affordable.

---

## What the hardware is

From `third_party/mame/src/mame/sega/model1.cpp` and Virtua Racing's ROM set:

| Part | What | ROM |
|---|---|---|
| 68000 | sound CPU, 10 MHz | `epr-14870a.7`, 128 KB in a 768 KB region |
| YM3438 | OPN2C, the FM half | — |
| 315-5560 | MultiPCM #1 | `mpr-14873.32`, 2 MB of samples |
| 315-5560 | MultiPCM #2 | `mpr-14876.4`, 2 MB of samples |

**Two MultiPCMs, four megabytes of samples.** Not one — `M1AUDIO_MPCM1_REGION`
and `M1AUDIO_MPCM2_REGION` are both populated for `vr`, so a single-PCM build is
half the sample voices and is not the board.

The V60 reaches it through the **uPD71051C USART at `0xC40000`** on the MAIN
board (i8251-compatible, `model1.cpp:1014` and `:1852`), clocked at 31.25 kHz x
16. **Not** through the I/O board, and **not** through either of the other two
things in this repo that are called a UART — see the note in `CLAUDE.md`.
`m1_decode` already asserts `sel_uart` for that page.

---

## What it costs — measured, from a core that has it working

Not estimated. `sega-model2-mister`'s `Model2.fit.rpt`: the same 68000, the same
YM3438, the same two MultiPCMs, fitted on the same 5CSEBA6U23I7.

| Block | ALM | Block memory bits | **M10K** |
|---|---|---|---|
| `m2_sound_board` total | **8,837** | 572,427 | **84** |
| ├ `fx68k` (68000) | 1,995 | 39,584 | 6 |
| ├ 68000 work RAM (2 x 32,768 x 8) | 20 | 524,288 | **64** |
| ├ `jt12` (YM3438) | 631 | 7,531 | 10 |
| ├ `m2_multipcm` x2 | 3,702 | 0 | 0 |
| ├ PCM rate filters x2 | — | 1,024 | 4 |
| └ board glue | 2,509 | — | — |

**The MultiPCMs use no block memory at all** — their samples stream from SDRAM,
which is what the 4 MB forces anyway. **The 68000's 64 KB of work RAM is 76% of
the section's M10K** and costs 20 ALM: it is pure storage, and storage is exactly
what should not be in M10K on a device where M10K is the binding resource.

An M10K holds 10,240 bits, so 572,427 bits looks like 57 blocks. It is 84,
because a 32,768-deep 8-bit array packs as 32 blocks of 1024x8 with 2,048 bits
wasted in each. **Bits/10,240 understates memory cost by half here; take the
figure from the fitter's RAM summary, not from the bit count.**

---

## The two constraints, and they pull in opposite directions

- **M10K** is solved by decision D5's precedent: put the 68000's work RAM in
  SDRAM as the V60's already is. 84 -> ~20 blocks. There is an SDRAM port
  spare and the 68000 at 10 MHz is a fraction of the V60's traffic.
- **ALM is not solved, and it is the real problem.** 8,837 ALM has to come from
  somewhere in a design that is already at 71% of 41,910.

---

## Where the ALM can come from

Every number below is measured on this core or on the sibling; none is an
estimate. See `docs/findings.md` for the entries behind each.

| Lever | ALM | Verdict |
|---|---|---|
| **The V60** | 17,453 in-core, **48% of the whole design** | the only block big enough |
| ├ FP group | -1,942 standalone | **BLOCKED** — a run under `S32_V60_NO_FP` executes a *reserved* FP opcode at `FED52B`. That is a symptom of the V60 reaching a page MAME never enters, not evidence the game uses FP, and removing the group trades one wrong behaviour for another. |
| ├ realign shift 8 | -46 in-core | already reverted; it was 485 standalone, which is the standalone-vs-in-core trap again |
| ├ loop cache | -167, +4% CPI | worst ratio of the three; stays |
| └ **the V60 itself** | Model 2's i960 does the equivalent job in **7,200** | this is the lever. See below. |
| `m1_raster3d` | 6,597 | the picture; not available |
| `m1_tgp` | 2,423 | the coprocessor; not available |
| `m1_diag` overlay | 183 | not worth the debugging it would cost |
| Aggressive Area on the full core | -469 to -595, **+11 M10K** and almost all the setup slack | measured twice; it spends the binding resource to save the plentiful one |

### The V60 is the answer and it is a project, not a knob

17,453 ALM for a CPU that retires in 3 cycles against a bus that is the actual
bottleneck (`docs/findings.md`, "SPEED: 35.0 -> 23.7 cycles per instruction").
Model 2's i960 — a wider, faster machine — is **7,200**. The V60 arrived from the
s32 project as a 4,601-line FSM with 128 distinct adder nodes and an FSM that
steps through 28% of its cycles doing nothing on the bus.

What is already known about it, so nobody re-derives it:

- **The register file is not the hog.** 105 references to `r[]`, 52 of them
  `r[31]`, only four with a variable index. Constant reads are free.
- **The replicated adders are real** — 128 `Add*` nodes, the PC alone with 19
  increment sites at different deltas — but sharing them means restructuring the
  whole FSM.
- **`fb32(o)`/`fb16(o)` expand to four and two 24:1 byte muxes each**, at five
  call sites across different always blocks. Naming them as shared wires **broke
  `tb_v60_search`** and was reverted. Worth retrying only after understanding
  why, not by assuming Quartus was not already sharing them.

**A V60 area pass is the single highest-value piece of work left in this
project**, and it is worth more than the sound board: it is the difference
between a core that fits M4 and one that does not.

---

## The order to do it in

1. **Move the 68000 work RAM to SDRAM before writing any of the sound RTL.**
   Doing it afterwards means writing the memory interface twice, and the
   precedent (D5) and the port are both already there. -64 M10K.
2. **Build the sound board with both MultiPCMs and no compromise**, and measure
   it in this core rather than trusting the sibling's number. A block measured
   alone with virtual pins is not the block in context: the V60 reports 20,129
   standalone and 17,453 in place.
3. **Then find the ALM in the V60**, with the three notes above as the starting
   point and `bash tools/run_v60_tests.sh` plus `make v60_trace` as the guard
   rails. 29/29 unit tests and an instruction-stream diff against MAME make this
   the safest large refactor in the repo — which is exactly why it is worth
   attempting at all.

**Do not start the sound RTL by cutting a MultiPCM to make the numbers fit.**
That is a decision about what the core sounds like, taken to avoid a decision
about what the V60 costs.
