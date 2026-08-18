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
| does the V60 read the coprocessor back | it must, to collect results | **constantly, 710,722 FIFO reads per 600 frames** — see the correction below. The "never" here was a census of the wrong address space. |
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

The row was built on a wrong assumption about what the signal meant, and then its
expected value was read as a fault.

**But "a zero there is correct behaviour" — which this entry originally concluded,
citing *"does the V60 read the coprocessor back — never, in 2,500 accesses"* — is
ITSELF WRONG, and that is corrected further down: the V60 reads the coprocessor
back constantly, through its I/O space. A zero in `dbg_fifo_pops` is a real gap.**
Two wrong readings of the same counter, in opposite directions, from two different
mistakes.

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

## WITHDRAWN: "the board never leaves boot" — ROM0 is where the game LIVES
## — 2026-08-18

MAME, tapped on the V60's program space and bucketed by region, 30 s of attract:

```
f=1800 total=240,967,154  rom0=89.7%  romx=0.3%  bank=0.3%  other=9.6%
```

**The real machine spends ~90% of its time in ROM0.** `0xf80000-0xffffff` holds
`epr-14878a.4` and `epr-14879a.5` — the main program — not merely a boot vector.
So a PC of `0xffe59c` says nothing about being stuck.

And the comparison it rested on was worse than unsupported. Simulation's two states
were read as "`ffe59c` = boot ROM" against "`fe02bc` = game code" — **both are
inside ROM0**. Two addresses in the same ROM, presented as two different phases of
execution. There was never a boot-versus-game distinction in that data.

### What that does to the instrument just built

Rows `06`/`07` count cycles in ROM0 against everything else, on the reading that
"mostly ROM0" would mean a boot loop. That interpretation is dead. The rows are
still worth having, but only **against this reference**: the real machine is
`89.7 / 10.3`, so a board reading near that is behaving normally and one reading
`99.9 / 0.1` is genuinely pinned. Without the oracle number the rows would have
been read as damning whatever they said.

Row `04` — the PC latched at the teardown edge — is unaffected and remains the
useful one, because it names a specific instant rather than a distribution.

### The rule this keeps proving

`CLAUDE.md` says: when something is unknown, run MAME, do not reason about it. Four
wrong causes today — the M10K crossing, the FIFO halt, the copro data ROM, and now
this — every one reasoned from a plausible mechanism, and this one was refuted by a
five-minute Lua script that could have been written at any point. The instrument
was available the whole time.

## The board's PC distribution is CORRECT — and row 04 cannot do its job
## — 2026-08-18

Board readings from the instrument build:

```
04  FFE46d, last three digits constantly changing
05  001FAB, rising            ~8,100 teardowns, ~3/s over 43 minutes
06  unreadable, churning fast
07  000000, always
```

### 07 = 0 is right, not a fault

The first reading of `07 = 000000` — zero cycles outside ROM0 — looked like a hard
divergence from the MAME reference of 10.3%. It is not, and the reference was
measuring something else: that tap counted **all program-space accesses**, data
reads included, while rows `06`/`07` count **the PC**. Measured properly, sampling
MAME's PC alone:

```
samples=3600  rom0=3600  other=0   0.00% outside ROM0
```

**The real machine's PC is 100% in ROM0 too.** The board matches the oracle
exactly. That would have been the fifth wrong cause of the day, and the only thing
that stopped it was checking that the two instruments measured the same quantity
before comparing them.

### Row 04 captures the wrong event

It latches the PC when `dbg_ctrl[1]` changes — and `dbg_ctrl[1]` is latched by the
**video renderer** when it reads tile RAM, once per layer per scanline. The CPU may
have written `ctrl` up to a frame earlier. So the captured PC is wherever the CPU
happens to be when the *renderer notices*, which is why it scatters across
`FFE4xx` rather than naming one instruction.

A design error, not a wiring one: the event is in the video domain and the question
is about the CPU domain. The instrument that answers it watches the CPU's own write
to tile RAM word `0x5006` — pair 2/3's `ctrl`, which is also tilemap 2's `vscr` —
and latches the PC there.

**Row 05 is sound** and worth keeping: ~8,100 teardowns at about 3 per second over
43 minutes, which matches the observed flash rate and confirms the event is real
and periodic rather than drifting.

## The teardown is the GAME toggling ctrl, and the code is named — 2026-08-18

Traced in simulation by watching the CPU's own writes to tile RAM word `0x5006`,
which is pair 2/3's `ctrl` and tilemap 2's `vscr`:

```
pc=ffe27a   145 writes
pc=ffe466   144 writes
data:  287 x 0x0000,  4 x 0x2000
```

**Two routines alternate it**, and the board's row `04` — the PC latched at the
teardown — read `FFE46d` churning in the low digits. `ffe466` is one of the two
writers, so that capture was pointing at the right code despite being latched on
the video-side observation. The earlier note calling it noise was too pessimistic;
the delay is evidently small enough that the PC is still inside the routine.

**So the teardown is not a fault.** The game deliberately toggles window mode off
and on, clearing and refilling tilemap 2 in step with it. Roughly 3 times a second,
which is the observed flash rate.

### Which makes the real question much narrower

**When `ctrl = 0x0000` and tilemap 2 is empty, why do we paint the screen blue
when MAME does not?**

With window mode off, `draw_common` takes the normal path and all four tilemaps
draw. Maps 2 and 3 draw their category-0 pass **opaque** — recorded here already —
so an empty map 2 covers all 190,464 pixels in palette 0, which is blue. MAME
plainly does not do that, so something suppresses map 2 there that we do not
reproduce. Candidates, in the order the source suggests:

1. **the row mask** — the normal path applies it and the window path does not, so
   this is the first place a difference of exactly this shape would live
2. **`vscr` bit 15, layer disable** — `draw_common` returns before drawing, and
   this design's mixer treats maps 2/3 as opaque *unconditionally*, so a disabled
   map still paints. Recorded as a suspected bug in `tb_m1_video.cpp` and
   deliberately not folded into the window change
3. a priority rule in the category-0 pass

Candidate 2 is already written down as suspected and never chased. It would produce
exactly this symptom.

**This is a compositing question with a definite oracle answer**, which is a much
better position than any of the four causes named and withdrawn today. The next
step is a MAME tap on `tile_ram[0x5006]` and the row-mask words at the moment `ctrl`
goes to zero, to see what the reference has set that we ignore.

## The reference sets window mode ONCE; the board toggles it forever — 2026-08-18

MAME, polling `tile_ram[0x5006]` every frame for 2,400 frames of attract:

```
f=600   ctrl==0 on 273 frames, window mode on 327
f=1200  ctrl==0 on 273 frames, window mode on 927
f=1800  ctrl==0 on 273 frames, window mode on 1527
f=2400  ctrl==0 on 273 frames, window mode on 2127
```

**`n_zero` stops at 273 and never rises again.** Every `ctrl == 0` frame is inside
the first ~300; from then on the reference holds window mode on permanently. It
does not toggle.

The board toggles it about three times a second, indefinitely, via the two routines
at `ffe27a` and `ffe466`. Simulation converges the same way MAME does — the long
runs settle at `ctrl=0000,2000` for 1,898 frames of 2,478.

### So the compositing question was the wrong question

The previous entry narrowed this to "when `ctrl=0` and tilemap 2 is empty, why do we
paint blue when MAME does not", and listed the row mask, `vscr` bit 15 and priority
as candidates. **All beside the point.** The reference is never in that state after
boot, so there is nothing to compare against and nothing in the mixer to fix. Our
renderer is faithfully drawing a state the game should have left.

Note `vscr` bit 15 was already ruled out by arithmetic and this makes it moot:
`ctrl` **is** tilemap 2's `vscr`, so a `ctrl` reading of `0x0000` means bit 15 is
clear and the layer is enabled by definition.

### What is actually left

**Why does the board keep re-entering the `ctrl = 0` path when MAME and simulation
both leave it after boot?** Hardware only — neither oracle reproduces it. Everything
downstream of that is a symptom: the periodic blue, the missing text and the absent
scrolling all follow from the game repeatedly restarting its screen build.

What is already excluded by measurement, and should not be re-derived: the
coprocessor (healthy, draining, executing during the blanks), its microcode and
data ROM (complete, correct, verified byte for byte), the command FIFO, the SDRAM
read phase (CL+2 is right, the others fail hard), the memory write path, a V60
reset, the PC distribution (100% ROM0, matching the oracle), and input divergence.

