# Sega Model 1 — releases

Copy to the SD card:

| from | to |
|---|---|
| `Model1_20260916.rbf` | `/media/fat/_Arcade/cores/` — **rename to `Model1.rbf` on the card** |
| `Virtua Racing.mra` | `/media/fat/_Arcade/` |
| `Virtua Formula.mra` | `/media/fat/_Arcade/` |

`Model1_20260909.rbf` is the previous build, kept so there is something to fall
back to. **It is superseded** — see *Which build to run* below.

ROMs are supplied by you and must be in `/media/fat/games/mame/` as the MRA
names them. Nothing here contains ROM data.

**You need TWO zips, not one.** `vr.zip` is the game, and the I/O board's Z80
firmware lives in a separate BIOS set:

| zip | why |
|---|---|
| `vr.zip` | Virtua Racing: the game, its coprocessor microcode, its sound program and PCM samples, and `93c45.bin` — the I/O board's settings EEPROM |
| `vformula.zip` | Virtua Formula. A Virtua Racing CLONE, so a split set holds only the six parts that differ and the rest come from `vr.zip`; a merged set carries everything itself |
| `model1io.zip` **or** `daytona93.zip` | `epr-14869.25`, the I/O board's Z80 firmware |

Either of the two will do; the MRA accepts both. **The core runs the real I/O
board Z80 and there is no behavioural fallback**, so without that firmware the
game does not boot — it waits forever for a board that never answers. MAME will
not start Virtua Racing without the same file, so a complete romset already has
it.

**SDRAM:** a **128 MB** module. The core addresses 64 MB of it — the packed game
image is ~25 MB and the sound regions sit above 32 MB. It has only ever been run
on 128 MB, so that is the only size that can be claimed.

## Which build to run

Run **`Model1_20260916.rbf`**. It is the one these MRAs are built for.

| | md5 | bytes |
|---|---|---|
| `Model1_20260916.rbf` | `99918f7520f2dc7c3f97d58fbdf85f07` | 4,636,660 |
| `Model1_20260909.rbf` | `9d401f3a6a6dc4c910efd2014b77be12` | 4,639,196 |

The MRAs here are **backward compatible**: the older core does not recognise the
sound stream and ignores it, so it still loads and plays — silently, and more
slowly, because it downloads 8.5 MB of samples and discards them. There is no
reason to prefer it other than as a fallback.

**Check what you are running.** If the core on your card does not have one of
those md5s you are not running either build — and the usual reason is a second
file: MiSTer resolves `<rbf>Model1</rbf>` by scanning for names starting
`Model1` followed by `.` or `_`, and keeps the lexicographically greatest. `_`
sorts after `.`, so a spare `Model1_old.rbf` in `cores/` silently wins over
`Model1.rbf`. Keep exactly one, and keep fallbacks out of `cores/`.

## What works

**Virtua Racing and Virtua Formula.** They boot, run, reach attract mode, play,
and read all fourteen control bytes at the board's own cadence. The 2D layers,
the coprocessor, and the 3D geometry and rasteriser are all running.

Virtua Formula is the same game on the linked-cabinet F1 board and is a Virtua
Racing clone in MAME: only the program ROMs, the two boot ROMs and one banked
pair differ. Both MRAs are verified byte for byte against an independently
written packer — the MRA is expanded exactly as MiSTer expands it and diffed
against a separate implementation of the same layout.

**Sound is implemented** as of `Model1_20260916.rbf`: the sound PCB's 68000,
its YM3438 and both MultiPCM channels. It is a new arrival and the honest
statement of what has been confirmed is in the next section.

## Not finished, as of `Model1_20260916.rbf`

This list describes the RBF named above. Every entry is removed in the same
change as the RBF that fixes it, so if an item is still here it is still true of
the newest build in this directory. **The heading carries the RBF's name for
exactly that reason — if they disagree, trust neither and check.**

- **Sound is confirmed on a game this release does not ship.** The sound board
  was brought up and verified on **Virtua Fighter**, which has attract audio.
  Virtua Racing's attract mode is **silent on the real hardware too**, so a
  quiet attract screen here is correct and proves nothing either way — and
  Virtua Racing's *in-game* audio has not been confirmed on hardware. Expect it
  to work; do not be surprised if something is wrong with it.

- **Scenery comes and goes on busy stretches.** The store that holds
  transformed quads for a frame fills in display-list order and drops whatever
  arrives once it is full — 3,072 quads, against peaks of about 3,034 while
  driving. Cars are early in the list and survive; track and scenery are later
  and are discarded. The same corner on the same racing line looks correct in
  attract mode and drops in play. The fix is to move the quad payload to SDRAM;
  on-chip memory is 551 of 553 blocks and nothing further fits.

- **The 2D tile fetch can overrun.** When it does, that scanline is displayed
  again rather than updated. Deliberate and stable — the alternative tears every
  following line — but it is not correct.

- **Only Virtua Racing and Virtua Formula are shipped.** An MRA is shipped only
  for a game somebody has played on hardware. Virtua Fighter, Star Wars, Wing
  War and NetMerc have MRAs in the source repository and are candidates, not
  releases. Star Wars does not currently load at all.

## Controls

| | default |
|---|---|
| Accelerate | R2, or **right stick up** |
| Brake | L2, or **right stick down** |
| Shift Up | R1 |
| Shift Down | L1 |
| VR1 – VR4 (view buttons) | A, B, X, Y |
| Start | Start |
| Coin | Select |

Both pedals are on the **right stick's Y axis**, one per direction, because
MiSTer has no analogue trigger input — so a pad's LT/RT cannot be read as pedals
at all. The buttons stay live alongside it and the larger of the two wins, so
digital-only play is unaffected. Which half is throttle depends on the pad, and
axis polarity is not standardised: **`Pedals` in the OSD swaps them.** The left
stick steers.

Service, Test and Coin 2 are mappable and unbound by default. The game is
configured through its own test menu, which is why there is no DIP menu.

## Credits

The V60 implementation is **[meathax](https://github.com/meathax)**'s, from the
[s32](https://github.com/meathax/s32) Sega System 32 project. The 68000 is
**fx68k**, by Jorge Cwik. The FM is **jt12**, by Jose Tejada (jotego). The Z80
is **T80**, originally by Daniel Wallner. The framework is
**MiSTer-devel**'s. The hardware behaviour was verified throughout against
**MAME**, whose Model 1 driver and MB86233 coprocessor model are the reference
this core is checked against — the coprocessor is fuzzed per opcode against it
and the V60's instruction stream is diffed against its tracer from reset.

GPL-3.0-or-later. Full detail in `THIRD-PARTY.md` in the source repository.
