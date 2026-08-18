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

### WITHDRAWN: a pair in window mode with hscr bit 15 clear draws NOTHING

**This is wrong and is the open bug.** It is kept in full because the RTL, the
reference model and this file all still carry it, and because the way it was
reached is the lesson.

What was claimed: `draw_common`'s inner `if (hscr & 0x8000)` has no `else`, so a
pair in window mode with that bit clear draws neither map.

```cpp
if (ctrl & 0x6000) {           // window mode
    if (layer & 1) return;     // the odd map never draws directly
    set_scrolly(both maps);
    if (hscr & 0x8000) { ...per-line draw... }   // and only here
} else { ...normal path, with the row mask... }
```

**There is an `else`, at `segaic24.cpp:418-456`**, and in it MAME splits the screen
into two rectangles and draws BOTH maps of the pair, one in each:

```cpp
} else {                                     // hscr & 0x8000 clear
  set_scrollx(both maps, -(hscr & 0x1ff));
  switch ((ctrl & 0x6000) >> 13) {
  case 1:                                    // VERTICAL split
    v = (-vscr) & 0x1ff;
    c1.max_y = v-1;  c2.min_y = v;
    if (!((-vscr) & 0x200)) layer ^= 1;
    draw(layer, c1);  draw(layer^1, c2);
  case 2: case 3:                            // HORIZONTAL split
    h = hscr & 0x1ff;
    c1.max_x = h-1;  c2.min_x = h;
    if (!(hscr & 0x200)) layer ^= 1;
    draw(layer, c1);  draw(layer^1, c2);
  }
}
```

The *measurement* below is right; the conclusion drawn from it was not. Attract
does set `ctrl` to `0x2000`-`0x23xx` on pair 2/3 — window mode 1 — with `hscr`
below `0x0200` so bit 15 is never set. That does not mean the pair is undisplayed.
It means the pair is drawn as a **vertical split at scanline `v`, tilemap 2 above
and tilemap 3 below** — which is a horizon. **That is the sky and the sea.**

Suppressing the pair instead paints the screen with palette 0, which is blue, at
whatever rate the game toggles the mode. The user identified this from the board
before the code was reread: the blue flashed at about the rate the text should
blink, and *"seems to me that the full maps are being selected instead"*.

The window decision uses the **pair's even** `hscr`, not each map's own, because
MAME only reaches that branch through the even map's draw call. That part holds.

**How to fix it**, in the order the reference actually exercises:

1. **mode 1, `hscr` bit 15 clear** — a per-**scanline** layer pick: `y >= v`
   selects the other map of the pair. Cheap, because the renderer is already
   per-scanline and `cur_line` is to hand. This is the sky and sea.
2. **modes 2/3, `hscr` bit 15 clear** — a per-**pixel** split at `x = h`. That is a
   column mask and can reuse the row-mask machinery.
3. **`hscr` bit 15 set** — the per-line H-scroll table at `0x4000 + 0x200*layer`.
   Nothing measured so far reaches it; do it last.

`tb_m1_video.cpp`'s reference model encodes the same misreading and must change
with the RTL, or the suite will hold the bug in place — which is exactly what it
did for 380,929 checks, below.

**Why rereading did not catch it, twice.** The first pass through `draw_common`
found the row-mask polarity bug and the `layer & 1` double meaning, and produced
this wrong rule in the same sitting. The second pass reproduced the wrong rule from
the notes rather than from the source. What broke it was neither pass: it was a
user looking at the board and matching the flash rate to the text blink rate.
**A rate is a measurement that a still frame cannot carry**, and the class of
evidence that had been relied on — single captured frames — cannot see a blink at
all. Several earlier "the text is absent" readings came from single frames and are
worth nothing.

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

## Tile RAM infers as dual-clock RAM, and Quartus calls its read-during-write
## behaviour UNDEFINED — 2026-08-17

From the build log, unprompted:

```
Warning (276027): Inferred dual-clock RAM node
  "...m1_main:main|m1_mainram:rams|tram_v_lo_rtl_0" ... The read-during-write
  behavior of a dual-clock RAM is UNDEFINED and may not match the behavior of
  the original design.
```

Both video-side tile RAM copies (`tram_v_lo`, `tram_v_hi`) and both palette
copies raise it. The CPU writes on `clk`, the video side reads on `vid_clk`, and
a simultaneous access to one address has no defined result on real silicon.

**Verilator models it as a clean read.** So this is a simulation-versus-hardware
divergence *by construction*, in the exact memory whose contents appear to be
missing on hardware — and no amount of simulation can show it. That makes it a
strong candidate rather than a proven cause; it has not been tested.

Note tile RAM is already **duplicated**, `tram_c_*` for the CPU side and
`tram_v_*` for the video side, precisely so each is one-write/one-read and fits
an M10K's two ports. So this is not a port-count overflow. It is the crossing.

### The selectivity fits it. The direction of the error does not. — 2026-08-17

This was argued in both directions before being settled, so both halves are here.

**For it**: the maps that read blank are exactly the maps being written. MAME's
own census shows tilemaps 2/3 constant at 4096 words at every sample — written
once at init, static after — while tilemaps 0 and 1 are rewritten every frame
(205 -> 315 -> 1675 -> 153 -> 663). Reads of a continuously written array collide;
reads of a static array never can. The sea renders perfectly and the text layers
read as empty, which is that split exactly.

