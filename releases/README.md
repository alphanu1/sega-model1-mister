# Sega Model 1 — releases

**All six Model 1 games play**, at full speed: Virtua Racing, Virtua Formula,
Virtua Fighter, Star Wars Arcade, Wing War and Sega NetMerc.

Copy to the SD card:

| from | to |
|---|---|
| `Model1_20261030.rbf` | `/media/fat/_Arcade/cores/` — **rename to `Model1.rbf` on the card** |
| the MRAs, from `mra/` | `/media/fat/_Arcade/` (or a folder inside it, such as `_Arcade/_Model1/`) |

`mra/` has twelve MRAs: one per game, and a `[15kHz CRT]` version of each that
starts the game at 15 kHz for a CRT.

**One core, deliberately.** If you need an older build it is in the git
history of this repository.

ROMs are supplied by you and go in `/media/fat/games/mame/`, named as the MRA
names them. Nothing here contains ROM data.

## ROMs

All sets are MAME's.

| zip | for |
|---|---|
| `vr.zip` | Virtua Racing |
| `vformula.zip` | Virtua Formula. A Virtua Racing clone: with a split set you also need `vr.zip` |
| `vf.zip` | Virtua Fighter |
| `swa.zip` | Star Wars Arcade, including its music board's ROMs (`epr-16471.2`, `mpr-16514.57`, `mpr-16515.58`, all in MAME's set) |
| `wingwar.zip` | Wing War |
| `netmerc.zip` | Sega NetMerc, including `netmerc_nvram.bin`, the default settings that hold the gun's alignment |
| `model1io.zip` **or** `daytona93.zip` | `epr-14869`, the I/O board's Z80 firmware, for every game except Wing War |
| `model1io2.zip` | `epr-16891.6`, the I/O board firmware for **Wing War**, which uses a different I/O board |

**The core runs the real I/O board Z80 and there is no fallback**, so without
its firmware a game does not boot: it waits forever for a board that never
answers. MAME needs the same files, so a complete romset already has them.

**Check what you are running.** `Model1_20261030.rbf` has the md5
`6037b8b7ab97b7adee3c2ee653b479d6`. If yours doesn't match, the usual reason is
a second file: MiSTer picks the core whose name sorts last, and `_` sorts after
`.`, so a spare `Model1_old.rbf` in `cores/` quietly wins over `Model1.rbf`.
Keep exactly one, and keep backups out of `cores/`.

**SDRAM:** a **64 MB or larger** module. The core addresses 64 MB (one 32M x 16
chip: 8,192 rows, 1,024 columns, 4 banks) and uses up to about 45 MB of it -
Star Wars, with its music data, is the largest - so a 32 MB module is too
small. It has been tested on a 128 MB module, which works because the core
uses only its first 64 MB.

## New in `Model1_20261030`

**Games**

