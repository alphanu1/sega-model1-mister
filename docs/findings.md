# Findings — what is established, and how

The durable record of **measured facts** about this hardware, separate from
`HANDOFF.md` (which is the state of play and changes weekly) and from the
per-topic investigations that produced them.

**Why this file exists.** Three findings have been re-derived from scratch after
being established once, and several conclusions were reached twice — the second
time correcting the first. A finding is only worth the measurement if the next
session can find it.

**Rules for entries here.** Every entry states what was measured, with what
instrument, and what it corrected. Anything not measured says so. When an entry
turns out to be wrong it is **corrected in place with the old reading kept
visible** — a doc that silently rewrites itself stops being trustworthy, and
knowing which way we were wrong is often the useful part.

Topic detail lives in: `io-board.md`, `2d-gap-analysis.md`,
`m2-tgp-integration.md`, `mister-integration.md`, `debug-overlay.md`.

---

## Reasoning has lost to measurement five times

Kept as a table because the pattern is the point, not the individual entries.

| Question | Reasoning said | Measurement said |
|---|---|---|
| where do the inputs live | a mailbox at DPRAM `0x100` | `0x00`-`0x0e`, polled every frame |
| why is most of the 2D missing | the row mask, then the window mode | neither — the V60 never gets that far |
| does the V60 read the coprocessor back | it must, to collect results | **never**, in 2,500 accesses |
| what blocks the coprocessor | the math units returning zero | the **data ROM**, read before any math unit |
| how deep are the coprocessor FIFOs | 64 seemed like sensible slack | **16**, and full halts the CPU |

Three cost a session or more. Every one was a plausible mechanism reasoned from
partial evidence that a five-minute instrument would have refuted. Hence the
rule: **when something is unknown, run MAME** — see `HANDOFF.md`.

---

## The I/O board

**The complete control map is measured**, not inferred. MAME running the real
Z80, one control held at a time.

| DPRAM | Contents |
|---|---|
| `0x00` | steering, centre `0x80`, full `00`-`ff` travel |
| `0x01` | accelerator, **released `0x01`**, floored `0xff` |
| `0x02` | brake, same shape |
| `0x03`-`0x07` | set to `0xff` at startup; contents unknown |
| `0x08` | IN.0 — coin 1, coin 2, test, service, start, VR1-3 |
| `0x09` | IN.1 — VR4 bit 0, shift down/up bits 4/5 |
| `0x0a` | IN.2 — drive-board RX, unused here |
| `0x0b`-`0x0d` | DSW1-3 |
| `0x0e` | chip port 6 |
| `0x0f`, `0x10` | read by the V60; **`0x0f` is also written by it** — not ours to publish |

Idle is **not** uniform: digital bytes rest at `0xff` (active low), a released
pedal at `0x01`. Publishing a blanket `0xff` is both pedals floored.

One row self-checks: the operator reported pressing F2 twice by accident, and
`0x08 -> fb` appears exactly twice in the log.

**A 128-byte identity block at DPRAM `0x100`-`0x17f` is what unblocked boot.** The
V60 block-reads all of it once, immediately after its first handshake is
answered, and will not poll its controls until it has. Nothing writes that window
beforehand, so the board supplies it. Contents in `io-board.md`.

**This is per-game, but barely.** The DPRAM addresses are board hardware — same
315-5338A, same `EPR-14869` in every cabinet. MAME carries six input maps across
ten Model 1 entries and the *system* half of IN.0 (coin 1, coin 2, test, service,
start) is bit-identical in all of them.

---

## The 2D path renders correctly — proven by a local frame

`make m1_frame FRAME_CYCLES=800000000` renders the attract-mode ranking table
correctly: `1st YU. 4'00"00` through `6th MAS`, with the car sprites and banners,
over the sky and sea. Saved as `docs/images/attract-ranking-2026-08-17.png`.

