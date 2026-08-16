# Why most of the 2D does not draw

Written 2026-08-17, after the row mask was implemented and did not fix it.
Everything here is measured against MAME running the real ROM unless it says
otherwise. `segaic24.cpp` is the reference — `draw_common` and `draw_rect`.

**The symptom.** MAME's attract frame shows a ranking table, `INSERT COIN(S)`,
`CREDIT 0` and the SEGA logo over the road. Ours shows the sky and sea and
nothing else, and neither scrolls.

---

## Ruled out by measurement — do not re-derive these

| Suspect | Evidence against |
|---|---|
| fetch bandwidth | overlay row `0C` reads **zero** deadline misses. An overrun repeats a scanline anyway, which is not this symptom |
| the ROM | 26 of 29 parts match MAME 0.289, **no CRC mismatches**, and all twelve the MRA loads are among them |
| scroll register decode | ours reads `0x5000+layer` / `0x5004+layer` and masks `& 0x1ff`, matching `draw_common` exactly |
| tilemap base addresses | MAME's four maps are at tile_ram `0x0000`/`0x1000`/`0x2000`/`0x3000`, 64x64 tiles — ours matches |
| tile word decode | `val & tile_mask`, colour `(val>>7) & 0xff`, category `val & 0x8000` — ours matches |
| the row mask alone | implemented, verified over 380,929 checks, on the board — **changed nothing on screen** |

That last one is the important negative result. The mask was a real defect,
correctly fixed, and something else is also wrong.

---

## The four tilemaps are two pairs, not four peers

This is the structural fact the implementation is missing, and it is visible in
MAME's own naming:

```c
tile_layer[0] = tile_info_0s    // pair 0, Scroll map   tile_ram 0x0000
tile_layer[1] = tile_info_0w    // pair 0, Window map   tile_ram 0x1000
tile_layer[2] = tile_info_1s    // pair 1, Scroll map   tile_ram 0x2000
tile_layer[3] = tile_info_1w    // pair 1, Window map   tile_ram 0x3000
```

An **odd tilemap is a window map**, and in `ctrl` mode it is not an independent
layer at all — it is drawn *as part of* its even partner's pass, selected by
region. `draw_common` returns immediately for the odd map:

```c
if (ctrl & 0x6000) {
    if (layer & 1) return;          // the window map draws only via its partner
    ...
}
```

`ctrl` is **not** each map's own register. It is
`tile_ram[0x5004 + ((layer >> 1) & 2)]` — the *even* map's vscr of the pair. So
one register governs both maps of a pair.

We model four independent layers and implement no `ctrl` at all.

---

## What Virtua Racing actually asks for, measured

At the attract frame:

```
tile_ram[5000]=0000  5001=0000  5002=0023  5003=0000     hscr 0..3
tile_ram[5004]=0000  5005=0000  5006=2058  5007=0000     vscr 0..3

pair 0/1: hscr=0000 vscr=0000 ctrl=0000  -> normal path, row mask applies
pair 2/3: hscr=0023 vscr=2058 ctrl=2058  -> window mode 1, hscr & 0x8000 clear
```

Working the mode-1 else-branch by hand for pair 2/3:

```c
v = (-vscr) & 0x1ff;                 // -0x2058 as u16 = 0xDFA8, & 0x1ff = 424
if (c1.max_y >= v) c1.max_y = v-1;   // 383 >= 424? no  -> c1 = rows 0..383
if (c2.min_y <  v) c2.min_y = v;     // -> c2 = rows 424..383, EMPTY
if (!((-vscr) & 0x200)) layer ^= 1;  // 0xDFA8 & 0x200 set -> no swap
tile_layer[2]->draw(c1);             // whole screen
tile_layer[3]->draw(c2);             // nothing at all
```

**So MAME draws tilemap 3 not at all in this frame, and we draw it.** That is a
confirmed divergence.

### What is in each map

