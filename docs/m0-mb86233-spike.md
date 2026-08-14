# M0 — MB86233 spike

The gate. Nothing else gets built until this closes.

Ground truth for everything below is MAME `src/devices/cpu/mb86233/mb86233.cpp`
(Olivier Galibert) plus the decapped microcode ROMs. Where this document and that
source disagree, the source wins.

---

## Scope

**In:**

- Floating point ALU, IEEE-754 single precision
- Integer/logical ALU ops (they share the register file and status flags)
- Shift ops
- Register file, address generation, both RAM banks
- Sequencer: branches, 4-deep hardware PC stack, `ldi`, `lipl`/`lia`/`lib`/`lid`
- External bus port and the Model 1 copro output FIFO at 0x400

**Out, deliberately:**

- **Fixed point mode.** MAME's note is explicit that Sega programs enable FP at startup
  and never leave it, and MAME does not implement fixed point. Do not build it.
- **Interrupts.** MAME does not implement them. The copro programs never even initialise
  the stack pointer. Revisit only if a game needs the rf0 status update path.
- MB86234 differences. Model 2 problem, not ours.

---

## Register model

Float/accumulator: `A`, `B`, `D`, `P`
Integer/index: `R`, `C0`, `C1`, `B0`, `B1`, `X0`, `X1`, `I0`, `I1`
Control: `SFT`, `VSM`, `MASK`, `M`, `SP`, `PCS0..PCS3`

`A`, `B`, `D`, `P` are addressable three ways: whole word, exponent field only, or
mantissa field only. The field accessors are non-obvious and must be copied exactly:

```
set_exp(v,e)  = (v & 0x807fffff) | ((e & 0xff) << 23)
set_mant(v,m) = (v & 0x07f800000) | ((m & 0x00800000) << 8) | (m & 0x007fffff)
get_exp(v)    = (v >> 23) & 0xff
get_mant(v)   = (v & 0x80000000) ? (v | 0x7f800000) : (v & 0x807fffff)
```

Note `get_mant` sign-extends through the exponent field where `set_mant` does not.
**That asymmetry is real** and is worth the comment it carries: removing the
sign-extension produces 93,765 mismatches in the `mb86233_regs` fuzz run.

**Corrected 2026-08-14.** This section previously warned that `set_mant`'s mask
"has a stray extra digit in MAME's source and evaluates as written — replicate
the arithmetic result, not the apparent intent." That is wrong, and the warning
was misleading. `0x07f800000` has nine hex digits, but the extra one is a
*leading zero*: it equals `0x7f800000` exactly, which is also the obvious intent.
Substituting one for the other produces zero mismatches across 3,000,000 cases.
There is no hazard here and nothing to replicate carefully. The literal is kept
verbatim only so the transcription matches the source line for line.

---

## ALU op table

Opcode is the ALU field of the instruction word. `f2u`/`u2f` are bit reinterpretations.

| Op | Name | Result |
|----|------|--------|
| 0x01 | `andd` | `D & A`, integer |
| 0x02 | `orad` | `D \| A`, integer |
| 0x03 | `eord` | `D ^ A`, integer |
| 0x04 | `notd` | `~D`, integer |
| 0x05 | `fcpd` | `D - A`, flags only, no writeback |
| 0x06 | `fadd` | `D = D + A` |
| 0x07 | `fsbd` | `D = D - A` |
| 0x08 | `fml`  | `P = A * B` |
| 0x09 | `fmsd` | `D = D + P` **and** `P = A * B` |
| 0x0a | `fmrd` | `D = D - P` **and** `P = A * B` |
| 0x0b | `fabd` | `D = D & 0x7fffffff` |
| 0x0c | `fsmd` | `D = D + P` |
| 0x0d | `fspd` | `D = P` **and** `P = A * B` |
| 0x0e | `cxfd` | `D = float(int32(D))` |
| 0x0f | `cfxd` | `D = int32(D)`, rounding per `M[2:1]` |
| 0x10 | `fdvd` | `D = D / A` |
| 0x11 | `fned` | `D = D ^ 0x80000000`, zero stays zero |
| 0x13 | — | `D = B + A` |
| 0x14 | — | `D = B - A` |
| 0x16 | `lsrd` | `D >> SFT`, logical |
| 0x17 | `lsld` | `D << SFT`, logical |
| 0x18 | `asrd` | `D >> SFT`, arithmetic |
| 0x19 | `asld` | `D << SFT`, arithmetic |
| 0x1a | `addd` | `D + A`, integer |
| 0x1b | `subd` | `D - A`, integer |