## Quartus is deterministic; the SDRAM interface is placement-SENSITIVE
## — 2026-08-18

The UART build broke the picture completely — green and pink swirls, the raster
shifted right — from a change that cannot touch the video path: a debug counter
that drives only debug outputs, and a transmitter emitting ~40 bytes a second.
Static checks were clean: `+0.296 ns` worst slack, no violation, and **no new
warning classes** against the previous build.

Reverting those three files and rebuilding produced a bitstream **bit-identical**
to the last known-good one, `55965cd8d77b2a6443b9d141dea568f8`.

**So builds ARE reproducible.** "Placement roulette" and "no two builds are
behaviourally equivalent", said earlier in this session, are wrong: identical source
gives identical bits. The accurate statement is narrower and still serious —
**an unrelated edit shifts placement enough to break the SDRAM interface**, which is
deterministic but fragile.

### Why, and it is not only the missing constraints

```
Model1.sv:397   assign SDRAM_CLK = ~clk_sys;
```

The memory's clock is **combinational fabric logic driving an output pin**. Its
delay to the pin is a routing result, so the edge arriving at the device moves with
placement relative to the data pins. That is why `RD_LAT` had to be found
empirically on hardware rather than derived, and why an unrelated edit can shift the
sampling point past the margin.

Neither the framework's `sys_top.sdc` nor our generated `Model1.sdc` contains a
single SDRAM constraint — no `create_generated_clock` on the port, no
`set_output_delay`, no `set_input_delay`. The fitter has never been told those paths
matter or been able to report them as bad.

### What the broken build's overlay showed, which is worth keeping

The corruption was informative rather than just noise:

```
row 11  001740   tilemap 0 wins 5,952 pixels   (had been 000005)
row 13  02D0C0   tilemap 2 wins 184,512
row 16  002000   window mode on
row 04  FFE29D   teardown PC — ffe27a, one of the two writers simulation named
```

**The overlay was legible while the picture was garbage.** The overlay renders from
on-chip data; the picture reads character RAM from SDRAM. Clean on-chip graphics
with corrupt SDRAM-sourced graphics is the signature of the read path, not the
renderer.

And **tilemap 0 won 5,952 pixels against 5 before** — the text is being drawn now.
The coprocessor data ROM fix moved the game forward; it was hidden behind a broken
picture. Row `04` also proved itself: `FFE29D` is `ffe27a`, so the entry calling
that instrument "noise" is withdrawn a second time.

Sweeping the SDRAM read phase through all four settings changed nothing on the
broken build, so the fault is not the capture phase alone.

### The fix, in order

1. **Generate `SDRAM_CLK` through a DDIO output register** clocked by `clk_sys`, so
   its phase is fixed by construction instead of by routing. Standard MiSTer
   practice and the part constraints alone cannot fix.
2. **Constrain the interface**: `create_generated_clock` on the port, plus
   `set_output_delay`/`set_input_delay` from the device's setup, hold and access
   times.
3. **Verify by rebuilding twice from identical source and comparing the reported
   SDRAM slack**, because the failure mode is sensitivity to unrelated edits, not a
   single bad number.

None of this is checkable by `make test` — it is a hardware-only change, verified by
builds and by the screen. It changes an interface that currently works at CL+2, so
the empirically-found phase may need re-finding, and the known-good bitstream above
is the reference to fall back to.

## PARTLY WITHDRAWN: the SDRAM violation is the READ CAPTURE, not the outputs
## — 2026-08-18

The first build ever to constrain this interface. `create_generated_clock` on
`SDRAM_CLK` with `-invert`, plus output and input delays from the device's tSU/tHD
and tAC/tOH:

```
clk_sys     -7.192 ns   TNS -112.637
sdram_clk   -0.150 ns   TNS   -0.221
```

**Failing by seven nanoseconds, and it always was.** Nothing constrained these
paths, so nothing analysed them and nothing could report them.

### The arithmetic is exact, which is what makes it certain

`Model1.sv:397` is `assign SDRAM_CLK = ~clk_sys` — the device is clocked on the
**falling** edge, so data launched on the rising edge has **half a period, 6.25 ns**,
to reach the pin. The worst path was measured earlier today at **12.899 ns** across
9 logic levels, `xfer_addr[2] -> sd_a[12]`:

```
6.25 - 12.9  =  -6.6 ns      against the -7.192 reported
```

That agreement rules out a bad constraint as the explanation. The path genuinely
takes about twice the time available.

### So this is structural, not marginal

The interface has never had timing margin. It works because the real SDRAM
tolerates whatever arrives, and `RD_LAT` was tuned by hand until the result was
readable. That single fact explains a list of symptoms recorded separately over
weeks as if they were unrelated:

- `RD_LAT` derived term by term and still needing an empirical fix on hardware
- CL+2 being the only capture phase that boots, with the other three hanging
- a build whose only change was a debug counter and a UART producing a garbage
  picture — placement moved a path that had no margin to move
- none of it visible to `make test`, `make lint`, or any static check, because the
  paths were unconstrained and the failure is at the pins

### What the fix has to be

Not tuning, and not constraints on their own — constraints only made it visible.

1. **Register the SDRAM outputs in the I/O cells.** Clock-to-output from an I/O
   register is a fixed, short, placement-independent number. `sd_a[12]` already sits
   in a `DDIOOUTCELL`, so the endpoint is right; what is wrong is the ~13 ns of
   combinational logic arriving at it.
2. **Cut the depth feeding `sd_a`** — `sel~1`, `sel~5`, `Mux118~0`, `always3~1/2`,
   `sd_ba~1`, `sd_a[0]~3/4`. The state machine computes its address mux in the same
   cycle it drives the pins. Registering the address select one cycle earlier
   removes most of them, which is the fix already identified when that path was
   first read.
3. **Then** re-check both numbers, and rebuild twice from identical source to
   confirm they are stable.

`make test` cannot see any of this. Verification is the timing report plus the
screen, with `55965cd8d77b2a6443b9d141dea568f8` as the known-good fallback.

### A tooling hazard found on the way

Regenerating the project over a completed build's database made Quartus 17.0 die
inside `quartus_map` with a stack trace in `write_removed_registers_report` and
`node_id != 0`. It reads like a source fault and is not one. `rm -rf build/mister/db
build/mister/incremental_db` before recompiling after `tools/mister_project.sh`.

### Correction, same day: the -7.192 ns is a different path entirely

The entry above attributes the violation to the output path and its 12.9 ns of
combinational depth. **The report does not say that.** Read properly:

```
From:  SDRAM_DQ[0]            (input pin)
To:    m1_sdram:sdram|dq_r[0] (capture register)
Slack: -7.192 (VIOLATED)
Data Delay: 2.445 ns    Number of Logic Levels: 1
```

It is the **read capture**, and the data path is *fast* — 2.4 ns through one level.
There is no logic to cut. The 12.9 ns output path was measured on the PREVIOUS,
unconstrained build and had about -0.02 ns slack: marginal, worth fixing, and
nothing like -7 ns. Two different paths from two different builds were merged into
one conclusion, and the arithmetic that "confirmed" it — 6.25 - 12.9 = -6.6 against
-7.192 — was a coincidence between unrelated numbers.

### What the violation actually is

`SDRAM_CLK = ~clk_sys`, so the device launches read data on the **falling** edge and
`dq_r` captures it on the next **rising** edge. That is half a period, 6.25 ns, for
tAC plus the clock's round trip to the device and the data's return. A clocking
margin problem, not a depth problem, and no amount of pipelining inside the
controller changes it.

### And the verdict currently rests on a guessed number

`tAC` was set to **6.0 ns**, described in the constraint file as "deliberately
pessimistic". Against a 6.25 ns window that fails almost by construction. A real
-6 grade part is nearer 5.4 ns, which would be tight but might close.

**So this build does not prove the interface is broken.** It proves the interface has
almost no read margin by construction, and that the exact verdict depends on a
device number nobody has looked up. The next step is the actual part on the MiSTer
SDRAM board and its datasheet tAC/tOH — not another RTL change, and not another
build on a guess.