Census from the same run: **tm0=0, tm1=18933, tm2=190464, tm3=0**. So tilemap 1 —
the text layer that was missing all week — reaches the screen, and tilemap 3
contributes nothing, meaning it is not what covers the picture.

`tm2` was first recorded here as `65535 (saturated)`, which was the counter's cap
being quoted as a measurement. It is 190,464 — 496 x 384, the entire screen. The
counters are 18 bits now.

### And most of what MAME shows on these screens is 3D, not 2D

Measured, MAME 60 s of attract, Lua frame notifier sampling tile RAM at `0x700000`
every 30 frames with snapshots every 90:

**At the ranking screen MAME's background is the 3D road, not the sky and sea.**
The sky-and-sea image is in tilemaps 2/3 all along — *behind* the 3D layer, which
covers it. Our render shows the ranking text over sky and sea because the 3D that
should be in between is absent. **That output is correct for a core with no
rasterizer**, not a compositing fault, and it was nearly filed as one.

**The attract loop cycles through screens, and tilemap 1 is empty on several of
them.** Tilemap 1's content count over 60 s runs `0 -> 144 -> 768 -> 336 -> 0`.

This was first written up here as "screens with no 2D text at all", which is
**wrong** and was corrected on being challenged: `INSERT COIN(S)`, `CREDIT 0` and
the SEGA logo are plainly on screen in those snapshots. What is empty is tilemap
*1*. That text is on **tilemap 0**, which holds 16-432 non-blank words on every
screen of the loop. Reading "tilemap 1 is empty" as "there is no text" skipped
straight past the question of which layer the visible text was on — and that
question was the bug. See below.

**Nothing scrolls, and `ctrl` is not the reason.** `ctrl` — the pair's even
`vscr` — animates **every frame** in MAME: `2059, 2047, 2033, 201e, 2005, 23e9,
23ce...`, counting down through a 10-bit wrap, while ours held `2000`. That is a
real divergence but it is a *consequence*: that register belongs to pair 2/3, and
pair 2/3 turns out not to be drawn at all (below). Recorded because it was briefly
treated as the cause.

**Interrupts were suspected and are innocent.** The vblank IRQ reaches the V60 and
is taken: our PSW reaches `0x10040000` — bit 18, IE — exactly as MAME's does, with
700+ acknowledges over 200 frames. MAME agrees the game enables interrupts by
frame 9. A static picture with correct content looks exactly like a vblank handler
that never runs, and that cost a round of investigation; the measurement is one
counter at the acknowledge, not the raise.

**Build the local instrument before flashing.** This render was one index-1 ioctl
pass away from working for days, and in the meantime three hardware round trips
were spent photographing an overlay whose rows could not be identified with
confidence — one of those builds predated the telemetry it was being asked to
report, which the photograph revealed by showing tag `00` where `0F` belonged.

**NEVER EDIT RTL WHILE A BUILD IS RUNNING.** `tools/mister_project.sh` SYMLINKS
`rtl/` and `Model1.sv` into `build/mister` rather than copying them, so synthesis
reads whatever is on disk at the moment it reads each file. Editing during a build
therefore produces a bitstream that is part one revision and part another, with
nothing to indicate it. That is how a build acquired the window mode but not the
census, and the mixed result was then debugged as though it were a logic fault.

**And check the flow is finished before flashing, by exact process name.** A stale
`fit.summary` and `.rbf` from the previous run sit in `output_files` looking
current. `pgrep -f quartus_` is not the check — the pattern matches the checking
command's own line and always reports something running; `pgrep -x quartus_fit`
and friends do not.

Also note the frame test's DEFAULT 120 M cycles renders the *wrong moment*:
`pc=fe143d`, one FIFO push, and only tilemap 2 on screen. The attract content
needs ~700 M. A render of the wrong program state looks exactly like a rendering
fault.

And the deadline-miss count is identical at 120 M and 800 M cycles (9,417 both),
so it is entirely boot transient — the same cumulative-counter trap as before, and
the char-fetch wait average falls from 136 to 19 cycles once the boot phase stops
dominating it.

