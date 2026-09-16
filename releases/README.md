# Sega Model 1 — releases

Copy to the SD card:

| from | to |
|---|---|
| `Model1_20260917.rbf` | `/media/fat/_Arcade/cores/` — **rename to `Model1.rbf` on the card** |
| `Virtua Racing.mra` | `/media/fat/_Arcade/` |
| `Virtua Formula.mra` | `/media/fat/_Arcade/` |
| `Star Wars Arcade.mra` | `/media/fat/_Arcade/` |

**One core, deliberately.** Earlier releases shipped a fallback alongside the
current build; that only ever made it possible to run the wrong one. If you need
an older build it is in the git history of this repository.

ROMs are supplied by you and must be in `/media/fat/games/mame/` as the MRA
names them. Nothing here contains ROM data.

**You need the I/O board's firmware as well as the game.** It is a separate BIOS
set, not part of any game zip:

| zip | why |
|---|---|
| `vr.zip` | Virtua Racing: the game, its coprocessor microcode, its sound program and PCM samples, and `93c45.bin` — the I/O board's settings EEPROM |
| `vformula.zip` | Virtua Formula. A Virtua Racing CLONE, so a split set holds only the six parts that differ and the rest come from `vr.zip`; a merged set carries everything itself |
| `swa.zip` | Star Wars Arcade |
| `model1io.zip` **or** `daytona93.zip` | `epr-14869.25`, the I/O board's Z80 firmware |

Either of the last two will do; the MRAs accept both. **The core runs the real
I/O board Z80 and there is no behavioural fallback**, so without that firmware a
game does not boot — it waits forever for a board that never answers. MAME will
not start these games without the same file, so a complete romset already has it.

**Check what you are running.** `Model1_20260917.rbf` is `MD5SUM_PENDING`. If the
core on your card does not have that md5 you are not running this build — and
the usual reason is a second file: MiSTer resolves `<rbf>Model1</rbf>` by
scanning for names starting `Model1` followed by `.` or `_`, and keeps the
lexicographically greatest. `_` sorts after `.`, so a spare `Model1_old.rbf` in
`cores/` silently wins over `Model1.rbf`. Keep exactly one, and keep fallbacks
out of `cores/`.

**SDRAM:** a **128 MB** module. The core addresses 64 MB of it — the packed game
image is ~25 MB and the sound regions sit above 32 MB. It has only ever been run
on 128 MB, so that is the only size that can be claimed.

## What works

**Virtua Racing, Virtua Formula and Star Wars Arcade.** All three boot, run and
read their controls. The 2D layers, the coprocessor, and the 3D geometry and
rasteriser are all running.

Virtua Formula is the same game on the linked-cabinet F1 board and is a Virtua
Racing clone in MAME: only the program ROMs, the two boot ROMs and one banked
pair differ.

**Star Wars Arcade is new in this build, and it plays** — but **its attract
sequence does not draw correctly**. Read the entry below before deciding whether
it is broken for you; it is a known gap, not damage to your setup.

It had never loaded at all before: its reset vector jumps into a region of the
address map that every other shipped game leaves empty, and the core decoded
that region as unpopulated. It has its own input map — stick to aim,
Fire/Thumb/Button 3 on A/B/X, and a second pad drives the gunner seat.

Every MRA here is verified byte for byte against an independently written packer
— the MRA is expanded exactly as MiSTer expands it and diffed against a separate
implementation of the same layout.

**Sound works in all three**, in attract and in play: the sound PCB's 68000, its
YM3438 and both MultiPCM channels, confirmed on hardware.

One thing that is correct but looks wrong: **Virtua Racing's attract mode is
silent on the real cabinet too.** A quiet attract screen is not a fault. Coin up
and the music and effects are there.

## Controls

| | Virtua Racing / Formula | Star Wars Arcade |
|---|---|---|
| Steer / aim | left stick, or d-pad | either stick, or d-pad |
| Accelerate | R2, or right stick up | — |
| Brake | L2, or right stick down | — |
| Buttons | VR1–VR4 on A, B, X, Y | Fire / Thumb / Button 3 on A, B, X |
| Shift | R1 / L1, or d-pad up / down | — |
| Start | Start | Start (pad 2 Start joins as gunner) |
| Coin | Select | Select |

