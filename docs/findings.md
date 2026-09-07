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

## 2026-09-08 — THE SDRAM CAN SILENTLY LOSE REFRESHES, AND IT HAS ONLY 4% OF MARGIN

Not chased yet, recorded because the mechanism is real whether or not it is the
symptom below.

    if (ref_cnt == T_REFI) begin ref_cnt <= '0; ref_pend <= 1'b1; end
    ...
    if (ref_pend && !pipe_busy && !ras_any) state <= S_PRE_REF;

**`ref_pend` is a single BIT, not a count.** If a refresh is still waiting when
the next interval elapses, the second is merged into the first and one refresh
is lost, silently. It can also only be serviced while `pipe_busy` is low --
`|tag_v`, so ANY read in flight on ANY port blocks it.

**And the margin is 4%.** `T_REFI = 600` at 80 MHz is 7.5 us; 8192 rows in 64 ms
needs one every 7.8 us. That is inside spec only while nothing is dropped.

### The symptom it would explain

Left on Virtua Fighter's ATTRACT for a long period, the 2D comes back badly
corrupted: text mirrored, tiles scrambled in regular vertical bands, palette and
overall layout intact. **The 3D is fine.** Photographed 2026-09-08 on the
57.143/28.571 build.

| observation | refresh starvation predicts |
|---|---|
| takes minutes | DRAM decay is slow and cumulative |
| corrupts 2D tiles | character RAM at 0xFA8000 is written once, then only read |
| 3D unaffected | polygon data is re-read constantly, from a different region |
| new today | clk_3d +21% -> more 3D traffic -> pipe_busy high more often |
| never seen before | the load was lower |

### What it is NOT

**Not the unclosed slack.** That build misses by -0.305 ns on
`mb86233_core|ir[20] -> state.S_LABB`, which is in the TGP on clk_3d and feeds
the 3D -- and the 3D is clean. clk_sys had +0.474 ns and clk_cpu +5.614, so the
domain the tilemap actually runs in meets timing comfortably. For the slack to
cause this, a violation in the coprocessor's state machine would have to corrupt
the tilemap while leaving the geometry it drives intact.

**Distinct from VR's five-minute black screen**, which is deterministic, happens
at the END of attract, looks like an attract restart, and never happens in game
or on VF. See the memory note; that one is a software/state fault.

### The fix, when it is taken up

Make `ref_pend` a small counter so refreshes queue instead of merging, and give
refresh a deadline after which it preempts rather than waiting for `pipe_busy`
to clear. Same shape as "acknowledges must be held, not pulsed" -- a
single-bit event that can be overwritten while the thing it asks for is
deferred.

**It is provable before a build**: count refreshes issued against elapsed cycles
in `tb_m1_sdram` under saturated load. If the ratio is worse than one per
T_REFI, the mechanism is confirmed without touching hardware.

---

## 2026-09-08 — THE TGP IS THE clk_3d CEILING, NOT THE 3D UNITS

Registering all three FP pool operand muxes took m1_geometry from 39.6 to
**59.36 MHz** and moved its critical path out of the pool entirely, into
`m1_geo_walk|o0z[20] -> qz[8]`. The pool is no longer the limiter.

So the next rung was tried - clk_3d 800/14 = 57.143, clk_cpu 800/28 = 28.571 -
and **it fails timing at -1.256 ns**, with TNS -2.820, so two or three paths.
All five worst are the same place, and it is not the 3D at all:

    mb86233_core|state.S_DST_W -> state.S_DST      -1.256
    mb86233_core|state.S_DST_W -> state.S_LABB     -1.241

**`m1_tgp` is dual-clock and its core runs on clk_3d**, deliberately at exactly
2x clk_cpu so the coprocessor gets two cycles per CPU cycle - "against a 16 MHz
V60, where we had 1:1". So raising clk_3d clocks the COPROCESSOR faster too, and
its state machine is the ceiling.

The TGP's in-core ceiling is between **53.333, which closes with +1.166 ns**,
and 57.143, which does not.

### The prediction that was wrong, and why it matters

m1_raster_fill was expected to be the next wall, on its standalone 58.84 MHz.
It is not - it clears 57.143 comfortably, and so does m1_geometry at 59.36. The
module that broke it had not been measured at all, because it is not in the 3D
layer and nobody had thought to check what else lives on clk_3d.

**Check what SHARES a clock before predicting what limits it.** The standalone
Fmax of the modules you are thinking about says nothing about the module you
forgot.

### Where the staircase stands

    47.059 / 23.529   start of day, ~70% of the real board
    53.333 / 26.667   SHIPPED and confirmed on hardware, ~79%, "noticeable"
    57.143 / 28.571   blocked on mb86233_core's state machine
    66.67  / 33.33    then blocked on m1_geo_walk 59.36, m1_raster_fill 58.84
    72.73  / 36.36    the V60's 38.19 binds through the 2x tie, ~107%

Each rung is now a named module with a measured number, which is the useful
part. The next one is the coprocessor's dispatch, and it is the same shape of
problem as the V60's - a large FSM whose state transition is the path.

---

## 2026-09-08 — clk_cpu IS GATED BY THE FP POOL, AND THE POOL'S LATENCY IS BAKED INTO ITS CONSUMERS

Chasing the CPU clock, not area. The V60 runs at 23.529 MHz and a mean CPI of
~17.9 against the ~12.5 real time needs, so the game gets about **70% of the
real board's work done per frame** - which is the VR slowdown.

### The V60 was never the limit

Pipelining fp_add/fp_mul's operand unpack took the V60 from 35.38 to
**38.19 MHz** (and -179 ALM; committed). But the CPU clock cannot follow,
because `clk_3d` is tied to **exactly 2x clk_cpu** so the crossing stays a clock
enable rather than a handshake - a deliberate choice, the comment noting this
project "has lost time twice to pulse-versus-level faults across domains".

So `clk_cpu <= clk_3d / 2`, and clk_3d has its own ceiling:

    m1_geometry     39.6 MHz  (shipping config; it CONTAINS the pool)
    m1_fp_pool      53.25
    m1_raster_fill  58.84
    m1_quad_store   94.99

    fp_add alone   138.48     <- the units are fast
    fp_mul alone   145.62
    fp_div alone   117.81

**The arithmetic is not the problem; the sharing wrapper is.** m1_geometry's
worst path is `m1_fp_pool|add_rr[1] -> m1_fp_pool|fp_add:u_add|sA_sticky`: the
round-robin arbiter, through the NC-way 32-bit operand mux `add_a[add_win]`,
into fp_add's first stage, all in one cycle.

### Why it has not been pipelined, which is the finding

Registering that mux is four lines and it WORKS electrically. It fails
functionally, and `m1_geo_xform` says why in its own header:

> The add schedule is fixed and spaced, not packed: ac 0 1 2 | 5 6 7 | 10 11 12.
> Three-cycle gaps, not two. **fp_add's latency is 4**, so round 1's first add
> reads a t[] the round-0 result must already have been WRITTEN to.

**The pool's latency is a hard-coded constant in its consumers' schedules.**
Adding a stage makes it 5 and those schedules read stale values:
`m1_geo_xform` went to 7,806 fails of 7,813. Reverted.

Nine modules instantiate against the pool - geo_xform, project, det, norm,
color, rsqrt, clip, planes and geometry itself - and only geo_xform documents
the assumption. The suite aborts at the first failure so the others are
UNMEASURED; do not assume geo_xform is the only one.

### What this costs and what it would take

The staircase, if the schedules were made latency-parametric:

    fix pool + geometry -> clk_3d ~56   clk_cpu ~28    ~84% of real speed
    + raster_fill       -> clk_3d ~64   clk_cpu ~32    ~95%
    + all               -> clk_3d 76.4  clk_cpu 38.19  ~113%, the V60 binds again

76.4 MHz is the ceiling worth aiming at, NOT the units' own 117-145: past
clk_3d 76.4 the V60's 38.19 binds through the 2x tie.

The honest scope is: make the consumers' schedules derive from a latency
parameter instead of a literal, then pipeline the pool. That is a session's
work across nine modules with `m1_geo_*` fuzz suites as the net, not a
four-line change - and the throughput cost of wider gaps has to be weighed
against the clock gained, on a geometry pass already measured at len=1.47 fr.

---

## 2026-09-07 — THE V60's AREA IS REAL LOGIC, NOT TIMING-DRIVEN DUPLICATION

The module build constrains `clk` at 20 ns - 50 MHz - and the V60 achieves
35.38, so it fails by 7.370 ns. A fitter chasing an impossible constraint
duplicates logic, which would have meant every V60 area figure was inflated and
that cutting LUT depth would recover area for free. Tested by constraining at
42.5 ns, the ~23.5 MHz the core actually clocks it at:

    50 MHz constraint    15,605 ALM   slack -7.370
    23.5 MHz constraint  15,649 ALM   slack +0.324

**Same area.** The fitter is not duplicating, the numbers are trustworthy, and
the 17,533 mux cells are genuine combinational logic implementing the
instruction set rather than an artefact of over-constraint.

That is a useful negative because it separates two things the LUT depth of 34.60
could have meant. Pipelining the dispatch would cut depth and raise Fmax - which
this design does not need, at 23.5 MHz against a 35 MHz ceiling - but it would
not on its own remove the 9,494 ALM. Area only comes back if the restructure
lets one physical unit do work that is currently done by several, and the
synthesiser has already shared everything that is mutually exclusive within the
block.

### What that leaves

The dispatch is 9,494 ALM of combinational decode for a CISC instruction set.
The classical answer to exactly that, and the one thing not yet tried here, is
to stop implementing decode as logic: **a microcoded or ROM-based decoder, which
moves the dispatch from ALM into M10K.** The core is at 76% of block memory bits
and ALM is the binding constraint at 98%, so the trade runs the right way. It is
also a genuine architectural change rather than a refactor, and it would need
`v60_trace` and the 29-test suite carrying it every step.

Nothing else measured this session has a path to four figures.

---

## 2026-09-07 — CORRECTION: THE DISPATCH IS 9,494 ALM, AND THE SPLIT WAS WRITTEN OFF TOO EARLY

The entry below concludes "this closes the V60 split as an area strategy". **That
conclusion is withdrawn.** It was drawn from three experiments that all probed
the same 9% of the module, and Ben pushed back on it. He was right.

    full V60                                    15,605 ALM
    opcode folded to a constant, so the whole
    primary dispatch casez folds away            6,111
                                                ------
                                                 9,494 ALM, 61% of the V60

| component | ALM | share |
|---|---|---|
| instruction dispatch + execute | **9,494** | **61%** |
| FP group | ~1,479 | 9% |
| addressing-mode decode | 1,391 | 9% |
| fetch, registers, misc | ~3,200 | 21% |

### Why the earlier experiments missed it

Every one of them - `dimext` at 16 ALM, the displacement share at -33, the
duplicate decode at 5 - hoisted AN EXPRESSION INTO A WIRE INSIDE THE SAME
MODULE. Not one of them changed the structure. They correctly establish that
**expression hoisting is exhausted**, and say nothing whatever about
restructuring, which is the transformation actually applied to Model 2's i960 -
that split took its CPI from 9 to 3.4, which is pipelining, not hoisting.

### The evidence that the structural target is real

From the post-synthesis netlist statistics, which had not been read before:

    Max LUT depth        34.60
    Average LUT depth    14.80
    arriav_lcell_comb    22,996   of which
        normal           17,533   76%, mux and select logic
        arith             4,400   ~137 adder-equivalents

An average combinational depth of ~15 levels with a maximum of 34 is what a
single 3,817-line `always` block with 200 state transitions produces, and it is
consistent with the 35 MHz Fmax. Depth and area are coupled - the fitter
duplicates logic to meet timing - so the 17,533 mux cells are both the symptom
and the cost. 137 adder-equivalents is also far more than a CPU needs, which is
the shared-datapath argument stated in numbers.

**The lesson about method, not about the V60:** three negative results in the
same 9% of a module do not license a conclusion about the other 91%. The
generalisation was made because the experiments were cheap and agreed with each
other, which is not the same as being representative.

---

## 2026-09-07 — THERE IS NO DUPLICATE ADDRESSING DECODE IN SILICON: THE SECOND COPY COSTS 5 ALM

Asked why the decode is "not fully recoverable" by extraction. Measured rather
than argued, and the answer is stronger than the claim was.

    both decodes present                     15,605 ALM
    S_BAM_MODE's decode folded away          15,600      -5
    BOTH decodes folded away                 14,214  -1,391

`S_EA_MODE` and `S_BAM_MODE` are near-duplicates in the SOURCE - same
`case (modtop)` arms, same displacement decode, same group-7 `modreg` sub-case -
and that duplication was the entire premise for extracting an AGU. **In the
netlist it is already gone.** Quartus shares the two states' decode completely,
because they are arms of one case and therefore mutually exclusive. Removing one
copy by hand recovers FIVE ALM.

So an AGU module would recover 5 ALM, not "a fraction of 1,391". The 1,391 is a
single shared decode that the CPU needs in order to decode addressing modes; it
is not duplication and there is nothing to hoist out of it.

The same argument disposes of the FP group. Its ~1,479 is what one shared FP
unit costs, and the game executes FP - `dbg_fp_trap` fires at `00fed52b` on a
real `cvt.sw` - so it cannot be deleted either.

**This closes the V60 split as an area strategy.** Every structural target
anyone named has now been priced, and the tool had already collapsed all of
them. What remains is functional logic. The one thing that DID pay, 1,054 ALM,
paid because the tool could not share it: a four-byte 24:1 mux whose select is a
runtime offset, different at every call site.

The generalisation worth keeping: **"the source looks duplicated" is not
evidence of duplicated silicon.** Mutually exclusive case arms are shared by the
synthesiser as a matter of course, and this project has now spent three
experiments - dimext at 16 ALM, the displacement share at -33, and this at 5 -
learning that the same way.

---

## 2026-09-07 — THE AGU IS WORTH 1,391 ALM IN TOTAL, SO EXTRACTING IT IS NOT WORTH A SESSION

Priced before writing it, which is the rule this session established after
hand-sharing lost twice. Constant mode selectors, so every
`case(modtop)`/`case(modreg)` arm in BOTH `S_EA_MODE` and its near-duplicate
`S_BAM_MODE` folds away - deliberately wrong, purely to measure:

    full addressing-mode decode   15,605 ALM
    decode stubbed out            14,214 ALM
                                  ------
                                   1,391 ALM, 9% of the V60

**That is the whole decode, both copies.** An AGU module can only recover the
DUPLICATION between the two states, never the decode itself, so its ceiling is
some fraction of 1,391 - and the directly comparable attempt, sharing the
displacement decode between exactly those two states, came out 33 ALM WORSE.
The expected return is a few hundred at best and plausibly negative.

### What this says about the whole split

The V60 is 15,605 ALM in the shipping configuration. The two things anyone has
been able to name as structural targets are the addressing-mode decode at 1,391
and the FP group at ~1,479. **Together that is under 20% of the module**, and
neither can be fully recovered by extraction. The remaining ~12,700 is the
instruction dispatch `casez`, the execution states and the load/store path -
not one structure, and not obviously duplicated.

So the reasoning that opened this work - the i960 is 5,414 lines in sixteen
modules at ~7,200 ALM while the V60 is 5,464 lines in four at ~16,000, therefore
splitting recovers the difference - **is not supported by what the V60 actually
measures.** The i960 is a fixed-width RISC; the V60 is CISC with variable-length
instructions, a 24-byte fetch window and multi-level addressing modes. Line
count is not the comparable quantity, and no measurement taken here shows a path
from 15,605 to 10,000.

What DID work is one specific shape, twice-confirmed: a large mux whose select
is a runtime offset, which the tool cannot share because each call site's offset
expression differs. That was worth 1,054 ALM. Nothing else measured has been
worth anything.

**Before spending another session on the split, price the target first.** Three
of the four things priced this way turned out to be worth 16, -33 and 1,391;
only one was worth building.

---

## 2026-09-07 — HAND-SHARING SMALL DECODES DOES NOT PAY; ONLY BIG OFFSET-DEPENDENT MUXES DO

Two experiments now say the same thing, and the second was tried anyway because
the first was not believed hard enough.

| hoisted by hand | sites | ALM |
|---|---|---|
| `dimext`, a 32-bit 3-way mux | 23 | **16** |
| addressing-mode displacement decode (`am_tdis`/`am_tlen`/`am_rdis`/`am_rlen`) | 18 | **-33, i.e. WORSE** |
| fetch-buffer extraction at `ea_ofs+1`/`+2` | 21 | **+1,054** |

The displacement share was reverted. It is correct - 29/29, `make test`
identical, `v60_trace` unmoved at 24,825 - and it costs 33 ALM and 0.23 MHz to
have. Quartus was already sharing those decodes across the mutually exclusive
case arms, so forcing a wire only adds the selection mux back by hand.

**The distinction that predicts which is which:** the fetch-buffer extraction
paid because each site built a FOUR-BYTE 24:1 MUX whose select is a runtime
offset. `dimext` and the displacement decode are small fixed-width selects on a
value the arm already has. The tool shares the second kind on its own and cannot
share the first, because each call site's offset expression differs.

So the rule for the rest of this split: **hoist a thing only if each of its call
sites builds a large mux whose select varies.** Counting call sites is not
evidence, and neither is the code looking duplicated - `S_EA_MODE` and
`S_BAM_MODE` genuinely are near-duplicates, and sharing the displacement between
them still lost.

That also lowers the expected return on extracting the AGU as a module. The
structural duplication is real, but if the tool is already sharing the logic
inside it, a module boundary changes the report and not the silicon. Price it
with a deliberately-broken build BEFORE writing it, the way the fetch-buffer
extraction was priced at 1,285 ALM before a line was changed.

---

## 2026-09-07 — A `function automatic` READING AN UNPACKED ARRAY IS WRONG IN A CONTINUOUS ASSIGNMENT

This cost a long bisect and will cost another one if it is not written down.

    wire [31:0] fbw_ea1 = fb32(ea_ofs + 1);                       // WRONG
    wire [31:0] fbw_ea1 = {fb[ea_ofs+4], fb[ea_ofs+3],
                           fb[ea_ofs+2], fb[ea_ofs+1]};           // CORRECT

`fb32` is `function automatic [31:0] fb32(input [4:0] o)` and its body is
exactly that concatenation, so the two lines are textually the same
computation. **They do not behave the same.** With the function form,
`tb_v60_search` fails on "encoded GA2 SKPCUH R28"; with the concatenation it
passes, every other line in the file identical.

### Why it took so long

Because every check said the substitution was faithful, and each check was
right:

- the diff was reviewed line by line - all substitutions textually correct
- `fb[]` is a stable generate-assign slice of `fb_flat`, itself `always_comb`
  off registers in `v60_ifetch`
- `ea_ofs` has no blocking assignments anywhere
- the addend width was tested both ways, `5'd1` and unsized `1` - no difference
- reverting the `modval2` part alone did not recover it

The bisect narrowed it to THREE lines, all of the form `d1t = fbw_ea1;`
replacing `d1t = fb32(ea_ofs+1);` inside `S_EA_MODE`, which look equivalent and
are not. Only swapping the function call for its own body fixed it, which
identifies the CONTEXT rather than the expression as the fault.

**The rule: inside a clocked block, calling these accessors is fine - that is
what the other ~60 call sites do and always have. In a continuous assignment,
write the concatenation.**

### What it unblocked

The hoist this was blocking is now in: 21 call sites of `disp_of`/`fb32`/`fb16`
at offsets `ea_ofs+1` and `ea_ofs+2`, across `S_EA_MODE` and its near-duplicate
`S_BAM_MODE`, collapsed to two extractions. Measured IN THE SHIPPING
CONFIGURATION this time - `QOPT="Aggressive Area"` with `TECHNIQUE AREA` -
**16,007 to 15,605 ALM, and Fmax 34.81 to 35.38 MHz.** Area and speed together,
with `v60_trace` unmoved at 24,825.

`S_EA_MODE` and `S_BAM_MODE` being near-duplicates is the finding to carry
forward: same `case (modtop)` arms, same displacement decode, same group-7
`modreg` sub-case. That duplicated addressing-mode decode is the AGU the i960
has as a 102-line module and we do not.

---

## 2026-09-07 — AGGRESSIVE AREA ALREADY IMPLIES RESOURCE SHARING; THE EXTRA FLAGS ARE FREE AND INERT

Added `AUTO_RESOURCE_SHARING`, `MUX_RESTRUCTURE`, `REMOVE_REDUNDANT_LOGIC_CELLS`
and `AUTO_DELAY_CHAINS_FOR_HIGH_FANOUT_INPUT_PINS` to the core build, taken from
Model 2's shipping `Model2.qsf`. The full 21-minute rebuild produced a
**byte-identical bitstream**: same md5 `93a95d746e3137d69eb3b48e9e8662bd`, same
41,124 ALM, same +0.896 ns on clk_sys.

Two independent instruments agree. On the V60 module the result is 16,007 ALM
with and without `AUTO_RESOURCE_SHARING`, once the mode is Aggressive Area and
the technique is AREA. On the core it is the same bitstream. **Those two
settings already enable the sharing the extra flags ask for.**

The flags are NOT harmless in every configuration. Against
`OPTIMIZATION_MODE "Aggressive Performance"`, `AUTO_RESOURCE_SHARING` alone
makes the V60 **worse** - 17,759 to 18,125 - because it fights the performance
bias. They are therefore written inside the same else-branch as the mode and
technique in `tools/mister_project.sh`, so a build that sets `M1_QSPEED` to keep
the template's speed-biased settings never gets them.

### What this says about the Model 2 result

Model 2's own comment records that "the mode, the technique and
AUTO_RESOURCE_SHARING all moved in one change and a fourth variable would make
the result unattributable". So its gain was credited to the combination and the
sharing flag's individual contribution was never isolated there. This build
isolates it: **the mode and the technique do the work**. That is a finding about
Model 2's configuration as much as ours, though nothing in that repository has
been changed.

### The thing that DOES matter, restated

The synthesis settings are worth **1,752 ALM on the V60** - more than every hand
edit made to it in this session combined - and `make rbf` has had them all
along. `make quartus MOD=<mod>` has not. That gap, not the sharing flag, is the
real finding of this line of work.

---

## 2026-09-07 — MODULE BUILDS AND THE CORE BUILD USE DIFFERENT OPTIMISATION SETTINGS

Asked whether Quartus has a flag for shared pathways. It does, the flags are
worth a lot, and **the core build already sets them** - so there is no win
sitting there. What the experiment found instead is that our two build paths do
not measure the same thing.

    make quartus MOD=<mod>     QOPT ?= "Aggressive Performance"
                               no OPTIMIZATION_TECHNIQUE line at all
    make rbf                   M1_QOPT  = "Aggressive Area"
                               M1_QTECH = AREA

Measured on the V60, same RTL:

    Aggressive Performance, no technique      17,759 ALM   36.54 MHz
    Aggressive Area + TECHNIQUE AREA          16,007 ALM   34.81 MHz

**1,752 ALM, larger than every hand edit made to the V60 today combined**, and
purely a synthesis setting. Fmax stays far above the 23.529 MHz the CPU is
clocked at, so the trade costs nothing here.

`AUTO_RESOURCE_SHARING ON` is a red herring twice over. On its own, against
Aggressive Performance, it makes the V60 WORSE - 17,759 to 18,125, because it
fights the performance bias. Added on top of Aggressive Area + AREA it changes
the result by **exactly zero**: 16,007 either way. Those two settings already
enable the sharing it asks for. Do not add it.

### What this invalidates

Every V60 area figure recorded earlier today came from the module path, so it
was measured under settings the shipping build does not use. The V60 costs
~16,007 in the configuration that actually ships, not 17,759. The SHAPE of that
profile still stands - 89% in v60.sv, FP small, dimext worthless - but the
absolute numbers were inflated and the gap to the i960's ~7,200 is smaller than
it appeared.

**So a module-level ALM number does not transfer to the core unless the
optimisation settings are matched.** Measure V60 work with
`make quartus MOD=s32_v60 QOPT="Aggressive Area"` and an
`OPTIMIZATION_TECHNIQUE AREA` line, or the number does not mean what it looks
like. This is the same class of error as the contaminated 103-cycle fetch wait:
an instrument measuring a configuration nobody ships.

---

## 2026-09-07 — WHERE THE V60's 18,411 ALM ACTUALLY IS, MEASURED

Profiled before restructuring anything, because the last three area guesses on
this project were wrong. All figures from `make quartus MOD=s32_v60`,
Quartus 17.0.

### The hierarchy

    v60.sv itself   16,325 ALM   89%   23,871 combinational ALUTs, 3,717 regs
    v60_ifetch       1,315
    v60_shift          677
    v60_alu             74
    lpm_divide          19
                    ------
                    18,411        44% of the whole device, 0 block memory bits

**89% is in one module, and inside it one `always @(posedge clk)` block of
3,817 lines.** For comparison Model 2's i960 is 5,414 lines across SIXTEEN
modules at ~7,200 ALM; ours is 5,464 lines across FOUR at 18,411. Near-identical
code volume, 2.5x the area. That comparison is what justifies the split.

### What each candidate is worth, priced by experiment

Each measured by deliberately breaking the thing and rebuilding - wrong output,
correct area - rather than by estimating.

| candidate | measured | verdict |
|---|---|---|
| fetch-buffer variable-offset muxing | **1,285 ALM** | real; 652 banked, 633 parked |
| FP group (`S32_V60_NO_FP`) | **1,479 ALM** | real, but it is only 8% |
| `dimext`, 23 call sites | **16 ALM** | NOT a target |

**`dimext` is the important negative.** Twenty-three inlined call sites of a
32-bit three-way mux cost sixteen ALM in total, because Quartus already shares
logic across mutually exclusive case arms. So "a Verilog function is inlined per
call site" is NOT on its own a reason to expect area back - the fetch-buffer
extractors were worth something because their muxes are large and
offset-dependent, not merely because they were inlined. Do not spend builds
hoisting small functions.

**The FP figure also corrects a stale one.** `CLAUDE.md` records the FP group at
-2,984 ALM. It is 1,479 today.

### So where is the other ~15,600?

Not in any single structure. Inside the 3,817-line block:

    255 add sites, 356 subtract sites, 2,042 compares

That is the monolith signature - mutually exclusive states each synthesising
their own arithmetic instead of sharing one datapath. The fitter also reports
`psw_rest[18]~0` at **fan-out 3,101**, which is `psw_ie`: the entire instruction
`casez` is nested in the `else` of the interrupt check, so that one condition
gates every register write in the dispatch. That is a routing/timing signal more
than an area one and should not be assumed to be worth ALM without measuring.

**The remaining prize is a shared datapath - one adder/subtractor and one
comparator with muxed operands - not more function hoisting.** That is a
multi-session restructure, and the regression net for it is
`run_v60_tests.sh` at 29/29 plus `make v60_trace`, which is the gate that
actually catches behaviour.

---

## 2026-09-07 — THE COPROCESSOR PORT WAS ALSO FETCHING DOUBLE, AND FIXING IT DID NOT MOVE THE LEFT-SIDE 3D

Confirmed on hardware at `dacf1e6`: nothing regressed, the 2D and the tile
overruns are as good as `46b9e2c`, and **the left-side 3D dropout is unchanged**.

### What was wrong

p3 is the coprocessor's `copro_data` and math tables. A fetch is one 32-bit
word; the port bursted FOUR, the top level aligned the address down to the
burst boundary, and `m1_integrated` picked the half it wanted with
`tgp_mem_addr[1]`. The same defect p1 had, found by auditing every port's
`p_dout` consumer against its `blen()` after p1 was fixed.

That audit is worth repeating on any new port. Of the seven: p0, p4 and p6 are
single-word and matched; p2 and p5 consume all 64 bits of their bursts; p1 and
p3 were the two fetching double. **p5 was NOT a third instance** - a comment in
`Model1.sv` claimed it picked a 32-bit half like p3 did, and it does not;
`m1_integrated` takes all of `r3d_rom_dout`. That comment was wrong and is
corrected.

Unlike p1, the bench totals move the right way here: 33,352 transactions served
to **34,096**, +2.2% in the same window, because with neither port fetching
words it discards the bus does more useful work. The build is also 76 ALM
smaller and `clk_sys` slack improved from +0.719 to +0.867 ns, consistent with
deleting the half-select mux.

### The hypothesis it was aimed at, and what the result means

The reasoning was: p3 is the read that blocks the coprocessor before any math
unit runs, the geometry pass it feeds measures `len=1.47 fr` against a
one-frame budget, and the left-side 3D dropout is INTERMITTENT - which fits a
deadline sometimes missed, where a clipping or coordinate error would cut in
the same place every frame.

**The dropout did not change.** But this is NOT yet a clean elimination, and
the difference matters:

- `len=` and `obj=` in the PASS3D line were **not read** on this build. If p3
  did not actually shorten the geometry pass, the hypothesis was never tested -
  only the fix's side effects were observed.
- A clean elimination needs `len=` measurably shorter WITH the dropout
  unchanged. That would say the pass got faster and the cut is elsewhere.
- `len=` unchanged would say p3 was not the pass's bottleneck, which is a
  different finding and leaves the deadline theory open.

**So the next measurement is `len=`/`obj=` off the UART, not another fix.**

### Where this leaves the left-side 3D

Still open, and the list of what has been eliminated by measurement grows:
`a_left = 0` (board said `BF62`), backface culling (identical cull rates, and
the yaw sweep), span starvation (`A=`/`Z=` answered 44.7%), and now the
coprocessor data port's bandwidth - provisionally, pending `len=`. The mixer
remains the last unexamined stage, and `K=`/`G=` have never been read on a
healthy build.

---

## 2026-09-07 — THE TILE FETCH IS FIXED, AND THE FIX WAS TO STOP FETCHING WHAT WAS DISCARDED

Confirmed on hardware at `46b9e2c`: the 2D renders correctly and **tile
overruns are massively reduced**. Third attempt at this module, first one to
survive the board.

### The defect

`char_data` is `p_dout[1][31:0]` - words 0 and 1 of the burst. Port 1 bursted
**four**. So every column fetched two 16-bit words that nothing ever read, spent
two CAS commands doing it, and the tile engine's ack waited for them to come
back before it could ask for the next column. The engine pays that round trip
248 times a line against a 3,936-cycle budget.

Fixing it is `blen(1) = 2`. The delivered value is bit-identical - `char_addr`
is `{tile_num,4'b0000} + {14'd0,map_y[2:0],1'b0}` and both terms have bit 0
clear, so the address is always 2-word aligned, and length 4 assembles `[31:0]`
as `{cap[1], cap[0]}` while length 2 assembles it as `{dq_r, cap[0]}` - both
`{word1, word0}`.

Length 2 was not expressible before. The capture assembled every non-single
burst as `{dq_r, cap[2], cap[1], cap[0]}`, hardcoding the last word at the top,
which is right for 1 and 4 and wrong for 2 and 3. Indexing that on the last
word's own tag is the whole enabling change, and the length-4 arm is the
default and bit-identical.

### THE PATTERN, which is the durable part

Three attempts at this module. The two that failed ADDED STRUCTURE; the one that
worked REMOVED WORK.

| Attempt | What it did | Board |
|---|---|---|
| 2026-09-05, second SDRAM port | added a port so two fetches could overlap | yellow rectangle, no sky or ground |
| 2026-09-07, next-scanline cache | added a cache to KEEP the discarded half | alternate scanlines missing |
| 2026-09-07, `blen(1)=2` | stopped fetching the discarded half | **good** |

**The discarded half was known before either failure.** The reverted cache
(`3a7c6b6`) is literally titled "Keep the half of every character burst that was
being thrown away" - the same observation, one week and two reverts earlier. It
led to a scanline cache with new ordering to get wrong, when the same fact
supported simply not fetching those words. The waste was treated as a resource
to exploit rather than as a defect to remove.

So when a measurement says work is being wasted, the first question is whether
the work can be *not done*, before it is whether the waste can be *used*.

### What still does not catch this class of bug

Nothing new. Every bench passed on both failed attempts and passes now, so the
benches did not distinguish the two that broke the board from the one that
worked. `tb_m1_video`'s blindness to both hardware failures is still open and
still unexplained.

What DID catch a real fault here was `burst_of()` in `tb_m1_sdram.cpp`, the
model's mirror of `blen()`. The RTL changed and the mirror did not, and the
suite failed immediately with 3,494 mismatches rather than letting a half-length
burst reach hardware as corrupt tile characters. Its comment already warned the
two must move together, from a previous drift; it now has a second instance.

### A hazard found while doing it

`build/mister/rtl` and `build/mister/Model1.sv` are **SYMLINKS INTO THE REPO**,
not copies. Editing RTL during a `make rbf` therefore edits the build's own
sources. It was survived here only because `quartus_map` - the sole stage that
reads `.sv` - had ended at 10:32:56 and the edit landed at 10:43:06, with
`quartus_fit` and `quartus_asm` working from the synthesis netlist. That is luck,
not design. Check `quartus_map` has ended before touching RTL mid-build, or do
not touch it.

---

## 2026-09-07 — THE CAPTURE DEPTH IS AN ALIGNMENT, NOT A MARGIN, and CL+2 is the only correct one

Measured on hardware, sweeping the SDRAM read phase option through all six
positions on the build at `0174f13`. **Every depth except CL+2 crashes the
CPU.** That includes CL+1 and CL+0, which had never been askable before this
build - the selector's floor was CL+2, so whether the window continued below it
was unobservable.

### What this corrects

It corrects a reading made ON THIS PAGE'S OWN LOGIC earlier the same day, and
the wrong reading is kept here because it is an easy mistake to repeat.

**The wrong reading:** "a healthy interface has a contiguous run of working
depths, so a window exactly one wide means we are clinging to the edge of it -
the capture is marginal and phase tuning is urgent." Model 2's own comment was
cited in support, since `m2_sdram` renumbers its selector specifically so that a
calibration sweep's pass mask reads as a *shape*.

**Why it is wrong:** a burst word is driven for exactly ONE SDRAM clock, which
is one `clk_sys` period. So exactly one `clk_sys` edge can ever fall inside a
given word's validity window, and a one-wide pass mask is the ONLY possible
result for a correct interface. `cap_depth` does not select how much margin the
capture has. It selects **which word of the burst is called word 0**.

The failure mode confirms it. A wrong depth does not produce noise, it produces
data shifted by a whole word, and `m1_sdram.sv` already records exactly that
from an earlier hunt: the assembled line came back shifted right by one 16-bit
word, and the V60's reset vector read `FE104E` where the ROM holds `4EF3D6`. A
word-shifted reset vector is a crashed CPU, which is what the board does on
all five wrong depths.

So CL+0 and CL+1 fail because the data has not arrived yet; CL+3 and above fail
because the bus has moved on to the next word. **CL+2 being uniquely correct is
the interface working as designed.**

### What it does NOT settle

Whether the capture has setup margin *within* its one-cycle window is a separate
question and is still open. The arithmetic on the SDC's own device numbers puts
data at the pin at 37.65 ns against a capture edge at 37.5 ns - nominally 0.15 ns
LATE, so it works only because the real `tAC` beats the pessimistic 6.4 ns the
constraints assume. The constrained build measured `SDRAM_CLK_pin` at +0.323 ns.

That is thin, and there is standing evidence it bites: a build whose only change
was a debug counter and a UART produced a garbage picture with +0.296 ns reported
slack and no new warnings. Shifting `phase_shift2` earlier than its present 6250 ps
(a plain 180 degrees, never tuned) buys margin at the same edge and would NOT
move the working depth, because it does not change which edge captures.

**But the one-wide window is not evidence for it.** Those are two different
questions and this entry exists because they were conflated.

### What the sweep was worth

The range extension stays. It cost nothing - `make test` counts were
byte-identical - and it converted "CL+2 is the shallowest we can ask for" into
"CL+2 is the only one that works", which are not the same statement. The
capture-depth knob is now settled and should not be looked at again.

Where the cycles actually are, since they are not here: `blen(1)=2` on the
character port (-2 cycles, and it stops discarding half of every burst),
skipping `S_DISPATCH` on a row hit (-1), `ACK_HOLD` 2->1 for same-clock ports
(-1), and the structural one - the single-outstanding-per-port contract at
`inflight[arb_grant] <= 1'b1`, which is what makes the tile engine latency-bound
rather than bandwidth-bound.

---

## 2026-09-07 — THE NEXT-SCANLINE CACHE BREAKS ALTERNATE SCANLINES, and no bench reproduces it

Second attempt at the tile engine's latency, second revert. Recorded because the
idea is sound, the measurement was real, and the failure is invisible in
simulation - which is now a pattern with this module rather than bad luck.

### What was built

`char_addr` points at the first of the TWO words holding an 8-pixel row and
port 1 bursts FOUR, so words 2 and 3 are the same tile's next row - exactly what
the next scanline needs - and `Model1.sv` read only `p_dout[1][31:0]`. The
engine kept the upper half in a 62 x 4 cache, keyed on the fetched ADDRESS so a
mid-frame `hscr` change could not produce a false hit.

Measured in the unit bench: **1,614 -> 1,182 cycles a layer per line.**

### What happened on hardware

**Every other scanline missing** - Ben's description: "almost like you would see
on 240p on a CRT". That is the cached lines specifically: even lines fetch and
draw, odd lines take the cached row and get nothing usable.

### What passed anyway

- `m1_tile_fetch`: 49,116 checks
- `m1_video`: **380,929 pixels over three full frames**, character memory filled
  with random data so a wrong row cannot match by accident
- the full suite, 54 harnesses

And then, trying to reproduce it, the video bench was given **variable latency
(8-40 cycles) and a two-cycle held ack**, matching what the real port does
against six other masters instead of a fixed 14 and a one-cycle ack. **It still
passed.** So the difference between bench and board is not the memory timing,
and it is not the data pattern.

### The other cost, and it is the same shape as last time

The first version read `cc_addr[cc_i]` combinationally. An asynchronous array
read makes Quartus build the memory out of flip-flops with a 248-way mux instead
of block RAM: **+1,300 ALM, 99% of the device, and one seed reported
`Error (11802): Can't fit design in device`.** Registering the read fixed the
inference - the arrays became `altsyncram` - but the design still sat at 98.2%
and only one seed in four closed timing.

### What this says

Two attempts, both green in every bench, both broken on the board:

| Attempt | Bench said | Board said |
|---|---|---|
| Two SDRAM ports | 1,614 -> 568 | yellow rectangle, no sky or ground |
| Next-scanline cache | 1,614 -> 1,182 | every other scanline missing |

**Do not attempt a third without a bench that reproduces a failure first.** The
right next step is not another fix; it is finding what the benches do not model.
`tb_m1_video` renders full frames against a reference with random character data
and variable memory timing, and it is still blind to both faults - so something
structural about the real system is absent from it, and that is the thing to
find.

---

## 2026-09-06 — THE SDRAM BUS IS 95% IDLE. "26% busy" was overhead, not data

Ben's challenge: ports starve while the bus reads 26% busy, and 26% of
160 MB/s is nowhere near the ceiling - so either the figure is wrong or the
setup is. He was right that the figure was wrong.

### The measurement

`dbg_occ`, which is what `O=` reports on the wire, counts cycles the controller
is **not in S_IDLE**. That includes dispatch, activate, tRCD, precharge and
refresh - overhead states in which the DQ pins carry nothing. It is not data.

A CAS command is the only thing that moves a word, so counting those against
elapsed cycles gives true bus utilisation:

```
SDRAM data cycles 6,420,000 of 120,957,803 = 5.30% -> 8 MB/s of 160 MB/s
```

**The bus is 95% idle.** Of the 26% the old metric reported, only about a fifth
was data.

### What it settles, both ways

**The setup IS inefficient.** A four-word burst costs six controller cycles for
four data cycles on a row hit, and eight to ten on a row miss. Bank interleaving
- activating one bank while another streams - would tighten that, and the
controller does not do it.

**And it does not matter.** At 5% utilisation there is no shortage to relieve.
The tile engine starves because it is SINGLE-OUTSTANDING: it issues one fetch,
waits about 18 cycles for the data, then starts the next. Its rate is set by
round-trip LATENCY, not by the bus. Give it the whole 160 MB/s and it fetches at
exactly the same speed.

That is the third time this session a bandwidth explanation has been offered for
a latency problem - after the SDRAM clock lift and the priority arbiter - and
the third time the measurement has refused it.

### What follows

The two-port character fetch was aimed correctly. It measured 1,614 -> 568
cycles a layer in the unit bench and broke the 2D on hardware for a reason never
diagnosed. **That is the thread to pull**, not the memory controller.

`O=` on the telemetry line should be changed to report data cycles rather than
non-idle cycles. As it stands it overstates bus use by about five times and it
has misled this project's reasoning more than once.

---

## 2026-09-05 — A QUAD TOUCHES 1.11 BANDS, SO BINNING IS THE CURE FOR THE DROPPED QUADS

Measured on real models out of the polygon ROM, 15,688 quads across 16 yaw
angles: **17,364 band touches, 1.11 a quad.** The guess going in was three.

### Why the number decides the architecture

The band renderer replays EVERY quad for EVERY one of the 24 bands and filters
on `band_range`. That is why the store has to hold a whole frame, and why
Virtua Fighter saturates it at 3,072 and discards **8,072 quads a capture**.

The store cannot grow: 211 bits a quad across two banks, so 3,072 -> 4,096 needs
about 42 M10K and a peak frame of 4,798 quads needs about 72. Seven are free,
and the display list buffers - the only large pool - turned out to be fully used
by Wing War. The sort key, the one fat field, cannot shrink because it is a
monotonic transform of the float z and MAME compares floats.

**Binning by band removes the problem instead of enlarging it.** Each quad is
written once per band it touches; each band reads only its own list. At 1.11
touches a quad a peak frame is ~5,300 entries, ~144 KB written and ~144 KB read
per frame, about **17 MB/s** against a 160 MB/s peak that currently sits 26%
busy. Three times fatter geometry than this bench's viewport would still be
~50 MB/s.

| | today | binned |
|---|---|---|
| Quad capacity | 3,072, hard | unlimited |
| On-chip store | a whole frame | one band |
| Band replay | every quad x 24 | own list x 1 |
| SDRAM | none | ~17 MB/s |

So it is not a trade. It removes the capacity limit, collapses the 24x replay to
1x, and RETURNS M10K rather than spending it.

**Caveat on the number.** 1.11 is real geometry under the bench's viewport, not
the game's camera. A road running to the horizon is a taller quad than anything
here. The board can measure it directly - `m1_quad_store` now counts band
touches and quads seen - and that should be read before the redesign is
committed to.

---

## 2026-09-05 — THE DISPLAY LIST BUFFERS CANNOT BE SHRUNK, and MAME runs all five games

Two results from the same evening, and the first would have broken a game.

### MAME runs every Model 1 game here

`vf` and `netmerc` are marked `MACHINE_NOT_WORKING` and both run correctly -
Virtua Fighter plays its attract demo, NetMerc reaches its title screen. The
flag is a curation stance about `BAD_DUMP` microcode, not a statement that the
machine fails. **Taking it at face value cost an hour of reading disassembly
while an instruction-level oracle sat unused.** Test the claim.

Virtua Racing stopped running here for an unrelated reason: `vr.zip` was
replaced on 2026-08-30 with a SPLIT set, and split sets need the BIOS ROMs as
separate archives. `vr_old.zip` is a merged set and still contains them.
`model1io.zip`, `m1comm.zip`, `model1io2.zip` and `hd44780.zip` were rebuilt
from files already present in `vr_old.zip`, `vf.zip` and `netmerc.zip`; the CRCs
match MAME's. All five games now run.

### The display list buffers are NOT spare memory

`m1_mainram` gives each of the two display list buffers the architectural
32,768 words, about **104 M10K of 553**, and `mame_dl_extent.lua` exists to
find how much is really used. Across all five games:

| Game | Highest word touched | of 32,768 |
|---|---|---|
| Virtua Racing | 16,383 | 50% |
| Virtua Fighter | 16,383 | 50% |
| NetMerc | 21,095 | 64% |
| Star Wars | 30,783 | 94% |
| **Wing War** | **32,767** | **100%** |

**Wing War uses every word of both buffers.** The region is not reducible.

Measuring only the two games that are easy to test would have said "halve it" -
VR and VF both stop at exactly half - and that would have broken Star Wars and
Wing War silently, in games nobody runs often enough to notice quickly.

`CLAUDE.md` described this region as "the one place a data cache could come
from". It is not, and that line needs correcting.

### What it was wanted for, and what that means

Virtua Fighter saturates the quad store at 3,072 and discards **8,072 quads a
capture**. The store costs 211 bits a quad across two banks - 128 of them the
four 16-bit vertex pairs - so 3,072 -> 4,096 needs about **42 M10K**, and
holding a peak frame of 4,798 quads needs about **72**. Seven are free.

The sort key is the only obviously fat field at 32 bits, and it cannot shrink:
it is a monotonic transform of the float z and MAME compares floats, so
truncating it reorders quads whose depths differ in the low mantissa.

So the store cannot be made big enough on this device. What remains is spilling
overflow to SDRAM - the controller is 26% busy, but band replay reads each quad
24 times, so it is roughly 75 MB/s of new traffic - or dropping SMARTER, since
the store currently keeps the first 3,072 quads and discards the rest
regardless of size or depth.

---

## 2026-09-05 — A SECOND FP DIVIDER BUYS NOTHING. Projection is serial per VERTEX, not short of dividers

Built and measured tonight, then reverted. Recorded because "add a second
divider" is the obvious read of the profile and it is wrong.

### The profile that suggests it

`tb_m1_geometry`: 488 cycles a quad against a budget of 83, and inside the
record `project` is outstanding **90.9%** of the time and the **sole cause
36.8%**. Nothing else is close - `xform`, `normalize` and `determinant` are
never the sole cause at all. So divide throughput looks like the lever.

### The measurement that refutes it

Two `fp_div` units in `m1_fp_pool`, issued round-robin from whichever is free
and retired in whatever order they finish:

| | cycles per quad |
|---|---|
| One divider | **488.2** |
| Two dividers | **493.9** |

Slightly WORSE, for the area of a second divider. The suite stayed green at
44,752 checks, so it is not broken - it is unused.

### Why

`m1_geo_project` computes **one reciprocal per vertex** - `div_a = ONE`,
`div_b = rz`, then two multiplies - and `in_ready = (rst_st == R_IDLE)`. It
accepts one vertex at a time and is busy for the whole 29 cycles. **There is
never more than one divide outstanding**, so a second unit has nothing to do.

That is the same shape as the tile fetch: latency times count, serialised. Not
a shortage of units.

### What would actually work

Let projection accept a second vertex while the first's reciprocal is in
flight. Then both dividers are used and the per-vertex cost roughly halves.
From the profile that is worth about **18%** - Virtua Fighter's geometry pass
1.55 frames -> about 1.28 - which helps the judder without curing it.

It is a pipelining change to a module verified at 20,037 checks, and the two-
port character fetch earlier the same evening shows what rushing that class of
change costs: both benches green, and the 2D broken on hardware.

**The pool's one-cycle grant mask stays regardless.** It is correct on its own
terms and it is the prerequisite that makes any second divider work at all -
see the entry above on why the 2026-09-04 attempt failed.

---

## 2026-09-05 — THE LEFT-SIDE 3D: WHAT IT IS NOT. Six candidate causes eliminated by measurement, and the remaining stage named

Ben's symptom, refined over the session: in gameplay the **left 40-48% of the
screen carries no 3D**. The road and the scenery are gone there; **cars on the
same side are drawn normally**. It gets worse on corners and persists while
parked at an angle. He believes it has always been the case.

Everything below is measured on the board unless it says otherwise.

### Eliminated

| Cause | How it was eliminated |
|---|---|
| SDRAM contention | tile port served in **18 cycles**, 2 waiting; controller ~29% busy |
| Coordinate wrapping in the quad store | `G=0` on every sample of every capture |
| Spans never reaching the left | `A=` — the fill emits **44.7%** of its pixels into the left half |
| The band memory losing them | `I=` — scanout reads back **46.3%** on the left. Write and read agree |
| Culling, clipping, projection | 16-yaw sweep vs `push_object`: 15,688 quads, **zero** differing |
| Over-culling | cull rate identical in the good and bad states, ~32,000/s both |
| The frustum's left plane | `Y=BF62` ~ -0.88. With x1=0, xc~248, zoomx~281 that puts the plane at screen x = **0**, where it belongs |
| Tile overruns causing it | an overrun repeats a 2D scanline and never touches the band buffer; misses ranged 0 to 2,175/s while the cut stayed put |

### What is left

The **mixer**. `poly_won` requires that no category-1 tile is in front of the
3D, which is correct - it is MAME's draw order, tiles 6/4/2/0 below and 7/5/3/1
above, and `m1_tile_decode` takes the category from `tile_word[15]` exactly as
`segaic24.cpp:56` does. So if a category-1 tile covers the left half, our mixer
is CORRECTLY suppressing the 3D and the fault is upstream of it.

`K=` and `G=` were repurposed to count pixels where the 3D was ready and a tile
beat it, per screen half. **Not yet read on a healthy build.**

### One reading that arrived and needs confirming

`w=0000 v=0000` on all 99 samples of the last capture - both tilemap pair
control words zero during play. If that holds, no window mode is configured at
all, the column-split theory is moot, and it raises a different question about
the 2D. The capture came from the build that was rolled back, so it is
suggestive rather than established.

### The hypotheses that were WRONG, and why they looked right

- **`a_left = 0`.** The arithmetic was sound: the left plane lands at
  `xc + a_left*zoomx + viewx`, which for a correct `a_left` is `x1 = 0` and for
  zero is `xc + viewx` ~ 248 - 48% of a 496-wide screen, exactly Ben's boundary.
  It also explained why near objects survive, since the test `p.x < p.z*a_left`
  scales with distance. `a_left` is the FIRST plane computed, so zero would have
  meant no recompute had ever run. The board said `BF62`. Right reasoning,
  wrong premise, and only hardware could say which.
- **Backface culling.** Fitted "large flat single-sided things vanish, closed
  objects do not" perfectly. Killed by an identical cull rate in both states and
  by the yaw sweep.
- **The left half being starved of spans.** `A=`/`Z=` were built to test it and
  answered 44.7%, which is not starvation. That counter was aimed at Ben's FIRST
  description - "the whole left side" - and his later detail, cars fine and road
  gone, changed the question underneath it.

---

## 2026-09-05 — THE TWO-PORT CHARACTER FETCH BROKE THE 2D, AND BOTH BENCHES PASSED

Reverted the same evening it was built. Recorded because the change is right in
principle, the measured win is real, and the next attempt needs to know what
caught it and what did not.

### What was built

The tile engine is latency-bound: strictly serial, `F_CHAR` raising `char_req`
and stalling for the whole round trip, once per column, 248 times a line. The
fix was two SDRAM ports alternating with a two-entry hand-off queue, keeping
`m1_sdram`'s single-outstanding-per-port contract intact rather than relaxing a
module verified at 87,893 checks.

**In the unit bench it worked**: 1,614 -> 568 cycles per layer per line, so four
dense layers cost ~2,270 against the 3,936 a scanline affords. That is the
number `m1_tile_fetch`'s own header predicted for this change.

### What happened on the board

A flashing yellow rectangle, sky and ground missing. `M=` saturated at `0xFFFF`
- the tile fetch missing deadlines continuously - and `Q=` at zero.

### What passed anyway

- `m1_tile_fetch`: 49,116 checks green
- `m1_video`: 380,929 pixels compared, green
- `tb_m1_frame`: no regression

A unit bench that models two ports with independent latency counters cannot show
what two REAL SDRAM masters do to each other through a shared arbiter, a shared
open row and a refresh cycle. And `tb_m1_frame` reproduces **zero** tile
deadline misses once the ROM load is excluded - all 9,434 of its misses happen
during the download - so the bench that should have caught it does not
reproduce the fault at all.

**Before this is tried again, build a way to see the failure off the board.**

### It also walked into the oldest trap first

The two ports are independent masters and the arbiter may grant them in either
order, so port 1 can return before port 0. `char_ack` is held only two cycles,
so an out-of-order ack arriving while the retire pointer watched the other port
was lost. The frame bench went 9,434 -> 36,867 misses and that one it DID catch.
Fixed by latching each port's completion the cycle it happens. *Acknowledges
must be held, not pulsed* - recorded twice before, three times now.

---

## 2026-09-05 — WHY THE SECOND FP DIVIDER FAILED, AND WHAT ACTUALLY LIMITS 3D SPEED

### The profile

`tb_m1_geometry`: **488 cycles a quad against a budget of 83**, and a peak frame
of 4,798 quads would need **286% of a frame**. Inside the record:

| Stage | Outstanding | Sole cause |
|---|---|---|
| **project** | **90.9%** | **36.8%** |
| tgp_ram | 22.9% | 0.1% |
| xform | 21.4% | 0.0% |
| normalize | 11.3% | 0.0% |
| colour | 10.3% | 1.4% |
| determinant | 2.1% | 0.0% |

Projection is the bottleneck and nothing else is close. `xform`, `normalize` and
`determinant` are NEVER the sole cause, so speeding them up buys nothing.
Projection is the perspective divide - eight divides a quad - so **divide
throughput is the only lever on 3D speed worth pulling**.

### Why the second divider made things worse, and it was not the divider

Grants in `m1_fp_pool` are combinational. A client's "I have been granted" flag
is necessarily REGISTERED - it cannot see the grant until the next edge - so its
request is still asserted during the grant cycle itself.

With one divider that costs nothing: the divider is busy for up to 29 cycles
afterwards and the stale request cannot win again. **The moment a second divider
exists the other one is free, the stale request wins immediately, and every
division is issued twice.**

It is not the client's bug either: gating `m1_geo_project`'s `div_req` on
`div_gnt` closes a combinational loop through the arbiter - request feeds the
winner pick feeds the grant.

**Fixed in the pool**: a client is masked for one cycle after being granted. NC
flops, no throughput lost because clients are single-outstanding. This changes
nothing today and that is the point - it is the prerequisite that lets the
second divider land.

---

## 2026-09-04 — THE LAYER BLEND ORDER IS THE SAME FOR EVERY MODEL 1 GAME, and the above-HUD 3D pass is NOT implemented

Asked because NetMerc's attract screen draws 3D over the `INSERT COIN` glyphs
and that looked like a layering fault. Two facts, both read off MAME.

### There is one blend order, not one per game

`model1.cpp:1835` sets `screen_update_model1` once, in the shared machine
config, and nothing overrides it. Every Model 1 game composites identically
(`model1_v.cpp:1846-1868`):

```
fill with pen 0
tiles 6, 4 opaque, then 2, 0        <- category 0
tgp_render(RENDER_BELOW_HUD)        <- the 3D
tiles 7, 5, 3, 1                    <- category 1
build_overlay_mask()
tgp_render(RENDER_ABOVE_HUD)        <- command 0x41 only
apply_overlay_stencil()
```

`segaic24`'s `draw(layer, ...)` splits its argument as `tpri = layer & 1` and
map `= layer >> 1`, so those eight calls are FOUR TILEMAPS EACH DRAWN TWICE -
once for the tiles whose category bit is clear, once for those where it is set.
Every tilemap therefore has tiles on both sides of the 3D.

**Ours matches.** `m1_tile_mixer` resolves cat1 tiles above the polygon layer
and the polygon layer above cat0, and `m1_tile_decode` takes the category from
`tile_word[15]` - which is what `segaic24.cpp:56` reads:
`tileinfo.category = (val & 0x8000) != 0`.

So a glyph buried under the 3D is a glyph whose category bit is clear, and MAME
buries it too. Whether NetMerc's attract frame is correct is a question for a
reference snapshot, not for the mixer.

### The ABOVE-HUD pass is a real gap

MAME renders the 3D **twice**. Objects with command `0x41` are held back and
drawn after the HUD tilemaps, through a stencil that only lets them through
"background" HUD pixels. MAME's own comment names the case: **SWA radar blips**.

`m1_listwalk` knows the opcode exists - there is a comment about dispatching on
it - but nothing in this design separates the two passes, and the mixer has a
single `poly_valid` input. So a 0x41 object renders BELOW the HUD and is hidden
by it.

That is the opposite of the NetMerc symptom, so it explains nothing there. It
will bite **Star Wars Arcade**, which is the game the MAME comment is about, and
it is now on record rather than being rediscovered from a missing radar.

Not scheduled: it needs a second polygon layer or a per-pixel stencil through
the mixer, and no game we can currently run needs it.

---

## 2026-09-04 — THE 103-CYCLE CHARACTER FETCH WAIT IS 18 CYCLES. The famous unexplained number was an average taken across the ROM download

`HANDOFF.md` item 6 has recorded since M1 began that a character fetch waits an
average of **103 cycles**, that this is "far more than a round-robin turn
between three active ports should cost", and that it is "not understood". It
said to find out where the time goes before changing `m1_sdram`.

**The time was never going anywhere. The measurement included the ROM load.**

`tb_m1_frame` counted from reset, and for the first tens of millions of cycles
the loader is streaming the ROM image into SDRAM through the dedicated write
port - which sits unconditionally above every read port, deliberately, because
game logic is held in reset during download. Averaging the tile port's wait
across that phase describes a machine that is not running.

Gated on `loader_done`:

| | Ungated | Gated on the load finishing |
|---|---|---|
| Total wait per fetch | 217 cycles | **18** |
| Waiting for a grant | 200 | **2** |
| Being served | 15 | 15 |
| Idle-but-not-granted, write port winning | 95% | **0%** |

Two cycles of arbitration is as good as this controller can do. The wait is the
transfer itself.

### How the error was caught, which is the transferable part

By a fix that did nothing. The ungated split pointed at round-robin, so the tile
port was given strict priority over the other six - and the figure moved by
**nothing at all**, 200 cycles before and 200 after. A change that cannot move
the number it targets is aimed at the wrong thing, and that is what prompted
gating the counter rather than trusting it.

The second wrong cause came from the same contaminated data: with priority in
and nothing changed, a state histogram said 70% of the wait was spent in write
and write-recovery, and 95% of the idle-with-request-pending cycles went to the
write port. True, and entirely the download. Counting how many of those
happened **after** `loader_done` returned zero.

The priority arbiter was **reverted**. It was justified by a contaminated
measurement, it adds logic to this design's worst timing path, and the clean
number says arbitration costs two cycles.

### What this rules out

- **The SDRAM is not what causes the tile overruns.** The port is served in 18
  cycles and still misses 9,434 deadlines in the run. Neither faster memory nor
  better arbitration can recover time that is not being lost there.
- **The 133 MHz clock lift is not the fix for this defect either.** Its case now
  rests on the geometry pass and on nothing else measured.

### Where the overruns actually come from

`m1_video.sv` has said so all along, in the comment beside the overrun counter:
a line's worth of fetching is 3,936 core cycles and **four dense layers need
about 6,456**. That is the fetch engine's own emission and per-column cost, not
memory latency. The repairs are fewer fetches per line or overlapping them -
wider bursts, or more than one request in flight, which is the one place the
N64 controller's FIFO-and-`reqprocessed` shape genuinely applies here.

---

## 2026-09-04 — THE TILE OVERRUNS ARE REAL AND THE SDRAM IS NOT THE CAUSE. The memory has 70% of its cycles free while the tile port misses 2,175 deadlines a second

Ben's reading was that the tile overruns and the 3D dropout together point at
the memory controller, and that raising the SDRAM clock to 133 MHz is the fix.
The overruns are real — his eye was right again. The bandwidth attribution is
not, and the same capture says so.

### What was measured

Two counters were added to `m1_sdram` and put on the UART, because nothing in
this project had ever measured memory occupancy on hardware. `bw_monitor` has
existed for months and its numbers only ever reached simulation.

- `O=` — cycles the controller is not in `S_IDLE`, over a 2^20-cycle window
  (13 ms at 80 MHz), as a fraction of 0xFF.
- `Q=` — cycles port 1, the tile character fetch, is pending, same window.
- `M=` — the tile fetch's deadline misses, free-running. This counter already
  existed and had never reached the wire: it was a row on the debug overlay,
  which is off.

148 seconds of gameplay, seed 11 build, `13a584c58a408e942d9f51d98285ec1e`.

| Second | Misses/s | Controller busy | Tile port pending |
|---|---|---|---|
| 0-2 | 1-6 | 38-40% | 31% |
| 3 | 394 | 32% | 40% |
| 4-12 | **2,165-2,192** | **30-33%** | **37-42%** |
| 13 on | 10-85 | 18-38% | 11-26% |

At 57.5 Hz and 384 lines that burst is about **10% of every scanline in the
frame overrunning**, which is more than enough to be the visible 2D corruption.

### The number that settles it

**Busy went DOWN as the misses went UP.** Occupancy fell from 40% to 32% over
exactly the seconds when misses rose from 1/s to 2,175/s, while the tile port's
pending time rose from 31% to 42%. A bandwidth wall does the opposite: the
controller saturates and everything queues behind it. Here the controller did
LESS work while one port waited LONGER.

The controller has **68 to 70 percent of its cycles idle** throughout. There is
no shortage of memory cycles to find. A faster clock multiplies capacity that is
already unused.

### What this means for the 133 MHz plan

It is not the fix for this defect. It may still be worth doing for other
reasons, but it must not be justified by the tile overruns.

Two other measurements from the same builds bear on it, both from the seed
reports rather than argued:

- `SDRAM_CLK_pin` has **+9.4 to +11.4 ns of slack against a 12.5 ns period**.
  The pin paths take about 3 ns, so the physical interface would still hold
  roughly 4.5 ns of margin at 133 MHz. The interface is not the limit.
- `clk_sys` closes at **+0.549 ns**, an 11.9 ns critical path. That domain
  carries the 2D video path and the loader as well as the controller, so it
  cannot simply be sped up. The memory would need its own domain — which is
  what Ben proposed — and whether the controller's own logic closes at 7.5 ns
  is not yet known.

### The prediction that came true

`HANDOFF.md` item 6 has recorded since M1 began that a character fetch waits an
average of **103 cycles**, that this is "far more than a round-robin turn
between three active ports should cost", that it is "not understood", and that
it "will matter when the rasterizer joins the same controller". The rasterizer
now shares that controller and the wait has become deadline misses. The item
said to find out where the time goes **before** changing `m1_sdram`. That is
still the right order, and it is now the blocking question rather than an
efficiency note.

The shape of the answer is constrained by the data: a port that is pending 40%
of cycles while the controller is idle 70% of them is spending its time in
handshake, not in service. A row-hit burst on this controller is six cycles.
103 is not six.

### What is NOT the cause, measured in the same capture

- **Not the 3D frustum.** `K=` reads `0000` on every one of the 148 samples, so
  no clipping is discarding the geometry. That was the competing explanation for
  the left-half dropout and it is struck off.
- **Not the fetch bandwidth alone.** See above.

---

## 2026-09-03 — THE MISSING 3D IS A THREE-FRAME PASS CADENCE. The producer runs over a frame, and the design then lost a frame on every pass

Fixed in `m1_raster3d`: the geometry pass now starts when the game presents a
new display list, not on the frame pulse. Built and measured in two benches;
the board is owed a flash. Everything below is measured.

### The board said which sequencer, and it was read the wrong way round

Three UART counters, from the 2026-09-03 captures, per one-second line:

    S   display-list swaps, the game's logic frames    27-29
    B   completed geometry passes                      19-20   (2/3 of S)
    N   bands PRESENTED                                1,392 = 24 x 58, every frame

N is the decisive one. `swap_now` needs three things at the blanking edge:
P_READY, C_IDLE and the edge. The consumer restarts its sweep on that same edge
and can only do so from C_IDLE - so 24 bands every frame means the consumer is
idle at every edge, without exception. **The only term that can be missing is
P_READY. The producer is late, not the consumer.**

The earlier entry below measured the consumer in exhaustive detail - sweep at
92.4% of a frame, idle 81% of it - and concluded the pipeline was healthy and
the defect did not reproduce in simulation. Both figures were right and both
were about the sequencer that was never late. Nothing had measured the
producer's pass length.

**WITHDRAWN, and reverted in this change: the "one-cycle swap window" fix
(fba1219).** It let the swap happen anywhere in blanking instead of on the
edge. The consumer leaves C_IDLE on the edge and does not return until the
sweep ends, so "anywhere in blanking while the consumer is idle" is the edge
cycle and no other: the change was a no-op by construction, and N had already
proved the race it was written for was not being lost.

### Why a pass over one frame costs three

    frame_start  (vblank_start, line 383 at hcnt = H_VISIBLE, over m1_cdc_pulse)
    swap         (vcnt reaches 384, two synchroniser flops)   ~470 clk_3d LATER

The producer started only on `frame_start`, and was freed only by the swap,
which is after it. So:

    pass < 1 frame:   start k, ready k+0.x, swap at the k+1 edge, start k+2
                      -> 2 frames a pass, equal to the game's list rate. B = S.
    1 < pass < 2:     start k, ready k+1.x, the k+2 edge swaps it out, and the
                      next frame_start is k+3 -> 3 frames a pass. B = 2/3 S.

58 frames a second / 3 = 19.3. That is the board's B.

### The pass IS over a frame, measured three ways

`tb_m1_raster3d`, the reference's frame 900 (33 objects, 626 quads), now with
a `ROM_LAT` knob on the polygon ROM and a per-pass cadence print:

    ROM latency   pass length   cadence (old)   cadence (fixed)
    1 cycle       0.95 frames   2               2
    8             0.95          2               2      the prefetch hides it
    24            1.27          3               2
    32            1.54          3               2
    64            2.90          4               -
    256           11.40         13              -

**0.95 of a frame with a memory that answers in a cycle.** The board's polygon
ROM is SDRAM shared with the V60 at 2:1, the tile fetch and the coprocessor; it
does not answer in a cycle.

`tb_m1_frame`, the real memory path, with the producer's pass timed from its
state (start = P_IDLE->P_WALK, ready = ->P_READY, swap = P_READY->P_IDLE),
900 M cycles of the old RTL, in the attract scene at 57-58 objects and ~1,650
quads:

    PASS3D #187 start=f368 len=1.47 fr wait=0.52 fr obj=58 q=1653
    PASS3D #188 start=f371 len=1.46 fr wait=0.53 fr obj=58 q=1669
    PASS3D #189 start=f374 len=1.47 fr wait=0.52 fr obj=58 q=1653
    PASS3D #190 start=f377 len=1.46 fr wait=0.53 fr obj=57 q=1660

A pass every three frames, each 1.47 frames long. **The defect reproduces in
simulation.** It always did; the instrument that showed it is a hundred lines
of bench. The whole 900 M-cycle run, old RTL:

    passes                       292   (303 list swaps)
    over a frame                 101
    cadence, start-to-start      1 frame: 39   2 frames: 152   3 frames: 101
    pass length, tenths of a fr  0: 173 (boot, empty lists)   13-15: 100 (attract)
    3D ROM port                  492,038 requests, mean wait 255 clk_sys cycles

Every pass over a frame cost three, to the pass. And the last line is the
next lever: the polygon ROM port waits 255 clk_sys cycles - 150 clk_3d - per
request on the shared controller. `rom_req` is a level held over a prefetch
burst, so that is per burst rather than per word, but the unit bench puts a
one-cycle memory at 0.95 frames and a 24-cycle one at 1.27; the board's memory
is where the other half-frame comes from.

The same 900 M cycles on the FIXED RTL:

    passes                       329
    over a frame                 150
    cadence, start-to-start      2 frames: 300   (1: 19, 3: 2, 4: 4, 5: 1, 0: 3)
    bands presented per frame    24 on 668 of 669
    WORST band fill              36,976 cycles, 108% of a band's beam slot

**And on the board, 2026-09-03 evening, seed 7 of ef6adce** (`build/uart_flipfix_seed7.txt`):

    S=001D  B=+1D..+1F  per second      B now equals S; it was 2/3 of it
    L=11xx..1Axx                        passes of 1.35 to 2.15 frames

The rate is fixed. Ben still sees overruns on the screen, so the rate was not
the whole picture.

### The overruns that remain are LATE BANDS, and they are the fill, not the pass

Second build (8e5e3d6, seed 7, `build/uart_late_seed7.txt`) adds T= (bands
presented after the beam had started on them, free-running) and W= (the worst
band fill in the second, in 16-cycle units; a slot is 0x0853):

    attract, 85-100 objects     T +3..+4 a second     W 0x0B00-0x0E3B  (1.3-1.7 slots)
    one second at 158 objects   T +23                 W 0x0C54

A late band shows as a horizontal strip with no 3D: scanout refuses rows the
presented band does not cover. Three buffers absorb one slow band, not a run
of them. `tb_m1_frame` at 900 M cycles (attract at ~25 objects) shows ZERO late
bands and a worst band of 108%, so the bench is not yet in a scene heavy
enough to see it; the board is.

**The reference's peak frame, 1020** (5,831 polygons in 41 objects by
`tools/mame_poly_budget.lua`, which now names the frame; dumped with
`DUMP_FRAME=1020 tools/mame_run.sh tools/mame_dump_frame.lua`, into
`build/mamerun/framedump/`), through `tb_m1_raster3d`:

    walked                 38 objects, 1,022 quads after culling and clipping
    pass                   1.26 frames WITH A ONE-CYCLE ROM (P_OBJW 54%)
    worst band fill        25,150 cycles, 74% of a slot; no late bands
    fill unit, by state    DIVAW+DIVBW 49%   FS_WALK 31%   everything else 20%
                           26,653 divides a side at 15.6 cycles each

So even the reference's heaviest sampled frame does not make a band late in
the bench, and the board reaches 1.3-1.7 slots in attract at 92-158 objects
(P=) - scenes heavier than any the 60-frame sample caught. **The divider is
half the fill.** `m1_raster_div` is radix-4 at 16 cycles and every quad-band
pays two of them serially (DIVA then DIVB). A pipelined divider, or issuing
A and B to two dividers at once, takes ~25% off every band; a reciprocal
table takes nearly the whole 49%. That is the next build, and T= and W= on
the board are its acceptance test.

**Built (a207c47): a second divider, both slopes issued at once.** Frame 1020
fill busy cycles 1,690,507 -> 1,332,363, exact (152,025 checks). But the
WORST band only went 25,150 -> 23,865, and its own breakdown says why:

    band 11 of frame 1020    23,865 cycles, 70% of a slot, 560 quads replayed
    divider wait             9,519   40%    501 segments x 19 cycles
    span walk                4,463   19%
    fixed per-quad states    ~4,900  20%    CLASSIFY, START1/2, LOADX, DIVA,
                                            DECIDE, FS_ENTER/END, FINAL, DONE
    the band clear           1,985    8%

42 cycles a quad, and 560 quads in one band because every quad is replayed
into every band it touches - the stadium and the road touch most of them.
The board's worst bands run 1.3-1.7 slots, so its pit-stop scene carries
about twice the quads a band of the reference's frame 1020, which the 60-frame
sample (frames 20-1600) never reached. The levers, in order of size: the
divide (radix-8 or -16, or overlapping the next quad's divides with this
quad's walk), the ten single-cycle states a quad, and a wider clear.

Sampled across the whole attract loop (`SAMPLE_UNTIL=7000`, 350 frames), the
polygon peak is frame 5460: 6,324 polygons in 45 objects, mean 4,661 in 69.
Through the bench (`build/framedump/frame5460/`): 1,352 quads walked, worst
band 26,808 cycles = 79% of a slot with 624 quads replayed, and the divider
wait is **47%** of it even with two dividers - 663 segments at 19 cycles,
because a band-clipped quad is almost always ONE segment, so the two slopes
are a quad's whole divide and parallelism past two buys nothing. The walk is
2,593 cycles: 4 a quad. So a quad in a heavy band costs ~40 cycles of which
~19 is one 16-step divide and ~12 are single-cycle bookkeeping states, and the
board's heavy bands carry ~2x these quads.

**The lever is the divide's LATENCY, not its count.** dy is an integer edge
height in scanlines and dx a pixel difference, so a 1/dy table (one M10K,
1,024 entries) and one DSP multiply, with a single remainder correction to
keep the quotient exactly truncated, makes it ~4 cycles. That and merging the
bookkeeping states roughly halves a heavy band. tb_m1_raster_fill's 152,025
exact checks are the gate; T= and W= on the board the acceptance test.

### THE MISSING GRANDSTAND IS THE QUAD STORE OVERFLOWING - 2026-09-03, late

Ben's photographs of the attract pit stop show the grandstand absent behind
the crew, in every frame of that scene, with the crew, car and road drawn.
Build 9e242f8 (seed 3, `build/uart_vblwait_seed3.txt`) adds D=, quads the
store could not hold summed over passes, and H=, passes that walked fewer
than half the previous pass's objects:

    D=  +400 to +10,000 a second, continuously      the store overflows every pass
    H=  +1 every few seconds                        passes are not short: the walk is complete
    T=  +2..+3 a second, bursts of +16..+31         late bands, as before
    W=  up to 0x10B6                                the worst band at 2.0 slots

`m1_quad_store` holds NQ = 2,048 quads a bank and drops everything after that
- the TAIL of the list, which is where the game puts the grandstand. MAME's
walk of the pit scene finds 161 objects and 5,582 polygons; after the
backface test that is well over 2,048. So the stadium is not culled and not
dropped for a frame; it never fits. H= says the list is walked completely,
which also rules out a half-written list, and the vblank wait added in
9e242f8 is therefore belt and braces rather than a fix.

The store is 51 M10K a bank at 2,048 (vertices 26, key 8, attributes 10,
indices 5), two banks. 3,072 a bank is ~+50 M10K, all of the 58 free and the
sound section's budget. `MISTER_SMALL_VBUF` was the framework's supposed lever on
M10K. **Measured: it frees NOTHING.** 496 of 553 M10K with it and without it
(par_13 vs par_3 of the same design); it changes the size of the scaler's
DDR3 frame buffer, not fabric memory. Struck off. The M10K for a bigger
store comes out of the sound budget or out of the quad record's width.

**PROVEN IN THE BENCH.** Frame 2500 (the tyre change, found by snapshotting
the attract loop every 250 frames - `build/render/attract_sheet.png`) dumped
with the corrected active-list choice and run through `tb_m1_raster3d`:

    objects walked            158 of 158, every ROM address matching MAME's walk
    quads the geometry emits  2,671   (MAME: 5,485 polygons before the backface test)
    store capacity            2,048   -> 623 quads dropped, the tail of the list
    object 156 (grandstand)   1,163 polygons -> 397 quads, LAST in the list
    picture at NQ=2,048       crew, car, tyres; no building, road, wall or stand
    picture at NQ=4,096       everything, matching MAME's snapshot of the frame

`build/render/frame2500_ours.png` against `frame2500_nq4096.png` and
`frame2500_mame.png`. NQ is a parameter of m1_raster3d now
(`make render3d VFLAGS="... -GNQ=4096"`). "dropped 0" in the bench's summary
is read from the bank that has just been cleared and means nothing.

The cost of the bigger store also lands on the FILL: the worst band of that
frame goes 112% -> 121% of a slot at 4,096, because every stored quad is
replayed into every band it touches. The store and the divider are one
budget, not two.

**THE TWO DIVIDERS ON THE BOARD (a207c47 seed 3, `build/uart_twodiv_seed3.txt`,
110 s of attract including the pit stop): T= 0. Not one late band**, against
+2..+3 a second with bursts of +16..+31 on the build before it
(`uart_vblwait_seed3.txt`, same scenes, same D= and L=). W= still reaches
0x0F8E - the worst single band at 1.9 slots - but the ring absorbs one slow
band, and what made bands late was RUNS of them; 21% off every band's fill
took the runs under the line. Whether the bars are gone to the eye is Ben's
to confirm.

### THE STORE IS 4,096 QUADS NOW, for +32 M10K - narrowed and split, measured

Three things made the record smaller, each checked exact:

- **Vertices are 9+9 bits, not 16+16.** tb_m1_raster3d now prints the
  post-clip coordinate range: 0..495 and 0..383 on frames 900, 2500 and
  5460. The clipper delivers screen coordinates. Anything outside is a
  contract violation, counted in the store's `dbg_oob`.
- **Colour is RGB565 in the store.** The band buffer keeps exactly those bits
  (`span_565` in m1_raster3d), so the 24-bit value was 8 bits of nothing.
- **The band mask is a band RANGE**, 5+5 bits instead of 24, computed from
  the full 16-bit inputs before they are narrowed so off-screen quads still
  land in no band.

And one thing Quartus does that the arithmetic did not predict: **any array
deeper than 2,048 goes into the 4,096 x 2 block mode**, so a 3,072-deep
32-bit key cost 16 blocks where 2,048 x 32 costs 7. Every array is now split
explicitly into a 2,048-deep half and the rest, selected by the top address
bit. The index array's two readers (sort and replay, never concurrent) share
one read, which removed a duplicate memory that had been there all along.
`make quartus MOD=qs<n>` with a wrapper in build/tmp, per bank:

    NQ       old record   narrowed, unsplit   narrowed, split
    2,048    52           37                  34
    3,072    -            84                  53
    4,096    -            84                  68

Two banks at 4,096: 136 blocks against 104 today, **+32 net**, 25 to spare.
`tb_m1_quad_store` 18,500 checks exact; pictures bit-identical at 2,048 on
three frames and at 4,096 identical to the earlier 4,096 render (frame 2500:
149,355 pixels, the whole scene). ALM went 1,046 -> 921 for the store.

Three replay-pipeline mistakes on the way, all caught by the store bench's
second position: the vertex read must be addressed a cycle early (q2, not
q); the attribute read is stage two and must hold under the stall gate; and
so must the index read, because pi advances in the cycle the read is taken.
A free-running registered read is NOT the same as a gated one when the
address moves on.

### WHERE THE STORE AND THE VERTEX WIDTH LANDED, after three board tests

The 4,096-quad store needed 9-bit vertices to fit, and **9 bits was wrong**:

- Truncated, a vertex the clipper puts at -1 wraps to 511 and the polygon
  stretches across the screen. On the board that was cars smeared over the
  whole picture, on two seeds.
- Saturated, the picture looked right to Ben - but `tb_m1_frame` counts
  **6,588 vertices outside 0..511/0..383 in 670 frames** and the board
  counted thousands a second on the wire (H= carried the store's `dbg_oob`).
  Every one of those is a polygon edge bent at the screen boundary instead
  of clipped. It looked good because the bend is small at speed.
- The three dumped frames (900, 2500, 5460) had NO out-of-range vertex,
  which is why the bench blessed 9 bits. **Three frames is not the range of
  a coordinate.** The frame bench now prints the range over a whole run:

      vertex coordinates, 670 frames   -104 .. 495
      quads with vertex 0 off-screen   10,246
      out-of-range at 16 bits          0

  And the cost of saturating them is measurable in the picture: the same
  900 M-cycle run paints **68,531,903 non-black pixels with 9-bit saturated
  vertices against 68,990,178 with 16-bit** - 458,275 pixels different over
  670 frames, which is the bent edges, about 680 pixels a frame.

So vertices are 16 bits again and the store is **3,072 a bank**, the largest
that fits: ~74 M10K a bank, 532 of 553 in the full core. Frame 2500 needs
2,671 and draws complete. **D= is not zero at 3,072** - the board's attract
drops in bursts, ~1,600 quads over a 110 s window - so some scenes still
exceed it, and the tail of those lists is not drawn. Ben's eye says the
picture is right, so what is dropped is small or distant; the number is on
the wire if it ever matters.

What DID pay for the bigger store, all exact: the arrays split at 2,048 deep
(Quartus's 4,096 x 2 block mode is half the density), colour as the RGB565
the band buffer keeps anyway, the band mask as a 5+5 range, and one read per
array.

### What the game does at a flip, measured, because the fix depends on it

`tools/mame_flip_writes.lua`, 2,000 frames, 994 flips. The flip is the V60's
write of listctl bit 3 - manual mode - not a vblank event.

    writes into the NEWLY SELECTED buffer, flip -> next vblank    0 on 992 of 994
    writes into the SELECTED buffer, flip -> next flip            0 on 992 of 994
    first write into the OTHER buffer                             one frame after the flip, 992 of 994

The two exceptions are the boot/attract transition. So the buffer the game
flips TO is finished when it flips and untouched until the next flip; the next
list is built in the other buffer starting a frame later. The flip's scanline
was not captured - `screen:vpos()` failed under pcall - so where in the frame
it lands is not known. (Run made with the device-ROM overlay, as always.)

### The fix

    prod_trig = list_flipped || (frame_start && no flip seen for 4 frames)

where `list_flipped` is the synchronised select differing from the one the
current pass latched. Starting at the flip is what MAME effectively does
(`set_current_render_list` at the next render) minus the wait for vblank, and
it fixes the PHASE as well as the rate: a pass finishes before the game flips
again and starts rewriting the buffer it read, for any pass up to two frames.
Restarting on the swap alone was considered and rejected - it locks a two-frame
cadence to the game's two-frame flips in whichever phase it lands, and the
wrong phase reads a buffer the V60 is writing for the tail of every pass.

The frame-pulse path is kept for a list that never flips (a bench, or a game
that single-buffers), held off while flips are arriving so it can never
pre-empt one by a few cycles.

Unit bench: 189,427 of 190,464 pixels painted, unchanged at every setting.

### Two instruments, and one bench fault

- `L=` on the UART: the last pass's length in units of 256 clk_3d cycles. A
  frame is 0x0C7C. The board can now say directly whether a pass fits.
- `tb_m1_frame` prints `PASS3D` per pass and, at the end, pass length and
  cadence histograms and the 3D ROM port's mean wait.
- `tb_m1_raster3d` held `frame_start` for the pixel's three clock ticks. The
  board delivers one, through m1_cdc_pulse. Three counted as three frames and
  tripped the four-frame fallback early - a bench artefact that looked like a
  one-frame cadence.

### What this does NOT fix

A pass over TWO frames still costs three, and its tail reads a buffer the game
has begun rewriting. The board's B fell to 14-18 at 157 objects (the crash
captures), which is passes of 2-3 frames in busy gameplay. The lever there is
the pass length itself: the polygon ROM's wait on the shared SDRAM, and the
geometry's cycles per quad. `L=` measures the first; the bench's ROM-port wait
measures the second.

### Test suite

`make test` is entirely green. Three lines differ from the block in CLAUDE.md,
none from this change: `v60_alu` and `v60_shift` were added on 2026-09-02 and
never entered; `m1_sdram`'s counts moved with an arbitration change before
today; `m1_copro_if` went 259 -> 261 with the both-FIFOs-full proof (520cf6a). The block
is corrected in this commit.

## 2026-09-04 — FFE59C IS NORMAL IN GAMEPLAY, and the crash is ATTRACT-ONLY

Three corrections, all from Ben watching the board while the telemetry ran.

**Gameplay does not crash. Attract does.** Every capture of the five-minute
freeze until now was taken in attract, and "the core crashes after five
minutes" was drawn from those. Playing the game it does not happen. Whatever
corrupts the copier's length is something ATTRACT does, which narrows the
hunt enormously.

**V=FFE59C is not by itself a crash.** The 2026-09-01 entry has it as "RARE
in normal running - 3 of 657 samples", measured in attract, and I read a long
run of it during gameplay as the freeze. It is not: the V60 sat there for
many consecutive samples while completing 29 display-list swaps a second, at
full speed. It is a block copy the game performs constantly and a
once-a-second sample lands in it often. The reliable signature is the TGP's
retire count FROZEN together with P=0000; the address alone will send the
next reader after the wrong thing, as it just sent me.

**And the stall pc is not always FE0C9B.** The 2026-09-03 entry calls the
crash deterministic on three attract captures that agreed. Gameplay gives
X=FE15FA. Three agreeing captures were evidence that attract reaches the
state one way, not that the state has one cause.

## 2026-09-04 — THE LEFT-HALF DROPOUT IS NOT THE QUAD STORE EITHER

Measured on the board while Ben played and saw the fault about ten times:

    objects            34-53 normally, 157-161 in the heaviest scenes
    quads dropped      ZERO, apart from one burst of 287 in two minutes
    logic frames       29 a second throughout - full speed
    bands late         3-4 a second
    worst band fill    45-90% of its slot

So it is not overflow, not starvation and not late bands. It also persists
while the car is STATIONARY, which rules out anything transient. Both
hypotheses so far are dead: the 2D window mode (ruled out because it varies
with load) and the quad store (ruled out because D= stays at zero).

### The hypothesis that fits all three observations: a LATCHED VIEWPORT

Ben's photograph plus "it happens more on corners" plus "I am stopped and it
is still there" only fit one shape: a register that latches a bad value
during a busy frame and keeps it.

`m1_raster3d` latches the viewport from display-list command 3 - vxc, vyc,
vx1, vx2, vy1, vy2 - and `m1_geo_clip` turns those into the frustum's left
and right planes and tests every vertex against them. A wrong vx1 clips
everything left of it, which is:

    a straight vertical edge      because a clip plane is exactly that
    worse on corners              because that is when the list is busiest
    persistent while parked       because nothing rewrites the viewport

It also explains why the drop counter is zero: the quads are not being
dropped for want of room, they are being CLIPPED AWAY before they are stored,
which is a different path entirely and counts nowhere.

**Tried in simulation and INCONCLUSIVE, because the run never reached
gameplay.** `FRAME_COIN=300000000` inserts a coin and presses start, and over
700 M cycles the viewport latched 606 times with vx1 never leaving 0 and x2
steady at 495.0 - but the run finished with 6 quads and no objects, still in
attract. A viewport that behaves in attract says nothing about one under
gameplay load, so this neither confirms nor refutes anything.

**What is needed first is a gameplay repro in simulation**, and the coin
sequence is not enough on its own: two 0.375 s presses of coin then start
leave the game in attract. Whether it needs more credits, a longer press, a
different DIP setting, or simply more time after the start is unmeasured -
`f_ctrl` and the layer census are already printed and would show the state
change when it works.

**The alternative is the wire**: m1_raster3d exposes dbg_xc, dbg_yc,
dbg_zoomx, dbg_zoomy, dbg_viewx and dbg_viewy and none of them reach the
UART. One word of view state there would show a corrupted viewport directly
on the board, where the fault definitely happens - if vx1 reads 248 rather
than 0 while the fault is on screen, that is the whole answer. That costs a
build; the simulation route costs none, which is why it was tried first.

**What would cause it** is the next question and is unmeasured: a walk that
reads command 3 while the V60 is mid-update would do it, and the pass now
starts on the list flip specifically to prevent that - so if this is the
mechanism, the flip protection is not covering something.

## 2026-09-04 — GAMEPLAY RUNS, and the left half of the 3D is hidden

With the tv80 I/O board the game reaches actual gameplay for the first time -
Ben's photograph shows Virtua Racing racing, position, lap time, the minimap,
the car. Two faults are visible and both are new information, because nothing
before this ever got past attract.

### The left half of the screen has no 3D

A PERFECTLY VERTICAL boundary at about half the width, roughly x = 248 of
496. Left of it: flat green below, flat blue above, and the 2D overlay. Right
of it: road, scenery, everything.

**That shape is the 2D window mode, not a 3D fault.** Dropped quads lose whole
objects and leave ragged holes; a straight vertical edge at the midpoint is a
clip or a column split, and `segaic24`'s window mode is exactly a per-pixel
column split that draws BOTH maps of a pair, one either side. The green and
blue are tilemap colours. So the likely mechanism is a tilemap drawn OPAQUE
over the left half, hiding the 3D behind it, rather than the 3D failing to
draw there.

Attract sets pair 2/3 to mode 1 with a varying split line, which is the
horizon and works. Gameplay has never been observed, so what it sets is
unmeasured.

**Next**: `make m1_frame FRAME_PRESS=0xfe` then `0xef` puts a coin in and
presses start, which is how to reach gameplay in the bench now that the I/O
board answers. Then read `f_ctrl[0]`/`f_ctrl[1]` and the per-layer pixel
census the bench already prints - it reports tm0..tm3 pixels a frame - and
compare against MAME on the same frame. The 2D rules are all implemented and
verified for attract; this is about what gameplay asks for.

### The pedals were digital, and triggers need TWO axes

MiSTer has no dedicated trigger signal: hps_io offers the two sticks, the
paddles and the spinners, and a trigger reaches a core by the player binding
it to a stick AXIS in the OSD. The documented racing convention is
left-stick-down for the accelerator and right-stick-right for the brake, so
those are the axes the core reads. A first attempt put both pedals on one
axis, which cannot work - two triggers are two independent inputs.

Magnitude rather than sign, because a trigger bound to an axis may rest at
either end depending on the pad. Idle 0x01, full 0xff, MAME's
PORT_MINMAX(1,0xff). The buttons stay live and the larger wins.

## 2026-09-04 — THE tv80 I/O BOARD BOOTS AND STOPS AT THE EEPROM

The Z80 runs EPR-14869 out of SDRAM and gets a long way. It does not reach the
shared RAM, and the reason is not the DPRAM path at all.

### What each side actually does, measured

**The V60 moves first, and it writes a signature.** `tb_m1_frame` counting its
writes into the shared RAM:

    01a=53  01b=45  01c=47  01d=41      "SEGA"
    020=01                              then the flag at 0x20

Three times each, which is the CPU retrying. So the V60 is not waiting for
permission to start - it has placed its request and is waiting at fe022c for
an answer.

**The Z80 never answers, because it never gets that far.** Every write it
makes into the 315-5338A's registers, in order:

    5=00  8=5e  0=40 0=c0 0=60 0=e0 0=60 0=e0 0=40 0=c0 0=40 0=c0 ...

Register 8 is the direction register; register 0 is port A. After setting
direction it toggles ONE BIT of port A for ever - 0x40 against 0xc0 - with a
second bit moving occasionally. That is a bit-banged serial clock, and port A
is where this board's **93C45 EEPROM** hangs. The firmware is stuck in its
EEPROM conversation and has not begun the DPRAM one.

### The contents are NOT the problem, tested

`93c45.bin` is 128 bytes in vr.zip and read as little-endian words its first
two are 0x5345 0x4741 - "SEGA", the same signature the V60 writes into the
shared RAM, which made it a very good suspect. Preloaded into the model
(`build/rom/vr_ee_le.hex`, simulation only for now) the behaviour is
**identical**. `ee[0]` reads back 5345, so the file loaded; the firmware
still never reaches the DPRAM.

### What the conversation actually looks like

The pin decode is confirmed against the RTL - port A bit 7 is the clock, bit
6 chip select, bit 5 data in - so the first command the firmware issues reads
as start(1), opcode(10)=READ, address 000000: a read of word 0, the
signature. Sensible, and what a boot check would do.

But over 512 register writes the model ends with `cs=0`, `st=EE_CMD` and
**`ee_addr` latched at 63** - all ones - and the trace beyond the first
command is six clocks of DI=0 followed by a long unbroken run of DI=1. All
ones decodes as start(1), opcode(11)=ERASE, address 111111.

So either the firmware is erasing and rewriting the device because it did not
like the read, or the model mis-frames the command and the firmware is
reacting to nonsense. Those are different bugs and the next measurement
separates them: **count how many times `ee_st` enters EE_READ and what
`ee_out` was loaded with**. If it never enters EE_READ the framing is wrong;
if it does, compare the 16 bits shifted out against ee[0] = 0x5345.

MAME's `eeprom_serial_93cxx_device` is the oracle for the framing, and the
one thing to check first there is the START BIT and dummy-bit convention -
93C45 and 93C46 differ in address width, and this model shifts nine bits
before decoding.

An earlier probe of `dbg_last_wr` read all zeros and I suspected the probe.
It was honest: that signal only updates on a DPRAM write COMMAND, and there
have not been any. The probe that answered the question watches `aw_l`/`dw_l`
on `wr_stb`, which is every register write.

## 2026-09-03 — THE FPS DIPS ARE THE V60 WAITING ON MEMORY, not the rasterizer

Ben reports the game slowing for about five seconds in one scene. That is the
GAME's logic rate, which is S= on the wire - display-list swaps a second, 29
when the game is running at full speed. From `build/uart_revert_seed7.txt`,
every line where S dips, against what else the core was doing:

    S=10..20    objects 41-58   geometry pass 1.48-2.02 frames
    S=27..29    objects 0-49    geometry pass 0.07-1.76 frames

So the dips are the busy scenes, and the question is which machine is short
of time. `tb_m1_frame`, 900 M cycles:

    V60 cycles                 273,793,911
    stalled on data                40.31%
    stalled on fetch               10.00%
    stalled on either              49.67%
    3D polygon-ROM port        703,087 requests, mean wait 255 clk_sys cycles

**The V60 spends half its life waiting for memory**, and the 3D geometry is
reading the polygon ROM out of the same SDRAM controller at a 255-cycle mean
wait. In a heavy scene the geometry reads far more ROM, so the contention
rises exactly when the game has most to do.

**The band fill is NOT part of this.** It reads the quad store and writes the
band buffer, both on-chip M10K; it never touches SDRAM. So the reciprocal
divider - which fixes late bands, a display artefact - cannot help the frame
rate, and neither can anything else aimed at the consumer. Said plainly
because the two symptoms look alike from the sofa and have nothing in common.

The levers, in the order their evidence supports:

1. **NOT the SDRAM constraints - those exist and are applied.** An earlier
   version of this entry said the interface was unconstrained, repeating a
   stale line from CLAUDE.md's to-do list. Ben corrected it, pointing at the
   Model 2 core. `tools/mister_project.sh` writes a full set into
   `Model1.sdc`: a generated clock on SDRAM_CLK, input delays of 6.4/1.0 ns
   on DQ, output delays of 1.5/-0.8 ns on the address, bank, data and control
   pins, and setup/hold multicycles to the CPU clock - with a critical
   warning if the generated clock cannot be created, so a build that lost
   them would say so. The 2026-09-03 builds read it and report SDRAM_CLK_pin
   at 12.5 ns with paths analysed and met. **Check a claim like this in the
   staged .sdc, not in a plan.**
2. **NOT the polygon-ROM latency either - the prefetch already hides it.**
   Measured with `ROM_LAT` on tb_m1_raster3d, frame 5460:

       ROM_LAT=0    P_OBJW 44.2% of the run
       ROM_LAT=8    P_OBJW 44.3%     - identical, fully hidden
       ROM_LAT=32   P_OBJW 58.0%     - now it bites

   So the geometry is ARITHMETIC-bound at any realistic memory latency, and
   what it is bound on is its own divider: `m1_geo_project` uses `fp_div`,
   29 cycles and not pipelined, which is 29 of the 32 cycles a point and 94%
   of the whole geometry stage (see the 2026-08-30 entry). Ben asked whether
   the divider work helps here and the answer is yes - just not the one that
   was done. The fill's divider never touches SDRAM or the geometry; the
   PROJECTION's divide is a separate unit and is the geometry pass's cost.

   Two ways at it, in increasing risk: a second `fp_div` so the two points of
   a record overlap, which the 2026-08-30 entry already names as "the obvious
   lever" and halves the stage to ~47%; or a reciprocal table like the fill's,
   which is harder because this one is IEEE-754 single and is checked
   bit-exact against MAME (20,037 checks in `m1_geo_project`), so a table
   needs a Newton step and its own exactness argument.

   That shortens the geometry PASS - L= on the wire, 1.5-2.0 frames in the
   busy scenes - and so restores the two-frame cadence there. It does NOT
   reduce the number of ROM reads, so its effect on the V60's frame rate is
   an open question rather than a promise.
3. **The V60's own CPI** - 17.71 in the earlier measurement, against the
   reference's 2 M instructions a second.

None of this is the 3D layer's display path, which is what the last session
fixed. It is the next thing, and it is bigger.

## 2026-09-03 — clear-on-readout for the band buffer DOES NOT SYNTHESISE

The 3D geometry rate is a third short of the display-list rate because the band
sweep tips past blanking and swap_now is missed. The obvious thing to reclaim is
the per-band clear: it walks 1,984 words at one address a cycle, per band, which
is a FULL-SCREEN WIPE per frame - 496x384/4 = 47,616 words, 5.8% of the 818,133
clk_3d cycles in a frame, whatever the band height.

The free way to remove it is clear-on-readout: the display already reads every
word of a band exactly once, so writing background back as it reads leaves the
buffer clean for its next fill. No extra memory, no extra time. The ring makes
it safe - an instance is either being filled or displayed, never both.

**Quartus 17.0 will not infer it.** Adding a write to the read port makes the
memory a dual-CLOCK true-dual-port RAM, and synthesis fails outright:

    Error (276003): Cannot convert all sets of registers into RAM megafunctions
    when creating nodes. The resulting number of registers remaining in design
    exceeds the number of registers in the device...

Tried twice: the plain form, and the symmetric template with a read added to the
write port (a write-only port is a known inference blocker). Same error both
times. Verilator simulates it happily - 825,351 checks pass - so this is
invisible without asking Quartus.

`make quartus MOD=m1_raster_band` was added for exactly this and answered it in
SIX SECONDS. CLAUDE.md's rule - "Test a memory idiom small; 1024 entries settles
the question in seconds" - is why this cost minutes instead of a 25-minute full
build and a mystery.

### What is left for the band fix

    a 4th band buffer     removes the clear entirely, costs ~16 M10K
                          (4 banks x 4 blocks). We have 57 free and sound wants
                          ~57, so this trades the 3D fix against sound fitting.
    find the margin       the clear is only 5.8% of a frame. Simulation puts the
    elsewhere             sweep at 92.4%, so hardware must be over 100%, and the
                          gap is unmeasured - 5.8% may not be enough.
    measure the gap       how much of a frame the sweep actually takes ON THE
    first                 BOARD. Without it, spending 16 M10K is a guess.

The third is the honest next step. Two fixes have already been talked out of on
this defect - a fourth buffer on a units error, and the FIFO deadlock - and both
would have been wrong.

**And so would all three of these.** They are about the band fill - the
consumer - which the board's own N= counter shows keeping up every frame. The
sequencer that was late is the producer; see the entry at the top of this
file.

## 2026-09-03 — the crash is DETERMINISTIC, and X=FE0C9B names the code

Third capture, with X= carrying the V60's pc latched at the instant the
coprocessor stops retiring. Log: `known_good/uart_crash_stallpc_2026-09-03.txt`.

**THE CRASH POINT IS IDENTICAL EVERY TIME.** Across three independent runs, on
two different builds:

    capture 1   R=35C5   B=0AD7
    capture 2   R=35C5   B=0AD6
    capture 3   R=35C5   B=0AD4

R is the TGP's free-running 16-bit retire count. It freezes at the SAME value in
all three, and the band count is within three. This is not a race and not a
timing flake - the coprocessor stops after the same amount of work every time,
which means the state is reachable in simulation given enough cycles.

**AND THE PC AT THE STALL IS NOT WHERE THE V60 ENDS UP.**

    X=FE0C9B    the V60's pc at the instant the TGP stopped retiring
    V=FFE59C    where the V60 is pinned afterwards

Two different addresses. FFE59C is the aftermath - the movcu block copy the game
runs in its error path, and the address the overlay has always shown because
sampling lands there. **FE0C9B is the instruction that was executing when the
coprocessor stalled**, and it is the lead this hunt has been missing.

That distinction is exactly what docs/findings.md asked for during an earlier
hunt at this same address: "The overlay's PC row cannot help - it samples at the
same point every frame and reads FFE59C blank or not. What is needed is the PC
at the instant of the teardown, latched on the transition, with a counter."

### Next step for this, when it comes back up the list

Disassemble around FE0C9B in the ROM. MAME's debugger will do it, and since the
crash is deterministic the same point can be reached under `make m1_frame` with
a long enough window - the V60 was reproduced stopping at ffe59c after 2.8
emulated minutes, which is about 13.4 billion cycles.

### Instrument notes, both mistakes worth not repeating

The latch was STICKY at first - "the first stall is the interesting one". Wrong:
the first stall is at BOOT, when the coprocessor legitimately has nothing to do,
so the field showed X=FE0027 while the core ran perfectly. Keeping the LATEST
stall is correct, and safe because after the crash nothing retires again, so the
crash's value is the last written.

And the 12.5 ms threshold fires on benign idle - at ~20 geometry passes a second
the TGP can idle 50 ms between commands. That is tolerable only because of the
non-sticky fix: benign latches are overwritten, and the crash's is final.

## 2026-09-03 — the "missing 3D bands" are not missing. The geometry is STALE

Ben reports bands not being drawn in busy 3D scenes. Measured on hardware, they
are all being drawn.

    N (bands PRESENTED)        1,392 a second
    expected, 24 x 57.52 fps   1,380 a second

Every band reaches the screen, every frame. What is short is the geometry behind
them:

    S (display-list swaps, the V60's logic frames)   ~29 a second
    B (completed geometry passes)                    ~20 a second

So about a third of the game's display lists never become new geometry, and the
display repaints the previous pass. On screen that is 3D updating in jerks while
the 2D moves smoothly - which from the outside looks like bands not being drawn.

### The mechanism

m1_raster3d hands a completed pass over only when three things coincide:

    swap_now = (pst == P_READY) && (cst == C_IDLE) && beam_blank && !beam_blank_d

Producer ready, CONSUMER IDLE, and the beam entering blanking. If the band
filler is still working when blanking arrives the swap is missed and the pass
waits a whole frame. Requiring C_IDLE is deliberate - the module's comment says
so - because swapping mid-sweep would tear the picture at a bank change.

There is no per-band timeout; `band_timer` only measures. Bands are not being
abandoned, the handoff is being skipped.

### What simulation says, and where it does NOT match the board

Over 647 sweeps of a 900 M-cycle run:

    mean sweep   1,285,088 cycles   92.4% of a frame
    worst sweep  1,285,761          92.5%
    bands presented per frame       24 on 668 of 669 frames

    per sweep:  WAIT 1,040,694  81%   idle, waiting for the beam
                FILLW  137,653  11%
                CLRW    81,008   6%   the per-band buffer clear
                FILL     26,638   2%

**The consumer is idle 81% of the time.** It finishes early and waits. In
simulation the pipeline is healthy and the defect does not reproduce - 24 bands
on 668 of 669 frames. On the board the geometry rate is a third short. So the
cause is something sdram_model does not capture, and real memory contention is
the obvious candidate: the 3D path shares that controller with the CPU, the tile
fetch and now a coprocessor running at 2:1.

**CORRECTED, later the same day.** Every number above is about the CONSUMER,
and the consumer was never late - N proves it idle at every edge. The defect
DOES reproduce in this same bench: the PRODUCER's pass is 1.47 frames in the
attract scene and runs every three frames. See the entry at the top of this
file. "Does not reproduce" meant "was not measured".

### A WITHDRAWN MEASUREMENT, because it nearly cost 14 M10K

An earlier pass concluded "the band filler does not fit a busy frame - 104% of
budget" and proposed a fourth band buffer to fix it. That was an 80 MHz cycle
count compared against a 47 MHz (clk_3d) budget. At 80 MHz a frame is 1,390,821
cycles, not 818,133, and the sweeps fit at 92%. The fourth buffer would have
bought nothing and spent a quarter of the M10K that sound needs.

The worst-BAND figure (35,719 against a 34,089 per-band budget) was units-
correct, but its budget assumed 24 bands must run back to back inside one frame.
They do not - they are paced by the beam.

### Where to look next

The board, not the bench. Candidates, in order:

1. SDRAM contention - the sweep sits at 92% of a frame in simulation, so a
   modest real-memory penalty tips it over and the handoff is missed.
2. The per-band clear, 1,984 cycles and 6% of a sweep. Cheap to remove IF a
   spare buffer exists to clear ahead; with three buffers all occupied there is
   no free window, and clearing one while it is displayed is a read-during-write
   on a dual-clock RAM.
3. Whether the sweep can start earlier in the frame rather than finish sooner.

### Instrument notes

`dbg_bands` and `dbg_band_cycles` were both UNCONNECTED outputs of m1_raster3d,
so Verilator optimised them away and nothing could read them. Both are now
wired: dbg_bands to the UART as N=, dbg_band_cycles to the bench.

N= originally SATURATED at 0xffff rather than wrapping, which at 1,380 bands a
second made it readable for 47 seconds and useless after. Fixed to wrap. It
answered the band question before it saturated, which is the only reason this
entry exists.

## 2026-09-03 (later) — the crash chain, with the V60's pc on the wire

Second 7-minute capture, this time with V= carrying the V60 program counter.
Full log in `known_good/uart_crash_pc_2026-09-03.txt`. The transition:

    S=0019  C=0233  R=C660  V=FF6C47   healthy - TGP pc varying, retiring
    S=0017  C=0229  R=68B0  V=FF85E4   healthy
    S=0017  C=004C  R=1C94  V=FF8629   TGP at idle dispatch, STILL RETIRING
    S=0007  C=004C  R=35C5  V=FFE59C   R FREEZES - V60 pc -> FFE59C
    S=0000  C=004C  R=35C5  V=FFE59C   V60 stalled, pc frozen
    S=0000  ...                FFE59C   four seconds
    S=000A  C=004C  R=35C5  V=FFE59C   swaps resume, pc STILL FFE59C
    S=001B  ...     P=0000   V=FFE59C   and never moves again

**THE TGP IS BLOCKED, NOT IDLE, and the retire count is what proves it.** Line
three has C=004C with R still advancing: at the idle dispatch the coprocessor
keeps retiring its polling loop, so the pc alone cannot distinguish hung from
waiting. R then freezes at 35C5 permanently. That is a stall.

**THE V60 IS PINNED AT FFE59C**, which is where the crash was reproduced in
simulation after 2.8 emulated minutes: a `movcu.h` block copy whose length is
read from memory. Swaps resume to ~26/s while the pc samples FFE59C every time,
so the main loop runs but spends nearly all its time inside that copy, every
frame.

**AND THAT EXPLAINS THE 2D GOING BLACK.** A game looping on a huge block copy
with P=0000 is clearing memory - tile RAM and display lists both. The tile path
never touches the coprocessor, which is why a dead TGP alone could not account
for the symptom, and this closes that gap.

So the chain is:

    TGP stalls -> V60 waits -> game takes an error path -> clears everything
    every frame -> black screen

The root cause is the coprocessor stall. Everything downstream is the game
reacting to it, which is why reloading the core is the only recovery.

WHAT IS STILL OPEN: why the TGP stalls at 0x004C. That address is the command
FIFO read, and a read of an EMPTY fifo returning zero was fixed on 2026-08-29 -
so either that regressed, or it is blocked pushing into a full OUTPUT fifo while
the V60 is not draining. The FIFOs are 16 deep and a full one halts the CPU.
Both sides waiting on each other fits every line above.

ALSO: a core load can fail silently, and V= now says so instantly. The first
load of this build gave V=FFFFF0 - the reset vector - with S=0000 and R=0041:
the CPU never fetched an instruction. Before this field that state was
indistinguishable from a core bug.

## 2026-09-03 — the five-minute crash is a COPROCESSOR deadlock, caught on the wire

The long-standing "black screen after about five minutes" was characterised for
the first time, on a 7-minute UART capture from a cold-ish machine (up 1:14).
Full log in `known_good/uart_crash_2026-09-03.txt`.

The overlay photo of this fault showed every counter frozen, which read as the
whole core stopping. That is not what happens:

    S=001D B=0A4B P=009D C=004C R=1C94   healthy, TGP retiring
    S=0007 B=0A5E P=0055 C=004C R=35C5   R FREEZES; swaps collapse 29 -> 7
    S=0000 B=0A72 P=009D C=004C R=35C5   swaps ZERO - the V60 has stalled
    S=0000 ...                            four seconds of S=0
    S=000B B=0AD7 P=0000 C=004C R=35C5   V60 resumes; objects -> 0 for good
    S=001D B=0B11 P=0000 C=004C R=35C5   full swap rate, no 3D ever again

So: the TGP stops retiring, the V60 stalls COMPLETELY for about four seconds,
then recovers to full display-list rate with P=0000 - no objects - permanently.
Video timing (F=003A) never falters throughout.

**AND THE 2D GOES BLACK TOO** - Ben, on seeing this analysis. The screen is
entirely black, not "3D missing over a 2D background". That matters because the
tile path never touches the coprocessor, so a dead TGP cannot explain it, and
the first draft of this finding was wrong to imply it could.

What has to be reconciled: video timing alive (F=003A throughout), the V60
running and swapping display lists at full rate (S=001D), bands still being
presented - and nothing on screen. Candidates, none yet tested:

  - the GAME has crashed. The V60's main loop still runs and still swaps lists,
    but the lists are empty (P=0000) and it has stopped writing tile RAM. A game
    error path that blanks the screen would look exactly like this, and the
    coprocessor deadlock is a plausible trigger for the game taking one.
  - the PALETTE. Both 2D and 3D index it, so a zeroed or unreadable palette
    blacks everything while every counter keeps moving.
  - a shared resource in the video path downstream of both layers.

The V60's pc would separate the first from the others in one reading, and it is
NOT on the printf channel - only in the 24-row overlay, which cannot show a
sequence. An earlier overlay photo of this fault showed pc=00FFE59C.

That is a COPROCESSOR DEADLOCK, not a dead core. The coprocessor FIFOs are 16
deep and a full one HALTS THE CPU, so the shape that fits is the TGP blocked
pushing a result into a full output FIFO while the V60 is blocked waiting on the
coprocessor. The V60 breaks out eventually - a timeout in the game code, or an
interrupt - and carries on with an empty display list.

WHAT CANNOT BE CLAIMED FROM THIS. At one sample a second the TGP freeze and the
V60 stall cannot be ordered; they appear in the same line. And `C=004C` is the
IDLE DISPATCH, so the pc sitting there is equally consistent with "hung" and
"correctly idle because no commands are arriving" - which is why the frozen
RETIRE COUNT is the stronger signal, not the pc.

This capture was only possible because 2:1 added C= and R= to the printf
channel. Before that the coprocessor's state was invisible on hardware and the
fault looked like a whole-core hang.

INSTRUMENT DEFECT FOUND IN THE SAME RUN: N= saturates. dbg_bands is
`if (ev_present && dbg_bands != 16'hffff) dbg_bands <= dbg_bands + 1` - it
SATURATES rather than wraps, so it is only readable for the first ~47 seconds at
1,380 bands a second. Long enough to answer the band question this time, useless
for anything longer. Make it wrap.

## 2026-09-03 — Virtua Fighter needs no special ROM, and MAME's NOT_WORKING is about MAME

`315-5724.bin`, VF's TGP microcode, is marked `BAD_DUMP` in MAME and `vf` is
`MACHINE_NOT_WORKING`. That reads as "the dump is broken, VF is blocked".

**It is not.** Ben confirms wangModel1 runs Virtua Fighter from the ordinary ROM
set with no special or replacement microcode. All three copies on this machine -
`vf.zip`, `vf.7z` and the loose `~/roms/vf/` - carry sha1
`8809d93d47593f808faca55161999677ac7a3eb0`, which is byte-identical to the dump
MAME flags. So the bytes another implementation runs successfully are the bytes
we already have.

`MACHINE_NOT_WORKING` describes the state of MAME's TGP emulation, not the ROM.
That matters here because **we implement the MB86233 rather than model it**, so
VF is worth actually trying rather than treating as blocked.

WHAT THIS COSTS US: MAME cannot be the oracle for VF. There is no reference
instruction stream, no reference frame to diff, no register census. Verification
for VF is "does it look right", which is weaker than everything else on this
project rests on. Virtua Racing stays the reference game.

**^^^ WITHDRAWN 2026-09-05. MAME RUNS VIRTUA FIGHTER.** It plays the attract
demo correctly, on a real emulated MB86233 at 40 MHz - `MB86233(config,
m_tgp_copro, 40_MHz_XTAL)` with program, data, IO and register-file maps, not
high-level emulation. It executes the microcode word our coprocessor hung on,
`0x04B0`, 116 times in a 20-second window and carries on. The same is true of
NetMerc.

The paragraph above reasoned correctly from the `MACHINE_NOT_WORKING` flag and
never tested it. That cost an hour of reading disassembly while a full
instruction-level oracle sat unused: `tgp_trace GAME=vf` produces 30 M
instructions of reference stream, and MAME snapshots give reference frames.

The flag means MAME's authors decline to call a game "working" on a `BAD_DUMP`
microcode. It is a curation stance, not a statement that the machine fails.
**Test the claim.** Kept visible because reasoning from a status flag felt like
evidence and was not.

DECOMPILING wangModel1 WAS CONSIDERED AND REJECTED. It is closed source, and
writing RTL from its internals would make that RTL arguably a derivative work -
the same reasoning that makes the s32 V60 import GPL-3.0-or-later however much
of it is rewritten, and the same policy CLAUDE.md already sets for
`third_party/geometrizer/`: run it as an external oracle, read it for
understanding, do not copy or adapt. Black-box observation of which files a
binary opens is fine; reading its internals is not. In the event it was
unnecessary - the ROM question was answered by asking.

## Reasoning has lost to measurement five times

Kept as a table because the pattern is the point, not the individual entries.

| Question | Reasoning said | Measurement said |
|---|---|---|
| where do the inputs live | a mailbox at DPRAM `0x100` | `0x00`-`0x0e`, polled every frame |
| why is most of the 2D missing | the row mask, then the window mode | neither — the V60 never gets that far |
| does the V60 read the coprocessor back | it must, to collect results | **constantly, 710,722 FIFO reads per 600 frames** — see the correction below. The "never" here was a census of the wrong address space. |
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

## The 2D path renders correctly — proven by a local frame

`make m1_frame FRAME_CYCLES=800000000` renders the attract-mode ranking table
correctly: `1st YU. 4'00"00` through `6th MAS`, with the car sprites and banners,
over the sky and sea. Saved as `docs/images/attract-ranking-2026-08-17.png`.

Census from the same run: **tm0=0, tm1=18933, tm2=190464, tm3=0**. So tilemap 1 —
the text layer that was missing all week — reaches the screen, and tilemap 3
contributes nothing, meaning it is not what covers the picture.

`tm2` was first recorded here as `65535 (saturated)`, which was the counter's cap
being quoted as a measurement. It is 190,464 — 496 x 384, the entire screen. The
counters are 18 bits now.

### And most of what MAME shows on these screens is 3D, not 2D

Measured, MAME 60 s of attract, Lua frame notifier sampling tile RAM at `0x700000`
every 30 frames with snapshots every 90:

**At the ranking screen MAME's background is the 3D road, not the sky and sea.**
The sky-and-sea image is in tilemaps 2/3 all along — *behind* the 3D layer, which
covers it. Our render shows the ranking text over sky and sea because the 3D that
should be in between is absent. **That output is correct for a core with no
rasterizer**, not a compositing fault, and it was nearly filed as one.

**The attract loop cycles through screens, and tilemap 1 is empty on several of
them.** Tilemap 1's content count over 60 s runs `0 -> 144 -> 768 -> 336 -> 0`.

This was first written up here as "screens with no 2D text at all", which is
**wrong** and was corrected on being challenged: `INSERT COIN(S)`, `CREDIT 0` and
the SEGA logo are plainly on screen in those snapshots. What is empty is tilemap
*1*. That text is on **tilemap 0**, which holds 16-432 non-blank words on every
screen of the loop. Reading "tilemap 1 is empty" as "there is no text" skipped
straight past the question of which layer the visible text was on — and that
question was the bug. See below.

**Nothing scrolls, and `ctrl` is not the reason.** `ctrl` — the pair's even
`vscr` — animates **every frame** in MAME: `2059, 2047, 2033, 201e, 2005, 23e9,
23ce...`, counting down through a 10-bit wrap, while ours held `2000`. That is a
real divergence but it is a *consequence*: that register belongs to pair 2/3, and
pair 2/3 turns out not to be drawn at all (below). Recorded because it was briefly
treated as the cause.

**Interrupts were suspected and are innocent.** The vblank IRQ reaches the V60 and
is taken: our PSW reaches `0x10040000` — bit 18, IE — exactly as MAME's does, with
700+ acknowledges over 200 frames. MAME agrees the game enables interrupts by
frame 9. A static picture with correct content looks exactly like a vblank handler
that never runs, and that cost a round of investigation; the measurement is one
counter at the acknowledge, not the raise.

**Build the local instrument before flashing.** This render was one index-1 ioctl
pass away from working for days, and in the meantime three hardware round trips
were spent photographing an overlay whose rows could not be identified with
confidence — one of those builds predated the telemetry it was being asked to
report, which the photograph revealed by showing tag `00` where `0F` belonged.

**NEVER EDIT RTL WHILE A BUILD IS RUNNING.** `tools/mister_project.sh` SYMLINKS
`rtl/` and `Model1.sv` into `build/mister` rather than copying them, so synthesis
reads whatever is on disk at the moment it reads each file. Editing during a build
therefore produces a bitstream that is part one revision and part another, with
nothing to indicate it. That is how a build acquired the window mode but not the
census, and the mixed result was then debugged as though it were a logic fault.

**And check the flow is finished before flashing, by exact process name.** A stale
`fit.summary` and `.rbf` from the previous run sit in `output_files` looking
current. `pgrep -f quartus_` is not the check — the pattern matches the checking
command's own line and always reports something running; `pgrep -x quartus_fit`
and friends do not.

Also note the frame test's DEFAULT 120 M cycles renders the *wrong moment*:
`pc=fe143d`, one FIFO push, and only tilemap 2 on screen. The attract content
needs ~700 M. A render of the wrong program state looks exactly like a rendering
fault.

And the deadline-miss count is identical at 120 M and 800 M cycles (9,417 both),
so it is entirely boot transient — the same cumulative-counter trap as before, and
the char-fetch wait average falls from 136 to 19 cycles once the boot phase stops
dominating it.

## The row mask is keyed to the tilemap, not to the tile category — 2026-08-17

**This is the missing text.** `draw_common` computes two values from the same
expression, one line apart, either side of a shift:

```cpp
uint16_t tpri = layer & 1;   // BEFORE the shift -> the tile CATEGORY
lpri = 1 << lpri;
layer >>= 1;                 // layer is now the tilemap, 0..3
...
int win = layer & 1;         // AFTER the shift  -> the ODD tilemap
```

`draw_rect` then applies them as two **independent** gates:

```cpp
uint16_t m = *mask1++;
if (win) m = ~m;                 // does this 8-pixel column draw from this map?
if (!(m & 0x8000)) {
    if (srct[xx] == tpri || ...) // which tiles inside it contribute?
```

So both categories of one tilemap see the **same** mask polarity, decided by
whether that tilemap is odd or even. Ours computed `mask ^ category` — the same
expression read one line too late — which is right for an even tilemap's
category-0 pass and an odd tilemap's category-1 pass, and inverted for the other
two. `INSERT COIN(S)`, `CREDIT 0` and the SEGA logo are category-1 tiles on
tilemap 0, an even map, so they were suppressed wherever the mask bit was clear —
which the game leaves clear across most of the screen.

**Measured, per frame, over 680 frames:** tilemap 0 held content in **617** frames
and won a pixel in **47** — and those 47 are the boot frames before the game
writes a mask table at all. Tilemap 1 won in 329 of the 333 it had content for.
That asymmetry is the fault's signature: the ranking table is category-1 on an
**odd** map, the one combination the wrong formula got right by luck, which is why
that text appeared and made the 2D path look healthy.

After the fix, the same 53 content words on tilemap 0 produce **9,674 visible
pixels**, and the attract screen renders `MEDIUM COURSE RANKING`, the column
headers, the rank rows with their car sprites, `INSERT COIN(S)`, `CREDIT 0` and
`© SEGA 1992` — every one of which was absent before. Saved as
`docs/images/attract-rowmask-fixed-2026-08-17.png`; against MAME's own frame the
text matches in position and colour throughout.

Two differences remain against the reference, neither a 2D fault:

- **The background is flat**, where MAME has the 3D road. That is the rasterizer,
  which is not built. 93% of the frame is backdrop.
- **The blue SEGA logo is not visible.** It is blue on MAME's grey road and would be
  blue on our blue backdrop, so it is probably drawn and indistinguishable rather
  than missing. Not confirmed either way — the census counts wins per tilemap, not
  per glyph, so it cannot separate the two.

### WITHDRAWN: a pair in window mode with hscr bit 15 clear draws NOTHING

**This is wrong and is the open bug.** It is kept in full because the RTL, the
reference model and this file all still carry it, and because the way it was
reached is the lesson.

What was claimed: `draw_common`'s inner `if (hscr & 0x8000)` has no `else`, so a
pair in window mode with that bit clear draws neither map.

```cpp
if (ctrl & 0x6000) {           // window mode
    if (layer & 1) return;     // the odd map never draws directly
    set_scrolly(both maps);
    if (hscr & 0x8000) { ...per-line draw... }   // and only here
} else { ...normal path, with the row mask... }
```

**There is an `else`, at `segaic24.cpp:418-456`**, and in it MAME splits the screen
into two rectangles and draws BOTH maps of the pair, one in each:

```cpp
} else {                                     // hscr & 0x8000 clear
  set_scrollx(both maps, -(hscr & 0x1ff));
  switch ((ctrl & 0x6000) >> 13) {
  case 1:                                    // VERTICAL split
    v = (-vscr) & 0x1ff;
    c1.max_y = v-1;  c2.min_y = v;
    if (!((-vscr) & 0x200)) layer ^= 1;
    draw(layer, c1);  draw(layer^1, c2);
  case 2: case 3:                            // HORIZONTAL split
    h = hscr & 0x1ff;
    c1.max_x = h-1;  c2.min_x = h;
    if (!(hscr & 0x200)) layer ^= 1;
    draw(layer, c1);  draw(layer^1, c2);
  }
}
```

The *measurement* below is right; the conclusion drawn from it was not. Attract
does set `ctrl` to `0x2000`-`0x23xx` on pair 2/3 — window mode 1 — with `hscr`
below `0x0200` so bit 15 is never set. That does not mean the pair is undisplayed.
It means the pair is drawn as a **vertical split at scanline `v`, tilemap 2 above
and tilemap 3 below** — which is a horizon. **That is the sky and the sea.**

Suppressing the pair instead paints the screen with palette 0, which is blue, at
whatever rate the game toggles the mode. The user identified this from the board
before the code was reread: the blue flashed at about the rate the text should
blink, and *"seems to me that the full maps are being selected instead"*.

The window decision uses the **pair's even** `hscr`, not each map's own, because
MAME only reaches that branch through the even map's draw call. That part holds.

**How to fix it**, in the order the reference actually exercises:

1. **mode 1, `hscr` bit 15 clear** — a per-**scanline** layer pick: `y >= v`
   selects the other map of the pair. Cheap, because the renderer is already
   per-scanline and `cur_line` is to hand. This is the sky and sea.
2. **modes 2/3, `hscr` bit 15 clear** — a per-**pixel** split at `x = h`. That is a
   column mask and can reuse the row-mask machinery.
3. **`hscr` bit 15 set** — the per-line H-scroll table at `0x4000 + 0x200*layer`.
   Nothing measured so far reaches it; do it last.

`tb_m1_video.cpp`'s reference model encodes the same misreading and must change
with the RTL, or the suite will hold the bug in place — which is exactly what it
did for 380,929 checks, below.

**Why rereading did not catch it, twice.** The first pass through `draw_common`
found the row-mask polarity bug and the `layer & 1` double meaning, and produced
this wrong rule in the same sitting. The second pass reproduced the wrong rule from
the notes rather than from the source. What broke it was neither pass: it was a
user looking at the board and matching the flash rate to the text blink rate.
**A rate is a measurement that a still frame cannot carry**, and the class of
evidence that had been relied on — single captured frames — cannot see a blink at
all. Several earlier "the text is absent" readings came from single frames and are
worth nothing.

### Why 380,929 checks agreed with the bug

`m1_video`'s reference model was written from the same reading of `draw_common` as
the RTL, so both were wrong in the same way and the comparison passed. Worse, the
comment in the reference stated the wrong rule explicitly and confidently.

- **A reference derived from the same reading of the source as the implementation
  cannot catch a misreading of the source.** It can only catch a slip between the
  two. What caught this was a per-layer census against the reference *running*,
  not against a rereading of it.
- `tb_m1_tile_fetch` never drove `row_mask` and never checked `lb_masked` at all,
  so the module owning the logic had no coverage of it. It does now, including a
  case asserting the mask is independent of the tile category, and reinstating the
  old expression fails it.

## Tile RAM infers as dual-clock RAM, and Quartus calls its read-during-write
## behaviour UNDEFINED — 2026-08-17

From the build log, unprompted:

```
Warning (276027): Inferred dual-clock RAM node
  "...m1_main:main|m1_mainram:rams|tram_v_lo_rtl_0" ... The read-during-write
  behavior of a dual-clock RAM is UNDEFINED and may not match the behavior of
  the original design.
```

Both video-side tile RAM copies (`tram_v_lo`, `tram_v_hi`) and both palette
copies raise it. The CPU writes on `clk`, the video side reads on `vid_clk`, and
a simultaneous access to one address has no defined result on real silicon.

**Verilator models it as a clean read.** So this is a simulation-versus-hardware
divergence *by construction*, in the exact memory whose contents appear to be
missing on hardware — and no amount of simulation can show it. That makes it a
strong candidate rather than a proven cause; it has not been tested.

Note tile RAM is already **duplicated**, `tram_c_*` for the CPU side and
`tram_v_*` for the video side, precisely so each is one-write/one-read and fits
an M10K's two ports. So this is not a port-count overflow. It is the crossing.

### The selectivity fits it. The direction of the error does not. — 2026-08-17

This was argued in both directions before being settled, so both halves are here.

**For it**: the maps that read blank are exactly the maps being written. MAME's
own census shows tilemaps 2/3 constant at 4096 words at every sample — written
once at init, static after — while tilemaps 0 and 1 are rewritten every frame
(205 -> 315 -> 1675 -> 153 -> 663). Reads of a continuously written array collide;
reads of a static array never can. The sea renders perfectly and the text layers
read as empty, which is that split exactly.

An earlier dismissal of this — *"maps 2/3 fill perfectly, so the write path works,
so it cannot be memory"* — is a **non-sequitur** and is withdrawn. The warning is
about read-during-**write**; the content census measures what the video side
**reads**. "Maps 0/1 are empty" and "reads of maps 0/1 come back blank" are
different claims and the census cannot separate them, because the census reads
through the suspect path. Its zero is not the proof it was presented as.

**Against it**: the *direction* of the error is wrong. Read-during-write returns
whatever the array holds mid-write. A corrupted word is overwhelmingly non-blank,
and the census counts non-blank words — so corruption can only push the count
**up**, or change *which* tiles appear. It cannot turn several hundred non-blank
words into the `008 000` the board reports. That reading means the words are not
there to be read, or are never read at all.

So: a real hazard, worth closing on its own merits, but not the explanation for an
empty layer. The write census (row `1B`) is what separates the two, and it exists
because neither census alone can.

**The fix, when it is done**, is to move tile RAM to a single clock domain and
cross the CPU's writes in as `m1_cdc_port` already does for SDRAM. A single-clock
simple dual-port RAM has *defined* read-during-write — old data — which Quartus
and Verilator model identically. Registering the read does not help: the
corruption is inside the RAM block, not at the crossing.

## The write census: what the CPU wrote, against what the renderer read
## — 2026-08-17

Overlay rows `19`/`1A` count non-blank tile words the renderer **read**. Row `1B`
counts the words the CPU **wrote**, by tile-RAM region, per frame. Neither alone
can say whether an empty layer is a CPU fault or a memory fault; together they
can, and that is the only reason the row exists.

Counted on `m_req && m_we && sel_tileram` in `m1_main.sv` — upstream of the RAM,
so a fault inside the memory cannot hide from it. Regions are word address bits
14:13: maps 0/1, maps 2/3, the H-scroll table and scroll registers, the row masks.

**Cumulative was tried first and does not work.** The boot self-test writes and
reads back every word of tile RAM, so all four regions saturate at `FFF` long
before the game loop starts — simulation showed exactly that by frame 64. A
cumulative count cannot distinguish "written once at boot" from "rewritten every
frame", which is the whole question. It is reset on `vblank_irq` instead, latching
the completed frame, so it measures the game loop alone.

**The content census is upstream of window suppression**, checked because it would
otherwise be a confound: `layer_off` reaches only `lb_masked` in
`m1_tile_fetch.sv`, while the `tw_nonblank` pulse fires at `F_TILE` regardless. A
suppressed layer is still fetched and still counted. So the board's `008 000` is a
real "the fetched words were blank", not our own suppression hiding the fetch.

### The game loop never rewrites the tilemaps — 2026-08-17

The first thing the per-frame census measured, and it was not expected.
`make m1_frame FRAME_TRACE=1`, steady state from about frame 90:

```
F92 ... have=53,0,0,0 rtl_have=1624,0,0,0 wr=0,0,12,0 ctrl=0000,0000 ...
F93 ... have=53,0,0,0 rtl_have=1624,0,0,0 wr=0,0,24,0 ...
```

**Zero writes per frame to any of the four tilemaps.** The only tile-RAM region the
game loop touches is `0x4000-0x5fff` — the H-scroll table and the scroll registers
— at 12 to 24 words a frame. Tilemap 0 holds 1,624 fetchable non-blank words at
the same moment, so its content was written **once during init** and is static
after.

Two consequences:

1. **It closes read-during-write as the explanation.** There are no writes to
   collide with. Whatever makes the board's maps 0/1 read blank happens at or
   before init, not in the steady state that is on screen.
2. **It moves the question to the init-time writes.** Both the CPU-side copy
   `tram_c_*` and the video-side copy `tram_v_*` take the same write strobe, so
   the next discriminator is whether the board's init writes land at all — not
   whether the steady state corrupts them.

It also decided the shape of overlay row `1B`. Showing both tilemap regions would
read `000 000` on a *working* design, which cannot be told from a counter that does
not work, so the right field is the scroll region instead: a live control that
proves the counter and the game loop are running.

### The full-screen blue is tilemap 2 drawn opaque over an empty map — 2026-08-17

Not the backdrop, which is where it was looked for. Four numbers already measured
make the chain, with nothing new needed:

- `bd=0/190464` — **zero** pixels fall through to the backdrop, every frame
- tilemap 2 wins 180,790 of 190,464 pixels
- tilemap 2 holds no content, so every tile word reads `0x0000`: tile index 0,
  colour bits 0
- tile 0's pixels index **palette entry 0**, which is blue in Virtua Racing

So the blue is tilemap 2's **opaque category-0 pass painting palette 0**. Maps 2/3
draw their category-0 pass opaque — already recorded above as a state worth
recognising — and over an empty map that fills the screen with one colour.

This is why the backdrop counter reads zero while the screen is blue. The two
sources are indistinguishable on a photograph and land in different counters, and
the search went to the wrong one.

It also says what the flashing is: alternation between frames whose map reads
content and frames whose map reads blank. The board shows sky and sea part of the
time, so the content exists — the blue frames are the reads that came back empty.

### WITHDRAWN: tilemaps 1, 2 and 3 are empty in simulation — 2026-08-17

**Wrong, and wrong because the run was too short.** It was measured at frames 90 to
296 as `have=53,0,0,0` and reported as a divergence from MAME. The user objected
that the board plainly shows sky and sea, so the data must be there. It is.

Run to 3.4e9 cycles instead of 4e8 and tile RAM fills completely, at frame ~352:

```
  tram blocks: 0000:315 1000:648 2000:4096 3000:4096 5000:1 6000:48
```

**Those are MAME's numbers.** Map 0 315 against MAME's 205-1675 (315 is one of its
sampled values), map 1 648 against MAME's 648, maps 2 and 3 4096 each against
MAME's constant 4096. Plus a scroll register and 48 mask words. Our tile RAM
content is not a divergence at all — it is right.

So the earlier reading has one cause: **296 frames is not far enough in.** This is
the third time a board-versus-simulation comparison has been made at the wrong
simulation state, and the first two are recorded under "Instruments, and what each
cannot do". The instrument is fine; the run length was the fault, and there was no
check that the state had been reached.

Keep the 4x stride caveat from the withdrawn entry — `tram_content_census` samples
every fourth word, so its counts must be multiplied by four before comparing with
MAME. `have=58,144,1024,1024` at frame 381 is 232/576/4096/4096, which agrees with
the full-stride block census above.

### The whole failure reproduces in simulation at frame 381 — 2026-08-17

Once the run is long enough there is no need for a board at all:

```
F382 bd=175982/190464 win=11038,3060,0,0 have=79,144,1024,1024
     rtl_have=2520,4095,4095,4095 wr=252,0,24,144 ctrl=0000,2000
```

Read across it:

- `ctrl=0000,2000` — pair 2/3 is in **window mode 1**
- `rtl_have=...,4095,4095` — maps 2 and 3 hold and fetch full content
- `win=11038,3060,0,0` — and they win **zero** pixels
- `bd=175982/190464` — so **92% of the screen falls through to the backdrop**,
  which is palette 0, which is blue

That is the reported symptom, cause and effect on one line, and it is the window
suppression above: MAME would draw this pair as a vertical split, tilemap 2 above
scanline `v` and tilemap 3 below. Note the blue arrives by the backdrop here and by
tilemap 2's opaque pass at frame 296 — two different routes to palette 0, which is
why chasing the colour rather than the counter wasted time.

`wr=252,0,24,144` also corrects the "the game loop never rewrites the tilemaps"
finding above: it does, once it reaches this screen. 252 words a frame into maps 0/1
and 144 into the row masks. That reopens read-during-write as a hazard on the
maps that are being written — though it remains unable to explain a *low* non-blank
count, for the reason given there.


### FIXED, and measured on real game code — 2026-08-17

Same frame, `make m1_frame FRAME_TRACE=1 FRAME_CYCLES=3400000000`, before and after
removing `!win_hs` from the suppress term:

| | before | after |
|---|---|---|
| backdrop | `175982/190464` (92%) | **`0/190464`** |
| tilemap 2 wins | `0` | **`176366`** |
| tilemaps 0/1 wins | `11038, 3060` | `11038, 3060` |

The blue is gone and the sky/sea layer draws, with the text layers untouched.

It agrees with MAME term for term. `ctrl = 0x2000` gives `v = (-0x2000) & 0x1ff =
0`, so `c1` is the empty rectangle and `c2` is the whole screen; bit 9 of `0xE000`
is clear so `layer ^= 1` fires, and `draw(layer^1, c2)` is **tilemap 2 across the
entire screen**. 176,366 is exactly the screen less the 14,098 pixels layers 0 and
1 take. An earlier note in `m1_video.sv` had this backwards — "MAME draws tilemap 3
across the whole screen and tilemap 2 not at all" — because the swap was read the
wrong way round.

### The fixture had been hiding the bug, and the first report of that was wrong too

Reinstating `!win_hs` initially left all 380,929 checks passing, which was reported
as "this suite cannot discriminate the fix", with two mechanisms offered for why:
row-mask complementarity between layers 0/1, and `cat0` treating layers 2/3 as
opaque. **Both were invented to explain a result that had a much simpler cause.**

`tb_m1_video.cpp` set `tile_ram[0x5002] = 0x8000 | 0x1f8`. The faulty term was
`!win_hs || ...`, so with bit 15 set it was never evaluated and the bug was
unreachable from that fixture. The game keeps `hscr` below `0x0200` on every
tilemap, so the fixture was testing an input the hardware never presents. With the
bit cleared the suite fails **4,330 of 380,929** checks against the bug and passes
clean without it.

Two things came out of it, both kept:

- **A fixture that avoids a bug is indistinguishable from one that covers it.** The
  only way to tell is to break the RTL on purpose and watch the count move. That is
  now done for this fix rather than asserted.
- `tb_m1_video` prints a **`layer wins`** line and **fails** if any tilemap never
  won a visible pixel. A layer that wins nothing is a layer the suite cannot test,
  and that had been true silently.

Still open and deliberately not folded in: `cat0` treats layers 2 and 3 as opaque
unconditionally, so a layer with its `vscr` disable bit set still paints. MAME's
`if (vscr & 0x8000) return;` skips it before any category decision. The RTL and the
reference agree, so the suite cannot see it.

### Modes 2/3 are the TEXT BLINK, and they are 7.8% of frames — 2026-08-17

Measured over a full 2,478-frame run, every `ctrl` value the game selects:

| `ctrl` (pair 0/1, pair 2/3) | frames | what it means |
|---|---|---|
| `0000,2000` | 1,898 | pair 2/3 in **mode 1** — fixed |
| `0000,0000` | 336 | no window mode |
| `4000,2000` | **194** | pair 0/1 in **mode 2**, pair 2/3 in mode 1 |
| `03xx,2000` etc. | 14 | pair 0/1 normal with a vscroll, pair 2/3 mode 1 |

So **mode 1 covers 85% of frames** and is what the fix addressed. **Mode 2 on pair
0/1 covers 7.8%** and is still suppressed. Pair 0/1 is the pair the text lives on.

On one of those frames, before the fix:

```
F1936 bd=190080/190464 win=0,0,0,0 have=16,768,1024,1024
      rtl_have=552,4095,4095,4095 ctrl=4000,2000
```

All four layers win nothing and 99.8% of the screen is backdrop, with every map
holding content. After the fix pair 2/3 draws on these frames and pair 0/1 still
does not — so the sky and sea are steady and **the text disappears on 8% of
frames**. That is the "coin and other text flash on and off" reported from the
board, and it now has a number.

**What it needs.** MAME, same `else` branch, cases 2 and 3:

```cpp
h = hscr & 0x1ff;
c1.max_x = h-1;  c2.min_x = h;
if (!(hscr & 0x200)) layer ^= 1;
draw(layer, c1);  draw(layer^1, c2);
```

A per-PIXEL split at x = h, not per scanline, so `win_suppress` cannot carry it.
The natural home is `m1_tile_fetch`: it writes the line buffer four pixels at a
time with a 4-bit `lb_masked` and knows its own x, so each of the four bits can be
set from `x < h` against which side this layer owns. The row-mask path is 8-pixel
granular and cannot be reused directly, but it is the same insertion point.

### And in window mode BOTH maps take the EVEN map's scroll — 2026-08-17

Found while planning the modes 2/3 work, from the same branch:

```cpp
set_scrolly(layer, vscr & 0x1ff);    set_scrolly(layer|1, vscr & 0x1ff);
set_scrollx(layer, -(hscr & 0x1ff)); set_scrollx(layer|1, -(hscr & 0x1ff));
```

`vscr` and `hscr` there are the **even** map's, because `if (layer & 1) return;`
runs first and only the even map ever reaches this code. We pass each layer its
own, so the odd map of a window pair scrolls wrongly.

Both values are already latched — `ctrl_r` **is** the even `vscr` and `hctrl_r` the
even `hscr` — so the fix is two muxes at the fetcher's ports:

```systemverilog
.hscr(win_mode ? hctrl_r : hscr_r),
.vscr(win_mode ? ctrl_r  : vscr_r),
```

`vscr` bit 15 rides along correctly rather than by accident: in window mode MAME
only ever tests the **even** map's disable bit, because the odd map returns before
the check. So an odd map cannot be disabled on its own in window mode, and passing
`ctrl_r` reproduces that.

**Invisible in attract today**, which is why it has not shown up: `ctrl = 0x2000`
gives `v = 0`, so only the even map draws and the odd map's scroll never matters.
It matters as soon as `v != 0`. Recorded rather than fixed on its own, because it
belongs with modes 2/3 and both touch the same ports.

## The build with the window fix: 29,434 ALM, 452 M10K, and -0.019 ns — 2026-08-17

`bash tools/mister_project.sh && cd build/mister && quartus_sh --flow compile
Model1`, Quartus 17.0.0 Lite, 5CSEBA6U23I7. Successful, 0 errors, 138 warnings.
`build/mister/output_files/Model1.rbf`, 4,118,248 bytes.

| | this build | free |
|---|---|---|
| ALM | 29,434 / 41,910 (70%) | 12,476 |
| M10K | 452 / 553 (82%) | **101** |
| DSP | 50 / 112 (45%) | 62 |
| registers | 23,433 | — |

M10K at 101 free matches what was already recorded as the binding resource, and
the band buffer wants ~51 of them. The `26,663 ALM / 409 M10K` figure in CLAUDE.md
is **stale** — it predates the row-mask, window and census work — and the numbers
here supersede it.

### Worst setup slack is -0.019 ns, and it is the SDRAM address path

```
From  emu:emu|m1_sdram:sdram|xfer_addr[2]_OTERM175
To    emu:emu|m1_sdram:sdram|sd_a[12]
Slack -0.019 (VIOLATED)
```

One violated path of five reported, the next two at +0.029 and +0.063 on the same
bus. **It is inside `m1_sdram` at both ends**, so the window change does not touch
it; the previous +0.401 ns was on a design ~2,800 ALM smaller and this is placement
pressure on an interface that has no constraints of its own.

**The pack warning is NOT the cause of this path, and saying so was wrong.** The
fitter does report it sixteen times —

```
Warning (176279): Can't pack register node "...|m1_sdram:sdram|sd_a[8]" into I/O
pin "SDRAM_A[8]". The node cannot simultaneously use clear and load signals.
```

— and `sd_a` is indeed reset to `'0` at `m1_sdram.sv:433` while being
conditionally loaded elsewhere, which a Cyclone V I/O register cannot do. But the
violating endpoint `sd_a[12]` **is** packed: its location is
`DDIOOUTCELL_X40_Y81_N10`. The warning applies to other bits. Attributing the
violation to it was a guess from the warning text, made before reading the path.

**What the path actually says**: 9 logic levels, 12.899 ns of data delay, **73% of
it interconnect**. Two hops dominate:

```
sd_a[0]~3 -> sd_a[0]~4      1.355 ns   X82_Y21 -> X51_Y21
sd_a[0]~4 -> sd_a[12]|ena   4.161 ns   X51_Y21 -> DDIOOUTCELL_X40_Y81
```

One wire is **4.161 ns, a third of the whole budget**, carrying the enable from
logic at row 21 to an I/O cell at row 81. The SDRAM pins are fixed by the board, so
that distance is the fitter having placed the control logic sixty rows from the
pins it drives, on an interface with no constraints telling it the path matters.

**So the area lever is not the remedy it looks like.** Freeing the V60's FP group
is -2,984 ALM and would give the fitter room to place that logic nearer the pins —
but nothing forces it to, and the result is only knowable after a 25-minute build.
It is a lottery ticket, not a fix.

**The deterministic fix is the 9 combinational levels feeding `sd_a`** — `sel~1`,
`sel~5`, `Mux118~0`, `always3~1/2`, `sd_ba~1`, `sd_a[0]~3/4` — the state machine
computing its address mux in the same cycle it drives the pins. Registering the
address select one cycle earlier removes most of them. Dropping the reset on the
outputs is still worth doing for the other sixteen bits, but it is a separate,
smaller thing.

Not done here: it belongs to "close the SDRAM interface", needs its own build to
measure, and `m1_sdram`'s 74,729-check suite has to be re-run against it. 19 ps at
the slow 85C corner is within the model's own noise and the board has run with
this interface unconstrained throughout, so the `.rbf` is flashable — but it is not
clean and is not recorded as if it were. It will also get worse as M2 and M3 grow
the design, which is when this becomes a requirement rather than a note.

## The window fix WORKS on hardware, and the blue flash is a different fault
## — 2026-08-18

Read off the board's own overlay, from a 30 fps video, comparing a picture frame
against a blank one in the same second.

**The fix is confirmed on hardware.** Row `13`, tilemap 2's visible pixels, reads
`02E800` = **190,464 — the entire screen** — where it read `000000` before, and the
sky and sea in those frames are real tilemap 2 content rather than a flat fill. Row
`11` reads `000005`, and 190,459 + 5 = 190,464 exactly, so there is no backdrop at
all. That defect is closed.

### The blue flash is periodic, and it is the game clearing the screen

Measured from the video by texture in the picture region only — a blue-pixel count
cannot see it, because the correct picture is *also* blue:

```
blank runs (video frames): (12,14) (26,28) (39,42) (53,55) (66,69) (80,82) ...
112 blank frames of 460, period ~13.5 frames at 30 fps
```

**0.45 s period, ~24% duty, about 7 core frames at a time.** The user timed it at
"every 1/2 second" before any of this was measured, and also pointed out that 30 fps
cannot resolve it cleanly — both correct, and the second is why earlier metrics on
the same video found nothing.

| overlay row | picture frame | blank frame |
|---|---|---|
| `16` pair 2/3 ctrl | `002000` | **`000000`** |
| `1A` map2, map3 content | `FFFFFF` | **`000FFF`** |
| `11`-`14` wins | `5, 0, 190459, 0` | **all zero** |
| `19` map0, map1 content | `008000` | `000000` |
| `1B` writes | `003 00C` | `000 008` |

**Window mode is OFF during the blank**, so the window logic is not involved. Map 2
reads empty, its category-0 pass is opaque, so it paints palette 0 over the whole
screen and hides map 3 — which still holds `FFF`. That is the blue.

Rows `19` and `16` change **in the same frame**, which the user established by
watching them: the game writes `ctrl` and the tile content as one operation, so the
screen is torn down and rebuilt each cycle rather than one register drifting.

### Three things this rules out

1. **The write path is innocent.** Row `1B` matches simulation exactly on both
   frames — `003 00C` against `wr=3,0,12,0`, and `000 008` against `wr=0,0,24,0`.
   Read-during-write is now dead on evidence rather than on the arithmetic argument
   used earlier, and the CPU writes maps 0/1 on hardware just as it does in sim.
2. **The V60 is not being reset.** Row `01`, instruction fetches, is monotonic
   across the blanks: `7A7D..` -> `7D4DE6` -> `88638.`. It fetches straight through.
3. **Simulation does not reproduce it.** Its 336 `ctrl=0000,0000` frames are ONE
   contiguous run at frames 1-336 — boot — and it never returns. The board goes back
   there every 0.45 s indefinitely.

### So maps 0/1 are empty because the game never finishes drawing them

Only **8** non-blank words reach map 0 before the next teardown, against
simulation's 552-2,520 at the same `ctrl` state. The missing text is not a memory
fault and not a compositing fault: the game is being restarted before it draws.

**Cause unknown, and this is a CPU-side question now.** The overlay's PC row cannot
help — it samples at the same point every frame and reads `FFE59C` blank or not.
What is needed is the PC **at the instant of the teardown**, latched on the `ctrl`
`0x2000 -> 0x0000` transition, with a counter. That names the code and makes it
traceable in the ROM. Candidates not yet tested: a self-test or synchronisation wait
timing out, and the published DPRAM bytes — the DSWs at `0x0b`-`0x0d` and the
`0x03`-`0x07` block whose contents are recorded as unknown — since simulation feeds
fixed inputs and the board reads real ones.

## Modes 2/3 verified on real game code — 2026-08-18

`make m1_frame FRAME_TRACE=1 FRAME_CYCLES=3400000000`, the full 2,478-frame run,
before and after the column split. Same frame, everything else identical:

```
before   F1936 bd=0/190464 win=0,0,190464,0    ctrl=4000,2000
after    F1936 bd=0/190464 win=2972,0,187492,0 ctrl=4000,2000
```

**Tilemap 0 wins 2,972 pixels where it won none.** That is the text pair drawing on
the frames that previously blanked it.

Across the whole run:

| | before | after |
|---|---|---|
| blue frames (`bd` > 100k) | 7 | **7** |
| mode-1 frame `F1900` wins | `11038,4648,174778,0` | **identical** |
| tilemap 0 pixels, total | 46,641,138 | **47,250,016** |

The 7 blue frames are the legitimate boot screen-clear in both, so nothing
regressed. The mode-1 frames are byte-identical, which is the point: `win_vsplit`
gates the two paths apart and mode 1 was already correct. The extra 608,878 pixels
divided by 2,972 a frame is ~205 frames, against the 194 mode-2 frames measured —
consistent.

**Note what this does NOT fix.** The 0.45 s teardown is untouched: the game still
restarts its screen build, so on hardware the text will draw on more frames but the
underlying restart remains. Modes 2/3 was a real defect worth closing on its own;
it is not the open one.

## THE COPROCESSOR'S DATA ROM WAS NEVER IN THE MRA — 2026-08-18

The board's 0.45 s screen teardown, traced to its cause. The instrument that found
it was overlay row `03`, added the night before precisely because nothing measured
this.

### What the board said

```
02  800 B9A     microcode: 2048 words, checksum B9A
03  FFF 000     command FIFO: pushes saturated, pops ZERO
10  000049      TGP program counter, stuck at 0x49 across two videos minutes apart
```

Row `02` **kills the microcode theory outright**: `0x800` is a complete 2,048-word
load, and `B9A` is exactly the folded checksum computed from `315-5573.bin`
independently — so the microcode is complete AND correct. The zip diagnosis of the
previous night was wrong, as the user suspected when asking why a missing file
produced no error.

Row `03` is the fault: **the V60 pushes commands and the TGP never pops one.** The
FIFO is 16 deep and **a full FIFO halts the V60** — so the CPU stalls, the game
gives up on its screen build and restarts it. That is the teardown.

### Why the TGP was stuck

`make m1_tgp`, on this same microcode, reaches `pc=0043`, blocks correctly on an
empty FIFO, and **pops 11 of 11** when commands are offered. The pop logic works.
The board sits six instructions further at `0x49`, because its FIFO is *not* empty
— it got past the read and stopped at the next thing.

That next thing is the data ROM. MAME's `copro_io_map` puts the math units at
`0x0020-0x002b` and the data-ROM window at `map(0x8000, 0xffff).r(copro_data_r)`,
and `findings.md` already recorded — measured through MAME's own IO tap — that the
data ROM is **read before any math unit**.

### The three regions, and which we loaded

`vr` needs, beyond the microcode:

| MAME region | size | files | in our MRA |
|---|---|---|---|
| `copro_data` | 2 MB | `mpr-14898.39` .. `mpr-14901.42` | **NO** |
| `copro_tables` | 256 KB | `opr14742.bin`, `opr14743.bin` | **NO** |
| `other_data` | 512 KB | `opr-14744.58` .. `opr-14747.63` | n/a — computed in `fp_div`, no port, not in the ROM set |

All six of the first two are present in the user's `vr.zip`. Neither region was in
the MRA.

### The part that makes this unambiguous

**`tools/build_rom_image.py` — which feeds SIMULATION — has placed both regions
correctly all along**, `copro_data` at byte `0x600000` and `copro_tables` at
`0x800000`, matching `COPRO_DAT_BASE` and `COPRO_TBL_BASE` in `m1_integrated.sv`
exactly. Its own comment says the layout was chosen so that *"the MRA needs no
padding"*.

So the layout was designed for the MRA to carry these, and **the MRA was never
updated**. Simulation had the data ROM; hardware never did. That is the whole
board-versus-simulation divergence chased across two sessions:

- sim: microcode + data ROM + tables -> TGP runs -> no teardown, 0 blue frames
- board: microcode only -> TGP stalls at 0x49 -> FIFO fills -> V60 halts -> teardown

### The fix, and what it is not

Six parts appended to the MRA's index-0 stream at `0x600000` and `0x800000`, with
the same interleaves the image builder uses — four-way byte interleave for
`copro_data`, two-way 16-bit for `copro_tables`. **No RTL change and no rebuild:
the MRA is a data file on the SD card**, so this was deployed and reloaded in
minutes.

**A lesson worth more than the fix.** Two independent loaders existed for the same
data — `build_rom_image.py` for simulation and the MRA for hardware — and only one
knew about two of the three regions. Nothing checked them against each other, and
the difference presented as a hardware bug for two sessions. The overlay row that
finally caught it exists only because the user asked why a missing ROM file would
not produce an error.

## The coprocessor stall REPRODUCES IN SIMULATION — 2026-08-18

The data ROM was necessary and **not sufficient**. With `copro_data` and
`copro_tables` both present, `make m1_frame FRAME_TRACE=1` settles from frame 85
onwards at:

```
F95 ... tgp=1/0/0049 io=0000/000 tbl=00 dat=00 ... pc=fe02bc
        ^^^^^^^^^^^^ pushes=1, pops=0, TGP pc = 0x0049
```

**`0x0049` is exactly the PC the board reports**, in two videos minutes apart. So
the stall is not a hardware effect at all and no board is needed to work on it.

**And it is not waiting on memory.** `io=0000/000` is the coprocessor's IO port
idle with no read, write or ack; `tbl=00 dat=00` are the table and data-ROM ports
with no request outstanding. It sits at `0x49` with a command queued in the input
FIFO and simply does not take it.

That matters because it eliminates the whole class of explanation the data ROM
belonged to. The remaining possibilities are narrow:

- the TGP never asserts its FIFO read at `0x49` — it is doing something else
- it asserts it and the handshake fails

`m1_copro_if` drives `fifo_in_valid = !fin_empty` and the TGP pops on
`fifo_rd && fifo_in_valid`, so with one word queued `valid` must be high. And
`m1_tgp`'s own suite pops **11 of 11** when its valid is driven. Both halves work
in isolation, which points at what the microcode is actually executing at `0x49`
rather than at the plumbing.

**Note the push counts differ between board and simulation**: the board's
saturates (`FFF`, and `010` = the full 16-deep FIFO once the CPU halted), while
simulation pushes **once** and stops. Same stall, different amount of work offered
before the CPU gives up. Not yet explained.

### What this says about the earlier fix

Loading `copro_data` was still right — `tb_m1_frame`'s own header records that
stopping at the V60 image "leaves the TGP reading 0xFFFF and the V60 stalls" — but
it was not the cause of the teardown. The teardown is this stall, and it was
present in simulation the whole time behind a push count too low to fill the FIFO.

**M0 exit criterion 2 is the relevant gap.** `mb86233_core`'s baseline says
"microcode-driven lockstep still owed": every opcode is fuzz-verified against MAME
individually, and the core has **never been run in lockstep on real microcode**.
A single wrong opcode on the path through `0x49` would produce exactly this and
would be invisible to every test that currently passes.

## WITHDRAWN: "the TGP never drains its command FIFO" — 2026-08-18

Stated this morning as the diagnosis, from overlay row `03` reading `FFF 000`. It
is wrong, and the counter is why.

**`dbg_fifo_pops` counts the V60 reading RESULTS out of the OUTPUT FIFO**, not the
TGP taking commands from the input one. It increments on `!we && sel_fifo && !a1`,
advancing `fout_rd`. The TGP's own consumption is
`if (fifo_in_pop && !fin_empty) fin_rd <= fin_rd + 1'd1` and **was not counted at
all**.

The row was built on a wrong assumption about what the signal meant, and then its
expected value was read as a fault.

**But "a zero there is correct behaviour" — which this entry originally concluded,
citing *"does the V60 read the coprocessor back — never, in 2,500 accesses"* — is
ITSELF WRONG, and that is corrected further down: the V60 reads the coprocessor
back constantly, through its I/O space. A zero in `dbg_fifo_pops` is a real gap.**
Two wrong readings of the same counter, in opposite directions, from two different
mistakes.

**The trace shows the opposite of the claim.** With the FIFO read strobe added:

```
F35  tgp=0/0/0043  frd=1   FIFO empty   correctly blocked on an empty FIFO
F37  tgp=1/0/0049  frd=1   pushes=1     PC MOVED 0x43 -> 0x49
```

The TGP asserted its read, took the command, advanced, and is now blocked at `0x49`
waiting for the next one — which is exactly right when only one command has been
sent. Nothing is stuck.

So the "full FIFO halts the V60" chain is unsupported. `FFF` is a saturating count
of total pushes, not FIFO occupancy, and it does not mean full.

**What still holds** from that episode: `010` — sixteen pushes, the exact FIFO
depth — read after the microcode was accidentally dropped. With no program the TGP
genuinely never drains, the FIFO genuinely fills, and the V60 genuinely halts. That
reading was real; the one before it was not.

**Fixed**: `dbg_fifo_drains` now counts `fifo_in_pop`, and overlay row `03`'s right
field shows it instead. Needs a rebuild to reach the board.

**The lesson is the same one twice in a day.** A counter was trusted for what its
name suggested rather than for what it increments on, and a whole diagnosis was
built on it. The previous instance was `dbg_layer_have` measuring reads while being
read as content. Check the increment condition, not the identifier.

## WITHDRAWN: the copro data ROM fixed the teardown — 2026-08-18

It did not. Claimed after the MRA fix on a video analysis that was wrong twice
over: the crop offset was changed for a differently framed video and ran off the
right edge of the picture, and the blank test required texture to be exactly zero
when blank frames read 1-2 from camera noise. It reported "0 blank frames in 466".
The user said the flashing was still there every half second, and it is:

```
low-texture runs: (2,4) (16,18) (29,31) (43,45) (57,59) (70,72) (84,86) ...
102 of 466 frames, period ~14 at 30 fps
```

Same 0.45 s period, same ~22% duty, unchanged by the data ROM.

**Two crop mistakes in one day on the same instrument.** The rule that came out of
the first one — measure texture in the picture region, not blueness, because the
correct picture is also blue — is right, but a fixed crop is not portable between
videos shot at different distances. Derive the picture region from the frame, or
check the crop lands on the picture before trusting the result.

### What the data ROM fix DID buy, measured

The coprocessor is now provably healthy, which it was not before:

| overlay | before | now |
|---|---|---|
| `02` microcode | `800 B9A` | `800 B9A` complete and correct |
| `03` pushes / **drains** | `FFF 000` (mislabelled) | **`FFF FFF`** — thousands of commands taken |
| `0F` retires | `FFFF` pinned | `0058D7` -> `00FEBD` over 5 s, churning |

And all three hold **during the blank frames too**. So the coprocessor executes
continuously and consumes work throughout the teardown, which eliminates it as a
cause rather than leaving it a suspect. That is worth the fix on its own, and the
microcode-dropped experiment separately proved the TGP does halt the V60 without a
program — that reading was real.

### The teardown's signature, unchanged

```
picture   16=002000  1A=FFFFFF  13=02E7FB  11=000005
blank     16=000000  1A=000FFF  13=000000  all wins zero
```

During the blank, pair 2/3's `ctrl` reads 0 and **tilemap 2's content census reads
000 while tilemap 3 still reads FFF**. Map 2 is words `0x2000-0x2fff` and map 3
`0x3000-0x3fff`, so whatever happens is confined to one 4,096-word map.

**And row `1B` reads `000` tilemap writes on every frame sampled**, blank or not,
which does not sit with map 2's content changing. Either the writes come in a
burst no sampled frame caught, or the content is not changing and the FETCH is
reading somewhere else. That contradiction is the next thing to resolve, and it is
resolvable in simulation — the blank state reproduces there (`ctrl=0000,0000`,
`have=0,0,0,0`, `bd=190080`) at frames 328-332.

## The blue detector in simulation was wrong, and the board never leaves boot
## — 2026-08-18

### The detector

Blue frames were counted in simulation as `bd > 100000` — backdrop share. That is
the wrong test and this file already said why: **the full-screen blue is tilemap 2
drawn opaque over an empty map, and `bd` reads 0 while it happens.** The mechanism
was written down and then the wrong counter was used to look for it anyway.

The correct test is layer 2 covering the screen while its content census is empty:

| test | blue frames of 407 |
|---|---|
| `bd > 100000` | 7 |
| `win[2] > 150000 && rtl_have[2] == 0` | **289** |

So "simulation shows no blue" was false. It is blue for most of boot.

### What the correct test shows

```
frames 1-39     not drawing yet
frames 40-328   BLUE, 289 frames contiguous
frames 329+     picture, and it never returns
```

Over the full 2,478-frame run: **289 blue, 2,189 picture**, the blue one contiguous
block during boot. The board oscillates between the same two states every 0.45 s,
indefinitely.

### And the PC separates them

| | sim, blue | sim, picture | board |
|---|---|---|---|
| `pc` | `ffe59c` | `fe02bc` | **`ffe59c` always** |

`0xffexxx` is the boot ROM; `0xfe02bc` is game code. **The board's V60 never leaves
the boot state that simulation passes through in about five seconds.** It keeps
re-running boot's screen build, which is why tilemaps 0/1 never accumulate the text
and why the blue returns on a cycle.

That reframes every symptom chased today. The missing text, the missing scrolling
and the periodic blue are one thing: the machine is stuck in boot. The video path,
the window modes, the memory and the coprocessor are all doing what they are told.

**What is NOT the reason**, all measured today:

- the coprocessor — microcode complete and correct, executing continuously,
  draining thousands of commands, *including during the blank frames*
- the copro data ROM and tables — now loaded, verified byte for byte
- the command FIFO — drains saturated, so it is not full and not halting the CPU
- the memory write path — row `1B` matches simulation exactly
- a V60 reset — instruction fetches are monotonic across the blanks
- input divergence — board idle values identical to the testbench's

**The open question** is what boot waits on that the board does not get, given the
I/O board is replying (`0B` climbs) and memory and the coprocessor both work. The
PC row samples at the same point every frame so `ffe59c` is a frame-synchronised
wait, not necessarily a hang — the useful next instrument is a PC histogram or a
capture of the PC at the moment the screen tears down, which the frame-synchronised
sample cannot give.

## The SDRAM read phase is settled: CL+2, and the others fail hard — 2026-08-18

Swept from the OSD, `O[5:4]`, all four settings. **CL+3, CL+4 and CL+5 all hang on
the test screen.** Only CL+2 boots.

That is a useful negative. A marginal capture phase would show as occasional wrong
data — rare bad fetches, wrong branches, the sort of thing that could explain the
board diverging from simulation on identical code. This is not that: a wrong phase
reads a *different word entirely*, the machine fails its own self-test, and the
failure is immediate and total rather than intermittent.

So the setting is right, its margin is not the question, and the periodic teardown
is not a memory-timing effect. Do not sweep it again.

Cost: one menu click, no build. It should have been run hours earlier — it was
recorded as an available free experiment in `HANDOFF.md` and repeatedly deferred in
favour of instrument builds.

### Turning a V60 address from the overlay into ROM contents

`tools/rom_at.py` takes an **SDRAM word address**, not a V60 address, and rejects
a V60 one as "past the end of the image" — which reads like the address is wrong
rather than in the wrong units. The map is `m1_decode.sv`'s packed layout:

| V60 | stream | word address |
|---|---|---|
| `0x200000-0x2fffff` ROMX | `0x000000` | `(0x000000 + (a - 0x200000)) >> 1` |
| `0xf80000-0xffffff` ROM0 | `0x100000` | `(0x100000 + (a - 0xf80000)) >> 1` |
| `0x100000-0x1fffff` banked | `0x180000 + bank*0x100000` | `(that + (a - 0x100000)) >> 1` |

So the PC the board reports on row `00`:

```
V60 0xffe59c -> word 0xbf2ce -> 885a 8975 8976 ea6a f4e4 0200 0070 e0e2
```

Real code in the boot ROM, and simulation sits at the same address during its own
boot phase — so the address is not itself suspicious. What differs is that
simulation leaves and the board does not.

## WITHDRAWN: "the board never leaves boot" — ROM0 is where the game LIVES
## — 2026-08-18

MAME, tapped on the V60's program space and bucketed by region, 30 s of attract:

```
f=1800 total=240,967,154  rom0=89.7%  romx=0.3%  bank=0.3%  other=9.6%
```

**The real machine spends ~90% of its time in ROM0.** `0xf80000-0xffffff` holds
`epr-14878a.4` and `epr-14879a.5` — the main program — not merely a boot vector.
So a PC of `0xffe59c` says nothing about being stuck.

And the comparison it rested on was worse than unsupported. Simulation's two states
were read as "`ffe59c` = boot ROM" against "`fe02bc` = game code" — **both are
inside ROM0**. Two addresses in the same ROM, presented as two different phases of
execution. There was never a boot-versus-game distinction in that data.

### What that does to the instrument just built

Rows `06`/`07` count cycles in ROM0 against everything else, on the reading that
"mostly ROM0" would mean a boot loop. That interpretation is dead. The rows are
still worth having, but only **against this reference**: the real machine is
`89.7 / 10.3`, so a board reading near that is behaving normally and one reading
`99.9 / 0.1` is genuinely pinned. Without the oracle number the rows would have
been read as damning whatever they said.

Row `04` — the PC latched at the teardown edge — is unaffected and remains the
useful one, because it names a specific instant rather than a distribution.

### The rule this keeps proving

`CLAUDE.md` says: when something is unknown, run MAME, do not reason about it. Four
wrong causes today — the M10K crossing, the FIFO halt, the copro data ROM, and now
this — every one reasoned from a plausible mechanism, and this one was refuted by a
five-minute Lua script that could have been written at any point. The instrument
was available the whole time.

## The board's PC distribution is CORRECT — and row 04 cannot do its job
## — 2026-08-18

Board readings from the instrument build:

```
04  FFE46d, last three digits constantly changing
05  001FAB, rising            ~8,100 teardowns, ~3/s over 43 minutes
06  unreadable, churning fast
07  000000, always
```

### 07 = 0 is right, not a fault

The first reading of `07 = 000000` — zero cycles outside ROM0 — looked like a hard
divergence from the MAME reference of 10.3%. It is not, and the reference was
measuring something else: that tap counted **all program-space accesses**, data
reads included, while rows `06`/`07` count **the PC**. Measured properly, sampling
MAME's PC alone:

```
samples=3600  rom0=3600  other=0   0.00% outside ROM0
```

**The real machine's PC is 100% in ROM0 too.** The board matches the oracle
exactly. That would have been the fifth wrong cause of the day, and the only thing
that stopped it was checking that the two instruments measured the same quantity
before comparing them.

### Row 04 captures the wrong event

It latches the PC when `dbg_ctrl[1]` changes — and `dbg_ctrl[1]` is latched by the
**video renderer** when it reads tile RAM, once per layer per scanline. The CPU may
have written `ctrl` up to a frame earlier. So the captured PC is wherever the CPU
happens to be when the *renderer notices*, which is why it scatters across
`FFE4xx` rather than naming one instruction.

A design error, not a wiring one: the event is in the video domain and the question
is about the CPU domain. The instrument that answers it watches the CPU's own write
to tile RAM word `0x5006` — pair 2/3's `ctrl`, which is also tilemap 2's `vscr` —
and latches the PC there.

**Row 05 is sound** and worth keeping: ~8,100 teardowns at about 3 per second over
43 minutes, which matches the observed flash rate and confirms the event is real
and periodic rather than drifting.

## The teardown is the GAME toggling ctrl, and the code is named — 2026-08-18

Traced in simulation by watching the CPU's own writes to tile RAM word `0x5006`,
which is pair 2/3's `ctrl` and tilemap 2's `vscr`:

```
pc=ffe27a   145 writes
pc=ffe466   144 writes
data:  287 x 0x0000,  4 x 0x2000
```

**Two routines alternate it**, and the board's row `04` — the PC latched at the
teardown — read `FFE46d` churning in the low digits. `ffe466` is one of the two
writers, so that capture was pointing at the right code despite being latched on
the video-side observation. The earlier note calling it noise was too pessimistic;
the delay is evidently small enough that the PC is still inside the routine.

**So the teardown is not a fault.** The game deliberately toggles window mode off
and on, clearing and refilling tilemap 2 in step with it. Roughly 3 times a second,
which is the observed flash rate.

### Which makes the real question much narrower

**When `ctrl = 0x0000` and tilemap 2 is empty, why do we paint the screen blue
when MAME does not?**

With window mode off, `draw_common` takes the normal path and all four tilemaps
draw. Maps 2 and 3 draw their category-0 pass **opaque** — recorded here already —
so an empty map 2 covers all 190,464 pixels in palette 0, which is blue. MAME
plainly does not do that, so something suppresses map 2 there that we do not
reproduce. Candidates, in the order the source suggests:

1. **the row mask** — the normal path applies it and the window path does not, so
   this is the first place a difference of exactly this shape would live
2. **`vscr` bit 15, layer disable** — `draw_common` returns before drawing, and
   this design's mixer treats maps 2/3 as opaque *unconditionally*, so a disabled
   map still paints. Recorded as a suspected bug in `tb_m1_video.cpp` and
   deliberately not folded into the window change
3. a priority rule in the category-0 pass

Candidate 2 is already written down as suspected and never chased. It would produce
exactly this symptom.

**This is a compositing question with a definite oracle answer**, which is a much
better position than any of the four causes named and withdrawn today. The next
step is a MAME tap on `tile_ram[0x5006]` and the row-mask words at the moment `ctrl`
goes to zero, to see what the reference has set that we ignore.

## The reference sets window mode ONCE; the board toggles it forever — 2026-08-18

MAME, polling `tile_ram[0x5006]` every frame for 2,400 frames of attract:

```
f=600   ctrl==0 on 273 frames, window mode on 327
f=1200  ctrl==0 on 273 frames, window mode on 927
f=1800  ctrl==0 on 273 frames, window mode on 1527
f=2400  ctrl==0 on 273 frames, window mode on 2127
```

**`n_zero` stops at 273 and never rises again.** Every `ctrl == 0` frame is inside
the first ~300; from then on the reference holds window mode on permanently. It
does not toggle.

The board toggles it about three times a second, indefinitely, via the two routines
at `ffe27a` and `ffe466`. Simulation converges the same way MAME does — the long
runs settle at `ctrl=0000,2000` for 1,898 frames of 2,478.

### So the compositing question was the wrong question

The previous entry narrowed this to "when `ctrl=0` and tilemap 2 is empty, why do we
paint blue when MAME does not", and listed the row mask, `vscr` bit 15 and priority
as candidates. **All beside the point.** The reference is never in that state after
boot, so there is nothing to compare against and nothing in the mixer to fix. Our
renderer is faithfully drawing a state the game should have left.

Note `vscr` bit 15 was already ruled out by arithmetic and this makes it moot:
`ctrl` **is** tilemap 2's `vscr`, so a `ctrl` reading of `0x0000` means bit 15 is
clear and the layer is enabled by definition.

### What is actually left

**Why does the board keep re-entering the `ctrl = 0` path when MAME and simulation
both leave it after boot?** Hardware only — neither oracle reproduces it. Everything
downstream of that is a symptom: the periodic blue, the missing text and the absent
scrolling all follow from the game repeatedly restarting its screen build.

What is already excluded by measurement, and should not be re-derived: the
coprocessor (healthy, draining, executing during the blanks), its microcode and
data ROM (complete, correct, verified byte for byte), the command FIFO, the SDRAM
read phase (CL+2 is right, the others fail hard), the memory write path, a V60
reset, the PC distribution (100% ROM0, matching the oracle), and input divergence.

## Quartus is deterministic; the SDRAM interface is placement-SENSITIVE
## — 2026-08-18

The UART build broke the picture completely — green and pink swirls, the raster
shifted right — from a change that cannot touch the video path: a debug counter
that drives only debug outputs, and a transmitter emitting ~40 bytes a second.
Static checks were clean: `+0.296 ns` worst slack, no violation, and **no new
warning classes** against the previous build.

Reverting those three files and rebuilding produced a bitstream **bit-identical**
to the last known-good one, `55965cd8d77b2a6443b9d141dea568f8`.

**So builds ARE reproducible.** "Placement roulette" and "no two builds are
behaviourally equivalent", said earlier in this session, are wrong: identical source
gives identical bits. The accurate statement is narrower and still serious —
**an unrelated edit shifts placement enough to break the SDRAM interface**, which is
deterministic but fragile.

### Why, and it is not only the missing constraints

```
Model1.sv:397   assign SDRAM_CLK = ~clk_sys;
```

The memory's clock is **combinational fabric logic driving an output pin**. Its
delay to the pin is a routing result, so the edge arriving at the device moves with
placement relative to the data pins. That is why `RD_LAT` had to be found
empirically on hardware rather than derived, and why an unrelated edit can shift the
sampling point past the margin.

Neither the framework's `sys_top.sdc` nor our generated `Model1.sdc` contains a
single SDRAM constraint — no `create_generated_clock` on the port, no
`set_output_delay`, no `set_input_delay`. The fitter has never been told those paths
matter or been able to report them as bad.

### What the broken build's overlay showed, which is worth keeping

The corruption was informative rather than just noise:

```
row 11  001740   tilemap 0 wins 5,952 pixels   (had been 000005)
row 13  02D0C0   tilemap 2 wins 184,512
row 16  002000   window mode on
row 04  FFE29D   teardown PC — ffe27a, one of the two writers simulation named
```

**The overlay was legible while the picture was garbage.** The overlay renders from
on-chip data; the picture reads character RAM from SDRAM. Clean on-chip graphics
with corrupt SDRAM-sourced graphics is the signature of the read path, not the
renderer.

And **tilemap 0 won 5,952 pixels against 5 before** — the text is being drawn now.
The coprocessor data ROM fix moved the game forward; it was hidden behind a broken
picture. Row `04` also proved itself: `FFE29D` is `ffe27a`, so the entry calling
that instrument "noise" is withdrawn a second time.

Sweeping the SDRAM read phase through all four settings changed nothing on the
broken build, so the fault is not the capture phase alone.

### The fix, in order

1. **Generate `SDRAM_CLK` through a DDIO output register** clocked by `clk_sys`, so
   its phase is fixed by construction instead of by routing. Standard MiSTer
   practice and the part constraints alone cannot fix.
2. **Constrain the interface**: `create_generated_clock` on the port, plus
   `set_output_delay`/`set_input_delay` from the device's setup, hold and access
   times.
3. **Verify by rebuilding twice from identical source and comparing the reported
   SDRAM slack**, because the failure mode is sensitivity to unrelated edits, not a
   single bad number.

None of this is checkable by `make test` — it is a hardware-only change, verified by
builds and by the screen. It changes an interface that currently works at CL+2, so
the empirically-found phase may need re-finding, and the known-good bitstream above
is the reference to fall back to.

## PARTLY WITHDRAWN: the SDRAM violation is the READ CAPTURE, not the outputs
## — 2026-08-18

The first build ever to constrain this interface. `create_generated_clock` on
`SDRAM_CLK` with `-invert`, plus output and input delays from the device's tSU/tHD
and tAC/tOH:

```
clk_sys     -7.192 ns   TNS -112.637
sdram_clk   -0.150 ns   TNS   -0.221
```

**Failing by seven nanoseconds, and it always was.** Nothing constrained these
paths, so nothing analysed them and nothing could report them.

### The arithmetic is exact, which is what makes it certain

`Model1.sv:397` is `assign SDRAM_CLK = ~clk_sys` — the device is clocked on the
**falling** edge, so data launched on the rising edge has **half a period, 6.25 ns**,
to reach the pin. The worst path was measured earlier today at **12.899 ns** across
9 logic levels, `xfer_addr[2] -> sd_a[12]`:

```
6.25 - 12.9  =  -6.6 ns      against the -7.192 reported
```

That agreement rules out a bad constraint as the explanation. The path genuinely
takes about twice the time available.

### So this is structural, not marginal

The interface has never had timing margin. It works because the real SDRAM
tolerates whatever arrives, and `RD_LAT` was tuned by hand until the result was
readable. That single fact explains a list of symptoms recorded separately over
weeks as if they were unrelated:

- `RD_LAT` derived term by term and still needing an empirical fix on hardware
- CL+2 being the only capture phase that boots, with the other three hanging
- a build whose only change was a debug counter and a UART producing a garbage
  picture — placement moved a path that had no margin to move
- none of it visible to `make test`, `make lint`, or any static check, because the
  paths were unconstrained and the failure is at the pins

### What the fix has to be

Not tuning, and not constraints on their own — constraints only made it visible.

1. **Register the SDRAM outputs in the I/O cells.** Clock-to-output from an I/O
   register is a fixed, short, placement-independent number. `sd_a[12]` already sits
   in a `DDIOOUTCELL`, so the endpoint is right; what is wrong is the ~13 ns of
   combinational logic arriving at it.
2. **Cut the depth feeding `sd_a`** — `sel~1`, `sel~5`, `Mux118~0`, `always3~1/2`,
   `sd_ba~1`, `sd_a[0]~3/4`. The state machine computes its address mux in the same
   cycle it drives the pins. Registering the address select one cycle earlier
   removes most of them, which is the fix already identified when that path was
   first read.
3. **Then** re-check both numbers, and rebuild twice from identical source to
   confirm they are stable.

`make test` cannot see any of this. Verification is the timing report plus the
screen, with `55965cd8d77b2a6443b9d141dea568f8` as the known-good fallback.

### A tooling hazard found on the way

Regenerating the project over a completed build's database made Quartus 17.0 die
inside `quartus_map` with a stack trace in `write_removed_registers_report` and
`node_id != 0`. It reads like a source fault and is not one. `rm -rf build/mister/db
build/mister/incremental_db` before recompiling after `tools/mister_project.sh`.

### Correction, same day: the -7.192 ns is a different path entirely

The entry above attributes the violation to the output path and its 12.9 ns of
combinational depth. **The report does not say that.** Read properly:

```
From:  SDRAM_DQ[0]            (input pin)
To:    m1_sdram:sdram|dq_r[0] (capture register)
Slack: -7.192 (VIOLATED)
Data Delay: 2.445 ns    Number of Logic Levels: 1
```

It is the **read capture**, and the data path is *fast* — 2.4 ns through one level.
There is no logic to cut. The 12.9 ns output path was measured on the PREVIOUS,
unconstrained build and had about -0.02 ns slack: marginal, worth fixing, and
nothing like -7 ns. Two different paths from two different builds were merged into
one conclusion, and the arithmetic that "confirmed" it — 6.25 - 12.9 = -6.6 against
-7.192 — was a coincidence between unrelated numbers.

### What the violation actually is

`SDRAM_CLK = ~clk_sys`, so the device launches read data on the **falling** edge and
`dq_r` captures it on the next **rising** edge. That is half a period, 6.25 ns, for
tAC plus the clock's round trip to the device and the data's return. A clocking
margin problem, not a depth problem, and no amount of pipelining inside the
controller changes it.

### And the verdict currently rests on a guessed number

`tAC` was set to **6.0 ns**, described in the constraint file as "deliberately
pessimistic". Against a 6.25 ns window that fails almost by construction. A real
-6 grade part is nearer 5.4 ns, which would be tight but might close.

**So this build does not prove the interface is broken.** It proves the interface has
almost no read margin by construction, and that the exact verdict depends on a
device number nobody has looked up. The next step is the actual part on the MiSTer
SDRAM board and its datasheet tAC/tOH — not another RTL change, and not another
build on a guess.

If the real numbers still fail, the fix is a **phase-shifted PLL output for
SDRAM_CLK** rather than `~clk_sys`, which is what gives a tunable, defined capture
window and is what other MiSTer cores do. Cutting logic depth would not have helped,
and the plan in the entry above — register the outputs, cut the depth feeding sd_a —
addresses a real but much smaller problem.

## Constraining the SDRAM: what was learned, and why it is opt-in — 2026-08-18

Three builds, ~75 minutes, and the honest outcome is a smaller result than the
attempt.

### The one number worth keeping

With **only the output side constrained** the build completes and reports:

```
sdram_clk   -0.150 ns   TNS -0.221
```

Our commands and addresses reaching the memory are marginally late. Small, real,
and on a path the framework is already trying to improve — `Template.qsf` asks for
`Fast Output Register=ON` on `SDRAM_*`, and ours are **refused**:

```
Warning (176279): Can't pack register node "sd_a[8]" into I/O pin "SDRAM_A[8]".
  The node cannot simultaneously use clear and load signals.   m1_sdram.sv:449
```

`sd_a` is reset to `'0` in an `always_ff @(posedge clk or negedge rst_n)` **and**
conditionally loaded, and a Cyclone V I/O register does one or the other. So the
output registers sit in the fabric paying routing delay to the pin, when the
intended design puts them in the I/O cell.

**That is a real, bounded fix**: split the pin registers into their own `always_ff`
without an async reset. Not attempted here — it changes a controller with a
74,729-check suite at the end of a long session, and it needs its own build and
board test.

### The read path could not be modelled, and the tool crashed trying

`SDRAM_DQ -> dq_r` reports **-7.192 ns** on a path with 2.4 ns of delay and one
logic level. That is a mis-model, not a failure: `dq_r` registers the pin every
cycle and a tag pipeline selects which sample to use, at a depth chosen CL+2..CL+5
from the OSD. **That selectable depth is the read phase.** The data is allowed to
arrive later by design.

The correct expression is a multicycle, and **Quartus 17.0's FITTER SEGFAULTS on
one** — `Fatal Error: Segment Violation`, twice, in both the
`-from <ports> -to <registers>` form and the conventional clock-to-clock form.
Twenty-five minutes per attempt to discover.

### So the constraints are OPT-IN and default OFF

`export MODEL1_SDRAM_SDC=1`. Default builds emit the text but skip it, so they stay
identical to the known-good bitstream.

Leaving them on by default would put a **-7.192 ns known false alarm** at the top of
every timing report, which would bury a genuine regression. A report nobody can
trust is worse than no report.

### What this did NOT establish

Two claims made earlier today and withdrawn: that the output paths "need 12.9 ns and
have 6.25 ns", and that the interface is "failing by seven nanoseconds and always
was". Neither survives reading the report properly. What survives is narrower:

- the output side is marginally late, `-0.150 ns`, with a known and specific cause
- the read side has never been analysed at all and still is not
- `SDRAM_CLK = ~clk_sys` gives the read half a period, which is genuinely little
  margin, but whether it fails is still unmeasured

**Next, in order**: the `sd_a` reset split so the outputs can pack into I/O cells
(bounded, testable, one build); then the read path on Quartus 24.1, which is
installed and may not crash on a multicycle; and only then any thought of a
phase-shifted PLL output for `SDRAM_CLK`.

## m1_sdram's reset cost 0.95 ns of margin and 217 ALM — 2026-08-18

Chasing the I/O packing warning produced no packing and a real improvement anyway.

| | known-good | synchronous reset | + no reset on sd_a/sd_ba/sd_dqm |
|---|---|---|---|
| `clk_sys` slack | +0.296 ns | +0.934 ns | **+1.246 ns** |
| ALM | 29,644 | 29,514 | **29,427** |
| packing warnings | 16 | 16 | 16 |

`m1_sdram` passes **74,729 checks with identical counts** at every step, so the
change is functionally transparent. Flashed as
`3851ff10ac6a4839d01668bb9a0b4330`.

**Why the margin matters more than the packing.** This morning an unrelated edit —
a debug counter and a UART — shifted placement and destroyed the picture on a design
carrying 0.3 ns of headroom. Quadrupling that headroom is the most direct defence
against a repeat, and it came from deleting reset logic rather than from any
cleverness.

### Two theories refuted, both cheaply

1. **A synchronous reset will let the outputs pack into the I/O cells.** No.
   Quartus counts a synchronous clear as a clear, the warning stayed at sixteen.
2. **Removing the reset will.** Also no, and for a reason worth knowing: the init
   sequence assigns `sd_a <= 13'h000` at line 599, which Quartus implements as a
   **synchronous clear** regardless of the reset branch. The register acquires the
   control signal from ordinary code.

So the remaining route is a fitter assignment, `ALLOW_SYNCH_CTRL_USAGE OFF` on
`sd_a[*]`, forcing the clear into the data path. Not attempted: the gain is
speculative, and a tested improvement is worth more than a fourth unverified change
in a row.

**Both refutations were binary** — sixteen warnings or none — which is why they cost
one build each and left nothing to argue about. That is the difference between these
and the four causes named and withdrawn earlier today, every one of which turned on
interpreting a number.

## The blue flash and the missing scroll are ONE bug, and it is in simulation
## — 2026-08-18

MAME, write tap on tile RAM word `0x5006` (pair 2/3's `ctrl`, tilemap 2's `vscr`):

```
ffe27a data=23dd x21    ffe27a data=23ce x292   ffe466 data=23ec x123
ffe27a data=23d1 x9     ffe466 data=2050 x1     ffe466 data=2016 x3
ffe27a data=209d x1     ffe466 data=205e x2     ffe27a data=2064 x2
```

**Every steady-state value is `0x2xxx`**: window mode 1 always on, with the low nine
bits — the vertical scroll — animating. That animation IS the scrolling.

Ours writes only **`0x0000` and `0x2000`**: the mode toggling on and off, the scroll
permanently zero. **Simulation does the same** — 287 writes of `0x0000` and 4 of
`0x2000` in 410 frames — so this is not a hardware fault and needs no board.

### One bug, two symptoms

- the `0x0000` writes are the **blue flash**: window mode off, tilemap 2 drawn
  opaque over an empty map, palette 0
- the scroll field never moving is **nothing scrolling**

Both are the same wrong value written by the same two routines, `ffe27a` and
`ffe466`, which the reference also uses. Same ROM, same code path, different data.

### Ruled out today

- **`c00040`**, polled 36,131 times and read as `0x0001`, looked like a missing I/O
  board value. It is not: **the V60 writes it itself** at `pc=fe03fd`, once a frame.
  Its own scratch flag.
- **the timers at `e0000c`/`e0000e`**, polled 164,185 times and always `0x0000` in
  the reference. Ours match: `m1_glue` only counts when `timer_period != 0`, exactly
  as `timer_r` only computes when `m_timer_period[offset]` is set.
- **the peripheral list generally** — 152 addresses, and nothing yet found that
  answers differently.

### Where the value comes from

The reads immediately before each `ctrl` write are all game state: work RAM
`0x501400`-`0x501424`, `0x501480`-`0x501484`, `0x500500`, and NVRAM `0x40ff5a`-
`0x40ff6e` where a counter steps `e1d9 -> e1dc -> e1df`. So the scroll is computed
from variables, and the divergence is upstream of the write.

**Next**: diff those specific work-RAM locations between simulation and MAME at a
matched point. The addresses are known and the comparison is mechanical, which is a
much better position than the peripheral hunt — and it is entirely local, needing
neither the board nor another bitstream.

## The scroll table at wram 0x501400 is never populated — 2026-08-18

Frame 300, same addresses, reference against our simulation:

```
             wram 0x501400 ...                         0x500500
MAME    0000 0000 0000 0000 0023 2058 ... 4400 0058    0100 0000
SIM     0000 0000 0000 0000 0000 0000 ... 0000 0000    0100 0000
```

`0x50140a` holds the animating `ctrl` value — `2058` at frame 300, `2fce` at 600,
`20a8` at 900 — with a companion at `0x501408`. **The whole table is zero in ours
and populated in the reference**, while `0x500500` matches exactly, so this is one
specific table rather than wholesale corruption.

**Who fills it in the reference**, from a write tap on `0x501408`-`0x50140b` over
600 frames:

```
pc=fe48d5 x163    pc=fef3b5 x164    pc=fe1469 x2
pc=fe6ab0 x2      pc=fe32b7 x1      pc=fe32be x1
```

Two routines, roughly once every four frames. Whether our V60 ever reaches them is
the next measurement, and it splits the problem cleanly: writes with wrong values
means the routines run and their inputs differ; no writes at all means a branch
earlier is taken differently.

### Unproven, and worth checking: the NVRAM window may be shifted 4 bytes

The same dump shows `e1a9 00ff 0000 00fe` at `0x40ff60` in the reference and at
`0x40ff5c` in ours — the same four words, four bytes apart:

```
MAME  40ff5a: 0000 0064 0000 e1a9 00ff 0000 00fe ffbb 1fff ffba
SIM   40ff5a: 0000 e1a9 00ff 0000 00fe 0101 0000 0100 0000 e1e8
```

That is either an addressing offset in our NVRAM mapping or simply different game
state, and the two look identical from one dump. **Flagged, not claimed.** It is
worth resolving because a four-byte offset in a region the game reads for state
would make exactly the kind of routine under investigation compute wrong values.
The test is a wider dump: a mapping error shifts everything, differing state does
not.

### A method note that cost a run

`(cmd > log) &` inside a foreground tool call is killed when the call returns. The
log ends at the first instruction fetches and the job reports success. Use the
harness's own backgrounding, not a shell ampersand.

## Localised: the same instruction computes a different address — 2026-08-18

Our V60 writes wram `0x501408` **only** from `pc=fe1469`, always `data=0000`, and
does it **2,607 times by frame 600**. The reference executes that address exactly
**twice** and fills the table from `fe48d5` and `fef3b5`, which our CPU never
reaches. So we are stuck in a loop around `fe14xx` that the reference passes
through.

Reads taken while the PC is in that region:

```
MAME:  pc=fe14f3  addr=40b906  -> 0100     addr=40ba06 -> 0280
OURS:  pc=fe14f3  addr=400006  -> 0080
```

**The same instruction reads a different address**, and the difference is exactly
`0xb900`. A pointer or index feeding that access is **zero in ours and 0xb900 in the
reference**. Everything downstream follows: different state, `fe48d5`/`fef3b5` never
reached, the scroll table never filled, and `ctrl` written as `0x0000`/`0x2000`
instead of an animating `0x2xxx`.

So the blue flash and the absent scrolling both trace to one wrong pointer.

Ours also walks a ROM table at `0xfd26e0`-`0xfd26fe` in that loop — `00c5 0000 0000
8000 0000 0080 0000 8657 00ff 136c 0050` — which is where the index most plausibly
comes from.

**Next**: find what writes the pointer. It is a register at the point of use, so the
question is which earlier read supplied it — and both machines can be tapped at the
same instruction, which is how this was narrowed in the first place.

This supersedes the peripheral hunt: no peripheral answers differently, the game
simply computes an address from state it built earlier.

## ROOT CAUSE: the game's sequencer is stuck on step 0xfe105f — 2026-08-18

NVRAM `0x40fffc` holds a **continuation pointer**: each step of the game's
boot/attract sequence stores the address of the next step there. A write tap on it
in the reference:

```
f=0  data=f000  pc=fe01e5      0x00fff000
f=0  data=105f  pc=fe105c      0x00fe105f   <- ours reaches here too
f=4  data=1065  pc=fe105f      0x00fe1065   <- MAME ADVANCES
f=4  data=1068  pc=fe1065
f=5  data=106b  pc=fe1068
...  834 writes over 400 frames, ending at 0x00fe1387
```

**Ours is frozen at `0x00fe105f`**, the value written at frame 0. The reference
completes that step in about four frames and walks hundreds more.

So the sequencer stalls on one step, and everything visible follows from it:

```
step fe105f never completes
  -> fe48d5 / fef3b5 never run
  -> wram 0x501400 scroll table stays zero
  -> ctrl written as 0x0000 / 0x2000 instead of an animating 0x2xxx
  -> the blue flash (mode off) and nothing scrolling (field stuck)
```

The routine that step runs is the `fe14xx` loop, where the same instruction reads
different addresses in the two machines:

```
MAME:  pc=fe14f3  addr=40b906 -> 0100      addr=40ba06 -> 0280
OURS:  pc=fe14f3  addr=400006 -> 0080
```

**Next**: find what that step is waiting on. It completes in ~4 frames in the
reference, so it is waiting for something that arrives — an interrupt, a
coprocessor result, a counter, or a device flag — and does not arrive for us. The
technique that got this far works here too: tap the same PC in both and compare.

### How this was found, which is the transferable part

Five causes were named and withdrawn today — the M10K crossing, the FIFO halt, the
copro data ROM, "stuck in boot", the SDRAM output paths — every one reasoned from a
plausible mechanism and refuted by measurement. What worked was **differential
measurement against the oracle**: same instruction, same address, compare the two.
It went from "the screen flashes blue" to a named stalled step in about an hour,
after several hours of theorising had produced nothing but withdrawals.

`CLAUDE.md` opens with exactly that rule.

## V60 vs MAME, instruction by instruction: they diverge at 197,251 — 2026-08-18

Built at the user's suggestion, after they asked why the V60 and TGP both have
"verified per-opcode, never checked on real code" gaps.

**Why those gaps exist**, honestly: per-opcode fuzzing is cheap to build and
produces impressive counts — `mb86233_dec: checked=3,000,000` — and it only proves
each instruction correct *for the state it was handed*. Lockstep on real code needs
a shared memory model and identically stubbed peripherals, so it was written down as
owed and never done. The V60 arrived from the s32 project with a 29/29 unit suite
and this core is the first thing to run Virtua Racing through it. `CLAUDE.md` warns
"do not let the green suite imply otherwise", and the warning was written and then
not acted on.

### The instrument

MAME's debugger emits a full disassembled instruction trace:

```
trace vrfull.tr,maincpu,noloop
```

**`noloop` is essential.** Without it the tracer collapses loops — it printed
`(loops for 620 instructions)` — and diffing against that reports 620 phantom extra
instructions in our trace. That produced a confident, wrong claim of a V60
conditional-branch bug at instruction 83, withdrawn when the trace file was read
properly. The traces were identical there.

Our side emits the same PC stream from `dbg_pc`. The diff is then mechanical.

### The result

**The first 197,250 instructions are identical.** Then:

```
FE0DCC: cmp.h   R0, FE[R11]
FE0DD1: be      FE0E36

MAME:  branch taken     -> FE0E36
OURS:  falls through    -> FE0DD3
```

`R11 = 0x40e800`, so the operand is **`0x40e8fe`**, in NVRAM, and MAME reads
**`0x0000`** there and branches.

So either the memory operand differs or the compare's flags do. That is exactly the
class of fault per-opcode fuzzing cannot reach, and the trace-diff found it in one
run.

**This connects to the NVRAM shift flagged earlier and left unproven**: our NVRAM
window appeared offset by four bytes against the reference. If our `0x40e8fe` is
non-zero, this is a data divergence rather than a CPU bug — and the earlier
observation stops being a coincidence.

### The tool is worth keeping

Two commands and a diff, and it localised in one run what hours of hand-comparing
access sequences did not. It applies unchanged to any future divergence, and the
same approach is what the TGP's outstanding M0 exit criterion needs — noting that
`sim/tgp/mb86233_ref.cpp` is a hand TRANSCRIPTION of MAME's `execute_run`, so even
the existing TGP lockstep compares against a copy of the oracle rather than the
oracle itself.

## A REAL V60 BUG: OUT had its operands swapped — 2026-08-18

Found by `make v60_trace`, the tool built an hour earlier, on its first real use.

The instruction streams match MAME for 197,250 instructions, so a **write** trace
was diffed next. First difference at write 28,698:

```
MAME:                       OURS:
680000 0000 fe010a          000000 0000 fe00c4   <- five writes MAME never makes
                            000000 0000 fe00d1
                            000000 0000 fe00de
                            000040 0000 fe00eb
                            00004e 0000 fe00fa
                            680000 0000 fe010a
```

Those PCs are `out` instructions:

```
FE00B4: movea.h C00000, R0
FE00C4: out.b   R1, 10002[R0]
FE00EB: out.b   #40, 10002[R0]
```

MAME's program-space tap never sees them because `out` writes the **I/O space**. We
wrote them to *memory*, at the wrong address: `out.b #40, ...` wrote to address
`0x000040` — **the immediate had become the address**.

### The oracle is unambiguous

```cpp
// op12.hxx
uint32_t v60_device::opOUTB() {
    F12DecodeOperands(&ReadAM, 0, &ReadAMAddress, 2);
    m_io->write_byte(m_op2, (uint8_t)m_op1);      // address op2, data op1
}
uint32_t v60_device::opINB() {
    F12DecodeFirstOperand(&ReadAMAddress, 0);     // for IN, op1 IS the address
```

**IN and OUT have opposite operand roles**, which is how it was got wrong. Our
`f12_op1_is_addr` already encodes the difference correctly — it lists IN and not
OUT — so `op1` always held the value; only `S_OUT_WR` used it as an address:

```systemverilog
dbus_addr <= op1; dbus_wdata <= op2val;   // was
dbus_addr <= op2; dbus_wdata <= op1;      // is
```

### Verified

```
before:  000040 0000 fe00eb
after:   c10002 0040 fe00eb
```

`out.b #40, 10002[R0]` with `R0 = 0xC00000` now sends `0x40` to port `0xC10002`.
V60 unit suite still **29/29**, `make test` still green.

**Virtua Racing configures its I/O board through those ports during boot**, so every
one of those writes was being thrown at the wrong address instead.

### What it did NOT fix

`make v60_trace` still reports **DIVERGES at instruction 197,251**. At least one
more difference remains. That is expected rather than disappointing: the tool
measures whether a fix moved the boundary, and this one did not, so the next bug is
independent of it.

Note `0xC10002` is outside the DPRAM window our decode maps at
`0xc00000`-`0xc00fff`, so those writes now go to an unmapped address and are
discarded. Whether Model 1 has something there is the next question — MAME maps
`model1_io` in that region.

### The lesson, which is the point

This bug survived: 29/29 V60 unit tests, every fuzz suite, a full `make test`, boot
traces, frame renders, and months of use. It was found in one run by diffing against
the oracle on real code. Per-opcode verification cannot find an instruction whose
*operands* are transposed, because the test feeds operands the same way the
implementation reads them.

## Next divergence: a byte READ of the GLUE irq_mask returns 0 — 2026-08-18

With the OUT fix in, the write-trace diff advances from write 28,698 to **77,904**
— the fix genuinely moved memory agreement a long way. The next difference is a
different KIND of bug: same address, same PC, **different data**.

```
MAME:  e00002 00fd fe01fd
OURS:  e00002 0000 fe01fd
```

The code is a read-modify-write of the interrupt mask:

```
FE01EF: movea.b E00000, R0
FE01F6: mov.b   2[R0], R2      ; read irq_mask
FE01FA: clr1    #1, R2         ; clear bit 1
FE01FD: mov.b   R2, 2[R0]      ; write back
```

MAME writes `0xfd` = `0xff` with bit 1 cleared. We write `0x00`, so **our read
returned `0x00`**.

And the register genuinely holds `0xff` — both machines write it identically during
boot, and our own trace confirms it:

```
ours:  WRT e00002 00ff 01 fe003f
MAME:  e00002 00ff 00ff fe003f
```

`m1_glue`'s read path is correct on inspection (`3'd1: rdata = {8'd0, irq_mask}`),
and the following write at `fe0045` targets the HIGH byte (`be=02`), which the
`be[0]` guard correctly ignores. So the value is there and the read loses it —
a byte-lane extraction on the read path is the obvious suspect, since `0xE00002` is
even and the byte wanted is the LOW one.

**Not yet chased.** Recorded with the evidence so it can be picked up directly.

### On the IN/OUT framing, corrected

The `in`/`out` I/O-space problem was **already known and already half-fixed** —
`v60.sv`'s header records that a faked IN "left the CPU polling a constant forever"
and that they are real bus accesses now. Today's contribution is narrower than it
was first presented: that repair got **IN** right and left **OUT** with its operands
transposed. The claim that `findings.md`'s "the V60 never reads the coprocessor
back" needed correcting is also softer than stated — that entry measured the program
space, and the header already noted `model1_io` maps the coprocessor's registers.

## FIXED: the GLUE decode aliased a whole page onto sixteen bytes — 2026-08-18

`m1_glue` decodes `a = addr[3:1]` — three bits, sixteen bytes — but `m1_decode`
asserted `sel_glue` for the **entire 0xe0 page**. Everything above `0xe0000f`
aliased back onto it.

Boot writes a run of bytes upward from `0xe00010`:

```
FE0060: movea.b 10[R0], R1     ; R1 = 0xE00010
FE006C: mov.b   #0, [R1+]      ; writes 0xE00012

MAME:  e00012 0000 00ff fe006c    -> unmapped, discarded
OURS:  glue a=1                   -> wrote 0xE00002, clearing irq_mask
```

The game sets `irq_mask` to `0xff` at `fe003f`; we cleared it at `fe006c`; the
read-modify-write at `fe01f6`/`fe01fd` then wrote `0x00` where the reference writes
`0xfd`. Traced by logging every change of `irq_mask` with the PC that caused it.

MAME maps these individually, with no mirror:

```
e00000 irq_control_w   e00004 bank_w         e00008 timer_period_w
e00002 irq_mask_r/w    e00006 timer_mode_w   e0000c timer_r
```

Fix: `sel_glue` additionally requires `addr[15:4] == 0`.

**The testbench encoded the same wrong assumption** — `tb_m1_decode`'s reference
model said `if (hi == 0xe0) return GLUE;`, the whole page — so implementation and
reference were wrong together and **466,714 checks passed regardless**. Corrected
against the oracle's map; the suite is green at the same count.

That is the third time in one day a reference written from the same reading as the
implementation hid a bug from its own test. See `docs/differential-testing.md`.

## Trace-diff progress, and where it stops — 2026-08-18

Memory agreement between our core and the reference, by first differing write:

| after | first differing write |
|---|---|
| (start) | 28,698 |
| `OUT` operand fix | 77,904 |
| GLUE decode fix | **266,496** |

The instruction-stream divergence moved 197,251 -> 205,156 -> 206,307 as the
comparison itself was corrected (cold NVRAM, collapsed repeats).

**It now stops at the I/O board handshake**, which is a timing difference rather
than a fault — see `docs/differential-testing.md`. `m1_ioboard`'s `LATENCY = 64`
answers faster than MAME's Z80, so the V60's poll loop runs once instead of many
times. Both complete; only the duration differs.

**Three divergences chased today turned out to be instrument artifacts**: collapsed
loops in MAME's tracer, branch-to-self loops invisible to a log-on-change PC trace,
and MAME's saved NVRAM making its boot warm while ours is cold. All three are now
handled by `tools/v60_trace.sh` and documented.

## The I/O board handshake, timed against the reference — 2026-08-18

`m1_ioboard` waited `LATENCY = 64` cycles before clearing the flag at `0xc00040`,
on the stated reasoning that "the V60 polls, so any non-zero value works and the
exact figure is not known". Two Lua instruments — `tools/mame_iohandshake.lua` and
`tools/mame_flag_state.lua` — replaced that with measurement:

| | reasoning said | reference says |
|---|---|---|
| time to answer | "microseconds, anything non-instant works" | **38,577 us** = 617,236 V60 cycles = **740,684** of our 19.2 MHz domain |
| how often | every request, forever | **once**, at boot, and never again |
| flag after boot | cleared each frame | **left set** — 1,194 of 1,200 frames sampled |

It is that long because it is not a mailbox turnaround: it is the I/O board's Z80
powering up and running its self-test. The 36,308 polls the V60 makes during it
account for essentially all 36,131 `c00040` reads in the earlier peripheral census.

**One number reproduces both behaviours.** A request re-arms the deadline, the
V60's doorbell arrives every 333,913 cycles, and 333,913 < 740,684 — so after boot
the count never expires and the flag stays set on its own, while at boot the V60
raises it once and only polls, so the single reply lands. No one-shot rule and no
second parameter.

**Why it mattered even though the game cannot see it.** The V60 never reads the
flag after boot, so clearing it was invisible on screen. It was not invisible to
`make v60_trace`: our V60 left the boot poll loop after one read where the
reference loops 36,308 times, and the diff reported that as a divergence at
instruction ~206,307, which was chased as a CPU bug. **A guessed constant in a
peripheral produced a false CPU-bug report.** That is the argument for measuring
peripherals whose behaviour the game cannot observe.

Also found while checking the baseline: `m1_uart_tx` and its testbench existed with
**no Makefile target at all**, so `make test` never ran them and `make lint` never
saw them — while CLAUDE.md's baseline listed `m1_uart_tx: checks=69` as though it
had. Now wired in. The module stays instantiated nowhere by intent; it is parked
for hardware monitoring if that is ever needed.

## CORRECTED: "the V60 never reads the coprocessor back" — 2026-08-18

This was recorded as a measurement, carried into `CLAUDE.md`'s table of things
reasoning got wrong, quoted in `docs/debug-overlay.md` row `03` to justify reading
`dbg_fifo_pops`'s zero as healthy, and written into `m1_copro_if.sv`'s own comments.
**It is false.**

`tools/mame_v60_iospace.lua`, 600 frames of the reference:

    V60 I/O SPACE: 859,618 reads, 5 writes
      reads by address:   d80000  710,722      the coprocessor output FIFO
                          d20000  148,896      coprocessor RAM data
      reads by PC:        fed5a4  138,224
                          ff850c   35,924  ...

About **1,433 I/O reads a frame**. The first ones appear at frame 9, from
`pc=ff9754` — the `in.w [R23], R2` that `v60_trace` had just walked into.

**Why the original census returned zero: it looked at the program space.**
`model1.cpp` maps the coprocessor interface into `AS_IO` *and* program space with
identical addresses (lines 1016-1019 and 1033-1036), but the game reaches it with
`in.w`/`out.w`, so all the traffic is in `AS_IO`. A census of the other space sees
nothing and **that nothing reads exactly like an answer**.

There is a second reason it went unchallenged: for much of this project our own V60
faked `IN`, returning a constant, so our core genuinely made zero readback accesses.
The measurement of the reference and the behaviour of our stub agreed, which made
the wrong conclusion look confirmed from two directions. `IN` is real now (and `OUT`
had transposed operands until today), so that agreement is gone.

**When a measurement says "never", check that the instrument could have seen it.**
And when a measurement of the reference agrees with a known stub in our own core,
that is not corroboration.

### What it means for M2

Our core's `TGP->V60 returns=0` and `V60 pops=0` are therefore **gaps to close, not
properties to preserve**. `m1_boot BOOT_CYCLES=600000000` has the TGP retiring
48,356 instructions and pushing nothing back, with `copro RAM writes=0`, while the
reference's V60 is reading results 1,433 times a frame. That is the next thing in
front of the 2D question, not behind it.

## CORRECTED: our coprocessor data ROM is fine; the ADDRESS is wrong — 2026-08-18

`tb_m1_boot` printed `first two data words: 3f800000 00012e00 (MAME: 00000030
00012e00)`, which reads as a broken `copro_data` image and points at the packer.

**The packer is correct.** The four ROM files byte-interleaved exactly as
`ROM_LOAD32_BYTE` specifies give word 0 = `3f800000`:

    mpr-14898.39  00 00 00 00 ...      -> byte 0 of each file, little-endian:
    mpr-14899.40  00 00 00 00 ...         00 | 00<<8 | 80<<16 | 3f<<24
    mpr-14900.41  80 00 00 00 ...       = 3f800000
    mpr-14901.42  3f 00 00 00 ...

**The reference gets `00000030` because it reads a different word.** Its TGP makes
exactly three io accesses in its first 30 frames (`tools/mame_tgp_io.lua`):

    W io 002e <- 00000010        set copro_data_base
    R io 8010 -> 00000030        data word 0x10
    R io 8020 -> 00012e00        data word 0x20

and `copro_data_r` computes `index = (base & ~0x7fff) | offset`, where `0x10 &
~0x7fff` is **0** — so the base write does not move the window at all. The reference
simply reads word `0x10`. Ours reads word `0x00`. Word `0x20` matches because both
ask for it.

So the mismatch was never in the data. **A wrong expectation in a testbench accused
the right code**, and it would have sent the next session into the ROM packer — the
one place that had two independent implementations checking each other
(`verify_mra.py`).

### What it really exposes: our TGP runs different microcode

Our TGP's first io accesses are **five reads of io `0x0000`** — `copro_ramadr` —
which the reference never makes, followed by `R 8000` where the reference does
`R 8010`. The divergence is there, at the very start, not in any ROM.

That is the concrete form of what M0 exit criterion 2 has always owed:
**microcode-driven lockstep for the TGP.** What exists is a whole-CPU reference in
lockstep over 8,000 retires of *generated* instructions, which cannot catch this.
The technique that made the V60 tractable today — MAME's tracer, periodic-loop
collapsing, diff the streams — applies directly, and `:tgp_copro` can be traced the
same way `maincpu` can.

Downstream state, for context: `TGP retires=48356 pc=0044`, `fifo_rd=1`,
`TGP->V60 returns=0`. The reference's V60 collects results 1,433 times a frame. So
the coprocessor producing nothing is now the nearest cause in front of the 2D
question, and its own cause is microcode divergence rather than data.

## FIXED: the boot bench loaded the TGP microcode one word out — 2026-08-18

`make tgp_trace` — microcode-driven lockstep for the coprocessor, M0 exit criterion
2 — found this on its **first run**, and the symptom pointed squarely at the CPU:

    MAME:  003E: bsif alw #0x7e2   ->  07E2: lid #0x10
    ours:  003e -> 003f -> 07e2

A `bsif` apparently executing a delay slot. Three things made the CPU look like the
only suspect: the streams matched for the preceding 48 instructions; `brif alw
#0x10` a few instructions earlier branched cleanly with no extra instruction; and
`build/rom/vr_tgp_prog.hex` was **byte-for-byte identical** to the reference's
program space at those words, checked directly:

    pc 003e  bf6407e2      pc 003f  40000000      pc 0040  41000200

MAME's `bsif` has no delay slot (`case 2: pcs_push(); m_pc = data;`) and our
`mb86233_seq` implements exactly that (`3'd2: begin pc_exec = data; do_push = 1; end`).
The decode is right too: for `0xbf6407e2`, `subtype = (opcode>>17)&7 = 2`,
`cond = (opcode>>20)&0x1f = 0x16` (always), `data = 0x07e2`.

**The bench was writing the microcode to the wrong addresses.**

```
uc_data <= ucode[uc_addr];
if (uc_we) uc_addr <= uc_addr + 11'd1;
```

Both non-blocking, so during any cycle `uc_addr` was already `A` while `uc_data`
still held `ucode[A-1]`, and `m1_tgp` wrote `prog[A] = ucode[A-1]`. **Address 0 came
out right by accident** — the address does not advance on the first cycle, because
`uc_we` is still low — which is why instruction 1 executed correctly and every one
after it came from the wrong word. That accident is what made the traces agree for
48 instructions and hid the shift.

What settled it in one run was adding the **fetch address and the opcode** to the
trace rather than reasoning further:

    TGPPC 0010 fetched_from=0010 ir=bf6e0000     <- hex word 0x0f, not 0x10

`uc_data` is now combinational on `uc_addr`. With that, `003e` holds the `bsif` and
branches straight to `07e2`, and the lockstep reports IDENTICAL.

### Scope, and what it invalidates

| bench | microcode loader | affected |
|---|---|---|
| `tb_m1_boot` | its own, broken | **yes** |
| `tb_m1_frame` | drives the real `m1_rom_loader` | no — `v60_trace` stands |
| `tb_m1_tgp.cpp` | sets address and data together | no |
| hardware | `tgp_din`/`tgp_addr`/`tgp_wr` same cycle | no — hence row 02's checksum matching |

**Every TGP figure `make m1_boot` ever printed came from a coprocessor running
microcode from the wrong addresses** — `TGP retires=48356 pc=0044`, `fifo_rd=1`,
`returns=0`, the lot. They were quoted in this session as evidence about the
coprocessor's output side; they were evidence about nothing.

This is the fifth divergence in two days that was the **instrument** rather than the
design, and the first where the instrument was a testbench's **stimulus** rather
than its observation. The others are in `docs/differential-testing.md`; the general
rule earned here is narrower and worth stating on its own: **when a trace and a ROM
image disagree, dump what the DUT actually fetched before suspecting either.**

## FIXED: ST was not a register — the TGP's flags lived in the ALU pipeline — 2026-08-18

`make tgp_trace`'s second use found this, and it explains why the coprocessor never
produced anything.

The command-dispatch loop reads a word from the input FIFO, masks it and compares:

    0043: ldi #0x100, x1      the input FIFO in data space
    0044: mov (x1), b
    0045: mov bh, d
    0046: lia #0x3f
    0047: andd : mov $0xb, a
    0048: subd
    0049: brif !zrd #0x44     loop until the compare matches

Our TGP went round 41 times where the reference goes round once. The FIFO word was
right — `04000000`, the same word the reference reads — so the flag was wrong:

    0048: subd       d=00000000  st=c0000002  zrd=1     correct, ZRD set
    0049: brif !zrd  d=00000000  st=c0000008  zrd=0     ST CHANGED under the branch

**The branch instruction recomputed ST before its own condition was evaluated.**

    assign st = {seq_zc1, seq_zc0, alu_st_out[29:0]};      // what it was

`alu_st_out` is combinational — `(s2_st & ~st_mask) | st_set`, where `s2_st` is
`st_in` pipelined through `ALU_LAT` stages. So the architectural flags were being
carried in the **ALU's pipeline registers** and recomputed for whatever instruction
happened to be in the ALU. Any conditional branch immediately after a flag-setting
ALU op read a corrupted ST.

MAME keeps ST as state and updates it exactly once per instruction:

    mb86233.cpp:201   m_st = F_ZRC|F_ZRD|F_ZX0|F_ZX1|F_ZX2|F_ZC0|F_ZC1;
    mb86233.cpp:499   m_st = (m_st & ~m_alu_stmask) | m_alu_stset;

`st_hold` is now that register, latched on `alu_out_valid`, reset to `0x38000003` —
MAME's value minus ZC0/ZC1, which the sequencer owns.

### Why the existing lockstep never caught it

`tb_mb86233_core` reports `lockstep_regs=8000 diverged=0` **both before and after
this fix.** Its 8,000 retires are *generated* instructions, and it never happened to
put a conditional branch straight after a flag-setting ALU op with a zero result.
That is the exact blind spot generated-instruction lockstep has and real microcode
does not, and it is the whole argument for `make tgp_trace` in one datum. Do not read
`diverged=0` there as coverage of the flag path.

### What it cost

The TGP could never leave command dispatch, so it never read a command, never
computed and never wrote a result. Every conclusion drawn from `returns=0`,
`V60 pops=0` and `copro RAM writes=0` was downstream of this. With the fix the
lockstep advances from 71 instructions (spinning) to 77 (progressing).

## FIXED: brul/bsul were not implemented — the dispatch jump was a constant — 2026-08-18

`seq_branch_val = d_bdata` unconditionally, for every branch subtype. So `brul` and
`bsul` — the register- and memory-indirect branches — jumped to **their own
immediate field**, turning a computed jump into a constant one.

MAME, `mb86233.cpp` case 1 (`brul`) and case 3 (`bsul`):

    if(opcode & 0x4000) { v = read_reg(opcode); }         // register form
    else { ea = ea_pre_0(opcode); v = read_dword(ea); }   // memory form

and `read_reg` masks its argument to **six** bits (`r &= 0x3f`), not the five the
disassembler prints — so the index is `d_bdata[5:0]`.

`make tgp_trace` found it at pc `0x0052`, `brul alw d`:

    0050: lia #0x53
    0051: addd : mov $0, p     d = 8 + 0x53 = 0x5b   (ours, correct)
    0052: brul alw d           MAME -> 0x005b,  ours -> 0x4019

`0x4019` is the instruction's own low half. **That instruction is the command
dispatch table**, so nothing past it ever ran.

### Sizing it before touching the FSM

Scanning the microcode for the branch group (`opcode >> 26` in `{0x2f, 0x3f}`,
subtype `(opcode >> 17) & 7`):

| subtype | | count |
|---|---|---|
| 0 | `brif` | 196 |
| 1 | `brul` | **1** — pc `0x0052`, register form, reg `0x19` = `d` |
| 2 | `bsif` | 23 |
| 3 | `bsul` | **2** — pc `0x04c5`, `0x04da`, both MEMORY form |
| 5 | `rtif` | 12 |
| 6 | `ldif` | 2 |
| 7 | — | 4 (no case in MAME's switch either; no PC change) |

So the register form is one site and the thing blocking dispatch; the memory form is
two sites, neither reached yet. The register form is implemented. **The memory form
is not** — it needs a data-memory read before the branch resolves, which is another
FSM state — and it now prints a warning in simulation rather than jumping somewhere
plausible, the way `v60.sv` reports a skipped `BRK`.

### Result

The lockstep advances **77 -> 102** instructions, and our stream goes from 71 lines
with 1 loop to 322 lines with 10 loops against the reference's 343 with 21. The
coprocessor is executing real work for the first time.

The next divergence is at the same instruction for a different reason: `brul alw d`
with `d = 0x85 + 0x53` where the reference has `0x02 + 0x53`. `d` comes from the FIFO
word via `mov bh, d`, so **the command word we read differs** — the dispatch itself
now works. That points at the V60 side or at FIFO ordering, not at the branch.

### Two self-inflicted build failures worth remembering

A `$display` block that tested `rst_n` under `posedge clk` tripped `SYNCASYNCNET`
("flopped as both synchronous and async"), and the test was redundant — `state`
resets to `S_FETCH` so it cannot be `S_RETIRE` in reset. Then the comment explaining
that contained the word "verilator", which the linter read as a pragma and rejected
with `BADVLTPRAGMA`. **Do not name the linter in a comment.**

## FIXED: 0x680000 had no read handler — the display-list buffer select read 0xFFFF — 2026-08-18

`make v60_trace` found this at instruction 26,283, once the identity-block fix had
carried the trace past 25,682:

    FF96F7: mov.h  680000, R0
    FF96FE: test1  #6, R0
    FF9701: be     FF970C        the reference takes it; we fell through

`0x680000` is the display-list control register. `m1_decode` asserted `sel_listctl`
and `m1_main` handled **writes only** — reads fell through the mux to
`rdata_r <= 16'hFFFF`. So bit 6, the **display-list buffer select**, read as 1
forever and we never followed the reference's double-buffer handshake.

### It is not a plain latch

From `model1_v.cpp`, three functions together define it:

| | |
|---|---|
| `model1_listctl_r` (:1358) | offset 0 returns `listctl[0] \| 0x30` — bits 4 and 5 **forced set**; offset 1 is plain |
| `set_current_render_list` / `get_list_number` (:1338, :1344) | when bit 2 is **clear**, bit 6 **mirrors bit 3** — software picks the buffer |
| `end_frame` (:1351) | when bit 2 is **set**, bit 6 **toggles every second frame** — automatic double buffer |

So a register that reads back what was written would still have been wrong.

### Built as its own module, with its own suite

`rtl/video/m1_listctl.sv` and `sim/video/tb_m1_listctl.cpp`, 26 checks, per hard
rule 5 — rather than a few lines buried in `m1_main`, because the behaviour is not
obvious and is worth testing exhaustively. The mirror is applied **combinationally
on the read path** instead of by mutating the stored value on a schedule: MAME
applies it inside the render functions, so it has always happened before anything
reads the register, and doing it on read is the same observable behaviour without
inventing a point in the frame to do it at.

**The testbench computes its expectations from `model1_v.cpp` in its own
`ref_read0()`** rather than from the RTL. That is deliberate after the
identity-block lesson, where one reading became the RTL table, the testbench's
expected values and the docs at once — and the testbench even carried a comment
explaining why it was typed out separately, which did not help because it was still
one reading.

### Also visible in the same trace

The loop census reports we spend far **less** time at `fe1433` than the reference —
1,819 iterations against 9,546. That is the wait loop immediately before this code,
so it is plausibly the same cause, and it is a useful confirmation signal.

## The V60 trace's second resolution limit, and a CPI gap worth its own look — 2026-08-18

With `0x680000` implemented the trace advances 26,283 -> **26,945**, and stops on a
difference that is again **timing, not function**:

    MAME:  fe1433 fe1435 fe143d  fe1433 fe1435 fe143d  -> fe02bc   (interrupt)
    ours:  fe1433 fe1435 fe143d  fe1433 fe1435         -> fe02bc

`fe1433`/`fe1435`/`fe143d` is `inc.w R0` / `cmp.b #2, 500501` / `blt` — a wait loop
on a byte the vblank handler advances. The interrupt lands **one instruction earlier
in the loop** for us. `v60_collapse.py` reduces the loop to one instance, but it
cannot absorb a **trailing partial iteration** of differing length, so the streams
are offset by one from there.

Two ways past it, neither done: teach the collapser to skip a partial final
iteration of a loop it has just collapsed, or move to **write-trace** diffing, which
tolerates this by construction.

### The CPI gap

The loop census makes the cause measurable rather than inferred:

    fe1433,fe1435,fe143d    MAME 11,506 iterations    ours 3,619    (-68.5%)

Consistent at every position it appears. That is the reference completing **3.2x**
as many iterations of the same three instructions in the same wall time:

| | instructions/frame in that loop | implied cycles/instruction |
|---|---|---|
| reference, 16 MHz | 11,506 x 3 = 34,518 | ~8 |
| ours, 19.2 MHz | 3,619 x 3 = 10,857 | ~30 |

`make m1_boot` has printed that ~30 average for a long time ("29.27 avg (INCLUDES
block instructions)") and it was read as a property of the design. Against the
reference it is a **3.8x shortfall per instruction**, and it is the direct reason an
asynchronous interrupt lands at a different point in a wait loop.

It is not a correctness fault on its own — the game waits either way — but it makes
every timing-dependent comparison approximate, and it is the kind of gap that
matters once the rasterizer has to keep up with a frame. Worth a look on its own
terms; `tools/v60_cpi_sweep.sh` already exists.

## Where the V60's cycles actually go — measured, after two wrong answers — 2026-08-18

The reference completes 3.18x more iterations of the `fe1433` wait loop than we do in
the same wall time. The question that matters for the planned V60 split is **what to
optimise**, and it took three attempts to answer honestly.

**Attempt 1, reasoning — wrong.** The FSM's shortest path is
`S_FETCH -> S_FETCH_W -> S_DECODE -> S_ALU -> S_RETIRE`, five cycles, against a
steady-state ~20 CPI, so "three quarters of every instruction is spent waiting on
memory". Arithmetic, not measurement.

**Attempt 2, the existing sweep — also wrong, and the tool was stale.**
`tools/v60_cpi_sweep.sh` hardcoded `-GCEDIV=3` while `Model1.sv` ships
`.ce_cpu(1'b1)`, so every number it ever produced described a V60 getting one cycle
in three. Its header said "at the production /3 clock enable" — true of an earlier
design, never revisited. Re-run at `CEDIV=1`:

| | LAT=0 | LAT=64 |
|---|---|---|
| FAST=0 | 6.08 | 7.31 |
| FAST=1 | 6.00 | 6.37 |

That reads as "the core is 6 CPI and latency is irrelevant", which retired attempt 1
— but the sweep's workload is **514 instructions producing FOUR instruction
fetches**. The test code sits inside the fetch window and loops, so it never
stresses fetch, which is exactly why latency barely moves it. It cannot explain the
~20-30 CPI real code shows.

**Attempt 3, direct measurement.** `tb_m1_boot` now counts CPU-domain cycles with a
bus request outstanding, in three buckets — data, fetch, and the union, because the
two overlap and adding them would overstate the total:

    819,812 instructions over 25,000,148 CPU cycles = 30.49 CPI
    data-stalled  9,625,651 (38%)
    fetch-stalled 6,819,902 (27%)
    either       16,435,859 (65%)

So **~20 of the 30.5 CPI is waiting on memory** and ~10 is execution. The two buckets
barely overlap, which says the single arbitrated bus is serialising them rather than
hiding one behind the other.

### What this means for the V60 split

**The V60's own logic is close to the reference already** — ~6 CPI in isolation
against MAME's implied ~8. The 3.18x throughput gap is almost entirely the **memory
subsystem**: SDRAM latency under five-master contention, plus instruction-fetch
bandwidth.

So extracting the V60 and optimising *it* would not close the gap. The target is the
memory path — a small instruction cache, deeper prefetch, or giving fetch its own
port — and that lives outside the CPU, which is a different sharing question between
the Model 1 and Model 2 projects than the core itself.

The split is still worth doing for the reasons it was proposed. It just is not the
lever on this number, and it would have been easy to spend the effort there and find
that out afterwards.

## The TGP fixes expose a deadlock: each side waits for the other — 2026-08-18

With the ST register and `brul` implemented, the coprocessor round-trip works for the
first time — and the core then **stops further back than it did before**.

    600 M cycles   pc fed5a4  TGP retires=501 pc=0492  pushes=71 returns=20 pops=20
    1.5 G cycles   pc fed5a4  TGP retires=501 pc=0492  pushes=71 returns=20 pops=20

**Identical.** The TGP retired nothing between 150 M and 375 M CPU cycles while the
V60 executed 8.8 M more instructions, all of them spinning at `fed5a4`. 862 frames,
well past the frame 276 the reference needs — this is a deadlock, not slow progress,
and an earlier "it is just pacing" reading of the 600 M run was wrong.

    TGP stuck? io_rd=0 io_wr=0 io_ack=0  fifo_rd=1  fifo_wr=0

`fifo_rd=1`: the TGP is blocked reading a command from an **empty input FIFO**, while
the V60 polls the **output FIFO** at `fed5a4` for a result. Each waits for the other.
The unimplemented `bsul` memory form is not involved — its warning never fired.

### This is a regression, and the fixes are still right

Before them the core reached `ff7d7e` with tilemap 1 holding its 648 category-1
tiles, `[5006] = 0x2000` and 96 row-mask words. It got there **because the V60 was
ignoring a coprocessor that never answered anything**. The fixes moved us from
"coprocessor absent, so the game skips it" to "coprocessor present but incomplete, so
the game waits for it" — the standard hazard of a partial implementation, and not a
reason to revert work that is verified against the reference instruction for
instruction.

### The most likely missing piece

`copro RAM writes=0`, while `tools/mame_v60_iospace.lua` measured the reference's V60
reading `0xd20000` — the coprocessor RAM data port — **148,896 times per 600 frames**,
second only to the output FIFO itself. That path is not implemented here, and a
coprocessor whose RAM the host can neither fill nor read back is a plausible reason
the exchange stops after twenty results.

### Do not flash the 2026-08-18 20:22 build

Simulation predicts the deadlock, so a hardware round trip would only confirm what is
already known and would look like a step backwards on screen. Fix the copro RAM path
first. The `.rbf` is kept because its resource numbers are wanted — 29,536 ALM,
452 M10K, +0.301 ns — but it is not an improvement to run.

## The interlock fix turns a spin into an honest deadlock — 2026-08-18

With the empty-outbound-FIFO stall in place, the boot sim changes character
completely:

| | before | after |
|---|---|---|
| V60 | spinning at `fed5a4` on stale data | **stalled at `ff9754`**, the `in.w` result read |
| ifetch lines | 6,253,201 | **70,369** |
| CPI | 30.5 | **516**, and 97% data-stalled |
| TGP | parked `0x0492` | **stalled `0x00a5`**, `mov (x1), a` on an empty FIFO |
| pushes | 71 | **4** |

Both sides now stall where the hardware stalls, instead of one of them running on
rubbish. **That is the fix working.** It is also a hang: 97% of CPU cycles hold a bus
request that never acknowledges, so this build would freeze on the board rather than
show sky and sea. Better to diagnose, worse to run.

### The imbalance it exposes, stated precisely

**The V60 believes it has sent a complete command after 4 pushes. The TGP is still
waiting for input.** One of the two is wrong about how many words a command is, and
the reference's own answer is already measured — `tools/mame_tgp_fifo.lua` shows one
command as **five** words in and one out:

    0x100 ->  04000000  00000000  01000000  3f400000  428c0000
    0x400 <-  42520000

So the next question is exactly: does our V60 push five words per command, and does
our TGP consume five? Both are countable with instruments that now exist. Do not
guess at it — a zero counter has been misread as a missing feature twice today
already.

### Also new, and mildly encouraging

The TGP's io accesses have changed shape: six reads of io `0x0000` and then **io
`0x0020`**, which is the **sincos unit** (`copro_io_map`, `0x0020-0x0023`). It was
reading `0x8000`, the data ROM window, before. The coprocessor is reaching for a math
unit for the first time.

### Do not flash this build

It deadlocks earlier than the 20:22 one and would freeze rather than draw. The 20:22
build remains the hardware baseline.

## The deadlock in one line: our V60 pushes four words, the reference pushes five

Counted on both sides rather than inferred (`tb_m1_boot`'s `COPRO PUSH`/`POP`/`RESULT`
lines against `tools/mame_tgp_fifo.lua`):

| | word | popped at TGP pc |
|---|---|---|
| both | `04000000` | `0x0044` |
| **reference only** | **`00000000`** | dispatch |
| both | `01000000` | `0x004d` |
| both | `3f400000` | `0x00a5` |
| both | `428c0000` | `0x00a5` / `0x00a6` |
| reference | result `42520000` | written to `0x400` |

**Every word we push matches the reference exactly, in order. One is missing.** The
TGP is therefore one word short of a complete command and waits; the V60 believes it
has sent one and waits for the result. That is the whole deadlock.

### Why this is a good place to be

It is a single, findable difference in the V60's instruction stream, and `v60_trace`
is the tool for exactly that. The pushes happen around `ff97xx`, which is *before*
the trace's current divergence at 26,945 — so on the face of it our V60 executes the
same instructions and should push the same words. One of those two statements is
wrong, and finding out which is a bounded question:

- if the streams really do match there, the missing push is a **bus or decode**
  problem — a write to `0xd80000` that does not become a push;
- if they do not, `v60_trace`'s divergence is being masked and the collapse or the
  window needs attention.

Do not assume which. The last two "obvious" answers here — the coprocessor RAM path,
and the FIFO not advancing — were both wrong, and both were reasoned from a counter
rather than read from the design.

## WITHDRAWN: "our V60 pushes four words, the reference pushes five" — 2026-08-18

Wrong, and wrong in the way this file keeps warning about.

`tools/mame_copro_pushes.lua` taps the reference's **writes** to `0xd80000` and names
the PC of every push:

    push 1  pc=fe69d3  0400_0000
    push 2  pc=ff9741  0100_0000
    push 3  pc=ff9749  3f40_0000
    push 4  pc=ff9751  428c_0000

**Four words, the same four we push, from the same instructions.** There is no
`00000000` push.

The `00000000` entries that finding rested on came from the FIFO **read** log
(`tools/mame_tgp_fifo.lua`). Per `gen_fifo.cpp:109`, **a pop on an empty FIFO returns
`T()` — zero** — and fires the stall callback. So those entries are stall-and-retry
attempts, and that tap cannot distinguish "read a zero" from "read nothing and
retried". They were read as data.

Seventh instrument artifact of the day, and the first written *after* the rule about
this was added to `docs/differential-testing.md`. Reading the rule is not the same as
applying it.

### What the comparison actually shows

| | ours | reference |
|---|---|---|
| pop 1 | `04000000` @ TGP pc `0044` | `0044` |
| pop 2 | `01000000` @ `004d` | `004d` |
| pop 3 | `3f400000` @ `00a5` | `00a5` |
| pop 4 | `428c0000` @ **`00a5`** | **`00a6`** |
| next | **stalled at `00a5`** | `00a7 fml` then `00a8` writes `42520000` |

The microcode at `00a5`/`00a6` is two consecutive FIFO reads — `mov (x1), a` then
`mov (x1), b`. Ours consumes both words but **never advances past `00a5`**: it pops,
does not retire, and comes back for another word. The reference retires each read and
reaches the multiply.

So the question is no longer about the protocol's length. It is: **why does a FIFO
read at `00a5` pop without retiring?** Look at `fifo_ack` against `fifo_in_pop` in
`m1_tgp`, and at how `mb86233_mem` holds `ext_rd` across the memory states — a
request held for more than one cycle pops more than once, and an acknowledge that
arrives on the wrong cycle retires nothing.

## M0 exit criterion 2 is met: the TGP is instruction-accurate on real microcode

`make tgp_trace` reports **`IDENTICAL for 342 instructions`** — the reference's entire
traced window, its collapsed stream being 343. Our coprocessor executes the same
instruction sequence as MAME's on the real decapped microcode.

This is the criterion the project has owed since M0. What existed was
`sim/tgp/mb86233_ref.cpp`, a whole-CPU reference in lockstep over 8,000 retires of
**generated** instructions — which proves each instruction correct for the state it
was handed, and cannot show the machine reaching the wrong state on real code.

Four bugs fell out of building it, in order:

| | |
|---|---|
| the boot bench loaded the microcode **one word high** | address 0 was right by accident, so instruction 1 worked and every one after came from the wrong word |
| **ST was not a register** | the flags lived in the ALU's pipeline and a branch corrupted its own condition |
| **`brul`/`bsul` unimplemented** | the dispatch jump was a constant |
| **FIFO pop and push fired per CYCLE, not per ACCESS** | every read ate two command words, every result was pushed twice |

### The caveat belongs with the claim

The window is three emulated seconds and the TGP is idle for most of it, so 342
instructions is **the reference's whole window, not deep coverage of the instruction
set**. And `tb_mb86233_core`'s `diverged=0` remains no evidence about the flag path —
it passed both before and after the ST fix, because generated instructions never put a
conditional branch straight after a flag-setting ALU op.

**Met for what the game currently executes, not for the instruction set.** Widen the
window as the game gets further.

### A note on where this was nearly recorded

`CLAUDE.md` is gitignored (`.gitignore:122`), so it is a local-only file. Several
commit messages on 2026-08-18 say "CLAUDE.md baseline updated" — those edits are real
on disk but are **not in the repository**, and a clone gets none of them. Durable
findings belong in `docs/`, which is tracked. The test-count baseline, the resource
figures and the corrected "the V60 never reads the coprocessor back" entry all live
only in the working copy.

## Traced end to end: "no text" reaches the TGP's unimplemented math units — 2026-08-19

The chain, each link measured except the last:

| link | evidence |
|---|---|
| no text on screen | board photograph and `m1_frame` |
| the V60 never reaches the per-frame 2D setup | `[5002]`, `[5006]` and the row mask all zero at 862 frames |
| it is stuck at `FED5A4` waiting for copro RAM to read zero | reference exits that loop after ~32 iterations; ours spins **1,120,224** times |
| copro RAM word 0 holds `ffffffff` | `CRAM rd: ram_addr=0000 ram_q=ffffffff` |
| **the TGP wrote it**, once | `CRAM WR: st=2 addr=0000 din=ffffffff tgp_we=1` |
| it computed that from unimplemented math units | **INFERENCE, not measurement** |

### Three of my own conclusions were wrong on the way here

**"The array is uninitialised."** Plausible — Verilator does bring unpacked arrays up
as ones, and `mb86233_mem.sv` already carried that exact fix and reasoning. But the
`initial` block prints `CRAM INIT: 8192 words zeroed, ram[0]=00000000` in both builds.
The array starts zeroed and is written afterwards. The fix is still right on its own
merits and stays.

**"Nothing writes `ram[0]`."** Said on the strength of `copro RAM writes=0`. That
counter is `dbg_ram_writes`, which increments only on the **V60's** writes — `we && a1`
in `S_V60_RAM`. The `S_TGP` path has its own `ram_we = tgp_we` that it never sees. The
boot line reads "copro RAM writes=0" as though it covered both ports; it does not.
**Third time this session a counter's name was trusted over what it increments on**,
after `dbg_fifo_pops` and this one twice.

**"The comment containing the pragma re-triggered it."** Both `translate_off`
occurrences are in comments, and the same file compiles to a zeroed array in the module
bench, so the comments cannot be the cause. Withdrawn before it was acted on.

### Where this leaves the text

The TGP's io sequence is `R 0020` (sincos), `W 002e`, `R 8010`, `R 8020`, `W 0028`
(inv), `R 0028`, `R 0029`, `W 0008` (copro RAM address). It is using the interfaces
correctly. But `m1_tgp`'s own header says the math path is not built: *"Index arithmetic
and the exponent fixups are NOT here yet — so a read presents the quadrant base and the
integrator's memory answers."* A sincos or inverse read returns table data at the
quadrant base, not the function's value.

So the V60's wait at `FED5A4` is downstream of **M2 work that was always known to be
outstanding**, not of a bug. Two things follow:

1. **The text is probably gated on the math units**, which is a substantial piece of
   work rather than a fix. Worth confirming by making an unimplemented math read return
   **zero** instead of table-base garbage and seeing whether the TGP then writes a word
   whose low byte is zero — `m1_integrated` already acknowledges those reads with zero,
   while `tb_m1_boot` wires them to real SDRAM tables, so the two disagree today.
2. **That asymmetry is worth closing either way.** Simulation and hardware currently
   feed the coprocessor different values on an unimplemented path, which is the same
   class of divergence as the uninitialised array.

## WITHDRAWN: the 0xffffffff was never garbage — the reference writes it too — 2026-08-19

Asked MAME instead of guessing a fourth time, which is what this repository's own
first rule says to do. `tools/mame_tgp_io_full.lua`, 400 frames:

     10  W io 0008  00010000        TGP sets the copro RAM address
     11  W io 0009  ffffffff        and writes ffffffff

**The reference's TGP writes `0xffffffff` into coprocessor RAM as well.** Our value was
correct all along. Three consecutive diagnoses were chasing a non-problem:

| guess | how it died |
|---|---|
| the RAM is uninitialised | `initial` runs and prints `ram[0]=00000000` |
| nothing writes it | the TGP does; `dbg_ram_writes` only watches the V60's port |
| the TGP computed it from unimplemented math units | `MATH_ZERO=1` changed nothing |
| the register file is uninitialised | never needed — the value was right |

Each fitted the evidence. None was measured against the oracle first, and the oracle
answers it in one run.

### The real difference is VOLUME, not values

| | io accesses |
|---|---|
| reference | **158,391** over 400 frames |
| ours | **~14**, then parked at dispatch with `pc=0043` |

Busiest: `W 0020` 13,169, `R 0021` 10,925, `W 002e` 9,710, `R 0020` 9,348, `W 0009`
5,345. The reference's TGP keeps working, writing coprocessor RAM over and over until
it eventually writes the word whose low byte is zero — which is what releases the V60
from `FED5A4`. Ours does its opening handful of accesses and stops.

### And this weakens the M0 claim made yesterday

`tgp_trace: IDENTICAL for 342 instructions` was over a **3-second window**, which
captures the reference's first 343 collapsed instructions and nothing of its steady
state. So the honest reading is: **our TGP matches the reference's opening and then
stops doing work**, and the window was too short to show it. "M0 exit criterion 2 met"
overstated it — met for the first 342 instructions, which is not the same thing.

Run `tgp_trace` with a window long enough to reach the 400-frame behaviour and the
divergence will name itself.

### The three initialisation fixes stay

`m1_copro_if`'s RAM, `m1_mainram`'s sixteen arrays, `mb86233_regs`' `rf` and
`m1_tgp`'s `copro_adr` are all still correct on their own merits — an M10K and a flop
come up cleared on the device, MAME's equivalents are zero-filled, and `mb86233_mem.sv`
already carried the same fix and reasoning. They were not this bug, and the commits
should not be read as if they were.

## FIXED: bsul's memory form — the geometry call jumped to its own address field

The long `tgp_trace` window named it in one run:

    04C5: bsul alw ($0x35)
    MAME:  -> 0693      reads data[0x35], finds 0x0693, and calls it
    ours:  -> 0035      jumped to the address field itself

`bsul` **memory form**, at exactly the site identified on 2026-08-18 and deliberately
left warning-only. `0x04c5` is a subroutine call into the geometry code at `0x0693`, so
jumping to `0x0035` dropped our TGP back into the dispatch region looking finished —
which is why it made **14** io accesses against the reference's **158,391**, and why the
V60 waited forever at `FED5A4` for a completion word nobody was going to write.

### The warning built to catch this was switched off by its own guard

It was wrapped in `// synthesis translate_off`, and the linter honours that pragma too,
so the one tool that could have printed it skipped the block. `bsul` went undiagnosed
for a day with its own alarm disabled — **the same trap that silenced the copro RAM
initialiser hours earlier.** Both are now unguarded. A `$display` costs nothing in
synthesis and the pragma was never needed.

**Rule: do not wrap diagnostics in a synthesis pragma.** Two instruments in one day
were made inert by it, and an inert instrument is worse than an absent one because its
silence reads as evidence.

### The implementation

MAME's `ea_pre_0`: `switch(r & 0x180) case 0x000: return r & 0x7f`. Both real sites
(`0x04c5`, `0x04da`) use that direct mode, so two states fetch the target from data
memory before the branch resolves, deliberately bypassing the AGU so the read cannot
disturb `x0`/`b0` the way a source operand would. The other three modes still warn —
and now the warning prints.

Divergence moves **500 -> 604**.

### The next one is an FP condition flag

    0730: fadd
    0731: brif ged #0x73a
    MAME:  falls through to 0732   (ged false)
    ours:  branches to 073a        (ged true)

Operands are `d = mem[0x43]`, `a = mem[3]` (the transfer wins over `orad`, per the
write-priority rule). So either the operands differ — they come from coprocessor RAM
and the data ROM, both only just flowing — or `fadd`'s flag output is wrong. **Print
the operands and the result on both sides before assuming which.** Four diagnoses were
withdrawn today for skipping that step.

## The value-level lockstep works, and names the fault in 26 writes — 2026-08-19

`make tgp_wrtrace` diffs the TGP's data-memory write streams. First divergence, at
write 22 of 26:

    22   ref  data[0069] = 00000030      ours = 00000000     DIFF
    23   ref  data[006a] = 00012e00      ours = 00000000     DIFF
    ...
    27   ref  data[0069] = 00000030      ours = 00000030     agree
    28   ref  data[006a] = 00012e00      ours = 00012e00     agree

Those two values are the **coprocessor data ROM's words** — `io 8010 -> 00000030` and
`io 8020 -> 00012e00`. The reference stores them; our **first** read of each stores
zero, and a later read of the same addresses is correct.

So this is a **first-read / warm-up fault in the data-ROM path**, not arithmetic. And
`tb_m1_boot` already documents the hazard, for its own capture rather than the DUT's:

> *"Sampled the cycle AFTER the acknowledge. `a_dout` is registered and updates on the
> same edge as `a_ack`, so a non-blocking capture at that edge takes the PREVIOUS value
> — which produced a half-right pair and read exactly like a data path fault."*

If `t_mem_rdata` becomes valid on the same edge as `t_mem_ack`, then `m1_tgp` sampling
`dat_rdata` **during** the ack cycle takes the previous value — zero on the first read.
`io_rdata = dat_rdata` and `io_ack = dat_ack` are combinational, so the DUT has no
slack for that.

**Check both wirings, because they may differ**: `tb_m1_boot`'s
`t_dat_ack = t_mem_ack && !t_tbl_req && t_dat_req` against `m1_integrated`'s, which
feeds the same `t_mem_rdata` on the hardware path. A one-cycle disagreement here would
be a simulation-only fault — or a hardware-only one — and this session has already
found two of those.

### Refined: the data path is INNOCENT, the loss is inside the core

Our io reads return the right values — the boot trace prints them:

    TGP io 9:  R 8010  waited 9
    TGP data read 1: sdram word 300020 -> 00000030     matches the reference
    TGP io 10: R 8020  waited 9
    TGP data read 2: sdram word 300040 -> 00012e00     matches

So the data ROM, the SDRAM path, `m1_cdc_port` and `io_rdata` are all correct, and the
`a_dout`/`a_ack` alignment worry above does **not** apply to the DUT — `a_dout` updates
on the same edge as `a_ack`, so a combinational read during the ack cycle is right. The
testbench's own capture problem was sampling a cycle later, which is a different thing.

**The value is lost between arriving at the io port and being stored.** The write that
should carry `00000030` into `data[0x69]` writes zero; a later pass carries it
correctly. So look inside `mb86233_core`:

- `S_SRC_W`: `src_val <= (x_src_sp == EP_IO) ? io_rdata : ...`, guarded by
  `!(x_src_sp == EP_IO && !io_ack)`. Does the guard hold for the FIRST io read, or does
  the state advance once before `io_ack` and latch a stale `src_val`?
- the store path that consumes `src_val` — if it fires a cycle early it writes whatever
  `src_val` held before, which at reset is 0 and matches the symptom exactly.

**Print `src_val`, `io_ack` and `io_rdata` across `S_SRC`/`S_SRC_W` for the first
`sel_datw` read.** Do not fix from inspection: four layers looked correct in the copro
RAM case this morning and the fault was elsewhere.

### Why this instrument was worth building

`tgp_trace` put the divergence at instruction 604, in `0731 brif ged`, which is **not
where the error is**. The value trace puts it at write 22, in the data-ROM read — many
instructions earlier and in a different subsystem. A PC diff can only ever report the
first place a wrong value changes control flow.

## LOCALISED: `src_val` follows the io ADDRESS, not the io DATA — 2026-08-19

The all-states io trace, at a run length that actually reaches the read:

    st=4  io_ack=1  io_rdata=00000030  src_val=00000010  addr=8010
    st=3  io_ack=0  io_rdata=00000030  src_val=00000020  addr=8020

At the acknowledge `io_rdata` is `00000030` — the correct data-ROM word, matching the
reference. **But `src_val` never becomes `0x30`.** It reads `0x00000010` through the
`8010` access and `0x00000020` through the `8020` one: the low bits of the io address,
not the data.

That is why `tgp_wrtrace` sees `data[0x69]` and `data[0x6a]` receive zero, or the wrong
value, while every diagnostic that looks at the *read* says the data path is perfect.
The read IS perfect. The capture is not.

`mb86233_core`'s `S_SRC_W` reads

    if (!mem_stall && !(x_src_sp == EP_IO && !io_ack))
      src_val <= (x_src_sp == EP_PROG) ? prog_rdata
               : (x_src_sp == EP_IO)   ? io_rdata
                                       : mem_rdata;

which is correct as written, so **something else assigns `src_val` on the same cycle and
wins**, or the guard lets the state advance before the acknowledge and a later
assignment overwrites it. Both are checkable: search every assignment to `src_val`, and
print it on the exact cycle `io_ack` rises alongside whatever else is driving it.

**Do not fix from that code reading.** It is the fifth time in two days that a path
"correct as written" was not the fault — the copro RAM had four such layers.

### The enumeration: only two writers, and neither explains it

`src_val` is assigned in exactly two places in `mb86233_core`:

    S_SRC:    if (x_src_reg) src_val <= rf_rd_data;          the register path
    S_SRC_W:  src_val <= (EP_IO) ? io_rdata : ... ;           memory / io / prog

The trace shows `st=3` then `st=4`, so the access took the `S_SRC_W` path — the register
path was not used. And at `st=4` the guard's terms are satisfied: `io_ack=1`, so
`src_val <= io_rdata` should have taken `00000030` at that edge. By the next
instruction's `S_SRC` it reads `00000020`.

**Both writers are accounted for and neither explains the value.** So one of these is
true and the next step is to find out which, not to guess:

1. the print is sampling something other than what it appears to — it fires on
   `posedge clk_cpu` while `m1_tgp` runs on `m1_main`'s `clk`; the bench drives them
   from the same signal, but that should be confirmed rather than assumed;
2. the capture happens and is then overwritten before the store consumes it, by a path
   not visible in a grep for `src_val` — a hierarchical or generate-scoped assignment;
3. `x_src_sp` is not `EP_IO` at the capturing edge even though it was during the wait,
   so the mux selects `mem_rdata` (which would be stale) instead of `io_rdata`.

**(3) is the cheapest to test and fits the evidence best**: `0x10` and `0x20` are the
low bits of the io address, and `mem_addr`/`ea_src` carry exactly that. Print
`x_src_sp`, `mem_rdata` and `io_rdata` together on the acknowledge edge.

### Why this took a value-level instrument to find

Every read-side diagnostic said the data was right: the boot trace prints
`TGP data read 1: sdram word 300020 -> 00000030`, the io census showed the correct
addresses, and `m1_cdc_port` is provably fine. The error is in the consumer, one cycle
after a correct read, and only comparing the STORED values against the reference exposed
it. `tgp_trace` reported it 578 instructions later as a branch going the wrong way.

## The instrument was subsampling: a filtered print cannot show a transition

Chasing `src_val` taking the io address instead of the io data, the trace came out
self-contradictory:

    st=4 sp=2 io_ack=1 io_rdata=00000030 mem_rdata=00000000 src_val=00000010 ea=08010
    st=3 sp=2 io_ack=0 io_rdata=00000030 mem_rdata=00000000 src_val=00000020 ea=08020

At the acknowledge every term of `S_SRC_W`'s guard is satisfied — `sp=2` is `EP_IO`,
`io_ack=1`, `mem_stall=0` — so `src_val <= io_rdata` should take `00000030` and the state
should advance to `S_DST`. The next line shows `src_val = 00000020`, and **nothing else in
`mb86233_core` writes `src_val`** (only two assignments exist, and the register path was
not taken).

Two explanations were eliminated by measurement rather than argument:

- **the print's clock.** `tb_m1_boot` instantiates `m1_main` with `.clk(clk_cpu)` and the
  TGP is not `ce`-gated, so a `posedge clk_cpu` print sees every TGP cycle. Sound.
- **the wrong mux leg.** `mem_rdata` is `00000000` at that edge, so selecting it would
  give zero, not `0x20`.

**The fault was the filter.** The print fired only on `io_rd && io_addr[15]` — the cycles
*during* an io read. `S_DST`, `S_RETIRE`, `S_FETCH`, `S_FETCH_W` and `S_DECODE` were never
printed, and those are exactly the cycles between the two lines. A subsampled trace cannot
show where a value changes; it can only show that it did, which invites inventing a
mechanism for the gap.

**Rule: to find where a signal changes, print every cycle in a bounded window — never a
filtered subset.** The filter is for finding the window, not for reading it.

The next instrument is therefore: trigger on the first `io_addr == 0x8010` with
`io_ack`, then print **every** cycle for the following ~40, unfiltered. That shows the
capture, the store, and anything in between.

## The store is CORRECT: write 22 is an extra pass, not a wrong value — 2026-08-19

The unfiltered 40-cycle window, armed on the acknowledged io `8010` read:

    W0 st=7 (S_DST)   src=00000030  mw=1  maddr=00069
    W1 st=8 (S_DST_W) src=00000030  mw=1  maddr=00069

`src_val` holds `00000030` — the correct data-ROM word — and the store writes it to
`data[0x69]`. **The capture and the store are both right, and there is no datapath
fault.** The three mechanisms invented for a "lost value" were explaining something that
never happened.

So `tgp_wrtrace`'s `TW 0069 00000000` at write 22 is a **different, earlier store**, and
the correct one is write 27. The divergence is therefore about **which stores happen and
in what order**, not about a corrupted value:

| | write 22 | write 27 |
|---|---|---|
| reference | `data[0069] = 00000030` | `data[0069] = 00000030` |
| ours | `data[0069] = 00000000` | `data[0069] = 00000030` |

Writes 1-21 match exactly. At 22 the reference has already completed its io read and
stores the word; we store zero at that point and only reach the correct store at 27. So
**our TGP passes through that store once more than the reference does**, or reaches it
before the read that should precede it.

### Third time today our side looked wrong and was not

After the `ffffffff` copro RAM write (correct — the reference writes it too) and the copro
RAM contents (correct — written, not uninitialised). The pattern is consistent enough to
state as a rule: **"ours looks odd" is not a fault until the oracle disagrees**, and the
disagreement has to be about the same event, not a similar-looking one.

### What to measure next

Not the datapath. Compare the **instruction stream around write 22** against the
reference: `tgp_trace` matched for 342 instructions in a 3-second window, but the extra
store means the streams diverge in *control flow* somewhere before that write. Run
`tgp_trace` with a window that reaches it and diff the PCs immediately preceding the two
stores to `0x69`.

## The PC settles it: same instruction, first read returns 0 — 2026-08-19

With the PC carried on every write (and MAME's `GENPC` being the NEXT instruction, so
its annotation reads one ahead of ours for the same store):

    ref   write 22:  TW 0069 00000030 pc=07e8    instruction 0x07e7
    ours  write 22:  TW 0069 00000000 pc=07e7    instruction 0x07e7
    ours  write 27:  TW 0069 00000030 pc=07e7    the SAME instruction again

`07E7` is `mov (bx0) (e), $0x69` — read io, store to data. **Both sides execute it twice.
The reference gets `0x30` both times; we get 0 the first time and `0x30` the second.**

So it is a value bug after all — a **first-read fault in the coprocessor data-ROM path** —
and the "extra store" reading of the previous entry is withdrawn. Same address, same
instruction, different data.

### Why the boot print said the data was fine

`BOOT: TGP data read 1: sdram word 300020 -> 00000030` comes from the testbench's OWN
capture, which samples through `dat_ack_d` — **one cycle after the acknowledge**. The DUT
samples **on** the ack cycle. The tb's comment beside that capture says so outright:

> *"Sampled the cycle AFTER the acknowledge. `a_dout` is registered and updates on the
> same edge as `a_ack`, so a non-blocking capture at that edge takes the PREVIOUS value."*

I read that as reassurance that the data path was healthy. It is the opposite: it is a
note that the tb had to work around a one-cycle offset, and the DUT does not.

**So the suspicion raised early this morning and dismissed was right**, and it was
dismissed on the strength of a diagnostic that measures a different cycle from the one
that matters.

### What to check, precisely

Whether `t_mem_rdata` is valid **on** the `t_mem_ack` cycle or the one after, in
`m1_cdc_port`. Then whether `m1_integrated` — the hardware path — has the same alignment
as `tb_m1_boot`. If they differ, this is simulation-only or hardware-only, and this
session has already found two of those.

## WITHDRAWN (the decode is CORRECT): `ldi #0x8000, b0` is mis-decoded — 2026-08-19

Armed on the instruction and printing every cycle, `07E6` executes and **`rf_wr_en` is
never asserted**:

    W0..W12  pc=07e6  st = 1,2,3,4,5,6,9,9,9,9,9,9,10   rfwe=0 throughout

States 5 and 6 are `S_LABB`/`S_LABB_W`, with `sp=1` (`EP_DATA`) doing a data-space read at
states 3/4. **Our decoder routes this instruction down the `lab` path.** It is not a
`lab`. The word at `0x07e6` is `0x40008000`:

    opcode >> 26          = 0x10        MAME's ldi range, cases 0x10-0x1f
    opcode & 0xffffff     = 0x008000    the immediate
    (opcode >> 24) & 0x3f = 0x00        the destination register — b0

so it is exactly `ldi #0x8000, b0`, as the disassembly says. Decoded as something else,
the write never issues, `b0` stays `0x0000`, the operand `(bx0)` addresses io `0x0000`
instead of `0x8010`, the read returns 0, and the store writes it.

### The chain, end to end

    ldi #0x8000, b0 mis-decoded
      -> b0 = 0 instead of 0x8000
      -> (bx0) addresses io 0x0000, not 0x8010
      -> the data-ROM read returns 0
      -> data[0x69] gets 0 instead of 00000030          (tgp_wrtrace write 22)
      -> the FP chain at 06EE-070C computes on it
      -> `0731 brif ged` branches where the reference falls through  (tgp_trace 604)
      -> the TGP takes a different path and stops early
      -> it never writes the completion word to coprocessor RAM
      -> the V60 spins at FED5A4 forever                (1,120,224 polls)
      -> it never reaches the per-frame 2D work
      -> no text

**Every link measured.** `tgp_trace` reported the sixth line; the fault is in the first.

### What to check before fixing

`mb86233_dec` passes 3,000,000 fuzz checks with `uncovered=0`, so either this encoding is
not generated by the fuzzer or its reference shares the misreading. **Find out which
before changing the decoder** — if the reference model agrees with the DUT, fixing the DUT
will break the suite and the suite is what would have caught this.

MAME's disassembler switches on `opcode >> 26`; cases `0x10`-`0x1f` are all `ldi`, with the
immediate in `opcode & 0xffffff` and the register in `(opcode >> 24) & 0x3f`. Compare that
against `mb86233_dec`'s primary decode and against `sim/tgp/mb86233_ref.cpp`.


---

## ROOT CAUSE: the bench released the CPU before the microcode finished loading — 2026-08-19

**Instrument:** a windowed per-cycle print in `tb_m1_boot.sv`, armed on `seq_pc == 0x07e5`,
dumping `pc`, `ir`, the sequencer state, the loader's `uc_addr`/`uc_we`/`uc_done` and
`prog[0x07e6]` *as it stood at that cycle*.

**Correcting:** the entry above, which said the decoder routed `ldi` down the `lab` path.
It does not. `mb86233_dec` was right, and its 3,000,000-case fuzz suite was right to pass.

The microcode loader advances four addresses per CPU cycle — 100 MHz against 25 MHz — so
2048 words take 512 CPU cycles. The coprocessor was released at the same instant and
reached microcode address `0x07e6` while the loader was still at `0x07c6`:

    W13 pc=07e6 ir=1c1c842e st=1 paddr=07e6 prd=40008000 ucwe=0 ucaddr=0000 ucdone=1 pr7e6=40008000

`prog[0x07e6]` was **genuinely zero at the moment of the fetch**, and correctly populated
by the time anything checked. A zero word has `opcode[31:26] == 0`, which is `is_lab` — so
`ldi #0x8000, b0` was fetched as `00000000` and executed as a `lab`. The disassembly was
right, the decoder was right, and the fetch returned a different word than either was
looking at.

**This is why the `UCODE CHECK` added the same morning kept passing.** It verified all 2048
words *after* the run; the defect existed only during a 512-cycle window at reset. An
instrument that samples the wrong instant reports the wrong answer confidently.

### One line, and it is simulation-only

    wire rst_n_cpu = rs_cpu[1] & uc_done;      // was: rs_cpu[1]

`m1_integrated` states the contract in its own comment — *"Complete before the CPU is
released, so there is no crossing to handshake"* — and hardware honours it, because
`m1_rom_loader` streams during the ioctl download and the CPU waits on `rom_loaded`. The
bench never did. **Fourth simulation-only divergence found in one day**, after the copro
RAM initialisation, the `a_dout`/`a_ack` capture offset and the loader restart.

### Every symptom chased that day was this one race

    b0 never written -> (bx0) addresses io 0x0000 not 0x8010 -> data[0x69] = 0
      -> the FP chain diverges -> 0731 brif ged branches -> the TGP stops early

`tgp_wrtrace`'s "extra store at write 22", `tgp_trace`'s "divergence at instruction 604",
the "wrong io address" and the "mis-decode" were six accurate descriptions of one cause.
**A chain of correct observations is not a diagnosis** — each was a link, and the instrument
that found the head was the only one that sampled reset.

### What it bought, measured

`make m1_boot` at 1.5 B cycles, before and after:

| | before | after |
|---|---|---|
| TGP retires | stops early | **49,518**, `unimplemented=0` |
| TGP io accesses | — | **1,401,155** completed, not stuck |
| V60 -> TGP pushes | — | **561** |
| TGP -> V60 returns | — | **232**, V60 pops 217 |

The coprocessor now runs real microcode to completion and returns results. **It was worth
the day.**

### It did NOT fix the text, and the next cause is already measured

The V60 still ends at `fed5a4`, in a three-instruction loop `fed5a4 -> fed5a7 -> fed5a9`,
reading the coprocessor RAM data port **6,221,996 times**. `[5000]`-`[5007]` are all zero
and the row mask is still `0/2048`.

**MAME never executes `FED5xx` at all.** A 4-second reference trace, cold nvram, contains
zero instructions anywhere in that page:

    grep -ic "fed5" mame.tr   ->  0

So this is not the coprocessor failing to answer a poll the reference also performs — it is
our V60 reaching code the reference never reaches. That makes it a **V60 divergence**, and
`make v60_trace` is the instrument for it. Do not debug the coprocessor further on this
symptom.

---

## SIX real TGP defects, found by the microcode oracle, none by the fuzz suites — 2026-08-19

**Instrument:** `make tgp_wrtrace` — the TGP's data-memory write stream diffed against
MAME's, now carrying `x0`, `a` and `d` alongside each write.

The V60 was spinning for ever at `FED5A4`, a poll on coprocessor RAM word 0 waiting for its
low byte to read zero. The reference enters that loop 41,521 times in eight seconds and
leaves it every time; ours entered once and stayed. Every defect below sat between those
two facts.

| # | defect | first divergence |
|---|---|---|
| 1 | `lab` loaded neither A nor B — the second read was issued and discarded, and `lab_a_val` was assigned and read by nothing | write 38 |
| 2 | the AGU post-increment fired once per **cycle**, not once per access | write 42 |
| 3 | `lab`'s B operand was addressed with the A operand's field (`r1`/bank 0 instead of `r2`/bank 1) | write 65 |
| 4 | a parallel ALU op computed on the transfer's **new** operand; MAME's `alu_pre` runs before the transfer | write 90 |
| 5 | the four math units — sincos, atan, inv, isqrt — were never implemented and returned the quadrant base word | write 102 |
| 6 | `lab`'s A side dropped its `+0x200`, addressing the **command FIFO** at 0x106 instead of RAM at 0x306 | (deadlock, no writes) |

`tgp_wrtrace` then reported **IDENTICAL for 110 writes**.

### Every suite stayed green throughout

All eleven TGP suites pass byte-identically before and after all six fixes — including
`mb86233_core`'s 8,000-retire lockstep at `diverged=0`. That is the third time this
lockstep has been cited as evidence and found not to be: it never generates a `lab` whose
registers are read afterwards, never a transfer into a register its own ALU op reads, and
never a stalling memory. **`diverged=0` from that suite is not evidence about any path it
does not generate.**

`mb86233_agu` is the sharper lesson. Three million cases, `uncovered_modes=0`, and defect 2
walked straight through it — because the suite tests the AGU as a combinational function,
*given r produce ea and x_next*, and the defect is in WHEN the core applies it. Nothing in
the suite has a stalling memory.

### Defect 2 is the FIFO bug again

`agu_post_en` was `(state == S_SRC_W) || ...`, and those states are held while the access
completes. The external reads wait eight and nine cycles — the boot trace has printed
`TGP io 2: R 8010 waited 8` since the beginning — so x0 advanced by 9 and by 7 where the
reference advanced by 1. **Those are the wait counts, not increments**, and they looked
exactly like a wrong `i0`.

The coprocessor FIFO had the identical fault a day earlier: one pop per cycle instead of
one per access. Two instances of one mistake in two modules. **Wherever a held state
drives a side effect, the side effect needs the completion condition, not the state.**

### Fixing a dead path turns its silent consumers into faults

Defect 1 made `lab` write its registers; defect 3 appeared one instruction later in the
same trace, because the B-side addressing had been wrong all along and nothing had ever
read the result. Defect 6 is the same shape again — unreachable until the branch at `0731`
went the right way. That is the fix working, not a regression, and it is worth expecting:
each repair moved the divergence forward rather than resolving it, 38 → 42 → 65 → 90 →
102 → identical.

### What it bought

`make m1_boot`, 1.5 B cycles:

| | before | after |
|---|---|---|
| scroll `[5002]` / `[5006]` | `0000` / `0000` | **`0044` / `2305`** |
| row mask 0x6000 | 0/2048 | **336**/2048 |
| copro sync word cleared | 62 | **14,308** |
| TGP io accesses | — | 596,454 |

`0x2305` is mode 1 on tilemap pair 2/3 — the vertical window split that draws the horizon —
and it is what MAME shows on the same frame. **The row mask has never been non-zero in this
core before.**

### Withdrawn in the making

- *"MAME never executes FED5xx"* — it executes `FED5A4` 41,521 times. The claim came from a
  four-second trace and the routine is first reached at 5.2 s. A window too short to
  contain the event reports "never" exactly as confidently as a real absence.
- *"The TGP is halted"* — `dbg_tgp_retires` counts something narrower than retires. The
  instruction trace showed 3.4 M against the reference's 3.42 M.
- *"`ldi #0x8000, b0` is mis-decoded"* — the decoder was always right; see the entry above.

---

## The window-mode scroll and split are CORRECT — four re-derivations, ruled out — 2026-08-19

The board now moves: with the TGP fixed, the tilemap control words are written and the
horizon scrolls. It scrolls **wrongly** — the sky runs off the top and palette 0 fills the
bottom half — and the obvious suspects are all innocent. Recorded so the next session does
not spend the evening re-reading `segaic24.cpp` as this one did.

**1. `neg_vscr = -ctrl_r` is not a bug**, though it reads like one against the comment
directly above it, which says `v = (-vscr) & 0x1ff`. MAME reads

    hscr = tile_ram[0x5000 + (layer >> 1)]
    vscr = tile_ram[0x5004 + (layer >> 1)]
    ctrl = tile_ram[0x5004 + ((layer >> 1) & 2)]

so `ctrl` and the EVEN map's `vscr` are **the same word** — 0x5004 for pair 0/1, 0x5006 for
pair 2/3. `-ctrl_r` therefore already is `-vscr_even`, which is what the window branch
uses. This was one edit away from being "fixed" into a real defect.

**2. The scroll signs are correct, in both modes.** MAME's non-window path sets its source
origin to `hscr = (-hscr) & 0x1ff`, `vscr = (+vscr) & 0x1ff`, i.e. `map_x = x - hscr` and
`map_y = y + vscr` — which is `m1_tile_decode.sv:97-98` exactly. The window path instead
calls `set_scrollx(0, -(hscr & 0x1ff))` and `set_scrolly(0, vscr & 0x1ff)`. Those look like
the opposite convention and are not: `-(hscr & 0x1ff)` and `(-hscr) & 0x1ff` are equal mod
512, and the tilemap is 512 wide, so `set_scrollx(S)` must mean `source_x = x + S` for the
two paths to agree. Both reduce to `map_x = x - hscr`. **MAME's `src/emu/` is not in the
bootstrap checkout**, so this was settled by requiring the two paths to be consistent
rather than by reading `tilemap.cpp` — worth confirming against upstream if it ever matters
more than it does here.

**3. The window register sources are correct.** `f_hscr`/`f_vscr` take the even map's
registers for both maps of the pair, which is what lines 359-361 and 420-421 do.

**4. The split-line arithmetic is correct.** With the measured `ctrl = 0x2305`: mode is
`(0x2305 >> 13) & 3 = 1`; `v = (-0x2305) & 0x1ff = 251`; bit 9 of `-0x2305` is clear so
`layer ^= 1`. Rows 0-250 draw the ODD map and 251-383 the EVEN one, which is what
`win_swap`/`win_pick` compute.

### So the fault is that one map draws nothing in its own half

The bottom half is palette 0, which is the backdrop showing through where tilemap 2 should
be. That is a layer failing to produce pixels in a region it owns, not a scroll or a split
computed wrongly.

Two things in `draw_common` gate a layer entirely and are worth checking against our
implementation before anything else:

    if(vscr & 0x8000) return;        // whole-layer disable, per layer
    if(layer & 1)     return;        // in window mode the ODD map's own pass draws NOTHING

The second is the one to check hardest: the pair is drawn **entirely by the even layer's
call**, so if our per-layer pipeline lets tilemap 3's own pass run, it draws over the
region tilemap 2 owns rather than leaving it. `docs/HANDOFF.md` records odd-map suppression
as implemented; confirm it covers the *fetch* as well as the *mix*.

**Measure before changing anything.** `manager.machine.video:snapshot()` on a known frame,
against ours on the same frame, plus a per-frame census of `[5000]`-`[5007]`. Four
plausible causes have already been ruled out here by reading, and reading is what produced
three withdrawn findings today.

---

## LOOK AT THE VIDEO. Both maps render correctly; they are never on screen together — 2026-08-19

A phone video of the board, frames extracted with `ffmpeg -vf fps=2` and read directly,
overturned two conclusions reached the same evening from reading `segaic24.cpp` and the
boot dump.

**What the frames show:**

- one frame has **sky, with clouds**; others have **sea, with full wave texture**
- both are *correct artwork* — tile fetch, tile decode, palette and the character ROM path
  all work, which no register dump had established
- they **alternate frame to frame** rather than appearing together
- each frame shows one map over roughly the top 40%, then flat colour bands below with
  razor-sharp horizontal edges at the split lines

**So the fault is that the two maps of a pair are never live at once.** The window split
selects one map for nearly the whole picture and flips which one as `ctrl` changes. The
entry above concluded "tilemap 2 is selected for the bottom half and produces no pixels
there" — it produces excellent pixels, and that conclusion is withdrawn.

### The instrument was sitting unopened for hours

`docs/2d-gap-analysis.md` lists `manager.machine.video:snapshot()` for exactly this, and
the user had already said the sea and sky were "jumping up and down". Five candidate causes
were ruled out by reading source in the time it would have taken to extract eight frames.
**A photograph or a video of the board is a measurement, and `ffmpeg` + the Read tool make
it a cheap one** — `ffmpeg -v error -i clip.mp4 -vf "fps=2,scale=640:-1" -frames:v 8
out%02d.png` and read the PNGs.

This is the same lesson already recorded as "when a measurement says never, check the
instrument could have seen it", in a new costume: a register census cannot tell correct
artwork from a blank layer, and only the picture can.

### Where to start

Why is only ever ONE map of the pair live? `win_suppress` is
`win_mode && win_vsplit && (cur_layer[0] != win_pick)`, and `win_pick` flips at
`cur_line == win_v`. Confirm on real scanlines that both parities clear the suppression
within one frame — if `win_v` lands at 0 or beyond 383, one map wins everywhere, and the
alternation is then `win_swap` toggling with `ctrl`.

### The blue band appears DURING the jump, and that rules out the suppression logic

Observed on the board, 2026-08-19: sea and sky are both on screen together with no blue
band; then the picture jumps up, a blue band appears; then it keeps jumping up and down,
and when both maps show again the band is gone.

**A gap means scanlines where NEITHER map paints.** `win_suppress` is

    win_mode && win_vsplit && (cur_layer[0] != win_pick)

and `win_pick` is a single bit per scanline, so exactly one parity is live on every line by
construction. **This logic cannot open a gap.** Two candidates remain:

1. the two layers' passes compute `win_pick` from **different values** — `ctrl_r`,
   `win_v` or `cur_line` not identical between the even and odd pass of the same frame,
   which would let both suppress on the same line. `ctrl_r` is refetched per layer from
   the same address, so a mid-frame write to `0x5006` between the two passes would do it,
   and the game writes that word every frame.
2. the map that owns those lines is scrolled onto **empty rows of its own tilemap**, so it
   paints transparent and the backdrop shows. That is a vertical-scroll or wrap fault, not
   a suppression fault.

Candidate 1 is the one to test first, and it is cheap: latch `ctrl_r`/`win_v` once per
FRAME rather than per layer pass and see whether the band closes. MAME reads the register
once, at the top of `draw_common`, for a call that draws both maps — our per-layer pipeline
reads it twice, and nothing guarantees the two reads agree.

### MEASURED: the video logic is innocent — we write the WRONG scroll values

`tools/mame_scroll_census`-style Lua on the reference, frames 280-292:

    frame  280  5000..5007 = 0000 0000 0025 0000 0000 0000 2062 0000
    frame  282  ...                    0025 ...                2061 ...
    frame  292  ...                    0025 ...                205c ...

against ours from `make m1_boot`:

    [5000]=0000 [5001]=0000 [5002]=0044 [5003]=0000
    [5004]=0000 [5005]=0000 [5006]=2305 [5007]=0000

**`[5006]` is 0x2062 in the reference and 0x2305 here, and that one word explains the
whole picture.** Work it through `draw_common`:

    reference   v = (-0x2062) & 0x1ff = 414   > 383, so the split is BELOW the screen:
                c1 keeps rows 0..383, c2.min_y becomes 414 and is EMPTY
                bit 9 of -0x2062 is SET, so no swap
                -> ONE tilemap fills the whole screen, vertical scroll 0x2062 & 0x1ff = 98

    ours        v = (-0x2305) & 0x1ff = 251   mid-screen, so the screen SPLITS
                bit 9 of -0x2305 is clear, so the maps SWAP
                -> tilemap 3 on top, tilemap 2 below, and the boundary jumps as ctrl moves

The reference's horizon drifts smoothly because `[5006]` decrements by one every two
frames, 0x2062 -> 0x205c. Sky and sea are BOTH IN ONE TILEMAP; there is no split at all at
this point in attract. Ours splits the screen and alternates the maps, which is exactly the
banding filmed on the board.

`[5002]` differs too: 0x0025 against 0x0044.

**So the window-mode implementation is not the bug.** Five suspects were ruled out by
reading and a sixth by arithmetic; the values feeding them are wrong. This is upstream
program state — what the V60 computes from the coprocessor's results — and no further
tilemap work will move it.

**Where to go:** `tgp_wrtrace` is identical for the 110 writes our side produces and then
stops because our side stops producing. Extend the window until it diverges again, or trace
the V60's writes to 0x70A00C (word 0x5006) and diff against MAME's writes to the same
address. The second is the more direct instrument and `install_write_tap` on the maincpu
program space is what does it.

### The scroll word is `mode | (scroll & 0x3ff)`, and only the scroll half is wrong

`install_write_tap` on 0x70a00c in the reference: the word is written twice a frame, from
`FFE466` and `FFE27A`, creeping 0x2064 -> 0x205d over the frames sampled. `FFE466`'s
producer:

    FFE44B: mov.h R28, R27
    FFE44E: add.h 50141A, R28      R28 += work RAM
    FFE455: shl.h #FF, R28         >> 1
    FFE459: and.h #E000, R27       keep the mode bits
    FFE45E: and.h #3FF, R28        keep TEN bits of scroll
    FFE463: or.h  R27, R28
    FFE466: mov.h R28, 70A00C

So `[5006] = mode | (scroll & 0x3ff)`.

    reference   0x2062   mode 0x2000, scroll 0x062 = 98
    ours        0x2305   mode 0x2000, scroll 0x305 = 773

**The mode half is correct on both.** Only the scroll value differs, and it comes from work
RAM at 0x50141A and 0x50140E — which is downstream of the coprocessor's geometry, not of
anything in the video path.

Note the field is masked to **0x3ff, ten bits**, while `draw_common` masks vscr to 0x1ff.
Bit 9 therefore survives into the register and is what selects the map swap, so a scroll
value that is merely too large does not just shift the picture — it flips which map is on
top and moves the split into the visible area. That is why one wrong number produces
banding rather than a displaced horizon.

### The 60,000-write comparison: divergence at 4122, reading the command FIFO

Both write caps were 4,000 — `mame_tgp_wrtrace.lua` and `tb_m1_boot`'s `tw_n` — so
"IDENTICAL for 4000 writes" meant "identical for as far as either instrument looked".
Raised to 60,000 on both sides with a 16-second reference window:

    tgp_wrtrace: DIVERGES at write 4122

and the divergence is that **we write zeros where the reference writes geometry**:

    0436: ldi #0x100, x0
    0437: ldi #0x120, x1
    0438: rep #0xc
    0439: mov (x0), (x1+1)+0x200      12 words, (x0) with x0 = 0x100

`0x100` is the **command FIFO** (`copro_fifo_in`, model1_m.cpp:129), so this copies the
V60's twelve-word command block into data RAM at 0x320. The reference gets
`c34e5382, 41f15c2c, 408ac7be, ...`; we get twelve zeros.

**The V60's command stream is correct where it has been checked.** A program-space write tap
on 0xd80000 in the reference gives, assembled from 16-bit halves,

    0400_0000  0100_0000  3f40_0000  428c_0000  0100_0000  3f40_0000  428c_0000

and `make m1_boot` prints exactly that sequence. So the early commands agree and the
divergence at write 4122 is later in the stream — either the V60 stops sending, sends
different data, or our FIFO returns zero where the reference's would stall.

**That last one is worth checking first.** MAME's FIFOs are a mutual interlock: reading an
empty input FIFO stalls the coprocessor. If our data-space route for 0x100-0x1ff ever
completes a read instead of stalling, an empty FIFO reads as twelve zeros and the
coprocessor carries on with them — which is precisely the symptom. `m1_tgp`'s `io_ack`
has an unqualified final `else` that acknowledges anything unmapped, and a
mis-decode into that arm would ack immediately with `io_rdata = 0`.

### The V60's command stream is CORRECT — it just never stops

`tools/mame_copro_push.lua` dumps the V60 -> TGP command stream as 32-bit words for diffing
against `tb_m1_boot`'s `COPRO PUSH` lines. Over a 900-frame reference window:

    command streams IDENTICAL for 61 commands
    reference total: 61      ours total: 65535 (our counter saturates)

**Every command the reference sends, we send, in the same order, with the same values.** We
then send tens of thousands more. The reference issues 61 commands in fifteen seconds and
stops; ours never stops.

That reframes the remaining defect completely. It is not that the V60 computes the wrong
geometry — the geometry is right. It is that our V60 keeps re-issuing work the reference
issues once, which is consistent with it ending in the `FED5A4` poll and something
re-triggering the send. The twelve zeros at TGP write 4122 then follow naturally: by that
point the two machines are in different places in the program, and comparing write 4122 of
one against write 4122 of the other stopped being meaningful several thousand writes
earlier.

**Instrument note.** The V60 writes the FIFO through PROGRAM space while reading it through
IO — `in.w` only appears in `AS_IO`. A write tap on the IO space returns nothing while
looking exactly like a working instrument, which is the same trap as the program-space read
census that concluded the V60 never touches the coprocessor. Tap the space that matches the
DIRECTION.

**Next:** `make v60_trace` with `tools/v60_resync.py`, now that the coprocessor returns
correct results. The earlier run found only interrupt-phase slips over 100,000 instructions
because the TGP was feeding it wrong data; with the data right, a structural divergence
should be visible and will say why the V60 loops.

### v60_trace after the TGP work: zero divergence sites

Re-run with `tools/v60_resync.py` now that the coprocessor returns correct results:

    --- compared 25685/1654754 reference and 25685/25685 our instructions
    --- IDENTICAL over the whole compared range

This afternoon the same instrument reported **304 divergence sites** over 100,000
instructions. Now there are none, and 52 collapsed loops are in common with **51 running
identical counts**. The single exception is the documented one:

    at 24804   fe022c,fe0232   MAME 36308   ours 41147   (+13.3%)

the I/O board handshake, 18 CPU cycles an iteration against the reference's 17, on a
deadline correct in cycles to within 38. Known, measured, benign.

**The window is the limit, not the agreement.** 700 M cycles reaches 25,685 collapsed
instructions while the boot runs to 1.5 B, so whatever makes us re-issue commands lies
beyond what was compared. Run `v60_trace` at `CYCLES=1500000000` with a 16-second reference
to reach it.

Note the collapsed count went *down* as the window grew earlier in the day — 50,923 at
200 M cycles against 25,685 at 700 M. That is not a contradiction: the collapse keeps one
instance of each repeating period, so a machine spending more of its time in loops yields
*fewer* collapsed lines. It is itself a signal that our core is looping more than the
reference beyond the compared window.

### The text routine RUNS on our side — it copies different strings

`v60_trace` at `CYCLES=1500000000` reports `IDENTICAL for 25685 instructions` and
`v60_resync` finds zero divergence sites, but our side yields **25,685 collapsed
instructions at both 700 M and 1.5 B cycles** while the reference reaches 5,193,988. The
agreement is real and the window is the whole story.

**The collapse hides a loop that only one side has.** `v60_trace` collapses both streams to
one instance per repeating period, so a loop present in ours and absent in MAME leaves the
PC sequences identical and is reported only in the counts file — and only if BOTH sides
collapsed it, since the comparison is over loops "in common". That is a blind spot in the
instrument, not in the design.

The counts file is where the difference lives:

    ours   ff8ac3,ff8ac6,ff8ac8,ff8aca,ff8acd   counts 6, 7, 8, 9, 10, 13, 14 ...
    MAME   ff8ac3,ff8ac6,ff8ac8,ff8aca,ff8acd   count  20, consistently

and that loop is:

    FF8AC3: mov.b  [R0+], R2      load a byte
    FF8AC6: test.b R2
    FF8AC8: be     FF8ACF         stop at the NUL
    FF8ACA: mov.h  R2, [R1+]      store it as a HALFWORD
    FF8ACD: br     FF8AC3

**A null-terminated string being written out as 16-bit tile codes: this is the text
routine.** It executes on our side, repeatedly, and copies six to fourteen characters where
the reference copies twenty.

So text IS being generated. The strings differ in length, which means either the source
pointer differs or the string content does — and the strings on this screen are built in
RAM (`CREDIT 0`, the ranking table) rather than read straight from ROM.

**Next:** capture R0, R1 and the copied bytes on both sides at FF8AC3. A write tap on the
destination range plus the same in `tb_m1_boot` gives the two strings side by side, and the
lengths alone (20 against 6-14) should identify which string each side thinks it is
drawing.

## SPEED: 35.0 -> 23.7 cycles per instruction, and where the rest goes — 2026-08-20

The core ran about **2.3x slower than the reference**. That is slow motion on the board, and
it also made every frame-indexed comparison against MAME meaningless — most of the "our
`[5006]` is 0x2305 against MAME's 0x209b" confusion came from comparing frame N of a machine
running at half speed against frame N of one running at full speed.

### The instruction cache, measured before it was built

Modelling the reference's own 31-million-PC trace offline, for an 8-byte line:

    1 line  (   8 B)  32.1% hit      2 lines (  16 B)  99.0% hit
    4 lines (  32 B)  99.2% hit      8 lines (  64 B)  99.6% hit

One line thrashes because the V60 alternates between two — an instruction straddling a
boundary fetches N and N+1 in turn — so 32% is the floor. Built 8 lines, direct-mapped.

    instructions        10,716,101  ->  15,838,344
    cycles/instruction       34.99  ->       23.67
    ifetch lines        13,810,468  ->   3,472,976   (-75%)
    fetch-stalled              34%  ->         13%

The real hit rate is 75%, not 99%: the model had one PC per instruction while the core
issues several fetch requests per instruction. The prediction still earned its keep — it is
what said two lines would work and one would not.

### Where the remaining time goes, measured

Per-page data-bus latency, from `m_req` rising to `m_ack`:

    100000  n=118940  avg=36        200000  n=32768  avg=36
    110000  n=83563   avg=36        210000  n=32768  avg=36
    120000  n=131064  avg=36        ...every page identical...

**Every page costs the same 36 fast cycles — 9 CPU cycles — whether it is BRAM or SDRAM.**
That is not memory latency; it is fixed handshake overhead, and it is why the page histogram
was useless for this question: 4.3 M cheap accesses and 1 M expensive ones look identical in
a count.

The 9 decomposes exactly:

    T0  adapter I_CYC asserts m_req
    T1  m1_main B_IDLE sees it, goes B_LOCAL
    T2  BRAM data valid, ack_r set, goes B_ACK
    T3  adapter sees ack, drops m_req, advances
    T4  m1_main sees req low, returns to B_IDLE      = 4 cycles per 16-bit cycle

and `v60_bus` splits a 32-bit access into **two** 16-bit cycles (three if unaligned), so
2 x 4 + entry = 9.

### What it would take to reach real time

At 25 MHz the target is ~12.5 cycles/instruction to match the reference's ~2 M
instructions/second. We are at 23.67, of which 54% is stall (41% data, 13% fetch). **Pure
execution is already ~11 cycles/instruction**, so removing the stalls entirely would reach
real time — the CPU core itself is fast enough.

Two levers, both real work:

1. **Shorten the handshake**, 4 cycles to 3, by letting `m1_main` accept a new request in
   the cycle it acknowledges. Risk: the "acknowledges must be held, not pulsed" rule exists
   because the requester is `ce`-gated. `ce_cpu` is tied high today, so the rule is
   currently slack — but it is slack, not gone.
2. **A 32-bit local data path**, halving the bus cycles per access. Bigger change:
   `v60_bus`, `m1_main`'s routing and the memories' ports.

Together those are roughly 2x and would land the core at real time. Neither should be done
in a hurry: the bus is the one thing in this core that every other block depends on.

### The V60 is NOT the bottleneck — a retire-to-retire histogram says so

Asked whether splitting the V60 would cut CPI the way splitting the i960 did on Model 2
(9 -> 3.4). Measured instead of judged, 9.6 M instructions:

     3 cycles   654,431   6%     <- I-cache hit, no data access: THE FLOOR
     7-8        602,853   6%
    10        1,883,483  19%
    12        2,101,037  21%     <- 3 + 9, one data access
    26        1,875,743  19%     <- 3 + two accesses
    35          514,236   5%
    mean 18.4   median 12

**The V60 retires in 3 cycles when it hits the instruction cache and touches no data.**
Every cluster above that is the 3-cycle base plus multiples of the ~9-cycle bus access.
Splitting the core would attack the 3, which is already small, and leave the 9s untouched.

**This corrects the entry above.** "Execution-only CPI is ~10.9" was computed as
`(1 - stall%) x 23.67` and is wrong: the stall counters do not capture all of the memory
wait. The histogram is the better instrument, and the conclusion drawn from 10.9 — that the
bus alone could not reach real time — does not hold.

Take the access from 9 cycles to ~4 and the 12-cluster becomes 7, the 26-cluster ~11, and
the mean lands near 9-10 against a 12.5 target. **The bus is the whole problem.**

Keep the V60 split on the roadmap for area or Fmax if it earns its place there; do not
spend it on throughput on this evidence.

## SDRAM IS VERIFIED, and the copro RAM initialiser was the FED5A4 deadlock — 2026-08-20

### The deadlock: nothing ever writes the sync word

The V60 spins at `FED5A4` reading coprocessor RAM word 0 until its **low byte is zero**.
Hours went into "why does the coprocessor never clear it". **It never clears it in
simulation either** — `tb_m1_frame` reports `TGP writes to copro RAM=0` — and simulation
works because the array's initialiser makes word 0 zero to begin with. MAME does the same
thing explicitly: `model1_m.cpp:59` ends `device_reset` with
`memset(m_copro_ram_data, 0, 0x2000*4)`.

**There was never a signal to write.** Every reading of this as "the coprocessor fails to
signal completion" was backwards.

**And the board lost that initialisation the same morning, self-inflicted.** Quartus caps a
loop at 5,000 iterations, so when the RAM initialisers broke synthesis they were wrapped in
`` `ifdef VERILATOR ``. That kept the simulator working and silently removed the
initialisation from the DEVICE, so word 0 came up `ffff` and the V60 waited for ever.

The fix is **chunking, not guarding**: two loops of 4,096 are each under the cap and
initialise the inferred M10K exactly as one loop of 8,192 would. A clear-at-reset FSM was
tried first and reverted — gating accesses for 8,192 cycles broke `m1_copro_if`'s suite,
156 of 259 checks.

Result on the board: the V60 **leaves** `FED5A4` and reaches the tilemap copy routines, and
the sync word reaches `000`. Tilemap 0 still holds 4,096 **spaces** and no characters, so
the drawing path runs and produces blanks — that is the next question.

### SDRAM: verified across the whole image

Rows 07/0B fold at the **ioctl input**, before the FIFO, so they say the HPS delivered the
right bytes and nothing about what reached the chip. The read-back sweep on the spare port 4
closes that:

    row 0E   4D2E75   matches the image exactly, 1,081,344 words across all 8.6 M
    row 0C   000000   correct: port 4 is a SINGLE-WORD port, there is no high half

**Memory is not the fault.** Correct data in, correct data out.

Checked and ruled out alongside, from the kaneko port's findings: the **A10 auto-precharge**
fault does not apply — our `S_RD` drives A10 low on every read including single-word ones
and precharges explicitly — and `COL_BITS=9` on a 64 MB module addresses half of each row
self-consistently, which is why write-then-read matches.

### FOUR instrument faults in one day, every one caught by a control

1. The sweep's address was wired into `tb_m1_frame` and **never into `Model1.sv`**, so port
   4 read word 0 for all 8,192 bursts. Caught because a control region returned the
   *identical* checksum to the region under test — impossible for real data.
2. The sweep was clocked on `clk_cpu` while the SDRAM ports are `clk_sys`, and completed
   **one burst of 4,096** while producing a plausible-looking number. Caught by adding a
   burst COUNT.
3. Expected values were computed for a 4-word burst on a port that `blen()` gives **one**
   word. Caught because the "high half" read zero on both sides.
4. `pgrep -f quartus` matched a watcher belonging to a *different project*, and
   `pgrep -f "compile Model1"` matched the shell running that very string — reporting a
   build as running for 82 minutes after it finished. **The honest test is whether the log
   file is still growing.**

**The rule that follows:** every new instrument ships with a known-good case measured in
the same run. Three of these four produced confident, specific, wrong answers that survived
until a control contradicted them.

### Characters are WRITTEN on hardware, and none is ever VISIBLE

Measured on the board with the character-write census:

    row 0E  000315 and RISING with every jump   789 real characters and climbing
    row 0C  FC567D                              the same routine simulation uses

So the V60 reaches the drawing code, runs the same routine, and writes real characters into
tilemap 0.

**NO TEXT IS VISIBLE ON THE SCREEN AT ANY POINT.** Those are two different claims and
conflating them was wrong: "the text is drawn" was written here when what is measured is
that characters reach tile RAM. What the board shows is sky and sea for a split second, then
a jump with a blue bar across the bottom third, repeating. The renderer finds eight
non-blank words a frame, so whatever is written is not there when it looks.

That matches the PC: row 00 alternates between `FED5A4` (waiting on the coprocessor sync
word) and `FFE???` (the tilemap copy routines). Clear, draw, wait, clear, draw.

**The divergence to chase is row 0D.** On the board the coprocessor writes coprocessor RAM
thousands of times — the counter saturates at `FFF` — while `tb_m1_frame` reports
`TGP writes to copro RAM=0`. Something on hardware keeps re-arming the sync word to `ffff`,
which sends the V60 back to `FED5A4`, and the cycle repeats for ever.

Since the microcode is verified identical (row 02 matches the image byte for byte) and SDRAM
is verified across the whole image, the coprocessor is executing a different path from the
same code and the same data. Row 06's read checksum differs between board and model, which
says the same thing: it is issuing different reads. What is left that could differ is its
INPUTS — the command stream from the V60 — or the relative timing of the two machines,
which is not the same on silicon as against a memory model.

### At depth, board and simulation agree on everything but ONE number

`tb_m1_frame` at 1.5 B cycles against the board:

    non-zero row-mask writes   4095 saturated   |  FFF saturated      agree
    tilemap0 character writes  1680 from fc567d |  1155 and rising    agree
    TGP writes to copro RAM    4095 saturated   |  FFF saturated      agree
    copro SDRAM read checksum  bd686d           |  1e0da5             DIFFER

**Two more inferences withdrawn**, both from samples taken before the machines had got
there:

- *"The row mask is never populated on hardware"* — it saturates on both.
- *"The coprocessor writes copro RAM on hardware and never in simulation"* — that was a
  400 M-cycle sample. At 1.5 B it saturates on both, so there is no divergence in that
  behaviour and nothing is "re-arming" the sync word that does not also do so in
  simulation.

That is the fourth and fifth claim retired today for the same reason: **a counter read
before the machine reaches the code is indistinguishable from a counter that never moves.**
Every one of them looked like a specific, actionable difference.

**One measured difference remains:** row 06, the fold of the coprocessor's first 1024 SDRAM
reads. SDRAM itself is verified whole-image, and the microcode is verified byte-identical,
so the coprocessor is reading *different addresses* — not different data. What can still
differ is the order and timing of those reads, which is the one thing a memory model does
not reproduce.

**And the visible difference:** simulation renders the attract screen; the board clears,
draws, and jumps. With the text and the mask both written on hardware and the renderer
finding blanks, the viewport is landing on empty rows of the map — the scroll word is
rewritten every pass of the V60's loop instead of settling.

## SETTLED: the V60's FP group must stay — but the evidence is a RESERVED opcode — 2026-08-23

`CLAUDE.md` carried this as an unspent lever: "the V60 without its FP group is -2,984 ALM on
the full core. `dbg_fp_trap` has never fired, but only through boot and attract, and it is
inert by construction in a build that has FP — so that is not yet evidence."

**Measured, standalone, Quartus 17.0:**

    V60 with FP     20,614 ALM   Fmax 24.92 MHz
    V60 without FP  18,672 ALM   Fmax 45.98 MHz

So the group is 1,942 ALM — not the 2,984 recorded, which was a full-core figure — **and it
halves the Fmax**. It is on the critical path as well as being 6% of the core, which makes
it a bigger prize than the ALM alone suggested.

**And the run under the define says it cannot go:**

    V60: reserved FP opcode 5f at 00fed52b
    BOOT: *** FP opcode executed — S32_V60_NO_FP is NOT safe ***

**READ THAT CAREFULLY BEFORE CONCLUDING THE GAME USES FLOATING POINT.** It is a *reserved*
opcode, at `FED52B` — inside the `FED5xx` page that **MAME never executes a single
instruction in**, measured with a 4-second reference trace on cold nvram. So what this
proves is that our V60 reaches a region the reference never reaches and executes data as
code there; the FP decoder catching it is incidental.

Two things follow:

1. **The lever stays unspent.** Removing the group would turn that into a different wrong
   behaviour rather than a correct one, and 1,942 ALM is not worth a build that traps on a
   path the machine should not be on.
2. **It is another instrument pointing at `FED5xx`.** The V60 spinning there was read all
   week as a legitimate poll on the coprocessor sync word. A reserved opcode inside the same
   page is hard to square with that, and worth following.

## V60 area and speed: what each knob is actually worth — 2026-08-23

Every figure below is Quartus 17.0 on the V60 alone, and `make m1_boot` at 400 M cycles for
the CPI. Standalone ALM runs higher than in-core (20,129 against 17,817) because the fitter
cannot optimise across the boundary; the DELTAS are the usable part.

| build | ALM | Fmax | mean CPI |
|---|---|---|---|
| baseline (shift 4, loop cache) | **20,129** | | **14.9** |
| realign shift 8 | 20,614 (+485) | | 14.6 (-2%) |
| no loop cache | 19,962 (-167) | | 15.5 (+4%) |
| no FP group | 18,672 (-1,942) | 45.98 MHz vs 24.92 | — (unsafe) |

**Conclusions, and two of them go against the change that produced them:**

- **The realign widening is reverted.** 485 ALM for 1.7% is the wrong trade with the core at
  72% of the device and a rasterizer still to fit.
- **The loop cache stays.** Removing it saves 167 ALM and costs 4% - the worst ratio of the
  three.
- **The FP group stays**, and not for its cost: a run under `S32_V60_NO_FP` executes a
  *reserved* FP opcode at `FED52B`, in a page MAME never enters. See the entry above.

### Where the V60's cycles go, measured

A state census over 100 M CPU cycles, counting CE cycles per FSM state:

    S_FILL            33%   never touches the data bus
      of which:  shifting 1.0/instr, dispatch 1.0/instr, STARVED-ALIGNED 3.3/instr
    S_OP2_LD          20%   almost entirely genuine memory wait
    S_DECODE..S_NEXT  28%   pure FSM stepping, all bus-free
    S_WB_MEM/S_EA_VAL 12%   memory wait

**The starved-aligned bucket is where the win was**, and answering instruction-cache hits
combinationally took mean CPI from 17.6 to 14.6 - the cache already hit 99% of the time, and
the handshake was costing ~2.5 CPU cycles on data sitting in a register array.

### What is NOT the area hog, so nobody re-derives it

- **The register file.** 105 references to `r[]`, but 52 are `r[31]` and nearly all the rest
  are constant indices - only four are variable. Constant reads are free.
- **Replicated adders** are real - 128 distinct `Add*` nodes - but sharing them means
  restructuring a 4,601-line FSM, and the PC alone has 19 increment sites with different
  deltas.
- **`fb32(o)`/`fb16(o)`** expand to four and two 24:1 byte muxes each, and
  `fb32(ea_ofs+1)` appears at five call sites in different always blocks. Naming them as
  shared wires **broke `tb_v60_search`** and was reverted. Worth retrying only after
  understanding why, rather than assuming Quartus was not already sharing them.

### Aggressive Area on the full core: DO NOT — it trades the binding resource

The V60 alone drops 2,631 ALM under `OPTIMIZATION_MODE "Aggressive Area"` +
`OPTIMIZATION_TECHNIQUE AREA`, 20,129 -> 17,498, for 3.5% of Fmax. On the full core it does
not transfer:

    default (HIGH PERFORMANCE EFFORT / SPEED)   30,206 ALM   452 M10K   +0.331 ns
    Aggressive Area / AREA                      29,611 ALM   463 M10K   +0.024 ns
                                                  -595        +11

**595 ALM, +11 M10K, and almost no setup slack.** M10K is the binding resource here - 82%
before this, 84% after, with the rasterizer's band buffer wanting ~51 blocks - so it spends
the scarce resource to save the plentiful one. And +0.024 ns is one unlucky fit from a
failing build.

The knob stays available as `M1_QOPT="Aggressive Area" make rbf` with this measurement
beside it, and the default is unchanged.

**REVERSED SINCE, and the reversal is the current state.** The design later
failed to fit at all (166,497 combinational nodes against 83,820), so ALM
became the binding resource and `tools/mister_project.sh` made Aggressive
Area with register and logic duplication OFF the default; `M1_QSPEED=1` is
the opt-out. Every build from the 2:1 coprocessor onward, including the
2026-09-03 known-good, is an aggressive-area build, and its ~1,500 ALM is
already inside the 39,150 ALM figure. Do not read the verdict above as
current; read it as the measurement of what the setting costs in slack.

**The general lesson, which cost two 25-minute builds to learn twice:** a module measured
alone with virtual pins is not the module in context. The V60 reports 20,129 ALM standalone
and 17,817 in the core; the area setting saves 13% standalone and 2% in place. Standalone
numbers are for comparing two versions of the same block, never for predicting what a change
does to the design.

### CORRECTION: the 485 ALM was standalone; in the core it is 46

The realign shift was reverted from 8 bytes to 4 on a standalone measurement of 485 ALM.
Rebuilt in the full core:

    shift 8   17,771 -> 17,817 ALM   +0.331 ns slack
    shift 4                17,771    +0.639 ns

**Forty-six ALM, inside fit-to-fit noise**, against 2% of CPU speed. The area justification
was wrong.

The revert stands, for a reason that was not measured at the time: **the 9:1 mux is on the
critical path**, and 0.3 ns of slack on a design that has been down to +0.024 ns is worth
more than 2% of the CPU. But the number in the commit message was misleading, and this is
the third time in two days a standalone figure has pointed the wrong way:

- the V60 measures 20,129 ALM alone and 17,771 in place
- Aggressive Area saves 2,631 alone and 595 in the core, while costing 11 M10K
- this shift saves 485 alone and 46 in place

**Rule: never justify a change with a standalone area number.** Use standalone only to rank
two versions of the same block, and confirm anything that matters with a full build.

### Which V60 instruction groups the game never touches — and why NOT to cut them

A state census over 200 M CPU cycles and 10.7 M instructions of boot and attract. States
never entered once, mapped back through the enum:

    18-24    XCH, ROTC, MOVD (64-bit moves)
    48-52    decimal arithmetic, the whole S_DEC_* group
    58-71    bit-field insert and every bit-string op, S_BF_INS*/S_BS_*
    83-88    task switching, S_TASK_*/S_TASI*
    89-90    PREPARE / DISPOSE

That is a large amount of datapath in a CPU that is **17,771 ALM of a 30,227-ALM core**,
with the rasterizer (~4-6 k ALM) and the whole sound board (~8-9 k) still to fit into 11,683
free. Gating the unused groups is the obvious way to close that gap.

**Do not do it on this evidence.** Attract mode exercises a narrow slice of a game. A
compiler emits PREPARE/DISPOSE around stack frames and MOVD for 64-bit moves, and those can
appear the moment a race starts; the census proves only that thirty seconds of attract does
not reach them.

**The distinction that matters:** restructuring the V60 is OPTIMISATION - identical
behaviour, and `v60_trace`/`v60_resync` report zero divergence sites against MAME, so it is
provable. Gating a group REMOVES CAPABILITY and cannot be proven by any amount of testing,
only disproven.

**If it is spent anyway, spend it the way the FP group is spent:** gate the group out AND
trap its opcodes, so a wrong path raises a visible flag instead of silently computing
nonsense. That is exactly how the FP group was settled - the trap fired at `FED52B`, and the
lever stayed unspent. Drive the game through a full race first.

### Expression sharing in the V60 is worth 25 ALM — the area is structural

`r[31] - 4` appears at eleven separate `dbus_addr` sites and `r[31] + 4` at more, spread
through a 90-state case. Naming them as shared wires:

    baseline          20,129 ALM   (standalone)
    shared sp_m4/p4   20,104 ALM   -25

**Quartus was already sharing them**, and that is the useful result. Taken with the earlier
findings - 128 distinct `Add*` nodes, a register file that is almost entirely
constant-indexed, and `Aggressive Area` saving only 2% in context - the conclusion is that
**the V60's 17,771 ALM is not duplicated logic that a refactor can fold together.**

**This also means splitting it into modules will not, by itself, save area.** Quartus
flattens hierarchy to optimise across it; drawing boundaries buys VISIBILITY and can cost
area by blocking cross-boundary sharing. The split is still worth doing for what it reveals
and for the pipelining it enables - but it should not be sold as an area fix on its own.

**What would actually reduce it** is a different implementation, not a reorganisation of
this one: the cost is the control-to-datapath mux network of a ~90-state machine in which
each state drives wide registers directly. A microcoded or pipelined V60 replaces that with a
narrow control word and one shared datapath. That is a reimplementation measured in weeks,
against a CPU that currently matches MAME instruction-for-instruction with zero divergence
sites.

**So the M4 budget gap should be closed from the other end first.** ~2-4 k ALM short, and
the sound board is the unbuilt part: a smaller 68000 core than fx68k, or one MultiPCM
time-multiplexed across both channels rather than two instances, are both cheaper and less
risky than reimplementing a working CPU.

### Fitter SEED is worth more slack than the RTL change cost — 2026-08-23

From the Kaneko16 core: *"SEED 1 to SEED 3 closed it: -0.084 to +0.344, with the same logic
and the same memory"*, and the diagnostic that matters — *"the build immediately before it
had MORE logic, 12,401 ALMs against 12,018, and closed at zero, which is what identifies
placement rather than capacity as the cause."*

That is our shape. Splitting `v60_ifetch` out took the core from 30,227 ALM at +0.639 ns to
29,992 at +0.143, and the slack drop looked like the price of the split. It was not:

    same split RTL, seed default   29,992 ALM   +0.143 ns
    same split RTL, seed 3         30,071 ALM   +0.379 ns

**0.24 ns of slack from the seed alone, on identical logic.** So a marginal timing result
after an RTL change should be re-fitted before the RTL is blamed - changing code that is not
on the failing path is the wrong lever, and it is how a real area saving gets reverted for
no reason.

`M1_SEED=<n> make rbf` pins it. Note the template's last line has no trailing newline, so
the assignment must be appended with a leading `\n` or Quartus rejects the whole file - one
wasted build.

### PREREQUISITE for a faster SDRAM clock: the ROM loader must not move with it

Raised from the Kaneko16 core, where splitting the memory clock to 96 MHz broke **every
game at once** on a build that **closed timing at +0.502 ns**:

> `kaneko_rom_loader` was clocked from `clk_sdram`. That was invisible while `clk_sdram` and
> `clk_sys` were the same net; doubling the memory clock made it wrong twice over: every
> input it takes comes from `hps_io` on `clk_sys` - so it became an unsynchronised crossing -
> and it drives the SLOW port while being clocked FAST, so `ACK_HOLD`'s two-cycle
> acknowledge, exactly one edge for a 48 MHz requester, was two edges for it. **Every ROM
> write counted twice and the image loaded corrupt.**

**Model 1 is correct today and only by accident of having one domain:**

    hps_io          .clk_sys(clk_sys)    80 MHz
    m1_rom_loader   .clk(clk_sys)        80 MHz
    m1_sdram        clk_sys              80 MHz

Our controller has the same `ACK_HOLD = 2`, so both halves of that bug are latent here. If
the memory clock is raised - and 96 MHz is +20% of bandwidth against a core that spends 20%
of its cycles starved for instruction bytes - then:

1. **Keep `m1_rom_loader` on `clk_sys`**, where its `ioctl_*` inputs already are, and let an
   adapter do the crossing.
2. **Re-check every requester against `ACK_HOLD`.** A held acknowledge counted in the fast
   domain is a different number of edges for a slow master.
3. **Recompute `T_REFI`.** It is in clock cycles and tuned for 80 MHz; `Model1.sv:364` already
   records that at 100 MHz it under-refreshes, which is a data-retention fault that would
   present as random corruption.

**And the line worth keeping from that entry:** *"the broken build CLOSED TIMING. Static
analysis says the paths are met, not that the design is right, and the guard cannot see a
module wired to the wrong clock."*

### The register file CANNOT be extracted as-is: rf_we* are blocking temporaries

Second extraction attempted after `v60_ifetch` succeeded, and reverted. It failed
`tb_v60_audit`, `tb_v60_search` and `tb_v60_cmpc` with wrong register values, and the reason
is structural rather than a wiring slip.

Every architectural update is funnelled through two masked ports, which looks like a clean
boundary:

    rf_we0 = 1'b0;              // cleared at the top of the FSM's always block
    ...
    rf_we0 = 1'b1;              // set by queue_reg_write, BLOCKING, inside a task
    ...
    if (rf_we0 && rf_wmask0[b]) r[waddr0][b] <= wdata0[b];   // consumed in the SAME block

**They are intra-block temporaries, not registers.** The write decode at the end of the
always block sees the value the tasks set during that same evaluation. Move the decode into
a submodule and it samples them at the clock edge instead - which is the value left over from
the PREVIOUS cycle. Most instructions still pass; the ones that queue two writes, or write
then immediately read, do not.

**So the boundary is real but the signalling is not.** Extracting the register file needs
`rf_we*`/`rf_waddr*`/`rf_wdata*`/`rf_wmask*` produced by an `always_comb` first, so they are
genuine combinational outputs of the FSM rather than scratch variables. That is a change to
how every write is queued, and it should be made and verified on its own before any
extraction depends on it.

**General rule for the remaining splits:** a signal set with `=` inside a clocked block and
consumed later in that same block is not an interface, however much it looks like one. Check
the assignment operator before drawing the boundary.

## The scroll latch FIXED the picture; the coprocessor now blocks the V60 — 2026-08-23

**The jumping is gone.** Latching the scroll and control words once per frame at vblank
begin - where `screen_device::vblank_begin` renders and where `draw_common` reads them -
gives a stable horizon on hardware: sky above, sea below, layer 2 winning `02E800` = 190,464
pixels, the whole visible area. That was the fault behind "sea and sky jumping up and down
and off the top of the screen", and it came from the Kaneko16 core's identical finding.

**And the core is now hung, on one fault with a clear chain:**

    row 0F  000035    TGP retires = 53
    row 10  0007E6    TGP pc = 0x7E6
    rows 06/0C/0E/07/0B  all zero   the coprocessor made NO SDRAM reads at all
    row 00  FE8B1E    V60 PC, FROZEN
    row 01  15580E    1,398,798 instruction fetches, frozen

The coprocessor is stuck, so it never drains the command FIFO; the FIFOs are a mutual
hardware interlock (`model1_m.cpp:29-44`), so the V60 fills the input FIFO and halts. **The
V60 is a victim here, not the cause** - and `FE8B1E` is above `FE6C`, which is the highest
address MAME ever executes, so it is off in the weeds exactly as `FED5A4` was.

**Not timing.** `clk_cpu` closes with **9.944 ns** of slack; only `clk_sys` is near the edge
at +0.379. The combinational instruction-cache hit added on 2026-08-22 is in the CPU domain
and is nowhere near critical.

**Not reproduced in simulation.** `tb_m1_frame` runs past 300 M cycles with the PC and frame
counter advancing, and reaches TGP pc `004c` - the command-wait loop - with 342 retires and
text rendering, `tm0=9787`.

### 53 retires at 0x7E6 is the empty-program-RAM signature

That is where a coprocessor executing zeros ends up: a zero word decodes as `lab`, so
`ldi #0x8000, b0` never writes `b0` - the fault that opened this whole investigation, then
found to be a testbench race.

**Row 02's `800B9A` does not disprove it.** That checksum is folded at the loader's IOCTL
INPUT, before the FIFO and before the write, so it proves the HPS delivered 2048 correct
words and nothing about what reached the TGP's program RAM. It is exactly the gap that rows
07/0B had for SDRAM, and that the read-back sweep closed by reading the memory back.

**Next instrument: read the TGP's program RAM back and fold it**, the same way
`v60_ifetch`'s SDRAM sweep does, and compare against `tools/rom_csum.py` over
`vr_tgp_prog.hex`. Until that exists, "the microcode arrived" is an assumption.

### The microcode IS intact, and a 2048-cycle reset delay fixed the hang — 2026-08-23

    row 0C   A07D51   the program RAM read back through its own port
    expected A07D51   tools/rom_csum.py over vr_tgp_prog.hex

**Exact match, so the load path is exonerated** and "the microcode arrived" is measured at
the array for the first time rather than at the loader's input.

**And the sweep fixed the hang as a side effect.** The only RTL change was holding the core
in reset for the 2048 cycles the sweep takes, and the coprocessor went from parked at 0x7E6
with 53 retires to running with its pc around 0x4xx and retires climbing. **There is a race
at coprocessor release and the previous build was losing it.** That delay is currently
incidental - it exists because the sweep needs it - and it should be made explicit and
justified rather than left as a side effect of a debug instrument.

### CORRECTION: the stable picture was the hang, not the scroll latch

The previous build showed a clean, still horizon and that was read here as the per-frame
scroll latch working. It was the game FROZEN: with the coprocessor hung the V60 never got
far enough to rewrite the scroll registers, so nothing moved. With the coprocessor running
again the jumping is back.

The latch change is still correct - it is what `draw_common` does, read once at vblank begin -
and it stays. It just did not cause the stable picture, and claiming it did would have
retired a bug that is still open.

### Where the coprocessor actually diverges: after read 4

    row 07   300020   first copro SDRAM read address    matches simulation
    row 0B   300040   second                            matches
    row 0E   300040   matches
    row 06   1E0DA5   fold of the first 1024 reads      simulation: BD686D

So it **starts identically and diverges later**, somewhere inside the first 1024 reads. That
is a bisectable range: capture the address at read 64, 256 and 512 and halve it each build,
the same way `tgp_wrtrace` went from "diverges at write 38" to a named instruction.

### The coprocessor read stream is TIMING-DEPENDENT, so row 06 is a weak comparison

Two deep `tb_m1_frame` runs, identical RTL except for making the release delay explicit:

    before   copro read checksum bd686d
    after    copro read checksum 101ed7

The delay changes when the coprocessor starts, which changes how its reads interleave with
the V60's commands, which changes the sequence. **So the read fold is not a stable
signature**, and the difference between the board's `1E0DA5` and simulation's value has been
read here as evidence of a defect when part of it is just interleaving.

Hardware and simulation interleave differently by construction - real SDRAM latency against a
behavioural model - so **any dynamic stream compared between them carries this caveat**. The
first read (`300020`) is deterministic because it happens before any interaction; the
addresses at 64, 256 and 512 are not.

**What this does not undermine**, because each is a static fact rather than a stream:

- the microcode read-back, `A07D51`, matching the ROM image exactly
- the SDRAM whole-image read-back, `4D2E75`, matching
- the row-mask and character write counts
- the tilemap pixel shares

**What to use instead for the coprocessor:** compare against MAME rather than against our own
simulation, at a defined program point rather than a cycle count. `make tgp_trace` already
does that for the retire stream and reports IDENTICAL for its window; extending that window
is the honest way forward, not comparing two machines that were never going to interleave
alike.

## The instrument this core is missing: diff tile RAM and palette CONTENT against MAME

From the Model 2 core, which had the same symptom - a test menu with coloured values and no
white labels - and named it in one step:

> `test_m2_boot` now dumps the tile RAM, palette and xlat OUR CPU builds, and
> `test_m2_video_frame` renders those instead of MAME's capture: 468 non-black pixels
> against the reference's 2054, and the picture is the bench photograph. The diff names it.
> Tile RAM differs in 13 words of 32768. The palette differs in 64 entries, all at 1+16k,
> each written 0000 where the reference holds a colour, and entry 1 is white:
>
>     pal[1] <= ffff  at instruction 1478810
>     pal[1] <= 0000  at instruction 1713595
>
> So the CPU executes something MAME does not, at 1713595 - past the 803355 instructions it
> has been differentially verified to.

**Model 1 has never done the content diff.** Everything measured here has been a COUNT or a
SHARE - pixels won per layer, character writes, non-zero mask writes, scroll register values -
and none of those can say *which word* is wrong. `tb_m1_frame` already renders our own state;
what is missing is dumping tile RAM and the palette and diffing them word for word against a
MAME capture at the same point.

That converts "no text on screen" into "this entry holds X where the reference holds Y", and
then `make v60_trace` can be aimed at the instruction that wrote it - which is exactly how
`tgp_wrtrace` found nine coprocessor bugs.

**And the warning that came with it**, which this core has nearly repeated twice:

> Also removes the tile-RAM fold probe. It cost 64 M10K, because Quartus duplicated the array
> for a third read port, and could never be read: the menu cannot be held still and a fold of
> a moving screen compares against nothing. **Its precondition was not checked before it was
> built.**

A checksum of something that moves compares against nothing. The SDRAM and microcode
read-backs here work because ROM contents are static; the same trick aimed at tile RAM while
the game is drawing would produce a number that means nothing.

**Palette sizing checked at the same time and Model 1 is correct:** MAME maps
`0x900000-0x903fff`, 8192 words, and `m1_mainram` declares `pram_c_lo[8192]` indexed
`addr[13:1]`. The Model 2 aliasing bug - 4096 entries for an 8192-entry region, so half of
every write folded onto the low half - does not exist here.

### BUILT, and it names things in one run: the content diff — 2026-08-27

`tb_m1_frame` now dumps the tile RAM (32,768 words) and palette (8,192 entries) our CPU
builds; `tools/mame_m1_dump.lua` captures the reference's; `tools/tram_diff.py` compares them
word for word. First run:

    tile RAM: 13,329 of 32,768 words differ (40.7%)
      our HIGH byte is 00 where the reference's is not:  12,951
      exactly ours|0x8000 == ref:                         3,470
    palette:     591 of 8,192 entries differ (7.2%)
      strides 1 x284 and 16 x94

**Two distinct faults, and both are addressable in a way no count ever was:**

1. **Tile RAM word 0 holds `0020` here and `8020` in the reference** - and so do thousands of
   others. `8020` is a space with **bit 15, the CATEGORY bit, set**; ours is a space with it
   clear. That is a single word at a fixed address with a known wrong value, which is exactly
   what `make v60_trace` can be aimed at: find the instruction that writes tile RAM word 0.

2. **Where the reference holds characters - `830a`, `8309`, `8303` - we hold `0020`,** the
   screen-clear space. So the clear ran and the draw did not, at specific addresses rather
   than "no text on screen".

The palette shows the same shape: 111 entries where we hold `0000` and the reference holds a
colour, on a stride of 16 - a zeroing loop that walks 32 bytes, exactly the pattern Model 2
found - and entry 0 is `fd02` there and `0000` here.

**This is the instrument that has been missing all along.** Every previous measurement was an
aggregate: pixels won per layer, character writes, non-zero mask writes, scroll register
values. None of them could say *which word*. Two runs of this say it directly.

**The caveat it carries**, and it is the one that has already produced a wrong finding here
once: the two sides must be at the same point IN THE PROGRAM, not at the same frame number.
This core runs at about 84% of real speed, so equal frame counts are different program
states. `tools/tram_diff.py` says so in its header.

### The content diff closes the causal chain: we never reach the drawing code

Tracing the one wrong word the diff named - tile RAM word 0, `0020` here against `8020` in
the reference - gives the whole story in three steps.

**Who writes it.** A write tap on 0x700000 in the reference: four writes, and the last one
decides it.

    w 1  data=0000  pc=fe026c
    w 2  data=0020  pc=fe6a71
    w 3  data=0020  pc=ffe60b
    w 4  data=8020  pc=ff92d5    <- sets bit 15, the CATEGORY bit

**What that instruction is part of.** An unrolled tile-RAM fill:

    FE215A: bsr     FE326F
    FE326F: mov.w   #700000, R0        tile RAM base
    FE3276: jsr     FF92C9[PC]
    FF92C9: mov.h   #8020, R1          a space WITH the category bit
    FF92CE: mov.w   #40, R2
    FF92D5: mov.h   R1, [R0+]          x64

**Whether we execute it.** MAME runs `ff92d5` **128 times**; we run it **zero**, and never
enter the `ff92` page at all. Every step of the call chain - `fe2145`, `fe214c`, `fe2154`,
`fe215a`, `fe326f` - is likewise 1 in MAME and 0 here.

**And it is not a branch taken differently.** `ff92c9` sits at collapsed instruction 87,277
of MAME's 5,193,988, while our entire stream is 25,685 long. **We stop progressing about a
third of the way there**, at `ff9754` - `in.w [R23], R2`, a coprocessor result read.

So the chain is complete and consistent with everything else measured:

    coprocessor diverges -> V60 blocks on in.w at ff9754 -> never reaches FF92C9
      -> tile RAM keeps 0020 instead of 8020 -> every tile is category 0
      -> the text layer draws nothing

**The missing text is not a video fault and never was.** The renderer is drawing exactly what
tile RAM contains. What the content diff added is proof rather than inference: a named word,
a named instruction, and a count of zero.

### tgp_trace with a wide window: 75,175 instructions of agreement, then a named divergence

`make tgp_trace SECONDS_RUN=16 BOOT_CYCLES=1500000000` - the widest window this has ever
been run at, against the previous 342.

    loops collapsed on both sides: 910 in common, 1 with differing counts
    tgp_trace: DIVERGES at instruction 75175

    MAME:  0051 addd -> 0052 brul alw d -> 0053 -> 009B
    ours:  0051      -> 0052            -> 0064

`brul alw d` branches to whatever is in `d`, so MAME lands at 0x53 and we land at 0x64 - a
difference of exactly 0x11. And `d` was built three instructions earlier:

    004D: mov (x1), b      b loaded from memory
    004F: mov bh, d        d = bh
    0050: lia #0x53        a = 0x53
    0051: addd             d = d + a

**`bh` is register 0x14, and it is NOT the high half of B** - `read_reg` returns
`get_exp(m_b)`, the floating-point exponent, `(val >> 23) & 0xff`. Our `mb86233_regs` does
exactly that for 0x14, so the accessor is right.

    MAME   get_exp(b) = 0x00   ->  d = 0x53
    ours   get_exp(b) = 0x11   ->  d = 0x64

**So the fault is the VALUE IN B**, loaded by `mov (x1), b` at 0x004D - either the word at
(x1) or x1 itself. Not the decode, not the register accessor, not the branch.

**This is the deepest the coprocessor has ever been verified.** The previous claim was
"IDENTICAL for 342 instructions", which was a 3-second window in which the reference's TGP
is idle almost throughout; 75,175 with 910 loops agreeing is a different order of evidence.
The next step is to trace what writes the word at (x1), which is the same escalation
`tgp_wrtrace` used to find nine bugs: stop comparing streams, compare the value and find its
writer.

### The Z80 LLE: a cost D9 did not count, and where the ROM has to live — 2026-08-27

Raised after the Model 2 core found a flaw in its I/O path: should Model 1 run the real Z80
instead of the HLE, and would it fit?

**D9's condition is not met.** It says "revisit when the resource count is final, which is not
the same as reversing" - and the rasterizer (4-6 k ALM) and sound (8-9 k) are still estimates
against 11,878 free. The uncertainty the HLE was chosen under is exactly as large as it was.

**And there is a cost the decision did not count.** D9 prices the LLE at ~2,000 ALM against
the HLE's ~300, in ALM only. The Z80 also needs `EPR-14869`, **64 KB**, which on-chip is about
**52 M10K** - and M10K is now the binding resource at 452 of 553, with the rasterizer's band
buffer wanting ~51 of the 101 free. That would leave nothing.

**The ROM belongs in SDRAM**, where every other ROM already is. A 4 MHz Z80 is negligible
traffic against a controller already serving five masters, and it is already in `vr.zip` so
no new asset is needed. That reduces the memory cost to the 8 KB work SRAM, about 7 M10K, and
leaves the decision an ALM question as D9 framed it.

**What would make it a correctness question rather than an area one:** our HLE reproduces a
protocol read out of the Z80 ROM BY DISASSEMBLY, not by running it. MAME's model is LLE and
therefore correct by construction. If a defect is ever traced to the I/O board, the ~1,700 ALM
stops being optional - which is an argument for keeping the interface interchangeable, as D9
already ensures: `m1_ioboard`'s ports do not change between the two.

**Checked at the same time, from the Model 2 finding:** its bridge suite modelled I/O as
COMBINATIONAL when the peripherals are registered, and used FULL-WIDTH accesses when the
failing one is a single byte. Neither applies here - `tb_m1_ioboard` models the edge
explicitly ("the RAM samples its inputs on the edge, so the byte that lands is the one
presented before the clock") and is byte-oriented throughout. And the composition it names as
the remaining untested link - CPU through bridge into I/O board on real code - is what
`make m1_boot` has been doing here all along.

### WITHDRAWN: "the command stream differs at the FIRST pop" — 2026-08-29

**It does not differ at all.** The command interface is bit-exact: over the same window the
V60 pushes **61 commands and the coprocessor pops 61**, and both streams match the reference
word for word.

    our pushes vs MAME pushes:  IDENTICAL, 61 words
    our pops   vs MAME pushes:  IDENTICAL, 61 words

That restores the earlier result recorded above under *"The V60's command stream is CORRECT —
it just never stops"*, which this entry had contradicted on the strength of a bad instrument.

**Three instrument faults of the same family produced the false finding, one after another,
in one investigation.** All three compared two captures that were not the same measurement:

1. **Different filters.** The reference capture was filtered to `GENPC == 0x4e`; ours counted
   every pop. Recorded below.
2. **Different LEVELS.** MAME's read tap on `0x100` fires on a read of an **empty** FIFO,
   which returns `0` and is retried; we stall instead and never log those. So the reference's
   pop log carries `00000000` entries that are not commands, and ours cannot. The two logs
   were never comparable in either direction.
3. **A registered signal sampled on its own write edge.** `pop_data <= fifo_in_data` updates
   on the very edge `fifo_in_pop` asserts, so logging `pop_data` there yields the PREVIOUS
   pop. Our log came out led by the reset value `00000000` and shifted one word behind — which
   read exactly like a phantom command ahead of the stream, and was written up as "offset by
   one" before being caught. `fifo_in_data` is the head itself and is what to log.

**The artefact-free comparator is the PUSH stream.** `v60_copro_fifo_w` pushes once per pair
of 16-bit writes — offset 0 latches the low half, **offset 1 supplies the high half and
performs the push** — so the pushes are exactly the command sequence, with no empty-read
entries and no retries. A tap on `0xd80000-0xd80001` alone sees every low half and **no
pushes at all**: 61 writes of `0000`, which is also precisely what `0x01000000`'s low half
looks like. Tap `0xd80000-0xd80003` and assemble on the odd offset.

**So the divergence at instruction 75,175 is genuinely 75,175 instructions deep**, and the
inputs are not the cause. `x1 = 0x100` at `004D` was read off a static trace back; whether
`x1` still holds `0x100` at the divergence is unverified, and is the next thing to measure
rather than infer.

### A filtering mistake that would have been a false finding

The first comparison put MAME's `00000000, 01000000, ...` against ours of
`00000000, 04000000, 01000000, 3f400000, 428c0000, ...` and appeared to diverge at pop 2.
It was an artefact: **the reference capture was filtered to `GENPC == 0x4e`** - pops at
instruction `0x004D` only - while ours counted EVERY pop. Two sequences with different
filters cannot be diffed.

Also recorded, because it cost a run: `tgp.state["PC"]` does not exist - `PC` is `.noshow()`
in `state_add` - and **a bad state key throws inside a tap and is silently swallowed**, so
the first capture produced an empty file and looked like a tap that never fired. Use `GENPC`,
which is the NEXT pc, so it reads `0x4e` while `0x4d` executes.

### Where the 452 M10K actually go, and the 80 that are recoverable — 2026-08-29

Measured from the fitter's own *Resource Utilization by Entity* table, `M10Ks` column, not
from grepping instance names — a grep of `altsyncram:<name>` counted `o_a_poly_mem` at 62
blocks when it is **1**, because the report names each memory in several sections. The
counts also failed to sum to 452, which is the tell.

    tram_c_lo/hi + tram_v_lo/hi   128     tile RAM, HALF OF IT DUPLICATION
    dl0_lo/hi + dl1_lo/hi         128     display lists, genuinely double-buffered
    cxlat_lo/hi                    32
    pram_c_lo/hi + pram_v_lo/hi    32     palette, HALF OF IT DUPLICATION
    ram                            32
    g_bank                         32
    ascal (framework)              42
    osd_buffer / prog / misc       ~26

**32 blocks per 32768x8 byte lane is the FLOOR, so the byte-array idiom is already optimal.**
M10K's widest useful configuration is 1024x8, so a 32768-deep lane needs 32 blocks whatever
the width: 262,144 bits into 8,192 usable bits each. Going to one 32768x16 array would be
*worse*, not better — the 512x16 configuration needs 64. Depth dominates, not width. The
82% "implementation bits" against 61% actual bits is this, and it is not recoverable.

**The recoverable M10K is the CPU/video DUPLICATION: 64 on tile RAM, 16 on palette.**
`m1_mainram` keeps `tram_c` for the CPU read port and `tram_v` for the video read port,
written identically from `clk`, because an M10K has two ports and write + CPU read + video
read is three. But port A can serve the write AND the CPU read, leaving port B for the video
read — which is two, and is what M10K true-dual-port mode exists for.

**Quartus 17.0 will not INFER it, tested small both ways** (`build/m10ktest`, 1024 entries,
seconds per run, per the rule about testing a memory idiom small):

  * one write + two reads on different clocks — Quartus silently **replicates the array into
    two Simple Dual Port blocks**, 16,384 bits for an 8,192-bit array. That is exactly what
    `m1_mainram` already does by hand, so merging the declarations saves nothing.
  * the true-dual-port template, both ports read and write — **`Error (276001): Cannot
    synthesize dual-port RAM logic "mem"`**. Refused outright.

So it needs an explicit `altsyncram` in `BIDIR_DUAL_PORT` with two clocks, plus a
behavioural model under `` `ifdef VERILATOR `` since Verilator cannot compile the
megafunction. That is a sim/synth divergence risk on the most heavily used memory in the
design, which is why it is written down rather than done in the middle of the TGP work.

**`MISTER_DISABLE_ADAPTIVE` is NOT worth it.** It sets ascal's `ADAPTIVE("false")`, and the
memory that guards is `o_a_poly_mem` — **1 M10K**. ascal's 42 are mostly its four scaler line
buffers at 5 each. `MISTER_SMALL_VBUF` changes DDR3 `RAMSIZE` only and touches no M10K.

### The TGP parks because an empty command FIFO must return ZERO, not stall — 2026-08-29

`tgp_trace` agrees for 75,175 instructions and then splits, and the split is one branch:

    MAME   ... 0051 0052 -> 0053 -> 009b 009c 009d 009e 009f 004c 004d ...   keeps polling
    ours   ... 0051 0052 -> 0064 -> 01c8 01c9 01ca ...                       dispatches

`0052 brul alw d` is a **computed jump**, and `d = get_exp(b) + 0x53` makes 004D-0052 a
dispatch table with base 0x53. `b` is loaded at `004D: mov (x1), b` with `x1 = 0x100`, which
`copro_data_map` maps to the command FIFO, so **the command type is carried in the exponent
field** and selects a handler above the base.

`get_exp` is `(val >> 23) & 0xff`, so **an empty FIFO gives `b = 0`, `d = 0x53`** — and 0x53
is the IDLE handler, which jumps back to 0x9b and polls again. That is the whole of what the
reference is doing at the divergence: its FIFO is empty and it is spinning in its idle loop.

**We stalled the pop instead, so `b = 0` was unreachable and the idle path was unreachable.**
The core parks at 004C the first time it polls an empty FIFO and never comes back. That is
exactly the recorded symptom — `pc=004c`, 342 retires, about fourteen io accesses per run
where the reference makes 158,391 in 400 frames.

**MAME's FIFO does not block on the pop, and the comment in `m1_tgp.sv` that said it did was
citing the one thing gen_fifo.h contradicts.** `on_fifo_empty_pre_sync`: *"Called on a pop
with an empty fifo. Must ask the destination to try again... **the pop itself will then
return zero**."* The halt only follows a machine sync that finds it still empty.

Measured over the same 16-second window: **61 pushes against a pop capture that filled its
300-entry cap.** Nearly every pop the reference makes is of an empty FIFO. A design that
stalls on empty cannot reproduce a machine whose normal state is polling nothing.

**The outbound FIFO keeps its stall and must.** That direction is the V60 reading results,
where acknowledging an empty read returned a stale word and hung the CPU at `fed5a4`; MAME
halts the maincpu there rather than letting it proceed. The two directions are not
symmetric in MAME and must not be made symmetric here.

`tb_m1_tgp` asserted the wrong behaviour until now — "it blocks on an empty input FIFO" —
and **could not have caught this**, because it only checked that `unimplemented` stayed low,
which a parked core satisfies. It now requires the core to make progress with the FIFO empty.

**Measured immediately after the change**, `make m1_frame BOOT_CYCLES=1500000000`:

    before   TGP retires=342    pc=004c  pushes=61 returns=20      parked at dispatch
    after    TGP retires=57660  pc=00a7  pushes=61 returns=36      running

`pc=00a7` is the instruction after the two consecutive FIFO reads at 0x00a5/0x00a6 — the
multiply whose result is written back — so the coprocessor is in its working path rather
than polling. 168x the retires from one acknowledge.

### The TGP:V60 clock ratio is 1:1 here and 2.5:1 on the board — 2026-08-29

    reference     V60 16 MHz (32_MHz_XTAL/2)    TGP 40 MHz (40_MHz_XTAL)    ratio 2.5 : 1
    ours          V60 19.2 MHz                  TGP 19.2 MHz                ratio 1.0 : 1

`Model1.sv` ties `.ce_cpu(1'b1)` and both processors run on `clk_cpu`, PLL `outclk_1` at
19.2 MHz. The "dual-clock" note on `m1_tgp` refers only to the microcode load port, not to
running the core faster. So **our coprocessor has 2.5x less throughput relative to the CPU
than the real board.**

**This makes instruction-level lockstep of the TGP impossible as a metric, and that is not a
statement about correctness.** 004D-0052 is a poll: which way `0052 brul alw d` goes depends
on whether the FIFO happens to hold a command at that instant, so the instruction stream
encodes the relative speed of the two processors. Diffing it compares timing, not semantics.

Demonstrated by the fix on the same day. Before, a read of an empty FIFO stalled, which
**synchronised** our TGP to the data and hid the ratio; `tgp_trace` agreed for 75,175
instructions. After, with the correct return-zero behaviour, it parts at instruction 89 —
with the roles reversed:

    before   MAME 0052 -> 0053 (idle)      ours 0052 -> 0064 (dispatch)
    after    MAME 0052 -> 0055 (dispatch)  ours 0052 -> 0053 (idle)

`get_exp(0x01000000)` is 2, so the reference dispatches to `0x53 + 2 = 0x55`; we read an
empty FIFO. **The longer agreement was the buggier build**, because stalling made our TGP
data-driven rather than time-driven. A metric that rewards the wrong behaviour is the wrong
metric.

**So M0 exit criterion 2 needs a timing-independent comparator**, and the candidates are the
data-memory WRITE streams (`make tgp_wrtrace`, already built) and the sequence of dispatched
handlers with their results. The command interface itself is already known bit-exact — 61
pushes, 61 pops — so what is left to prove is that each command produces the same work, which
is a value question, not a schedule question.

Whether the ratio should be corrected in RTL is open and is NOT required for the criterion.
It would need the TGP in its own faster domain, which costs timing closure at 29,771 ALM and
+0.634 ns; and our V60's CPI is ~15 against real silicon's ~8, so the two errors are not
independent and fixing only the clock would not make the machine match the board.

### quartus_fit segfaults AT EXIT, and the multicycles were not the cause — 2026-08-29

`make rbf` reported `Error (23031): Evaluation of Tcl script qsh_flow.tcl unsuccessful` and
produced no `.rbf`. That message names neither the stage nor the cause, and the log two lines
above it says the opposite:

    Info: Quartus Prime Fitter was successful. 0 errors, 45 warnings
    *** Fatal Error: Segment Violation
    Module: quartus_fit
       0x32ee4f: STA_COLLECTION_ATCL_OBJ::~STA_COLLECTION_ATCL_OBJ()
        0x2b0be: ATCL_OBJ::tcl_freeInternalRepProc(Tcl_Obj*)
       0x130ec1: UnsetVarStruct
       0x131253: TclDeleteNamespaceVars
       0x103fc0: TclTeardownNamespace
        0x19d82: atcl_exe_fini()

**The fit succeeds — 30,099 ALM, 452 M10K, 0 errors — and the crash is in the TEARDOWN**,
freeing STA collection objects that the SDC left in Tcl variables. Because it dies at exit,
no fit report is written and the assembler never runs, so the build has no `.rbf` while
claiming success. The stale `.rbf` from an earlier build is still sitting in `output_files/`,
which makes it look as though something was produced. **Check the `.rbf` timestamp, not its
existence.**

Fix: `unset -nocomplain sdram_clk_src sdram_clk_prt sdram_out sys_clk cpu_clk sdc_exe` at the
end of the SDC, so the collections are freed inside the STA session rather than at
interpreter shutdown.

**THE MULTICYCLE PATHS WERE BLAMED FOR THIS AND ARE NOT THE CAUSE.** They are opt-in behind
`MODEL1_SDRAM_MCP`, which was **not set** on the build that crashed, so those four lines never
ran. Three earlier crashes were attributed to them and the SDRAM constraints were made
opt-out in response — that is a workaround built on a misattribution, and the constraints can
stay on.

### The coprocessor is now blocked on the V60, not on commands — 2026-08-29

With the empty-FIFO fix in, `tb_m1_frame` was instrumented with 64-bit counters (the RTL's
`dbg_retires` and `dbg_fifo_pops` are 16 bits and **wrap with no saturation**, so
"retires=57660" is `57,660 + 65,536k` and cannot be divided by a cycle count):

    TGP cycles=36,273,868  retires=385,340   ->  94 cycles per instruction
      mem_req   25,248,162    70% of all cycles
      fifo_rd      128,484     0.4%
      fifo_wr   24,991,194    69%          <- stalled WRITING results
    V60 read the result FIFO 20 times in 109 frames (0/frame)
    TGP pushed 36 results

**`fifo_out_push` requires `!fifo_out_full`, the FIFO is 16 deep, and 36 results went in — so
it is full and the coprocessor has been stalled on the 37th push ever since.** That is the
correct interlock (MAME halts the TGP on a full outbound FIFO too); what is wrong is the
other end.

**The reference's V60 reads that FIFO about 1,185 times a frame** — 710,722 over 600 frames,
in I/O space via `in.w`. Ours reads it 20 times in 109 frames. The V60's `IN`/`OUT` are
already real bus transactions here (that was fixed after the `fed5a4` poll), so the path
exists and the V60 simply is not executing the code that uses it.

So the coprocessor is **not** starved of commands — pushes match the reference exactly, 61
against 61 — and the 94 cycles per instruction is almost entirely one blocked write. The next
question is a V60 control-flow question, and `make v60_trace` is the instrument: it currently
parts at instruction 197,251 on `cmp.h R0, FE[R11]` / `be`, where `0x40e8fe` reads `0000`
there and `ffff` here.

Note the 2.5:1 clock ratio recorded above is a real difference but is NOT what this is —
a stalled writer does not care how fast its clock is.

### The chain closes: the V60 takes an interrupt early, and everything follows — 2026-08-29

Four measurements taken in sequence, each answering the one before:

**1. The TGP is not starved of commands, it is blocked pushing results.** `fifo_wr` is
asserted for 69% of all TGP cycles; 36 results went into a 16-deep outbound FIFO and it has
been stalled on the 37th ever since. That interlock is correct — MAME halts the TGP on a full
outbound FIFO too.

**2. The V60 does not drain it.** 20 reads in 109 frames, against the reference's ~1,185 per
frame. The `IN`/`OUT` path is real here, so the V60 is simply not executing that code.

**3. `v60_trace` says why: DIVERGES at instruction 25,281**, and it is an interrupt.

    MAME   FC57C5: jsr FF8ABC  ->  FF8ABC
    ours   fc57c5              ->  fe02bc

A `jsr` target is fixed, so ours cannot have gone to `fe02bc` by executing it. `fe02bc` is
reached from **five different predecessors** in our own trace — `fe1435`, `fe1433`, `fe143d`,
`fe10cd`, `fc57c5` — which is the signature of an interrupt handler, not a subroutine. **We
take an interrupt the reference has not taken yet.**

**4. And the cause is speed.** The same run reports our loops running about HALF the
reference's iterations:

    fe1433,fe1435,fe143d    MAME 8769    ours 4102    (-53.2%)

repeated across many sites. These are time-based waits, so the iteration count IS the
relative speed of the two machines. Our V60 executes ~1.28 MIPS (19.2 MHz at CPI ~15) against
real silicon's ~2.0 (16 MHz at CPI ~8).

**So the TGP work is downstream of CPU speed, not of the coprocessor.** `tgp_wrtrace`'s
value-level divergence at write 268 — `41ef3336` (29.9) there against `bdcccccd` (-0.1) here,
from `x0 = 0x100`, the command FIFO — is the V60 having pushed different data after taking a
different path. It is not a TGP arithmetic fault.

### A fifth instrument fault, and this one nearly stood: the MIRROR

`map(0xd80000, 0xd80003).mirror(0x1fffc)` means the coprocessor FIFO answers across the whole
of `0xd80000-0xd9ffff`. A write tap on the four base bytes catches **61 pushes** where a tap
on the mirrored range fills a 4,000-entry cap immediately. 61 could never have been the whole
stream for a window in which the reference dispatches 265,555 commands, and that contradiction
is what exposed it.

**The prefix comparison survives, checked rather than assumed**: the first 61 pushes of the
full capture are byte-identical to the base-only capture, so "61 pushes, 61 pops, bit-exact"
holds for that prefix and the withdrawal of "differs at the FIRST pop" stands. What does NOT
follow is that the command stream is correct in general — beyond the prefix our V60 diverges
and pushes far fewer commands.

**Our own decode was never at fault**: `m1_decode` matches `hi == 8'hd8 || hi == 8'hd9`, which
is the full mirror, and `a1` is `addr[1]`, which is MAME's `offset` under mirroring too.

### clk_cpu closes at 24.94 MHz and runs at 19.2 — 30% is sitting unused — 2026-08-29

From the last successful build's STA, `Fmax Summary`:

    24.94 MHz   emu|pll|...|general[1]|divclk     <- clk_cpu, RUN AT 19.2
    83.43 MHz   emu|pll|...|general[0]|divclk     <- clk_sys, run at 80

**The V60 is the machine's critical path now** — see the interrupt divergence above — and a
30% speedup needs only a PLL output change, no RTL. It takes ~1.28 MIPS to ~1.66 against real
silicon's ~2.0 (16 MHz at CPI ~8). **It does not close the gap**; our loops run at 47% of the
reference's iteration counts and 30% does not make that 100%, so CPI work is still what
matters.

**It is not free of consequences, and this is the dependency that would break silently.**
`m1_ioboard`'s `LATENCY = 740684` is *derived from the clock*: the reference's I/O board takes
38,577 us to answer the boot handshake, which is 740,684 cycles **at 19.2 MHz**. Change the
clock and that constant has to move with it, or the deadline stops meaning 38,577 us. The
property that matters is that the deadline exceeds the V60's once-a-frame doorbell interval,
so a wrong constant would not fail loudly — it would change boot behaviour.

Left as a measured option rather than done, because it changes how fast the whole machine
runs and interacts with hardware testing that is mid-flight.

### How much speed is actually missing: 1.63x, measured two independent ways — 2026-08-29

**Interrupts per instruction**, from `v60_trace`'s RAW streams (`our_pc_raw.txt`,
`mame_pc_raw.txt` — the collapsed files CANNOT answer this, one collapsed line stands for
thousands of iterations, and comparing them gives a meaningless 31-against-31):

    ours    31 entries to fe02bc in   949,429 instructions   ->  1 per 30,627
    MAME    19 entries in the same    949,429 instructions   ->  1 per 49,970
    MAME   107 entries in           3,996,841 instructions   ->  1 per 37,354

The interrupt arrives on wall-clock time and is the same rate on both sides, so
**interrupts-per-instruction is a direct measure of relative throughput**: we take 1.63x as
many, so we execute about **61%** of the reference's instructions per unit time.

That agrees with the arithmetic from the other direction — 19.2 MHz at CPI ~15 is ~1.28 MIPS
against 16 MHz at CPI ~8, which is ~2.0, and 1.28/2.0 = 64%. Two unrelated instruments, 61%
and 64%.

**So the target is 1.63x, and it decomposes:**

    clk_cpu 19.2 -> 24.94 MHz (its measured Fmax, PLL change only)   1.30x
    CPI 15 -> 12 (the remainder)                                     1.25x
                                                                     ----
                                                                     1.63x

CPI 15 -> 12 is a 20% improvement on a figure that has already moved 18.4 -> 17.9 -> 14.9 in
this project. **This is a reachable target, not an open-ended one**, and it is the thing
standing between the coprocessor and useful work: the V60 never reaches the code that drains
the result FIFO, so the TGP sits stalled on a full outbound FIFO at 69% of its cycles.

### With the constraints actually analysed, the SDRAM read path misses by 8.186 ns — 2026-08-29

Once `quartus_fit` stopped crashing at exit, a full compilation ran with the SDRAM SDC in
force for the first time — and the design **does not meet timing**:

    clk_sys (general[0])   -8.186 ns    TNS -127.514
    SDRAM_CLK_pin          -0.387 ns

The earlier `+0.514 ns` on `clk_sys` came from builds with the constraints suppressed, so
**this violation had been invisible for as long as the workaround was in place.** That is what
suppressing a constraint buys: not a faster design, a quieter report.

**The failing transfer names itself.** From the Setup Transfers matrix:

    From SDRAM_CLK_pin  ->  To clk_sys      16 paths

Sixteen paths is the sixteen `SDRAM_DQ` bits: the **read-capture path**. TimeQuest assumes
next-edge capture there and this controller does not do that — which is precisely what the
four `set_multicycle_path` lines in the SDC exist to express, and they were **opt-in behind
`MODEL1_SDRAM_MCP` because they had been blamed for the fitter segfault**.

They are not the cause. The crash is the Tcl teardown recorded above, and it happened on a
build where `MODEL1_SDRAM_MCP` was **not set**. So the multicycles are now **on by default**,
with `MODEL1_NO_SDRAM_MCP` as the escape hatch.

**Two workarounds were stacked on one misattribution**: the constraints were made opt-out AND
the multicycles opt-in, both to dodge a crash in neither of them. The measurement that
separated them was reading the stack trace instead of the exit code.

**And the multicycles close it.** Same design, `MODEL1_NO_SDRAM_MCP` unset:

    clk_sys setup        -8.186 ns  ->  +0.378 ns
    SDRAM_CLK_pin setup  -0.387 ns  ->  +10.582 ns
    worst setup / hold   failing    ->  +0.321 / +0.253 ns, no negative slack anywhere
    ALM / M10K           30,101     ->  29,979 / 452

So the -8.186 WAS the sixteen read-capture paths and not internal `clk_sys` logic — the
rebuild is what settled that, rather than reading the transfer matrix and assuming. **A full
compilation now meets timing with the SDRAM interface constrained**, which is the first time
that has been true here.

### The hardware degradation REPRODUCES in simulation — 2026-08-29

`make m1_frame FRAME_CYCLES=3600000000`, 2,611 frames:

    at    109 frames   tm0=9787   tm1=0  tm2=180677  tm3=0    text layer drawing
    at  2,611 frames   tm0=0      tm1=0  tm2=190464  tm3=0    tilemap 2 over everything
    scroll changes over 2,610 frames:  hscr[5002]=1  vscr[5006]=1   (MAME: hscr 1,344/2,000)
    window ctrl  pair01=0000  pair23=0000                            (never set)
    V60 pc pinned at feb673 from ~620 M cycles - frame ~469 - onward

**The V60 enters a loop at `feb673` around frame 469 and never leaves**, and the picture
collapses to the sky-and-sea state. That is the same failure reported from the board — "after
about 10 minutes we hit a black screen; after a core reset we go back to the broken sky and
sea only, and a full reload gets it back" — and it is now **reproducible without hardware**,
which is the difference between a 25-minute build plus a person watching a screen and a
105-second bench.

`FRAME_CYCLES`, not `BOOT_CYCLES`: `tb_m1_frame`'s parameter is `RUN_CYCLES` and the Makefile
passes `-GRUN_CYCLES="64'd$(FRAME_CYCLES)"`. Every earlier run in this session that passed
`BOOT_CYCLES=1500000000` to `m1_frame` silently used the 120,000,000 default — 109 frames —
which is why the degradation had not been seen there.

Note the 109-frame numbers are not the healthy state either: `window ctrl` is `0000` in both,
where the reference sets pair 2/3 to `0x2xxx`. The run reaches the attract screen and then
falls out of it rather than never getting there.

### The black screen is a MUTUAL DEADLOCK between the V60 and the TGP — 2026-08-29

`make m1_frame FRAME_CYCLES=800000000`, with FIFO occupancy added to the periodic report:

    400 M cycles  pc=fe1435  fin= 0/16  fout=16/16  v60_stall=0  tgp_wr=1
    420 M cycles  pc=ff9323  fin= 0/16  fout=16/16  v60_stall=0  tgp_wr=1
    440 M cycles  pc=feb673  fin=16/16  fout=16/16  v60_stall=1  tgp_wr=1
    540 M cycles  pc=feb673  fin=16/16  fout=16/16  v60_stall=1  tgp_wr=1   (never recovers)

**The order matters and it names the cause.** The OUTBOUND fifo is full first, at 400 M, while
the inbound is still empty and the V60 is running: the coprocessor is already blocked pushing
results that nobody is reading. It therefore stops taking commands. The V60 keeps pushing
until the INBOUND fifo fills too, and then it blocks on `fin_full`. From 440 M onward both
processors are waiting for the other and `pc` never moves again.

**This is the board's failure, reproduced.** "After about 10 minutes we hit a black screen;
after a core reset we go back to the broken sky and sea only, and a full reload gets it back."
A deadlock is exactly that shape — permanent, and unrecoverable by anything short of a reload.

**Both interlocks are CORRECT and neither should be relaxed.** MAME halts the TGP on a full
outbound fifo and the V60 on a full inbound one; `m1_copro_if`'s tests assert both. The
deadlock is a *consequence* of the V60 never reaching the code that drains results, which is
the interrupt-timing divergence at instruction 25,281 and the 1.63x speed deficit recorded
above. **Fix the speed and the deadlock cannot arm.** Adding an escape hatch to the FIFOs
would hide it and produce a machine that silently drops geometry instead.

### The V60's CPI is TRIMODAL, so a targeted fix beats pipelining — 2026-08-29

`make m1_boot BOOT_CYCLES=400000000`, retire-to-retire histogram over 6,292,761 instructions:

    mean 14.9   median 9

    25 cyc   1,672,426 instr   26.6% of instrs   44.4% of ALL CYCLES
     9 cyc   3,421,949 instr   54.4%             32.7%
    33 cyc     409,890 instr    6.5%             14.4%
     3 cyc     538,100 instr    8.6%              1.7%
    30 cyc      64,092 instr    1.0%              2.0%

**A third of the instructions consume 59% of the cycles.** `tb_m1_boot`'s own comment poses
the question this answers: *"A UNIFORM ~11 means every instruction is genuinely multi-cycle
and a split pays; a BIMODAL distribution means a short average dragged by a few slow classes,
which pipelining barely touches and a targeted fix does."* Median 9 against mean 14.9, with
four sharp peaks at 3 / 9 / 25 / 33, is emphatically the second.

**So the V60 split should target the 25-cycle class, not general pipelining.** If that class
came down to ~12 cycles it is worth ~23% of all cycles — CPI 14.9 -> ~11.5, which is 1.30x and
**more than the 1.25x the 1.63x speed target needs from CPI**. That is an estimate of the
prize, not a measurement of the fix: what the 25-cycle class actually IS has not been
identified yet, and a per-opcode breakdown is the next instrument. The shape says where to
point it.

The tail is negligible and should not be chased: everything above 33 cycles together is under
2% of cycles, and the `63 or more` bucket is 0.5%.

### Isolation on the board: the empty-FIFO fix WAS the regression — 2026-08-29

Flashed with `EMPTY_FIFO_READS_ZERO = 1` and the board went to **sky and sea with no glyphs
and nothing moving**, from an image that had been drawing the attract text, `INSERT COIN(S)`,
`CREDIT 0` and the high-score table. Rebuilt with the parameter at 0 and **the picture came
back**.

The SDRAM constraints and the read-path multicycles were unchanged between those two images
and stayed on, so they are cleared: the regression is the coprocessor being unparked.

    77bec12b   EMPTY_FIFO_READS_ZERO=1, SDRAM constrained   sky and sea, no glyphs
    e85a33ed   EMPTY_FIFO_READS_ZERO=0, SDRAM constrained   attract text back

**This is the deadlock, and it was predicted before the flash rather than after.** Unparking
the coprocessor makes it PRODUCE results; the V60 never drains them; `fout` fills, the TGP
stops taking commands, `fin` fills, and both halt. A halted V60 draws nothing new, which on a
screen is a frozen sky and sea.

**Two process failures, both mine.** The flash bundled the empty-FIFO fix WITH the SDRAM
timing change, so the board could not say which regressed, and the working `.rbf` was
overwritten without a copy, forcing a 13-minute rebuild to recover a known-good image. Keep
the last-known-good `.rbf` in `build/` under a name that says what is in it, and change ONE
thing per flash.

### And it invalidates the scroll census

`FRAME: scroll changes over 2,610 frames: hscr[5002]=1 vscr[5006]=1` was measured on the
run with the fix ON, which deadlocks at ~frame 340. **About 87% of those frames were a halted
machine**, so "the scroll registers never change" was largely a statement about a dead V60,
not about the scroll logic. Re-measured against the shipped configuration.

### The reference does not scroll before ~frame 400 either — 2026-08-29

`tools/mame_scroll_census.lua` samples from frame 400 and reports at 2,000, so every
comparison against our 108-frame bench window was comparing different points in the attract
sequence. Measured directly (`build/dasm/early.lua`):

    MAME  f=20..160    hscr2=0000  ctrl01=0000  ctrl23=0000   hscr2 changed on 0 frames
    ours  f=0..108     hscr2 changed once, window ctrl pair23=0000

**So at matched frames we agree with the reference**, and "we never enter window mode where
MAME always does" would have been a false finding. The reference's own numbers only diverge
from that later:

    f=400   hscr2=000b  ctrl23=2015          layer 2 hscr CHANGED on 1,345 of 2,000 frames
    f=800   hscr2=000e  ctrl23=23db          layers 0/1/3 changed on 18 / 0 / 0
    f=1200  hscr2=0102  ctrl23=23fc          0x4000 per-line table: 0 of 2048 non-zero
    f=1600  hscr2=03dc  ctrl23=23ce

Pair 2/3 is mode 1 throughout — `ctrl & 0x6000` is `0x2000` on every counted frame — with the
low bits moving, so the horizon's split line slides while `hscr` scrolls the pair sideways.
**Vertical movement without horizontal is what you get if the split line moves and `hscr`
does not**, which is the reported symptom, but establishing that needs our run to reach frame
400+ and the 108-frame window cannot show it.

The per-line H-scroll table stays struck off: still 0 of 2048 words non-zero over 2,000
frames, and no layer ever sets `hscr` bit 15.

### Where the V60's cycles go: work RAM at 36 cycles an access — 2026-08-30

`make m1_boot BOOT_CYCLES=300000000`, data-bus latency by page:

    500000   n=1,289,439   46,511,564 stall cycles   avg 36     <- RAMB, the game's work RAM
    400000   n=   87,312    2,995,996                avg 34
    100000-280000 (ROM)    ~1.2 M each               avg 36
    780000-7d0000          ~0.9 M each               avg 32
    600000/610000 (copro RAM)                        avg  8
    700000 (tile RAM)                                avg  8
    910000 (palette) / c00000                        avg  8

**One page absorbs 1.29 M accesses at 36 cycles — 46.5 M stall cycles in a 300 M-cycle run.**
`model1.cpp:992` maps `0x500000-0x53ffff` as `.ram()`: RAMB, 256 KB of work RAM, which lives
in SDRAM here.

**Two separate costs, and neither is SDRAM physics.**

  * **The bus baseline is 8 cycles**, paid by every access including on-chip block RAM. A
    registered M10K read is one cycle; the rest is the req/ack round trip, which must be HELD
    rather than pulsed (see the acknowledge rule in HANDOFF).
  * **SDRAM adds ~28 more.** At 19.2 MHz that is ~150 cycles of the 80 MHz `clk_sys` domain,
    where a CAS-2 read after an activate is roughly 9. So the penalty is the CDC handshake and
    the controller's per-access sequencing, not the memory.

**This is the concrete target for the 1.25x CPI the speed deficit needs**, and it is bus work
rather than CPU work — which matters, because it does not touch the V60's verified behaviour.
Caching RAMB is not obviously the answer: it is read/write, and 256 KB is 256 M10K against
101 free. Shortening the handshake helps every page at once.

**Caveat on the histogram**: 4.6 M instructions retired in a 300 M-cycle window is ~65
cycles/instruction overall, against the histogram's mean of 14.9. The histogram bins
retire-to-retire runs and caps at 63, so long waits are undercounted. Treat 14.9 as the shape
of the common case, and `v60_trace`'s 1.63x against MAME as the reliable relative figure.

### The scroll asymmetry is real, and it is program state — 2026-08-30

`make m1_frame FRAME_CYCLES=2000000000`, 1,461 frames, shipped configuration (coprocessor
parked, so no deadlock and the V60 runs throughout):

    ours   hscr[5002] changed  86 of 1,460 frames    vscr[5006] changed 372
           window ctrl  pair01=0000  pair23=2305
           layer px  tm0=11038  tm1=11733  tm2=59412  tm3=0

    MAME   layer 2 hscr changed 1,345 of 2,000 frames   (~982 scaled to 1,460)
           pair 2/3 ctrl = 0x2xxx on every frame

**Window mode is working**: our `pair23 = 2305` is mode 1 with a split line, the same shape as
the reference's `0x2xxx`. The video path is not at fault.

**The asymmetry is in what the V60 WRITES.** Our vertical register moves 372 times and our
horizontal 86; the reference moves horizontal ~982 times. Mostly-vertical motion with a little
horizontal is the reported symptom on the board, and it follows directly from those counts.

So the tile movement joins the coprocessor behind the same root cause: our V60 diverges from
the reference (interrupt at instruction 25,281, 1.63x speed deficit) and therefore writes
different scroll values. There is nothing to fix in `m1_video` for this.

### And the 36 cycles split three ways — 2026-08-30

Same bench, 814,355 accesses to page 0x50:

    dispatch    4.0 cycles     m_req rising to sdr_req asserted
    sdram+cdc  27.9 cycles     sdr_req to sdr_ack
    finish      4.0 cycles     sdr_ack to m_ack
                -----
               35.9

Dispatch plus finish is 8, which is exactly the on-chip baseline measured on pages 0x60, 0x70,
0x91 and 0xc0 — so that half is the req/ack round trip, paid by every access whatever answers
it. **The 27.9 is the whole prize**: it is 116 cycles of the 80 MHz domain for a read that
needs about 9 after an activate, so roughly a factor of thirteen is not the memory.

Candidates, in the order worth measuring: arbitration against the tile-fetch engine, which
reads SDRAM continuously and would queue the CPU behind it (`docs/HANDOFF.md` carried an
"unexplained 103-cycle character fetch wait" here, WITHDRAWN 2026-09-04: the
average included the ROM download, and the real figure is 18 cycles with 2 of
them arbitration); the two CDC crossings; and per-access
activate/precharge sequencing with no open-row reuse.

### The SDRAM controller is innocent: 8.7 cycles of ~116 — 2026-08-30

Instrumented inside `m1_sdram` on its own 80 MHz clock, port 0 (the V60's data port),
1,504,699 grants:

    wait-for-grant   1.1 cycles
    service          7.6 cycles
                     ----
                     8.7 of the ~116 the CPU waits

**So neither the memory nor the arbiter is the cost.** 7.6 cycles is close to the ~9 a read
needs after an activate, and arbitration is essentially free at 1.1.

**And it is not contention with the video engine, at least not here**: `tb_m1_boot` ties
`p_req[1]` low, so the tile-fetch port is not connected in this bench at all. The only other
masters are instruction fetch (port 2) and the TGP (port 3). That also means this arbitration
figure is a LOWER BOUND on the hardware's, where the video engine reads continuously — worth
re-measuring on `tb_m1_frame`, which drives the real port map.

**~107 cycles of the 80 MHz domain are therefore outside the controller**, in the CDC and the
bus FSM. `m1_cdc_port` uses 3-flop toggle synchronisers, and at the 19.2/80 ratio those cost
about 3 CPU cycles on the A side and 3 domain cycles on the B side — roughly **4 CPU cycles of
the 26 unaccounted for**. The remainder is NOT yet explained and should not be guessed at: the
next measurement is `a_req` to `b_req` and `ack_tog` to `a_ack` on the CPU's own CDC instance,
which splits synchroniser latency from anything serialising behind `a_busy`.

Worth checking in that measurement: whether a partial write's read-modify-write is being
counted as one access at the `m1_main` level but two transactions at the controller — 814,355
page-0x50 accesses against 1,504,699 total grants leaves room for it.

**The CDC split did not measure and the reason is worth keeping.** The counters were written
entirely on `clk_cpu`, but `m_sdr_req`/`m_sdr_ack` are `clk_sys` signals — 80 MHz against
19.2, a ratio of 4.17 — so a one-cycle pulse in the fast domain falls between two slow-domain
edges and is never seen. `cdc_n` stayed 0 and the report printed nothing at all, which looks
identical to a counter that was never reached.

**Sample each signal in ITS OWN domain and hand the timestamp across**, or the measurement is
of the sampling, not the design. That is the sixth instrument fault of this family in two
days: mismatched filters, taps at different levels, a registered signal read on its own write
edge, a tap on a base address with a mirror, a census over a window the machine was dead for,
and now a fast-domain pulse sampled slowly.

What stands without it: **8.7 of ~116 cycles are the controller**, so ~26 of the CPU's 36
cycles are the crossing and the bus FSM, and that is where the 1.25x CPI lives.

### CORRECTION: those bus figures were in 80 MHz cycles, not CPU cycles — 2026-08-30

`tb_m1_boot`'s `cycles` counter increments on **`clk`**, which is `clk_sys` at 80 MHz, not
`clk_cpu` at 19.2. Every latency figure quoted from the by-page table and the phase split
above is therefore in 80 MHz cycles, and dividing by the 4.17 ratio changes the conclusion.

    work RAM access   36 clk_sys = 8.6 CPU cycles     (NOT 36 CPU cycles)
    on-chip access     8 clk_sys = 1.9 CPU cycles

    dispatch  4.0   path 27.9   finish  4.0           all clk_sys
      within the path:  issue 7.0  serve 8.5  return 11.4  = 26.9
      controller:       1.1 arbitration + 7.4 service = 8.5

**The three measurements agree with each other and with the CDC's structure**, which is what
identifies the units as the error rather than the design: the 26.9 measured across the
crossing matches the 27.9 measured at the bus, and the 8.5 measured inside the controller
matches the crossing's own `serve`. A 3-flop toggle each way over a 4.17:1 ratio predicts
about this.

**What this overturns.** The claim that the SDRAM path was ~150 cycles of the 80 MHz domain
for a read needing 9 — "a factor of thirteen is not the memory" — was the same number divided
by the wrong clock. And with it, the claim that the speed deficit is in the bus rather than
the CPU:

    total CPI 14.9  =  ~10.7 execution  +  ~4.2 stall

which is the split already recorded for this core. **Execution dominates.** Halving the CDC
saves perhaps 2 cycles an instruction against the 3 that 1.25x needs, so it is worth doing but
is not sufficient alone, and the V60's own execution CPI is back on the critical path.

**Check the clock a testbench counter runs on before quoting it.** The by-page table has been
in this bench for weeks and its unit was never stated.

### clk_cpu 19.2 -> 22.857 MHz, and why not 23 — 2026-08-30

23 MHz is not synthesisable by this PLL: `Error: PLL Output Counter parameter
'output_clock_frequency' is set to an illegal value of '23.0 MHz'`. The VCO is 480 MHz
(480/25 = 19.2, 480/6 = 80) and the output counters are integer divisors, so the legal values
either side are **480/21 = 22.857 MHz** and 480/20 = 24 MHz. 24 leaves 0.3% against a measured
Fmax of 24.08 and was rejected; 22.857 leaves about 5%.

**Fmax is 24.08 MHz, not the 24.94 recorded earlier.** That figure came from a build without
the read-path multicycles; the current configuration's `clk_cpu` setup slack is +10.549 ns on
a 52.08 ns period, so the critical path is 41.53 ns.

    result   worst setup +0.408 ns, no negative setup slack anywhere
             30,186 ALM, 452 M10K, 0 errors

**The dependent constant moved with the clock.** `m1_ioboard`'s `LATENCY` is 38,577 us
expressed in CPU cycles: 740,684 at 19.2 MHz becomes **881,760** at 22.857. Still inside the
20-bit counter, and still longer than the V60's once-a-frame doorbell, which is the property
that makes the flag stay set after boot. The Makefile's `-GLATENCY`/`-DLATENCY_CFG` pair and
`tb_m1_frame`'s clock period were changed in the same commit.

**Measured effect before flashing**, `m1_frame` at the default window: the V60 reads the
coprocessor result FIFO **276 times (2/frame)** where at 19.2 MHz it managed 20 (0/frame). The
reference does ~1,185/frame, so this is a long way short - but it is the quantity whose being
zero armed the deadlock, and it is no longer zero.

Gain is 1.19x of the 1.63x needed. The rest is execution CPI.

### A probe that indexed a bit outside its vector, and what it hid — 2026-08-30

`m_addr` in `m1_main` is declared `logic [23:1]` — a byte address with bit 0 omitted — so the
word index inside a 64 KB page is `m_addr[15:1]`. A probe written as `m_addr[14:0]` selects a
bit that **does not exist**, never matches, and reports **zero**.

That produced a confident wrong finding and it survived a control check: the controls
(108,098 tile-RAM writes, 1,406,540 acked bus writes) were healthy, because they did not use
the broken index. "Zero writes to the scroll registers while tile RAM is clearly being
written" then looked like evidence of a write-path bug, and the region histogram — also built
on the wrong bits — appeared to corroborate it.

    broken probe   hscr[5002]=0    vscr[5006]=0    all 5000-5007=0
    correct probe  hscr[5002]=130  vscr[5006]=130  all 5000-5007=788

**A control has to exercise the same expression as the measurement**, or it confirms only that
the testbench is running. The other probe in this same file has used `m_addr[15:1]` throughout.

### At matched frames the scroll path AGREES with the reference — 2026-08-30

With the index fixed, over 108 frames:

    ours   130 writes to 0x5002   (~1.2 per frame)
    MAME  2003 writes over 2000   (~1.0 per frame)

**The registers are written at the reference's rate.** What differs is the VALUE: ours barely
changes while the reference's moves constantly from ~frame 400 onward.

The value comes from a table in work RAM. Ours writes `0x501408` from `pc=fe1469` with
`data=0000`; the reference writes `0x501408`/`0x50140a` from `fe48d5` and `fef3b5` with
computed values. But **neither side reaches `fe48d5` or `fef3b5` in the traced window**, and
both execute `fe1469` **exactly 64,512 times** — identical. So the early behaviour matches and
the divergence is later than any window measured so far.

That is consistent with the reference itself: `hscr2` is `0000` and unchanging through frame
160, and only starts moving around frame 400. **Every comparison of the scroll path made
before this one was inside the window where both machines legitimately do nothing.**

### The scroll value is COMPUTED and CONSTANT: 0x501408/0x50140a — 2026-08-30

Past frame 400, where the reference actually scrolls, with the probe indexing fixed:

    hscr[0x5002]   WRITES   ours 1.9/frame      MAME 1.0/frame
    hscr[0x5002]   CHANGES  ours 33 of 525      MAME 1,345 of 2,000

So the register is written faithfully and often; **the value it is given barely moves**. That
value comes from a work-RAM pair at `0x501408`/`0x50140a`, and both machines compute it from
the same two instructions:

    W1400 writes by pc   ours (526 frames)   MAME (700 frames)
      fe48d5                977                 213
      fef3b5              1,001                 214
      fe1469 (the clear)     19                   2
      fe6ab0 (also zeroes)   38                   4

**We run the computing routines about six times more often than the reference and they write a
CONSTANT:**

    ours   fe48d5 -> 0x501408 = 003e      fef3b5 -> 0x50140a = 2fa6
    MAME   fe48d5 -> 0x501408 = 0001      fef3b5 -> 0x50140a = 2064, 2063, and moving
                                                    (2058 / 2fce / 20a8 at frames 300/600/900)

So this is not reachability and not the write path — **the routines' INPUT is static here**.
`0x501408` is `0x3e` against the reference's `0x01`, which is a large difference in what looks
like an index or counter, and is the concrete thing to trace next.

**Three earlier readings of this were wrong and each is instructive:**

  * "we never write the scroll registers" — a probe indexing `m_addr[14:0]` on a `[23:1]`
    vector, so a bit that does not exist. Reported zero on a machine writing 1.9 times a frame.
  * "only `fe1469` writes the table" — the print was capped at the first eight writes, which
    are all the clear. The computing writes come later and were never shown.
  * "the divergence is later than any window measured" — true, and the reason every earlier
    scroll comparison agreed: the reference's own `hscr2` is `0000` until about frame 400, so
    all of them sat inside the window where both machines correctly do nothing.

### The scroll animation is fed by the COPROCESSOR — the chain closes — 2026-08-30

Tracing the constant scroll value back through the reference:

    hscr/ctrl written from        fe48d5 (0x501408) and fef3b5 (0x50140a)
      those read                  0x501320/22 (constant both sides),
                                  0x501a2c/2e and 0x501424/26  <- the animating pair
    the animating pair written by fef25c/fef265 (0x501a2c) and fef39d/fef3a4 (0x501424)
    and THAT routine reads:

        program fef000  8,128     its own code
        program 501000    384
        program 400000    256
        io      d80000    256     <- THE COPROCESSOR RESULT FIFO
        program 403000    192

`0x50140a` is literally `0x2000 | (0x501424 & 0xfff)` — the window mode bits plus a split line
taken from a value the coprocessor supplies. In the reference `0x501424` moves
`0058 -> 0014 -> ffce -> ffda` and `0x501a2c` moves `846b -> 8162 -> 82fc -> 3fa5 -> 763c`;
here both are static, so the split line is fixed and `hscr` barely moves.

**The whole chain, every link measured:**

    V60 is 1.63x too slow
      -> enabling the coprocessor deadlocks it against the V60 (both FIFOs full)
      -> so the coprocessor is parked
      -> so fef25c/fef3a4 read nothing useful from 0xd80000
      -> so the scroll inputs are constant
      -> so the background does not scroll horizontally

**This qualifies the entry above.** "The scroll asymmetry is program state, and there is
nothing to fix in `m1_video`" is right about the video path and about the write path, and
wrong to imply the scroll fault is independent of the coprocessor. It is not: it is the same
root cause, two steps further downstream.

**Open question worth checking before enabling the TGP again:** the V60 reads the result FIFO
276 times per 108 frames while the coprocessor has pushed only 20 results, so most of those
reads find it EMPTY. `m1_copro_if` deliberately withholds the acknowledge on an empty
outbound read, which should stall the V60 — and it plainly does not hang. Either those reads
are the always-completing high half at offset 1, or the interlock is not doing what its
comment says. That is worth settling on its own terms.

### The interlock works, and the "V60 reads the FIFO N times" figure was STALL CYCLES — 2026-08-30

Settling the open question above:

    result-FIFO reads: offset0=273  offset1=20
      of offset0: empty=253, acked-while-empty=0

**The interlock is correct**: not one read of an empty outbound FIFO was ever acknowledged.

But `v60_acc` is `req && !served && ...`, and `served` only latches on the acknowledge — so an
unacknowledged access asserts it on EVERY cycle it is held. The counter was therefore counting
**stall cycles, not reads**. Offset 1 always completes and is counted once per access, so the
true number of completed result reads is **20**, matching the 20 results the parked
coprocessor had pushed. The 253 are cycles spent waiting, spread across those 20 reads.

**This withdraws a claim made in support of the clock change.** "The V60 now reads the result
FIFO 276 times (2/frame) where at 19.2 MHz it managed 20 (0/frame)" compared the same broken
metric before and after, so it is not evidence that raising the clock improved anything. The
clock change stands on its own terms — Fmax headroom that was measured and unused — but that
particular justification does not.

**Counting an event on a held request counts cycles.** Latch the completion edge, or count a
signal that is asserted once per transaction. The same shape as the `pop_data` fault and the
`m_addr[14:0]` fault: the instrument, not the design.

### The V60 never enters the geometry submission path at all — 2026-08-30

**This is the answer, and it is not speed.** Walking up the call chain from the coprocessor's
result reads, none of it is reached in 525 frames:

    FEF9C6 list walk      0     FEFA25 submit    0     FEFB40 jsr       0
    FEF9CC cmp/bne        0     FEFA93           0     FF84A2 gate      0
    FEF9D2 bsr FEFA25     0     FEFAD1           0     FF84AE bgt       0
    FEF9D8 (the skip)     0     FEFB00 in.w      0     FF850C in.w      0

The reference runs `FF850C` **202 times a frame**. We run it zero times, while running
neighbouring routines - `fef3b5` 2,359 times, `fe48d5` 2,335 - thousands of times in the same
window. So this is one large routine that is simply never entered, not a path taken less often.

`FEF7xx-FEFBxx` is the geometry submission routine: it writes commands to `[R24]` and reads
results back with `in.w [R23]`, and `FF84A2` is the block-read that drains the FIFO. **Not
entering it explains every open symptom at once** — nobody drains the outbound FIFO, so it
fills and the two processors deadlock; and the scroll inputs at `0x501a2c`/`0x501424` never
receive coprocessor data, so the background does not scroll horizontally.

**The gate is NOT the reason.** `FF84A2` compares `0x5011B0` against `0x5011A0` and `FF84AE`
branches past the reads on the wrong result — but our values are `5011a0 = 0` and
`5011b0 = 0x157c`, identical to the reference's, so the branch would fall through correctly if
it were ever reached.

**So the chain recorded earlier is wrong where it blamed speed.** "V60 1.63x too slow ->
deadlock -> parked coprocessor -> static scroll" put a throughput number in a place that needs
a control-flow answer: a 1.63x deficit cannot turn 202 executions a frame into zero, and the
arithmetic said so all along — the reference reads that FIFO ~1,185 times a frame against our
0.49, a factor of ~2,400.

Finding what calls `FEF7xx` and why we do not is the next step, and `make v60_trace` over a
window that reaches it is the instrument. The traced window currently ends around frame 115,
before this routine runs, which is why every trace comparison so far has agreed.

### WITHDRAWN: "the V60 never enters the geometry submission path" — 2026-08-30

It enters it. The measurement that said otherwise was taken with
`EMPTY_FIFO_READS_ZERO = 1`, the configuration that **deadlocks at frame ~340** — so the
machine was frozen for the rest of the run and could not reach anything. Re-measured with the
shipped configuration (coprocessor parked, V60 running throughout), same 526-frame window:

    geometry gate  501A35=01  501A28=00000001      IDENTICAL to the reference
    submit chain   fef9c6=35  fefa25=35  fefb00=18  fef9d2=75
    call chain     fefb40=65  ff84a2=452  ff84ae=174
                   ff84b1(reads)=259  ff8582(skip)=390  ff850c=194

**So every routine in the chain runs, and the gate values match the reference exactly.** What
differs is the RATE: the reference executes `ff850c` about 202 times a frame, we execute it
194 times in 526 frames — 0.37 a frame. And the gate at `FF84AE` diverts to `FF8582` on 390 of
452 visits where the reference falls through.

**Measure the configuration you are asking about.** A frozen machine reports zero for
everything downstream of the freeze, and that zero is about the freeze, not about the code.
This is the second finding in two days built on a window in which the machine was not running
— the other being a scroll census over 2,610 frames of which ~87% were post-deadlock.

### The M10K duplication is gone: 452 -> 372 blocks — 2026-08-30

`m1_tdp_ram` shares the tile RAM and palette between the CPU and video ports instead of
keeping a copy each. Quartus confirms a single memory:

    altsyncram:u_ram ... M10K block ; True Dual Port ; 32768 x 16 ; 32768 x 16 ; 524288 bits

524,288 bits is exactly one copy of 32768x16, where the inferred form produced two. Full
build:

    M10K   452 -> 372   (-80, and 372/553 is 67% against 82%)
    ALM  30,186 -> 30,139
    worst setup +0.141 ns, no negative setup or hold slack anywhere

**The Model 2 core solves the same problem the same way** and `rtl/mem/m2_tdp_ram.sv` is the
reference. What differs here: our two ports are on DIFFERENT CLOCKS, so port B needs
`address_reg_b`/`outdata_reg_b`/`indata_reg_b`/`wrcontrol_wraddress_reg_b`/`byteena_reg_b` all
on `CLOCK1` — leaving any of them at `CLOCK0` silently puts that part of port B back on the
CPU's clock. And our CPU port is byte-enabled, so the two byte-wide arrays become one 16-bit
array with a `byteena`. **Both ports must be the same width** or the block is replicated again.

**A 10 ps timing miss is placement luck, not a design fault.** The default seed landed
`clk_sys` at -0.010 ns; `M1_SEED=3` gives +0.141 with nothing negative. Try a seed before
changing logic.

### What is left, and none of it is duplication

    dl0/dl1  128   two genuinely different buffers (the V60 writes one while the renderer
                   reads the other), one read port each, 32 blocks per byte lane is the floor
    ram       32   the coprocessor RAM, single-ported behind m1_copro_if's arbiter
    cxlat     32   at its floor
    g_bank    32   the video line buffers - THE LARGEST REMAINING INEFFICIENCY

`g_bank` is 2 banks x 4 layers x 4 lanes = **32 separate memories of 128x15 bits**, each in
its own M10K: 1,920 bits of a 10,240-bit block, **19% utilisation**, 32 blocks holding 61,440
bits in total. It is structural rather than accidental — the four-lane split exists because a
per-lane byte-enable is the one idiom Quartus 17.0 will not infer as RAM at all, and merging
lanes would need four write ports, which no M10K has. Worth revisiting only with a different
line-buffer scheme.

### Two counting faults, and a V60 bug that was not one — 2026-08-30

**1. `dbg_pc == X` counts CYCLES, not executions.** `dbg_pc` is a level, so the comparison
holds for every cycle the instruction occupies. It showed up as `FF84A2` (a ~25-cycle `cmp`)
at 452 against the `bgt` immediately after it at 174 — consecutive instructions cannot execute
different numbers of times. Edge-detecting the PC transition gives executions, and the numbers
change completely:

    counted as cycles     ff84a2=452  ff84ae=174  ff850c=194  fe1469=2,035,042
    counted as executions ff84a2=7    ff84ae=7    ff850c=6    fefa25=1

So "the gate diverts on 390 of 452 visits" was wrong twice over: those were cycles, and the
gate does not divert at all — `a0 > b0` on **0 of 174** samples taken at `FF84AE` itself, with
`a0=0x257` against `b0=0x157c`.

**2. Our PC trace emits only on a PC CHANGE**, `core.dbg_pc !== pc_prev` in `tb_m1_frame`.
MAME's tracer emits every instruction. **A self-branch therefore records ONCE here and N times
there**, and `FFA6BD` is exactly that:

    FFA6B4: pushm #1
    FFA6B6: mov.w #1388, R0        ; 5000
    FFA6BD: dbr   R0, FFA6BD[PC]   ; branches to ITSELF

MAME 30,000 (6 calls x 5000), ours 6. That looked like a broken `dbr` falling straight
through — a delay loop after a write to the sound USART at `0xC40002`, which would have been a
serious find. **It is a tracing artefact and `dbr` is fine**: the decode reads
`rf_raddr_a = fb[1][4:0]` in `S_DECODE`, `cc4 = 4'ha` maps to `cond_true = 1`, and the loop
executes normally.

Self-loops are the only thing this collapses, and they are ~0.75% of the reference's
instructions, so the interrupts-per-instruction ratio recorded earlier is not materially
affected.

**What still stands:** our V60 executes the per-frame geometry update roughly **once in 526
frames** where the reference runs it every frame — `fefa25=1`, `fefb40=1`, `feef14=1`, and
nothing upstream gates it: `fef325` (the divert) is 0 and `fef9d8` (the skip) is 0. The path
is simply not being called, and finding its caller is the next step.

### THE V60 SPINS ON DPRAM 0x40 AND OUR I/O BOARD ANSWERS 0x20 — 2026-08-30

Found by normalising the two instruction streams instead of walking the call chain by hand.
`v60_trace` parts at instruction 25,281 on interrupt timing; **filtering the interrupt handler
out of both streams** (`fe02bc` to its `retis` at `fe0343`) **and collapsing self-loops in
both** — which our tracer already does to ours and MAME's tracer does not — pushes agreement
from 25,281 to **278,920** instructions, and the first divergence there is real:

    MAME   fe022c fe0232 ... fe0234 fe108f ...     exits the loop
    ours   fe022c fe0232 ... fe022c fe0232 ...     still spinning

    FE03FD: mov.b  #1, C00040      set the flag
    FE022C: test.b C00040          poll it
    FE0232: bne    FE022C          spin until it reads ZERO

`0xC00000-0xC00FFF` is the DPRAM shared with the I/O board (`model1.cpp:1013`, an `mb8421`), so
this is an I/O-board handshake. Measured on the reference over 300 frames:

    dpram 0x20   V60 writes 12      reads 12
    dpram 0x21   V60 writes  0      reads  0        <- nothing ever reads this
    dpram 0x40   V60 writes 295     reads 36,131    <- the byte it spins on

**`m1_ioboard` answers `FLAG_ADDR = 0x020` and publishes `STAT_ADDR = 0x021`, and never touches
`0x040`.** So the V60 sets the flag it actually waits on and nothing ever clears it. The
38,577 us `LATENCY` the board models is right — the reference's first clear of 0x40 takes
**38,389 us**, the same handshake — but it is being applied to the wrong byte.

**And `0x021` is read ZERO times by the reference's V60.** Publishing byte 0x21 was recorded
here as bringing tilemap 1 from 0 to 2,518 pixels, so something changed when it was added; but
the reference never reads it, so whatever that was, it was not this.

This is one wait loop, not a speed problem, and it is upstream of everything measured
yesterday: the main loop stops here, so the per-frame object dispatch runs 0.44 times a frame
against the reference's 5.6, the geometry submission runs once in 526 frames, the coprocessor
is never fed or drained, and the scroll inputs never move. The interrupt handler keeps
drawing, which is why the picture is there at all.

### WITHDRAWN: "the V60 spins on DPRAM 0x40 and our I/O board answers 0x20" — 2026-08-30

Wrong twice over, and both faults are ones this file already warns about.

**1. Byte against word.** `model1.cpp:1013` maps the DPRAM `umask16(0x00ff)`, so only EVEN V60
byte addresses exist and **V60 byte `0xC00040` IS DPRAM word index `0x20`** — which is exactly
`m1_ioboard`'s `FLAG_ADDR`, since it takes `v60_addr = m_addr[11:1]`. Our board answers the
right location. The census that appeared to prove otherwise compared MAME BYTE offsets against
our WORD indices, and its "byte 0x21 sees zero accesses" was an odd address that does not
exist at all — absence of a thing that cannot be there, read as evidence.

**2. The divergence is the timed wait, not a stall.** Measured properly — count the polls
between each SET and the first zero read:

    sets=295   completed waits=1   over 300 frames
      wait 1: 36,131 polls, 38,389 us

**Every one of those 36,131 polls is the single boot handshake.** The reference spins in
`FE022C/FE0232` for 38.4 ms too, and after that the flag is never cleared again and the V60
never waits again — which is precisely what `m1_ioboard` implements and what
`docs/io-board.md` already records. So the instruction-stream divergence at 278,920 is our
slower CPU needing MORE INSTRUCTIONS to cover the same wall-clock wait. A timed wait compared
in instruction counts always looks like a hang on the slower machine.

**To compare past it the loop has to be collapsed on both sides**, the same treatment
self-loops needed. `tools/v60_collapse.py` exists for exactly this and was not used here.

**The Z80 I/O board is probably still the right thing** — the Model 2 core found HLE
insufficient where the board COMPUTES rather than responds, and it is the same physical PCB —
but the evidence offered for it above was not evidence.

### The V60's FP group IS used, so the 2,984 ALM lever is closed — 2026-08-30

`make m1_frame FRAME_CYCLES=700000000 FRAME_DEFS=+define+S32_V60_NO_FP`:

    cycles=421763431  halted=1  fp_trap=1        the trap fires at about frame 326
    layer px  tm0=0 tm1=0 tm2=0 tm3=0            the CPU is stopped, so nothing draws

**Virtua Racing executes V60 floating-point instructions.** `docs/m1-m4-plan.md` recorded
removing the FP group as worth **-2,984 ALM**, about 10% of the device, held open because
"whether Model 1 game code executes V60 FP instructions is unverified". It is verified now and
the answer is that the group must stay.

**The question could not be answered before because the test was vacuous.** `dbg_fp_trap` is
inert by construction in a build that HAS floating point — it only means anything under
`S32_V60_NO_FP` — and `make m1_frame` had no way to pass a define. `FRAME_DEFS` did not exist,
so `make m1_frame FRAME_DEFS=+define+S32_V60_NO_FP` silently built the ordinary core and
reported `fp_trap=0`, which reads exactly like "no FP is used". Only `m1_boot` had `BOOT_DEFS`.
The variable is added, mirroring `BOOT_DEFS`.

**A define that does not reach the build is worse than no test**, because it produces the
answer you were hoping for. Check that the switch moved something — here, `halted=1` and a
blank screen are what the define actually doing its job looks like.

### The V60 agrees for 7 M instructions; the first real divergence is a frame-tick overrun — 2026-08-30

With the interrupt stripped, loops collapsed, and the tracer's cap raised (it was silently
ending the window at 4,000,000 entries — about 2.5 emulated seconds):

    MAME   27,467,032 instructions, 798 interrupts  -> 4,163,971 collapsed
    ours    7,011,730 instructions, 281 interrupts  ->    48,413 collapsed
    DIVERGES at collapsed instruction 33,401

and the divergence is:

    FE13F3: cmp.b #3, 500501
    FE13FB: blt   FE1406        MAME takes it (value < 3); we do not (value >= 3)

`0x500501` is a **frame tick**: the interrupt handler increments it at `FE0320` once a frame
and the main loop drains it at `FE1406`. The reference only ever holds 0, 1 or 2 — measured,
590 writes over 400 frames, values `00`/`01`/`02` only. Ours:

    0=134  1=134  2=133  |  3=2  4=2  5=2  6=2  7+=6

**So we keep up on 97.3% of frames and overrun on 14 of 526.** That is the ~1.25x speed
deficit expressed in the game's own terms, and it is what the trace caught. Interrupts per
instruction now: ours 1/27,536 against the reference's 1/34,432, so **1.25x** — down from the
1.63x measured before `clk_cpu` went 19.2 -> 22.857 MHz, which is the 1.19x that change was
worth. Two independent measurements agreeing.

**But 2.7% of frames does not explain the object dispatch.** `FE1C09` runs 0.44 times a frame
here against the reference's 5.6, and its indirect call fires on 11% of iterations against
66%. A 12x gap is not a 2.7% overrun, so there is a second cause still unaccounted for, and
it sits between the frame tick and the object list.

### The deadlock is ONE BIT: object 0 word 0 is 84000000 here and 80000000 there — 2026-08-30

Our V60 pins at `FEB673` when the coprocessor FIFO fills. **`FEB673` does not appear once in
fourteen emulated seconds of reference trace.** Walking back through our own trace:

    FEB643: mov.w 501118, R28      loop count (15)
    FEB64A: mov.w 501324, R22      object array pointer -> 0x400f80
    FEB651: test1 #1A, 0[R22]      bit 26 of the object's word 0
    FEB65A: be    FEB688           skip when CLEAR
      ours   feb651 feb65a -> feb65c   falls through, into the submission body
      MAME   FEB651 FEB65A -> FEB688   branches, EVERY time

and the body writes geometry to `[R24]`, the coprocessor. The object words:

    ours       84000000  00000000  00000000  00000000  00000000  80000000
    reference  80000000  ...                                     (bit 26 never set)

**One bit — `0x04000000` — on object 0.** It puts us in a submission loop the reference never
enters, which fills the outbound FIFO, which halts the coprocessor, which stops it consuming
commands, which fills the inbound FIFO, which halts the V60. The whole deadlock hangs off it.

**What this displaces.** The deadlock was attributed to the V60 being too slow to drain
results. It is not: the reference does not drain that traffic either, because it never
generates it. The speed deficit is real and separately measured at 1.25x — the frame tick at
`0x500501` overruns on 2.7% of frames — but it is not what arms the deadlock.

**Next: what sets bit 26 of the object at 0x400f80.** That is a single-bit write to a known
address, which a write tap on either side answers directly. The object array is at V60
0x400f80 (pointer at 0x501324, count 15 at 0x501118), and in `tb_m1_frame` that is
`device.mem` word 0xFA07C0 — V60 byte B in the 0x400000 region maps to 0xFA0000 + (B-0x400000)/2.

### Model 1's tile scroll VALUE comes from the coprocessor — verified at register level

Model 2 drives tiles and 3D separately from the CPU, which predicts that Model 1's tile scroll
should not depend on the geometry engine. On Model 1 it does, and this is the data flow rather
than an inference from a PC range:

    FEF372: mov.w   #E800000, [R24]     CPU pushes a command to the coprocessor
    FEF37A: movs.hw E5[R25], [R24]      ...with an angle from the object
    FEF380: mov.w   #C3800000, [R24]
    FEF388: in.w    [R23], R0           READS THE RESULT BACK
    FEF38B: cvt.sw  R0, R0
    FEF3A4: mov.w   R0, 501424          -> the scroll input
    FEF3AB: and.h   #FFF, R0
    FEF3B0: or.h    #2000, R0
    FEF3B5: mov.h   R0, 50140A          -> the ctrl/scroll word

`or.h #2000` then the store is exactly the `0x2000 | (value & 0xfff)` measured from outside,
so the two agree. **And `[R23]` was checked rather than assumed** — a read tap filtered to
`pc == 0xfef388` reports `io d80000` and `io d80002`, 28 each over 300 frames, which is the
32-bit coprocessor FIFO read in both halves. `R23` being the result port was originally
inherited from `FF850C`, a different routine, which is not evidence.

**The plumbing is still CPU-driven** — the coprocessor never touches tile RAM. The V60 pushes,
reads back, masks and writes the tile register itself. What has a data dependency on the
geometry engine is the scroll VALUE, at about 0.09 reads a frame, matching the ~63 frames in
400 on which the scroll registers change.

**Consequence:** with the coprocessor parked, `in.w` returns zero, `R0` is constant, and the
background cannot scroll horizontally. That part of the chain stands.

**The earlier evidence for this did not.** It was a read tap over the 368-byte range
`fef250-fef3c0` that found 256 reads of `d80000` among 9,216, which would have supported the
claim whether or not it was true.

### The root cause: bit 31 of the coprocessor's answer to command 0x20800000 — 2026-08-30

Tracing the one bit back one more level:

    FEB5C0: clr1  #1A, 0[R22]       clear bit 26 on this object
    FEB5C9: mov.w #20800000, [R24]  ask the coprocessor about it
    FEB5D1: mov.w 1E[R22], [R24]    two operands from the object
    FEB5D6: mov.w 26[R22], [R24]
    FEB5DB: in.w  [R23], R0         read the answer
    FEB5DE: test1 #1F, R0           test BIT 31 OF THE ANSWER
    FEB5E5: be    FEB5F0            clear -> skip
    FEB5E7:                         set   -> SET bit 26, marking the object
    FEB5F3: dbr   R28, FEB5C0       next object

A per-object visibility or culling test. **Bit 31 of the coprocessor's reply decides whether
an object is marked for geometry submission**, and the marked objects are what `FEB651` later
feeds into the FIFO.

    FEB5C0 (the clear)   reference 3,990 executions      ours 15
    FEB5E7 (the set)     reference     0 executions      ours  4

The reference's answer always has bit 31 clear, so it marks nothing and `FEB661-FEB687` never
runs. Ours comes back with bit 31 set, objects get marked, geometry floods the outbound FIFO,
the coprocessor halts, it stops consuming commands, the inbound FIFO fills and the V60 halts.

**So the deadlock is the coprocessor's arithmetic, not the V60's control flow.** The V60 is
doing exactly what it is told by a wrong answer. That also displaces the speed explanation a
second time: the reference does not drain this traffic because it never generates it, and it
never generates it because its coprocessor says "no".

**Next: what the reference's coprocessor returns for command 0x20800000, and what ours
returns.** That is a bounded question about one microcode routine and one result word, and it
is the first point in this whole chain where the fault is ours to fix in RTL rather than a
consequence two or three steps downstream.

### The fix target: our coprocessor answers the visibility command with one word, not two — 2026-08-30

Same command, same operands, captured at the FIFO on both sides:

    cmd 20800000  operands c342028f  4128cccd
      reference   ANS 00000000   then   ANS 41170ddd
      ours        ANS 4356e2e1

The reference returns **a zero flag word followed by a value**. `FEB5DE` tests bit 31 of the
FIRST word, gets `00000000`, and skips — which is why it never marks an object and never
submits the geometry that deadlocks us. Ours returns a **single computed word**, so whatever
lands in that first read decides the branch, and sometimes it has bit 31 set.

Further reference pairs, for a regression test:

    c342028f 4128cccd -> 00000000 41170ddd
    c34211ec 41953333 -> 00000000 41734eb0
    c34d8a3d 41de3d71 -> 00000000 41a5ec1b
    c34d947b 4222b852 -> 00000000 42068fb4
    c3426148 4262eb85 -> 00000000 424b366b

**Where the fix is.** `get_exp(0x20800000)` is `(0x20800000 >> 23) & 0xff = 0x41`, and the
dispatch at `0052 brul alw d` jumps to `d = get_exp(b) + 0x53`, so this is **microcode handler
0x94**. Our TGP executes that handler differently — it produces one result where the reference
produces two — and `make tgp_trace` around pc 0x94 is the instrument.

**Note on the capture**: each line appears twice in `build/frame_answers.txt` because
`v60_acc` is asserted on both cycles of a held access. That is the probe, not duplicated
traffic — the same trap as the result-FIFO read count earlier today, where a held request read
as repeated reads.

**And the opening exchange already agrees.** Our first 400 commands match the reference's
stream and our answers include its dominant `42520000`, so this is not a broken coprocessor —
it is one handler.

### WITHDRAWN: "an empty command FIFO must read as ZERO" — 2026-08-30

**Handler 0x53 is a real command handler, not an idle dispatch, and that was the whole basis
of the change.** The microcode at 0x9b, which 0x53 jumps to:

    009B: mov (x1), d       pop a word
    009C: mov (x1), a       pop another
    009D: fadd : mov $0xd, x1
    009E: mov d, (bx1)      PUSH THE SUM AS AN ANSWER
    009F: brif alw #0x4c

So a command whose exponent field is 0 means "add the next two words and return the sum".
Reading an EMPTY fifo as zero therefore dispatches into that handler, pops two more zeros,
adds them and pushes `00000000` as an answer the V60 never asked for. Measured, with the
parameter on and off, over the same window:

    EMPTY_FIFO_READS_ZERO=1   17 answers of 00000000 from pc=009e, THEN 42520000 from 00a8
    EMPTY_FIFO_READS_ZERO=0   42520000 from 00a8 immediately - identical to the reference

**MAME returns zero from the pop AND stalls, so the zero is never consumed.** `gen_fifo.h`:
the pop returns zero, `on_fifo_empty_pre_sync` asks the destination to try again, and
`on_fifo_empty_post_sync` HALTS it if the fifo is still empty. The retry is the point. Quoting
only the "returns zero" half — which is what was done — inverts the behaviour.

**So stalling was right all along, and parking at 004C on an empty FIFO is correct**: MAME
halts its coprocessor in exactly the same situation. `EMPTY_FIFO_READS_ZERO` stays 0 and the
parameter should probably be deleted rather than left as a trap.

**And the deadlock traced all day was caused by this change.** With the parameter off there is
no deadlock: the frame bench runs to 526 frames with `fin=0/16 fout=0/16`. The chain built on
top of it — "bit 26 of object 0", "the coprocessor answers the visibility command wrongly",
"the V60 is too slow to drain results" — was all downstream of a self-inflicted fault. Every
capture taken while the parameter was on has to be discarded, including the command-stream
comparison that put the first divergence at command 77.

**The lesson, and it is the same one as the deadlocked-window census:** an experimental switch
left on turns every subsequent measurement into a measurement of the switch. Check the
configuration is the shipped one before believing anything downstream of it.

### CORRECTION to the withdrawal above: the deadlock happens WITHOUT the parameter too

The withdrawal said "with the parameter off there is no deadlock". **That is wrong.** It came
from reading `fin=0/16 fout=0/16` at 80 M cycles — early in a run, not at the end. Measured to
completion with `EMPTY_FIFO_READS_ZERO = 0`, the shipped default:

    640 M cycles  pc=ff8504  frames=483  fin=16/16 fout=16/16 v60_stall=1 tgp_wr=1
    700 M cycles  pc=ff8504  frames=526  fin=16/16 fout=16/16 v60_stall=1 tgp_wr=1

So the deadlock is real and is NOT an artefact of that parameter. `pc=ff8504` is inside the
result-reading block, one instruction before `FF850C`'s `in.w`, so the V60 is stalled writing
a command while trying to read results.

What the parameter withdrawal does still stand on: handler 0x53 IS a command handler, reading
an empty FIFO as zero DOES emit 17 answers nobody asked for, and stalling IS what MAME does.
Those are measured. Only the "and therefore no deadlock" conclusion was wrong.

### Open lead: our command stream looks DOUBLED

Logging one line per increment of the FIFO write pointer `fin_wr`, in the shipped
configuration:

    ours   2,098 pushes, 1,121 of them adjacent-equal
    MAME   04000000 01000000 3f400000 428c0000 ...   no adjacent duplicates
    ours   04000000 04000000 01000000 01000000 ...

The per-frame rate matches the reference (4.0 against 4.3), so this is not extra traffic — it
is **half as many distinct commands, each pushed twice**, which would fill the inbound FIFO at
twice the necessary rate and is a plausible cause of the deadlock.

**NOT CONFIRMED, and the check that would settle it did not run.** Two explanations remain
open: the V60 issuing two bus writes to the command port, or `m1_copro_if` pushing twice for
one access. Counting the V60's acknowledged high-half writes against the pushes separates
them; that probe failed to compile and was not retried.

Weighing against the doubling being real: an earlier measurement compared 61 of our pushes
against the reference's 61 and found them IDENTICAL, which a doubled stream cannot be. Either
something regressed between those two measurements, or one of the two probes is wrong. **That
contradiction has to be resolved before acting on this.**

### RESOLVED: the "doubled command stream" was the probe, inserted twice — 2026-08-30

The anchor used to insert the command/answer logger —
`if (core.main.rst_n && core.main.m_we && core.main.m_ack` — occurs **twice** in
`tb_m1_frame.sv` (once with `sel_tileram`, once as the write-ack control counter), and the
insertion was a text replace without a count. The logger therefore landed in two separate
always blocks and wrote every command and every answer twice, sharing one counter. That is
the whole of the "2,098 pushes, 1,121 adjacent-equal pairs" result, and the "17 spurious
answers" count was doubled the same way (it was 17 real ones - that part stands).

The 61-for-61 identical push comparison stands; the doubled stream is withdrawn; and the
"first differing command at 97" from the pair-halved stream is unverified pending a clean run.

**A text replace without a count is an edit to every match.** Count the anchor first, or
insert at something unique. `tools/copro_stream_diff.py` now does the comparison from a single
probe placed at `endmodule`.

### THE DEADLOCK'S CAUSE: the outbound zero-on-empty change, measured and reverted — 2026-08-30

With a single, verified probe (`tools/copro_stream_diff.py`), shipped configuration, 526
frames:

    commands  672 identical, then at 673:
      MAME   18800000  c34e5382 41f15c2c 408ac7be c34c86b6
      ours   18800000  00000000 00000000 00000000 00000000
    answers   258 identical, then at 259 (704 commands in - AFTER the command divergence):
      MAME   00000000     ours   ffffffff   from microcode pc=045d

**The command stream diverges first**, so the coprocessor's wrong answers are downstream of
being fed zeros. Where the zeros come from, read off the reference trace:

    FF84B6: mov.w  5017F4, R5          destination pointer
    FF850C: in.w   [R23], [R5+]        result reads, stored through R5   <- fills the matrix
    ...
    FEB58A: mov.w  40C900, R20         structure pointer
    FEB5F7: mov.w  #18800000, [R24]
    FEB5FF: mov.w  72[R20], [R24]      the matrix pushed back as operands
    ...     9E[R20]

So the operands ARE earlier results, read back at `FF850C` and stored. **The outbound
zero-on-empty change made that read return zero instead of waiting.** Our TGP runs at 1:1 with
the V60 where the board runs 2.5:1, so the V60 reaches `FF850C` before the results exist,
consumes zeros, stores zeros, and pushes zeros at command 673. The real results then arrive
in `fout` with nobody coming back for them: `fout` fills, the TGP halts, it stops consuming,
`fin` fills, the V60 halts at `ff8504`. That is the whole deadlock, and it explains the
measured order - `fout=16/16` with `fin` empty first, then both.

**gen_fifo returns zero from the pop AND makes the reader retry.** The retry is what matters:
the zero is never consumed. Quoting the first half without the second inverted the behaviour,
in BOTH directions, one day apart. The inbound side was caught by the 17 spurious answers;
the outbound side by this. Both FIFOs now stall on empty, as they did before yesterday.

`m1_copro_if` and its test are reverted to the stall; the test's comment records why the
zero-and-complete version stood for a day.

### The revert fixes the deadlock; the zeros at command 673 are something else — 2026-08-30

Same 700 M-cycle window, outbound stall restored:

    before   fin=16/16 fout=16/16 v60_stall=1 from frame ~483   1,136 commands   438 answers
    after    fin=0/16  fout=0/16  v60_stall=0 throughout       13,947 commands  5,995 answers

**No deadlock, and twelve times the coprocessor traffic.** That part of the entry above
stands. What does NOT stand is the explanation for the zeros: with the stall back, command
673 STILL pushes `00000000 x4` where the reference pushes four floats, so the zero-read was
not what zeroed the matrix. And the link that entry inferred - that `FF850C` fills the matrix
- is wrong: `R5 = [0x5017F4] = 0x60xxxx`, the coprocessor RAM window, so `FF850C` stores
results into copro RAM, not into `72[R20]`.

**Who actually fills the matrix, measured on the reference** (`build/dasm/matrix.lua`):

    FEDA41: mov.w #D000000, [R24]      command 0D000000
    FEDA49: mov.w [R3+], [R24]         three ROM vectors from 0xFD3826
    FEDA4D / FEDA51
    FEDA55: in.w  [R23], [R4+]         three RESULTS into 72[R25], 76, 7A
    FEDA59 / FEDA5D
    ... four times over, 12 floats

So the matrix is built from coprocessor ANSWERS to command 0D000000, and it is zero in the
reference too until that routine first runs: `MXW 400d72 pc=feda55 f=272`, and command 673
follows at `f=273`. One frame apart, same pass.

    FEDA55 executions   ours 16 in ~281 frames    reference 8,518 in ~798 frames

Two hundred times rarer here. Whether ours has run `FEDA02` by ITS command 673 is what the
frame-stamped capture answers.

### THE BUG: V60 `IN` with a memory destination never stored — 2026-08-30

Traced by logging every bus access the matrix routine makes (`FEDR`/`FEDW` in `tb_m1_frame`):

    FEDR d80000 pc=feda55 data=5382      in.w [R23],[R4+] READS c34e5382 - the reference's
    FEDR d80002 pc=feda55 data=c34e      exact matrix value - and NO WRITE TO 0x400d72 FOLLOWS

The port read is right. The store is dropped. `rtl/cpu/v60/v60.sv`, `S_IN_RD`:

    wb_op2(dimext(bus_rdata, cur_op[2:1]), cur_op[2:1]);
    if (st == S_IN_RD) st <= S_NEXT;   // "wb_op2 may divert to S_WB_MEM"

`wb_op2` sets `st <= S_WB_MEM` for a memory destination - NON-BLOCKING - so `st` still reads
`S_IN_RD` on the next line, the guard is always true, and the later assignment wins. The
S_WB_MEM state that issues the store is never entered. Register destinations (`flag2`) take
`setreg` inside `wb_op2` and are unaffected, which is why `in.w [R23], R0` at FEF388 worked and
every `in.w [R23], [Rn+]` silently did not: the FEDA55 matrix fill, and the FF850C result block
into copro RAM.

Fix: `if (flag2) st <= S_NEXT;` - a register destination is done, a memory destination has
already been pointed at S_WB_MEM. **The same pattern at S_ROTC** (`if (st == S_ROTC) st <=
S_NEXT` after `wb_op2`) was found by scanning for it, not by a test, and fixed the same way.

    V60 unit suite   29/29     make test   37/37

**No unit test covers IN with a memory destination** - `grep -rli 'in\.[bhw]' third_party/
s32/verif/v60/` finds nothing - and the suite arrived from a System 32 project where the I/O
space is unused, so the whole `IN`/`OUT` path was never exercised there. This is the second
IN/OUT fault found by tracing real code (the first was OUT's swapped operands, at instruction
197,250), and both were invisible to per-opcode fuzzing because that harness never generated
the instruction.

**What this explains, in one place:** the matrix at 72[R20] stayed at its init zeros, so
command 673 pushed 00000000 x4 where the reference pushes four floats; the coprocessor then
computed on zeros and its answers diverged from #259; the scroll value derived from those
answers barely moved; and with the outbound zero-read in place, the results the V60 never
came back for filled fout and deadlocked the pair. Each of those was measured as a separate
symptom this weekend and attributed to something else - speed, the FIFO semantics, a
microcode handler, a single object bit - before the store was traced.

### THE SECOND BUG: the CDC port re-accepted a held request with its OLD address — 2026-08-30

With the IN fix in, the command stream is identical over all 4,000 and the answers diverge
at #767, from microcode `037c`, on identical inputs. That handler computes from a sincos
lookup, so the sincos unit's traffic was logged on both sides (`tools/sincos_diff.py`,
addresses normalised - our probe logs unit-relative 0-3, MAME's tap absolute 0x20-0x23):

    249 events identical, then
      MAME  SCW 20=00000131  SCR 22=bcef8326  SCR 21=3f7fe3fc
      ours  SCW 20=00000131  SCR 22=bcef8326  SCR 21=3cef8326

Same base, same first read, and the second read - `0371: mov $0x21 (e)` immediately after
`0370: mov $0x22 (e)` - returned **the previous lookup's table word** (entry 0x131, unflipped)
instead of the mirrored entry 0x3ecf. Not the table, not the unit: a back-to-back handshake.

**The mechanism, in `m1_cdc_port`.** It accepted on `a_req && !a_busy`, and `a_busy` clears
on the same edge that raises the one-cycle `a_ack`. The TGP core holds its request as a
LEVEL: it sees `io_ack` during the ack cycle with its old address still on the bus, and
presents the next read only from the following edge. So on the ack+1 edge the port saw
`a_req && !a_busy` again and re-accepted **the old address**; ran a duplicate transaction;
ignored the core's real next request as busy; and delivered the duplicate's ack - with the
old data - as if it were the new read's. Every sincos-dependent answer from there was wrong.

The V60's path never showed it because `m1_main` drops `sdr_req` on the ack cycle and idles
through B_ACK before issuing again; the port's comment even documented `a_req` as a
one-cycle pulse. Both real requesters drive a level.

**The fix**: refuse acceptance on the ack cycle only when the request was ALREADY high on the
ack cycle - `!(a_ack && a_req_d)`. A bare `!a_ack` guard drops a fresh pulse that lands on
that cycle and hangs the requester: the port's fuzz bench completed 1 of 20,000 that way.

**The test models the core's one-cycle lag, and had to.** A bench requester that switches to
the new address in zero time after the ack is faster than the hardware and passed on the
broken port; presenting the old address for one more edge, as the core does, makes the old
port fail (`addr 3ecf read 0858, expected b7aa`) and the new one pass. Both were run.

    m1_cdc_port: checks=254848 -> 254853 fails=0     make test 38/38

### THE COPROCESSOR IS BIT-EXACT AGAINST THE REFERENCE — 2026-08-30

With both fixes in - `IN` storing to memory, and the CDC port not re-accepting a held
request with its old address - the frame bench over 526 frames, shipped configuration:

    commands   IDENTICAL over all 4,000 captured      (was: diverged at 673)
    answers    IDENTICAL over all 4,336 captured      (was: diverged at 259, then 767)
    sincos     IDENTICAL over 1,545 events            (was: diverged at 250)
    fin/fout   0/16 throughout, no deadlock           (was: both 16/16 from frame ~340)
    TGP pushed 75,669 results (~144/frame; reference ~168 at 1.25x our speed)
    layers     tm0=7449 tm1=6919 tm2=176096  window ctrl pair23=202a
    scroll     hscr[5002] changed 44 of 525 frames, vscr 73   (was 33 / 96)

Every word the V60 pushes and every word the coprocessor answers matches MAME for the
whole traced window. M0 exit criterion 2 asked for instruction-accuracy on real microcode
over a busy window; this is the value-level form of it, and it is stronger than the PC diff,
which cannot compare a poll loop across two machines with different clock ratios.

**On the scroll count.** 44 changes in 526 frames is not the reference's 67% of frames, but
the reference's `hscr` only starts moving around frame 300 and drifts slowly at first
(`000b` at f=400, `000e` at f=800), and at 1.25x slower our frame 526 is the reference's
~420. The scroll VALUE is derived from coprocessor answers that are now identical, so the
value-level check is the one that counts; a longer run would settle the rate.

**Two V60-side facts from the same run that are NOT problems:** `TGP retires=9217 pc=004c`
is the 16-bit counter wrapped and the idle park, and "read the result FIFO 8,605,502 times"
is the held-access cycle counter, not reads. Both were documented as unreliable yesterday.

**What it took, for the record.** Two bugs, neither in the place the symptoms pointed:

  1. `S_IN_RD` overrode `wb_op2`'s `S_WB_MEM` with a guard that read the old `st`, so every
     `in.w [R23], [Rn+]` read the port and dropped the store. Found by logging the matrix
     routine's bus accesses: the read returned the reference's exact value and no write
     followed.
  2. `m1_cdc_port` re-accepted a level request on the ack+1 edge with its old address, so two
     back-to-back coprocessor table reads returned the first's word for the second. Found by
     logging the sincos unit's traffic on both sides after the answer streams diverged on
     identical commands.

Both have directed tests that fail on the old RTL and pass on the new; both suites and the
38-suite baseline are clean.

### Scrolling: the VALUES are now the reference's, the SEQUENCE alternates — 2026-08-30

`tools/scroll_diff.py` diffs the sequence of values the V60 writes to tile words 0x5002 and
0x5006 against the reference's, both raw and as distinct values in order:

    5006  MAME  0000  2032@f273  2064@f274  2063@f275  2062@f277    advances a step a frame
          ours  0000  2064@f328  2032@f329  2064@f330  2032@f331    alternates two states
    5002  MAME  0000  0001@f276  0013@f277  0025@f278  0024@f293
          ours  0000  0001@f334  0000@f335  0001@f336  0013@f337  0025@f338

**Every value ours writes is one the reference writes** - 2032, 2064, 0001, 0013, 0025 -
which was never true before the two fixes; the coprocessor-derived arithmetic is right. What
differs is the ORDER: the reference progresses through its states once, ours flips between
two of them frame by frame. On the board that should show as the background in the right
place but jittering between two positions rather than drifting.

The value at 0x5006 is `0x2000 | (answer & 0xfff)` where the answer is the coprocessor's
reply at `FEF388` to the operand pushed at `FEF37A` (`movs.hw E5[R25]`). So the alternation is
either the V60 asking a different question on alternate frames (R25 pointing at a different
object, or E5[R25] itself alternating) or the TGP answering the same question differently.
Logging that exchange's (operand, answer) pairs per frame on both sides separates the two.

Frame offset: ours reaches the same program point ~55 frames later (f=328 against f=273),
the 1.25x speed ratio, as expected.

### Scroll: identical operands and answers, a third the update RATE — 2026-08-30

The exchange the scroll value comes from (`FEF37A` pushes the operand, `FEF388` reads the
answer), per frame, both sides:

    reference   OPER ffffef9e f=273  ffffefc5 f=275  ffffefec f=277  fffff014 f=279
    ours        OPER ffffef9e f=327  ffffefc5 f=334

**The operands are identical and so are the answers** (`42c85e9d`, `42c69b41`) - the
coprocessor path is exact. The reference runs the update every 2 frames; we run it every 7.
So the horizon lands on the right values in the right order but steps in larger jumps, which
on screen reads as flicking between positions rather than drifting. That is a RATE difference,
consistent with the 1.25x speed deficit and whatever else throttles that path, not an
arithmetic fault - and the earlier "alternates two states" reading was the same thing seen
through the write stream.

Nothing further is learnable about the 2D from here without the 3D running: the rasteriser is
what makes the rest of the frame's work exist.

### Rasterizer: objects per frame measured, quads per frame NOT measurable from outside — 2026-08-30

`docs/m3-rasterizer-spec.md` says the quad count per frame decides the sorting structure and
whether D3's premise survives, and must be measured. Attempted, and the honest result is
partial.

**Measurable.** The display lists are CPU-visible (`model1.cpp:994-995` map `0x600000` and
`0x610000` with `.share()`), so the walker can be replicated in Lua from
`model1_v.cpp:1464+`. Walked to its end marker, over 700 reference frames:

    objects per list   mean 49.8   max 59      direct (type 2) records: 0
    object size field  5500 on every one of 42,269 objects, never 0

So the frame is **~50 objects**, and the attract sequence uses no `draw_direct` polys at all -
which means the unsorted batch path is not exercised by anything measured so far.

**NOT measurable this way, and the first attempt gave a nonsense number.** Summing the size
field gave 273,827 "quads" per frame - 15 M/s on 1993 hardware, which is the tell.
`push_object` treats `size` as an UPPER BOUND (`if (!size) size = 0xffffffff;` then
`for (i = 0; i < size; i++)` breaking on an end marker inside the polygon data), and 5500 is
that bound, identical for every object. The real count is where the loop breaks, in
`m_poly_ram`/`m_poly_rom` - MAME-internal arrays, not in the CPU map, so no Lua tap or read
can reach them.

**Getting the real number needs one of:** a patched MAME that counts `m_quadpt` advances;
walking the polygon ROM ourselves once its format is transcribed; or measuring it from our own
list walker when one exists. None is a five-minute job, and the spec is right that the number
comes before the design - **50 objects a frame does not tell you whether that is 500 quads or
50,000**, and the difference decides between per-band insertion, a hardware merge sort, and a
bucketed approximation.

### Scroll: values exact, rate ~40x low, and the cause is NOT the I/O flag — 2026-08-30

Corrected from "diagnosed": the arithmetic is diagnosed, the rate is not.

    scroll exchange (FEF372/FEF388)   reference 114 in ~227 frames, every 2
                                      ours        3 in 526 frames

Operands and answers are identical where they occur, so the coprocessor path is exact. A
1.25x speed deficit cannot produce 40x, so the earlier attribution to speed was wrong.

**Walked up the call chain, edge-detected** (`dbg_pc` is a level; comparing it directly counts
cycles, which has caught me twice):

    ours       fe1c09=753  fe1c15=419  feeb10=1  | feef14=3   fef047=3   fef372=3
    reference  FE1C09=47294 FE1C15=35388 FEEB10=1 | FEEF14=266 FEF047=266 FEF372=266

The dispatch loop and its indirect calls run (753/419 against 47,294/35,388 over a longer
window), and `FEEB10` is 1 on BOTH sides - an init, not the caller. The chain stops at
`FEEE49 test.b 40DC8C / FEEE4F be FEEF06`, which runs 266 times there and ~3 here, so the
routine containing it is what is not being entered.

**The I/O board command-code hypothesis is dead, measured.** Model 2's `docs/io-board.md`
establishes that the flag is a command code - 1 acknowledges, 2 copies the window, 3 clears
and restarts - and that a responder clearing on any non-zero write is "silently wrong for 2
and 3". `m1_ioboard` is exactly that responder. But Virtua Racing writes **`01` and nothing
else**, 495 times over 500 frames, all from `fe03fd`. The distinction does not arise in this
game, so this is not the fault here.

Also note the routine above the gate does `FEEE30: in.w [R23], [R1+]` - the IN-to-memory form
fixed today - so its behaviour changed with that fix and any pre-fix measurement of it is void.

### listctl matches, so rendering is not what gates the scroll routine — 2026-08-30

Checked before parking the scroll question, because if the game waited on the video hardware
then the scroll rate would be a symptom of having no rasterizer rather than a bug:

    read       ours (lc0_fixed | 0x0030)      MAME  m_listctl[0] | 0x30
    toggle     bit 2 set and every 2nd frame  MAME  (m_listctl[0] & 4) && (frame & 1)
    bit 2 clear  combinational mirror         MAME  recomputed in set_current_render_list

`m1_listctl` reproduces all three. That register is the ONLY signal MAME models from the
rendering side back to the game, so the absent rasterizer is not throttling `FEEE49`, and the
40x scroll-rate deficit is a real and separate defect.

**Parked deliberately anyway.** With only the sky and sea drawn there is nothing on screen to
judge the scroll against, so the next measurement of it is worth more after the rasterizer
than before. The chain is recorded above to the exact instruction (`FEEE49 test.b 40DC8C`,
266 executions against 3) for whoever picks it up.

### M2's exit criterion is met, and the coprocessor does NOT do the vertex transform — 2026-08-30

**M2's criterion**, `docs/m2-tgp-integration.md` step 6: "Polygon list capture off
`copro_fifo_out`, diffed frame by frame against MAME. Bit-exact agreement with the reference,
checked in volume." Measured today with `tools/copro_stream_diff.py`, shipped configuration:

    commands  IDENTICAL over all 4,000 captured
    answers   IDENTICAL over all 4,336 captured    (answers ARE copro_fifo_out)
    sincos    IDENTICAL over 1,545 events

That is the criterion, and it became true when the `IN`-to-memory and CDC-port bugs were
fixed. Volume is moderate rather than the millions the unit fuzzes ran to, so the honest form
is: bit-exact over every command and answer in a 526-frame window, with the streams captured
at the FIFO on both sides.

**And the same data corrects the doc's premise about the transform.** That file says "The TGP
does the transform *and* the maths the game logic consumes". The output volume says otherwise:

    coprocessor answers   168 per frame (58,868 over 350)
    objects per frame     ~50, each with a size bound of 5500
    a per-vertex transform of 50 objects x 10 polys x 4 vertices would be ~2,000/frame

168 results a frame cannot carry the frame's transformed geometry - it is not even enough for
a 4x4 matrix per object (800 floats). The display list also carries `poly_adr` POINTERS into
polygon ROM (`push_object(tex_adr, poly_adr, size)`), and `model1_v.cpp` transforms that
model-space data itself at draw time. So the transform is downstream of the coprocessor, in
the video hardware, and **M3's scope includes vertex transform, projection and frustum
clipping** - not just the fill path that exists.

That is a materially bigger M3 than "wire up the fill unit", and it is better known now than
after building the wrong thing. What exists (`m1_raster_fill`, verified over 152,025 quads)
takes ALREADY-PROJECTED screen coordinates, which is the last stage of that pipeline.

### M3 and M4 sizing, measured — the polygon ROM is not loaded and sound is 8,837 ALM

**The `polygons` region is absent from our MRA.** Virtua Racing's ROM regions against
`mra/Virtua Racing.mra`:

    maincpu          12 files, all 12 present     5.2 MB
    copro_data        4 files, all  4 present     2.0 MB
    tgp_copro         4 files, only 1 present     4.1 MB   <- partial
    polygons          8 files, NONE present      16.0 MB   <- the 3D models
    ioboard:eeprom    1 file,  none present        128 B
                                        total     27.4 MB

**There is nothing for a rasterizer to draw until those eight files are loaded.** This is the
same class of miss as the coprocessor data ROM, which CLAUDE.md records as costing two
sessions of a stalled coprocessor with a 2.25 MB length mismatch sitting in plain sight -
and `make verify_mra` exists precisely to catch it.

27.4 MB fits the single 32 MB stick D2 requires (D2 sized it at "roughly 31 MB"), but the
polygon ROM is over half of it, and the rasterizer's traffic against it has never been in a
bandwidth budget.

**M4's area is measured, not estimated - from the Model 2 core's own fit report**, which
builds the same sound board (68000 + YM3438 + 2 x MultiPCM):

    m2_sound_board   8,837 ALM        fx68k          1,995
      multipcm x2    3,703              pcm_fetch x2 2,273
      jt12 (YM3438)    631

**8,837, against my guess of 6-8k and against 11,772 ALM free.** That leaves ~2,900 for the
whole of M3, which the transform, projection, clipping, sort and band buffer will not fit
into. Freeing area is therefore a prerequisite for M3+M4 together, not a later tidy-up, and
the debug overlay is only **207 ALM** (`m1_diag`; the 1,058 in `osd:*` is the framework's
menu, not ours). The V60 is 17,643 - 59% of the design - and Model 2's i960 does a comparable
job in 7,200.

### Costed: dropping one MultiPCM saves ~3,000 ALM and 4 MB of ROM

From the Model 2 core's fit report, a PCM channel is the chip AND its fetch unit:

    m2_multipcm:u_pcm1  1,861   +  m2_pcm_fetch:u_p1fetch  1,151  =  3,012
    m2_multipcm:u_pcm2  1,841   +  m2_pcm_fetch:u_p2fetch  1,122  =  2,963

So one channel is ~3,000 ALM, taking the sound board from 8,837 to ~5,800, and 4 MB off the
ROM budget with it.

**It is not a polyphony trade.** `M1AUDIO_MPCM1_REGION` and `M1AUDIO_MPCM2_REGION` are two
SEPARATE 4 MB sample regions in every Model 1 set, so dropping one loses whatever sounds live
in that half rather than reducing the voice count on a shared bank. Acceptable to get sound in
at all; it will be audibly missing something specific rather than thinner.

### M3: the 3D path carries LIT RGB, not a palette index, and 24bpp doubles the band — 2026-08-30

**The compositing interface in `m1_tile_mixer` is the wrong shape for the real thing.** It
takes `poly_index[11:0]`, a palette index, at priority between the cat1 and cat0 tiles. But
MAME's quad colour is

    cquad.col = scale_color(machine().pens[0x1000 | (m_tgp_ram[tex_adr-0x40000] & 0x3ff)],
                            MIN(1.0, ln));

a palette entry **multiplied by a lighting factor**, which lands between palette entries -
hence `fill_quad` writing into a `bitmap_rgb32` while the tile path stays indexed. An index
cannot carry it.

Two ways to composite, and the mixer needs a change either way:

  * the mixer keeps deciding the winner and gains a "the poly won" output, with the final
    RGB muxed after the palette lookup - small, and keeps the tile path indexed;
  * or the mixer moves downstream of the palette and works in RGB throughout - larger.

**And the pixel width is not a linear trade, because M10K packs by configuration:**

    17 bits  x20 (512x20)    62 blocks single, 124 double
    16 bits  x16 (512x16)    62 blocks single, 124 double
    25 bits  x32 (256x32)   124 blocks single, 248 double    <- 24-bit RGB + hit
                                                     free: 181

**24-bit colour DOUBLES the band buffer**, because 25 bits rounds up to a x32 configuration
and halves the words per block. So RGB565 + hit at 62 blocks is the efficient point, and
`docs/m3-rasterizer-spec.md`'s "16bpp costs nothing in fidelity" is right about the palette
entries being xBGR-555 but does not account for the lighting multiply - lit polygons DO get
quantised to 5-6-5.

**A third option preserves full precision at the same 62 blocks**: store the 10-bit palette
index plus a ~5-bit lighting level plus the hit bit, and apply `scale_color` at scanout. It
costs a second palette read port, which the current single-ported `m1_palette` does not have.
Recorded rather than taken - it is the better answer if the port is affordable when the
scanout is built.

---

## The polygon ROMs were never in the MRA — 16 MB of geometry the core could not have read

**2026-08-30.** `vr`'s `polygons` region is eight 2 MB files loaded as four
`ROM_LOAD32_WORD` pairs (`mpr-14890`..`14897`, at 0x000000/0x400000/0x800000/0xc00000),
and **not one of them was in the MRA or in the packer.** The core has never had access to
the 3D geometry at all.

Nothing noticed, and nothing could have: with no rasterizer, a missing 16 MB region looks
exactly like a working core. **This is the coprocessor data ROM's failure repeated** —
that one was in the packer but not the MRA, so simulation worked and hardware stalled for
two sessions. `make verify_mra` exists because of it and is what caught this pair being
added consistently now:

    MRA expands to   25,427,968 bytes
    packer produces  25,427,968 bytes
    OK  every byte matches

Both tools grew the region independently — `POLYGONS`/`POLY_OFF = 0x840000` in each — so
the layout keeps the two sources the check depends on.

**The map strings are `0021` and `2100`**, derived from the existing `copro_tables` pair
and confirmed against it: for `output="32"` the digits run byte 3 down to byte 0, so a
part supplying bytes 0-1 of each word is `0021` and one supplying bytes 2-3 is `2100`.

**And `vr.zip` does not contain `mpr-14897.33`.** It has seven of the eight. The eighth is
in `~/roms/vr decapped/` at MAME's exact CRC (`74873195`), so the file is good and the set
is short — checked against the loose directory first, because CLAUDE.md records
`315-5573.bin` being declared missing on a zip-only audit when it was sitting in
`~/roms/vr/`. `build/vr_full.zip` is the completed set used for verification; **a MiSTer
will fail to load this MRA until that file is added to the user's `vr.zip`.**

The stream is now 25.4 MB of a 32 MB SDRAM, leaving ~6.5 MB. The polygon base is
0x840000 bytes = `24'h420000` in the `[24:1]` word addressing `m1_integrated.sv` uses for
`COPRO_DAT_BASE`/`COPRO_TBL_BASE`.

---

## `OPTIMIZATION_MODE "Aggressive Area"` buys 469 ALM and costs most of the timing margin

**2026-08-30**, full `make rbf`, Quartus 17.0, 0 errors, against the `ab4ae51c` baseline
built from the same tree:

|              | baseline   | Aggressive Area | delta |
|---|---|---|---|
| ALM          | 30,138     | **29,669**      | **-469 (-1.6%)** |
| M10K         | 372        | **383**         | **+11** |
| DSP          | 50         | 50              | 0 |
| worst setup  | +0.375 ns  | **+0.103 ns**   | **-0.272 ns** |

So it is real but small, and it is **not free**: it pushes logic into memory and spends
nearly three quarters of the slack to do it. 469 ALM is 1.6% against an M4 sound section
measured at 8,837 ALM in the Model 2 project — it does not change what fits.

**Not adopted as the default.** `M1_QOPT="Aggressive Area"` remains opt-in in
`tools/mister_project.sh`. Burning 0.272 ns of margin for 1.6% is the wrong trade while
ALM is not the binding constraint; the setting is worth taking when sound and the
rasterizer have actually made it binding, and the slack can be re-checked then.

---

## Virtua Racing draws NOTHING through the direct path — the geometry engine is mandatory

**2026-08-30**, `tools/mame_dlist_census.lua`, 120 samples over 1,200 frames of attract.

The 3D path has two drawing commands and they cost wildly different amounts to
build. Command 1/0x41 is *draw object*: an address into the polygon ROM, which the
hardware must read, transform by the current matrix, project, light and clip.
Command 2 is *direct*: quads already in screen space, sitting in the list, needing
a fill and a sort and nothing else.

    type   1 OBJECT           7880
    type   2 DIRECT              0        <- none, ever
    type   b matrix            7880
    type   3 viewport           187
    objects drawn      7880
    direct sub-quads   0
    distinct objects   224

**Zero direct quads.** The hoped-for shortcut — a rasterizer with a fill unit, a
band buffer and no geometry stage, drawing whatever the list already holds in
screen space — draws an empty screen on this game. It is not a partial win; it is
nothing. `m1_raster_fill` and `m1_raster_band` cannot show a single pixel until
transform and projection exist to feed them.

One matrix command per object, and a single viewport all run:
`248,231 0,39 495,422` — centre (248,231), the full 496x384 active area offset by
the 39-line top border the reference subtracts.

---

## The geometry budget: 5,831 polygons in a peak frame, 34 cycles per point

**2026-08-30**, `tools/mame_poly_budget.lua`, 60 sampled frames, walking each
object in the polygon ROM exactly as `push_object` does — a 6-float header then
10-float records until one has type 0 in its flags.

    peak frame         5831 polygons in 41 objects
    mean frame         3204 polygons in 34 objects
    peak points/frame  11662   (2 per polygon record)
    cycles per point   34.1    at 22.86 MHz and 57.5 Hz

Measured **before** building the stage, not after, because the answer decides its
shape. Per polygon record the reference does a 3x3 transform of two points and a
normal, a projection divide per point, and a lighting dot product: roughly 27
multiplies, 24 adds and **2 divides**, in the ~68 cycles two points are worth.

Multiplies and adds fit comfortably — one pipelined `fp_mul` and one `fp_add` at a
result per cycle cover 27 and 24 cycles and overlap each other.

**The divider is the constraint.** `fp_div` measures `max_latency=29` and is not
pipelined, so two projections per record is up to 58 of the 68 cycles on their
own. One divider *just* fits with nothing to spare and no allowance for the frame
being longer than average; the honest reading is that the geometry stage needs
either a second divider or a table-based reciprocal.

**And the reciprocal table exists in the ROM set we do not load.** MAME's
`other_data` — `opr-14744`..`14747`, the 1/x and 1/sqrt tables — was deliberately
left out because `fp_div` computes those instead (see the `wpair` comment in
`gen_mra.py`). That decision was made for the coprocessor, where it is right; for
the geometry stage the trade is the other way round, and the reversal condition is
this measurement. Recorded, not yet taken.

Data rate is not a concern either way: 5,831 records of 40 bytes is 233 KB a
frame, 13.4 MB/s, sequential — nothing for the SDRAM controller.

---

## The geometry stage fits, and the reciprocal is 94% of it

**2026-08-30.** Both stages built and measured against the 68-cycles-a-record budget:

| stage | per record | share of a peak frame |
|---|---|---|
| `m1_geo_xform`, 3 transforms | 57.1 cycles | 84% |
| `m1_geo_project`, 2 points   | 64.1 cycles | 94% |

They run on separate units so the frame cost is the larger, not the sum: **94%**.
It fits, and it fits with almost nothing spare — any stall the measurement does
not model (polygon fetch from SDRAM, backpressure from the fill stage) pushes the
peak frame over. `fp_div` is 29 cycles and does not pipeline, so 29 of those 32
cycles a point are the reciprocal alone. **A second divider halves it to ~47% and
is the obvious lever if integration needs one.** The mean frame is 3,204 records,
so this is a peak-frame concern, not a typical one.

**Both stages needed restructuring that only a THROUGHPUT test could have asked
for, and in both cases the first version of that test measured the wrong thing.**
Submitting one point and waiting for its result measures latency; it reported
`m1_geo_xform` at 34 cycles when its streamed figure is 19, and
`m1_geo_project` at 57 when its streamed figure is 32. A pipeline that exists to
overlap two points cannot be measured one point at a time. Written down because
the mistake was made twice in one evening, the second time knowing about the
first.

Streaming then found a real bug in `m1_geo_xform` that one-at-a-time never could:
`in_ready` let a new point overwrite a product bank the adder had not yet
collected, because `fill_bank` flips when the adder TAKES the products, not when
the multiplier finishes them.

**The projection's deviation from the reference is now bounded by its bench, not
just by a comment.** 19,613 fuzzed points: one differed by a single pixel
(0.005%), none by more. The bench asserts both halves — never more than one pixel
out, and a difference rate near the measured 0.002% — because a systematically
wrong reciprocal would pass a "within one pixel" check on every point while
differing on far too many of them.

---

## The painter's sort needs a quad store, and it does not fit in M10K

**2026-08-30**, from `sort_quads` and `quad_t::compare` (model1_v.cpp:535-560).

Model 1 has no Z-buffer. `draw_quads` paints in sorted order — **z descending,
ties broken by submission order** — so every quad of a viewport has to be
collected before any of it can be drawn. VR uses a single viewport for the whole
list (measured: one `viewport 248,231 0,39 495,422` across 1,200 frames), so
"every quad of a viewport" is every quad of the frame: **up to 5,831**.

That store is the problem, and it is worth stating before more of M3 is built on
the assumption it is free.

A quad needs four screen vertices, a colour and a sort key — about 184 bits packed,
so 5,831 of them is **1.07 Mbit, roughly 105 M10K blocks**. The current build
leaves 170 free (383 of 553 used), and the band buffer wants 62 of those single-
buffered. 105 + 62 = 167 of 170, with the binning structures and everything else
in M3 still to come. It does not fit.

**So the quad store belongs in SDRAM, not M10K.** 5,831 quads is 134 KB a frame to
write; with a 64-row band buffer the picture is six bands, and a quad is read once
per band it touches — call it 1.5 on average, so ~335 KB a frame, **19 MB/s**.
That is nothing for the controller, and the polygon ROM traffic measured earlier
(233 KB a frame, 13 MB/s) sits alongside it comfortably. SDRAM has ~6.5 MB spare
after the 25.4 MB ROM image.

The sort itself is affordable: 5,831 elements is ~76,000 comparisons at log2 n,
against 397,515 cycles in a frame. It is the STORAGE that forced the decision, not
the comparisons.

The comparator is exact and must stay exact — descending z with ties resolved by
submission order. `qsort` is not stable, so MAME makes the order total by falling
back on the address; an approximate bucket sort by z would reorder coincident
quads and is not a shortcut available here.

---

## One multiplier and one adder serve the whole geometry stage — measured, 446 ALM a copy

**2026-08-30.** The stages were first built with private arithmetic: a multiplier
and an adder each in `m1_geo_xform` and `m1_geo_det`, both plus a divider in
`m1_geo_project`. Three of each. Counting what a polygon record needs:

    transform    3 points     27 mul   24 add
    determinant               9 mul   11 add
    projection   2 points      8 mul    8 add   2 div
                             ---------------------------
                              44 mul   43 add   2 div

against 68 cycles a record. `fp_mul` and `fp_add` retire one result per cycle, so
**one of each runs at 65% and 63%.** Three of each was convenience, not necessity.

Measured on the same module, Quartus 17.0, before and after moving its units to a
shared pool:

    m1_geo_xform   private mul+add   1,444 ALM
    m1_geo_xform   pooled              998 ALM      -446
    m1_fp_pool     mul + add + div + arbitration  1,264 ALM

So a private multiplier-and-adder pair is ~446 ALM, and the whole pool — including
the divider that could never be shared away because there was only ever one — costs
less than three of those pairs. Round robin rather than fixed priority: at 65%
utilisation priority is *almost* always fine, and "almost always" is how a stage
starved on the busiest frames gets shipped.

The refactor is behaviour-preserving: all three benches report identical numbers
and identical throughput afterwards.

**The one thing sharing forces on every client**: an issue must advance only on a
GRANT. With a private unit each issue was accepted, so a schedule counter could
run free; shared, a cycle lost to arbitration silently drops an operand and leaves
a result short forever.

---

## Virtua Racing needs the whole lighting path, and it does not fit one divider

**2026-08-30**, `tools/mame_light_census.lua`, 100 samples over 1,200 frames.

Measured before building the colour unit, on the theory that the cheapest unit is
the one that is not built. Nothing could be dropped:

    command 7   spec_enable=1 on 294 of 294 mode words   specular is ALWAYS on
    command 6   banks with s=255 p=7, and banks with s=0 p=0
    command 4   mode 0 155,876   mode 1 (blinking) 5,832
                mode 2   6,336   mode 3 (unlit)  40,852

So the specular term, the alternate-frame channel rotation and the unlit flag are
all live for this game. 22% of colour words set the unlit bit and 2.8% blink.

**And that creates a budget problem.** `glm::normalize` on the polygon normal is a
reciprocal square root, once per record, on top of the two reciprocals projection
already needs. Three expensive operations a record, and `fp_div` is 29 cycles
unpipelined: **87 cycles against a budget of 68.** The geometry stage as MAME
writes it does not fit behind one divider.

Three ways out, in the order they should be considered:

1. **The precision requirement is low and worth measuring.** The normalize feeds
   `dif`, which feeds `lumval = 255*min(1,ln)` and is then shifted right by two —
   a **6-bit** output. A relative error of ~1.6% is invisible in it. Specular
   squares its argument up to three times, so that path needs ~8x better, but even
   then a ten-bit reciprocal square root suffices. This wants the same treatment
   the projection reciprocal got: measure the pixel-level difference, then decide.
2. **A second `fp_div`**, which brings 87 cycles to ~44. Exact, and the pool
   already has the arbitration for it.
3. **The hardware's own tables.** `other_data` — `opr-14744`/`14745` are a 1/x
   table and `opr-14746`/`14747` a 1/sqrt(x) table, 256 KB each, 64K entries of 32
   bits. They are in the ROM set and **deliberately absent from our MRA** because
   `fp_div` computes what the coprocessor needed. This is the second time that
   decision has come up against a stage that would rather have the table; the
   reversal condition is a measurement showing the table's precision is enough.

Not yet decided. Recorded so the decision is made on the measurement rather than
on whichever is easiest to write.

---

## The normalize needs 16 bits, not a divider — and the budget is per QUAD, not per record

**2026-08-30.** Two measurements that between them removed the geometry stage's
budget problem entirely.

**How accurate does the reciprocal square root have to be?** It feeds a dot
product, a specular term, and then `lumval = (255*min(1,ln)) >> 2` — **six bits**.
Over 400,000 random normals against the light parameter banks measured from the
real display list, truncating the rsqrt mantissa changes that six-bit luminance:

    10 bits   0.776% of polygons, by up to 2 levels
    12 bits   0.190%, by at most 1
    16 bits   0.013%, by at most 1
    23 bits   never

Specular squares its argument up to three times and so amplifies error eightfold;
it is that path, not the diffuse one, that sets the requirement. An 8-bit seed
table plus **one** Newton-Raphson step reaches ~16 bits, and `m1_geo_rsqrt`
measures a worst relative error of **5.7e-06** across the full exponent range —
in 23 cycles using four operations on the shared pool, against 29 blocking cycles
for a divide that does not exist anyway. **No second `fp_div`, and no reason to
load the 1/sqrt ROM tables.**

**And the per-record budget was the wrong budget for half the stage.**
`tools/mame_poly_budget.lua`, extended: of 5,831 records in a peak frame, only
**4,798 can emit a quad at all** — `push_object` jumps straight to `next` when the
record's link field is zero — and the backface test discards more of those still
(14.9% of them skip the test entirely via flag 0x4000). So the colour, clipping,
sort and fill stages run at most 4,798 times, which is **83 cycles each**, not 68.
`m1_geo_color` measures 77. Held to the transform's 68 it would have been
"25% over" and optimised against a budget it does not have.

---

## Five bugs in the colour unit, every one of which would have looked like a working picture

**2026-08-30.** `m1_geo_color` reproduces push_object's colour block. Its bench
found five faults before it passed, and the reason to write them down is that not
one of them would have produced an obviously broken screen:

1. **The light parameters were never divided by 255.** MAME stores them as
   `float(v)/255.0f` on upload; taking the raw byte makes `ln` ~255x too large, so
   every luminance saturates at 0x3f and the whole scene renders at full
   brightness. Fixed by dividing once at upload — where MAME does it — rather than
   per polygon, which would have put a divide inside the per-quad budget.
2. **`lumval >>= 2` came after the clamp instead of before.** Clamping the
   unshifted 0..255 value to 0x3f turns everything above 63 into full brightness,
   which is most of the range. Same symptom as (1), different cause.
3. **The palette base was 0x400, not 0x1000.** `pal_addr` is 13 bits so 0x1000 is
   the top bit: `{3'b100, ...}`, not `{3'b001, ...}`. The wrong bank is still full
   of colours.
4. **The colour-translation index was 13 bits in a 15-bit field.** MAME indexes
   `(c << 8) | lumval | bank`, so **bits 7:6 are zero** — packing `{bank, c, lum}`
   without that gap reads a completely different entry of a table that is
   plausible everywhere.
5. **The three lookups assumed combinational memory.** Reading `xlat_data` in the
   cycle the address is driven returns the previous lookup's word, so every
   channel got its neighbour's translation.

Each is a one-line fix and each produces a picture. That is the argument for
comparing against a transcribed reference rather than looking at output.

---

## The geometry stage draws Virtua Racing — a real frame, from real RTL

**2026-08-30.** `make render` puts one frame of the reference's own state through
`m1_geometry` and `m1_raster_fill` and writes an image.

Everything the stage reads is the reference's: `tools/mame_dump_frame.lua` writes
out the display list, the palette, the colour-translation table, the colour words
and the light banks at a chosen frame, and the models come from the polygon ROM in
the packed image. So a difference in the picture is the RTL's and not the input's.

    display list: 33 objects, 1 viewport
    viewport xc=248 yc=191  x 0..495  y 0..383  zoom 210,280  view 0,-30
    records 3604, culled 884, link-0 686, quads emitted 2001
    filled 2001 quads (168 were wireframes), 414,570 pixels painted

The picture is the attract-mode chase camera: a car, the red-and-white kerb, the
track surface, a second car up the road, and the SEGA logo. 99.8% of the frame is
painted.

**And it found a bug no unit test could have.** The first render came out entirely
black with the geometry perfect — every quad in the right place, every one the
same shade. `tex_data` read `0xffff` for every record, because
`m1_geo_walk` indexed `tgp_ram` with the RAW texture address where MAME indexes
`m_tgp_ram[tex_adr - 0x40000]`. Off by 0x40000 words, the read lands outside the
written region and returns 0xffff, which is a **valid-looking colour word with the
unlit bit set** - so nothing errored and nothing looked broken except the colour.

The per-stage benches cannot see this: they supply `tex_data` directly and never
exercise the address arithmetic. The integration bench cannot either, because it
uses the same synthetic memory for both sides. It took a real dump, where the
address means something, to expose it. **That is the argument for rendering a real
frame as a test and not only as a demonstration.**

Two pieces of the chain are still C++ rather than RTL, and both are named in the
bench: the display-list interpretation (`m1_listwalk` is verified separately and
decodes the same grammar) and the painter's sort (the quad store is an SDRAM
decision that is not built yet). Everything between an object address and a span
is RTL.

Still missing from the picture: the frustum clipper, so geometry crossing the
screen edge relies on the fill unit's 2D clamp; the band buffer, so this renders
to a full framebuffer rather than in 64-row bands; and the 2D tilemaps, so there
is no sky, no horizon and no HUD behind or over it.

---

## The sound section needs ~57 M10K, measured — and it decided the band height

**2026-08-30.** From Model 2's own fit report, `output_files/Model2.fit.rpt`:

    m2_sound_board    8,837 ALM    572,427 block memory bits   ~57 M10K

Read from the **Block Memory Bits** column, which is column 11 of the hierarchy
table. Column 14 is *Virtual Pins*, and reading that instead reports every block
as using zero memory - which is exactly the answer one wants to hear and is wrong.
Checked the header before quoting it.

This settled the 3D layer's band height. At 64 rows a band buffer is 53 M10K and
the pair 106, so the 3D layer took 145 of the 181 free and left **36** - twenty
short of what sound needs, and it would not have been discovered until the
rasterizer had been built around it. At 32 rows the pair is 54, the 3D layer is
93, and **88** remain.

The cost is twelve bands instead of six, and the quad store's band filter makes
that nearly free: a quad is replayed only for the bands its rows touch, so halving
the band height moves a typical quad from one or two bands to two or three, not
from six to twelve.

**The caveat is that Model 2's sound is an SCSP and Model 1's is a YM3438 with TWO
MultiPCMs.** 57 blocks is the closest measured analogue, not a guarantee, and the
~31 spare is thinner than it looks.

---

## clk_cpu to 23.529 MHz — and the CPI gap it does not close

**2026-08-30.** `clk_cpu` was 22.857 MHz, chosen when 23 was rejected as "not a
legal PLL output". The reason is now written down: with 80 MHz fixed on outclk0
the VCO is **800 MHz**, and every output is an integer division of it. 800/23 is
not an integer; **800/34 = 23.529** is the smallest step at or above 23.

    800/10 = 80.000    clk_sys, and the SDRAM pin at 180 degrees
    800/17 = 47.059    clk_3d
    800/34 = 23.529    clk_cpu, an exact half of clk_3d

Both halving relationships are exact, which is what keeps the 3D-to-CPU crossing a
clock enable rather than a handshake — the same arrangement Model 2 uses, where
`clk_i960` is an exact half of `clk_sys`.

Everything derived from the clock moved with it: the I/O board's deadline is a
**measured wall-clock time** (the reference answers the boot handshake in 38,577
us) and is now 907,694 cycles rather than 881,760, in the RTL, its bench and its
comment; `tb_m1_frame`'s clock period likewise.

**IT BUYS 2.9%, AND THE GAP IS 3.2x.** The measurement that matters here is
already in this file and it is worth restating next to the clock change, because
raising the clock is the intuitive fix and it is the wrong one:

    V60 core in isolation     6 CPI     the reference implies ~8 - ours is FASTER
    whole system          30.49 CPI     65% of cycles are bus stalls

The core is not the slow part. Two thirds of every cycle is spent waiting on
memory, and that is where a 3.2x lives. Clocking from 22.857 to 23.529 is 2.9% of
it. The clock change is still right — the CPU should not be below the target rate
— but it should not be mistaken for progress on throughput.

---

## The 3D block renders the reference frame: 100.0% agreement, four bugs on the way

**2026-08-31.** `make render3d` drives `m1_raster3d` alone - a frame pulse and
five memories in, a pixel out - and captures each band through the scanout port
the video path will use. Nothing orchestrated from C++: the list walk, the
per-object geometry, the sort, the band sequencing and the presentation are the
module's own.

    RTL block vs the C++-orchestrated render
      agree within RGB565 rounding   190,462 of 190,464   100.0%
      differ by more than 8                            2

**Four bugs stood between "it produces a picture" and that number, and every one
of them produced a picture.**

1. **The band geometry was three constants that disagreed.** Halving the band
   height to 32 for the sound budget left a 6-bit band mask, a 3-bit band select
   and a row-to-band index written as `y[8:6]` - a division by 64 that does not
   say so. A 3-bit counter compared against `3'(12-1)` truncates to 3, so the
   frame stopped dead after band 3, correct as far as it went.
2. **The viewport handler was an empty stub**, left that way because command 3
   emits `idx 0` for its 32-bit word AND for the first of its six 16-bit words.
   `xc`/`yc` stayed at zero and stretched the whole frame. Fixed at the source:
   the viewport's seven values now number 0..6.
3. **The zoom was missing its x4.** MAME's command 9 is
   `set_zoom(readf(+2) * 4, ...)`. Taking the word as written under-zooms the
   scene by exactly four - which looks like a stretched picture with objects
   wandering off the edges, and the quad count is identical either way. The
   multiply is free: add two to the exponent.
4. **The light vector was not normalized.** `set_light_direction` is
   `glm::normalize`, and the display list's vector is **1.0941** long - so every
   dot product came out 9.4% large and every polygon one luminance level too
   bright. A picture that looks right and is uniformly washed out.

Number 4 is the one worth remembering. It showed up as a *colour* difference
confined to one surface in the diff image, with the road and the HUD agreeing
exactly - and the quad count, the coverage and the geometry were all already
perfect. Diffing the render against a reference is what found it; no unit test
could, because the light vector is an input to the colour unit and both sides of
its bench used the same one.

The normalize is **borrowed rather than duplicated**: `m1_geometry` lends its
`m1_geo_norm` out while the stage is idle, which is exactly when the caller is
between objects. A second one would have cost ~450 ALM of multiplier and adder to
normalize one vector per frame.

---

## The 3D layer fits, and one unsynchronised register was 1,327 ns of negative slack

**2026-08-31.** The first build that fitted:

    ALM    36,582 / 41,910   87%
    M10K      518 / 553      94%
    DSP        53 / 112      47%
    worst setup slack  -5.934 ns, TNS -1,327 ns

**Five builds failed before it, each on a distinct defect that 53 passing test
suites and a pixel-exact frame render could not see:**

1. Quartus rejects a bit-select of a part-select. `att[q][AT_W-1:25][replay_band]`
   is legal to Verilator; 17.0 answers "range must be the final index in the
   indexed name". A synthesis error, not a simulation one.
2. **A four-ported array.** `vtx[NQ*4]` was written four vertices at a time and
   read four at a time. No RAM has four ports, so Quartus built all 8,192 x 32
   bits from flip-flops **and said nothing**: 166,497 combinational nodes against
   a device holding 83,820.
3. **Asynchronous reads.** `wire x = mem[addr];` is a read no block RAM can do, so
   `key`, `idx_a`/`idx_b` and `att` all stayed in flip-flops - 63,630 registers in
   one module. Registered reads cost a cycle each and changed the sort's schedule
   from three cycles an element to five.
4. **A histogram too wide.** Read-modify-written at a dynamic address, so it can
   only be registers plus a mux per entry. At 8 bits that missed fitting by 15
   LABs of 4,191 - 0.36%. At 4 bits the arrays are a sixteenth the size, at the
   cost of eight passes instead of four (21% of a frame to 41%).
5. **A reset loop still clearing 256 buckets** after the arrays became 16.
   Verilator clamps silently; Quartus refuses to elaborate.

**Ben's benchmark is what turned (2) and (3) from "3D is expensive" into "this
number is wrong".** VDP1 and the N64's RDP are 4,000-8,000 ALM, and the RDP is far
more capable. `m1_geometry` - transform, projection, cull, normalize, lighting -
measured 6,238 nodes and 5,778 registers, squarely in that range. It was the
STORE that was anomalous, and storage should cost almost no logic at all.

**Then the timing, which was one register.** Every one of the 40 worst paths began
at `m1_raster3d|wr_buf`:

    wr_buf -> ... -> m1_tdp_ram:u_pram|...|portb_address_reg   -5.934

`wr_buf` selects which band buffer the scanout reads. Unsynchronised, it fed
combinationally from a clk_3d register through `scan_hit` into the mixer's
`poly_won`, out to `pal_addr`, and onto the palette RAM's address register in the
clk_sys domain. `disp_band` and `disp_valid` were synchronised and this was not -
and it is the one that carries the data.

It changes in the same cycle as `disp_band`, so all three now cross together and
the buffer selected always matches the band advertised.

**M10K at 94% is the next problem.** 35 blocks free against the ~57 the sound
section measures on Model 2. The band-height change bought 52 and something has
since eaten them - `cxlat` rounding up to 32,768 words and the four vertex
memories are the candidates. It needs revisiting before M4.

---

## THE FRAME BUDGET WAS HALF THE REAL ONE — 397,515 against 818,133 — 2026-08-31

Every per-stage budget in this project was checked against **397,515 cycles a
frame**, in six benches and two RTL headers. That figure is a 22.9 MHz plan for
the 3D clock: 397,515 x 57.52 = 22.87 MHz.

`clk_3d` is **47.059 MHz** — its own PLL output, 800/17 — so a frame is
**818,133 cycles**. Every budget derived from the old number was half the real
one, and `tb_m1_geo_det`, `tb_m1_geo_xform` and `tb_m1_geo_project` all carry an
explicit `FAIL OVER BUDGET` test against it.

Corrected in all eight places. Nothing had failed against the wrong figure, so
the error only ever made the stages look tighter than they are — but a budget
test that is wrong by 2x is worse than none, because it drives design decisions.

---

## THE BENCH WAS TICKING BOTH CLOCKS TOGETHER, and understated the fill 3x — 2026-08-31

`tb_m1_raster3d` drove `clk` and `scan_clk` from one `tick()`. The 3D clock is
47.059 MHz and the pixel clock is 656 x 424 x 57.52 = **15.996 MHz**, so the fill
gets **2.94 cycles per pixel of raster** and the bench was handing it one.

Every throughput figure that bench printed understated the hardware by a factor
of three, including the "band fill 44,868-66,819 against a band-time of 61,741"
that drove the band-height decision. It carries the ratio as a fraction now.

It also cleared the framebuffer **once** and reported the union of eleven frames
as coverage — 93.9% for a renderer delivering a third of its bands per frame.
Per-frame now, which is what a screen shows.

**Both faults flattered the design.** A bench that is wrong in the safe direction
is still wrong, and this one hid the fact that the geometry, not the fill, was
the pole.

---

## WHERE THE GEOMETRY'S 444 CYCLES A QUAD WENT — and it was not the arithmetic — 2026-08-31

`m1_geo_walk`'s state sampled every cycle and bucketed (`tb_m1_geometry`, 20
objects, 340 quads):

    transform    32.7%      three points, one at a time
    project      38.4%      two points, one at a time
    normalize    11.7%
    colour       10.8%
    polygon ROM   3.4% at a one-cycle memory, 40% at a twelve-cycle one
    determinant   1.9%

against 44 multiplies and 43 adds a record through pipelines that retire one a
cycle — **a floor of about 68 cycles**. The stages were not slow. The walker was
issuing them one at a time and waiting for each.

`m1_geo_xform` carries a ping-pong product bank so the adds of point N-1 run
while the multiplies of point N are issued; `m1_geo_project` keeps the reciprocal
and the scale chain as separate stages for the same reason. **Both were built
that way deliberately and the walker used neither.**

The record path is a dataflow schedule now — each stage issued the moment its
operands exist — and the polygon ROM is prefetched a record ahead. **444 -> 226
cycles a quad**, and a twelve-cycle memory costs 1.0x rather than 1.4x. Exact
throughout: 3,357 quads, 0 vertices a pixel out, 0 colours different.

**A SPECULATIVE ISSUE HAS TO BE DRAINED.** Issuing the normalize before the cull
is known takes 40 cycles off the critical path — and leaving a culled record with
that normalize still in flight let its result land in the NEXT record. Measured:
**345 of 3,357 colours wrong, 10.3%, with every vertex exact.** A colour is
all-or-nothing (a luminance level selects a different translation entry), so this
looked like a lighting bug and was a scheduling one.

And **collect only what was issued**. `!collected` alone accepts any pulse the
stage happens to make, including one left over from the previous record: a link-0
record that asks for nothing ended up with a colour it could never match, and the
walk deadlocked at record 19 of iteration 19 with `cl 0/1`.

---

## THE DIVIDER IS THE FILL — radix-4, and the measurement it asked for — 2026-08-31

`m1_raster_div` was radix-2, 32 cycles, with a note that setup runs at most four
times per quad and never per pixel, and that the lever if it ever hurt was
"radix-4 or a reciprocal table, and that is a measurement to take rather than a
guess to build."

Taken. `tb_m1_raster3d` against a real raster: **FILLW 436,000 cycles a frame of
818,133**, and the quad count gives 275 cycles of fill per quad against at most
eight divides of 32.

Radix-4 is 16 cycles and the quotient is exact integer division either way, so
`tb_m1_raster_fill` is unchanged at 152,025 checks and 0 fails. **FILLW 436,000
-> 373,000.**

**Its `spans`, `lines` and `empty` totals MOVED, and that is not a regression.**
The bench's stall model draws from the same mt19937 as the quad generator, once
per cycle, so anything that changes how many cycles a quad takes reshuffles the
whole corpus: 31,637,915 spans became 31,658,020. `checks` and `fails` are the
invariants; the totals are not. This will happen again.

---

## THE SORT SPENT FIVE CYCLES AN ELEMENT WAITING FOR TWO BLOCK RAMS — 2026-08-31

`m1_quad_store`'s radix sort walked `key` and `idx` through five sequential
states per element, because both reads are registered and an asynchronous read
of `key` had cost 65,536 registers. That is 5 x 2 loops x 8 passes = **80 cycles
a quad**, and **812,776 cycles of the render bench, 7.1% of everything**, to sort
at most 2,048 items.

Pipelined to one element a cycle — the same shape the **replay path forty lines
below it in the same file** already had — it is **172,584**. 2,000 quads sort in
34,330 cycles.

The index that belongs with a digit has to be carried alongside: `cur_idx` has
already moved on two elements by the time its key comes back.

---

## BAND 0 WENT UP HALFWAY DOWN THE SCREEN — 2026-08-31

The pass is geometry, then sort, then 24 beam-locked band fills. The geometry is
367,000 cycles and the sort 21,000, so **band 0 was ready with the beam at band
11** — and `in_disp_band` then correctly refuses to draw rows 0..191 during rows
192..383. Sixteen of twenty-four bands presented, 257 of 384 rows painted, and
every band was on time by its own rule.

Band 0 now waits for a vblank the **band phase** sees: the one it is in if the
geometry finished inside it, otherwise the next.

**Clearing the arm on `frame_start` alone did nothing at all.** The blank flag
comes through two synchroniser stages, so it rises three cycles AFTER
`frame_start` and re-armed immediately — the run printed byte-identical numbers
twice, which is the only reason it was caught rather than believed.

Result: **95.9% of pixels, 369 of 384 rows, 23 of 24 bands**, every second frame.

---

## THE 3D LAYER IS 28.8 Hz, and the reason is the quad store — 2026-08-31

Work per pass, measured by state (`tb_m1_raster3d`, the reference's frame 900):

    geometry (OBJW)   367,000
    fill     (FILLW)  373,000
    sort     (SORTW)   21,000
    clear    (CLRW)    34,000
                      -------
                      796,000   against 818,133 in a frame

It fits — and it still takes two frames, because **the geometry cannot overlap
the fill**. Both use the quad store: the geometry writes it, the sort orders it,
and every one of the 24 band fills replays it. So a pass is
`geometry + one whole beam traversal`, about 1.2 M cycles.

The fill itself is idle for 445,000 of the 818,133 it is stretched across, so the
geometry would fit inside it exactly — with a **double-buffered quad store**.
That is `vtx0..3` (26 M10K), `key` (8), `att` (10) and `idx_a`/`idx_b` (5) again:
**+49 M10K**, against 100 free and ~57 wanted by the sound section.

So 28.8 Hz for the 3D over 57.5 Hz for the 2D is the shape of this design until
either the quad store shrinks or the geometry reaches ~77,000 cycles, which is
what fits in vblank. **Not a throughput problem any more.**

---

## 28.8 Hz IS THE BOARD'S OWN GEOMETRY RATE — measured, not a shortfall — 2026-08-31

Our 3D layer completes a render pass every second frame, and the entry above
calls that a consequence of the quad store. It is also **exactly what the
reference does**, which changes what it means.

`tools/mame_listctl_rate.lua`, 2,000 frames of `vr`:

    bit 2 (automatic double buffer) set on 4 frames
    buffer flipped 996 times
    frames between flips:  2 frames: 993 times
                           1 frame: 1,  3 frames: 1,  10 frames: 1
    register values:  00b2 on 1,001 frames,  00fa on 995
    => new geometry at 28.64 Hz of a 57.52 Hz refresh

**Virtua Racing presents a new display list every two frames.** 993 of 996 flips
are exactly two frames apart; the three exceptions are at the boot/attract
transition.

And it does it **by hand**, not through the hardware's automatic mode:
`model1_v.cpp:1351` toggles bit 6 on odd frames only when bit 2 is set, and bit 2
is set on 4 frames of 2,000. The game alternates `00b2` and `00fa` — bit 3, which
bit 6 mirrors on the `!(listctl[0] & 4)` path. `m1_listctl` already implements
both paths; the measurement says which one is used.

**So the 3D layer running at 28.8 Hz over a 57.5 Hz 2D layer is the hardware, not
a compromise.** A 3D layer that updated every frame would be rendering the same
display list twice. The band architecture's cadence and the game's happen to
agree, which is luck rather than design - but the number to hold it to is 28.64,
and it meets it.

---

## MAME CANNOT RUN `vr` IN THIS TREE WITHOUT A DEVICE-ROM OVERLAY — 2026-08-31

Every instrument in this project, and `make v60_trace` and `make tgp_trace` with
them, dies before the machine starts:

    epr-14869.25 NOT FOUND (tried in model1io vr)
    epr-15112.17 NOT FOUND (tried in m1comm vr)
    Fatal error: Required files are missing, the machine cannot be run.

These are **device** ROM sets, not part of `vr.zip`: the I/O board's own 68000
firmware and the comm board's. MAME 0.289 treats both as required and will not
start, and `-video none` means there is no warning screen to dismiss - the
documented "press a key once and autoboot proceeds" does not apply to a fatal
error.

Both are on this machine, in other sets:

    epr-14869.25   ~/roms/Model2/daytona93/
    epr-15624.17   ~/roms/vr/vformula/     (the OTHER m1comm bios)

`epr-15112.17` is on no disk here — not in `vr.zip`, not in `vr.7z`, not in the
decapped set. The overlay in `build/roms/` supplies `epr-15624.17` under that
name, which MAME accepts with a `WRONG CHECKSUMS` warning and runs. The comm
board is not linked in a standalone run and the V60 only touches it at
`0xb00000`-`0xb01002`, so the substitution is visible in the log and not in the
measurement — **but say so whenever a result comes from a run made this way.**

    mame vr -rompath "$HOME/roms;<project>/build/roms" \
            -skip_gameinfo -autoboot_delay 0 -video none -sound none -nothrottle \
            -autoboot_script <script>.lua

`build/roms/` is gitignored like everything else under `build/`, so hard rule 2
holds. `tools/mame_run.sh` wraps this so it is not re-derived a third time.

---

## THE 3D REWORK COSTS 369 ALM — the whole day's work, measured — 2026-08-31

`make rbf`, Quartus 17.0, 0 errors, and no negative TNS on any clock:

    36,979 ALM of 41,910   88%      4,931 free   (+369 on 36,610)
       504 M10K of 553     91%         49 free
        53 DSP  of 112     47%
    worst setup slack   +0.318 ns

    s32_v60:cpu        17,264 ALM   47% of the whole design
    m1_raster3d         6,977 ALM   922,912 bits
    m1_tgp              2,434 ALM
    m1_video              789 ALM
    m1_diag (overlay)     176 ALM

**+369 ALM for all of it** — three band buffers instead of two, a radix-4
divider, a sort pipelined to one element a cycle, and a geometry walker
restructured from a chain into a dataflow schedule with a ROM prefetch. The
throughput came from scheduling, and scheduling is cheap.

**M10K at 91% with 49 free is now the number to watch.** The sound section needs
84 as measured and about 20 once the 68000's work RAM moves to SDRAM, so it fits
- and a double-buffered quad store, the thing that would take the 3D layer to
57 Hz, wants 49 more and does not.

---

## THE SDRAM TAIL IS NOT ARBITRATION — a bounded CPU boost bought 0.01 cycles — 2026-08-31

The V60's data bus, measured on the current design with every master live
(`tb_m1_frame`, 400 M cycles):

    10,634,698 data accesses, mean 12.05 samples of the 80 MHz clock
    histogram   2:58%   8:9%   28:1%   31:7%   32:10%   35:4%   38:2%
    CPU         data stall 32.83%   fetch stall 0.61%   17.49 CPI

**The 9-cycle fixed handshake is gone.** `docs/findings.md`'s 2026-08-20 entry
had every page costing the same 36 fast cycles whether BRAM or SDRAM, which was
handshake overhead. That predates the V60 moving to its own clock domain, and it
no longer holds: **58% of accesses complete in two samples** — under a CPU cycle,
free.

**And fetch stall is 0.61%.** The instruction cache is doing its entire job.
There is nothing left to win on the fetch side.

What remains is bimodal: a quarter of accesses take 28-39 samples, about 9.2 CPU
cycles, and that is 33% of every cycle the CPU spends.

**The obvious explanation was queueing** — p0 waits behind six other masters and
the 3D layer added two of them the same day. So p0 was given a bounded
pre-emption: it may jump the rotation but not if it won the previous grant, which
caps its share at half and cannot starve the character fetch's hard deadline.

    before   mean 12.05, data stall 32.83%, 17.49 CPI
    after    mean 12.04, data stall 32.82%, 17.49 CPI

**Nothing. One hundredth of a cycle.** The tail is the SDRAM round trip itself -
the CDC out, the service, the CDC back - not the wait for a grant. Reverted
rather than kept: unproven logic on a design at 90% of its ALM is a cost with no
benefit.

**So the lever is not to serve the access sooner but to not make it.** A data
cache for the V60's work RAM turns that quarter into two-cycle hits, and 4-8 KB
of it needs about 5 M10K on a device with none free — which is what makes
right-sizing the display-list buffers (32,768 words each where the game's list
ends at word 0x2006, +64 blocks) a prerequisite rather than housekeeping.

---

## THE REFERENCE V60 RETIRES 2,015,165 INSTRUCTIONS A SECOND — measured — 2026-08-31

Assumed at "about 8 CPI at 16 MHz, so 2 M/s" for the whole speed budget and
never measured. Measured now, because the budget rests on it: a full MAME
instruction trace of `vr`, one emulated second, `noloop`, counting retired
instructions.

    2,015,165 instructions in 1 emulated second

The assumption was right to within 1%. Ours, from the same bench that gives the
CPI: 7,233,673 retires in 126,571,439 cycles at 23.529 MHz = 5.379 s, so
**1,345,000 a second — 67% of the reference, a gap of 1.50x.**

**THAT DOES NOT MATCH WHAT THE BOARD LOOKS LIKE.** Ben times the MiSTer against
real running time and reads about a third. Instruction throughput cannot explain
a factor of three, so something beyond it is costing us and counting
instructions will not find it. The end-to-end metric is the display-list swap
rate - one swap per completed game-logic frame - and the reference's is measured
at exactly 2 video frames (`tools/mame_listctl_rate.lua`, 993 of 996). Ours
against that number is the game-speed ratio with no modelling in it at all.