## The row mask is keyed to the tilemap, not to the tile category — 2026-08-17

**This is the missing text.** `draw_common` computes two values from the same
expression, one line apart, either side of a shift:

```cpp
uint16_t tpri = layer & 1;   // BEFORE the shift -> the tile CATEGORY
lpri = 1 << lpri;
layer >>= 1;                 // layer is now the tilemap, 0..3
...
int win = layer & 1;         // AFTER the shift  -> the ODD tilemap
```

`draw_rect` then applies them as two **independent** gates:

```cpp
uint16_t m = *mask1++;
if (win) m = ~m;                 // does this 8-pixel column draw from this map?
if (!(m & 0x8000)) {
    if (srct[xx] == tpri || ...) // which tiles inside it contribute?
```

So both categories of one tilemap see the **same** mask polarity, decided by
whether that tilemap is odd or even. Ours computed `mask ^ category` — the same
expression read one line too late — which is right for an even tilemap's
category-0 pass and an odd tilemap's category-1 pass, and inverted for the other
two. `INSERT COIN(S)`, `CREDIT 0` and the SEGA logo are category-1 tiles on
tilemap 0, an even map, so they were suppressed wherever the mask bit was clear —
which the game leaves clear across most of the screen.

**Measured, per frame, over 680 frames:** tilemap 0 held content in **617** frames
and won a pixel in **47** — and those 47 are the boot frames before the game
writes a mask table at all. Tilemap 1 won in 329 of the 333 it had content for.
That asymmetry is the fault's signature: the ranking table is category-1 on an
**odd** map, the one combination the wrong formula got right by luck, which is why
that text appeared and made the 2D path look healthy.

After the fix, the same 53 content words on tilemap 0 produce **9,674 visible
pixels**, and the attract screen renders `MEDIUM COURSE RANKING`, the column
headers, the rank rows with their car sprites, `INSERT COIN(S)`, `CREDIT 0` and
`© SEGA 1992` — every one of which was absent before. Saved as
`docs/images/attract-rowmask-fixed-2026-08-17.png`; against MAME's own frame the
text matches in position and colour throughout.

Two differences remain against the reference, neither a 2D fault:

- **The background is flat**, where MAME has the 3D road. That is the rasterizer,
  which is not built. 93% of the frame is backdrop.
- **The blue SEGA logo is not visible.** It is blue on MAME's grey road and would be
  blue on our blue backdrop, so it is probably drawn and indistinguishable rather
  than missing. Not confirmed either way — the census counts wins per tilemap, not
  per glyph, so it cannot separate the two.

### And a pair in window mode with hscr bit 15 clear draws NOTHING

The nesting in `draw_common` carries the rule, and there is no `else` on the inner
`if`:

```cpp
if (ctrl & 0x6000) {           // window mode
    if (layer & 1) return;     // the odd map never draws directly
    set_scrolly(both maps);
    if (hscr & 0x8000) { ...per-line draw... }   // and only here
} else { ...normal path, with the row mask... }
```

Measured: attract sets `ctrl` to `0x2000`-`0x23xx` on pair 2/3 — window mode 1 —
while `hscr` for all four tilemaps stays below `0x0200`, so bit 15 is **never**
set. MAME therefore draws tilemaps 2 and 3 **not at all**. We drew tilemap 2, and
its category-0 pass is opaque, so it covered all 190,464 pixels. **That is where
the sky and sea came from: a pair the hardware does not display at all.**

The window decision uses the **pair's even** `hscr`, not each map's own, because
MAME only reaches that branch through the even map's draw call.

### Why 380,929 checks agreed with the bug

`m1_video`'s reference model was written from the same reading of `draw_common` as
the RTL, so both were wrong in the same way and the comparison passed. Worse, the
comment in the reference stated the wrong rule explicitly and confidently.

- **A reference derived from the same reading of the source as the implementation
  cannot catch a misreading of the source.** It can only catch a slip between the
  two. What caught this was a per-layer census against the reference *running*,
  not against a rereading of it.
