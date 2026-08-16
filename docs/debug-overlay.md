# The debug overlay

A MiSTer core has one output channel and it is the screen. This puts numbers on
it: fifteen 32-bit words drawn as hex digits over the top-left of the picture,
readable off a phone photograph.

It has found five faults that nothing else could see — an `ioctl_wait` deadlock,
a ROM arriving intact when that was in doubt, a CPU halted on a null reset
vector, every SDRAM burst returning one word late, and a scanline budget that
was being missed. Each of those would otherwise have cost a twenty-five minute
Quartus build per hypothesis, answered only by "still wrong".

**Off by default.** Turn it on with *Debug overlay* in the OSD.

---

## What it costs

Measured by building the same core twice, with `DEBUG_OVERLAY` in `Model1.sv`
set to 1 and to 0. Quartus 17.0, 5CSEBA6U23I7:

| | overlay in | overlay out | cost |
|---|---|---|---|
| ALM | 26,469 | 26,162 | **307** (0.7% of the device) |
| registers | 19,507 | 18,954 | **553** |
| M10K | 409 | 409 | **0** |
| worst-case setup slack | +0.306 ns | +0.296 ns | none it can be blamed for |

307 ALM is under a third of a percent of what the core uses, it takes no block
RAM at all, and it did not cost timing — the overlay build actually closed
marginally better, which is placement noise rather than a real difference.

That is cheap enough to keep in every build. `DEBUG_OVERLAY = 0` removes the
renderer, the capture registers, the fetch trace and the frame-rate counters
together, for a release build that wants nothing extra in it.

---

## What each row means

Every row leads with its own number, so a photograph that is cropped or partly
glared out can still be matched up row by row. The remaining six digits are the
value, most significant first.

| Row | Contents | Reading it |
|---|---|---|
| `00` | V60 program counter | Moving means the CPU is executing. Parked at a small value means it halted — the V60 sets `halted` on opcode `0x00`, and address 0 is work RAM full of zeros. |
| `01` | Instruction fetches served | Frozen at a tiny number is a CPU that died early. It stops counting when the CPU is executing from on-chip RAM, which generates no SDRAM traffic. |
| `02` | CPU data reads served | |
| `03` | Character fetches served | The tilemap engine's activity. Frozen means the video path is not fetching. |
| `04` | Words the HPS sent | Should read `300000` — the whole ROM stream. |
| `05` | ...that reached SDRAM | **Must equal row `04`.** A shortfall is the loader dropping what arrived after `ioctl_wait` went up: a ROM with holes in it, reported as a successful load. |
| `06` | First instruction fetch: address | Normally `000000`, a prefetch artefact. Simulation does the same, so it is not a fault. |
| `07` | ...and the word it returned | |
| `08` | Reset vector data | **`4EF3D6`** when the SDRAM read phase is right. `FE104E` is the same burst read one 16-bit word late — see below. |
| `09` | Fetch 4 data | `414C50` on a healthy boot. |
| `0A` | Fetch 5 data | `FFEFB2` on a healthy boot. |
| `0B` | Flags and I/O replies | Top byte after the tag: bit 5 loader overflow, bit 4 CPU halted, bit 3 FP trap, bit 2 ROM ready, bit 1 memory ready, bit 0 downloading. Low four digits are the I/O board's reply count, which should climb. |
| `0C` | Fetch deadline misses, then last line's worst-layer fetch count | Misses are cumulative, **not a rate** — reading them as one is a mistake this project has already made. Watch whether the number is still moving. |
| `0D` | Frames per ten seconds, BCD | `0575` reads as **57.5 Hz**, which is what MAME's timing gives. |
| `0E` | Frame period in `clk_sys` cycles | Nominally `153A40` = 1,390,720: 656 x 424 dots at five cycles a dot. Updates every frame, so a drifting rate or a wrong-length frame shows immediately instead of being averaged away. |

Rows `06`–`0A` are a trace of the CPU's first few instruction fetches, captured
once and held. They exist because a CPU that dies does so in the first handful
of fetches, and by the time anyone can photograph the screen the evidence is
long gone. `tools/rom_at.py <addr>` turns any of those addresses into what the
ROM image says should be there.

---

## Reading it off a photograph

- Digits are 5x7 in an 8x8 cell drawn at 2x, so each is 16x16 pixels. A phone
  resolves that without trouble; the first version drew 32 blocks per word with
  a green rule every four bits, and three values were misread off it because a
  camera against an LCD produces moire on an 8-pixel pitch.
- A cell that shows stripes rather than solid colour is one that changed during
  the exposure. That is free information: it says which counters are live.
- The overlay draws from registers only and never touches SDRAM, but it is not
  independent of the video timing — its position counters are rebuilt from the
  same `hb`/`vb` the picture uses. If the picture is unstable the overlay will
  be too, so a steady overlay is not evidence that the video path is healthy.

---

## Verification

`make test_diag` — 761,856 checks, every pixel of every frame against the glyph
it should be, in three word patterns covering all sixteen glyphs in all eight
digit positions, plus a pass with the overlay disabled where every pixel must
come through untouched.

The font is typed out a second time in the testbench rather than shared with the
RTL. A test that imports the table it is checking proves the renderer consistent
with itself and nothing else; written twice, a wrong glyph has to be wrong the
same way twice to survive.