An earlier dismissal of this — *"maps 2/3 fill perfectly, so the write path works,
so it cannot be memory"* — is a **non-sequitur** and is withdrawn. The warning is
about read-during-**write**; the content census measures what the video side
**reads**. "Maps 0/1 are empty" and "reads of maps 0/1 come back blank" are
different claims and the census cannot separate them, because the census reads
through the suspect path. Its zero is not the proof it was presented as.

**Against it**: the *direction* of the error is wrong. Read-during-write returns
whatever the array holds mid-write. A corrupted word is overwhelmingly non-blank,
and the census counts non-blank words — so corruption can only push the count
**up**, or change *which* tiles appear. It cannot turn several hundred non-blank
words into the `008 000` the board reports. That reading means the words are not
there to be read, or are never read at all.

So: a real hazard, worth closing on its own merits, but not the explanation for an
empty layer. The write census (row `1B`) is what separates the two, and it exists
because neither census alone can.

**The fix, when it is done**, is to move tile RAM to a single clock domain and
cross the CPU's writes in as `m1_cdc_port` already does for SDRAM. A single-clock
simple dual-port RAM has *defined* read-during-write — old data — which Quartus
and Verilator model identically. Registering the read does not help: the
corruption is inside the RAM block, not at the crossing.

## The write census: what the CPU wrote, against what the renderer read
## — 2026-08-17

Overlay rows `19`/`1A` count non-blank tile words the renderer **read**. Row `1B`
counts the words the CPU **wrote**, by tile-RAM region, per frame. Neither alone
can say whether an empty layer is a CPU fault or a memory fault; together they
can, and that is the only reason the row exists.

Counted on `m_req && m_we && sel_tileram` in `m1_main.sv` — upstream of the RAM,
so a fault inside the memory cannot hide from it. Regions are word address bits
14:13: maps 0/1, maps 2/3, the H-scroll table and scroll registers, the row masks.

**Cumulative was tried first and does not work.** The boot self-test writes and
reads back every word of tile RAM, so all four regions saturate at `FFF` long
before the game loop starts — simulation showed exactly that by frame 64. A
cumulative count cannot distinguish "written once at boot" from "rewritten every
frame", which is the whole question. It is reset on `vblank_irq` instead, latching
the completed frame, so it measures the game loop alone.

**The content census is upstream of window suppression**, checked because it would
otherwise be a confound: `layer_off` reaches only `lb_masked` in
`m1_tile_fetch.sv`, while the `tw_nonblank` pulse fires at `F_TILE` regardless. A
suppressed layer is still fetched and still counted. So the board's `008 000` is a
real "the fetched words were blank", not our own suppression hiding the fetch.

### The game loop never rewrites the tilemaps — 2026-08-17

The first thing the per-frame census measured, and it was not expected.
`make m1_frame FRAME_TRACE=1`, steady state from about frame 90:

```
F92 ... have=53,0,0,0 rtl_have=1624,0,0,0 wr=0,0,12,0 ctrl=0000,0000 ...
F93 ... have=53,0,0,0 rtl_have=1624,0,0,0 wr=0,0,24,0 ...
```

**Zero writes per frame to any of the four tilemaps.** The only tile-RAM region the
game loop touches is `0x4000-0x5fff` — the H-scroll table and the scroll registers
— at 12 to 24 words a frame. Tilemap 0 holds 1,624 fetchable non-blank words at
the same moment, so its content was written **once during init** and is static
after.

Two consequences:

1. **It closes read-during-write as the explanation.** There are no writes to
   collide with. Whatever makes the board's maps 0/1 read blank happens at or
   before init, not in the steady state that is on screen.
2. **It moves the question to the init-time writes.** Both the CPU-side copy
   `tram_c_*` and the video-side copy `tram_v_*` take the same write strobe, so
   the next discriminator is whether the board's init writes land at all — not
   whether the steady state corrupts them.

It also decided the shape of overlay row `1B`. Showing both tilemap regions would
read `000 000` on a *working* design, which cannot be told from a counter that does
not work, so the right field is the scroll region instead: a live control that
proves the counter and the game loop are running.

### The full-screen blue is tilemap 2 drawn opaque over an empty map — 2026-08-17

Not the backdrop, which is where it was looked for. Four numbers already measured
make the chain, with nothing new needed:

- `bd=0/190464` — **zero** pixels fall through to the backdrop, every frame
- tilemap 2 wins 180,790 of 190,464 pixels
- tilemap 2 holds no content, so every tile word reads `0x0000`: tile index 0,
  colour bits 0
- tile 0's pixels index **palette entry 0**, which is blue in Virtua Racing

So the blue is tilemap 2's **opaque category-0 pass painting palette 0**. Maps 2/3
draw their category-0 pass opaque — already recorded above as a state worth
recognising — and over an empty map that fills the screen with one colour.

This is why the backdrop counter reads zero while the screen is blue. The two
sources are indistinguishable on a photograph and land in different counters, and
the search went to the wrong one.

It also says what the flashing is: alternation between frames whose map reads
content and frames whose map reads blank. The board shows sky and sea part of the
time, so the content exists — the blue frames are the reads that came back empty.

### WITHDRAWN: tilemaps 1, 2 and 3 are empty in simulation — 2026-08-17

**Wrong, and wrong because the run was too short.** It was measured at frames 90 to
296 as `have=53,0,0,0` and reported as a divergence from MAME. The user objected
that the board plainly shows sky and sea, so the data must be there. It is.