`0x12` and `0x15` do not decode. Neither do `0x1c`-`0x1f`: they fall through
`alu_pre`'s default and log `unhandled alu pre`.

**Corrected 2026-08-14.** This table previously listed the shift and integer ops
two slots high, `lsrd` at 0x18 through `subd` at 0x1d. Both MAME sources agree on
0x16-0x1b: `mb86233.cpp` `alu_pre` cases 0x16-0x1b, and `mb86233d.cpp` lines
243-248 disassemble the same numbering. Per hard rule 3, MAME wins.

`cfxd` rounding modes from `M[2:1]`: 0 = `roundf`, 1 = `ceilf`, 2 = `floorf`,
3 = C cast (truncate toward zero). Mode 0 is round-half-**away-from-zero**, which
is what C's `roundf` does — *not* the round-half-to-even that "round to nearest"
usually implies, and not what the FP units use internally for their own rounding.

`SFT` is a `u8` in MAME and the shift ops evaluate `m_d >> m_sft` directly, so
counts above 31 are undefined behaviour in C++. On x86 the shift count masks to
5 bits, which is what MAME exhibits in practice and what the RTL models. Real
silicon is unverified above 31; the fuzz harness constrains `SFT` to 0-31 rather
than compare against undefined behaviour.

`cxfd` and `cfxd` dispatch from `alu_post_1`, the *integer* post path, even
though `cxfd` produces a float. They take no extra cycle and lose write-priority
against a concurrent transfer. That asymmetry is real; do not move them.

**The datapath falls straight out of 0x09/0x0a/0x0d.** One FP multiplier feeding `P`
and one FP adder feeding `D`, both live in the same cycle. That is the entire structure.
Build those two units, wire the operand mux in front of them, and the FP half is done.

---

## Timing

- `execute_clocks_to_cycles` = `(clocks + 2) / 3`. Three part clocks per instruction cycle.
- FP post-ops burn one additional cycle (`m_icount--` in `alu_post_2`).
- Write-priority quirk, from MAME's own comment: with two writes to one register in a
  single instruction, transfers beat integer ops, but FP ops beat transfers. Attributed
  to the FP ALU taking more than one cycle. **Model this explicitly.** It is exactly the
  class of detail that produces geometry drift a thousand frames in.

At 16 MHz that is ~5.3 M instructions/sec. A multi-cycle FSM at 50 MHz has enormous
headroom. Do not pipeline aggressively; correctness and area matter, speed does not.

---

## Memory map

From `copro_data_map` in `third_party/mame/src/mame/sega/model1_m.cpp`:

| Range | Contents |
|---|---|
| `0x0000-0x00ff` | RAM bank 0, 256 words |
| `0x0100` | `copro_fifo_in`, **read only**, a single address |
| `0x0200-0x03ff` | RAM bank 1, 512 words |
| `0x0400` | `copro_fifo_out`, **write only**, a single address |

Program space is `0x000-0x7ff` ROM — 2048 words of microcode. The register file
space maps only `0x0` (leds, write-ignored) on Model 1.

**Corrected 2026-08-14.** This section previously said "accesses to `0x100-0x1ff`
and `0x400+` route externally", implying two external windows of 256 and 64K
words. There is exactly **one address at each end, one direction each**. A write
to `0x0100` and a read from `0x0400` hit no handler at all. Decoding `0x0100` as
a 256-word window produces 63,534 mismatches in the `mb86233_mem` fuzz run;
dropping the direction gate on `0x0400` produces 267.

The +0x200 auto-add on one side of move/load addressing is not optional
decoration; the FIFO writes depend on it. It works precisely because `0x400` is a
single decoded address — `x1 = 0x200` plus the adder lands on it exactly.

