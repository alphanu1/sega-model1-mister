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

#### Does Model 1 use V60 floating point? — evidence, 2026-08-15

Enabling `S32_V60_NO_FP` is worth ~2,000 ALM and takes Fmax from 24.6 to 45.5
MHz, and the only thing blocking it is whether any game executes a V60 FP
instruction. Two lines of evidence, neither conclusive alone.

**Static.** The FP group is two opcodes, 0x5C and 0x5F, each followed by a byte
whose low five bits must be a valid sub-opcode. Scanning the V60 program ROMs
for those pairs, against a baseline computed from each image's own byte
distribution rather than assuming uniform bytes:

| | valid-subop rate | expected for that image |
|---|---|---|
| vr, 0x5C | 14.4% | 40.6% |
| vr, 0x5F | 42.4% | 38.8% |
| vf, 0x5C | 14.9% | 31.2% |
| vf, 0x5F | 5.3% | 16.2% |

Every figure is at or below chance for that image; a real FP instruction stream
would show an excess. (A first pass using a uniform-random baseline looked
alarming for `vr` 0x5F purely because that image is 29% zero-fill, which
inflates any `xx 0x00` pairing.)

This cannot prove absence. It is a byte scan, not a disassembly: it cannot tell
code from data, cannot establish reachability, and only `vr` and `vf` program
ROM layouts were mapped.

**Dynamic, and this is the one that settles it.** The core now raises a sticky
`dbg_fp_trap` when a build without the FP group meets an FP opcode, and
`make m1_main` fails on it. Silence across real code means the build is safe;
one assertion names the PC. The same target runs a fourth configuration with an
FP opcode planted in the test program, which must trap — because a detector
that has never fired is indistinguishable from one wired to nothing.

Remaining work: run it against real game code once boot exists. Until then the
option is evidenced but not taken.

---

#### V60 without the FP group, measured 2026-08-15

The M1 work list already says to "strip the System 32 profile down to what
Model 1 uses: no MMU paging, no FP group". s32 provides that as a preprocessor
define, `S32_V60_NO_FP`, with a testbench asserting FP opcodes then take the
architectural reserved-instruction vector. `make quartus MOD=s32_v60
QDEFS=S32_V60_NO_FP=1`:

| | with FP | without FP |
|---|---|---|
| ALM | 20,000 | 18,013 (-1,987, -10%) |
| Fmax | 24.62 MHz | **45.54 MHz (+85%)** |
| DSP | 16 | 15 |

**The Fmax is the result, not the area.** The FP group sits on the critical
path, and removing it nearly doubles the closing frequency. Combined with the
fetch measurement above, that removes timing as a V60 concern with margin:
matching a 16 MHz part needs `F >= 16 * CPI_ours / CPI_real`, and at 45.54 MHz
even pessimistic assumptions on both sides fit.

The unit suite with the define set: **27 passed, 2 failed, and the two are
`tb_v60_fp` and `tb_v60_fpdecode`.** Nothing outside the FP group is affected.

**Not enabled yet, deliberately.** Whether Model 1 game code executes V60 FP
instructions is unverified. It is plausible that it does not — the TGP exists
precisely because the V60's own floating point was inadequate for the job — but
plausible is not measured, and a core that traps on an instruction the game
really uses fails in a way that looks like a decode bug. The boot test settles
it, and until then this is a one-variable build switch held in reserve rather
than a decision taken.

What it does change now: **V60 Fmax should stop driving decisions.** There is a
known 45.54 MHz configuration available the moment it is needed.

---

#### V60 fetch, measured 2026-08-15 — the prefetch is already in, and it works

**Correction to the figures quoted above.** BASELINE.md's 22.7 cycles/instruction
and "56% of all cycles in fetch" are its own Phase 0 capture, taken *before* the
prefetch redesign: "Captured 2026-07-23 before the fetch/prefetch redesign". The
copy imported into `rtl/cpu/v60/` already contains that redesign — `v60.sv:802`
notes S_FILLW "is retained for the enum but no longer reached: instruction fetch
is performed asynchronously by the PFU". Those numbers describe the old code.

`make v60_cpi` measures the current one. Production cadence (/3 clock enable),
sweeping memory acknowledge latency, CPU cycles per instruction:

| memory latency | FAST_IFETCH=0 | FAST_IFETCH=1 |
|---|---|---|
| 0 | 6.08 | 6.00 |
| 8 | 6.22 | 6.01 |
| 32 | 6.69 | 6.05 |
| 64 | 6.45 | **6.11** |

**With the wide fetch port the core is effectively immune to memory latency** —
64-cycle memory costs 1.8%. Five line fetches served a 514-instruction run, and
`dreads` fell to zero: all instruction traffic left the data port. That matters
directly, because m1_sdram measured a worst case of 86 cycles under load from
five masters, and this says the V60 can live with it.

**FAST_IFETCH defaults to 0 and must be turned on for this core.** s32 leaves it
off because their unit tests run at ce=1 where the data adapter is already fast
and `if_*` can stay unconnected. On the real board that default is the slow
path. The port wants an 8-byte line, which is exactly a 4-word burst on
m1_sdram — the same shape p1 and p2 already serve — so this is wiring, not a
redesign.

**What this does NOT establish.** The benchmark is a 12-byte loop, the best
possible case for a fetch window: once resident it never misses. It proves
latency *tolerance*, not real-code CPI. BASELINE's 22.7 came from ga2 attract
gameplay with far worse locality, and the equivalent number for this core needs
real game code — which is what M1's boot test provides. Neither of s32's fetch
tests can settle it either: `tb_v60_fetch` runs ce=1 with the fast port off, so
there is no latency to hide, and `tb_v60_fetch_wide` serves the wide port with
zero latency, assuming away the thing the prefetch exists to survive. Both
report cycles≈3128, which read side by side suggests the redesign achieved
nothing; it cannot have, because neither configuration lets it do anything.

---

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

**Closed 2026-08-15.** Two changes took it from 30.6 to 100.2 MB/s at 100 MHz,
which clears the requirement with margin:

| | words/cycle | at 100 MHz |
|---|---|---|
| original, auto-precharge every read | 0.153 | 30.6 MB/s |
| + per-bank open rows | 0.209 | 41.7 MB/s |
| + pipelined tagged capture | 0.501 | 100.2 MB/s |

**Per-bank open rows.** The device holds an open row in each of four banks; the
controller tracked one and closed all four on every row change. With five
masters interleaving, p0's access evicted p1's row and nearly every transfer
became a row miss.

**Pipelined capture.** Each transfer waited for its own read data to drain — 5
dead cycles of a 10-cycle row-hit burst — before the next could start. Tagging
each CAS with its port and word index makes capture independent of issue, so
the FSM never waits for data it has already asked for.

Single-master figures are unchanged at 0.109 and 0.326 words/cycle, and that is
expected rather than a disappointment: one master with one outstanding request
is bounded by round-trip latency, not by the controller. The aggregate gain
comes from overlapping *different* masters. A master that needs more on its own
has to issue multiple outstanding requests.

Three bugs surfaced only once the drain stall was removed, and all three would
have been extremely hard to find later:

- `pend` was doing double duty as "wants service" and "not yet serviced". With
  the stall gone the FSM re-entered arbitration while data was in flight, saw
  `pend` still set, and re-dispatched the same transaction.
- `inflight` cleared one cycle before `pend` did, leaving a window where the
  arbiter re-dispatched a completed transaction's stale address. Every read
  returned the previous word — which looks exactly like a broken data path.
- Refresh starved completely. It required an empty read pipeline, and under
  continuous traffic the pipeline is never empty. On hardware that is silent
  data decay.

Two findings behind those numbers.

The first version auto-precharged after every read, so the row closed behind
each transfer and **sequential traffic ran at exactly the same rate as random —
locality gain 1.00x**. Adding row reuse (skip PRECHARGE and ACTIVATE when the
bank and row are already open) took the gain to 1.54x on single words and 1.40x
on bursts. That change is in and measured.

The clock still matters: the same controller at 143 MHz reaches 143 MB/s. The
operating point is not yet chosen, and 100 MHz already clears the requirement,
so the choice can now be made on Fmax closure rather than on bandwidth.

---

### Resource breakdown, measured 2026-08-15

Quartus, standalone per-module builds, virtual pins, `Aggressive Performance`.
Device is the DE10-Nano's 5CSEBA6U23I7: **41,910 ALM, 112 DSP, 553 M10K**.