Run to 3.4e9 cycles instead of 4e8 and tile RAM fills completely, at frame ~352:

```
  tram blocks: 0000:315 1000:648 2000:4096 3000:4096 5000:1 6000:48
```

**Those are MAME's numbers.** Map 0 315 against MAME's 205-1675 (315 is one of its
sampled values), map 1 648 against MAME's 648, maps 2 and 3 4096 each against
MAME's constant 4096. Plus a scroll register and 48 mask words. Our tile RAM
content is not a divergence at all — it is right.

So the earlier reading has one cause: **296 frames is not far enough in.** This is
the third time a board-versus-simulation comparison has been made at the wrong
simulation state, and the first two are recorded under "Instruments, and what each
cannot do". The instrument is fine; the run length was the fault, and there was no
check that the state had been reached.

Keep the 4x stride caveat from the withdrawn entry — `tram_content_census` samples
every fourth word, so its counts must be multiplied by four before comparing with
MAME. `have=58,144,1024,1024` at frame 381 is 232/576/4096/4096, which agrees with
the full-stride block census above.

### The whole failure reproduces in simulation at frame 381 — 2026-08-17

Once the run is long enough there is no need for a board at all:

```
F382 bd=175982/190464 win=11038,3060,0,0 have=79,144,1024,1024
     rtl_have=2520,4095,4095,4095 wr=252,0,24,144 ctrl=0000,2000
```

Read across it:

- `ctrl=0000,2000` — pair 2/3 is in **window mode 1**
- `rtl_have=...,4095,4095` — maps 2 and 3 hold and fetch full content
- `win=11038,3060,0,0` — and they win **zero** pixels
- `bd=175982/190464` — so **92% of the screen falls through to the backdrop**,
  which is palette 0, which is blue

That is the reported symptom, cause and effect on one line, and it is the window
suppression above: MAME would draw this pair as a vertical split, tilemap 2 above
scanline `v` and tilemap 3 below. Note the blue arrives by the backdrop here and by
tilemap 2's opaque pass at frame 296 — two different routes to palette 0, which is
why chasing the colour rather than the counter wasted time.

`wr=252,0,24,144` also corrects the "the game loop never rewrites the tilemaps"
finding above: it does, once it reaches this screen. 252 words a frame into maps 0/1
and 144 into the row masks. That reopens read-during-write as a hazard on the
maps that are being written — though it remains unable to explain a *low* non-blank
count, for the reason given there.


### FIXED, and measured on real game code — 2026-08-17

Same frame, `make m1_frame FRAME_TRACE=1 FRAME_CYCLES=3400000000`, before and after
removing `!win_hs` from the suppress term:

| | before | after |
|---|---|---|
| backdrop | `175982/190464` (92%) | **`0/190464`** |
| tilemap 2 wins | `0` | **`176366`** |
| tilemaps 0/1 wins | `11038, 3060` | `11038, 3060` |

The blue is gone and the sky/sea layer draws, with the text layers untouched.

It agrees with MAME term for term. `ctrl = 0x2000` gives `v = (-0x2000) & 0x1ff =
0`, so `c1` is the empty rectangle and `c2` is the whole screen; bit 9 of `0xE000`
is clear so `layer ^= 1` fires, and `draw(layer^1, c2)` is **tilemap 2 across the
entire screen**. 176,366 is exactly the screen less the 14,098 pixels layers 0 and
1 take. An earlier note in `m1_video.sv` had this backwards — "MAME draws tilemap 3
across the whole screen and tilemap 2 not at all" — because the swap was read the
wrong way round.

### The fixture had been hiding the bug, and the first report of that was wrong too

Reinstating `!win_hs` initially left all 380,929 checks passing, which was reported
as "this suite cannot discriminate the fix", with two mechanisms offered for why:
row-mask complementarity between layers 0/1, and `cat0` treating layers 2/3 as
opaque. **Both were invented to explain a result that had a much simpler cause.**

`tb_m1_video.cpp` set `tile_ram[0x5002] = 0x8000 | 0x1f8`. The faulty term was
`!win_hs || ...`, so with bit 15 set it was never evaluated and the bug was
unreachable from that fixture. The game keeps `hscr` below `0x0200` on every
tilemap, so the fixture was testing an input the hardware never presents. With the
bit cleared the suite fails **4,330 of 380,929** checks against the bug and passes
clean without it.

Two things came out of it, both kept:

- **A fixture that avoids a bug is indistinguishable from one that covers it.** The
  only way to tell is to break the RTL on purpose and watch the count move. That is
  now done for this fix rather than asserted.
- `tb_m1_video` prints a **`layer wins`** line and **fails** if any tilemap never
  won a visible pixel. A layer that wins nothing is a layer the suite cannot test,
  and that had been true silently.

Still open and deliberately not folded in: `cat0` treats layers 2 and 3 as opaque
unconditionally, so a layer with its `vscr` disable bit set still paints. MAME's
`if (vscr & 0x8000) return;` skips it before any category decision. The RTL and the
reference agree, so the suite cannot see it.

### Modes 2/3 are the TEXT BLINK, and they are 7.8% of frames — 2026-08-17

Measured over a full 2,478-frame run, every `ctrl` value the game selects:

