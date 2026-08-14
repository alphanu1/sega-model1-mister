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
fp_mul: checked=1885699 skipped=114301 fails=0
fp_add: checked=1968564 skipped=31436 fails=0
```

If either reports a nonzero `fails`, stop and fix that before starting new work.

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

**The Quartus path has never been executed.** It was written from the flow, not run.
Expect to fix a path or a report-parsing regex on first use; the greps in
`quartus/report.sh` are Quartus-version-sensitive.

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

`rtl/tgp/mb86233_alu.sv`.

The opcode table is already transcribed into `rtl/tgp/mb86233_pkg.sv` with the semantics
in `docs/m0-mb86233-spike.md`. `fp_mul` and `fp_add` are done and verified. What remains:

1. Operand mux feeding the two FP units. The structure falls out of ops `0x09`/`0x0a`/
   `0x0d`: `A*B -> P` runs concurrently with `D +/- P -> D`. One multiplier, one adder,
   both live in the same cycle.
2. Integer/logical/shift ops (`0x01`-`0x04`, `0x16`-`0x1b`).
3. `cxfd` / `cfxd` int-float conversion, with `cfxd` honouring the four rounding modes in
   `M[2:1]`: 0 nearest, 1 ceil, 2 floor, 3 truncate.
4. Status flag generation. Flag bit positions are in the package; the masks per op are in
   `mb86233.cpp` `alu_pre`.
5. Write-priority arbitration between the ALU result and a concurrent transfer.
6. A fuzz testbench covering every opcode in the table.

`fp_div` (op `0x10`, `fdvd`) is still unwritten. It is one opcode and can lag the rest.

After that: AGU (`mb86233_agu.sv`), sequencer (`mb86233_seq.sv`), top level, then the
Quartus gate. `docs/m0-mb86233-spike.md` has the ordering and the pass/fail thresholds.

---

## Style

See `docs/rtl-conventions.md`. Short version: SystemVerilog, `always_ff`/`always_comb`,
no loop-with-break (yosys rejects it), explicit widths, comment *why* not *what*, and
keep the lint clean at `-Wall`.