If the real numbers still fail, the fix is a **phase-shifted PLL output for
SDRAM_CLK** rather than `~clk_sys`, which is what gives a tunable, defined capture
window and is what other MiSTer cores do. Cutting logic depth would not have helped,
and the plan in the entry above — register the outputs, cut the depth feeding sd_a —
addresses a real but much smaller problem.

## Constraining the SDRAM: what was learned, and why it is opt-in — 2026-08-18

Three builds, ~75 minutes, and the honest outcome is a smaller result than the
attempt.

### The one number worth keeping

With **only the output side constrained** the build completes and reports:

```
sdram_clk   -0.150 ns   TNS -0.221
```

Our commands and addresses reaching the memory are marginally late. Small, real,
and on a path the framework is already trying to improve — `Template.qsf` asks for
`Fast Output Register=ON` on `SDRAM_*`, and ours are **refused**:

```
Warning (176279): Can't pack register node "sd_a[8]" into I/O pin "SDRAM_A[8]".
  The node cannot simultaneously use clear and load signals.   m1_sdram.sv:449
```

`sd_a` is reset to `'0` in an `always_ff @(posedge clk or negedge rst_n)` **and**
conditionally loaded, and a Cyclone V I/O register does one or the other. So the
output registers sit in the fabric paying routing delay to the pin, when the
intended design puts them in the I/O cell.

**That is a real, bounded fix**: split the pin registers into their own `always_ff`
without an async reset. Not attempted here — it changes a controller with a
74,729-check suite at the end of a long session, and it needs its own build and
board test.

### The read path could not be modelled, and the tool crashed trying

`SDRAM_DQ -> dq_r` reports **-7.192 ns** on a path with 2.4 ns of delay and one
logic level. That is a mis-model, not a failure: `dq_r` registers the pin every
cycle and a tag pipeline selects which sample to use, at a depth chosen CL+2..CL+5
from the OSD. **That selectable depth is the read phase.** The data is allowed to
arrive later by design.

The correct expression is a multicycle, and **Quartus 17.0's FITTER SEGFAULTS on
one** — `Fatal Error: Segment Violation`, twice, in both the
`-from <ports> -to <registers>` form and the conventional clock-to-clock form.
Twenty-five minutes per attempt to discover.

### So the constraints are OPT-IN and default OFF

`export MODEL1_SDRAM_SDC=1`. Default builds emit the text but skip it, so they stay
identical to the known-good bitstream.

Leaving them on by default would put a **-7.192 ns known false alarm** at the top of
every timing report, which would bury a genuine regression. A report nobody can
trust is worse than no report.

### What this did NOT establish

Two claims made earlier today and withdrawn: that the output paths "need 12.9 ns and
have 6.25 ns", and that the interface is "failing by seven nanoseconds and always
was". Neither survives reading the report properly. What survives is narrower:

- the output side is marginally late, `-0.150 ns`, with a known and specific cause
- the read side has never been analysed at all and still is not
- `SDRAM_CLK = ~clk_sys` gives the read half a period, which is genuinely little
  margin, but whether it fails is still unmeasured

**Next, in order**: the `sd_a` reset split so the outputs can pack into I/O cells
(bounded, testable, one build); then the read path on Quartus 24.1, which is
installed and may not crash on a multicycle; and only then any thought of a
phase-shifted PLL output for `SDRAM_CLK`.

## m1_sdram's reset cost 0.95 ns of margin and 217 ALM — 2026-08-18

Chasing the I/O packing warning produced no packing and a real improvement anyway.

| | known-good | synchronous reset | + no reset on sd_a/sd_ba/sd_dqm |
|---|---|---|---|
| `clk_sys` slack | +0.296 ns | +0.934 ns | **+1.246 ns** |
| ALM | 29,644 | 29,514 | **29,427** |
| packing warnings | 16 | 16 | 16 |

`m1_sdram` passes **74,729 checks with identical counts** at every step, so the
change is functionally transparent. Flashed as
`3851ff10ac6a4839d01668bb9a0b4330`.

**Why the margin matters more than the packing.** This morning an unrelated edit —
a debug counter and a UART — shifted placement and destroyed the picture on a design
carrying 0.3 ns of headroom. Quadrupling that headroom is the most direct defence
against a repeat, and it came from deleting reset logic rather than from any
cleverness.

### Two theories refuted, both cheaply

1. **A synchronous reset will let the outputs pack into the I/O cells.** No.
   Quartus counts a synchronous clear as a clear, the warning stayed at sixteen.
2. **Removing the reset will.** Also no, and for a reason worth knowing: the init
   sequence assigns `sd_a <= 13'h000` at line 599, which Quartus implements as a
   **synchronous clear** regardless of the reset branch. The register acquires the
   control signal from ordinary code.

So the remaining route is a fitter assignment, `ALLOW_SYNCH_CTRL_USAGE OFF` on
`sd_a[*]`, forcing the clear into the data path. Not attempted: the gain is
speculative, and a tested improvement is worth more than a fourth unverified change
in a row.

**Both refutations were binary** — sixteen warnings or none — which is why they cost
one build each and left nothing to argue about. That is the difference between these
and the four causes named and withdrawn earlier today, every one of which turned on
interpreting a number.

## The blue flash and the missing scroll are ONE bug, and it is in simulation
## — 2026-08-18

MAME, write tap on tile RAM word `0x5006` (pair 2/3's `ctrl`, tilemap 2's `vscr`):

```
ffe27a data=23dd x21    ffe27a data=23ce x292   ffe466 data=23ec x123
ffe27a data=23d1 x9     ffe466 data=2050 x1     ffe466 data=2016 x3
ffe27a data=209d x1     ffe466 data=205e x2     ffe27a data=2064 x2
```

**Every steady-state value is `0x2xxx`**: window mode 1 always on, with the low nine
bits — the vertical scroll — animating. That animation IS the scrolling.

Ours writes only **`0x0000` and `0x2000`**: the mode toggling on and off, the scroll
permanently zero. **Simulation does the same** — 287 writes of `0x0000` and 4 of
`0x2000` in 410 frames — so this is not a hardware fault and needs no board.

### One bug, two symptoms

- the `0x0000` writes are the **blue flash**: window mode off, tilemap 2 drawn
  opaque over an empty map, palette 0
- the scroll field never moving is **nothing scrolling**

Both are the same wrong value written by the same two routines, `ffe27a` and
`ffe466`, which the reference also uses. Same ROM, same code path, different data.

### Ruled out today

- **`c00040`**, polled 36,131 times and read as `0x0001`, looked like a missing I/O
  board value. It is not: **the V60 writes it itself** at `pc=fe03fd`, once a frame.
  Its own scratch flag.
- **the timers at `e0000c`/`e0000e`**, polled 164,185 times and always `0x0000` in
  the reference. Ours match: `m1_glue` only counts when `timer_period != 0`, exactly
  as `timer_r` only computes when `m_timer_period[offset]` is set.
- **the peripheral list generally** — 152 addresses, and nothing yet found that
  answers differently.

### Where the value comes from

The reads immediately before each `ctrl` write are all game state: work RAM
`0x501400`-`0x501424`, `0x501480`-`0x501484`, `0x500500`, and NVRAM `0x40ff5a`-
`0x40ff6e` where a counter steps `e1d9 -> e1dc -> e1df`. So the scroll is computed
from variables, and the divergence is upstream of the write.

**Next**: diff those specific work-RAM locations between simulation and MAME at a
matched point. The addresses are known and the comparison is mechanical, which is a
much better position than the peripheral hunt — and it is entirely local, needing
neither the board nor another bitstream.

## The scroll table at wram 0x501400 is never populated — 2026-08-18

Frame 300, same addresses, reference against our simulation:

```
             wram 0x501400 ...                         0x500500
MAME    0000 0000 0000 0000 0023 2058 ... 4400 0058    0100 0000
SIM     0000 0000 0000 0000 0000 0000 ... 0000 0000    0100 0000
```

`0x50140a` holds the animating `ctrl` value — `2058` at frame 300, `2fce` at 600,
`20a8` at 900 — with a companion at `0x501408`. **The whole table is zero in ours
and populated in the reference**, while `0x500500` matches exactly, so this is one
specific table rather than wholesale corruption.

**Who fills it in the reference**, from a write tap on `0x501408`-`0x50140b` over
600 frames:

```
pc=fe48d5 x163    pc=fef3b5 x164    pc=fe1469 x2
pc=fe6ab0 x2      pc=fe32b7 x1      pc=fe32be x1
```

