# Incremental bring-up from the last known-good hardware build

**Rule: one change per build. Flash it. Confirm on the board. ONE COMMIT PER
ADDITION, on this branch, recording the hardware result. Do not add the next
change until the current one is confirmed and committed.**

Each rung's commit message carries: what was added, the build's slack and ALM,
and the telemetry from the board - `P` non-zero (works) or `P=0000` (broken),
with the swap rate. That way the branch history IS the bisect record, and a
future session can see exactly which change was on the board when.

Two days were spent flashing images containing eight changes at once and
attributing each black screen to whichever piece had been touched most recently.
Five different "found it" moments all produced the same black screen, because the
experiment could not distinguish them.

## ALWAYS `rm -rf build/mister` BEFORE A BUILD

`tools/mister_project.sh` does not fully refresh the staging directory, so files
from a previous build survive into the next one. Measured 2026-09-02: after
switching to this branch, `build/mister/Model1.sv` still carried `dbg_dc_dropped`
from the data-cache work and the build failed with 102 errors naming a port that
does not exist on this branch.

Worse than the failure is the case where it does NOT fail: a stale file that
still elaborates produces a build from a MIXTURE of branches, which is
unattributable. Some builds over the preceding two days did not clear staging.

## Base

`61e383e` — confirmed working on the board by Ben, 2026-09-02.
Binary and md5 in `known_good/`. Built with `M1_SEED=5`, closes at +0.061.

## The ladder

| # | change | commit | why it might break the board | status |
|---|---|---|---|---|
| 1 | display lists halved | `cc3b548` | 64 M10K freed; reads above the cap return zero | **WORKS** - 41,310 ALM, 495 M10K, +0.340 |
| 2 | data cache, WITH its burst and crossing changes | `949c0a8` | caches charram, wram, rom, nvram; changes bus occupancy for all seven masters | untested |
| 3 | FP pipelining | `7418cfd` | −1,672 ALM, one extra cycle on FP arith | untested |
| 4 | SDRAM arbiter registered | uncommitted | −1,305 ALM, changes grant timing | untested |
| 5 | pixel census pipelined | uncommitted | telemetry off the critical path | untested |
| 6 | TGP at 2:1 + CDC | uncommitted | the coprocessor at the board's own ratio | untested |

**Rungs 2-4 of the original plan are ONE change and must not be split.** Making
port 0 burst four words requires the requester to send burst-aligned addresses
and select the wanted word from the 64-bit return - which is precisely what
m1_dcache does. Split apart, `m1_main` would send unaligned addresses and take
`p_dout[15:0]`, reading the wrong word. The widened crossing exists for the same
reason: so a 4-word line arrives in one transaction. Testing them separately
would be testing something that was never meant to work.

## Verify each step on the BOARD, not in simulation

Simulation has passed every one of these. It does not reproduce the failure.

    ssh root@192.168.1.105 "stty -F /dev/ttyS1 115200 raw -echo; cat /dev/ttyS1"

## The signature of a WORKING core, recorded on the board 2026-09-02

    F=003A S=000E B=011C P=0039     <- P NON-ZERO is the test

`P` is the 3D object count. A working core reports it non-zero. **Every one of
the two days' worth of failing captures had `P=0000`**, with `S` pinned between
23 and 29 and nothing on screen at all - neither 2D nor 3D. So "does it work" is
answerable from the telemetry alone, without anyone watching the television, and
a rung of this ladder can be judged in the six minutes it takes to capture.

Full reference: `known_good/uart_working_reference.txt`.

Capture five minutes minimum — the game needs about four to reach steady state.
`S` is only meaningful while `P` is non-zero. A healthy board draws both layers;
`S` pinned at 29 with `P=0000` is the failure signature seen throughout.


## Open question: the FP cut's area saving

The first FP pipeline cut was recorded as **-1,672 ALM** (41,372 -> 39,700),
measured on the full stack. Measured alone on this branch it is **-276**
(41,310 -> 41,034).

Both builds should have used the default `Aggressive Area` optimisation, but that
was not verified at the time, so the two figures are not known to be comparable.
Ben's recollection is that the larger figure may have been taken with aggressive
area explicitly enabled.

Worth settling, because area is what blocks the 2:1 coprocessor: `tools/mister_project.sh`
now takes `M1_QOPT`, `M1_QTECH` and `M1_QDUP` independently, so the same RTL can
be built both ways and compared directly.

## The design has almost no timing margin

Step 3, identical RTL, four seeds:

    SEED 5   -0.187
    SEED 3   -0.523
    SEED 1   +0.026    <- the only one that closed
    SEED 4   -0.420

