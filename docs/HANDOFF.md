# HANDOFF

## 2026-08-29 — the coprocessor stops parking: an empty command FIFO reads as ZERO

**The TGP was blocked at its own dispatch, and the cause was our FIFO being too strict.**
`004D` pops a command into `b`; `0052 brul alw d` jumps to `d = get_exp(b) + 0x53`, so
004D-0052 is a computed dispatch whose command type rides in the exponent field. `get_exp` is
`(val >> 23) & 0xff`, so **an empty FIFO gives `b = 0` and `d = 0x53` — the IDLE handler**,
which loops back to `0x9b` and polls again.

We stalled the pop until data arrived, so `b = 0` was unreachable, the idle path was
unreachable, and the core parked at `004C` the first time it polled an empty FIFO.

    before   TGP retires=342    pc=004c  pushes=61 returns=20
    after    TGP retires=57660  pc=00a7  pushes=61 returns=36

`gen_fifo.h` is explicit and the comment in `m1_tgp.sv` claimed the opposite of it:
*"Called on a pop with an empty fifo... **the pop itself will then return zero**."* Over a
16-second window the reference makes **61 pushes and fills a 300-entry pop capture** — polling
an empty FIFO is its normal state.

**The outbound FIFO keeps its stall and must not be made symmetric.** That direction is the
V60 reading results, where acknowledging an empty read returned a stale word and hung the CPU
at `fed5a4`; MAME halts the maincpu there instead.

**The command interface itself was never wrong.** 61 pushes and 61 pops, both bit-exact
against the reference. Yesterday's "differs at the FIRST pop" is withdrawn — see
`docs/findings.md` for the three stacked instrument faults that produced it, all of the same
family: mismatched filters, taps at different LEVELS, and a registered signal sampled on its
own write edge.

**And then the blocker moved, and it is the V60's SPEED.** Four measurements, each answering
the one before:

    TGP fifo_wr asserted 69% of all cycles   -> blocked PUSHING results, not starved
    V60 reads the result FIFO 20x/109 frames -> reference does ~1,185 PER FRAME
    v60_trace DIVERGES at instruction 25,281 -> MAME jsr FF8ABC, we land at fe02bc
    our loops run at 47% of MAME's counts    -> 8,769 vs 4,102, repeatedly

`fe02bc` is entered from five different predecessors in our own trace, so it is an interrupt
handler, not a subroutine: **we take an interrupt the reference has not taken yet.** The loop
counts say why — those are time-based waits, so the ratio IS our relative speed. Same
wall-clock IRQ rate against half the instruction throughput puts the interrupt earlier in the
instruction stream.

So the TGP is waiting behind the CPU. `tgp_wrtrace`'s value divergence at write 268
(`41ef3336` there, `bdcccccd` here, sourced from `x0 = 0x100`) is the V60 having pushed
different data after taking a different path — not TGP arithmetic.

**`clk_cpu` closes at 24.94 MHz and runs at 19.2**, so 30% is available from a PLL change
alone. It does not close a 2x gap, and `m1_ioboard`'s `LATENCY = 740684` is derived from
19.2 MHz and must move with it. Recorded, not done.

**Still open:** the background scrolls on the wrong axis and flickers. Worth re-testing on
hardware *after* these fixes — the V60 was waiting on a coprocessor that never answered, so
what it wrote into the scroll registers was downstream of a dead TGP.

## 2026-08-19 — the coprocessor works, and the reason nothing drew was a reset

**Read this section first.** It supersedes anything below it about the TGP or the missing
2D.

### The fix that mattered