Two routines, roughly once every four frames. Whether our V60 ever reaches them is
the next measurement, and it splits the problem cleanly: writes with wrong values
means the routines run and their inputs differ; no writes at all means a branch
earlier is taken differently.

### Unproven, and worth checking: the NVRAM window may be shifted 4 bytes

The same dump shows `e1a9 00ff 0000 00fe` at `0x40ff60` in the reference and at
`0x40ff5c` in ours — the same four words, four bytes apart:

```
MAME  40ff5a: 0000 0064 0000 e1a9 00ff 0000 00fe ffbb 1fff ffba
SIM   40ff5a: 0000 e1a9 00ff 0000 00fe 0101 0000 0100 0000 e1e8
```

That is either an addressing offset in our NVRAM mapping or simply different game
state, and the two look identical from one dump. **Flagged, not claimed.** It is
worth resolving because a four-byte offset in a region the game reads for state
would make exactly the kind of routine under investigation compute wrong values.
The test is a wider dump: a mapping error shifts everything, differing state does
not.

### A method note that cost a run

`(cmd > log) &` inside a foreground tool call is killed when the call returns. The
log ends at the first instruction fetches and the job reports success. Use the
harness's own backgrounding, not a shell ampersand.

## Localised: the same instruction computes a different address — 2026-08-18

Our V60 writes wram `0x501408` **only** from `pc=fe1469`, always `data=0000`, and
does it **2,607 times by frame 600**. The reference executes that address exactly
**twice** and fills the table from `fe48d5` and `fef3b5`, which our CPU never
reaches. So we are stuck in a loop around `fe14xx` that the reference passes
through.

Reads taken while the PC is in that region:

```
MAME:  pc=fe14f3  addr=40b906  -> 0100     addr=40ba06 -> 0280
OURS:  pc=fe14f3  addr=400006  -> 0080
```

**The same instruction reads a different address**, and the difference is exactly
`0xb900`. A pointer or index feeding that access is **zero in ours and 0xb900 in the
reference**. Everything downstream follows: different state, `fe48d5`/`fef3b5` never
reached, the scroll table never filled, and `ctrl` written as `0x0000`/`0x2000`
instead of an animating `0x2xxx`.

So the blue flash and the absent scrolling both trace to one wrong pointer.

Ours also walks a ROM table at `0xfd26e0`-`0xfd26fe` in that loop — `00c5 0000 0000
8000 0000 0080 0000 8657 00ff 136c 0050` — which is where the index most plausibly
comes from.

**Next**: find what writes the pointer. It is a register at the point of use, so the
question is which earlier read supplied it — and both machines can be tapped at the
same instruction, which is how this was narrowed in the first place.

This supersedes the peripheral hunt: no peripheral answers differently, the game
simply computes an address from state it built earlier.

## ROOT CAUSE: the game's sequencer is stuck on step 0xfe105f — 2026-08-18

NVRAM `0x40fffc` holds a **continuation pointer**: each step of the game's
boot/attract sequence stores the address of the next step there. A write tap on it
in the reference:

```
f=0  data=f000  pc=fe01e5      0x00fff000
f=0  data=105f  pc=fe105c      0x00fe105f   <- ours reaches here too
f=4  data=1065  pc=fe105f      0x00fe1065   <- MAME ADVANCES
f=4  data=1068  pc=fe1065
f=5  data=106b  pc=fe1068
...  834 writes over 400 frames, ending at 0x00fe1387
```

**Ours is frozen at `0x00fe105f`**, the value written at frame 0. The reference
completes that step in about four frames and walks hundreds more.

So the sequencer stalls on one step, and everything visible follows from it:

```
step fe105f never completes
  -> fe48d5 / fef3b5 never run
  -> wram 0x501400 scroll table stays zero
  -> ctrl written as 0x0000 / 0x2000 instead of an animating 0x2xxx
  -> the blue flash (mode off) and nothing scrolling (field stuck)
```

The routine that step runs is the `fe14xx` loop, where the same instruction reads
different addresses in the two machines:

```
MAME:  pc=fe14f3  addr=40b906 -> 0100      addr=40ba06 -> 0280
OURS:  pc=fe14f3  addr=400006 -> 0080
```

**Next**: find what that step is waiting on. It completes in ~4 frames in the
reference, so it is waiting for something that arrives — an interrupt, a
coprocessor result, a counter, or a device flag — and does not arrive for us. The
technique that got this far works here too: tap the same PC in both and compare.

### How this was found, which is the transferable part

Five causes were named and withdrawn today — the M10K crossing, the FIFO halt, the
copro data ROM, "stuck in boot", the SDRAM output paths — every one reasoned from a
plausible mechanism and refuted by measurement. What worked was **differential
measurement against the oracle**: same instruction, same address, compare the two.
It went from "the screen flashes blue" to a named stalled step in about an hour,
after several hours of theorising had produced nothing but withdrawals.

`CLAUDE.md` opens with exactly that rule.

## V60 vs MAME, instruction by instruction: they diverge at 197,251 — 2026-08-18

Built at the user's suggestion, after they asked why the V60 and TGP both have
"verified per-opcode, never checked on real code" gaps.

**Why those gaps exist**, honestly: per-opcode fuzzing is cheap to build and
produces impressive counts — `mb86233_dec: checked=3,000,000` — and it only proves
each instruction correct *for the state it was handed*. Lockstep on real code needs
a shared memory model and identically stubbed peripherals, so it was written down as
owed and never done. The V60 arrived from the s32 project with a 29/29 unit suite
and this core is the first thing to run Virtua Racing through it. `CLAUDE.md` warns
"do not let the green suite imply otherwise", and the warning was written and then
not acted on.

### The instrument

MAME's debugger emits a full disassembled instruction trace:

```
trace vrfull.tr,maincpu,noloop
```

**`noloop` is essential.** Without it the tracer collapses loops — it printed
`(loops for 620 instructions)` — and diffing against that reports 620 phantom extra
instructions in our trace. That produced a confident, wrong claim of a V60
conditional-branch bug at instruction 83, withdrawn when the trace file was read
properly. The traces were identical there.

Our side emits the same PC stream from `dbg_pc`. The diff is then mechanical.

### The result

**The first 197,250 instructions are identical.** Then:

```
FE0DCC: cmp.h   R0, FE[R11]
FE0DD1: be      FE0E36

MAME:  branch taken     -> FE0E36
OURS:  falls through    -> FE0DD3
```

`R11 = 0x40e800`, so the operand is **`0x40e8fe`**, in NVRAM, and MAME reads
**`0x0000`** there and branches.

So either the memory operand differs or the compare's flags do. That is exactly the
class of fault per-opcode fuzzing cannot reach, and the trace-diff found it in one
run.

**This connects to the NVRAM shift flagged earlier and left unproven**: our NVRAM
window appeared offset by four bytes against the reference. If our `0x40e8fe` is
non-zero, this is a data divergence rather than a CPU bug — and the earlier
observation stops being a coincidence.

### The tool is worth keeping

Two commands and a diff, and it localised in one run what hours of hand-comparing
access sequences did not. It applies unchanged to any future divergence, and the
same approach is what the TGP's outstanding M0 exit criterion needs — noting that
`sim/tgp/mb86233_ref.cpp` is a hand TRANSCRIPTION of MAME's `execute_run`, so even
the existing TGP lockstep compares against a copy of the oracle rather than the
oracle itself.

## A REAL V60 BUG: OUT had its operands swapped — 2026-08-18

Found by `make v60_trace`, the tool built an hour earlier, on its first real use.

The instruction streams match MAME for 197,250 instructions, so a **write** trace
was diffed next. First difference at write 28,698:

```
MAME:                       OURS:
680000 0000 fe010a          000000 0000 fe00c4   <- five writes MAME never makes
                            000000 0000 fe00d1
                            000000 0000 fe00de
                            000040 0000 fe00eb
                            00004e 0000 fe00fa
                            680000 0000 fe010a
```

Those PCs are `out` instructions:

```
FE00B4: movea.h C00000, R0
FE00C4: out.b   R1, 10002[R0]
FE00EB: out.b   #40, 10002[R0]
```

MAME's program-space tap never sees them because `out` writes the **I/O space**. We
wrote them to *memory*, at the wrong address: `out.b #40, ...` wrote to address
`0x000040` — **the immediate had become the address**.

### The oracle is unambiguous

