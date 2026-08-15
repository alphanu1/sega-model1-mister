# M1 — M4

M0 is specified separately in `m0-mb86233-spike.md`. Nothing below starts until the M0
resource gate reports.

---

### M1 baseline, measured 2026-08-14

Reproduced before writing anything, per the plan's own warning not to assume an
imported core is a solved problem.

**Unit suite** (`third_party/s32/verif/v60/run_v60_verilator.sh`):
**22 passed, 6 build-failed.** All six failures are the Icarus white-box tests,
and none is a core fault — Icarus 13.0 refuses to compile `s32_v60.sv` at all:

```
rtl/cpu/v60/s32_v60.sv:1317: error: This assignment requires an explicit cast.
  ea_len <= 5'd1 + disp_len(modtop[1:0]);
```

21 sites, all the same shape: a function result used in arithmetic without an
explicit width cast. Verilator accepts it; Icarus 13 does not. This is the same
class of problem as the yosys strictness issues found in M0 — code that passes
one toolchain and not another — and it wants the same fix, an explicit cast at
each site. It belongs in **our** copy once the V60 is imported into `rtl/`,
because `third_party/` is gitignored and re-cloned by `bootstrap.sh`, so a
patch there would not survive.

#### MAME's V60 cycle count is a placeholder — do not target it

Before using any "we are Nx slower than MAME" figure, read
`third_party/mame/src/devices/cpu/v60/v60.cpp`:

```
614:  // Actual cycles / instruction is unknown
626:      m_icount -= 8;  /* fix me -- this is just an average */
```

That is the **only** `m_icount -=` in the file. Every V60 instruction costs a
flat 8 cycles, and MAME says in its own comment that the real figure is unknown
and this is a guess.

So the s32 baseline's "ours 22.70 vs MAME 8, about 2.8x" is not a measurement
of being 2.8x too slow. It compares against a number MAME explicitly disclaims.
Chasing CPI 10-12 to approach 8 would be optimising toward a placeholder.

**This narrows hard rule 3.** MAME is the oracle for *behaviour* — instruction
semantics, registers, flags, memory effects — and M0 leaned on that heavily and
correctly. It is **not** an oracle for V60 instruction timing, and nothing in
this project should treat it as one.

What would settle it: the uPD70616 datasheet's instruction timing tables, or
measurement against real hardware. Until then the honest target is not a CPI
number at all but whether the V60 sustains the game's real-time workload —
which is exactly what M1's bandwidth telemetry is for, and what the M0 TGP
result was framed as (9.83 cycles/instruction, 52.1 MHz needed, 1.38x headroom).

#### V60 imported, 2026-08-14

`rtl/cpu/v60/v60.sv` and `v60_bus.sv`, from `third_party/s32/rtl/cpu/v60/`.
Verified **identical to upstream modulo the casts below** — the import changed
nothing else.

**Icarus fix.** 14 sites assigned a ternary of enum members to an `st_t`
variable, which Icarus 13.0 refuses without an explicit cast and Verilator
accepts silently:

```
st <= ea_want_addr ? S_EA_DONE : S_EA_VAL;        // before
st <= st_t'(ea_want_addr ? S_EA_DONE : S_EA_VAL); // after
```

Both toolchains now compile it; `make lint` runs Verilator **and** Icarus over
the V60 on every invocation, so this cannot silently regress.

**Full suite against the imported copy: 28 passed, 0 failed** — two better than
the recorded baseline of 26, because the six Icarus white-box tests now run
here at all.

That result took two attempts, and the first one is worth recording. The
initial cast pass used a regex without a word boundary, so `st` matched the
start of `str_dst` and wrapped a 32-bit string-destination pointer in
`st_t'(...)`, truncating it to the state enum:

```
str_dst <= st_t'(subop[0] ? str_dst - 1 : str_dst + 1);   // WRONG
```

Verilator and Icarus both compiled that happily. The only thing that caught it
was `tb_v60_bits` failing `MOVBSD got=0000 want=00fb` — a test that had passed
before the import. Restoring the pristine file and re-running proved the
regression was mine rather than pre-existing.

The lesson is the one this project keeps relearning: a mechanical edit across
4,500 lines of unfamiliar code needs its diff read line by line, and needs a
test suite that was green beforehand to compare against. Both were available
and only the second one caught it.