There is also an **IO space** (`copro_io_map`) that the `lab mem, mem (e)` form
reads, and it is not memory: it holds the Model 1 board's hardware math
accelerators — `sincos`, `atan`, `inv`, `isqrt` — plus a windowed view of the
copro RAM. Those belong to the copro glue rather than the TGP, but the core needs
the port, and M2 needs the functions.

---

## Deliverables

```
rtl/tgp/mb86233_pkg.sv      opcode/register/flag constants
rtl/tgp/fp_mul.sv           IEEE-754 single multiplier
rtl/tgp/fp_add.sv           IEEE-754 single adder/subtractor
rtl/tgp/fp_div.sv           IEEE-754 single divider (fdvd only)
rtl/tgp/mb86233_alu.sv      ALU op decode + P/D writeback + status flags
rtl/tgp/mb86233_agu.sv      address generation, both EA modes, +0x200 adder
rtl/tgp/mb86233_seq.sv      sequencer, PC stack, branch/call/return
rtl/tgp/mb86233_regs.sv     register file, 0x00-0x3f space
rtl/tgp/mb86233_mem.sv      data-space RAM banks and decode
rtl/tgp/mb86233_dec.sv      instruction decoder
rtl/tgp/mb86233_xfer.sv     ld/mov source and destination routing
rtl/tgp/mb86233_core.sv     top level
sim/tgp/tb_mb86233.cpp      Verilator harness
sim/tgp/oracle/             MAME lockstep bridge
```

---

## Exit criteria

1. Per-opcode fuzz: 10^6 random operand pairs per ALU op, bit-exact against MAME
   including all status flags. FP ops must match on NaN, inf, zero-sign and denormal
   inputs, not just normals.
2. Full-trace lockstep across a Virtua Racing cold boot into attract, running the real
   315-5571 geometrizer microcode. Every architectural register compared every
   instruction. Zero divergence.
3. Standalone Quartus synthesis against `5CSEBA6U23I7` with a 50 MHz constraint.

## Measured — Quartus, 2026-08-14

Device 5CSEBA6U23I7, 50 MHz constraint, I/O paths cut, all ports virtual-pinned.
Built on **both** toolchains: 17.0.0 Lite (what MiSTer's `sys/` requires from M1
onwards) and 24.1std Lite.

| Module | ALM 17.0 | ALM 24.1 | Fmax 17.0 | Fmax 24.1 | DSP | M10K |
|---|---|---|---|---|---|---|
| `fp_mul` | 144 | 144 | 116.85 | 114.31 | **1** | 0 |
| `fp_add` | 411 | 410 | 76.35 | 77.42 | 0 | 0 |
| `fp_div` | 263 | 263 | 113.96 | 106.30 | 0 | 0 |
| `mb86233_alu` | 1318 | 1319 | 91.99 | 94.64 | **1** | 0 |
| `mb86233_agu` | 176 | 176 | comb | comb | 0 | 0 |
| `mb86233_seq` | 174 | 175 | 231.64 | 244.20 | 0 | 0 |
| `mb86233_regs` | 644 | 646 | 827.81 | 825.08 | 0 | 0 |
| `mb86233_mem` | 123 | — | n/a | — | 0 | **3** |
| `mb86233_dec` | 121 | — | comb | — | 0 | 0 |
| `mb86233_xfer` | 28 | — | comb | — | 0 | 0 |
| **`mb86233_core`** | **2153** | — | **51.65** | — | **1** | **3** |

### The assembled core misses the Fmax gate

`mb86233_core` is the whole TGP: all eleven blocks, both RAM banks, the
divider. Against the gate:

| Metric | Measured | Pass | Verdict |
|---|---|---|---|
| ALM | 2153 | < 4K | pass, with margin |
| DSP | 1 | 1-2 | pass |
| M10K | 3 | < 6 | pass |
| **Fmax** | **51.65 MHz** | **> 80 MHz** | **FAIL** — below the 60 MHz floor |

It still meets the flat 50 MHz constraint in `quartus/spike.sdc`, and the part
runs at 16 MHz retiring ~5.3 M instructions/sec, so this is not a functional
problem. But the gate asks for 80 MHz and this is 51.65, which lands under the
60 MHz "fail" line rather than in the investigate band.