- `tb_m1_tile_fetch` never drove `row_mask` and never checked `lb_masked` at all,
  so the module owning the logic had no coverage of it. It does now, including a
  case asserting the mask is independent of the tile category, and reinstating the
  old expression fails it.

## The 2D path

**The missing 2D was never a rendering fault.** Our tile RAM at frame 71 matches
MAME at frame 71 exactly, including 370 category-1 tiles on map 0 — not a number
to match by chance. MAME writes the text, the scroll registers and the row-mask
table only between frames 150 and 300, and our V60 stops advancing before that.

Everything chased before that was a difference in **program state**, not in
pixels. Two real gaps were found on the way and both are worth keeping:

- **The row mask is implemented** and verified: segas24 masks each tilemap in
  8-pixel columns from tile RAM `0x6000` (maps 0/1) or `0x6800` (2/3), four words
  per scanline, and each tilemap is drawn twice with the mask inverted for the
  second pass — so a column shows whichever category matches its mask bit.
  Ignoring it equals `m = 0`, which MAME treats as "draw all 128 pixels".
- **`ctrl & 0x6000` window/split-scroll mode is NOT implemented.** Confirmed
  active in the reference (`ctrl = 0x2058`). The four tilemaps are two **pairs**,
  not four peers — odd maps are window maps, drawn only through their even
  partner — and `ctrl` is the pair's even `vscr`, not each map's own register.

**The mixer's draw order and opaque flags are confirmed** against
`model1_v.cpp`, not inferred: layers `6,4` opaque then `2,0`, then the 3D, then
`7,5,3,1`. Our `opaque_pass = (i >= 2)` and paint order match exactly.

Ruled out by measurement: fetch bandwidth (**zero** deadline misses; an overrun
repeats a scanline anyway, which is not the symptom) and the ROM set (29/29,
zero CRC mismatches).

---

## The coprocessor

**The V60 never reads back from it.** Over 2,500 logged accesses the reference
does 1,198 FIFO writes, 102 address-register writes, two status reads, and **zero
FIFO reads and zero copro RAM data accesses**. The TGP's output goes to the
renderer, not to the CPU. So a core showing "returns=0, pops=0" is behaving
correctly.

**Flow control is by halting a CPU, not by a status register.** `setup(16, ...)`
on both FIFOs, and `gen_fifo.h` names the callbacks: empty halts the TGP, full
halts the **V60**, un-empty and un-full release them. That is why
`fifoin_status_r` can be a constant `0xffff` nobody polls. **Depth is 16.** A
push into a full FIFO must stall, never drop — dropping loses geometry with no
counter moving anywhere.

**The data ROM is the coprocessor's first blocker, not the math units.** Its
opening move at frame 0:

```
W DATABASE 002e = 00000010      set the window base
R DATAROM  8010 = 00000030      read a word out of it
R DATAROM  8020 = 00012e00      and another — which becomes the NEXT base
```

Two data-ROM reads before any math unit is touched, and the second value is
itself a window base. **Those two words are a free test vector** for whatever
wires that memory up.

Nothing in the IO space is optional. To frame 400: DATAROM 70,119 reads, SINCOS
21,548/13,337, INV 11,072/5,536, ISQRT 9,332/4,666, ATAN 1,008/4,032.

**The two sides' copro RAM rules differ**, and both are on the same 8192x32 RAM:

| | V60 | TGP |
|---|---|---|
| address registers | one | **four**, selected by IO address bits 4:3 |
| increment | only when bit 15 set, by 1 | **always**, by **4** when bit 18 set else 1 |
| commit | on the **high** half of a 16-bit pair | whole 32-bit word |

**The four math units are table lookups**, not arithmetic: a 256 KB ROM in four
16K-word quadrants — sincos `0x0000`, atan `0x4000`, inv `0x8000`, isqrt
`0xc000` — each an index computation plus an exponent fixup. `atan` carries a
**deliberate table-bug correction** that MAME reproduces, with a comment saying
the hardware does something equivalent. Reproduce it; do not tidy it.