Half a nanosecond of spread from placement alone. Single-seed builds are a
lottery at this occupancy, which is why `build/tmp/seeds_par.sh` runs four at
once - Quartus only exploits about five of 32 cores per build, so four
concurrent builds cost nothing and turn an 80-minute sweep into 25.

## Where the V60's 16,867 ALM actually goes — MULTIPLEXERS

Measured from `Model1.map.rpt`'s Multiplexer Restructuring Statistics, 2026-09-02.
The i960 in the Model 2 core is a more capable CPU in 7,200 ALM; ours is 2.3x
that, and it is not architecture.

    826 multiplexers attributed to s32_v60, including
     13 x 32:1   4,557 LEs  (~2,278 ALM, ~175 ALM each on 32 bits)
    109 x  4:1
     45 x  3:1
     31 x  7:1
     24 x  5:1
     23 x  9:1
     20 x  8:1
     19 x  6:1

Summing every mux gives more than the module's whole area, so those LE figures
are pre-restructuring estimates and Quartus recovers much of it. The PROPORTION
is the signal: 826 mux structures in one module is the signature of a 3,800-line
`always` block where every destination register infers its own selection tree
across 47 case arms, because the tool cannot prove which arms are exclusive.

### The concrete first target

The register file already has TWO proper read ports - `rf_rdata_a`/`rf_rdata_b`,
each one explicit 32-way case, addressed by `rf_raddr_a`/`rf_raddr_b` and driven
combinationally per state around line 618.

But `exec_op`'s MOVD arm (opcode 0x3f, around line 3304) bypasses them entirely:

    movd_lo <= r[op1[4:0]];
    movd_hi <= r[op1[4:0] + 5'd1];
    queue_reg_write(op2[4:0],        r[op1[4:0]],        32'hffffffff);
    queue_reg_write(op2[4:0] + 5'd1, r[op1[4:0] + 5'd1], 32'hffffffff);

Each variable index infers a fresh 32:1 mux on 32 bits, and `+ 5'd1` adds an
adder in front of it. Routing these through the existing read ports costs
nothing - `rf_rdata_a/b` are combinational from `rf_raddr_a/b` - but needs the
state context, because `rf_raddr` is assigned per state and `exec_op` is a task.
DONE, 2026-09-02. `S_EXEC` already drove `rf_raddr_a = op1[4:0]` for every
opcode but DIVX, so `rf_rdata_a` was the low word for free; MOVD only *writes*
`op2`, which left port b available for `op1+1`. The `+1` now happens on a 5-bit
read address instead of behind a 32-bit mux.

**The three further targets listed here were wrong, and are struck off.**
`r[init_reg_i]` is inside an `initial` block - simulation only, no hardware at
all. `r[rf_waddr0]` and `r[rf_waddr1]` are the WRITE port: a variable index on
the left of an assignment infers an address decoder, not a mux, and that is the
correct structure for a register file. After MOVD no variable-index *read* of
`r[]` remains; the only survivors are `alu_r[bi]`, single-bit selects worth
about 2 ALM each.

### The second target: the scaled index

`(rf_rdata_a << ea_dim)` appeared at seven sites in the addressing-mode decoder,
in different arms of nested case statements. Quartus will not share logic across
arms it cannot prove exclusive, so each site inferred its own 32-bit shifter.
`ea_dim` is registered in an earlier state and `rf_rdata_a` is combinational, so
one `wire [31:0] ea_index` is exactly equivalent to the seven.

It must be declared AFTER `rf_rdata_a` and outside the `always` block: Icarus
binds strictly in source order, and six of the V60 tests are built with Icarus,
so a declaration placed beside `ea_dim` passes Verilator and fails the suite.

### Measuring V60 area: use the standalone target

`make quartus MOD=s32_v60` synthesises and fits the CPU alone, which is both far
faster than a full build and free of the rest of the design's placement noise.
Counting lines that merely mention `s32_v60` in the full design's `.map.rpt` is
NOT a measurement - it matches every message about the module, not mux-table
rows, and comparing two such counts produced an apparent 826 -> 499 improvement
that means nothing.

### Why it matters more than anything else left

    sound (M4)          ~5,000 ALM
    Z80 I/O board       ~2,000     rtl/io/m1_ioz80.sv and rtl/cpu/tv80/ ALREADY
                                   EXIST in this tree, instantiated NOWHERE
    TGP at 2:1          ~1,300
    -------------------------------
                        ~8,300 ALM against ~900 free

Every other lever on this project is worth a few hundred ALM. This one is worth
thousands, and it is also why builds miss timing by 0.1-0.5 ns depending purely
on the fitter's seed: at 98-99% occupancy there is no room to place.
