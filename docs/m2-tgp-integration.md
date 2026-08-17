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
| V60-side registers: address, RAM window, FIFO window, status | small | new `m1_copro_if` |
| copro RAM, shared V60/TGP | 8192 x 32 | **32 M10K** |
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

## Order of work

1. **`m1_copro_if`** — the four V60-side registers and the copro RAM, with a
   directed testbench asserting the post-increment rule, the commit-on-high-half
   rule, and the pop-on-low/push-on-high asymmetry. Self-contained and testable
   with no TGP present.
2. **Wire it into `m1_main`'s decode** so the V60's existing traffic lands
   somewhere real. The boot trace already shows 510 accesses to `0xd00000`, so
   this is immediately observable: those reads should stop returning nothing.
3. **The FIFOs and the TGP's data space**, still without the math units. At this
   point the TGP can execute microcode and exchange words.
4. **Microcode load through the MRA**, and the SDRAM regions for tables and
   data.
5. **The four math units**, each against MAME as oracle — they are pure
   functions of (operand, table), so they fuzz cleanly the way the FP units did.
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
