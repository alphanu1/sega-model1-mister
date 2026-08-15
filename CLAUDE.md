# CLAUDE.md

Instructions for agentic work on this repository. Read this before touching anything.

---

## What this is

An FPGA implementation of the Sega Model 1 arcade board targeting MiSTer
(Terasic DE10-Nano, Cyclone V 5CSEBA6U23I7). Not an emulator. RTL that behaves as the
original silicon did, verified against MAME as an oracle.

Current milestone is **M0**: prove the MB86233 TGP fits before building anything else.
`README.md` has live status. `docs/00-decisions.md` records every architectural decision
and what would reverse it.

---

## Run this first

```
chmod +x tools/bootstrap.sh quartus/report.sh   # zip transport drops exec bits
./tools/bootstrap.sh
```

`third_party/` is **not in the repository**. It is gitignored and populated by that
script. Without it there is no MAME reference source, no V60, no `sys/` framework, and
most of what the docs point at will not exist on disk.

Verify the toolchain afterwards:

```
make lint && make test
```

Expected output, exactly:

```
bw_monitor[cw=24,bw=8]: checked=2000000 skipped=0 fails=0 uncovered=0 snaps=3867 wraps=0 sat=0
bw_monitor[cw=12,bw=4]: checked=2000000 skipped=0 fails=0 uncovered=0 snaps=3867 wraps=122 sat=534462
fp_mul: checked=1885699 skipped=114301 fails=0
fp_add: checked=1968564 skipped=31436 fails=0
fp_div: checked=282606 skipped=17394 fails=0 max_latency=29
mb86233_alu: checked=2170388 skipped=69612 fails=0 uncovered_ops=0
mb86233_agu: checked=3000000 skipped=0 fails=0 uncovered_modes=0
mb86233_seq: checked=3000000 skipped=0 fails=0 uncovered=0
mb86233_regs: checked=3000000 skipped=0 fails=0 uncovered_regs=0
mb86233_mem: checked=178399 skipped=0 fails=0 uncovered=0
mb86233_dec: checked=3000000 skipped=0 fails=0 uncovered=0
mb86233_xfer: checked=256 skipped=0 fails=0 (exhaustive)
mb86233_core: checks=23 fails=0 lockstep_regs=8000 diverged=0 (microcode-driven lockstep still owed)
```

`bw_monitor` is built twice on purpose. At the real counter widths a 500 k-cycle
run cannot wrap a 24-bit counter or saturate an 8-bit burst counter, so the
narrow `-GCW=12 -GBW=4` build is the only thing that reaches those paths.

If any reports a nonzero `fails`, or a nonzero `uncovered_*`, stop and fix that
before starting new work. The counts are reproducible: the harnesses seed
mt19937 with a fixed constant, so they do not drift with toolchain or host.

---

## Hard rules

These are not style preferences. Violating them creates legal or correctness problems
that are expensive to unwind.

1. **Never copy code from `third_party/geometrizer/`.** It has no licence file, so all
   rights are reserved. It may be run as an external oracle and read for understanding.
   Copying or adapting it — including its test harness — is not permitted. Use MAME's
   BSD-3-Clause device model as the source instead.

2. **Never commit ROM images**, or anything derived from them, including extracted
   microcode arrays baked into source files. Load microcode at runtime via the MRA path.

3. **MAME is the oracle, not a suggestion.** When this repo's documentation and
   `third_party/mame/src/devices/cpu/mb86233/mb86233.cpp` disagree, MAME wins and the
   documentation gets corrected in the same change.

4. **Do not "fix" a hardware quirk into something cleaner.** The write-priority rule
   (transfers beat integer ops, FP ops beat transfers), the asymmetry between `get_mant`
   and `set_mant`, the automatic +0x200 EA adder — these are real behaviours that
   software depends on. Reproduce them, comment why, move on.

5. **Every new RTL module ships with a fuzz or directed testbench in the same change.**
   Untested RTL does not get merged, and "I'll add tests after" has already been tried by
   everyone who has failed at this.

6. **Do not touch `docs/00-decisions.md` to make an implementation easier.** If a
   decision genuinely needs reversing, the entry states its reversal condition. Cite the
   measurement that met it.

---

## Verification model

Correctness here is not "it looks right on screen". It is bit-exact agreement with a
reference, checked in volume.

- **ALU / CPU work**: per-opcode fuzzing, millions of cases, comparing every
  architecturally visible register and status flag against MAME.
- **Geometry**: polygon list stream captured from the output FIFO, diffed frame by frame
  against MAME's.
- **Video**: frame image diffs against MAME on a fixed input script.

The existing harnesses in `sim/tgp/` show the pattern: drive the DUT, track a pipeline of
in-flight operands, compare on `out_valid`, print the first 20 mismatches with both the
raw hex and the decoded value. Copy that shape.