### The V60 faked IN and OUT — RESOLVED

The cores agreed exactly at `pc=fed58f`, then ours looped at
`fed5a4`/`fed5a7`/`fed5a9` while the reference reached `fed5b9`. Disassembling
those three instructions named it in minutes:

| Address | Opcode | Instruction |
|---|---|---|
| `fed5a4` | `0x24` | **`INW`** — read a word from the V60's **I/O space** |
| `fed5a7` | `0xf1` | `TESTB` |
| `fed5a9` | `0x65` | `BNE8` — branch back |

A polling loop on an I/O-space read. And our imported V60 did this:

```systemverilog
8'h20, 8'h22, 8'h24: begin  // IN — read io (mapped to bus, io space unused on S32)
    wb_op2(32'hffffffff, cur_op[2:1]);
end
8'h21, 8'h23, 8'h25: begin  // OUT — ignore
    st <= S_NEXT;
end
```

**`IN` returned a constant and `OUT` was discarded.** True enough for System 32,
where nothing uses the space. On Model 1 `model1_io` maps the coprocessor's four
registers — RAM address, RAM data, command FIFO, FIFO status — **at the same
addresses as `model1_mem`**, so an `IN` or `OUT` there is a real transaction with
real side effects: reading the FIFO pops it, writing the address register arms an
auto-increment. The V60 was polling a value that could never satisfy its test.

Routed to the ordinary data bus, since the two maps coincide on this board. A
machine that mapped them differently would need a separate space.

Effect, against the reference at the equivalent frame:

| | before | after | reference |
|---|---|---|---|
| tilemap 0 category-1 | 4096 | **4012** | 4012 |
| tilemap 1 category-1 | **0** | **648** | 648 |
| row mask non-zero | 0 | 240 | 72 |
| `scroll[5006]` | `0000` | `2000` | `2058` |

Tilemap 1's 648 tiles are the text layer that was missing from the screen, and it
matches exactly. Row mask and scroll do **not** match yet — plausibly the
unimplemented `ctrl & 0x6000` window mode, which now matters.

**THE INSTRUMENT LESSON, and it is the most expensive one here.** The I/O space
generates no memory-bus traffic, so every bus-level instrument showed an empty
loop and the fault read as a CPU bug. A PC-filtered read tap on the reference
reported "no data reads at all in `fed5a4`-`fed5a9`" — true, and utterly
misleading. **When a loop appears to poll nothing, disassemble it.** Ten minutes
of decoding against days spent around it.

---

## Imported code carries its origin's assumptions

**IMPORTED CODE CARRIES ITS ORIGIN'S ASSUMPTIONS, AND THEY ARE USUALLY IN A
COMMENT.** The V60 comes from `meathax/s32`, and its `IN`/`OUT` handler said
"io space unused on S32" while returning a constant and discarding writes. That
was *correct for System 32* and silently wrong here, and it cost days — the
comment was accurate, honest, and load-bearing, and nobody read it against Model
1's memory map.

Worth a sweep for the same shape wherever `S32`, `Golden Axe` or `Spider-Man`
appears in a comment in `rtl/cpu/v60/`: each one marks a place where behaviour was
scoped to a different board. `S32_V60_NO_FP`'s own comment says "Golden Axe never
executes the optional floating-point groups", which is exactly the same class of
claim about a different game.

## Instruments, and what each cannot do

- **A read tap and a memory watch are different tools.** A read leaves no trace
  in memory, so watching contents cannot find where something is *read*. Not
  knowing this cost a day.
- **A saturating counter that reports its cap as a value is worse than no
  instrument**, because it produces a confident number. The boot trace's
  watch-page tables held 32 entries and filled silently, so "the V60 touches 32
  addresses and none is `0x08`" was a table limit reported as a finding. They
  hold 256 now.