| Block | ALM | % dev | DSP | M10K | Fmax | Toolchain |
|---|---|---|---|---|---|---|
| `s32_v60` | 20,000 | 47.7% | 16 | 0 | 24.62 MHz | 24.1std |
| `mb86233_core` x3 (D4) | 7,662 | 18.3% | 3 | 18 | 72.17 MHz | 17.0 |
| `m1_sdram` | 937 | 2.2% | 0 | 0 | 88.78 MHz | 24.1std |
| `bw_monitor` | 381 | 0.9% | 0 | 0 | 237.64 MHz | 24.1std |
| **committed so far** | **28,980** | **69.1%** | 19 | 18 | | |
| **left for everything else** | **12,930** | **30.9%** | 93 | 535 | | |

TGP internals, for reference — these are inside `mb86233_core`, not additional:
`mb86233_alu` 1,522 (containing `fp_mul` 161, `fp_add` 406, `fp_div` 263),
`mb86233_regs` 644, `mb86233_agu` 176, `mb86233_seq` 174, `mb86233_mem` 123 +
3 M10K, `mb86233_dec` 121, `mb86233_xfer` 28. They sum to ~2,788 against the
core's 2,554 because synthesis optimises across the boundaries.

**Still to build:** MiSTer `sys/` framework (typically 2.5-4K ALM), tilemap and
text layer, palette, priority mixer, the M3 rasterizer, sound (68000 + YM3438 +
two MultiPCM), 315-5338A I/O and 315-5465 decode. That does not fit in 12,930
comfortably, and the rasterizer is the largest single item still unwritten.

#### The V60 is the problem, on both axes

At 20,000 ALM it is 48% of the device on its own — more than twice all three
TGPs combined. Rebuilt with `QOPT="Aggressive Area"` it is 17,406, so the real
figure is 17.4-20K depending on target; either way it dominates.

The shape says why: **28,990 combinational ALUTs against 4,148 registers.** That
is a very flat design — wide combinational decode and muxing with little
pipelining — which is also why **Fmax is 24.62 MHz, and 24.00 MHz under area
optimisation.** Fmax barely moves between the two, so it is structural rather
than an artefact of how it was compiled.

Whether 24.62 MHz is enough is not yet answerable, and the reason is the
placeholder problem recorded above: Model 1's V60 runs at 16 MHz, this core
takes ~22.7 cycles/instruction, and the real chip's cycles/instruction is
unknown because MAME's flat 8 is explicitly a guess. If the real figure were 8,
the RTL would need ~45 MHz; if 12, ~30 MHz. Both are above what it closes at.

The encouraging part is that one piece of work addresses both axes. BASELINE.md
puts 56% of all cycles in fetch states, and a prefetch redesign both lowers
cycles/instruction — which lowers the Fmax needed — and is likely to break up
the combinational fetch path that is inflating area and limiting Fmax. That
makes it the highest-value V60 work, and it should happen before anything is
concluded about whether the whole design fits.

**Caveat on these numbers.** Standalone per-module builds with virtual pins,
summed. A real integrated build differs in both directions: cross-boundary
optimisation can reduce, while routing congestion above ~70% utilisation
usually costs Fmax. The three modules marked 24.1std were taken on the wrong
toolchain and want re-measuring on 17.0, which is now the Makefile default.

---

### Tilemap scanline budget, measured 2026-08-15

`make test_tile_fetch` reports cycles per layer per scanline against the real
budget. A scanline is 656 pixel clocks at 16 MHz, about 41 us, which at 100 MHz
is ~4100 SDRAM cycles for all four layers together.

| content | cycles/layer/line | x4 layers | fits 4100? |
|---|---|---|---|
| text / menu, tiles repeat | 699 | 2,796 | yes |
| worst case, every tile distinct | 1,614 | 6,456 | **no, by 57%** |

**M1's exit criteria fit; the worst case does not.** The text layer and the
service menu are exactly the repeated-tile case — a menu is mostly one blank
tile and one font — so booting and navigating is comfortable. Four layers of
entirely distinct characters is not, and that is a real limit rather than a
pessimistic estimate.

Three things would close it when it matters, in increasing order of effort: a
multi-entry tile cache instead of the single retained row; fetching the full
4-word burst the controller already serves, which covers two character rows per
transaction instead of one; or simply that games rarely enable four dense
layers at once. The measurement is in the test output, so this stays visible
rather than being rediscovered in M3.