Note the harnesses deliberately **skip** denormal inputs and denormal results. That is an
unresolved question, documented in `README.md` and `docs/m0-mb86233-spike.md`, not an
oversight. Do not silently widen the coverage without resolving the underlying question
about real silicon behaviour.

---

## Build paths

Three, deliberately separate:

| Command | Needs | Purpose |
|---|---|---|
| `make lint` / `make test` | verilator | correctness |
| `make area` | yosys | relative area tracking between edits |
| `make quartus MOD=<module>` | Quartus 17.0.x Lite | real ALM/DSP/Fmax, settles the M0 gate |

`make area` uses generic 6-LUT mapping with no DSP inference and no device model. It is
useful for spotting a regression between two edits. It does **not** settle the resource
gate — only Quartus does.

The full core `.rbf` build does not exist yet. There is no top level until M1.

**The Quartus path runs, on both toolchains.** 17.0.0 Lite and 24.1std are
installed side by side; `make quartus_list` shows them, `QUARTUS=17.0` selects
one, and every report prints the version that produced it. Numbers agree within
2 ALM — see `docs/m0-mb86233-spike.md`.

Installing 17.0 is not obvious and `tools/install-quartus17.sh` encodes it:
`setup.sh` is what marks the install Lite Edition (running
`QuartusLiteSetup.run` directly leaves it as Standard, which then fails every
build with `Error (292025): License file is not specified`), but `setup.sh`
stalls before installing the device families, so those are extracted from their
`.qdz` archives by hand — each is a plain zip already rooted at
`quartus/common/devinfo/`.

Four report-parsing faults were found on first use and are fixed: a placeholder
token substituted inside a comment; an Fmax section name matched as `85C` when
an industrial part reports `100C`/`-40C`; metrics printed two or three times;
and a combinational module's absent Fmax table reading as a parse failure.

**When testing a Quartus change, re-run `quartus_map`, not just `quartus_fit`.**
A fit-only rerun reuses the previous synthesis netlist and will happily report
success for a setting that actually breaks the build.

---

## Where to find ground truth

After bootstrap:

| Question | File |
|---|---|
| What does the TGP do? | `third_party/mame/src/devices/cpu/mb86233/mb86233.cpp` |
| How is a TGP instruction encoded? | `third_party/mame/src/devices/cpu/mb86233/mb86233d.cpp` (disassembler) |
| What chips are on the board, at what clocks? | `third_party/mame/src/mame/sega/model1.cpp` header comment |
| How does the video hardware work? | `third_party/mame/src/mame/sega/model1_v.cpp` |
| V60 CPU implementation | `third_party/s32/rtl/cpu/v60/s32_v60.sv` |
| V60 test suite and its baseline | `third_party/s32/verif/v60/BASELINE.md` |
| MiSTer framework, HPS I/O, scaler | `third_party/template/sys/` |

The MB86233 instruction encoding is **only** documented in the disassembler. There is no
datasheet with opcode encodings in English. Read `mb86233d.cpp` alongside
`mb86233.cpp`; the former gives field layout, the latter gives semantics.

---

## Immediate next task

`rtl/tgp/mb86233_core.sv`, the top level. Everything it ties together exists and
is verified: `mb86233_alu`, `mb86233_agu`, `mb86233_seq`, `mb86233_regs`,
`fp_mul`, `fp_add`, `fp_div`.

What the core has to add:

1. Instruction fetch from program memory (32-bit words, 16-bit word address
   space) and decode of the six instruction types: `lab` (0x00), `ld`/`mov`
   (0x07), `stm`/`clm` (0x0d), `lipl`/`lia`/`lib`/`lid` (0x0e),
   `rep`/`clr0`/`clr1`/`set` (0x0f), `ldi` (0x10-0x1f), and branches
   (0x2f/0x3f). `execute_run` in `mb86233.cpp` is the whole dispatch.
2. Both data RAM banks, `0x000-0x0ff` and `0x200-0x3ff`.
3. The external bus port, and the Model 1 copro output FIFO at `0x400`.
4. **A stall path.** External reads stall (`m_stall` / `goto do_stall` in MAME),
   and `fdvd` needs one too — `fp_div` is a 29-cycle iterative block with a busy
   handshake, while `mb86233_alu` is uniform-latency-2. That mismatch is why
   `fp_div` is verified but not yet instantiated, and it is the core's problem
   to solve rather than something to bolt onto the ALU.

Then the MAME lockstep bridge, which is M0 exit criterion 2 and the only part of
the verification model not yet built.

Note `mb86233_seq` owns `c0`/`c1` and the ZC flags while `mb86233_regs` forwards
writes to them as strobes; `x0`/`x1` live in the register file but the AGU's
post-increment wins; `d`/`p` live there but the ALU's writeback wins. The core
wires those, it does not re-arbitrate them.

---

## Style

See `docs/rtl-conventions.md`. Short version: SystemVerilog, `always_ff`/`always_comb`,
no loop-with-break (yosys rejects it), explicit widths, comment *why* not *what*, and
keep the lint clean at `-Wall`.