- **A cumulative counter is not a rate.** 6,849 deadline misses over 103 frames
  read as "one line in six"; every miss was before frame 31 and 72 consecutive
  frames were clean.
- **A test comparing two empty sets passes and proves nothing.** The loader test
  reported "0 program words, 0 mismatches" and went green when a helper was
  overriding the download index. Assert there is something to check.
- **A guard test must fail if it stops measuring.** The single-cycle strobe test
  asserts both that one strobe advances one word *and* that three advance three.
- **`make area` is not `make quartus`.** Generic 6-LUT mapping built
  `m1_copro_if`'s 256 Kbit RAM out of logic and reported 17,737 LUTs against the
  real 1,244 ALM and 33 M10K — a 14x disagreement, and only one of them measures
  the thing.
- **"Non-black pixels" is not a liveness metric.** 15.7 M non-black was one flat
  blue field.
- **The overlay reported four wrong rows, and the wrongness was invisible.** Four
  faults at once, none of which any test or lint caught — see
  `debug-overlay.md`. The one to carry forward: three of them made rows read
  `00000000`, and a blank row looks like *absence* rather than *error*, so the
  hunt went after the bitstream instead of the wiring.
- **A single captured frame cannot see an alternation.** The board's picture
  flashed between a rendered image and a flat colour; the frame test captured
  one frame at one cycle and rendered correctly, so "simulation is right and
  hardware is wrong" was believed for two builds. `FRAME_TRACE=1` now prints one
  line per frame.
- **A backdrop is not a blank screen.** `m1_tile_mixer` emits source 15 when no
  layer wins, and the backdrop is palette entry 0 — which in this game is blue.
  So a frame where every layer declines to draw is a *flat blue picture*, not a
  black one, and the per-tilemap census reads four zeros because it only counts
  sources below 8. Two different faults produce that reading and the census
  alone cannot separate them; the backdrop share can.
- **Verify against data that can distinguish the fault.** The SDRAM word-late bug
  survived a session because it was checked at word 0, where the ROM is
  `000d 000d 000d 000d` — the one address where a one-word shift cannot show.

### MAME harness details, each of which cost a run

`-skip_gameinfo` or the warning screen blocks autoboot and the script silently
never loads. `-autoboot_delay 0` or a tap installs after the exchange it was
meant to capture. Assign every notifier and tap to a **global** or the
subscription is collected and the callback stops with no error. Wrap notifier
bodies in `pcall` — errors inside them vanish. Run from a scratch directory:
MAME drops `cfg/`, `nvram/` and `snap/` wherever it starts.

**A leftover in the working directory invalidated three of my own
conclusions.** I claimed, from pointing `-rompath` at one source at a time, that
neither `vr.zip` nor `vr.7z` was complete and that MAME assembles a set across
both. That was wrong. `-verbose` shows MAME **never opens the 7z**: it runs from
`vr.zip` alone. What actually differed between the runs was a
`nvram/vr/ioboard_eeprom` file this session had created — with it present, the
EEPROM comes from saved NVRAM and `93c45.bin` is not needed from any archive at
all. The "missing file" was a fresh-NVRAM condition wearing a missing-ROM costume.

**So: run ROM-resolution experiments from a clean directory, and check what the
previous run left behind.** This project's own notes say a control experiment run
against a dirty state proves nothing — written about the MiSTer needing a reboot
between core loads — and the same applies here. `cfg/`, `nvram/` and `snap/`
accumulate wherever MAME starts.

**What MAME needs is not what the core needs**, and that part stands. MAME
emulates the I/O board Z80 and the comm board; the MRA loads thirteen parts, all
present in `vr.zip` and CRC-verified. Check against the MRA's part list, not
against MAME's.

---

## Measured resource costs

Quartus 17.0, 5CSEBA6U23I7, on the real core unless stated.

