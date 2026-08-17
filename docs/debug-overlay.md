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

A row's number is its **identity, not its position**. Rows have been added and
removed and the numbers stayed put, so photographs from different builds can be
compared row by row. The sequence therefore has gaps — `09` and `0A` are retired,
not missing.

| Row | Contents | Reading it |
|---|---|---|
| `00` | V60 program counter | Moving means the CPU is executing. Parked at a small value means it halted — the V60 sets `halted` on opcode `0x00`, and address 0 is work RAM full of zeros. Sampled through two flops, so a PC changing every cycle may show a value never actually held; a parked one reads exactly, which is the case this exists for. |
| `01` | Instruction fetches served | Frozen at a tiny number is a CPU that died early. It stops counting when the CPU is executing from on-chip RAM, which generates no SDRAM traffic. |
| `02`–`07` | Addresses of the first six instruction fetches | Captured once at boot and held. A CPU that dies does so in the first handful of fetches, and by the time anyone can photograph the screen the evidence is gone. `03` is the reset vector's fetch. Healthy: `000000`, `0BFFF8`, `0BFFFC`, `000000`, `0B0824`, `0B0828`. |
| `08` | Reset vector data | **`4EF3D6`** when the SDRAM read phase is right. `FE104E` is the same burst read one 16-bit word late — see below. |
| `0B` | Flags and I/O replies | Top byte after the tag: bit 5 loader overflow, bit 4 CPU halted, bit 3 FP trap, bit 2 ROM ready, bit 1 memory ready, bit 0 downloading. So `06` is the healthy value — ROM and memory ready, not halted, no trap. Low four digits are the I/O board's reply count, which should climb. |
| `0C` | Fetch deadline misses, then last line's worst-layer fetch count | Misses are cumulative, **not a rate** — reading them as one is a mistake this project has already made. Watch whether the number is still moving. |
| `0D` | Frames per ten seconds, **BCD** | Read the digits as decimal and move the point one place: `0576` is **57.6 Hz**. |
| `0E` | Frame period in `clk_sys` cycles, **hex** | `80000000 / value` = Hz. `15387F` = 1,390,719 → **57.52 Hz**. Nominal is `153A40` = 1,390,720: 656 x 424 dots at five cycles a dot. |
| `0F` | Coprocessor retire count, and `unimpl` in bit 16 | A count that moves means it is executing real microcode. `unimpl` set means it hit an opcode the core does not implement. |
| `10` | Coprocessor PC | Where it stopped, if it stopped. |
| `11`–`14` | Visible pixels won per tilemap, per frame — 0 to 3 | **`02E800` is 190,464 = 496 x 384, the whole screen.** A layer with content in tile RAM reading `000000` is not reaching the screen; a layer reading near `02E800` is covering everything. Latched at vblank, so it is a whole frame's worth. |
| `15`, `16` | Window/split-scroll control for pairs 0/1 and 2/3 | Bits 14:13 non-zero means the game asked for a split; negate the value and take the low nine bits for the scanline it splits at. `0000` means window mode is off and the window logic is not implicated in whatever is on screen. |
| `17`, `18` | Coprocessor FIFO pushes, and returns | Separates "the V60 is not sending work" from "the coprocessor is not taking it" — the two look identical from a screen. |

### What rows `11`–`14` cannot tell you

They count which layer **won** a pixel, not which layer drew. All four tilemaps
composite in a fixed order and each pixel shows the frontmost non-transparent
contributor, so a layer reading zero may be rendering perfectly and simply be
covered.

They also do not distinguish two very different states, because **both read as
four zeros**: a frame where the renderer never ran, and a frame where every layer
declined to draw and the whole picture fell through to the backdrop. The backdrop
is palette entry 0, which in Virtua Racing is blue — so "all four zero" can mean
a flat blue screen that is working exactly as designed. `make m1_frame
FRAME_TRACE=1` reports the backdrop share per frame and separates them; the
overlay cannot.

### Working out the frame rate

The two rows answer the same question at different precisions, and they are read
differently — `0D` is BCD and `0E` is hex.