```
tilemap 0: 4096/4096 nonzero, 4096 category-1, commonest colour 00 (3781 tiles)
tilemap 1: 4096/4096 nonzero,  648 category-1, commonest colour 00 (3448 tiles)
tilemap 2: 4096/4096 nonzero,    0 category-1, commonest colour 7c (1150 tiles)
tilemap 3: 4096/4096 nonzero,    0 category-1, commonest colour 60 (3072 tiles)
```

Three things fall out:

- **Tilemap 3 is 3072 tiles of one colour** — a flat fill, and it is the map
  MAME does not draw.
- **Tilemap 0 is entirely category-1.** With the row mask at `0x6000` mostly
  zero, category-1 is hidden — so tilemap 0 is almost entirely invisible in MAME
  too. Our mask implementation agrees with that, which is a point in its favour.
- **Tilemap 1 is 84% category-0**, so most of it shows through a zero mask. If
  the text is anywhere, it is most likely here.

---

## Implemented versus not

| segas24 behaviour | MAME | ours |
|---|---|---|
| four maps at `0x0000`/`0x1000`/`0x2000`/`0x3000`, 64x64 | yes | **yes** |
| tile decode: number, colour, category | yes | **yes** |
| scroll `& 0x1ff`, layer disable `vscr & 0x8000` | yes | **yes** |
| row mask, `0x6000`/`0x6800`, 4 words/line, bit set = hidden | yes | **yes** (new) |
| category selected by mask, `win = layer & 1` inverting it | yes | **yes** (new) |
| tilemaps 2/3 category-0 pass opaque | yes | **yes** |
| **`ctrl & 0x6000` window/split-scroll modes** | yes | **NO** |
| **odd map suppressed in `ctrl` mode** | yes | **NO** |
| **per-line H-scroll table at `0x4000 + 0x200*layer`** | yes | **NO** |
| **`ctrl` read from the pair's even vscr** | yes | **NO** |

---

## Ranked hypotheses for tomorrow

### 1. We draw tilemap 3 when MAME does not — confirmed divergence

Measured above. What is *not* yet established is whether it explains the
symptom, and there is an argument that it does not: our mixer paints back to
front `3,2,1,0`, so tilemap 3's category-0 pass is the **backmost** layer, and
tilemap 2 — which is opaque on its category-0 pass — should paint straight over
it. On that reasoning drawing tilemap 3 is wrong but harmless here.

Test it directly rather than reasoning further: force tilemap 3 off (tie its
`disabled` bit) and rebuild. If the text appears, this is the whole bug and the
priority reasoning above is wrong somewhere. If nothing changes, it is a real
divergence that is not the cause, and hypothesis 2 moves up.

**This is the cheapest decisive experiment and should be first.**

### 2. Something is wrong with tilemap 1's rendering specifically

If the text lives on tilemap 1 (84% category-0, so mostly visible through a zero
mask), and tilemap 2 paints opaquely *behind* it, then the text should already be
showing. It is not. That points at tilemap 1's own path.

The unfinished measurement: dump map rows around the text and confirm which map
holds it. `scratchpad/mame/rows.lua` is written and did not fire — the log was
empty and the output file was never created, so it is a harness fault, not a
result. Re-run it, and if it stays silent, fall back to dumping via
`-autoboot_script` at a later frame or reading the region with the debugger.

### 3. The opaque rule may be wrong

Ours makes the category-0 pass opaque for tilemaps 2 **and** 3
(`opaque_pass = (i >= 2)`). Check that against MAME: the flag comes from the
caller in `model1_v.cpp`, not from the tile device, so the truth is in how
Model 1 calls `draw()` — which is worth reading, because if only tilemap 2 is
opaque there, our tilemap 3 is both drawn when it should not be *and* opaque
when it should not be, and it would occlude after all.

**Read `model1_v.cpp`'s draw calls before anything else** — it is the piece of
this that has never been checked, and it determines layer order, priority and
the opaque flags all at once.

---

## The scrolling, separately

