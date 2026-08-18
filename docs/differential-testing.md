# Differential testing against MAME

**When behaviour diverges from the reference, diff against the oracle before
theorising. This is the first tool, not the last.**

On 2026-08-18 five causes were named and withdrawn in a day — the M10K crossing,
a FIFO-full halt, the coprocessor data ROM, "stuck in boot", the SDRAM output
paths — every one reasoned from a plausible mechanism and refuted by measurement.
The same afternoon, differential tracing found **three real defects in about two
hours**, two of them CPU bugs that had survived every test in the suite.

`CLAUDE.md` already said "when something is unknown, run MAME, do not reason about
it". This is what that looks like in practice.

---

## The tools

### `make v60_trace` — instruction streams

```
make v60_trace                                # 2 emulated seconds
make v60_trace SECONDS_RUN=5 CYCLES=200000000
```

MAME's debugger emits a disassembled instruction trace; our core emits the same PC
stream from `dbg_pc`; the script aligns and diffs them and prints MAME's
disassembly around the first divergence.

**`noloop` is not optional.** Without it MAME's tracer collapses loops and prints
`(loops for 620 instructions)`. Diffing against that reports phantom extra
instructions in our trace and reads exactly like a CPU branch bug — that false
finding was made here and withdrawn only when the trace file was read by eye. The
script warns if the flag fails to take.

### Write traces — memory effects

When the instruction streams match but behaviour differs, the CPUs are executing
the same code and producing different memory. Diff the writes:

```
# MAME: install_write_tap over the whole space, log "addr data pc"
# ours: make m1_frame V60_WRTRACE=1, log the same
# then: cmp the two
```

**Filter I/O-space writes from our side before comparing.** Our design routes
`IN`/`OUT` to the same bus as memory, while MAME keeps a separate I/O space that a
program-space tap cannot see. Leaving them in reports every `out` as a phantom
extra write.

### MAME Lua taps — everything else

`install_read_tap` / `install_write_tap` on any device's address space, plus
frame notifiers. Assign every tap and notifier to a **global** or the subscription
is collected and the callback silently stops. Always pass `-skip_gameinfo` and
`-autoboot_delay 0`. Run from a scratch directory; MAME drops `cfg/`, `nvram/` and
`snap/` where it starts.

`tools/mame_pcdist.lua`, `tools/mame_pconly.lua` and `tools/mame_ctrl_toggle.lua`
are kept examples.

---

## What it found, and what the suites missed

| Defect | Found by | Why the suite missed it |
|---|---|---|
| `OUT` operands transposed — the immediate became the address | write-trace diff | per-opcode fuzzing hands the instruction its operands the same way the implementation reads them, so both are wrong together |
| GLUE decode aliased the whole `0xe0` page onto 16 bytes, clearing `irq_mask` | write-trace diff | `tb_m1_decode`'s reference model said the same thing the RTL did |
| tilemap window mode blanked a pair instead of splitting it | census + oracle reread | `tb_m1_video`'s reference was written from the same misreading |

The V60 defects survived **29/29 unit tests, every fuzz suite, a full `make test`,
boot traces, frame renders and months of use.**

---

## The trap this keeps exposing

**A reference model written from the same reading of the source as the
implementation cannot catch a misreading of the source.** It only catches a slip
between the two. Three of today's bugs were invisible to their own tests for
exactly this reason, and each test kept passing with impressive numbers —
466,714 checks, 380,929 checks — while agreeing with the bug.

Two habits follow:

1. **Derive reference models from the oracle's source, and cite the file and
   function in a comment.** If the citation is wrong, the model is wrong, and a
   future reader can check the citation.
2. **Break the RTL on purpose and confirm the count moves.** A test that does not
   fail when the logic is inverted is not testing that logic. Doing this found a
   fixture feeding an input the game never presents, which had made the whole
   window implementation untestable.

---

## Method notes that cost time

- **A measurement that agrees with your own stub is not corroboration.** "The V60
  never reads the coprocessor back" survived because the reference census (of the
  wrong address space) matched our core's faked `IN`, which returned a constant and
  made no accesses at all. Two sources, one of them a stub, both saying zero.

- **Check what a counter increments on, not what its name suggests.** `dbg_fifo_pops`
  counted the V60 reading results, not the TGP taking commands; its correct zero
  was read as a stall and produced a whole wrong diagnosis.