| `ctrl` (pair 0/1, pair 2/3) | frames | what it means |
|---|---|---|
| `0000,2000` | 1,898 | pair 2/3 in **mode 1** — fixed |
| `0000,0000` | 336 | no window mode |
| `4000,2000` | **194** | pair 0/1 in **mode 2**, pair 2/3 in mode 1 |
| `03xx,2000` etc. | 14 | pair 0/1 normal with a vscroll, pair 2/3 mode 1 |

So **mode 1 covers 85% of frames** and is what the fix addressed. **Mode 2 on pair
0/1 covers 7.8%** and is still suppressed. Pair 0/1 is the pair the text lives on.

On one of those frames, before the fix:

```
F1936 bd=190080/190464 win=0,0,0,0 have=16,768,1024,1024
      rtl_have=552,4095,4095,4095 ctrl=4000,2000
```

All four layers win nothing and 99.8% of the screen is backdrop, with every map
holding content. After the fix pair 2/3 draws on these frames and pair 0/1 still
does not — so the sky and sea are steady and **the text disappears on 8% of
frames**. That is the "coin and other text flash on and off" reported from the
board, and it now has a number.

**What it needs.** MAME, same `else` branch, cases 2 and 3:

```cpp
h = hscr & 0x1ff;
c1.max_x = h-1;  c2.min_x = h;
if (!(hscr & 0x200)) layer ^= 1;
draw(layer, c1);  draw(layer^1, c2);
```

A per-PIXEL split at x = h, not per scanline, so `win_suppress` cannot carry it.
The natural home is `m1_tile_fetch`: it writes the line buffer four pixels at a
time with a 4-bit `lb_masked` and knows its own x, so each of the four bits can be
set from `x < h` against which side this layer owns. The row-mask path is 8-pixel
granular and cannot be reused directly, but it is the same insertion point.

### And in window mode BOTH maps take the EVEN map's scroll — 2026-08-17

Found while planning the modes 2/3 work, from the same branch:

```cpp
set_scrolly(layer, vscr & 0x1ff);    set_scrolly(layer|1, vscr & 0x1ff);
set_scrollx(layer, -(hscr & 0x1ff)); set_scrollx(layer|1, -(hscr & 0x1ff));
```

`vscr` and `hscr` there are the **even** map's, because `if (layer & 1) return;`
runs first and only the even map ever reaches this code. We pass each layer its
own, so the odd map of a window pair scrolls wrongly.

Both values are already latched — `ctrl_r` **is** the even `vscr` and `hctrl_r` the
even `hscr` — so the fix is two muxes at the fetcher's ports:

```systemverilog
.hscr(win_mode ? hctrl_r : hscr_r),
.vscr(win_mode ? ctrl_r  : vscr_r),
```

`vscr` bit 15 rides along correctly rather than by accident: in window mode MAME
only ever tests the **even** map's disable bit, because the odd map returns before
the check. So an odd map cannot be disabled on its own in window mode, and passing
`ctrl_r` reproduces that.

**Invisible in attract today**, which is why it has not shown up: `ctrl = 0x2000`
gives `v = 0`, so only the even map draws and the odd map's scroll never matters.
It matters as soon as `v != 0`. Recorded rather than fixed on its own, because it
belongs with modes 2/3 and both touch the same ports.

## The build with the window fix: 29,434 ALM, 452 M10K, and -0.019 ns — 2026-08-17

`bash tools/mister_project.sh && cd build/mister && quartus_sh --flow compile
Model1`, Quartus 17.0.0 Lite, 5CSEBA6U23I7. Successful, 0 errors, 138 warnings.
`build/mister/output_files/Model1.rbf`, 4,118,248 bytes.

| | this build | free |
|---|---|---|
| ALM | 29,434 / 41,910 (70%) | 12,476 |
| M10K | 452 / 553 (82%) | **101** |
| DSP | 50 / 112 (45%) | 62 |
| registers | 23,433 | — |

M10K at 101 free matches what was already recorded as the binding resource, and
the band buffer wants ~51 of them. The `26,663 ALM / 409 M10K` figure in CLAUDE.md
is **stale** — it predates the row-mask, window and census work — and the numbers
here supersede it.

### Worst setup slack is -0.019 ns, and it is the SDRAM address path

```
From  emu:emu|m1_sdram:sdram|xfer_addr[2]_OTERM175
To    emu:emu|m1_sdram:sdram|sd_a[12]
Slack -0.019 (VIOLATED)
```

One violated path of five reported, the next two at +0.029 and +0.063 on the same
bus. **It is inside `m1_sdram` at both ends**, so the window change does not touch
it; the previous +0.401 ns was on a design ~2,800 ALM smaller and this is placement
pressure on an interface that has no constraints of its own.

**The pack warning is NOT the cause of this path, and saying so was wrong.** The
fitter does report it sixteen times —

```
Warning (176279): Can't pack register node "...|m1_sdram:sdram|sd_a[8]" into I/O
pin "SDRAM_A[8]". The node cannot simultaneously use clear and load signals.
```

— and `sd_a` is indeed reset to `'0` at `m1_sdram.sv:433` while being
conditionally loaded elsewhere, which a Cyclone V I/O register cannot do. But the
violating endpoint `sd_a[12]` **is** packed: its location is
`DDIOOUTCELL_X40_Y81_N10`. The warning applies to other bits. Attributing the
violation to it was a guess from the warning text, made before reading the path.

**What the path actually says**: 9 logic levels, 12.899 ns of data delay, **73% of
it interconnect**. Two hops dominate:

```
sd_a[0]~3 -> sd_a[0]~4      1.355 ns   X82_Y21 -> X51_Y21
sd_a[0]~4 -> sd_a[12]|ena   4.161 ns   X51_Y21 -> DDIOOUTCELL_X40_Y81
```

One wire is **4.161 ns, a third of the whole budget**, carrying the enable from
logic at row 21 to an I/O cell at row 81. The SDRAM pins are fixed by the board, so
that distance is the fitter having placed the control logic sixty rows from the
pins it drives, on an interface with no constraints telling it the path matters.

**So the area lever is not the remedy it looks like.** Freeing the V60's FP group
is -2,984 ALM and would give the fitter room to place that logic nearer the pins —
but nothing forces it to, and the result is only knowable after a 25-minute build.
It is a lottery ticket, not a fix.

**The deterministic fix is the 9 combinational levels feeding `sd_a`** — `sel~1`,
`sel~5`, `Mux118~0`, `always3~1/2`, `sd_ba~1`, `sd_a[0]~3/4` — the state machine
computing its address mux in the same cycle it drives the pins. Registering the
address select one cycle earlier removes most of them. Dropping the reset on the
outputs is still worth doing for the other sixteen bits, but it is a separate,
smaller thing.

Not done here: it belongs to "close the SDRAM interface", needs its own build to
measure, and `m1_sdram`'s 74,729-check suite has to be re-run against it. 19 ps at
the slow 85C corner is within the model's own noise and the board has run with
this interface unconstrained throughout, so the `.rbf` is flashable — but it is not
clean and is not recorded as if it were. It will also get worse as M2 and M3 grow
the design, which is when this becomes a requirement rather than a note.

## The window fix WORKS on hardware, and the blue flash is a different fault
## — 2026-08-18

Read off the board's own overlay, from a 30 fps video, comparing a picture frame
against a blank one in the same second.

**The fix is confirmed on hardware.** Row `13`, tilemap 2's visible pixels, reads
`02E800` = **190,464 — the entire screen** — where it read `000000` before, and the
sky and sea in those frames are real tilemap 2 content rather than a flat fill. Row
`11` reads `000005`, and 190,459 + 5 = 190,464 exactly, so there is no backdrop at
all. That defect is closed.

### The blue flash is periodic, and it is the game clearing the screen

Measured from the video by texture in the picture region only — a blue-pixel count
cannot see it, because the correct picture is *also* blue:

```
blank runs (video frames): (12,14) (26,28) (39,42) (53,55) (66,69) (80,82) ...
112 blank frames of 460, period ~13.5 frames at 30 fps
```

**0.45 s period, ~24% duty, about 7 core frames at a time.** The user timed it at
"every 1/2 second" before any of this was measured, and also pointed out that 30 fps
cannot resolve it cleanly — both correct, and the second is why earlier metrics on
the same video found nothing.

| overlay row | picture frame | blank frame |
|---|---|---|
| `16` pair 2/3 ctrl | `002000` | **`000000`** |
| `1A` map2, map3 content | `FFFFFF` | **`000FFF`** |
| `11`-`14` wins | `5, 0, 190459, 0` | **all zero** |
| `19` map0, map1 content | `008000` | `000000` |
| `1B` writes | `003 00C` | `000 008` |

**Window mode is OFF during the blank**, so the window logic is not involved. Map 2
reads empty, its category-0 pass is opaque, so it paints palette 0 over the whole
screen and hides map 3 — which still holds `FFF`. That is the blue.

Rows `19` and `16` change **in the same frame**, which the user established by
watching them: the game writes `ctrl` and the tile content as one operation, so the
screen is torn down and rebuilt each cycle rather than one register drifting.

### Three things this rules out

1. **The write path is innocent.** Row `1B` matches simulation exactly on both
   frames — `003 00C` against `wr=3,0,12,0`, and `000 008` against `wr=0,0,24,0`.
   Read-during-write is now dead on evidence rather than on the arithmetic argument
   used earlier, and the CPU writes maps 0/1 on hardware just as it does in sim.
2. **The V60 is not being reset.** Row `01`, instruction fetches, is monotonic
   across the blanks: `7A7D..` -> `7D4DE6` -> `88638.`. It fetches straight through.
3. **Simulation does not reproduce it.** Its 336 `ctrl=0000,0000` frames are ONE
   contiguous run at frames 1-336 — boot — and it never returns. The board goes back
   there every 0.45 s indefinitely.

### So maps 0/1 are empty because the game never finishes drawing them

Only **8** non-blank words reach map 0 before the next teardown, against
simulation's 552-2,520 at the same `ctrl` state. The missing text is not a memory
fault and not a compositing fault: the game is being restarted before it draws.

**Cause unknown, and this is a CPU-side question now.** The overlay's PC row cannot
help — it samples at the same point every frame and reads `FFE59C` blank or not.
What is needed is the PC **at the instant of the teardown**, latched on the `ctrl`
`0x2000 -> 0x0000` transition, with a counter. That names the code and makes it
traceable in the ROM. Candidates not yet tested: a self-test or synchronisation wait
timing out, and the published DPRAM bytes — the DSWs at `0x0b`-`0x0d` and the
`0x03`-`0x07` block whose contents are recorded as unknown — since simulation feeds
fixed inputs and the board reads real ones.

## Modes 2/3 verified on real game code — 2026-08-18

`make m1_frame FRAME_TRACE=1 FRAME_CYCLES=3400000000`, the full 2,478-frame run,
before and after the column split. Same frame, everything else identical:

```
before   F1936 bd=0/190464 win=0,0,190464,0    ctrl=4000,2000
after    F1936 bd=0/190464 win=2972,0,187492,0 ctrl=4000,2000
```

**Tilemap 0 wins 2,972 pixels where it won none.** That is the text pair drawing on
the frames that previously blanked it.

Across the whole run:

| | before | after |
|---|---|---|
| blue frames (`bd` > 100k) | 7 | **7** |
| mode-1 frame `F1900` wins | `11038,4648,174778,0` | **identical** |
| tilemap 0 pixels, total | 46,641,138 | **47,250,016** |

The 7 blue frames are the legitimate boot screen-clear in both, so nothing
regressed. The mode-1 frames are byte-identical, which is the point: `win_vsplit`
gates the two paths apart and mode 1 was already correct. The extra 608,878 pixels
divided by 2,972 a frame is ~205 frames, against the 194 mode-2 frames measured —
consistent.

**Note what this does NOT fix.** The 0.45 s teardown is untouched: the game still
restarts its screen build, so on hardware the text will draw on more frames but the
underlying restart remains. Modes 2/3 was a real defect worth closing on its own;
it is not the open one.

## THE COPROCESSOR'S DATA ROM WAS NEVER IN THE MRA — 2026-08-18

The board's 0.45 s screen teardown, traced to its cause. The instrument that found
it was overlay row `03`, added the night before precisely because nothing measured
this.

### What the board said

```
02  800 B9A     microcode: 2048 words, checksum B9A
03  FFF 000     command FIFO: pushes saturated, pops ZERO
10  000049      TGP program counter, stuck at 0x49 across two videos minutes apart
```

Row `02` **kills the microcode theory outright**: `0x800` is a complete 2,048-word
load, and `B9A` is exactly the folded checksum computed from `315-5573.bin`
independently — so the microcode is complete AND correct. The zip diagnosis of the
previous night was wrong, as the user suspected when asking why a missing file
produced no error.

Row `03` is the fault: **the V60 pushes commands and the TGP never pops one.** The
FIFO is 16 deep and **a full FIFO halts the V60** — so the CPU stalls, the game
gives up on its screen build and restarts it. That is the teardown.

### Why the TGP was stuck

`make m1_tgp`, on this same microcode, reaches `pc=0043`, blocks correctly on an
empty FIFO, and **pops 11 of 11** when commands are offered. The pop logic works.
The board sits six instructions further at `0x49`, because its FIFO is *not* empty
— it got past the read and stopped at the next thing.

That next thing is the data ROM. MAME's `copro_io_map` puts the math units at
`0x0020-0x002b` and the data-ROM window at `map(0x8000, 0xffff).r(copro_data_r)`,
and `findings.md` already recorded — measured through MAME's own IO tap — that the
data ROM is **read before any math unit**.

### The three regions, and which we loaded

`vr` needs, beyond the microcode:

| MAME region | size | files | in our MRA |
|---|---|---|---|
| `copro_data` | 2 MB | `mpr-14898.39` .. `mpr-14901.42` | **NO** |
| `copro_tables` | 256 KB | `opr14742.bin`, `opr14743.bin` | **NO** |
| `other_data` | 512 KB | `opr-14744.58` .. `opr-14747.63` | n/a — computed in `fp_div`, no port, not in the ROM set |

All six of the first two are present in the user's `vr.zip`. Neither region was in
the MRA.

### The part that makes this unambiguous

**`tools/build_rom_image.py` — which feeds SIMULATION — has placed both regions
correctly all along**, `copro_data` at byte `0x600000` and `copro_tables` at
`0x800000`, matching `COPRO_DAT_BASE` and `COPRO_TBL_BASE` in `m1_integrated.sv`
exactly. Its own comment says the layout was chosen so that *"the MRA needs no
padding"*.

So the layout was designed for the MRA to carry these, and **the MRA was never
updated**. Simulation had the data ROM; hardware never did. That is the whole
board-versus-simulation divergence chased across two sessions:

- sim: microcode + data ROM + tables -> TGP runs -> no teardown, 0 blue frames
- board: microcode only -> TGP stalls at 0x49 -> FIFO fills -> V60 halts -> teardown

### The fix, and what it is not

Six parts appended to the MRA's index-0 stream at `0x600000` and `0x800000`, with
the same interleaves the image builder uses — four-way byte interleave for
`copro_data`, two-way 16-bit for `copro_tables`. **No RTL change and no rebuild:
the MRA is a data file on the SD card**, so this was deployed and reloaded in
minutes.

**A lesson worth more than the fix.** Two independent loaders existed for the same
data — `build_rom_image.py` for simulation and the MRA for hardware — and only one
knew about two of the three regions. Nothing checked them against each other, and
the difference presented as a hardware bug for two sessions. The overlay row that
finally caught it exists only because the user asked why a missing ROM file would
not produce an error.

## The coprocessor stall REPRODUCES IN SIMULATION — 2026-08-18

The data ROM was necessary and **not sufficient**. With `copro_data` and
`copro_tables` both present, `make m1_frame FRAME_TRACE=1` settles from frame 85
onwards at:

```
F95 ... tgp=1/0/0049 io=0000/000 tbl=00 dat=00 ... pc=fe02bc
        ^^^^^^^^^^^^ pushes=1, pops=0, TGP pc = 0x0049
```

**`0x0049` is exactly the PC the board reports**, in two videos minutes apart. So
the stall is not a hardware effect at all and no board is needed to work on it.