`Pedals` in the OSD swaps throttle and brake, because both sit on the right
stick's Y axis and pad axis polarity is not standardised — MiSTer has no
analogue trigger input, so a pad's LT/RT cannot be read as pedals at all. The
buttons stay live alongside, and the larger of the two wins.

`Stick X axis` and `Stick Y axis` in the OSD invert Star Wars' aim if either
direction feels backwards.

Service, Test and Coin 2 are mappable and unbound by default. The games are
configured through their own test menus, which is why there is no DIP menu.

## Not finished, as of `Model1_20260917.rbf`

This list describes the RBF named above. Every entry is removed in the same
change as the RBF that fixes it, so if an item is still here it is still true of
the newest build in this directory. **The heading carries the RBF's name for
exactly that reason — if they disagree, trust neither and check.**

- **STAR WARS ARCADE'S ATTRACT SCREEN IS WRONG, IN TWO SEPARATE WAYS.** The
  game boots, plays, reads its controls and has sound — but what you see before
  you start is not what the cabinet shows.

  **The Star Wars logo never appears.** After the Star Destroyer passes, the
  yellow outlined title should fill the screen. It is drawn with a display list
  command that supplies polygons already projected into screen space, and this
  core walks that command and discards it — the code to emit those polygons was
  never written. The same gap is why Virtua Fighter's knives are missing. It is
  not a Star Wars fault and no setting will bring it back.

  **The Star Destroyer draws only partly**, as thin pale slivers rather than a
  solid shaded hull, and entirely white where the reference is shaded grey with
  blue engine glow. **Undiagnosed.** It is *not* the quad store running out —
  that store is not overflowing here.

  Neither is a regression. Star Wars had never loaded at all until this build,
  so this is the first time anyone has seen its attract screen on this core.

- **Scenery comes and goes on busy stretches of Virtua Racing.** The store that
  holds transformed quads for a frame fills in display-list order and drops
  whatever arrives once it is full — 3,072 quads, against peaks of about 3,034
  while driving. Cars are early in the list and survive; track and scenery are
  later and are discarded. The same corner on the same racing line looks correct
  in attract mode and drops in play. The fix is to move the quad payload to
  SDRAM; on-chip memory is 551 of 553 blocks and nothing further fits.

- **The 2D tile fetch can overrun.** When it does, that scanline is displayed
  again rather than updated. Deliberate and stable — the alternative tears every
  following line — but it is not correct.

- **Three games are not shipped, and two of them cannot be.** Virtua Fighter
  boots, has sound and reads its controls, but **is not playable**: the
  fighting arena is the wrong size during a match, which makes a real fight
  unplayable even though attract and character select are correct. Two display
  list commands are parsed and discarded and either could be the cause — the
  polygon RAM upload, which has no consumer because there is no polygon RAM in
  the core, and direct already-projected polygons. It is a candidate for a
  later release, not this one. **Wing War and
  Sega NetMerc use a different I/O board** — MAME gives both `SEGA_MODEL1IO2`,
  a different device rather than different firmware — and this core implements
  only the first board, so no control reaches either game however it is mapped.
  That board is not built. See `docs/io-board.md` in the source repository.

## Credits

The V60 implementation is **[meathax](https://github.com/meathax)**'s, from the
[s32](https://github.com/meathax/s32) Sega System 32 project. The sound board's
68000 is **fx68k**, by Jorge Cwik (ijor), and its YM3438 is **jt12**, by Jose
Tejada (jotego). The Z80 is **T80**, originally by Daniel Wallner. The framework
is **MiSTer-devel**'s. The hardware behaviour was verified throughout against
**MAME**, whose Model 1 driver and MB86233 coprocessor model are the reference
this core is checked against — the coprocessor is fuzzed per opcode against it
and the V60's instruction stream is diffed against its tracer from reset.

GPL-3.0-or-later. Full detail in `THIRD-PARTY.md` in the source repository.