```
0D 000576   ->  576 frames in ten seconds  ->  57.6 Hz
0E 15387F   ->  0x15387F = 1390719 cycles  ->  80e6 / 1390719 = 57.52 Hz
```

`0D` counts whole frames, so 575.2 shows as 575 or 576 and jitters by one; it is
the number to read at a glance. `0E` is exact and updates every frame, so it is
the one to use when the answer matters — a frame one cycle short of nominal is
the vsync edge falling either side of the count, not drift.

`tools/rom_at.py <addr>` turns any address from rows `02`–`07` into what the ROM
image says should be there.

The data words of fetches 4 and 5 used to occupy rows `09` and `0A`, reading
`414C50` and `FFEFB2` on a healthy boot. They were retired to stay under the
24-row ceiling — 384 visible lines at 16 pixels a row. They proved ROM contents
were arriving, which a core that now boots and runs proves better. Their
addresses survive as rows `06` and `07`.

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

## The four faults this instrument had, and why none was visible

All four were live at once on a board being photographed for diagnosis. Kept here
because the shape recurs: **an instrument that lies is worse than one that is
absent**, and three of these lied by going blank.

| Fault | What it looked like |
|---|---|
| `m1_diag` instantiated with `NWORDS(19)`, `words` pin wired from a 15-word concatenation | Top 128 bits read zero, so rows `0F`–`12` rendered `00000000` **including their row tags**. A blank row reads as *absence*, so the hunt went after the bitstream — was a stale `.rbf` flashed? — rather than the wiring. |
| `row` was 4 bits, compared as `row == 4'(w)` | `4'(16)` is 0, so word 16 matched row 0 as well. The comb loop runs ascending and the last match wins, so words 16–18 — undriven, hence zero — **overwrote rows 0, 1 and 2**. Those held the PC and the fetch history, so the instrument reported a dead CPU on a running core. Seven of nineteen rows wrong from one truncated index. |
| Two rows built 40 bits wide, assigned to 32 | Verilog truncation discards the **high** bits, so those rows lost their own tags and rendered under a wrong row number — the one failure the tagging scheme exists to prevent. |
| Census counters 16 bits | A visible frame is 190,464 pixels. A layer covering everything pinned at 65,535 and read the same as a layer covering a small window. The saturated value was quoted as evidence for a frame. |

And why each check missed it:

- **The testbench built at `NWORDS=12`**, below the threshold where the row index
  truncates, and passed throughout. It now builds twice, at 12 and 23, the way
  `bw_monitor` is built twice for its counter widths. Reinstating the 4-bit index
  fails the wide build on 12,716 pixels; the narrow build still passes, which is
  the point.
- **Its word lists held 12 entries**, so a wide build would have zero-filled the
  new rows — and zero is the one value that hides the aliasing, because the
  symptom was a high row overwriting a low one *with zero*. A test whose expected
  value equals the corrupt value proves nothing. The lists are now filled
  programmatically, distinct and non-zero to the last row.
- **`make lint_top` grepped its log for `%Error` and discarded every warning.** A
  short pin connection is a `WIDTHEXPAND` warning, not an error, so the check ran
  and reported clean. It now also fails on width warnings of two classes — port
  connections and `ASSIGNW` — scoped to our own files. Not all width warnings:
  `make lint` waives them project-wide and there are around fifty across `rtl/`,
  most in the imported V60. A check with no backlog is one that stays switched on.

The packed vector is now built by a generate loop over `NDW`, which sizes the
array, the loop bound and the parameter together, so adding a row cannot leave
the port half-connected. The residual risk — a wrong loop bound — is silent, but
there is no second number to keep in step, which is what actually went wrong.

---

## Verification

`make test_diag` — two builds, at 12 and 23 words, 761,856 checks each: every
pixel of every frame against the glyph it should be, in word patterns covering
all sixteen glyphs in all eight digit positions, plus a pass with the overlay
disabled where every pixel must come through untouched.

The font is typed out a second time in the testbench rather than shared with the
RTL. A test that imports the table it is checking proves the renderer consistent
with itself and nothing else; written twice, a wrong glyph has to be wrong the
same way twice to survive.