**And it is not waiting on memory.** `io=0000/000` is the coprocessor's IO port
idle with no read, write or ack; `tbl=00 dat=00` are the table and data-ROM ports
with no request outstanding. It sits at `0x49` with a command queued in the input
FIFO and simply does not take it.

That matters because it eliminates the whole class of explanation the data ROM
belonged to. The remaining possibilities are narrow:

- the TGP never asserts its FIFO read at `0x49` — it is doing something else
- it asserts it and the handshake fails

`m1_copro_if` drives `fifo_in_valid = !fin_empty` and the TGP pops on
`fifo_rd && fifo_in_valid`, so with one word queued `valid` must be high. And
`m1_tgp`'s own suite pops **11 of 11** when its valid is driven. Both halves work
in isolation, which points at what the microcode is actually executing at `0x49`
rather than at the plumbing.

**Note the push counts differ between board and simulation**: the board's
saturates (`FFF`, and `010` = the full 16-deep FIFO once the CPU halted), while
simulation pushes **once** and stops. Same stall, different amount of work offered
before the CPU gives up. Not yet explained.

### What this says about the earlier fix

Loading `copro_data` was still right — `tb_m1_frame`'s own header records that
stopping at the V60 image "leaves the TGP reading 0xFFFF and the V60 stalls" — but
it was not the cause of the teardown. The teardown is this stall, and it was
present in simulation the whole time behind a push count too low to fill the FIFO.

**M0 exit criterion 2 is the relevant gap.** `mb86233_core`'s baseline says
"microcode-driven lockstep still owed": every opcode is fuzz-verified against MAME
individually, and the core has **never been run in lockstep on real microcode**.
A single wrong opcode on the path through `0x49` would produce exactly this and
would be invisible to every test that currently passes.

## WITHDRAWN: "the TGP never drains its command FIFO" — 2026-08-18

Stated this morning as the diagnosis, from overlay row `03` reading `FFF 000`. It
is wrong, and the counter is why.

**`dbg_fifo_pops` counts the V60 reading RESULTS out of the OUTPUT FIFO**, not the
TGP taking commands from the input one. It increments on `!we && sel_fifo && !a1`,
advancing `fout_rd`. The TGP's own consumption is
`if (fifo_in_pop && !fin_empty) fin_rd <= fin_rd + 1'd1` and **was not counted at
all**.

So a zero there is **correct behaviour**, and this file already said so: *"does the
V60 read the coprocessor back — **never**, in 2,500 accesses."* The row was built
on a wrong assumption about what the signal meant, and then its expected value was
read as a fault.

**The trace shows the opposite of the claim.** With the FIFO read strobe added:

```
F35  tgp=0/0/0043  frd=1   FIFO empty   correctly blocked on an empty FIFO
F37  tgp=1/0/0049  frd=1   pushes=1     PC MOVED 0x43 -> 0x49
```

The TGP asserted its read, took the command, advanced, and is now blocked at `0x49`
waiting for the next one — which is exactly right when only one command has been
sent. Nothing is stuck.

So the "full FIFO halts the V60" chain is unsupported. `FFF` is a saturating count
of total pushes, not FIFO occupancy, and it does not mean full.

**What still holds** from that episode: `010` — sixteen pushes, the exact FIFO
depth — read after the microcode was accidentally dropped. With no program the TGP
genuinely never drains, the FIFO genuinely fills, and the V60 genuinely halts. That
reading was real; the one before it was not.

**Fixed**: `dbg_fifo_drains` now counts `fifo_in_pop`, and overlay row `03`'s right
field shows it instead. Needs a rebuild to reach the board.

**The lesson is the same one twice in a day.** A counter was trusted for what its
name suggested rather than for what it increments on, and a whole diagnosis was
built on it. The previous instance was `dbg_layer_have` measuring reads while being
read as content. Check the increment condition, not the identifier.

## WITHDRAWN: the copro data ROM fixed the teardown — 2026-08-18

It did not. Claimed after the MRA fix on a video analysis that was wrong twice
over: the crop offset was changed for a differently framed video and ran off the
right edge of the picture, and the blank test required texture to be exactly zero
when blank frames read 1-2 from camera noise. It reported "0 blank frames in 466".
The user said the flashing was still there every half second, and it is:

```
low-texture runs: (2,4) (16,18) (29,31) (43,45) (57,59) (70,72) (84,86) ...
102 of 466 frames, period ~14 at 30 fps
```

Same 0.45 s period, same ~22% duty, unchanged by the data ROM.

**Two crop mistakes in one day on the same instrument.** The rule that came out of
the first one — measure texture in the picture region, not blueness, because the
correct picture is also blue — is right, but a fixed crop is not portable between
videos shot at different distances. Derive the picture region from the frame, or
check the crop lands on the picture before trusting the result.

### What the data ROM fix DID buy, measured

The coprocessor is now provably healthy, which it was not before:

| overlay | before | now |
|---|---|---|
| `02` microcode | `800 B9A` | `800 B9A` complete and correct |
| `03` pushes / **drains** | `FFF 000` (mislabelled) | **`FFF FFF`** — thousands of commands taken |
| `0F` retires | `FFFF` pinned | `0058D7` -> `00FEBD` over 5 s, churning |