| | ALM | M10K | note |
|---|---|---|---|
| whole core, before M2 | 26,663 | 409 | timing +0.401 ns |
| whole core, **with M2** | **29,141** | **452** | timing **+0.116 ns** — thin |
| **`s32_v60` alone** | **17,691** | — | **67% of the design** |
| `ascal` + framework | ~3,600 | 54 | not ours |
| everything we wrote | <1,000 | — | before M2 |
| `m1_copro_if` | 1,244 | 33 | `RAM_BLOCK_TYPE = M10K` confirmed |
| row mask | +204 | 0 | line-buffer word 14 -> 15 bits was free |
| debug overlay | 307 | 0 | |
| `S32_V60_NO_FP` | **-2,984** | 0 | unspent. Its justification is a claim about *Golden Axe*, not this game — get Model 1's own `dbg_fp_trap` evidence first |

**The V60 being the majority of the design is the fact that decides where
optimisation is worth any effort.** Squeezing our own code cannot matter.

### And the V60 is about 2.5x larger than it needs to be

Measured against the sibling Model 2 core's i960, which is a fair comparison
rather than a flattering one — it has decimal, multiply, divide AND a full
floating-point unit:

| | i960 (Model 2) | our V60 |
|---|---|---|
| ALM | **7,015** | **17,691** |
| source lines | 4,069 | 4,571 |
| modules | **16** | **1** |
| FP included | add, mul, div, sqrt, misc | yes |

Comparable source size, 2.5x the area — and the i960's *entire* FP unit fits
inside its 7,015 while our FP group **alone** is 2,984.

**So the cost is structure, not instruction count.** The i960 is decomposed with a
shared `i960_alu`, `i960_muldiv` and `i960_regs`; ours is one module with a
102-state FSM that spells arithmetic out inline per state, so nothing can be
shared. That is exactly why it measures **93% combinational** — 21,470 ALM of
logic against 1,591 of registers.

**The tempting fix is the wrong one.** Gating instruction families off (the way
`S32_V60_NO_FP` does) removes features to buy area, needs per-family evidence that
this game never uses them, and leaves the underlying waste in place. Sharing
datapaths keeps every instruction and attacks the actual cause. Reach for the
second before the first.

Caveat on doing it: the V60 is imported and carries a 29/29 unit suite. Any
restructuring is measured against that suite staying green, one shared structure
at a time, with a Quartus number per step — `SRCS_s32_v60` already exists so a
V60-only build makes each step minutes rather than half an hour.

**Does sharing cost speed? The sibling project measured it, and no.** Its i960
registered the register-file read and reported *"Cost: zero cycles. Same 65,630
cycles, same 3,870 retires"* with Fmax 25.29 -> 27.3 (+8%) and slack 0.451 ->
3.370. Cycles cannot suffer in a sequential FSM anyway — one state is active at a
time, so states that never coincide can share a unit for free.

**And the path it fixed is a description of ours**: *"read address through a
combinational 32:1 multiplexer, through the ALU and FP result muxing, into
writeback"*. So start there rather than with FP: it is small, contained, and has
cross-project evidence on the same device at a similar operating point. Note the
same commit is candid that the gain was less than predicted — the register read
was half the path — so expect incremental steps, each measured.

**Two inherited cautions.** When a restructuring appears to cost Fmax, check for a
FALSE PATH before redesigning: that project's decoder change measured a 27.44 ->
24.63 loss whose cause was a static path no cycle ever uses. And it fixed that
structurally rather than with an SDC exception, because *"a constraint that stops
being true fails silently, whereas this cannot rot"* — the same preference applies
here, where the SDRAM interface is already carrying unconstrained paths.

M10K is the binding resource: **101 blocks free** against the band buffer's ~51.
Reserves, in order of value: tile RAM and palette
are each held **twice** (80 blocks of pure redundancy, and the video side has 5:1
clock slack to interleave a CPU read); display lists to SDRAM (128 blocks,
sequential access, consumer not yet built); line buffers to MLAB (12 blocks for
~480 ALM — they use 17% of each block).
