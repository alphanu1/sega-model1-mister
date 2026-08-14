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

- Program: 32-bit words, 16-bit word address space
- Data RAM banks: `0x000-0x0ff` and `0x200-0x3ff`
- Register file: separate 16-entry space
- Model 1 copro output FIFO sits at `0x400`, reached by the automatic +0x200 adder with
  `X1 = 0x200`. Accesses to `0x100-0x1ff` and `0x400+` route externally.

The +0x200 auto-add on one side of move/load addressing is not optional decoration; the
FIFO writes depend on it.

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

## Measured — first Quartus run, 2026-08-14

Quartus Prime Lite **24.1std**, not the 17.0.x this document specifies. See the
caveat below. Device 5CSEBA6U23I7, 50 MHz constraint, I/O paths cut, all ports
virtual-pinned.

| Module | ALMs | Registers | DSP | M10K | Fmax (worst slow corner) |
|---|---|---|---|---|---|
| `fp_mul` | 144 | 101 | **1** | 0 | 114.31 MHz |
| `fp_add` | 410 | 81 | 0 | 0 | 77.42 MHz |
| `fp_div` | 263 | 137 | 0 | 0 | 106.30 MHz |
| `mb86233_alu` | 1319 | 461 | **1** | 0 | 94.64 MHz |
| `mb86233_agu` | 176 | 0 | 0 | 0 | n/a, combinational |
| `mb86233_seq` | 175 | 106 | 0 | 0 | 244.20 MHz |
| `mb86233_regs` | 646 | 781 | 0 | 0 | 825.08 MHz |

`mb86233_alu` already contains one `fp_mul` and one `fp_add`, so a TGP instance
built from what exists today is **alu + agu + seq = 1670 ALM, 1 DSP, 0 M10K**,
and the binding Fmax is the ALU's 94.64 MHz.

**The DSP question is settled.** `fp_mul` infers exactly one DSP block, which is
what D4 rests on. It also drops from 1312 LUT6 under the yosys proxy to 144 ALM
under Quartus — better than the "roughly 300" this document predicted, because
the significand multiply leaves the fabric entirely.

Note `fp_add` standalone reports 77.42 MHz but the ALU containing it reports
94.64 MHz. Standalone numbers are pessimistic here: in isolation the module's
critical path terminates at virtual pins with nothing to retime against.
**The instance-level number is the one the gate should read.**

Against the gate below, per instance:

| Metric | Measured | Threshold | Verdict |
|---|---|---|---|
| ALM | 1670 | < 4K | pass |
| DSP | 1 | 1-2 | pass |
| M10K | 0 | < 6 | pass |
| Fmax | 94.64 MHz | > 80 MHz | pass |

Three instances extrapolate to ~5.0K ALM and 3 DSP, against a budget of 15K ALM
and 8 DSP. D4 holds comfortably.

**This is not the gate closed.** What is missing:

- No top level. The register file, program store, both data RAM banks and the
  external bus are not built, which is why M10K reads 0 — the memories that will
  consume it do not exist yet.
- `fp_div` is written and verified but not yet instantiated in the ALU, so its
  263 ALM are not inside the 1319. A TGP instance including it is ~1930 ALM,
  still comfortably inside the 4K threshold.
- **Quartus 24.1std, not 17.0.x.** MiSTer cores build against 17.0.x, and its
  fitter and DSP inference differ. These numbers are a strong signal, not the
  sign-off. Re-measure on 17.0.x before treating the gate as closed.

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