And all three hold **during the blank frames too**. So the coprocessor executes
continuously and consumes work throughout the teardown, which eliminates it as a
cause rather than leaving it a suspect. That is worth the fix on its own, and the
microcode-dropped experiment separately proved the TGP does halt the V60 without a
program — that reading was real.

### The teardown's signature, unchanged

```
picture   16=002000  1A=FFFFFF  13=02E7FB  11=000005
blank     16=000000  1A=000FFF  13=000000  all wins zero
```

During the blank, pair 2/3's `ctrl` reads 0 and **tilemap 2's content census reads
000 while tilemap 3 still reads FFF**. Map 2 is words `0x2000-0x2fff` and map 3
`0x3000-0x3fff`, so whatever happens is confined to one 4,096-word map.

**And row `1B` reads `000` tilemap writes on every frame sampled**, blank or not,
which does not sit with map 2's content changing. Either the writes come in a
burst no sampled frame caught, or the content is not changing and the FETCH is
reading somewhere else. That contradiction is the next thing to resolve, and it is
resolvable in simulation — the blank state reproduces there (`ctrl=0000,0000`,
`have=0,0,0,0`, `bd=190080`) at frames 328-332.

## The blue detector in simulation was wrong, and the board never leaves boot
## — 2026-08-18

### The detector

Blue frames were counted in simulation as `bd > 100000` — backdrop share. That is
the wrong test and this file already said why: **the full-screen blue is tilemap 2
drawn opaque over an empty map, and `bd` reads 0 while it happens.** The mechanism
was written down and then the wrong counter was used to look for it anyway.

The correct test is layer 2 covering the screen while its content census is empty:

| test | blue frames of 407 |
|---|---|
| `bd > 100000` | 7 |
| `win[2] > 150000 && rtl_have[2] == 0` | **289** |

So "simulation shows no blue" was false. It is blue for most of boot.

### What the correct test shows

```
frames 1-39     not drawing yet
frames 40-328   BLUE, 289 frames contiguous
frames 329+     picture, and it never returns
```

Over the full 2,478-frame run: **289 blue, 2,189 picture**, the blue one contiguous
block during boot. The board oscillates between the same two states every 0.45 s,
indefinitely.

### And the PC separates them

| | sim, blue | sim, picture | board |
|---|---|---|---|
| `pc` | `ffe59c` | `fe02bc` | **`ffe59c` always** |

`0xffexxx` is the boot ROM; `0xfe02bc` is game code. **The board's V60 never leaves
the boot state that simulation passes through in about five seconds.** It keeps
re-running boot's screen build, which is why tilemaps 0/1 never accumulate the text
and why the blue returns on a cycle.

That reframes every symptom chased today. The missing text, the missing scrolling
and the periodic blue are one thing: the machine is stuck in boot. The video path,
the window modes, the memory and the coprocessor are all doing what they are told.

**What is NOT the reason**, all measured today:

- the coprocessor — microcode complete and correct, executing continuously,
  draining thousands of commands, *including during the blank frames*
- the copro data ROM and tables — now loaded, verified byte for byte
- the command FIFO — drains saturated, so it is not full and not halting the CPU
- the memory write path — row `1B` matches simulation exactly
- a V60 reset — instruction fetches are monotonic across the blanks
- input divergence — board idle values identical to the testbench's

**The open question** is what boot waits on that the board does not get, given the
I/O board is replying (`0B` climbs) and memory and the coprocessor both work. The
PC row samples at the same point every frame so `ffe59c` is a frame-synchronised
wait, not necessarily a hang — the useful next instrument is a PC histogram or a
capture of the PC at the moment the screen tears down, which the frame-synchronised
sample cannot give.

## The SDRAM read phase is settled: CL+2, and the others fail hard — 2026-08-18

Swept from the OSD, `O[5:4]`, all four settings. **CL+3, CL+4 and CL+5 all hang on
the test screen.** Only CL+2 boots.

That is a useful negative. A marginal capture phase would show as occasional wrong
data — rare bad fetches, wrong branches, the sort of thing that could explain the
board diverging from simulation on identical code. This is not that: a wrong phase
reads a *different word entirely*, the machine fails its own self-test, and the
failure is immediate and total rather than intermittent.

So the setting is right, its margin is not the question, and the periodic teardown
is not a memory-timing effect. Do not sweep it again.

Cost: one menu click, no build. It should have been run hours earlier — it was
recorded as an available free experiment in `HANDOFF.md` and repeatedly deferred in
favour of instrument builds.

### Turning a V60 address from the overlay into ROM contents

`tools/rom_at.py` takes an **SDRAM word address**, not a V60 address, and rejects
a V60 one as "past the end of the image" — which reads like the address is wrong
rather than in the wrong units. The map is `m1_decode.sv`'s packed layout:

| V60 | stream | word address |
|---|---|---|
| `0x200000-0x2fffff` ROMX | `0x000000` | `(0x000000 + (a - 0x200000)) >> 1` |
| `0xf80000-0xffffff` ROM0 | `0x100000` | `(0x100000 + (a - 0xf80000)) >> 1` |
| `0x100000-0x1fffff` banked | `0x180000 + bank*0x100000` | `(that + (a - 0x100000)) >> 1` |

So the PC the board reports on row `00`:

```
V60 0xffe59c -> word 0xbf2ce -> 885a 8975 8976 ea6a f4e4 0200 0070 e0e2
```

Real code in the boot ROM, and simulation sits at the same address during its own
boot phase — so the address is not itself suspicious. What differs is that
simulation leaves and the board does not.
