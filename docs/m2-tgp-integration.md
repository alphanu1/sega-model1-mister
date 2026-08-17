# M2 — putting the TGP in the design

The MB86233 core is built, fuzz-verified against MAME at millions of cases per
unit, and area-measured at 2,554 ALM / 72 MHz. It is instantiated nowhere. This
is the interface it has to present, read off MAME rather than inferred —
`model1.cpp` for the memory maps and machine config, `model1_m.cpp` for the
handlers.

**Why this is the blocker.** Measured 2026-08-17: our V60 advances through
attract mode, matches MAME's tile RAM exactly at frame 71, reaches map 0's
frame-300 state, then starts touching `0xd00000` (510 accesses in 700 M cycles)
and the rest of the attract setup never happens. It ends in a three-instruction
loop at `fed5a4`-`fed5a9`, not halted, no FP trap, I/O board still answering —
the same PC the debug overlay reports on hardware. The 2D path has no
demonstrated fault; the coprocessor's absence is what stops the picture.

---

## The V60 side — four registers, and they are simple

From `model1_mem`, mirrored as noted:

| Address | Width | Behaviour |
|---|---|---|
| `0xd00000` | 16 | copro RAM address register, r/w. **Bit 15 enables post-increment** |
| `0xd20000`/`2` | 16+16 | copro RAM data, one 32-bit word as two halves |
| `0xd80000`/`2` | 16+16 | copro FIFO, one 32-bit word as two halves |
| `0xdc0000` | 16 | FIFO status — **constant `0xffff`** |

### The RAM window, exactly

```c
// read
if (!offset) r = copro_ram_data[adr & 0x1fff];          // low half
else       { r = copro_ram_data[adr & 0x1fff] >> 16;    // high half
             if (adr & 0x8000) adr++; }                 // post-increment

// write
latch[offset] = data;                                    // COMBINE_DATA
if (offset) { copro_ram_data[adr & 0x1fff] = latch[0] | (latch[1] << 16);
              if (adr & 0x8000) adr++; }
```

So the **high half commits**, and the increment is conditional on bit 15 of the
address register — not on anything about the access. `[adr & 0x1fff]` is 8192
words of 32 bits.

### The FIFO window, exactly

```c
// read:  offset 0 pops a 32-bit word and returns its low half;
//        offset 1 returns the high half of THAT SAME popped word
// write: offset 0 latches the low half; offset 1 pushes the 32-bit word
```

Note the asymmetry: reading pops on the **low** access and writing pushes on the
**high** one. Getting that backwards costs one word of skew per transfer, which
would look like a geometry bug much later.

`fifoin_status_r` returning a constant `0xffff` is worth noticing: MAME never
reports the FIFO full or empty, so the V60's code either does not check or is
satisfied by all-ones. Do not invent a status encoding — match the constant
until something proves it wrong.

---

## The TGP side — four address spaces

`MB86233(config, m_tgp_copro, 40_MHz_XTAL)` — 40 MHz, against our core's
measured 72 MHz Fmax, so timing is not the problem.

### AS_PROGRAM

```
0x000-0x7ff  ROM
```

2048 words. **`315-5573.bin` is 8192 bytes = 2048 x 32 bits — an exact fit.**
It is present in `~/roms/vr/` with CRC `3335a19b`. Load it through the MRA per
hard rule 2; nothing ROM-derived gets committed.

### AS_DATA

```
0x0000-0x00ff  RAM                     256 words
0x0100         read  <- copro_fifo_in   (V60 -> TGP)
0x0200-0x03ff  RAM                     512 words
0x0400         write -> copro_fifo_out  (TGP -> V60)
```

The FIFOs are `GENERIC_FIFO_U32`, so 32 bits wide, and they appear to the TGP as
**single data addresses**, not as a register pair.

### AS_IO

```
0x0000       copro RAM address    r/w   (select 0x18 -> mirrored)
0x0001       copro RAM data       r/w   (select 0x18)
0x0020-0x0023  sincos             r/w
0x0024-0x0027  atan               r/w
0x0028-0x0029  inv                r/w
0x002a-0x002b  isqrt              r/w
0x002e         copro_data_w       w
0x8000-0xffff  copro_data_r       r     -> the 2 MB data ROM window
```

### AS_RF

```
0x0  nopw    // LEDs
```

---

## The four math units are table lookups, not arithmetic

