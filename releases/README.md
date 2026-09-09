# Sega Model 1 — releases

Copy to the SD card:

| from | to |
|---|---|
| `Model1_20260909.rbf` | `/media/fat/_Arcade/cores/` — **rename to `Model1.rbf` on the card** |
| `Virtua Racing.mra` | `/media/fat/_Arcade/` |
| `Virtua Formula.mra` | `/media/fat/_Arcade/` |

ROMs are supplied by you and must be in `/media/fat/games/mame/` as the MRA
names them. Nothing here contains ROM data.

**You need TWO zips, not one.** `vr.zip` is the game, and the I/O board's Z80
firmware lives in a separate BIOS set:

| zip | why |
|---|---|
| `vr.zip` | Virtua Racing: the game, its coprocessor microcode, and `93c45.bin` — the I/O board's settings EEPROM |
| `vformula.zip` | Virtua Formula. A Virtua Racing CLONE, so a split set holds only the six parts that differ and the rest come from `vr.zip`; a merged set carries everything itself |
| `model1io.zip` **or** `daytona93.zip` | `epr-14869.25`, the I/O board's Z80 firmware |

Either of the two will do; the MRA accepts both. **The core runs the real I/O
board Z80 and there is no behavioural fallback**, so without that firmware the
game does not boot — it waits forever for a board that never answers. MAME will
not start Virtua Racing without the same file, so a complete romset already has
it.

**Check what you are running.** `Model1_20260909.rbf` is
`9d401f3a6a6dc4c910efd2014b77be12`, 4,639,196 bytes. If the core on your card
does not have that md5 you are not running this build — and the usual reason is
a second file: MiSTer resolves `<rbf>Model1</rbf>` by scanning for names
starting `Model1` followed by `.` or `_`, and keeps the lexicographically
greatest. `_` sorts after `.`, so a spare `Model1_old.rbf` in `cores/` silently
wins over `Model1.rbf`. Keep exactly one, and keep fallbacks out of `cores/`.

**SDRAM:** a **128 MB** module. Virtua Racing's packed image is ~25 MB and the
polygon and texture regions sit above it; this has only ever been run on 128 MB.

## What works

**Virtua Racing and Virtua Formula.** Virtua Racing boots, runs, reaches attract
mode, plays, and reads all fourteen control bytes at the board's own cadence.
The 2D layers, the coprocessor and the 3D geometry and rasteriser are all
running.

Virtua Formula is the same game on the linked-cabinet F1 board and is a Virtua
Racing clone in MAME: only the program ROMs, the two boot ROMs and one banked
pair differ. Its MRA is verified byte for byte against an independently written
packer, the same check Virtua Racing gets.

An MRA is shipped only for a game somebody has played on hardware. Virtua
Fighter, Star Wars, Wing War, NetMerc and Virtua Formula have MRAs in the source
repository and are **not** shipped here: they are candidates, not releases.
Star Wars does not currently boot at all.

## Not finished, as of `Model1_20260909.rbf`

This list describes the RBF named above. Every entry is removed in the same
change as the RBF that fixes it, so if an item is still here it is still true of
the newest build in this directory. **The heading carries the RBF's name for
exactly that reason — if they disagree, trust neither and check.**

- **THERE IS NO SOUND.** None at all. The Model 1's audio is a separate PCB — a
  68000, a YM3438 and two MultiPCM chips — reached over a uPD71051C USART on the
  main board, and none of it is implemented. The core produces silence and that
  is expected, not a fault with your setup. It is milestone M4 and it has not
  been started.

- **The 2D tile fetch overruns about twice a frame.** When it does, that
  scanline is displayed again rather than updated. Deliberate and stable — the
  alternative tears every following line — but it is not correct.

- Only Virtua Racing and Virtua Formula are shipped; see above.

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
[s32](https://github.com/meathax/s32) Sega System 32 project. The Z80 is
**T80**, originally by Daniel Wallner. The framework is **MiSTer-devel**'s. The hardware behaviour was verified throughout against
**MAME**, whose Model 1 driver and MB86233 coprocessor model are the reference
this core is checked against — the coprocessor is fuzzed per opcode against it
and the V60's instruction stream is diffed against its tracer from reset.

GPL-3.0-or-later. Full detail in `THIRD-PARTY.md` in the source repository.