`m1_main` wired the coprocessor to the **raw** reset while the V60 was gated on
`rom_loaded`:

    m1_tgp tgp ( .clk(clk), .rst_n(rst_n),          // was
    m1_tgp tgp ( .clk(clk), .rst_n(~rst_cpu),       // now

So the TGP left reset at power-on and executed its program RAM while the HPS was still
streaming ROMs into it. Zeros decode as `lab`; one of the first four does a data-space read
of `0x100`, the **command FIFO**, which blocks until the V60 sends something. The microcode
then arrived to a coprocessor already parked on that read, and the V60 hung at `ff9754`
waiting for a result that never came.

    before   tgp=4/0/004c     pc=ff9754   irq=3/4       wr=0,0,0,0
    after    tgp=53918/23739  pc=fe02bc   irq=387/1611  ctrl=0000,238b

**`tb_m1_boot` preloads the microcode and could never see this.** That bench had the same
race in its own reset, and fixing it there this morning *masked* the real one. `tb_m1_frame`
drives the genuine `m1_rom_loader` and is the only bench on the hardware path — treat a
`tb_m1_boot` pass as evidence about the boot bench, not about the board.

### Nine more defects fixed the same day, all real, all hardware

| # | defect | found by |
|---|---|---|
| 1 | `lab` loaded neither A nor B | `tgp_wrtrace` write 38 |
| 2 | AGU post-increment fired once per **cycle**, not per access | write 42 |
| 3 | `lab`'s B operand addressed with the A field | write 65 |
| 4 | a parallel ALU op computed on the transfer's **new** operand | write 90 |
| 5 | the four math units — sincos, atan, inv, isqrt — never implemented | write 102 |
| 6 | `lab`'s A side dropped `+0x200`, addressing the command FIFO | deadlock |
| 7 | shared request line let one memory master read the other's data | write 455 |
| 8 | RAM initialisers over 5,000 entries broke synthesis | `make rbf` |
| 9 | the coprocessor reset above | `tb_m1_frame` |

### What now agrees with MAME, measured

- **V60 instruction stream**: `v60_trace` + `v60_resync` — zero divergence sites over the
  compared window; 51 of 52 collapsed loops identical counts. The one exception is the I/O
  board handshake at 18 cycles an iteration against 17, known and benign.
- **V60 → TGP command stream**: identical for all 61 commands the reference issues.
- **TGP data writes**: identical for 4,121 writes.
- **Text routine**: identical, 400 writes, same addresses and data.
- **Row mask**: identical for its first 289 words.
- **Tilemaps 1 and 3**: byte-identical over all 4096 words.

### What still differs

Tilemaps 0 and 2, on 21 of 1024 dumped lines — the attract ranking table. The reference
holds `a0xx` (category 1, palette 0x2000); we hold `0020`, a plain space with bit 15 clear.
Measured **before** fix 9, so re-measure: the coprocessor now runs and the V60 is no longer
hung, and this may already have moved.

The scroll word `[5006]` was `0x2305` against the reference's `0x209b`. It is
`mode | (scroll & 0x3ff)` from `FFE44B-FFE466`; the mode half matched and only the scroll
half differed. Also measured before fix 9.

### Instruments built today — use them before reading source

| tool | what it answers |
|---|---|
| `tools/v60_resync.py` | all divergence sites, not just the first — `cmp` stopped at an interrupt phase slip and hid 79,000 instructions |
| `tools/mame_copro_push.lua` | the V60 → TGP command stream, for diffing |
| `tools/mame_text_writes.lua` | what the text routine stores, and where |
| `tools/mame_rowmask.lua` | the row mask word by word |
| `tools/mame_tilemap0.lua` | all four tilemaps, for a byte diff |
| `make tgp_wrtrace` | TGP data writes with `x0`, `a` and `d` alongside |

### Lessons that cost the most time

- **Open the video.** Frames pulled with `ffmpeg -vf fps=2` and read directly overturned two
  conclusions in ninety seconds that five source readings had produced. A photograph is a
  measurement.
- **Check the window before believing "never" or "identical".** "MAME never executes
  FED5xx" came from a 4-second trace of a routine first reached at 5.2 s. "Identical for
  4000 writes" meant both instruments stopped at exactly 4,000.
- **A held state must not drive a side effect.** The AGU post-increment and the coprocessor
  FIFO pop were the same bug in two modules: once per cycle instead of once per access.
- **Fixing a dead path exposes its silent consumers.** Making `lab` write its registers
  surfaced defect 3 one instruction later. That is the fix working.
- **Do not begin a comment line with the simulator's name** — it parses as a pragma and
  breaks the build, and `make lint` does not catch it.

---


## Where this actually is

**The blue flashing, the missing text and the absent scrolling are one bug**, and
it is in the CPU, not the video path. Verified: the reference animates pair 2/3's
`ctrl` every frame (`0x20xx`-`0x23xx`, the vertical scroll counting) while we write
only `0x0000` and `0x2000` with the scroll stuck at zero. Simulation reproduces it,
so **no board and no bitstream are needed to work on it**.

### Read this first: how the remaining work is done

`docs/differential-testing.md`. Diff against MAME before theorising. On 2026-08-18
five causes were named and withdrawn from reasoning; the same afternoon
differential tracing found three real defects in about two hours, two of them CPU
bugs that had survived every test in the suite.

```
make v60_trace          # instruction streams, ours against MAME's
```

### Fixed on 2026-08-18, in order

1. **The coprocessor's data ROM and sincos tables were never in the MRA.**
   `tools/build_rom_image.py` had them all along, so simulation worked and hardware
   stalled its TGP. Now generated by `gen_mra.py`, with `verify_mra.py` checking
   both against the packer.
2. **Window mode 1's vertical split** — the sky and sea. Backdrop 92% -> 0%.
3. **Window modes 2/3 and the even-map window scroll** — the pair the text lives
   on, blanked on 194 frames of 2,478.
4. **`m1_sdram`'s reset** cost 0.95 ns of margin and 217 ALM. Now `+1.246 ns`.
5. **V60 `OUT` had its operands transposed** — the immediate became the address.
6. **The GLUE decode aliased the whole `0xe0` page** onto sixteen bytes, clearing
   `irq_mask` moments after the game set it.
7. **`m1_ioboard`'s handshake latency was a guess, 64 cycles.** Measured: the
   reference takes **38,577 us = 740,684 cycles** of the 19.2 MHz domain, answers
   **once**, and then never clears the flag again while the V60 doorbells it every
   frame. One number reproduces both, because the doorbell re-arms the deadline
   faster than it expires. `tools/mame_iohandshake.lua`, `tools/mame_flag_state.lua`.
8. **Six wrong bytes in the I/O board's identity block**, from a dump taken while
   the Z80 was still filling the window. One of them, offset `0x0b`, is copied to
   `0x40DC8B` and tested at `FF9737` to decide whether the game uses a coprocessor
   path at all — so we were skipping it. `tools/mame_idblock.lua`.
9. **`dbg_pc` was published on entering `S_DECODE`**, above the interrupt check, so
   a preempted instruction's PC appeared in the trace as though it had run.

10. **`tb_m1_boot` loaded the TGP microcode shifted by one word.** `uc_data` and
   `uc_addr` were both assigned non-blockingly in the same cycle, so `prog[A]` got
   `ucode[A-1]`; address 0 was right only because the address does not advance on
   the first cycle. **Every TGP figure that bench printed before this was
   meaningless.** `tb_m1_frame` drives the real `m1_rom_loader` and was unaffected,
   so `v60_trace`'s results stand, as does the board (the hardware loader presents
   address and data together, which is why row 02's checksum matched).

11. **The TGP's ST was not a register.** The flags lived in the ALU's pipeline and
   were recomputed for whatever instruction was in it, so a conditional branch after
   a flag-setting op read a corrupt ST — `subd` set ZRD, the following
   `brif !zrd` cleared it under itself, and the coprocessor **could never leave
   command dispatch**. `st_hold` now latches on `alu_out_valid`, MAME's
   once-per-instruction update. `tb_mb86233_core`'s 8,000-retire lockstep passes
   either way; it never generated that pairing, which is the argument for
   `tgp_trace` in one datum.
12. **`brul`/`bsul` were not implemented** — `seq_branch_val = d_bdata` for every
   subtype, so the indirect branches jumped to their own immediate field. The one
   `brul` in the microcode (pc `0x0052`, register form) is the **command dispatch
   jump**, so nothing past it ran. Register form implemented (`d_bdata[5:0]`, six
   bits, because MAME's `read_reg` masks to six not the five the disassembler
   prints); the two `bsul` memory-form sites are **still unimplemented** and now
   warn in simulation instead of jumping somewhere plausible.

   Together these took the lockstep from 71 instructions (spinning) to **102**, and
   our stream from 71 lines/1 loop to 322 lines/10 loops against the reference's
   343/21.

### Instruments built or repaired on 2026-08-18

`make tgp_trace` (`tools/tgp_trace.sh`) is M0 exit criterion 2, armed at last: our
TGP's retire stream diffed against MAME's tracer on `:tgp_copro`, over the real
decapped microcode. It reuses `v60_collapse.py` unchanged. It found the loader bug
above on its first run. It is shallow so far — our TGP retires only dozens of
instructions per window because it waits on the input FIFO — so deepen it before
calling the criterion met.

`tools/v60_collapse.py` collapses periodic wait loops in a PC trace and reports the
iteration counts instead of dropping them — without it, a two-address poll loop
reads as a divergence. Seven Lua instruments were added: `mame_iohandshake`,
`mame_flag_state`, `mame_dpram_census`, `mame_scroll_census`, `mame_tileram_writes`,
`mame_mask_writers`, `mame_idblock`, `mame_watch_byte`.

**Four of the divergences chased today were the instrument, not the design** — see
`docs/differential-testing.md`. Two more measurements retired suspicions rather
than confirming them: the per-line H-scroll table is never reached (`hscr` bit 15
never set in 2,000 frames) and the row mask is not written by the reference until
**frame 276**, so `m1_boot`'s 86-frame run was never long enough to say anything
about it.

13. **`0x680000` had no read handler.** The display-list control register was
   decoded for writes only, so reads returned `0xFFFF` and bit 6 — the buffer
   select — read as 1 forever. Now `rtl/video/m1_listctl.sv` with its own suite,
   including the bit-6 mirror and the two-frame toggle. Trace 26,283 -> 26,945.

### The regression protocol for the V60 split

The split is planned as **one change at a time, hardware-tested after each**. That is
right, and a hardware round trip is 25 minutes of Quartus plus a person at the
screen — so run the cheap gates first. Roughly twelve minutes of simulation catches
essentially any behavioural regression before a build is spent.

| gate | baseline to hold | cost |
|---|---|---|
| `make lint && make test` | every suite, 0 fails | ~2 min |
| `bash tools/run_v60_tests.sh` | **29/29** | ~3 min |
| `make v60_trace` | diverges at **26,945** — later is fine, EARLIER IS A REGRESSION | ~5 min |
| `make m1_boot BOOT_CYCLES=100000000` | 819,812 instrs, 30.49 CPI, 65% bus-stalled | ~2 min |
| `make area`, or `make quartus MOD=m1_integrated` | ALM delta | mins / 25 min |
| `make rbf` + board | overlay rows `02`, `03`, `0B`, `11`-`14` | 25 min + a person |

**`v60_trace`'s divergence point is the gate that matters for a refactor.** It diffs
the instruction stream against MAME from reset, so a change that alters behaviour
moves it earlier. Treat 26,945 the way the test counts in `CLAUDE.md` are treated:
when a change legitimately moves it, update the number in the same commit.

**Before dropping the FP group**, note what the `-2,984 ALM` figure does and does not
rest on. `dbg_fp_trap` has never fired — but only through boot and attract, and it is
inert by construction in a build that HAS FP, so that is not yet evidence. The honest
gate is a long run under the no-FP define with `tb_m1_boot`'s explicit warning armed.

**And throughput is not a reason for the split.** The V60 is ~6 CPI in isolation
against the reference's implied ~8, and 65% of its cycles are bus stalls that live
outside the core. Area, maintainability and sharing with the i960 project are good
reasons; speed is not one.

### Where to pick up: the microcode IS loaded. The FETCH delivers zero.

    UCODE CHECK: 0 of 2048 words differ; prog[07e6]=40008000 ucode[07e6]=40008000

`tb_m1_boot` now verifies **every** word of program RAM against what `$readmemh` loaded,
once the stream finishes, and reports a count with examples. All 2048 match. So the ROM is
in correctly and the three candidates queued for it — a `$readmemh` gap, a loader dropping
writes, an early-execution race — are all eliminated by one measurement.

**Yet the core fetches `ir = 00000000` at `pc = 07e6`, where `prog[0x07e6]` provably holds
`40008000`.** So the fault is in the fetch path:

    prog_addr = (state == S_SRC || S_SRC_W) && x_src_sp == EP_PROG ? agu_ea[15:0] : seq_pc;
    always_ff @(posedge clk) prog_rdata <= prog[prog_addr[10:0]];
    S_FETCH_W: ir <= prog_rdata;

Timing reads correctly: `S_FETCH` presents `seq_pc`, the edge into `S_FETCH_W` registers
`prog[seq_pc]`, and `S_FETCH_W` latches it into `ir`. **So measure it rather than read it**
— print `prog_addr`, `prog_rdata` and `ir` across `S_FETCH`/`S_FETCH_W`, and note the
existing trace arms one cycle late (its first line is `st=1`, so `S_FETCH` itself is never
shown). Arm on `seq_pc == 0x07e5` to see the fetch of `07e6` from the state before it.

**A specific suspect, now half-confirmed.** `prog_addr` is shared with the `EP_PROG` source
path, so an instruction that reads program space as data steals the address port:

    prog_addr = (S_SRC || S_SRC_W) && x_src_sp == EP_PROG ? agu_ea[15:0] : seq_pc;

**`07E5` is `0x1c1c842e`, whose `top = opcode[31:26] = 0x07` — `ldmov`**, a transfer that
goes through `S_SRC`/`S_SRC_W`. So the instruction immediately before the failing fetch is
in the class that can take that port.

What is still unmeasured is whether its `x_src_sp` is actually `EP_PROG`, and whether
`prog_rdata` — registered every cycle from `prog[prog_addr]` — is sampled by `S_FETCH_W`
before it has settled on `seq_pc` again. **Print `prog_addr`, `prog_rdata`, `ir` and
`x_src_sp` across `07E5` and `07E6` together**, arming on `seq_pc == 0x07e5`. On paper the
timing is correct: `S_FETCH` presents `seq_pc`, the edge registers `prog[seq_pc]`, and
`S_FETCH_W` latches it. On paper is where the last five wrong answers came from.

**Do not change `mb86233_dec`, `mb86233_core`'s decode, or the loader.** All three are
proven correct for this case.

### Superseded: "program RAM reads zero at 0x07e6" — the RAM is fine, the fetch is not

    W0 pc=07e6 ir=00000000 st=1 ...        the core fetches ZERO
    hex 07e6   40008000                    the file holds `ldi #0x8000, b0`

An all-zero word has `top = opcode[31:26] = 0x00`, which is exactly `is_lab` — so the
`lab` path the trace showed is the **correct** decode of the word actually fetched.
Nothing is mis-decoded. **The microcode is not in program RAM at that address.**

**Every bound checks out**, so this is not an obvious sizing error:

| | |
|---|---|
| `m1_tgp`'s `PROG_WORDS` | 2048 |
| `build/rom/vr_tgp_prog.hex` | 2048 lines |
| `tb_m1_boot`'s `ucode` array | `[0:2047]` |
| the address | `0x07e6` = 2022, inside |
| the loader's bound | walks to `11'd2047` |

**So check, in this order:**

1. **Does `ucode[0x07e6]` hold `40008000` in the bench?** `$readmemh` can stop early or skip
   silently. Print it in the same `initial` that already prints the preload check.
2. **Does `prog[0x07e6]` hold it after the load?** If `ucode` is right and `prog` is not,
   the loader is dropping writes — and note the one-word shift fixed here on 2026-08-18
   was in this same loader, so a second fault in it is plausible.
3. **Does the TGP start executing before the load finishes?** The stream runs after `rst_n`
   rises; if the coprocessor is released at the same time it will fetch from a partly
   filled RAM. `0x07e6` is reached late, so this is the least likely of the three, but it
   is the one that would differ between simulation and hardware — `m1_rom_loader` is a
   different loader again.

**Do not change `mb86233_dec` or `mb86233_core`.** Both are correct for the word they were
given. Three earlier conclusions in this hunt — "mis-decoded", "b0 not written", "the store
is wrong" — were all correct descriptions of consequences, and all wrong about the cause.

### Superseded: "check `ir` at 07E6 first" — done, and it reads zero

The chain is complete and every link is measured except the last step, which flipped at
the end and is the one thing to verify before touching anything:

**The decoder is CORRECT for this opcode.** `mb86233_dec` has

    assign top      = opcode[31:26];
    assign is_lab   = (top == 6'h00);
    assign is_ldmov = (top == 6'h07);
    assign is_ldi   = (top >= 6'h10) && (top <= 6'h1f);
    assign ldi_reg  = opcode[29:24];
    assign ldi_val  = {{8{opcode[23]}}, opcode[23:0]};

and the word at `0x07e6` in `build/rom/vr_tgp_prog.hex` is `0x40008000`, so `top = 0x10`,
`is_ldi = 1`, `is_lab = 0`, `is_ldmov = 0`, `ldi_reg = 0x00` (b0), `ldi_val = 0x8000`.
**The flags are mutually exclusive; there is no decode overlap.** A correctly fetched
`0x40008000` would go straight to `S_ALU` and write `b0` at `S_RETIRE`.

**But the trace shows it going through `S_SRC`, `S_SRC_W`, `S_LABB`, `S_LABB_W` with a
data-space read, and `rf_wr_en` never asserted.** That is the `lab` path, which requires
`top == 0x00`.

**So the core is not fetching `0x40008000` at `0x07e6`.** Print `ir` in that window before
anything else — one field added to a trace that already exists. Candidates:

- the microcode image in program RAM differs from the hex file at that address. The
  one-word load shift was fixed on 2026-08-18 in `tb_m1_boot`; **verify it is still
  correct**, and note the hardware path (`m1_rom_loader`) is a different loader again.
- the fetch is returning a stale or wrong word for another reason.

**Do not change `mb86233_dec`.** It is right for this encoding, and `mb86233_dec` passes
3,000,000 fuzz checks — the earlier worry that its reference might share a misreading does
not apply, because there is no misreading to share.

### Superseded: "it is b0, not the data path" — true, but the cause is a step earlier

Armed on `seq_pc == 0x07e7` — the instruction, not a symptom — and printing every cycle:

    W2 pc=07e7 st=3 ack=1 rd=1 ioaddr=0000 io=00000000 b0=0000 x0=0000
    W4 pc=07e7 st=7 mw=1 maddr=00069            stores that 0 into data[0x69]

**`b0 = 0x0000` at the first execution of `07E7`.** `07E6` is `ldi #0x8000, b0`, so it
should be `0x8000`. With `b0` and `x0` both zero the operand `(bx0)` addresses io
`0x0000` — the coprocessor RAM address register, which reads 0 — instead of `0x8010`.
The read succeeds, returns 0, and the store faithfully writes 0. **Nothing in the data
path was ever wrong; the address was.**

That also explains why the second execution is correct: by then `b0` holds `0x8000`.

**The question is now: did `07E6` execute before that first `07E7`, and if so why did
`b0` not take the value?** Two shapes, and they need different fixes:

1. **`07E6` did not execute** — we reach `07E7` by a path the reference does not take,
   so this is control flow and `tgp_trace` with a window that reaches it will show the
   entry.
2. **`07E6` executed and the write did not land.** `ldi` is an immediate-form write and
   `mb86233_core` lands those in `S_RETIRE` via `rf_wr_en`/`rf_wr_addr = d_ldireg`. Check
   `d_ldireg` resolves to `b0`'s index — `read_reg` case `0x00` is `m_b0` — and that the
   write is not being lost to the register file's shared-ownership rules. **CLAUDE.md
   warns that `x0`/`x1` have two writers and the AGU wins; `b0` deserves the same
   scrutiny.**

Widen the arm to `seq_pc == 0x07e6` and print through both instructions. That
distinguishes the two in one run.

### Superseded: "the bug is one instruction wide" — the store looked wrong and was not

**`07E7` — `mov (bx0) (e), $0x69` — stores the wrong value on its FIRST execution.**

    ref   write 22:  TW 0069 00000030 pc=07e8    (GENPC is the NEXT pc, so instr 07e7)
    ours  write 22:  TW 0069 00000000 pc=07e7
    ours  write 27:  TW 0069 00000030 pc=07e7    same instruction, correct second time

Both sides execute it twice; the reference gets `0x30` both times.

**Cleared by measurement, do not revisit:**

- **`m1_cdc_port`.** `a_dout <= x_dout; a_ack <= 1'b1;` are assigned together, so the data
  IS valid on the ack cycle, exactly as its comment says. A combinational read during that
  cycle is correct.
- **The store path.** An unfiltered 40-cycle window shows `src=00000030`, `mw=1`,
  `maddr=00069` — the capture and the store are both right.
- **The data ROM, SDRAM and the io reads themselves** — the values arrive correctly.

**The likely shape, and the measurement that settles it.** The operand is `(bx0)` =
`b0 + x0`, set up by `07E6: ldi #0x8000, b0`. So the address depends on `x0`, and the two
executions read **different io addresses** — probably `0x8000` first and `0x8010` second.
The earlier window trace armed on `io_addr == 0x8010`, so **it only ever showed the second,
working execution**, which is why the store looked correct.

**Arm on `seq_pc == 0x07e7` instead**, print every cycle for ~40, and compare the FIRST
execution's io address and returned data against the reference's. `tools/mame_tgp_io_full.lua`
already shows the reference's side: `W io 002e`, `R io 8010`, `R io 8020` — note it does
**not** read `0x8000`, so if ours does, that is the divergence.

### THE RUN-LENGTH TRAP, three times in one day

Every figure from `make m1_boot` scales with `BOOT_CYCLES`, and this file has said so
about quoting figures since 2026-08-15. It bites just as hard when *comparing runs* or
when *hunting for an event*:

1. `WATCH_PAGE=0xD2` showed zero reads of `d20000` at 300 M cycles while a 600 M run
   showed the V60 parked on the instruction that reads it. Reported as an instrument
   contradiction. It was two run lengths.
2. A 700 M run showed 324 TGP retires where earlier runs showed 537, and that was read
   as the zero-init commits changing behaviour. **Still unresolved** — the run lengths
   differed there too, so the behaviour change is not established either way.
3. An all-states io trace at 300 M produced nothing, because `TGP data reads=0` at that
   length: the read being hunted had not happened yet.

**Before concluding that an event does not occur, check the run reached the point where
it would.** The boot trace prints `TGP data reads=N` and `pc now` — both say how far the
run actually got, and both were sitting in the output each time.

### Where to pick up — 2026-08-19 afternoon, and it is narrow

**`make tgp_wrtrace` exists and works.** Value-level lockstep for the coprocessor: it
diffs the data-memory write streams and located in **26 writes** what `tgp_trace` could
not in 604 instructions.

    tgp_wrtrace: DIVERGES at write 22
      22   ref data[0069] = 00000030    ours = 00000000
      23   ref data[006a] = 00012e00    ours = 00000000
      27   ref data[0069] = 00000030    ours = 00000030   (a later pass is correct)

`00000030` and `00012e00` are the coprocessor data ROM's words at io `8010`/`8020`.

**Three suspects already cleared by measurement**, so do not revisit them: the data ROM,
the SDRAM path and `m1_cdc_port` are all correct — the boot trace prints
`TGP data read 1: sdram word 300020 -> 00000030` and `read 2: ... -> 00012e00`, matching
the reference. The `a_dout`/`a_ack` alignment worry does not apply to the DUT either:
`a_dout` updates on the same edge as `a_ack`, so a combinational read during the ack
cycle is right. The testbench's own capture bug was sampling a cycle later — a different
thing, which I conflated once already.

**So the value is lost between `io_rdata` and the store.** And the next measurement
narrowed it further: printing `S_SRC`/`S_SRC_W` with `x_src_sp == EP_IO` and
`io_addr[15]` set produced **nothing** over 300 M cycles, while the same print without
the address filter fires for io `0x0000` and `0x0020`. So the data-window read at
`0x8010` **is not issued from `S_SRC` with `EP_IO`**.

**Next: find which path does issue it.** Candidates are the `lab` path (`S_LABB`,
`S_LABB_W`) and the destination side (`S_DST`, `S_DST_W`) — the reference instruction is
of the form `mov (bx0) (e), $0x69`, an external-space source with a data-memory
destination. Print `io_rd`, `io_addr`, `io_ack`, `io_rdata` and `src_val` across **all**
states rather than a guessed subset; the guessed subset is what just cost a run.

### Where to pick up — 2026-08-19, later

Four things established since the midday note, two of them corrections.

**1. `$0xNN` in the TGP disassembly is a DATA ADDRESS, not a register.** It comes from
`mb86233d.cpp`'s `memory()` helper — `case 0x000: "$0x%x", reg & 0x7f` — while `regs()`
is used only for `brul`/`bsul`'s register form. So at the divergence

    06D4: mov d, $0x43        writes data[0x43]
    070C: mov d, $0x42        writes data[0x42]
    072D/072E/072F            reads them back, plus data[3]
    0730: fadd

the operands are **data memory**, filled by the FP chain at `06EE`-`070C` (`fml`,
`fmrd`, `fabd`). An earlier note in this session claimed they were `x0`/`x1` via
`read_reg`; that was wrong and is withdrawn.

**2. The PC-stream lockstep has hit its structural limit.** `0731 brif ged` is merely
where a wrong **value** first changes control flow. The error itself is somewhere in
that FP chain, and no amount of PC comparison will localise it. **Per-retire value
comparison is what is needed**, which is the thing `mb86233_ref.cpp` does for generated
instructions and nothing does for real microcode.

**3. Getting register/memory values out of MAME: three routes tried, all failed.**

- `install_read_tap` on a CPU's **program** space never fires — instruction fetches use
  the direct path and bypass taps. Rules out PC-hooking that way on any CPU here.
- `trace f.tr,tgp_copro,noloop,{tracelog "x1=%04X ",x1}` writes the instruction lines
  but **no action text**, with a constant format as well as with registers. So it is the
  action mechanism, not the register symbols.
- `bpset 730,1,{tracelog ...}` after `focus tgp_copro` never fired.
- A **data**-space tap works but saw only one matching read in 200 frames, far fewer
  than the instruction stream implies. Worth understanding before relying on it.

**4. The four zero-init commits DID change behaviour, and I called them harmless.** Our
TGP now retires **324** instructions where runs before them reached **537**. Whether
that is better or worse is unmeasured. Check it: the inits are individually defensible
(an M10K and a flop come up cleared on the device) but their effect was asserted, not
tested, and one of them may be masking or moving the divergence.

### Where to pick up — 2026-08-19 midday

`make tgp_trace SECONDS_RUN=10 BOOT_CYCLES=1500000000` **diverges at instruction 604**:

    0730: fadd
    0731: brif ged #0x73a      reference falls through to 0732; we branch to 073a

So an FP condition flag, or the operands feeding it. The microcode is

    072D: mov $0x43, d
    072E: mov $0x42, a
    072F: orad : mov $3, a     the transfer beats orad, per the write-priority rule
    0730: fadd

**`$0x43` is a REGISTER, not a data address** — `read_reg` masks its argument to six
bits, so these are register reads. A data-space tap sees only `data[3]` and is the wrong
instrument; that was tried.

**Getting the reference's values needs a register read at that instant**, and two routes
failed:

- `install_read_tap` on the TGP's **program** space never fires. MAME fetches
  instructions through the direct path, which bypasses taps. Do not use PC-hooking via
  program taps on any CPU here.
- `trace tgpr.tr,tgp_copro,noloop,{tracelog "A=%08X ...",a,d,st}` produced the
  instruction lines but no register values. The action syntax needs checking, or use a
  breakpoint (`bpset`) with a print, or MAME's Lua debugger hooks.

**Our side needs `BOOT_CYCLES=1500000000`** to reach `0730` at all — a 700 M run stops
at ~324 TGP retires, short of it. `TGPTRACE=1` already prints `a`/`b`/`d`/`st` per
retire, so our half of the comparison is one long run away.

**Do not guess whether it is the flag or the data.** Both operands come from registers
that are loaded from coprocessor RAM and the data ROM, which only started flowing
today, and four diagnoses were withdrawn on 2026-08-19 for reasoning instead of
measuring — including three consecutive guesses at a value (`0xffffffff`) that turned
out to be **correct**.

### Corrected 2026-08-19: the coprocessor stops working, it does not compute wrongly

Everything below this heading was written before MAME was asked the obvious question,
and two of its conclusions are withdrawn.

**The `ffffffff` in coprocessor RAM is CORRECT.** `tools/mame_tgp_io_full.lua` shows the
reference's TGP doing `W io 0008 <- 00010000` then `W io 0009 <- ffffffff`. Four
diagnoses chased that value — uninitialised RAM, no writer, the math units, the
register file — and all of them were chasing a non-problem.

**The difference is VOLUME.** The reference makes **158,391** io accesses over 400
frames and keeps writing coprocessor RAM until it writes the word whose low byte is
zero, which releases the V60 from `FED5A4`. Ours makes about fourteen and parks at
dispatch with `pc=0043`.

**And `tgp_trace: IDENTICAL for 342 instructions` does not mean what it was taken to
mean.** That was a 3-second window holding the reference's first 343 collapsed
instructions, with the TGP idle for most of it. Our coprocessor matches the opening and
then stops. M0 exit criterion 2 is **not** met.

Next: `make tgp_trace SECONDS_RUN=10 BOOT_CYCLES=1500000000`, long enough to reach the
400-frame behaviour, and the divergence names itself.

### Report for the morning — 2026-08-18, end of session

**The coprocessor works.** `make tgp_trace` reports `IDENTICAL for 342 instructions`,
the reference's entire traced window. M0 exit criterion 2 is met for what the game
executes. The command exchange is byte-identical to the reference — same four words,
same pop PCs, same `42520000` result — and 21 commands complete.

**On the board** (build `99b9857a`, deployed): stable sky and sea, **no blue
flashing**, and row `03` reading 11 pushes against 11 drains — the first hardware
evidence the TGP takes commands. It then deadlocked exactly where simulation said,
row `10` = `000492`. That deadlock is fixed since; the board has not been reflashed.

**The block now:** the V60 pushes 71 command words and stops. Identical state at
600 M and 1.5 G cycles, so parked rather than slow.

#### What the reference does in that loop, now fully read off the trace

`FED56F`-`FED5D0`, from an 8-second reference trace (the 2-second `v60_trace` window
never reaches it):

    FED56F  mov.w #1B010000, [R24]     command word
    FED577  mov.w R1, [R24]            four more pushes: R1, R5, R0, R2
    FED587  mov.h #0, D00000[PC]       copro RAM address := 0
    FED58F  cmp.h #0, D00000[PC]       read it back, confirm it took
    FED59D  movea.w D20000[PC], R1
    FED5A4  in.w  [R1], R0             poll copro RAM
    FED5A7  test.b R0
    FED5A9  bne   FED5A4               LOOP UNTIL THE LOW BYTE READS ZERO  (~32 times)
    FED5AF  mov.h #8001, D00000[PC]    then address := 0x8001
    FED5C9  in.w  D20000, R0           and read the results out
    FED5D0  in.w  D20000, R1

**So the TGP must WRITE coprocessor RAM, and the V60 spins until it does.** Ours never
writes it — the TGP's io accesses reach `0x0020` (sincos) and have never touched io
`0x0001`, the RAM data port. That is the next thing to chase.

#### The anomaly flagged here was mine, and it is resolved

`WATCH_PAGE=0xD2` reported zero reads of page `d20000` while `pc now fed5a4` said the
V60 was on the instruction that reads it. **Those were two different runs.** The page
census came from a 300 M-cycle run and the PC from a 600 M one, and at 300 M the V60
is still in the `fe1433` wait loop — its last 128 distinct PCs are `fe1433`/`fe1435`/
`fe143d` and nothing else. It does not reach `fed5a4` until later.

No contradiction, no instrument fault: an apples-to-oranges comparison, the eighth and
most basic instrument error of the session. **Always quote the run length with a boot
figure** — this file already says so about `BOOT_CYCLES` scaling, and the same rule
covers comparing two runs to each other.

#### MEASURED, and this is where to start: our copro RAM reads return 0xff

`make m1_boot BOOT_CYCLES=700000000 WATCH_PAGE=0xD2`:

    d20000  1,120,224 reads
    cyc 526042741  d20000 -> ff  be=11  pc=fed5a4
    cyc 526043049  d20000 -> ff  be=11  pc=fed5a4
    ... 1.1 M more, all identical

**The reference's loop exits when this reads ZERO. Ours reads `ff` forever.** That is
the whole reason the V60 never leaves `FED5A4`, and it is one value in one read path.

`0xff` is the unmapped default, not RAM contents — so the read is not returning
`ram[adr]`. **Every layer looks correct on inspection**, which is why this needs
instrumenting rather than more reading:

- `m1_main:410` — `to_copro = sel_copro_adr || sel_copro_ram || sel_copro_fifo`,
  so a RAM read is routed to `copro_q`, not to the mux that ends in `16'hFFFF`.
- `m1_decode` — `hi == 8'hd2 || hi == 8'hd3` asserts `sel_copro_ram`.
- `m1_copro_if` `S_IDLE` — `if (v60_ram) st <= S_V60_RAM;` is checked **first**,
  before the register/FIFO branch.
- `S_V60_RAM` — `if (!we) q <= a1 ? ram_q[31:16] : ram_q[15:0];`

So one of those is not doing what it reads as. **Next step: print
`main.copro.st`, `main.copro.adr` and `main.copro.ram_q` at each `d20000` access.**
That says in one run whether the FSM reaches `S_V60_RAM`, whether `adr` is the 0 the
V60 wrote at `FED587`, and whether the RAM itself holds zero. Do not fix from the
code-reading above — four layers all looked right and the value is still wrong.

Worth checking early: whether the V60's `mov.h #0, D00000[PC]` at `FED587` actually
lands in `adr` — `cmp.h #0, D00000[PC]` at `FED58F` reads it straight back, so if
`adr` were not taking the write the reference's own check would fail too, which
suggests it does.

#### Also worth knowing

- **`CLAUDE.md` is gitignored** (`.gitignore:122`). Several commit messages today say
  "CLAUDE.md baseline updated" — those edits are on disk but **not in the repository**,
  and a clone gets none of them. Durable findings belong in `docs/`.
- **The hardware build grew +2,873 ALM and +43 M10K** against the recorded baseline
  and today's changes do not account for it. M10K is at 82% with the rasterizer's band
  buffer wanting ~51 of the remaining 101. Worth a comparison build.
- **The V60 is not the CPI problem.** 6 CPI in isolation against the reference's ~8;
  65% of cycles are bus stalls outside the core.

### Open, in order

0. **FIXED, pending confirmation: the copro FIFOs are a mutual interlock and we
   implemented one half.** `model1_m.cpp:29-44` halts each processor when the FIFO it
   reads is empty and releases it when the other side fills it. A push into a full
   inbound FIFO correctly withheld its acknowledge; a **read of an empty outbound
   FIFO did not** — it acknowledged and returned `fout_head`, stale on an empty FIFO.
   The V60 took that for a result and span at `fed5a4` while the TGP waited at
   `0x0492`. Only offset 0 stalls: offset 1 returns the high half of the already
   latched word and must always complete. `m1_copro_if` 254 checks.

   **The coprocessor RAM path is NOT missing** — `m1_copro_if` implements it in full,
   8192 words. `copro RAM writes=0` meant the V60 never reached that code. It was
   named as the likely cause twice before anyone read the module.

0. **NEXT: the V60 polls COPRO RAM at `fed5a4` and the TGP never writes it.**
   With the FIFO fixed the copro exchange completes **21 commands correctly**, then
   stops: identical state at 600 M and 1.5 G cycles (`pushes=71 returns=21 pops=21`,
   `TGP retires=537 pc=0043`) while the V60 executes 8.8 M more instructions at
   `fed5a4`. Parked, not slow.

   `tools/mame_v60_iospace.lua` puts ~138 k reads at PC `fed5a4` and 148,896 reads at
   **`0xd20000`, the copro RAM data port** — so that loop is polling coprocessor RAM,
   not the FIFO. Our `copro RAM writes=0` and our TGP's io accesses reach only
   `0x0020` (sincos); it has never touched io `0x0001`, the RAM data port. Confirm
   the PC-to-address pairing before acting on it — that inference is from two
   separate census columns, not one measurement.

0. **DONE: a FIFO read at TGP pc `00a5` popped without retiring.** Our TGP consumes all
   four command words — the same four the reference pushes, from the same PCs — but
   never advances past `00a5`, where the reference does `00a5` then `00a6` and reaches
   the multiply at `00a7`. Look at `fifo_ack` against `fifo_in_pop` in `m1_tgp`, and
   at how `mb86233_mem` holds `ext_rd` across the memory states: a request held for
   more than one cycle pops more than once, and an acknowledge on the wrong cycle
   retires nothing.

0. **WITHDRAWN: "our V60 pushes FOUR, the reference pushes FIVE."**
   Counted on both sides. Every word we push matches the reference in order; the
   missing one is **`00000000`**, second in the sequence, popped by the reference's
   TGP at the dispatch stage. The TGP is one word short of a command and waits; the
   V60 thinks it has sent one and waits for the result. **That is the entire
   deadlock.** The pushes happen around `ff97xx`, *before* `v60_trace`'s divergence at
   26,945 — so either the streams match and this is a bus/decode fault where a write
   to `0xd80000` does not become a push, or the trace is masking a divergence. Find
   out which; do not assume.

0. **Superseded: does a command carry five words, and does each side agree?** With the
   interlock in, the V60 stalls at `ff9754` after **4 pushes** while the TGP stalls at
   `0x00a5` wanting more. The reference's command is **five** words in, one out —
   `04000000 00000000 01000000 3f400000 428c0000` -> `42520000`
   (`tools/mame_tgp_fifo.lua`). Count both sides rather than guessing; a zero counter
   has been misread as a missing feature twice in one day.

0. **The deadlock this replaced, for reference.** With the ST
   and `brul` fixes in, the coprocessor round-trip works (`returns=20`, `pops=20`) and
   then both sides stop. Identical state at 600 M and 1.5 G cycles — `TGP retires=501
   pc=0492`, `fifo_rd=1` on an empty input FIFO, V60 spinning at `fed5a4` polling the
   output FIFO. **This is further back than the pre-fix core reached**, which got to
   `ff7d7e` with tilemap 1's 648 category-1 tiles — because it was ignoring a
   coprocessor that never answered. Most likely missing piece: **`copro RAM
   writes=0`** while the reference's V60 reads `0xd20000` 148,896 times per 600
   frames. **Do not flash the 20:22 build**; simulation already predicts the result.

0. **A measured CPI gap of 3.2x, and it is NOT in the V60.** The reference completes
   11,506 iterations of the `fe1433` wait loop where we complete 3,619. `make m1_boot`
   now breaks the cycles down: **65% have a bus request outstanding** (data 38%,
   fetch 27%, barely overlapping), so ~20 of 30.5 CPI is memory and ~10 is execution.
   The V60 in isolation is **6 CPI** at the shipped `ce=1` across latencies 0-64,
   against MAME's implied ~8 — so **the core is fine and the memory path is the
   target**: an instruction cache, deeper prefetch, or a dedicated fetch port. This
   matters for the planned V60 split, which is not the lever on this number.
   `tools/v60_cpi_sweep.sh` had hardcoded `CEDIV=3` while the core ships `ce=1`;
   fixed, and its workload only produces four instruction fetches so it cannot see
   fetch pressure at all.

0. **`[5002]` — tilemap 2's H-scroll — is zero here and moving in the reference.**
   That is the missing scrolling, measured on both sides: the reference changes it
   on 1,344 of 2,000 frames (`000b -> 000e -> 0101 -> 01dc`), and `m1_boot` at
   `BOOT_CYCLES=600000000` (frame 345) reports `[5002]=0000`. It is the most
   specific open difference and the likeliest single cause of what is on screen.
   Suspected chain, not yet confirmed: block offset `0x0b` was 0, so we branched
   past `FF9741`, which writes `0x1000000` and the float `0x3F400000` to a port and
   reads a result back with `in.w` — a transform whose output is a plausible source
   for that register. Re-run the 600M boot with fix 8 in and compare `[5002]`.

1. **`make v60_trace` — re-run it.** It diverged at ~206,307 on the I/O board
   handshake at `0xC00040`, which turned out to be a **guessed constant in a
   peripheral, not a CPU fault**: `m1_ioboard`'s `LATENCY` was 64 cycles where the
   reference takes **740,684** (38,577 us, measured — `tools/mame_iohandshake.lua`),
   so our poll loop ran once where MAME's runs 36,308 times. `LATENCY` is now the
   measured figure, so the trace should carry past this point; **the next divergence
   it reports has not been looked at yet.** Memory agreement is at write **266,496**
   and rising with each fix (28,698 -> 77,904 -> 266,496).

   When the diff next points at a wait loop, measure the thing being waited on
   before suspecting the CPU. That mistake cost a session here.
2. The SDRAM read path has never been analysed — Quartus 17.0's fitter segfaults on
   the multicycle it needs. Try 24.1, which is installed. Constraints are opt-in via
   `MODEL1_SDRAM_SDC=1` and default off.
3. M2 rasterizer, M4 sound.

### On the board right now — 2026-08-18 evening

`99b9857a048af436f91cdb52b5921475`, built 20:22, deployed to
`/media/fat/_Arcade/cores/Model1.rbf`. **29,536 ALM, 452/553 M10K, 50 DSP, +0.301 ns.**

What it shows: **sky and sea, stable, no blue flashing** — window mode is off
(rows `15`/`16` = `000000`) and tilemap 2 covers the whole screen (row `13` =
`02E800`). No text. The coprocessor is alive — row `03` reads 11 pushes against 11
drains, the first hardware evidence the TGP takes commands — and then deadlocked, row
`10` = `000492` matching the simulation exactly.

**This build predates the FIFO interlock fix above.** It is a good baseline for the
next hardware comparison, not a target to beat.

### The previous "on the board right now"

`3851ff10ac6a4839d01668bb9a0b4330` — confirmed working, sky and sea with the blue
flash. `55965cd8d77b2a6443b9d141dea568f8` is the previous known-good fallback.

---

# Handoff — 2026-08-16

State of the Sega Model 1 core at the end of the M1 memory/CPU/video work.
Everything below is committed and pushed; the tree is clean and the full suite
is green.

`README.md` was brought back into agreement with this document on 2026-08-15 — it
still described M0 as the current milestone. If the two ever disagree again, this
file is where the measurements are.

## On hardware, as of 2026-08-16

**The core loads and runs on a real DE10-Nano.** `.rbf` built, MRA loads, the
ROM streams in complete and the video path drives HDMI. Four separate faults
were found and fixed getting there, every one of them invisible to simulation
until simulation was changed to model what hardware does:

| Fault | Symptom on the board |
|---|---|
| `ioctl_wait` ungated, holding `HPS_BUS[37]` | core never appears to load at all |
| memory subsystem inside the game reset | "Assembling ROM" frozen partway |
| core clocks in no clock group (−87 ns slack) | clean build, nothing runs |
| one port meaning both "SDRAM ready" and "ROM loaded" | "Assembling ROM" frozen at zero bytes |

Plus one that reported success and corrupted data: the loader **silently
dropped** every word the HPS sent more than 15 cycles after `ioctl_wait` rose.
Its test swept host latency 0..6 — exactly the margin the parameter was set to,
so it confirmed the setting rather than testing it. Buffer now 512/256, sweep to
64, and `overflow` is brought out to the debug overlay.

**`docs/mister-integration.md` is the full write-up**, framework-generic rather
than Model 1 specific, for reuse on any future MiSTer core.
**`docs/debug-overlay.md`** documents the on-screen instrument: what every row
means, and its measured cost of 307 ALM / 553 registers / zero M10K.

### The fifth fault: every SDRAM burst came back one word late

The V60 read `FE104E` as its reset vector where the ROM holds `4EF3D6`. Both are
the same burst `FFFF00FE104EF3D6`, simulation taking bits `[23:0]` and the board
`[39:16]`: the controller was calling the burst's word 1 its word 0, on every
read. The CPU therefore got a corrupt jump operand, computed a target of ~0,
landed in on-chip work RAM full of zeros, executed opcode `0x00` and halted —
generating no further SDRAM fetches, which is why the fetch count froze at six.

**It survived a session of looking straight at it.** The first fetch is at word
0, where the ROM is `000d 000d 000d 000d` — every word identical, the one
address in the image where a one-word shift cannot show. That fetch was checked
against the ROM, matched, and reads were declared correct; the wrong conclusion
then cost three long detours into the clock-domain crossings, the PLL dividers
and the clock ratio, all of which were fine. **Verify against data that can
distinguish the fault.**

`RD_LAT = CL + 3` is derived term by term in `m1_sdram` and derived entirely
against `sdram_model`, which samples commands and presents data on the same edge
the controller uses. The board does not: `SDRAM_CLK` is the inverse of
`clk_sys`, so the device answers half a period away, and the model's own header
says that forwarded-clock phase is "deliberately not modelled here". Every term
is right and the total is a simulation figure.

The capture depth is now selectable at run time, CL+2 through CL+5, from the
OSD; simulation ties it to CL+3 so no harness was rebaselined. **Hardware wants
CL+2**, and with it the core boots: Virtua Racing's TEST MODE menu renders from
real ROM, the V60 runs at `fe1435`, the I/O board has answered 1,398 times, and
every value the overlay reports matches simulation exactly.

## The wobble — resolved

The picture was unstable on hardware, flashing white and jumping vertically. It
was the scaler, not the core: `vsync_adjust` fixed it and the picture has been
steady since. The diagnosis cost a day and two of the three theories died on
contact with a measurement.

**The reading that wasted the most time**: 6,849 fetch deadline misses over 103
frames, read as a rate — "one line in six" — when the counter is cumulative and
every miss happened before frame 31. Seventy-two consecutive frames were clean.
A cumulative counter is not a rate, and this file said so afterwards and the
mistake was still repeated later in the same week.

The engine work done chasing it was worth keeping anyway — cost per dense layer
went 1,614 -> 1,182 cycles, text layers ~700 -> 267 — and the current build
reports **zero** deadline misses on real content.

## The M1 2D defect — FOUND AND FIXED, 2026-08-17

**Two faults in `draw_common`, both measured against MAME, both now fixed.** Full
detail with the source quotes is in `findings.md`; the short version:

1. **The row mask is keyed to the odd/even tilemap, not to the tile category.**
   `draw_common` computes `tpri = layer & 1` before a shift and `win = layer & 1`
   after it — the category and the odd tilemap, one line apart. We used the mask
   as `mask ^ category`. That is right for two of the four combinations and
   inverted for the other two, and it suppressed every category-1 tile on the even
   tilemaps. `INSERT COIN(S)`, `CREDIT 0` and the SEGA logo live there.
2. ~~A pair in window mode draws nothing unless `hscr & 0x8000`.~~ **WITHDRAWN, and
   it is now the open defect.** There *is* an `else` on that inner `if`, at
   `segaic24.cpp:418-456`, and in it MAME splits the screen into two rectangles and
   draws **both** maps of the pair. Attract does select window mode 1 on pair 2/3
   with `hscr` never above `0x0200` — which means the pair is drawn as a **vertical
   split at scanline `v`, tilemap 2 above and tilemap 3 below**. That is a horizon:
   **the sky and sea are correct, and suppressing them is the bug.** It paints
   palette 0 — blue — across the screen instead. See the START HERE block below.

Measured before: tilemap 0 held content in 617 of 680 frames and won a pixel in 47,
all of them boot frames. After: 9,674 pixels, then 7,449 with the full attract
screen up, and tilemaps 2/3 correctly silent.

**Our tile RAM content matches MAME's census exactly**, confirmed twice: `58, 144,
1024, 1024` sampled at the ranking screen, and `315, 648, 4096, 4096` at full
stride over the whole array (the sampled census strides by four). So the V60
produces the right picture data. What the 2D path then does with it is the defect.

**What is left on that screen is the 3D.** 93% of the frame is backdrop, because
the road and cars that fill it are geometry and the rasterizer is not built. Expect
text on a flat colour, not a full picture. That is M2/M3, not a 2D fault.

### The board, and why its photographs misled

The board showed sky and sea alternating with a flat blue. That was read as
"the sky/sea is the wrongly-drawn pair and the blue is the backdrop", which has it
backwards: **the sky and sea are correct and the blue is the fault** — the window
split not being drawn. The user settled it by matching the blue's flash rate to the
text blink rate, which no still frame can carry. Simulation rendered "correctly" only because the one
frame it captured was the ranking table, whose text sits on tilemap 1 — the single
combination the wrong mask formula got right.

**Building the `.rbf` is TWO commands, and `make quartus` is not one of them.**
There is no `SRCS_Model1`, so `make quartus MOD=Model1` writes a project with no
source files and fails six seconds in with `Error (12007): Top-level design entity
"Model1" is undefined`. It cost a build cycle, and this file said otherwise.

```
bash tools/mister_project.sh                       # stages build/mister
cd build/mister && quartus_sh --flow compile Model1
```

The framework's `sys_top` is the real top level; `emu` — our `Model1.sv` — is what
it instantiates, which is why the project has to be staged rather than generated
from a module list. `make quartus MOD=<module>` is for single modules, area and
Fmax on one block; `MOD=m1_integrated` is the largest of them and still produces
nothing loadable.

**Board access**: SSH key auth stopped working mid-session — the key is offered
and the host key still matches, so it is the same machine, but
`/root/.ssh/authorized_keys` does not accept it. Password auth works with the
stock MiSTer default. No `sshpass`, `paramiko` or `pexpect` on this host, so a
20-line stdlib helper drives `ssh`/`scp` through a pty instead of installing
anything; it reads the password from a file so it never reaches argv or shell
history. Recreate it if needed rather than leaving a credential on disk.

The core can also be loaded remotely, which saves a trip to the machine:

    printf "load_core /media/fat/_Arcade/Virtua Racing.mra\n" > /dev/MiSTer_cmd

Two things that have burned time. **The board runs UTC and the host BST**, so every
timestamp on the board reads an hour behind — that looked like a stale flash until
`date` was compared on both ends. Verify by **md5**, not mtime. And check for a
running flow by exact process name: `pgrep -x 'quartus_(map|fit|sh|asm|sta)'`.
`pgrep -f quartus_` matches its own command line and always reports something.

### Where it stands on hardware, and the next three moves

The row-mask and window-mode fixes are **confirmed working on the board** — a
video of the screen shows the renderer obeying `ctrl` correctly in both states
(see `findings.md`). They did not put text on screen.

**THE OPEN M1 DEFECT IS FIXED. Window mode 1 draws its vertical split.**

`draw_common`'s inner `if (hscr & 0x8000)` was recorded as having no `else`. **It
has one, at `segaic24.cpp:418-456`**, and in it MAME splits the screen into two
rectangles and draws BOTH maps of the pair, one in each. We suppress both.

Virtua Racing's attract sets `ctrl = 0x2000-0x23xx` on pair 2/3 — window mode 1 —
with `hscr` below `0x0200`, so bit 15 is never set. So the reference draws that
pair as a **vertical split at scanline `v`, tilemap 2 above and tilemap 3 below**.
That is a horizon: **it is the sky and the sea.** Suppressing the pair paints
palette 0 across the screen instead, which is blue, at whatever rate the game
toggles the mode — which is what the board shows, and what the flash is.

**Measured on real game code**, `make m1_frame FRAME_TRACE=1
FRAME_CYCLES=3400000000`, same frame before and after:

| | before | after |
|---|---|---|
| backdrop | `175982/190464` (92%) | **`0/190464`** |
| tilemap 2 wins | `0` | **`176366`** |
| tilemaps 0/1 wins | `11038, 3060` | `11038, 3060` |

The change was one term: `hscr` bit 15 never belonged in the layer decision. For
mode 1 both of MAME's branches pick the same map — bit 15 set flips at `y >= v` per
scanline, bit 15 clear clips two rectangles at the same `v` — so the bit selects
where the horizontal scroll comes from, not which map draws.

`tb_m1_video.cpp`'s reference is corrected in step, and the suite now **fails 4,330
checks** against the reinstated bug, verified by doing it. It did not before,
because the fixture set `hscr` bit 15 and the faulty term was `!win_hs || ...` — an
input the game never presents. `findings.md` has that, and the fact that the first
report of the blindness invented two wrong mechanisms for it.

Still owed on this path:

1. **modes 2/3 — THIS IS THE TEXT BLINK, do it next.** Measured over a full
   2,478-frame run: `ctrl = 0x4000` on pair 0/1 — the pair the text lives on — for
   **194 frames, 7.8%**. On those frames all four layers win nothing and 99.8% of
   the screen is backdrop. After the mode 1 fix the sky and sea are steady on them
   and the text is still gone, which is the "text flashes on and off" reported
   from the board. Needs a per-**pixel** split at `x = h`; `m1_tile_fetch` is the
   home, since it writes four pixels at a time with a 4-bit `lb_masked` and knows
   its own x. The row mask is 8-pixel granular so it cannot be reused directly,
   but it is the same insertion point.
2. **`hscr` bit 15 set** — the per-line H-scroll table at `0x4000 + 0x200*layer`.
   Nothing measured reaches it. Last.
3. **A disabled layer 2/3 still paints.** `cat0` treats them as opaque
   unconditionally, so `vscr` bit 15 does not stop them; MAME's
   `if (vscr & 0x8000) return;` skips before any category decision. RTL and
   reference agree, so the suite cannot see it. Separate bug, unresolved.

**The full-screen blue is tilemap 2 drawn opaque over an empty map.**
Not the backdrop — `bd=0/190464`, nothing falls through. Tilemap 2 wins 180,790 of
190,464 pixels, its every tile word reads `0x0000`, and that indexes palette entry
0, which is blue. The blue and the backdrop are indistinguishable on a photograph
and land in different counters, and the search went to the wrong one for a while.

**RUN THE SIMULATION LONG ENOUGH — 3.4e9 cycles, not the default.** At 4e8 cycles
it reaches frame 296 and tile RAM holds map 0 only, which was written up here as a
divergence from MAME and is not one. At 3.4e9 it reaches frame ~352 and tile RAM
fills to `0000:315 1000:648 2000:4096 3000:4096`, which is **MAME's census
exactly**. Our tile-RAM content is right. That withdrawn entry is in
`findings.md`; the failure was run length, and this is the third board-versus-sim
comparison made at the wrong simulation state.

**The whole defect then reproduces locally, no board needed**, at frame 381:

```
F382 bd=175982/190464 win=11038,3060,0,0 have=79,144,1024,1024
     rtl_have=2520,4095,4095,4095 wr=252,0,24,144 ctrl=0000,2000
```

Pair 2/3 in window mode 1, maps 2 and 3 holding full content, winning **zero**
pixels, and 92% of the screen falling through to the backdrop — palette 0, blue.
Symptom, cause and effect on one line. Fix the window split and this is the frame
to check it against.

Note `wr=252,0,24,144`: the game *does* rewrite maps 0/1 and the row masks once it
reaches this screen, which corrects the "the game loop never rewrites the tilemaps"
reading taken at frame 92.

In order:

1. **The hardware content census is BUILT** — overlay rows `19` and `1A`, two
   12-bit counts each, tilemaps 0-3. Read them against the win census in rows
   `11`-`14`:

   | have | won | Meaning | Where to look |
   |---|---|---|---|
   | 0 | 0 | the layer holds nothing | the CPU, or its writes to tile RAM |
   | >0 | 0 | content is there and not reaching the screen | masking, window mode, priority |
   | 0 | >0 | an opaque pass over an empty map | correct, and worth recognising |
   | >0 | >0 | on screen | — |

   That third row is real and was seen in simulation: tilemap 2 winning 180,790
   pixels while holding no content at all, because tilemaps 2/3 draw their
   category-0 pass opaque. Do not read a zero `have` as a broken layer without
   checking `won`.

   Validated against a direct read of tile RAM — `make m1_frame FRAME_TRACE=1`
   prints both `have=` (the whole map, from the testbench) and `rtl_have=` (words
   fetched on the displayed span, from the RTL). They differ in magnitude by
   design and agree about zero, which is the reading that matters.
2. **Read the WRITE census against the content census** — overlay row `1B`, CPU
   writes into tile RAM per frame: the tilemaps on the left, the scroll and
   H-scroll registers on the right. Counted on `m_req && m_we && sel_tileram` in
   `m1_main.sv`, upstream of the RAM, so a fault inside the memory cannot hide
   from it. This is the next thing to look at on hardware:

   | row `1B` | Meaning | Where to look |
   |---|---|---|
   | `000` `00C`–`018` | matches simulation exactly | the init-time writes — the loop never rewrites the maps |
   | `000` `000` | the CPU writes no tile RAM at all | the V60's own behaviour; further off-reference than anything measured yet |
   | left `> 0` | the loop rewrites the maps and they still read blank | the memory |

   **Simulation already measured the first row of that table**, and it was not
   expected: the game loop writes **zero** words to any tilemap, and 12–24 words
   per frame to the scroll region alone (`findings.md`). Tilemap 0 holds 1,624
   fetchable words at the same moment, so its content came from init. That is why
   the right field is the scroll region and not the other tilemap pair — a row
   showing both map regions reads `000 000` on a working design, which cannot be
   told from a broken counter.

   So the most likely reading on hardware is that row `1B` matches simulation, and
   the question becomes **whether the board's init-time tile writes land at all**.
   The next instrument after this one compares the two copies: `tram_c_*` and
   `tram_v_*` are separate arrays taking the same write strobe, so a CPU-side
   readback that finds content where the video side finds none isolates the
   crossing, and one that also finds none says the writes never landed.

   **The dual-clock hazard is real but the arithmetic cuts against it**, and this
   was argued in both directions before being settled on paper. Quartus warns the
   tile RAM's read-during-write is undefined while Verilator models it as clean,
   so it is a genuine sim-versus-hardware divergence in the memory in question
   (`findings.md`) — and the *selectivity* fits it well: MAME's counts show maps
   2/3 are written once and static (4096 constant at every sample) while maps 0/1
   are rewritten every frame (205→315→1675→153→663), so the maps reading blank
   are exactly the maps being written. That is a good fit.

   What kills it outright is that **there are no writes to collide with**: the
   game loop rewrites no tilemap words at all, measured above. And what killed it
   before that measurement was the *direction* of the error. Corruption
   returns whatever the RAM has mid-write; a garbage word is overwhelmingly
   non-blank, and the census counts non-blank words. So read-during-write can only
   push the count **up**, or scramble which tiles appear — it cannot turn several
   hundred non-blank words into the `008 000` the board reports. A count that low
   means the words are not there to read, or are never read at all.

   Treat it as a hazard to close on its own merits, not as the explanation. The
   fix, when it is done, is to move tile RAM to a single clock domain and cross
   the CPU's writes in as `m1_cdc_port` already does for SDRAM — a single-clock
   simple dual-port RAM has *defined* read-during-write, which both toolchains
   model identically. Registering the read does not help; the corruption is inside
   the RAM block, not at the crossing.

   Free experiment before any rebuild: the OSD carries
   `O[5:4],SDRAM read phase,CL+2..CL+5`, so sweeping it costs a menu click and
   says whether any memory-timing sensitivity exists at all.
3. **The test/service switches are CORRECTLY MAPPED** — checked against the
   oracle, `INPUT_PORTS( vr )` in `model1.cpp`:

   | Bit | MAME | Ours |
   |---|---|---|
   | `0x04` (2) | `PORT_SERVICE_NO_TOGGLE` | `io_test` |
   | `0x08` (3) | `IPT_SERVICE1` | `io_service` |

   Both active low, both in IN.0, which `findings.md` measured as DPRAM `0x08`.
   So bit order, address and polarity are all right and **no edit is warranted**.

   The naming is misleading and worth knowing: bit 2 is MAME's *Service Mode*
   switch — the one that opens the test menu — while bit 3 is the service *coin*
   button, which does not.

   **Setting `Test switch` On and resetting was tried on hardware and does NOT
   work.** So with the byte contents confirmed against the oracle, the remaining
   unknown is **where those bytes land**: `m1_ioboard`'s `INPUT_BASE` is `0x000`
   and `io-board.md` records that the base address was never confirmed — only the
   bit layout within a byte was. The contents are right and the address is a
   guess.

   Measure it, do not adjust it. Install a **read tap** on the I/O board Z80's
   DPRAM in MAME and log which addresses the V60 actually reads for IN.0 — a
   memory watch cannot do this, because a read leaves no trace in memory. That
   instrument is the one that found the fourteen control bytes in the first place.
   Two candidates worth checking specifically: the game may read the inputs
   through a different DPRAM window than the sweep publishes to, and the real
   board's Z80 may transform them rather than copying them straight through.

### How to see it, and what to expect

    make m1_frame FRAME_CYCLES=900000000 FRAME_TRACE=1

One line per frame: backdrop share, per-tilemap **wins**, per-tilemap **content**,
window control, interrupts raised/acknowledged, and the PC. The two censuses side
by side are what found this — "holds nothing" and "holds text that cannot reach
the screen" read identically from wins alone and need opposite fixes.

At the attract ranking screen, post-fix:

    F410 bd=177927/190464 win=7449,4704,0,0 have=58,144,1024,1024 ctrl=0000,2000

`have` matches MAME's own census exactly. `bd` is 93% because the 3D is missing.

### Historical note: three wrong turns on this one

Kept because each looked convincing:

- **"The 2D path renders correctly, so the board must be diverging."** One captured
  frame cannot see an alternation, and the frame it captured — the ranking table —
  is the one screen whose text sits on the single tilemap/category combination the
  wrong mask formula got right. Two builds were spent hunting silicon.
- **"Attract has screens with no text at all."** Said from a census showing
  tilemap 1 empty, while `INSERT COIN(S)` was plainly in the snapshot. The text was
  on tilemap **0**. Being challenged on that is what found the bug — the question
  "which layer is that text on, then?" was the whole investigation.
- **"The vblank handler never runs."** A static picture with correct content looks
  exactly like it. Interrupts were fine: PSW reaches `0x10040000` as MAME's does,
  with 700+ acknowledges over 200 frames. Count at the acknowledge, not the raise.

Before the V60's `IN`/`OUT` fix this section read "most of the 2D does not draw",
and the row mask and window mode were each implemented and **changed nothing on
screen** — because the V60 never got far enough. Both were real gaps and both were
also implemented *wrongly*, which the picture could not show while the CPU was
stuck. Three correct-looking fixes in a row changed nothing visible.

### Ruled out, by measurement

Do not re-derive these.

| Suspect | Evidence it is not the cause |
|---|---|
| fetch bandwidth | overlay row `0C` reads **zero** deadline misses; an overrun repeats a scanline anyway, which is not the symptom |
| the ROM | 26 of 29 parts match MAME 0.289, **no CRC mismatches**, all twelve the MRA loads among them |
| the vblank interrupt | reaches the V60 and is **taken**: PSW `0x10040000` as MAME's, 700+ acknowledges over 200 frames |
| tile RAM contents | our per-map content census matches MAME's **exactly** — `58, 144, 1024, 1024` at the ranking screen |

### The row mask: a real gap that was not the whole bug

segas24 masks each tilemap in 8-pixel columns from a table at tile RAM `0x6000`
(tilemaps 0/1) or `0x6800` (2/3), four words per scanline. MAME draws every
tilemap twice, once per tile category, and inverts the mask for the second pass
— so a column shows whichever category matches its mask bit. Ignoring the table
is equivalent to `m = 0`, which MAME's own fast path treats as "draw all 128
pixels", so a layer was painted solid across windows that should have been
transparent.

It was measured in use: table `0x6000` holds 72 non-zero words at the attract
frame, pattern `007f ffff e000` repeating from scanline 88, and `vscr & 0x1ff`
is 88 for that tilemap. Two independent numbers agreeing.

It is now implemented — gated in the mixer rather than folded into
`lb_transparent`, because tilemaps 2/3 draw their category-0 pass opaque and an
opaque pass ignores transparency. Cost **+204 ALM, zero M10K**, timing +0.401 ns.
`test_video` agrees with the updated reference over 380,929 checks;
`test_tile_mixer` went exhaustive 8,192 -> 131,072 states.

**And the picture did not change.** Record that plainly: the mask was a real
defect, correctly fixed, and something else is also wrong.

### The window mode — implemented, and confirmed in use

**`docs/2d-gap-analysis.md`** is the investigation behind it: what was ruled out
by measurement, what segas24 does, a per-tilemap content census from the running
reference, and the MAME harness notes.

The headline: **the four tilemaps are two pairs, not four peers.** Odd maps are
*window* maps and in `ctrl` mode are drawn only through their even partner. At the
attract frame MAME draws tilemap 3 **not at all**, and we used to draw it.

`ctrl` is the pair's **even** `vscr` — MAME reads
`tile_ram[0x5004 + ((layer>>1) & 2)]`, so one register governs both maps of a
pair, and reading each map's own makes the mode look inactive on the odd one.

Mode 1 is implemented: `v = (-ctrl) & 0x1ff` splits the screen, `(-ctrl) & 0x200`
clear swaps which map is live above the split, and the other map does not draw on
that line at all. Simulation confirms the game asks for it — `ctrl` reads `0x2000`
from the attract frame onward — and that our tilemap 3 is then correctly silent.

**Modes 2 and 3 are still unimplemented**: the horizontal split, and per-line
H-scroll from a table at `0x4000 + 0x200*layer` when `hscr & 0x8000`. The symptom
would be a vertical seam that moves. `segaic24.cpp` `draw_common` is the
reference; read it alongside `draw_rect`.

### How to measure, next session

The tooling is built and in the scratchpad pattern — run MAME from a scratch
directory, it drops `cfg/`, `nvram/` and `snap/` wherever it starts:

    mame vr -rompath ~/roms -window -skip_gameinfo -autoboot_delay 0 \
            -autoboot_script <script>.lua

`-skip_gameinfo` is required or the warning screen blocks autoboot and the
script silently never loads. `-autoboot_delay 0` or the tap installs after the
exchange it is meant to capture. Assign every notifier and tap to a global or
the subscription is collected and the callback stops with no error.

The scripts written today: log every change to a memory range, install a
read/write tap with run-length compression, snapshot at frame intervals, and
dump a named region. `manager.machine.video:snapshot()` gives a reference frame
to diff against a photograph of the board.

## Where it is

**Real Virtua Racing code boots and executes.** The V60 takes the architectural
reset vector, fetches through the packed ROM mapping, clears and tests NVRAM,
work RAM, both display lists and tile RAM, passes the ROM checksum, completes
the I/O board handshake, and runs game code out of work RAM, with zero SDRAM
protocol violations and `dbg_fp_trap` never asserted.

**Always quote the run length with a boot figure.** Every count from this test
scales with `BOOT_CYCLES`, and the numbers in commit 9577ab3 (5,304,880 fetch
lines, 19.90 CPI) came from a run roughly ten times the committed default with
its length unrecorded — which is why they do not reproduce from `make m1_boot`
and read as a regression when they are not. Reproducible, 2026-08-15:

| `BOOT_CYCLES` | instructions | fetch line fills | CPI | busiest page |
|---|---|---|---|---|
| 20,000,000 (default) | 236,367 | 116,359 | 28.20 | tile RAM |
| 100,000,000 | 1,619,871 | 2,422,369 | 20.57 | work RAM, 504,334 |

Both end at `fe143d` with `replies=3`. CPI falls with run length because the
early phase is dominated by block instructions sweeping memory; it is
converging on the ~19.9 the longer run recorded, not disagreeing with it.

Note `ifetch lines` counts **8-byte wide-port line fills, not instructions** —
this document called them "instruction fetches" until 2026-08-15.

Two boot phases get cited and they are not the same run. The **post-handshake**
one above executes out of work RAM at `fe143d`. The **pre-handshake** one
stopped at `fe095a` polling the I/O board, and is where the 7.8 M-instruction
CPI and FP-trap figures come from — that one was mostly `MOVC` sweeping memory,
so it is the weaker evidence of the two about what game code does.

**Boot initialises the whole 2D path**, which matters for the top level: with no
TGP and no rasterizer, a core built today still has content to display. Accesses
over the default run — character RAM 168,288 across six pages, tile RAM 53,673,
colour translation tables 40,960, display lists 0 and 1 at 16,420 each, palette
8,433. The palette writes are real xBGR-555 entries (`8010 8200 c000 e318 801f
83e0 83ff fc00 fc1f ffe0`), not a clear.

Built, tested and area-measured:

| block | ALM | verification |
|---|---|---|
| `s32_v60` (imported, cast-fixed) | 20,000 | 29/29 unit tests |
| `m1_sdram` + `sdram_model` | 937 | 80,009 checks, 0 protocol violations |
| `m1_main` + `m1_mainram` + `m1_glue` | ~700 | boot + 25 glue checks |
| `m1_video` (whole 2D path) | 287 | 380,929 checks vs MAME |
| `m1_rom_loader` / `m1_decode` | 319 | 1,675 / 466,714 checks |
| `bw_monitor` | 381 | 2M checks, mutation-tested |
| `mb86233_core` (TGP, not yet wired) | 2,554 | ~16.7M fuzz + lockstep |
| `m1_raster_fill` + `m1_raster_div` | 2,113 | 152,025 quads / 31.6M spans vs MAME |

**Integrated** (`make quartus MOD=m1_integrated`): 21,796 ALM, 332/553 M10K,
24.62 MHz — Fmax is the V60's, which is the critical path in context too.

The table is per-block standalone measurements, and several of those blocks are
already inside the integrated figure. The budget total is composed differently
and does not double-count: **21,796 (integrated) + 2,554 (TGP) + 937 (m1_sdram)
= 25,287 ALM.**

## How to run things

On a fresh clone, first:

    chmod +x tools/bootstrap.sh quartus/report.sh   # zip transport drops exec bits
    ./tools/bootstrap.sh                            # populates third_party/

`third_party/` is gitignored, so without that there is no MAME reference source,
no V60 upstream and no `sys/`, and nothing below works.

    make test                  # full Verilator suite, must be all fails=0
    make lint                  # must be clean
    bash tools/run_v60_tests.sh    # V60 unit suite, 29/29
    make m1_main               # CPU+memory integration, 4 configurations
    make m1_boot               # boots real ROM; needs the image below
    make m1_boot WATCH_PAGE=0xC0   # ...with one page traced address by address
    make v60_cpi               # CPI vs memory latency sweep
    make area                  # yosys proxy area, for tracking between edits
    make quartus MOD=<module>  # real ALM/Fmax; defaults to Quartus 17.0
    make quartus_list          # which Quartus installs were found, and which won
    make quartus_paths         # worst timing paths of the last build

    python3 tools/build_rom_image.py vr ~/roms/vr.zip -o build/rom

ROM images and anything derived from them never enter the repository.

`make test` prints a fixed set of counts — the harnesses seed mt19937 with a
constant, so they do not drift with host or toolchain. The build instructions carry the
expected block; when a change legitimately moves a count, update it in the same
commit.

## What to do next

**M1 is complete and running on hardware.** The core boots, loads its ROM,
executes real Virtua Racing code and renders correctly on a DE10-Nano: zero
fetch deadline misses, 57.52 Hz measured from the core's own vsync, and the
picture pixel-identical to the reference. Two of the four items that used to be in this section are done — the top level
and MRA exist, and the tilemap fetch is pipelined.

**The controls work, and the attract sequence now advances.** The whole DPRAM map
is measured rather than guessed and the V60 polls all fourteen control bytes every
frame on hardware. The thing that stopped the picture was **the V60 faking `IN`
and `OUT`** — see `findings.md` — and with real I/O-space accesses tilemap 1 gains
its 648 category-1 tiles, matching the reference exactly. The remaining 2D
question is the unimplemented `ctrl & 0x6000` window mode, which is now reachable
for the first time.

Resource state after all of it, Quartus 17.0 on 5CSEBA6U23I7:

| | used | of | |
|---|---|---|---|
| ALM | 29,141 | 41,910 | 70% |
| M10K | 452 | 553 | **82%** |
| DSP | 50 | 112 | 45% |

Worst setup slack **+0.116 ns**, down from +0.401 before M2 — thin enough that
odd behaviour on this build should be read as a timing suspect before a logic
one, and the V60 owns that path.

**M10K is now the binding resource, not ALM.** 144 blocks remain and D3's band
buffer wants about 51 of them.

---

### 1. M2 — the TGP is in the design and running  (IN PROGRESS)

**`docs/m2-tgp-integration.md` is the interface spec**, read off MAME. What is
built, measured on the real core at **29,141 ALM (70%), 452/553 M10K (82%)**:

- `m1_copro_if` — the V60's four CPR registers and the 8192x32 copro RAM, shared
  with the TGP through an arbiter. 248 checks.
- `m1_tgp` — `mb86233_core` with its microcode ROM, the two data-space FIFOs, the
  IO decode and the TGP's own four RAM address registers.
- **The coprocessor executes real decapped microcode** (`315-5573.bin`, over the
  MRA's index 1) and `unimplemented` has never asserted — the first check on
  months of fuzzing from real code rather than generated instructions.
- `copro_data` (2 MB) and the math tables (256 KB) in SDRAM, reads verified
  **bit-exact against the reference**.
- FIFO depth 16 with stall-on-full, which is what the board does — flow control
  is by halting a CPU, not by a status register.

**What is left:**

1. **The four math units.** Table lookups into the 256 KB ROM in four 16K-word
   quadrants — sincos, atan, inv, isqrt — each an index computation plus an
   exponent fixup. Currently the table read returns the quadrant base rather than
   a computed index, so anything derived from them is wrong. They are pure
   functions of (operand, table) and fuzz cleanly the way the FP units did.
   **`atan` carries a deliberate table-bug correction** that MAME reproduces:
   reproduce it, do not tidy it.
2. **Polygon-list capture** off the output FIFO, diffed frame by frame against
   MAME. That is M2's exit criterion.
3. **Widen two saturating debug counters** — TGP retires and V60->TGP pushes both
   sit at 65,535, so they currently say only "a lot".
4. **The frame testbench needs an index-1 ioctl pass** for the microcode, or the
   TGP executes zeros there and the V60 stalls exactly as it used to.

### And it closes M0 exit criterion 2

`315-5573.bin` is real decapped microcode and the core now runs it, so lockstep
against the reference executing the same 8 KB is finally reachable.
`sim/tgp/mb86233_ref.cpp` has the whole-CPU reference; what it never had was real
code to run.

### 2. The I/O board — DONE, and how it was found

**Status, 2026-08-16: complete.** The control map is measured, wired and
verified on hardware — the V60 polls all fourteen control bytes every frame at
the reference's own cadence. What blocks playability now is the 2D defect above,
not the I/O board. `docs/io-board.md` carries the full trail.

#### The map, measured

Three static readings had each been plausible and each been wrong. Running the
real Z80 against the real ROM under MAME, with a Lua script logging every change
to the shared RAM and one control held at a time, settled it in minutes:

| DPRAM | Contents |
|---|---|
| `0x00` | steering, centre `0x80`, full `00`-`ff` |
| `0x01` | accelerator, released `0x01`, floored `0xff` |
| `0x02` | brake, same shape |
| `0x03`-`0x07` | set to `0xff` at startup, contents unknown |
| `0x08` | IN.0 — coin 1, coin 2, test, service, start, VR1-3 |
| `0x09` | IN.1 — VR4 at bit 0, shift down/up at bits 4/5 |
| `0x0a` | IN.2 — drive-board RX, unused here |
| `0x0b`-`0x0d` | DSW1-3 |
| `0x0e` | chip port 6 |
| `0x0f` | toggles on its own period — a board output, do not write it |

Every digital bit matches MAME's `INPUT_PORTS( vr )` and what `Model1.sv`
already wired, so the layout recovered from the Z80 disassembly was right; what
was missing was any way to know it. The analog channels are new information —
nothing before this said where the MSM6253 landed.

**Note the idle values are not uniform.** Digital bytes rest at `0xff` because
every control is active low, but a released pedal reads `0x01`. A blanket
`0xff` idle is both pedals floored.

#### What is built

- `m1_ioboard` sweeps `0x00`-`0x0e` — fifteen bytes, `SWEEP_BYTES` — at roughly
  the board's own rate, stopping short of the `0x0f` output byte.
- All fourteen controls come off `hps_io`, steering on the left stick with the
  d-pad at full lock, pedals on buttons, test and service also on OSD switches.
- Both driving-cabinet MRAs name the real panel in the RTL's bit order.
- `make test_ioboard`: 21 + 68 checks, covering that each byte lands at its own
  address, that the sweep wraps at `0x0e` rather than at the counter's natural
  16, and that the boot handshake still wins the shared write port.

#### What is owed

**A hardware test.** The input path is complete in simulation: with the identity
block pushed, the V60 leaves the setup exchange and polls `0x00`-`0x0e` every
frame, at the reference's own cadence. What has not happened yet is a button
press on the board changing something on screen.

After that, the open questions are small and named: `0x03`-`0x07` are published
as `0xff` because that is what the board sets them to and their contents are not
known, and the twenty-three undecoded bytes of the identity block are reproduced
because the V60 requires them rather than because they are understood.

#### The finding that unblocked it

This game does **not** read the low-DPRAM sweep during setup — and that led to
three sessions of wrong conclusions. Our V60 polled the flag at `0x20`,
block-read `0x100`, and never touched `0x08`, which read as "the inputs arrive
through a mailbox at `0x100`". It does not. The V60 was **stuck in the setup
exchange**, and every conclusion drawn from that trace was a conclusion about
the phase it was stuck in.

What was missing is a **128-byte identity block at DPRAM `0x100`-`0x17f`**. The
V60 block-reads all of it once, immediately after its first handshake is
answered, and will not go on to poll its controls until it has. Nothing writes
that window beforehand, so the board supplies it. `docs/io-board.md` has the
bytes and the hard-rule-2 reasoning for reproducing them.

#### Two lessons worth keeping

**The MRA and the RTL must be edited together.** They disagreed — the MRA named
joystick bit 4 `Start` while `Model1.sv` read it as Coin, and the generic
`names="Start,Coin,Service,Test,-,-"` covered four controls where the game has
twelve. That is invisible until someone presses a button, and then it presents
as a protocol fault.

**Read the emulator's own key bindings rather than assuming them.** A whole
measurement round was recorded as "these controls produce nothing" because Z and
X were guessed as the shifters; they are VR3 and VR4, and the shifters are C and
V. The presses had worked perfectly and the interpretation was wrong.

**An instrument that saturates silently is worse than none.** The boot trace's
watch-page tables held 32 addresses and filled without saying so, so "the V60
touches 32 DPRAM addresses and none is `0x08`" was a table limit reported as a
measurement — and it was used to reject the correct answer. They hold 256 now
and the same run reports 90. Anything that can fill must report that it did.

**A negative result is a result, and must be written down as one.** The row
mask was measured in use, correctly implemented, verified against MAME over
380,929 checks, and changed nothing on screen. Without that recorded, the next
session re-derives the same fix.

**A read tap is a different instrument from a memory watch.** Watching memory
change finds where values are *written*; it cannot find where they are *read*,
because a read leaves no trace. Both ends of this protocol are available as
oracles — MAME's Lua `install_read_tap` on one side, our own boot trace on the
other — and the question was settled in minutes once the right one was pointed
at it. Two setup notes that each cost a run: `-skip_gameinfo`, or the warning
screen blocks autoboot and the script silently never loads, and
`-autoboot_delay 0`, or the tap installs after the exchange it is meant to
capture.

#### This is per-game, but barely

The DPRAM addresses are board hardware and do not vary — same 315-5338A, same
`EPR-14869` in every cabinet. MAME carries six input maps across the ten Model 1
entries, and the system half of IN.0 (coin 1, coin 2, test, service, start) is
bit-identical in all of them. Only the game buttons move, IN.1 is fully
game-specific, and the analog count runs from two (`netmerc`) to five (`swa`).
That makes the per-game part a mux on the bit packing, selectable from the MRA,
rather than an RTL change per title — not worth building until there is a second
game, and the others need M2 and M3 first anyway.

Sound does **not** depend on any of this. MAME reaches the sound board through an
i8251 UART (`m1uart` -> `segam1audio`), not through the I/O board — see item 5.


### 3. Finish the rasterizer — the band buffer and binning

The fill path is done and measured: 2,113 ALM, 2 DSP, 0 M10K, 63.67 MHz, checked
against a C transcription of MAME's `fill_quad` over 152,025 quads and 31.6 M
spans with zero mismatches.

What is left is **the band buffer, the binning pass, writeback and scanout** —
which is where D3 actually gets tested and where the M10K goes. See
`docs/m3-rasterizer-spec.md` for the rules and the two unspent levers. Note the
read that preceded it found MAME performs the depth sort in the rasterizer
rather than receiving a sorted list, which is D3's premise; that is not a
measurement meeting D3's reversal condition, and the quad count per frame from
the M2 capture is what settles it.

### 4. Close the SDRAM interface properly

**This works but is unverified, and it is the one part of the design nothing has
ever constrained.** `SDRAM_CLK` is a fabric inversion of `clk_sys`; there is no
`create_generated_clock`, no `set_input_delay`, no `set_output_delay`. The
fitter is free to skew the clock pin against data and address, and it may do so
differently on every build.

The read capture phase that makes the board work — CL+2, selectable from the OSD
— was found **empirically, from observing every burst return one 16-bit word
late**. It was not derived from a timing analysis, and it is one cycle away from
the value the simulation model needs. That is a working core resting on a number
nobody has closed.

Do this before trusting the design on a second board or a different SDRAM
module. It is also the honest explanation for why the derivation in
`m1_sdram`'s header is correct term by term and still gives the wrong total.

### 5. M4 — sound, over the main board's uPD71051C serial port at 0xC40000

Entirely unbuilt, and worth recording how it attaches because it is not
obvious: the main board talks to the sound board through a **uPD71051C USART —
i8251-compatible — mapped at `0xC40000`**, not through the I/O board or a shared
latch. `model1.cpp:1014` maps it `umask16(0x00ff)`; `:1852` instantiates it; the
clock is `16_MHz_XTAL / 2 / 16`, i.e. 31.25 kHz x 16, the standard Sega/MIDI sound
data rate. MAME wires `m1uart`'s txd to `segam1audio`'s rxd and back, with
`rxrdy`/`txrdy` driving `sound_ready_w`. `m1_decode` already asserts `sel_uart`
for the `0xc4` page, so the decode side of this exists.

**Do not confuse this with the other two UARTs in the repo.** This one is arcade
hardware on the main board. `rtl/io/m1_uart_tx.sv` is a debug printf channel into
the HPS's `ttyS0`, instantiated nowhere and parked for hardware monitoring. The
DE10-Nano's physical UART header is a third thing. The one-line summaries in
`README.md` and `CLAUDE.md` used to say only "a UART", which read as though M4
needed the MiSTer's; both now name the chip and the address.

The sound board itself is a 68000, a YM3438 and two MultiPCMs, with its own ROM
regions (`M1AUDIO_CPU_REGION`, `M1AUDIO_MPCM1/2_REGION`). `tools/gen_mra.py`
already documents where they belong in the stream and deliberately omits them
while the blocks do not exist.

### 6. Understand the 103-cycle character fetch wait

Measured in the whole system, a character fetch waits an average of 103 cycles
(240 before the line-buffer work reduced the request rate). That is far more
than a round-robin turn between three active ports should cost, and it is not
understood.

It is **not** currently a problem — the engine keeps up with room to spare and
misses no deadlines — so this is an efficiency question, not a bug. It will
matter when the rasterizer joins the same controller. Find out where the time
goes before changing `m1_sdram`, which is verified at 80,009 checks.

## What is owed

Neither of these blocks the three tasks above, and neither is visible in a green
`make test`. Both are recorded here so they are not quietly lost.

**Microcode-driven lockstep for the TGP — M0 exit criterion 2, not met.** What
exists is `sim/tgp/mb86233_ref.cpp`, a whole-CPU `execute_run` reference running
in lockstep with the core over 8,000 retires of *generated* instructions across
every decoded ALU op. It has already caught two real core bugs. The criterion
asks for real microcode, and the suite line says so: `mb86233_core: checks=23
fails=0 lockstep_regs=8000 diverged=0 (microcode-driven lockstep still owed)`.

**Denormal and NaN-payload semantics.** The FP harnesses skip denormal inputs,
denormal results and NaN results, and the gap reaches the flags too — `fcpd`
against a negative NaN sets SGD in MAME and not in the RTL, because the units
emit a canonical quiet NaN. MAME evaluates with host C floats; silicon of this
era commonly flushes to zero. `README.md` states both questions in full.
Resolve against real microcode traces, not against the host, and do not widen
the harness coverage before that is settled.

## Budget

**Measured on the real core** (`make rbf`, Quartus 17.0, 5CSEBA6U23I7), not on
`m1_integrated` — earlier versions of this section quoted the measurement
vehicle, which excludes the whole MiSTer framework:

| | used | of | |
|---|---|---|---|
| ALM | 29,141 | 41,910 | 70% |
| M10K | 452 | 553 | **82%** |
| DSP | 50 | 112 | 45% |

Worst setup slack **+0.116 ns**, down from +0.401 before M2 — thin enough that
odd behaviour on this build should be read as a timing suspect before a logic
one, and the V60 owns that path.

**The V60 is 17,691 ALM — 67% of the entire design.** Everything written for
this project totals under 1,000; `ascal` takes 1,984 and the rest of the
framework about 1,600. That single fact decides where optimisation is worth any
effort, and it is the V60 or nothing.

Still to build, against **12,769 free ALM** and **101 free M10K**: the rasterizer
3,000-6,000 and sound ~7,000. The TGP is spent. That fits at the optimistic end
and does not at the pessimistic one, so the `S32_V60_NO_FP` lever below has
stopped being optional — and M10K is tighter than ALM, with the band buffer
wanting ~51 of the 101 left.

**Unspent lever, and its evidence is about the wrong game.** The V60's own
comment justifies it with "Golden Axe never executes the optional floating-point
groups" — a claim about Golden Axe, and the same shape as the "io space unused on
S32" comment that cost days on the IN/OUT path. Model 1 needs Model 1's evidence:
`dbg_fp_trap` under a build with the define, through attract and a race.

V60 without the FP group is **-2,984 ALM** on
the full core. An earlier -1,987 is recorded in `00-decisions.md` from a smaller
design; both are kept rather than one silently overwritten, and they get
reconciled when the lever is actually spent. `dbg_fp_trap` has never fired but
is **inert by construction in a build that has FP**, so that is not evidence
yet — `tb_m1_boot` prints a warning if an FP opcode executes, and a long run
under the define settles it off-hardware.

### M10K is the binding resource, and where it goes

| memory | M10K | note |
|---|---|---|
| tile RAM (`tram_c` + `tram_v`) | 128 | **held twice** |
| display lists (`dl0`, `dl1`) | 128 | consumer not built |
| colour translation (`cxlat`) | 48 | |
| palette (`pram_c` + `pram_v`) | 32 | **held twice** |
| video line buffers | 12 | 1,792 bits in a 10,240-bit block |
| `ascal` (framework) | 54 | not ours |
| loader, DPRAM | 7 | |

144 blocks free and D3's band buffer wants ~51, so M3 fits without any of the
below. These are the reserve, in order of value:

- **Deduplication is the biggest lever and it is ours.** Tile RAM and palette
  are each stored twice, a CPU-side copy and a video-side copy, because an M10K
  has two ports and we need one write plus two reads. That is **80 M10K of pure
  redundancy**. The video side reads at 16 MHz effective against an 80 MHz
  `clk_sys`, so there is 5:1 slack to interleave the CPU read behind an arbiter.
  No SDRAM bandwidth cost.
- **Display lists to SDRAM: 128 M10K.** Sequential streaming access, and the
  consumer does not exist yet, so there is no working code to break.
- **Line buffers to MLAB: 12 M10K for ~480 ALM.** They use 17% of each block.
  The only good MLAB candidate — MLAB is 32 words deep, so everything else is
  too deep to qualify.
- Tile RAM to SDRAM is the wrong candidate: read every scanline, on a bus that
  already has an unexplained 103-cycle character-fetch wait.

### Sound, sized from MAME rather than guessed

`model1.cpp`: 68000 with 768 KB of code, YM3438 at 8 MHz, **two MultiPCMs with
4 MB of samples each**, over an i8251 UART at 31.25 kHz.

- fx68k and Jotego's JT12 are both GPLv3, and every file here is
  `GPL-3.0-or-later`, so both are usable. That removes the two largest pieces.
- **The MultiPCM is the real unknown** — a 28-channel wavetable engine with
  envelopes, interpolation and panning, times two instances, and no open core I
  know of. MAME's device is BSD-3-Clause so it can drive per-channel fuzzing the
  way the TGP was verified.
- **Put the 8 MB of samples on DDR3, not SDRAM.** 56 channels each fetching from
  a different place is random access, not bursts; it would row-thrash a bus that
  already carries V60 fetch, CPU data and character fetch. `DDRAM_*` is
  available and `ascal` already uses it.

Worth spiking one MultiPCM channel through Quartus early — it converts the
~7,000 estimate into a number, and that number decides whether all four
milestones fit on this device.

## Open decisions

**tv80 vs HLE for the I/O board — deferred, not settled.** The evidence is that
nothing has needed a Z80 *yet*: the V60 reads only the status byte, never input
data. But attract mode and the service menu have not run, and that is where
controls, coin, service and DIP switches get read. Licensing is clear either
way — tv80 is MIT and Verilog (simulatable), T80 is BSD-3 but VHDL (Quartus
only), MAME's 315-5338A is BSD-3 and not yet in the sparse checkout. See
`THIRD-PARTY.md`.

**`NO_FP`.** `dbg_fp_trap` never asserted on either boot run — 7.8 M
instructions pre-handshake, and 5.3 M fetches of real game code after it — and
the ROMs of 2 of 8 sets show no excess of FP-shaped byte pairs. The
post-handshake run is the evidence that matters, since the earlier one was
largely `MOVC` sweeping memory. Good evidence, not conclusive: attract mode and
gameplay have not run. `make m1_main` runs a configuration with an FP opcode
injected, which must trap, so the detector is known live.

## Things that bite, learned the hard way

**Everything MiSTer-specific now lives in `docs/mister-integration.md`** — the
framework deadlocks, the PLL naming requirement, the block-RAM inference table,
how to make the screen an instrument, and how to test against a board. Written
framework-generic so it carries to the next core.

**Block RAM inference is silent when it fails.** Quartus builds memories out of
flip-flops and keeps going. Two separate incidents: the video line buffers cost
28,816 ALM before being fixed, and the main-board memories consumed 15 GB and
never finished synthesising. Quartus 17.0 does **not** infer RAM from
`mem[a][7:0] <= d[7:0]` byte-enables — use two byte-wide arrays with plain
write enables, and put an explicit `ramstyle` on anything that matters.
Simulation cannot see any of this; only `make quartus` can.

**Test the idiom small.** The RAM question was settled in 30 seconds by
synthesising both forms at 1024 entries, after hours of full-size builds
answered nothing.

**Acknowledges must be held, not pulsed.** Anything talking to a `ce`-gated
requester must hold `ack` until the request drops. A one-cycle pulse is missed
and the CPU waits forever. This bit twice — `m1_main`'s bus and the fetch
bridge — and both times looked like a dead CPU rather than a handshake fault.

**The boot trace is the best debugging tool here.** A histogram of bus accesses
by page, plus per-address counts and write data for one watched page, has found
five blockers in a row. The watched page is a make variable: `make m1_boot
WATCH_PAGE=0xC0`, defaulting to the I/O board. `BOOT_CYCLES` shortens the run.

**Watch the machine.** Quartus with un-inferrable RAM will eat all system
memory; `make quartus` now runs under a timeout. Do not use `ulimit -v` —
Quartus reserves far more virtual address space than it uses. Also: `/tmp` here
is a 16 GB tmpfs, so build artefacts must not go there.

**Quartus parses `// synthesis <word>` as a pragma** — do not start a comment
sentence with it.

**A file list outside `make test` rots silently.** `m1_boot` kept its own
verilator source list and lost `rtl/m1_mainram.sv` when the on-chip memories
were split out of `m1_main.sv`; `run_m1_main.sh` and `SRCS_m1_integrated` were
updated and it was not. Because it is not in `make test`, nine commits went by
green while the target would not elaborate — including the two that quote its
output. Anything with a hand-maintained
source list needs running after a file moves — or its list needs to stop being
hand-maintained.

## When something is unknown, run MAME. Do not reason about it.

The single most useful rule this project has. MAME is not only the correctness
oracle for finished work — it is the cheapest way to answer a question about the
hardware, it is available at every moment, and instrumenting it takes minutes.

Reasoning about what the hardware "must" do has been wrong five times, and in
every case the measurement was available the whole time:

| Question | Reasoning said | Measurement said |
|---|---|---|
| where do the inputs live | a mailbox at DPRAM `0x100` | `0x00`-`0x0e`, polled every frame |
| why is most of the 2D missing | the row mask, then the window mode | neither — the V60 never gets that far |
| does the V60 read the coprocessor back | it must, to collect results | **constantly — 710,722 FIFO reads per 600 frames, in the I/O space.** The "never" was a census of the program space, agreeing with our own faked `IN`. Corrected 2026-08-18. |
| what blocks the coprocessor | the math units returning zero | the **data ROM**, read before any math unit |
| how deep are the coprocessor FIFOs | 64 seemed like sensible slack | **16**, and full halts the CPU |

Three of those cost a session or more. The pattern is identical every time: a
plausible mechanism, reasoned from partial evidence, that a five-minute
instrument would have refuted.

### Which instrument answers which question

- **`install_read_tap` / `install_write_tap`** on a device's address space —
  what does it actually *touch*. A memory watch cannot answer this: **a read
  leaves no trace in memory**, and not knowing that cost a day.
- **A frame notifier polling a region** — what does it *contain*.
- **`manager.machine.video:snapshot()`** — a reference frame to diff against a
  photograph of the board.
- **Any CPU can be tapped, not just the main one.** Tapping `:tgp_copro`'s IO
  space is what named the data ROM as the coprocessor's first blocker, after the
  math units had been assumed.

Three setup details, each of which cost a run: **`-skip_gameinfo`** or the
warning screen blocks autoboot and the script silently never loads;
**`-autoboot_delay 0`** or the tap installs after the exchange it was meant to
capture; and **assign every notifier and tap to a global** or the subscription is
collected and the callback stops with no error. Run from a scratch directory —
MAME drops `cfg/`, `nvram/` and `snap/` wherever it starts.

### And measure before building

A Quartus build is 25 minutes and a hardware test needs someone watching a
screen. The boot trace and the board have been shown to reach the same state — the
same PC, `fed5a4` — so a question simulation can answer should never be sent to
hardware. Build when simulation says the thing being tested has changed.

## Method note

Every significant finding this session came from measuring rather than
reasoning, and several came after an assertion turned out to be wrong: the V60
CPI figure was stale, the budget did not justify what I claimed, the I/O board
did not need per-variant work, the handshake reply was not a signature. Where
an estimate has a wide spread, measure it — it has consistently been cheaper
than the argument about it.

---

# 2026-08-23 overnight: V60 speed and area, measured

## Speed: mean CPI 18.4 -> 14.9, and where the rest is

`make m1_boot BOOT_CYCLES=400000000` on the same 100 M CPU cycles throughout.

| change | mean CPI | note |
|---|---|---|
| start | 18.4 | |
| bus issues its first cycle a cycle earlier | 17.9 | `I_IDLE` latched, `I_CYC` issued |
| realign shift 4 -> 8 | 17.6 | **reverted**, see area |
| **instruction-cache hits answered combinationally** | **14.6** | the real win |
| shift reverted to 4 | **14.9** | 485 ALM back for 2% |

**19% faster.** Real time at 25 MHz needs 12.5, so about 16% still to find.

**Where it goes now**, from a state census counting CE cycles per FSM state:

    S_FILL            33%   never touches the data bus
      shifting 1.0/instr | dispatch 1.0/instr | STARVED-ALIGNED 3.3/instr
    S_DECODE..S_NEXT  28%   pure FSM stepping, all bus-free
    S_OP2_LD          20%   genuine memory wait
    S_WB_MEM/S_EA_VAL 12%   genuine memory wait

The remaining front-end starvation is most likely **branch refill** - a taken branch zeroes
the window and the core waits for a rebuild - which is inherent to a non-speculative front
end. A branch-target cache is the fix, not a gate tweak; one gate change was tried, changed
NOTHING to the digit, and was reverted.

The 28% in bus-free FSM stepping is what a pipelined or shared-datapath restructure removes,
and it is the one remaining item large enough to close the gap.

## Area: 485 ALM taken, and what every other knob is worth

The V60 is **17,445 ALM of the core's 29,611 - 59% of the whole design**, and 79% of
`m1_main`. Everything else in our core totals ~2,500; the framework (ascal, osd, audio) is
~6,500.

| knob | ALM | verdict |
|---|---|---|
| realign shift 8 vs 4 | +485 | **taken** - 1.7% speed was not worth it |
| loop cache | 167 | keep - removing it costs 4% speed |
| FP group | 1,942 | **cannot** - a reserved FP opcode executes at FED52B |
| Aggressive Area, V60 alone | 2,631 | does not transfer |
| Aggressive Area, full core | 595 | **do not** - costs 11 M10K and the slack |

**M10K is the binding resource, not ALM** - 452 of 553 with the rasterizer's band buffer
wanting ~51 - which is why the area-optimised build is the wrong trade at 84%.

## What is NOT the hog, so nobody re-derives it

- **The register file.** 105 `r[]` references but 52 are `r[31]` and nearly all the rest are
  constant indices; only four are variable, and constant reads are free.
- **Replicated adders** are real - 128 distinct `Add*` nodes - but the PC alone has 19
  increment sites with different deltas, so sharing them means restructuring the FSM.
- **`fb32`/`fb16` window muxes.** Four and two 24:1 byte muxes each, `fb32(ea_ofs+1)` at five
  call sites in different always blocks. Naming them as shared wires **broke
  `tb_v60_search`** and was reverted.

## The split, and why it is not done

It is the right next move for both goals and it is a multi-day job, not an overnight one:
4,644 lines, ~90 states, shared registers and tasks. The gate that makes it safe already
exists - `v60_trace` and `v60_resync` report **zero divergence sites** against MAME, plus 29
unit tests and `m1_main` - and that harness does not decay.

**Do it in stages, measuring each:** the prefetch/fetch-buffer unit first (self-contained,
biggest cycle consumer), then the EA engine (one datapath nearly every instruction uses),
then let the cold groups - `S_STR_*`, `S_BF_*`, `S_DEC_*`, `S_BS_*`, all under 5% of cycles -
share it rather than each carrying its own.

**Standalone numbers do not predict in-context ones.** The V60 measures 20,129 ALM alone and
17,445 in the design; Aggressive Area saves 13% alone and 2% in place. Use standalone figures
only to compare two versions of the same block.
