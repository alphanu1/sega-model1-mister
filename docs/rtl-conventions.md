# RTL conventions

Rules that exist because breaking them cost time already, not because they are tidy.

---

## Language

SystemVerilog. `.sv` extension. `always_ff` and `always_comb`, never bare `always`.

Target toolchains are **verilator**, **yosys** and **Quartus 17.0.x Lite**. Code must
pass all three. Quartus 17.0.2 predates a lot of SystemVerilog-2017, so the usable
subset is narrower than verilator alone would suggest.

---

## Things that pass verilator and fail elsewhere

**No `break` inside a synthesis loop.** Yosys rejects it outright:
`ERROR: Can't resolve task name '\break'`. Write the priority encoder as an
unconditional loop that overwrites, lowest priority first:

```systemverilog
// Works everywhere.
always_comb begin
  lzc = 5'd27;
  for (int i = 0; i < 27; i++)
    if (s1_sum[i]) lzc = 5'(27 - i);
end
```

**Explicit widths on every literal in arithmetic.** `11'sd127`, not `127`. Quartus and
verilator disagree about implicit extension in signed contexts often enough that it is
not worth finding out which one is right this time.

**Cast loop-derived values explicitly.** `5'(27 - i)`, not `27 - i`.

---

## Structure

One module per file, filename matching module name.

Pipeline stages get an explicit prefix: `s1_`, `s2_`. A signal without a stage prefix is
combinational within the current stage. This is not decoration — the two real bugs found
in `fp_add` were both stage confusion, one of them reading a stage-1 combinational signal
from stage-2 logic.

Reset is `rst_n`, active low, asynchronous:

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    ...
  end else begin
    ...
  end
end
```

Handshake is `in_valid` / `out_valid`. No ready-side backpressure unless a block genuinely
needs it. The TGP retires roughly 5.3 M instructions/sec against a 50 MHz fabric clock, so
throughput is never the constraint; do not add flow control to solve a problem that does
not exist.

---

## Parameters

Behaviour that is genuinely unknown about the real hardware gets a parameter, not a
guess buried in the logic. `FLUSH_DENORM_IN` in the FP units is the model: both
behaviours are reachable, the default matches the current oracle, and the open question
is documented in the file header and in `docs/m0-mb86233-spike.md`.

Default to whatever MAME does. Deviate only with a trace from real hardware.

---

## Comments

Comment the *why*. The *what* is already in the code.

Bad:
```systemverilog
// shift right by one
shifted = s1_sum >> 1;
```

Good:
```systemverilog
// Carry out of the significand: shift right one, exponent up one.
shifted  = s1_sum >> 1;
lost_bit = s1_sum[0];
```

Any place where the hardware does something that looks like a bug, say so explicitly and
name the source:

```systemverilog
// Copied verbatim from MAME. get_mant sign-extends through the exponent
// field; that asymmetry against set_mant is real, not a transcription error.
```

Every file gets an SPDX header. Files transcribing anything from MAME additionally carry
the BSD-3-Clause attribution to Olivier Galibert. See `THIRD_PARTY.md`.

---

## Testbenches

C++ under Verilator, in `sim/<block>/tb_<module>.cpp`.

Shape, per the existing two:

1. Reference is computed in C, not reimplemented in the testbench's own logic.
2. Interesting operands seeded ahead of the random stream — zeroes, signed zeroes, ones,
   infinities, NaNs, smallest normal, largest denormal, largest finite. Cross-product
   them before going random.
3. Track in-flight operands through a pipeline array indexed by latency. **Get this depth
   right first.** The initial `fp_mul` run showed 1.87 M failures that were entirely a
   testbench off-by-one, and it looks exactly like a broken DUT.
4. Compare on `out_valid`. Print the first 20 mismatches with raw hex *and* decoded
   values.
5. Print a one-line summary: `checked= skipped= fails=`.
6. Exit nonzero on any failure so `make` stops.

Volume target is ~2M cases per module. That runs in seconds and catches the 1-ULP class
of bug that a hundred directed cases will not.

Skipped cases must be skipped for a documented reason, and the reason belongs in a
comment at the skip site.

---

## Resource discipline

`make area` after any nontrivial change to a datapath block. It is a proxy, not a gate,
but a sudden jump in LUT count means something inferred badly and it is far cheaper to
notice now than at the Quartus gate.

Known baseline, yosys 0.66 generic 6-LUT mapping, `synth -lut 6 -flatten`:

| Module | LUT6 | FF | Notes |
|---|---|---|---|
| `fp_mul` | 1312 | 99 | |
| `fp_add` | 690 | 80 | |
| `mb86233_alu` | 2974 | 381 | includes one `fp_mul` + one `fp_add` |
| `mb86233_agu` | 220 | 0 | purely combinational |

Record the yosys version with the numbers. The first two were previously logged as
1362/747 under an older yosys; the flop counts were identical and only the LUT
counts moved, which is abc mapping better rather than the RTL changing. A baseline
without a toolchain version cannot distinguish those two cases.

**`-flatten` matters.** Without it `stat` prints "Local Count, excluding submodules"
and `mb86233_alu` reports 938 LUT6 — less than `fp_mul` alone, because both FP
instances are omitted. Any module that instantiates another must be read flattened
or the number is meaningless.

`fp_mul` drops to roughly 300 under Quartus once the 24x24 significand multiply infers a
DSP block. If it does not infer, that is a bug worth chasing — three TGP instances
without DSP inference will not fit.

---

## Package portability

`mb86233_pkg.sv` is read by all three toolchains, and yosys is by far the most
restrictive. Four separate constructs had to go:

| Construct | yosys result |
|---|---|
| `op inside {A, B, C}` | `syntax error, unexpected TOK_ID` |
| `return expr;` in a function | `syntax error, unexpected TOK_ID` |
| `module foo import pkg::*; #(...)` | `syntax error, unexpected TOK_IMPORT` |
| `import pkg::*;` at file or module scope | parses, then `ERROR: Assert 'wire != nullptr' failed` |
| `typedef enum` member via `pkg::NAME` | `Failed to detect width for identifier` |

What works everywhere: sized `localparam`s instead of `typedef enum`, `case`
statements instead of `inside`, assignment to the function name instead of `return`,
and explicit `mb86233_pkg::NAME` scope resolution with no `import` at all.

None of this was caught before because `make area` read each module file on its own
and never fed the package to yosys. If you add a package, add it to a synth path in
the same change.