This is the good news for area: each is an index computation plus an exponent
fixup over a ROM, and the ROM is `copro_tables` — 0x40000 bytes = **65,536
words of 32 bits**, split into four 16K-word quadrants:

| Unit | Quadrant | Index | Fixup |
|---|---|---|---|
| sincos | `0x0000` | `ang & 0x3fff`, folded when `ang & 0x4000` | XOR sign when `ang & 0x8000` |
| atan | `0x4000` | `base[3] & 0xffff`, clamped to `0x3fff` if `& 0xc000` | **table-bug correction, see below** |
| inv | `0x8000` | `(base >> 9) & 0x3ffe \| (offset & 1)` | exponent `+= 0x7f - bexp`; XOR sign |
| isqrt | `0xc000` | `0x2000 ^ (((base >> 10) & 0x3ffe) \| (offset & 1))` | exponent `+= 0x3f - bexp`; mask sign on even offset |

Each has a `_w` that only latches its operand base (`COMBINE_DATA`) and a `_r`
that does the lookup — so they are write-operand-then-read-result, not
pipelined operations.

### The atan table bug — reproduce it, do not fix it

MAME carries an explicit correction with the comment *"Correct for table bug, it
seems that the hardware does something equivalent somehow"*:

```c
u16 dt = (result >> 16) + result;
if (dt & 0x001) { if ((result & 0x00f) == 0x00e) result -= 0x00000001;
                  else                           result -= 0x00010000; }
if (dt & 0x010) { if ((result & 0x0f0) == 0x0e0) result -= 0x00000010;
                  else                           result -= 0x00100000; }
```

Hard rule 4 applies squarely. This is exactly the class of thing that looks like
a bug to clean up and is not.

### Where the tables come from

`copro_tables` is `opr14742.bin` + `opr14743.bin`, interleaved as 32-bit words,
0x20000 each. Both are in `~/roms/vr/`. There are three further data regions —
`other_data` (0x80000, `opr-14744`..`14747`), `other_other_data` (0x20000,
`opr14748.bin`) — whose consumers have not been traced yet; D4 records that MAME
never executes the geometrizer ROMs, which is a different claim from never
reading these.

---

## What has to be built

| Piece | Size | Where it lives |
|---|---|---|
| V60-side registers: address, RAM window, FIFO window, status | small | `m1_copro_if` **(built)** |
| copro RAM, shared V60/TGP, arbitrated | 8192 x 32 | **32 M10K** — `m1_copro_if` **(built)** |
| TGP data RAM | 768 x 32 | 3 M10K, or MLAB |
| two 32-bit FIFOs | shallow | MLAB |
| microcode ROM | 2048 x 32 | 8 M10K, loaded via MRA |
| `copro_tables` | 65,536 x 32 | **256 KB — SDRAM** |
| `copro_data` window | 2 MB | **SDRAM** |
| four math units | index + exponent fixup | modest ALM |

M10K is the constraint, as ever: 409 of 553 spent, 144 free, and the copro RAM
alone wants 32. D3's band buffer wants ~51. That still fits, but the reserve
options in `HANDOFF.md` "Budget" exist for exactly this.

**The polygon ROMs are 16 MB** (`mpr-14890`-`14897`), which roughly quadruples
the SDRAM footprint over the V60's 6 MB. That is the other argument for putting
sound's 8 MB of samples on DDR3.

---

## The RAM is shared, so the V60's window is a handshake

One M10K port, two masters — Quartus will not infer a second write port, and
duplicating 8192x32 would cost 64 blocks against 144 free. So `m1_copro_if`
arbitrates: a RAM access takes two cycles, register and FIFO accesses take one,
and the V60 wins contention because it is the side whose CPU stalls. Measured in
the testbench: V60 acknowledged at cycle 1, TGP at cycle 3, neither starved.

That forced two corrections worth remembering, both caught by the directed test
rather than by review:

- **Read data cannot be combinational.** The first version tracked the V60's
  address register continuously so the RAM output was always ready. That stops
  being true once the TGP can hold the port. The alternative — a second copy
  that goes stale for one cycle — is correct almost always, which is how this
  project has acquired its worst bugs.
- **The action must be a one-shot even though the request is held.** `m1_main`
  holds `m_req` until it sees `ack`, and the region selects come from the held
  address, so the state machine would otherwise re-run the access and increment
  the address once per pass. This is the complement of the project's other
  handshake lesson: *acknowledges must be held, not pulsed* — and here the
  request is held, so the action must fire once.