- **Compare like with like.** A PC-distribution comparison against MAME's *memory
  accesses* is not the same measurement and reported a divergence that did not
  exist.
- **Beware comparing different points in a loop.** "The same instruction reads a
  different address" turned out to be MAME's later iterations against our first.
- **A saturating counter cannot show liveness.** Prefer wrapping counters for
  anything you will read off a screen to answer "is this still running".

---

## Where the instruction-trace method stops

**At the first timing-dependent wait loop.** Beyond that point the PC streams
legitimately differ and the diff reports a divergence that is not a bug.

The boundary on this core is the I/O board handshake at instruction ~206,307:

```
FE03FD: mov.b  #1, C00040      ; V60 writes a command flag
FE022C: test.b C00040
FE0232: bne    FE022C          ; wait for the I/O board to clear it
```

MAME's Z80 takes real time — its census counted 36,131 polls of `c00040` — while
`m1_ioboard` answers after `LATENCY = 64` cycles, whose own comment admits "the
exact figure is not known". Our V60's first read already sees zero, so the loop runs
once. Both complete the handshake; only the duration differs.

**RESOLVED, by measuring rather than tuning.** The concern above was that raising
`LATENCY` to make the traces agree would be fitting a number to an emulator. It
is not, because the reference can simply be asked: `tools/mame_iohandshake.lua`
times the exchange at **38,577 us — 740,684 cycles of our 19.2 MHz domain** — and
`tools/mame_flag_state.lua` shows the flag is then **never cleared again**, set in
1,194 of 1,200 frames sampled. `LATENCY` is now that measurement, and the same
number reproduces both behaviours because the once-a-frame doorbell re-arms the
deadline faster than it expires. See `docs/io-board.md`.

The general lesson is worth more than the fix: **a guessed constant in a
peripheral produced a false CPU-bug report**, and it survived because the
peripheral's behaviour was invisible to the game. When the diff points at a wait
loop, measure the thing being waited on before suspecting the CPU.

Past a wait loop, also prefer **write traces** and targeted comparisons over the
instruction stream, because a write trace tolerates timing differences that a PC
stream does not.

### Four artifacts this method produced, all withdrawn

- **Collapsed loops.** Without `noloop` MAME prints `(loops for N instructions)` and
  the diff reports N phantom extras — read as a branch bug at instruction 83.
- **Branch-to-self loops.** Our trace logs the PC on CHANGE, so `dbr R0, FFA6BD[PC]`
  — 5,000 iterations at one address — appears once while MAME logs all 5,000. Read
  as a broken `dbr`. The script now collapses consecutive repeats on **both** sides;
  the register check (`R0 = 0x1388` then `0x1387`) showed the loop was fine.
- **Warm NVRAM.** MAME saves `nvram/` on exit and reloads it, so a reused directory
  boots with battery-backed RAM the game has already written while our core is
  always cold. That alone produced a "divergence at 197,251" chased as a CPU bug:
  `0x40e8fe` read `0x0000` there and `0xffff` here, and with the file deleted MAME
  reads `0xffff` too. The script now deletes `nvram/` every run.

- **A PC published but never executed.** The V60 assigned `dbg_pc <= pc` at the top
  of `S_DECODE`, *above* the interrupt check in the same state — so when an
  interrupt preempted an instruction, `dbg_pc` still advertised its PC. MAME's
  tracer only prints instructions it retires. At `updpsw.w #FFFFFFFF, #40000` —
  whose mask `0x40000` is bit 18, `psw_ie`, so the instruction unmasks interrupts
  and the reference vectors straight to the handler — we appeared to execute one
  extra instruction. We did not; we published its PC. `dbg_pc` is now assigned on
  dispatch, which is also the more useful reading for the overlay: it names the
  last instruction that *ran*.

- **A poll loop that alternates two addresses.** Collapsing consecutive repeats
  cannot touch `test.b` / `bne`, so the whole 36,308-iteration wait survived and
  the diff reported the exit as a divergence. `tools/v60_collapse.py` collapses the
  shortest repeating period instead, and reports the iteration counts rather than
  dropping them.

Each of those cost a wrong diagnosis, and **all four were the instrument, not the
design.** That is the shape to expect: a differential tool compares two things
neither of which was built to be compared, and every mismatch in *how* they are
observed shows up as a mismatch in *what* they did. Suspect the instrument first
when the reported fault is a difference in count, in timing, or in one instruction.