Note no individual block is near this: the ALU alone is 96.26 MHz and everything
else is faster. The critical path is created by assembly — decode feeding
`mb86233_xfer`, feeding the AGU, feeding the memory address, all combinational
inside one FSM state.

That is cheap to fix and the fix costs a cycle, which this design has in
abundance: register the decoded control or the effective address and add a state.
Deliberately not done yet, because doing it before the lockstep bridge exists
would mean re-verifying a pipeline change with no reference to check it against.

**The two toolchains agree.** Every module is within 2 ALM and a few percent of
Fmax. The version caveat that hedged the earlier 24.1-only numbers is resolved:
whichever is used, the answer is the same.

A TGP instance from what exists today — `alu + agu + seq + regs + div`, where
the ALU already contains one `fp_mul` and one `fp_add` — is:

| Metric | 17.0 | 24.1 | Threshold | Verdict |
|---|---|---|---|---|
| ALM | 2575 | 2579 | < 4K | pass |
| DSP | 1 | 1 | 1-2 | pass |
| M10K | 0 | 0 | < 6 | pass |
| Fmax | 91.99 MHz | 94.64 MHz | > 80 MHz | pass |

Three instances extrapolate to ~7.7K ALM and 3 DSP against a 15K / 8 budget.

**The DSP question is settled.** `fp_mul` infers exactly one DSP block on both
toolchains, which is what D4 rests on, and drops from 1312 LUT6 under the yosys
proxy to 144 ALM because the 24x24 significand multiply leaves the fabric.

Standalone Fmax is pessimistic: `fp_add` alone reads 76-77 MHz while the ALU
containing it reads 92-95 MHz. In isolation the critical path terminates at
virtual pins with nothing to retime against. **The instance-level number is what
the gate should read.**

**Still not the gate closed.** There is no top level, so the program store and
both RAM banks are absent — which is why M10K reads 0, not because the memories
are free. `fp_div` is verified but not yet instantiated in the ALU, so its 263
ALM sit outside the 1318.

### Installing 17.0 alongside a newer Quartus

`tools/install-quartus17.sh`, and the procedure is not obvious:

- `setup.sh` marks the install as **Lite Edition**. Running
  `QuartusLiteSetup.run` directly installs the binaries but leaves it as
  "SJ Standard Edition", and every build then fails with
  `Error (292025): License file is not specified.`
- `setup.sh` then **stalls before installing the device families** — it stops
  writing files and sits in `futex_wait`. With the default UI it blocks on a GUI
  progress dialog, because the base installer forces `--unattendedmodeui minimal`
  on its children whatever it was given; with `--unattendedmodeui none` it still
  stalls, just silently.
- So the device families are installed by hand. Each `.qdz` is a plain zip
  already rooted at `quartus/common/devinfo/<family>/`, so extracting it into the
  install directory puts everything exactly where the installer would have.
  `quartus_sh --qinstall` is not an alternative: it takes `-qda` and rejects
  `.qdz` as a different format.

## Resource gate

| Metric | Pass | Investigate | Fail |
|--------|------|-------------|------|
| ALM per instance | < 4K | 4-6K | > 6K |
| DSP blocks | 1-2 | 3-4 | > 4 |
| M10K (excl. program store) | < 6 | 6-10 | > 10 |
| Fmax | > 80 MHz | 60-80 MHz | < 60 MHz |

Three instances must total under 15K ALM and 8 DSP blocks. Above that, fall back to a
single context-multiplexed datapath at 4x clock — the 3-clocks-per-instruction ratio
makes that viable, it is just uglier.

**Kill criteria:** neither arrangement fits under 18K ALM. Stop, write up the negative
result, and the honest conclusion is that Model 1 does not belong on Cyclone V.

## Order of work

1. `fp_mul`, `fp_add` standalone against a software IEEE reference. Fuzz first.
2. `mb86233_pkg` + `mb86233_alu`. Fuzz every opcode in the table above.
3. AGU, including both EA modes and the +0x200 behaviour.
4. Sequencer and top level. Then full-trace lockstep.
5. Synthesis. Report numbers before touching M1.

Two to three weeks. If step 1 takes longer than four days something is wrong with the
harness, not the RTL.