```cpp
// op12.hxx
uint32_t v60_device::opOUTB() {
    F12DecodeOperands(&ReadAM, 0, &ReadAMAddress, 2);
    m_io->write_byte(m_op2, (uint8_t)m_op1);      // address op2, data op1
}
uint32_t v60_device::opINB() {
    F12DecodeFirstOperand(&ReadAMAddress, 0);     // for IN, op1 IS the address
```

**IN and OUT have opposite operand roles**, which is how it was got wrong. Our
`f12_op1_is_addr` already encodes the difference correctly — it lists IN and not
OUT — so `op1` always held the value; only `S_OUT_WR` used it as an address:

```systemverilog
dbus_addr <= op1; dbus_wdata <= op2val;   // was
dbus_addr <= op2; dbus_wdata <= op1;      // is
```

### Verified

```
before:  000040 0000 fe00eb
after:   c10002 0040 fe00eb
```

`out.b #40, 10002[R0]` with `R0 = 0xC00000` now sends `0x40` to port `0xC10002`.
V60 unit suite still **29/29**, `make test` still green.

**Virtua Racing configures its I/O board through those ports during boot**, so every
one of those writes was being thrown at the wrong address instead.

### What it did NOT fix

`make v60_trace` still reports **DIVERGES at instruction 197,251**. At least one
more difference remains. That is expected rather than disappointing: the tool
measures whether a fix moved the boundary, and this one did not, so the next bug is
independent of it.

Note `0xC10002` is outside the DPRAM window our decode maps at
`0xc00000`-`0xc00fff`, so those writes now go to an unmapped address and are
discarded. Whether Model 1 has something there is the next question — MAME maps
`model1_io` in that region.

### The lesson, which is the point

This bug survived: 29/29 V60 unit tests, every fuzz suite, a full `make test`, boot
traces, frame renders, and months of use. It was found in one run by diffing against
the oracle on real code. Per-opcode verification cannot find an instruction whose
*operands* are transposed, because the test feeds operands the same way the
implementation reads them.

## Next divergence: a byte READ of the GLUE irq_mask returns 0 — 2026-08-18

With the OUT fix in, the write-trace diff advances from write 28,698 to **77,904**
— the fix genuinely moved memory agreement a long way. The next difference is a
different KIND of bug: same address, same PC, **different data**.

```
MAME:  e00002 00fd fe01fd
OURS:  e00002 0000 fe01fd
```

The code is a read-modify-write of the interrupt mask:

```
FE01EF: movea.b E00000, R0
FE01F6: mov.b   2[R0], R2      ; read irq_mask
FE01FA: clr1    #1, R2         ; clear bit 1
FE01FD: mov.b   R2, 2[R0]      ; write back
```

MAME writes `0xfd` = `0xff` with bit 1 cleared. We write `0x00`, so **our read
returned `0x00`**.

And the register genuinely holds `0xff` — both machines write it identically during
boot, and our own trace confirms it:

```
ours:  WRT e00002 00ff 01 fe003f
MAME:  e00002 00ff 00ff fe003f
```