## Measured: what the coprocessor actually needs, and in what order

Tapped on the reference's `:tgp_copro` IO space. This was asserted before it was
measured — the claim "the math units being acked with zero is probably the
blocker" was a guess, and the measurement both confirms it and corrects the
ordering.

**The data ROM is the first blocker, not the math units.** The microcode's
opening move, at frame 0:

```
W DATABASE 002e = 00000010      set the window base
R DATAROM  8010 = 00000030      read a word out of it
R DATAROM  8020 = 00012e00      and another — which becomes the NEXT base
```

Two data-ROM reads before any math unit is touched, and the second value is
itself used as a window base. Answering those with zero misdirects the microcode
on its second instruction, which is exactly where ours parks (pc=0044, 116
retires).

Nothing in this space is optional. Census to frame 400:

| Unit | reads | writes |
|---|---|---|
| DATAROM | **70,119** | — |
| SINCOS | 21,548 | 13,337 |
| INV | 11,072 | 5,536 |
| ISQRT | 9,332 | 4,666 |
| ATAN | 1,008 | 4,032 |
| RAMADR / RAMDATA | 1,081 | 8,648 |

**The window arithmetic is confirmed correct.** With `base = 0x12e00` and IO
address `0xae00`, MAME's `index = (base & ~0x7fff) | (offset & 0x7fff)` gives
`0x12e00` — which is what `{dat_base[18:15], io_addr[14:0]}` in `m1_tgp` already
computes. So that logic needs memory behind it, not correcting.

### Test vectors for free

The first three accesses are a ready-made check on the data-ROM path before any
of the harder work: base `0x10` then reading index `0x10` must give `0x00000030`,
and index `0x20` must give `0x00012e00`. If a freshly wired data window does not
produce those two values, nothing further is worth debugging.

## Order of work

1. ~~**`m1_copro_if`**~~ — **done**, 211 checks. The four V60-side registers, the
   8192x32 RAM, both FIFOs and an arbitrated TGP port.
2. ~~**Wire it into `m1_main`**~~ — **done**. Measured: the V60 pushes **11
   command words** per block, which agrees with the 22 accesses to `0xd80000` the
   page histogram showed — two 16-bit accesses per 32-bit word. It writes the RAM
   zero times and never touches the data window at this stage, so its behaviour
   here is purely push-commands-and-wait.
   `tools/build_tgp_rom.py` extracts the microcode and math tables, CRC-checked.
3. ~~**The FIFOs and the TGP's data space**~~ — **done**, `m1_tgp`, `make m1_tgp`.
   **The coprocessor executes real decapped microcode.** Measured: 65 retires of
   initialisation, then it parks with the input FIFO empty rather than consuming
   a stale word, then drains all 11 offered command words and continues to 101
   retires. `unimplemented` never asserts, which is the first check on the
   fuzzing from real code rather than generated instructions.

   What that does NOT establish is that any result is right — the math units are
   not implemented, so this serves their reads from the real tables at the
   quadrant base instead of a computed index, and anything derived from sincos,
   atan, inv or isqrt is wrong on purpose. Correctness is step 5 and the polygon
   diff.
4. **Microcode load through the MRA**, and the SDRAM regions for tables and
   data.
5. **The 2 MB data-ROM window FIRST**, then the four math units. Measured above:
   the data ROM is read before any math unit and 70,119 times to frame 400, and
   the microcode's second instruction depends on it. The math units are pure
   functions of (operand, table) so they fuzz cleanly the way the FP units did,
   but they are not what is blocking the coprocessor's first move.
6. **Polygon list capture** off `copro_fifo_out`, diffed frame by frame against
   MAME. That is the M2 exit criterion in `CLAUDE.md`'s verification model.

### And it closes M0 exit criterion 2

`315-5573.bin` is real decapped microcode, so once the TGP runs it, the
long-owed criterion — lockstep against real microcode rather than generated
instructions — becomes reachable with the same oracle. `sim/tgp/mb86233_ref.cpp`
already has the whole-CPU reference; what it has never had is real code to run.

**A stub will not do.** The TGP does the transform *and* the maths the game logic
consumes, so a block that merely acknowledges the FIFO would let the V60 proceed
on garbage. That is why the microcode being present matters.