The sky and sea do not scroll. Our scroll decode is correct in isolation, so the
likely cause is that pair 2/3 is in window mode, where MAME drives scroll
through the pair rather than per map, and optionally from the per-line table at
`0x4000`. VR has `hscr & 0x8000` clear at this frame, so the per-line table is
*not* in use here — the plain `set_scrollx(0, -(hscr & 0x1ff))` applies to both
maps of the pair.

Note the sign: MAME sets **negative** scrollx in the window path
(`-(hscr & 0x1ff)`) where our decode computes `map_x = x - hscr`. Those may or
may not agree; it is worth deriving rather than assuming, and a static scroll
value would hide a sign error.

Also worth checking whether the registers move at all over time on our side —
if the V60 never updates them, the fault is upstream of the video path entirely.

---

## Method notes for the MAME harness

Everything here came from Lua against the running reference. Run MAME from a
scratch directory — it drops `cfg/`, `nvram/` and `snap/` wherever it starts.

```
mame vr -rompath ~/roms -window -skip_gameinfo -autoboot_delay 0 \
        -autoboot_script <script>.lua
```

- `-skip_gameinfo` is **required**, or the game-info screen blocks autoboot and
  the script silently never loads — no output, no error.
- **The orange screen is a different one**: MAME's missing-ROM warning, which
  `-skip_gameinfo` does *not* skip, and which waits for a keypress. It appears
  because three files are absent from the set — see below. Press a key once and
  autoboot proceeds; the scripts here all ran that way.
- If a run produces an empty log **and** no output file at all, MAME did not
  start — the `io.open` at the top of every script creates the file
  immediately, so a missing file means the script never loaded. The usual cause
  is launching before the previous instance has exited; `pkill -x mame` then
  wait for `pgrep` to go quiet rather than sleeping a fixed few seconds.

### Completing the ROM set removes the orange screen

Three files are missing against MAME 0.289, and one is free:

| File | Status |
|---|---|
| `mpr-14897.33` | **present under a transposed name** — the set has `mpr-14879.33` with CRC `74873195`, which is exactly what `mpr-14897.33` should be. Copy it under the right name and this warning goes |
| `315-5573.bin` | genuinely absent. TGP microcode, 8 KB, CRC `3335a19b`. Needed for M2 regardless |
| `93c45.bin` | genuinely absent. I/O board EEPROM default, 128 bytes, CRC `65aac303`. Our HLE does not use it |

Do the rename into a **scratch copy** of the zip and point `-rompath` there —
hard rule 2 keeps ROM images out of the repository, and there is no reason to
mutate the working set in `~/roms` either.
- `-autoboot_delay 0`, or a tap installs after the exchange it should capture.
- Assign every notifier and tap to a **global**, or the subscription is
  collected and the callback stops with no error.
- Wrap notifier bodies in `pcall` and log the message; errors inside a notifier
  vanish otherwise.
- `manager.machine.video:snapshot()` gives a reference frame to diff against a
  photograph of the board.
- tile_ram word *w* is at V60 `0x700000 + w*2`.

Scripts in `scratchpad/mame/`: `maps.lua` (per-map census plus the window-mode
arithmetic), `mask.lua` (row-mask tables and scroll registers), `rows.lua`
(per-row dump, did not fire), `trace.lua` (read/write tap, run-length
compressed), `snap.lua` (timed snapshots).

---

## The best experiment nobody has run yet

Render the **same data** both ways and diff. Dump MAME's tile RAM, character RAM
and palette at a known frame, feed them into `tb_m1_video`, render, and compare
against `manager.machine.video:snapshot()` from the same frame.

That is decisive in a way none of the above is, because it removes the CPU, the
bus and the timing from the question entirely and tests only the pixel path
against the oracle's own output. `tb_m1_video` already fills those three arrays
and walks every pixel — it needs the arrays loaded from a dump instead of
generated, and the comparison pointed at a PNG rather than at its internal C
model.

The internal C model is worth keeping either way, but note its limit: it encodes
**our** reading of MAME. When our reading is wrong, model and RTL agree with each
other and both are wrong — which is exactly what has happened here twice.