**BLKSEQ suppressed, not fixed — flagged for review.** The source uses blocking
assignments for default-then-override signals inside `always_ff` blocks that
also use non-blocking for state, e.g. `rf_we0 = 1'b0;` alongside
`bus_owner <= OWN_NONE;`. Mixing the two in one sequential block is a genuine
footgun and `docs/rtl-conventions.md` would normally reject it. It is accepted
here because the code carries 22 passing directed tests plus a differential
harness against a Python reference, so rewriting 4,500 lines to satisfy a lint
flag risks far more than it fixes. **Revisit before the V60 is integrated**, and
treat any unexplained behaviour in that area as a prime suspect.

**The real M1 risk is timing, not correctness.** s32's own baseline records:

| | s32 V60 | MAME |
|---|---|---|
| CPI, attract gameplay | **22.70** | flat 8 |
| work vs idle, char select | 42% work | 15% work |
| FSM state distribution | **S_FILLW 40%, S_FILL 16%** | — |

56% of all cycles sit in fetch. A prefetch redesign was in progress upstream
targeting CPI ~10-12, but `docs/v60-prefetch-plan.md` is **not present** in the
vendored tree — only the baseline that references it. So that work either did
not land or is not published, and M1 should budget for doing it rather than
inheriting it.

But note the target itself is suspect, per the section above: CPI 10-12 was
chosen to approach MAME's 8, and MAME's 8 is a self-declared guess. 56% of
cycles in fetch is worth fixing on its own merits — it is a real inefficiency
regardless of what the reference says — but "how close to 8" is not the measure
of success. Whether the game's workload fits in real time is.


### SDRAM bandwidth, measured 2026-08-15

D2 and D3 both rest on a bandwidth figure that had only ever been arithmetic.
`make test_m1_sdram` now measures it against a protocol-checking device model,
with data integrity verified at the same time.

Streaming traffic — every master walking its own cursor in its own bank, which
is what the board does: V60 code fetch, tile character runs, polygon stream,
sample stream:

| | words/cycle | at 100 MHz | at 143 MHz |
|---|---|---|---|
| Aggregate, five masters | 0.153 | 30.6 MB/s | 43.8 MB/s |
| p1 alone, 4-word bursts, sequential | 0.326 | 65.2 MB/s | 93.2 MB/s |
| p0 alone, single words, sequential | 0.109 | 21.8 MB/s | 31.2 MB/s |

**D3 needs 55-75 MB/s aggregate with banding. The controller delivers 30.6 at
100 MHz.** It is short by roughly a factor of two, and closing that is M1 work,
not something to discover in M3.

Two findings behind those numbers.

The first version auto-precharged after every read, so the row closed behind
each transfer and **sequential traffic ran at exactly the same rate as random —
locality gain 1.00x**. Adding row reuse (skip PRECHARGE and ACTIVATE when the
bank and row are already open) took the gain to 1.54x on single words and 1.40x
on bursts. That change is in and measured.

What remains is that each transfer waits for its own read-capture pipeline to
drain before the next one starts, so per-transfer latency is paid serially
instead of being overlapped. A 4-word burst to an open row spends 4 cycles
issuing and about 5 draining. Overlapping the next transfer's ACTIVATE and CAS
with the previous transfer's data return is the remaining factor of two, and it
is a real redesign of the issue/capture split rather than a tuning parameter.

Note the clock matters as much as the design: the same controller at 143 MHz
delivers 43.8 MB/s. The operating point is not yet chosen and should be settled
alongside the pipelining work rather than after it.

---

## M1 — V60, bus, 2D subsystem, boot

**Work**

- Import the V60 from meathax's System 32 core (`third_party/s32/rtl/cpu/v60/`, 4.5k
  lines). Strip the System 32 profile down to what Model 1 uses: no MMU paging, no FP
  group.
- **Do not write a V60 test suite from scratch.** s32 already ships one:
  `verif/v60/` holds ~35 directed testbenches with a documented pass baseline
  (26 passed / 0 failed as of 2026-07-23), `verif/cosim/` has a differential harness
  against a Python reference plus a MAME trace instrumentation patch, and
  `verif/quartus_v60/area/` is a standalone Cyclone V area project targeting the same
  5CSEBA6U23I7 part. Read `verif/v60/BASELINE.md` first and re-baseline against it.