---

### Real Virtua Racing boot, measured 2026-08-15

`make m1_boot` runs Sega's actual ROM: reset vector at 0xfffffff0, fetch through
m1_decode's packed mapping, real startup code. 200M core cycles / 66.7M CPU
cycles.

**Real-code cycles per instruction: 8.56.** 7,786,593 instructions. This is the
number the timing argument needed and could not get from a twelve-byte loop.
Matching a 16 MHz part requires `F >= 16 * 8.56 / CPI_real`:

| real V60 CPI | Fmax needed | with FP (24.62) | without FP (45.54) |
|---|---|---|---|
| 8 (MAME's placeholder) | 17.1 MHz | fits | fits |
| 12 | 11.4 MHz | fits | fits |

**V60 timing is closed.** Even against MAME's disclaimed flat-8, and even with
the FP group left in, there is margin. The `NO_FP` option is now purely an area
and headroom decision rather than a timing one.

Caveat kept in the output: the average includes the V60's block group
(MOVC/CMPC), one instruction that runs for as long as the block. Over 7.8M
instructions those are a small fraction, unlike the first run where a single
block instruction checksumming ROM produced an apparent 199.

**No FP opcode in 7.8M instructions.** `dbg_fp_trap` never asserted. Combined
with the ROM scan finding no excess of FP-shaped byte pairs, that is good
evidence for building without the FP group — worth ~2,000 ALM and taking Fmax
to 45.54 MHz. Not conclusive until attract mode and gameplay run too.

**No SDRAM protocol violations** across the whole run.

#### Where boot stops, and what it wants next

Bus accesses by region, busiest first:

| region | accesses | what |
|---|---|---|
| 0xc00000 | 3,791,847 | **I/O board dual-port RAM** |
| 0x100000-0x130000 | ~146,000 | banked data ROM checksum |
| 0x700000, 0x780000-0x7d0000 | ~215,000 | tile and character RAM |
| 0x910000 | 40,960 | colour translation table |
| 0x400000-0x530000 | ~161,000 | NVRAM and work RAM tests |

The memory test and the ROM checksum both complete — the PC range widens from a
single stuck loop to 0xfc3b49..0xfffff0 once the data ROMs are preloaded, which
is what a passing checksum looks like. It then polls 0xc00000 nearly four
million times.

**So the next thing boot needs is the 315-5338A I/O board**, not the framework,
not the video path, and not more CPU work. That is a precise answer that no
amount of reasoning about the memory map would have produced.

---

### The I/O board, investigated 2026-08-15

Boot stops polling one byte, and this is what stands behind it.

**What the V60 does.** Writes four bytes at DPRAM 0x1a-0x1d (V60 0xc00034-3a),
then reads DPRAM 0x20 (V60 0xc00040) 3,791,843 times and nothing else. A
command/response handshake with a single status byte.

**What produces the response.** A Z80 at 4 MHz running `epr-14869` (16 KB
mapped of a 64 KB device), with an MB8464 SRAM, a 93C46 EEPROM, an MSM6253 ADC
and a Sega 315-5338A. The Z80's own memory map has NO dual-port RAM in it:
model1io.cpp maps ROM at 0x0000, RAM at 0x4000, the 315-5338A at 0x8000 and the
ADC at 0xc000. It reaches the DPRAM **through the 315-5338A**, whose read and
write callbacks model1.cpp wires to the DPRAM's left port.

**What is not available.** The 315-5338A source is not in the sparse MAME
checkout, and the DPRAM layout is documented nowhere else. The single layout
fact `model1.cpp` exposes is netmerc writing pose data at 0x80-0x8b.

#### The handshake, observed 2026-08-15

Logging the write DATA rather than just the addresses answers what the V60 is
asking for:

    cyc 17991096   c00034  data=53      'S'
    cyc 17991162   c00036  data=45      'E'
    cyc 17991231   c00038  data=47      'G'
    cyc 17991297   c0003a  data=41      'A'
    cyc 17991492   c00040  data=01      request flag

The V60 writes the ASCII signature **"SEGA"** into DPRAM 0x1a-0x1d, writes 1 to
DPRAM 0x20, and then polls 0x20 and nothing else. A signature plus a
request flag, waiting for the other side to change the flag.

That is a protocol shape, not a guess, and it came from reading the request
before inventing a reply. The next step is correspondingly narrow: have the
responder change 0x20 and see whether the V60 proceeds. If it does, the trace
names whatever it asks for next; if it does not, the question is only what value
it expects, against a known handshake rather than an unknown one.

Worth noting for whichever implementation is chosen: a signature handshake is
also how the I/O board would identify ITSELF, so the reply may well be a
signature rather than a bare acknowledgement.

#### Both options cost more than first estimated

- **HLE** (~300 ALM) needs the protocol, which exists only inside the Z80 ROM.
  That means disassembling it, not inferring it.
- **LLE** (~2,000 ALM) needs a Z80 *and* the 315-5338A, since the DPRAM is
  reached through the custom chip. It is not "wire a core and load a ROM".

Correcting two earlier claims in this plan: HLE was described as needing repeat
work for three BIOS revisions plus model1io2. The three revisions
(epr-14869/B/C) are firmware updates of one board selected by
ROM_DEFAULT_BIOS, so they need one implementation, not three; and model1io2 is
a genuinely different board used by only two later machine configs, neither of
them the D5 bring-up title. For M1 the requirement is one protocol.

#### Recommended next step: extend by observation, not by guessing

The same method that found the missing on-chip RAMs and the single-cycle m_ack
applies here. Implement the minimum that could satisfy the handshake, run the
boot, and read the trace: it names exactly which address stalls next, and each
answer is evidence rather than a guess. That is how the last three blockers
were cleared, and it does not require committing to HLE or LLE up front —
whatever is learned about the layout serves both.

What it does require first is deciding whether the 315-5338A and a Verilog Z80
enter `third_party/` via bootstrap, with a licence check, since both paths
eventually want at least one of them.

---

### Integrated area, measured 2026-08-15

`make quartus MOD=m1_integrated` builds the V60 side and the 2D video side as
one design — no framework, no clocking, no I/O board, no TGP, no SDRAM
controller. It answers whether the per-module sums this plan has been quoting
survive integration.

| | integrated | standalone sum |
|---|---|---|
| ALM | 21,796 / 41,910 (52%) | ~21,400 |
| M10K | 332 / 553 (60%) | — |
| DSP | 16 / 112 | 16 |
| Fmax | 24.62 MHz | 24.62 MHz (V60 alone) |

**Integration is neutral.** The extra ~400 ALM is m1_main's bus routing, which
had never been measured on its own. Cross-boundary optimisation and routing
congestion did not move the total either way, so the summed figures elsewhere
in this document can be trusted to about 2%.

**Fmax is exactly the V60's standalone number**, which says the V60 is the
critical path in context as well as alone. Nothing else in the design is close.

**M10K is now a real constraint, not a free resource.** 332 of 553 for the main
board's memories and the video line buffers, before D3's band buffer (~51),
before sound, before sprites. Earlier entries in this plan treated block RAM as
effectively unlimited; that is no longer true.

#### The budget, with real numbers

Built and measured: 21,796 (this) + 2,554 (one TGP, D4 as reversed) + 937
(m1_sdram) = **25,287 ALM. 16,623 left.**

D4 originally called for three TGP instances. It was reversed on 2026-08-15
after finding that MAME instantiates one MB86233 and never executes the two
Geometrizer ROMs it loads — see that entry. That frees 5,108 ALM.

Still to build, estimated: MiSTer `sys/` 3,000-4,000; sound — 68000, YM3438 and
two MultiPCM — 5,000-7,000; I/O board as a Z80 3,000-2,500; rasterizer
3,000-6,000. **12,500-19,500 against 11,515 available.**

Against 16,623 available that fits, with the pessimistic end uncomfortably
close. One further lever is measured and held in reserve:

- **V60 without the FP group: -1,987 ALM**, and Fmax 24.62 -> 45.54. Evidence is
  good (no trap across 7.8M instructions of real boot code, no excess of
  FP-shaped byte pairs in the ROMs) but not conclusive: attract mode and
  gameplay have not run, and only two of eight ROM sets were scanned.
With NO_FP as well, 18,610 against a 12,500-19,500 need. That lever should not
be taken before the rasterizer is sized, since it carries the widest
uncertainty of anything left and is the one block nothing is known about.

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