`m1_glue`'s read path is correct on inspection (`3'd1: rdata = {8'd0, irq_mask}`),
and the following write at `fe0045` targets the HIGH byte (`be=02`), which the
`be[0]` guard correctly ignores. So the value is there and the read loses it —
a byte-lane extraction on the read path is the obvious suspect, since `0xE00002` is
even and the byte wanted is the LOW one.

**Not yet chased.** Recorded with the evidence so it can be picked up directly.

### On the IN/OUT framing, corrected

The `in`/`out` I/O-space problem was **already known and already half-fixed** —
`v60.sv`'s header records that a faked IN "left the CPU polling a constant forever"
and that they are real bus accesses now. Today's contribution is narrower than it
was first presented: that repair got **IN** right and left **OUT** with its operands
transposed. The claim that `findings.md`'s "the V60 never reads the coprocessor
back" needed correcting is also softer than stated — that entry measured the program
space, and the header already noted `model1_io` maps the coprocessor's registers.

## FIXED: the GLUE decode aliased a whole page onto sixteen bytes — 2026-08-18

`m1_glue` decodes `a = addr[3:1]` — three bits, sixteen bytes — but `m1_decode`
asserted `sel_glue` for the **entire 0xe0 page**. Everything above `0xe0000f`
aliased back onto it.

Boot writes a run of bytes upward from `0xe00010`:

```
FE0060: movea.b 10[R0], R1     ; R1 = 0xE00010
FE006C: mov.b   #0, [R1+]      ; writes 0xE00012

MAME:  e00012 0000 00ff fe006c    -> unmapped, discarded
OURS:  glue a=1                   -> wrote 0xE00002, clearing irq_mask
```

The game sets `irq_mask` to `0xff` at `fe003f`; we cleared it at `fe006c`; the
read-modify-write at `fe01f6`/`fe01fd` then wrote `0x00` where the reference writes
`0xfd`. Traced by logging every change of `irq_mask` with the PC that caused it.

MAME maps these individually, with no mirror:

```
e00000 irq_control_w   e00004 bank_w         e00008 timer_period_w
e00002 irq_mask_r/w    e00006 timer_mode_w   e0000c timer_r
```

Fix: `sel_glue` additionally requires `addr[15:4] == 0`.

**The testbench encoded the same wrong assumption** — `tb_m1_decode`'s reference
model said `if (hi == 0xe0) return GLUE;`, the whole page — so implementation and
reference were wrong together and **466,714 checks passed regardless**. Corrected
against the oracle's map; the suite is green at the same count.

That is the third time in one day a reference written from the same reading as the
implementation hid a bug from its own test. See `docs/differential-testing.md`.

## Trace-diff progress, and where it stops — 2026-08-18

Memory agreement between our core and the reference, by first differing write:

| after | first differing write |
|---|---|
| (start) | 28,698 |
| `OUT` operand fix | 77,904 |
| GLUE decode fix | **266,496** |

The instruction-stream divergence moved 197,251 -> 205,156 -> 206,307 as the
comparison itself was corrected (cold NVRAM, collapsed repeats).

**It now stops at the I/O board handshake**, which is a timing difference rather
than a fault — see `docs/differential-testing.md`. `m1_ioboard`'s `LATENCY = 64`
answers faster than MAME's Z80, so the V60's poll loop runs once instead of many
times. Both complete; only the duration differs.

**Three divergences chased today turned out to be instrument artifacts**: collapsed
loops in MAME's tracer, branch-to-self loops invisible to a log-on-change PC trace,
and MAME's saved NVRAM making its boot warm while ours is cold. All three are now
handled by `tools/v60_trace.sh` and documented.

## The I/O board handshake, timed against the reference — 2026-08-18

`m1_ioboard` waited `LATENCY = 64` cycles before clearing the flag at `0xc00040`,
on the stated reasoning that "the V60 polls, so any non-zero value works and the
exact figure is not known". Two Lua instruments — `tools/mame_iohandshake.lua` and
`tools/mame_flag_state.lua` — replaced that with measurement:

| | reasoning said | reference says |
|---|---|---|
| time to answer | "microseconds, anything non-instant works" | **38,577 us** = 617,236 V60 cycles = **740,684** of our 19.2 MHz domain |
| how often | every request, forever | **once**, at boot, and never again |
| flag after boot | cleared each frame | **left set** — 1,194 of 1,200 frames sampled |

It is that long because it is not a mailbox turnaround: it is the I/O board's Z80
powering up and running its self-test. The 36,308 polls the V60 makes during it
account for essentially all 36,131 `c00040` reads in the earlier peripheral census.

**One number reproduces both behaviours.** A request re-arms the deadline, the
V60's doorbell arrives every 333,913 cycles, and 333,913 < 740,684 — so after boot
the count never expires and the flag stays set on its own, while at boot the V60
raises it once and only polls, so the single reply lands. No one-shot rule and no
second parameter.

**Why it mattered even though the game cannot see it.** The V60 never reads the
flag after boot, so clearing it was invisible on screen. It was not invisible to
`make v60_trace`: our V60 left the boot poll loop after one read where the
reference loops 36,308 times, and the diff reported that as a divergence at
instruction ~206,307, which was chased as a CPU bug. **A guessed constant in a
peripheral produced a false CPU-bug report.** That is the argument for measuring
peripherals whose behaviour the game cannot observe.

Also found while checking the baseline: `m1_uart_tx` and its testbench existed with
**no Makefile target at all**, so `make test` never ran them and `make lint` never
saw them — while CLAUDE.md's baseline listed `m1_uart_tx: checks=69` as though it
had. Now wired in. The module stays instantiated nowhere by intent; it is parked
for hardware monitoring if that is ever needed.

## CORRECTED: "the V60 never reads the coprocessor back" — 2026-08-18

This was recorded as a measurement, carried into `CLAUDE.md`'s table of things
reasoning got wrong, quoted in `docs/debug-overlay.md` row `03` to justify reading
`dbg_fifo_pops`'s zero as healthy, and written into `m1_copro_if.sv`'s own comments.
**It is false.**

`tools/mame_v60_iospace.lua`, 600 frames of the reference:

    V60 I/O SPACE: 859,618 reads, 5 writes
      reads by address:   d80000  710,722      the coprocessor output FIFO
                          d20000  148,896      coprocessor RAM data
      reads by PC:        fed5a4  138,224
                          ff850c   35,924  ...

About **1,433 I/O reads a frame**. The first ones appear at frame 9, from
`pc=ff9754` — the `in.w [R23], R2` that `v60_trace` had just walked into.

**Why the original census returned zero: it looked at the program space.**
`model1.cpp` maps the coprocessor interface into `AS_IO` *and* program space with
identical addresses (lines 1016-1019 and 1033-1036), but the game reaches it with
`in.w`/`out.w`, so all the traffic is in `AS_IO`. A census of the other space sees
nothing and **that nothing reads exactly like an answer**.

There is a second reason it went unchallenged: for much of this project our own V60
faked `IN`, returning a constant, so our core genuinely made zero readback accesses.
The measurement of the reference and the behaviour of our stub agreed, which made
the wrong conclusion look confirmed from two directions. `IN` is real now (and `OUT`
had transposed operands until today), so that agreement is gone.

**When a measurement says "never", check that the instrument could have seen it.**
And when a measurement of the reference agrees with a known stub in our own core,
that is not corroboration.

### What it means for M2

Our core's `TGP->V60 returns=0` and `V60 pops=0` are therefore **gaps to close, not
properties to preserve**. `m1_boot BOOT_CYCLES=600000000` has the TGP retiring
48,356 instructions and pushing nothing back, with `copro RAM writes=0`, while the
reference's V60 is reading results 1,433 times a frame. That is the next thing in
front of the 2D question, not behind it.

## CORRECTED: our coprocessor data ROM is fine; the ADDRESS is wrong — 2026-08-18

`tb_m1_boot` printed `first two data words: 3f800000 00012e00 (MAME: 00000030
00012e00)`, which reads as a broken `copro_data` image and points at the packer.

**The packer is correct.** The four ROM files byte-interleaved exactly as
`ROM_LOAD32_BYTE` specifies give word 0 = `3f800000`:

    mpr-14898.39  00 00 00 00 ...      -> byte 0 of each file, little-endian:
    mpr-14899.40  00 00 00 00 ...         00 | 00<<8 | 80<<16 | 3f<<24
    mpr-14900.41  80 00 00 00 ...       = 3f800000
    mpr-14901.42  3f 00 00 00 ...

**The reference gets `00000030` because it reads a different word.** Its TGP makes
exactly three io accesses in its first 30 frames (`tools/mame_tgp_io.lua`):

    W io 002e <- 00000010        set copro_data_base
    R io 8010 -> 00000030        data word 0x10
    R io 8020 -> 00012e00        data word 0x20

and `copro_data_r` computes `index = (base & ~0x7fff) | offset`, where `0x10 &
~0x7fff` is **0** — so the base write does not move the window at all. The reference
simply reads word `0x10`. Ours reads word `0x00`. Word `0x20` matches because both
ask for it.

So the mismatch was never in the data. **A wrong expectation in a testbench accused
the right code**, and it would have sent the next session into the ROM packer — the
one place that had two independent implementations checking each other
(`verify_mra.py`).

### What it really exposes: our TGP runs different microcode

Our TGP's first io accesses are **five reads of io `0x0000`** — `copro_ramadr` —
which the reference never makes, followed by `R 8000` where the reference does
`R 8010`. The divergence is there, at the very start, not in any ROM.

That is the concrete form of what M0 exit criterion 2 has always owed:
**microcode-driven lockstep for the TGP.** What exists is a whole-CPU reference in
lockstep over 8,000 retires of *generated* instructions, which cannot catch this.
The technique that made the V60 tractable today — MAME's tracer, periodic-loop
collapsing, diff the streams — applies directly, and `:tgp_copro` can be traced the
same way `maincpu` can.

Downstream state, for context: `TGP retires=48356 pc=0044`, `fifo_rd=1`,
`TGP->V60 returns=0`. The reference's V60 collects results 1,433 times a frame. So
the coprocessor producing nothing is now the nearest cause in front of the 2D
question, and its own cause is microcode divergence rather than data.

## FIXED: the boot bench loaded the TGP microcode one word out — 2026-08-18

`make tgp_trace` — microcode-driven lockstep for the coprocessor, M0 exit criterion
2 — found this on its **first run**, and the symptom pointed squarely at the CPU:

    MAME:  003E: bsif alw #0x7e2   ->  07E2: lid #0x10
    ours:  003e -> 003f -> 07e2

A `bsif` apparently executing a delay slot. Three things made the CPU look like the
only suspect: the streams matched for the preceding 48 instructions; `brif alw
#0x10` a few instructions earlier branched cleanly with no extra instruction; and
`build/rom/vr_tgp_prog.hex` was **byte-for-byte identical** to the reference's
program space at those words, checked directly:

    pc 003e  bf6407e2      pc 003f  40000000      pc 0040  41000200

MAME's `bsif` has no delay slot (`case 2: pcs_push(); m_pc = data;`) and our
`mb86233_seq` implements exactly that (`3'd2: begin pc_exec = data; do_push = 1; end`).
The decode is right too: for `0xbf6407e2`, `subtype = (opcode>>17)&7 = 2`,
`cond = (opcode>>20)&0x1f = 0x16` (always), `data = 0x07e2`.

**The bench was writing the microcode to the wrong addresses.**

```
uc_data <= ucode[uc_addr];
if (uc_we) uc_addr <= uc_addr + 11'd1;
```

Both non-blocking, so during any cycle `uc_addr` was already `A` while `uc_data`
still held `ucode[A-1]`, and `m1_tgp` wrote `prog[A] = ucode[A-1]`. **Address 0 came
out right by accident** — the address does not advance on the first cycle, because
`uc_we` is still low — which is why instruction 1 executed correctly and every one
after it came from the wrong word. That accident is what made the traces agree for
48 instructions and hid the shift.

What settled it in one run was adding the **fetch address and the opcode** to the
trace rather than reasoning further:

    TGPPC 0010 fetched_from=0010 ir=bf6e0000     <- hex word 0x0f, not 0x10

`uc_data` is now combinational on `uc_addr`. With that, `003e` holds the `bsif` and
branches straight to `07e2`, and the lockstep reports IDENTICAL.

### Scope, and what it invalidates

| bench | microcode loader | affected |
|---|---|---|
| `tb_m1_boot` | its own, broken | **yes** |
| `tb_m1_frame` | drives the real `m1_rom_loader` | no — `v60_trace` stands |
| `tb_m1_tgp.cpp` | sets address and data together | no |
| hardware | `tgp_din`/`tgp_addr`/`tgp_wr` same cycle | no — hence row 02's checksum matching |

**Every TGP figure `make m1_boot` ever printed came from a coprocessor running
microcode from the wrong addresses** — `TGP retires=48356 pc=0044`, `fifo_rd=1`,
`returns=0`, the lot. They were quoted in this session as evidence about the
coprocessor's output side; they were evidence about nothing.

This is the fifth divergence in two days that was the **instrument** rather than the
design, and the first where the instrument was a testbench's **stimulus** rather
than its observation. The others are in `docs/differential-testing.md`; the general
rule earned here is narrower and worth stating on its own: **when a trace and a ROM
image disagree, dump what the DUT actually fetched before suspecting either.**

## FIXED: ST was not a register — the TGP's flags lived in the ALU pipeline — 2026-08-18

`make tgp_trace`'s second use found this, and it explains why the coprocessor never
produced anything.

The command-dispatch loop reads a word from the input FIFO, masks it and compares:

    0043: ldi #0x100, x1      the input FIFO in data space
    0044: mov (x1), b
    0045: mov bh, d
    0046: lia #0x3f
    0047: andd : mov $0xb, a
    0048: subd
    0049: brif !zrd #0x44     loop until the compare matches

Our TGP went round 41 times where the reference goes round once. The FIFO word was
right — `04000000`, the same word the reference reads — so the flag was wrong:

    0048: subd       d=00000000  st=c0000002  zrd=1     correct, ZRD set
    0049: brif !zrd  d=00000000  st=c0000008  zrd=0     ST CHANGED under the branch

**The branch instruction recomputed ST before its own condition was evaluated.**

    assign st = {seq_zc1, seq_zc0, alu_st_out[29:0]};      // what it was

`alu_st_out` is combinational — `(s2_st & ~st_mask) | st_set`, where `s2_st` is
`st_in` pipelined through `ALU_LAT` stages. So the architectural flags were being
carried in the **ALU's pipeline registers** and recomputed for whatever instruction
happened to be in the ALU. Any conditional branch immediately after a flag-setting
ALU op read a corrupted ST.

MAME keeps ST as state and updates it exactly once per instruction:

    mb86233.cpp:201   m_st = F_ZRC|F_ZRD|F_ZX0|F_ZX1|F_ZX2|F_ZC0|F_ZC1;
    mb86233.cpp:499   m_st = (m_st & ~m_alu_stmask) | m_alu_stset;

`st_hold` is now that register, latched on `alu_out_valid`, reset to `0x38000003` —
MAME's value minus ZC0/ZC1, which the sequencer owns.

### Why the existing lockstep never caught it

`tb_mb86233_core` reports `lockstep_regs=8000 diverged=0` **both before and after
this fix.** Its 8,000 retires are *generated* instructions, and it never happened to
put a conditional branch straight after a flag-setting ALU op with a zero result.
That is the exact blind spot generated-instruction lockstep has and real microcode
does not, and it is the whole argument for `make tgp_trace` in one datum. Do not read
`diverged=0` there as coverage of the flag path.

### What it cost

The TGP could never leave command dispatch, so it never read a command, never
computed and never wrote a result. Every conclusion drawn from `returns=0`,
`V60 pops=0` and `copro RAM writes=0` was downstream of this. With the fix the
lockstep advances from 71 instructions (spinning) to 77 (progressing).

## FIXED: brul/bsul were not implemented — the dispatch jump was a constant — 2026-08-18

`seq_branch_val = d_bdata` unconditionally, for every branch subtype. So `brul` and
`bsul` — the register- and memory-indirect branches — jumped to **their own
immediate field**, turning a computed jump into a constant one.

MAME, `mb86233.cpp` case 1 (`brul`) and case 3 (`bsul`):

    if(opcode & 0x4000) { v = read_reg(opcode); }         // register form
    else { ea = ea_pre_0(opcode); v = read_dword(ea); }   // memory form

and `read_reg` masks its argument to **six** bits (`r &= 0x3f`), not the five the
disassembler prints — so the index is `d_bdata[5:0]`.

`make tgp_trace` found it at pc `0x0052`, `brul alw d`:

    0050: lia #0x53
    0051: addd : mov $0, p     d = 8 + 0x53 = 0x5b   (ours, correct)
    0052: brul alw d           MAME -> 0x005b,  ours -> 0x4019

`0x4019` is the instruction's own low half. **That instruction is the command
dispatch table**, so nothing past it ever ran.

### Sizing it before touching the FSM

Scanning the microcode for the branch group (`opcode >> 26` in `{0x2f, 0x3f}`,
subtype `(opcode >> 17) & 7`):

| subtype | | count |
|---|---|---|
| 0 | `brif` | 196 |
| 1 | `brul` | **1** — pc `0x0052`, register form, reg `0x19` = `d` |
| 2 | `bsif` | 23 |
| 3 | `bsul` | **2** — pc `0x04c5`, `0x04da`, both MEMORY form |
| 5 | `rtif` | 12 |
| 6 | `ldif` | 2 |
| 7 | — | 4 (no case in MAME's switch either; no PC change) |

So the register form is one site and the thing blocking dispatch; the memory form is
two sites, neither reached yet. The register form is implemented. **The memory form
is not** — it needs a data-memory read before the branch resolves, which is another
FSM state — and it now prints a warning in simulation rather than jumping somewhere
plausible, the way `v60.sv` reports a skipped `BRK`.

### Result

The lockstep advances **77 -> 102** instructions, and our stream goes from 71 lines
with 1 loop to 322 lines with 10 loops against the reference's 343 with 21. The
coprocessor is executing real work for the first time.

The next divergence is at the same instruction for a different reason: `brul alw d`
with `d = 0x85 + 0x53` where the reference has `0x02 + 0x53`. `d` comes from the FIFO
word via `mov bh, d`, so **the command word we read differs** — the dispatch itself
now works. That points at the V60 side or at FIFO ordering, not at the branch.

### Two self-inflicted build failures worth remembering

A `$display` block that tested `rst_n` under `posedge clk` tripped `SYNCASYNCNET`
("flopped as both synchronous and async"), and the test was redundant — `state`
resets to `S_FETCH` so it cannot be `S_RETIRE` in reset. Then the comment explaining
that contained the word "verilator", which the linter read as a pragma and rejected
with `BADVLTPRAGMA`. **Do not name the linter in a comment.**

## FIXED: 0x680000 had no read handler — the display-list buffer select read 0xFFFF — 2026-08-18

`make v60_trace` found this at instruction 26,283, once the identity-block fix had
carried the trace past 25,682:

    FF96F7: mov.h  680000, R0
    FF96FE: test1  #6, R0
    FF9701: be     FF970C        the reference takes it; we fell through

`0x680000` is the display-list control register. `m1_decode` asserted `sel_listctl`
and `m1_main` handled **writes only** — reads fell through the mux to
`rdata_r <= 16'hFFFF`. So bit 6, the **display-list buffer select**, read as 1
forever and we never followed the reference's double-buffer handshake.

### It is not a plain latch

From `model1_v.cpp`, three functions together define it:

| | |
|---|---|
| `model1_listctl_r` (:1358) | offset 0 returns `listctl[0] \| 0x30` — bits 4 and 5 **forced set**; offset 1 is plain |
| `set_current_render_list` / `get_list_number` (:1338, :1344) | when bit 2 is **clear**, bit 6 **mirrors bit 3** — software picks the buffer |
| `end_frame` (:1351) | when bit 2 is **set**, bit 6 **toggles every second frame** — automatic double buffer |

So a register that reads back what was written would still have been wrong.

### Built as its own module, with its own suite

`rtl/video/m1_listctl.sv` and `sim/video/tb_m1_listctl.cpp`, 26 checks, per hard
rule 5 — rather than a few lines buried in `m1_main`, because the behaviour is not
obvious and is worth testing exhaustively. The mirror is applied **combinationally
on the read path** instead of by mutating the stored value on a schedule: MAME
applies it inside the render functions, so it has always happened before anything
reads the register, and doing it on read is the same observable behaviour without
inventing a point in the frame to do it at.

**The testbench computes its expectations from `model1_v.cpp` in its own
`ref_read0()`** rather than from the RTL. That is deliberate after the
identity-block lesson, where one reading became the RTL table, the testbench's
expected values and the docs at once — and the testbench even carried a comment
explaining why it was typed out separately, which did not help because it was still
one reading.

### Also visible in the same trace

The loop census reports we spend far **less** time at `fe1433` than the reference —
1,819 iterations against 9,546. That is the wait loop immediately before this code,
so it is plausibly the same cause, and it is a useful confirmation signal.

## The V60 trace's second resolution limit, and a CPI gap worth its own look — 2026-08-18

With `0x680000` implemented the trace advances 26,283 -> **26,945**, and stops on a
difference that is again **timing, not function**:

    MAME:  fe1433 fe1435 fe143d  fe1433 fe1435 fe143d  -> fe02bc   (interrupt)
    ours:  fe1433 fe1435 fe143d  fe1433 fe1435         -> fe02bc

`fe1433`/`fe1435`/`fe143d` is `inc.w R0` / `cmp.b #2, 500501` / `blt` — a wait loop
on a byte the vblank handler advances. The interrupt lands **one instruction earlier
in the loop** for us. `v60_collapse.py` reduces the loop to one instance, but it
cannot absorb a **trailing partial iteration** of differing length, so the streams
are offset by one from there.

Two ways past it, neither done: teach the collapser to skip a partial final
iteration of a loop it has just collapsed, or move to **write-trace** diffing, which
tolerates this by construction.

### The CPI gap

The loop census makes the cause measurable rather than inferred:

    fe1433,fe1435,fe143d    MAME 11,506 iterations    ours 3,619    (-68.5%)

Consistent at every position it appears. That is the reference completing **3.2x**
as many iterations of the same three instructions in the same wall time:

| | instructions/frame in that loop | implied cycles/instruction |
|---|---|---|
| reference, 16 MHz | 11,506 x 3 = 34,518 | ~8 |
| ours, 19.2 MHz | 3,619 x 3 = 10,857 | ~30 |

`make m1_boot` has printed that ~30 average for a long time ("29.27 avg (INCLUDES
block instructions)") and it was read as a property of the design. Against the
reference it is a **3.8x shortfall per instruction**, and it is the direct reason an
asynchronous interrupt lands at a different point in a wait loop.

It is not a correctness fault on its own — the game waits either way — but it makes
every timing-dependent comparison approximate, and it is the kind of gap that
matters once the rasterizer has to keep up with a frame. Worth a look on its own
terms; `tools/v60_cpi_sweep.sh` already exists.

## Where the V60's cycles actually go — measured, after two wrong answers — 2026-08-18

The reference completes 3.18x more iterations of the `fe1433` wait loop than we do in
the same wall time. The question that matters for the planned V60 split is **what to
optimise**, and it took three attempts to answer honestly.

**Attempt 1, reasoning — wrong.** The FSM's shortest path is
`S_FETCH -> S_FETCH_W -> S_DECODE -> S_ALU -> S_RETIRE`, five cycles, against a
steady-state ~20 CPI, so "three quarters of every instruction is spent waiting on
memory". Arithmetic, not measurement.

**Attempt 2, the existing sweep — also wrong, and the tool was stale.**
`tools/v60_cpi_sweep.sh` hardcoded `-GCEDIV=3` while `Model1.sv` ships
`.ce_cpu(1'b1)`, so every number it ever produced described a V60 getting one cycle
in three. Its header said "at the production /3 clock enable" — true of an earlier
design, never revisited. Re-run at `CEDIV=1`:

| | LAT=0 | LAT=64 |
|---|---|---|
| FAST=0 | 6.08 | 7.31 |
| FAST=1 | 6.00 | 6.37 |

That reads as "the core is 6 CPI and latency is irrelevant", which retired attempt 1
— but the sweep's workload is **514 instructions producing FOUR instruction
fetches**. The test code sits inside the fetch window and loops, so it never
stresses fetch, which is exactly why latency barely moves it. It cannot explain the
~20-30 CPI real code shows.

**Attempt 3, direct measurement.** `tb_m1_boot` now counts CPU-domain cycles with a
bus request outstanding, in three buckets — data, fetch, and the union, because the
two overlap and adding them would overstate the total:

    819,812 instructions over 25,000,148 CPU cycles = 30.49 CPI
    data-stalled  9,625,651 (38%)
    fetch-stalled 6,819,902 (27%)
    either       16,435,859 (65%)

So **~20 of the 30.5 CPI is waiting on memory** and ~10 is execution. The two buckets
barely overlap, which says the single arbitrated bus is serialising them rather than
hiding one behind the other.

### What this means for the V60 split

**The V60's own logic is close to the reference already** — ~6 CPI in isolation
against MAME's implied ~8. The 3.18x throughput gap is almost entirely the **memory
subsystem**: SDRAM latency under five-master contention, plus instruction-fetch
bandwidth.

So extracting the V60 and optimising *it* would not close the gap. The target is the
memory path — a small instruction cache, deeper prefetch, or giving fetch its own
port — and that lives outside the CPU, which is a different sharing question between
the Model 1 and Model 2 projects than the core itself.

The split is still worth doing for the reasons it was proposed. It just is not the
lever on this number, and it would have been easy to spend the effort there and find
that out afterwards.

## The TGP fixes expose a deadlock: each side waits for the other — 2026-08-18

With the ST register and `brul` implemented, the coprocessor round-trip works for the
first time — and the core then **stops further back than it did before**.

    600 M cycles   pc fed5a4  TGP retires=501 pc=0492  pushes=71 returns=20 pops=20
    1.5 G cycles   pc fed5a4  TGP retires=501 pc=0492  pushes=71 returns=20 pops=20

**Identical.** The TGP retired nothing between 150 M and 375 M CPU cycles while the
V60 executed 8.8 M more instructions, all of them spinning at `fed5a4`. 862 frames,
well past the frame 276 the reference needs — this is a deadlock, not slow progress,
and an earlier "it is just pacing" reading of the 600 M run was wrong.

    TGP stuck? io_rd=0 io_wr=0 io_ack=0  fifo_rd=1  fifo_wr=0

`fifo_rd=1`: the TGP is blocked reading a command from an **empty input FIFO**, while
the V60 polls the **output FIFO** at `fed5a4` for a result. Each waits for the other.
The unimplemented `bsul` memory form is not involved — its warning never fired.

### This is a regression, and the fixes are still right

Before them the core reached `ff7d7e` with tilemap 1 holding its 648 category-1
tiles, `[5006] = 0x2000` and 96 row-mask words. It got there **because the V60 was
ignoring a coprocessor that never answered anything**. The fixes moved us from
"coprocessor absent, so the game skips it" to "coprocessor present but incomplete, so
the game waits for it" — the standard hazard of a partial implementation, and not a
reason to revert work that is verified against the reference instruction for
instruction.

### The most likely missing piece

`copro RAM writes=0`, while `tools/mame_v60_iospace.lua` measured the reference's V60
reading `0xd20000` — the coprocessor RAM data port — **148,896 times per 600 frames**,
second only to the output FIFO itself. That path is not implemented here, and a
coprocessor whose RAM the host can neither fill nor read back is a plausible reason
the exchange stops after twenty results.

### Do not flash the 2026-08-18 20:22 build

Simulation predicts the deadlock, so a hardware round trip would only confirm what is
already known and would look like a step backwards on screen. Fix the copro RAM path
first. The `.rbf` is kept because its resource numbers are wanted — 29,536 ALM,
452 M10K, +0.301 ns — but it is not an improvement to run.

## The interlock fix turns a spin into an honest deadlock — 2026-08-18

With the empty-outbound-FIFO stall in place, the boot sim changes character
completely:

| | before | after |
|---|---|---|
| V60 | spinning at `fed5a4` on stale data | **stalled at `ff9754`**, the `in.w` result read |
| ifetch lines | 6,253,201 | **70,369** |
| CPI | 30.5 | **516**, and 97% data-stalled |
| TGP | parked `0x0492` | **stalled `0x00a5`**, `mov (x1), a` on an empty FIFO |
| pushes | 71 | **4** |

Both sides now stall where the hardware stalls, instead of one of them running on
rubbish. **That is the fix working.** It is also a hang: 97% of CPU cycles hold a bus
request that never acknowledges, so this build would freeze on the board rather than
show sky and sea. Better to diagnose, worse to run.

### The imbalance it exposes, stated precisely

**The V60 believes it has sent a complete command after 4 pushes. The TGP is still
waiting for input.** One of the two is wrong about how many words a command is, and
the reference's own answer is already measured — `tools/mame_tgp_fifo.lua` shows one
command as **five** words in and one out:

    0x100 ->  04000000  00000000  01000000  3f400000  428c0000
    0x400 <-  42520000

So the next question is exactly: does our V60 push five words per command, and does
our TGP consume five? Both are countable with instruments that now exist. Do not
guess at it — a zero counter has been misread as a missing feature twice today
already.

### Also new, and mildly encouraging

The TGP's io accesses have changed shape: six reads of io `0x0000` and then **io
`0x0020`**, which is the **sincos unit** (`copro_io_map`, `0x0020-0x0023`). It was
reading `0x8000`, the data ROM window, before. The coprocessor is reaching for a math
unit for the first time.

### Do not flash this build

It deadlocks earlier than the 20:22 one and would freeze rather than draw. The 20:22
build remains the hardware baseline.