- The author's own note is that the V60 still needs work for correct timing, and
  BASELINE.md quantifies it: ~22.7 cycles/instruction against MAME's flat 8, with 56%
  of all cycles sitting in fetch states. A prefetch redesign was in progress. Budget for
  that work landing, or for doing it. Do not assume an imported core is a solved problem.
- MiSTer framework skeleton, MRA ROM loader, SDRAM controller with a per-master
  arbiter.
- 315-5465 address decode and interrupt logic. 315-5338A input block.
- Tilemap/text layer, palette RAM, priority mixer. No 3D path at all in this milestone.
- **Instrument the arbiter now.** Per-master cycle counters dumped to the HPS. This is
  how D2 and D3 get validated with numbers instead of arithmetic, and it costs almost
  nothing to add at this stage versus retrofitting during M3.

**Exit**

- ROM checksum self-test passes
- Text layer renders
- Service/test menu navigable via real inputs
- Bandwidth telemetry reporting sane per-master figures against the M1 traffic mix

---

## M2 — Geometry pipeline

**Work**

- Instantiate 315-5571 and 315-5572 geometrizers plus the game copro, starting with
  315-5573 (Virtua Racing). Load the decapped microcode.
- MB8421 dual-port mailboxes. 315-5464 copro/TGP glue. Command and result FIFOs,
  including the output FIFO at 0x400 that the +0x200 EA adder reaches.
- Terminate the output FIFO into a capture stub that DMAs polygon lists to the HPS.

**Exit**

- Captured polygon list stream matches MAME's, frame for frame, across a Virtua Racing
  cold boot into attract.

**Discipline:** do not start the rasterizer until that diff is clean. Every rasterizer
bug chased before this point will turn out to be a geometry bug wearing a disguise.

---

## M3 — Rasterizer and video

**Work**

- Band binning pass over the TGP's already-sorted polygon list.
- Edge-walking span filler, flat shaded, into a 64-line M10K band buffer.
  No Z-buffer: Model 1 depth-sorts in the TGP and paints back to front. That omission
  is what makes the fit possible at all.
- Band writeback and scanout. Framebuffer in SDRAM per D3; f2h DDR3 is the documented
  fallback.
- 496x384 at 24 kHz out the analog path, plus the scaler chain for HDMI.

**Exit**

- Virtua Racing attract renders correctly
- Frame image diffs against MAME within tolerance on a fixed input script
- **Profile Virtua Fighter worst-case overdraw against the M1 telemetry.** This is the
  specific case that could still force D2 to reverse. Measure it before declaring
  single-module support.

---

## M4 — Sound, inputs, full set

**Work**

- Sound board: 68000 at 10 MHz, YM3438 (ikaOPN2), 2x MultiPCM 315-5560.
- **MultiPCM is the open risk in this milestone.** It is an OPL4 derivative with the FM
  side removed, 28 PCM channels, and there is no proven MiSTer implementation to lift.
  Treat it as a mini-M0: build it standalone, verify against MAME, gate on resources
  before integrating.
- Analog input paths: wheel and pedals for Virtua Racing and Virtua Formula, flight
  stick for Star Wars Arcade and Wing War.
- Per-game copro ROM switching across 315-5573, 315-5711 and 315-5724. MRA set for all
  six titles.

**Exit**

- Virtua Racing, Virtua Formula, Virtua Fighter, Wing War, Star Wars Arcade and NetMerc
  all playable with sound.

---

## Standing risks

| Risk | Milestone | Mitigation |
|---|---|---|
| TGP area overrun | M0 | Context-multiplexed datapath fallback; kill criteria defined |
| Denormal semantics unknown | M0 | Resolve against real microcode traces, not host floats |
| V60 timing accuracy | M1 | Directed tests before integration, not after |
| Rasterizer customs undocumented | M3 | Geometry diff must be clean first so bugs localise |
| VF overdraw exceeds bandwidth | M3 | f2h DDR3 framebuffer before demanding dual SDRAM |
| MultiPCM has no prior art | M4 | Standalone spike with its own gate |
| Stale ROM definitions | all | Pull current MAME sets; 315-5711 carried two bit corruptions until recently |