- **Wing War boots and plays, for the first time.** The game copies small
  routines into RAM and runs them there, which the core couldn't do, and it
  uses a different I/O board from the other games (MAME's `model1io2`), now
  built. Its sky is back too: it's a 3D model the game uploads at boot, which
  the core never stored.
- **Virtua Fighter plays properly.** The arena is the right size, so full
  matches work. A CPU multiply into memory never wrote its result back.
- **Sega NetMerc works in game.** The camera, the gun and its alignment, and
  the 3D layering are right: the core now gives the game the headset's
  starting position, the gun's stick and its saved calibration.
  **Look around with the left stick, aim with the right** (see *OSD* below).
- **Star Wars Arcade:**
  - the ships are complete: half of the colour data was being dropped;
  - **the music board is in**: Star Wars' second sound board, a Z80 and an
    MPEG audio player, now plays the music;
  - the opening crawl scrolls properly and the Death Star stays put.
- **Virtua Racing's attract freeze is fixed.** The same CPU bug as Virtua
  Fighter.

**Picture**

- The 3D is drawn whole into DDR3 before it is shown, so the late 3D bands are
  gone.
- Tile overruns are fixed.
- The thin lines through ships and mountains are gone: rows were lost at the
  edges of the 3D drawing bands.
- If a game hasn't finished its 3D in time, the last frame stays up instead of
  an empty one, with no added lag.

**Sound**

- The sample chips now have proper volume envelopes, 12-bit samples and
  smoothing, so notes fade out instead of cutting off, and the harsh hiss is
  gone. Every game benefits.
- The sound link runs at the real arcade speed.

**Speed and space**

- The geometry coprocessor is about twice as fast, ported from the Sega Model 2
  core.
- About 6,000 ALMs saved, and some polygon data moved to DDR3, which made room
  for all of the above.

**Other**

- `Analog control` wheel modes for the racers.
- 15 kHz CRT MRAs for every game. Not yet tested on a CRT: reports welcome.

## OSD

| setting | what it does |
|---|---|
| `Video timing` | `Original 24kHz` or `Scandoubled` |
| `Video` | `Native 24kHz` or `15kHz interlaced` (fixed on in the `[15kHz CRT]` MRAs), with `15kHz lines` and `15kHz pairing` |
| `Pedals` | swaps throttle and brake, for pads whose axis runs the other way |
| `Analog control` | `Standard`, `Wheel A` (each pedal on the up half of an axis) or `Wheel B` (each pedal on its full travel) |
| `Stick X axis` / `Stick Y axis` | invert the aim (Star Wars, NetMerc's gun) |
| `Star Wars music volume` | `Firmware` (the game's own levels and fades, the default) or `MAME` |
| `NetMerc head look` | `Left stick` (default): look around with the left stick, aim with the right. `Left stick Y inv` flips up and down. `Off`: a fixed forward view, with both sticks on the gun |
| `Test switch` / `Service switch` | the cabinet's switches, for the games' own test menus |

The games are configured in their own test menus, so there is no DIP menu.

## Controls

| | Virtua Racing / Formula | Virtua Fighter | Star Wars Arcade | Wing War | NetMerc |
|---|---|---|---|---|---|
| Move | left stick or d-pad: steer | d-pad | either stick or d-pad: aim | stick: fly | left stick: look; right stick: aim |
| Buttons | Accelerate R2, Brake L2, Shift R1/L1, VR1-VR4 on A/B/X/Y | Punch, Kick, Guard on A, B, X | Fire, Thumb, Button 3 on A, B, X | Machine Gun, Missile, Smoke on A, B, X; View 1-4 on L1, R1, L2, R2 | Trigger and Thumb: set them with the OSD's button mapping |
| Start / Coin | Start / Select | Start / Select | Start / Select (pad 2 Start joins as gunner) | Start / Select | Start / Select |

Service, Test and Coin 2 are mappable and unbound by default.

## Known issues

- Small seams in Star Wars Arcade, Virtua Fighter and Virtua Racing (on Virtua
  Racing, very occasionally a sliver of road with the grass showing through).
- Wing War: the photo screens fill in from left to right, there's a small
  glitch on the VR buttons screen, and some polygon colours differ from MAME's.
- **NetMerc is nearly silent.** One of its sample ROMs, `mpr-18134`, is a bad
  dump (all `0xFF`) in every set going, MAME's included, so most of its sound
  isn't there to play. Its ground is also a little darker than it should be,
  and its button names are still Virtua Racing's.
- The Wing War clones (US, Japan, R360) and Star Wars Arcade (Japan) are not
  shipped: they're untested.

Please report anything else you find, with the game and where.

## Credits

The V60 implementation is **[meathax](https://github.com/meathax)**'s, from the
[s32](https://github.com/meathax/s32) Sega System 32 project. The sound board's
68000 is **fx68k**, by Jorge Cwik (ijor), and its YM3438 is **jt12**, by Jose
Tejada (jotego). The Z80 is **T80**, originally by Daniel Wallner. The 15 kHz
scan converter is retrorepair's design, from the Sega Model 2 core. The
framework is **MiSTer-devel**'s. The hardware behaviour was verified throughout
against **MAME**, whose Model 1 driver, MB86233 coprocessor model and Star
Wars music board (`dsbz80`) are the references this core is checked against.

GPL-3.0-or-later. Full detail in `THIRD-PARTY.md` in the source repository.
