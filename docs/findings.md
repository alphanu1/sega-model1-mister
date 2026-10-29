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

## 2026-10-29 — WING WAR NEVER RAN: THE V60 COULD NOT EXECUTE FROM RAM, AND IT HAD THE WRONG I/O BOARD

Branch `wingwar-boot`, on `main` (1daae7a). Ben: Wing War does not boot, and
he thinks it never has. The board showed a grey backdrop, "credit 0", the SEGA
logo, no 3D and no response to Start (HANDOFF 2026-09-16, 3b).

**Two faults, found in the wrong order.** The I/O board was found first, from
`io-board.md`'s 2026-09-16 note, and fixed - and the bench then crashed at
**exactly the same instruction** (PC 40D007, 237 vblanks into the game) with
the right board as with the wrong one. That identity is what said the crash
was something else. The second fault is the one that stopped the game.

### Fault 1, the crash: instruction fetches from RAM went to ROM

Wing War copies routines into RAMA and calls them: MAME's trace runs
40D000h-40D014h and 40DC00h-40DCCEh from the first attract frame, and a
write tap shows them written once, at frame 477 of a cold boot, and never
rewritten in 1,500 frames. **Our fetch path only knew the ROM mapping**:
`m1_main` drove `if_sdram_addr` from `m1_decode`'s `rom_addr`, which is zero
outside ROM, so a fetch from 40D000h read SDRAM word 0 - the first bytes of
the program. The frame bench's new PC ring (printed on a halt) shows the
last instructions as `... 0220EE 0220F2 40D000` and the halt at 40D007. No
other title here executes from RAM, which is how it survived.

Fix: fetches from RAMA/RAMB take the data port's mapping (NVRAM_BASE /
WRAM_BASE), and are **not cached** by `m1_fetch_bridge`, whose comment had
recorded the assumption this broke - "the V60 ... never executes what it
wrote ... If either of those ever stops being true this needs a real
invalidate". Uncached rather than an invalidate port: the RAM routines are
about 0.1% of the instructions in MAME's trace (1,959 of ~1.4 M over 60
frames), and an invalidate would need a second tag read. `tb_m1_fetch_bridge`
gained a section for it (175,156 -> 175,228 checks).

### Fault 2: the wrong I/O board

### Reproduced on the bench first

`tb_m1_frame GAME=wingwar` with the I/O board firmware every MRA has always
sent (EPR-14869) ends on **exactly the board's picture** - grey, `credit 0`,
SEGA logo, no 3D - and at 367 M cycles the **V60 halts at PC 40D007**, in its
own backup RAM. So "boots" in the 2026-09-16 entry meant the 2D came up; the
game itself never ran. (That halt is fault 1. With EPR-16891 the run halts
at the same PC after the same 237 vblanks, 2.2 board-seconds later.)

### The cause, measured

**`model1.cpp`'s `wingwar()` replaces the I/O board** with
`SEGA_MODEL1IO2` and BIOS `epr16891` (io-board.md had recorded this on
2026-09-16 and left it unbuilt). EPR-14869 answers the V60's boot exchange,
but **it does not keep Wing War's settings block**. The exchange, from a new
V60-side DPRAM tap in MAME (cold nvram) and the matching `DPTRACE` in the
frame bench:

    V60 writes "SEGA" at 0x1a, flag 0x20 = 1, waits for the board's 0x21 = 40h
    command 3   board copies its 128-byte settings block to 0x100
    (blank)     V60 writes its defaults ("S32AF0", 42 5E 01 ...) to 0x100
    command 2   board stores them   (MAME: 2.2 s, an EEPROM write per word)
    command 3   V60 reads them back, then command 1 every frame (inputs)

On EPR-14869 the block read back after command 2 is right for 34 bytes and
**FF from DPRAM 0x122 on**, where the game wrote 00 - the first board's
EEPROM layout is not this game's - and the game runs on that block as its
settings. Reading 0x0e also differs: MAME 0x0F, EPR-14869 0xFF.

**WRONG AT FIRST: this was written down as the cause of the crash.** It is
not - the right board crashes identically (fault 1). It is a real fault in
its own right: the settings are the game's, the board answers in MAME's
time, and Wing War's stick, throttle and buttons reach it through this
board's firmware, not EPR-14869's.

### The fix: m1_ioz80 is model1io2 for game id 3

Ruled by `model1io2.cpp`, and by EPR-16891 itself (disassembled with
`tools/z80dasm.py`; a MAME census of the I/O Z80's memory and I/O space
named every device it touches):

- **memory map**: ROM 0000-7FFF (EPR-16891 has only 8 KB of code), RAM
  E000-FFFF, the 315-5338A at 8000h, board/jumpers/EEPROM DO at 8040h, DSW1
  at 8080h, the MSM6253 at 8200h-8207h;
- **315-5338A ports the other way round**: IN.0/1/2 on PA/PB/PC, reads that
  honour the direction register (the tick handler read-modify-writes PG);
  EEPROM on PF (bit 5 CLK, 4 CS, 6 DI); the ADC's secondary switch on PG6;
- **the TMPZ84C015's I/O space**: SIO status (the firmware's one poll waits
  on TX-empty), PIO A/B = DSW2/DSW3, and **a CTC**. EPR-16891 sets IM 2 with
  I = 0 and does ALL of its work in channel 1's interrupt (control A5h, time
  constant 26h: every 9,728 Z80 clocks, vector EAh -> 08FDh). The CTC is a new
  module, `m1_ctc`, in m1_ioz80.sv with its own bench (`make test_ctc`);
- **the EEPROM starts blank** for this board: no Wing War set has a
  93c45.bin, so MAME's part is erased, and the SDRAM block the preload reads
  would otherwise hold whatever game was loaded before.

The MRAs send EPR-16891 from `model1io2.zip` on index 2.

### Three things that were wrong on the way

1. **The board's own clock ratio broke the fetch stall.** model1io2's Z80 is
   9.8304 MHz against the V60's 16: 0.6144 of a V60 clock. At that rate two
   clock enables land on consecutive clocks, and **tv80s registers /RD and
   /MREQ a clock after the core moves A**, so in that clock `fw_miss` cannot
   see the new read and the second enable carries the Z80 through T1 on a
   stale cache word. Measured in the new `tb_m1_ioz80`: a firmware fetch for
   A = F001h, then RST 38h forever, straight after the LDIR at 0611h. The
   board runs at 1/2 of clk_cpu instead (81% of its real speed against the
   V60; the CTC counts the same enable, so it is uniformly slower).
2. **I/O reads and the interrupt vector were lost in T2.** The same one-clock
   lag: /IORQ is low from T1+1 to T2+1, the core samples the bus through all
   of T2, so a read decoded from /IORQ handed the Z80 the memory map's byte in
   T2's last clock. The vector came back as 08h (the 315-5338A status) and the
   first tick sent the firmware to CA30h. Each kind of cycle is now held from
   its strobe until the next memory cycle; INTA is /IORQ with neither /RD nor
   /WR. RETI is detected from opcode fetches whose /M1 is taken on the read's
   FIRST clock, because tv80's /M1 rises a clock before its /RD.
3. **The Wing War clone MRAs never had the coprocessor data ROM.**
   `tools/gen_mra.py` lists copro data for parent sets only, so the US, Japan
   and R360 MRAs sent the polygon ROMs to stream 0x600000, where the core reads
   the TGP's data ROM, and no data ROM or sincos tables at all. MAME's clones
   carry the parent's mpr-16739..16742. Hand-fixed; checked with stand-in zips
   (the parent's files under the clones' names) by `tools/verify_mra.py`:
   every byte of all three now matches the packer, and the US one did not
   before (358,000+ differing runs). US and Japan also take MAME's
   epr-16751.7 sound program, not the World set's epr-17126.7.

### Proof

- `make ioz80` (new, `sim/io/tb_m1_ioz80.sv`): the board alone on EPR-16891
  against MAME's boot exchange. 14/14: ready after 21,834,262 board clocks
  (MAME 2.15 s = 21.1 M), command 2 in 22.1 M (MAME 2.2 s), the block reads
  back as written, inputs 80 80 01 / FF FF FF / 0E = 0F exactly as MAME.
  Negative control `IOZ80_IO2=0` with EPR-14869: the block does not survive
  (128 of 128 bytes), 0x0e = FF.
- The first board is unchanged: the same bench on EPR-14869 against main's
  m1_ioz80.sv and this one gives identical clock counts at every step
  (366,411 / 3,432 / 312,268 / 721,767).
- `tb_m1_frame GAME=wingwar` (FRAME_IO2=1, EPR-16891, 600 M cycles): the
  exchange is MAME's cold boot step for step - ready f=210, command 3, the
  defaults written, command 2 accepted at f=321, the re-read block identical
  to MAME's in all 128 bytes, the per-frame command 1 from f=339 with
  0x0e = 0F. **And then the same halt at 40D007, f=585** - which is what
  sent the search to fault 1.
- With both fixes (2e99f55), the same run passes f=585 and shows the attract
  airbase scene with its 3D at frame 625, as MAME does (MAME cold: black
  at f=455, the scene by f=500; ours starts 79 frames later because the
  download and settle precede the V60's release). The run reaches 1,000 M
  cycles without halting: 484 vblanks, 81 objects / 1,134 quads, the city
  scene with the helicopter at the end. **The sky is grey where MAME's is a
  cyan gradient** - open.
- `make test` all fails=0 (one new line, `m1_ctc: checks=50 fails=0`;
  `m1_fetch_bridge` 175,156 -> 175,228 checks). `tools/run_m1_main.sh`:
  data_fetch, rom_readonly and muldiv_memory pass; the three FAST_IFETCH
  configurations fail as they did before this branch (findings 2026-10-28).
- Fit, Quartus 17.0 seed 3: 36,223 ALM, 523 M10K, 50 DSP; setup clk_3d
  +0.548, clk_sys +1.112, clk_cpu +5.398, pll_hdmi +0.181; hold all
  positive (worst clk_sys +0.185).

---

## 2026-10-29 — NETMERC'S "TWO 3D LAYERS": MAME SORTS PER VIEWPORT, THE CORE SORTED THE WHOLE FRAME AS ONE

Branch `netmerc-layers`, on `main` (1daae7a). Ben, from the board: "there
seem to be two 3D layers; one is drawn over the top of the 2D UI and on top of
3D characters that it should be behind."

### What the list carries (MAME, headless)

A census script (in `build/`, not committed: it walks the active display list
every frame and prints each viewport command with the objects that follow it)
on NetMerc with a coin at frame 600 and the trigger pulsed:

| frames | viewport groups, objects in each |
|---|---|
| attract (title), 0-600 and 7,200 frames without a coin | 0, 1, 1, 1 or 0, 0-1 - nothing that paints (render3d: 3 quads, 0 pixels) |
| gameplay, 2,600-4,000 | **three groups every list**, e.g. 29 / 6 / 11, 5 / 23 / 11, 12 / 23 / 11 |

Every viewport command in NetMerc has the SAME rectangle (centre 248,299,
edges 2..495, 41..420). The game is not opening windows; it is using the
viewport command as a layer separator: the terrain, then the enemies, then
the player's gun, hands and health bar.

The same census, 3,000 frames of attract each: **vr, vf, swa - one group in
every list. wingwar - two** (the second is the radar, 4 objects). So NetMerc
and Wing War are the only games the order below can affect.

### What MAME does with that, and what we did

`model1_v.cpp` `tgp_render`, `case 3`: `draw_objects()` BEFORE
`set_viewport` - which sorts the quads collected so far, draws them, and
empties the list. So the painter's order is per viewport, and a later
viewport paints over an earlier one whatever the depths. The z sort was only
ever right "per list" because VR, VF and SWA have one viewport a list.

`m1_quad_store` sorted every quad of the frame on z alone. NetMerc's terrain
is in the same camera space as the gun, and its near polygons are nearer than
the gun and hands, so they sorted after them and painted over them; terrain
in front of an enemy covered it.

### The "2D UI" is 3D

render3d has no tile layers at all and draws the health bar, the gun and the
hands (build/nm/after_3600.png in the worktree). They are the third viewport
group. NetMerc's gameplay screen has no tilemap content in MAME's frames but
the backdrop. The 3D-vs-tile priority (`m1_tile_mixer`, checked against
`screen_update_model1` on 2026-09-04) is not involved and was not changed.

### Reproduced, then fixed, in render3d

MAME frames 3000, 3600 and 3900 dumped with `tools/mame_dump_frame.lua`
(native-size snapshots, `-snapsize 496x384`), rendered by render3d at
58.947 MHz. NetMerc's stream is 21 MB and render3d wants 25 MB, so it is
padded with zeros. Compared per pixel against MAME's frame by SURFACE, not by
colour (hue/saturation class; the terrain is lit differently - see below):

| MAME frame | pixels on a different surface, before | after |
|---|---|---|
| 3000 | 18,075 (9.49%) - terrain over the floor, the hands, the gun's left side | 716 (0.38%) |
| 3600 | 24,264 (12.74%) - terrain over the hands, the gun and the floor | 677 (0.36%) |
| 3900 | 1,194 (0.63%) - terrain over the enemy on the right | 470 (0.25%) |

Virtua Racing's frames 2270, 2500 and 5460 render **bit-identical** before
and after, and so do Wing War's 2000 and 2600 (its radar group happens to sort
last on z as well).

### The fix

The key is `{viewport group, z}`: ascending group, then the old descending z
with submission order on ties. `m1_raster3d` numbers the groups: reset at the
pass start, advanced at a viewport command only if an object came since the
last advance (NetMerc opens some lists with an empty viewport), saturating at
7. The walk is paused for every object until `geo_done`, which waits for the
clipper to drain, so every quad of a group is in the store before the number
moves.

- **Three bits, for no block RAM.** A 2,048-deep key array is M10K in its x5
  mode: 32 bits took seven blocks and used 35. A 35-bit key fills them. The
  most groups seen in a list is four (NetMerc, some lists open with an empty
  one); past eight, later groups merge into the eighth.
- **Nine radix passes instead of eight, so the sort starts in `idx_b`.** Each
  pass moves the order to the other index array and the replay reads `idx_a`.
  Starting in `idx_a` with nine passes replays the order after eight - sorted by
  z and not by group, the fault itself. `tb_m1_quad_store` now models the group
  and fuzzes it, and has a NetMerc-shaped case where the last group is nearer
  AND farther than the terrain.
- The sort: 2,000 quads 34,330 -> 38,371 cycles (4.2% -> 4.7% of a frame).

### Not fixed, seen on the way

- **NetMerc's terrain is darker than MAME's** in every dumped frame (41-75% of
  pixels differ by more than 16 per channel; the surfaces match). Not
  investigated. `m1_geo_walk` already takes flags bit 22 for the second light
  bank.
- **Command 0x41 (above the HUD) is still drawn in the ordinary pass**, and
  direct polygons (command 2) are still not drawn. NetMerc uses neither (0 of
  either in every list of the census).

### A wrong turn

The first "after" render was byte-identical to "before" and looked like the
group counter never advancing. It was a stale binary: `make render3d` had been
piped into a grep whose pattern did not compile, the grep exited, make died of
the broken pipe before linking, and the old `tb_render3d` ran. Moving
`vp_grp`'s declaration above its first use (it was used in the store's port
list above where it was declared) looked like the cure and was not: a build of
the late-declared version renders identically to the fixed one. The
declaration stays above its use anyway. **Never pipe a build into a filter
that can fail; check the binary's time.**

### Benches and the fit

- `make test`: every suite `fails=0`. Only `m1_quad_store` moves:
  31,165 -> 30,135 checks (its fuzz now draws groups from the same generator,
  so the quad counts change; the old harness on the new RTL still reads 31,165,
  fails 0). The rules file's expected block says 18,500 for it, which was
  already stale on main.
- **`make render3d_fuzz` is broken on main**, independently: the target lacks
  the frame-buffer sources (`m2_ddr3`, `m1_ddram_mux`, ...), and with them added
  the bench paints 0 pixels and FAILs at cold start, because it was written for
  the band display. Built by hand with the full source list and
  `-GFB_DDR3=0`: 40 episodes PASS, base and fix, the same cold-start hash
  (`60b228b6a6b0fbe3`, 189,518 pixels).
- Seed 17, Quartus 17.0, against main at the same seed:

| build | ALM | M10K | DSP | clk_3d | clk_sys | clk_cpu | pll_hdmi | hold (worst ours) |
|---|---|---|---|---|---|---|---|---|
| main 1daae7a s17 | 36,102 | 523 | 50 | +0.771 | +1.065 | +6.230 | -0.189 | +0.206 |
| netmerc-layers s17 | **35,882** | **523** | 50 | **+0.996** | **+1.114** | **+5.751** | **+0.545** | **+0.250** |

  Block memory bits +24,576 (2 stores x 2 key arrays x 2,048 x 3), M10K
  blocks unchanged as predicted. ALM within seed noise of main.

---

## 2026-10-29 — STAR WARS' SOUND BOARD IS BUILT: 1,083 ALM BY quartus_map, ITS Z80 CUT DOWN TO 392

Branch `swa-sound`. Ben chose the faithful board (a real program on a Z80,
plus the decoder) and then a Z80 cut down to that program. Everything below is
benched; **nothing has been on the board yet**.

### What was built (rtl/sound/dsb_*.sv, all on clk_cpu)

- `dsb_z80` -- a microcoded Z80 that runs exactly the 76 opcodes
  `epr-16471.2` can reach (`tools/dsb/z80_census.py`: 391 instructions from the
  reset and IM 1 vectors, every opcode checked against the dispatch table) and
  traps anything else. 130 micro-ops of 40 bits in one M10K, dispatch through a
  1024 x 8 table in another. Documented Z80 T-states per instruction, I/O at
  the T-state tv80s commits it, only Z and C.
- `dsb_mpeg` -- ports e0-e9 with dsbz80.cpp's latch/loop/stop semantics, and a
  serial fixed-point Layer II decoder: one bit per cycle, one multiplier for
  everything, the 48-bit accumulator inside the DSP, 24-bit samples and history.
- `dsb_board` -- the two, `m2_i8251` for the UART, a 32 kHz output. The Z80's
  program (2 KB copy, loaded from SDRAM before it starts), variables
  (8000-83ff) and stack (fc00-ffff) are on chip; the rest of its 128 KB ROM and
  32 KB RAM and all 4 MB of MPEG data are in SDRAM through **port 11** (the
  controller is twelve ports now) and one `m1_cdc_port`.
- `Model1.sv` -- the sound 68000's transmit line is paced as the wire is (a
  holding and a shift register, 320 us a byte) and handed to the board; the
  board is held in reset unless the game is Star Wars (id 2) and its stream is
  in; its output is summed with the sound board's, saturated. O[20] picks the
  e8 reading (below).
- Data: the MRA appends `epr-16471.2`, `mpr-16514.57`, `mpr-16515.58` to
  index 5 and the loader's existing linear map carries them past PCM2: Z80 ROM
  at SDRAM word `0x1480000`, MPEG at `0x1490000`, Z80 RAM at `0x1690000`, all
  in space nothing used. **Nothing moved**; the only loader change is the end
  constant.

### What it costs (full quartus_map, base `3d-overrun` 786fcfb = 35,280)

    quartus_map  +1,083 ALM (36,363)    +3 DSP (53)
    fitted       37,199 ALM (88.8 %, seed 5; 37,163-37,259 over seeds 11/17/5)
                 537 M10K (+14, 16 free)   53 DSP   every clock positive
                 the board itself 999 ALM: dsb_mpeg 570, dsb_z80 339,
                 memories/cache/arbiter 86, UART 4; CDC 8; twelfth port 31

| block | LUTs | regs | memory bits | DSP |
|---|---|---|---|---|
| `dsb_mpeg` | 988 | 572 | 48,640 (7 M10K) | 3 |
| `dsb_z80` | 480 | 215 | 18,432 (2 M10K) | 0 |
| `dsb_board` itself (memories, cache, arbiter, T clock) | 120 | 116 | 32,768 (4 M10K) | 0 |
| `m2_i8251` | 7 | 13 | | |
| `m1_cdc_port` | 7 | 113 | | |
| `m1_sdram` going 11 -> 12 ports | +19 | +57 | | |

### The Z80, three ways, by standalone quartus_map

    tv80s, full Z80                                956 ALM
    per-opcode state machine, cut down            1,543 ALM   <- worse than the full Z80
    microcoded, cut down (shipped)                  392 ALM   (+2 M10K)

**A cut-down CPU written as a case per opcode is bigger than a whole Z80.**
Every opcode grew its own path into every register and the address bus, and
the muxes cost more than the opcodes saved. Driving a regular datapath (seven
registers, PC/SP/TMP, one 16-bit adder, one 8-bit ALU) from a ROM got it to
490, and moving the opcode dispatch from logic into an M10K to 392.

### The decoder, standalone: 844 -> 718 ALM, and the accumulator that would not go into the DSP

The 48-bit accumulator lands in the DSP block only in one shape: operand muxes,
the negation applied to an operand, `acc <= (load ? const : acc) + a * b`.
Written as `acc +/- a*b` (dynamic subtract) Quartus keeps all 48 bits and the
adder in ALMs -- tested in isolation, eleven variants. The other savings: the
FIFO written straight from the window result with byte enables, Nal and p1
taken from x and from the accumulator instead of registers, a tagless one-word
bit buffer, and a remaining-bits down-counter so every end-of-data test is a
sign check instead of a 27-bit comparator.

### Evidence

- **Decoder, bit-exact against `dsb_fixmodel.h`:** every song in the table,
  and every loop restart, played to its end -- 25,944,992 stereo samples, 22,522
  frames, 0 differences, SDRAM latency [1, 40] cycles. The short form in
  `make test` covers ends, loops, the loop abort, stops and plays mid-frame:
  105,764 samples, at latency 1, 20 and 400, and again at the real 32 kHz rate
  with the FIFO full.
- **Z80 against tv80s on the real program, MAME's 300 s of input:** 6,843,318
  port accesses (26,693 writes, the rest status polls), identical in value and
  in T-state; no trap.
- **The whole board against MAME's capture** (`tb_dsb_board`): 70 s -- 6,167
  port accesses identical to MAME's in order and value, mean +0.7 us late,
  worst +0.8 us; 460,288 decoded samples bit-exact; every 32 kHz output sample
  equal to the decoded one with volume and pan applied. 300 s: see HANDOFF.
- MAME's capture against the C model: within 1 LSB on every sample (2026-10-28 (c)).

### Things MAME does that the bench found, and the RTL now does

1. **A frame that fails at the end address still moves the synthesis history.**
   MAME decodes granule by granule and throws only when a read crosses the end,
   so every complete granule has already gone through the filterbank. A
   precheck that skipped the frame left a different history behind and the next
   song's first 512 samples differed.
2. **A stop does not undo synthesis.** MAME has the whole playing frame
   decoded when a stop lands, so the history is at its end. The RTL finishes
   that frame muted (matrixing only). The one case it cannot match: a stop in
   the last 64 samples of a frame, when it has already started the next.
3. **The end address is latched per frame.** The firmware stops, writes the
   next song's start and end, and plays -- while the stopped frame is still
   finishing. Reading the end live failed that frame.
4. **A reference that decodes lazily is wrong.** MAME decodes the next frame
   the moment the last one runs out; a bench reference that waited for the next
   sample skipped a failing frame when a stop came first and reported 285
   "failures" that were its own.

### The e8 volume writes: firmware reading by default, MAME's on O[20]

The firmware writes `e8 80`, `e8 c5` after every level it sets and `e8 c4`
every 256 passes of its main loop; MAME takes them all as volume. Every level
the firmware computes is masked with `0x7e` -- bit 7 is never set in one -- and
its fades write `e8` once per step and nothing else, which MAME's reading
would cancel within 256 passes. So the default treats a write with bit 7 set as
something other than volume: music plays at the song's own level (song 1:
`0x50` -> 47/127) and fades work. O[20] = MAME gives MAME's 0x3b/0x7f.
**Neither is confirmed against a real board.**

### Wrong along the way

- The class map for subbands 0-2 sent allocation index 2 to class 4 (it is 3).
- The volume multiply was 16 bits wide, a SystemVerilog sizing trap.
- `io_rdata` was gated on the strobe, which the Z80 samples the cycle before:
  every UART read returned 0 and no command was ever seen.
- The Z80's every access went to SDRAM: **755,000 words a second**, a tenth
  of the controller's time. Its program, variables and stack are on chip now:
  11,800 a second over the first four seconds (the boot-time clear), then none.
- At latency the Z80 cannot hide (uniform [1, 80] and up) it falls behind
  real time; at [1, 400] its boot finishes 0.18 s late, after the 68000's first
  byte (a stop) has arrived, and the UART reset in its init drops it. Harmless
  (the byte is a stop to nothing), and at [1, 40] the boot is ~0.8 ms late,
  against 56 ms of margin before that byte.

---

## 2026-10-28 (c) — STAR WARS' SECOND SOUND BOARD, MEASURED: WHAT IT IS AND WHAT IT WOULD COST

Branch `swa-sound` (on `3d-overrun`, `786fcfb`). Research only -- **nothing is
built**, because the faithful design does not fit the budget it was given
(<= ~1,500 ALM, >= 10 M10K left) and that is Ben's decision. Instruments:
`tools/mame_dsb_cap.lua` (MAME 0.289, headless, 300 emulated seconds: attract,
coin at 150 s, start at 152 s), MAME's debugger `dasm` of `epr-16471.2`, a
bit-level scan of `mpr-16514/16515`, and `tools/dsb/` (a bit-accurate C model
of the planned decoder against MAME's own `mpeg_audio.cpp`).

### The board (MAME `dsbz80.cpp`, `model1.cpp` swa())

- **Z80 at 4 MHz** (MAME: "unknown clock"). `0000-7fff` ROM = the first 32 KB
  of the 128 KB `epr-16471.2`; `8000-ffff` 32 KB RAM.
- Ports: `e0` trigger (0 stop, 1 play, 2 play+loop), `e2-e4` start (reading
  them returns the play position), `e5-e7` end, `e8` volume (`~d & 0x7f`),
  `e9` pan (0 stereo, 1 left on both, 2 right on both), `f0/f1` an i8251.
  Writes to `ea`/`eb` are unmapped in MAME (the firmware writes them).
- **Its only input is the sound 68000's UART TRANSMIT line**, not the V60's:
  `m_m1audio->rxd_handler().append(dsbz80 write_txd)`. In this core
  `m2_sound_board`'s `tx_*` is tied off (`tx_ack(1'b1)`), so the wire exists
  and is unconnected.
- **Interrupts play no part.** The IM1 vector at `0x38` is `di; ei; reti`, and
  the main loop runs with `di` (at `0x01a3`), polling the UART status.
- Output: MPEG-1 Layer II, 32 kHz stereo, scaled `sample * vol / 128` and
  summed with the main sound board's speaker.

### The firmware is 725 bytes

`0x0100-0x03d4` is the whole program; `0x03d5` is a 15-entry song table. Command
bytes: `00` stop, `01-0f` play song n, `10-7f` ignored, `80-ef` fade out
(rate from the low 7 bits), `f0-fe` volume step, `ff` restore volume. Fade and
delayed-stop timing is **counted in main-loop passes**, so it depends on the
Z80's speed -- a Z80 slowed by memory stalls fades slower.

**A volume quirk the reference carries:** the main loop writes `e8 c4` every
256 passes (26,628 times in 300 s). MAME treats every `e8` write as volume, so
in MAME the music sits at `0x3b/0x7f` (46 %) most of the time, not at the
song's table volume. MAME's own TODO says bit 7's purpose is unknown; on the
real board those writes are probably something else. Unresolved.

### What the game actually sends

In 300 s, **six bytes**: `00` at 0.23 s, 3.74 s, 14.35 s, 150.31 s; `01` (song 1,
`0x334000-0x3f4000`, no loop, volume `0x50`) at **55.62 s** in attract and at
**191.58 s** after the start. So the attract theme is song 1 and appears 55 s in.

### The MPEG data

All 4 MB is **7,281 frames, every one MPEG-1 Layer II, 32 kHz, 128 kbit/s,
stereo, no CRC** -- 576 bytes each, ~262 s of audio. **They are not byte
aligned**: the first sync word is at bit 3,651. One header, one allocation
table (table 0, 27 subbands), so the decoder only ever needs that one format.
MAME scans for sync bit by bit, continues from where a frame's data ended,
**drops a frame that would cross the end address**, never clears the synthesis
history between songs, and rounds with `int(x*32768 + 0.5)` (truncation toward
zero).

### Precision, priced in M10K (`tools/dsb/`, all 15 songs + loop restarts, 22,481 frames, 51.8 M samples)

    S / V width   error vs MAME (16-bit samples)      V RAM (2 ch x 512)
    40 bits       0: 99.88 %   1: 0.12 %   max 1      -   (first 6 entries only)
    24 bits       0: 81.5 %    1: 18.5 %   max 1      3 M10K
    20 bits       0: 73.3 %    1: 26.5 %   2: 0.16 %  2 M10K

No position ever diverged from MAME's. MAME decodes in doubles, so bit-exact
against MAME is not available to fixed point at any width; the RTL is meant to
be bit-exact against `dsb_fixmodel.h`, and that against MAME as above. The
synthesis window is exactly k/65536 (max 75,038, 18 bits signed) and 504 of
its 511 pairs are antisymmetric.

### Reusable HDL

No open-source Layer II decoder found; the nearest is an OpenCores MP3
(Layer III) VHDL project, and Maintech's Layer II core is commercial. The Model
2 core has none either (its STCC uses the same DSB, unbuilt). tv80s is already
here (I/O board).

### Cost

**Superseded 2026-10-29 by measurement** (entry above): the board as built is
1,083 ALM by quartus_map, because the Z80 was cut down to 392 instead of
tv80s's 834. The estimate as it stood:

    piece                                      ALM            M10K   DSP   basis
    tv80s                                       834            0      0     MEASURED, I/O board instance, 3dfb fit
    Z80 glue (pacing, cache, RAM/ROM/MPEG mux,
      port decode, i8251 from m2_i8251)         150-250        0      0     estimate
    SDRAM port 12 (+CDC if on clk_cpu)          60-120         0      0     estimate; m1_cdc_port 7-27 measured
    MPEG register file, trigger/loop logic      ~100           0      0     estimate
    Layer II decoder (one MAC, bit-serial)      600-900        3-5    1-2   estimate
    32 kHz pacing, vol/pan, mix                 ~50            0      1     estimate
    ---------------------------------------------------------------------
    faithful total                             1,800-2,250     3-5    2-3

Against 35,849 that is 37,650-38,100 ALM -- **at or over the 90 % line**, with
nothing left for the V60 fix or a polygon RAM. Replacing the Z80 with a state
machine that runs the same 15 commands off the real song table (in SDRAM)
would be ~150-250 ALM instead of ~1,000-1,100, for **~950-1,400 total** --
inside the budget, but an imitation of a program, which is what R60 moved the
I/O board away from. That choice is Ben's; see `docs/HANDOFF.md`.

### Where its data would live (nothing moves)

SDRAM word `0x1048000-0x107ffff` (448 KB, free between `SND_RAM` and
`SND_PCM1`) for the Z80 ROM (128 KB) and RAM (32 KB); the 4 MB of MPEG at word
`0x1480000` (41 MB), above `SND_PCM2`, which is where the map currently ends.
The Z80 does write all 32 KB (a boot-time clear) but lives in `0x8100-0x8126`,
`0x8200`, `0x8300` and the stack, so off-chip RAM costs only stalls.

---

## 2026-10-28 (c) — STAR WARS' SHIPS ARE MISSING QUADS BECAUSE HALF OF EVERY DISPLAY LIST WAS NEVER STORED

Branch `vf-swa-geo`. Ben: the first large ship in Star Wars' attract is
missing quads (HANDOFF 0: "the Star Destroyer draws as thin pale slivers";
0c: "a ship is missing from the attract intro"). Both are this.

**The colour words never arrived.** Star Wars uploads its whole colour table
(123,623 tgp_ram words) through display-list command 4 during boot, eight
blocks of 0x3c00 words in list 0 at offset 0x38, MAME frames 21-133. Command
4 reads its payload at a two-word pitch (`readi16(off + 6 + 2*i)`), so each
block runs from word 0x3e to word **0x783e**. m1_mainram holds only the
bottom 16,384 words of each list - a cap measured on Virtua Racing (max
0x3fff over 40 s) and recorded as "a program constant". Everything above
0x4000 was dropped: of each block, colour words 0x1fe1 onward. 56,287 of
121,575 colour words never existed in our tgp_ram, and every polygon using
one drew with colour word 0 (palette 0x1000).

**Measured, three ways:**

- **MAME's lists, our renderer, MAME's colour words** (`render3d` on
  `tools/mame_dump_frame.lua` dumps): the corvette (frame 1400) and the Star
  Destroyer (2000, 2300) draw correctly - the 3D path is not at fault.
- **The same with the colour words removed the way the core removes them**
  (every index whose block offset is >= 0x1fe1): the corvette paints **0**
  pixels of 56,442 - the ship is gone - and the Star Destroyer **43,647 of
  69,339** and **41,281 of 74,889**: quads missing all over the hull. That is
  both board reports. `build/swa_cap_before_fix.png`.
- **The full system** (`tb_m1_frame GAME=swa`, board clocks): the far ship's
  two objects are walked (`OBJ:` 1,102 and 304 quads, on screen at x 231-287)
  and the frame at 1,420 has **0** non-black pixels there. render3d with that
  same frame's list and MAME's colour words paints 783.

**Every set, measured** (MAME, 4,000 frames, the list rendered that frame):
Virtua Racing, Virtua Fighter and Virtua Formula never pass word 0x2006; Star
Wars passes 0x4000 only with command 4, at boot; **Wing War and NetMerc pass
it with command 4 in play** (frames 283 and 182 on), so both have been
losing colour words too.

### The fix: the upper half in SDRAM, in space the layout already leaves free

Doubling the two lists on chip is +64 M10K (16K x 16 true dual port is 32
apiece) against ~28 free. Instead the upper half of each list lives in SDRAM
at **0x19C0000** - the 256 KB gap between tgp_ram (0x1840000-0x19bffff) and
the I/O firmware at 0x1A00000. **Nothing in the layout moves**; the loader
and the MRAs are untouched.

- **V60 side** (`m1_main`): a display-list access with word address >= 0x4000
  (`m_addr[15]`) is an SDRAM access at `DLHI_BASE + {list, word[13:0]}`,
  through the same path as work RAM.
- **3D side** (`m1_integrated`, new `rtl/video/m1_p6_arb.sv`): the walker's
  reads above 0x4000 go through p6, the port tgp_ram already uses, and the
  two share it through a one-owner arbiter. The walker already holds its
  request until valid, so it needed no change. **The arbiter latches the
  access at the grant** and keeps the list word in a tagged buffer until the
  walker asks again: the first version drove the port from the requests, and
  `tb_m1_p6_arb` caught the walker's stall (which drops mem_req) making a
  request fall and rise around its own acknowledge - which m1_cdc_port takes
  as a new transaction, so the next owner was handed a stray word.
- `make test_p6_arb`: both requesters at random, the walker stalling, against
  a port at random latency 2..2, 2..20 and 2..200 cycles; 5,641,907 checks, 0
  fails.

### After

- **tgp_ram after the boot uploads**, out of the full system's SDRAM model
  (`+define+TGPRAMDUMP`, frame 300): **121,575 of 121,575 words equal to
  MAME's**, including all 56,287 that were missing.
- **Our own V60's lists** (the full-system run's dumps at frames 1500, 1900,
  2000) through render3d: with the old colour state 0 / 40,491 / 31,016
  pixels; with the fixed system's tgp_ram 2,050 / 49,577 / 62,859 - and the
  1900 and 2000 frames are **byte-identical** to the same lists rendered with
  MAME's colour words. `build/swa_before_after.png`, and the full system before
  the fix in `build/swa_fullsys_before.png` (corvette absent, Destroyer holed).
- The full-system run with the fix (`build/run_swafix`) was still short of
  the ship frames when this was written.

### Everywhere else

Virtua Racing never reaches the upper half, but every tgp_ram access now
takes the arbiter's latch cycle, and that moves SDRAM grant timing for the
V60 (its cycle hash parts from tile-overrun's at frame 129). Board clocks,
attract (the bench sits in VR's test menu), FRAME_PPM=1, every frame of 404
compared against tile-overrun: **402 identical, 2 differ** - frame 395, the
menu's header band being redrawn while it is scanned out, torn at a
different line (3,557 px, rows 13-72), and frame 401, one scanline (row 363).
Both are the "screen wiped while drawn" class recorded under tile-overrun:
the same content reaching the screen a few lines earlier or later; the frames
either side are identical and so is the last frame of a 462-frame run.
`build/vr_frame395_base_vs_fix.png`.

### Cost

quartus_map 34,566 -> **34,644 ALM (+78)**, block memory bits unchanged
(3,912,698) - no M10K. Fitted with the V60 fix (this branch, 3eba4a6):
**seed 11 35,282 ALM, 525 M10K, 50 DSP**, clk_3d +0.837, clk_sys +1.185,
clk_cpu +6.515, pll_hdmi +0.673, worst hold +0.245;
`build/Model1_vfswa_seed11_35282.rbf`, md5 `0a9941d96296dcd2a021bf8fb2faedbd`.
Seed 5 35,300, every clock positive (clk_cpu +4.522); seed 3 35,344 with
clk_sys -0.200 and pll_hdmi -0.259.

---

## 2026-10-28 (b) — VIRTUA FIGHTER'S ARENA IS A DROPPED V60 STORE: `mulu.w #A, 501276` NEVER WROTE BACK

Branch `vf-swa-geo`, on `tile-overrun`. Ben: the fighting arena is the wrong
size in a real match; fighters right, arena right in attract and character
select. README's open questions named polygon RAM (command 0x05), the masked
bit 23 and direct polygons (0x02); findings 2026-09-10 had narrowed it to "the
matrix arrives wrong, so the V60 or the coprocessor produces it".

**It is the V60.** Three instructions at FCCA33 compute a value from the
game settings and send it to the coprocessor as the second argument of its
very first command:

    FCCA33  movz.bw FCC9F6(R0), 501276    table 75,70,65,60 by setting
    FCCA40  mulu.w  #A, 501276            x10
    FCCA48  cvt.ws  501276, 501276        to float
    FCCA64  mov.w   501276, [R24]         -> TGP, command 01000000

MAME pushes `01000000 3c23d70a 442f0000` (0.01, **700.0**); our core pushed
`01000000 3c23d70a 428c0000` (0.01, **70.0**). The multiply never happened -
or rather it happened and was thrown away: `S_MULDIV` ended with
`md_finish(); st <= S_NEXT;`, and md_finish's wb_op2 had just set
`st <= S_WB_MEM` for the memory destination. The later non-blocking
assignment won. **Every MUL/MULU/DIV/DIVU/REM/REMU with a memory destination,
at every width, in every game, computed its result and dropped it.** The
third instance of the pattern after S_IN_RD and S_ROTC, both fixed earlier
with exactly the same one-line guard (`if (flag2) st <= S_NEXT`), and both
recorded as "found by scanning for the pattern" - the scan missed this one.

### How it was found, in order

1. **The candidates in README, re-measured against a running MAME through a
   real match** (`tools/mame_geo_census.lua`, attract + select + two rounds,
   3,000 frames, the list rendered that frame): **0** direct polygons,
   **0** polygon RAM uploads, **0** objects with poly_adr bit 23. That is
   what 2026-09-09 (6) said; README had kept the older suspicion. Eliminated.
2. **The coprocessor, replayed against MAME's own traffic.**
   `tools/mame_tgp_stream.lua` records everything the V60 says to the TGP
   from reset (FIFO pushes, copro RAM address/data writes, in BOTH address
   spaces) and every word the TGP pushes back (tapped at the TGP's data 0x400,
   not at the V60's reads, which carry phantom zeros from stalled pops).
   `sim/tgp/tb_tgp_replay.cpp` (`make tgp_replay`) feeds that to `m1_tgp`
   alone. Virtua Fighter boot -> attract -> select -> match, 2,000 frames:
   **1,484,210 answers, 0 different**, also with random 0-7 cycle memory
   jitter and at 20-cycle latency. Virtua Racing 805,532 and Star Wars 54,576,
   0 different. **The coprocessor is exonerated** - the 2026-09-10 suspicion
   (its matrix stack) is withdrawn.
3. **Our V60's command stream against MAME's**, framed into commands by the
   dispatcher's pop (`tools/tgp_cmd_frames.py`; pc 02a on this microcode).
   The **first command** differs, in the one argument above.
4. **The ROM read at that address** (MAME's debugger `dasm`), then a directed
   test with the game's own bytes: `sim/cpu/tb_v60_mul_mem.sv`.

### The fix and its test

One line in `rtl/cpu/v60/v60.sv`: `st <= S_NEXT` moved BEFORE `md_finish()`,
so wb_op2's `S_WB_MEM` is the later assignment and wins. **Found
independently, the same evening, on branch `vr-freeze` (89a636a)**, from
Virtua Racing's side: its attract wraps the course number with
`rem.b #3, 501934[PC]` at FE207A, the 3 stayed 3, the bank register became 4
and the scene loader copied memory over itself - the freeze at the end of
every attract cycle. This branch first had the S_ROTC form
(`if (flag2) st <= S_NEXT` after the call); it now carries vr-freeze's text
byte for byte so the two branches merge as one change. Both forms pass the
sweep below (1,084 of 1,084).
`make test_v60_mul_mem` (in `make test`): the game's FCCA33 sequence, then
every MUL/MULU/DIV/DIVU/REM/REMU at byte, half and word with a memory
destination - 12 edge values (0, 1, -1, 10, 70, 700, 0x7f/0x80, 0x7fff/0x8000,
0x7fffffff/0x80000000) and 48 LCG pairs each, 1,080 cases, checked against
the C semantics MAME implements. Before (the tile-overrun V60):
`checks=1084 fails=874` - the 210 that pass are the ones whose answer equals
the untouched destination (x*1, 0*y, x/1 ...). After: `checks=1084 fails=0`.
The V60 unit suite stays 29/29.

**What else executes one.** MAME debugger traces from reset: Virtua Fighter
through attract, select and a match (1,300 frames) executes exactly one
memory-destination multiply/divide, FCCA40, three times (boot and the start
of each match). Star Wars Arcade to the Star Destroyer (2,100 frames)
executes none - 1,942 `div.h`, 1,002 `remu.h`, 302 `mulu.b`, all to
registers. 2,000 frames of attract each: Virtua Formula, Wing War and NetMerc
none; Virtua Racing one, `inc.b 50119C ; rem.b #4, 50119C` at FE24F5 (a
counter wrapped mod 4 - unchanged until it would pass 3), besides vr-freeze's
FE207A. Traces run headless (`-debug -debugger none`, trace started and
stopped from Lua): a plain `-debug` opens the debugger window and can sit
stopped in it, which one run here did, on Ben's desktop.

### Before and after, the full system

`tb_m1_frame GAME=vf`, board clocks, `sim/input/vf_match.txt`, the same
inputs both runs (`build/vf_before_after.png`, `build/vf_fixed_fight.png`):

- **tile-overrun**: frame 780, ROUND 1 - the ring a small block in the sand,
  both fighters standing outside it; frame 900 "DRAW" with the clock at 30.
- **with the store fixed**: frame 780 the stone floor to the horizon with
  both fighters on it, as MAME; frames 980-1080 a fight, the clock running
  (28" -> 26"), Akira's health dropping.
- Our in-system coprocessor traffic through the match start (295,356
  answers, 790 frames) replays with 0 differences - nothing else in that
  path changed.

Identity elsewhere, Virtua Racing attract at board clocks with FRAME_HASH=1,
462 frames: the **video hash is identical on every frame**; the CPU and 3D
hashes part at frame 402, where VR's own memory-destination remainder starts
to store (the extra write cycle moves bus timing).

### Cost, fitted (Quartus 17.0, tile-overrun + this line)

quartus_map 34,615 -> 34,566 ALM (noise; the change is one assignment
moved). Fitted, three seeds: **seed 5 35,293 ALM, 525 M10K**, every clock
positive at the slow corner - clk_3d +0.039, clk_sys +1.813, clk_cpu +5.715,
pll_hdmi +0.280, worst hold +0.186; seed 3 35,143 (clk_3d -0.016, pll_hdmi
-0.709), seed 11 35,165 (clk_3d -0.700). `build/Model1_vfmul_seed5_35293.rbf`,
md5 `968cf0d66b7f07cc2a2924fa1932fbcb`. clk_3d at +0.039 is thin; tile-overrun's
own seed 5 had +0.891, so this is placement, not the change - reseed before
reading anything into it.

### Why the arena and only the arena

The value is a size the game hands the coprocessor once and the arena's
sixteen ring objects are built from (`2f000000`, then `27000000 + i` for
each, FF0611). The fighters are posed through other commands and never
touch it; attract uses its own fixed staging. Our bench showed it the other
way too: at round start the ring is drawn a tenth of its size and both
fighters are outside it - "DRAW" with the clock still at 30.

### What turned out wrong

- Polygon RAM, bit 23 and direct polygons (README): not issued by this game.
- "The matrix stack in the coprocessor" (2026-09-10): the coprocessor answers
  every one of 1.48 M commands exactly.
- **A copro RAM ordering race, mine, this session.** The replay can let the
  TGP lag the V60 (`RACE=1 SLACK=n`): at 5,000 answers of lag Virtua Fighter
  gets 154,614 wrong answers, because it uploads each object's block to
  0x1500 and pushes `33800000 00011500` without reading back before the next
  upload. A gate in m1_copro_if that held the committing write until the TGP
  was quiet was built and tested - and then measured unnecessary: with the
  board's 16-word FIFO modelled (`FIFO=16`, V60 infinitely fast) it is
  **0 wrong at 1 and 20 cycles of memory latency**, and our own in-system
  stream replays clean. Reverted, unbuilt. The hazard is real if the FIFO
  ever deepens; the replay modes stay in the bench to show it.
- Also found and reverted with it: m1_copro_if shares ONE low-half latch
  between the RAM window and the FIFO, where MAME has two
  (`m_v60_copro_ram_latch[0]`, `m_v60_copro_fifo_w`). A command push between
  a RAM low half and its commit would replace the low half. The census found
  no game that interleaves them (Virtua Fighter's 69,109 commits are each
  immediately after their low half), so it is recorded, not changed.

### Polygon RAM, measured for the record (Ben asked)

Command 0x05 and objects with bit 23, MAME, the list rendered each frame:

| game | uploads | words | address range | objects that READ it |
|---|---|---|---|---|
| Virtua Fighter (boot, attract, select, 2 rounds) | 0 | 0 | - | 0 |
| Star Wars, attract (4,000 frames) | 1 block, re-sent in the boot list frames 150-166 | 1,421 (0x58d) | 0x800000-0x80058c | 0 |
| Star Wars, play (12,000 frames, firing) | the same, at boot only | 1,421 | the same | 0 |

1,421 words is 5.6 KB - six M10K at 2048x5 or 512x40, well inside the ~49
the 3D frame buffer port would free - but **nothing reads it** in anything
measured, so there is nothing to build. Not built.

---

## 2026-10-28 (b) — THE 3D OVERRUN IS BANDS FILLED PAST THE BEAM ON THE BEGINNER COURSE'S HILLS; THE 3D NOW DRAWS WHOLE INTO DDR3

Branch `3d-overrun`, written on `alm-save` (0ac55df) and rebased onto
`tile-overrun` (4253a86) so one board build carries both. Ben: a small, long-standing
3D overrun in Virtua Racing, track 1, the second or third corner - the 3D
bands running late, not quads dropped.

### Reproduced, and why no bench had

**Instrument: `tools/mame_vr_drive.lua`** drives MAME round the beginner
course (an autopilot that steers toward the grey road just above the car, read
off MAME's own screen - it laps Big Forest at full throttle) and dumps every
20th frame from 1100 to 3100 for render3d (101 frames). **render3d at the
board's clk_3d, 58.947 MHz** (new `CLK3D`; it had always run at the old
47.059), DDR3 at 40 cycles, the base (`alm-save`):

| MAME frame | where | least band slack | rows on screen |
|---|---|---|---|
| 2760 | the hills after the first corners, checkpoint ahead | **-1.13 lines** | 383 of 384 |
| 2780 | the same | **-1.36 lines** (band 22, a fill of 31,766 cycles, 149% of a band) | 383 of 384 |
| 2800 | the same | -0.02 | |
| 2880, 2900 | further on | +1.35, +1.43 | |

Slack is the lines between a band's hand-off and the beam reaching its first
row. Negative is a band put up with the beam already inside it: the rows above
the beam show the 2D for that frame. The same frames against DDR3 latency
(the payload): -1.1 at 10 cycles, -1.2 at 100, **-7.3 at 400, -53 at 1,000**.
It is the FILL, not the memory: the worst band is 1,244 quads replayed.

Why it was never seen:

- **No bench reached the hills.** The race bench stops at the pit start.
- **`dbg_late` (the board's T=) does not count it.** It counts a band
  presented with the beam in a LATER band (`beam_ext > want_ext`); a band
  presented with the beam inside its own first rows - every one of the above -
  counts nothing. tb_m1_frame now counts rows lost (`LATE3D`).
- render3d's own constants were stale: BAND_H 16 for its "% of a slot" and
  47.059 MHz, which overstated every slot by 2x and understated the clock.

**The full-system bench, `tb_m1_frame`, with the same autopilot** (AUTO_AT,
reading its own picture) and the board's clocks (29.474 / 58.947 MHz - the
base run used this branch's REALCLK before the rebase, the same half periods
as tile-overrun's BOARD_CLOCKS, which replaced it):
alm-save (the build on the board), `vr_race.txt` then the autopilot from
cycle 1.35e9, DDR3 at 40. The bench lapped the course to the same hills and
checkpoint (its frames ~2300-2450). **LATE3D: 24 frames lost 3D rows - 108
rows in 48 late bands, all between frames 2410 and 2455, up to 18 rows in one
frame (2444-2445). The same run's `OVERRUN` line - dbg_late, the board's T= -
read late=0 throughout.** That is the board's tear, reproduced in the full
system, and the blind spot in the counter that let it hide. No DDR3 traffic
before the ROM was in. (Run: `build/snap_base/race.log`, 3,158 frames.)

### The fix: the 3D drawn whole into DDR3 (Ben's call: the Model 2 core's frame buffer)

`m1_raster3d FB_DDR3=1` (the build default; `FB_DDR3=0` is the band display,
cycle for cycle - render3d's logs and pictures are identical to the base's):

- The list is drawn ONCE, band by band, into one of two DDR3 frames
  (0x30080000 up, above the quad payload). Nothing races the beam.
- A frame drawn whole by scan line 416 is shown from the next frame start; one
  that is not is not shown, and the last whole frame stays up (counted: H=).
- The scanout fetches each line three lines ahead into four line buffers
  (`m1_fb_read`, the Model 2 core's m2_fb_read at 47ad2e2) - the mixer's
  rd_col/rd_hit are unchanged; the frame's first four lines are fetched just
  after the publish line, before line 0 (Model 2's R657); the writer is held
  while a line is owed (R655) and through the publish window.
- `m2_ddr3` and `m2_ddr3_arb` are Model 2's, unchanged. `m1_ddram_mux` shares
  the one DDRAM port with the quad payload (in-order read replies routed by a
  queue of owners; a write burst never split; the grant never moved under BUSY).

**The writer is not Model 2's**, and that was measured, not assumed:
`m2_fb_write` (a DDR3 command per span, head/body/tail) was ported first and
drew MAME frame 2780 in **538,361 cycles (0.53 of a frame)** against a fill
of about 290,000 - Model 1's spans are polygon rows, each its own command, and
Model 2's combining writer (R661) combines adjacent words on one row, which
successive Model 1 spans never are. So the band buffer is the write combiner:
the fill draws a band into one of TWO band buffers exactly as before, and
`m1_fb_flush` copies the finished band into DDR3 (16-beat bursts) while the
fill draws the next into the other, emptying the buffer behind its reads so no
band clear is needed and the frame needs no clear either (every pixel of every
line is rewritten). The line in DDR3 is 124 words of RGB565 (four pixels a
word) then 8 words of painted bits - half the beats of Model 2's 32-bit
pixel; frame 1180's draw had been waiting on the copy longer than it filled.

| | per-span writer | band copy, 32-bit | + clear-behind | + 16-bit layout |
|---|---:|---:|---:|---:|
| frame 2780 draw (cycles) | 538,361 | 337,043 | 289,636 | ~287,000 |
| render3d default frame (47 MHz) | 281,478 | 177,432 | 152,199 | 123,631 |

### Proof

- **101 MAME frames, render3d at 58.947 MHz, DDR3 40: every picture byte
  identical to the reference** - the base rendered at 200 MHz, where no band
  is late. The base itself differs on the late frames (rows 176-177 of 2780
  missing).
- **The worst six frames x nine DDR3 settings** (latency 10/40/100/400/1,000;
  BUSY 50-500 per mille with 30-50% of reply beats withheld): all 54 pictures
  identical to the reference, **0 scanout lines late, 0 protocol errors**. The
  draw stretches from 0.27 to 0.65 of a frame at the hostile end; the picture
  does not change.
- `make test`: every existing suite's count identical to `tile-overrun`'s (and
  to `alm-save`'s bar its m1_tile_fetch), and five new:
  `m1_ddram_mux: checks=796258 fails=0` (two masters of the two real shapes,
  four DDR3 settings to 1,000 cycles / 90% BUSY; three mutations of the grant
  logic each caught), `m1_fb_flush: checks=93120 fails=0 bands=30` (through
  the real m2_ddr3, every DDR3 word and every clear checked; two of three
  mutations caught, the third is unreachable by timing), `m1_fb_read: checks=24`,
  `m2_ddr3: checks=19`, `m2_ddr3_arb: checks=26` (Model 2's benches).

### Bugs found on the way, none of which a unit bench saw

1. **The fill reports a quad done with its last span still offered**
   (m1_raster_fill says so), and a span taken is painted for up to 124 cycles
   after. A band handed to the copy at quad_done lost that span, and the
   clear-behind - refused while the buffer painted - left it for the next band
   in that buffer. Before the clear-behind the copy just missed it: one pixel
   wrong in 50 of 101 frames. With it, the late span survived into the next
   band in that buffer: a whole row (row 8, band 47's bottom road) in 54. The
   band display has the same race and never cared, because a band is shown a
   band-time later.
2. **The band ring rotated the band buffers under the copy.** ev_handoff fired
   every cycle of C_WAIT in frame-buffer mode too; it is the band display's
   alone now.
3. **The DDR3 models ignored byte enables** (render3d's and tb_m1_frame's):
   harmless while the payload wrote whole words, 4,110 wrong pixels the first
   time a half word was written - every odd span end.
4. **A grant on a presented command deadlocks m1_ddram_payload**, which raises
   a command only after a cycle of !BUSY: it got neither. The mux grants on its
   `want`.
5. Quartus put the mux's owner queue (read combinationally) in two M10K;
   it is `ramstyle = "logic"` now.

### What it costs - LATENCY, and Ben has to decide this

The band display could start showing a list the frame after its pass was ready
by line 376; the frame buffer must also DRAW it by line 416. The draw is 70-118
lines. It is fill-bound: on MAME frame 1940, of the draw's cycles 22% wait
on the store's replay, 19% on the band buffer painting (four pixels a
cycle), 15% on the copy, and 44% are the fill's own per-quad work.
render3d's own timing (flip at vblank, polygon ROM in a cycle), list by list
against `FB_DDR3=0`: **75 of 101 frames show each list on the same frame; 26
show every list ONE FRAME LATER** - all of them passes of 0.84-0.96 frames that
are ready at lines 316-367, after which a band display could still sweep but a
whole draw cannot finish by 416. The heavy hills frames, whose passes run 1.18
frames, are on time.

A publish that does not wait for the whole frame - the frame shown at the first
publish line after its draw STARTS, each line fetched only once its band is in
DDR3 - would remove all of that. render3d's race margin (how far ahead of the
beam's fetch each band landed, had the frame been shown that way), over 457
draws: every one +8.0 lines or more except a single draw that started one
line before the publish line (-2.7). Such a publish would need the draw a few
lines under way first (or the band in DDR3 before its line is fetched). It is
not what the brief said ("an incomplete one is never shown"), so it is not
built.

In the full system the number is smaller. The frame-buffer race (the rebased
tree, board clocks, the same autopilot; `build/snap_fbrb/race.log`), list by
list from the race start, against when a band display would have started
sweeping the same pass (the first line 376 after it was ready): **of 494
lists, 446 reached the screen on the same frame and 48 (9.7%) one frame
later**. (The game's passes there run 1.1-1.5 frames, so fewer end in the
window than render3d's 0.84-0.96.)

**On the board (Ben, seed 17 of 786fcfb, md5 903cf718...): "runs great",
track 1's heavy corners fine, no late 3D bands.** No lag was remarked on.

### Resources (Quartus 17.0, Slow 1100mV 100C)

quartus_map on alm-save: 35,264 ALMs needed against 34,530 (+734). Fitted:

| build | commit | ALM | M10K | DSP | clk_3d | clk_sys | clk_cpu | pll_hdmi | hold |
|---|---|---|---|---|---|---|---|---|---|
| alm-save s3 (on the board) | 16e6d88 | 35,156 | 541 | 50 | +1.038 | +1.070 | +4.141 | +0.100 | +0.189 |
| tile-overrun s5 (tested by Ben) | 2d561d3 | 35,230 | 525 | 50 | +0.891 | +1.229 | +5.289 | +0.732 | +0.245 |
| this on alm-save, s11 | 905badc | 35,820 | 539 | 50 | +1.296 | +1.315 | +6.080 | +0.421 | +0.147 |
| **this on tile-overrun, s17 (ON THE BOARD)** | 786fcfb | **35,849** | **523** | 50 | **+0.833** | **+0.830** | **+6.093** | **+0.389** | **+0.223** |
| the same, s5 | 786fcfb | 35,889 | 523 | 50 | +0.689 | +0.955 | +6.461 | +0.561 | +0.242 |
| the same, s11 | 786fcfb | 35,802 | 523 | 50 | +1.410 | +0.504 | +6.282 | +0.046 | +0.197 |
| the same, s29 / s3 / s7 | 786fcfb | 35,809 / 35,781 / 35,810 | 523 | 50 | | | | -0.101 / -0.357 / -0.078 | |

**M10K went 525 -> 523, not -24, and that is the design, not a leftover.**
Two of the three 8-block band buffers are still built: they are the write
combiner the fill draws into and m1_fb_flush copies from (the per-span
alternative drew the hills frame in 0.53 of a frame). The scanout's line
buffers take 6: four 512x16 colour banks (four lines, R655's slack) and the
painted bits, 32x64 in two blocks. 24 -> 16 + 6. What more could come back:

- the painted-bit RAM into MLAB: **2 M10K**, a few dozen ALMs, no behaviour change
- four-row band buffers (4 M10K each): **8 M10K**, but the store replays 96
  bands instead of 48 - measured, the draw grows 40-50% (MAME 1180 222k ->
  317k cycles, 1940 259k -> 366k, 2780 287k -> 432k), so more lists lag a frame
- one band buffer: 8 M10K, and the fill waits on every copy

`build/Model1_3dfb_rb2_seed17_35849.rbf` (= `Model1_3dfb_tile_seed17_35849.rbf`),
md5 `903cf718a7311114af54bdf08311b4d3`; reports in `build/3dfb_tile_s17_reports/`.
(905badc predates the ROM gate below; it is not a candidate.)

### And one fault the full-system bench found that render3d could not

**The frame buffer used DDR3 during the ROM download**: 9.2 M write beats and
36,864 read beats before `rom_loaded` in a 200 M-cycle run - empty lists drawn
and shown while the HPS was streaming the ROM over the same bridge, which is
exactly what killed the Model 2 core's coprocessor boot (its R380). The 3D
block's reset is the game reset, not the load. No draw starts now until the
TGP's own release (the ROM loaded, on clk_3d): **0 and 0** in the same run.

## 2026-10-28 (b) — THE FREEZE IS A V60 BUG: MUL, DIV AND REM INTO MEMORY NEVER STORED THEIR RESULT

**Found from the board, through the diagnostic build of entry (a) below.** Ben:
the freeze happens only in attract, and only when the attract cycle wraps
round. The overlay, photographed at the freeze:

    00 FFE59C   V60 PC: the scene loader's block copy (movcu.h)
    01 01004C   V60 held reading an EMPTY TGP output FIFO; TGP idle at 004C
    04 40FFFF   >= 65,535 stores into ROM windows, the first with BANK 4
    05 FFE59C   ...from the block copy
    06 FFFFFE   ...to the top of memory
    07 010000   no colour upload dropped
    0B 00FFFF   (I/O replies saturated)
    0E 000F93 -> 001252 ten seconds later: flips and 3D passes still running

and **RESTART brought the game back** - the first time it ever has. So hole 1
of entry (a), the ROM image taking V60 stores, is what made the freeze
permanent, and hole 2 was not involved (`07` = 0).

### Why bank 4 - read off MAME

- The attract cycle is **7,026 frames** (2 min 2 s): the scene loads that
  start it are at frames 272, 7298, 14324 (`build/wrap/wrap.log`).
- Each demo scene selects its ROM bank at `FE216F`:
  `R0 = ([501934] + 1) << 4 | 1; mov.b R0, E00004`. `501934` is the course
  being demonstrated, 0-2, so banks 1-3. MAME writes `0011`, `0031`, `0021`,
  `0031`, `0031`, `0031`, `0011` ... and never anything else.
- The course advances at `FE2074`/`FE207A`: `inc.b 501934[PC]` then
  **`rem.b #3, 501934[PC]`**. MAME, at the wrap (frame 7296): writes `3`, then
  `0` (`build/wrap/course.lua`).
- Bank 4 is SDRAM words `0x2C0000-0x33FFFF` - erased (`FFFF`) at the bottom.
  The loader at `FFE583` takes its table from banked ROM (`0x118051`), so with
  bank 4 every table entry is `FFFFFFFF`: destination `FFFFFFFE`, length
  `FFFF...<<4`. The copy then runs through all of memory - palette, tile and
  character RAM, the display lists (`0A`: walks ending on garbage), the
  coprocessor's FIFO window, where its source finally blocks on an empty
  output FIFO (`01`) - and, before entry (a), through the ROM image.

### The bug

`rtl/cpu/v60/v60.sv`, `S_MULDIV`:

    md_finish();     // ends in wb_op2: st <= S_WB_MEM for a memory destination
    st <= S_NEXT;    // ...and this later non-blocking write wins

so **MUL, MULU, DIV, DIVU, REM and REMU with a memory destination set the
flags and never stored the result**. Inherited from s32 (`s32_v60.sv` has the
same order); `S_EXEC` has the right one. `rem.b #3` left the `3` in place.

`tools/run_m1_main.sh` `muldiv_memory` runs the game's two instructions
(absolute instead of PC-relative) and a DIV.W/MUL.W into memory: before,
`3` and `9`; after, `0` and `15`. The register form was always right, which is
why the V60 unit suite (29/29 before and after) and `v60_trace` (the first
seconds of boot) never saw it.

### What was right and wrong in entry (a)

- Right: RESTART failed because the ROM image took stores. The board now
  recovers on RESTART.
- Wrong guess: a garbage display list reaching the I/O firmware. Colour drops
  read zero on the board; the trigger was the CPU.
- The bench never reached this: the attract wrap is ~10^10 clk_sys cycles of
  frame bench (about two days at the speed it runs here), and the race script
  never plays attract at all.

---

## 2026-10-28 (a) — RESTART COULD NOT UNDO TWO KINDS OF WRITE: THE ROM IMAGE AND THE I/O FIRMWARE WERE WRITABLE

Branch `vr-freeze`, on `tile-overrun` (`4253a86`). Ben: Virtua Racing freezes to
a black screen, the 3D never comes back, there is only the tile background and
random colours, and **RESTART does not recover it** - a core reload does.
Long-standing.

### What RESTART does not reset, listed rather than guessed

RESTART is the game reset (`status[0]`, `buttons[1]`, the framework's `RESET`);
`mem_rst_n` is PLL lock only. Checked for state that survives it:

- **Logic.** Every `always_ff` without a reset in `rtl/video`, `rtl/tgp` and
  `rtl/mem` was read: all are memories or data pipelines, none holds control
  state. On the memory reset alone are `m1_sdram` (a request left pending by a
  client that was reset is served and acknowledged into nothing; a new request
  edge re-latches the mailbox - at worst one wrong word, no wedge), the ROM
  loader, the DDR3 payload client (flushed by the game reset; it finishes any
  burst it started and discards replies still owed - read in full), the overlay
  and the 15 kHz converter.
- **Memory.** In SDRAM: the ROM image, the I/O board's firmware and EEPROM
  image, the sound program and samples - **nothing reloads any of them short of
  a new MRA load** - and the RAM regions. On chip: the TGP program RAM (written
  only by the loader), display lists, tile RAM, palette (the game rewrites them).

So a stop that survives RESTART is a **write into memory RESTART does not
reload**. Two paths could make one, and neither exists on the board.

### Hole 1: a V60 store into a ROM window went into the ROM image

`m1_main` sent `sel_rom | sel_wram | sel_nvram | sel_charram` to SDRAM with
`sdr_we = m_we`: a store to ROMA, ROMO, ROMX or ROM0 was written into the packed
ROM image. MAME maps all four `.rom()`/`.bankr()` (`model1.cpp:985`); the board's
are mask ROM. ROMO at banks 4-7 reaches past the banked data onto the TGP's data
ROM and tables and the polygon models, so one stray store could break the 3D for
good and leave the 2D alone.

- **MAME never does it**: a write tap on all four windows, 600 s of `vr` attract
  (34,500 frames): **0 writes**. The frame bench's region census agrees (`rom ...
  0 writes` in every run on record).
- **Before/after**, `tools/run_m1_main.sh` configuration `rom_readonly` (a
  program stores `A5A5A5A5` into ROM0, ROMX, ROMO and work RAM, then reads back).
  Fix disabled: all three ROM words in the SDRAM model read `a5a5 a5a5`, ROM0
  reads back `a5a5a5a5`. Fixed: the image is as loaded, ROM0 reads back the ROM,
  the work-RAM control lands, `dbg_rom_wr` = 6, first at `FC0100`.

### Hole 2: a colour upload could overwrite the I/O board's firmware

Display-list command 4 writes tgp_ram at `adr - 0x40000 + i`. Our offset was 20
bits from SDRAM word `0xC20000`, so it reached `0xD1FFFF`; tgp_ram is 786,432
words (`0xC20000-0xCDFFFF`). **The I/O board's Z80 firmware is at `0xD00000` and
its EEPROM image at `0xD02000`**: `m1_ioz80` fetches its program from there a
word at a time and preloads the 93C46 from there at every reset. A header whose
address has low 20 bits in about `0x10000-0x23FFF` writes over them.

- A real list never does it: MAME, 400 s of attract, **128 distinct colour
  uploads, every one at `0x40000` or above and ending by offset `0x80000`** of
  `0xC0000` (`build/mame_col_census.lua`, a walk of both buffers every frame).
  The new bound has half of tgp_ram to spare.
- A list walked as garbage does: one misaligned command boundary that lands on
  a word holding 4 reads the next two words as an address and a length.
- `make render3d_fuzz` (new, `sim/video/tb_m1_raster3d_fuzz.cpp`). Base RTL:
  2,091,036 uploads escaped tgp_ram in 4 of 34 episodes, then 73,308 in 40 more
  (seed 1, with the escape census added). **None of those happened to land on
  the firmware window itself** - the fuzz's hostile addresses rarely have the
  low bits that reach it - so the firmware hit is shown by address arithmetic,
  not by the fuzz. Fixed RTL: 0 escapes in 218 episodes (seeds 1, 2 and 4, the
  last with a 48-cycle polygon ROM, 200-cycle DDR3 and 10% BUSY).

### What the board's report looks like with the firmware gone - reproduced

`tb_m1_frame`, `vr_race.txt`, board clocks: `IOFW_TRASH_AT=330M` overwrites the
firmware and EEPROM image in the SDRAM model, `GRST_AT=430M` presses RESTART
(game reset only). A control run presses the same RESTART with the firmware
intact.

    after RESTART       control                 firmware overwritten
    V60 PC              fe0e8d -> fe1435 ...    fe022c / fe0232 for ever
    screen (frame 425)  the game's test menu    one flat colour, nothing drawn
    display list walks  resume                  none

`fe022c/fe0232` is the boot's poll of the I/O board - the loop the rules file
records for a board that never answers. So: firmware gone -> RESTART reboots the
V60 and the Z80 onto the same damage -> the boot waits for ever on a flat
screen, and only a reload (which re-streams the firmware) clears it. In this run
the game did NOT visibly stop in the ~1.25 s between the overwrite and the
RESTART (it was in the course select, where the I/O board was not being waited
on); what it does in a race when the board stops answering was not run.

### The 3D layer itself does not wedge on garbage, and the game reset clears it

The fuzz feeds `m1_raster3d` random words, well-formed commands carrying NaN,
both infinities, denormals, 1e38 and wild addresses and lengths, real lists
with hundreds of words flipped, and real lists with the terminator removed;
then the game reset (memory reset left alone, as RESTART); then the real list.
258 episodes across both RTLs: no pass sequence stopped for good, and every
reset gave the cold-start frame hash for hash. The Model 2 shape - one NaN
wedging the walk - was looked for and is not present here.

### How garbage reaches the walker in normal play: torn lists

The walker reads the buffer it latched at the pass start; the pass starts a
frame after the game's flip; the game flips every second frame and then writes
its next list into the buffer it flipped away from. A pass longer than what is
left of the two frames walks a list being rewritten under it.
`render3d_fuzz TORN=24` (flip every frame, the game's writer at one word per 40
clk_3d cycles, the captured lists of frames 900, 2500 and 5460):

    polygon ROM latency   writes into the walked buffer   ahead of the walker   walks ended on garbage
    16 cycles             40,746                          30,608                0
    48 cycles             11,058                           1,190                1

Lists of adjacent frames are alike, so a torn walk mostly yields last frame's
geometry, and occasionally garbage. With hole 2 closed a garbage walk costs one
frame of wrong geometry, never the I/O board. `tb_m1_frame` now counts torn
walks in the full system (`TORN:`); the race at the board's clocks had not yet
reached its busy stretch when this was written - see `HANDOFF.md`.

### Not established

**That either hole is the board's trigger.** Neither a ROM store nor an escaped
upload has been seen on the board, and the bench cannot run long enough to wait
for one. The freeze diagnostic build (`M1_FREEZE_DIAG`, `debug-overlay.md`) is
how to find out: rows `04`-`07` count both, and the snapshot rows keep the
moment of the stop through RESTART. If the board freezes with both at zero, the
cause is something else and the snapshot names the stage.

### Identity, cost

- Frame bench, `vr_race.txt`, board clocks, `FRAME_HASH=25`: base against the
  final RTL, identical on every HASH line compared (see `HANDOFF.md` for how far
  the run had got).
- `make test`: every count as on `tile-overrun`.
- quartus_map: 34,549 ALM for the fix (tile-overrun recorded 34,572; map noise
  is +/-50). The diagnostic build maps ~35,450.

### Failure modes met on the way

- **`tb_m1_main` had rotted twice over.** Its source list predated five modules
  (`BUILDFAIL` on every configuration), and it left `rd_lat_sel` unconnected,
  which since the selector was renumbered is CL+0: every read returned zero and
  the CPU executed `HALT` at once. Both fixed. The three FAST_IFETCH
  configurations still fail (the wide fetch port returns zeros in this bench);
  that predates this branch.
- **The bench dropped the last word of its own download**: `ioctl_download` fell
  on the edge of the final `ioctl_wr`. A final word of zeros had hidden it.
- **MAME's `-debugscript` does nothing with `-debugger none`.** Disassemble with
  `manager.machine.debugger:command("dasm file,addr,len")` in an autoboot script.
- **A MAME census of NaN/denormal bit patterns through the TGP FIFOs is not an
  answer**: integer commands share the FIFO and read as denormals (`00000024`)
  or NaN patterns - 757,640 and 1,213,207 in, 127,726 and 86,039 out over
  21,000 frames - meaningless without the command grammar.
- `FFE583`, where an earlier capture found the V60 pinned, is the scene change's
  table-driven copy of glyphs and palettes out of banked ROM (MAME: lengths
  `0x0003`-`0x0938` blocks of 16 halfwords, at every scene change). A wrong
  length would sweep memory - and, before hole 1, the ROM image with it.

---

## 2026-10-28 — THE TILE OVERRUNS ARE THE FETCH ENGINE'S OWN OVERHEAD ON DENSE SCREENS, AND THE BENCH RAN AT CLOCKS THAT HID THEM

Branch `tile-overrun`, on `alm-save` (`0ac55df`; first written on `ddr3-crt-wheel`,
which alm-save is cycle-identical to). Ben sees tile
overruns on the board; the frame bench reported 18,844 in the Virtua Racing
race, 18,841 of them during the ROM download and 3 in play.

### Why the frame bench saw three: its clocks were seven weeks old

`tb_m1_frame` ran clk_cpu at 23.529 MHz and clk_3d at 47.059 - the PLL from
before 2026-09-15. The board runs **29.474 and 58.947** (`rtl/pll`, 560/19 and
1120/19), a quarter more V60 and 3D traffic on the SDRAM. `FRAME_DEFS=+define+BOARD_CLOCKS`
now runs the board's. Same RTL (`bba4ecd`), same inputs, every lost line
counted (TILE2D, below):

    run (1.1 G cycles, 894 frames)   clocks   lines lost in play   worst line
    VR race, vr_race.txt             bench    4                    3,297
    VR race, vr_race.txt             board    1,734                3,883
    VF match, vf_match.txt           board    2,780                3,701
    SWA, no inputs (settings menu)   board    0                    2,160

(line = 3,280 cycles: 656 dots x 5 at 80 MHz). VR loses lines from frame 412
(the course select) and through the race; VF about 20 a frame from frame 606.
**So the full-system bench reproduces the board once it runs the board's
clocks.** Every frame bench figure taken at 23.5/47 MHz under-states SDRAM
contention; treat them as such.

Two counting faults, both fixed: `dbg_overruns` counted a line_start only in
Q_RUN - one landing in the per-layer register reads or Q_NEXT is just as lost
(49 of VR's 1,734) - and nothing said WHICH line, so a loss in vblank could not
be told from one on screen. The bench's TILE2D census now counts every refused
line_start, names the line, and prints the character port's latency as a
histogram: in play the port waits a mean of **16.3-18.2 cycles**, mode 12,
tail to 97.

### The instrument that reproduces it in seconds: MAME's own scenes

The frame bench takes ~2 h a race and reaches only what our V60 reaches. A
line's cost is a function of tile RAM, character RAM and the row mask alone,
so `tools/mame_tile_dump.lua` dumps those (plus palette) from MAME at a run of
frames, any title, and `tb_m1_video2d` (`make video2d`) replays each snapshot
through the real `m1_video`, the character port answering as `m1_sdram` does
(request latched on its rising edge, ack held two cycles), after a fixed
latency, a jittered one, or one drawn from the frame bench's histogram. Every
visible pixel is checked against the end-to-end reference, every lost line
counted, every frame hashed. Six titles, attract and play: **20,112 frames**.

### The cause: 148 fetches at L+4, and the engine's overhead was the +4

Not bandwidth - 2026-09-04 stands, and the controller is still mostly idle.
The densest real line is Virtua Racing's **course select** (Virtua Formula's
is the same screen): **148** distinct character rows across the four layers.
The old engine paid **L+4** cycles a fetch - round trip, then check, tile read,
raise and hand-off in series - so that line took `2,560 + 148 x (L - 10)`
cycles: **3,448 at L = 16**, fitting only to L = 15, a cycle under the mean.
Replayed at L = 16, the old engine loses lines in 352 of 10,056 frames (7,060
lines), all of them course select; at the measured histogram, in about one
frame in ten across all six titles.

### The fix, part 1: the engine's overhead (`rtl/video/m1_tile_fetch.sv`)

- **Lookahead, requester and emitter, decoupled by a 4-entry descriptor queue
  and a 2-entry data queue.** The next columns' tile words are read while a
  request is in flight, and the next request rises the cycle after the ack's
  own: **L+1 a fetch**. The port contract is unchanged - one outstanding,
  rising edge, address held from it, the held second ack cycle ignored on the
  raise.
- **A column the mixer cannot see is not fetched**: the window pair's other map
  (VR's tilemap 3 - a whole layer, every line), both mask columns set, or the
  split covering both ends. `!masked` gates both mixer passes, so what the line
  buffer holds there is immaterial; the masked bit is still written per pixel.
  On the course select 34 of the 148 are such columns.
- The emitter takes the next column on the last cycle of the previous one: two
  cycles a column, not three.
- `Q_HSCR` loads the latched frame configuration in one cycle instead of seven
  states of tile-RAM reads whose results were discarded.

Course select, worst line, old -> new: **3,448 -> 2,265** at L = 16; at the
measured histogram 3,669 (46 lines lost) -> 2,455 (none); at 1.25x it 2,949
(none); at 1.5x, 12. Fixed latency: the new engine is clean on every scene to
L = 20-22 and loses lines in 161 of 2,520 frames at L = 24.

### The fix, part 2: a ring of four line buffers (`m1_video.sv`)

Part 1 alone, in the full system at the board's clocks, took the VR race from
1,734 lost lines to **72** and the VF match from 2,780 to **1**. What was left
were isolated lines in the race (frames 698-880, lines ~129-180), each a few
dozen to ~200 cycles over while its neighbours had hundreds spare: the 3D
layer's SDRAM traffic stretches the character port's latency on exactly those
lines (the race's latency tail reaches 108). That is variance, and a double
buffer cannot absorb variance - every line had exactly one line period
whatever its neighbours needed.

So line L now lives in bank L[1:0] of a four-bank ring, and the renderer
starts a line as soon as its bank is free - up to three lines ahead of the
beam - and stops only to wait for one. A line whose display has begun is
skipped; a display line whose buffer is not finished repeats the previous one,
as before, and is counted (`lost_line`, `lost_no` for the benches). The four
banks are one 512 x 15 memory per layer and lane, **16 M10K where the double
buffer took 32**. The frame's configuration is still latched by the first
render to start after vblank begins - one of the blank lines just past 383,
as before.

Replayed, the ring changes nothing where latency is steady (a dense screen is
dense on every line) and removes the variance losses: course select at 1.5x
the measured latency histogram, 23 lost lines -> 0.

Measured with both parts, the full system at the board's clocks (same runs,
same inputs as the table above):

    run                 base (bba4ecd)   part 1 only   parts 1 + 2
    VR race, lost       1,734            72            **0**
    VF match, lost      2,780            1             **0**
    worst line render   3,883            3,478         3,560 (absorbed)

Same 363 / 371 display-list swaps, 42,817 bands, 0 late, 0 dropped quads in
every case: the 3D is untouched. Replayed (6 titles, 5,028 frames at the
board's measured latency histogram): base loses lines in 538 frames (13,788
lines); part 1 alone in none at 1.0x and 175 frames at 1.25x; with the ring
**none at 1.0x or 1.25x**, 290 frames at 1.5x.

### Cost, fitted (Quartus 17.0, on alm-save)

quartus_map: 34,530 -> **34,572 ALM (+42)**. Fitted at seed 5: **35,230 ALM,
525 M10K (alm-save: 541), 50 DSP**, every clock positive at Slow 1100mV 100C -
clk_3d +0.891, clk_sys +1.229, clk_cpu +5.289, pll_hdmi +0.732, worst hold
+0.245. Seeds 3 and 11: 35,129 / 35,157 ALM, pll_hdmi -0.007 / +0.037, ours
positive. (Part 1 alone on ddr3-crt-wheel had fitted +23 ALM at seed 11 against
build B, with pll_hdmi negative on four seeds of five - the framework's clock,
seed lottery, as recorded for build A.)

### Unchanged picture

- L = 12, where the old engine never overruns: **10,056 of 10,056 frames
  byte-identical**, old against new - part 1 alone, and part 1 with the ring.
- L = 16: the 9,704 frames the old engine drew in time are identical; the 352
  it did not are the only ones that differ, and in all of them the new engine
  matches the reference and the old does not.
- The full system, bench clocks (`vr_race.txt`, 894 frames, part 1): final
  frame byte for byte, the same 316 list swaps, 42,817 bands, 0 late, 0
  dropped; the old engine's 4 lost lines are 0.
- The full system, board clocks, with the ring: of the 204 frames dumped
  from both runs (every second frame from 488 on), 203 are byte-identical to
  the old engine's. The one that is not, frame 666, differs in 16 pixels of
  row 54 in the middle of a screen wipe: the game was rewriting those two
  tiles while the line was being rendered, and the two engines read tile RAM
  at different moments. Neither is MAME's answer (MAME draws the whole frame
  at vblank). CAUTION: the dumps are every second frame and VR works on a
  two-frame cadence, so the lost lines - all in even-numbered frames by the
  bench's count - may sit in the frames that were not dumped. That those
  repeats are invisible is NOT shown.
- alm-save + this branch against ddr3-crt-wheel + this branch, board clocks,
  the whole VR race: 447 dumped frames, 0 differ, 0 lines lost - alm-save's
  cycle identity holds with it, and the fitted candidate is that tree.

### What went wrong on the way

- **The first invisibility test was `pmask(first) && pmask(last)`**: both end
  pixels masked, but by DIFFERENT causes - the split boundary inside a column
  whose right half the row mask hides - with visible pixels between. The new
  fuzz in `tb_m1_tile_fetch` (repeats across masked columns, latency 3-200 with
  jitter, 3,600 lines) failed 104 pixels on it; each cause is now tested for
  the whole column. 60,000 fuzzed lines clean after.
- **The unit bench's port model dropped ack with the request.** `m1_sdram`
  holds it two cycles, and a requester that re-raises at once sees the second.
  The model now latches on the rising edge, holds ack and counts protocol
  errors. `tb_m1_video` still divides by 6 - the 96 MHz design's 3,936-cycle
  line - which is 20% more time than the board has; `tb_m1_video2d` divides by
  5.
- **Reading the latched config arrays at a second place made Quartus 17.0 infer
  `f_ctrl_l` as a 4 x 16 altsyncram** - a block for 64 bits, on a chip whose
  binding resource is M10K. Caught in the quartus_map RAM summary, not in a
  fit; `ramstyle = "logic"` on the four arrays and the new queues.
- The descriptor first carried the 18-bit character address. It is the tile
  number and the row side by side - the decode's `+` adds into zero bits - so
  the requester rebuilds it from the queued tile word: -72 flops.

### Not done: the next lever, modelled

A line-PAIR engine - fetch four words, which are rows r and r+1 of the same
tile, and render two lines at once (the ring already has the banks) - halves
the fetches on every pair that does not cross a tile row: the lever for a
screen that is dense on EVERY line, which the ring cannot help. Modelled on the
same 20,112 frames at constant latency: the new engine clean to L ~ 24 (the RTL
replay says ~22), the pair engine to ~32. It restructures the sequencer, and
the one earlier use of a
four-word burst's upper half (`3a7c6b6`, the next-scanline cache) broke
alternate lines on hardware for a reason never found. Not attempted without a
bench that reproduces that failure.

---

## 2026-10-28 — 6,147 ALM BACK FITTED (5,478 BY quartus_map), AND NO BENCH CAN TELL THE DIFFERENCE

Branch `alm-save`, from `ddr3-crt-wheel` at bba4ecd (build B: 41,303 / 41,910
ALM fitted, 98%). The brief: at least 3,000 ALM back with **no behaviour
change** - room for the tile-overrun fix and what follows. Nothing below moves
a cycle on any bench; nothing was allowed to.

**Fitted:** seed 3 of HEAD (16e6d88), Quartus 17.0, Slow 1100mV 100C: **35,156 / 41,910
ALM (84%), down 6,147 from build B's 41,303**; 541 / 553 M10K (542); 50 / 112
DSP (62). Every clock positive: clk_3d +1.038 (B: +0.472), clk_sys +1.070
(+0.752), clk_cpu +4.141 (+4.781), `pll_hdmi` +0.100 (+0.130), worst hold
+0.189. `build/Model1_almsave_seed3_35156.rbf`, md5
`00b99984ebc450947d2a97414dd3b11f`; reports in `build/almsave_s3_reports/`.
Seeds 11 and 29 fitted at 35,096 and 35,142 with our clocks positive
(clk_3d +1.202 / +0.974) but the framework's `pll_hdmi` at -0.291 / -0.082:
seed 3 is the candidate. By module (fitted ALMs, B -> seed 3): s32_v60 13,716
-> 11,199 (its own logic 10,694 -> 7,972), m1_raster3d 9,895 -> 8,803,
m2_sound_board 4,957 -> 3,844, m1_sdram 878 -> 553, m1_fetch_bridge 492 ->
231.

### Instrument

A full-design `quartus_map` (Quartus 17.0, the staged MiSTer project, "Estimate
of Logic utilization (ALMs needed)") for every change - about six minutes,
against twenty-five-plus for a fit, so each change could be priced on its own:
the V60 changes cumulatively on top of the register-file commit, everything
else one file at a time on top of that commit. Baseline: **40,008** for the
RTL that fitted at 41,303.

**The estimate is noisy at about +/-50**, and identical logic moves between
runs: the V60's own combinational count for the SAME v60.sv read 15,282,
15,289, 15,300 and 15,315 in four maps whose only difference was another
module. A delta under ~60 is not a measurement. Per-entity combinational
ALUT and register counts from the same report are steadier and are quoted
where the ALM figure is ambiguous.

### Cycle identity, and the instrument added for it

`tb_m1_frame` gained `FRAME_HASH` (parameter HASHEVERY): three 64-bit hashes
folded on **every** enabled cycle and printed each frame -

- clk_cpu: the V60's whole bus (req, we, size, address, write data, ack, read
  data), its fetch port (if_req, if_addr, if_ack), irq_ack, ce, dbg_pc and the
  sequencer state `st`;
- clk_3d: the 3D block's DDR3 (address, rd, we, burst, byte enables, write
  data), display-list, ROM, texture, palette and translation ports, band
  presentation and its quad/object/drop/late counters;
- clk_sys at ce_pix: the video output, every pixel and sync.

Two builds that behave the same print the same lines; the first line that
differs names the frame where they parted. Results, base (bba4ecd plus the
instrument) against the final tree:

| bench | frames | result |
|---|---:|---|
| race, `vr_race.txt`, 1.1e9 cycles | 894 | **identical on every one of the 894 frames** (365,237,706 CPU and
730,475,413 3D cycles); final frame, audio, TGP pushes/pops/answers and 3D
streams byte-identical; the same 42,817 bands, 0 late, 0 dropped, 451 passes,
18,844 tile overruns |
| VF, `vf_match.txt`, 3e8 cycles | 318 | every HASH line identical; picture, audio, TGP pushes/pops/answers, 3D streams byte-identical |
| Star Wars attract, 3e8 cycles | 318 | the same |
| render3d, 4 MAME frames x 9 DDR3 latency/BUSY settings | 36 runs | every log (each frame's fill cycles, late bands) and picture identical |
| `make test` | 62 suites | every count identical to the base |
| V60 unit suite | 29 | 29/29; the FTZ (shipping) FP bench's log, 236 numpy disagreements and its finish time to the picosecond, identical to the base |
| sound board bench | 0.5 s | WAV and every statistic byte-identical |
| `make v60_trace` (against MAME) | - | not re-run: the V60's dbg_pc is in the clk_cpu hash, so our PC stream is the base's to the cycle and the trace's verdict is necessarily the base's |

Simulation-only checkers ride along in every bench: the V60's register file
is compared, every register every cycle, against a flat mirror (`RF MISMATCH`
fails the unit suite); the 68000's likewise (`FX68K RF MISMATCH`); the
determinant checks its input-stability contract (`GEO_DET INPUT MOVED`). None
fired.

### What each change was worth (quartus_map, ALMs needed)

V60, cumulative from the base:

| change | before | after | delta | registers |
|---|---:|---:|---:|---:|
| register file in MLAB: two banks x two read copies x three lanes, a live-value table, a one-clock write bypass, flip-flop shadows of R26/R29/R30/SP | 40,008 | 39,212 | **-796** | -716 |
| string completion arithmetic built once (`movc_finish` was inlined at three sites with three index expressions) | 39,212 | 38,643 | **-569** | -13 |
| *new-PSW hoist - REVERTED, see below* | 38,643 | 38,766 | *+123* | |
| one 33x33 multiplier for MULX/MULUX and MUL/MULU's overflow flag (was four) | 38,643 | 38,517 | **-126** | 0, DSP 62 -> 50 |
| second displacement of double-displacement modes from fixed offsets (was a runtime-offset 4-byte extraction at three sites) | 38,517 | 38,257 | **-260** | 0 |
| SP +/-4 and two bit-field expressions as wires | 38,257 | 38,229 | -28 | +5 |
| DIVX/DIVUX operand magnitudes once (64-bit negators were duplicated for the register and memory forms) | 38,229 | 38,034 | **-195** | 0 |
| privileged registers only LDPR/STPR touch (PIR, PSW2, ATBR/ATLR, TRMODE, ADTR/ADTMR) in MLAB, valid bits for S_RESET | 38,034 | 37,726 | **-308** | -471 |
| EA/BAM address adders once each (`modtop-4` and `modtop[1:0]` were different expressions for the same bits); PUSHM's encoder reused | 37,726 | 37,550 | **-176** | 0 |
| small repeated sums as wires; one DIV/REM sign negator | 37,550 | 37,634 | +84 (V60 comb +95) | 0 |
| `bitdiv8` as `(x+7)>>>3` for negatives - one adder, not two negators (proven over all 2^32 inputs) | 37,634 | 37,511 | **-123** | 0 |
| `wb_op2`'s value routed once after the state case | 37,511 | 37,528 | +17 (V60 comb -128) | 0 |
| the five banked stack pointers in MLAB, one read port addressed by state, last write bypassed | 37,528 | 37,357 | **-171** | -103 |
| DIVX shares MUL/DIV's accumulator, divisor and counter | 37,357 | 37,349 | -8 | -118 |
| idle registers shared between groups that never overlap (ROTC/alu_r, FP result/wb_val, task block/string fill, MOVBS/string lengths, v60_fp takes op1); plus v60_fp's one pack | 37,349 | 37,343 | -6 | -225 |
| one barrel shifter for EXTBFL and INSBFL (a right shift is the reversal of a left shift of the reversal) | 37,343 | 37,308 | -35 (V60 comb -140) | +1 |

Everything else, each alone on top of the register-file commit (39,212):

| change | module | after | delta | registers |
|---|---|---:|---:|---:|
| PCM fetch tags in MLAB (never consulted in the cycle after a write) | m2_pcm_fetch x2 | 38,716 | **-496** | -1,217 |
| 68000 register file in MLAB, live-value table, last writes bypassed | fx68k excUnit | 38,686 | **-526** | -357 |
| radix-sort histogram and bucket bases in MLAB, last write bypassed | m1_quad_store x2 | 38,714 | **-498** | -719 |
| matrix (a copy per reader, last write bypassed) and product banks in MLAB | m1_geo_xform | 38,856 | **-356** | -926 |
| read capture in MLAB, three words a port, last beat bypassed | m1_sdram | 39,013 | **-199** | -495 |
| result FIFO `fout` in MLAB, last push bypassed | m1_copro_if | 39,022 | **-190** | -474 |
| general register file in MLAB, valid bits, last write bypassed | mb86233_regs | 39,038 | **-174** | -463 |
| line cache and tags in MLAB (never read in the cycle after a fill) | m1_fetch_bridge | 39,043 | **-169** | -659 |
| reg 1 (sample number) in MLAB, valid bits, last write bypassed | m2_multipcm x2 | 39,084 | **-128** | -382 |
| the three points read where the walker holds them, not copied | m1_geo_det | 39,152 | -60 | -288 |
| SHA's overflow field from the right shifter (a third barrel shifter gone) | v60_shift | 39,155 | -57 (comb 699 -> 588) | 0 |
| one fp_pack for CVTWS, SCLFS, add/multiply and divide | v60_fp | 39,192 | -20 | 0 |
| the window frontier added once | v60_ifetch | 39,212 | 0 | 0 |
| bit ops ride the integer lane (Model 2's R952, f92030c) | mb86233_alu | 39,269 | +57 (noise: the lane lived in an altshift_taps RAM, not ALMs) | 0 |

**All of it together: 40,008 -> 34,530 (-5,478)**, registers 38,873 ->
31,321 (-7,552), DSP 62 -> 50. The individual deltas sum to -5,516, so they
are roughly additive.

### Three patterns that paid, and one that did not

**1. Storage held in flip-flops because it is read asynchronously goes into
MLAB - with `no_rw_check` and, where a read can follow a write by one cycle, a
one-clock bypass.** A bare `(* ramstyle = "MLAB" *)` on an array read
combinationally is NOT inferred - "uninferred due to unsupported
read-during-write behavior" - and stays flip-flops with no other sign (Model
2's R607 hit the same). `"MLAB, no_rw_check"` infers it. The MLAB registers
its write inputs at the edge (the generated altdpram has INDATA_REG,
WRADDRESS_REG and WRCONTROL_REG = INCLOCK) and writes the cell during the
following cycle, so a read of that address IN that cycle is the "don't care"
no_rw_check accepts. Wherever a read can land there, the previous clock's
write is held in flip-flops and wins for that one clock; after it the cell is
written. Where the access pattern proves no read lands there, there is no
bypass and the comment beside the array says why. A reset that cleared the
array becomes a valid bit per entry where the reset value is observable, and
is dropped where it cannot be (every entry written before it is read).

Two write ports become a live-value table: a bank per write port, a copy of
each bank per read port, one bit per entry and lane naming the newest bank,
the later port claiming last so it still wins a collision. The V60's file
(12 MLABs) and the 68000's (12) are built that way.

**2. A task or function inlined at several sites with a DIFFERENT argument at
each builds its whole datapath once per site.** The fb32() lesson of
2026-09-07, still the largest single V60 lever: `movc_finish` -569, the
runtime-offset second displacement -260, DIVX's negators -195, the address
adders -176. Choose the varying input by state into one wire, compute once,
let the sites route. Where the inlined copies had the SAME argument (the
fetch frontier, `pc + 1` and friends) Quartus had already shared them and the
hoist measured 0 or noise.

**3. Registers count at this utilisation.** The geometry and sound wins are
almost all flip-flops: the PCM tags were 1,217 registers and 496 ALM. At 98%
the fitter cannot pair registers with unrelated logic freely, which is why
storage moved to MLAB pays nearly an ALM per 2-3 flip-flops even with the read
mux it also removes.

**What did not pay - hoisting the new PSW.** Six PSW writers each inline a
5:1 32-bit pick of the new stack pointer selected by their own new-PSW value.
Muxing the new PSW into one wire first mapped **+123**: the 32-bit mux cost
more than the picks it saved. Reverted. The stack pointers went into an MLAB
instead, whose read address is a 3-bit function of the new PSW - that is the
version that paid (-171). Also noise-level and kept only because they are
verified: the small sums (+84), `wb_op2` (+17, though V60 comb -128), the
register sharing (-6/-8), `fp_pack` (-20), the fetch frontier (0) and the TGP
lane (+57). Dropping them is free if a smaller diff is wanted.

**Not finished: a per-register cone attribution of the V60** (yosys `synth
-lut 6`, then each flip-flop's fan-in cone). ABC had not finished after 47
minutes on the flat 4,300-line block and was stopped; the deliberate-break
pricing of 2026-09-11 remains the only map of where the V60's logic is.

### Timing

clk_3d and clk_sys both gained (+1.038 and +1.070 against +0.472 and +0.752
on build B): the MLAB reads are no slower than the flip-flop read muxes they
replace, and the fitter has 16% of the device free to place with. clk_cpu
lost 0.64 ns (+4.141) and has four nanoseconds to spare. The framework's
`pll_hdmi` is the seed lottery as always: +0.100 on seed 3, negative on 11
and 29.

---

## 2026-10-27 — THE QUAD PAYLOAD IS IN DDR3, AND IT BOUGHT 15 kHz, WHEEL MODES AND ROOM

Branch `ddr3-crt-wheel`. Fitted at seed 29, Quartus 17.0: **41,205 / 41,910
ALM, 526 / 553 M10K, 62 / 112 DSP**, against the release build re-fitted from
main at seed 3 the same day (41,267 ALM, 551 M10K, 56 DSP - it reproduced the
release's numbers exactly). Every clock better than the release's:

| clock | release (main, s3) | this branch (s29) |
|---|---|---|
| clk_3d | +0.407 | **+0.486** |
| clk_sys | +0.848 | **+1.519** |
| clk_cpu | +4.549 | **+5.043** |
| pll_hdmi (framework) | +0.074 | **+0.138** |
| hold, worst | +0.154 | **+0.216** |

Seeds 3 and 11 of the same commit fitted at 41,293 and 41,190 ALM with clk_3d
+0.190 and +0.057 and `pll_hdmi` -0.316 and -0.022: seed 29 is the one to test.

### The 3D "frame buffer" is not a frame buffer

Model 1's renderer has no frame buffer to move: it fills 8-row bands just
ahead of the beam (three 8 M10K buffers). What holds the 3D in block RAM is
the **quad store** - two banks, 69 M10K each on the release fit, of which the
vertex payload was **39 a bank, 78 in all**. That is what went to DDR3, on the
path `vf-play-area` started (its three commits taken, then finished). The
Model 2 core's frame-buffer port (its study R340-R385, R640-R664) would free
only the 24 band-buffer blocks against a reader's own line buffers, and adds a
frame of latency on any frame the draw does not finish inside blanking - it is
the follow-up for the BEAM DEADLINE, not for space.

### Measured, render3d on four MAME frames against main

- the picture is **byte for byte main's** at every round trip to 400 cycles of
  clk_3d (6.8 us) and under random BUSY and withheld reply beats; Model 2
  measured 130-500 ns on this bus (its R351)
- the worst band fill is **faster**: frame 2500, 14,076 cycles against
  16,965, because the store's scan now runs ahead of the fill
- bands go late only at a fixed 1,000-cycle (17 us) round trip
- the geometry posts a payload write at most 4 times in 1,024 cycles, its
  shortest gap 154; the write queue is 256 deep and an overrun is counted

### Two bugs no unit bench could see

- **`c9d2914` (vf-play-area) dropped quads.** P_IDLE cleared `out_valid`
  while the output stage still held a quad for the fill: 2,598 pixels of
  frame 2500. The store's bench took every quad at once. It now also runs a
  consumer that stalls 50% and 90% of the time, which fails with the bug.
- **A client queue shallower than its credit froze the 3D under a busy bus.**
  The store asks a cycle after sampling ready, so a request arrived after the
  credit was spent. Only render3d with BUSY found it.

And one in a bench: `longint t = cyc + LATENCY;` inside an always block is a
static initialiser that runs ONCE, so the SV DDR3 model answered every read at
once. The first full-system race ran against that; `dbg_rd_wait` reading 1
gave it away.

### The full-system race, main against this branch

`make m1_frame GAME=vr FRAME_CYCLES=1100000000` with `vr_race.txt`, 879
frames to the pit start: **identical** - same progress lines throughout, same
final frame byte for byte, and the same overrun totals: 42,817 bands, **0 late,
0 dropped**, 451 passes; **18,844 tile fetch overruns, 18,841 of them during the
ROM download** and 3 in play (frames 735-850, as the 3D load rises). No DDR3
traffic before `rom_loaded`. That run's DDR3 answered at once (see above), so
it was rerun with the model fixed at 40 cycles, and at 200 with BUSY 100 per
mille: worst reply waits 41 and 225 cycles, and both again identical to main -
final frame byte for byte, the same overrun totals, no protocol error.

### NQ 4,096

With the payload off chip a bank's cost is att, key and the index arrays, so
4,096 quads a bank (from 3,072) cost 16 M10K: fitted at seed 11, 41,303 ALM,
542 M10K, every clock positive (clk_3d +0.472, clk_sys +0.752, clk_cpu +4.781,
pll_hdmi +0.130). Frames under 3,072 quads are cycle-identical on render3d.
The board's busy-driving peaks of 3,034-3,193 quads now fit.

### Room

MLABs chosen when M10K was full are block RAM now that it is not (both
MultiPCMs, both sample-fetch line buffers, the clipper's stack, the EEPROM):
the release fit had **330 ALMs of MLAB; this one has 0**. The store's colour
FIFOs moved from flip-flops to block RAM, the DDR3 client keeps no copies of
data the queue already holds, and the TGP ALU shares one adder for ADDD/SUBD
(Model 2's R952). Each is cycle-identical on render3d's 36-run sweep.

---

## 2026-09-16 (b) — STAR WARS ARCADE JUMPS INTO A REGION WE DECODED AS EMPTY

**`m1_decode` declared ROMA (0x000000-0x0fffff) unpopulated for every game.**
The comment read "no dumped game loads anything here". **Four of the six load
something there**, and Star Wars Arcade's reset vector jumps straight into it.

**MAME maps it for every Model 1 game** -- `model1_mem`, first line:
`map(0x000000, 0x0fffff).rom();  /* ROMA */`. What varies is whether a set puts
anything behind it, and the sets that do use `ROM_RELOAD` -- a mirror of the
boot ROM, not separate data:

| set | boot ROM | mirrored to |
|---|---|---|
| vr, vformula, vf | -- | nothing; reads erased |
| swa, swaj | 512 KB at 0xf80000 | 0x000000 **and** 0x080000 |
| netmerc | 512 KB at 0xf80000 | 0x000000 |
| wingwar | 128 KB at 0xfc0000 | 0x000000 |
| | 128 KB at 0xfe0000 | 0x020000 |

**The measurement that named it.** Star Wars' reset instruction at 0xfffff0 is
`d6 f3 00 ff 0f 00` -- a jump to **0x000fff00**, inside ROMA's second mirror.
Virtua Racing's is `d6 f3 4e 10 fe 00`, jumping to 0xfe104e inside its own boot
ROM. **Star Wars is the only shipped set that jumps into ROMA**, which is how
the gap survived this long. Resolved through the mirror, 0x000fff00 is boot-ROM
offset 0x7ff00, packed at stream byte 0x17ff00, and the bytes there are real
V60 code -- `f3` immediate stores to 0x40ff00, 0x408000 and 0xd80000, the
coprocessor FIFO. Not filler.

Decoded as void, the V60 fetched erased space, wandered to PC 4 and emitted
`reserved opcode 03` continuously. That is the "both CPUs park during init"
symptom this file carried, and the V60 half of it is now explained.

**Confirmed by experiment before anything was built.** An unconditional alias
took Star Wars from an endless reserved-opcode loop to `halted=0`, **zero**
reserved opcodes, V60 PC 0x0c1f1f -- executing inside ROMA -- no SDRAM
violations, tilemap 2 filling the screen, and the sound board running.

**The fix is gated on the MRA's game-id byte**, because the mirror is not
uniform: wingwar's begins 256 KB into the packed boot region and covers only
256 KB, where the rest begin at its base. `roma_mode` 0/1/2 carries that.
Nothing in the MRAs changed -- all ten already sent the byte for the per-game
input maps, and it is sent ahead of index 0 precisely so it lands before the
ROM does.

**The negative control is complete.** Three Virtua Racing runs at 150 M cycles
-- without the change, with the gated fix, and with the alias applied
UNCONDITIONALLY -- are **byte-identical**, 111 lines of PC trace and every
FRAME line. The unconditional run is the important one: it is strictly more
invasive than what shipped, and it changed nothing, so Virtua Racing provably
never reads ROMA.

**A bad control was used first and withdrawn.** `build/diag_settle.log` was
quoted as the Virtua Racing baseline and is a **Virtua Fighter** run; the
differing PC and layer pixels it appeared to show were two different games, not
a regression. Check what a log actually loaded before believing a diff of it.

**CONFIRMED ON HARDWARE, 2026-09-16: ALL SIX SETS NOW BOOT.** Virtua Racing,
Virtua Formula, Virtua Fighter, Star Wars Arcade, Wing War and Sega NetMerc all
get past boot on the DE10-Nano with seed 29 (41,091 ALM, 551 M10K, every clock
positive). Star Wars had never loaded before; Wing War had never been run on
hardware at all.

**NetMerc did NOT regress**, which was the flagged risk -- it boots today with
ROMA void and was moved to mode 1 on MAME's authority alone, untested. It
survived. The entry below that called that out as the first place to look if it
broke can stand as a risk that did not materialise rather than one that did.

**Booting is not working.** Three defects are open across the newly-booting
sets; see `HANDOFF.md`. Getting past boot is the floor, not the goal.

**STAR WARS BOOTS AND PLAYS**, confirmed on hardware the same evening, with
sound and its own input map. The caution that stood here -- "unblocked, not
fixed; whether it reaches a game is a separate question" -- was right to write
and is now answered: it reaches the game.
Its TGP has retired 85 instructions and sits on an empty command FIFO at 40 M
cycles, but that is **0.5 s of emulated time against the 150 M a Virtua Racing
attract run needs**, so it is too early to read as a second fault -- and it was
briefly reported here as one before that was noticed.

**NetMerc's mode is a deliberate behaviour change to a WORKING game.** MAME
declares the mirror, hard rule 3 says MAME wins, so it is mode 1. But netmerc
boots today with ROMA void, which means it does not read there during boot, and
this is **untested on hardware**. If netmerc regresses, that is the first place
to look.

---

## 2026-09-16 — THE V60 WAS RELEASED FROM RESET THREE TIMES MID-LOAD

**`sys/hps_io.sv` clears `ioctl_download` at the end of EVERY MRA part**, not
once at the end of the MRA. `m1_rom_loader` cleared `rom_loaded` whenever a
stream started and set it again when that stream drained -- so across a
multi-part MRA the flag toggled per part, and `rom_present` (which gates the
V60's reset) toggled with it.

**Read off the framework source, not inferred.** `hps_io.sv` handles
`FIO_FILE_TX` with a zero first byte by doing `ioctl_download <= 0`; the HPS
sends that at the end of each part and a fresh TX-start for the next one.

**What that did.** The Virtua Fighter MRA sends, in order:

    index 4   (not one we accept -- no effect)
    index 0   main ROM
    index 1   TGP microcode
    index 2   I/O board firmware
    index 5   sound: 512 KB program + 2 x 4 MB PCM

So the V60 came out of reset **after the main ROM, with no TGP microcode
underneath it**, and that release lasted for the whole 8.5 MB sound download --
seconds of a CPU executing real game code against a ROM that is not all there.
It can write its work RAM, poke hardware, and scribble the EEPROM image that
index 4 had already placed in SDRAM. Then the next stream clears the flag, the
CPU is reset again, and it boots for real on top of whatever it just damaged.

**This is the shape of the intermittent loading reported from hardware**: the
same core and the same MRA sometimes stall at 0%, sometimes come up with no 3D,
and sometimes work. How long the rogue release got, and therefore what it
damaged, depends on HPS file-system timing, which varies run to run. Nothing
about the ROM set is involved -- which is why chasing a missing-file theory was
the wrong track: **a missing file fails the same way every time. Intermittent
means race.**

**The fix is `CPU_SETTLE`**: `rom_loaded` must be stable for that many cycles
before it reaches the CPU, and any new stream restarts the count.

**The first value chosen for it was WRONG and would have looked right.** 800,000
cycles is 10 ms at 80 MHz, picked as "far longer than a bus round trip". But the
gap being waited out is the HPS opening the next member of a **zip** and starting
to decompress it -- a file-system operation of tens of milliseconds. 10 ms sits
inside the range it was supposed to exclude. It is 80,000,000 now: one second,
far past any plausible gap and invisible against a download that already takes
seconds. Being too long costs nothing observable; being too short reinstates the
fault silently.

**CONFIRMED ON HARDWARE, 2026-09-16.** Loaded several times on the DE10-Nano,
all working as expected -- where before the same core and the same MRA gave
stalls at 0%, loads with no 3D, and clean loads unpredictably. Repeated loads
are what settles this: a single good load proves nothing about an intermittent
fault.

Simulation could not reproduce it and could not have. The bench's inter-stream
gap is whatever the bench chooses, so the fault is invisible there by
construction -- the mechanism had to be read out of the framework source and the
cure had to be measured on the board. Another entry for "simulation proves the
design runs; the board answers what it does".

`LED_USER` now carries the loader's sticky FIFO-overflow flag as an independent
check that came along with the fix: the loader drops words silently when its
FIFO fills and that flag went nowhere visible. It did not light, so words were
not also being dropped -- the reset releases were the whole fault.

---

## 2026-09-15 — jt12 WOULD NOT ROUTE, AND IT WAS m1_sdram's DUPLICATED MUXES

**The design PLACED and then failed to route 2-4 wires, every seed, all of them
`m1_sdram|Mux*`.** Collapsing two duplicated mux networks in that module fixed
it. Adding the FM cost no ALM headroom at all -- there was 1,995 spare the whole
time.

**What the failure actually looked like**, and it is not what "cannot fit" reads
like:

    Info (170137): Fitter placement was successful          <- it FITS
    Info (170138): Failed to route the following 2 signal(s)
        Signal "emu:emu|m1_sdram:sdram|Mux44~1"
        Signal "emu:emu|m1_sdram:sdram|Mux40~2"
    Info (170141): Routing resource LAB Block interconnect (X73_Y27, I43)
    Info (170134): Cannot fit design -- retrying with increased optimization
    Internal Error: VPR20KMAIN ... altera_arch_cluster_slm.c:2961   <- CRASH

Placement succeeds, a handful of wires will not route, and **Quartus 17.0 then
crashes on the higher-effort retry**. The crash is a tool bug and it hides the
real message, which is two lines earlier.

**TWO WRONG DIAGNOSES, BOTH KILLED BY MEASUREMENT.**

1. *"The device is full -- LABs are 4,188/4,191."* **Wrong, and Ben caught it.**
   41,910 - 39,915 = **1,995 ALM genuinely spare**. "LABs 100%" counts every LAB
   with *any* ALM in use; a LAB with 9 of 10 used still takes another. LAB
   percentage is not a capacity figure.

2. *"Contention with the Model 2 builds on the same machine."* Ben's hypothesis
   and a reasonable one. **Disproved by running one seed with the machine
   otherwise idle**: identical signals, identical routing resource (X73_Y27),
   identical internal error. Bit-for-bit reproducible, so it is the design.

**THE FIX, AND IT IS THE SAME DEFECT AS THE OTHER FOUR TODAY.** Variable-index
reads written out more than once, each building its own NP:1 mux:

* **Round 1** (did NOT fix it, but moved the failure informatively):
  `we_p[arb_grant]` read at THREE sites -- the refresh guard, `is_write` and the
  burst-length select -- plus `addr_p`/`din_p`/`be_p` indexed inline. Hoisted to
  one wire each. The failing signals then moved to `p_dout[9][40]` and `dq_r[0]`
  -- **the read-return path**, naming the next target.

* **Round 2** (fixed it): `cap[tag_p[0]]` is an **11:1 mux of 64 bits** and was
  written out **five times** across four case arms, which also each performed
  their own variable-index write to `p_dout`. One `g_cap` wire and one assembled
  `dout_n` written once.

`cap` is `NP x 4 x 16` bits in FLIP-FLOPS (`ramstyle "logic"`), so those five
muxes were pure duplicated routing in the densest module on the device.

**Result, seed 3, Quartus 17.0, 0 errors: 41,150 / 41,910 ALM (98%), 534/553
M10K, 54 DSP, and every one of our clocks positive** -- clk_3d +0.023, clk_sys
+0.107, clk_cpu +4.978. Only the framework's `pll_hdmi` at -0.539.

**THE LESSON THAT GENERALISES.** A duplicated mux costs area, which is the
obvious price and the one the earlier entries chased. It also costs **routing**,
and that bill lands somewhere else entirely: not as "your module is too big" but
as two unroutable wires and a fitter crash, in a design with 1,995 spare ALM.
When a fit fails for routing rather than capacity, **read which module the
signals are in and look for duplicated indexing there** before touching seeds,
effort levels or the size of anything.

**Still owed, and better than another mux hoist**: the sound 68000's work RAM is
on SDRAM port 10, and `segam1audio.cpp:28` says the real PCB has **16 KB**
(2 x 8 KB SRAMs), not the 64 KB we model -- our own bench agrees, touching 8,193
words. 16 KB is 16 M10K against 19 free, so it can come on-chip, which deletes
port 10, takes NP 11 -> 10, shrinks every mux in the module and removes the
shared-SDRAM deviation from Model 2. That is the structural fix; the hoists are
the cheap one.

---

## 2026-09-16 — THE SOUND 68000 WAS CRASHING, AND ITS WORK RAM WAS WHY

**Every sound symptom chased for two sessions was downstream of a CPU executing
garbage.** The sound board's work RAM had been moved to SDRAM port 10 to save
M10K. Its stack lives there.

### What it looked like

    SNDCPU: 68000 pc=312000  insns=4759144   ym_writes=4  pcm_writes=0
    SNDRAM: work-RAM requests=32768 (writes 32768) acks=65536   READS=0
    SNDI8251: cmd_r=00 (RxE=0 TxEN=0)  rxrdy=1  uart writes seen=0

The 68000 wrote **exactly 32,768 words** - the full 64 KB clear loop every 68000
firmware runs at boot - **and then never read the RAM once**. It died on its
first read, which for a 68000 is a stack access, and spent 4.7 M instructions in
unmapped memory. The PC is different every run (312000, 349fde, 8d272a, dec1a4,
747dac) and never inside its own map (ROM 0-0x3FFFF, RAM 0xF00000-0xF0FFFF).

A CPU that lands somewhere different every run has lost its stack.

### The fix, and it is Model 2's

Model 2's `m2_sound_board` has **no external RAM port at all** - two byte-wide
M10K arrays inside the module - and its sound works. Ben said so repeatedly
before it was acted on.

| | off-chip | on-chip |
|---|---|---|
| 68000 PC | wandering | **0x000104, in ROM** |
| work-RAM writes | 32,768 then dead | **472,392** |
| UART interrupts (IRQ2) | 6 | **2,040** |
| ym_writes / pcm_writes | 4 / 0 | **342 / 479** |
| `tb_m1_sndboard` | fails=1 | **fails=0** |

**SIXTEEN KILOBYTES, NOT MODEL 2's SIXTY-FOUR.** `segam1audio.cpp` maps
0xF00000-0xF0FFFF and says outright *"real PCB actually has 2x 8kBx8-bit SRAMs
(16kB total)"*, so the upper three quarters of that window ALIAS on hardware.
Our own bench agrees: `ram_words = 8193`, exactly 16 KB. 16 KB costs 16 M10K
against 18 free; 64 KB would need 64.

### THE BENCH REPORTED fails=0 THROUGHOUT

`tb_m1_sndboard` has its **own** RAM model and never touched SDRAM port 10, so
it could not see this fault. It passed while the board was silent.

**That is the second time in two days this same bench gave a false pass** - it
also never served its PCM sample ROMs (see 2026-09-15). A bench reporting
`fails=0` on the exact subsystem that is broken is worse than no bench: it
actively argues against looking there.

The bench that found it is `tb_m1_frame`, which drives the REAL SDRAM, the real
loader and now the real sound board. It did not exist for sound until this
session.

### Two of my own changes were the causes, not fixes

* **work RAM to SDRAM port 10** - an M10K saving that crashed the sound CPU.
* **the YM's IRQ wired at level 4** - `segam1audio.cpp` contains exactly one
  `set_input_line`, the UART's `M68K_IRQ_2`; the YM3438's IRQ is not connected
  to the 68000 on the real board, and Model 2 lists `ym_irq_n` in its unused
  reduction. Level 4 outranks level 2, so it would have starved the UART. It was
  added during the jt12 work, recorded in the same session as "a dead end", and
  left wired in. **Removed - but measurement showed it was NOT the blocker**,
  and saying so matters: the fix was claimed before it was tested.

A third change was real but not the blocker either: `CHAR_CLKS` was 5,120, one
character time at the board's 16 MHz V60, while we clock ours at 29.47 MHz with
`ce` tied high - the link ran 1.84x fast into a sound board that is NOT
overclocked (`TICK_NUM/TICK_DEN` puts its 68000 at the real 10 MHz). Now 9,430.
Ben spotted that one.

### The rule

**An optimisation that moves a CPU's stack off-chip is not an optimisation.**
The M10K saved was 16 blocks; the cost was two sessions of silence and three
wrong diagnoses. When a CPU's PC is different every run, stop looking at what it
talks to and look at where its stack lives.

---

## 2026-09-16 — 64 MB SDRAM, AND A CONCATENATION THAT SHIFTED THE V60's FETCH

**The controller was right from the first build. The plumbing around it was
wrong, it passed `make test`, it passed lint, and it was flashed to a board that
showed a black screen.**

### The change

`m1_sdram` went from 9 column bits to 10: 8192 rows x 1024 columns x 4 banks of
16-bit words = 25 address bits, 64 MB. Model 2 has run ten bits on this same
hardware throughout (`Model2.sv`: `localparam SDR_COL = 10`), which is what
settled that the module supports it.

**Ten is the safe limit, not the dangerous one.** The note that stood in
`m1_sdram` refused ten bits because it "overlaps bit 10 between row and column".
The overlap it feared is between ADDRESS PINS: column bits map to A0..A9 and
then SKIP A10, the auto-precharge flag, continuing at A11. Ten column bits land
on A0..A9 exactly and never reach A10. The hazard begins at ELEVEN.

Cost: **+14 ALM** (41,225 -> 41,239) for double the address space.

### Three slices had to move, and two were missed

    bank = xfer_addr[25:24]     row = xfer_addr[23:11]     col = xfer_addr[10:1]

* `trow` kept the 32 MB slice `[22:10]`. That is not a wrong address but a wrong
  DECISION: `trow` is what `bank_row[]` remembers and what the open-row check
  compares, so the controller believed a row was already active, skipped the
  ACTIVATE and read whatever row really was open.
* `S_RD`'s bank slice kept `[24:23]` while `S_WR`'s moved, **because it had two
  more spaces of indentation and my replacement string did not match it**.
  Writes went to the new bank and reads to the old one, so bank 0 passed and
  banks 1-3 returned zeros - which reads as a bank-decode fault and is not.

**AND I SEARCHED FOR IT AND FOUND NOTHING**, because I piped the search through
`head -12` and the match was on line 13. Do not truncate a search for a defect.

### The one that cost the flash

    r3d_tex_addr, {r3d_rom_addr[24:2], 1'b0},     <- 23 + 1 = 24 bits
    IOFW_BASE + {10'd0, iofw_word},
    tgp_mem_addr, ifp_addr,                       <- SHIFTED ONE BIT DOWN
    24'hFA8000 + {6'd0, char_addr}, sdr_addr};

**Concatenation operands are SELF-DETERMINED.** A short element is not
zero-extended into its slot - it slides everything below it. One 24-bit element
in a 25-bit slot corrupted `ifp_addr`, the V60's instruction fetch, and the CPU
halted 520 cycles after reset with `pc=000003`. Four instances across
`Model1.sv` and `tb_m1_frame.sv`.

**EVERY ONE OF THESE IS WIDTH-LEGAL SYSTEMVERILOG. Lint was clean throughout.**

### How it should have been caught, and was not

`make test` passes: **no unit bench boots a CPU.** The bench that does -
`tb_m1_frame` - reproduces the board exactly:

    FRAME: cycles=520 halted=1  pc=000003        broken
    FRAME: cycles=200000000 halted=0 pc=fe3dea   fixed

It was sitting there and was not run before flashing. **A mechanical sweep over
76 sites in seven files needs a BOOT test as its gate, not a lint and not a unit
suite.**

### And the first diagnosis was wrong

The 64 MB geometry was blamed. An A/B disproved it in one run: with the **32 MB**
controller restored and everything else unchanged, the V60 still halted (503
cycles). `m1_sdram` passes both geometries with zero fails and zero violations.
The controller was never the problem.

### Found along the way, and real

Every `m1_cdc_port` was hardcoded `AW(24)` - including `m1_fetch_bridge`'s, which
carries the V60's instruction fetch, and `u_data_cdc`, which carries its data
port. They would have truncated any address above 32 MB, silently defeating the
entire point of the change. Now `AW(25)`.

Also harness-side: every `sdram_model` instance was pinned to `COL_BITS(9)`, so
four benches were modelling a 32 MB part against a 64 MB controller, and
`tb_m1_sdram`'s `pick_addr` built addresses to the old geometry and never
reached the top half of the device at all.

---

## 2026-09-15 — THE SOUND BENCH NEVER SERVED THE SAMPLE ROMS

**Every PCM symptom this project has chased came from a missing servant in
`tb_m1_sndboard`.** The chip was right the whole time.

`sim/sound/tb_m1_sndboard.cpp` loads both real sample ROMs into `s1` and `s2`,
prints their sizes -- and **never uses them**. `pcm1_ack`/`pcm2_ack` are assigned
`0` once at init and never again; `pcm1_data`/`pcm2_data` are never driven at
all. So every MULTIPCM fetch that missed the per-voice cache waited forever for
an acknowledge that could not arrive.

**The comment directly above the ROM load warned about this exact failure:**
*"THE REAL SAMPLE ROMS. Feeding zeros here makes the mix flat zero no matter what
the chips do, which looks exactly like the hardware fault and is not."* The load
was wired. The servant was not.

**Adding it, one change, nothing else touched:**

| | ROMs unserved | served |
|---|---|---|
| rate | 20,202 Hz | **44,670 Hz** (chip wants 44,643) |
| underruns | 12,220 | **0** |
| chip advancing | 29.2% | **100.0%** |
| descriptor fetches | started 1, **completed 0** | started 15, **completed 15** |
| non-zero L / R | 1,440 / 1,440 | 12,560,432 / 21,362,710 |
| descriptors resolved | *(none)* | `s000@020000 s001@0285f0 s004@04df60` |

224.00 ce per sample against a nominal 224. L and R now differ, which is real
stereo panning rather than a mono test tone.

**WHAT THIS RETRACTS.** Anything measured about the PCM path with this bench is
void, including:

* "the chip is producing 45% of its samples" - it produces 100%
* "the chip stalls on fetch latency" - `rom_req` is 0.0% of `ce`
* "a descriptor fetch hangs" - 15 start, 15 complete
* "PCM_CACHE makes no difference" - true, but because nothing reached memory
* **"tb_m1_sndboard measures a peak of 20 at the mix with the real sample ROMs,
  about -64 dB"** - this number is quoted in `m2_sound_board.sv` to justify
  removing the mixer's `[17:2]` shift, and it came from a bench feeding the
  chips nothing. **That justification is void.** The FM alone now peaks at
  **1,136** against MAME's reference peak of 127, so the level argument may
  point the OTHER way. Re-derive it; do not trust the comment.

**HOW IT WAS FOUND, AND IT WAS NOT BY LOOKING AT THE BENCH.** Three hypotheses
were raised and each killed by measurement - a halved divider (the output stage
measured exactly 44,642 Hz), a wrong clock enable (20 MHz, correct by
construction), fetch latency (`rom_req` 0.0%). The fourth measurement, three
counters splitting `ce` into advancing / `rom_req` / `df_busy`, reported
`started=1 completed=0` and 224.00 ce per sample **while advancing** -- a chip
that is exactly on rate and then stops dead. A chip cannot both be perfect and
be slow, so the instrument was wrong.

**The general rule: when a measurement refuses to add up, suspect the
instrument.** That is now twice in one day - `v60_trace` aligning on the wrong
boot restart, and this. Both times the arithmetic gap was the signal, and both
times it would have been easy to round it off and carry on.

**The servant holds its ack until the request drops**, because `m2_pcm_fetch`
clears `m_req` on `m_ack` and a pulse on the wrong cycle is the fault that has
cost this project the most time - it cost `tb_v60_ifetch` a false 73,584
failures earlier the same day. It also returns zero above 2 MB, matching
`Model1.sv`'s `snd_pcm1_addr[21] ? 64'd0 : p_dout[8]`.

---

## 2026-09-15 — THE 20 kHz IS THE CHIP, NOT THE RATE STAGE, AND THE MUSIC PATH IS CLEAN

`tb_m1_sndboard` prints `20202 Hz (chip wants 44643)`, which reads as a divider
that is half what it should be. It is not. **Ben asked whether it should not be
40-odd kHz, and taking the two numbers apart is what located the fault.**

**THE OUTPUT STAGE IS EXACTLY RIGHT.** Every pop either delivers a sample or
underruns, so the two counters sum to the output rate:

    jt12       10,101 samples + 12,220 underruns = 22,321 in 0.5 s = 44,642 Hz
    stubbed    10,031 samples + 12,290 underruns = 22,321 in 0.5 s = 44,642 Hz

against the 44,643 the chip wants. `m2_pcm_rate` drains correctly. The 20,202 is
`dbg_pcm_samples`, which counts `p1_stb` -- **samples the chip PRODUCES** -- not
pops.

**THE CLOCK ENABLE IS RIGHT TOO, and this was worth checking** given three Model
2 clock assumptions had already been found wrong here. `ce` is
`CE_NUM/CE_DEN * clk` = 20/80 * 80 MHz = **20 MHz**, the same as Model 2's
20/50 * 50 MHz. `CE_DEN` is clk-in-MHz by construction, which makes `CE_NUM` the
MHz figure directly, so it scales correctly and is NOT a fourth instance.

**SO THE CHIP ITSELF IS SLOW.** A sample period is 28 slots x 8 ticks = **224
`ce` nominal**; measured ~990. It spends about 77% of its time not advancing.

**THE MECHANISM.** `m2_multipcm`'s slot loop is gated:

        else if (df_busy) begin ... end
        else if (!rom_req) begin
            tick <= tick + 1'b1;
            ... if (slot == 5'd27) sample_stb <= 1'b1;

**The whole chip stops advancing while a ROM request is outstanding**, and a
descriptor fetch (`df_busy`, twelve sequential byte reads) preempts the loop
entirely. **The real YMW-258-F does not do this** - it reads sample data with
fixed timing inside its slot and has no mechanism to stretch a sample period
because memory was slow. The stall is ours, not the hardware's.

**PCM_CACHE MAKES NO DIFFERENCE AT ALL**, which is the surprise. PCM_CACHE=1 and
PCM_CACHE=0 give byte-identical output - same samples, same underruns, same
peak. The two binaries were checked to be genuinely different (different md5,
different size) and the harness does forward the parameter, so this is not a
build that failed to take. **The per-voice fetch cache is not moving the stall.**

**AND THE ARITHMETIC DOES NOT CLOSE. Saying so rather than dressing it up.** At
`PCM_LAT=1` the bench's memory answers in a clock, and `rom_req` is cleared on
`clk` rather than on `ce` (deliberately - see the comment at the clear). With 28
active slots issuing one fetch each per sample period, the expected cost is
roughly 28-56 `ce` on top of 224 -- **12-25% slower, not 340%**. Something else
dominates and this entry does not name it.

> **CORRECTED SAME DAY, AND THE GAP ABOVE IS WHY IT WAS FOUND.** The arithmetic
> did not close because **none of this was real**. The bench never served the
> PCM sample ROMs at all - see the entry above this one. The chip was correct
> throughout; the instrument was not. Everything in this section from "SO THE
> CHIP ITSELF IS SLOW" onwards describes a bench artefact. The reading is kept
> visible because the shape of the mistake is the useful part: **three
> successive hypotheses (a halved divider, a wrong clock enable, fetch-latency
> stalling) were each disproved by measurement, and the fourth measurement
> found the instrument.** The refusal to paper over the 12-25%-versus-340% gap
> is what kept it going.

The instrument that would: count `ce` cycles spent with `rom_req` high versus
`df_busy` high versus advancing, per sample period, and print the three. That
separates sample fetches from descriptor fetches from a third cause, and it is a
handful of counters in the harness.

**WHAT THIS DOES NOT AFFECT: THE MUSIC.** Ben's point, and the RTL agrees --
`ym_l` goes straight from jt12's `snd_left` into the mixer and **never touches
`m2_pcm_rate`**; only `p1_raw`/`p2_raw` do. Music is FM and is independent of all
of the above. The A/B is direct evidence: with the FM stubbed the mix peaks at
**0** and with jt12 at **1,136**, so in that window the starved PCM contributes
nothing and every bit of the signal is FM.

So the prediction for the board is **clean music, ragged effects** - and if that
is what it sounds like, the two faults are cleanly separated.

**A stale label fixed alongside**: `make test_m1_sndboard_nc` announced itself as
"PCM_CACHE=0, the HARDWARE configuration". `Model1.sv:823` instantiates
`PCM_CACHE(1'b1)`, so the *other* target is the hardware configuration and that
echo would send the next reader to benchmark the wrong build.

---

## 2026-09-15 — THE SOUND BOARD FAILS ITS OWN BENCH, AND jt12 IS WHAT FIXES IT

**`FAIL the mix is flat zero -- the chips play but nothing comes out`.**

That is `tb_m1_sndboard` on the board as it stood, and it is the hardware
symptom reproduced in simulation. It had been reported by the bench all along.

**The A/B, same harness, one file swapped:**

| | FM stubbed (`m1_ym_timer`) | `jt12` |
|---|---|---|
| peak \|l\| | **0** | **1,136** (-29.2 dBFS) |
| snd_l non-zero | 0 cycles | 1,440 cycles |
| IRQ4 (timer) | **0 times** | 1 |
| IRQ2 (uart) | 1,697 | 6 |
| bench | **fails=1** | **fails=0** |

**RUN THE CONTROL.** "peak 1136, bench passes" on its own is a number. Against a
control that measures **zero** on the same harness, it is a result. The control
cost one bench run.

**IRQ4 NEVER FIRED WITH THE STUB IN**, and the stub's stated reason for existing
was *"sound effects, and the IRQ4 timebase the sound program sequences on"*. It
was not providing the timebase. That is worth holding onto: a stub that is
documented as preserving a behaviour had stopped preserving it, and nothing said
so except a bench nobody had read the output of.

**What the sample rate says, and it exonerates the change**: ~20,062 Hz stubbed
against ~20,202 Hz with jt12, both against a chip that wants 44,643. **The rate
fault is pre-existing and unrelated** - it did not arrive with the FM. Measuring
it on both sides is the only reason that can be said.

### What went in with it

- **`ym_div` /6 -> /10.** Model 2's clk_sys is 48 MHz and 48/6 is 8 MHz exactly;
  **Model 1 runs clk_sys at 80 MHz**, where /6 gives 13.3 MHz and the FM plays
  **67% sharp**. The counter also had to widen to four bits - 0..9 does not fit
  in three. This was the third Model 2 clock assumption inherited unchanged
  (TICK_DEN and m2_pcm_rate's CE_DEN/OUT_DEN were the others) and all three were
  wrong here. It was harmless only while the FM was stubbed.

- **The mixer saturates but does NOT attenuate**, against the note in the file
  that said to restore `[17:2]` and the saturation together. Only half of that
  is right. The saturation is real protection - three live sources can exceed 16
  bits and a wrap turns a loud passage into full-scale noise. The `[17:2]` is
  **12 dB of attenuation** on a board already ~16 dB below the reference (MAME's
  vr peaks at 127 of 32,767; our mix measured 20), and would put it back under
  the noise floor - the "silent on the board, samples arriving the whole time"
  state that already cost a session. The ~60 ALM the saturator costs did not fit
  at 99% ALM and fits at 95%.

- **`m1_quad_store` 3,584 -> 3,072 quads**, to free the 10 M10K. **A deliberate,
  temporary regression of the 3D**, Ben's call: the design was at 553/553 with
  nothing to reclaim, and it goes back up when the 3D path moves to DDR3. It
  costs dropped scenery on busy stretches (measured on hardware: D=33, D=111).

- **The harness stopped compiling** on `u_board.u_ym.reg_sel`, an internal of the
  stub - an error naming a dotted path rather than the swap that caused it. The
  register number is not the chip's secret: the 68000 writes it to the address
  port and the value to the data port, so the harness now reconstructs it from
  the bus and works against either chip.

**NOT PROVEN YET.** The audio is non-zero for 1,440 cycles of a 0.5 s window and
IRQ4 fires once. That is a long way from sustained music, and the 20 kHz rate
fault is still open. What is established is that the mix is no longer flat zero
and the bench no longer fails - not that the board will sing.

---

## 2026-09-15 — QUADRATIC MUX NETWORKS: -130 ALM MEASURED, THREE SEEDS

**Measured, not estimated.** Same three seeds, same design, one change set:

    seed 23   41,194 -> 41,061   -133
    seed 19   41,171 -> 41,037   -134
    seed  3   41,275 -> 41,161   -114

All three moved together, which is what separates a real saving from fit noise.
Our clocks stayed positive (seed 23 +0.158, seed 19 +0.083); only the
framework's `pll_hdmi` is negative.

**THE PATTERN, AND IT IS THE SAME ONE THREE TIMES NOW.** A loop that indexes an
array with a COMPUTED index builds one full mux per iteration. It looks like one
mux in the source and it is N of them in the fitter.

**1. `m1_fp_pool.rr_pick`.** A rotating arbiter walked its request vector as

    sum = first + k;  idx = (sum >= NC) ? sum - NC : sum;  if (req[idx]) ...

unrolled NC times. `idx` is a variable in every one of them, so each iteration
built its own NC:1 mux to read `req[idx]`, plus its own add, compare and
subtract. NC of those per arbiter, and there are THREE arbiters. Rotating the
vector ONCE - `{req, req} >> first`, whose bit k is `req[(first+k) % NC]` - makes
the priority chain index with k CONSTANT, and the wrap arithmetic happens once on
the winner instead of NC times on every candidate.

**2. `v60.sv` fetch-buffer bytes.** Three offsets into `fb[]` are read at EIGHT
sites - the `rf_raddr_a` decode and seven sequential arms. Each inline read built
its own 24:1 byte mux. Three module-level wires now serve all eight.

An earlier attempt muxed the INDEX on `st` and kept one byte mux. **That is
worse, not better**: the sequential arms cannot use it, so they kept their seven
muxes and the index mux was pure addition. Name the bytes; do not mux the index.

**3. `v60_ifetch` fill network.** `fb[i] <= if_data_i[(i - fb_wr_r)*8 +: 8]` for
i in 0..23 - twenty-four 8:1 byte muxes. But the enable restricts
`i - fb_wr_r` to 0..7, so the select is `(i - fb_wr_r) & 7`, which depends only
on `fb_wr_r[2:0]` and the constant i. **fb[i], fb[i+8] and fb[i+16] select the
same source byte.** Rotating the 8-byte line once by `fb_wr_r[2:0]` and indexing
with `i & 7` leaves EIGHT muxes and a plain wire per byte.

**HOW TO FIND THEM.** Rank our modules by `Combinational ALUTs / Dedicated Logic
Registers` from the fit report's entity table. `m1_fp_pool` stood at **10.17**
(2,136 comb, 209 reg) against ~1.5 for a healthy datapath - the outlier by a
factor of three, and the arbiters were exactly why.

**AND THE RATIO STOPS YOU WASTING TIME TOO.** `m1_geo_xform` has the same
computed-index pattern and a ratio of **0.18** - 231 combinational ALUTs in the
whole module. The change there is correct and was kept, but it saves almost
nothing. Check the ratio before optimising, not after.

**What did NOT need touching, checked rather than assumed**: `s32_v60`'s two 32:1
register-file read muxes are already minimal; `v60_ifetch`'s 4-byte realign shift
is deliberate and measured (see its own comment - 8 was tried and reverted on
timing); and the `FAST_IFETCH` legacy fill path is a parameter test, so Quartus
constant-folds it away.

---

## 2026-09-15 — THE HELD-ACK TRAP BIT THE INSTRUMENT, NOT THE DESIGN

**73,584 window mismatches, and the DUT was correct throughout.**

`v60_ifetch` is 937 ALM, every instruction the CPU executes passes through it,
and it had **no bench of its own** - hard rule 5 says every RTL module ships
with one. It was split out of `v60.sv` as a pure refactor and has only ever been
covered end-to-end, by the 29-test unit suite and by running real game code.
Both say the CPU works; neither says the fetch window is correct, and neither
can be aimed at a specific hazard.

**The invariant that needs no reference model.** The fetch window has one
complete correctness statement:

    for every i < fb_valid:  fb_flat byte i == memory[fb_base + i]

on EVERY cycle, not only when `fill_ready` - the decoder reads `fb_flat`
combinationally, so a window that is briefly wrong is a window that can be read
wrong. Checking an invariant against a golden memory beats diffing against a
second implementation, because it cannot be wrong in the same direction as the
DUT.

**Plus liveness, which the invariant misses entirely.** A window that never
fills satisfies it vacuously. The bench also fails if `fill_ready` has not
asserted within a bounded number of cycles - a deadlocked fetch reads as a dead
CPU, which is the shape that has cost this project the most time.

**THE FIRST RUN REPORTED 73,584 FAILURES AND THEY WERE ALL MINE.** Stale bytes in
the tail of the window, at a plausible depth, reproducible - it read exactly like
a real fetch bug. The cause: the bench pulsed `if_ack` for one cycle. The CPU is
`ce`-gated at one cycle in three, so most pulses are simply never seen.
`m1_fetch_bridge.sv:20` states the protocol in as many words - *"`if_ack` must
then stay high until `if_req` drops"* - and the rules file lists held-versus-pulsed
acknowledges as the fault that has cost the most time here.

With the ack held until the request drops: **checks=400000 fails=0 ready=24913
seq=21905 jumps=3008 worst_stall=17**.

**So it has now cost a session twice: once in the design, once in the
instrument.** When a brand-new bench reports failures against RTL that real game
code has been running for months, suspect the bench first - and check the
handshake before anything else.

**The liveness bound is measured, not guessed.** The first version used 400 ce
cycles against a real worst case of 17 - loose enough to pass a fetch unit that
had become twenty times slower. It is now 100: ~6x headroom against arbitrary
reshuffling, and still far below a deadlock.

**Not covered, and said out loud rather than implied**: the self-modifying-code
guard. `dbus_req` is held low, so invalidate-on-overlapping-write is untested
here - it needs the golden memory mutated in step with the DUT's view of the
write, a race this bench does not yet resolve. `tb_v60_smc` in the unit suite
exercises it.

---

## 2026-09-15 — `v60_trace` WAS BROKEN BY THE SOUND ROMS, NOT BY THE V60

**The instrument reported `DIVERGES at instruction 2` and the CPU was correct.**

**What it looked like.** `make v60_trace` — the strongest V60 verification there
is, and what the rules file records as reporting *no mismatch at all* on 2026-09-08 —
began failing at the second instruction:

    v60_trace: DIVERGES at instruction 2
    --- MAME, collapsed: FE104E: jmp FE0000[PC] ...
    --- ours: fe104e fffff0 fe104e fe0000 fe000e fe0016 fe001d fe0020

It surfaced while optimising `v60.sv`, which is the worst possible moment: a
trace failure on the file you have just edited reads as your own bug.

**The negative control is what saved the time.** Copying the *unmodified*
`v60.sv` back over the working file and re-running produced the **identical**
divergence, character for character. The edit was exonerated in one run, before
any of it was unpicked. Run the control first; it costs one run and it decides
whether you are debugging the change or the instrument.

**The mechanism.** Our raw stream begins

    000000 fffff0 fe104e fffff0 fe104e fe0000 fe000e ...

The core passes the **reset vector twice**. `m1_rom_loader.sv` clears
`rom_loaded` whenever `ioctl_download` rises, and `rst_cpu = ~rst_n |
~rom_loaded` — so **every MRA part holds the V60 in reset and releases it
again**. Each aborted pass executes the single `jmp` at the entry point and is
reset before it touches anything, so the restarts are harmless; but they are in
the trace.

The aligner took the **first** occurrence of the entry point, which keeps the
aborted passes in the stream, so the diff compared our restart against MAME's
second real instruction.

**What changed since the clean trace, and it was not the CPU.** Virtua Racing's
MRA now has **six** download streams (indices 0-5) against five for every other
game — indices 3 and 5 are the sound ROMs added this session. More parts, more
restarts. **Adding a ROM stream broke the CPU verification instrument**, and
nothing in either change is anywhere near the other.

**The fix is in the instrument.** `tools/v60_trace.sh` now aligns on the **last**
reset-vector pass inside a bounded boot preamble, **counts the restarts and
prints them**, and **warns loudly** if a reset vector is reached after the
preamble — that would be a watchdog or a real fault and must not be swallowed by
an aligner. Bounding the search is the point: an unbounded "last occurrence"
rule would silently discard a genuine mid-run restart, which is a worse failure
than the one being fixed.

Verified offline against the existing artefacts before re-running: aligned
stream `fe104e fe0000 fe000e fe0016 fe001d fe0020 fe0027 fe002d` against MAME's
identical `fe104e fe0000 fe000e fe0016 fe001d fe0020 fe0027 fe002d`.

**The general lesson, and this file already carries three of these.** When a
measurement changes, check what changed about the *instrument* before concluding
something changed about the hardware. The V60 had not moved at all.

---

## 2026-09-15 — THE V60 FETCH-BUFFER HOIST, AND WHY THE TRACE COULD NOT VERIFY IT

`v60.sv` reads its 24-byte fetch buffer `fb[]` at a **variable index** in 19
places. In one `always @*` block, five case arms read it at three distinct
computed indices, each synthesising its own 24:1 byte mux. Hoisted to one index
mux feeding one byte mux:

    logic [4:0] fb_ra_idx;
    always @* begin
        case (st)
            S_STR_OP2:            fb_ra_idx = 5'd3 + len1 + len2;
            S_DEC_OP2, S_BF_INS2: fb_ra_idx = 5'd2 + len1 + len2;
            default:              fb_ra_idx = 5'd2 + len1;
        endcase
    end
    wire [7:0] fb_ra_byte = fb[fb_ra_idx];

**A first attempt grouped the states wrongly** — `S_DEC_OP2`/`S_BF_INS2` use
`5'd2 + len1 + len2`, not `5'd3 + len1 + len2`. Caught by reading the arms
again before building. Three distinct addresses, not two.

**How it was verified, given the trace was down.** `v60_alu` 360,001 checks / 0
fails, `v60_shift` 69,121 / 0, and the V60 unit suite 29 passed / 0 failed / 0
skipped — but per-opcode fuzzing proves each instruction correct *for the state
it was handed*, which is exactly the gap an operand-addressing change can fall
through. So the change was run through **real game code**: `make m1_boot
BOOT_CYCLES=60000000`, with and without the hoist, logs diffed.

**Every line of simulation output identical over 60 million cycles.** The only
difference between the two logs was Verilator warning text from a compile-cache
miss. That is a far stronger statement than the two instructions the broken
trace was managing, and it is the technique to reach for when a change is
correct-by-fuzzing but unproven in situ.

---

## 2026-09-15 — DUPLICATED BARREL SHIFTERS: ~385 ALM, AND HOW TO FIND THEM

A repeatable method, three modules, all verified by existing fuzz suites.

**THE METHOD.** The fit report's entity table carries `Combinational ALUTs` and
`Dedicated Logic Registers` per module. Rank OUR modules by the ratio:

    s32_v60        10,869 own  16,049 comb   3,488 reg   4.60
    v60_fp          1,447       2,524 comb     362 reg   6.97
    m1_fp_pool      1,304       2,157 comb     212 reg  10.17
    v60_shift         640         993 comb       2 reg  496
    mb86233_alu       618       1,019 comb     194 reg   5.25

A module that is nearly all combination and no registers is either genuinely
combinational or is building the same structure several times. Read the worst.

**WHAT IT FOUND.**

1. **A non-constant modulo inside an unrolled loop.** `m1_fp_pool`'s round-robin
   did `idx = (first + k) % NC` and `m1_sdram`'s arbiter did
   `cand = (rr_next + j) % NP` -- a DIVIDER, unrolled NC and NP times, twice in
   the pool. Both operands are 0..N-1, so the sum is at most 2N-2 and ONE
   conditional subtract is exact. **~290 ALM**, and `m1_sdram`'s is on the path
   its own comment calls "the worst path in the whole design".

2. **`v60_shift` had SIX 32-bit barrel shifters where its comment claimed one
   pair.** "One left shifter and one right shifter serve all three opcodes" was
   the intent; the code had `xz<<sh`, `xz>>sh`, `xs<<sh`, `xs>>sh` and the two
   the rotate builds. SHL/SHA/ROT are mutually exclusive, so the operand and
   distance are chosen BEFORE the shifter. **47-165 ALM depending on the seed**,
   69,121 fuzz checks unchanged.

3. **`mb86233_alu` had four, and two were BYTE-IDENTICAL.** `ALU_LSLD` and
   `ALU_ASLD` computed `reg_d << shamt` in separate case arms. The arithmetic
   right shift is the logical one plus a sign MASK, and a mask with a constant
   operand is a decoder rather than a barrel. **59 ALM**, 2,170,388 cases
   against MAME unchanged.

**THE RULE UNDERNEATH ALL THREE: Quartus does not share logic across case arms
or across distinct expressions.** It will CSE within one expression scope and
nowhere else. If two arms want the same shifter, the source has to hoist it.

**WHERE THE SEAM RUNS OUT.** `v60_ifetch` has the same duplication -- two
24-iteration variable part-selects in exclusive branches -- and NO unit bench,
so it was left alone; write the bench first. `v60.sv`'s 28 variable shifts are
mostly 2-bit element scales and `32'h1 << bit` decoders, which are already
cheap. `v60_fp` is the biggest remaining at ratio 6.97, but `tb_v60_fp` fails
236 of ~5,950 cases in the configuration that SHIPS, so a regression there
would be invisible -- fix the bench before the module.

## 2026-09-15 (b) — PARALLEL BUILDS RACED ON ONE sys_top.v

`tools/mister_project.sh` did `ln -sfn "$tpl/sys" "$stage/sys"` -- every staging
directory SYMLINKED the shared template -- and then sed-edited
`$tpl/sys/sys_top.v` in place for IHRES/OHRES. Three parallel seeds therefore
rewrote one file while the others synthesised from it. Quartus reports it as

    Error (125085): The Quartus Prime Settings File changed outside of the
    Quartus Prime software and contains errors.

which names the **qsf** and is really a race on **sys/**. It cost a seed on
2026-09-15 and had been intermittent before. Staging now copies `sys/` per
build and patches the copy; `third_party/template` is back to pristine and
stays that way, which is also the right side of "never modify the framework".


## 2026-09-14 (e) — PORT 7 CHANGED HANDS MID-TRANSACTION, THE SAME BUG AS PORT 4

Found because Ben refused a bad excuse. The working theory had become "the PCM
starves under gameplay load", and the proposal was to rebuild the sound bench
around the real V60 to prove it. His answer: **Model 2 runs ELEVEN ports with
working sound AND textures on a heavier 3D path.** Capacity was never the
problem, and the excuse was covering for not having looked.

`Model1.sv`, port 7 -- the sound 68000's ENTIRE bus, program ROM and work RAM
on one port:

    snd_mem_req  = snd_rom_req | snd_ram_req;
    snd_mem_addr = snd_ram_req ? RAM : ROM;
    snd_mem_we   = snd_ram_req & snd_ram_we;
    snd_mem_be   = snd_ram_req ? snd_ram_be : 2'b11;
    snd_rom_ack  = snd_mem_ack && !snd_ram_req;
    snd_ram_ack  = snd_mem_ack &&  snd_ram_req;

Every field is a mux on the CURRENT value of `snd_ram_req`. A ROM fetch in
flight when `snd_ram_req` rises has its address changed under it, its byte
enables changed, and its acknowledge delivered to the RAM instead. The 68000
executes whatever comes back.

**THIS IS THE SAME DEFECT AS PORT 4, IN THE SAME FILE**, fixed earlier in the
same session, with a comment beside it reading "a port is a single-transaction
resource: pick an owner when nothing is in flight and hold it until the ack
comes back". Port 7 was never checked.

### Why every instrument missed it

- **It is load-dependent.** In attract the driver sits in a tight loop and
  rarely interleaves ROM and RAM; in a race it does both continuously. The
  sound effects are in the race.
- **tb_m1_sndboard gives the ROM and the RAM SEPARATE PORTS** with independent
  acknowledges. The shared-port hazard cannot exist there, which is why the
  board simulates perfectly -- register traffic byte-identical to MAME,
  descriptors exact, rate within 0.06% -- and fails on hardware.
- **The externalised work RAM is this core's own change.** Model 2 keeps the
  68000's RAM on-chip, so it has no shared port to get wrong. Every comparison
  against Model 2 was looking at a structure they do not have.

### The cost of the detour

Sizing a gain from an idle-window measurement, concluding the rumble was normal,
concluding the audible content was FM -- three wrong turns, all from comparing
ATTRACT-mode audio, and all corrected by Ben rather than by an instrument. The
one that mattered: "sound effects should not be FM", which forced the gameplay
measurement that showed MAME at full scale where we sit at 132.


## 2026-09-14 (d) — WITHDRAWN: "the audible sound is FM". IT IS THE PCM.

**This entry originally concluded the audible sound was FM. That was wrong, and
it contradicted the data in the same entry.** Ben caught it: segam1audio routes
all three chips to the speaker IN PARALLEL --

    m_ym         -> speaker, 0.30
    m_multipcm_1 -> speaker, 0.50
    m_multipcm_2 -> speaker, 0.50

-- so the PCM does not depend on the FM, and the measurement below shows PCM
activity rising 2.5x into gameplay while the YM stays FLAT at 232 writes / 2 s.
The full-scale audio tracks the PCM. The FM being stubbed costs the music; it
does not explain missing sound effects.

The original heading is kept so the reversal is visible rather than tidied away.

## 2026-09-14 (d, as first written) — the measurements, which stand

Measured, after verifying the entire PCM path against MAME and finding nothing
wrong with it.

`tools/mame_play_pcm.lua` inserts a coin and start, then reports write rates:

    attract    PCM 4,408 / 2 s     YM 232 / 2 s    total audio peak ~100
    gameplay   PCM 11,400 / 2 s    YM 232 / 2 s    total audio peak 16,000-31,883

So gameplay audio is FULL SCALE and 250x louder than attract. **Every earlier
comparison here used attract**, where MAME itself is nearly silent -- which is
why -54 dBFS looked like "too quiet" and the idle drone looked like a fault.

And `m1_sndboard`'s YM register trace shows what the driver is actually doing:

    28=00..28=0b   key-on/off, all twelve FM channels
    42,4a,46,4e    total level        52..7e   attack/decay
    82..8e         release            b2, b6   algorithm, pan/LFO

**It never writes 0x24-0x27**, the timer registers -- so the IRQ4 theory is
dead, the driver does not use the YM timer. It does program FM voices
continuously, and `m1_ym_timer` discards all of that, so the MUSIC is missing.
But the YM write rate does NOT change between attract and gameplay while the
PCM's does, and the audio level follows the PCM. **The sound effects are PCM
and they are missing for a different reason.**

### The PCM path is verified correct IN ATTRACT, and only there

| | evidence |
|---|---|
| register programming | byte-identical to `tools/mame_pcm_tap.lua` |
| slot map, register clamp | `v-(v>>3)`, `%8==7` invalid, `>7 -> 7` -- match `VALUE_TO_CHANNEL` |
| descriptors | `s000@020000 s001@0285f0 s004@04df60`, decoded independently from the ROM |
| sample rate | 44,645 Hz vs 44,643 |
| address decode | `addr[23:3]==0x188000` = `0xC40000-7`, matching segam1audio |
| idle character | ours peak 132 / 71 Hz against MAME's ~100 / 125 Hz |

### A third inherited Model 2 clock assumption, not yet fixed

`ym_div` counts 0..5 -- divide by six -- because 48/6 = 8 MHz on Model 2. At
Model 1's 80 MHz that is 13.3 MHz and the FM will play **67% sharp** the moment
jt12 returns. It needs a divide by TEN. Commented in place; harmless while the
FM is stubbed.

### What cannot currently be tested

THIS IS THE GAP THAT MATTERS. `tb_m1_sndboard` has no V60, and replaying MAME's
captured command stream (40 bytes for a whole race) does NOT reach the gameplay
state -- `pcm_writes` stays
at 479 with no commands, with attract commands and with gameplay commands,
identically. So whether the PCM behaves correctly UNDER GAMEPLAY is untested,
and the bench cannot answer it. That needs the sound board in `tb_m1_frame`,
behind the real V60.


## 2026-09-14 (c) — THE "RUMBLE AND STATIC" WAS THE GAIN I ADDED

Recorded because three build cycles went into making this WORSE, and the
measurement that settles it takes four minutes.

The board produced a constant rumble with intermittent static, never resembling
a sound effect. The working assumption was that samples were being fetched or
decoded wrongly. **MAME says otherwise.** `mame vr -seconds_to_run 75
-wavwrite`, in five-second windows:

        0-35 s   peak    ~100   zero-x ~125 Hz    idle
       35-40 s   peak  16,330   zero-x  395 Hz    the attract audio
       40-65 s   peak    ~100                     idle
       65-70 s   peak  16,322                     the next burst

**THE REFERENCE IS NEARLY SILENT FOR THIRTY-FIVE SECONDS AT A TIME**, and while
it waits it produces the same low-level ~125 Hz drone we do (ours: peak 132,
71 Hz). The real audio is **-6 dBFS** and needs nothing added to it.

The x16 gain came from reading -54 dBFS on the board and sizing a gain to it.
**That reading was taken during the idle window.** The gain amplified the drone
to audibility -- the "rumble" -- and saturated the 16,330 peaks -- the
"static". Both symptoms were manufactured by the fix, not revealed by it.
Unity restores the reference's own level.

### What was verified while chasing the wrong thing

None of it was wasted; all of it is now known-good rather than assumed:

| | how |
|---|---|
| register programming | `tools/mame_pcm_tap.lua` taps segam1audio's 68000. Ours is BYTE-IDENTICAL: `bank=01 bank=01 1=00 2=09 0=0f 2=05 0=fe 2=04 0=00 1=01 ...` |
| slot translation and register clamp | `v - (v>>3)`, `%8==7` invalid, `>7 -> 7` -- all match `VALUE_TO_CHANNEL` and `m_address` |
| sample descriptors | traced out of the RTL and decoded from the ROM independently: `s000@020000 s001@0285f0 s004@04df60`, exact |
| sample rate | 44,645 Hz against the chip's 44,643 |
| address decode | `addr[23:3] == 0x188000` is exactly `0xC40000-7`, matching segam1audio's map |

### The instrument lesson, for the third time this session

**Do not size a correction from a measurement taken in the wrong window.** -54
dBFS was real, and it described silence. The same error in a different costume
as the display-list census and the zero-latency PCM bench: the number was
right, what it was a number OF was wrong.

And `third_party/mame`'s `multipcm.cpp` is **TRUNCATED** here -- 185 lines
against the real ~700, with `update_step` called but never defined. Source
reading against that copy is unreliable; run the binary instead.


## 2026-09-14 (b) — THE SAMPLES PLAYED 1.6x TOO FAST: a 50 MHz default on an 80 MHz clock

The first audio this core ever produced was, on the board, "a rumble and slight
crackle constantly -- it does not resemble any SFX", at a correct level.

**Ben's objection is what found it.** The working theory was that PCM reads
above the loaded 2 MB were fetching the display lists. He pointed out that if
only SOME voices were out of range, the in-range ones should still have played
recognisably -- and none did. That rules out a partial fault and demands one
that breaks EVERY sample.

`m2_pcm_rate`'s parameters are written for Model 2's 50 MHz clk_sys:

    parameter CE_NUM  = 20,    CE_DEN  = 50            // the chip's enable
    parameter OUT_NUM = 44643, OUT_DEN = 50_000_000    // the drain

and `m2_sound_board` instantiated it as `m2_pcm_rate #(.BYPASS(!PCM_RATE))` --
forwarding NOTHING. It forwards TICK_NUM/TICK_DEN to the 68000 and stops there.
On Model 1's 80 MHz clock the drain therefore ran at

    80e6 x 44643 / 50e6 = 71,429 Hz      against the chip's own 44,643

and the chip's own enable at 32 MHz instead of 20. Measured in
`tb_m1_sndboard`: **71,456 samples/s**, and 80/50 is exactly that 1.60 ratio.
Every sample played 60% fast, which is not "wrong pitch" so much as
unrecognisable.

TICK_DEN IS clk_sys IN MHz by construction, so it is the one number both stages
need. Passing `.CE_DEN(TICK_DEN), .OUT_DEN(TICK_DEN * 1_000_000)` gives

    before   71,456 Hz
    after    44,670 Hz   (chip wants 44,643 -- 0.06% out), underruns 0

and reproduces Model 2's existing defaults exactly when TICK_DEN is 50.

### Four hypotheses died on the way, all by measurement

| | how it died |
|---|---|
| PCM cache bypass starving the chip | identical rate and zero underruns at fetch latency 1, 40 and 80 |
| MultiPCM banking | matches `segam1audio`'s `a < 0x100000 ? a : {bank_sel, a[19:0]}` exactly |
| byte order in the 64-bit line | `m_data[7:0]` is file byte 0, matching the SDRAM burst assembly |
| loader split and MRA layout | 7 boundary probes in `tb_m1_rom_loader`; `verify_mra` passes byte-for-byte |

### And the instrument was blind twice before it worked

**`tb_m1_sndboard` acked every PCM fetch on the SAME CYCLE as the request.**
`ACK_HOLD` set how long the ack stayed up, not how long it took to arrive, so
fetch latency was ZERO. Comparing PCM_CACHE 0 against 1 under that answered
nothing -- a cache exists to hide latency. `PCM_LAT` now models the delay.

**And the harness never passed TICK_DEN either**, so it ran the board at
80 x 20/50 = 32 MHz. Fixing that changed the 68000's instruction count
(1,159,595 -> 901,005) and left the sample rate untouched, which is what
isolated the fault to the rate stage rather than the tick.

**A bench that does not match the top level is measuring a machine nobody
builds.** Both defaults were Model 2's, both were silently inherited, and
neither was visible until the number they produced was compared against the
hardware it claims to model.

### Still true, and NOT the rumble

PCM reads above the loaded 2 MB are now zeroed, which is what MAME's erased
region does -- `model1.cpp` gives each chip 0x400000 and loads 0x200000. Bit 21
is the BANK, not an overflow: the chip emits 2 MB and the upper megabyte is a
window onto one of four 1 MB pages. For vr, banks 2 and 3 are MAME's zeros, so
the masking is correct -- it just was not the fault.


## 2026-09-14 — clk_sys CLOSED: the critical path was ONE path, and it was already named

Every timing round on this core has been a seed lottery. Four seeds of the same
design gave **-0.601, -0.747, -0.831 and -3.473** on `clk_sys`, and a
distribution centred below zero is a slow path, not luck. So instead of buying
a fifth ticket, the path was read:

    quartus_sta -t paths.tcl   (get_timing_paths -setup -npaths 5)

**All five worst paths in the design were the SAME path**, and it is the one
`docs/HANDOFF.md` had already written down:

    emu|m1_integrated|m1_video|m1_video_timing|vcnt[7]
      -> m1_main|m1_mainram|m1_tdp_ram:u_pram|...|portb_address_reg0

`assign pal_addr = mixed;` — the raster counter through the entire tile fetch
and mixer priority resolution, combinationally, into an M10K's port B address.
Deep logic AND a long route to wherever the fitter put the block.

Registering `pal_addr` closed it:

    before   clk_sys -0.601   clk_3d  +0.4    pll_hdmi -0.352
    after    clk_sys +0.037   clk_3d  +0.418  pll_hdmi +0.495

**Every clock in the design is positive for the first time**, the framework's
HDMI PLL included — that had been negative in every build on record.

**IT COSTS NO PICTURE SHIFT, and that is why it was safe to do.** `ce_pix` is
**/6**: six core cycles per pixel, and this chain used one of them. Two still
settles inside the dot period, and `m1_video`'s output stage latches on
`ce_pix` rather than on a cycle count, so nothing downstream counts cycles.
`tb_m1_video` passes 380,929 checks unchanged.

**The lesson is the cheap one.** A Quartus build is 25-80 minutes and a seed
sweep is four of them. `get_timing_paths` is three minutes and it named the
fault, the module and the line. When the slack distribution across seeds is
centred below zero, stop sweeping and read the path.


## 2026-09-13 — the blue screen was FOUR bugs in the display-list move, and none was arbitration

Moving the two display lists out of `m1_mainram`'s block RAM into SDRAM
(`rtl/mem/m1_dlist_sdram.sv`, 64 M10K freed) produced a blue screen: the 2D
layer drew, the 3D layer drew nothing at all. Sound was unaffected and
confirmed working on the board throughout (DISK and POWER both solid).

**The first suspect was wrong and cost a build cycle.** Port 4 is shared
between the I/O firmware fetch and the display lists, and its arbitration was
combinational, so ownership could switch mid-transaction. That is a real
defect and it was fixed with a latched `p4_owner_dl`. **The blue screen
survived it.** A plausible mechanism that is genuinely broken is still not
evidence that it is THIS symptom's mechanism.

### Bug 1: address bit 14 is an OUT-OF-RANGE FLAG, not the bank select

`m1_integrated.sv` wired `m1_dlist_sdram`'s `rd_bank` from
`dl_rd_addr_w[14]`. The original, at `m1_mainram.sv:224`:

```
  assign r3d_dl_data = r3d_dl_sel ? dl1_b_q : dl0_b_q;
```

with, twenty lines above it:

```
  wire dl_b_hi = r3d_dl_addr[14];
  ...
  assign dl0_b_q = dl_b_hi_q ? 16'h0000 : dl0_b_raw;
```

So the list is chosen by **`r3d_dl_sel`**, the reader's own buffer-select
register, and bit 14 of the address means "at or above the 16,384 words a list
holds" — a read there returns zero, and the walk relies on that zero to stop.
Both meanings were collapsed onto one wire. The walker read list 0 every frame
against a game that alternates, and out-of-range reads selected list 1 instead
of terminating.

The original module's comment says it outright — *"The buffer select is the
reader's, and it is applied to the DATA rather than the address"* — and it was
read past twice.

The same flag exists on the write side (`a_we(dl0_we && !dl_a_hi)`, gated on
`addr[15]`), and the replacement truncated instead of dropping, so an
out-of-range write wrapped onto a live word. `m1_main` now exposes `dl_hi` and
both sides reproduce the original behaviour.

### Bug 2: the walk WITHDREW a request it had already issued

This is the larger one, and it explains the symptom by itself.

`m1_listwalk` had `assign mem_req = in_read && !rd_gap && !stall`, and
`wire got = mem_req && mem_valid`. Against block RAM that was free: the old
`m1_integrated` drove `r3_dl_valid <= r3_dl_req`, one cycle, unconditionally,
so a request and its answer were adjacent cycles and abandoning one cost a
cycle.

Against SDRAM across a clock crossing the answer arrives tens of cycles later —
and `m1_raster3d` asserts `lw_stall` for **the whole of every quad's
transform** (`lw_stall = ((pst != P_WALK) && (pst != P_IDLE)) || w_tex_req`).
So a stall lands inside nearly every read. `mem_req` dropped, the arriving word
was discarded by `got`, and the walk re-ran the entire round trip. Measured in
`tb_m1_listwalk` with the withdrawal restored, at 24 cycles of latency:

```
    request withdrawn   78,635,456 cycles / 43,289 words = 1,816 cycles/word
    request held            43,958 cycles /  1,224 words =    35.9 cycles/word
```

**A 50x slowdown.** A 3,000-word list at 1,816 cycles a word is 5.4 M cycles —
fourteen frames. No list ever completed, so nothing was ever drawn.

The fix holds `mem_req` until the read is answered, latches the word whenever
it lands, and hands it to the walk when the walk resumes. The
one-outstanding-read discipline and the gap cycle are unchanged; only the
withdrawal is gone.

### Bug 3: the base address was added TWICE, putting the lists inside the ROM

Found by the frame bench dumping both lists and getting 16,384 words of
`ffff` -- the SDRAM model's default for never-written -- at the address the
module claimed to use.

`m1_dlist_sdram` forms an ABSOLUTE address: `mem_addr <= DL_BASE + {rd_bank,
rd_addr}`. `Model1.sv` then did `p4_addr = DLIST_BASE + dlist_addr_r`, and a
comment beside the port instantiation asserted the opposite of the truth --
*"m1_dlist_sdram emits an offset within the 32 K-word region and DLIST_BASE is
added outside"*.

    module   DL_BASE     0xC40000  (its own default -- Model1's parameter was
                                    declared and never passed)
    Model1   DLIST_BASE  0xF40000
    sum                 0x1B80000  -> 24 bits -> 0xB80000

The polygon ROM image runs to word `0xC20000`, so **both display lists sat
inside it**. Every list write corrupted polygon data, and reads came back from
the corrupted region. The two bases being different is what made the sum wrap;
had the parameter been passed, the double-add would have been `0xF40000 * 2`
and equally wrong.

The base is now added in exactly one place: `m1_integrated` takes `DLIST_BASE`
as a parameter, passes it to `m1_dlist_sdram`'s `DL_BASE`, and the top level
uses `dlist_addr_r` untouched.

### Bug 4: a held write was enqueued once per CYCLE, not once per transaction

`m1_main` holds `m_req` until `m_ack`, and holds `m_ack` until `m_req` drops --
its own `B_ACK` comment explains why, and it is the rule this project has been
bitten by twice. The V60 runs on a clk/3 enable, so **one write presents for
three to six cycles**.

`m1_mainram` consumed exactly that signal as a block-RAM write enable, where
re-writing the same word at the same address for six cycles is free. A FIFO
COUNTS. `wire cpu_wr = (cpu_sel0 | cpu_sel1) & cpu_we` enqueued every write
three to six times over, filled the 64 entries, and refused the real traffic.

Negative control, with the edge detect removed, 40 writes held six cycles each:

    153 of 240 pushes refused, and the data lost

The level is safe to re-read; the EDGE is the event. Same treatment for the
read-back counter, which was counting cycles of the decode -- and `sel_dlist*`
is combinational on `m_addr`, so it counts even when no request is outstanding
at all. That is why the first read-back measurement read 977,784 and the
correct one reads 32,840.

### Bug 5 is WITHDRAWN: the V60 does NOT read its display lists

Recorded here for a day as "32,840 completed read-backs in 426 frames", and it
was wrong. The counter was placed in `m1_main`'s `B_LOCAL` else chain, at
`else if (sel_dlist0) rdata_r <= dl0_q;`. **That chain runs for writes as well
as reads** -- `rdata_r` is simply ignored when the access is a write -- so it
counted list WRITES and called them reads.

Re-gated on `!m_we`, the count is **zero**. `tools/dl_census.lua` was right:
the game does not read its display lists back.

The read path built on the strength of the wrong number is kept, because it is
correct and costs nothing when nothing exercises it -- `m1_main` waits for
`dl_rd_ack` the way it waits for the coprocessor, the module drains its posted
writes before serving a read so ordering holds, and both are tested. If a game
ever does read a list it will now get its data instead of zero. But it is not
what blanked the screen, and this entry is here so the next session does not
re-derive a fix for a problem that does not exist.

**The lesson is the one directly above it, applied to my own instrument.** I
wrote "when a measurement says never, check that the instrument could have seen
it" into the entry for Bug 5, and then trusted a counter that could not tell a
read from a write. A counter has to be placed where the thing it counts is the
only thing that can reach it.

It also cost a real bug of its own: `to_dlist` was `sel_dlist0 || sel_dlist1`
with no `!m_we`, so a list WRITE entered the read branch and waited for an ack
that could never arrive. The CPU hung with `m_req` and `m_we` stuck high, and
the bench counted a list write offered on 556,962,710 of 560,000,000 cycles --
every one of them. That number is what named it.

### STILL OPEN: 92,232 writes commit, 18 words land

With all four real bugs fixed, at 560 M cycles / frame 426:

    writes offered   334,969 cycles, dropped 0
    port 4 grants    lists 92,232, iofw 87,524      no starvation
    words in SDRAM   18, in each list
    passes with objects   0        (pre-move control at the same point: 45)

The writes are accepted, granted the port and committed, and eighteen distinct
words are visible at `DL_BASE`. Either the game is writing the same small
header in a loop because it is waiting on something else, or the committed
writes are not landing where the dump reads. That is the next measurement:
the min, max and spread of the addresses `m1_dlist_sdram` actually drives.

### THE MOVE IS REVERTED, and that is the finding

Fixing four real bugs did not restore the picture. At 560 M cycles the tree
still had 0 passes with objects against a pre-move control's 45, and the V60
was issuing 77 list writes a frame against a census of 3,032 -- it was running
different code, and after a day the reason was still unidentified.

**The move was worth 54 M10K. It is a resource optimisation, not a feature, and
it was bundled with the sound work that had to ship.** That bundling is the
actual mistake: every measurement afterwards compared a tree with five
unrelated changes against a tree with none, so nothing could be attributed. The
`git worktree` control was built at HEAD, which differs by `v60_fp.sv`,
`m1_rom_loader.sv`, `m1_sdram.sv`, `m1_copro_if.sv` and the whole sound board
as well as the lists.

Reverted, `tb_m1_frame` gives 25 passes with objects and f=233 against the
control's f=232. The work is preserved in `build/dlist_work/` with its tests.

**What the four fixes are still worth**: they are real, they have negative
controls, and whoever picks the move up again needs all four before they start.
They are not wasted -- but they were not the blocker, and continuing to fix
bugs inside a change that had already failed its own acceptance test is what
cost the day.

### The control, and its confound

Reasoning about which of five bugs was "the" one was worth nothing. A
`git worktree` at HEAD -- the pre-move tree, with its own bench -- run to the
same 560 M cycles as the fixed tree, on the same ROMs and the same inputs:

    pre-move (block RAM)   45 passes with objects, obj=1 q=62   3D WORKS
    SDRAM (the move)        0 passes with objects, obj=0 q=0    BLANK

One command, twenty minutes, and it turned "I think the 3D is fixed" into a
number. Build the control BEFORE the fix, not after.

**But that control was CONFOUNDED and it took hours to notice.** HEAD differs
from the working tree by every uncommitted change, not just the display lists.
`v60_fp.sv`'s denormal flush was suspected on that basis and cleared only by a
separate run with `+define+V60_IEEE_DENORM`, which came back byte-identical. A
control that differs in five ways measures nothing. Revert to ONE difference,
or the number is not evidence.

### And the bench could not have caught any of it

`tb_m1_frame` never wired `m1_integrated`'s `dlist_*` ports at all. The
`m1_frame` target passes `-Wno-PINMISSING`, so elaboration said nothing:
`dlist_ack` sat at zero, the posted-write FIFO filled, every write was dropped,
and the walk read an empty list. The bench printed `obj=0 q=0` and read as a 3D
bug.

Three separate mechanisms hid these bugs, and they are the same mechanism:
**a check that was silently not running.** `-Wno-PINMISSING` hid the missing
port; `m1_dlist_sdram` was not in `make test`; the module was not in the
Makefile's `SRCS_TOP_CORE` or in `tools/mister_project.sh`. Every one of those
is a list that must be edited by hand when a module is added, and every one of
them fails by omission rather than by error.

### Why no test could see the first two

`tb_m1_listwalk`'s memory model was a one-cycle synchronous RAM, *because the
lists were block RAM*. It even has a test called "STALLING pauses the walk
without losing anything" — which passes, and which cannot reach the window,
because at one cycle of latency there is no window. The model now takes a
latency parameter and there is a directed test at 24 cycles with stalls raised
only while a read is in flight. It checks the decode against `model()` and,
crucially, a **cycle budget**: a walk that refetches blows through it by 30x.
Reverting the fix fails it immediately.

`m1_dlist_sdram`'s own bench passed throughout and was never in `make test` —
it tested the module against a dedicated port with flags the integration never
set. It is in `make test` now, with directed coverage for both out-of-range
paths.

**The lesson is the one this file keeps recording.** A module that replaces
another must reproduce what the original's ADDRESS DECODE did, not just what
its storage held: block RAM whose address bus physically could not reach past
16 K words encodes a behaviour that SDRAM's can. And a bench whose memory model
was written to match the old implementation silently stops being a test of the
new one — its latency was a property of the thing being replaced.

## 2026-09-13 (b) — EIGHT M10K OVER COSTS ~570 ALM, SILENTLY

The design stopped fitting after the display-list revert: 42,384 ALM (101%) and
**M10K 561/553**. The obvious reading was "the sound board does not fit without
the M10K the move freed". That was wrong, and it nearly cost a feature.

`m1_sdram`'s `cap` array (`[NP-1:0][3:0][15:0]`) had been left unpinned during
the sound work so it would land in M10K -- 8 blocks -- rather than cost ~16
LABs. With the display lists back on-chip that took M10K to 561 of 553.

**Quartus does not fail when M10K is oversubscribed. It builds the overflow out
of flip-flops and keeps going.** The rules file already says so, for inference that
fails; it applies just as much to inference that succeeds and then has nowhere
to go. Forcing `cap` back to `ramstyle = "logic"`:

    before   42,384 ALM (101%)   M10K 561/553    NO FIT
    after    41,353 ALM ( 99%)   M10K 553/553    fits, all four seeds

`cap` in logic costs about 160 ALM of its own, so the spill it was causing was
roughly **570 ALM**. The ALM number was a SYMPTOM of the M10K overshoot, not an
independent problem -- and an 8-block overshoot reads as a 500-ALM one.

**Check M10K before believing an ALM figure.** Ben's correction ("it did fit, we
have tested loads of times") is what forced the comparison against the morning's
fitting build, and the two numbers together named the cause in minutes.

### And the M10K itself is being wasted, badly

From the same fit report, shallow-wide arrays mapped to M10K at ~0.3%
efficiency:

    m1_geo_clip sk_mem    20 x 96   ->  96 blocks for 1,920 bits
    m2_multipcm desc_ram  32 x 55   ->  55 blocks each, x2
    m2_multipcm pos_ram   32 x 38   ->  38 blocks each, x2
    m2_pcm_rate fl/fr     16 x 16   ->  16 blocks each, x4  (256 bits!)

About **346 blocks holding ~10 Kbit**. `m1_geo_clip` carries an explicit
`(* ramstyle = "MLAB" *)` and Quartus **ignored it**. Fixing this is worth far
more than the 54 blocks the display-list move was chasing, and it needs a small
test case rather than a full build to settle -- the rules file's own advice on memory
idioms. NOT attempted yet.


## 2026-09-13 (2) — THE NEGATIVE SLACK IS TWO PATHS, AND ONE OF THEM IS NOT OURS

**Instrument:** `quartus_sta` with `get_timing_paths -setup -npaths 40`, filtered
for paths that do not touch `ascal`. Eleven seeds across two designs never closed
it, which is what prompted looking at the path instead of re-rolling.

### pll_hdmi, -0.838: entirely inside the framework

```
ascal|o_h_poly_t.r0[16]  ->  ascal|o_h_poly_pix.r[1]
```

The polyphase filter's horizontal interpolation. **No part of it is this
project's logic.** pll_hdmi has shipped negative before (-0.096 on 2026-09-08,
-0.338 on 2026-09-09) on builds that ran correctly.

### clk_sys, -0.650: ours, and always the same path

Every failing clk_sys path in the top forty is this one:

```
m1_video|m1_video_timing|vcnt[7]    (also [9])
  ->  m1_mainram|u_pram|altsyncram|ram_block1a*~portb_address_reg0
```

The video timing's VERTICAL COUNTER feeding the PALETTE RAM's read address.
`m1_video.sv:814` is `assign pal_addr = mixed;` -- the mixer's combinational
output -- and it crosses into `m1_mainram.sv:146` as `.b_addr({1'b0,
vid_pal_addr})` on a block RAM's registered address port. The whole tile
fetch and mix sits in that path with no register between the counter and the
memory.

**The fix is a pipeline stage on `pal_addr`**, which is a DESIGN CHANGE and not
a re-roll: it delays the palette read by one cycle and shifts the picture one
pixel unless the compensation is made at the same time. Not attempted here.

### Why seeds cannot fix it

| design | seeds tried | best | clean? |
|---|---|---|---|
| 553 M10K | 1,3,5,7,9,11,2,13,17,23 | **-0.240** (seed 11) | no, 3 negative |
| 499 M10K | 3,11,13,17 | -0.384 (seed 17) | no, 2 negative |

Both distributions are centred below zero. That is a path that is too slow, not
a placement lottery -- the distinction the Kaneko16 note in
`tools/mister_project.sh` draws, and this is the other side of it.

**Freeing 54 M10K made timing WORSE, not better** (see the entry above): the
density that hurts placement here is ALM at 99%, not memory.

---

## 2026-09-13 — THE DISPLAY LISTS ARE OFF-CHIP: 553 -> 499 M10K, AND IT DID NOT HELP TIMING

**Instrument:** `tools/dl_census.lua` for the traffic, `sim/mem/tb_m1_dlist_sdram.cpp`
for the design, `make rbf` for the result.

`m1_mainram`'s `u_dl0`/`u_dl1` were 16384x16 each -- **64 of the 553 M10K blocks**
-- and M10K had been at 553/553 for the whole sound effort, with a one-bit
signal widening costing eight blocks and failing the fit.

**The traffic, measured before any code was written** (400 reference frames,
a read tap AND a write tap on 0x600000/0x610000):

| | |
|---|---|
| writes | 3,032 per frame mean, **16,418 at peak** |
| **reads** | **ZERO. Not one, on either list.** |

Zero reads is what makes it clean: every access is a write, so every access is
POSTED and the V60 never waits, and there is no CPU read path to build. The
replacement sustains **one write every 16 cycles** against a measured peak
demand of one every 85 -- a 5x margin, measured by sweeping the rate until the
FIFO refused (`tb_m1_dlist_sdram`, 6,877 checks).

### It shares port 4 rather than adding an eleventh

`NP=11` IS BROKEN and that is why. `tb_m1_sdram` at `TB_NP=11` reports **"port 10
never acknowledged"**: the eleventh port serves one read and then stalls forever.
Unexplained. The lists need one write per 85 cycles, so they ride the I/O
board's firmware port behind a priority mux -- the Z80 wins because it is
stalled waiting, the list writes are posted and can afford to queue.

### The result, and the part that did NOT work

| | before | after |
|---|---|---|
| M10K | 553 / 553 | **499 / 553** |
| ALM | 41,418 | 41,409 |
| worst setup | -0.219 | **-0.838** |

**54 blocks freed, and timing got WORSE.** Freeing block RAM does not relieve
`clk_sys`, because the density that hurts placement here is LOGIC: ALM is still
99%. Seven seeds on the pre-move design clustered between -0.24 and -1.13, which
is a distribution centred below zero rather than a placement lottery.

**The lever for slack is not memory.** If a seed does not close it, the
remaining option is pipelining the actual failing path, which is a design
change and not a re-roll.

### Two mechanical traps on the way in, both documented already

- `m_addr` is `[23:1]` -- a WORD address with no bit 0. `m_addr[13:0]` is an
  out-of-range slice that **Verilator accepts and Quartus rejects**.
- A new RTL file must be added to `tools/mister_project.sh` or the hardware
  build fails at elaboration with an error that does not name the missing file
  (`Node instance "u_dlist" instantiates undefined entity`). The rules file warns
  about this; it still happened.

---

## 2026-09-12 (2) — ascal's OHRES IS WORTH 8 M10K AT 2048, AND READING THE SOURCE SAID IT WAS WORTH NOTHING

**Instrument:** `make rbf` with `OHRES` 2304 (the framework default) against 2048,
everything else identical.

| | M10K |
|---|---|
| OHRES 2304, `cap` in block RAM | **561 / 553** -- would not fit |
| OHRES 2048, `cap` in block RAM | **553 / 553** -- fits |

**Eight blocks, which was exactly what was needed.** `sys_top.v` never sets
OHRES, so every MiSTer core takes the 2304 default.

**I PREDICTED THIS WOULD GIVE NOTHING, FROM THE SOURCE, AND WAS WRONG.**
ascal maps OHRES through case statements (`ascal.vhd:296-318`):

```
ohres_l: 1024 => 1024 | 2048|2304|2560 => 2048 | OTHERS => 4096
ohres_m: 1024|2048|2304 => 256         | OTHERS => 512
```

`o_line0..3` are sized by OHRESL and `o_linf0..3` by OHRESM, and BOTH are
unchanged between 2304 and 2048 -- which is why I said the line buffers do not
shrink. They do not. Something else does: only `OHRESH` changes (4096 -> 2048),
and it sizes counters rather than memory, yet the fit needs eight fewer blocks.
The mechanism is not in those three functions and I have not run it down.

**Take the measurement, not the derivation.** Ben pushed to build it after I had
written the lever off on paper.

### The values that are legal, and the trap

Only 1024, 2048, 2304, 2560 are matched; ANYTHING ELSE falls to `OTHERS` and
allocates 4096-wide buffers -- WORSE than the default. 1680 and 1920 are both in
that trap, and both are also below 1920 or equal to it, so they would tear a
1080p line as well.

| OHRES | `o_line0..3` | good for |
|---|---|---|
| 1024 | 1024 | 720p and below ONLY |
| **2048** | 2048 | **1080p -- what this core uses** |
| 2304 | 2048 | 1080p, no benefit over 2048 |
| 2560 | 2048 | 1440p |
| 1680, 1920, other | **4096** | nothing -- silently the worst case |

IHRES is the input side and is a separate lever, already at its floor of 512:
this core's picture is 496 pixels wide (`m1_video_timing.sv:37`), so 512 is the
smallest power of two that holds a line. That one was worth 27 blocks.

**If the picture ever tears or repeats horizontally at a wide output
resolution, OHRES is the first thing to put back to 2304.**

---

## 2026-09-12 — THE SHARED SOUND BOARD IS 6 dB QUIET, AND MAME SAYS WHY

**Instrument:** MAME's own configuration for the Model 1 sound board, plus a
captured reference and a simulation of our own board against the same ROMs.

`third_party/mame/src/mame/shared/segam1audio.cpp` routes the three chips with
DIFFERENT gains:

```
m_multipcm_1->add_route(0, "speaker", 0.5, 0);
m_multipcm_2->add_route(0, "speaker", 0.5, 0);
m_ym->add_route(0, "speaker", 0.30, 0);
```

`m2_sound_board.sv` sums all three and applies ONE shift:

```
wire signed [17:0] mix_l = ym_l + p1_l + p2_l;   // sign-extended
assign snd_l = mix_l[17:2];                      // >> 2, i.e. 0.25 for everything
```

**So the MultiPCMs come out at 0.25 where MAME uses 0.5 -- exactly half.**

Three independent measurements agree:

| | |
|---|---|
| MAME reference, `vr`, 20 s captured to WAV | peak 127 of 32,767, **-48.2 dBFS** |
| our board in `tb_m1_sndboard`, real sample ROMs, 5 s | peak 66, **-53.9 dBFS** |
| Ben, comparing Model 2 against the reference | **"too quiet by 52%"** |

-53.9 against -48.2 is 5.7 dB; a factor of two is 6.0 dB; 52% is a factor of
two. The same number three ways.

**The fix is `>> 1`, not `>> 2`**, and it is not a bodge -- it is what MAME's
0.5 route gain says. The `>> 2` is headroom for summing three 16-bit sources
without clipping, and with the FM stubbed (`m1_ym_timer` has no audio path, so
`ym_l` is permanently zero) only two sources are live: two 16-bit signed values
fit in 17 bits and the extra bit of headroom cannot be used.

**CARRY THIS TO MODEL 2 WITH CARE.** It is the same `m2_sound_board.sv` and the
same fault, but Model 2's FM is not stubbed. A bare `>> 1` puts the YM at 0.5
where MAME uses 0.30, about 4.4 dB hot against the samples. Exact parity needs
the YM scaled on its own -- `(ym * 5) >> 4` is 0.3125 -- rather than sharing the
shift. Model 1 is unaffected while the FM is stubbed.

**And this is NOT why the Model 1 board was silent.** Six dB does not turn audio
into nothing. The silence was `m1_sdram` tagging in-flight reads with
`grant[2:0]` in a ten-port controller, so the two MULTIPCM ports wrapped onto
ports 0 and 1 and never received a word; see the entry below. The quietness is
a separate, real defect that was found while chasing it.

---

## 2026-09-11 (5) — THE V60's DENORMAL SUPPORT COSTS 353 ALM IN-DESIGN, AND EVERY FREE WAY TO GET IT BACK MEASURES ZERO

**Instrument:** `make quartus MOD=v60_ftz` / `MOD=v60_fphoist` against
`MOD=s32_v60`, all `QOPT="Aggressive Area"`, then a full `make rbf`. FP
correctness from `third_party/s32/verif/v60/tb_v60_fp.sv` under Icarus.

`v60_fp` is 3,218 combinational ALUTs for 389 registers -- 8.3 comb per
register, against the i960's FP units at about 1.2. It is built from
SystemVerilog `function`s and has exactly ONE clocked block, at line 419 of 550.

| change | standalone ALM | in-design ALM | tb_v60_fp |
|---|---:|---:|---|
| baseline | 15,057 | 42,885 | pass |
| flush denormals in AND out | 14,491 (**-566**) | 42,532 (**-353**) | **236 fails of ~5,950** |
| hoist the six operand unpacks to two | 15,052 (**-5**) | — | pass, 0 fails |

**Two things are established here and both correct an assumption made in the
same session.**

**1. The standalone module over-reports a saving by 60%.** -566 ALM measured on
`MOD=s32_v60` became **-353** in a full `make rbf`. The standalone build's ports
are pins, so Quartus cannot constant-propagate across the boundary. Price
anything that matters with a full build; Ben's instruction, and the numbers
agree.

**2. The duplication theory was wrong.** `fp_unpack` is a function, so it is
inlined at all ten of its call sites, and ADDFS/SUBFS/MULFS instantiate SIX of
them on two values -- with SUBFS passing `fp_unpack(a ^ 32'h8000_0000)`, whose
argument expression differs from `fp_unpack(a)`. That is textbook the condition
that made the `fb32()` hoist worth 1,054 ALM (2026-09-07), so the hoist was
built: `fp_unpack(a ^ 0x8000_0000)` is EXACTLY sign-flipped `fp_unpack(a)`,
because unpack takes `sign = x[31]` and derives e and m from `x[30:0]`.
It is behaviour-identical -- `tb_v60_fp` passes with 0 failures -- and it is
worth **-5 ALM**. Quartus was already sharing them. **The denormal logic exists
ONCE and costs what it costs.** This is the third time hand-sharing has priced
at approximately nothing; see 2026-09-07's rule.

### The correctness position, stated carefully

**A claim made earlier in this session was wrong and is withdrawn.** "The fuzz
harnesses deliberately skip denormals, so this is unverified" is about the
**TGP** -- `README.md:191-195` and the `FLUSH_DENORM_IN` parameter live on
`rtl/tgp/fp_div.sv`, not on the V60. The V60 has its own suite and it covers
denormals. Splitting the change shows both halves are exercised:

| flushed | tb_v60_fp failures |
|---|---:|
| denormal INPUTS only | 204 |
| denormal OUTPUTS only | 76 |
| both | 236 |

So there is no free subset. **But the failures are against `numpy.float32`** --
`tb_v60_fp`'s header says "expectations from numpy.float32 (IEEE-754 RNE, the
MAME host-float contract)" -- and `README.md` records the repo's own position
that "real silicon of this era commonly flushes to zero" and that the question
must be resolved "against real microcode traces, not against the host". The 236
failures are therefore a disagreement with a HOST-FLOAT MODEL, not with measured
hardware. Flush-to-zero is a different unverified guess, not a known regression.

**What would settle it:** `make v60_trace` on vr, vf and netmerc. If the games
never produce or consume a denormal, the two behaviours are observationally
identical on real code and the 353 ALM is free in practice. Until that is run,
the change stays out of the tree; `build/v60_fp_backup.sv` holds the clean file
and `rtl/cpu/v60/v60_fp.sv` has been restored from it.

### Where the V60's area actually is

Structure pricing, each forcing a destination register constant so its mux tree
and everything feeding only it folds away (standalone, baseline 15,057):

| forced constant | ALM | delta |
|---|---:|---:|
| `str_src`/`str_cnt`/`str_faddr`/`str_fi` | 13,600 | **-1,457** |
| `bit_val`/`bit_len`/`bam_off`/`bam_base` | 14,145 | **-912** |
| `dbus_addr` | 14,177 | **-880** |
| `ea_addr`/`ea_out` | 14,432 | **-625** |
| `pc` | 14,559 | **-498** |
| `exc_pushval`/`exc_vector`/`exc_retpc`/`exc_code`/`exc_extra` | 14,763 | **-294** |

This is the first attribution of the top module's area; 2026-09-07 stopped at
"the remaining ~12,700 is ... not one structure". **It is a map, not money.**
`dbus_addr` is the proof: it prices at 880 and narrowing it measured EXACTLY
ZERO the same day.

### And the V60 cannot fix this build anyway

The full `make rbf` fails on **two** errors, and ALM is the second one:

```
Error (170048): Selected device has 553 RAM location(s) of type M10K block.
                However, the current design needs more than 553
Error (11802):  Can't fit design in device.
```

**42,532/41,910 ALM (622 over) and 582/553 M10K (29 over). The V60 contains zero
M10K**, so no amount of squeezing it produces a fitting build. The 29 blocks
have to come from the display lists (64, see 2026-09-11 (3)) or the quad store
(188).

---

## 2026-09-11 (4) — ONE-HOTTING THE V60's SEQUENCER IS WORTH 63 ALM, NOT THE 13.7% THE MICROBENCH PROMISED

**Instrument:** `sim/microbench/v60_onehot.sv`, a scripted conversion of the
whole core — `typedef enum logic [6:0]` to 91 index localparams, both
`case (st)` blocks to `case (1'b1)` with `st[S_X]` arms (107 arms), 310 `oh()`
sites, `bam_next()` widened. `make quartus MOD=v60_onehot QOPT="Aggressive Area"`
against `MOD=s32_v60` in the same conditions.

| | ALM | registers | own comb ALUTs |
|---|---:|---:|---:|
| binary `st` (shipping) | 15,057 | 4,413 | 16,237 |
| one-hot `st` | 14,994 | 4,497 | 16,184 |
| **delta** | **-63 (0.4%)** | +84 | -53 |

**The reasoning was sound and the result is nothing.** `Model1.map.rpt`'s "State
Machine" sections do list ten extracted FSMs in Model 2's i960 including its main
sequencer `ts`, and do NOT list the V60's `st` — that part is true, and the cause
is the subroutine pattern (`st <= st_after_fill`, `st <= st_after_ea`) which
stops the tool proving a closed state set. What does not follow is that the
binary encoding is costing anything: Quartus builds an efficient select network
either way.

**The microbench over-promised by 20x and that is the lesson.**
`sim/microbench/fsm_binary.sv` vs `fsm_onehot.sv` — 64 states, two return
registers, four wide destinations — measured 791 vs 683 ALM, a 13.7% saving, at
identical register count. On the real core the same transformation is 0.4%. A
synthetic FSM with four destinations does not predict a core with 131.

**This is now the third V60 structural idea to price at approximately zero**,
after mux narrowing (0%, same day) and adder sharing (7% on a bench, 150-250
core-wide, 2026-09-10). Together with 2026-09-07's verdict — "no measurement
taken here shows a path from 15,605 to 10,000" — the position is that **the only
V60 lever that has ever measured positive is stubbing unused instruction groups
at -764 ALM**, and the only structural one that ever paid was hoisting the
runtime-offset fetch-buffer mux at +1,054, which is already taken.

A census of what remains of that winning shape: `fb32()` now has **one** runtime
call site and `fb16()` one; the `ea_ofs` window is hoisted. What is left is
twelve SINGLE-BYTE reads at three `len1`/`len2` offsets, a quarter the width of
the muxes that paid.

---

## 2026-09-11 (3) — WHERE THE 584 M10K BLOCKS GO, AND THE DISPLAY-LIST CLAIM CORRECTED

**Instrument:** the "Fitter RAM Summary" table of
`build/mister/output_files/Model1.fit.rpt` (the failed sound fit, 2026-09-11
22:34), aggregated per module. 144 memories. This census had never been taken —
the M10K figure was only ever known in total.

| M10K | module |
|---:|---|
| **188** | `m1_quad_store` (two stores, five banks each) |
| 64 | `m1_mainram` `u_tram` — tile RAM, 32768x16 |
| 48 | `m1_mainram` `u_cxlat`, 24576x16 |
| 42 | `ascal` (framework) |
| 33 | `m1_copro_if`, 8192x32 |
| 32 | `m1_mainram` `u_dl0` — display list 0, 16384x16 |
| 32 | `m1_mainram` `u_dl1` — display list 1 |
| 32 | `m1_video` |
| 24 | `m1_raster_band` |
| 16 | `m1_mainram` `u_pram` |
| 13 | `m1_tgp` |
| 10 | `m2_sound_board` (plus 214 MLAB cells) |
| 9 | `osd` |
| 8 | `m1_ioz80` (plus 32 MLAB) |
| 7 | `altshift_taps`, 7 `m1_lightbank`, 4 `m1_raster_fill`, 2 `m1_geometry` |
| **584** | **total, against 553 on the device — over by 31** |

Implementation bits equal used bits across the whole table, so **there is no
partial-block waste to reclaim.** Every block is full. The device is at 77% of
its memory BITS in 105% of its blocks because the memories are wide and shallow,
not because they are badly packed. Consolidating small arrays will not help;
only moving a memory off-chip will.

**Two corrections to what the rules file says about the display lists.** It reads
"the two display lists (~52 M10K), which the walker already has an SDRAM read
path for."

- They are **64 M10K**, not ~52 — 32 each, `AW(14)`, 16384x16.
- The walker does **not** have an SDRAM read path. `m1_listwalk.sv:84-90`
  defines a held-request, latency-tolerant port (`mem_addr`/`mem_req`/
  `mem_valid`/`mem_data`) and its comment says "the SDRAM path will need that
  even though block RAM answers next cycle" — the interface was built in
  ANTICIPATION of the path. The path itself does not exist, and the harder half
  is not the read side at all: the display lists are true dual-port with the
  **V60 writing port A at bus speed**, and that write traffic moving to SDRAM is
  unmeasured.

`MISTER_SMALL_VBUF` is not an M10K lever and was checked: `sys_top.v:717` uses
it only to change ascal's `RAMSIZE` parameter, which is a DDR3 buffer.

---

## 2026-09-11 (2) — NARROWING THE V60's WIDEST MUX IS WORTH ZERO. QUARTUS ALREADY DOES IT

**Instrument:** `sim/microbench/mux_wide.sv` vs `mux_coded.sv`,
`make quartus MOD=mux_wide` / `MOD=mux_coded`.

`dbus_addr` is the V60's widest mux: **62 assignment sites, 32 bits**, inside one
95-state case, and only **23 distinct right-hand sides** feed it (`op2` 10 times,
`sp_m4` 7, `str_dst` 6, `task_addr` 6, `op1` 4, and a tail of ones). The obvious
transformation is to assign a small SOURCE CODE per state and mux the sources
once — 62x32 = 1,984 mux-input-bits becoming 8x32 + 62x3 = 442.

| arm | ALM |
|---|---|
| 64-way 32-bit mux, one source named per state | **634** |
| 64-way 3-bit code feeding an 8-way 32-bit mux  | **634** |

**Identical. The transformation is worth nothing** — Quartus's synthesis already
recognises that a wide mux has few distinct sources and builds the encoded form
itself. Hand-coding it changes only the source text.

This is the second time this shape of idea has measured as a wash; see
2026-09-10 (7), where sharing an adder was worth 7%. **The V60 is not losing
area to naive datapath structure.** An independent yosys census of `v60.sv`
alone confirms what it IS losing it to:

```
14873  $mux      613  $pmux     1106  $eq
  140  $add       56  $sub         3  $lt
```

Mux- and comparator-bound, by a factor of a hundred over arithmetic. Any V60
optimisation that targets adders or datapath sharing is aimed at 140 cells out
of 16,000.

---

## 2026-09-11 — MODEL 1 AND MODEL 2 HAVE THE SAME REGISTER COUNT. THE WHOLE 6,287 ALM GAP IS COMBINATIONAL LOGIC, SO MLAB IS NOT THE LEVER

Whole-project comparison, both from Quartus 17.0 fitter reports on the same part:
`build/mister/output_files/Model1.fit.rpt` (2026-09-11 22:34, the failed sound fit)
against `sega-model2-mister/build/fix3d/s14/output_files/Model2.fit.rpt`
(2026-09-11 22:19, successful).

|          | comb ALUTs | registers |    ALM | comb/ALM |
|----------|-----------:|----------:|-------:|---------:|
| Model 1  |     62,513 |    39,710 | 40,843 |     1.53 |
| Model 2  |     51,141 |    39,543 | 34,556 |     1.48 |
| delta    |    +11,372 |      +167 | +6,287 |          |

**The register counts are the same to within 0.4%.** On Cyclone V an ALM holds
four flops and two ALUTs, so 39,710 registers have a floor of 9,928 ALM against
an actual 40,843, while 62,513 combinational ALUTs have a floor of 31,256.
**Registers are nowhere near binding in either design; combinational logic is,
in both.** Model 1 is at 1.31x its combinational floor and Model 2 at 1.35x, so
the two are packed equally well — Model 1 simply has 11,372 more logic functions.

**This corrects the working premise that Model 1 has registers to move to MLAB.**
It does not, in bulk. The MLAB wins already taken were real and are consistent
with this: an array in flops costs a **read mux**, which is combinational, and
MLAB replaces that mux with the memory's own decoder. The flops themselves were
never the cost. That is why `m1_geo_clip`'s stack paid 1,598 ALM (32 deep x 96
bits, so a 32:1 mux 96 wide) and why a four-deep array pays nothing at all.
**The payoff scales with depth x read width, not with bit count.** An array
shallower than about 16 is not worth tagging.

Remaining untagged arrays in `rtl/`, censused the same day: only `v60.sv r[0:31]`
(multi-port, two writers), `v60_ifetch fb[24]`/`fb_prev[24]` (a parallel-read
instruction window), `m1_copro_if fin/fout[16]`, `m1_video mem[128]` and
`m1_quad_store hist/base[16]` are 16 deep or more. Everything else is 10 or
fewer. There is no bulk MLAB left to take.

### Where the 11,372 combinational ALUTs actually are

Own-logic figures (the parenthesised column, excluding children):

| Model 1              | own comb | own ALM |   | Model 2         | own comb | own ALM |
|----------------------|---------:|--------:|---|-----------------|---------:|--------:|
| `s32_v60`            |   16,015 |   8,336 |   | `i960_top`      |    4,496 |   2,867 |
| `v60_fp`             |    3,161 |   1,561 |   | (7 FP children) |    2,232 |   1,534 |
| `m1_fp_pool`         |    2,138 |   1,178 |   | `m2_fp_pool`    |    1,943 |   1,226 |
| `v60_ifetch`         |    1,515 |     818 |   | `i960_icache`   |      ~   |     386 |

**`s32_v60`'s own logic is 8,336 ALM in a single `always @(posedge clk)` block
spanning lines 778-3188 of `rtl/cpu/v60/v60.sv` — 2,410 lines, 96 case items,
228 `st <=` assignments and 396 `+`/`-` operators.** The i960's largest clocked
block is 157 lines; it is decomposed into seventeen child modules sharing one
ALU (469 ALM), one AGU (137) and one LSU (118). `AUTO_RESOURCE_SHARING` is `ON`
in both projects and every other optimisation setting is identical between the
two `.qsf` files, so the difference is structural, not a setting.

### The geometry pipeline is the other half

| Model 1 `m1_geometry` = 7,221 | ALM | | Model 2 `m2_geometry` = 4,609 | ALM |
|---|---:|---|---|---:|
| `m1_fp_pool`  | 1,784 | | `m2_fp_pool`   | 1,226 |
| `m1_geo_clip` | 1,117 | | `m2_geo_clip`  | 1,078 |
| `m1_geo_project` | 662 | | `m2_geo_project` | 343 |
| `m1_geo_walk` | 1,505 | | `m2_geo_engine` | 1,709 |
| `m1_geo_xform` | 662 | | " | |
| `m1_geo_det`  |   491 | | " | |
| `m1_geo_norm` |   450 | | " | |
| `m1_geo_color`|   329 | | " | |
| `m1_geo_planes`|   98 | | " | |

Model 2 sequences walk, transform, determinant, normalise, colour and plane
setup through **one** engine at 1,709 ALM. Model 1 gives each a dedicated unit,
totalling 3,535. **~1,800 ALM is available there**, and it is the largest
single lever measured that does not touch the V60.

Caveat on the Model 1 column: it is read from a fit that **failed** to place
(41,910/41,910), so the per-entity ALM figures are from a partial placement.
The combinational-ALUT and register counts come from synthesis and are sound;
treat the ALM split as indicative to a few percent.
## 2026-09-10 (10) — THE QUAD STORE: SDRAM IS AFFORDABLE, BUT THE OVERFLOW DID NOT REPRODUCE

Two measurements, and they point in different directions.

**1. THE STORE IS NOT CURRENTLY DROPPING.** 90 seconds of Ben driving Virtua
Racing on build `5011fb44`, captured over UART:

    D dropped quads      0    0    (min/max over 90 samples)
    U quads stored     139  3193
    O sdram occupancy   50   102   (40% of full scale)
    Q tile port wait    25    67   (26%)
    T bands late         0    0
    M fetch miss      2438  7417

`D` was **zero throughout**. The 2026-09-09 finding measured D=2,452-3,311 per
pass against a **3,072**-quad cap; the cap was later raised to 3,584 and on this
drive that was enough - `U` peaked at 3,193, 89% full and marginal, but never
over. **So the premise of the SDRAM work does not currently hold.** `M` at 7,417
is the other overrun in the same capture and is not the store.

**2. IF IT IS DONE ANYWAY, LATENCY IS NOT THE OBSTACLE.** Ben's concern was
SDRAM latency and its effect on cycles per quad. Measured in `tb_m1_frame` with
a new emissions probe - emissions being how many times a quad passes its band
filter and has its vertices read, which is the figure SDRAM would have to serve:

    busiest pass    11,320 emissions from 1,589 quads   = 7.12 bands per quad
    pass length     1.22 frames = 21.2 ms
    so             one emission every 1.87 us = ~150 SDRAM cycles available
    needed         10 cycles (20 bytes on a 16-bit bus)
    margin         ~15x

Scaled to the board's 3,193-quad peak: ~22,700 emissions, **13 MB/s**, about
**+8% occupancy** against the 40% measured. Comfortable.

**7.12 bands per quad is the surprise** and it is a property of the content:
VR's road and scenery quads are tall, so with 8-row bands they span many. An
earlier guess of 2-3 would have under-sized the traffic by 3x.

**WHAT MUST STAY IN M10K.** `att` carries the band range and is read for EVERY
quad on EVERY one of the 48 bands - 172,032 reads a pass at NQ=3,584. It is the
filter, and it can never be behind SDRAM. Only the ~145-bit vertex payload
moves. That splits the store's 196 M10K (35% of the device) into ~140 that can
leave and ~56 that cannot.

**AND MOVING IT COSTS ALM, IT DOES NOT FREE IT.** Block RAM and ALMs are
separate resources. The store's arrays are M10K; its ~1,188 ALM (543.9 + 644.3
for the two banks) is control logic, and an SDRAM version keeps all of that and
adds address generation, a prefetch FIFO and another port to arbitrate. This
was asked directly and is worth stating plainly: **SDRAM migration is the M10K
lever, not the ALM lever.**

**The other constraint SDRAM does not fix**: a 1,589-quad pass already runs 1.22
frames, so 3,193 quads would be ~2.45 - past the game's two-frame list flip.
That is overrun 3 from the 2026-09-09 entry and it is untouched by where the
quads are stored.

Caveat on the emissions figure: the VR input script reaches real geometry for
only four passes (282 passes at q=0, 97 at q=6, four at ~1,580), so the 3,193
figure is an EXTRAPOLATION at the same 7.12 bands per quad, not a measurement.

---

## 2026-09-10 (9) — THE LANE-ENABLE REGISTER FILE IS ON HARDWARE: -547 ALM, AND THE TRACE CAUGHT THE BUG THE FUZZERS DID NOT

Build `5011fb4493ae56f603f09cbd8fe03ccf`, 0 errors.

| | before | after |
|---|---|---|
| ALM | 41,473 (99%) | **40,926 (98%)** |
| spare | 437 | **984** |
| `clk_cpu` setup | +0.410 | +0.655 |
| `pll_hdmi` | +0.108 | +0.166 |
| M10K / DSP | 553 / 61 | unchanged |

**-547 ALM in the design**, against 981 on the standalone microbench - the
standalone figure was inflated by virtual pins, so quote this one.

**THE FIRST ATTEMPT WAS WRONG, AND ONLY THE TRACE FOUND IT.** The premise was
that every write mask is a byte/halfword/word lane. Three sites are not:
`SET1` (0x97), `CLR1` (0xa7) and `NOT1` (0xb7) pass a SINGLE-BIT mask of the
form `32'h1 << bi`. The census that "proved" the premise used a regex that only
matched hex literals, so it never saw them, and the first build had `SET1`
writing all 32 bits instead of one.

What did NOT catch that:

- `make lint`, clean
- the V60 unit suite, **29/29**
- `v60_alu`, **360,001 checks, 0 fails**
- `v60_shift`, **69,121 checks, 0 fails**
- `make test`, fully green

What DID catch it, immediately: **`make v60_trace GAME=vr`**. Our collapsed
stream went from 27,377 instructions to 50,609 with 14,326 spinning loops, and
parted from MAME at instruction 24,909.

**This is the clearest demonstration yet of the gap in the V60's verification.**
Per-opcode fuzzing proves each instruction correct FOR THE STATE IT WAS HANDED;
it never generated a `SET1` whose clobbered upper bits were read back later, so
a change that corrupted 31 of 32 bits passed 429,000 checks. Only running real
code found it. A full-CPU lockstep against MAME's device - the
`sim/tgp/mb86233_ref.cpp` pattern - is what would close it.

The fix costs nothing: those three merge in the datapath using `rf_rdata_b`,
which is the same register they already read for the flag test on the line
above, so no read port is added.

**Also fixed alongside**: `irq_mask` now resets to `0xff`, matching MAME's
`machine_reset`. Ours was `'0` - nothing masked - which was harmless while only
the timer and vblank existed, since both need their own trigger and every game
programs the mask first. Level 3 raises off a USART event and made the reset
value observable, exactly as model1.cpp's comment says it otherwise is not.

Board: VR loaded, telemetry healthy (`D`=0, `T`=0, 58 Hz), Ben confirms "that's
working fine". VF healthy on telemetry likewise.

---

## 2026-09-10 (8) — THE V60's PER-BIT REGISTER WRITE MASK COSTS ~1,030 ALM

**Instrument:** `sim/microbench/rf_flops.sv` and two variants, each
`make quartus MOD=<m>`. The model is v60.sv's actual register file: 32x32, two
async read ports built as 32-way muxes, two write ports with PER-BIT masks.

| variant | ALM |
|---|---|
| as built - 2 write ports, per-bit masks | **2,289** |
| 2 write ports, WORD writes | 1,256 |
| 1 write port, per-bit masks | 1,250 |

**The per-bit mask costs about 1,030 ALM** - more than stubbing every unused
instruction group (764), and unlike stubbing it removes no functionality. Each
of the 1,024 flops carries its own enable term (`we && wmask[b] && address
match`) plus a two-port data mux, so there is roughly one ALUT of control per
bit of storage.

**The fix is to merge before the write**: `wdata = (old & ~mask) | (new & mask)`
into a whole-word write. One 32-bit merge replaces 1,024 per-bit enables, and
the old value is already to hand - `r[rf_waddr0]` and `r[rf_waddr1]` are two of
only FOUR dynamic read sites in the whole file.

**The correctness crux is a same-register collision.** With per-bit masks, two
ports writing the same register merge bit by bit; with word writes port 1 would
clobber port 0 entirely, and v60.sv's own comment says the ordering is
load-bearing ("Port 1 is applied second so the final queued write retains the
original nonblocking-assignment priority when both ports address the same
bit"). The merge must therefore combine BOTH masks when the addresses match.

**Context: this is now the largest measured lever in the V60**, against the
whole optimisation list measured the same day - shared address datapath
150-250, FP add/mul dedup 54, FP onto DSP already done. It is also the only one
of them that changes no architectural behaviour at all.

---

## 2026-09-10 (7) — SHARING AN ADDER SAVES 7%, NOT A LOT: THE OPTIMISATION RANKING WAS WRONG

**Instrument:** `sim/microbench/addr_separate.sv` vs `addr_shared.sv`,
identical function, `make quartus MOD=addr_separate` / `MOD=addr_shared`.

| arm | ALM |
|---|---|
| 8 separate 32-bit adders + an 8-way result mux | 471 |
| 1 adder with 8-way operand muxes | 438 |

**33 ALM, about 7%.** Sharing pays, but barely - because on Cyclone V an adder
is a carry chain at roughly half an ALM per bit, while every mux input costs
LUTs. Moving the muxing from after the adders to before them is close to a
wash.

**This corrects a ranking made earlier the same day.** The yosys census found
140 `$add` cells and 14,798 `$mux`, and "a shared address datapath" was called
the highest-return, highest-risk optimisation on the strength of the adder
count. The adder count was never converted into area. The V60 has about 52
WIDE (32-bit) arithmetic sites - `dbus_addr` 10, `str_src` 9, `pc` 9, `ea_addr`
8, `str_faddr` 5, `str_dst` 4, and a long tail - so at this rate the whole
refactor is worth **150-250 ALM**, against **764 measured** for stubbing the
unused instruction groups.

It is therefore the SMALLEST of the three candidates and still the riskiest: it
touches the core's address path in dozens of places and needs the 29/29 unit
suite plus `v60_trace` on three games before it can go near hardware.

Also worth keeping from the same measurement: **most of the 53 `dbus_addr`
assignment sites carry no arithmetic at all.** They are plain register reads -
`sp_m4`, `task_addr`, `str_dst`, `op2`, `str_src` - so `dbus_addr` is a wide
MUX, and only about ten of its sites contain a `+`. The earlier description of
"53 sites each with its own adder" was wrong.

---

## 2026-09-10 (6) — THE USART/IRQ-3 FIX IS ON HARDWARE: NO REGRESSION, AND IT DOES NOT FIX VF'S ARENA

Build `ef8cfa103ecb26648273fa57f40859d4`, 41,473/41,910 ALM (99%), 553/553 M10K,
61/112 DSP, 0 errors. **Every clock positive, including `pll_hdmi` at +0.108** -
that one had been negative on the last several builds (-0.034, -0.096, -0.338).
The USART cost +152 ALM over the 41,321 baseline.

Tested on the board from a cold boot, one `load_core` per reboot:

- **Virtua Racing: unchanged.** Ben: "it looks and plays the same". Telemetry
  matches its documented healthy baseline - `U` 887-983 quads inside the
  documented 976-1,301 attract band, `D`=0 dropped, `T`=0 late bands, 58 Hz.
  This was the regression check that mattered, because VR's level 3 is now live
  too and VR is the title that already worked.
- **Virtua Fighter: unchanged.** Ben: "vf is the same. small fighting arena, no
  regression." Telemetry healthy - `D`=0, `T`=0, 58 Hz, `U` 842-1,889.

**So the arena is NOT the missing interrupt.** That was the prediction stated
before the test and it held. The correlation argument was sound - one thing was
measurably wrong and it demonstrably changed execution from frame 124 - but the
change it makes is not the arena.

**What the fix is still worth keeping for**: the V60 no longer diverges from
MAME on Virtua Fighter, so "but our CPU diverges" can no longer sit in front of
the arena investigation. The register the game polls 12.9 times a frame now
returns real status instead of the bus's undecoded 0xffff, which had been
claiming RxRDY plus parity, overrun and framing errors on every poll.

**Next for the arena is the coprocessor**, which was Ben's original hypothesis:
`tgp_wrtrace GAME=vf`, repointed from `make m1_boot` to `m1_frame` with
`sim/input/vf_match.txt`.

---

## 2026-09-10 (5) — WHERE THE V60'S AREA ACTUALLY IS: MUXES AND DUPLICATED ADDRESS ARITHMETIC

**Instrument:** the Fitter's per-entity table in `s32_v60.fit.rpt`, plus a yosys
coarse-cell census (`proc; opt -fast; stat`). Recorded so the next person does
not optimise the wrong block.

| entity | ALM | share |
|---|---|---|
| `s32_v60` top level ITSELF | 13,377 | 75.5% |
| `v60_fp` | 2,266 | 12.8% |
| `v60_ifetch` | 1,299 | 7.3% |
| `v60_shift` | 672 | 3.8% |
| `v60_alu` | **74** | 0.4% |

**`v60_alu` at 74 ALM is the finding.** That is far too small to be a 32-bit
CPU's ALU, and it means arithmetic is NOT routed through it - it is inlined,
per-case, across the top level's exec statement.

The yosys census says the same thing from the other side. For the whole design:

    $mux 14,798   $pmux 588   $eq 1,106   $ne 433
    $add   140   $sub   56   $mul    7   $div   1

**Muxing dominates, not arithmetic** - and the 140 adders are the symptom of
the same cause. At source level, single registers are assigned from very many
places:

    st 196 sites   dbus_req 116   dbus_addr 53   exc_vector 25
    total_len 23   ea_len 21      pc 17          ea_addr 17    dbus_wdata 16

`dbus_addr` is 32 bits wide and computed by 53 different expressions, so it
carries a 53-way 32-bit mux AND most of those expressions contain their own
adder. That is the classic monolithic-microsequencer shape.

**So the highest-value structural change is a shared address datapath** - route
address arithmetic through one adder with a small operand mux, rather than 53
independent expressions - and NOT optimising the ALU, shifter or FP unit, which
are between them under a quarter of the core. This is what the "split the V60
for AREA, not speed" note has been pointing at.

**Two caveats on the absolute numbers.** The 17,707 total was built by
`make quartus MOD=s32_v60`, whose `quartus/spike.qsf.in` defaults to
OPTIMIZATION_TECHNIQUE **Speed**. The real hardware build already runs
`Aggressive Area` + `AREA` + `MUX_RESTRUCTURE ON` (`tools/mister_project.sh`),
so the in-design cost is lower and that lever is ALREADY PULLED - do not
"discover" it again. The DELTAS measured on the spike remain valid; the
absolutes do not transfer.

**And STA cannot break the 13,377 down further** - it is a timing tool. The
per-entity table stops at module boundaries, so seeing inside the top level
needs either the yosys census above or wrapping logical blocks (EA engine, exec
case, register file) in real modules, which would make the Fitter report them
separately as a side effect of being the refactor worth doing anyway.

---

## 2026-09-10 (4) — STUBBING THE UNUSED V60 INSTRUCTIONS IS WORTH 764 ALM

**Instrument:** `tools/v60_opcensus.sh` for the candidate list, then
`make quartus MOD=s32_v60` with and without a define. Experiment preserved on
branch `v60-stub-experiment` (`41785e3`); the working tree was restored and
`v60.sv` verified byte-identical to `build/v60_backup/v60.sv`.

| | ALM | registers | setup slack |
|---|---|---|---|
| full V60 | 17,707 | 4,415 | -3.067 ns |
| unused groups stubbed | 16,943 | 4,191 | -2.474 ns |
| **delta** | **-764 (-4.3%)** | **-224** | **+0.593 ns** |

Both slacks are negative because `quartus/spike.sdc` asks the standalone module
for a clock it cannot meet. That is the measurement vehicle, not a failure; the
DELTA is the result, and stubbing helps timing as well as area.

**Eight groups**, each measured never executed by vr, vf or netmerc: ROTC,
DISPOSE, TASI, PREPARE, the decimal group (ADDDC/SUBDC/SUBRDC), bit-field
INSERT, bit-string MOVE, and task switch (LDTASK/STTASK). **The halves that ARE
used stayed**: `extbfl`/`extbfz` (bit-field extract) and `sch1bsu` (bit-string
search) are in the census, so only their siblings went.

**764 ALM is worth having.** The last full build was 41,321/41,910 with 589
spare, so this roughly doubles the headroom - at a moment when M10K is at
553/553 and ALM is the binding constraint.

**WHAT THIS MEASUREMENT DOES NOT ESTABLISH, and the precedent says take it
seriously.** The census window is 10 emulated seconds of each game with no
input automation, so it is BOOT AND ATTRACT for all three. That is the same
window that said the V60's FP group was unused - worth 2,984 ALM and 21 MHz -
and `dbg_fp_trap` fired on a real `cvt.sw` at 421.7 M cycles. netmerc alone
moving the list (it is the only one of the three reaching `divf.s`, `mulf.s`,
`negf.s`) shows how sensitive the set is to which code you happen to run.

The experiment branch has **no trap**: an unused opcode falls through to the
state machine's default and resets the CPU, silently. It is NOT for merge.
Anything shipped must follow the `dbg_fp_trap` pattern - a sticky bit set the
first time a stubbed opcode takes the reserved vector, surfaced where a test
run can read it - which is exactly what Ben proposed when he asked for this.

Also on the V60, and correcting a claim made in this session: **the core was
PORTED from the s32 project** (`0d1f85b M1: import the V60`), not translated
from MAME here. Its header's "behavioural contract is MAME's v60 core" is the
UPSTREAM AUTHOR'S claim about their own work, and citing it as evidence that
the core is a faithful MAME translation was wrong. Our own evidence is
`v60_alu` (360,001 checks), `v60_shift` (69,121) and `v60_trace`; none of them
checks register values instruction by instruction on real code, which is the
gap a full-CPU lockstep against MAME's device would close - the pattern
`sim/tgp/mb86233_ref.cpp` already uses for the coprocessor.

---

## 2026-09-10 (3) — THE VF "CPU DIVERGENCE" IS NOT THE CPU. IT IS A MISSING INTERRUPT SOURCE

**Instrument:** `make v60_trace GAME=vf INPUTSCRIPT=sim/input/vf_match.txt`,
plus a probe in `tb_m1_frame` reporting `irq_n` and `psw_ie` at the one
instruction the two streams parted on.

`make v60_trace GAME=vf` reported **DIVERGES at instruction 21,817**, at
`FE4648: updpsw.w #FFFFFFFF, #40000` — mask `0x40000` is bit 18, `psw_ie`, so
this is the game enabling interrupts for the first time. MAME went one way, we
went another, and it was read as a V60 bug. **It is not.**

The collapsed streams part like this:

    MAME:  fe4648 -> fe3f5c -> ff3ebc..ff3f24 -> fe3f62 -> fe3f6b -> fe4654 -> ...
    OURS:  fe4648 ->                                                 fe4654 -> ...

and rejoin at `fe4654` with nothing else different. So it was never seven wrong
instructions: it is the reference running an extra block and returning.

**The RAW traces settle it.** Aligned from `fe4648`, ours and MAME's agree for
198 instructions — both enter the interrupt handler at `fe3ed4` on the SAME
boundary, both run it identically — and part at instruction 199, on `FE3F59:
retis #0`. MAME's next instruction is `FE3F5C: jsr FF3EBC[PC]`. That is not a
fall-through past the `retis`. It is a SECOND interrupt taken immediately, and
model1.cpp names it in a comment:

    // vf
    // 1 = fe3ed4 (vblank)
    // 3 = fe3f5c (uart queue pump)

**Level 3 is the sound USART, and we never had one.** `m1_decode` asserted
`sel_uart` for `0xc4xxxx` and NOTHING WAS CONNECTED TO IT — the bus returned its
undecoded `0xffff` and `m1_glue` raised only levels 0 and 1. `m1_glue`'s own
header said so in as many words: "IRQ 3  UART ready — the sound path, not
implemented yet". model1.cpp wires the uPD71051C's txrdy and rxrdy handlers to
`sound_ready_w()`, which raises level 3 whenever the line is ready and level 3
is unmasked; vf unmasks it while its sound queue is non-empty and masks it again
once drained. With no USART the queue never drained and the interrupt never
existed.

**So the V60 is exonerated for this divergence.** It took the same interrupt at
the same instruction boundary and ran the same handler. It was never offered the
second one. `psw_ie` and the `!irq_n && psw_ie` boundary check are correct.

**VERIFIED AFTER THE FIX.** Re-run with the USART present, `make v60_trace
GAME=vf` reaches **instruction 25,283 of our 25,284** — the end of our own
capture window. The two collapsed streams are identical for 25,282 of them; the
last two are us still spinning in the `fe03a2/fe03a4/fe03ac` poll loop when the
trace ran out, where MAME had already left it. That is the same shape of result
`make v60_trace` gives on Virtua Racing ("26,336 of our 26,338"), and it means
**there is no V60 control-flow divergence on Virtua Fighter in the window that
can be compared.** The ISR-strip counts say the same thing independently: ours
went from 100 handler entries to **101**, and the extra one is level 3.

**What this does NOT establish.** It does not explain VF's small arena — that is
still open — and agreement ends where our capture does, so it says nothing about
the V60 beyond ~25,000 collapsed instructions. Level 3 fires only ONCE in MAME's
two-second window, so nothing here should be read as a likely cause of the
arena. Making the traces comparable is the point of the fix, not the end of the
question.

**A near-miss worth recording.** A note already in `v60.sv` at `S_DECODE`
describes a PREVIOUS false report at this very instruction — `dbg_pc` was
published above the interrupt check, so a preempted instruction advertised a PC
it never executed. That was found, fixed, and documented. Arriving at `fe4648`
a second time by a different route, the temptation was to assume the same cause.
It was not. **The same address can name two unrelated faults**; read the raw
trace rather than the previous conclusion.

**Fixed by** `rtl/io/m1_sound_usart.sv` — the i8251 transmit path modelled off
`third_party/mame/src/devices/machine/i8251.cpp`, with the byte discarded until
M4 gives it somewhere to go — and the level 3 raise in `m1_glue`. The subtlety
that matters is that TxRDY is **double buffered**: `data_w` clears it and
`check_for_tx_start()` sets it straight back when the shifter is idle, so a
write to an idle transmitter leaves the line HIGH and re-raises level 3. That is
the drain loop. A plain busy flag would drain one byte per unmask instead of one
per character, which looks like it works and is not what the reference does.
Character time is held as a RATIO of the CPU (5,120 V60 clocks: 10 bits at
31.25 kbit/s against 16 MHz), so the overclock carries the sound handshake with
it — the same reasoning as `m1_ioz80`'s `CEN_NUM/CEN_DEN`.

---

## 2026-09-10 (2) — VF'S ARENA IS NOT A TIMING FAULT: IT IS THE SAME AT 16 MHz

Ben's argument, and the measurement agrees with him rather than with me.

The V60 runs at 29.474 MHz against the board's 16, so the game gets ~512,000
CPU cycles a frame where the hardware gave it ~278,000 - the one ratio the clock
raise does NOT preserve, because video is fixed at 57.5 Hz on both. That was the
hypothesis. Ben's objections were that every INTERNAL ratio is preserved
(CPU:TGP 1:2, CPU:Z80 4:1) and that the arena was small before the clock raise,
so a 3% change cannot explain it.

`ce_cpu` was wired to a Bresenham divider in `tb_m1_frame` - the port exists for
exactly this and was tied to 1 - and Virtua Fighter re-run at 16/29 of clk_cpu,
about 16.26 MHz. **The arena renders identically small.** Timing is eliminated.

`ce_cpu` in the CORE is untouched and stays at 1; the throttle is a bench
parameter (`FRAME_CE_NUM`/`FRAME_CE_DEN`) and nothing shipped changed. 57.5 Hz
is not negotiable and was never a candidate to move.

**What that leaves.** The wrong matrix is already in the display list; our
reading of it is byte-exact; the model data is byte-identical to MAME's; MAME
runs the same microcode with no HLE and no patches. So the V60 or the
coprocessor produces it, and not because of how fast either runs.

**A divergence that is still unresolved, and honestly reported.** With the ISR
strip finally working (entries=105/exits=105 reference, 100/100 ours) the V60
trace on VF diverges at instruction 21,817, at
`FE4648: updpsw.w #FFFFFFFF, #40000` - bit 18 is `psw_ie`. MAME takes a pending
interrupt immediately; we run on for seven instructions. It sits directly after
an I/O board poll loop that runs 439 iterations in MAME and 314 in ours, so a
different moment in the frame is still a live explanation and this is NOT yet a
CPU bug. The V60 already carries a comment about this exact instruction from a
previous FALSE bug report - that one was a stale published PC, and this is not
that, because seven instructions execute.

**THREE TOOLS SILENTLY DID NOTHING ON A NON-VR GAME**, each producing a
confident result from a test that had not run:

- `v60_trace.sh` passed `GAME` to MAME and not to our bench, so every run built
  Virtua Racing whatever was asked for. Our V60 had never been diffed on any
  other title.
- `v60_strip_isr.py` had Virtua Racing's handler ENTRY hardcoded (`fe02bc`,
  which occurs 0 times in VF). It stripped nothing and reported
  `entries=0 exits=0`, and I read the resulting divergence as real.
- the same file had VR's EXIT hardcoded. With VF's entry but VR's exit it
  entered the handler once, never left, dropped 3,694,020 of 3,981,461
  instructions and reported the surviving 21,816-instruction prefix as
  IDENTICAL.

All three are fixed. The lesson is the `entries == exits` line: the tool printed
`MISMATCH - handler extent is wrong` next to a result I quoted anyway.

---

## 2026-09-10 — VF'S ARENA: THE RENDERING PATH IS EXONERATED, THE MATRIX ARRIVES WRONG

The bug now reproduces in simulation (`sim/input/vf_match.txt`), so it can be
measured instead of eliminated. Taking the arena object `00b0f5f`, which BOTH
MAME and our core draw:

| | MAME | ours |
|---|---|---|
| model bytes at `poly_adr 0xb0d67` | | **byte-identical**, all 16 words |
| display list commands | | identical - no 0x02, no 0x05, no bit 23 |
| `zoomx` / `xc` when the object is drawn | `4415a000` / `43780000` | **the same** |
| on-screen width | fills much of 496 | **6 pixels** |

**The matrix `mat[]` holds is exactly the matrix the display list asked for.**
Printed side by side for the same object in the same frame, `mat:` and `cmd:`
agree element for element, and 78,240 matrix element writes across 6,520 `0x0b`
commands is 12.0 per command - nothing partial, nothing dropped.

So the whole rendering path is correct and the bad matrix was **already in the
display list**. The V60 wrote it there from values the COPROCESSOR computed.
Ben's suggestion, and it is now the only explanation left standing.

**The matrix is wrong on its own terms too.** Treating rows as MAME's
`transform_point` does - `(m[0],m[3],m[6])`, `(m[1],m[4],m[7])`, `(m[2],m[5],m[8])`:

    x row  0,      0.3125, 1.0      length 1.047
    y row -0.0978, 0.0428, 0        length 0.107     <- ten times short
    z row -0.9952, 0.4353, 0        length 1.086

Two rows unit-length and one squashed tenfold is not something a camera
transform should produce.

**MAME is NOT working around the bad dump**, which was worth checking before
blaming our execution: it instantiates a real `MB86233` at 40 MHz with program,
data and IO maps, and there is no HLE, no patched opcode and no driver
workaround - only the `BAD_DUMP` marker on the ROM load. Both run the same bytes;
only MAME renders correctly.

**A caveat on the likely shape of the fault.** Our coprocessor is fuzzed per
opcode against MAME and passes, so a divergence is more likely to be STATE than
arithmetic - the microcode's matrix stack (`cmd_05_matrix_push`,
`cmd_06_matrix_pop`) persists across objects, and corrupting it gives exactly
"objects drawn right after their own matrix write are fine, ones drawn deep in
the list are wrong". That is the fighters-correct/arena-wrong split. It is also
the same class as the `ST` register bug already in this file, which per-opcode
fuzzing likewise passed.

**Two comparisons of mine were invalid and are withdrawn.** Matrices from
MAME's frame ~2400 were compared against ours from frame 681 as though they were
the same instant; the camera moves, so they SHOULD differ, and no conclusion
about magnitude survives that. And a cluster of small objects during READY/DRAW
was read as "the whole scene is tiny" when Ben had already watched the video and
seen only the arena wrong.

**Next**: `tgp_wrtrace` is the right instrument - it diffs the coprocessor's
data-memory WRITES, catching a wrong value where it is produced, which a PC-level
trace cannot because a wrong number does not change control flow. It drives
`make m1_boot` though, which has none of the input scripting, so neither side
reaches a match and the arena is never drawn. It needs pointing at `m1_frame`
with the input script before it can answer this.

---

## 2026-09-09 (8) — WITHDRAWN: THE BENCH RENDERS FINE. IT IS SITTING IN TEST MODE

The entry below is **wrong** and is kept because the way it was wrong is the
point. It concluded the simulated video path was broken, from three palette
indices and a two-colour frame, and called frame-diffing against MAME a
verification method that "has never once worked".

**Converting the frame to a PNG and LOOKING AT IT settles it in one step**: the
image is Virtua Racing's TEST MODE menu, fully legible - START CREDIT, COIN
SETTING, CAR COLOR, COURSE SELECT, EXIT. The renderer is perfect.

Every "symptom" was just what was on screen. White text on black is two colours.
A font uses low tile indices, and in this chip the colour field OVERLAPS the
index (`colour = tile_word[14:7]`), so a low index legitimately gives colour 0
and a palette address in the bottom sixteen. Nothing was misreading anything.

**Why it is in test mode**: the game's backup RAM starts blank in every fresh
simulation, so it comes up in the settings menu waiting for an operator. The
board was configured once and has persisted since, which is why hardware reaches
attract and the bench does not. The I/O board is fine and the run proves it - the
EEPROM streams (word 0 = 5345), the identity block reads SEGA, and the firmware
makes 64 READS and 0 WRITES, so it found valid settings and left them alone.

**The reasoning error, worth naming.** Two games producing the same colour COUNTS
was treated as proof they rendered the same picture. Two different text screens
have similar counts. A 350M-cycle run "confirming" a 90M one confirmed only that
the menu does not time out. Three measurements, all consistent, all pointing at a
conclusion that one glance at the image destroys - and the image cost one command.

**LOOK AT THE PICTURE BEFORE THEORISING ABOUT THE PICTURE.** The bench has
written `build/frame.ppm` all along.

**What is actually needed for simulated gameplay** is to drive the menu to EXIT,
which needs input injection the bench does not have: it drives IN.0 only, so it
can insert a coin and press start but cannot work a menu, and for Virtua Fighter
cannot select a character either since those buttons are on IN.1.

---

## 2026-09-09 (7) — [WITHDRAWN, see above] THE BENCH'S RENDERED FRAME IS THREE PALETTE ENTRIES

`tb_m1_frame` writes the last frame to `build/frame.ppm`, and the image is two
colours. That is not a capture bug and not a short run:

| | 90 M cycles | 350 M cycles |
|---|---|---|
| distinct palette WORDS read | 6 | 6 |
| distinct tile words read | 32 | 32 |
| distinct palette INDICES requested | **3** | **3** |
| tilemap 2 pixels that frame | 180,677 | 180,677 |

Identical at nearly four times the length, so the game is not simply "not there
yet". The palette RAM itself is fine - `build/frame_pal.hex` holds **579
distinct entries, 2,706 non-zero** - and the tilemap is being read with real
entries (`8031`, `8032`, `8036`, ...). The problem is between them:

    m1_tile_decode:  pal_index = {colour, pixel},  colour = tile_word[14:7]

and every tile word observed has bits 14:7 ZERO, so every palette address lands
in the bottom sixteen. Two Virtua Racing runs and one Virtua Fighter run all
produced a byte-identical frame - 186,142 black and 4,322 white - which is
conclusive on its own: two different games cannot render the same picture.

**The same RTL renders full colour on hardware**, so this is a simulation-side
divergence rather than a core defect. It matters because "frame image diffs
against MAME on a fixed input script" is one of the project's three stated
verification methods and, on this evidence, has never once worked. There is
already a probe in the bench written for this exact symptom - "Two colours out
of a palette holding real xBGR-555 entries says the data reaching the video path
is not the data the CPU wrote" - so it was hit before and left.

Not chased further yet. The next question is whether the tile words the renderer
sees are the ones the V60 wrote, which the probe was built to answer and which
nothing has yet compared against the CPU's write stream.

---

## 2026-09-09 (6) — VIRTUA FIGHTER'S ARENA: WHAT IT IS NOT, MEASURED AGAINST A RUNNING MAME

Ben confirmed MAME renders the arena at the correct size with the same ROMs, so
this is our defect and not the BAD_DUMP microcode. A Lua display-list decoder
(`build/mame_vf/`, not committed - it reads the lists at V60 0x600000/0x610000
and walks them with model1_v.cpp's own stride table) was run against attract,
character select and a real match.

**Eliminated, all measured rather than argued:**

| candidate | measurement |
|---|---|
| the BAD_DUMP microcode | MAME renders correctly with the same `315-5724.bin` |
| direct polygons, command 0x02 | **0** issued, in attract, character select AND a match |
| polygon RAM, command 0x05 | **0** issued; and no object has poly_adr bit 23 set |
| viewport | `xc=248 x1=0 x2=495` in play, matching ours exactly |
| zoom | raw `0x4315a000` x4 = `0x4415A000`; our board reports the top half as `4415`. IDENTICAL - the "596 vs 598.5" was my truncation of a 16-bit field, not a discrepancy |
| object size semantics | `size==0` means unlimited in both |
| geometry for the arena models | 96 object walks over 16 yaws: 960 quads, **0** vertex coordinates differing, colour exact on all |
| MAME's `init_translation_matrix` | a REAL divergence - see below - but VF submits **0 objects before its first matrix command**, every frame |
| `vxx/vyy/vzz` and the `ayy` yaw in `transform_point` | inside `#if 0`. A keyboard debug hook, never non-zero, so the transform reduces to ours |

**One real divergence found, which is NOT this bug.** MAME calls
`init_translation_matrix()` - identity - immediately before walking each list.
`m1_geo_xform` has `always_ff @(posedge clk) if (mat_we) mat[mat_idx] <= mat_data;`
and **no per-pass reset at all**, so the matrix carries across objects, passes
and frames. An object drawn before the first 0x0b would get identity there and a
stale matrix here. Measured: VF never does that, so it cannot explain the arena -
but it is still wrong and a game that does draw before its first matrix would
break in a way that looks like nothing else.

**The limit of the geometry result.** `tb_m1_geometry`'s reference is our own
reimplementation of `push_object`, written from MAME's source. 0 mismatches
shows the RTL matches the C++ model, NOT independently that either matches MAME.
A misreading shared by both passes. The only test that would settle it is
comparing against MAME's actual emitted quads.

**Still unchecked:** `old_z`, which `push_object` takes BY REFERENCE and carries
between objects - the flat-z reuse register for poly zmode 0. It affects sort
order rather than size, so it is a weak candidate, but it is cross-object state
we may not model. And whether we walk the same NUMBER of objects: MAME shows
92-104 in play while the board's `P` field ranged 52-92.

---

## 2026-09-09 (5) — THE BAND SWAP LANDED ON A VISIBLE PIXEL, AND IT WAS TWO SYMPTOMS

Confirmed on the board: the missing pixels at the top of every band are gone,
AND so are the intermittent gaps in a band that were reported this morning as a
separate fault. One cause, two symptoms.

`disp_buf_s2` is what the scanout reads through. If it changes while the beam is
inside a visible line, every pixel after that point on that line comes from a
buffer that does not hold it. Measured in `tb_m1_frame`, swaps landing on a
genuinely visible pixel over one attract run:

| lead | swaps on a visible pixel |
|---|---|
| none, as shipped | **3,029 of 3,093** |
| a whole line | **3,029 of 3,093** |
| the last line's HORIZONTAL BLANK | **0 of 3,093** |

Both broken variants are 100% of swaps and differ only in WHERE the damage
lands, which is why the board showed two different pictures: with no lead the
swap arrives about eight pixels into the band's first line and takes the top few
pixels; leading a whole line moves it eight pixels into the PREVIOUS line and
takes most of that instead. The second was flashed and is much worse.

**The window that works is the blank at the end of the last line** - `scan_x`
runs to 655 against 496 visible, about 160 cycles against a round trip of
roughly eight.

**THIS WAS NEVER HARDWARE-ONLY, and it was treated as though it were.** It is a
LATENCY effect, not a metastability one: the bench drives both clocks and the
toggle handshake costs real cycles, so it was always visible here. Nothing had
looked. The beam-band multi-bit crossing was fixed first on the strength of a
plausible story, did not cure it, and is recorded at 2026-09-09 (3) as a real
defect that was not this one - correctly, but the counter should have come
first. That is the third time this month the answer was an instrument rather
than a theory.

**One detail nearly produced a false residual.** The first version of the check
tested `scan_x` alone and reported 64 failures. Adding `scan_y` showed all 64
are band 0 presenting during VERTICAL blanking, where nothing is drawn. Stopping
at the first number would have reported a 2% residual fault that does not exist.

**Also settled here:** two builds of near-identical logic went from "Can't fit
design in device" to fitting on a fitter SEED change alone, and `clk_3d` slack
has swung 0.043 to 0.543 ns between builds that differed only by ADDED logic. A
single failed fit at 99% is placement luck, not proof of capacity - reseed before
spending area.

**Measured reserves, from a real fit's entity table rather than estimated:**
framework `audio_out` is **862 ALM** for sound this core does not produce (DC
blockers, a 425-ALM IIR filter, mixers); the UART report is **467** and is now
behind `UART_REPORT`, defaulted on; the debug overlay is already off and fully
pruned, with 4,287 registers removed and nothing left to reclaim.

---

## 2026-09-09 (4) — VIRTUA FIGHTER: POLYGON RAM IS NOT IMPLEMENTED, AND NEITHER ARE DIRECT POLYS

Ben, on hardware: the fighters are correct and only the fighting arena is wrong;
it is right in ATTRACT and wrong once a match starts. Two display list commands
turn out to be parsed and then discarded, and both are Virtua Fighter's.

**1. Command 0x05, the POLYGON RAM upload, has no consumer.**

    case 5: m_poly_ram[adr - 0x800000 + i] = readi(...);      model1_v.cpp:1526

`m1_listwalk` defines `C_POLYRAM = 8'h05` and parses its length, but
`m1_raster3d` consumes only kinds 01, 03, 04, 06, 09, 0c and 41. **There is no
polygon RAM anywhere in the core** - the grep returns nothing outside the
walker.

**And the selector that reaches it is masked away.** MAME chooses the source
per object:

    if (poly_adr & 0x800000) poly_data = m_poly_ram;
    else                     poly_data = m_poly_rom;

`m1_geo_walk` does `padr <= in_poly_adr[22:0]`, discarding bit 23. So an object
that should read UPLOADED geometry reads the polygon ROM at the masked offset -
a different model entirely. That is not a scaling error, it is the wrong object,
which is what a wrong-size arena looks like. It fits attract-fine/play-wrong
directly if VF uploads the ring only once a match begins.

Not yet proven to be the arena specifically: no instrument counts command 5 yet,
and until one does this is a strong explanation rather than a measurement. The
counter is the next thing to build, not another theory - that is the lesson from
the left-side cut.

**2. Command 0x02, DIRECT polygons, is also dropped.** `push_direct` hands over
polygons ALREADY PROJECTED rather than transformed. `m1_listwalk` walks its
18-word header and sub-records purely to find the length and step over it, and
nothing downstream consumes `ev_kind` 2. Ben expects this is why the knives do
not appear in Virtua Fighter. Confirmed absent by the same census; a separate
defect from the arena, and it needs fixing too.

**What was ruled out first, all by comparison against model1_v.cpp rather than
by reasoning:**

| checked | result |
|---|---|
| copro microcode `315-5724.bin` | correct file on index 1; MAME flags it BAD_DUMP |
| program banking `0x100000-0x1fffff` | implemented, `rom_bank[2:0]` |
| zoom command 0x09 | matches `set_zoom(readf(+2)*4, readf(+4)*4)`, x/y order and the x4 |
| viewport command 0x03 | indices 1..6 are xc,yc,x1,y2,x2,y1 and the y words are `422 - word`; matches |
| matrix command 0x0b | 12 floats, stride 26; matches |
| object command 0x01/0x41 | 3 params, stride 8; matches |
| camera state on hardware | `xc` 248.0, `viewx` 0, `zoomx` 596.0 and the left plane -0.41 are SELF-CONSISTENT: 248 + (-0.41 x 596) = 4, the left edge |

The camera measurement is what removed the whole projection theory: `zoomx` does
not change between attract and play, and the fighters being correct says the
same thing independently.

**Cost of the fix.** MAME's poly RAM is `0x400000` 32-bit words - **16 MB**. M10K
is 100% full, so it belongs in SDRAM alongside the polygon ROM, which the
geometry already fetches from. How much of it Virtua Fighter actually touches is
unmeasured.

**The frame bench was Virtua Racing whatever you asked for.** `ROMHEX` was a
parameter but the microcode, I/O firmware and EEPROM paths were hardcoded to
`vr_*`, so `make m1_frame` could not run another game at all. Now
`make m1_frame GAME=vf` works and VF reaches 3D: 103 objects, 2,273 quads, 160
passes, viewport latched 150 times, `0..495`.

---

## 2026-09-09 (3) — THE BEAM-BAND CDC FIX DID NOT FIX THE BAND ARTEFACT

Flashed `a1d9192` (md5 `699ee64f82ac8731e70b5b52f094bcbd`) and driven. **The
misplaced band is still there** - a few pixels deep, in the wrong place, for
about two seconds at a time.

So the multi-bit crossing was a real defect and is NOT the cause of this
symptom. The fix stays in: crossing a six-bit incrementing index on two flops is
wrong however the picture looks, and the file's own comment says so about the
other direction. But the artefact has another cause and this entry exists so the
next session does not re-derive the same theory from the same comment.

**What is now ruled out for the band artefact**, all measured:

- every 3D deadline counter flat zero over a two-minute race - `T` bands
  presented late, `D` quads dropped, `G` vertices out of range, `H` short. There
  is no timing headroom to buy, so a clock raise cannot be the fix either.
- the beam-band clock crossing, above.
- the quad store: `D` = 0 and `U` peaks at 2,257 against a 3,584 cap.

**Still open as candidates:** the band buffer's own addressing or clear
sequencing; the three-buffer rotation (`fill_buf` / `ready_buf` / `disp_buf`)
picking the wrong buffer; the row-behind-the-beam clear erasing a row that is
still to be shown. None of these has an instrument yet, and none of the existing
counters distinguishes them - which is the gap to close before theorising again.

Nothing about it is countable today, which is the real problem: the left-side
cut was solved by a counter that made the fault visible in telemetry, and this
symptom has no equivalent. That is where to start.

---

## 2026-09-09 (2) — THE BEAM-BAND CROSSING HAD THE SAME MULTI-BIT FAULT, IN THE OTHER DIRECTION

Ben, on the board after the clip-plane fix: "a gap in a band where it's in the
wrong place, only a few pixels deep, lasts about 2 seconds". A band is eight
rows, so "a few pixels deep" is one band.

`m1_raster3d` carries a long comment - written when the 3D-to-video crossing was
fixed - explaining that a multi-bit bus cannot be crossed on two flops because
"an increment is not a single-bit change: 7 to 8 flips four bits and 15 to 16
flips five", and that the receiver can see a value that is neither the old one
nor the new one. **Twenty lines below it, the video-to-3D crossing did exactly
that:**

    logic [BW-1:0] beam_band_s1, beam_band_s2;
    always_ff @(posedge clk) begin
      beam_band_s1 <= BW'(scan_y >> $clog2(BAND_H));   // six bits, plain 2FF
      beam_band_s2 <= beam_band_s1;

The fix was applied to one direction and not the other, in the same file, under
the comment that describes the bug.

**Why it shows.** `beam_band_s2` feeds `beam_ext`, which is what decides WHEN A
FILLED BAND IS PRESENTED. A mixed sample swaps a band in while the beam is
somewhere else - a band's worth of picture in the wrong place - and
`beam_blank = (beam_ext >= NBANDS)` can read as blanking when it is not, which
arms band 0 mid-frame. With 48 bands the index changes 48 times a frame, about
2,760 times a second, so a rare mixed sample still lands often enough to disturb
the sequencer for a second or two while it re-syncs.

**Fixed** with the same toggle handshake the other direction uses: data held
stable, a single toggle bit crossed, receiver captures on the toggle edge. The
data changes once a line - 655 scan clocks - so it is settled long before the
toggle has been through two flops.

**NO BENCH CAN CONFIRM THIS, and the file says so about the original**: render3d
ticks both clocks from one edge and `tb_m1_frame` drives them from exact
multiples, so neither can produce a settling failure. It is hardware-only by
construction. `make test` is identical to baseline and `tb_m1_frame` still fills
and presents bands at the same rate with zero late - which shows the crossing
still delivers, not that the fault is gone. **Only the board can say that.**

**What was ruled out first, from the same two-minute capture:** every deadline
counter in the 3D path is flat zero over the whole race - `T` late bands, `D`
dropped quads, `G` out-of-range vertices, `H` short. There is no time to buy, so
the clock bump that was proposed could not have helped. The only non-zero
counter is `M`, the 2D tile fetch overrun, at about 1.7 a frame - a repeated
scanline in the 2D layer, on `clk_sys`, and a separate matter.

---

## 2026-09-09 — THE LEFT-SIDE CUT IS FIXED, CONFIRMED ON THE BOARD

Two minutes of real driving with the plane fix (`01ef1cf`), against the same two
minutes captured the night before on the build without it. Same track, same
instrument, same analysis.

| | before | after |
|---|---|---|
| left plane reading `0xBD6A` | 49 of 119 lines | **0 of 119** |
| `L/R` scanout split, min / mean | 0.18 / 0.69 | **0.82 / 1.00** |
| intervals in cut (`L/R` < 0.30) | 37 of 118 (31%) | **0** |
| quads per object | 25.8 | **31.8** |
| dropped recomputes caught (`q`) | - | **+18,841** |

The bad plane value never appears. The scanout split sits at 1.00 instead of
collapsing to 0.19, and quads per object is back to the 31.9 that the healthy
intervals of the previous capture showed. Ben, driving: "Left side stayed the
whole race."

**`q` says how often this was happening: 18,841 in two minutes**, about 157 a
second, roughly 2.7 per frame. The game issues its viewport/zoom/translate burst
constantly and a request landed mid-set on nearly every frame; about one in
three of those left the frustum wrong. The fault was never rare - it only needed
one later command to arrive while the module was idle to clear itself, which is
precisely why it appeared to come and go with scene complexity.

**What this closes.** The missing left side was the single open defect blocking
the 3D picture and it took four sessions, during which it was attributed in turn
to the quad store overflowing, the geometry pass duration, the band presentation,
the clipper, the backface cull, the projection state, and a display-list race -
every one of those cleared by measurement, and two of them fixed as real but
unrelated defects. `docs/findings.md` 2026-09-08 has why the plane itself was
cleared wrongly: it was sampled only in the healthy state.

**The method that finally worked**, worth keeping: one capture containing BOTH a
cut and a recovery, with intervals classified by a signal that defines the
symptom (`I`/`J` as wrap-aware deltas), then every other field compared between
the two classes. Every previous capture was taken entirely inside one state or
the other, so a value that CHANGED looked constant. Nothing new had to be built
to do it - the fields were already on the wire.

---

## 2026-09-08 (late, 2) — THE CAUSE: A PLANE RECOMPUTE ARRIVING MID-SET WAS DROPPED

Found in `m1_geo_planes`, reproduced in simulation to the BIT, and fixed.

    S_IDLE: if (recompute) begin ... st <= S_S1; end

`recompute` is a ONE-CYCLE pulse and that was the only place it was sampled. A
full set is four planes of two adds and a divide through the shared FP pool -
172 cycles with the pool to itself, and considerably longer in the design where
six other clients contend for it. The frustum follows THREE display list
commands (viewport 0x03, zoom 0x09, view translation 0x0c) and the game sends
them together, so the later ones land mid-set. **Those pulses were thrown away.**

The operands are combinational on the live registers, so the in-flight set is
computed from a mix - and is then never recomputed, because the request that
would have corrected it was the pulse that was lost. **The wrong plane LATCHES**
until some later command happens to arrive while the module is idle. That is the
"it lasts minutes if you stop at the right time" symptom, exactly.

**The direction, from the test:** the game sets a NARROW viewport (x1 = 232) for
some inset and then restores the full one (x1 = 0). It is the RESTORE that gets
dropped, so the frustum stays narrow and the left 47% of the picture is clipped
away. Nothing was ever wrong with what the game asked for.

**The fix** is `pend`: a pulse in any state is remembered and the whole set is
redone when the current one finishes, so the last command of a burst always gets
a full pass over settled operands. That is correct without latching all ten
inputs - 320 flops this design has no room for at 99% ALM. `busy` covers `pend`
too, or an object handed over in the single cycle between a set and its redo
would be clipped against the mixed planes the redo exists to replace.

**`m1_geo_planes` HAD NO BENCH.** Not one, in a suite with benches for xform,
project, det, rsqrt, recip, color, norm and clip. The module that produces
`a_left` - and a wrong `a_left` is a hard vertical cut across the picture - was
never tested. `tb_m1_geo_planes` now covers it: the board's own viewport, the
mid-set request, `busy` across the redo, and 400 fuzzed viewports against
`set_viewport` in host float.

**The bench was verified to CATCH the bug**, by restoring the old behaviour and
watching it fail - because a test that passes before and after is not evidence:

    FAIL mid_set_request a_left: got -0.8857143 (bf62be2c) want -0.05714286 (bd6a0ea1)

`bf62be2c` and `bd6a0ea1` are, in their top sixteen bits, `BF62` and `BD6A` -
**the exact two values the board reported** as healthy and cut. Simulation
reproduces the hardware's wrong value bit for bit.

**Still owed: the board test.** This is proven in simulation and against the
measured plane values, but nobody has yet driven the game with the fix in.

---

## 2026-09-08 (late) — THE LEFT-SIDE CUT IS THE LEFT CLIP PLANE, AND IT IS COMPUTED WRONG

**Measured on hardware, in a single capture that contains both a cut and a
recovery** - which is what every previous attempt lacked. 119 report lines, two
minutes of driving. Intervals classified by the scanout split `I`/`J` as
wrap-aware deltas: `L/R < 0.30` is a cut (37 intervals), `> 0.80` healthy (64).

**The left clip plane differs between the two states:**

| | plane_l (`Y`) | float32 | of intervals |
|---|---|---|---|
| cut | `0xBD6A` | **-0.0571** | 35 of 37 |
| healthy | `0xBF62` | **-0.8828** | 47 of 54 |

`m1_geometry`'s own comment gives the mapping, and the same capture gives every
term: `xc` = `0x4378` = 248.0, `zoomx` = `0x438C` = 280.0, `viewx` = 0.

    screen_x = xc + a_left*zoomx + viewx

    healthy  -0.8828 -> 248 - 247.2 =   0.8   (the left edge; correct)
    cut      -0.0571 -> 248 -  16.0 = 232.0

**232 of 496 is 47% of the screen**, which is Ben's "about 48% on the left",
derived rather than guessed. The design note predicted this exact cut for
`a_left = 0.0` and concluded that a non-zero `a_left` meant the recompute was
running - but -0.0571 is not zero and still lands the plane in the same place.
That is why "it is not zero, so that is not it" survived.

**The input is IDENTICAL in both states.** `K` (viewport x1) is 0 on every one
of the 119 lines, as are `viewx`, `xc` and `zoomx`. Same input, different
output: the plane COMPUTATION is producing a wrong result, not the game asking
for a different frustum.

**Three earlier conclusions are corrected by this capture:**

- **"The left clip plane is correct (Y=BF62 = -0.88)."** It sampled only the
  healthy state. The instrument existed; nobody compared cut against healthy
  intervals WITHIN one capture, so a value that changes looked constant.
- **"The cut is fewer objects walked (130 -> 27)."** Not supported here. During
  the cut `P` is 46.4 mean and while healthy 40.1 - HIGHER during the cut. `P`
  does not track the cut at all. What tracks it is quads per object: **18.5
  during the cut against 31.9 healthy**, with `D` = 0. The objects are walked
  and the clipper eats them.
- **"The geometry pass is 206% of a frame."** Stale, as Ben suspected. `L` peaks
  at 5,763 against a two-frame budget of 7,762 - **74%** - and at full scene
  (`P`=130) it is 5,256, which is **1.35 frames, not 2.06**. The speed work
  already closed it. Nothing in this capture is over budget.

**The list race is NOT the cause, measured.** `dbg_list_race` (`p`) was built for
this and reads FLAT through the entire cut - 37 intervals, zero increments. Its
106 counts all land after the cut recovers. The theory that the pass overruns
the two-frame flip is dead, and consistent with `L` never approaching budget.

**Where to look next.** `a_left` is computed by `m1_geo_planes` from the
viewport, using the SHARED adder and divider pool (`add_req[6]`, `div_req[6]`)
over a req/gnt/rsp handshake. Pool contention scales with scene complexity,
which is exactly when the cut appears - and would explain a correct input
producing a wrong output intermittently while attract, with far less
contention, stays clean. Not yet proven: the per-port `rsp` lines are indexed,
but `div_res` is a shared bus, so the question is whether the result is stable
for the granted port on the cycle its `rsp` fires.

`v` (2D tilemap pair 0/1 ctrl) also flips 0x800 <-> 0 with the cut. It is a 2D
register and cannot clip the 3D layer, so treat it as a marker of the game state
rather than a mechanism - but it is a reliable one for finding the state again.

---

## 2026-09-08 — THE GEOMETRY BUDGET IS ONE DEADLINE, NOT TWO, AND IT IS 3% NOT 206%

Written down because it has now been misstated three ways in one session and
each way changes what work looks worth doing.

**The pass takes 2.06 frames. The budget is 2 frames. It is 3% over.**

    206% of ONE frame  =  103% of TWO frames  =  the same duration

Both percentages describe the same measurement. The meaningful denominator is
two frames, and here is why - it is not a convenience:

- **Virtua Racing flips its display list by hand, every SECOND frame**, at the
  V60's listctl write. `tools/mame_flip_writes.lua` measured that the buffer it
  flips TO is finished at the flip and untouched until the next one.
- So a new list exists only every two frames. **Finishing a pass in one frame
  would render the same list twice and change nothing on screen.** There is no
  visual deadline at one frame, and any figure quoted against one frame is
  measuring against a deadline that does not exist.
- The flip IS a real deadline, and a correctness one: past it the V60 starts
  rewriting the buffer the walker is still reading.

**What this rules out.** A claim was made in session that the pass needed
~76 MHz on `clk_3d`. It does not, and the arithmetic never supported it: 57.14
-> 76 MHz is 1.33x, which turns 206% into 155% - neither one frame nor two. Ben
caught this. The deficit is 3%, so the useful clock question is "what buys a few
percent", not "what buys 2x".

**And the clock ladder is coarse.** The PLL VCO is 800 MHz and every output is
an integer divisor (`80 = 800/10`, `57.142857 = 800/14`, `28.571429 = 800/28`),
so the steps above the current `clk_3d` are:

| divisor | clk_3d | vs now |
|---|---|---|
| 800/14 | 57.143 (current) | - |
| 800/13 | 61.538 | +7.7% |
| 800/12 | 66.667 | +16.7% |

`58.947` is NOT on that ladder - it needs a different VCO, and the figure in
The rules file predates the present PLL. 800/13 costs 1.25 ns of period against a
measured `clk_3d` slack of +0.588 to +0.745 ns, so it does not close as it
stands, and when `clk_3d` is pushed the binding path is the COPROCESSOR
(`mb86233_core` state paths), not the geometry - `m1_geometry` reaches 59.36 and
`m1_raster_fill` 58.84.

**So the cheapest few percent is worth more than a clock step.** If the pass
does not begin at the flip - the bench shows idle time before a pass, though
its scene is not representative - then starting earlier buys the 3% for nothing.

**The quad store is PER PASS, not per two frames.** `m1_raster3d` instantiates
`m1_quad_store` twice in a generate, one bank per role, and `qs_clear = prod_go`
empties the producer's bank at pass start. So NQ = 3,584 is the ceiling on ONE
image's quads; the silicon holds 7,168 across both banks. A bank's contents are
DISPLAYED for about two frames because the list only changes that often, which
is what makes "held for two frames" a natural but wrong reading of the capacity.
The board measured U peaking at 3,034 against the old 3,072 cap - one image at
99% of it.

---

## 2026-09-08 — THE I/O BOARD'S EEPROM WAS READ ONE BIT LATE, AND THE GAME SAW AN UNCONFIGURED BOARD

**The V60's instruction stream now agrees with MAME's for the whole trace
window.** `make v60_trace` diverged at instruction 24,825 for weeks, on

    FE078E: cmp.w #41474553, 0[R20]     ; "SEGA"
    FE0797: be     FE07AC

where the reference branches and we fell through. It now runs to the end of our
window (27,376 of 27,377 instructions, i.e. no mismatch) with only loop COUNTS
differing.

**What it was.** `R20` points at a 128-byte identity block the I/O board's Z80
publishes into shared RAM `0x100..0x17f`, which the V60 block-copies to work RAM
`0x40DC80` at `FE08F2` and then checks. The Z80 reads that block out of a 93C46
serial EEPROM. Ours returned every word **shifted right by one bit**:

| EEPROM word | want | Z80 got | `want >> 1` |
|---|---|---|---|
| 0 | `5345` | `29a2` | `29A2` |
| 1 | `4741` | `23a0` | `23A0` |
| 2 | `1c82` | `0e41` | `0E41` |
| 3 | `0100` | `0080` | `0080` |
| 4 | `889a` | `444d` | `444D` |
| 5 | `ff01` | `7f80` | `7F80` |

All six, exactly. `m1_ioz80` loaded `ee_out <= {1'b0, ee[addr]}` when the
address completed, so the **first** read clock emitted the dummy 0 and the
firmware — which clocks exactly sixteen times — collected `[0, D15..D1]`. A real
93C46 presents the dummy on the clock that latches the last address bit. Fixed
by loading `{ee[addr], 1'b0}` and driving the dummy on that same edge.

The game then failed its own signature check and took its uninitialised-board
branch. That is upstream of everything: a different init path, a different
display list.

**A SIMULATION-ONLY `$readmemh` IS WHY THIS SURVIVED.** The array was filled by
`` `ifdef VERILATOR $readmemh("build/rom/vr_ee_le.hex", ee) ``, with a comment
saying "hardware needs a load path". So simulation had contents to get wrong and
**hardware had no contents at all** — it read a blank part and failed the same
check for a second, independent reason. Both had to be fixed to reach the board:

- the EEPROM now rides SDRAM with the I/O firmware, one 16 KB block above it, on
  its own download index 3, and `m1_ioz80` preloads its array through the fetch
  port it already owns before releasing the Z80. No new clock crossing.
- the `$readmemh` is **gone**. Simulation and hardware get it the same way or
  neither does.
- `tools/build_rom_image.py` extracts `93c45.bin` (it is in the GAME zip, not the
  model1io BIOS set) and `verify_mra.py` now checks index 3 exists, is 128 bytes
  and starts `5345`. That check is the same insurance that would have caught the
  coprocessor's data ROM being missing from the MRA.

Byte order needs no swap: the dump holds `45 53 41 47`, and `hps_io` with
`WIDE=1` presents `{byte1, byte0}` = `0x5345 0x4741`.

**Widening the fetch index bit me once.** `iofw_word` went 13 -> 14 bits to
reach the second 16 KB, and `m1_integrated` reconstructs it after a CDC as
`iofw_addr_sys[13:1]`. Left at 13 it truncated, the preload read word 0 of the
**firmware**, and the Z80 published `ed f3 31 56` as the identity block — which
looks like a fresh EEPROM bug rather than a width one.

**The Z80's clock ratio was also wrong, and is NOT this bug.** The real board
runs both CPUs off one 32 MHz crystal, V60 at /2 = 16 MHz and Z80 at /8 = 4 MHz:
**4:1**. `m1_ioz80` was instantiated `CEN_DIV(6)` off `clk_cpu`, so **6:1** — the
I/O board ran at two thirds of its proper speed relative to the CPU it
handshakes with, from the day the tv80 went in (2026-09-04). The ratio IS the
divisor, so it never depended on `clk_cpu` and the overclock did not cause it;
the overclock only moved the absolute frequency (3.92 -> 4.76 MHz). Nothing in
the suite could see it, because nothing exercises the boot handshake. Now a
Bresenham `CEN_NUM/CEN_DEN` defaulting to 1/4 — a RATIO, with no frequency to go
stale — and `m1_main` deliberately passes no override. **Fixing it did not move
the divergence**, measured before the EEPROM fix; it is correct against the
reference on its own terms.

**Measured before building, and it paid.** Both fixes were found and confirmed
in `tb_m1_frame` and `make v60_trace`, with no hardware round trip. The
instruments are in `tb_m1_frame.sv`: `IDWR` (Z80 writes into the block), `IDW60`
(V60 writes into it) and `IDBLK` (what the V60 reads back, with the PC).

## 2026-09-09 (late) — THE LEFT-SIDE CUT IS FEWER OBJECTS WALKED, NOT ANYTHING DOWNSTREAM

The projection state went on the wire (j= viewx, k= xc, l= zoomx) along with two
races that had only ever been cleared by READING the source, and a walker stall
counter. Two minutes with the cut present and the car parked so it held:

    n     viewx     xc  zoomx   P obj  L passlen   wrL    wrR   L/R   f   g
    7       0.0  248.0  280.0     129       5500  7188   6436  1.12   0   0
    11      0.0  248.0  280.0     132       5637  7219   6383  1.13   0   0
    56      0.0  248.0  280.0      27       3254  1719   9454  0.18   0   0
    60      0.0  248.0  280.0      27       3255  1719   9453  0.18   0   0
    68      0.0  248.0  280.0      27       3255  1718   9455  0.18   0   0

**THE PROJECTION STATE NEVER MOVES.** viewx 0.0, xc 248.0, zoomx 280.0, identical
during the cut and outside it. So nothing is being displaced, which was the best
remaining theory - a wrong latched viewx would move every vertex sideways and
produce exactly this left/right split. It does not happen.

**AND BOTH RACES ARE ZERO.** f=0 (matrix words written mid-object) and g=0 (plane
recomputes started mid-object) for the entire run. Those were cleared earlier by
reading lw_stall and planes_wait in the source; they are now cleared by
measurement, which is the standard this project sets and I had not met.

**WHAT DOES CHANGE IS THE OBJECT COUNT: 130 -> 27, a five-fold drop**, with the
pass length falling with it, 5,500 -> 3,255. The geometry is not clipped, culled,
dropped, shifted or frozen - it is never walked. That is consistent with every
clean measurement of the last two days, because nothing downstream can be at
fault for quads that are never produced.

**TWO CORRECTIONS TO MY OWN READING, both Ben's.**

1. Counting quads while geometry is "missing" gave a count that ROSE six-fold,
   and I carried on reasoning as though quads were absent. They were not absent.
   A count that contradicts the symptom means the interpretation is wrong.
2. The identical pixel counts for a minute (1718/9454 repeating) were NOT a
   frozen producer. F=58 and S=29 are RATES - 58 fps and the game's 29 Hz list
   swap - and both are healthy throughout. The counts repeat because the car was
   parked and the scene is static. An earlier reading of F/S "frozen" was
   dismissed as a crash state and then wrongly resurrected as evidence.

**THE OPEN QUESTION, stated honestly: is 27 objects WRONG, or is it what is
visible from where the car stopped?** A sparse stretch of track legitimately
walks fewer objects, and H= (passes walking fewer than half the previous pass's
objects) reads 0 throughout, so the walker does not consider it short. The
correlation with the cut is strong; correlation with "parked somewhere quiet"
would look identical in this data.

**HOW TO SETTLE IT:** tools/mame_poly_budget.lua counts records walked per frame
in the reference. Park where the cut shows, dump the same scene from MAME, and
compare. If MAME walks 130 where we walk 27, the walk is truncating and the
fault is in m1_listwalk or what terminates it.

---

## 2026-09-09 — VR'S LEFT-SIDE CUT: SIX CANDIDATES CLEARED, AND WHAT IT ACTUALLY LOOKS LIKE

Two minutes of driving with the UART report, the cut present for about a minute
in the middle and confirmed by Ben against the trace. Deltas per sample:

           clip_in  clip_drop   e/c   culls    wrL     wrR   L/R
    healthy  11,092     ~1.3x         18,230   7,000   6,000  ~1.0
    CUT      45,025      0.41         32,205   1,660  10,010   0.17

**THE CLIPPER IS NOT DOING IT.** Its drop ratio sits at a steady 0.40-0.42 right
through the cut. **NOR IS THE BACKFACE CULL** - flat at ~30,400 against ~32,200
elsewhere. Both were the leading suspects and both are now cleared by their own
counters, which had to be fixed first: they saturated at 0xffff and read FFFF
across a whole capture until they were made to wrap.

**WHAT THE CUT ACTUALLY IS: quad production jumps SIX-FOLD and lands on the
right.** Left pixels fall 7,000 -> 1,660 while right pixels RISE 6,000 -> 10,010,
and total pixels barely change. A clip plane or a cull can only REMOVE geometry;
neither multiplies it. Six times the quads producing the same pixel count means
the quads are far smaller, and they are all on one side.

**AND THE COUNTERS GO STATIC.** 62756, 25852, 30392 repeating exactly, sample
after sample, for the duration. Identical deltas mean the stage is reprocessing
identical work rather than following a moving scene.

**SIX CANDIDATES CLEARED BY MEASUREMENT, so do not re-derive them:**

    quad store overflow   D=0 through the cut
    viewport x1           K=0, correct full width
    left clip plane       Y=BF62 stable at -0.88 throughout; a_left=0 would put
                          the cut at 48% and it is never 0
    out-of-range vertices G=0
    band memory, scanout  A=/Z= track I=/J= in the same proportion, so the fill
                          is not writing those pixels rather than scanout losing
                          them - this is what cleared the mixer, the last stage
                          HANDOFF listed as unexamined
    the fill's spans      152,025 checks against the reference INCLUDING
                          self-intersecting quads; the per-segment-vs-per-scanline
                          left/right bug is already fuzzed for
    the frustum planes    m1_geo_planes' recompute race is gated by planes_wait,
                          which m1_raster3d honours at P_OBJ
    the matrix            m1_geo_xform's mat[] is written ungated, BUT lw_stall
                          holds the list walker whenever the producer is not in
                          P_WALK or P_IDLE, so no matrix write can land mid-object

**WHERE TO GO NEXT.** The signature is upstream of the clipper: something makes
the geometry emit six times the quads, small and right-heavy, in a repeating
pattern. That is the walker or what it reads - not a rendering stage. The
instruments to add are a per-pass (not free-running) count of objects walked and
records processed, and the pass length L= read across the same window.

**AND A PROCESS NOTE THAT COST TWO DAYS.** docs/HANDOFF.md's top entry already
said, on 2026-09-05, that the left-side cut is VR-specific, that eight causes
were eliminated, that the mixer was the last unexamined stage and that K=/G= had
been built for it and never read. The rules file says to read HANDOFF after it. It was
not read, and two days went into geometry throughput - which was a real problem,
measurably fixed, and not this one.

---

## 2026-09-09 — THE MISSING 3D IS THE QUAD STORE OVERFLOWING, NOT THROUGHPUT

Measured on the board over UART, after two days of treating it as a geometry
throughput problem. The store holds 3,072 quads and the board reports:

    D = 2,452 to 3,311 quads DROPPED per pass
    U = up to 3,072 stored
    so roughly 5,500-6,400 quads are offered to a 3,072-quad store

`has_room = (count < NQ)`: the store fills in DISPLAY LIST ORDER and drops
everything that arrives after it is full. Cars are early in the list and
survive; the track and the scenery come later and are thrown away. That is
exactly the symptom - "the cars show but the track and scenery do not" - and it
is why it is intermittent: it depends on how much geometry is in front of you.

The store's own comment already records the same failure one size down: "at
2,048 the grandstand at the end of the list fell off."

**SIMULATION CANNOT SEE THIS, AND SAYS SO.** m1_speed_report.sv's own note:
"the dropped-quad counter reads zero throughout. Simulation cannot answer" -
tb_m1_geometry feeds the store synthetic objects and never fills it. The D=
field existed the whole time and had never been read on hardware.

**WHAT THIS COST.** Two days went on making the geometry pass faster: the
reciprocal 29->6 cycles, projection carrying four points, the rsqrt 27->8, the
transform prefetch. All real, all verified, 543.2 -> 351.3 cycles a quad - and
none of it could ever have fixed the picture, because the pass duration is not
what drops the objects. The lesson is the project's own rule, not followed: the
board had the answer in a telemetry field built for this exact question.

**WHAT IS AND IS NOT STILL BROKEN.** Three distinct overruns, and they need
different fixes:

    1. quad store drops       2,452-3,311 a pass   THE missing scenery
    2. band fill late         T climbing           bands miss their beam slot
    3. pass vs the list flip  3% over              a torn tail, not a drop

Only 1 is the missing 3D. And fixing 1 will make 2 WORSE, because the store is
currently discarding a third of the geometry the fill would otherwise have to
draw.

**THE FIX IS NOT MORE MEMORY.** Doubling the store needs +138 M10K against 7
free. The V60's work RAM is already in SDRAM (D8), so that lever is spent, and
what M10K remains is video memory that is read per scanline - bandwidth-bound,
which D3 says caching does not fix. The routes that remain are the quad payload
in SDRAM (bandwidth is trivial at ~8 MB/s; the radix sort's scatter pass is what
blocks it) or per-band binning.

## 2026-09-09 — WITHDRAWN THE SAME DAY: clk_3d at 58.947 MHz

Raised on the reasoning that the pass had to fit the game's two-frame list flip
and was 3.01% over. That reasoning is sound - m1_raster3d's prod_go note says a
pass is safe "for any pass up to two frames" and the bench prints against ONE
frame, which is why 206% looked like a 2x problem - but it is not what breaks
the picture. The quad store is.

REVERTED because it cost band 0. Ben: "band 0 is overrunning which it did not
before on the previous clock." Band 0 is the only band whose presentation is
tied to the blanking window rather than to the band ahead of it, so a 3% shift
in when a pass completes relative to the frame boundary moves that phase and
band 0 falls off the edge of it. A 3% margin on a path that is not the fault is
not worth a working band.

The VCO arithmetic is kept here because it was the hard part and is reusable:
clk_sys must stay exactly 80 MHz for the SDRAM, so the VCO must be a multiple of
it, and 1120 gives 1120/14 = 80.000, 1120/19 = 58.947 and 1120/38 = 29.474 -
clk_cpu still exactly half of clk_3d. The old 800 VCO could not: 800/14 = 57.143
and the next step 800/13 = 61.5 is far past m1_raster_fill's 58.84 ceiling.

---

## 2026-09-09 — 1,521 ALM WAS IN FOUR COMMENTED-OUT LINES OF THE BUILD SCRIPT

The device sat at 99% for two days and that gated everything: the 3D record
overlap could not be afforded, and the V60 was being restructured to pay for it.
Then Ben asked what the Jaguar core's qsf sets. Every OPTIMISATION assignment in
it was already set here - as with N64_MiSTer - but both files carry a block of
`VERILOG_MACRO` feature switches, and the MiSTer template ships every one of
them COMMENTED OUT. A core pays for those features unless it opts out. Ours was
paying.

    41,312 ALM  99%   before
    39,791      95%   with four macros set          -1,521
    598 free    ->    2,119 free

    MISTER_DISABLE_ALSA        292 ALM, measured in the per-entity table
    MISTER_DISABLE_YC          221 ALM
    MISTER_DOWNSCALE_NN        the two together were worth ~1,000 more than
    MISTER_DISABLE_ADAPTIVE    predicted; both are ascal parameters

Every clock we own passes: clk_sys +0.479, clk_3d +1.072, and only the
framework's HDMI PLL is negative at -0.166. Confirmed on hardware the same day.

**FOR SCALE, AGAINST WHAT WAS BEING DONE INSTEAD.** The same day, splitting the
V60's floating-point group into its own module - 549 lines, three states out of
the 106-state machine, a full verification pass - returned **341 ALM standalone
and 56 in context**. The macros returned 1,521 for four lines and no risk to any
of our logic. Two other lines of attack were measured at ZERO on the way: the
nine barrel shifters inside the FP module (removing all of them changed nothing)
and hoisting the shared displacement expressions (+20 ALM, noise - Quartus
already shares mutually exclusive arithmetic inside one always block).

**THE LESSON IS ABOUT ORDER, NOT ABOUT MACROS.** Hours went into optimising our
own logic while a documented, measured, zero-risk saving four times larger sat
in a file another core publishes. Read what comparable cores switch OFF before
optimising what we switch on.

**WHAT IS SAFE AND WHY, checked in sys_top.v rather than assumed:**

- ALSA is the LINUX-side audio channel. The mixer takes core_l/core_r outside
  the ifndef and every output - i2s/HDMI, analog DAC, S/PDIF - is outside it
  too, so our own sound reaches all of them whether it is set or not. It stays
  unused after M4, because Model 1's sound is generated in the fabric.
- YC costs composite VIDEO (CVBS) and S-video only. COMPOSITE SYNC IS
  PRESERVED: sys_top.v:1510-1514 has an explicit else branch for the macro that
  drives vga_cs from vga_out's csync_o, and pin 13 carries sync, not video.
  RGB, VGA and YPbPr are untouched.
- DOWNSCALE_NN swaps the polyphase filter for nearest neighbour when
  DOWNscaling. Model 1 renders 496x384 into 1080p and never downscales, so it
  removes unreachable logic here rather than trading quality.
- DISABLE_ADAPTIVE is the scanline filter, reachable whenever scanlines are
  enabled in the OSD. Taken deliberately, not silently.

**AND ONE NOTE IN OUR OWN SCRIPT WAS WRONG.** It said MISTER_SMALL_VBUF shrinks
"ascal's video buffer - M10K, which is what actually blocks sound". It is DDR3:
RAMBASE is 32'h20000000 and the macro only changes RAMSIZE, 8 MB -> 2 MB
(sys_top.v:717). It does nothing for ALM or M10K. Still worth remembering for
M4, whose PCM samples also live on DDR3.

**WHAT THIS DOES AND DOES NOT UNBLOCK.** The 3D record overlap costs ~350 ALM
measured, so it now fits with room to spare. Sound does not: it needs ~8,837 ALM
and ~57 M10K, against 2,119 ALM and 7 M10K free. The ALM half of that is the
V60's 7,500 gap to the i960 - so the V60 restructure is the SOUND prerequisite,
not the 3D one. The M10K half has to come from moving a memory off-chip.

---

## 2026-09-08 — ALL THREE LATENCY FIXES CONFIRMED ON HARDWARE, AND THE 3D IS UNCHANGED

Flashed and run on the DE10-Nano in sequence, each its own bitstream:

    reciprocal 29 -> 6 cycles     c17a481   same picture, working
    projection 1 -> 4 points      7daf73f   same picture, working
    rsqrt 27 -> 8 cycles          eca5616   same picture, working

"Same picture" is the PASS CONDITION, not a disappointment: all three are
speed-only and were proven bit-identical in simulation (0 vertex coordinates
differing and colour exact on 15,688 real-model quads). A visible difference
would have meant hardware disagreeing with simulation.

**The left-side missing 3D is unchanged, exactly as predicted.** The pass still
needs 217% of a frame, so objects still drop; cars on the left are present as
before. Three latency fixes in a row, each buying less than the one before -
543.2 -> 413.5 -> 375.7 -> 369.2 cycles a quad - and the symptom does not move,
because the units were never the constraint. See the dead-time entry: 54% of
cycles ask neither shared unit for work, all of it inside the record walk.

The rsqrt build carries clk_sys at -0.417 with TNS -4.837 and runs correctly
anyway. That is a data point about how much negative slack this design tolerates
on that clock, not permission to ship it.

**WITHDRAWN THE SAME DAY: "register packing is a timing dial".** Two controlled
pairs disagree and there is no explanation that fits both:

    pool rsqrt RTL:  NORMAL/MEDIUM 40,941 ALM clk_3d -0.246
                     DENSE/HIGH    41,145 ALM clk_3d +0.672   (+204 ALM, +0.9 ns)
    DSP  rsqrt RTL:  NORMAL/MEDIUM 41,140 ALM clk_sys -0.417
                     DENSE/HIGH    41,140 ALM clk_sys -0.417   (identical to the ps)

Identical slack to the picosecond across a re-place is not a small effect, it is
no effect. Both report files were verified fresh. The knob is kept in
tools/mister_project.sh with this caveat; do not rely on it until a proper
controlled test explains the difference.

---

## 2026-09-08 — THE RECIPROCAL BOUGHT 652 ALM AS WELL AS 23 CYCLES

`make rbf`, Quartus 17.0, 0 errors, with the 6-cycle reciprocal in, against
yesterday's build:

                    2026-09-07      2026-09-08
    ALM             41,491 (99%)    40,839 (97%)    -652
    DSP             63              67              +4
    M10K            -               545/553 (99%)
    pll_hdmi slack  -0.044          -0.096

It **paid for itself in area**. Trading `fp_div` round trips for four DSPs and
1.7 Kbit of LUT ROM took 652 ALM out of a design that was at 99%, and ALM is
the binding constraint. The core clocks are all met - clk_3d +0.440, clk_cpu
+1.090, clk_sys +5.003 - and the only negative path is the framework's HDMI
output PLL, which was already negative yesterday and got 0.052 ns worse.

**A correction made while writing this entry.** The first version said the 97%
was "not attributable to the reciprocal" and compared it against 29,771 ALM
from 2026-08-19 - a figure three weeks stale, from before the 3D path existed.
The rules file had the 2026-09-07 number the whole time. Comparing against the
oldest number to hand turned a 652 ALM saving into an 11,000 ALM alarm. Take
the most recent measurement, not the most memorable one.

**WHERE THE GEOMETRY PASS ACTUALLY STANDS.**

    543.2 cycles a quad   316% of a peak frame   before today
    413.5                 243%                   reciprocal 29 -> 6, pipelined
    375.7                 220%                   projection carries 4 points
     95.0                  56%                   the arithmetic floor

The floor is what the pass ISSUES: 95 multiplies and 69.6 adds a quad through
one fp_mul and one fp_add, both of which retire one operation a cycle. So the
multiplier is busy 95 cycles in 375 - idle three cycles in four - and **the
remaining 4x is dependency chain, not arithmetic.** There is enough arithmetic
in the design to make budget already.

**THE CHAIN IS THE WALKER'S, NOT ANY ONE STAGE'S.** Every stage inside a record
is now issue-many-and-collect rather than issue-one-and-wait: m1_geo_xform
always was, m1_geo_project is as of today. What remains is that the walker
retires one record before starting the next, so the pool drains between them.
Overlapping RECORDS is the next lever and it is a larger change than anything
done today.

**A MEASURED NEGATIVE RESULT, so it is not retried.** The transform order is
P0, VN, P1, and the note explaining it rested on projection being a 29-cycle
unpipelined reciprocal - which expired this morning. Reordering to P0, P1, VN,
so the second projection no longer waits on all three transforms, measures
**WORSE: 375.7 -> 384.2**. Projection is no longer the longest pole;
`normalize -> colour` is, and moving the normal last pushes that tail out by a
whole transform. Recorded in `m1_geo_walk.sv` at the order itself.

---

## 2026-09-08 — THE RECIPROCAL IS 6 CYCLES, AND THE INSTRUMENT THAT SIZED IT WAS WRONG

Projection's `1/z` moved off `fp_div` and off the shared FP pool onto a local
fixed-point Newton pipeline in DSPs (`rtl/video/m1_geo_recip.sv`).

    latency            29 cycles  ->   6
    pipelined          no         ->   yes, one reciprocal per cycle
    cycles per quad    543.2      ->   413.5
    peak frame         316%       ->   243% of 818,133 cycles
    cost               920 ALM / 4 DSP / 0 M10K for all of m1_geo_project,
                       Fmax 94.50 MHz against a 57.143 MHz clk_3d
                       (Quartus 17.0, MOD=m1_geo_project)

**A TABLE ALONE IS NOT THE MECHANISM, AND THIS WAS ASKED TWICE.** The 64-entry
seed table is only a ~7-bit first guess. The Newton step `r' = r*(2 - m*r)`
SQUARES its own error, so 7 -> 14 -> 24 bits in two passes, and a float32
mantissa only has 24 bits. The table sets where the iteration starts, not where
it ends, which is why 64 entries is enough and a bigger one buys nothing.

Measured in pixels against the same corpus - 4 M points, x in +/-4096, z over
six decades, zoom 256, comparing `floor(x*recip*zoom)` to `floor(x/z*zoom)`:

    exact reciprocal (what shipped)     0.1646% of points a pixel out
    64-entry seed + two Newton steps    0.1667%, never more than 1 pixel
    64-entry seed + ONE Newton step    14%, up to 62 pixels - rejected

**TWO EARLIER READINGS ARE CORRECTED, both kept visible.**

1. *"the reciprocal is 425% of a frame budget"* - **wrong, and it is what
   justified this work.** `tb_m1_geometry`'s four inside-projection counters
   (`pj_recip`, `pj_scale`, `pj_hold`, `pj_idle`) were never reset, so they
   accumulated over the entire bench while `busy` covered only the throughput
   loop. Numerator and denominator measured different windows. Fixed in the
   same change; the honest reading afterwards is **recip 11.2%, scale 47.0%,
   handover 6.4%, idle 34.3%**. The *ratios* were always sound because all four
   shared the same wrong window, so the reciprocal genuinely was the largest
   term - the decision was right, the magnitude was not. Any
   inside-projection percentage quoted from before 2026-09-08 is inflated.

2. *"x*(1/z) lands on a different pixel in 0.002% of cases"*, in
   `m1_geo_project.sv`'s header - **not comparable to the numbers above.** It
   was taken over six FIXED zoom levels; on the corpus above the exact divider
   itself measures 0.1646%. Comparing 0.002% against 0.1667% reads as a 100x
   regression when the like-for-like difference is 1.3%. Compare rows of the
   same corpus, never a row against a number from another one.

**THE SHARED FP POOL WAS THE LATENCY, not a route to avoiding it.** The first
version of this module ran Newton's step on the pool's float multiplier and
adder. It was correct - 22.3 bits, 0.15% a pixel out - and measured **21.0
cycles against fp_div's 29**, a 27% cut where 3x was needed. Three round trips
through an arbiter (request, grant, respond) cost more than the arithmetic. On
a latency problem, the pool IS the latency. That version is deleted.

This is the third thing aimed at this reciprocal. A second pooled `fp_div` was
tried twice and made it slightly WORSE (543.2 -> 545.4 cycles a quad), because
only one reciprocal is ever outstanding: more units help contention, only a
faster operation helps a serial dependency.

**WHAT IS NOW THE LARGEST TERM: the scale chain, 47.0%.** Four FP latencies per
point (`S_M0`, `S_M1`, `S_A0`, `S_A1`). `S_A0` and `S_A1` fold into one - the
adds are `(ax + viewx) + xc` and `yc - (ay + viewy)`, which regroup to
`ax + (xc + viewx)` and `(yc - viewy) - ay` against constants that only change
with the viewport. That removes one latency of four and is not done yet. The
note in `m1_geo_project.sv` saying the chain was "well inside the 29 the
reciprocal takes, so tightening it would buy nothing" was true when written and
is now false; it has been corrected in place.

---

## 2026-09-08 — THE CLOCK RAISE FIXED TWO SYMPTOMS AND NOT THE THIRD

clk_cpu 23.529 -> 28.571 and clk_3d 47.059 -> 57.143, +21.4% on both, all
timing met (clk_3d +0.498, clk_sys +0.759, pll_hdmi +0.134 -- the first build
of the day with no negative slack anywhere). Confirmed on hardware:

    band 0 overrun     ALMOST COMPLETELY GONE
    slow speed in pit  almost gone, nearly full speed
    48% missing 3D     STILL THERE, "at times"

### What that says about each

**The overrun and the pit slowdown were throughput**, and 21% more clock was
enough. That is consistent with the CPU running at ~66% of the real board's work
per frame before and ~80% now.

**The missing 3D is NOT simply the geometry deadline, or not only that.** The
pass went from len=1.47 fr to ~1.21 fr -- a 21% cut in the overrun -- and the
dropout persisted. If it were purely "the pass does not finish in time", a fifth
of the overrun disappearing should have shown. It did not.

That does not clear the deadline theory outright: 1.21 is still over one frame,
so the pass still does not fit. But it means the effect is at best partial, and
the theory has now survived one test it could have failed cleanly.

**The measurement that would settle it has still never been taken.** `len=` and
`obj=` come out on the UART and nobody has read them on a healthy build. If
`len=` is now ~1.21 and `obj=` is unchanged on the frames that drop, the cut is
not the deadline. If `obj=` rose and the dropout merely became rarer, it is.
One capture answers it, and it is cheaper than the next clock rung -- which
would need m1_geometry from 61.05 to 66.67 and whatever the TGP needs after
that.

### Where the clock ladder stands

    47.059 / 23.529   start of day, ~66% of the real board
    53.333 / 26.667   "noticeable"
    57.143 / 28.571   SHIPPED, timing met, ~80%, overrun and pit fixed
    66.67  / 33.33    needs m1_geometry +9% (61.05 today), pass 1.04 fr, ~93%
    72.73  / 36.36    pass 0.95 fr -- the first rung that FITS -- ~102%

---

## 2026-09-08 — THE MISSING 3D IS A LATENCY PROBLEM IN PROJECTION, AND A SECOND DIVIDER CANNOT FIX IT

The geometry bench, run against REAL models out of the polygon ROM, settles two
things at once.

### Geometry does not lose the objects

    800 real objects over 16 yaw angles, 0 that did not match at all
    15,688 quads, 0 vertex coordinates differing, colour exact on 15,688
    band touches 1.11 a quad, 0 off screen

Transform, cull, clip and colour are all exact on the real corpus. Whatever
removes 48% of the 3D is not discarding it in the geometry stage.

### It cannot FINISH, and the overrun is far worse than the telemetry said

    a peak frame of 4,798 quads needs 2,587,533 cycles of 818,133  = 316%
      project      90.6% outstanding, 36.1% SOLE CAUSE
      inside projection: recip 425.2%  scale 399.8%  idle 545.5%

**316% of a frame, not the 147% that `len=1.47 fr` suggested.** That is why the
clock raise did not fix the dropout: clk_3d went up 41% and this needs 3x.

### A second divider was tried again and is still wrong

fp_div is only 263 ALM and the grant race that broke the FIRST attempt is fixed,
so it deserved a retry. Measured: 543.2 -> **545.4** cycles per quad, 316% ->
**320%**, reciprocal 425.2% -> **434.0%**. Slightly worse, again.

**The reason is that this is LATENCY, not CONTENTION.** `idle 545.5%` inside
projection is the tell: the unit is not queueing behind a busy divider, it is
waiting on its own single reciprocal, because every point needs 1/z before its
multiplies can start. One request outstanding at a time means a second divider
sits idle. More units help contention; only a faster operation helps latency.

So the 2026-09-0x note that the grant mask "is the prerequisite that makes any
second divider work" is true and beside the point -- the mask was needed, and
the divider still does not help.

### What does follow from it

Make the reciprocal FASTER rather than more numerous. `m1_geo_rsqrt` already did
exactly this for the same divider - "an 8-bit seed table and ONE Newton-Raphson
step... about 5 cycles of a multiplier at 69% rather than 29 cycles of a divider
at 85%".

Measured before writing any RTL, 8 M points over six decades of depth, error
counted in PIXELS rather than mantissa bits:

    exact reciprocal (ships today)   0.078% of points land a pixel out, max 1
    2048-entry seed + 1 Newton step  0.152%, max 1
    1024-entry seed + 2 steps        0.139%, max 1
    256-entry seed + 1 step          2.6%,   max 4    <- rejected

and the accuracy of the step itself:

    table lookup alone      12.0 correct bits
    after ONE refinement    22.5 correct bits
    a real float32 divide   ~24 bits, the format's limit

Past 2048 entries nothing improves - the residue is float32 rounding in the
final multiply, not the table - so 2048 with one step is the stopping point and
there is a reason for it rather than a guess. Cost is 64 Kbit of M10K, ~1%.

---

## 2026-09-08 — WITHDRAWN: THE SDRAM DOES NOT LOSE REFRESHES

**This entry was wrong and is kept because the reasoning looked sound.** It
claimed `ref_pend` being a single bit meant a refresh falling due while another
waited would be silently merged and lost, with only 4% of margin at
`T_REFI = 600`.

The arbitration prevents it, and reading twenty lines further would have shown
that:

    end else if (!ref_pend && ((wr_pend && ...) || (arb_ok && ...)))
    // "No new transfer once a refresh is due."

Once `ref_pend` sets, NO new transfer starts. The read pipeline therefore drains
within `RD_LAT` (7) plus `T_RAS` (5), about twelve cycles, against a `T_REFI` of
600. A second refresh cannot fall due before the first is serviced, so the
single bit is safe *because* of that interlock rather than in spite of it.

It was then used to explain VF's attract-mode tile corruption and the 66.667 MHz
picture, on the grounds that more 3D traffic would starve refresh further. That
explanation is void too.

### What the entry below still gets right

The observation that prompted it stands: on the 66.667 build the 2D was
corrupt while the 3D was clean. The likelier reading is that the **V60 hung** --
its PC pinned in FE13E7..FE13F1 across every UART sample -- and a hung CPU never
finishes writing the tilemap, so the sky and ground are whatever was left there.
One fault, not two, and it explains why the 3D still drew correctly from an
already-loaded display list.

**So the open question is what the V60 polls at FE13E7 that never arrives at
clk_cpu 33.333.** Disassemble it. This project's own rule -- "when a counter
names an address, go and read what is at that address" -- has beaten
hypothesising twice, and two hypotheses died here before it was applied.

---

## 2026-09-08 — SUPERSEDED: the refresh-starvation claim (see above)

Not chased yet, recorded because the mechanism is real whether or not it is the
symptom below.

    if (ref_cnt == T_REFI) begin ref_cnt <= '0; ref_pend <= 1'b1; end
    ...
    if (ref_pend && !pipe_busy && !ras_any) state <= S_PRE_REF;

**`ref_pend` is a single BIT, not a count.** If a refresh is still waiting when
the next interval elapses, the second is merged into the first and one refresh
is lost, silently. It can also only be serviced while `pipe_busy` is low --
`|tag_v`, so ANY read in flight on ANY port blocks it.

**And the margin is 4%.** `T_REFI = 600` at 80 MHz is 7.5 us; 8192 rows in 64 ms
needs one every 7.8 us. That is inside spec only while nothing is dropped.

### The symptom it would explain

Left on Virtua Fighter's ATTRACT for a long period, the 2D comes back badly
corrupted: text mirrored, tiles scrambled in regular vertical bands, palette and
overall layout intact. **The 3D is fine.** Photographed 2026-09-08 on the
57.143/28.571 build.

| observation | refresh starvation predicts |
|---|---|
| takes minutes | DRAM decay is slow and cumulative |
| corrupts 2D tiles | character RAM at 0xFA8000 is written once, then only read |
| 3D unaffected | polygon data is re-read constantly, from a different region |
| new today | clk_3d +21% -> more 3D traffic -> pipe_busy high more often |
| never seen before | the load was lower |

### What it is NOT

**Not the unclosed slack.** That build misses by -0.305 ns on
`mb86233_core|ir[20] -> state.S_LABB`, which is in the TGP on clk_3d and feeds
the 3D -- and the 3D is clean. clk_sys had +0.474 ns and clk_cpu +5.614, so the
domain the tilemap actually runs in meets timing comfortably. For the slack to
cause this, a violation in the coprocessor's state machine would have to corrupt
the tilemap while leaving the geometry it drives intact.

**Distinct from VR's five-minute black screen**, which is deterministic, happens
at the END of attract, looks like an attract restart, and never happens in game
or on VF. See the memory note; that one is a software/state fault.

### The fix, when it is taken up

Make `ref_pend` a small counter so refreshes queue instead of merging, and give
refresh a deadline after which it preempts rather than waiting for `pipe_busy`
to clear. Same shape as "acknowledges must be held, not pulsed" -- a
single-bit event that can be overwritten while the thing it asks for is
deferred.

**It is provable before a build**: count refreshes issued against elapsed cycles
in `tb_m1_sdram` under saturated load. If the ratio is worse than one per
T_REFI, the mechanism is confirmed without touching hardware.

---

## 2026-09-08 — THE TGP IS THE clk_3d CEILING, NOT THE 3D UNITS

Registering all three FP pool operand muxes took m1_geometry from 39.6 to
**59.36 MHz** and moved its critical path out of the pool entirely, into
`m1_geo_walk|o0z[20] -> qz[8]`. The pool is no longer the limiter.

So the next rung was tried - clk_3d 800/14 = 57.143, clk_cpu 800/28 = 28.571 -
and **it fails timing at -1.256 ns**, with TNS -2.820, so two or three paths.
All five worst are the same place, and it is not the 3D at all:

    mb86233_core|state.S_DST_W -> state.S_DST      -1.256
    mb86233_core|state.S_DST_W -> state.S_LABB     -1.241

**`m1_tgp` is dual-clock and its core runs on clk_3d**, deliberately at exactly
2x clk_cpu so the coprocessor gets two cycles per CPU cycle - "against a 16 MHz
V60, where we had 1:1". So raising clk_3d clocks the COPROCESSOR faster too, and
its state machine is the ceiling.

The TGP's in-core ceiling is between **53.333, which closes with +1.166 ns**,
and 57.143, which does not.

### The prediction that was wrong, and why it matters

m1_raster_fill was expected to be the next wall, on its standalone 58.84 MHz.
It is not - it clears 57.143 comfortably, and so does m1_geometry at 59.36. The
module that broke it had not been measured at all, because it is not in the 3D
layer and nobody had thought to check what else lives on clk_3d.

**Check what SHARES a clock before predicting what limits it.** The standalone
Fmax of the modules you are thinking about says nothing about the module you
forgot.

### Where the staircase stands

    47.059 / 23.529   start of day, ~70% of the real board
    53.333 / 26.667   SHIPPED and confirmed on hardware, ~79%, "noticeable"
    57.143 / 28.571   blocked on mb86233_core's state machine
    66.67  / 33.33    then blocked on m1_geo_walk 59.36, m1_raster_fill 58.84
    72.73  / 36.36    the V60's 38.19 binds through the 2x tie, ~107%

Each rung is now a named module with a measured number, which is the useful
part. The next one is the coprocessor's dispatch, and it is the same shape of
problem as the V60's - a large FSM whose state transition is the path.

---

## 2026-09-08 — clk_cpu IS GATED BY THE FP POOL, AND THE POOL'S LATENCY IS BAKED INTO ITS CONSUMERS

Chasing the CPU clock, not area. The V60 runs at 23.529 MHz and a mean CPI of
~17.9 against the ~12.5 real time needs, so the game gets about **70% of the
real board's work done per frame** - which is the VR slowdown.

### The V60 was never the limit

Pipelining fp_add/fp_mul's operand unpack took the V60 from 35.38 to
**38.19 MHz** (and -179 ALM; committed). But the CPU clock cannot follow,
because `clk_3d` is tied to **exactly 2x clk_cpu** so the crossing stays a clock
enable rather than a handshake - a deliberate choice, the comment noting this
project "has lost time twice to pulse-versus-level faults across domains".

So `clk_cpu <= clk_3d / 2`, and clk_3d has its own ceiling:

    m1_geometry     39.6 MHz  (shipping config; it CONTAINS the pool)
    m1_fp_pool      53.25
    m1_raster_fill  58.84
    m1_quad_store   94.99

    fp_add alone   138.48     <- the units are fast
    fp_mul alone   145.62
    fp_div alone   117.81

**The arithmetic is not the problem; the sharing wrapper is.** m1_geometry's
worst path is `m1_fp_pool|add_rr[1] -> m1_fp_pool|fp_add:u_add|sA_sticky`: the
round-robin arbiter, through the NC-way 32-bit operand mux `add_a[add_win]`,
into fp_add's first stage, all in one cycle.

### Why it has not been pipelined, which is the finding

Registering that mux is four lines and it WORKS electrically. It fails
functionally, and `m1_geo_xform` says why in its own header:

> The add schedule is fixed and spaced, not packed: ac 0 1 2 | 5 6 7 | 10 11 12.
> Three-cycle gaps, not two. **fp_add's latency is 4**, so round 1's first add
> reads a t[] the round-0 result must already have been WRITTEN to.

**The pool's latency is a hard-coded constant in its consumers' schedules.**
Adding a stage makes it 5 and those schedules read stale values:
`m1_geo_xform` went to 7,806 fails of 7,813. Reverted.

Nine modules instantiate against the pool - geo_xform, project, det, norm,
color, rsqrt, clip, planes and geometry itself - and only geo_xform documents
the assumption. The suite aborts at the first failure so the others are
UNMEASURED; do not assume geo_xform is the only one.

### What this costs and what it would take

The staircase, if the schedules were made latency-parametric:

    fix pool + geometry -> clk_3d ~56   clk_cpu ~28    ~84% of real speed
    + raster_fill       -> clk_3d ~64   clk_cpu ~32    ~95%
    + all               -> clk_3d 76.4  clk_cpu 38.19  ~113%, the V60 binds again

76.4 MHz is the ceiling worth aiming at, NOT the units' own 117-145: past
clk_3d 76.4 the V60's 38.19 binds through the 2x tie.

The honest scope is: make the consumers' schedules derive from a latency
parameter instead of a literal, then pipeline the pool. That is a session's
work across nine modules with `m1_geo_*` fuzz suites as the net, not a
four-line change - and the throughput cost of wider gaps has to be weighed
against the clock gained, on a geometry pass already measured at len=1.47 fr.

---

## 2026-09-07 — THE V60's AREA IS REAL LOGIC, NOT TIMING-DRIVEN DUPLICATION

The module build constrains `clk` at 20 ns - 50 MHz - and the V60 achieves
35.38, so it fails by 7.370 ns. A fitter chasing an impossible constraint
duplicates logic, which would have meant every V60 area figure was inflated and
that cutting LUT depth would recover area for free. Tested by constraining at
42.5 ns, the ~23.5 MHz the core actually clocks it at:

    50 MHz constraint    15,605 ALM   slack -7.370
    23.5 MHz constraint  15,649 ALM   slack +0.324

**Same area.** The fitter is not duplicating, the numbers are trustworthy, and
the 17,533 mux cells are genuine combinational logic implementing the
instruction set rather than an artefact of over-constraint.

That is a useful negative because it separates two things the LUT depth of 34.60
could have meant. Pipelining the dispatch would cut depth and raise Fmax - which
this design does not need, at 23.5 MHz against a 35 MHz ceiling - but it would
not on its own remove the 9,494 ALM. Area only comes back if the restructure
lets one physical unit do work that is currently done by several, and the
synthesiser has already shared everything that is mutually exclusive within the
block.

### What that leaves

The dispatch is 9,494 ALM of combinational decode for a CISC instruction set.
The classical answer to exactly that, and the one thing not yet tried here, is
to stop implementing decode as logic: **a microcoded or ROM-based decoder, which
moves the dispatch from ALM into M10K.** The core is at 76% of block memory bits
and ALM is the binding constraint at 98%, so the trade runs the right way. It is
also a genuine architectural change rather than a refactor, and it would need
`v60_trace` and the 29-test suite carrying it every step.

Nothing else measured this session has a path to four figures.

---

## 2026-09-07 — CORRECTION: THE DISPATCH IS 9,494 ALM, AND THE SPLIT WAS WRITTEN OFF TOO EARLY

The entry below concludes "this closes the V60 split as an area strategy". **That
conclusion is withdrawn.** It was drawn from three experiments that all probed
the same 9% of the module, and Ben pushed back on it. He was right.

    full V60                                    15,605 ALM
    opcode folded to a constant, so the whole
    primary dispatch casez folds away            6,111
                                                ------
                                                 9,494 ALM, 61% of the V60

| component | ALM | share |
|---|---|---|
| instruction dispatch + execute | **9,494** | **61%** |
| FP group | ~1,479 | 9% |
| addressing-mode decode | 1,391 | 9% |
| fetch, registers, misc | ~3,200 | 21% |

### Why the earlier experiments missed it

Every one of them - `dimext` at 16 ALM, the displacement share at -33, the
duplicate decode at 5 - hoisted AN EXPRESSION INTO A WIRE INSIDE THE SAME
MODULE. Not one of them changed the structure. They correctly establish that
**expression hoisting is exhausted**, and say nothing whatever about
restructuring, which is the transformation actually applied to Model 2's i960 -
that split took its CPI from 9 to 3.4, which is pipelining, not hoisting.

### The evidence that the structural target is real

From the post-synthesis netlist statistics, which had not been read before:

    Max LUT depth        34.60
    Average LUT depth    14.80
    arriav_lcell_comb    22,996   of which
        normal           17,533   76%, mux and select logic
        arith             4,400   ~137 adder-equivalents

An average combinational depth of ~15 levels with a maximum of 34 is what a
single 3,817-line `always` block with 200 state transitions produces, and it is
consistent with the 35 MHz Fmax. Depth and area are coupled - the fitter
duplicates logic to meet timing - so the 17,533 mux cells are both the symptom
and the cost. 137 adder-equivalents is also far more than a CPU needs, which is
the shared-datapath argument stated in numbers.

**The lesson about method, not about the V60:** three negative results in the
same 9% of a module do not license a conclusion about the other 91%. The
generalisation was made because the experiments were cheap and agreed with each
other, which is not the same as being representative.

---

## 2026-09-07 — THERE IS NO DUPLICATE ADDRESSING DECODE IN SILICON: THE SECOND COPY COSTS 5 ALM

Asked why the decode is "not fully recoverable" by extraction. Measured rather
than argued, and the answer is stronger than the claim was.

    both decodes present                     15,605 ALM
    S_BAM_MODE's decode folded away          15,600      -5
    BOTH decodes folded away                 14,214  -1,391

`S_EA_MODE` and `S_BAM_MODE` are near-duplicates in the SOURCE - same
`case (modtop)` arms, same displacement decode, same group-7 `modreg` sub-case -
and that duplication was the entire premise for extracting an AGU. **In the
netlist it is already gone.** Quartus shares the two states' decode completely,
because they are arms of one case and therefore mutually exclusive. Removing one
copy by hand recovers FIVE ALM.

So an AGU module would recover 5 ALM, not "a fraction of 1,391". The 1,391 is a
single shared decode that the CPU needs in order to decode addressing modes; it
is not duplication and there is nothing to hoist out of it.

The same argument disposes of the FP group. Its ~1,479 is what one shared FP
unit costs, and the game executes FP - `dbg_fp_trap` fires at `00fed52b` on a
real `cvt.sw` - so it cannot be deleted either.

**This closes the V60 split as an area strategy.** Every structural target
anyone named has now been priced, and the tool had already collapsed all of
them. What remains is functional logic. The one thing that DID pay, 1,054 ALM,
paid because the tool could not share it: a four-byte 24:1 mux whose select is a
runtime offset, different at every call site.

The generalisation worth keeping: **"the source looks duplicated" is not
evidence of duplicated silicon.** Mutually exclusive case arms are shared by the
synthesiser as a matter of course, and this project has now spent three
experiments - dimext at 16 ALM, the displacement share at -33, and this at 5 -
learning that the same way.

---

## 2026-09-07 — THE AGU IS WORTH 1,391 ALM IN TOTAL, SO EXTRACTING IT IS NOT WORTH A SESSION

Priced before writing it, which is the rule this session established after
hand-sharing lost twice. Constant mode selectors, so every
`case(modtop)`/`case(modreg)` arm in BOTH `S_EA_MODE` and its near-duplicate
`S_BAM_MODE` folds away - deliberately wrong, purely to measure:

    full addressing-mode decode   15,605 ALM
    decode stubbed out            14,214 ALM
                                  ------
                                   1,391 ALM, 9% of the V60

**That is the whole decode, both copies.** An AGU module can only recover the
DUPLICATION between the two states, never the decode itself, so its ceiling is
some fraction of 1,391 - and the directly comparable attempt, sharing the
displacement decode between exactly those two states, came out 33 ALM WORSE.
The expected return is a few hundred at best and plausibly negative.

### What this says about the whole split

The V60 is 15,605 ALM in the shipping configuration. The two things anyone has
been able to name as structural targets are the addressing-mode decode at 1,391
and the FP group at ~1,479. **Together that is under 20% of the module**, and
neither can be fully recovered by extraction. The remaining ~12,700 is the
instruction dispatch `casez`, the execution states and the load/store path -
not one structure, and not obviously duplicated.

So the reasoning that opened this work - the i960 is 5,414 lines in sixteen
modules at ~7,200 ALM while the V60 is 5,464 lines in four at ~16,000, therefore
splitting recovers the difference - **is not supported by what the V60 actually
measures.** The i960 is a fixed-width RISC; the V60 is CISC with variable-length
instructions, a 24-byte fetch window and multi-level addressing modes. Line
count is not the comparable quantity, and no measurement taken here shows a path
from 15,605 to 10,000.

What DID work is one specific shape, twice-confirmed: a large mux whose select
is a runtime offset, which the tool cannot share because each call site's offset
expression differs. That was worth 1,054 ALM. Nothing else measured has been
worth anything.

**Before spending another session on the split, price the target first.** Three
of the four things priced this way turned out to be worth 16, -33 and 1,391;
only one was worth building.

---

## 2026-09-07 — HAND-SHARING SMALL DECODES DOES NOT PAY; ONLY BIG OFFSET-DEPENDENT MUXES DO

Two experiments now say the same thing, and the second was tried anyway because
the first was not believed hard enough.

| hoisted by hand | sites | ALM |
|---|---|---|
| `dimext`, a 32-bit 3-way mux | 23 | **16** |
| addressing-mode displacement decode (`am_tdis`/`am_tlen`/`am_rdis`/`am_rlen`) | 18 | **-33, i.e. WORSE** |
| fetch-buffer extraction at `ea_ofs+1`/`+2` | 21 | **+1,054** |

The displacement share was reverted. It is correct - 29/29, `make test`
identical, `v60_trace` unmoved at 24,825 - and it costs 33 ALM and 0.23 MHz to
have. Quartus was already sharing those decodes across the mutually exclusive
case arms, so forcing a wire only adds the selection mux back by hand.

**The distinction that predicts which is which:** the fetch-buffer extraction
paid because each site built a FOUR-BYTE 24:1 MUX whose select is a runtime
offset. `dimext` and the displacement decode are small fixed-width selects on a
value the arm already has. The tool shares the second kind on its own and cannot
share the first, because each call site's offset expression differs.

So the rule for the rest of this split: **hoist a thing only if each of its call
sites builds a large mux whose select varies.** Counting call sites is not
evidence, and neither is the code looking duplicated - `S_EA_MODE` and
`S_BAM_MODE` genuinely are near-duplicates, and sharing the displacement between
them still lost.

That also lowers the expected return on extracting the AGU as a module. The
structural duplication is real, but if the tool is already sharing the logic
inside it, a module boundary changes the report and not the silicon. Price it
with a deliberately-broken build BEFORE writing it, the way the fetch-buffer
extraction was priced at 1,285 ALM before a line was changed.

---

## 2026-09-07 — A `function automatic` READING AN UNPACKED ARRAY IS WRONG IN A CONTINUOUS ASSIGNMENT

This cost a long bisect and will cost another one if it is not written down.

    wire [31:0] fbw_ea1 = fb32(ea_ofs + 1);                       // WRONG
    wire [31:0] fbw_ea1 = {fb[ea_ofs+4], fb[ea_ofs+3],
                           fb[ea_ofs+2], fb[ea_ofs+1]};           // CORRECT

`fb32` is `function automatic [31:0] fb32(input [4:0] o)` and its body is
exactly that concatenation, so the two lines are textually the same
computation. **They do not behave the same.** With the function form,
`tb_v60_search` fails on "encoded GA2 SKPCUH R28"; with the concatenation it
passes, every other line in the file identical.

### Why it took so long

Because every check said the substitution was faithful, and each check was
right:

- the diff was reviewed line by line - all substitutions textually correct
- `fb[]` is a stable generate-assign slice of `fb_flat`, itself `always_comb`
  off registers in `v60_ifetch`
- `ea_ofs` has no blocking assignments anywhere
- the addend width was tested both ways, `5'd1` and unsized `1` - no difference
- reverting the `modval2` part alone did not recover it

The bisect narrowed it to THREE lines, all of the form `d1t = fbw_ea1;`
replacing `d1t = fb32(ea_ofs+1);` inside `S_EA_MODE`, which look equivalent and
are not. Only swapping the function call for its own body fixed it, which
identifies the CONTEXT rather than the expression as the fault.

**The rule: inside a clocked block, calling these accessors is fine - that is
what the other ~60 call sites do and always have. In a continuous assignment,
write the concatenation.**

### What it unblocked

The hoist this was blocking is now in: 21 call sites of `disp_of`/`fb32`/`fb16`
at offsets `ea_ofs+1` and `ea_ofs+2`, across `S_EA_MODE` and its near-duplicate
`S_BAM_MODE`, collapsed to two extractions. Measured IN THE SHIPPING
CONFIGURATION this time - `QOPT="Aggressive Area"` with `TECHNIQUE AREA` -
**16,007 to 15,605 ALM, and Fmax 34.81 to 35.38 MHz.** Area and speed together,
with `v60_trace` unmoved at 24,825.

`S_EA_MODE` and `S_BAM_MODE` being near-duplicates is the finding to carry
forward: same `case (modtop)` arms, same displacement decode, same group-7
`modreg` sub-case. That duplicated addressing-mode decode is the AGU the i960
has as a 102-line module and we do not.

---

## 2026-09-07 — AGGRESSIVE AREA ALREADY IMPLIES RESOURCE SHARING; THE EXTRA FLAGS ARE FREE AND INERT

Added `AUTO_RESOURCE_SHARING`, `MUX_RESTRUCTURE`, `REMOVE_REDUNDANT_LOGIC_CELLS`
and `AUTO_DELAY_CHAINS_FOR_HIGH_FANOUT_INPUT_PINS` to the core build, taken from
Model 2's shipping `Model2.qsf`. The full 21-minute rebuild produced a
**byte-identical bitstream**: same md5 `93a95d746e3137d69eb3b48e9e8662bd`, same
41,124 ALM, same +0.896 ns on clk_sys.

Two independent instruments agree. On the V60 module the result is 16,007 ALM
with and without `AUTO_RESOURCE_SHARING`, once the mode is Aggressive Area and
the technique is AREA. On the core it is the same bitstream. **Those two
settings already enable the sharing the extra flags ask for.**

The flags are NOT harmless in every configuration. Against
`OPTIMIZATION_MODE "Aggressive Performance"`, `AUTO_RESOURCE_SHARING` alone
makes the V60 **worse** - 17,759 to 18,125 - because it fights the performance
bias. They are therefore written inside the same else-branch as the mode and
technique in `tools/mister_project.sh`, so a build that sets `M1_QSPEED` to keep
the template's speed-biased settings never gets them.

### What this says about the Model 2 result

Model 2's own comment records that "the mode, the technique and
AUTO_RESOURCE_SHARING all moved in one change and a fourth variable would make
the result unattributable". So its gain was credited to the combination and the
sharing flag's individual contribution was never isolated there. This build
isolates it: **the mode and the technique do the work**. That is a finding about
Model 2's configuration as much as ours, though nothing in that repository has
been changed.

### The thing that DOES matter, restated

The synthesis settings are worth **1,752 ALM on the V60** - more than every hand
edit made to it in this session combined - and `make rbf` has had them all
along. `make quartus MOD=<mod>` has not. That gap, not the sharing flag, is the
real finding of this line of work.

---

## 2026-09-07 — MODULE BUILDS AND THE CORE BUILD USE DIFFERENT OPTIMISATION SETTINGS

Asked whether Quartus has a flag for shared pathways. It does, the flags are
worth a lot, and **the core build already sets them** - so there is no win
sitting there. What the experiment found instead is that our two build paths do
not measure the same thing.

    make quartus MOD=<mod>     QOPT ?= "Aggressive Performance"
                               no OPTIMIZATION_TECHNIQUE line at all
    make rbf                   M1_QOPT  = "Aggressive Area"
                               M1_QTECH = AREA

Measured on the V60, same RTL:

    Aggressive Performance, no technique      17,759 ALM   36.54 MHz
    Aggressive Area + TECHNIQUE AREA          16,007 ALM   34.81 MHz

**1,752 ALM, larger than every hand edit made to the V60 today combined**, and
purely a synthesis setting. Fmax stays far above the 23.529 MHz the CPU is
clocked at, so the trade costs nothing here.

`AUTO_RESOURCE_SHARING ON` is a red herring twice over. On its own, against
Aggressive Performance, it makes the V60 WORSE - 17,759 to 18,125, because it
fights the performance bias. Added on top of Aggressive Area + AREA it changes
the result by **exactly zero**: 16,007 either way. Those two settings already
enable the sharing it asks for. Do not add it.

### What this invalidates

Every V60 area figure recorded earlier today came from the module path, so it
was measured under settings the shipping build does not use. The V60 costs
~16,007 in the configuration that actually ships, not 17,759. The SHAPE of that
profile still stands - 89% in v60.sv, FP small, dimext worthless - but the
absolute numbers were inflated and the gap to the i960's ~7,200 is smaller than
it appeared.

**So a module-level ALM number does not transfer to the core unless the
optimisation settings are matched.** Measure V60 work with
`make quartus MOD=s32_v60 QOPT="Aggressive Area"` and an
`OPTIMIZATION_TECHNIQUE AREA` line, or the number does not mean what it looks
like. This is the same class of error as the contaminated 103-cycle fetch wait:
an instrument measuring a configuration nobody ships.

---

## 2026-09-07 — WHERE THE V60's 18,411 ALM ACTUALLY IS, MEASURED

Profiled before restructuring anything, because the last three area guesses on
this project were wrong. All figures from `make quartus MOD=s32_v60`,
Quartus 17.0.

### The hierarchy

    v60.sv itself   16,325 ALM   89%   23,871 combinational ALUTs, 3,717 regs
    v60_ifetch       1,315
    v60_shift          677
    v60_alu             74
    lpm_divide          19
                    ------
                    18,411        44% of the whole device, 0 block memory bits

**89% is in one module, and inside it one `always @(posedge clk)` block of
3,817 lines.** For comparison Model 2's i960 is 5,414 lines across SIXTEEN
modules at ~7,200 ALM; ours is 5,464 lines across FOUR at 18,411. Near-identical
code volume, 2.5x the area. That comparison is what justifies the split.

### What each candidate is worth, priced by experiment

Each measured by deliberately breaking the thing and rebuilding - wrong output,
correct area - rather than by estimating.

| candidate | measured | verdict |
|---|---|---|
| fetch-buffer variable-offset muxing | **1,285 ALM** | real; 652 banked, 633 parked |
| FP group (`S32_V60_NO_FP`) | **1,479 ALM** | real, but it is only 8% |
| `dimext`, 23 call sites | **16 ALM** | NOT a target |

**`dimext` is the important negative.** Twenty-three inlined call sites of a
32-bit three-way mux cost sixteen ALM in total, because Quartus already shares
logic across mutually exclusive case arms. So "a Verilog function is inlined per
call site" is NOT on its own a reason to expect area back - the fetch-buffer
extractors were worth something because their muxes are large and
offset-dependent, not merely because they were inlined. Do not spend builds
hoisting small functions.

**The FP figure also corrects a stale one.** The rules file records the FP group at
-2,984 ALM. It is 1,479 today.

### So where is the other ~15,600?

Not in any single structure. Inside the 3,817-line block:

    255 add sites, 356 subtract sites, 2,042 compares

That is the monolith signature - mutually exclusive states each synthesising
their own arithmetic instead of sharing one datapath. The fitter also reports
`psw_rest[18]~0` at **fan-out 3,101**, which is `psw_ie`: the entire instruction
`casez` is nested in the `else` of the interrupt check, so that one condition
gates every register write in the dispatch. That is a routing/timing signal more
than an area one and should not be assumed to be worth ALM without measuring.

**The remaining prize is a shared datapath - one adder/subtractor and one
comparator with muxed operands - not more function hoisting.** That is a
multi-session restructure, and the regression net for it is
`run_v60_tests.sh` at 29/29 plus `make v60_trace`, which is the gate that
actually catches behaviour.

---

## 2026-09-07 — THE COPROCESSOR PORT WAS ALSO FETCHING DOUBLE, AND FIXING IT DID NOT MOVE THE LEFT-SIDE 3D

Confirmed on hardware at `dacf1e6`: nothing regressed, the 2D and the tile
overruns are as good as `46b9e2c`, and **the left-side 3D dropout is unchanged**.

### What was wrong

p3 is the coprocessor's `copro_data` and math tables. A fetch is one 32-bit
word; the port bursted FOUR, the top level aligned the address down to the
burst boundary, and `m1_integrated` picked the half it wanted with
`tgp_mem_addr[1]`. The same defect p1 had, found by auditing every port's
`p_dout` consumer against its `blen()` after p1 was fixed.

That audit is worth repeating on any new port. Of the seven: p0, p4 and p6 are
single-word and matched; p2 and p5 consume all 64 bits of their bursts; p1 and
p3 were the two fetching double. **p5 was NOT a third instance** - a comment in
`Model1.sv` claimed it picked a 32-bit half like p3 did, and it does not;
`m1_integrated` takes all of `r3d_rom_dout`. That comment was wrong and is
corrected.

Unlike p1, the bench totals move the right way here: 33,352 transactions served
to **34,096**, +2.2% in the same window, because with neither port fetching
words it discards the bus does more useful work. The build is also 76 ALM
smaller and `clk_sys` slack improved from +0.719 to +0.867 ns, consistent with
deleting the half-select mux.

### The hypothesis it was aimed at, and what the result means

The reasoning was: p3 is the read that blocks the coprocessor before any math
unit runs, the geometry pass it feeds measures `len=1.47 fr` against a
one-frame budget, and the left-side 3D dropout is INTERMITTENT - which fits a
deadline sometimes missed, where a clipping or coordinate error would cut in
the same place every frame.

**The dropout did not change.** But this is NOT yet a clean elimination, and
the difference matters:

- `len=` and `obj=` in the PASS3D line were **not read** on this build. If p3
  did not actually shorten the geometry pass, the hypothesis was never tested -
  only the fix's side effects were observed.
- A clean elimination needs `len=` measurably shorter WITH the dropout
  unchanged. That would say the pass got faster and the cut is elsewhere.
- `len=` unchanged would say p3 was not the pass's bottleneck, which is a
  different finding and leaves the deadline theory open.

**So the next measurement is `len=`/`obj=` off the UART, not another fix.**

### Where this leaves the left-side 3D

Still open, and the list of what has been eliminated by measurement grows:
`a_left = 0` (board said `BF62`), backface culling (identical cull rates, and
the yaw sweep), span starvation (`A=`/`Z=` answered 44.7%), and now the
coprocessor data port's bandwidth - provisionally, pending `len=`. The mixer
remains the last unexamined stage, and `K=`/`G=` have never been read on a
healthy build.

---

## 2026-09-07 — THE TILE FETCH IS FIXED, AND THE FIX WAS TO STOP FETCHING WHAT WAS DISCARDED

Confirmed on hardware at `46b9e2c`: the 2D renders correctly and **tile
overruns are massively reduced**. Third attempt at this module, first one to
survive the board.

### The defect

`char_data` is `p_dout[1][31:0]` - words 0 and 1 of the burst. Port 1 bursted
**four**. So every column fetched two 16-bit words that nothing ever read, spent
two CAS commands doing it, and the tile engine's ack waited for them to come
back before it could ask for the next column. The engine pays that round trip
248 times a line against a 3,936-cycle budget.

Fixing it is `blen(1) = 2`. The delivered value is bit-identical - `char_addr`
is `{tile_num,4'b0000} + {14'd0,map_y[2:0],1'b0}` and both terms have bit 0
clear, so the address is always 2-word aligned, and length 4 assembles `[31:0]`
as `{cap[1], cap[0]}` while length 2 assembles it as `{dq_r, cap[0]}` - both
`{word1, word0}`.

Length 2 was not expressible before. The capture assembled every non-single
burst as `{dq_r, cap[2], cap[1], cap[0]}`, hardcoding the last word at the top,
which is right for 1 and 4 and wrong for 2 and 3. Indexing that on the last
word's own tag is the whole enabling change, and the length-4 arm is the
default and bit-identical.

### THE PATTERN, which is the durable part

Three attempts at this module. The two that failed ADDED STRUCTURE; the one that
worked REMOVED WORK.

| Attempt | What it did | Board |
|---|---|---|
| 2026-09-05, second SDRAM port | added a port so two fetches could overlap | yellow rectangle, no sky or ground |
| 2026-09-07, next-scanline cache | added a cache to KEEP the discarded half | alternate scanlines missing |
| 2026-09-07, `blen(1)=2` | stopped fetching the discarded half | **good** |

**The discarded half was known before either failure.** The reverted cache
(`3a7c6b6`) is literally titled "Keep the half of every character burst that was
being thrown away" - the same observation, one week and two reverts earlier. It
led to a scanline cache with new ordering to get wrong, when the same fact
supported simply not fetching those words. The waste was treated as a resource
to exploit rather than as a defect to remove.

So when a measurement says work is being wasted, the first question is whether
the work can be *not done*, before it is whether the waste can be *used*.

### What still does not catch this class of bug

Nothing new. Every bench passed on both failed attempts and passes now, so the
benches did not distinguish the two that broke the board from the one that
worked. `tb_m1_video`'s blindness to both hardware failures is still open and
still unexplained.

What DID catch a real fault here was `burst_of()` in `tb_m1_sdram.cpp`, the
model's mirror of `blen()`. The RTL changed and the mirror did not, and the
suite failed immediately with 3,494 mismatches rather than letting a half-length
burst reach hardware as corrupt tile characters. Its comment already warned the
two must move together, from a previous drift; it now has a second instance.

### A hazard found while doing it

`build/mister/rtl` and `build/mister/Model1.sv` are **SYMLINKS INTO THE REPO**,
not copies. Editing RTL during a `make rbf` therefore edits the build's own
sources. It was survived here only because `quartus_map` - the sole stage that
reads `.sv` - had ended at 10:32:56 and the edit landed at 10:43:06, with
`quartus_fit` and `quartus_asm` working from the synthesis netlist. That is luck,
not design. Check `quartus_map` has ended before touching RTL mid-build, or do
not touch it.

---

## 2026-09-07 — THE CAPTURE DEPTH IS AN ALIGNMENT, NOT A MARGIN, and CL+2 is the only correct one

Measured on hardware, sweeping the SDRAM read phase option through all six
positions on the build at `0174f13`. **Every depth except CL+2 crashes the
CPU.** That includes CL+1 and CL+0, which had never been askable before this
build - the selector's floor was CL+2, so whether the window continued below it
was unobservable.

### What this corrects

It corrects a reading made ON THIS PAGE'S OWN LOGIC earlier the same day, and
the wrong reading is kept here because it is an easy mistake to repeat.

**The wrong reading:** "a healthy interface has a contiguous run of working
depths, so a window exactly one wide means we are clinging to the edge of it -
the capture is marginal and phase tuning is urgent." Model 2's own comment was
cited in support, since `m2_sdram` renumbers its selector specifically so that a
calibration sweep's pass mask reads as a *shape*.

**Why it is wrong:** a burst word is driven for exactly ONE SDRAM clock, which
is one `clk_sys` period. So exactly one `clk_sys` edge can ever fall inside a
given word's validity window, and a one-wide pass mask is the ONLY possible
result for a correct interface. `cap_depth` does not select how much margin the
capture has. It selects **which word of the burst is called word 0**.

The failure mode confirms it. A wrong depth does not produce noise, it produces
data shifted by a whole word, and `m1_sdram.sv` already records exactly that
from an earlier hunt: the assembled line came back shifted right by one 16-bit
word, and the V60's reset vector read `FE104E` where the ROM holds `4EF3D6`. A
word-shifted reset vector is a crashed CPU, which is what the board does on
all five wrong depths.

So CL+0 and CL+1 fail because the data has not arrived yet; CL+3 and above fail
because the bus has moved on to the next word. **CL+2 being uniquely correct is
the interface working as designed.**

### What it does NOT settle

Whether the capture has setup margin *within* its one-cycle window is a separate
question and is still open. The arithmetic on the SDC's own device numbers puts
data at the pin at 37.65 ns against a capture edge at 37.5 ns - nominally 0.15 ns
LATE, so it works only because the real `tAC` beats the pessimistic 6.4 ns the
constraints assume. The constrained build measured `SDRAM_CLK_pin` at +0.323 ns.

That is thin, and there is standing evidence it bites: a build whose only change
was a debug counter and a UART produced a garbage picture with +0.296 ns reported
slack and no new warnings. Shifting `phase_shift2` earlier than its present 6250 ps
(a plain 180 degrees, never tuned) buys margin at the same edge and would NOT
move the working depth, because it does not change which edge captures.

**But the one-wide window is not evidence for it.** Those are two different
questions and this entry exists because they were conflated.

### What the sweep was worth

The range extension stays. It cost nothing - `make test` counts were
byte-identical - and it converted "CL+2 is the shallowest we can ask for" into
"CL+2 is the only one that works", which are not the same statement. The
capture-depth knob is now settled and should not be looked at again.

Where the cycles actually are, since they are not here: `blen(1)=2` on the
character port (-2 cycles, and it stops discarding half of every burst),
skipping `S_DISPATCH` on a row hit (-1), `ACK_HOLD` 2->1 for same-clock ports
(-1), and the structural one - the single-outstanding-per-port contract at
`inflight[arb_grant] <= 1'b1`, which is what makes the tile engine latency-bound
rather than bandwidth-bound.

---

## 2026-09-07 — THE NEXT-SCANLINE CACHE BREAKS ALTERNATE SCANLINES, and no bench reproduces it

Second attempt at the tile engine's latency, second revert. Recorded because the
idea is sound, the measurement was real, and the failure is invisible in
simulation - which is now a pattern with this module rather than bad luck.

### What was built

`char_addr` points at the first of the TWO words holding an 8-pixel row and
port 1 bursts FOUR, so words 2 and 3 are the same tile's next row - exactly what
the next scanline needs - and `Model1.sv` read only `p_dout[1][31:0]`. The
engine kept the upper half in a 62 x 4 cache, keyed on the fetched ADDRESS so a
mid-frame `hscr` change could not produce a false hit.

Measured in the unit bench: **1,614 -> 1,182 cycles a layer per line.**

### What happened on hardware

**Every other scanline missing** - Ben's description: "almost like you would see
on 240p on a CRT". That is the cached lines specifically: even lines fetch and
draw, odd lines take the cached row and get nothing usable.

### What passed anyway

- `m1_tile_fetch`: 49,116 checks
- `m1_video`: **380,929 pixels over three full frames**, character memory filled
  with random data so a wrong row cannot match by accident
- the full suite, 54 harnesses

And then, trying to reproduce it, the video bench was given **variable latency
(8-40 cycles) and a two-cycle held ack**, matching what the real port does
against six other masters instead of a fixed 14 and a one-cycle ack. **It still
passed.** So the difference between bench and board is not the memory timing,
and it is not the data pattern.

### The other cost, and it is the same shape as last time

The first version read `cc_addr[cc_i]` combinationally. An asynchronous array
read makes Quartus build the memory out of flip-flops with a 248-way mux instead
of block RAM: **+1,300 ALM, 99% of the device, and one seed reported
`Error (11802): Can't fit design in device`.** Registering the read fixed the
inference - the arrays became `altsyncram` - but the design still sat at 98.2%
and only one seed in four closed timing.

### What this says

Two attempts, both green in every bench, both broken on the board:

| Attempt | Bench said | Board said |
|---|---|---|
| Two SDRAM ports | 1,614 -> 568 | yellow rectangle, no sky or ground |
| Next-scanline cache | 1,614 -> 1,182 | every other scanline missing |

**Do not attempt a third without a bench that reproduces a failure first.** The
right next step is not another fix; it is finding what the benches do not model.
`tb_m1_video` renders full frames against a reference with random character data
and variable memory timing, and it is still blind to both faults - so something
structural about the real system is absent from it, and that is the thing to
find.

---

## 2026-09-06 — THE SDRAM BUS IS 95% IDLE. "26% busy" was overhead, not data

Ben's challenge: ports starve while the bus reads 26% busy, and 26% of
160 MB/s is nowhere near the ceiling - so either the figure is wrong or the
setup is. He was right that the figure was wrong.

### The measurement

`dbg_occ`, which is what `O=` reports on the wire, counts cycles the controller
is **not in S_IDLE**. That includes dispatch, activate, tRCD, precharge and
refresh - overhead states in which the DQ pins carry nothing. It is not data.

A CAS command is the only thing that moves a word, so counting those against
elapsed cycles gives true bus utilisation:

```
SDRAM data cycles 6,420,000 of 120,957,803 = 5.30% -> 8 MB/s of 160 MB/s
```

**The bus is 95% idle.** Of the 26% the old metric reported, only about a fifth
was data.

### What it settles, both ways

**The setup IS inefficient.** A four-word burst costs six controller cycles for
four data cycles on a row hit, and eight to ten on a row miss. Bank interleaving
- activating one bank while another streams - would tighten that, and the
controller does not do it.

**And it does not matter.** At 5% utilisation there is no shortage to relieve.
The tile engine starves because it is SINGLE-OUTSTANDING: it issues one fetch,
waits about 18 cycles for the data, then starts the next. Its rate is set by
round-trip LATENCY, not by the bus. Give it the whole 160 MB/s and it fetches at
exactly the same speed.

That is the third time this session a bandwidth explanation has been offered for
a latency problem - after the SDRAM clock lift and the priority arbiter - and
the third time the measurement has refused it.

### What follows

The two-port character fetch was aimed correctly. It measured 1,614 -> 568
cycles a layer in the unit bench and broke the 2D on hardware for a reason never
diagnosed. **That is the thread to pull**, not the memory controller.

`O=` on the telemetry line should be changed to report data cycles rather than
non-idle cycles. As it stands it overstates bus use by about five times and it
has misled this project's reasoning more than once.

---

## 2026-09-05 — A QUAD TOUCHES 1.11 BANDS, SO BINNING IS THE CURE FOR THE DROPPED QUADS

Measured on real models out of the polygon ROM, 15,688 quads across 16 yaw
angles: **17,364 band touches, 1.11 a quad.** The guess going in was three.

### Why the number decides the architecture

The band renderer replays EVERY quad for EVERY one of the 24 bands and filters
on `band_range`. That is why the store has to hold a whole frame, and why
Virtua Fighter saturates it at 3,072 and discards **8,072 quads a capture**.

The store cannot grow: 211 bits a quad across two banks, so 3,072 -> 4,096 needs
about 42 M10K and a peak frame of 4,798 quads needs about 72. Seven are free,
and the display list buffers - the only large pool - turned out to be fully used
by Wing War. The sort key, the one fat field, cannot shrink because it is a
monotonic transform of the float z and MAME compares floats.

**Binning by band removes the problem instead of enlarging it.** Each quad is
written once per band it touches; each band reads only its own list. At 1.11
touches a quad a peak frame is ~5,300 entries, ~144 KB written and ~144 KB read
per frame, about **17 MB/s** against a 160 MB/s peak that currently sits 26%
busy. Three times fatter geometry than this bench's viewport would still be
~50 MB/s.

| | today | binned |
|---|---|---|
| Quad capacity | 3,072, hard | unlimited |
| On-chip store | a whole frame | one band |
| Band replay | every quad x 24 | own list x 1 |
| SDRAM | none | ~17 MB/s |

So it is not a trade. It removes the capacity limit, collapses the 24x replay to
1x, and RETURNS M10K rather than spending it.

**Caveat on the number.** 1.11 is real geometry under the bench's viewport, not
the game's camera. A road running to the horizon is a taller quad than anything
here. The board can measure it directly - `m1_quad_store` now counts band
touches and quads seen - and that should be read before the redesign is
committed to.

---

## 2026-09-05 — THE DISPLAY LIST BUFFERS CANNOT BE SHRUNK, and MAME runs all five games

Two results from the same evening, and the first would have broken a game.

### MAME runs every Model 1 game here

`vf` and `netmerc` are marked `MACHINE_NOT_WORKING` and both run correctly -
Virtua Fighter plays its attract demo, NetMerc reaches its title screen. The
flag is a curation stance about `BAD_DUMP` microcode, not a statement that the
machine fails. **Taking it at face value cost an hour of reading disassembly
while an instruction-level oracle sat unused.** Test the claim.

Virtua Racing stopped running here for an unrelated reason: `vr.zip` was
replaced on 2026-08-30 with a SPLIT set, and split sets need the BIOS ROMs as
separate archives. `vr_old.zip` is a merged set and still contains them.
`model1io.zip`, `m1comm.zip`, `model1io2.zip` and `hd44780.zip` were rebuilt
from files already present in `vr_old.zip`, `vf.zip` and `netmerc.zip`; the CRCs
match MAME's. All five games now run.

### The display list buffers are NOT spare memory

`m1_mainram` gives each of the two display list buffers the architectural
32,768 words, about **104 M10K of 553**, and `mame_dl_extent.lua` exists to
find how much is really used. Across all five games:

| Game | Highest word touched | of 32,768 |
|---|---|---|
| Virtua Racing | 16,383 | 50% |
| Virtua Fighter | 16,383 | 50% |
| NetMerc | 21,095 | 64% |
| Star Wars | 30,783 | 94% |
| **Wing War** | **32,767** | **100%** |

**Wing War uses every word of both buffers.** The region is not reducible.

Measuring only the two games that are easy to test would have said "halve it" -
VR and VF both stop at exactly half - and that would have broken Star Wars and
Wing War silently, in games nobody runs often enough to notice quickly.

The rules file described this region as "the one place a data cache could come
from". It is not, and that line needs correcting.

### What it was wanted for, and what that means

Virtua Fighter saturates the quad store at 3,072 and discards **8,072 quads a
capture**. The store costs 211 bits a quad across two banks - 128 of them the
four 16-bit vertex pairs - so 3,072 -> 4,096 needs about **42 M10K**, and
holding a peak frame of 4,798 quads needs about **72**. Seven are free.

The sort key is the only obviously fat field at 32 bits, and it cannot shrink:
it is a monotonic transform of the float z and MAME compares floats, so
truncating it reorders quads whose depths differ in the low mantissa.

So the store cannot be made big enough on this device. What remains is spilling
overflow to SDRAM - the controller is 26% busy, but band replay reads each quad
24 times, so it is roughly 75 MB/s of new traffic - or dropping SMARTER, since
the store currently keeps the first 3,072 quads and discards the rest
regardless of size or depth.

---

## 2026-09-05 — A SECOND FP DIVIDER BUYS NOTHING. Projection is serial per VERTEX, not short of dividers

Built and measured tonight, then reverted. Recorded because "add a second
divider" is the obvious read of the profile and it is wrong.

### The profile that suggests it

`tb_m1_geometry`: 488 cycles a quad against a budget of 83, and inside the
record `project` is outstanding **90.9%** of the time and the **sole cause
36.8%**. Nothing else is close - `xform`, `normalize` and `determinant` are
never the sole cause at all. So divide throughput looks like the lever.

### The measurement that refutes it

Two `fp_div` units in `m1_fp_pool`, issued round-robin from whichever is free
and retired in whatever order they finish:

| | cycles per quad |
|---|---|
| One divider | **488.2** |
| Two dividers | **493.9** |

Slightly WORSE, for the area of a second divider. The suite stayed green at
44,752 checks, so it is not broken - it is unused.

### Why

`m1_geo_project` computes **one reciprocal per vertex** - `div_a = ONE`,
`div_b = rz`, then two multiplies - and `in_ready = (rst_st == R_IDLE)`. It
accepts one vertex at a time and is busy for the whole 29 cycles. **There is
never more than one divide outstanding**, so a second unit has nothing to do.

That is the same shape as the tile fetch: latency times count, serialised. Not
a shortage of units.

### What would actually work

Let projection accept a second vertex while the first's reciprocal is in
flight. Then both dividers are used and the per-vertex cost roughly halves.
From the profile that is worth about **18%** - Virtua Fighter's geometry pass
1.55 frames -> about 1.28 - which helps the judder without curing it.

It is a pipelining change to a module verified at 20,037 checks, and the two-
port character fetch earlier the same evening shows what rushing that class of
change costs: both benches green, and the 2D broken on hardware.

**The pool's one-cycle grant mask stays regardless.** It is correct on its own
terms and it is the prerequisite that makes any second divider work at all -
see the entry above on why the 2026-09-04 attempt failed.

---

## 2026-09-05 — THE LEFT-SIDE 3D: WHAT IT IS NOT. Six candidate causes eliminated by measurement, and the remaining stage named

Ben's symptom, refined over the session: in gameplay the **left 40-48% of the
screen carries no 3D**. The road and the scenery are gone there; **cars on the
same side are drawn normally**. It gets worse on corners and persists while
parked at an angle. He believes it has always been the case.

Everything below is measured on the board unless it says otherwise.

### Eliminated

| Cause | How it was eliminated |
|---|---|
| SDRAM contention | tile port served in **18 cycles**, 2 waiting; controller ~29% busy |
| Coordinate wrapping in the quad store | `G=0` on every sample of every capture |
| Spans never reaching the left | `A=` — the fill emits **44.7%** of its pixels into the left half |
| The band memory losing them | `I=` — scanout reads back **46.3%** on the left. Write and read agree |
| Culling, clipping, projection | 16-yaw sweep vs `push_object`: 15,688 quads, **zero** differing |
| Over-culling | cull rate identical in the good and bad states, ~32,000/s both |
| The frustum's left plane | `Y=BF62` ~ -0.88. With x1=0, xc~248, zoomx~281 that puts the plane at screen x = **0**, where it belongs |
| Tile overruns causing it | an overrun repeats a 2D scanline and never touches the band buffer; misses ranged 0 to 2,175/s while the cut stayed put |

### What is left

The **mixer**. `poly_won` requires that no category-1 tile is in front of the
3D, which is correct - it is MAME's draw order, tiles 6/4/2/0 below and 7/5/3/1
above, and `m1_tile_decode` takes the category from `tile_word[15]` exactly as
`segaic24.cpp:56` does. So if a category-1 tile covers the left half, our mixer
is CORRECTLY suppressing the 3D and the fault is upstream of it.

`K=` and `G=` were repurposed to count pixels where the 3D was ready and a tile
beat it, per screen half. **Not yet read on a healthy build.**

### One reading that arrived and needs confirming

`w=0000 v=0000` on all 99 samples of the last capture - both tilemap pair
control words zero during play. If that holds, no window mode is configured at
all, the column-split theory is moot, and it raises a different question about
the 2D. The capture came from the build that was rolled back, so it is
suggestive rather than established.

### The hypotheses that were WRONG, and why they looked right

- **`a_left = 0`.** The arithmetic was sound: the left plane lands at
  `xc + a_left*zoomx + viewx`, which for a correct `a_left` is `x1 = 0` and for
  zero is `xc + viewx` ~ 248 - 48% of a 496-wide screen, exactly Ben's boundary.
  It also explained why near objects survive, since the test `p.x < p.z*a_left`
  scales with distance. `a_left` is the FIRST plane computed, so zero would have
  meant no recompute had ever run. The board said `BF62`. Right reasoning,
  wrong premise, and only hardware could say which.
- **Backface culling.** Fitted "large flat single-sided things vanish, closed
  objects do not" perfectly. Killed by an identical cull rate in both states and
  by the yaw sweep.
- **The left half being starved of spans.** `A=`/`Z=` were built to test it and
  answered 44.7%, which is not starvation. That counter was aimed at Ben's FIRST
  description - "the whole left side" - and his later detail, cars fine and road
  gone, changed the question underneath it.

---

## 2026-09-05 — THE TWO-PORT CHARACTER FETCH BROKE THE 2D, AND BOTH BENCHES PASSED

Reverted the same evening it was built. Recorded because the change is right in
principle, the measured win is real, and the next attempt needs to know what
caught it and what did not.

### What was built

The tile engine is latency-bound: strictly serial, `F_CHAR` raising `char_req`
and stalling for the whole round trip, once per column, 248 times a line. The
fix was two SDRAM ports alternating with a two-entry hand-off queue, keeping
`m1_sdram`'s single-outstanding-per-port contract intact rather than relaxing a
module verified at 87,893 checks.

**In the unit bench it worked**: 1,614 -> 568 cycles per layer per line, so four
dense layers cost ~2,270 against the 3,936 a scanline affords. That is the
number `m1_tile_fetch`'s own header predicted for this change.

### What happened on the board

A flashing yellow rectangle, sky and ground missing. `M=` saturated at `0xFFFF`
- the tile fetch missing deadlines continuously - and `Q=` at zero.

### What passed anyway

- `m1_tile_fetch`: 49,116 checks green
- `m1_video`: 380,929 pixels compared, green
- `tb_m1_frame`: no regression

A unit bench that models two ports with independent latency counters cannot show
what two REAL SDRAM masters do to each other through a shared arbiter, a shared
open row and a refresh cycle. And `tb_m1_frame` reproduces **zero** tile
deadline misses once the ROM load is excluded - all 9,434 of its misses happen
during the download - so the bench that should have caught it does not
reproduce the fault at all.

**Before this is tried again, build a way to see the failure off the board.**

### It also walked into the oldest trap first

The two ports are independent masters and the arbiter may grant them in either
order, so port 1 can return before port 0. `char_ack` is held only two cycles,
so an out-of-order ack arriving while the retire pointer watched the other port
was lost. The frame bench went 9,434 -> 36,867 misses and that one it DID catch.
Fixed by latching each port's completion the cycle it happens. *Acknowledges
must be held, not pulsed* - recorded twice before, three times now.

---

## 2026-09-05 — WHY THE SECOND FP DIVIDER FAILED, AND WHAT ACTUALLY LIMITS 3D SPEED

### The profile

`tb_m1_geometry`: **488 cycles a quad against a budget of 83**, and a peak frame
of 4,798 quads would need **286% of a frame**. Inside the record:

| Stage | Outstanding | Sole cause |
|---|---|---|
| **project** | **90.9%** | **36.8%** |
| tgp_ram | 22.9% | 0.1% |
| xform | 21.4% | 0.0% |
| normalize | 11.3% | 0.0% |
| colour | 10.3% | 1.4% |
| determinant | 2.1% | 0.0% |

Projection is the bottleneck and nothing else is close. `xform`, `normalize` and
`determinant` are NEVER the sole cause, so speeding them up buys nothing.
Projection is the perspective divide - eight divides a quad - so **divide
throughput is the only lever on 3D speed worth pulling**.

### Why the second divider made things worse, and it was not the divider

Grants in `m1_fp_pool` are combinational. A client's "I have been granted" flag
is necessarily REGISTERED - it cannot see the grant until the next edge - so its
request is still asserted during the grant cycle itself.

With one divider that costs nothing: the divider is busy for up to 29 cycles
afterwards and the stale request cannot win again. **The moment a second divider
exists the other one is free, the stale request wins immediately, and every
division is issued twice.**

It is not the client's bug either: gating `m1_geo_project`'s `div_req` on
`div_gnt` closes a combinational loop through the arbiter - request feeds the
winner pick feeds the grant.

**Fixed in the pool**: a client is masked for one cycle after being granted. NC
flops, no throughput lost because clients are single-outstanding. This changes
nothing today and that is the point - it is the prerequisite that lets the
second divider land.

---

## 2026-09-04 — THE LAYER BLEND ORDER IS THE SAME FOR EVERY MODEL 1 GAME, and the above-HUD 3D pass is NOT implemented

Asked because NetMerc's attract screen draws 3D over the `INSERT COIN` glyphs
and that looked like a layering fault. Two facts, both read off MAME.

### There is one blend order, not one per game

`model1.cpp:1835` sets `screen_update_model1` once, in the shared machine
config, and nothing overrides it. Every Model 1 game composites identically
(`model1_v.cpp:1846-1868`):

```
fill with pen 0
tiles 6, 4 opaque, then 2, 0        <- category 0
tgp_render(RENDER_BELOW_HUD)        <- the 3D
tiles 7, 5, 3, 1                    <- category 1
build_overlay_mask()
tgp_render(RENDER_ABOVE_HUD)        <- command 0x41 only
apply_overlay_stencil()
```

`segaic24`'s `draw(layer, ...)` splits its argument as `tpri = layer & 1` and
map `= layer >> 1`, so those eight calls are FOUR TILEMAPS EACH DRAWN TWICE -
once for the tiles whose category bit is clear, once for those where it is set.
Every tilemap therefore has tiles on both sides of the 3D.

**Ours matches.** `m1_tile_mixer` resolves cat1 tiles above the polygon layer
and the polygon layer above cat0, and `m1_tile_decode` takes the category from
`tile_word[15]` - which is what `segaic24.cpp:56` reads:
`tileinfo.category = (val & 0x8000) != 0`.

So a glyph buried under the 3D is a glyph whose category bit is clear, and MAME
buries it too. Whether NetMerc's attract frame is correct is a question for a
reference snapshot, not for the mixer.

**2026-10-29: the NetMerc symptom was not the blend order.** NetMerc's
gameplay lists carry three viewport groups and MAME sorts each separately;
the core sorted the whole frame as one, and the "HUD" it covered is itself 3D.
See the 2026-10-29 entry. The blend order above still stands.

### The ABOVE-HUD pass is a real gap

MAME renders the 3D **twice**. Objects with command `0x41` are held back and
drawn after the HUD tilemaps, through a stencil that only lets them through
"background" HUD pixels. MAME's own comment names the case: **SWA radar blips**.

`m1_listwalk` knows the opcode exists - there is a comment about dispatching on
it - but nothing in this design separates the two passes, and the mixer has a
single `poly_valid` input. So a 0x41 object renders BELOW the HUD and is hidden
by it.

That is the opposite of the NetMerc symptom, so it explains nothing there. It
will bite **Star Wars Arcade**, which is the game the MAME comment is about, and
it is now on record rather than being rediscovered from a missing radar.

Not scheduled: it needs a second polygon layer or a per-pixel stencil through
the mixer, and no game we can currently run needs it.

---

## 2026-09-04 — THE 103-CYCLE CHARACTER FETCH WAIT IS 18 CYCLES. The famous unexplained number was an average taken across the ROM download

`HANDOFF.md` item 6 has recorded since M1 began that a character fetch waits an
average of **103 cycles**, that this is "far more than a round-robin turn
between three active ports should cost", and that it is "not understood". It
said to find out where the time goes before changing `m1_sdram`.

**The time was never going anywhere. The measurement included the ROM load.**

`tb_m1_frame` counted from reset, and for the first tens of millions of cycles
the loader is streaming the ROM image into SDRAM through the dedicated write
port - which sits unconditionally above every read port, deliberately, because
game logic is held in reset during download. Averaging the tile port's wait
across that phase describes a machine that is not running.

Gated on `loader_done`:

| | Ungated | Gated on the load finishing |
|---|---|---|
| Total wait per fetch | 217 cycles | **18** |
| Waiting for a grant | 200 | **2** |
| Being served | 15 | 15 |
| Idle-but-not-granted, write port winning | 95% | **0%** |

Two cycles of arbitration is as good as this controller can do. The wait is the
transfer itself.

### How the error was caught, which is the transferable part

By a fix that did nothing. The ungated split pointed at round-robin, so the tile
port was given strict priority over the other six - and the figure moved by
**nothing at all**, 200 cycles before and 200 after. A change that cannot move
the number it targets is aimed at the wrong thing, and that is what prompted
gating the counter rather than trusting it.

The second wrong cause came from the same contaminated data: with priority in
and nothing changed, a state histogram said 70% of the wait was spent in write
and write-recovery, and 95% of the idle-with-request-pending cycles went to the
write port. True, and entirely the download. Counting how many of those
happened **after** `loader_done` returned zero.

The priority arbiter was **reverted**. It was justified by a contaminated
measurement, it adds logic to this design's worst timing path, and the clean
number says arbitration costs two cycles.

### What this rules out

- **The SDRAM is not what causes the tile overruns.** The port is served in 18
  cycles and still misses 9,434 deadlines in the run. Neither faster memory nor
  better arbitration can recover time that is not being lost there.
- **The 133 MHz clock lift is not the fix for this defect either.** Its case now
  rests on the geometry pass and on nothing else measured.

### Where the overruns actually come from

`m1_video.sv` has said so all along, in the comment beside the overrun counter:
a line's worth of fetching is 3,936 core cycles and **four dense layers need
about 6,456**. That is the fetch engine's own emission and per-column cost, not
memory latency. The repairs are fewer fetches per line or overlapping them -
wider bursts, or more than one request in flight, which is the one place the
N64 controller's FIFO-and-`reqprocessed` shape genuinely applies here.

---

## 2026-09-04 — THE TILE OVERRUNS ARE REAL AND THE SDRAM IS NOT THE CAUSE. The memory has 70% of its cycles free while the tile port misses 2,175 deadlines a second

Ben's reading was that the tile overruns and the 3D dropout together point at
the memory controller, and that raising the SDRAM clock to 133 MHz is the fix.
The overruns are real — his eye was right again. The bandwidth attribution is
not, and the same capture says so.

### What was measured

Two counters were added to `m1_sdram` and put on the UART, because nothing in
this project had ever measured memory occupancy on hardware. `bw_monitor` has
existed for months and its numbers only ever reached simulation.

- `O=` — cycles the controller is not in `S_IDLE`, over a 2^20-cycle window
  (13 ms at 80 MHz), as a fraction of 0xFF.
- `Q=` — cycles port 1, the tile character fetch, is pending, same window.
- `M=` — the tile fetch's deadline misses, free-running. This counter already
  existed and had never reached the wire: it was a row on the debug overlay,
  which is off.

148 seconds of gameplay, seed 11 build, `13a584c58a408e942d9f51d98285ec1e`.

| Second | Misses/s | Controller busy | Tile port pending |
|---|---|---|---|
| 0-2 | 1-6 | 38-40% | 31% |
| 3 | 394 | 32% | 40% |
| 4-12 | **2,165-2,192** | **30-33%** | **37-42%** |
| 13 on | 10-85 | 18-38% | 11-26% |

At 57.5 Hz and 384 lines that burst is about **10% of every scanline in the
frame overrunning**, which is more than enough to be the visible 2D corruption.

### The number that settles it

**Busy went DOWN as the misses went UP.** Occupancy fell from 40% to 32% over
exactly the seconds when misses rose from 1/s to 2,175/s, while the tile port's
pending time rose from 31% to 42%. A bandwidth wall does the opposite: the
controller saturates and everything queues behind it. Here the controller did
LESS work while one port waited LONGER.

The controller has **68 to 70 percent of its cycles idle** throughout. There is
no shortage of memory cycles to find. A faster clock multiplies capacity that is
already unused.

### What this means for the 133 MHz plan

It is not the fix for this defect. It may still be worth doing for other
reasons, but it must not be justified by the tile overruns.

Two other measurements from the same builds bear on it, both from the seed
reports rather than argued:

- `SDRAM_CLK_pin` has **+9.4 to +11.4 ns of slack against a 12.5 ns period**.
  The pin paths take about 3 ns, so the physical interface would still hold
  roughly 4.5 ns of margin at 133 MHz. The interface is not the limit.
- `clk_sys` closes at **+0.549 ns**, an 11.9 ns critical path. That domain
  carries the 2D video path and the loader as well as the controller, so it
  cannot simply be sped up. The memory would need its own domain — which is
  what Ben proposed — and whether the controller's own logic closes at 7.5 ns
  is not yet known.

### The prediction that came true

`HANDOFF.md` item 6 has recorded since M1 began that a character fetch waits an
average of **103 cycles**, that this is "far more than a round-robin turn
between three active ports should cost", that it is "not understood", and that
it "will matter when the rasterizer joins the same controller". The rasterizer
now shares that controller and the wait has become deadline misses. The item
said to find out where the time goes **before** changing `m1_sdram`. That is
still the right order, and it is now the blocking question rather than an
efficiency note.

The shape of the answer is constrained by the data: a port that is pending 40%
of cycles while the controller is idle 70% of them is spending its time in
handshake, not in service. A row-hit burst on this controller is six cycles.
103 is not six.

### What is NOT the cause, measured in the same capture

- **Not the 3D frustum.** `K=` reads `0000` on every one of the 148 samples, so
  no clipping is discarding the geometry. That was the competing explanation for
  the left-half dropout and it is struck off.
- **Not the fetch bandwidth alone.** See above.

---

## 2026-09-03 — THE MISSING 3D IS A THREE-FRAME PASS CADENCE. The producer runs over a frame, and the design then lost a frame on every pass

Fixed in `m1_raster3d`: the geometry pass now starts when the game presents a
new display list, not on the frame pulse. Built and measured in two benches;
the board is owed a flash. Everything below is measured.

### The board said which sequencer, and it was read the wrong way round

Three UART counters, from the 2026-09-03 captures, per one-second line:

    S   display-list swaps, the game's logic frames    27-29
    B   completed geometry passes                      19-20   (2/3 of S)
    N   bands PRESENTED                                1,392 = 24 x 58, every frame

N is the decisive one. `swap_now` needs three things at the blanking edge:
P_READY, C_IDLE and the edge. The consumer restarts its sweep on that same edge
and can only do so from C_IDLE - so 24 bands every frame means the consumer is
idle at every edge, without exception. **The only term that can be missing is
P_READY. The producer is late, not the consumer.**

The earlier entry below measured the consumer in exhaustive detail - sweep at
92.4% of a frame, idle 81% of it - and concluded the pipeline was healthy and
the defect did not reproduce in simulation. Both figures were right and both
were about the sequencer that was never late. Nothing had measured the
producer's pass length.

**WITHDRAWN, and reverted in this change: the "one-cycle swap window" fix
(fba1219).** It let the swap happen anywhere in blanking instead of on the
edge. The consumer leaves C_IDLE on the edge and does not return until the
sweep ends, so "anywhere in blanking while the consumer is idle" is the edge
cycle and no other: the change was a no-op by construction, and N had already
proved the race it was written for was not being lost.

### Why a pass over one frame costs three

    frame_start  (vblank_start, line 383 at hcnt = H_VISIBLE, over m1_cdc_pulse)
    swap         (vcnt reaches 384, two synchroniser flops)   ~470 clk_3d LATER

The producer started only on `frame_start`, and was freed only by the swap,
which is after it. So:

    pass < 1 frame:   start k, ready k+0.x, swap at the k+1 edge, start k+2
                      -> 2 frames a pass, equal to the game's list rate. B = S.
    1 < pass < 2:     start k, ready k+1.x, the k+2 edge swaps it out, and the
                      next frame_start is k+3 -> 3 frames a pass. B = 2/3 S.

58 frames a second / 3 = 19.3. That is the board's B.

### The pass IS over a frame, measured three ways

`tb_m1_raster3d`, the reference's frame 900 (33 objects, 626 quads), now with
a `ROM_LAT` knob on the polygon ROM and a per-pass cadence print:

    ROM latency   pass length   cadence (old)   cadence (fixed)
    1 cycle       0.95 frames   2               2
    8             0.95          2               2      the prefetch hides it
    24            1.27          3               2
    32            1.54          3               2
    64            2.90          4               -
    256           11.40         13              -

**0.95 of a frame with a memory that answers in a cycle.** The board's polygon
ROM is SDRAM shared with the V60 at 2:1, the tile fetch and the coprocessor; it
does not answer in a cycle.

`tb_m1_frame`, the real memory path, with the producer's pass timed from its
state (start = P_IDLE->P_WALK, ready = ->P_READY, swap = P_READY->P_IDLE),
900 M cycles of the old RTL, in the attract scene at 57-58 objects and ~1,650
quads:

    PASS3D #187 start=f368 len=1.47 fr wait=0.52 fr obj=58 q=1653
    PASS3D #188 start=f371 len=1.46 fr wait=0.53 fr obj=58 q=1669
    PASS3D #189 start=f374 len=1.47 fr wait=0.52 fr obj=58 q=1653
    PASS3D #190 start=f377 len=1.46 fr wait=0.53 fr obj=57 q=1660

A pass every three frames, each 1.47 frames long. **The defect reproduces in
simulation.** It always did; the instrument that showed it is a hundred lines
of bench. The whole 900 M-cycle run, old RTL:

    passes                       292   (303 list swaps)
    over a frame                 101
    cadence, start-to-start      1 frame: 39   2 frames: 152   3 frames: 101
    pass length, tenths of a fr  0: 173 (boot, empty lists)   13-15: 100 (attract)
    3D ROM port                  492,038 requests, mean wait 255 clk_sys cycles

Every pass over a frame cost three, to the pass. And the last line is the
next lever: the polygon ROM port waits 255 clk_sys cycles - 150 clk_3d - per
request on the shared controller. `rom_req` is a level held over a prefetch
burst, so that is per burst rather than per word, but the unit bench puts a
one-cycle memory at 0.95 frames and a 24-cycle one at 1.27; the board's memory
is where the other half-frame comes from.

The same 900 M cycles on the FIXED RTL:

    passes                       329
    over a frame                 150
    cadence, start-to-start      2 frames: 300   (1: 19, 3: 2, 4: 4, 5: 1, 0: 3)
    bands presented per frame    24 on 668 of 669
    WORST band fill              36,976 cycles, 108% of a band's beam slot

**And on the board, 2026-09-03 evening, seed 7 of ef6adce** (`build/uart_flipfix_seed7.txt`):

    S=001D  B=+1D..+1F  per second      B now equals S; it was 2/3 of it
    L=11xx..1Axx                        passes of 1.35 to 2.15 frames

The rate is fixed. Ben still sees overruns on the screen, so the rate was not
the whole picture.

### The overruns that remain are LATE BANDS, and they are the fill, not the pass

Second build (8e5e3d6, seed 7, `build/uart_late_seed7.txt`) adds T= (bands
presented after the beam had started on them, free-running) and W= (the worst
band fill in the second, in 16-cycle units; a slot is 0x0853):

    attract, 85-100 objects     T +3..+4 a second     W 0x0B00-0x0E3B  (1.3-1.7 slots)
    one second at 158 objects   T +23                 W 0x0C54

A late band shows as a horizontal strip with no 3D: scanout refuses rows the
presented band does not cover. Three buffers absorb one slow band, not a run
of them. `tb_m1_frame` at 900 M cycles (attract at ~25 objects) shows ZERO late
bands and a worst band of 108%, so the bench is not yet in a scene heavy
enough to see it; the board is.

**The reference's peak frame, 1020** (5,831 polygons in 41 objects by
`tools/mame_poly_budget.lua`, which now names the frame; dumped with
`DUMP_FRAME=1020 tools/mame_run.sh tools/mame_dump_frame.lua`, into
`build/mamerun/framedump/`), through `tb_m1_raster3d`:

    walked                 38 objects, 1,022 quads after culling and clipping
    pass                   1.26 frames WITH A ONE-CYCLE ROM (P_OBJW 54%)
    worst band fill        25,150 cycles, 74% of a slot; no late bands
    fill unit, by state    DIVAW+DIVBW 49%   FS_WALK 31%   everything else 20%
                           26,653 divides a side at 15.6 cycles each

So even the reference's heaviest sampled frame does not make a band late in
the bench, and the board reaches 1.3-1.7 slots in attract at 92-158 objects
(P=) - scenes heavier than any the 60-frame sample caught. **The divider is
half the fill.** `m1_raster_div` is radix-4 at 16 cycles and every quad-band
pays two of them serially (DIVA then DIVB). A pipelined divider, or issuing
A and B to two dividers at once, takes ~25% off every band; a reciprocal
table takes nearly the whole 49%. That is the next build, and T= and W= on
the board are its acceptance test.

**Built (a207c47): a second divider, both slopes issued at once.** Frame 1020
fill busy cycles 1,690,507 -> 1,332,363, exact (152,025 checks). But the
WORST band only went 25,150 -> 23,865, and its own breakdown says why:

    band 11 of frame 1020    23,865 cycles, 70% of a slot, 560 quads replayed
    divider wait             9,519   40%    501 segments x 19 cycles
    span walk                4,463   19%
    fixed per-quad states    ~4,900  20%    CLASSIFY, START1/2, LOADX, DIVA,
                                            DECIDE, FS_ENTER/END, FINAL, DONE
    the band clear           1,985    8%

42 cycles a quad, and 560 quads in one band because every quad is replayed
into every band it touches - the stadium and the road touch most of them.
The board's worst bands run 1.3-1.7 slots, so its pit-stop scene carries
about twice the quads a band of the reference's frame 1020, which the 60-frame
sample (frames 20-1600) never reached. The levers, in order of size: the
divide (radix-8 or -16, or overlapping the next quad's divides with this
quad's walk), the ten single-cycle states a quad, and a wider clear.

Sampled across the whole attract loop (`SAMPLE_UNTIL=7000`, 350 frames), the
polygon peak is frame 5460: 6,324 polygons in 45 objects, mean 4,661 in 69.
Through the bench (`build/framedump/frame5460/`): 1,352 quads walked, worst
band 26,808 cycles = 79% of a slot with 624 quads replayed, and the divider
wait is **47%** of it even with two dividers - 663 segments at 19 cycles,
because a band-clipped quad is almost always ONE segment, so the two slopes
are a quad's whole divide and parallelism past two buys nothing. The walk is
2,593 cycles: 4 a quad. So a quad in a heavy band costs ~40 cycles of which
~19 is one 16-step divide and ~12 are single-cycle bookkeeping states, and the
board's heavy bands carry ~2x these quads.

**The lever is the divide's LATENCY, not its count.** dy is an integer edge
height in scanlines and dx a pixel difference, so a 1/dy table (one M10K,
1,024 entries) and one DSP multiply, with a single remainder correction to
keep the quotient exactly truncated, makes it ~4 cycles. That and merging the
bookkeeping states roughly halves a heavy band. tb_m1_raster_fill's 152,025
exact checks are the gate; T= and W= on the board the acceptance test.

### THE MISSING GRANDSTAND IS THE QUAD STORE OVERFLOWING - 2026-09-03, late

Ben's photographs of the attract pit stop show the grandstand absent behind
the crew, in every frame of that scene, with the crew, car and road drawn.
Build 9e242f8 (seed 3, `build/uart_vblwait_seed3.txt`) adds D=, quads the
store could not hold summed over passes, and H=, passes that walked fewer
than half the previous pass's objects:

    D=  +400 to +10,000 a second, continuously      the store overflows every pass
    H=  +1 every few seconds                        passes are not short: the walk is complete
    T=  +2..+3 a second, bursts of +16..+31         late bands, as before
    W=  up to 0x10B6                                the worst band at 2.0 slots

`m1_quad_store` holds NQ = 2,048 quads a bank and drops everything after that
- the TAIL of the list, which is where the game puts the grandstand. MAME's
walk of the pit scene finds 161 objects and 5,582 polygons; after the
backface test that is well over 2,048. So the stadium is not culled and not
dropped for a frame; it never fits. H= says the list is walked completely,
which also rules out a half-written list, and the vblank wait added in
9e242f8 is therefore belt and braces rather than a fix.

The store is 51 M10K a bank at 2,048 (vertices 26, key 8, attributes 10,
indices 5), two banks. 3,072 a bank is ~+50 M10K, all of the 58 free and the
sound section's budget. `MISTER_SMALL_VBUF` was the framework's supposed lever on
M10K. **Measured: it frees NOTHING.** 496 of 553 M10K with it and without it
(par_13 vs par_3 of the same design); it changes the size of the scaler's
DDR3 frame buffer, not fabric memory. Struck off. The M10K for a bigger
store comes out of the sound budget or out of the quad record's width.

**PROVEN IN THE BENCH.** Frame 2500 (the tyre change, found by snapshotting
the attract loop every 250 frames - `build/render/attract_sheet.png`) dumped
with the corrected active-list choice and run through `tb_m1_raster3d`:

    objects walked            158 of 158, every ROM address matching MAME's walk
    quads the geometry emits  2,671   (MAME: 5,485 polygons before the backface test)
    store capacity            2,048   -> 623 quads dropped, the tail of the list
    object 156 (grandstand)   1,163 polygons -> 397 quads, LAST in the list
    picture at NQ=2,048       crew, car, tyres; no building, road, wall or stand
    picture at NQ=4,096       everything, matching MAME's snapshot of the frame

`build/render/frame2500_ours.png` against `frame2500_nq4096.png` and
`frame2500_mame.png`. NQ is a parameter of m1_raster3d now
(`make render3d VFLAGS="... -GNQ=4096"`). "dropped 0" in the bench's summary
is read from the bank that has just been cleared and means nothing.

The cost of the bigger store also lands on the FILL: the worst band of that
frame goes 112% -> 121% of a slot at 4,096, because every stored quad is
replayed into every band it touches. The store and the divider are one
budget, not two.

**THE TWO DIVIDERS ON THE BOARD (a207c47 seed 3, `build/uart_twodiv_seed3.txt`,
110 s of attract including the pit stop): T= 0. Not one late band**, against
+2..+3 a second with bursts of +16..+31 on the build before it
(`uart_vblwait_seed3.txt`, same scenes, same D= and L=). W= still reaches
0x0F8E - the worst single band at 1.9 slots - but the ring absorbs one slow
band, and what made bands late was RUNS of them; 21% off every band's fill
took the runs under the line. Whether the bars are gone to the eye is Ben's
to confirm.

### THE STORE IS 4,096 QUADS NOW, for +32 M10K - narrowed and split, measured

Three things made the record smaller, each checked exact:

- **Vertices are 9+9 bits, not 16+16.** tb_m1_raster3d now prints the
  post-clip coordinate range: 0..495 and 0..383 on frames 900, 2500 and
  5460. The clipper delivers screen coordinates. Anything outside is a
  contract violation, counted in the store's `dbg_oob`.
- **Colour is RGB565 in the store.** The band buffer keeps exactly those bits
  (`span_565` in m1_raster3d), so the 24-bit value was 8 bits of nothing.
- **The band mask is a band RANGE**, 5+5 bits instead of 24, computed from
  the full 16-bit inputs before they are narrowed so off-screen quads still
  land in no band.

And one thing Quartus does that the arithmetic did not predict: **any array
deeper than 2,048 goes into the 4,096 x 2 block mode**, so a 3,072-deep
32-bit key cost 16 blocks where 2,048 x 32 costs 7. Every array is now split
explicitly into a 2,048-deep half and the rest, selected by the top address
bit. The index array's two readers (sort and replay, never concurrent) share
one read, which removed a duplicate memory that had been there all along.
`make quartus MOD=qs<n>` with a wrapper in build/tmp, per bank:

    NQ       old record   narrowed, unsplit   narrowed, split
    2,048    52           37                  34
    3,072    -            84                  53
    4,096    -            84                  68

Two banks at 4,096: 136 blocks against 104 today, **+32 net**, 25 to spare.
`tb_m1_quad_store` 18,500 checks exact; pictures bit-identical at 2,048 on
three frames and at 4,096 identical to the earlier 4,096 render (frame 2500:
149,355 pixels, the whole scene). ALM went 1,046 -> 921 for the store.

Three replay-pipeline mistakes on the way, all caught by the store bench's
second position: the vertex read must be addressed a cycle early (q2, not
q); the attribute read is stage two and must hold under the stall gate; and
so must the index read, because pi advances in the cycle the read is taken.
A free-running registered read is NOT the same as a gated one when the
address moves on.

### WHERE THE STORE AND THE VERTEX WIDTH LANDED, after three board tests

The 4,096-quad store needed 9-bit vertices to fit, and **9 bits was wrong**:

- Truncated, a vertex the clipper puts at -1 wraps to 511 and the polygon
  stretches across the screen. On the board that was cars smeared over the
  whole picture, on two seeds.
- Saturated, the picture looked right to Ben - but `tb_m1_frame` counts
  **6,588 vertices outside 0..511/0..383 in 670 frames** and the board
  counted thousands a second on the wire (H= carried the store's `dbg_oob`).
  Every one of those is a polygon edge bent at the screen boundary instead
  of clipped. It looked good because the bend is small at speed.
- The three dumped frames (900, 2500, 5460) had NO out-of-range vertex,
  which is why the bench blessed 9 bits. **Three frames is not the range of
  a coordinate.** The frame bench now prints the range over a whole run:

      vertex coordinates, 670 frames   -104 .. 495
      quads with vertex 0 off-screen   10,246
      out-of-range at 16 bits          0

  And the cost of saturating them is measurable in the picture: the same
  900 M-cycle run paints **68,531,903 non-black pixels with 9-bit saturated
  vertices against 68,990,178 with 16-bit** - 458,275 pixels different over
  670 frames, which is the bent edges, about 680 pixels a frame.

So vertices are 16 bits again and the store is **3,072 a bank**, the largest
that fits: ~74 M10K a bank, 532 of 553 in the full core. Frame 2500 needs
2,671 and draws complete. **D= is not zero at 3,072** - the board's attract
drops in bursts, ~1,600 quads over a 110 s window - so some scenes still
exceed it, and the tail of those lists is not drawn. Ben's eye says the
picture is right, so what is dropped is small or distant; the number is on
the wire if it ever matters.

What DID pay for the bigger store, all exact: the arrays split at 2,048 deep
(Quartus's 4,096 x 2 block mode is half the density), colour as the RGB565
the band buffer keeps anyway, the band mask as a 5+5 range, and one read per
array.

### What the game does at a flip, measured, because the fix depends on it

`tools/mame_flip_writes.lua`, 2,000 frames, 994 flips. The flip is the V60's
write of listctl bit 3 - manual mode - not a vblank event.

    writes into the NEWLY SELECTED buffer, flip -> next vblank    0 on 992 of 994
    writes into the SELECTED buffer, flip -> next flip            0 on 992 of 994
    first write into the OTHER buffer                             one frame after the flip, 992 of 994

The two exceptions are the boot/attract transition. So the buffer the game
flips TO is finished when it flips and untouched until the next flip; the next
list is built in the other buffer starting a frame later. The flip's scanline
was not captured - `screen:vpos()` failed under pcall - so where in the frame
it lands is not known. (Run made with the device-ROM overlay, as always.)

### The fix

    prod_trig = list_flipped || (frame_start && no flip seen for 4 frames)

where `list_flipped` is the synchronised select differing from the one the
current pass latched. Starting at the flip is what MAME effectively does
(`set_current_render_list` at the next render) minus the wait for vblank, and
it fixes the PHASE as well as the rate: a pass finishes before the game flips
again and starts rewriting the buffer it read, for any pass up to two frames.
Restarting on the swap alone was considered and rejected - it locks a two-frame
cadence to the game's two-frame flips in whichever phase it lands, and the
wrong phase reads a buffer the V60 is writing for the tail of every pass.

The frame-pulse path is kept for a list that never flips (a bench, or a game
that single-buffers), held off while flips are arriving so it can never
pre-empt one by a few cycles.

Unit bench: 189,427 of 190,464 pixels painted, unchanged at every setting.

### Two instruments, and one bench fault

- `L=` on the UART: the last pass's length in units of 256 clk_3d cycles. A
  frame is 0x0C7C. The board can now say directly whether a pass fits.
- `tb_m1_frame` prints `PASS3D` per pass and, at the end, pass length and
  cadence histograms and the 3D ROM port's mean wait.
- `tb_m1_raster3d` held `frame_start` for the pixel's three clock ticks. The
  board delivers one, through m1_cdc_pulse. Three counted as three frames and
  tripped the four-frame fallback early - a bench artefact that looked like a
  one-frame cadence.

### What this does NOT fix

A pass over TWO frames still costs three, and its tail reads a buffer the game
has begun rewriting. The board's B fell to 14-18 at 157 objects (the crash
captures), which is passes of 2-3 frames in busy gameplay. The lever there is
the pass length itself: the polygon ROM's wait on the shared SDRAM, and the
geometry's cycles per quad. `L=` measures the first; the bench's ROM-port wait
measures the second.

### Test suite

`make test` is entirely green. Three lines differ from the block in the rules file,
none from this change: `v60_alu` and `v60_shift` were added on 2026-09-02 and
never entered; `m1_sdram`'s counts moved with an arbitration change before
today; `m1_copro_if` went 259 -> 261 with the both-FIFOs-full proof (520cf6a). The block
is corrected in this commit.

## 2026-09-04 — FFE59C IS NORMAL IN GAMEPLAY, and the crash is ATTRACT-ONLY

Three corrections, all from Ben watching the board while the telemetry ran.

**Gameplay does not crash. Attract does.** Every capture of the five-minute
freeze until now was taken in attract, and "the core crashes after five
minutes" was drawn from those. Playing the game it does not happen. Whatever
corrupts the copier's length is something ATTRACT does, which narrows the
hunt enormously.

**V=FFE59C is not by itself a crash.** The 2026-09-01 entry has it as "RARE
in normal running - 3 of 657 samples", measured in attract, and I read a long
run of it during gameplay as the freeze. It is not: the V60 sat there for
many consecutive samples while completing 29 display-list swaps a second, at
full speed. It is a block copy the game performs constantly and a
once-a-second sample lands in it often. The reliable signature is the TGP's
retire count FROZEN together with P=0000; the address alone will send the
next reader after the wrong thing, as it just sent me.

**And the stall pc is not always FE0C9B.** The 2026-09-03 entry calls the
crash deterministic on three attract captures that agreed. Gameplay gives
X=FE15FA. Three agreeing captures were evidence that attract reaches the
state one way, not that the state has one cause.

## 2026-09-04 — THE LEFT-HALF DROPOUT IS NOT THE QUAD STORE EITHER

Measured on the board while Ben played and saw the fault about ten times:

    objects            34-53 normally, 157-161 in the heaviest scenes
    quads dropped      ZERO, apart from one burst of 287 in two minutes
    logic frames       29 a second throughout - full speed
    bands late         3-4 a second
    worst band fill    45-90% of its slot

So it is not overflow, not starvation and not late bands. It also persists
while the car is STATIONARY, which rules out anything transient. Both
hypotheses so far are dead: the 2D window mode (ruled out because it varies
with load) and the quad store (ruled out because D= stays at zero).

### The hypothesis that fits all three observations: a LATCHED VIEWPORT

Ben's photograph plus "it happens more on corners" plus "I am stopped and it
is still there" only fit one shape: a register that latches a bad value
during a busy frame and keeps it.

`m1_raster3d` latches the viewport from display-list command 3 - vxc, vyc,
vx1, vx2, vy1, vy2 - and `m1_geo_clip` turns those into the frustum's left
and right planes and tests every vertex against them. A wrong vx1 clips
everything left of it, which is:

    a straight vertical edge      because a clip plane is exactly that
    worse on corners              because that is when the list is busiest
    persistent while parked       because nothing rewrites the viewport

It also explains why the drop counter is zero: the quads are not being
dropped for want of room, they are being CLIPPED AWAY before they are stored,
which is a different path entirely and counts nowhere.

**Tried in simulation and INCONCLUSIVE, because the run never reached
gameplay.** `FRAME_COIN=300000000` inserts a coin and presses start, and over
700 M cycles the viewport latched 606 times with vx1 never leaving 0 and x2
steady at 495.0 - but the run finished with 6 quads and no objects, still in
attract. A viewport that behaves in attract says nothing about one under
gameplay load, so this neither confirms nor refutes anything.

**What is needed first is a gameplay repro in simulation**, and the coin
sequence is not enough on its own: two 0.375 s presses of coin then start
leave the game in attract. Whether it needs more credits, a longer press, a
different DIP setting, or simply more time after the start is unmeasured -
`f_ctrl` and the layer census are already printed and would show the state
change when it works.

**The alternative is the wire**: m1_raster3d exposes dbg_xc, dbg_yc,
dbg_zoomx, dbg_zoomy, dbg_viewx and dbg_viewy and none of them reach the
UART. One word of view state there would show a corrupted viewport directly
on the board, where the fault definitely happens - if vx1 reads 248 rather
than 0 while the fault is on screen, that is the whole answer. That costs a
build; the simulation route costs none, which is why it was tried first.

**What would cause it** is the next question and is unmeasured: a walk that
reads command 3 while the V60 is mid-update would do it, and the pass now
starts on the list flip specifically to prevent that - so if this is the
mechanism, the flip protection is not covering something.

## 2026-09-04 — GAMEPLAY RUNS, and the left half of the 3D is hidden

With the tv80 I/O board the game reaches actual gameplay for the first time -
Ben's photograph shows Virtua Racing racing, position, lap time, the minimap,
the car. Two faults are visible and both are new information, because nothing
before this ever got past attract.

### The left half of the screen has no 3D

A PERFECTLY VERTICAL boundary at about half the width, roughly x = 248 of
496. Left of it: flat green below, flat blue above, and the 2D overlay. Right
of it: road, scenery, everything.

**That shape is the 2D window mode, not a 3D fault.** Dropped quads lose whole
objects and leave ragged holes; a straight vertical edge at the midpoint is a
clip or a column split, and `segaic24`'s window mode is exactly a per-pixel
column split that draws BOTH maps of a pair, one either side. The green and
blue are tilemap colours. So the likely mechanism is a tilemap drawn OPAQUE
over the left half, hiding the 3D behind it, rather than the 3D failing to
draw there.

Attract sets pair 2/3 to mode 1 with a varying split line, which is the
horizon and works. Gameplay has never been observed, so what it sets is
unmeasured.

**Next**: `make m1_frame FRAME_PRESS=0xfe` then `0xef` puts a coin in and
presses start, which is how to reach gameplay in the bench now that the I/O
board answers. Then read `f_ctrl[0]`/`f_ctrl[1]` and the per-layer pixel
census the bench already prints - it reports tm0..tm3 pixels a frame - and
compare against MAME on the same frame. The 2D rules are all implemented and
verified for attract; this is about what gameplay asks for.

### The pedals were digital, and triggers need TWO axes

MiSTer has no dedicated trigger signal: hps_io offers the two sticks, the
paddles and the spinners, and a trigger reaches a core by the player binding
it to a stick AXIS in the OSD. The documented racing convention is
left-stick-down for the accelerator and right-stick-right for the brake, so
those are the axes the core reads. A first attempt put both pedals on one
axis, which cannot work - two triggers are two independent inputs.

Magnitude rather than sign, because a trigger bound to an axis may rest at
either end depending on the pad. Idle 0x01, full 0xff, MAME's
PORT_MINMAX(1,0xff). The buttons stay live and the larger wins.

## 2026-09-04 — THE tv80 I/O BOARD BOOTS AND STOPS AT THE EEPROM

The Z80 runs EPR-14869 out of SDRAM and gets a long way. It does not reach the
shared RAM, and the reason is not the DPRAM path at all.

### What each side actually does, measured

**The V60 moves first, and it writes a signature.** `tb_m1_frame` counting its
writes into the shared RAM:

    01a=53  01b=45  01c=47  01d=41      "SEGA"
    020=01                              then the flag at 0x20

Three times each, which is the CPU retrying. So the V60 is not waiting for
permission to start - it has placed its request and is waiting at fe022c for
an answer.

**The Z80 never answers, because it never gets that far.** Every write it
makes into the 315-5338A's registers, in order:

    5=00  8=5e  0=40 0=c0 0=60 0=e0 0=60 0=e0 0=40 0=c0 0=40 0=c0 ...

Register 8 is the direction register; register 0 is port A. After setting
direction it toggles ONE BIT of port A for ever - 0x40 against 0xc0 - with a
second bit moving occasionally. That is a bit-banged serial clock, and port A
is where this board's **93C45 EEPROM** hangs. The firmware is stuck in its
EEPROM conversation and has not begun the DPRAM one.

### The contents are NOT the problem, tested

`93c45.bin` is 128 bytes in vr.zip and read as little-endian words its first
two are 0x5345 0x4741 - "SEGA", the same signature the V60 writes into the
shared RAM, which made it a very good suspect. Preloaded into the model
(`build/rom/vr_ee_le.hex`, simulation only for now) the behaviour is
**identical**. `ee[0]` reads back 5345, so the file loaded; the firmware
still never reaches the DPRAM.

### What the conversation actually looks like

The pin decode is confirmed against the RTL - port A bit 7 is the clock, bit
6 chip select, bit 5 data in - so the first command the firmware issues reads
as start(1), opcode(10)=READ, address 000000: a read of word 0, the
signature. Sensible, and what a boot check would do.

But over 512 register writes the model ends with `cs=0`, `st=EE_CMD` and
**`ee_addr` latched at 63** - all ones - and the trace beyond the first
command is six clocks of DI=0 followed by a long unbroken run of DI=1. All
ones decodes as start(1), opcode(11)=ERASE, address 111111.

So either the firmware is erasing and rewriting the device because it did not
like the read, or the model mis-frames the command and the firmware is
reacting to nonsense. Those are different bugs and the next measurement
separates them: **count how many times `ee_st` enters EE_READ and what
`ee_out` was loaded with**. If it never enters EE_READ the framing is wrong;
if it does, compare the 16 bits shifted out against ee[0] = 0x5345.

MAME's `eeprom_serial_93cxx_device` is the oracle for the framing, and the
one thing to check first there is the START BIT and dummy-bit convention -
93C45 and 93C46 differ in address width, and this model shifts nine bits
before decoding.

An earlier probe of `dbg_last_wr` read all zeros and I suspected the probe.
It was honest: that signal only updates on a DPRAM write COMMAND, and there
have not been any. The probe that answered the question watches `aw_l`/`dw_l`
on `wr_stb`, which is every register write.

## 2026-09-03 — THE FPS DIPS ARE THE V60 WAITING ON MEMORY, not the rasterizer

Ben reports the game slowing for about five seconds in one scene. That is the
GAME's logic rate, which is S= on the wire - display-list swaps a second, 29
when the game is running at full speed. From `build/uart_revert_seed7.txt`,
every line where S dips, against what else the core was doing:

    S=10..20    objects 41-58   geometry pass 1.48-2.02 frames
    S=27..29    objects 0-49    geometry pass 0.07-1.76 frames

So the dips are the busy scenes, and the question is which machine is short
of time. `tb_m1_frame`, 900 M cycles:

    V60 cycles                 273,793,911
    stalled on data                40.31%
    stalled on fetch               10.00%
    stalled on either              49.67%
    3D polygon-ROM port        703,087 requests, mean wait 255 clk_sys cycles

**The V60 spends half its life waiting for memory**, and the 3D geometry is
reading the polygon ROM out of the same SDRAM controller at a 255-cycle mean
wait. In a heavy scene the geometry reads far more ROM, so the contention
rises exactly when the game has most to do.

**The band fill is NOT part of this.** It reads the quad store and writes the
band buffer, both on-chip M10K; it never touches SDRAM. So the reciprocal
divider - which fixes late bands, a display artefact - cannot help the frame
rate, and neither can anything else aimed at the consumer. Said plainly
because the two symptoms look alike from the sofa and have nothing in common.

The levers, in the order their evidence supports:

1. **NOT the SDRAM constraints - those exist and are applied.** An earlier
   version of this entry said the interface was unconstrained, repeating a
   stale line from the rules file's to-do list. Ben corrected it, pointing at the
   Model 2 core. `tools/mister_project.sh` writes a full set into
   `Model1.sdc`: a generated clock on SDRAM_CLK, input delays of 6.4/1.0 ns
   on DQ, output delays of 1.5/-0.8 ns on the address, bank, data and control
   pins, and setup/hold multicycles to the CPU clock - with a critical
   warning if the generated clock cannot be created, so a build that lost
   them would say so. The 2026-09-03 builds read it and report SDRAM_CLK_pin
   at 12.5 ns with paths analysed and met. **Check a claim like this in the
   staged .sdc, not in a plan.**
2. **NOT the polygon-ROM latency either - the prefetch already hides it.**
   Measured with `ROM_LAT` on tb_m1_raster3d, frame 5460:

       ROM_LAT=0    P_OBJW 44.2% of the run
       ROM_LAT=8    P_OBJW 44.3%     - identical, fully hidden
       ROM_LAT=32   P_OBJW 58.0%     - now it bites

   So the geometry is ARITHMETIC-bound at any realistic memory latency, and
   what it is bound on is its own divider: `m1_geo_project` uses `fp_div`,
   29 cycles and not pipelined, which is 29 of the 32 cycles a point and 94%
   of the whole geometry stage (see the 2026-08-30 entry). Ben asked whether
   the divider work helps here and the answer is yes - just not the one that
   was done. The fill's divider never touches SDRAM or the geometry; the
   PROJECTION's divide is a separate unit and is the geometry pass's cost.

   Two ways at it, in increasing risk: a second `fp_div` so the two points of
   a record overlap, which the 2026-08-30 entry already names as "the obvious
   lever" and halves the stage to ~47%; or a reciprocal table like the fill's,
   which is harder because this one is IEEE-754 single and is checked
   bit-exact against MAME (20,037 checks in `m1_geo_project`), so a table
   needs a Newton step and its own exactness argument.

   That shortens the geometry PASS - L= on the wire, 1.5-2.0 frames in the
   busy scenes - and so restores the two-frame cadence there. It does NOT
   reduce the number of ROM reads, so its effect on the V60's frame rate is
   an open question rather than a promise.
3. **The V60's own CPI** - 17.71 in the earlier measurement, against the
   reference's 2 M instructions a second.

None of this is the 3D layer's display path, which is what the last session
fixed. It is the next thing, and it is bigger.

## 2026-09-03 — clear-on-readout for the band buffer DOES NOT SYNTHESISE

The 3D geometry rate is a third short of the display-list rate because the band
sweep tips past blanking and swap_now is missed. The obvious thing to reclaim is
the per-band clear: it walks 1,984 words at one address a cycle, per band, which
is a FULL-SCREEN WIPE per frame - 496x384/4 = 47,616 words, 5.8% of the 818,133
clk_3d cycles in a frame, whatever the band height.

The free way to remove it is clear-on-readout: the display already reads every
word of a band exactly once, so writing background back as it reads leaves the
buffer clean for its next fill. No extra memory, no extra time. The ring makes
it safe - an instance is either being filled or displayed, never both.

**Quartus 17.0 will not infer it.** Adding a write to the read port makes the
memory a dual-CLOCK true-dual-port RAM, and synthesis fails outright:

    Error (276003): Cannot convert all sets of registers into RAM megafunctions
    when creating nodes. The resulting number of registers remaining in design
    exceeds the number of registers in the device...

Tried twice: the plain form, and the symmetric template with a read added to the
write port (a write-only port is a known inference blocker). Same error both
times. Verilator simulates it happily - 825,351 checks pass - so this is
invisible without asking Quartus.

`make quartus MOD=m1_raster_band` was added for exactly this and answered it in
SIX SECONDS. The rules file's rule - "Test a memory idiom small; 1024 entries settles
the question in seconds" - is why this cost minutes instead of a 25-minute full
build and a mystery.

### What is left for the band fix

    a 4th band buffer     removes the clear entirely, costs ~16 M10K
                          (4 banks x 4 blocks). We have 57 free and sound wants
                          ~57, so this trades the 3D fix against sound fitting.
    find the margin       the clear is only 5.8% of a frame. Simulation puts the
    elsewhere             sweep at 92.4%, so hardware must be over 100%, and the
                          gap is unmeasured - 5.8% may not be enough.
    measure the gap       how much of a frame the sweep actually takes ON THE
    first                 BOARD. Without it, spending 16 M10K is a guess.

The third is the honest next step. Two fixes have already been talked out of on
this defect - a fourth buffer on a units error, and the FIFO deadlock - and both
would have been wrong.

**And so would all three of these.** They are about the band fill - the
consumer - which the board's own N= counter shows keeping up every frame. The
sequencer that was late is the producer; see the entry at the top of this
file.

## 2026-09-03 — the crash is DETERMINISTIC, and X=FE0C9B names the code

Third capture, with X= carrying the V60's pc latched at the instant the
coprocessor stops retiring. Log: `known_good/uart_crash_stallpc_2026-09-03.txt`.

**THE CRASH POINT IS IDENTICAL EVERY TIME.** Across three independent runs, on
two different builds:

    capture 1   R=35C5   B=0AD7
    capture 2   R=35C5   B=0AD6
    capture 3   R=35C5   B=0AD4

R is the TGP's free-running 16-bit retire count. It freezes at the SAME value in
all three, and the band count is within three. This is not a race and not a
timing flake - the coprocessor stops after the same amount of work every time,
which means the state is reachable in simulation given enough cycles.

**AND THE PC AT THE STALL IS NOT WHERE THE V60 ENDS UP.**

    X=FE0C9B    the V60's pc at the instant the TGP stopped retiring
    V=FFE59C    where the V60 is pinned afterwards

Two different addresses. FFE59C is the aftermath - the movcu block copy the game
runs in its error path, and the address the overlay has always shown because
sampling lands there. **FE0C9B is the instruction that was executing when the
coprocessor stalled**, and it is the lead this hunt has been missing.

That distinction is exactly what docs/findings.md asked for during an earlier
hunt at this same address: "The overlay's PC row cannot help - it samples at the
same point every frame and reads FFE59C blank or not. What is needed is the PC
at the instant of the teardown, latched on the transition, with a counter."

### Next step for this, when it comes back up the list

Disassemble around FE0C9B in the ROM. MAME's debugger will do it, and since the
crash is deterministic the same point can be reached under `make m1_frame` with
a long enough window - the V60 was reproduced stopping at ffe59c after 2.8
emulated minutes, which is about 13.4 billion cycles.

### Instrument notes, both mistakes worth not repeating

The latch was STICKY at first - "the first stall is the interesting one". Wrong:
the first stall is at BOOT, when the coprocessor legitimately has nothing to do,
so the field showed X=FE0027 while the core ran perfectly. Keeping the LATEST
stall is correct, and safe because after the crash nothing retires again, so the
crash's value is the last written.

And the 12.5 ms threshold fires on benign idle - at ~20 geometry passes a second
the TGP can idle 50 ms between commands. That is tolerable only because of the
non-sticky fix: benign latches are overwritten, and the crash's is final.

## 2026-09-03 — the "missing 3D bands" are not missing. The geometry is STALE

Ben reports bands not being drawn in busy 3D scenes. Measured on hardware, they
are all being drawn.

    N (bands PRESENTED)        1,392 a second
    expected, 24 x 57.52 fps   1,380 a second

Every band reaches the screen, every frame. What is short is the geometry behind
them:

    S (display-list swaps, the V60's logic frames)   ~29 a second
    B (completed geometry passes)                    ~20 a second

So about a third of the game's display lists never become new geometry, and the
display repaints the previous pass. On screen that is 3D updating in jerks while
the 2D moves smoothly - which from the outside looks like bands not being drawn.

### The mechanism

m1_raster3d hands a completed pass over only when three things coincide:

    swap_now = (pst == P_READY) && (cst == C_IDLE) && beam_blank && !beam_blank_d

Producer ready, CONSUMER IDLE, and the beam entering blanking. If the band
filler is still working when blanking arrives the swap is missed and the pass
waits a whole frame. Requiring C_IDLE is deliberate - the module's comment says
so - because swapping mid-sweep would tear the picture at a bank change.

There is no per-band timeout; `band_timer` only measures. Bands are not being
abandoned, the handoff is being skipped.

### What simulation says, and where it does NOT match the board

Over 647 sweeps of a 900 M-cycle run:

    mean sweep   1,285,088 cycles   92.4% of a frame
    worst sweep  1,285,761          92.5%
    bands presented per frame       24 on 668 of 669 frames

    per sweep:  WAIT 1,040,694  81%   idle, waiting for the beam
                FILLW  137,653  11%
                CLRW    81,008   6%   the per-band buffer clear
                FILL     26,638   2%

**The consumer is idle 81% of the time.** It finishes early and waits. In
simulation the pipeline is healthy and the defect does not reproduce - 24 bands
on 668 of 669 frames. On the board the geometry rate is a third short. So the
cause is something sdram_model does not capture, and real memory contention is
the obvious candidate: the 3D path shares that controller with the CPU, the tile
fetch and now a coprocessor running at 2:1.

**CORRECTED, later the same day.** Every number above is about the CONSUMER,
and the consumer was never late - N proves it idle at every edge. The defect
DOES reproduce in this same bench: the PRODUCER's pass is 1.47 frames in the
attract scene and runs every three frames. See the entry at the top of this
file. "Does not reproduce" meant "was not measured".

### A WITHDRAWN MEASUREMENT, because it nearly cost 14 M10K

An earlier pass concluded "the band filler does not fit a busy frame - 104% of
budget" and proposed a fourth band buffer to fix it. That was an 80 MHz cycle
count compared against a 47 MHz (clk_3d) budget. At 80 MHz a frame is 1,390,821
cycles, not 818,133, and the sweeps fit at 92%. The fourth buffer would have
bought nothing and spent a quarter of the M10K that sound needs.

The worst-BAND figure (35,719 against a 34,089 per-band budget) was units-
correct, but its budget assumed 24 bands must run back to back inside one frame.
They do not - they are paced by the beam.

### Where to look next

The board, not the bench. Candidates, in order:

1. SDRAM contention - the sweep sits at 92% of a frame in simulation, so a
   modest real-memory penalty tips it over and the handoff is missed.
2. The per-band clear, 1,984 cycles and 6% of a sweep. Cheap to remove IF a
   spare buffer exists to clear ahead; with three buffers all occupied there is
   no free window, and clearing one while it is displayed is a read-during-write
   on a dual-clock RAM.
3. Whether the sweep can start earlier in the frame rather than finish sooner.

### Instrument notes

`dbg_bands` and `dbg_band_cycles` were both UNCONNECTED outputs of m1_raster3d,
so Verilator optimised them away and nothing could read them. Both are now
wired: dbg_bands to the UART as N=, dbg_band_cycles to the bench.

N= originally SATURATED at 0xffff rather than wrapping, which at 1,380 bands a
second made it readable for 47 seconds and useless after. Fixed to wrap. It
answered the band question before it saturated, which is the only reason this
entry exists.

## 2026-09-03 (later) — the crash chain, with the V60's pc on the wire

Second 7-minute capture, this time with V= carrying the V60 program counter.
Full log in `known_good/uart_crash_pc_2026-09-03.txt`. The transition:

    S=0019  C=0233  R=C660  V=FF6C47   healthy - TGP pc varying, retiring
    S=0017  C=0229  R=68B0  V=FF85E4   healthy
    S=0017  C=004C  R=1C94  V=FF8629   TGP at idle dispatch, STILL RETIRING
    S=0007  C=004C  R=35C5  V=FFE59C   R FREEZES - V60 pc -> FFE59C
    S=0000  C=004C  R=35C5  V=FFE59C   V60 stalled, pc frozen
    S=0000  ...                FFE59C   four seconds
    S=000A  C=004C  R=35C5  V=FFE59C   swaps resume, pc STILL FFE59C
    S=001B  ...     P=0000   V=FFE59C   and never moves again

**THE TGP IS BLOCKED, NOT IDLE, and the retire count is what proves it.** Line
three has C=004C with R still advancing: at the idle dispatch the coprocessor
keeps retiring its polling loop, so the pc alone cannot distinguish hung from
waiting. R then freezes at 35C5 permanently. That is a stall.

**THE V60 IS PINNED AT FFE59C**, which is where the crash was reproduced in
simulation after 2.8 emulated minutes: a `movcu.h` block copy whose length is
read from memory. Swaps resume to ~26/s while the pc samples FFE59C every time,
so the main loop runs but spends nearly all its time inside that copy, every
frame.

**AND THAT EXPLAINS THE 2D GOING BLACK.** A game looping on a huge block copy
with P=0000 is clearing memory - tile RAM and display lists both. The tile path
never touches the coprocessor, which is why a dead TGP alone could not account
for the symptom, and this closes that gap.

So the chain is:

    TGP stalls -> V60 waits -> game takes an error path -> clears everything
    every frame -> black screen

The root cause is the coprocessor stall. Everything downstream is the game
reacting to it, which is why reloading the core is the only recovery.

WHAT IS STILL OPEN: why the TGP stalls at 0x004C. That address is the command
FIFO read, and a read of an EMPTY fifo returning zero was fixed on 2026-08-29 -
so either that regressed, or it is blocked pushing into a full OUTPUT fifo while
the V60 is not draining. The FIFOs are 16 deep and a full one halts the CPU.
Both sides waiting on each other fits every line above.

ALSO: a core load can fail silently, and V= now says so instantly. The first
load of this build gave V=FFFFF0 - the reset vector - with S=0000 and R=0041:
the CPU never fetched an instruction. Before this field that state was
indistinguishable from a core bug.

## 2026-09-03 — the five-minute crash is a COPROCESSOR deadlock, caught on the wire

The long-standing "black screen after about five minutes" was characterised for
the first time, on a 7-minute UART capture from a cold-ish machine (up 1:14).
Full log in `known_good/uart_crash_2026-09-03.txt`.

The overlay photo of this fault showed every counter frozen, which read as the
whole core stopping. That is not what happens:

    S=001D B=0A4B P=009D C=004C R=1C94   healthy, TGP retiring
    S=0007 B=0A5E P=0055 C=004C R=35C5   R FREEZES; swaps collapse 29 -> 7
    S=0000 B=0A72 P=009D C=004C R=35C5   swaps ZERO - the V60 has stalled
    S=0000 ...                            four seconds of S=0
    S=000B B=0AD7 P=0000 C=004C R=35C5   V60 resumes; objects -> 0 for good
    S=001D B=0B11 P=0000 C=004C R=35C5   full swap rate, no 3D ever again

So: the TGP stops retiring, the V60 stalls COMPLETELY for about four seconds,
then recovers to full display-list rate with P=0000 - no objects - permanently.
Video timing (F=003A) never falters throughout.

**AND THE 2D GOES BLACK TOO** - Ben, on seeing this analysis. The screen is
entirely black, not "3D missing over a 2D background". That matters because the
tile path never touches the coprocessor, so a dead TGP cannot explain it, and
the first draft of this finding was wrong to imply it could.

What has to be reconciled: video timing alive (F=003A throughout), the V60
running and swapping display lists at full rate (S=001D), bands still being
presented - and nothing on screen. Candidates, none yet tested:

  - the GAME has crashed. The V60's main loop still runs and still swaps lists,
    but the lists are empty (P=0000) and it has stopped writing tile RAM. A game
    error path that blanks the screen would look exactly like this, and the
    coprocessor deadlock is a plausible trigger for the game taking one.
  - the PALETTE. Both 2D and 3D index it, so a zeroed or unreadable palette
    blacks everything while every counter keeps moving.
  - a shared resource in the video path downstream of both layers.

The V60's pc would separate the first from the others in one reading, and it is
NOT on the printf channel - only in the 24-row overlay, which cannot show a
sequence. An earlier overlay photo of this fault showed pc=00FFE59C.

That is a COPROCESSOR DEADLOCK, not a dead core. The coprocessor FIFOs are 16
deep and a full one HALTS THE CPU, so the shape that fits is the TGP blocked
pushing a result into a full output FIFO while the V60 is blocked waiting on the
coprocessor. The V60 breaks out eventually - a timeout in the game code, or an
interrupt - and carries on with an empty display list.

WHAT CANNOT BE CLAIMED FROM THIS. At one sample a second the TGP freeze and the
V60 stall cannot be ordered; they appear in the same line. And `C=004C` is the
IDLE DISPATCH, so the pc sitting there is equally consistent with "hung" and
"correctly idle because no commands are arriving" - which is why the frozen
RETIRE COUNT is the stronger signal, not the pc.

This capture was only possible because 2:1 added C= and R= to the printf
channel. Before that the coprocessor's state was invisible on hardware and the
fault looked like a whole-core hang.

INSTRUMENT DEFECT FOUND IN THE SAME RUN: N= saturates. dbg_bands is
`if (ev_present && dbg_bands != 16'hffff) dbg_bands <= dbg_bands + 1` - it
SATURATES rather than wraps, so it is only readable for the first ~47 seconds at
1,380 bands a second. Long enough to answer the band question this time, useless
for anything longer. Make it wrap.

## 2026-09-03 — Virtua Fighter needs no special ROM, and MAME's NOT_WORKING is about MAME

`315-5724.bin`, VF's TGP microcode, is marked `BAD_DUMP` in MAME and `vf` is
`MACHINE_NOT_WORKING`. That reads as "the dump is broken, VF is blocked".

**It is not.** Ben confirms wangModel1 runs Virtua Fighter from the ordinary ROM
set with no special or replacement microcode. All three copies on this machine -
`vf.zip`, `vf.7z` and the loose `~/roms/vf/` - carry sha1
`8809d93d47593f808faca55161999677ac7a3eb0`, which is byte-identical to the dump
MAME flags. So the bytes another implementation runs successfully are the bytes
we already have.

`MACHINE_NOT_WORKING` describes the state of MAME's TGP emulation, not the ROM.
That matters here because **we implement the MB86233 rather than model it**, so
VF is worth actually trying rather than treating as blocked.

WHAT THIS COSTS US: MAME cannot be the oracle for VF. There is no reference
instruction stream, no reference frame to diff, no register census. Verification
for VF is "does it look right", which is weaker than everything else on this
project rests on. Virtua Racing stays the reference game.

**^^^ WITHDRAWN 2026-09-05. MAME RUNS VIRTUA FIGHTER.** It plays the attract
demo correctly, on a real emulated MB86233 at 40 MHz - `MB86233(config,
m_tgp_copro, 40_MHz_XTAL)` with program, data, IO and register-file maps, not
high-level emulation. It executes the microcode word our coprocessor hung on,
`0x04B0`, 116 times in a 20-second window and carries on. The same is true of
NetMerc.

The paragraph above reasoned correctly from the `MACHINE_NOT_WORKING` flag and
never tested it. That cost an hour of reading disassembly while a full
instruction-level oracle sat unused: `tgp_trace GAME=vf` produces 30 M
instructions of reference stream, and MAME snapshots give reference frames.

The flag means MAME's authors decline to call a game "working" on a `BAD_DUMP`
microcode. It is a curation stance, not a statement that the machine fails.
**Test the claim.** Kept visible because reasoning from a status flag felt like
evidence and was not.

DECOMPILING wangModel1 WAS CONSIDERED AND REJECTED. It is closed source, and
writing RTL from its internals would make that RTL arguably a derivative work -
the same reasoning that makes the s32 V60 import GPL-3.0-or-later however much
of it is rewritten, and the same policy the rules file already sets for
`third_party/geometrizer/`: run it as an external oracle, read it for
understanding, do not copy or adapt. Black-box observation of which files a
binary opens is fine; reading its internals is not. In the event it was
unnecessary - the ROM question was answered by asking.

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
the band buffer wants ~51 of them. The `26,663 ALM / 409 M10K` figure in the rules file
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

The rules file says: when something is unknown, run MAME, do not reason about it. Four
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

The rules file opens with exactly that rule.

## V60 vs MAME, instruction by instruction: they diverge at 197,251 — 2026-08-18

Built at the user's suggestion, after they asked why the V60 and TGP both have
"verified per-opcode, never checked on real code" gaps.

**Why those gaps exist**, honestly: per-opcode fuzzing is cheap to build and
produces impressive counts — `mb86233_dec: checked=3,000,000` — and it only proves
each instruction correct *for the state it was handed*. Lockstep on real code needs
a shared memory model and identically stubbed peripherals, so it was written down as
owed and never done. The V60 arrived from the s32 project with a 29/29 unit suite
and this core is the first thing to run Virtua Racing through it. The rules file warns
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

## A GENUINE BUG IN THE V60 CORE: OUT had its operands swapped — 2026-08-18

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
saw them — while the rules file's baseline listed `m1_uart_tx: checks=69` as though it
had. Now wired in. The module stays instantiated nowhere by intent; it is parked
for hardware monitoring if that is ever needed.

## CORRECTED: "the V60 never reads the coprocessor back" — 2026-08-18

This was recorded as a measurement, carried into the rules file's table of things
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

## The deadlock in one line: our V60 pushes four words, the reference pushes five

Counted on both sides rather than inferred (`tb_m1_boot`'s `COPRO PUSH`/`POP`/`RESULT`
lines against `tools/mame_tgp_fifo.lua`):

| | word | popped at TGP pc |
|---|---|---|
| both | `04000000` | `0x0044` |
| **reference only** | **`00000000`** | dispatch |
| both | `01000000` | `0x004d` |
| both | `3f400000` | `0x00a5` |
| both | `428c0000` | `0x00a5` / `0x00a6` |
| reference | result `42520000` | written to `0x400` |

**Every word we push matches the reference exactly, in order. One is missing.** The
TGP is therefore one word short of a complete command and waits; the V60 believes it
has sent one and waits for the result. That is the whole deadlock.

### Why this is a good place to be

It is a single, findable difference in the V60's instruction stream, and `v60_trace`
is the tool for exactly that. The pushes happen around `ff97xx`, which is *before*
the trace's current divergence at 26,945 — so on the face of it our V60 executes the
same instructions and should push the same words. One of those two statements is
wrong, and finding out which is a bounded question:

- if the streams really do match there, the missing push is a **bus or decode**
  problem — a write to `0xd80000` that does not become a push;
- if they do not, `v60_trace`'s divergence is being masked and the collapse or the
  window needs attention.

Do not assume which. The last two "obvious" answers here — the coprocessor RAM path,
and the FIFO not advancing — were both wrong, and both were reasoned from a counter
rather than read from the design.

## WITHDRAWN: "our V60 pushes four words, the reference pushes five" — 2026-08-18

Wrong, and wrong in the way this file keeps warning about.

`tools/mame_copro_pushes.lua` taps the reference's **writes** to `0xd80000` and names
the PC of every push:

    push 1  pc=fe69d3  0400_0000
    push 2  pc=ff9741  0100_0000
    push 3  pc=ff9749  3f40_0000
    push 4  pc=ff9751  428c_0000

**Four words, the same four we push, from the same instructions.** There is no
`00000000` push.

The `00000000` entries that finding rested on came from the FIFO **read** log
(`tools/mame_tgp_fifo.lua`). Per `gen_fifo.cpp:109`, **a pop on an empty FIFO returns
`T()` — zero** — and fires the stall callback. So those entries are stall-and-retry
attempts, and that tap cannot distinguish "read a zero" from "read nothing and
retried". They were read as data.

Seventh instrument artifact of the day, and the first written *after* the rule about
this was added to `docs/differential-testing.md`. Reading the rule is not the same as
applying it.

### What the comparison actually shows

| | ours | reference |
|---|---|---|
| pop 1 | `04000000` @ TGP pc `0044` | `0044` |
| pop 2 | `01000000` @ `004d` | `004d` |
| pop 3 | `3f400000` @ `00a5` | `00a5` |
| pop 4 | `428c0000` @ **`00a5`** | **`00a6`** |
| next | **stalled at `00a5`** | `00a7 fml` then `00a8` writes `42520000` |

The microcode at `00a5`/`00a6` is two consecutive FIFO reads — `mov (x1), a` then
`mov (x1), b`. Ours consumes both words but **never advances past `00a5`**: it pops,
does not retire, and comes back for another word. The reference retires each read and
reaches the multiply.

So the question is no longer about the protocol's length. It is: **why does a FIFO
read at `00a5` pop without retiring?** Look at `fifo_ack` against `fifo_in_pop` in
`m1_tgp`, and at how `mb86233_mem` holds `ext_rd` across the memory states — a
request held for more than one cycle pops more than once, and an acknowledge that
arrives on the wrong cycle retires nothing.

## M0 exit criterion 2 is met: the TGP is instruction-accurate on real microcode

`make tgp_trace` reports **`IDENTICAL for 342 instructions`** — the reference's entire
traced window, its collapsed stream being 343. Our coprocessor executes the same
instruction sequence as MAME's on the real decapped microcode.

This is the criterion the project has owed since M0. What existed was
`sim/tgp/mb86233_ref.cpp`, a whole-CPU reference in lockstep over 8,000 retires of
**generated** instructions — which proves each instruction correct for the state it
was handed, and cannot show the machine reaching the wrong state on real code.

Four bugs fell out of building it, in order:

| | |
|---|---|
| the boot bench loaded the microcode **one word high** | address 0 was right by accident, so instruction 1 worked and every one after came from the wrong word |
| **ST was not a register** | the flags lived in the ALU's pipeline and a branch corrupted its own condition |
| **`brul`/`bsul` unimplemented** | the dispatch jump was a constant |
| **FIFO pop and push fired per CYCLE, not per ACCESS** | every read ate two command words, every result was pushed twice |

### The caveat belongs with the claim

The window is three emulated seconds and the TGP is idle for most of it, so 342
instructions is **the reference's whole window, not deep coverage of the instruction
set**. And `tb_mb86233_core`'s `diverged=0` remains no evidence about the flag path —
it passed both before and after the ST fix, because generated instructions never put a
conditional branch straight after a flag-setting ALU op.

**Met for what the game currently executes, not for the instruction set.** Widen the
window as the game gets further.

### A note on where this was nearly recorded

The rules file is gitignored (`.gitignore:122`), so it is a local-only file. Several
commit messages on 2026-08-18 say "the rules file baseline updated" — those edits are real
on disk but are **not in the repository**, and a clone gets none of them. Durable
findings belong in `docs/`, which is tracked. The test-count baseline, the resource
figures and the corrected "the V60 never reads the coprocessor back" entry all live
only in the working copy.

## Traced end to end: "no text" reaches the TGP's unimplemented math units — 2026-08-19

The chain, each link measured except the last:

| link | evidence |
|---|---|
| no text on screen | board photograph and `m1_frame` |
| the V60 never reaches the per-frame 2D setup | `[5002]`, `[5006]` and the row mask all zero at 862 frames |
| it is stuck at `FED5A4` waiting for copro RAM to read zero | reference exits that loop after ~32 iterations; ours spins **1,120,224** times |
| copro RAM word 0 holds `ffffffff` | `CRAM rd: ram_addr=0000 ram_q=ffffffff` |
| **the TGP wrote it**, once | `CRAM WR: st=2 addr=0000 din=ffffffff tgp_we=1` |
| it computed that from unimplemented math units | **INFERENCE, not measurement** |

### Three of my own conclusions were wrong on the way here

**"The array is uninitialised."** Plausible — Verilator does bring unpacked arrays up
as ones, and `mb86233_mem.sv` already carried that exact fix and reasoning. But the
`initial` block prints `CRAM INIT: 8192 words zeroed, ram[0]=00000000` in both builds.
The array starts zeroed and is written afterwards. The fix is still right on its own
merits and stays.

**"Nothing writes `ram[0]`."** Said on the strength of `copro RAM writes=0`. That
counter is `dbg_ram_writes`, which increments only on the **V60's** writes — `we && a1`
in `S_V60_RAM`. The `S_TGP` path has its own `ram_we = tgp_we` that it never sees. The
boot line reads "copro RAM writes=0" as though it covered both ports; it does not.
**Third time this session a counter's name was trusted over what it increments on**,
after `dbg_fifo_pops` and this one twice.

**"The comment containing the pragma re-triggered it."** Both `translate_off`
occurrences are in comments, and the same file compiles to a zeroed array in the module
bench, so the comments cannot be the cause. Withdrawn before it was acted on.

### Where this leaves the text

The TGP's io sequence is `R 0020` (sincos), `W 002e`, `R 8010`, `R 8020`, `W 0028`
(inv), `R 0028`, `R 0029`, `W 0008` (copro RAM address). It is using the interfaces
correctly. But `m1_tgp`'s own header says the math path is not built: *"Index arithmetic
and the exponent fixups are NOT here yet — so a read presents the quadrant base and the
integrator's memory answers."* A sincos or inverse read returns table data at the
quadrant base, not the function's value.

So the V60's wait at `FED5A4` is downstream of **M2 work that was always known to be
outstanding**, not of a bug. Two things follow:

1. **The text is probably gated on the math units**, which is a substantial piece of
   work rather than a fix. Worth confirming by making an unimplemented math read return
   **zero** instead of table-base garbage and seeing whether the TGP then writes a word
   whose low byte is zero — `m1_integrated` already acknowledges those reads with zero,
   while `tb_m1_boot` wires them to real SDRAM tables, so the two disagree today.
2. **That asymmetry is worth closing either way.** Simulation and hardware currently
   feed the coprocessor different values on an unimplemented path, which is the same
   class of divergence as the uninitialised array.

## WITHDRAWN: the 0xffffffff was never garbage — the reference writes it too — 2026-08-19

Asked MAME instead of guessing a fourth time, which is what this repository's own
first rule says to do. `tools/mame_tgp_io_full.lua`, 400 frames:

     10  W io 0008  00010000        TGP sets the copro RAM address
     11  W io 0009  ffffffff        and writes ffffffff

**The reference's TGP writes `0xffffffff` into coprocessor RAM as well.** Our value was
correct all along. Three consecutive diagnoses were chasing a non-problem:

| guess | how it died |
|---|---|
| the RAM is uninitialised | `initial` runs and prints `ram[0]=00000000` |
| nothing writes it | the TGP does; `dbg_ram_writes` only watches the V60's port |
| the TGP computed it from unimplemented math units | `MATH_ZERO=1` changed nothing |
| the register file is uninitialised | never needed — the value was right |

Each fitted the evidence. None was measured against the oracle first, and the oracle
answers it in one run.

### The real difference is VOLUME, not values

| | io accesses |
|---|---|
| reference | **158,391** over 400 frames |
| ours | **~14**, then parked at dispatch with `pc=0043` |

Busiest: `W 0020` 13,169, `R 0021` 10,925, `W 002e` 9,710, `R 0020` 9,348, `W 0009`
5,345. The reference's TGP keeps working, writing coprocessor RAM over and over until
it eventually writes the word whose low byte is zero — which is what releases the V60
from `FED5A4`. Ours does its opening handful of accesses and stops.

### And this weakens the M0 claim made yesterday

`tgp_trace: IDENTICAL for 342 instructions` was over a **3-second window**, which
captures the reference's first 343 collapsed instructions and nothing of its steady
state. So the honest reading is: **our TGP matches the reference's opening and then
stops doing work**, and the window was too short to show it. "M0 exit criterion 2 met"
overstated it — met for the first 342 instructions, which is not the same thing.

Run `tgp_trace` with a window long enough to reach the 400-frame behaviour and the
divergence will name itself.

### The three initialisation fixes stay

`m1_copro_if`'s RAM, `m1_mainram`'s sixteen arrays, `mb86233_regs`' `rf` and
`m1_tgp`'s `copro_adr` are all still correct on their own merits — an M10K and a flop
come up cleared on the device, MAME's equivalents are zero-filled, and `mb86233_mem.sv`
already carried the same fix and reasoning. They were not this bug, and the commits
should not be read as if they were.

## FIXED: bsul's memory form — the geometry call jumped to its own address field

The long `tgp_trace` window named it in one run:

    04C5: bsul alw ($0x35)
    MAME:  -> 0693      reads data[0x35], finds 0x0693, and calls it
    ours:  -> 0035      jumped to the address field itself

`bsul` **memory form**, at exactly the site identified on 2026-08-18 and deliberately
left warning-only. `0x04c5` is a subroutine call into the geometry code at `0x0693`, so
jumping to `0x0035` dropped our TGP back into the dispatch region looking finished —
which is why it made **14** io accesses against the reference's **158,391**, and why the
V60 waited forever at `FED5A4` for a completion word nobody was going to write.

### The warning built to catch this was switched off by its own guard

It was wrapped in `// synthesis translate_off`, and the linter honours that pragma too,
so the one tool that could have printed it skipped the block. `bsul` went undiagnosed
for a day with its own alarm disabled — **the same trap that silenced the copro RAM
initialiser hours earlier.** Both are now unguarded. A `$display` costs nothing in
synthesis and the pragma was never needed.

**Rule: do not wrap diagnostics in a synthesis pragma.** Two instruments in one day
were made inert by it, and an inert instrument is worse than an absent one because its
silence reads as evidence.

### The implementation

MAME's `ea_pre_0`: `switch(r & 0x180) case 0x000: return r & 0x7f`. Both real sites
(`0x04c5`, `0x04da`) use that direct mode, so two states fetch the target from data
memory before the branch resolves, deliberately bypassing the AGU so the read cannot
disturb `x0`/`b0` the way a source operand would. The other three modes still warn —
and now the warning prints.

Divergence moves **500 -> 604**.

### The next one is an FP condition flag

    0730: fadd
    0731: brif ged #0x73a
    MAME:  falls through to 0732   (ged false)
    ours:  branches to 073a        (ged true)

Operands are `d = mem[0x43]`, `a = mem[3]` (the transfer wins over `orad`, per the
write-priority rule). So either the operands differ — they come from coprocessor RAM
and the data ROM, both only just flowing — or `fadd`'s flag output is wrong. **Print
the operands and the result on both sides before assuming which.** Four diagnoses were
withdrawn today for skipping that step.

## The value-level lockstep works, and names the fault in 26 writes — 2026-08-19

`make tgp_wrtrace` diffs the TGP's data-memory write streams. First divergence, at
write 22 of 26:

    22   ref  data[0069] = 00000030      ours = 00000000     DIFF
    23   ref  data[006a] = 00012e00      ours = 00000000     DIFF
    ...
    27   ref  data[0069] = 00000030      ours = 00000030     agree
    28   ref  data[006a] = 00012e00      ours = 00012e00     agree

Those two values are the **coprocessor data ROM's words** — `io 8010 -> 00000030` and
`io 8020 -> 00012e00`. The reference stores them; our **first** read of each stores
zero, and a later read of the same addresses is correct.

So this is a **first-read / warm-up fault in the data-ROM path**, not arithmetic. And
`tb_m1_boot` already documents the hazard, for its own capture rather than the DUT's:

> *"Sampled the cycle AFTER the acknowledge. `a_dout` is registered and updates on the
> same edge as `a_ack`, so a non-blocking capture at that edge takes the PREVIOUS value
> — which produced a half-right pair and read exactly like a data path fault."*

If `t_mem_rdata` becomes valid on the same edge as `t_mem_ack`, then `m1_tgp` sampling
`dat_rdata` **during** the ack cycle takes the previous value — zero on the first read.
`io_rdata = dat_rdata` and `io_ack = dat_ack` are combinational, so the DUT has no
slack for that.

**Check both wirings, because they may differ**: `tb_m1_boot`'s
`t_dat_ack = t_mem_ack && !t_tbl_req && t_dat_req` against `m1_integrated`'s, which
feeds the same `t_mem_rdata` on the hardware path. A one-cycle disagreement here would
be a simulation-only fault — or a hardware-only one — and this session has already
found two of those.

### Refined: the data path is INNOCENT, the loss is inside the core

Our io reads return the right values — the boot trace prints them:

    TGP io 9:  R 8010  waited 9
    TGP data read 1: sdram word 300020 -> 00000030     matches the reference
    TGP io 10: R 8020  waited 9
    TGP data read 2: sdram word 300040 -> 00012e00     matches

So the data ROM, the SDRAM path, `m1_cdc_port` and `io_rdata` are all correct, and the
`a_dout`/`a_ack` alignment worry above does **not** apply to the DUT — `a_dout` updates
on the same edge as `a_ack`, so a combinational read during the ack cycle is right. The
testbench's own capture problem was sampling a cycle later, which is a different thing.

**The value is lost between arriving at the io port and being stored.** The write that
should carry `00000030` into `data[0x69]` writes zero; a later pass carries it
correctly. So look inside `mb86233_core`:

- `S_SRC_W`: `src_val <= (x_src_sp == EP_IO) ? io_rdata : ...`, guarded by
  `!(x_src_sp == EP_IO && !io_ack)`. Does the guard hold for the FIRST io read, or does
  the state advance once before `io_ack` and latch a stale `src_val`?
- the store path that consumes `src_val` — if it fires a cycle early it writes whatever
  `src_val` held before, which at reset is 0 and matches the symptom exactly.

**Print `src_val`, `io_ack` and `io_rdata` across `S_SRC`/`S_SRC_W` for the first
`sel_datw` read.** Do not fix from inspection: four layers looked correct in the copro
RAM case this morning and the fault was elsewhere.

### Why this instrument was worth building

`tgp_trace` put the divergence at instruction 604, in `0731 brif ged`, which is **not
where the error is**. The value trace puts it at write 22, in the data-ROM read — many
instructions earlier and in a different subsystem. A PC diff can only ever report the
first place a wrong value changes control flow.

## LOCALISED: `src_val` follows the io ADDRESS, not the io DATA — 2026-08-19

The all-states io trace, at a run length that actually reaches the read:

    st=4  io_ack=1  io_rdata=00000030  src_val=00000010  addr=8010
    st=3  io_ack=0  io_rdata=00000030  src_val=00000020  addr=8020

At the acknowledge `io_rdata` is `00000030` — the correct data-ROM word, matching the
reference. **But `src_val` never becomes `0x30`.** It reads `0x00000010` through the
`8010` access and `0x00000020` through the `8020` one: the low bits of the io address,
not the data.

That is why `tgp_wrtrace` sees `data[0x69]` and `data[0x6a]` receive zero, or the wrong
value, while every diagnostic that looks at the *read* says the data path is perfect.
The read IS perfect. The capture is not.

`mb86233_core`'s `S_SRC_W` reads

    if (!mem_stall && !(x_src_sp == EP_IO && !io_ack))
      src_val <= (x_src_sp == EP_PROG) ? prog_rdata
               : (x_src_sp == EP_IO)   ? io_rdata
                                       : mem_rdata;

which is correct as written, so **something else assigns `src_val` on the same cycle and
wins**, or the guard lets the state advance before the acknowledge and a later
assignment overwrites it. Both are checkable: search every assignment to `src_val`, and
print it on the exact cycle `io_ack` rises alongside whatever else is driving it.

**Do not fix from that code reading.** It is the fifth time in two days that a path
"correct as written" was not the fault — the copro RAM had four such layers.

### The enumeration: only two writers, and neither explains it

`src_val` is assigned in exactly two places in `mb86233_core`:

    S_SRC:    if (x_src_reg) src_val <= rf_rd_data;          the register path
    S_SRC_W:  src_val <= (EP_IO) ? io_rdata : ... ;           memory / io / prog

The trace shows `st=3` then `st=4`, so the access took the `S_SRC_W` path — the register
path was not used. And at `st=4` the guard's terms are satisfied: `io_ack=1`, so
`src_val <= io_rdata` should have taken `00000030` at that edge. By the next
instruction's `S_SRC` it reads `00000020`.

**Both writers are accounted for and neither explains the value.** So one of these is
true and the next step is to find out which, not to guess:

1. the print is sampling something other than what it appears to — it fires on
   `posedge clk_cpu` while `m1_tgp` runs on `m1_main`'s `clk`; the bench drives them
   from the same signal, but that should be confirmed rather than assumed;
2. the capture happens and is then overwritten before the store consumes it, by a path
   not visible in a grep for `src_val` — a hierarchical or generate-scoped assignment;
3. `x_src_sp` is not `EP_IO` at the capturing edge even though it was during the wait,
   so the mux selects `mem_rdata` (which would be stale) instead of `io_rdata`.

**(3) is the cheapest to test and fits the evidence best**: `0x10` and `0x20` are the
low bits of the io address, and `mem_addr`/`ea_src` carry exactly that. Print
`x_src_sp`, `mem_rdata` and `io_rdata` together on the acknowledge edge.

### Why this took a value-level instrument to find

Every read-side diagnostic said the data was right: the boot trace prints
`TGP data read 1: sdram word 300020 -> 00000030`, the io census showed the correct
addresses, and `m1_cdc_port` is provably fine. The error is in the consumer, one cycle
after a correct read, and only comparing the STORED values against the reference exposed
it. `tgp_trace` reported it 578 instructions later as a branch going the wrong way.

## The instrument was subsampling: a filtered print cannot show a transition

Chasing `src_val` taking the io address instead of the io data, the trace came out
self-contradictory:

    st=4 sp=2 io_ack=1 io_rdata=00000030 mem_rdata=00000000 src_val=00000010 ea=08010
    st=3 sp=2 io_ack=0 io_rdata=00000030 mem_rdata=00000000 src_val=00000020 ea=08020

At the acknowledge every term of `S_SRC_W`'s guard is satisfied — `sp=2` is `EP_IO`,
`io_ack=1`, `mem_stall=0` — so `src_val <= io_rdata` should take `00000030` and the state
should advance to `S_DST`. The next line shows `src_val = 00000020`, and **nothing else in
`mb86233_core` writes `src_val`** (only two assignments exist, and the register path was
not taken).

Two explanations were eliminated by measurement rather than argument:

- **the print's clock.** `tb_m1_boot` instantiates `m1_main` with `.clk(clk_cpu)` and the
  TGP is not `ce`-gated, so a `posedge clk_cpu` print sees every TGP cycle. Sound.
- **the wrong mux leg.** `mem_rdata` is `00000000` at that edge, so selecting it would
  give zero, not `0x20`.

**The fault was the filter.** The print fired only on `io_rd && io_addr[15]` — the cycles
*during* an io read. `S_DST`, `S_RETIRE`, `S_FETCH`, `S_FETCH_W` and `S_DECODE` were never
printed, and those are exactly the cycles between the two lines. A subsampled trace cannot
show where a value changes; it can only show that it did, which invites inventing a
mechanism for the gap.

**Rule: to find where a signal changes, print every cycle in a bounded window — never a
filtered subset.** The filter is for finding the window, not for reading it.

The next instrument is therefore: trigger on the first `io_addr == 0x8010` with
`io_ack`, then print **every** cycle for the following ~40, unfiltered. That shows the
capture, the store, and anything in between.

## The store is CORRECT: write 22 is an extra pass, not a wrong value — 2026-08-19

The unfiltered 40-cycle window, armed on the acknowledged io `8010` read:

    W0 st=7 (S_DST)   src=00000030  mw=1  maddr=00069
    W1 st=8 (S_DST_W) src=00000030  mw=1  maddr=00069

`src_val` holds `00000030` — the correct data-ROM word — and the store writes it to
`data[0x69]`. **The capture and the store are both right, and there is no datapath
fault.** The three mechanisms invented for a "lost value" were explaining something that
never happened.

So `tgp_wrtrace`'s `TW 0069 00000000` at write 22 is a **different, earlier store**, and
the correct one is write 27. The divergence is therefore about **which stores happen and
in what order**, not about a corrupted value:

| | write 22 | write 27 |
|---|---|---|
| reference | `data[0069] = 00000030` | `data[0069] = 00000030` |
| ours | `data[0069] = 00000000` | `data[0069] = 00000030` |

Writes 1-21 match exactly. At 22 the reference has already completed its io read and
stores the word; we store zero at that point and only reach the correct store at 27. So
**our TGP passes through that store once more than the reference does**, or reaches it
before the read that should precede it.

### Third time today our side looked wrong and was not

After the `ffffffff` copro RAM write (correct — the reference writes it too) and the copro
RAM contents (correct — written, not uninitialised). The pattern is consistent enough to
state as a rule: **"ours looks odd" is not a fault until the oracle disagrees**, and the
disagreement has to be about the same event, not a similar-looking one.

### What to measure next

Not the datapath. Compare the **instruction stream around write 22** against the
reference: `tgp_trace` matched for 342 instructions in a 3-second window, but the extra
store means the streams diverge in *control flow* somewhere before that write. Run
`tgp_trace` with a window that reaches it and diff the PCs immediately preceding the two
stores to `0x69`.

## The PC settles it: same instruction, first read returns 0 — 2026-08-19

With the PC carried on every write (and MAME's `GENPC` being the NEXT instruction, so
its annotation reads one ahead of ours for the same store):

    ref   write 22:  TW 0069 00000030 pc=07e8    instruction 0x07e7
    ours  write 22:  TW 0069 00000000 pc=07e7    instruction 0x07e7
    ours  write 27:  TW 0069 00000030 pc=07e7    the SAME instruction again

`07E7` is `mov (bx0) (e), $0x69` — read io, store to data. **Both sides execute it twice.
The reference gets `0x30` both times; we get 0 the first time and `0x30` the second.**

So it is a value bug after all — a **first-read fault in the coprocessor data-ROM path** —
and the "extra store" reading of the previous entry is withdrawn. Same address, same
instruction, different data.

### Why the boot print said the data was fine

`BOOT: TGP data read 1: sdram word 300020 -> 00000030` comes from the testbench's OWN
capture, which samples through `dat_ack_d` — **one cycle after the acknowledge**. The DUT
samples **on** the ack cycle. The tb's comment beside that capture says so outright:

> *"Sampled the cycle AFTER the acknowledge. `a_dout` is registered and updates on the
> same edge as `a_ack`, so a non-blocking capture at that edge takes the PREVIOUS value."*

I read that as reassurance that the data path was healthy. It is the opposite: it is a
note that the tb had to work around a one-cycle offset, and the DUT does not.

**So the suspicion raised early this morning and dismissed was right**, and it was
dismissed on the strength of a diagnostic that measures a different cycle from the one
that matters.

### What to check, precisely

Whether `t_mem_rdata` is valid **on** the `t_mem_ack` cycle or the one after, in
`m1_cdc_port`. Then whether `m1_integrated` — the hardware path — has the same alignment
as `tb_m1_boot`. If they differ, this is simulation-only or hardware-only, and this
session has already found two of those.

## WITHDRAWN (the decode is CORRECT): `ldi #0x8000, b0` is mis-decoded — 2026-08-19

Armed on the instruction and printing every cycle, `07E6` executes and **`rf_wr_en` is
never asserted**:

    W0..W12  pc=07e6  st = 1,2,3,4,5,6,9,9,9,9,9,9,10   rfwe=0 throughout

States 5 and 6 are `S_LABB`/`S_LABB_W`, with `sp=1` (`EP_DATA`) doing a data-space read at
states 3/4. **Our decoder routes this instruction down the `lab` path.** It is not a
`lab`. The word at `0x07e6` is `0x40008000`:

    opcode >> 26          = 0x10        MAME's ldi range, cases 0x10-0x1f
    opcode & 0xffffff     = 0x008000    the immediate
    (opcode >> 24) & 0x3f = 0x00        the destination register — b0

so it is exactly `ldi #0x8000, b0`, as the disassembly says. Decoded as something else,
the write never issues, `b0` stays `0x0000`, the operand `(bx0)` addresses io `0x0000`
instead of `0x8010`, the read returns 0, and the store writes it.

### The chain, end to end

    ldi #0x8000, b0 mis-decoded
      -> b0 = 0 instead of 0x8000
      -> (bx0) addresses io 0x0000, not 0x8010
      -> the data-ROM read returns 0
      -> data[0x69] gets 0 instead of 00000030          (tgp_wrtrace write 22)
      -> the FP chain at 06EE-070C computes on it
      -> `0731 brif ged` branches where the reference falls through  (tgp_trace 604)
      -> the TGP takes a different path and stops early
      -> it never writes the completion word to coprocessor RAM
      -> the V60 spins at FED5A4 forever                (1,120,224 polls)
      -> it never reaches the per-frame 2D work
      -> no text

**Every link measured.** `tgp_trace` reported the sixth line; the fault is in the first.

### What to check before fixing

`mb86233_dec` passes 3,000,000 fuzz checks with `uncovered=0`, so either this encoding is
not generated by the fuzzer or its reference shares the misreading. **Find out which
before changing the decoder** — if the reference model agrees with the DUT, fixing the DUT
will break the suite and the suite is what would have caught this.

MAME's disassembler switches on `opcode >> 26`; cases `0x10`-`0x1f` are all `ldi`, with the
immediate in `opcode & 0xffffff` and the register in `(opcode >> 24) & 0x3f`. Compare that
against `mb86233_dec`'s primary decode and against `sim/tgp/mb86233_ref.cpp`.


---

## ROOT CAUSE: the bench released the CPU before the microcode finished loading — 2026-08-19

**Instrument:** a windowed per-cycle print in `tb_m1_boot.sv`, armed on `seq_pc == 0x07e5`,
dumping `pc`, `ir`, the sequencer state, the loader's `uc_addr`/`uc_we`/`uc_done` and
`prog[0x07e6]` *as it stood at that cycle*.

**Correcting:** the entry above, which said the decoder routed `ldi` down the `lab` path.
It does not. `mb86233_dec` was right, and its 3,000,000-case fuzz suite was right to pass.

The microcode loader advances four addresses per CPU cycle — 100 MHz against 25 MHz — so
2048 words take 512 CPU cycles. The coprocessor was released at the same instant and
reached microcode address `0x07e6` while the loader was still at `0x07c6`:

    W13 pc=07e6 ir=1c1c842e st=1 paddr=07e6 prd=40008000 ucwe=0 ucaddr=0000 ucdone=1 pr7e6=40008000

`prog[0x07e6]` was **genuinely zero at the moment of the fetch**, and correctly populated
by the time anything checked. A zero word has `opcode[31:26] == 0`, which is `is_lab` — so
`ldi #0x8000, b0` was fetched as `00000000` and executed as a `lab`. The disassembly was
right, the decoder was right, and the fetch returned a different word than either was
looking at.

**This is why the `UCODE CHECK` added the same morning kept passing.** It verified all 2048
words *after* the run; the defect existed only during a 512-cycle window at reset. An
instrument that samples the wrong instant reports the wrong answer confidently.

### One line, and it is simulation-only

    wire rst_n_cpu = rs_cpu[1] & uc_done;      // was: rs_cpu[1]

`m1_integrated` states the contract in its own comment — *"Complete before the CPU is
released, so there is no crossing to handshake"* — and hardware honours it, because
`m1_rom_loader` streams during the ioctl download and the CPU waits on `rom_loaded`. The
bench never did. **Fourth simulation-only divergence found in one day**, after the copro
RAM initialisation, the `a_dout`/`a_ack` capture offset and the loader restart.

### Every symptom chased that day was this one race

    b0 never written -> (bx0) addresses io 0x0000 not 0x8010 -> data[0x69] = 0
      -> the FP chain diverges -> 0731 brif ged branches -> the TGP stops early

`tgp_wrtrace`'s "extra store at write 22", `tgp_trace`'s "divergence at instruction 604",
the "wrong io address" and the "mis-decode" were six accurate descriptions of one cause.
**A chain of correct observations is not a diagnosis** — each was a link, and the instrument
that found the head was the only one that sampled reset.

### What it bought, measured

`make m1_boot` at 1.5 B cycles, before and after:

| | before | after |
|---|---|---|
| TGP retires | stops early | **49,518**, `unimplemented=0` |
| TGP io accesses | — | **1,401,155** completed, not stuck |
| V60 -> TGP pushes | — | **561** |
| TGP -> V60 returns | — | **232**, V60 pops 217 |

The coprocessor now runs real microcode to completion and returns results. **It was worth
the day.**

### It did NOT fix the text, and the next cause is already measured

The V60 still ends at `fed5a4`, in a three-instruction loop `fed5a4 -> fed5a7 -> fed5a9`,
reading the coprocessor RAM data port **6,221,996 times**. `[5000]`-`[5007]` are all zero
and the row mask is still `0/2048`.

**MAME never executes `FED5xx` at all.** A 4-second reference trace, cold nvram, contains
zero instructions anywhere in that page:

    grep -ic "fed5" mame.tr   ->  0

So this is not the coprocessor failing to answer a poll the reference also performs — it is
our V60 reaching code the reference never reaches. That makes it a **V60 divergence**, and
`make v60_trace` is the instrument for it. Do not debug the coprocessor further on this
symptom.

---

## SIX real TGP defects, found by the microcode oracle, none by the fuzz suites — 2026-08-19

**Instrument:** `make tgp_wrtrace` — the TGP's data-memory write stream diffed against
MAME's, now carrying `x0`, `a` and `d` alongside each write.

The V60 was spinning for ever at `FED5A4`, a poll on coprocessor RAM word 0 waiting for its
low byte to read zero. The reference enters that loop 41,521 times in eight seconds and
leaves it every time; ours entered once and stayed. Every defect below sat between those
two facts.

| # | defect | first divergence |
|---|---|---|
| 1 | `lab` loaded neither A nor B — the second read was issued and discarded, and `lab_a_val` was assigned and read by nothing | write 38 |
| 2 | the AGU post-increment fired once per **cycle**, not once per access | write 42 |
| 3 | `lab`'s B operand was addressed with the A operand's field (`r1`/bank 0 instead of `r2`/bank 1) | write 65 |
| 4 | a parallel ALU op computed on the transfer's **new** operand; MAME's `alu_pre` runs before the transfer | write 90 |
| 5 | the four math units — sincos, atan, inv, isqrt — were never implemented and returned the quadrant base word | write 102 |
| 6 | `lab`'s A side dropped its `+0x200`, addressing the **command FIFO** at 0x106 instead of RAM at 0x306 | (deadlock, no writes) |

`tgp_wrtrace` then reported **IDENTICAL for 110 writes**.

### Every suite stayed green throughout

All eleven TGP suites pass byte-identically before and after all six fixes — including
`mb86233_core`'s 8,000-retire lockstep at `diverged=0`. That is the third time this
lockstep has been cited as evidence and found not to be: it never generates a `lab` whose
registers are read afterwards, never a transfer into a register its own ALU op reads, and
never a stalling memory. **`diverged=0` from that suite is not evidence about any path it
does not generate.**

`mb86233_agu` is the sharper lesson. Three million cases, `uncovered_modes=0`, and defect 2
walked straight through it — because the suite tests the AGU as a combinational function,
*given r produce ea and x_next*, and the defect is in WHEN the core applies it. Nothing in
the suite has a stalling memory.

### Defect 2 is the FIFO bug again

`agu_post_en` was `(state == S_SRC_W) || ...`, and those states are held while the access
completes. The external reads wait eight and nine cycles — the boot trace has printed
`TGP io 2: R 8010 waited 8` since the beginning — so x0 advanced by 9 and by 7 where the
reference advanced by 1. **Those are the wait counts, not increments**, and they looked
exactly like a wrong `i0`.

The coprocessor FIFO had the identical fault a day earlier: one pop per cycle instead of
one per access. Two instances of one mistake in two modules. **Wherever a held state
drives a side effect, the side effect needs the completion condition, not the state.**

### Fixing a dead path turns its silent consumers into faults

Defect 1 made `lab` write its registers; defect 3 appeared one instruction later in the
same trace, because the B-side addressing had been wrong all along and nothing had ever
read the result. Defect 6 is the same shape again — unreachable until the branch at `0731`
went the right way. That is the fix working, not a regression, and it is worth expecting:
each repair moved the divergence forward rather than resolving it, 38 → 42 → 65 → 90 →
102 → identical.

### What it bought

`make m1_boot`, 1.5 B cycles:

| | before | after |
|---|---|---|
| scroll `[5002]` / `[5006]` | `0000` / `0000` | **`0044` / `2305`** |
| row mask 0x6000 | 0/2048 | **336**/2048 |
| copro sync word cleared | 62 | **14,308** |
| TGP io accesses | — | 596,454 |

`0x2305` is mode 1 on tilemap pair 2/3 — the vertical window split that draws the horizon —
and it is what MAME shows on the same frame. **The row mask has never been non-zero in this
core before.**

### Withdrawn in the making

- *"MAME never executes FED5xx"* — it executes `FED5A4` 41,521 times. The claim came from a
  four-second trace and the routine is first reached at 5.2 s. A window too short to
  contain the event reports "never" exactly as confidently as a real absence.
- *"The TGP is halted"* — `dbg_tgp_retires` counts something narrower than retires. The
  instruction trace showed 3.4 M against the reference's 3.42 M.
- *"`ldi #0x8000, b0` is mis-decoded"* — the decoder was always right; see the entry above.

---

## The window-mode scroll and split are CORRECT — four re-derivations, ruled out — 2026-08-19

The board now moves: with the TGP fixed, the tilemap control words are written and the
horizon scrolls. It scrolls **wrongly** — the sky runs off the top and palette 0 fills the
bottom half — and the obvious suspects are all innocent. Recorded so the next session does
not spend the evening re-reading `segaic24.cpp` as this one did.

**1. `neg_vscr = -ctrl_r` is not a bug**, though it reads like one against the comment
directly above it, which says `v = (-vscr) & 0x1ff`. MAME reads

    hscr = tile_ram[0x5000 + (layer >> 1)]
    vscr = tile_ram[0x5004 + (layer >> 1)]
    ctrl = tile_ram[0x5004 + ((layer >> 1) & 2)]

so `ctrl` and the EVEN map's `vscr` are **the same word** — 0x5004 for pair 0/1, 0x5006 for
pair 2/3. `-ctrl_r` therefore already is `-vscr_even`, which is what the window branch
uses. This was one edit away from being "fixed" into a real defect.

**2. The scroll signs are correct, in both modes.** MAME's non-window path sets its source
origin to `hscr = (-hscr) & 0x1ff`, `vscr = (+vscr) & 0x1ff`, i.e. `map_x = x - hscr` and
`map_y = y + vscr` — which is `m1_tile_decode.sv:97-98` exactly. The window path instead
calls `set_scrollx(0, -(hscr & 0x1ff))` and `set_scrolly(0, vscr & 0x1ff)`. Those look like
the opposite convention and are not: `-(hscr & 0x1ff)` and `(-hscr) & 0x1ff` are equal mod
512, and the tilemap is 512 wide, so `set_scrollx(S)` must mean `source_x = x + S` for the
two paths to agree. Both reduce to `map_x = x - hscr`. **MAME's `src/emu/` is not in the
bootstrap checkout**, so this was settled by requiring the two paths to be consistent
rather than by reading `tilemap.cpp` — worth confirming against upstream if it ever matters
more than it does here.

**3. The window register sources are correct.** `f_hscr`/`f_vscr` take the even map's
registers for both maps of the pair, which is what lines 359-361 and 420-421 do.

**4. The split-line arithmetic is correct.** With the measured `ctrl = 0x2305`: mode is
`(0x2305 >> 13) & 3 = 1`; `v = (-0x2305) & 0x1ff = 251`; bit 9 of `-0x2305` is clear so
`layer ^= 1`. Rows 0-250 draw the ODD map and 251-383 the EVEN one, which is what
`win_swap`/`win_pick` compute.

### So the fault is that one map draws nothing in its own half

The bottom half is palette 0, which is the backdrop showing through where tilemap 2 should
be. That is a layer failing to produce pixels in a region it owns, not a scroll or a split
computed wrongly.

Two things in `draw_common` gate a layer entirely and are worth checking against our
implementation before anything else:

    if(vscr & 0x8000) return;        // whole-layer disable, per layer
    if(layer & 1)     return;        // in window mode the ODD map's own pass draws NOTHING

The second is the one to check hardest: the pair is drawn **entirely by the even layer's
call**, so if our per-layer pipeline lets tilemap 3's own pass run, it draws over the
region tilemap 2 owns rather than leaving it. `docs/HANDOFF.md` records odd-map suppression
as implemented; confirm it covers the *fetch* as well as the *mix*.

**Measure before changing anything.** `manager.machine.video:snapshot()` on a known frame,
against ours on the same frame, plus a per-frame census of `[5000]`-`[5007]`. Four
plausible causes have already been ruled out here by reading, and reading is what produced
three withdrawn findings today.

---

## LOOK AT THE VIDEO. Both maps render correctly; they are never on screen together — 2026-08-19

A phone video of the board, frames extracted with `ffmpeg -vf fps=2` and read directly,
overturned two conclusions reached the same evening from reading `segaic24.cpp` and the
boot dump.

**What the frames show:**

- one frame has **sky, with clouds**; others have **sea, with full wave texture**
- both are *correct artwork* — tile fetch, tile decode, palette and the character ROM path
  all work, which no register dump had established
- they **alternate frame to frame** rather than appearing together
- each frame shows one map over roughly the top 40%, then flat colour bands below with
  razor-sharp horizontal edges at the split lines

**So the fault is that the two maps of a pair are never live at once.** The window split
selects one map for nearly the whole picture and flips which one as `ctrl` changes. The
entry above concluded "tilemap 2 is selected for the bottom half and produces no pixels
there" — it produces excellent pixels, and that conclusion is withdrawn.

### The instrument was sitting unopened for hours

`docs/2d-gap-analysis.md` lists `manager.machine.video:snapshot()` for exactly this, and
the user had already said the sea and sky were "jumping up and down". Five candidate causes
were ruled out by reading source in the time it would have taken to extract eight frames.
**A photograph or a video of the board is a measurement, and `ffmpeg` + the Read tool make
it a cheap one** — `ffmpeg -v error -i clip.mp4 -vf "fps=2,scale=640:-1" -frames:v 8
out%02d.png` and read the PNGs.

This is the same lesson already recorded as "when a measurement says never, check the
instrument could have seen it", in a new costume: a register census cannot tell correct
artwork from a blank layer, and only the picture can.

### Where to start

Why is only ever ONE map of the pair live? `win_suppress` is
`win_mode && win_vsplit && (cur_layer[0] != win_pick)`, and `win_pick` flips at
`cur_line == win_v`. Confirm on real scanlines that both parities clear the suppression
within one frame — if `win_v` lands at 0 or beyond 383, one map wins everywhere, and the
alternation is then `win_swap` toggling with `ctrl`.

### The blue band appears DURING the jump, and that rules out the suppression logic

Observed on the board, 2026-08-19: sea and sky are both on screen together with no blue
band; then the picture jumps up, a blue band appears; then it keeps jumping up and down,
and when both maps show again the band is gone.

**A gap means scanlines where NEITHER map paints.** `win_suppress` is

    win_mode && win_vsplit && (cur_layer[0] != win_pick)

and `win_pick` is a single bit per scanline, so exactly one parity is live on every line by
construction. **This logic cannot open a gap.** Two candidates remain:

1. the two layers' passes compute `win_pick` from **different values** — `ctrl_r`,
   `win_v` or `cur_line` not identical between the even and odd pass of the same frame,
   which would let both suppress on the same line. `ctrl_r` is refetched per layer from
   the same address, so a mid-frame write to `0x5006` between the two passes would do it,
   and the game writes that word every frame.
2. the map that owns those lines is scrolled onto **empty rows of its own tilemap**, so it
   paints transparent and the backdrop shows. That is a vertical-scroll or wrap fault, not
   a suppression fault.

Candidate 1 is the one to test first, and it is cheap: latch `ctrl_r`/`win_v` once per
FRAME rather than per layer pass and see whether the band closes. MAME reads the register
once, at the top of `draw_common`, for a call that draws both maps — our per-layer pipeline
reads it twice, and nothing guarantees the two reads agree.

### MEASURED: the video logic is innocent — we write the WRONG scroll values

`tools/mame_scroll_census`-style Lua on the reference, frames 280-292:

    frame  280  5000..5007 = 0000 0000 0025 0000 0000 0000 2062 0000
    frame  282  ...                    0025 ...                2061 ...
    frame  292  ...                    0025 ...                205c ...

against ours from `make m1_boot`:

    [5000]=0000 [5001]=0000 [5002]=0044 [5003]=0000
    [5004]=0000 [5005]=0000 [5006]=2305 [5007]=0000

**`[5006]` is 0x2062 in the reference and 0x2305 here, and that one word explains the
whole picture.** Work it through `draw_common`:

    reference   v = (-0x2062) & 0x1ff = 414   > 383, so the split is BELOW the screen:
                c1 keeps rows 0..383, c2.min_y becomes 414 and is EMPTY
                bit 9 of -0x2062 is SET, so no swap
                -> ONE tilemap fills the whole screen, vertical scroll 0x2062 & 0x1ff = 98

    ours        v = (-0x2305) & 0x1ff = 251   mid-screen, so the screen SPLITS
                bit 9 of -0x2305 is clear, so the maps SWAP
                -> tilemap 3 on top, tilemap 2 below, and the boundary jumps as ctrl moves

The reference's horizon drifts smoothly because `[5006]` decrements by one every two
frames, 0x2062 -> 0x205c. Sky and sea are BOTH IN ONE TILEMAP; there is no split at all at
this point in attract. Ours splits the screen and alternates the maps, which is exactly the
banding filmed on the board.

`[5002]` differs too: 0x0025 against 0x0044.

**So the window-mode implementation is not the bug.** Five suspects were ruled out by
reading and a sixth by arithmetic; the values feeding them are wrong. This is upstream
program state — what the V60 computes from the coprocessor's results — and no further
tilemap work will move it.

**Where to go:** `tgp_wrtrace` is identical for the 110 writes our side produces and then
stops because our side stops producing. Extend the window until it diverges again, or trace
the V60's writes to 0x70A00C (word 0x5006) and diff against MAME's writes to the same
address. The second is the more direct instrument and `install_write_tap` on the maincpu
program space is what does it.

### The scroll word is `mode | (scroll & 0x3ff)`, and only the scroll half is wrong

`install_write_tap` on 0x70a00c in the reference: the word is written twice a frame, from
`FFE466` and `FFE27A`, creeping 0x2064 -> 0x205d over the frames sampled. `FFE466`'s
producer:

    FFE44B: mov.h R28, R27
    FFE44E: add.h 50141A, R28      R28 += work RAM
    FFE455: shl.h #FF, R28         >> 1
    FFE459: and.h #E000, R27       keep the mode bits
    FFE45E: and.h #3FF, R28        keep TEN bits of scroll
    FFE463: or.h  R27, R28
    FFE466: mov.h R28, 70A00C

So `[5006] = mode | (scroll & 0x3ff)`.

    reference   0x2062   mode 0x2000, scroll 0x062 = 98
    ours        0x2305   mode 0x2000, scroll 0x305 = 773

**The mode half is correct on both.** Only the scroll value differs, and it comes from work
RAM at 0x50141A and 0x50140E — which is downstream of the coprocessor's geometry, not of
anything in the video path.

Note the field is masked to **0x3ff, ten bits**, while `draw_common` masks vscr to 0x1ff.
Bit 9 therefore survives into the register and is what selects the map swap, so a scroll
value that is merely too large does not just shift the picture — it flips which map is on
top and moves the split into the visible area. That is why one wrong number produces
banding rather than a displaced horizon.

### The 60,000-write comparison: divergence at 4122, reading the command FIFO

Both write caps were 4,000 — `mame_tgp_wrtrace.lua` and `tb_m1_boot`'s `tw_n` — so
"IDENTICAL for 4000 writes" meant "identical for as far as either instrument looked".
Raised to 60,000 on both sides with a 16-second reference window:

    tgp_wrtrace: DIVERGES at write 4122

and the divergence is that **we write zeros where the reference writes geometry**:

    0436: ldi #0x100, x0
    0437: ldi #0x120, x1
    0438: rep #0xc
    0439: mov (x0), (x1+1)+0x200      12 words, (x0) with x0 = 0x100

`0x100` is the **command FIFO** (`copro_fifo_in`, model1_m.cpp:129), so this copies the
V60's twelve-word command block into data RAM at 0x320. The reference gets
`c34e5382, 41f15c2c, 408ac7be, ...`; we get twelve zeros.

**The V60's command stream is correct where it has been checked.** A program-space write tap
on 0xd80000 in the reference gives, assembled from 16-bit halves,

    0400_0000  0100_0000  3f40_0000  428c_0000  0100_0000  3f40_0000  428c_0000

and `make m1_boot` prints exactly that sequence. So the early commands agree and the
divergence at write 4122 is later in the stream — either the V60 stops sending, sends
different data, or our FIFO returns zero where the reference's would stall.

**That last one is worth checking first.** MAME's FIFOs are a mutual interlock: reading an
empty input FIFO stalls the coprocessor. If our data-space route for 0x100-0x1ff ever
completes a read instead of stalling, an empty FIFO reads as twelve zeros and the
coprocessor carries on with them — which is precisely the symptom. `m1_tgp`'s `io_ack`
has an unqualified final `else` that acknowledges anything unmapped, and a
mis-decode into that arm would ack immediately with `io_rdata = 0`.

### The V60's command stream is CORRECT — it just never stops

`tools/mame_copro_push.lua` dumps the V60 -> TGP command stream as 32-bit words for diffing
against `tb_m1_boot`'s `COPRO PUSH` lines. Over a 900-frame reference window:

    command streams IDENTICAL for 61 commands
    reference total: 61      ours total: 65535 (our counter saturates)

**Every command the reference sends, we send, in the same order, with the same values.** We
then send tens of thousands more. The reference issues 61 commands in fifteen seconds and
stops; ours never stops.

That reframes the remaining defect completely. It is not that the V60 computes the wrong
geometry — the geometry is right. It is that our V60 keeps re-issuing work the reference
issues once, which is consistent with it ending in the `FED5A4` poll and something
re-triggering the send. The twelve zeros at TGP write 4122 then follow naturally: by that
point the two machines are in different places in the program, and comparing write 4122 of
one against write 4122 of the other stopped being meaningful several thousand writes
earlier.

**Instrument note.** The V60 writes the FIFO through PROGRAM space while reading it through
IO — `in.w` only appears in `AS_IO`. A write tap on the IO space returns nothing while
looking exactly like a working instrument, which is the same trap as the program-space read
census that concluded the V60 never touches the coprocessor. Tap the space that matches the
DIRECTION.

**Next:** `make v60_trace` with `tools/v60_resync.py`, now that the coprocessor returns
correct results. The earlier run found only interrupt-phase slips over 100,000 instructions
because the TGP was feeding it wrong data; with the data right, a structural divergence
should be visible and will say why the V60 loops.

### v60_trace after the TGP work: zero divergence sites

Re-run with `tools/v60_resync.py` now that the coprocessor returns correct results:

    --- compared 25685/1654754 reference and 25685/25685 our instructions
    --- IDENTICAL over the whole compared range

This afternoon the same instrument reported **304 divergence sites** over 100,000
instructions. Now there are none, and 52 collapsed loops are in common with **51 running
identical counts**. The single exception is the documented one:

    at 24804   fe022c,fe0232   MAME 36308   ours 41147   (+13.3%)

the I/O board handshake, 18 CPU cycles an iteration against the reference's 17, on a
deadline correct in cycles to within 38. Known, measured, benign.

**The window is the limit, not the agreement.** 700 M cycles reaches 25,685 collapsed
instructions while the boot runs to 1.5 B, so whatever makes us re-issue commands lies
beyond what was compared. Run `v60_trace` at `CYCLES=1500000000` with a 16-second reference
to reach it.

Note the collapsed count went *down* as the window grew earlier in the day — 50,923 at
200 M cycles against 25,685 at 700 M. That is not a contradiction: the collapse keeps one
instance of each repeating period, so a machine spending more of its time in loops yields
*fewer* collapsed lines. It is itself a signal that our core is looping more than the
reference beyond the compared window.

### The text routine RUNS on our side — it copies different strings

`v60_trace` at `CYCLES=1500000000` reports `IDENTICAL for 25685 instructions` and
`v60_resync` finds zero divergence sites, but our side yields **25,685 collapsed
instructions at both 700 M and 1.5 B cycles** while the reference reaches 5,193,988. The
agreement is real and the window is the whole story.

**The collapse hides a loop that only one side has.** `v60_trace` collapses both streams to
one instance per repeating period, so a loop present in ours and absent in MAME leaves the
PC sequences identical and is reported only in the counts file — and only if BOTH sides
collapsed it, since the comparison is over loops "in common". That is a blind spot in the
instrument, not in the design.

The counts file is where the difference lives:

    ours   ff8ac3,ff8ac6,ff8ac8,ff8aca,ff8acd   counts 6, 7, 8, 9, 10, 13, 14 ...
    MAME   ff8ac3,ff8ac6,ff8ac8,ff8aca,ff8acd   count  20, consistently

and that loop is:

    FF8AC3: mov.b  [R0+], R2      load a byte
    FF8AC6: test.b R2
    FF8AC8: be     FF8ACF         stop at the NUL
    FF8ACA: mov.h  R2, [R1+]      store it as a HALFWORD
    FF8ACD: br     FF8AC3

**A null-terminated string being written out as 16-bit tile codes: this is the text
routine.** It executes on our side, repeatedly, and copies six to fourteen characters where
the reference copies twenty.

So text IS being generated. The strings differ in length, which means either the source
pointer differs or the string content does — and the strings on this screen are built in
RAM (`CREDIT 0`, the ranking table) rather than read straight from ROM.

**Next:** capture R0, R1 and the copied bytes on both sides at FF8AC3. A write tap on the
destination range plus the same in `tb_m1_boot` gives the two strings side by side, and the
lengths alone (20 against 6-14) should identify which string each side thinks it is
drawing.

## SPEED: 35.0 -> 23.7 cycles per instruction, and where the rest goes — 2026-08-20

The core ran about **2.3x slower than the reference**. That is slow motion on the board, and
it also made every frame-indexed comparison against MAME meaningless — most of the "our
`[5006]` is 0x2305 against MAME's 0x209b" confusion came from comparing frame N of a machine
running at half speed against frame N of one running at full speed.

### The instruction cache, measured before it was built

Modelling the reference's own 31-million-PC trace offline, for an 8-byte line:

    1 line  (   8 B)  32.1% hit      2 lines (  16 B)  99.0% hit
    4 lines (  32 B)  99.2% hit      8 lines (  64 B)  99.6% hit

One line thrashes because the V60 alternates between two — an instruction straddling a
boundary fetches N and N+1 in turn — so 32% is the floor. Built 8 lines, direct-mapped.

    instructions        10,716,101  ->  15,838,344
    cycles/instruction       34.99  ->       23.67
    ifetch lines        13,810,468  ->   3,472,976   (-75%)
    fetch-stalled              34%  ->         13%

The real hit rate is 75%, not 99%: the model had one PC per instruction while the core
issues several fetch requests per instruction. The prediction still earned its keep — it is
what said two lines would work and one would not.

### Where the remaining time goes, measured

Per-page data-bus latency, from `m_req` rising to `m_ack`:

    100000  n=118940  avg=36        200000  n=32768  avg=36
    110000  n=83563   avg=36        210000  n=32768  avg=36
    120000  n=131064  avg=36        ...every page identical...

**Every page costs the same 36 fast cycles — 9 CPU cycles — whether it is BRAM or SDRAM.**
That is not memory latency; it is fixed handshake overhead, and it is why the page histogram
was useless for this question: 4.3 M cheap accesses and 1 M expensive ones look identical in
a count.

The 9 decomposes exactly:

    T0  adapter I_CYC asserts m_req
    T1  m1_main B_IDLE sees it, goes B_LOCAL
    T2  BRAM data valid, ack_r set, goes B_ACK
    T3  adapter sees ack, drops m_req, advances
    T4  m1_main sees req low, returns to B_IDLE      = 4 cycles per 16-bit cycle

and `v60_bus` splits a 32-bit access into **two** 16-bit cycles (three if unaligned), so
2 x 4 + entry = 9.

### What it would take to reach real time

At 25 MHz the target is ~12.5 cycles/instruction to match the reference's ~2 M
instructions/second. We are at 23.67, of which 54% is stall (41% data, 13% fetch). **Pure
execution is already ~11 cycles/instruction**, so removing the stalls entirely would reach
real time — the CPU core itself is fast enough.

Two levers, both real work:

1. **Shorten the handshake**, 4 cycles to 3, by letting `m1_main` accept a new request in
   the cycle it acknowledges. Risk: the "acknowledges must be held, not pulsed" rule exists
   because the requester is `ce`-gated. `ce_cpu` is tied high today, so the rule is
   currently slack — but it is slack, not gone.
2. **A 32-bit local data path**, halving the bus cycles per access. Bigger change:
   `v60_bus`, `m1_main`'s routing and the memories' ports.

Together those are roughly 2x and would land the core at real time. Neither should be done
in a hurry: the bus is the one thing in this core that every other block depends on.

### The V60 is NOT the bottleneck — a retire-to-retire histogram says so

Asked whether splitting the V60 would cut CPI the way splitting the i960 did on Model 2
(9 -> 3.4). Measured instead of judged, 9.6 M instructions:

     3 cycles   654,431   6%     <- I-cache hit, no data access: THE FLOOR
     7-8        602,853   6%
    10        1,883,483  19%
    12        2,101,037  21%     <- 3 + 9, one data access
    26        1,875,743  19%     <- 3 + two accesses
    35          514,236   5%
    mean 18.4   median 12

**The V60 retires in 3 cycles when it hits the instruction cache and touches no data.**
Every cluster above that is the 3-cycle base plus multiples of the ~9-cycle bus access.
Splitting the core would attack the 3, which is already small, and leave the 9s untouched.

**This corrects the entry above.** "Execution-only CPI is ~10.9" was computed as
`(1 - stall%) x 23.67` and is wrong: the stall counters do not capture all of the memory
wait. The histogram is the better instrument, and the conclusion drawn from 10.9 — that the
bus alone could not reach real time — does not hold.

Take the access from 9 cycles to ~4 and the 12-cluster becomes 7, the 26-cluster ~11, and
the mean lands near 9-10 against a 12.5 target. **The bus is the whole problem.**

Keep the V60 split on the roadmap for area or Fmax if it earns its place there; do not
spend it on throughput on this evidence.

## SDRAM IS VERIFIED, and the copro RAM initialiser was the FED5A4 deadlock — 2026-08-20

### The deadlock: nothing ever writes the sync word

The V60 spins at `FED5A4` reading coprocessor RAM word 0 until its **low byte is zero**.
Hours went into "why does the coprocessor never clear it". **It never clears it in
simulation either** — `tb_m1_frame` reports `TGP writes to copro RAM=0` — and simulation
works because the array's initialiser makes word 0 zero to begin with. MAME does the same
thing explicitly: `model1_m.cpp:59` ends `device_reset` with
`memset(m_copro_ram_data, 0, 0x2000*4)`.

**There was never a signal to write.** Every reading of this as "the coprocessor fails to
signal completion" was backwards.

**And the board lost that initialisation the same morning, self-inflicted.** Quartus caps a
loop at 5,000 iterations, so when the RAM initialisers broke synthesis they were wrapped in
`` `ifdef VERILATOR ``. That kept the simulator working and silently removed the
initialisation from the DEVICE, so word 0 came up `ffff` and the V60 waited for ever.

The fix is **chunking, not guarding**: two loops of 4,096 are each under the cap and
initialise the inferred M10K exactly as one loop of 8,192 would. A clear-at-reset FSM was
tried first and reverted — gating accesses for 8,192 cycles broke `m1_copro_if`'s suite,
156 of 259 checks.

Result on the board: the V60 **leaves** `FED5A4` and reaches the tilemap copy routines, and
the sync word reaches `000`. Tilemap 0 still holds 4,096 **spaces** and no characters, so
the drawing path runs and produces blanks — that is the next question.

### SDRAM: verified across the whole image

Rows 07/0B fold at the **ioctl input**, before the FIFO, so they say the HPS delivered the
right bytes and nothing about what reached the chip. The read-back sweep on the spare port 4
closes that:

    row 0E   4D2E75   matches the image exactly, 1,081,344 words across all 8.6 M
    row 0C   000000   correct: port 4 is a SINGLE-WORD port, there is no high half

**Memory is not the fault.** Correct data in, correct data out.

Checked and ruled out alongside, from the kaneko port's findings: the **A10 auto-precharge**
fault does not apply — our `S_RD` drives A10 low on every read including single-word ones
and precharges explicitly — and `COL_BITS=9` on a 64 MB module addresses half of each row
self-consistently, which is why write-then-read matches.

### FOUR instrument faults in one day, every one caught by a control

1. The sweep's address was wired into `tb_m1_frame` and **never into `Model1.sv`**, so port
   4 read word 0 for all 8,192 bursts. Caught because a control region returned the
   *identical* checksum to the region under test — impossible for real data.
2. The sweep was clocked on `clk_cpu` while the SDRAM ports are `clk_sys`, and completed
   **one burst of 4,096** while producing a plausible-looking number. Caught by adding a
   burst COUNT.
3. Expected values were computed for a 4-word burst on a port that `blen()` gives **one**
   word. Caught because the "high half" read zero on both sides.
4. `pgrep -f quartus` matched a watcher belonging to a *different project*, and
   `pgrep -f "compile Model1"` matched the shell running that very string — reporting a
   build as running for 82 minutes after it finished. **The honest test is whether the log
   file is still growing.**

**The rule that follows:** every new instrument ships with a known-good case measured in
the same run. Three of these four produced confident, specific, wrong answers that survived
until a control contradicted them.

### Characters are WRITTEN on hardware, and none is ever VISIBLE

Measured on the board with the character-write census:

    row 0E  000315 and RISING with every jump   789 real characters and climbing
    row 0C  FC567D                              the same routine simulation uses

So the V60 reaches the drawing code, runs the same routine, and writes real characters into
tilemap 0.

**NO TEXT IS VISIBLE ON THE SCREEN AT ANY POINT.** Those are two different claims and
conflating them was wrong: "the text is drawn" was written here when what is measured is
that characters reach tile RAM. What the board shows is sky and sea for a split second, then
a jump with a blue bar across the bottom third, repeating. The renderer finds eight
non-blank words a frame, so whatever is written is not there when it looks.

That matches the PC: row 00 alternates between `FED5A4` (waiting on the coprocessor sync
word) and `FFE???` (the tilemap copy routines). Clear, draw, wait, clear, draw.

**The divergence to chase is row 0D.** On the board the coprocessor writes coprocessor RAM
thousands of times — the counter saturates at `FFF` — while `tb_m1_frame` reports
`TGP writes to copro RAM=0`. Something on hardware keeps re-arming the sync word to `ffff`,
which sends the V60 back to `FED5A4`, and the cycle repeats for ever.

Since the microcode is verified identical (row 02 matches the image byte for byte) and SDRAM
is verified across the whole image, the coprocessor is executing a different path from the
same code and the same data. Row 06's read checksum differs between board and model, which
says the same thing: it is issuing different reads. What is left that could differ is its
INPUTS — the command stream from the V60 — or the relative timing of the two machines,
which is not the same on silicon as against a memory model.

### At depth, board and simulation agree on everything but ONE number

`tb_m1_frame` at 1.5 B cycles against the board:

    non-zero row-mask writes   4095 saturated   |  FFF saturated      agree
    tilemap0 character writes  1680 from fc567d |  1155 and rising    agree
    TGP writes to copro RAM    4095 saturated   |  FFF saturated      agree
    copro SDRAM read checksum  bd686d           |  1e0da5             DIFFER

**Two more inferences withdrawn**, both from samples taken before the machines had got
there:

- *"The row mask is never populated on hardware"* — it saturates on both.
- *"The coprocessor writes copro RAM on hardware and never in simulation"* — that was a
  400 M-cycle sample. At 1.5 B it saturates on both, so there is no divergence in that
  behaviour and nothing is "re-arming" the sync word that does not also do so in
  simulation.

That is the fourth and fifth claim retired today for the same reason: **a counter read
before the machine reaches the code is indistinguishable from a counter that never moves.**
Every one of them looked like a specific, actionable difference.

**One measured difference remains:** row 06, the fold of the coprocessor's first 1024 SDRAM
reads. SDRAM itself is verified whole-image, and the microcode is verified byte-identical,
so the coprocessor is reading *different addresses* — not different data. What can still
differ is the order and timing of those reads, which is the one thing a memory model does
not reproduce.

**And the visible difference:** simulation renders the attract screen; the board clears,
draws, and jumps. With the text and the mask both written on hardware and the renderer
finding blanks, the viewport is landing on empty rows of the map — the scroll word is
rewritten every pass of the V60's loop instead of settling.

## SETTLED: the V60's FP group must stay — but the evidence is a RESERVED opcode — 2026-08-23

The rules file carried this as an unspent lever: "the V60 without its FP group is -2,984 ALM on
the full core. `dbg_fp_trap` has never fired, but only through boot and attract, and it is
inert by construction in a build that has FP — so that is not yet evidence."

**Measured, standalone, Quartus 17.0:**

    V60 with FP     20,614 ALM   Fmax 24.92 MHz
    V60 without FP  18,672 ALM   Fmax 45.98 MHz

So the group is 1,942 ALM — not the 2,984 recorded, which was a full-core figure — **and it
halves the Fmax**. It is on the critical path as well as being 6% of the core, which makes
it a bigger prize than the ALM alone suggested.

**And the run under the define says it cannot go:**

    V60: reserved FP opcode 5f at 00fed52b
    BOOT: *** FP opcode executed — S32_V60_NO_FP is NOT safe ***

**READ THAT CAREFULLY BEFORE CONCLUDING THE GAME USES FLOATING POINT.** It is a *reserved*
opcode, at `FED52B` — inside the `FED5xx` page that **MAME never executes a single
instruction in**, measured with a 4-second reference trace on cold nvram. So what this
proves is that our V60 reaches a region the reference never reaches and executes data as
code there; the FP decoder catching it is incidental.

Two things follow:

1. **The lever stays unspent.** Removing the group would turn that into a different wrong
   behaviour rather than a correct one, and 1,942 ALM is not worth a build that traps on a
   path the machine should not be on.
2. **It is another instrument pointing at `FED5xx`.** The V60 spinning there was read all
   week as a legitimate poll on the coprocessor sync word. A reserved opcode inside the same
   page is hard to square with that, and worth following.

## V60 area and speed: what each knob is actually worth — 2026-08-23

Every figure below is Quartus 17.0 on the V60 alone, and `make m1_boot` at 400 M cycles for
the CPI. Standalone ALM runs higher than in-core (20,129 against 17,817) because the fitter
cannot optimise across the boundary; the DELTAS are the usable part.

| build | ALM | Fmax | mean CPI |
|---|---|---|---|
| baseline (shift 4, loop cache) | **20,129** | | **14.9** |
| realign shift 8 | 20,614 (+485) | | 14.6 (-2%) |
| no loop cache | 19,962 (-167) | | 15.5 (+4%) |
| no FP group | 18,672 (-1,942) | 45.98 MHz vs 24.92 | — (unsafe) |

**Conclusions, and two of them go against the change that produced them:**

- **The realign widening is reverted.** 485 ALM for 1.7% is the wrong trade with the core at
  72% of the device and a rasterizer still to fit.
- **The loop cache stays.** Removing it saves 167 ALM and costs 4% - the worst ratio of the
  three.
- **The FP group stays**, and not for its cost: a run under `S32_V60_NO_FP` executes a
  *reserved* FP opcode at `FED52B`, in a page MAME never enters. See the entry above.

### Where the V60's cycles go, measured

A state census over 100 M CPU cycles, counting CE cycles per FSM state:

    S_FILL            33%   never touches the data bus
      of which:  shifting 1.0/instr, dispatch 1.0/instr, STARVED-ALIGNED 3.3/instr
    S_OP2_LD          20%   almost entirely genuine memory wait
    S_DECODE..S_NEXT  28%   pure FSM stepping, all bus-free
    S_WB_MEM/S_EA_VAL 12%   memory wait

**The starved-aligned bucket is where the win was**, and answering instruction-cache hits
combinationally took mean CPI from 17.6 to 14.6 - the cache already hit 99% of the time, and
the handshake was costing ~2.5 CPU cycles on data sitting in a register array.

### What is NOT the area hog, so nobody re-derives it

- **The register file.** 105 references to `r[]`, but 52 are `r[31]` and nearly all the rest
  are constant indices - only four are variable. Constant reads are free.
- **Replicated adders** are real - 128 distinct `Add*` nodes - but sharing them means
  restructuring a 4,601-line FSM, and the PC alone has 19 increment sites with different
  deltas.
- **`fb32(o)`/`fb16(o)`** expand to four and two 24:1 byte muxes each, and
  `fb32(ea_ofs+1)` appears at five call sites in different always blocks. Naming them as
  shared wires **broke `tb_v60_search`** and was reverted. Worth retrying only after
  understanding why, rather than assuming Quartus was not already sharing them.

### Aggressive Area on the full core: DO NOT — it trades the binding resource

The V60 alone drops 2,631 ALM under `OPTIMIZATION_MODE "Aggressive Area"` +
`OPTIMIZATION_TECHNIQUE AREA`, 20,129 -> 17,498, for 3.5% of Fmax. On the full core it does
not transfer:

    default (HIGH PERFORMANCE EFFORT / SPEED)   30,206 ALM   452 M10K   +0.331 ns
    Aggressive Area / AREA                      29,611 ALM   463 M10K   +0.024 ns
                                                  -595        +11

**595 ALM, +11 M10K, and almost no setup slack.** M10K is the binding resource here - 82%
before this, 84% after, with the rasterizer's band buffer wanting ~51 blocks - so it spends
the scarce resource to save the plentiful one. And +0.024 ns is one unlucky fit from a
failing build.

The knob stays available as `M1_QOPT="Aggressive Area" make rbf` with this measurement
beside it, and the default is unchanged.

**REVERSED SINCE, and the reversal is the current state.** The design later
failed to fit at all (166,497 combinational nodes against 83,820), so ALM
became the binding resource and `tools/mister_project.sh` made Aggressive
Area with register and logic duplication OFF the default; `M1_QSPEED=1` is
the opt-out. Every build from the 2:1 coprocessor onward, including the
2026-09-03 known-good, is an aggressive-area build, and its ~1,500 ALM is
already inside the 39,150 ALM figure. Do not read the verdict above as
current; read it as the measurement of what the setting costs in slack.

**The general lesson, which cost two 25-minute builds to learn twice:** a module measured
alone with virtual pins is not the module in context. The V60 reports 20,129 ALM standalone
and 17,817 in the core; the area setting saves 13% standalone and 2% in place. Standalone
numbers are for comparing two versions of the same block, never for predicting what a change
does to the design.

### CORRECTION: the 485 ALM was standalone; in the core it is 46

The realign shift was reverted from 8 bytes to 4 on a standalone measurement of 485 ALM.
Rebuilt in the full core:

    shift 8   17,771 -> 17,817 ALM   +0.331 ns slack
    shift 4                17,771    +0.639 ns

**Forty-six ALM, inside fit-to-fit noise**, against 2% of CPU speed. The area justification
was wrong.

The revert stands, for a reason that was not measured at the time: **the 9:1 mux is on the
critical path**, and 0.3 ns of slack on a design that has been down to +0.024 ns is worth
more than 2% of the CPU. But the number in the commit message was misleading, and this is
the third time in two days a standalone figure has pointed the wrong way:

- the V60 measures 20,129 ALM alone and 17,771 in place
- Aggressive Area saves 2,631 alone and 595 in the core, while costing 11 M10K
- this shift saves 485 alone and 46 in place

**Rule: never justify a change with a standalone area number.** Use standalone only to rank
two versions of the same block, and confirm anything that matters with a full build.

### Which V60 instruction groups the game never touches — and why NOT to cut them

A state census over 200 M CPU cycles and 10.7 M instructions of boot and attract. States
never entered once, mapped back through the enum:

    18-24    XCH, ROTC, MOVD (64-bit moves)
    48-52    decimal arithmetic, the whole S_DEC_* group
    58-71    bit-field insert and every bit-string op, S_BF_INS*/S_BS_*
    83-88    task switching, S_TASK_*/S_TASI*
    89-90    PREPARE / DISPOSE

That is a large amount of datapath in a CPU that is **17,771 ALM of a 30,227-ALM core**,
with the rasterizer (~4-6 k ALM) and the whole sound board (~8-9 k) still to fit into 11,683
free. Gating the unused groups is the obvious way to close that gap.

**Do not do it on this evidence.** Attract mode exercises a narrow slice of a game. A
compiler emits PREPARE/DISPOSE around stack frames and MOVD for 64-bit moves, and those can
appear the moment a race starts; the census proves only that thirty seconds of attract does
not reach them.

**The distinction that matters:** restructuring the V60 is OPTIMISATION - identical
behaviour, and `v60_trace`/`v60_resync` report zero divergence sites against MAME, so it is
provable. Gating a group REMOVES CAPABILITY and cannot be proven by any amount of testing,
only disproven.

**If it is spent anyway, spend it the way the FP group is spent:** gate the group out AND
trap its opcodes, so a wrong path raises a visible flag instead of silently computing
nonsense. That is exactly how the FP group was settled - the trap fired at `FED52B`, and the
lever stayed unspent. Drive the game through a full race first.

### Expression sharing in the V60 is worth 25 ALM — the area is structural

`r[31] - 4` appears at eleven separate `dbus_addr` sites and `r[31] + 4` at more, spread
through a 90-state case. Naming them as shared wires:

    baseline          20,129 ALM   (standalone)
    shared sp_m4/p4   20,104 ALM   -25

**Quartus was already sharing them**, and that is the useful result. Taken with the earlier
findings - 128 distinct `Add*` nodes, a register file that is almost entirely
constant-indexed, and `Aggressive Area` saving only 2% in context - the conclusion is that
**the V60's 17,771 ALM is not duplicated logic that a refactor can fold together.**

**This also means splitting it into modules will not, by itself, save area.** Quartus
flattens hierarchy to optimise across it; drawing boundaries buys VISIBILITY and can cost
area by blocking cross-boundary sharing. The split is still worth doing for what it reveals
and for the pipelining it enables - but it should not be sold as an area fix on its own.

**What would actually reduce it** is a different implementation, not a reorganisation of
this one: the cost is the control-to-datapath mux network of a ~90-state machine in which
each state drives wide registers directly. A microcoded or pipelined V60 replaces that with a
narrow control word and one shared datapath. That is a reimplementation measured in weeks,
against a CPU that currently matches MAME instruction-for-instruction with zero divergence
sites.

**So the M4 budget gap should be closed from the other end first.** ~2-4 k ALM short, and
the sound board is the unbuilt part: a smaller 68000 core than fx68k, or one MultiPCM
time-multiplexed across both channels rather than two instances, are both cheaper and less
risky than reimplementing a working CPU.

### Fitter SEED is worth more slack than the RTL change cost — 2026-08-23

From the Kaneko16 core: *"SEED 1 to SEED 3 closed it: -0.084 to +0.344, with the same logic
and the same memory"*, and the diagnostic that matters — *"the build immediately before it
had MORE logic, 12,401 ALMs against 12,018, and closed at zero, which is what identifies
placement rather than capacity as the cause."*

That is our shape. Splitting `v60_ifetch` out took the core from 30,227 ALM at +0.639 ns to
29,992 at +0.143, and the slack drop looked like the price of the split. It was not:

    same split RTL, seed default   29,992 ALM   +0.143 ns
    same split RTL, seed 3         30,071 ALM   +0.379 ns

**0.24 ns of slack from the seed alone, on identical logic.** So a marginal timing result
after an RTL change should be re-fitted before the RTL is blamed - changing code that is not
on the failing path is the wrong lever, and it is how a real area saving gets reverted for
no reason.

`M1_SEED=<n> make rbf` pins it. Note the template's last line has no trailing newline, so
the assignment must be appended with a leading `\n` or Quartus rejects the whole file - one
wasted build.

### PREREQUISITE for a faster SDRAM clock: the ROM loader must not move with it

Raised from the Kaneko16 core, where splitting the memory clock to 96 MHz broke **every
game at once** on a build that **closed timing at +0.502 ns**:

> `kaneko_rom_loader` was clocked from `clk_sdram`. That was invisible while `clk_sdram` and
> `clk_sys` were the same net; doubling the memory clock made it wrong twice over: every
> input it takes comes from `hps_io` on `clk_sys` - so it became an unsynchronised crossing -
> and it drives the SLOW port while being clocked FAST, so `ACK_HOLD`'s two-cycle
> acknowledge, exactly one edge for a 48 MHz requester, was two edges for it. **Every ROM
> write counted twice and the image loaded corrupt.**

**Model 1 is correct today and only by accident of having one domain:**

    hps_io          .clk_sys(clk_sys)    80 MHz
    m1_rom_loader   .clk(clk_sys)        80 MHz
    m1_sdram        clk_sys              80 MHz

Our controller has the same `ACK_HOLD = 2`, so both halves of that bug are latent here. If
the memory clock is raised - and 96 MHz is +20% of bandwidth against a core that spends 20%
of its cycles starved for instruction bytes - then:

1. **Keep `m1_rom_loader` on `clk_sys`**, where its `ioctl_*` inputs already are, and let an
   adapter do the crossing.
2. **Re-check every requester against `ACK_HOLD`.** A held acknowledge counted in the fast
   domain is a different number of edges for a slow master.
3. **Recompute `T_REFI`.** It is in clock cycles and tuned for 80 MHz; `Model1.sv:364` already
   records that at 100 MHz it under-refreshes, which is a data-retention fault that would
   present as random corruption.

**And the line worth keeping from that entry:** *"the broken build CLOSED TIMING. Static
analysis says the paths are met, not that the design is right, and the guard cannot see a
module wired to the wrong clock."*

### The register file CANNOT be extracted as-is: rf_we* are blocking temporaries

Second extraction attempted after `v60_ifetch` succeeded, and reverted. It failed
`tb_v60_audit`, `tb_v60_search` and `tb_v60_cmpc` with wrong register values, and the reason
is structural rather than a wiring slip.

Every architectural update is funnelled through two masked ports, which looks like a clean
boundary:

    rf_we0 = 1'b0;              // cleared at the top of the FSM's always block
    ...
    rf_we0 = 1'b1;              // set by queue_reg_write, BLOCKING, inside a task
    ...
    if (rf_we0 && rf_wmask0[b]) r[waddr0][b] <= wdata0[b];   // consumed in the SAME block

**They are intra-block temporaries, not registers.** The write decode at the end of the
always block sees the value the tasks set during that same evaluation. Move the decode into
a submodule and it samples them at the clock edge instead - which is the value left over from
the PREVIOUS cycle. Most instructions still pass; the ones that queue two writes, or write
then immediately read, do not.

**So the boundary is real but the signalling is not.** Extracting the register file needs
`rf_we*`/`rf_waddr*`/`rf_wdata*`/`rf_wmask*` produced by an `always_comb` first, so they are
genuine combinational outputs of the FSM rather than scratch variables. That is a change to
how every write is queued, and it should be made and verified on its own before any
extraction depends on it.

**General rule for the remaining splits:** a signal set with `=` inside a clocked block and
consumed later in that same block is not an interface, however much it looks like one. Check
the assignment operator before drawing the boundary.

## The scroll latch FIXED the picture; the coprocessor now blocks the V60 — 2026-08-23

**The jumping is gone.** Latching the scroll and control words once per frame at vblank
begin - where `screen_device::vblank_begin` renders and where `draw_common` reads them -
gives a stable horizon on hardware: sky above, sea below, layer 2 winning `02E800` = 190,464
pixels, the whole visible area. That was the fault behind "sea and sky jumping up and down
and off the top of the screen", and it came from the Kaneko16 core's identical finding.

**And the core is now hung, on one fault with a clear chain:**

    row 0F  000035    TGP retires = 53
    row 10  0007E6    TGP pc = 0x7E6
    rows 06/0C/0E/07/0B  all zero   the coprocessor made NO SDRAM reads at all
    row 00  FE8B1E    V60 PC, FROZEN
    row 01  15580E    1,398,798 instruction fetches, frozen

The coprocessor is stuck, so it never drains the command FIFO; the FIFOs are a mutual
hardware interlock (`model1_m.cpp:29-44`), so the V60 fills the input FIFO and halts. **The
V60 is a victim here, not the cause** - and `FE8B1E` is above `FE6C`, which is the highest
address MAME ever executes, so it is off in the weeds exactly as `FED5A4` was.

**Not timing.** `clk_cpu` closes with **9.944 ns** of slack; only `clk_sys` is near the edge
at +0.379. The combinational instruction-cache hit added on 2026-08-22 is in the CPU domain
and is nowhere near critical.

**Not reproduced in simulation.** `tb_m1_frame` runs past 300 M cycles with the PC and frame
counter advancing, and reaches TGP pc `004c` - the command-wait loop - with 342 retires and
text rendering, `tm0=9787`.

### 53 retires at 0x7E6 is the empty-program-RAM signature

That is where a coprocessor executing zeros ends up: a zero word decodes as `lab`, so
`ldi #0x8000, b0` never writes `b0` - the fault that opened this whole investigation, then
found to be a testbench race.

**Row 02's `800B9A` does not disprove it.** That checksum is folded at the loader's IOCTL
INPUT, before the FIFO and before the write, so it proves the HPS delivered 2048 correct
words and nothing about what reached the TGP's program RAM. It is exactly the gap that rows
07/0B had for SDRAM, and that the read-back sweep closed by reading the memory back.

**Next instrument: read the TGP's program RAM back and fold it**, the same way
`v60_ifetch`'s SDRAM sweep does, and compare against `tools/rom_csum.py` over
`vr_tgp_prog.hex`. Until that exists, "the microcode arrived" is an assumption.

### The microcode IS intact, and a 2048-cycle reset delay fixed the hang — 2026-08-23

    row 0C   A07D51   the program RAM read back through its own port
    expected A07D51   tools/rom_csum.py over vr_tgp_prog.hex

**Exact match, so the load path is exonerated** and "the microcode arrived" is measured at
the array for the first time rather than at the loader's input.

**And the sweep fixed the hang as a side effect.** The only RTL change was holding the core
in reset for the 2048 cycles the sweep takes, and the coprocessor went from parked at 0x7E6
with 53 retires to running with its pc around 0x4xx and retires climbing. **There is a race
at coprocessor release and the previous build was losing it.** That delay is currently
incidental - it exists because the sweep needs it - and it should be made explicit and
justified rather than left as a side effect of a debug instrument.

### CORRECTION: the stable picture was the hang, not the scroll latch

The previous build showed a clean, still horizon and that was read here as the per-frame
scroll latch working. It was the game FROZEN: with the coprocessor hung the V60 never got
far enough to rewrite the scroll registers, so nothing moved. With the coprocessor running
again the jumping is back.

The latch change is still correct - it is what `draw_common` does, read once at vblank begin -
and it stays. It just did not cause the stable picture, and claiming it did would have
retired a bug that is still open.

### Where the coprocessor actually diverges: after read 4

    row 07   300020   first copro SDRAM read address    matches simulation
    row 0B   300040   second                            matches
    row 0E   300040   matches
    row 06   1E0DA5   fold of the first 1024 reads      simulation: BD686D

So it **starts identically and diverges later**, somewhere inside the first 1024 reads. That
is a bisectable range: capture the address at read 64, 256 and 512 and halve it each build,
the same way `tgp_wrtrace` went from "diverges at write 38" to a named instruction.

### The coprocessor read stream is TIMING-DEPENDENT, so row 06 is a weak comparison

Two deep `tb_m1_frame` runs, identical RTL except for making the release delay explicit:

    before   copro read checksum bd686d
    after    copro read checksum 101ed7

The delay changes when the coprocessor starts, which changes how its reads interleave with
the V60's commands, which changes the sequence. **So the read fold is not a stable
signature**, and the difference between the board's `1E0DA5` and simulation's value has been
read here as evidence of a defect when part of it is just interleaving.

Hardware and simulation interleave differently by construction - real SDRAM latency against a
behavioural model - so **any dynamic stream compared between them carries this caveat**. The
first read (`300020`) is deterministic because it happens before any interaction; the
addresses at 64, 256 and 512 are not.

**What this does not undermine**, because each is a static fact rather than a stream:

- the microcode read-back, `A07D51`, matching the ROM image exactly
- the SDRAM whole-image read-back, `4D2E75`, matching
- the row-mask and character write counts
- the tilemap pixel shares

**What to use instead for the coprocessor:** compare against MAME rather than against our own
simulation, at a defined program point rather than a cycle count. `make tgp_trace` already
does that for the retire stream and reports IDENTICAL for its window; extending that window
is the honest way forward, not comparing two machines that were never going to interleave
alike.

## The instrument this core is missing: diff tile RAM and palette CONTENT against MAME

From the Model 2 core, which had the same symptom - a test menu with coloured values and no
white labels - and named it in one step:

> `test_m2_boot` now dumps the tile RAM, palette and xlat OUR CPU builds, and
> `test_m2_video_frame` renders those instead of MAME's capture: 468 non-black pixels
> against the reference's 2054, and the picture is the bench photograph. The diff names it.
> Tile RAM differs in 13 words of 32768. The palette differs in 64 entries, all at 1+16k,
> each written 0000 where the reference holds a colour, and entry 1 is white:
>
>     pal[1] <= ffff  at instruction 1478810
>     pal[1] <= 0000  at instruction 1713595
>
> So the CPU executes something MAME does not, at 1713595 - past the 803355 instructions it
> has been differentially verified to.

**Model 1 has never done the content diff.** Everything measured here has been a COUNT or a
SHARE - pixels won per layer, character writes, non-zero mask writes, scroll register values -
and none of those can say *which word* is wrong. `tb_m1_frame` already renders our own state;
what is missing is dumping tile RAM and the palette and diffing them word for word against a
MAME capture at the same point.

That converts "no text on screen" into "this entry holds X where the reference holds Y", and
then `make v60_trace` can be aimed at the instruction that wrote it - which is exactly how
`tgp_wrtrace` found nine coprocessor bugs.

**And the warning that came with it**, which this core has nearly repeated twice:

> Also removes the tile-RAM fold probe. It cost 64 M10K, because Quartus duplicated the array
> for a third read port, and could never be read: the menu cannot be held still and a fold of
> a moving screen compares against nothing. **Its precondition was not checked before it was
> built.**

A checksum of something that moves compares against nothing. The SDRAM and microcode
read-backs here work because ROM contents are static; the same trick aimed at tile RAM while
the game is drawing would produce a number that means nothing.

**Palette sizing checked at the same time and Model 1 is correct:** MAME maps
`0x900000-0x903fff`, 8192 words, and `m1_mainram` declares `pram_c_lo[8192]` indexed
`addr[13:1]`. The Model 2 aliasing bug - 4096 entries for an 8192-entry region, so half of
every write folded onto the low half - does not exist here.

### BUILT, and it names things in one run: the content diff — 2026-08-27

`tb_m1_frame` now dumps the tile RAM (32,768 words) and palette (8,192 entries) our CPU
builds; `tools/mame_m1_dump.lua` captures the reference's; `tools/tram_diff.py` compares them
word for word. First run:

    tile RAM: 13,329 of 32,768 words differ (40.7%)
      our HIGH byte is 00 where the reference's is not:  12,951
      exactly ours|0x8000 == ref:                         3,470
    palette:     591 of 8,192 entries differ (7.2%)
      strides 1 x284 and 16 x94

**Two distinct faults, and both are addressable in a way no count ever was:**

1. **Tile RAM word 0 holds `0020` here and `8020` in the reference** - and so do thousands of
   others. `8020` is a space with **bit 15, the CATEGORY bit, set**; ours is a space with it
   clear. That is a single word at a fixed address with a known wrong value, which is exactly
   what `make v60_trace` can be aimed at: find the instruction that writes tile RAM word 0.

2. **Where the reference holds characters - `830a`, `8309`, `8303` - we hold `0020`,** the
   screen-clear space. So the clear ran and the draw did not, at specific addresses rather
   than "no text on screen".

The palette shows the same shape: 111 entries where we hold `0000` and the reference holds a
colour, on a stride of 16 - a zeroing loop that walks 32 bytes, exactly the pattern Model 2
found - and entry 0 is `fd02` there and `0000` here.

**This is the instrument that has been missing all along.** Every previous measurement was an
aggregate: pixels won per layer, character writes, non-zero mask writes, scroll register
values. None of them could say *which word*. Two runs of this say it directly.

**The caveat it carries**, and it is the one that has already produced a wrong finding here
once: the two sides must be at the same point IN THE PROGRAM, not at the same frame number.
This core runs at about 84% of real speed, so equal frame counts are different program
states. `tools/tram_diff.py` says so in its header.

### The content diff closes the causal chain: we never reach the drawing code

Tracing the one wrong word the diff named - tile RAM word 0, `0020` here against `8020` in
the reference - gives the whole story in three steps.

**Who writes it.** A write tap on 0x700000 in the reference: four writes, and the last one
decides it.

    w 1  data=0000  pc=fe026c
    w 2  data=0020  pc=fe6a71
    w 3  data=0020  pc=ffe60b
    w 4  data=8020  pc=ff92d5    <- sets bit 15, the CATEGORY bit

**What that instruction is part of.** An unrolled tile-RAM fill:

    FE215A: bsr     FE326F
    FE326F: mov.w   #700000, R0        tile RAM base
    FE3276: jsr     FF92C9[PC]
    FF92C9: mov.h   #8020, R1          a space WITH the category bit
    FF92CE: mov.w   #40, R2
    FF92D5: mov.h   R1, [R0+]          x64

**Whether we execute it.** MAME runs `ff92d5` **128 times**; we run it **zero**, and never
enter the `ff92` page at all. Every step of the call chain - `fe2145`, `fe214c`, `fe2154`,
`fe215a`, `fe326f` - is likewise 1 in MAME and 0 here.

**And it is not a branch taken differently.** `ff92c9` sits at collapsed instruction 87,277
of MAME's 5,193,988, while our entire stream is 25,685 long. **We stop progressing about a
third of the way there**, at `ff9754` - `in.w [R23], R2`, a coprocessor result read.

So the chain is complete and consistent with everything else measured:

    coprocessor diverges -> V60 blocks on in.w at ff9754 -> never reaches FF92C9
      -> tile RAM keeps 0020 instead of 8020 -> every tile is category 0
      -> the text layer draws nothing

**The missing text is not a video fault and never was.** The renderer is drawing exactly what
tile RAM contains. What the content diff added is proof rather than inference: a named word,
a named instruction, and a count of zero.

### tgp_trace with a wide window: 75,175 instructions of agreement, then a named divergence

`make tgp_trace SECONDS_RUN=16 BOOT_CYCLES=1500000000` - the widest window this has ever
been run at, against the previous 342.

    loops collapsed on both sides: 910 in common, 1 with differing counts
    tgp_trace: DIVERGES at instruction 75175

    MAME:  0051 addd -> 0052 brul alw d -> 0053 -> 009B
    ours:  0051      -> 0052            -> 0064

`brul alw d` branches to whatever is in `d`, so MAME lands at 0x53 and we land at 0x64 - a
difference of exactly 0x11. And `d` was built three instructions earlier:

    004D: mov (x1), b      b loaded from memory
    004F: mov bh, d        d = bh
    0050: lia #0x53        a = 0x53
    0051: addd             d = d + a

**`bh` is register 0x14, and it is NOT the high half of B** - `read_reg` returns
`get_exp(m_b)`, the floating-point exponent, `(val >> 23) & 0xff`. Our `mb86233_regs` does
exactly that for 0x14, so the accessor is right.

    MAME   get_exp(b) = 0x00   ->  d = 0x53
    ours   get_exp(b) = 0x11   ->  d = 0x64

**So the fault is the VALUE IN B**, loaded by `mov (x1), b` at 0x004D - either the word at
(x1) or x1 itself. Not the decode, not the register accessor, not the branch.

**This is the deepest the coprocessor has ever been verified.** The previous claim was
"IDENTICAL for 342 instructions", which was a 3-second window in which the reference's TGP
is idle almost throughout; 75,175 with 910 loops agreeing is a different order of evidence.
The next step is to trace what writes the word at (x1), which is the same escalation
`tgp_wrtrace` used to find nine bugs: stop comparing streams, compare the value and find its
writer.

### The Z80 LLE: a cost D9 did not count, and where the ROM has to live — 2026-08-27

Raised after the Model 2 core found a flaw in its I/O path: should Model 1 run the real Z80
instead of the HLE, and would it fit?

**D9's condition is not met.** It says "revisit when the resource count is final, which is not
the same as reversing" - and the rasterizer (4-6 k ALM) and sound (8-9 k) are still estimates
against 11,878 free. The uncertainty the HLE was chosen under is exactly as large as it was.

**And there is a cost the decision did not count.** D9 prices the LLE at ~2,000 ALM against
the HLE's ~300, in ALM only. The Z80 also needs `EPR-14869`, **64 KB**, which on-chip is about
**52 M10K** - and M10K is now the binding resource at 452 of 553, with the rasterizer's band
buffer wanting ~51 of the 101 free. That would leave nothing.

**The ROM belongs in SDRAM**, where every other ROM already is. A 4 MHz Z80 is negligible
traffic against a controller already serving five masters, and it is already in `vr.zip` so
no new asset is needed. That reduces the memory cost to the 8 KB work SRAM, about 7 M10K, and
leaves the decision an ALM question as D9 framed it.

**What would make it a correctness question rather than an area one:** our HLE reproduces a
protocol read out of the Z80 ROM BY DISASSEMBLY, not by running it. MAME's model is LLE and
therefore correct by construction. If a defect is ever traced to the I/O board, the ~1,700 ALM
stops being optional - which is an argument for keeping the interface interchangeable, as D9
already ensures: `m1_ioboard`'s ports do not change between the two.

**Checked at the same time, from the Model 2 finding:** its bridge suite modelled I/O as
COMBINATIONAL when the peripherals are registered, and used FULL-WIDTH accesses when the
failing one is a single byte. Neither applies here - `tb_m1_ioboard` models the edge
explicitly ("the RAM samples its inputs on the edge, so the byte that lands is the one
presented before the clock") and is byte-oriented throughout. And the composition it names as
the remaining untested link - CPU through bridge into I/O board on real code - is what
`make m1_boot` has been doing here all along.

### WITHDRAWN: "the command stream differs at the FIRST pop" — 2026-08-29

**It does not differ at all.** The command interface is bit-exact: over the same window the
V60 pushes **61 commands and the coprocessor pops 61**, and both streams match the reference
word for word.

    our pushes vs MAME pushes:  IDENTICAL, 61 words
    our pops   vs MAME pushes:  IDENTICAL, 61 words

That restores the earlier result recorded above under *"The V60's command stream is CORRECT —
it just never stops"*, which this entry had contradicted on the strength of a bad instrument.

**Three instrument faults of the same family produced the false finding, one after another,
in one investigation.** All three compared two captures that were not the same measurement:

1. **Different filters.** The reference capture was filtered to `GENPC == 0x4e`; ours counted
   every pop. Recorded below.
2. **Different LEVELS.** MAME's read tap on `0x100` fires on a read of an **empty** FIFO,
   which returns `0` and is retried; we stall instead and never log those. So the reference's
   pop log carries `00000000` entries that are not commands, and ours cannot. The two logs
   were never comparable in either direction.
3. **A registered signal sampled on its own write edge.** `pop_data <= fifo_in_data` updates
   on the very edge `fifo_in_pop` asserts, so logging `pop_data` there yields the PREVIOUS
   pop. Our log came out led by the reset value `00000000` and shifted one word behind — which
   read exactly like a phantom command ahead of the stream, and was written up as "offset by
   one" before being caught. `fifo_in_data` is the head itself and is what to log.

**The artefact-free comparator is the PUSH stream.** `v60_copro_fifo_w` pushes once per pair
of 16-bit writes — offset 0 latches the low half, **offset 1 supplies the high half and
performs the push** — so the pushes are exactly the command sequence, with no empty-read
entries and no retries. A tap on `0xd80000-0xd80001` alone sees every low half and **no
pushes at all**: 61 writes of `0000`, which is also precisely what `0x01000000`'s low half
looks like. Tap `0xd80000-0xd80003` and assemble on the odd offset.

**So the divergence at instruction 75,175 is genuinely 75,175 instructions deep**, and the
inputs are not the cause. `x1 = 0x100` at `004D` was read off a static trace back; whether
`x1` still holds `0x100` at the divergence is unverified, and is the next thing to measure
rather than infer.

### A filtering mistake that would have been a false finding

The first comparison put MAME's `00000000, 01000000, ...` against ours of
`00000000, 04000000, 01000000, 3f400000, 428c0000, ...` and appeared to diverge at pop 2.
It was an artefact: **the reference capture was filtered to `GENPC == 0x4e`** - pops at
instruction `0x004D` only - while ours counted EVERY pop. Two sequences with different
filters cannot be diffed.

Also recorded, because it cost a run: `tgp.state["PC"]` does not exist - `PC` is `.noshow()`
in `state_add` - and **a bad state key throws inside a tap and is silently swallowed**, so
the first capture produced an empty file and looked like a tap that never fired. Use `GENPC`,
which is the NEXT pc, so it reads `0x4e` while `0x4d` executes.

### Where the 452 M10K actually go, and the 80 that are recoverable — 2026-08-29

Measured from the fitter's own *Resource Utilization by Entity* table, `M10Ks` column, not
from grepping instance names — a grep of `altsyncram:<name>` counted `o_a_poly_mem` at 62
blocks when it is **1**, because the report names each memory in several sections. The
counts also failed to sum to 452, which is the tell.

    tram_c_lo/hi + tram_v_lo/hi   128     tile RAM, HALF OF IT DUPLICATION
    dl0_lo/hi + dl1_lo/hi         128     display lists, genuinely double-buffered
    cxlat_lo/hi                    32
    pram_c_lo/hi + pram_v_lo/hi    32     palette, HALF OF IT DUPLICATION
    ram                            32
    g_bank                         32
    ascal (framework)              42
    osd_buffer / prog / misc       ~26

**32 blocks per 32768x8 byte lane is the FLOOR, so the byte-array idiom is already optimal.**
M10K's widest useful configuration is 1024x8, so a 32768-deep lane needs 32 blocks whatever
the width: 262,144 bits into 8,192 usable bits each. Going to one 32768x16 array would be
*worse*, not better — the 512x16 configuration needs 64. Depth dominates, not width. The
82% "implementation bits" against 61% actual bits is this, and it is not recoverable.

**The recoverable M10K is the CPU/video DUPLICATION: 64 on tile RAM, 16 on palette.**
`m1_mainram` keeps `tram_c` for the CPU read port and `tram_v` for the video read port,
written identically from `clk`, because an M10K has two ports and write + CPU read + video
read is three. But port A can serve the write AND the CPU read, leaving port B for the video
read — which is two, and is what M10K true-dual-port mode exists for.

**Quartus 17.0 will not INFER it, tested small both ways** (`build/m10ktest`, 1024 entries,
seconds per run, per the rule about testing a memory idiom small):

  * one write + two reads on different clocks — Quartus silently **replicates the array into
    two Simple Dual Port blocks**, 16,384 bits for an 8,192-bit array. That is exactly what
    `m1_mainram` already does by hand, so merging the declarations saves nothing.
  * the true-dual-port template, both ports read and write — **`Error (276001): Cannot
    synthesize dual-port RAM logic "mem"`**. Refused outright.

So it needs an explicit `altsyncram` in `BIDIR_DUAL_PORT` with two clocks, plus a
behavioural model under `` `ifdef VERILATOR `` since Verilator cannot compile the
megafunction. That is a sim/synth divergence risk on the most heavily used memory in the
design, which is why it is written down rather than done in the middle of the TGP work.

**`MISTER_DISABLE_ADAPTIVE` is NOT worth it.** It sets ascal's `ADAPTIVE("false")`, and the
memory that guards is `o_a_poly_mem` — **1 M10K**. ascal's 42 are mostly its four scaler line
buffers at 5 each. `MISTER_SMALL_VBUF` changes DDR3 `RAMSIZE` only and touches no M10K.

### The TGP parks because an empty command FIFO must return ZERO, not stall — 2026-08-29

`tgp_trace` agrees for 75,175 instructions and then splits, and the split is one branch:

    MAME   ... 0051 0052 -> 0053 -> 009b 009c 009d 009e 009f 004c 004d ...   keeps polling
    ours   ... 0051 0052 -> 0064 -> 01c8 01c9 01ca ...                       dispatches

`0052 brul alw d` is a **computed jump**, and `d = get_exp(b) + 0x53` makes 004D-0052 a
dispatch table with base 0x53. `b` is loaded at `004D: mov (x1), b` with `x1 = 0x100`, which
`copro_data_map` maps to the command FIFO, so **the command type is carried in the exponent
field** and selects a handler above the base.

`get_exp` is `(val >> 23) & 0xff`, so **an empty FIFO gives `b = 0`, `d = 0x53`** — and 0x53
is the IDLE handler, which jumps back to 0x9b and polls again. That is the whole of what the
reference is doing at the divergence: its FIFO is empty and it is spinning in its idle loop.

**We stalled the pop instead, so `b = 0` was unreachable and the idle path was unreachable.**
The core parks at 004C the first time it polls an empty FIFO and never comes back. That is
exactly the recorded symptom — `pc=004c`, 342 retires, about fourteen io accesses per run
where the reference makes 158,391 in 400 frames.

**MAME's FIFO does not block on the pop, and the comment in `m1_tgp.sv` that said it did was
citing the one thing gen_fifo.h contradicts.** `on_fifo_empty_pre_sync`: *"Called on a pop
with an empty fifo. Must ask the destination to try again... **the pop itself will then
return zero**."* The halt only follows a machine sync that finds it still empty.

Measured over the same 16-second window: **61 pushes against a pop capture that filled its
300-entry cap.** Nearly every pop the reference makes is of an empty FIFO. A design that
stalls on empty cannot reproduce a machine whose normal state is polling nothing.

**The outbound FIFO keeps its stall and must.** That direction is the V60 reading results,
where acknowledging an empty read returned a stale word and hung the CPU at `fed5a4`; MAME
halts the maincpu there rather than letting it proceed. The two directions are not
symmetric in MAME and must not be made symmetric here.

`tb_m1_tgp` asserted the wrong behaviour until now — "it blocks on an empty input FIFO" —
and **could not have caught this**, because it only checked that `unimplemented` stayed low,
which a parked core satisfies. It now requires the core to make progress with the FIFO empty.

**Measured immediately after the change**, `make m1_frame BOOT_CYCLES=1500000000`:

    before   TGP retires=342    pc=004c  pushes=61 returns=20      parked at dispatch
    after    TGP retires=57660  pc=00a7  pushes=61 returns=36      running

`pc=00a7` is the instruction after the two consecutive FIFO reads at 0x00a5/0x00a6 — the
multiply whose result is written back — so the coprocessor is in its working path rather
than polling. 168x the retires from one acknowledge.

### The TGP:V60 clock ratio is 1:1 here and 2.5:1 on the board — 2026-08-29

    reference     V60 16 MHz (32_MHz_XTAL/2)    TGP 40 MHz (40_MHz_XTAL)    ratio 2.5 : 1
    ours          V60 19.2 MHz                  TGP 19.2 MHz                ratio 1.0 : 1

`Model1.sv` ties `.ce_cpu(1'b1)` and both processors run on `clk_cpu`, PLL `outclk_1` at
19.2 MHz. The "dual-clock" note on `m1_tgp` refers only to the microcode load port, not to
running the core faster. So **our coprocessor has 2.5x less throughput relative to the CPU
than the real board.**

**This makes instruction-level lockstep of the TGP impossible as a metric, and that is not a
statement about correctness.** 004D-0052 is a poll: which way `0052 brul alw d` goes depends
on whether the FIFO happens to hold a command at that instant, so the instruction stream
encodes the relative speed of the two processors. Diffing it compares timing, not semantics.

Demonstrated by the fix on the same day. Before, a read of an empty FIFO stalled, which
**synchronised** our TGP to the data and hid the ratio; `tgp_trace` agreed for 75,175
instructions. After, with the correct return-zero behaviour, it parts at instruction 89 —
with the roles reversed:

    before   MAME 0052 -> 0053 (idle)      ours 0052 -> 0064 (dispatch)
    after    MAME 0052 -> 0055 (dispatch)  ours 0052 -> 0053 (idle)

`get_exp(0x01000000)` is 2, so the reference dispatches to `0x53 + 2 = 0x55`; we read an
empty FIFO. **The longer agreement was the buggier build**, because stalling made our TGP
data-driven rather than time-driven. A metric that rewards the wrong behaviour is the wrong
metric.

**So M0 exit criterion 2 needs a timing-independent comparator**, and the candidates are the
data-memory WRITE streams (`make tgp_wrtrace`, already built) and the sequence of dispatched
handlers with their results. The command interface itself is already known bit-exact — 61
pushes, 61 pops — so what is left to prove is that each command produces the same work, which
is a value question, not a schedule question.

Whether the ratio should be corrected in RTL is open and is NOT required for the criterion.
It would need the TGP in its own faster domain, which costs timing closure at 29,771 ALM and
+0.634 ns; and our V60's CPI is ~15 against real silicon's ~8, so the two errors are not
independent and fixing only the clock would not make the machine match the board.

### quartus_fit segfaults AT EXIT, and the multicycles were not the cause — 2026-08-29

`make rbf` reported `Error (23031): Evaluation of Tcl script qsh_flow.tcl unsuccessful` and
produced no `.rbf`. That message names neither the stage nor the cause, and the log two lines
above it says the opposite:

    Info: Quartus Prime Fitter was successful. 0 errors, 45 warnings
    *** Fatal Error: Segment Violation
    Module: quartus_fit
       0x32ee4f: STA_COLLECTION_ATCL_OBJ::~STA_COLLECTION_ATCL_OBJ()
        0x2b0be: ATCL_OBJ::tcl_freeInternalRepProc(Tcl_Obj*)
       0x130ec1: UnsetVarStruct
       0x131253: TclDeleteNamespaceVars
       0x103fc0: TclTeardownNamespace
        0x19d82: atcl_exe_fini()

**The fit succeeds — 30,099 ALM, 452 M10K, 0 errors — and the crash is in the TEARDOWN**,
freeing STA collection objects that the SDC left in Tcl variables. Because it dies at exit,
no fit report is written and the assembler never runs, so the build has no `.rbf` while
claiming success. The stale `.rbf` from an earlier build is still sitting in `output_files/`,
which makes it look as though something was produced. **Check the `.rbf` timestamp, not its
existence.**

Fix: `unset -nocomplain sdram_clk_src sdram_clk_prt sdram_out sys_clk cpu_clk sdc_exe` at the
end of the SDC, so the collections are freed inside the STA session rather than at
interpreter shutdown.

**THE MULTICYCLE PATHS WERE BLAMED FOR THIS AND ARE NOT THE CAUSE.** They are opt-in behind
`MODEL1_SDRAM_MCP`, which was **not set** on the build that crashed, so those four lines never
ran. Three earlier crashes were attributed to them and the SDRAM constraints were made
opt-out in response — that is a workaround built on a misattribution, and the constraints can
stay on.

### The coprocessor is now blocked on the V60, not on commands — 2026-08-29

With the empty-FIFO fix in, `tb_m1_frame` was instrumented with 64-bit counters (the RTL's
`dbg_retires` and `dbg_fifo_pops` are 16 bits and **wrap with no saturation**, so
"retires=57660" is `57,660 + 65,536k` and cannot be divided by a cycle count):

    TGP cycles=36,273,868  retires=385,340   ->  94 cycles per instruction
      mem_req   25,248,162    70% of all cycles
      fifo_rd      128,484     0.4%
      fifo_wr   24,991,194    69%          <- stalled WRITING results
    V60 read the result FIFO 20 times in 109 frames (0/frame)
    TGP pushed 36 results

**`fifo_out_push` requires `!fifo_out_full`, the FIFO is 16 deep, and 36 results went in — so
it is full and the coprocessor has been stalled on the 37th push ever since.** That is the
correct interlock (MAME halts the TGP on a full outbound FIFO too); what is wrong is the
other end.

**The reference's V60 reads that FIFO about 1,185 times a frame** — 710,722 over 600 frames,
in I/O space via `in.w`. Ours reads it 20 times in 109 frames. The V60's `IN`/`OUT` are
already real bus transactions here (that was fixed after the `fed5a4` poll), so the path
exists and the V60 simply is not executing the code that uses it.

So the coprocessor is **not** starved of commands — pushes match the reference exactly, 61
against 61 — and the 94 cycles per instruction is almost entirely one blocked write. The next
question is a V60 control-flow question, and `make v60_trace` is the instrument: it currently
parts at instruction 197,251 on `cmp.h R0, FE[R11]` / `be`, where `0x40e8fe` reads `0000`
there and `ffff` here.

Note the 2.5:1 clock ratio recorded above is a real difference but is NOT what this is —
a stalled writer does not care how fast its clock is.

### The chain closes: the V60 takes an interrupt early, and everything follows — 2026-08-29

Four measurements taken in sequence, each answering the one before:

**1. The TGP is not starved of commands, it is blocked pushing results.** `fifo_wr` is
asserted for 69% of all TGP cycles; 36 results went into a 16-deep outbound FIFO and it has
been stalled on the 37th ever since. That interlock is correct — MAME halts the TGP on a full
outbound FIFO too.

**2. The V60 does not drain it.** 20 reads in 109 frames, against the reference's ~1,185 per
frame. The `IN`/`OUT` path is real here, so the V60 is simply not executing that code.

**3. `v60_trace` says why: DIVERGES at instruction 25,281**, and it is an interrupt.

    MAME   FC57C5: jsr FF8ABC  ->  FF8ABC
    ours   fc57c5              ->  fe02bc

A `jsr` target is fixed, so ours cannot have gone to `fe02bc` by executing it. `fe02bc` is
reached from **five different predecessors** in our own trace — `fe1435`, `fe1433`, `fe143d`,
`fe10cd`, `fc57c5` — which is the signature of an interrupt handler, not a subroutine. **We
take an interrupt the reference has not taken yet.**

**4. And the cause is speed.** The same run reports our loops running about HALF the
reference's iterations:

    fe1433,fe1435,fe143d    MAME 8769    ours 4102    (-53.2%)

repeated across many sites. These are time-based waits, so the iteration count IS the
relative speed of the two machines. Our V60 executes ~1.28 MIPS (19.2 MHz at CPI ~15) against
real silicon's ~2.0 (16 MHz at CPI ~8).

**So the TGP work is downstream of CPU speed, not of the coprocessor.** `tgp_wrtrace`'s
value-level divergence at write 268 — `41ef3336` (29.9) there against `bdcccccd` (-0.1) here,
from `x0 = 0x100`, the command FIFO — is the V60 having pushed different data after taking a
different path. It is not a TGP arithmetic fault.

### A fifth instrument fault, and this one nearly stood: the MIRROR

`map(0xd80000, 0xd80003).mirror(0x1fffc)` means the coprocessor FIFO answers across the whole
of `0xd80000-0xd9ffff`. A write tap on the four base bytes catches **61 pushes** where a tap
on the mirrored range fills a 4,000-entry cap immediately. 61 could never have been the whole
stream for a window in which the reference dispatches 265,555 commands, and that contradiction
is what exposed it.

**The prefix comparison survives, checked rather than assumed**: the first 61 pushes of the
full capture are byte-identical to the base-only capture, so "61 pushes, 61 pops, bit-exact"
holds for that prefix and the withdrawal of "differs at the FIRST pop" stands. What does NOT
follow is that the command stream is correct in general — beyond the prefix our V60 diverges
and pushes far fewer commands.

**Our own decode was never at fault**: `m1_decode` matches `hi == 8'hd8 || hi == 8'hd9`, which
is the full mirror, and `a1` is `addr[1]`, which is MAME's `offset` under mirroring too.

### clk_cpu closes at 24.94 MHz and runs at 19.2 — 30% is sitting unused — 2026-08-29

From the last successful build's STA, `Fmax Summary`:

    24.94 MHz   emu|pll|...|general[1]|divclk     <- clk_cpu, RUN AT 19.2
    83.43 MHz   emu|pll|...|general[0]|divclk     <- clk_sys, run at 80

**The V60 is the machine's critical path now** — see the interrupt divergence above — and a
30% speedup needs only a PLL output change, no RTL. It takes ~1.28 MIPS to ~1.66 against real
silicon's ~2.0 (16 MHz at CPI ~8). **It does not close the gap**; our loops run at 47% of the
reference's iteration counts and 30% does not make that 100%, so CPI work is still what
matters.

**It is not free of consequences, and this is the dependency that would break silently.**
`m1_ioboard`'s `LATENCY = 740684` is *derived from the clock*: the reference's I/O board takes
38,577 us to answer the boot handshake, which is 740,684 cycles **at 19.2 MHz**. Change the
clock and that constant has to move with it, or the deadline stops meaning 38,577 us. The
property that matters is that the deadline exceeds the V60's once-a-frame doorbell interval,
so a wrong constant would not fail loudly — it would change boot behaviour.

Left as a measured option rather than done, because it changes how fast the whole machine
runs and interacts with hardware testing that is mid-flight.

### How much speed is actually missing: 1.63x, measured two independent ways — 2026-08-29

**Interrupts per instruction**, from `v60_trace`'s RAW streams (`our_pc_raw.txt`,
`mame_pc_raw.txt` — the collapsed files CANNOT answer this, one collapsed line stands for
thousands of iterations, and comparing them gives a meaningless 31-against-31):

    ours    31 entries to fe02bc in   949,429 instructions   ->  1 per 30,627
    MAME    19 entries in the same    949,429 instructions   ->  1 per 49,970
    MAME   107 entries in           3,996,841 instructions   ->  1 per 37,354

The interrupt arrives on wall-clock time and is the same rate on both sides, so
**interrupts-per-instruction is a direct measure of relative throughput**: we take 1.63x as
many, so we execute about **61%** of the reference's instructions per unit time.

That agrees with the arithmetic from the other direction — 19.2 MHz at CPI ~15 is ~1.28 MIPS
against 16 MHz at CPI ~8, which is ~2.0, and 1.28/2.0 = 64%. Two unrelated instruments, 61%
and 64%.

**So the target is 1.63x, and it decomposes:**

    clk_cpu 19.2 -> 24.94 MHz (its measured Fmax, PLL change only)   1.30x
    CPI 15 -> 12 (the remainder)                                     1.25x
                                                                     ----
                                                                     1.63x

CPI 15 -> 12 is a 20% improvement on a figure that has already moved 18.4 -> 17.9 -> 14.9 in
this project. **This is a reachable target, not an open-ended one**, and it is the thing
standing between the coprocessor and useful work: the V60 never reaches the code that drains
the result FIFO, so the TGP sits stalled on a full outbound FIFO at 69% of its cycles.

### With the constraints actually analysed, the SDRAM read path misses by 8.186 ns — 2026-08-29

Once `quartus_fit` stopped crashing at exit, a full compilation ran with the SDRAM SDC in
force for the first time — and the design **does not meet timing**:

    clk_sys (general[0])   -8.186 ns    TNS -127.514
    SDRAM_CLK_pin          -0.387 ns

The earlier `+0.514 ns` on `clk_sys` came from builds with the constraints suppressed, so
**this violation had been invisible for as long as the workaround was in place.** That is what
suppressing a constraint buys: not a faster design, a quieter report.

**The failing transfer names itself.** From the Setup Transfers matrix:

    From SDRAM_CLK_pin  ->  To clk_sys      16 paths

Sixteen paths is the sixteen `SDRAM_DQ` bits: the **read-capture path**. TimeQuest assumes
next-edge capture there and this controller does not do that — which is precisely what the
four `set_multicycle_path` lines in the SDC exist to express, and they were **opt-in behind
`MODEL1_SDRAM_MCP` because they had been blamed for the fitter segfault**.

They are not the cause. The crash is the Tcl teardown recorded above, and it happened on a
build where `MODEL1_SDRAM_MCP` was **not set**. So the multicycles are now **on by default**,
with `MODEL1_NO_SDRAM_MCP` as the escape hatch.

**Two workarounds were stacked on one misattribution**: the constraints were made opt-out AND
the multicycles opt-in, both to dodge a crash in neither of them. The measurement that
separated them was reading the stack trace instead of the exit code.

**And the multicycles close it.** Same design, `MODEL1_NO_SDRAM_MCP` unset:

    clk_sys setup        -8.186 ns  ->  +0.378 ns
    SDRAM_CLK_pin setup  -0.387 ns  ->  +10.582 ns
    worst setup / hold   failing    ->  +0.321 / +0.253 ns, no negative slack anywhere
    ALM / M10K           30,101     ->  29,979 / 452

So the -8.186 WAS the sixteen read-capture paths and not internal `clk_sys` logic — the
rebuild is what settled that, rather than reading the transfer matrix and assuming. **A full
compilation now meets timing with the SDRAM interface constrained**, which is the first time
that has been true here.

### The hardware degradation REPRODUCES in simulation — 2026-08-29

`make m1_frame FRAME_CYCLES=3600000000`, 2,611 frames:

    at    109 frames   tm0=9787   tm1=0  tm2=180677  tm3=0    text layer drawing
    at  2,611 frames   tm0=0      tm1=0  tm2=190464  tm3=0    tilemap 2 over everything
    scroll changes over 2,610 frames:  hscr[5002]=1  vscr[5006]=1   (MAME: hscr 1,344/2,000)
    window ctrl  pair01=0000  pair23=0000                            (never set)
    V60 pc pinned at feb673 from ~620 M cycles - frame ~469 - onward

**The V60 enters a loop at `feb673` around frame 469 and never leaves**, and the picture
collapses to the sky-and-sea state. That is the same failure reported from the board — "after
about 10 minutes we hit a black screen; after a core reset we go back to the broken sky and
sea only, and a full reload gets it back" — and it is now **reproducible without hardware**,
which is the difference between a 25-minute build plus a person watching a screen and a
105-second bench.

`FRAME_CYCLES`, not `BOOT_CYCLES`: `tb_m1_frame`'s parameter is `RUN_CYCLES` and the Makefile
passes `-GRUN_CYCLES="64'd$(FRAME_CYCLES)"`. Every earlier run in this session that passed
`BOOT_CYCLES=1500000000` to `m1_frame` silently used the 120,000,000 default — 109 frames —
which is why the degradation had not been seen there.

Note the 109-frame numbers are not the healthy state either: `window ctrl` is `0000` in both,
where the reference sets pair 2/3 to `0x2xxx`. The run reaches the attract screen and then
falls out of it rather than never getting there.

### The black screen is a MUTUAL DEADLOCK between the V60 and the TGP — 2026-08-29

`make m1_frame FRAME_CYCLES=800000000`, with FIFO occupancy added to the periodic report:

    400 M cycles  pc=fe1435  fin= 0/16  fout=16/16  v60_stall=0  tgp_wr=1
    420 M cycles  pc=ff9323  fin= 0/16  fout=16/16  v60_stall=0  tgp_wr=1
    440 M cycles  pc=feb673  fin=16/16  fout=16/16  v60_stall=1  tgp_wr=1
    540 M cycles  pc=feb673  fin=16/16  fout=16/16  v60_stall=1  tgp_wr=1   (never recovers)

**The order matters and it names the cause.** The OUTBOUND fifo is full first, at 400 M, while
the inbound is still empty and the V60 is running: the coprocessor is already blocked pushing
results that nobody is reading. It therefore stops taking commands. The V60 keeps pushing
until the INBOUND fifo fills too, and then it blocks on `fin_full`. From 440 M onward both
processors are waiting for the other and `pc` never moves again.

**This is the board's failure, reproduced.** "After about 10 minutes we hit a black screen;
after a core reset we go back to the broken sky and sea only, and a full reload gets it back."
A deadlock is exactly that shape — permanent, and unrecoverable by anything short of a reload.

**Both interlocks are CORRECT and neither should be relaxed.** MAME halts the TGP on a full
outbound fifo and the V60 on a full inbound one; `m1_copro_if`'s tests assert both. The
deadlock is a *consequence* of the V60 never reaching the code that drains results, which is
the interrupt-timing divergence at instruction 25,281 and the 1.63x speed deficit recorded
above. **Fix the speed and the deadlock cannot arm.** Adding an escape hatch to the FIFOs
would hide it and produce a machine that silently drops geometry instead.

### The V60's CPI is TRIMODAL, so a targeted fix beats pipelining — 2026-08-29

`make m1_boot BOOT_CYCLES=400000000`, retire-to-retire histogram over 6,292,761 instructions:

    mean 14.9   median 9

    25 cyc   1,672,426 instr   26.6% of instrs   44.4% of ALL CYCLES
     9 cyc   3,421,949 instr   54.4%             32.7%
    33 cyc     409,890 instr    6.5%             14.4%
     3 cyc     538,100 instr    8.6%              1.7%
    30 cyc      64,092 instr    1.0%              2.0%

**A third of the instructions consume 59% of the cycles.** `tb_m1_boot`'s own comment poses
the question this answers: *"A UNIFORM ~11 means every instruction is genuinely multi-cycle
and a split pays; a BIMODAL distribution means a short average dragged by a few slow classes,
which pipelining barely touches and a targeted fix does."* Median 9 against mean 14.9, with
four sharp peaks at 3 / 9 / 25 / 33, is emphatically the second.

**So the V60 split should target the 25-cycle class, not general pipelining.** If that class
came down to ~12 cycles it is worth ~23% of all cycles — CPI 14.9 -> ~11.5, which is 1.30x and
**more than the 1.25x the 1.63x speed target needs from CPI**. That is an estimate of the
prize, not a measurement of the fix: what the 25-cycle class actually IS has not been
identified yet, and a per-opcode breakdown is the next instrument. The shape says where to
point it.

The tail is negligible and should not be chased: everything above 33 cycles together is under
2% of cycles, and the `63 or more` bucket is 0.5%.

### Isolation on the board: the empty-FIFO fix WAS the regression — 2026-08-29

Flashed with `EMPTY_FIFO_READS_ZERO = 1` and the board went to **sky and sea with no glyphs
and nothing moving**, from an image that had been drawing the attract text, `INSERT COIN(S)`,
`CREDIT 0` and the high-score table. Rebuilt with the parameter at 0 and **the picture came
back**.

The SDRAM constraints and the read-path multicycles were unchanged between those two images
and stayed on, so they are cleared: the regression is the coprocessor being unparked.

    77bec12b   EMPTY_FIFO_READS_ZERO=1, SDRAM constrained   sky and sea, no glyphs
    e85a33ed   EMPTY_FIFO_READS_ZERO=0, SDRAM constrained   attract text back

**This is the deadlock, and it was predicted before the flash rather than after.** Unparking
the coprocessor makes it PRODUCE results; the V60 never drains them; `fout` fills, the TGP
stops taking commands, `fin` fills, and both halt. A halted V60 draws nothing new, which on a
screen is a frozen sky and sea.

**Two process failures, both mine.** The flash bundled the empty-FIFO fix WITH the SDRAM
timing change, so the board could not say which regressed, and the working `.rbf` was
overwritten without a copy, forcing a 13-minute rebuild to recover a known-good image. Keep
the last-known-good `.rbf` in `build/` under a name that says what is in it, and change ONE
thing per flash.

### And it invalidates the scroll census

`FRAME: scroll changes over 2,610 frames: hscr[5002]=1 vscr[5006]=1` was measured on the
run with the fix ON, which deadlocks at ~frame 340. **About 87% of those frames were a halted
machine**, so "the scroll registers never change" was largely a statement about a dead V60,
not about the scroll logic. Re-measured against the shipped configuration.

### The reference does not scroll before ~frame 400 either — 2026-08-29

`tools/mame_scroll_census.lua` samples from frame 400 and reports at 2,000, so every
comparison against our 108-frame bench window was comparing different points in the attract
sequence. Measured directly (`build/dasm/early.lua`):

    MAME  f=20..160    hscr2=0000  ctrl01=0000  ctrl23=0000   hscr2 changed on 0 frames
    ours  f=0..108     hscr2 changed once, window ctrl pair23=0000

**So at matched frames we agree with the reference**, and "we never enter window mode where
MAME always does" would have been a false finding. The reference's own numbers only diverge
from that later:

    f=400   hscr2=000b  ctrl23=2015          layer 2 hscr CHANGED on 1,345 of 2,000 frames
    f=800   hscr2=000e  ctrl23=23db          layers 0/1/3 changed on 18 / 0 / 0
    f=1200  hscr2=0102  ctrl23=23fc          0x4000 per-line table: 0 of 2048 non-zero
    f=1600  hscr2=03dc  ctrl23=23ce

Pair 2/3 is mode 1 throughout — `ctrl & 0x6000` is `0x2000` on every counted frame — with the
low bits moving, so the horizon's split line slides while `hscr` scrolls the pair sideways.
**Vertical movement without horizontal is what you get if the split line moves and `hscr`
does not**, which is the reported symptom, but establishing that needs our run to reach frame
400+ and the 108-frame window cannot show it.

The per-line H-scroll table stays struck off: still 0 of 2048 words non-zero over 2,000
frames, and no layer ever sets `hscr` bit 15.

### Where the V60's cycles go: work RAM at 36 cycles an access — 2026-08-30

`make m1_boot BOOT_CYCLES=300000000`, data-bus latency by page:

    500000   n=1,289,439   46,511,564 stall cycles   avg 36     <- RAMB, the game's work RAM
    400000   n=   87,312    2,995,996                avg 34
    100000-280000 (ROM)    ~1.2 M each               avg 36
    780000-7d0000          ~0.9 M each               avg 32
    600000/610000 (copro RAM)                        avg  8
    700000 (tile RAM)                                avg  8
    910000 (palette) / c00000                        avg  8

**One page absorbs 1.29 M accesses at 36 cycles — 46.5 M stall cycles in a 300 M-cycle run.**
`model1.cpp:992` maps `0x500000-0x53ffff` as `.ram()`: RAMB, 256 KB of work RAM, which lives
in SDRAM here.

**Two separate costs, and neither is SDRAM physics.**

  * **The bus baseline is 8 cycles**, paid by every access including on-chip block RAM. A
    registered M10K read is one cycle; the rest is the req/ack round trip, which must be HELD
    rather than pulsed (see the acknowledge rule in HANDOFF).
  * **SDRAM adds ~28 more.** At 19.2 MHz that is ~150 cycles of the 80 MHz `clk_sys` domain,
    where a CAS-2 read after an activate is roughly 9. So the penalty is the CDC handshake and
    the controller's per-access sequencing, not the memory.

**This is the concrete target for the 1.25x CPI the speed deficit needs**, and it is bus work
rather than CPU work — which matters, because it does not touch the V60's verified behaviour.
Caching RAMB is not obviously the answer: it is read/write, and 256 KB is 256 M10K against
101 free. Shortening the handshake helps every page at once.

**Caveat on the histogram**: 4.6 M instructions retired in a 300 M-cycle window is ~65
cycles/instruction overall, against the histogram's mean of 14.9. The histogram bins
retire-to-retire runs and caps at 63, so long waits are undercounted. Treat 14.9 as the shape
of the common case, and `v60_trace`'s 1.63x against MAME as the reliable relative figure.

### The scroll asymmetry is real, and it is program state — 2026-08-30

`make m1_frame FRAME_CYCLES=2000000000`, 1,461 frames, shipped configuration (coprocessor
parked, so no deadlock and the V60 runs throughout):

    ours   hscr[5002] changed  86 of 1,460 frames    vscr[5006] changed 372
           window ctrl  pair01=0000  pair23=2305
           layer px  tm0=11038  tm1=11733  tm2=59412  tm3=0

    MAME   layer 2 hscr changed 1,345 of 2,000 frames   (~982 scaled to 1,460)
           pair 2/3 ctrl = 0x2xxx on every frame

**Window mode is working**: our `pair23 = 2305` is mode 1 with a split line, the same shape as
the reference's `0x2xxx`. The video path is not at fault.

**The asymmetry is in what the V60 WRITES.** Our vertical register moves 372 times and our
horizontal 86; the reference moves horizontal ~982 times. Mostly-vertical motion with a little
horizontal is the reported symptom on the board, and it follows directly from those counts.

So the tile movement joins the coprocessor behind the same root cause: our V60 diverges from
the reference (interrupt at instruction 25,281, 1.63x speed deficit) and therefore writes
different scroll values. There is nothing to fix in `m1_video` for this.

### And the 36 cycles split three ways — 2026-08-30

Same bench, 814,355 accesses to page 0x50:

    dispatch    4.0 cycles     m_req rising to sdr_req asserted
    sdram+cdc  27.9 cycles     sdr_req to sdr_ack
    finish      4.0 cycles     sdr_ack to m_ack
                -----
               35.9

Dispatch plus finish is 8, which is exactly the on-chip baseline measured on pages 0x60, 0x70,
0x91 and 0xc0 — so that half is the req/ack round trip, paid by every access whatever answers
it. **The 27.9 is the whole prize**: it is 116 cycles of the 80 MHz domain for a read that
needs about 9 after an activate, so roughly a factor of thirteen is not the memory.

Candidates, in the order worth measuring: arbitration against the tile-fetch engine, which
reads SDRAM continuously and would queue the CPU behind it (`docs/HANDOFF.md` carried an
"unexplained 103-cycle character fetch wait" here, WITHDRAWN 2026-09-04: the
average included the ROM download, and the real figure is 18 cycles with 2 of
them arbitration); the two CDC crossings; and per-access
activate/precharge sequencing with no open-row reuse.

### The SDRAM controller is innocent: 8.7 cycles of ~116 — 2026-08-30

Instrumented inside `m1_sdram` on its own 80 MHz clock, port 0 (the V60's data port),
1,504,699 grants:

    wait-for-grant   1.1 cycles
    service          7.6 cycles
                     ----
                     8.7 of the ~116 the CPU waits

**So neither the memory nor the arbiter is the cost.** 7.6 cycles is close to the ~9 a read
needs after an activate, and arbitration is essentially free at 1.1.

**And it is not contention with the video engine, at least not here**: `tb_m1_boot` ties
`p_req[1]` low, so the tile-fetch port is not connected in this bench at all. The only other
masters are instruction fetch (port 2) and the TGP (port 3). That also means this arbitration
figure is a LOWER BOUND on the hardware's, where the video engine reads continuously — worth
re-measuring on `tb_m1_frame`, which drives the real port map.

**~107 cycles of the 80 MHz domain are therefore outside the controller**, in the CDC and the
bus FSM. `m1_cdc_port` uses 3-flop toggle synchronisers, and at the 19.2/80 ratio those cost
about 3 CPU cycles on the A side and 3 domain cycles on the B side — roughly **4 CPU cycles of
the 26 unaccounted for**. The remainder is NOT yet explained and should not be guessed at: the
next measurement is `a_req` to `b_req` and `ack_tog` to `a_ack` on the CPU's own CDC instance,
which splits synchroniser latency from anything serialising behind `a_busy`.

Worth checking in that measurement: whether a partial write's read-modify-write is being
counted as one access at the `m1_main` level but two transactions at the controller — 814,355
page-0x50 accesses against 1,504,699 total grants leaves room for it.

**The CDC split did not measure and the reason is worth keeping.** The counters were written
entirely on `clk_cpu`, but `m_sdr_req`/`m_sdr_ack` are `clk_sys` signals — 80 MHz against
19.2, a ratio of 4.17 — so a one-cycle pulse in the fast domain falls between two slow-domain
edges and is never seen. `cdc_n` stayed 0 and the report printed nothing at all, which looks
identical to a counter that was never reached.

**Sample each signal in ITS OWN domain and hand the timestamp across**, or the measurement is
of the sampling, not the design. That is the sixth instrument fault of this family in two
days: mismatched filters, taps at different levels, a registered signal read on its own write
edge, a tap on a base address with a mirror, a census over a window the machine was dead for,
and now a fast-domain pulse sampled slowly.

What stands without it: **8.7 of ~116 cycles are the controller**, so ~26 of the CPU's 36
cycles are the crossing and the bus FSM, and that is where the 1.25x CPI lives.

### CORRECTION: those bus figures were in 80 MHz cycles, not CPU cycles — 2026-08-30

`tb_m1_boot`'s `cycles` counter increments on **`clk`**, which is `clk_sys` at 80 MHz, not
`clk_cpu` at 19.2. Every latency figure quoted from the by-page table and the phase split
above is therefore in 80 MHz cycles, and dividing by the 4.17 ratio changes the conclusion.

    work RAM access   36 clk_sys = 8.6 CPU cycles     (NOT 36 CPU cycles)
    on-chip access     8 clk_sys = 1.9 CPU cycles

    dispatch  4.0   path 27.9   finish  4.0           all clk_sys
      within the path:  issue 7.0  serve 8.5  return 11.4  = 26.9
      controller:       1.1 arbitration + 7.4 service = 8.5

**The three measurements agree with each other and with the CDC's structure**, which is what
identifies the units as the error rather than the design: the 26.9 measured across the
crossing matches the 27.9 measured at the bus, and the 8.5 measured inside the controller
matches the crossing's own `serve`. A 3-flop toggle each way over a 4.17:1 ratio predicts
about this.

**What this overturns.** The claim that the SDRAM path was ~150 cycles of the 80 MHz domain
for a read needing 9 — "a factor of thirteen is not the memory" — was the same number divided
by the wrong clock. And with it, the claim that the speed deficit is in the bus rather than
the CPU:

    total CPI 14.9  =  ~10.7 execution  +  ~4.2 stall

which is the split already recorded for this core. **Execution dominates.** Halving the CDC
saves perhaps 2 cycles an instruction against the 3 that 1.25x needs, so it is worth doing but
is not sufficient alone, and the V60's own execution CPI is back on the critical path.

**Check the clock a testbench counter runs on before quoting it.** The by-page table has been
in this bench for weeks and its unit was never stated.

### clk_cpu 19.2 -> 22.857 MHz, and why not 23 — 2026-08-30

23 MHz is not synthesisable by this PLL: `Error: PLL Output Counter parameter
'output_clock_frequency' is set to an illegal value of '23.0 MHz'`. The VCO is 480 MHz
(480/25 = 19.2, 480/6 = 80) and the output counters are integer divisors, so the legal values
either side are **480/21 = 22.857 MHz** and 480/20 = 24 MHz. 24 leaves 0.3% against a measured
Fmax of 24.08 and was rejected; 22.857 leaves about 5%.

**Fmax is 24.08 MHz, not the 24.94 recorded earlier.** That figure came from a build without
the read-path multicycles; the current configuration's `clk_cpu` setup slack is +10.549 ns on
a 52.08 ns period, so the critical path is 41.53 ns.

    result   worst setup +0.408 ns, no negative setup slack anywhere
             30,186 ALM, 452 M10K, 0 errors

**The dependent constant moved with the clock.** `m1_ioboard`'s `LATENCY` is 38,577 us
expressed in CPU cycles: 740,684 at 19.2 MHz becomes **881,760** at 22.857. Still inside the
20-bit counter, and still longer than the V60's once-a-frame doorbell, which is the property
that makes the flag stay set after boot. The Makefile's `-GLATENCY`/`-DLATENCY_CFG` pair and
`tb_m1_frame`'s clock period were changed in the same commit.

**Measured effect before flashing**, `m1_frame` at the default window: the V60 reads the
coprocessor result FIFO **276 times (2/frame)** where at 19.2 MHz it managed 20 (0/frame). The
reference does ~1,185/frame, so this is a long way short - but it is the quantity whose being
zero armed the deadlock, and it is no longer zero.

Gain is 1.19x of the 1.63x needed. The rest is execution CPI.

### A probe that indexed a bit outside its vector, and what it hid — 2026-08-30

`m_addr` in `m1_main` is declared `logic [23:1]` — a byte address with bit 0 omitted — so the
word index inside a 64 KB page is `m_addr[15:1]`. A probe written as `m_addr[14:0]` selects a
bit that **does not exist**, never matches, and reports **zero**.

That produced a confident wrong finding and it survived a control check: the controls
(108,098 tile-RAM writes, 1,406,540 acked bus writes) were healthy, because they did not use
the broken index. "Zero writes to the scroll registers while tile RAM is clearly being
written" then looked like evidence of a write-path bug, and the region histogram — also built
on the wrong bits — appeared to corroborate it.

    broken probe   hscr[5002]=0    vscr[5006]=0    all 5000-5007=0
    correct probe  hscr[5002]=130  vscr[5006]=130  all 5000-5007=788

**A control has to exercise the same expression as the measurement**, or it confirms only that
the testbench is running. The other probe in this same file has used `m_addr[15:1]` throughout.

### At matched frames the scroll path AGREES with the reference — 2026-08-30

With the index fixed, over 108 frames:

    ours   130 writes to 0x5002   (~1.2 per frame)
    MAME  2003 writes over 2000   (~1.0 per frame)

**The registers are written at the reference's rate.** What differs is the VALUE: ours barely
changes while the reference's moves constantly from ~frame 400 onward.

The value comes from a table in work RAM. Ours writes `0x501408` from `pc=fe1469` with
`data=0000`; the reference writes `0x501408`/`0x50140a` from `fe48d5` and `fef3b5` with
computed values. But **neither side reaches `fe48d5` or `fef3b5` in the traced window**, and
both execute `fe1469` **exactly 64,512 times** — identical. So the early behaviour matches and
the divergence is later than any window measured so far.

That is consistent with the reference itself: `hscr2` is `0000` and unchanging through frame
160, and only starts moving around frame 400. **Every comparison of the scroll path made
before this one was inside the window where both machines legitimately do nothing.**

### The scroll value is COMPUTED and CONSTANT: 0x501408/0x50140a — 2026-08-30

Past frame 400, where the reference actually scrolls, with the probe indexing fixed:

    hscr[0x5002]   WRITES   ours 1.9/frame      MAME 1.0/frame
    hscr[0x5002]   CHANGES  ours 33 of 525      MAME 1,345 of 2,000

So the register is written faithfully and often; **the value it is given barely moves**. That
value comes from a work-RAM pair at `0x501408`/`0x50140a`, and both machines compute it from
the same two instructions:

    W1400 writes by pc   ours (526 frames)   MAME (700 frames)
      fe48d5                977                 213
      fef3b5              1,001                 214
      fe1469 (the clear)     19                   2
      fe6ab0 (also zeroes)   38                   4

**We run the computing routines about six times more often than the reference and they write a
CONSTANT:**

    ours   fe48d5 -> 0x501408 = 003e      fef3b5 -> 0x50140a = 2fa6
    MAME   fe48d5 -> 0x501408 = 0001      fef3b5 -> 0x50140a = 2064, 2063, and moving
                                                    (2058 / 2fce / 20a8 at frames 300/600/900)

So this is not reachability and not the write path — **the routines' INPUT is static here**.
`0x501408` is `0x3e` against the reference's `0x01`, which is a large difference in what looks
like an index or counter, and is the concrete thing to trace next.

**Three earlier readings of this were wrong and each is instructive:**

  * "we never write the scroll registers" — a probe indexing `m_addr[14:0]` on a `[23:1]`
    vector, so a bit that does not exist. Reported zero on a machine writing 1.9 times a frame.
  * "only `fe1469` writes the table" — the print was capped at the first eight writes, which
    are all the clear. The computing writes come later and were never shown.
  * "the divergence is later than any window measured" — true, and the reason every earlier
    scroll comparison agreed: the reference's own `hscr2` is `0000` until about frame 400, so
    all of them sat inside the window where both machines correctly do nothing.

### The scroll animation is fed by the COPROCESSOR — the chain closes — 2026-08-30

Tracing the constant scroll value back through the reference:

    hscr/ctrl written from        fe48d5 (0x501408) and fef3b5 (0x50140a)
      those read                  0x501320/22 (constant both sides),
                                  0x501a2c/2e and 0x501424/26  <- the animating pair
    the animating pair written by fef25c/fef265 (0x501a2c) and fef39d/fef3a4 (0x501424)
    and THAT routine reads:

        program fef000  8,128     its own code
        program 501000    384
        program 400000    256
        io      d80000    256     <- THE COPROCESSOR RESULT FIFO
        program 403000    192

`0x50140a` is literally `0x2000 | (0x501424 & 0xfff)` — the window mode bits plus a split line
taken from a value the coprocessor supplies. In the reference `0x501424` moves
`0058 -> 0014 -> ffce -> ffda` and `0x501a2c` moves `846b -> 8162 -> 82fc -> 3fa5 -> 763c`;
here both are static, so the split line is fixed and `hscr` barely moves.

**The whole chain, every link measured:**

    V60 is 1.63x too slow
      -> enabling the coprocessor deadlocks it against the V60 (both FIFOs full)
      -> so the coprocessor is parked
      -> so fef25c/fef3a4 read nothing useful from 0xd80000
      -> so the scroll inputs are constant
      -> so the background does not scroll horizontally

**This qualifies the entry above.** "The scroll asymmetry is program state, and there is
nothing to fix in `m1_video`" is right about the video path and about the write path, and
wrong to imply the scroll fault is independent of the coprocessor. It is not: it is the same
root cause, two steps further downstream.

**Open question worth checking before enabling the TGP again:** the V60 reads the result FIFO
276 times per 108 frames while the coprocessor has pushed only 20 results, so most of those
reads find it EMPTY. `m1_copro_if` deliberately withholds the acknowledge on an empty
outbound read, which should stall the V60 — and it plainly does not hang. Either those reads
are the always-completing high half at offset 1, or the interlock is not doing what its
comment says. That is worth settling on its own terms.

### The interlock works, and the "V60 reads the FIFO N times" figure was STALL CYCLES — 2026-08-30

Settling the open question above:

    result-FIFO reads: offset0=273  offset1=20
      of offset0: empty=253, acked-while-empty=0

**The interlock is correct**: not one read of an empty outbound FIFO was ever acknowledged.

But `v60_acc` is `req && !served && ...`, and `served` only latches on the acknowledge — so an
unacknowledged access asserts it on EVERY cycle it is held. The counter was therefore counting
**stall cycles, not reads**. Offset 1 always completes and is counted once per access, so the
true number of completed result reads is **20**, matching the 20 results the parked
coprocessor had pushed. The 253 are cycles spent waiting, spread across those 20 reads.

**This withdraws a claim made in support of the clock change.** "The V60 now reads the result
FIFO 276 times (2/frame) where at 19.2 MHz it managed 20 (0/frame)" compared the same broken
metric before and after, so it is not evidence that raising the clock improved anything. The
clock change stands on its own terms — Fmax headroom that was measured and unused — but that
particular justification does not.

**Counting an event on a held request counts cycles.** Latch the completion edge, or count a
signal that is asserted once per transaction. The same shape as the `pop_data` fault and the
`m_addr[14:0]` fault: the instrument, not the design.

### The V60 never enters the geometry submission path at all — 2026-08-30

**This is the answer, and it is not speed.** Walking up the call chain from the coprocessor's
result reads, none of it is reached in 525 frames:

    FEF9C6 list walk      0     FEFA25 submit    0     FEFB40 jsr       0
    FEF9CC cmp/bne        0     FEFA93           0     FF84A2 gate      0
    FEF9D2 bsr FEFA25     0     FEFAD1           0     FF84AE bgt       0
    FEF9D8 (the skip)     0     FEFB00 in.w      0     FF850C in.w      0

The reference runs `FF850C` **202 times a frame**. We run it zero times, while running
neighbouring routines - `fef3b5` 2,359 times, `fe48d5` 2,335 - thousands of times in the same
window. So this is one large routine that is simply never entered, not a path taken less often.

`FEF7xx-FEFBxx` is the geometry submission routine: it writes commands to `[R24]` and reads
results back with `in.w [R23]`, and `FF84A2` is the block-read that drains the FIFO. **Not
entering it explains every open symptom at once** — nobody drains the outbound FIFO, so it
fills and the two processors deadlock; and the scroll inputs at `0x501a2c`/`0x501424` never
receive coprocessor data, so the background does not scroll horizontally.

**The gate is NOT the reason.** `FF84A2` compares `0x5011B0` against `0x5011A0` and `FF84AE`
branches past the reads on the wrong result — but our values are `5011a0 = 0` and
`5011b0 = 0x157c`, identical to the reference's, so the branch would fall through correctly if
it were ever reached.

**So the chain recorded earlier is wrong where it blamed speed.** "V60 1.63x too slow ->
deadlock -> parked coprocessor -> static scroll" put a throughput number in a place that needs
a control-flow answer: a 1.63x deficit cannot turn 202 executions a frame into zero, and the
arithmetic said so all along — the reference reads that FIFO ~1,185 times a frame against our
0.49, a factor of ~2,400.

Finding what calls `FEF7xx` and why we do not is the next step, and `make v60_trace` over a
window that reaches it is the instrument. The traced window currently ends around frame 115,
before this routine runs, which is why every trace comparison so far has agreed.

### WITHDRAWN: "the V60 never enters the geometry submission path" — 2026-08-30

It enters it. The measurement that said otherwise was taken with
`EMPTY_FIFO_READS_ZERO = 1`, the configuration that **deadlocks at frame ~340** — so the
machine was frozen for the rest of the run and could not reach anything. Re-measured with the
shipped configuration (coprocessor parked, V60 running throughout), same 526-frame window:

    geometry gate  501A35=01  501A28=00000001      IDENTICAL to the reference
    submit chain   fef9c6=35  fefa25=35  fefb00=18  fef9d2=75
    call chain     fefb40=65  ff84a2=452  ff84ae=174
                   ff84b1(reads)=259  ff8582(skip)=390  ff850c=194

**So every routine in the chain runs, and the gate values match the reference exactly.** What
differs is the RATE: the reference executes `ff850c` about 202 times a frame, we execute it
194 times in 526 frames — 0.37 a frame. And the gate at `FF84AE` diverts to `FF8582` on 390 of
452 visits where the reference falls through.

**Measure the configuration you are asking about.** A frozen machine reports zero for
everything downstream of the freeze, and that zero is about the freeze, not about the code.
This is the second finding in two days built on a window in which the machine was not running
— the other being a scroll census over 2,610 frames of which ~87% were post-deadlock.

### The M10K duplication is gone: 452 -> 372 blocks — 2026-08-30

`m1_tdp_ram` shares the tile RAM and palette between the CPU and video ports instead of
keeping a copy each. Quartus confirms a single memory:

    altsyncram:u_ram ... M10K block ; True Dual Port ; 32768 x 16 ; 32768 x 16 ; 524288 bits

524,288 bits is exactly one copy of 32768x16, where the inferred form produced two. Full
build:

    M10K   452 -> 372   (-80, and 372/553 is 67% against 82%)
    ALM  30,186 -> 30,139
    worst setup +0.141 ns, no negative setup or hold slack anywhere

**The Model 2 core solves the same problem the same way** and `rtl/mem/m2_tdp_ram.sv` is the
reference. What differs here: our two ports are on DIFFERENT CLOCKS, so port B needs
`address_reg_b`/`outdata_reg_b`/`indata_reg_b`/`wrcontrol_wraddress_reg_b`/`byteena_reg_b` all
on `CLOCK1` — leaving any of them at `CLOCK0` silently puts that part of port B back on the
CPU's clock. And our CPU port is byte-enabled, so the two byte-wide arrays become one 16-bit
array with a `byteena`. **Both ports must be the same width** or the block is replicated again.

**A 10 ps timing miss is placement luck, not a design fault.** The default seed landed
`clk_sys` at -0.010 ns; `M1_SEED=3` gives +0.141 with nothing negative. Try a seed before
changing logic.

### What is left, and none of it is duplication

    dl0/dl1  128   two genuinely different buffers (the V60 writes one while the renderer
                   reads the other), one read port each, 32 blocks per byte lane is the floor
    ram       32   the coprocessor RAM, single-ported behind m1_copro_if's arbiter
    cxlat     32   at its floor
    g_bank    32   the video line buffers - THE LARGEST REMAINING INEFFICIENCY

`g_bank` is 2 banks x 4 layers x 4 lanes = **32 separate memories of 128x15 bits**, each in
its own M10K: 1,920 bits of a 10,240-bit block, **19% utilisation**, 32 blocks holding 61,440
bits in total. It is structural rather than accidental — the four-lane split exists because a
per-lane byte-enable is the one idiom Quartus 17.0 will not infer as RAM at all, and merging
lanes would need four write ports, which no M10K has. Worth revisiting only with a different
line-buffer scheme.

### Two counting faults, and a V60 bug that was not one — 2026-08-30

**1. `dbg_pc == X` counts CYCLES, not executions.** `dbg_pc` is a level, so the comparison
holds for every cycle the instruction occupies. It showed up as `FF84A2` (a ~25-cycle `cmp`)
at 452 against the `bgt` immediately after it at 174 — consecutive instructions cannot execute
different numbers of times. Edge-detecting the PC transition gives executions, and the numbers
change completely:

    counted as cycles     ff84a2=452  ff84ae=174  ff850c=194  fe1469=2,035,042
    counted as executions ff84a2=7    ff84ae=7    ff850c=6    fefa25=1

So "the gate diverts on 390 of 452 visits" was wrong twice over: those were cycles, and the
gate does not divert at all — `a0 > b0` on **0 of 174** samples taken at `FF84AE` itself, with
`a0=0x257` against `b0=0x157c`.

**2. Our PC trace emits only on a PC CHANGE**, `core.dbg_pc !== pc_prev` in `tb_m1_frame`.
MAME's tracer emits every instruction. **A self-branch therefore records ONCE here and N times
there**, and `FFA6BD` is exactly that:

    FFA6B4: pushm #1
    FFA6B6: mov.w #1388, R0        ; 5000
    FFA6BD: dbr   R0, FFA6BD[PC]   ; branches to ITSELF

MAME 30,000 (6 calls x 5000), ours 6. That looked like a broken `dbr` falling straight
through — a delay loop after a write to the sound USART at `0xC40002`, which would have been a
serious find. **It is a tracing artefact and `dbr` is fine**: the decode reads
`rf_raddr_a = fb[1][4:0]` in `S_DECODE`, `cc4 = 4'ha` maps to `cond_true = 1`, and the loop
executes normally.

Self-loops are the only thing this collapses, and they are ~0.75% of the reference's
instructions, so the interrupts-per-instruction ratio recorded earlier is not materially
affected.

**What still stands:** our V60 executes the per-frame geometry update roughly **once in 526
frames** where the reference runs it every frame — `fefa25=1`, `fefb40=1`, `feef14=1`, and
nothing upstream gates it: `fef325` (the divert) is 0 and `fef9d8` (the skip) is 0. The path
is simply not being called, and finding its caller is the next step.

### THE V60 SPINS ON DPRAM 0x40 AND OUR I/O BOARD ANSWERS 0x20 — 2026-08-30

Found by normalising the two instruction streams instead of walking the call chain by hand.
`v60_trace` parts at instruction 25,281 on interrupt timing; **filtering the interrupt handler
out of both streams** (`fe02bc` to its `retis` at `fe0343`) **and collapsing self-loops in
both** — which our tracer already does to ours and MAME's tracer does not — pushes agreement
from 25,281 to **278,920** instructions, and the first divergence there is real:

    MAME   fe022c fe0232 ... fe0234 fe108f ...     exits the loop
    ours   fe022c fe0232 ... fe022c fe0232 ...     still spinning

    FE03FD: mov.b  #1, C00040      set the flag
    FE022C: test.b C00040          poll it
    FE0232: bne    FE022C          spin until it reads ZERO

`0xC00000-0xC00FFF` is the DPRAM shared with the I/O board (`model1.cpp:1013`, an `mb8421`), so
this is an I/O-board handshake. Measured on the reference over 300 frames:

    dpram 0x20   V60 writes 12      reads 12
    dpram 0x21   V60 writes  0      reads  0        <- nothing ever reads this
    dpram 0x40   V60 writes 295     reads 36,131    <- the byte it spins on

**`m1_ioboard` answers `FLAG_ADDR = 0x020` and publishes `STAT_ADDR = 0x021`, and never touches
`0x040`.** So the V60 sets the flag it actually waits on and nothing ever clears it. The
38,577 us `LATENCY` the board models is right — the reference's first clear of 0x40 takes
**38,389 us**, the same handshake — but it is being applied to the wrong byte.

**And `0x021` is read ZERO times by the reference's V60.** Publishing byte 0x21 was recorded
here as bringing tilemap 1 from 0 to 2,518 pixels, so something changed when it was added; but
the reference never reads it, so whatever that was, it was not this.

This is one wait loop, not a speed problem, and it is upstream of everything measured
yesterday: the main loop stops here, so the per-frame object dispatch runs 0.44 times a frame
against the reference's 5.6, the geometry submission runs once in 526 frames, the coprocessor
is never fed or drained, and the scroll inputs never move. The interrupt handler keeps
drawing, which is why the picture is there at all.

### WITHDRAWN: "the V60 spins on DPRAM 0x40 and our I/O board answers 0x20" — 2026-08-30

Wrong twice over, and both faults are ones this file already warns about.

**1. Byte against word.** `model1.cpp:1013` maps the DPRAM `umask16(0x00ff)`, so only EVEN V60
byte addresses exist and **V60 byte `0xC00040` IS DPRAM word index `0x20`** — which is exactly
`m1_ioboard`'s `FLAG_ADDR`, since it takes `v60_addr = m_addr[11:1]`. Our board answers the
right location. The census that appeared to prove otherwise compared MAME BYTE offsets against
our WORD indices, and its "byte 0x21 sees zero accesses" was an odd address that does not
exist at all — absence of a thing that cannot be there, read as evidence.

**2. The divergence is the timed wait, not a stall.** Measured properly — count the polls
between each SET and the first zero read:

    sets=295   completed waits=1   over 300 frames
      wait 1: 36,131 polls, 38,389 us

**Every one of those 36,131 polls is the single boot handshake.** The reference spins in
`FE022C/FE0232` for 38.4 ms too, and after that the flag is never cleared again and the V60
never waits again — which is precisely what `m1_ioboard` implements and what
`docs/io-board.md` already records. So the instruction-stream divergence at 278,920 is our
slower CPU needing MORE INSTRUCTIONS to cover the same wall-clock wait. A timed wait compared
in instruction counts always looks like a hang on the slower machine.

**To compare past it the loop has to be collapsed on both sides**, the same treatment
self-loops needed. `tools/v60_collapse.py` exists for exactly this and was not used here.

**The Z80 I/O board is probably still the right thing** — the Model 2 core found HLE
insufficient where the board COMPUTES rather than responds, and it is the same physical PCB —
but the evidence offered for it above was not evidence.

### The V60's FP group IS used, so the 2,984 ALM lever is closed — 2026-08-30

`make m1_frame FRAME_CYCLES=700000000 FRAME_DEFS=+define+S32_V60_NO_FP`:

    cycles=421763431  halted=1  fp_trap=1        the trap fires at about frame 326
    layer px  tm0=0 tm1=0 tm2=0 tm3=0            the CPU is stopped, so nothing draws

**Virtua Racing executes V60 floating-point instructions.** `docs/m1-m4-plan.md` recorded
removing the FP group as worth **-2,984 ALM**, about 10% of the device, held open because
"whether Model 1 game code executes V60 FP instructions is unverified". It is verified now and
the answer is that the group must stay.

**The question could not be answered before because the test was vacuous.** `dbg_fp_trap` is
inert by construction in a build that HAS floating point — it only means anything under
`S32_V60_NO_FP` — and `make m1_frame` had no way to pass a define. `FRAME_DEFS` did not exist,
so `make m1_frame FRAME_DEFS=+define+S32_V60_NO_FP` silently built the ordinary core and
reported `fp_trap=0`, which reads exactly like "no FP is used". Only `m1_boot` had `BOOT_DEFS`.
The variable is added, mirroring `BOOT_DEFS`.

**A define that does not reach the build is worse than no test**, because it produces the
answer you were hoping for. Check that the switch moved something — here, `halted=1` and a
blank screen are what the define actually doing its job looks like.

### The V60 agrees for 7 M instructions; the first real divergence is a frame-tick overrun — 2026-08-30

With the interrupt stripped, loops collapsed, and the tracer's cap raised (it was silently
ending the window at 4,000,000 entries — about 2.5 emulated seconds):

    MAME   27,467,032 instructions, 798 interrupts  -> 4,163,971 collapsed
    ours    7,011,730 instructions, 281 interrupts  ->    48,413 collapsed
    DIVERGES at collapsed instruction 33,401

and the divergence is:

    FE13F3: cmp.b #3, 500501
    FE13FB: blt   FE1406        MAME takes it (value < 3); we do not (value >= 3)

`0x500501` is a **frame tick**: the interrupt handler increments it at `FE0320` once a frame
and the main loop drains it at `FE1406`. The reference only ever holds 0, 1 or 2 — measured,
590 writes over 400 frames, values `00`/`01`/`02` only. Ours:

    0=134  1=134  2=133  |  3=2  4=2  5=2  6=2  7+=6

**So we keep up on 97.3% of frames and overrun on 14 of 526.** That is the ~1.25x speed
deficit expressed in the game's own terms, and it is what the trace caught. Interrupts per
instruction now: ours 1/27,536 against the reference's 1/34,432, so **1.25x** — down from the
1.63x measured before `clk_cpu` went 19.2 -> 22.857 MHz, which is the 1.19x that change was
worth. Two independent measurements agreeing.

**But 2.7% of frames does not explain the object dispatch.** `FE1C09` runs 0.44 times a frame
here against the reference's 5.6, and its indirect call fires on 11% of iterations against
66%. A 12x gap is not a 2.7% overrun, so there is a second cause still unaccounted for, and
it sits between the frame tick and the object list.

### The deadlock is ONE BIT: object 0 word 0 is 84000000 here and 80000000 there — 2026-08-30

Our V60 pins at `FEB673` when the coprocessor FIFO fills. **`FEB673` does not appear once in
fourteen emulated seconds of reference trace.** Walking back through our own trace:

    FEB643: mov.w 501118, R28      loop count (15)
    FEB64A: mov.w 501324, R22      object array pointer -> 0x400f80
    FEB651: test1 #1A, 0[R22]      bit 26 of the object's word 0
    FEB65A: be    FEB688           skip when CLEAR
      ours   feb651 feb65a -> feb65c   falls through, into the submission body
      MAME   FEB651 FEB65A -> FEB688   branches, EVERY time

and the body writes geometry to `[R24]`, the coprocessor. The object words:

    ours       84000000  00000000  00000000  00000000  00000000  80000000
    reference  80000000  ...                                     (bit 26 never set)

**One bit — `0x04000000` — on object 0.** It puts us in a submission loop the reference never
enters, which fills the outbound FIFO, which halts the coprocessor, which stops it consuming
commands, which fills the inbound FIFO, which halts the V60. The whole deadlock hangs off it.

**What this displaces.** The deadlock was attributed to the V60 being too slow to drain
results. It is not: the reference does not drain that traffic either, because it never
generates it. The speed deficit is real and separately measured at 1.25x — the frame tick at
`0x500501` overruns on 2.7% of frames — but it is not what arms the deadlock.

**Next: what sets bit 26 of the object at 0x400f80.** That is a single-bit write to a known
address, which a write tap on either side answers directly. The object array is at V60
0x400f80 (pointer at 0x501324, count 15 at 0x501118), and in `tb_m1_frame` that is
`device.mem` word 0xFA07C0 — V60 byte B in the 0x400000 region maps to 0xFA0000 + (B-0x400000)/2.

### Model 1's tile scroll VALUE comes from the coprocessor — verified at register level

Model 2 drives tiles and 3D separately from the CPU, which predicts that Model 1's tile scroll
should not depend on the geometry engine. On Model 1 it does, and this is the data flow rather
than an inference from a PC range:

    FEF372: mov.w   #E800000, [R24]     CPU pushes a command to the coprocessor
    FEF37A: movs.hw E5[R25], [R24]      ...with an angle from the object
    FEF380: mov.w   #C3800000, [R24]
    FEF388: in.w    [R23], R0           READS THE RESULT BACK
    FEF38B: cvt.sw  R0, R0
    FEF3A4: mov.w   R0, 501424          -> the scroll input
    FEF3AB: and.h   #FFF, R0
    FEF3B0: or.h    #2000, R0
    FEF3B5: mov.h   R0, 50140A          -> the ctrl/scroll word

`or.h #2000` then the store is exactly the `0x2000 | (value & 0xfff)` measured from outside,
so the two agree. **And `[R23]` was checked rather than assumed** — a read tap filtered to
`pc == 0xfef388` reports `io d80000` and `io d80002`, 28 each over 300 frames, which is the
32-bit coprocessor FIFO read in both halves. `R23` being the result port was originally
inherited from `FF850C`, a different routine, which is not evidence.

**The plumbing is still CPU-driven** — the coprocessor never touches tile RAM. The V60 pushes,
reads back, masks and writes the tile register itself. What has a data dependency on the
geometry engine is the scroll VALUE, at about 0.09 reads a frame, matching the ~63 frames in
400 on which the scroll registers change.

**Consequence:** with the coprocessor parked, `in.w` returns zero, `R0` is constant, and the
background cannot scroll horizontally. That part of the chain stands.

**The earlier evidence for this did not.** It was a read tap over the 368-byte range
`fef250-fef3c0` that found 256 reads of `d80000` among 9,216, which would have supported the
claim whether or not it was true.

### The root cause: bit 31 of the coprocessor's answer to command 0x20800000 — 2026-08-30

Tracing the one bit back one more level:

    FEB5C0: clr1  #1A, 0[R22]       clear bit 26 on this object
    FEB5C9: mov.w #20800000, [R24]  ask the coprocessor about it
    FEB5D1: mov.w 1E[R22], [R24]    two operands from the object
    FEB5D6: mov.w 26[R22], [R24]
    FEB5DB: in.w  [R23], R0         read the answer
    FEB5DE: test1 #1F, R0           test BIT 31 OF THE ANSWER
    FEB5E5: be    FEB5F0            clear -> skip
    FEB5E7:                         set   -> SET bit 26, marking the object
    FEB5F3: dbr   R28, FEB5C0       next object

A per-object visibility or culling test. **Bit 31 of the coprocessor's reply decides whether
an object is marked for geometry submission**, and the marked objects are what `FEB651` later
feeds into the FIFO.

    FEB5C0 (the clear)   reference 3,990 executions      ours 15
    FEB5E7 (the set)     reference     0 executions      ours  4

The reference's answer always has bit 31 clear, so it marks nothing and `FEB661-FEB687` never
runs. Ours comes back with bit 31 set, objects get marked, geometry floods the outbound FIFO,
the coprocessor halts, it stops consuming commands, the inbound FIFO fills and the V60 halts.

**So the deadlock is the coprocessor's arithmetic, not the V60's control flow.** The V60 is
doing exactly what it is told by a wrong answer. That also displaces the speed explanation a
second time: the reference does not drain this traffic because it never generates it, and it
never generates it because its coprocessor says "no".

**Next: what the reference's coprocessor returns for command 0x20800000, and what ours
returns.** That is a bounded question about one microcode routine and one result word, and it
is the first point in this whole chain where the fault is ours to fix in RTL rather than a
consequence two or three steps downstream.

### The fix target: our coprocessor answers the visibility command with one word, not two — 2026-08-30

Same command, same operands, captured at the FIFO on both sides:

    cmd 20800000  operands c342028f  4128cccd
      reference   ANS 00000000   then   ANS 41170ddd
      ours        ANS 4356e2e1

The reference returns **a zero flag word followed by a value**. `FEB5DE` tests bit 31 of the
FIRST word, gets `00000000`, and skips — which is why it never marks an object and never
submits the geometry that deadlocks us. Ours returns a **single computed word**, so whatever
lands in that first read decides the branch, and sometimes it has bit 31 set.

Further reference pairs, for a regression test:

    c342028f 4128cccd -> 00000000 41170ddd
    c34211ec 41953333 -> 00000000 41734eb0
    c34d8a3d 41de3d71 -> 00000000 41a5ec1b
    c34d947b 4222b852 -> 00000000 42068fb4
    c3426148 4262eb85 -> 00000000 424b366b

**Where the fix is.** `get_exp(0x20800000)` is `(0x20800000 >> 23) & 0xff = 0x41`, and the
dispatch at `0052 brul alw d` jumps to `d = get_exp(b) + 0x53`, so this is **microcode handler
0x94**. Our TGP executes that handler differently — it produces one result where the reference
produces two — and `make tgp_trace` around pc 0x94 is the instrument.

**Note on the capture**: each line appears twice in `build/frame_answers.txt` because
`v60_acc` is asserted on both cycles of a held access. That is the probe, not duplicated
traffic — the same trap as the result-FIFO read count earlier today, where a held request read
as repeated reads.

**And the opening exchange already agrees.** Our first 400 commands match the reference's
stream and our answers include its dominant `42520000`, so this is not a broken coprocessor —
it is one handler.

### WITHDRAWN: "an empty command FIFO must read as ZERO" — 2026-08-30

**Handler 0x53 is a real command handler, not an idle dispatch, and that was the whole basis
of the change.** The microcode at 0x9b, which 0x53 jumps to:

    009B: mov (x1), d       pop a word
    009C: mov (x1), a       pop another
    009D: fadd : mov $0xd, x1
    009E: mov d, (bx1)      PUSH THE SUM AS AN ANSWER
    009F: brif alw #0x4c

So a command whose exponent field is 0 means "add the next two words and return the sum".
Reading an EMPTY fifo as zero therefore dispatches into that handler, pops two more zeros,
adds them and pushes `00000000` as an answer the V60 never asked for. Measured, with the
parameter on and off, over the same window:

    EMPTY_FIFO_READS_ZERO=1   17 answers of 00000000 from pc=009e, THEN 42520000 from 00a8
    EMPTY_FIFO_READS_ZERO=0   42520000 from 00a8 immediately - identical to the reference

**MAME returns zero from the pop AND stalls, so the zero is never consumed.** `gen_fifo.h`:
the pop returns zero, `on_fifo_empty_pre_sync` asks the destination to try again, and
`on_fifo_empty_post_sync` HALTS it if the fifo is still empty. The retry is the point. Quoting
only the "returns zero" half — which is what was done — inverts the behaviour.

**So stalling was right all along, and parking at 004C on an empty FIFO is correct**: MAME
halts its coprocessor in exactly the same situation. `EMPTY_FIFO_READS_ZERO` stays 0 and the
parameter should probably be deleted rather than left as a trap.

**And the deadlock traced all day was caused by this change.** With the parameter off there is
no deadlock: the frame bench runs to 526 frames with `fin=0/16 fout=0/16`. The chain built on
top of it — "bit 26 of object 0", "the coprocessor answers the visibility command wrongly",
"the V60 is too slow to drain results" — was all downstream of a self-inflicted fault. Every
capture taken while the parameter was on has to be discarded, including the command-stream
comparison that put the first divergence at command 77.

**The lesson, and it is the same one as the deadlocked-window census:** an experimental switch
left on turns every subsequent measurement into a measurement of the switch. Check the
configuration is the shipped one before believing anything downstream of it.

### CORRECTION to the withdrawal above: the deadlock happens WITHOUT the parameter too

The withdrawal said "with the parameter off there is no deadlock". **That is wrong.** It came
from reading `fin=0/16 fout=0/16` at 80 M cycles — early in a run, not at the end. Measured to
completion with `EMPTY_FIFO_READS_ZERO = 0`, the shipped default:

    640 M cycles  pc=ff8504  frames=483  fin=16/16 fout=16/16 v60_stall=1 tgp_wr=1
    700 M cycles  pc=ff8504  frames=526  fin=16/16 fout=16/16 v60_stall=1 tgp_wr=1

So the deadlock is real and is NOT an artefact of that parameter. `pc=ff8504` is inside the
result-reading block, one instruction before `FF850C`'s `in.w`, so the V60 is stalled writing
a command while trying to read results.

What the parameter withdrawal does still stand on: handler 0x53 IS a command handler, reading
an empty FIFO as zero DOES emit 17 answers nobody asked for, and stalling IS what MAME does.
Those are measured. Only the "and therefore no deadlock" conclusion was wrong.

### Open lead: our command stream looks DOUBLED

Logging one line per increment of the FIFO write pointer `fin_wr`, in the shipped
configuration:

    ours   2,098 pushes, 1,121 of them adjacent-equal
    MAME   04000000 01000000 3f400000 428c0000 ...   no adjacent duplicates
    ours   04000000 04000000 01000000 01000000 ...

The per-frame rate matches the reference (4.0 against 4.3), so this is not extra traffic — it
is **half as many distinct commands, each pushed twice**, which would fill the inbound FIFO at
twice the necessary rate and is a plausible cause of the deadlock.

**NOT CONFIRMED, and the check that would settle it did not run.** Two explanations remain
open: the V60 issuing two bus writes to the command port, or `m1_copro_if` pushing twice for
one access. Counting the V60's acknowledged high-half writes against the pushes separates
them; that probe failed to compile and was not retried.

Weighing against the doubling being real: an earlier measurement compared 61 of our pushes
against the reference's 61 and found them IDENTICAL, which a doubled stream cannot be. Either
something regressed between those two measurements, or one of the two probes is wrong. **That
contradiction has to be resolved before acting on this.**

### RESOLVED: the "doubled command stream" was the probe, inserted twice — 2026-08-30

The anchor used to insert the command/answer logger —
`if (core.main.rst_n && core.main.m_we && core.main.m_ack` — occurs **twice** in
`tb_m1_frame.sv` (once with `sel_tileram`, once as the write-ack control counter), and the
insertion was a text replace without a count. The logger therefore landed in two separate
always blocks and wrote every command and every answer twice, sharing one counter. That is
the whole of the "2,098 pushes, 1,121 adjacent-equal pairs" result, and the "17 spurious
answers" count was doubled the same way (it was 17 real ones - that part stands).

The 61-for-61 identical push comparison stands; the doubled stream is withdrawn; and the
"first differing command at 97" from the pair-halved stream is unverified pending a clean run.

**A text replace without a count is an edit to every match.** Count the anchor first, or
insert at something unique. `tools/copro_stream_diff.py` now does the comparison from a single
probe placed at `endmodule`.

### THE DEADLOCK'S CAUSE: the outbound zero-on-empty change, measured and reverted — 2026-08-30

With a single, verified probe (`tools/copro_stream_diff.py`), shipped configuration, 526
frames:

    commands  672 identical, then at 673:
      MAME   18800000  c34e5382 41f15c2c 408ac7be c34c86b6
      ours   18800000  00000000 00000000 00000000 00000000
    answers   258 identical, then at 259 (704 commands in - AFTER the command divergence):
      MAME   00000000     ours   ffffffff   from microcode pc=045d

**The command stream diverges first**, so the coprocessor's wrong answers are downstream of
being fed zeros. Where the zeros come from, read off the reference trace:

    FF84B6: mov.w  5017F4, R5          destination pointer
    FF850C: in.w   [R23], [R5+]        result reads, stored through R5   <- fills the matrix
    ...
    FEB58A: mov.w  40C900, R20         structure pointer
    FEB5F7: mov.w  #18800000, [R24]
    FEB5FF: mov.w  72[R20], [R24]      the matrix pushed back as operands
    ...     9E[R20]

So the operands ARE earlier results, read back at `FF850C` and stored. **The outbound
zero-on-empty change made that read return zero instead of waiting.** Our TGP runs at 1:1 with
the V60 where the board runs 2.5:1, so the V60 reaches `FF850C` before the results exist,
consumes zeros, stores zeros, and pushes zeros at command 673. The real results then arrive
in `fout` with nobody coming back for them: `fout` fills, the TGP halts, it stops consuming,
`fin` fills, the V60 halts at `ff8504`. That is the whole deadlock, and it explains the
measured order - `fout=16/16` with `fin` empty first, then both.

**gen_fifo returns zero from the pop AND makes the reader retry.** The retry is what matters:
the zero is never consumed. Quoting the first half without the second inverted the behaviour,
in BOTH directions, one day apart. The inbound side was caught by the 17 spurious answers;
the outbound side by this. Both FIFOs now stall on empty, as they did before yesterday.

`m1_copro_if` and its test are reverted to the stall; the test's comment records why the
zero-and-complete version stood for a day.

### The revert fixes the deadlock; the zeros at command 673 are something else — 2026-08-30

Same 700 M-cycle window, outbound stall restored:

    before   fin=16/16 fout=16/16 v60_stall=1 from frame ~483   1,136 commands   438 answers
    after    fin=0/16  fout=0/16  v60_stall=0 throughout       13,947 commands  5,995 answers

**No deadlock, and twelve times the coprocessor traffic.** That part of the entry above
stands. What does NOT stand is the explanation for the zeros: with the stall back, command
673 STILL pushes `00000000 x4` where the reference pushes four floats, so the zero-read was
not what zeroed the matrix. And the link that entry inferred - that `FF850C` fills the matrix
- is wrong: `R5 = [0x5017F4] = 0x60xxxx`, the coprocessor RAM window, so `FF850C` stores
results into copro RAM, not into `72[R20]`.

**Who actually fills the matrix, measured on the reference** (`build/dasm/matrix.lua`):

    FEDA41: mov.w #D000000, [R24]      command 0D000000
    FEDA49: mov.w [R3+], [R24]         three ROM vectors from 0xFD3826
    FEDA4D / FEDA51
    FEDA55: in.w  [R23], [R4+]         three RESULTS into 72[R25], 76, 7A
    FEDA59 / FEDA5D
    ... four times over, 12 floats

So the matrix is built from coprocessor ANSWERS to command 0D000000, and it is zero in the
reference too until that routine first runs: `MXW 400d72 pc=feda55 f=272`, and command 673
follows at `f=273`. One frame apart, same pass.

    FEDA55 executions   ours 16 in ~281 frames    reference 8,518 in ~798 frames

Two hundred times rarer here. Whether ours has run `FEDA02` by ITS command 673 is what the
frame-stamped capture answers.

### THE BUG: V60 `IN` with a memory destination never stored — 2026-08-30

Traced by logging every bus access the matrix routine makes (`FEDR`/`FEDW` in `tb_m1_frame`):

    FEDR d80000 pc=feda55 data=5382      in.w [R23],[R4+] READS c34e5382 - the reference's
    FEDR d80002 pc=feda55 data=c34e      exact matrix value - and NO WRITE TO 0x400d72 FOLLOWS

The port read is right. The store is dropped. `rtl/cpu/v60/v60.sv`, `S_IN_RD`:

    wb_op2(dimext(bus_rdata, cur_op[2:1]), cur_op[2:1]);
    if (st == S_IN_RD) st <= S_NEXT;   // "wb_op2 may divert to S_WB_MEM"

`wb_op2` sets `st <= S_WB_MEM` for a memory destination - NON-BLOCKING - so `st` still reads
`S_IN_RD` on the next line, the guard is always true, and the later assignment wins. The
S_WB_MEM state that issues the store is never entered. Register destinations (`flag2`) take
`setreg` inside `wb_op2` and are unaffected, which is why `in.w [R23], R0` at FEF388 worked and
every `in.w [R23], [Rn+]` silently did not: the FEDA55 matrix fill, and the FF850C result block
into copro RAM.

Fix: `if (flag2) st <= S_NEXT;` - a register destination is done, a memory destination has
already been pointed at S_WB_MEM. **The same pattern at S_ROTC** (`if (st == S_ROTC) st <=
S_NEXT` after `wb_op2`) was found by scanning for it, not by a test, and fixed the same way.

    V60 unit suite   29/29     make test   37/37

**No unit test covers IN with a memory destination** - `grep -rli 'in\.[bhw]' third_party/
s32/verif/v60/` finds nothing - and the suite arrived from a System 32 project where the I/O
space is unused, so the whole `IN`/`OUT` path was never exercised there. This is the second
IN/OUT fault found by tracing real code (the first was OUT's swapped operands, at instruction
197,250), and both were invisible to per-opcode fuzzing because that harness never generated
the instruction.

**What this explains, in one place:** the matrix at 72[R20] stayed at its init zeros, so
command 673 pushed 00000000 x4 where the reference pushes four floats; the coprocessor then
computed on zeros and its answers diverged from #259; the scroll value derived from those
answers barely moved; and with the outbound zero-read in place, the results the V60 never
came back for filled fout and deadlocked the pair. Each of those was measured as a separate
symptom this weekend and attributed to something else - speed, the FIFO semantics, a
microcode handler, a single object bit - before the store was traced.

### THE SECOND BUG: the CDC port re-accepted a held request with its OLD address — 2026-08-30

With the IN fix in, the command stream is identical over all 4,000 and the answers diverge
at #767, from microcode `037c`, on identical inputs. That handler computes from a sincos
lookup, so the sincos unit's traffic was logged on both sides (`tools/sincos_diff.py`,
addresses normalised - our probe logs unit-relative 0-3, MAME's tap absolute 0x20-0x23):

    249 events identical, then
      MAME  SCW 20=00000131  SCR 22=bcef8326  SCR 21=3f7fe3fc
      ours  SCW 20=00000131  SCR 22=bcef8326  SCR 21=3cef8326

Same base, same first read, and the second read - `0371: mov $0x21 (e)` immediately after
`0370: mov $0x22 (e)` - returned **the previous lookup's table word** (entry 0x131, unflipped)
instead of the mirrored entry 0x3ecf. Not the table, not the unit: a back-to-back handshake.

**The mechanism, in `m1_cdc_port`.** It accepted on `a_req && !a_busy`, and `a_busy` clears
on the same edge that raises the one-cycle `a_ack`. The TGP core holds its request as a
LEVEL: it sees `io_ack` during the ack cycle with its old address still on the bus, and
presents the next read only from the following edge. So on the ack+1 edge the port saw
`a_req && !a_busy` again and re-accepted **the old address**; ran a duplicate transaction;
ignored the core's real next request as busy; and delivered the duplicate's ack - with the
old data - as if it were the new read's. Every sincos-dependent answer from there was wrong.

The V60's path never showed it because `m1_main` drops `sdr_req` on the ack cycle and idles
through B_ACK before issuing again; the port's comment even documented `a_req` as a
one-cycle pulse. Both real requesters drive a level.

**The fix**: refuse acceptance on the ack cycle only when the request was ALREADY high on the
ack cycle - `!(a_ack && a_req_d)`. A bare `!a_ack` guard drops a fresh pulse that lands on
that cycle and hangs the requester: the port's fuzz bench completed 1 of 20,000 that way.

**The test models the core's one-cycle lag, and had to.** A bench requester that switches to
the new address in zero time after the ack is faster than the hardware and passed on the
broken port; presenting the old address for one more edge, as the core does, makes the old
port fail (`addr 3ecf read 0858, expected b7aa`) and the new one pass. Both were run.

    m1_cdc_port: checks=254848 -> 254853 fails=0     make test 38/38

### THE COPROCESSOR IS BIT-EXACT AGAINST THE REFERENCE — 2026-08-30

With both fixes in - `IN` storing to memory, and the CDC port not re-accepting a held
request with its old address - the frame bench over 526 frames, shipped configuration:

    commands   IDENTICAL over all 4,000 captured      (was: diverged at 673)
    answers    IDENTICAL over all 4,336 captured      (was: diverged at 259, then 767)
    sincos     IDENTICAL over 1,545 events            (was: diverged at 250)
    fin/fout   0/16 throughout, no deadlock           (was: both 16/16 from frame ~340)
    TGP pushed 75,669 results (~144/frame; reference ~168 at 1.25x our speed)
    layers     tm0=7449 tm1=6919 tm2=176096  window ctrl pair23=202a
    scroll     hscr[5002] changed 44 of 525 frames, vscr 73   (was 33 / 96)

Every word the V60 pushes and every word the coprocessor answers matches MAME for the
whole traced window. M0 exit criterion 2 asked for instruction-accuracy on real microcode
over a busy window; this is the value-level form of it, and it is stronger than the PC diff,
which cannot compare a poll loop across two machines with different clock ratios.

**On the scroll count.** 44 changes in 526 frames is not the reference's 67% of frames, but
the reference's `hscr` only starts moving around frame 300 and drifts slowly at first
(`000b` at f=400, `000e` at f=800), and at 1.25x slower our frame 526 is the reference's
~420. The scroll VALUE is derived from coprocessor answers that are now identical, so the
value-level check is the one that counts; a longer run would settle the rate.

**Two V60-side facts from the same run that are NOT problems:** `TGP retires=9217 pc=004c`
is the 16-bit counter wrapped and the idle park, and "read the result FIFO 8,605,502 times"
is the held-access cycle counter, not reads. Both were documented as unreliable yesterday.

**What it took, for the record.** Two bugs, neither in the place the symptoms pointed:

  1. `S_IN_RD` overrode `wb_op2`'s `S_WB_MEM` with a guard that read the old `st`, so every
     `in.w [R23], [Rn+]` read the port and dropped the store. Found by logging the matrix
     routine's bus accesses: the read returned the reference's exact value and no write
     followed.
  2. `m1_cdc_port` re-accepted a level request on the ack+1 edge with its old address, so two
     back-to-back coprocessor table reads returned the first's word for the second. Found by
     logging the sincos unit's traffic on both sides after the answer streams diverged on
     identical commands.

Both have directed tests that fail on the old RTL and pass on the new; both suites and the
38-suite baseline are clean.

### Scrolling: the VALUES are now the reference's, the SEQUENCE alternates — 2026-08-30

`tools/scroll_diff.py` diffs the sequence of values the V60 writes to tile words 0x5002 and
0x5006 against the reference's, both raw and as distinct values in order:

    5006  MAME  0000  2032@f273  2064@f274  2063@f275  2062@f277    advances a step a frame
          ours  0000  2064@f328  2032@f329  2064@f330  2032@f331    alternates two states
    5002  MAME  0000  0001@f276  0013@f277  0025@f278  0024@f293
          ours  0000  0001@f334  0000@f335  0001@f336  0013@f337  0025@f338

**Every value ours writes is one the reference writes** - 2032, 2064, 0001, 0013, 0025 -
which was never true before the two fixes; the coprocessor-derived arithmetic is right. What
differs is the ORDER: the reference progresses through its states once, ours flips between
two of them frame by frame. On the board that should show as the background in the right
place but jittering between two positions rather than drifting.

The value at 0x5006 is `0x2000 | (answer & 0xfff)` where the answer is the coprocessor's
reply at `FEF388` to the operand pushed at `FEF37A` (`movs.hw E5[R25]`). So the alternation is
either the V60 asking a different question on alternate frames (R25 pointing at a different
object, or E5[R25] itself alternating) or the TGP answering the same question differently.
Logging that exchange's (operand, answer) pairs per frame on both sides separates the two.

Frame offset: ours reaches the same program point ~55 frames later (f=328 against f=273),
the 1.25x speed ratio, as expected.

### Scroll: identical operands and answers, a third the update RATE — 2026-08-30

The exchange the scroll value comes from (`FEF37A` pushes the operand, `FEF388` reads the
answer), per frame, both sides:

    reference   OPER ffffef9e f=273  ffffefc5 f=275  ffffefec f=277  fffff014 f=279
    ours        OPER ffffef9e f=327  ffffefc5 f=334

**The operands are identical and so are the answers** (`42c85e9d`, `42c69b41`) - the
coprocessor path is exact. The reference runs the update every 2 frames; we run it every 7.
So the horizon lands on the right values in the right order but steps in larger jumps, which
on screen reads as flicking between positions rather than drifting. That is a RATE difference,
consistent with the 1.25x speed deficit and whatever else throttles that path, not an
arithmetic fault - and the earlier "alternates two states" reading was the same thing seen
through the write stream.

Nothing further is learnable about the 2D from here without the 3D running: the rasteriser is
what makes the rest of the frame's work exist.

### Rasterizer: objects per frame measured, quads per frame NOT measurable from outside — 2026-08-30

`docs/m3-rasterizer-spec.md` says the quad count per frame decides the sorting structure and
whether D3's premise survives, and must be measured. Attempted, and the honest result is
partial.

**Measurable.** The display lists are CPU-visible (`model1.cpp:994-995` map `0x600000` and
`0x610000` with `.share()`), so the walker can be replicated in Lua from
`model1_v.cpp:1464+`. Walked to its end marker, over 700 reference frames:

    objects per list   mean 49.8   max 59      direct (type 2) records: 0
    object size field  5500 on every one of 42,269 objects, never 0

So the frame is **~50 objects**, and the attract sequence uses no `draw_direct` polys at all -
which means the unsorted batch path is not exercised by anything measured so far.

**NOT measurable this way, and the first attempt gave a nonsense number.** Summing the size
field gave 273,827 "quads" per frame - 15 M/s on 1993 hardware, which is the tell.
`push_object` treats `size` as an UPPER BOUND (`if (!size) size = 0xffffffff;` then
`for (i = 0; i < size; i++)` breaking on an end marker inside the polygon data), and 5500 is
that bound, identical for every object. The real count is where the loop breaks, in
`m_poly_ram`/`m_poly_rom` - MAME-internal arrays, not in the CPU map, so no Lua tap or read
can reach them.

**Getting the real number needs one of:** a patched MAME that counts `m_quadpt` advances;
walking the polygon ROM ourselves once its format is transcribed; or measuring it from our own
list walker when one exists. None is a five-minute job, and the spec is right that the number
comes before the design - **50 objects a frame does not tell you whether that is 500 quads or
50,000**, and the difference decides between per-band insertion, a hardware merge sort, and a
bucketed approximation.

### Scroll: values exact, rate ~40x low, and the cause is NOT the I/O flag — 2026-08-30

Corrected from "diagnosed": the arithmetic is diagnosed, the rate is not.

    scroll exchange (FEF372/FEF388)   reference 114 in ~227 frames, every 2
                                      ours        3 in 526 frames

Operands and answers are identical where they occur, so the coprocessor path is exact. A
1.25x speed deficit cannot produce 40x, so the earlier attribution to speed was wrong.

**Walked up the call chain, edge-detected** (`dbg_pc` is a level; comparing it directly counts
cycles, which has caught me twice):

    ours       fe1c09=753  fe1c15=419  feeb10=1  | feef14=3   fef047=3   fef372=3
    reference  FE1C09=47294 FE1C15=35388 FEEB10=1 | FEEF14=266 FEF047=266 FEF372=266

The dispatch loop and its indirect calls run (753/419 against 47,294/35,388 over a longer
window), and `FEEB10` is 1 on BOTH sides - an init, not the caller. The chain stops at
`FEEE49 test.b 40DC8C / FEEE4F be FEEF06`, which runs 266 times there and ~3 here, so the
routine containing it is what is not being entered.

**The I/O board command-code hypothesis is dead, measured.** Model 2's `docs/io-board.md`
establishes that the flag is a command code - 1 acknowledges, 2 copies the window, 3 clears
and restarts - and that a responder clearing on any non-zero write is "silently wrong for 2
and 3". `m1_ioboard` is exactly that responder. But Virtua Racing writes **`01` and nothing
else**, 495 times over 500 frames, all from `fe03fd`. The distinction does not arise in this
game, so this is not the fault here.

Also note the routine above the gate does `FEEE30: in.w [R23], [R1+]` - the IN-to-memory form
fixed today - so its behaviour changed with that fix and any pre-fix measurement of it is void.

### listctl matches, so rendering is not what gates the scroll routine — 2026-08-30

Checked before parking the scroll question, because if the game waited on the video hardware
then the scroll rate would be a symptom of having no rasterizer rather than a bug:

    read       ours (lc0_fixed | 0x0030)      MAME  m_listctl[0] | 0x30
    toggle     bit 2 set and every 2nd frame  MAME  (m_listctl[0] & 4) && (frame & 1)
    bit 2 clear  combinational mirror         MAME  recomputed in set_current_render_list

`m1_listctl` reproduces all three. That register is the ONLY signal MAME models from the
rendering side back to the game, so the absent rasterizer is not throttling `FEEE49`, and the
40x scroll-rate deficit is a real and separate defect.

**Parked deliberately anyway.** With only the sky and sea drawn there is nothing on screen to
judge the scroll against, so the next measurement of it is worth more after the rasterizer
than before. The chain is recorded above to the exact instruction (`FEEE49 test.b 40DC8C`,
266 executions against 3) for whoever picks it up.

### M2's exit criterion is met, and the coprocessor does NOT do the vertex transform — 2026-08-30

**M2's criterion**, `docs/m2-tgp-integration.md` step 6: "Polygon list capture off
`copro_fifo_out`, diffed frame by frame against MAME. Bit-exact agreement with the reference,
checked in volume." Measured today with `tools/copro_stream_diff.py`, shipped configuration:

    commands  IDENTICAL over all 4,000 captured
    answers   IDENTICAL over all 4,336 captured    (answers ARE copro_fifo_out)
    sincos    IDENTICAL over 1,545 events

That is the criterion, and it became true when the `IN`-to-memory and CDC-port bugs were
fixed. Volume is moderate rather than the millions the unit fuzzes ran to, so the honest form
is: bit-exact over every command and answer in a 526-frame window, with the streams captured
at the FIFO on both sides.

**And the same data corrects the doc's premise about the transform.** That file says "The TGP
does the transform *and* the maths the game logic consumes". The output volume says otherwise:

    coprocessor answers   168 per frame (58,868 over 350)
    objects per frame     ~50, each with a size bound of 5500
    a per-vertex transform of 50 objects x 10 polys x 4 vertices would be ~2,000/frame

168 results a frame cannot carry the frame's transformed geometry - it is not even enough for
a 4x4 matrix per object (800 floats). The display list also carries `poly_adr` POINTERS into
polygon ROM (`push_object(tex_adr, poly_adr, size)`), and `model1_v.cpp` transforms that
model-space data itself at draw time. So the transform is downstream of the coprocessor, in
the video hardware, and **M3's scope includes vertex transform, projection and frustum
clipping** - not just the fill path that exists.

That is a materially bigger M3 than "wire up the fill unit", and it is better known now than
after building the wrong thing. What exists (`m1_raster_fill`, verified over 152,025 quads)
takes ALREADY-PROJECTED screen coordinates, which is the last stage of that pipeline.

### M3 and M4 sizing, measured — the polygon ROM is not loaded and sound is 8,837 ALM

**The `polygons` region is absent from our MRA.** Virtua Racing's ROM regions against
`mra/Virtua Racing.mra`:

    maincpu          12 files, all 12 present     5.2 MB
    copro_data        4 files, all  4 present     2.0 MB
    tgp_copro         4 files, only 1 present     4.1 MB   <- partial
    polygons          8 files, NONE present      16.0 MB   <- the 3D models
    ioboard:eeprom    1 file,  none present        128 B
                                        total     27.4 MB

**There is nothing for a rasterizer to draw until those eight files are loaded.** This is the
same class of miss as the coprocessor data ROM, which the rules file records as costing two
sessions of a stalled coprocessor with a 2.25 MB length mismatch sitting in plain sight -
and `make verify_mra` exists precisely to catch it.

27.4 MB fits the single 32 MB stick D2 requires (D2 sized it at "roughly 31 MB"), but the
polygon ROM is over half of it, and the rasterizer's traffic against it has never been in a
bandwidth budget.

**M4's area is measured, not estimated - from the Model 2 core's own fit report**, which
builds the same sound board (68000 + YM3438 + 2 x MultiPCM):

    m2_sound_board   8,837 ALM        fx68k          1,995
      multipcm x2    3,703              pcm_fetch x2 2,273
      jt12 (YM3438)    631

**8,837, against my guess of 6-8k and against 11,772 ALM free.** That leaves ~2,900 for the
whole of M3, which the transform, projection, clipping, sort and band buffer will not fit
into. Freeing area is therefore a prerequisite for M3+M4 together, not a later tidy-up, and
the debug overlay is only **207 ALM** (`m1_diag`; the 1,058 in `osd:*` is the framework's
menu, not ours). The V60 is 17,643 - 59% of the design - and Model 2's i960 does a comparable
job in 7,200.

### Costed: dropping one MultiPCM saves ~3,000 ALM and 4 MB of ROM

From the Model 2 core's fit report, a PCM channel is the chip AND its fetch unit:

    m2_multipcm:u_pcm1  1,861   +  m2_pcm_fetch:u_p1fetch  1,151  =  3,012
    m2_multipcm:u_pcm2  1,841   +  m2_pcm_fetch:u_p2fetch  1,122  =  2,963

So one channel is ~3,000 ALM, taking the sound board from 8,837 to ~5,800, and 4 MB off the
ROM budget with it.

**It is not a polyphony trade.** `M1AUDIO_MPCM1_REGION` and `M1AUDIO_MPCM2_REGION` are two
SEPARATE 4 MB sample regions in every Model 1 set, so dropping one loses whatever sounds live
in that half rather than reducing the voice count on a shared bank. Acceptable to get sound in
at all; it will be audibly missing something specific rather than thinner.

### M3: the 3D path carries LIT RGB, not a palette index, and 24bpp doubles the band — 2026-08-30

**The compositing interface in `m1_tile_mixer` is the wrong shape for the real thing.** It
takes `poly_index[11:0]`, a palette index, at priority between the cat1 and cat0 tiles. But
MAME's quad colour is

    cquad.col = scale_color(machine().pens[0x1000 | (m_tgp_ram[tex_adr-0x40000] & 0x3ff)],
                            MIN(1.0, ln));

a palette entry **multiplied by a lighting factor**, which lands between palette entries -
hence `fill_quad` writing into a `bitmap_rgb32` while the tile path stays indexed. An index
cannot carry it.

Two ways to composite, and the mixer needs a change either way:

  * the mixer keeps deciding the winner and gains a "the poly won" output, with the final
    RGB muxed after the palette lookup - small, and keeps the tile path indexed;
  * or the mixer moves downstream of the palette and works in RGB throughout - larger.

**And the pixel width is not a linear trade, because M10K packs by configuration:**

    17 bits  x20 (512x20)    62 blocks single, 124 double
    16 bits  x16 (512x16)    62 blocks single, 124 double
    25 bits  x32 (256x32)   124 blocks single, 248 double    <- 24-bit RGB + hit
                                                     free: 181

**24-bit colour DOUBLES the band buffer**, because 25 bits rounds up to a x32 configuration
and halves the words per block. So RGB565 + hit at 62 blocks is the efficient point, and
`docs/m3-rasterizer-spec.md`'s "16bpp costs nothing in fidelity" is right about the palette
entries being xBGR-555 but does not account for the lighting multiply - lit polygons DO get
quantised to 5-6-5.

**A third option preserves full precision at the same 62 blocks**: store the 10-bit palette
index plus a ~5-bit lighting level plus the hit bit, and apply `scale_color` at scanout. It
costs a second palette read port, which the current single-ported `m1_palette` does not have.
Recorded rather than taken - it is the better answer if the port is affordable when the
scanout is built.

---

## The polygon ROMs were never in the MRA — 16 MB of geometry the core could not have read

**2026-08-30.** `vr`'s `polygons` region is eight 2 MB files loaded as four
`ROM_LOAD32_WORD` pairs (`mpr-14890`..`14897`, at 0x000000/0x400000/0x800000/0xc00000),
and **not one of them was in the MRA or in the packer.** The core has never had access to
the 3D geometry at all.

Nothing noticed, and nothing could have: with no rasterizer, a missing 16 MB region looks
exactly like a working core. **This is the coprocessor data ROM's failure repeated** —
that one was in the packer but not the MRA, so simulation worked and hardware stalled for
two sessions. `make verify_mra` exists because of it and is what caught this pair being
added consistently now:

    MRA expands to   25,427,968 bytes
    packer produces  25,427,968 bytes
    OK  every byte matches

Both tools grew the region independently — `POLYGONS`/`POLY_OFF = 0x840000` in each — so
the layout keeps the two sources the check depends on.

**The map strings are `0021` and `2100`**, derived from the existing `copro_tables` pair
and confirmed against it: for `output="32"` the digits run byte 3 down to byte 0, so a
part supplying bytes 0-1 of each word is `0021` and one supplying bytes 2-3 is `2100`.

**And `vr.zip` does not contain `mpr-14897.33`.** It has seven of the eight. The eighth is
in `~/roms/vr decapped/` at MAME's exact CRC (`74873195`), so the file is good and the set
is short — checked against the loose directory first, because the rules file records
`315-5573.bin` being declared missing on a zip-only audit when it was sitting in
`~/roms/vr/`. `build/vr_full.zip` is the completed set used for verification; **a MiSTer
will fail to load this MRA until that file is added to the user's `vr.zip`.**

The stream is now 25.4 MB of a 32 MB SDRAM, leaving ~6.5 MB. The polygon base is
0x840000 bytes = `24'h420000` in the `[24:1]` word addressing `m1_integrated.sv` uses for
`COPRO_DAT_BASE`/`COPRO_TBL_BASE`.

---

## `OPTIMIZATION_MODE "Aggressive Area"` buys 469 ALM and costs most of the timing margin

**2026-08-30**, full `make rbf`, Quartus 17.0, 0 errors, against the `ab4ae51c` baseline
built from the same tree:

|              | baseline   | Aggressive Area | delta |
|---|---|---|---|
| ALM          | 30,138     | **29,669**      | **-469 (-1.6%)** |
| M10K         | 372        | **383**         | **+11** |
| DSP          | 50         | 50              | 0 |
| worst setup  | +0.375 ns  | **+0.103 ns**   | **-0.272 ns** |

So it is real but small, and it is **not free**: it pushes logic into memory and spends
nearly three quarters of the slack to do it. 469 ALM is 1.6% against an M4 sound section
measured at 8,837 ALM in the Model 2 project — it does not change what fits.

**Not adopted as the default.** `M1_QOPT="Aggressive Area"` remains opt-in in
`tools/mister_project.sh`. Burning 0.272 ns of margin for 1.6% is the wrong trade while
ALM is not the binding constraint; the setting is worth taking when sound and the
rasterizer have actually made it binding, and the slack can be re-checked then.

---

## Virtua Racing draws NOTHING through the direct path — the geometry engine is mandatory

**2026-08-30**, `tools/mame_dlist_census.lua`, 120 samples over 1,200 frames of attract.

The 3D path has two drawing commands and they cost wildly different amounts to
build. Command 1/0x41 is *draw object*: an address into the polygon ROM, which the
hardware must read, transform by the current matrix, project, light and clip.
Command 2 is *direct*: quads already in screen space, sitting in the list, needing
a fill and a sort and nothing else.

    type   1 OBJECT           7880
    type   2 DIRECT              0        <- none, ever
    type   b matrix            7880
    type   3 viewport           187
    objects drawn      7880
    direct sub-quads   0
    distinct objects   224

**Zero direct quads.** The hoped-for shortcut — a rasterizer with a fill unit, a
band buffer and no geometry stage, drawing whatever the list already holds in
screen space — draws an empty screen on this game. It is not a partial win; it is
nothing. `m1_raster_fill` and `m1_raster_band` cannot show a single pixel until
transform and projection exist to feed them.

One matrix command per object, and a single viewport all run:
`248,231 0,39 495,422` — centre (248,231), the full 496x384 active area offset by
the 39-line top border the reference subtracts.

---

## The geometry budget: 5,831 polygons in a peak frame, 34 cycles per point

**2026-08-30**, `tools/mame_poly_budget.lua`, 60 sampled frames, walking each
object in the polygon ROM exactly as `push_object` does — a 6-float header then
10-float records until one has type 0 in its flags.

    peak frame         5831 polygons in 41 objects
    mean frame         3204 polygons in 34 objects
    peak points/frame  11662   (2 per polygon record)
    cycles per point   34.1    at 22.86 MHz and 57.5 Hz

Measured **before** building the stage, not after, because the answer decides its
shape. Per polygon record the reference does a 3x3 transform of two points and a
normal, a projection divide per point, and a lighting dot product: roughly 27
multiplies, 24 adds and **2 divides**, in the ~68 cycles two points are worth.

Multiplies and adds fit comfortably — one pipelined `fp_mul` and one `fp_add` at a
result per cycle cover 27 and 24 cycles and overlap each other.

**The divider is the constraint.** `fp_div` measures `max_latency=29` and is not
pipelined, so two projections per record is up to 58 of the 68 cycles on their
own. One divider *just* fits with nothing to spare and no allowance for the frame
being longer than average; the honest reading is that the geometry stage needs
either a second divider or a table-based reciprocal.

**And the reciprocal table exists in the ROM set we do not load.** MAME's
`other_data` — `opr-14744`..`14747`, the 1/x and 1/sqrt tables — was deliberately
left out because `fp_div` computes those instead (see the `wpair` comment in
`gen_mra.py`). That decision was made for the coprocessor, where it is right; for
the geometry stage the trade is the other way round, and the reversal condition is
this measurement. Recorded, not yet taken.

Data rate is not a concern either way: 5,831 records of 40 bytes is 233 KB a
frame, 13.4 MB/s, sequential — nothing for the SDRAM controller.

---

## The geometry stage fits, and the reciprocal is 94% of it

**2026-08-30.** Both stages built and measured against the 68-cycles-a-record budget:

| stage | per record | share of a peak frame |
|---|---|---|
| `m1_geo_xform`, 3 transforms | 57.1 cycles | 84% |
| `m1_geo_project`, 2 points   | 64.1 cycles | 94% |

They run on separate units so the frame cost is the larger, not the sum: **94%**.
It fits, and it fits with almost nothing spare — any stall the measurement does
not model (polygon fetch from SDRAM, backpressure from the fill stage) pushes the
peak frame over. `fp_div` is 29 cycles and does not pipeline, so 29 of those 32
cycles a point are the reciprocal alone. **A second divider halves it to ~47% and
is the obvious lever if integration needs one.** The mean frame is 3,204 records,
so this is a peak-frame concern, not a typical one.

**Both stages needed restructuring that only a THROUGHPUT test could have asked
for, and in both cases the first version of that test measured the wrong thing.**
Submitting one point and waiting for its result measures latency; it reported
`m1_geo_xform` at 34 cycles when its streamed figure is 19, and
`m1_geo_project` at 57 when its streamed figure is 32. A pipeline that exists to
overlap two points cannot be measured one point at a time. Written down because
the mistake was made twice in one evening, the second time knowing about the
first.

Streaming then found a real bug in `m1_geo_xform` that one-at-a-time never could:
`in_ready` let a new point overwrite a product bank the adder had not yet
collected, because `fill_bank` flips when the adder TAKES the products, not when
the multiplier finishes them.

**The projection's deviation from the reference is now bounded by its bench, not
just by a comment.** 19,613 fuzzed points: one differed by a single pixel
(0.005%), none by more. The bench asserts both halves — never more than one pixel
out, and a difference rate near the measured 0.002% — because a systematically
wrong reciprocal would pass a "within one pixel" check on every point while
differing on far too many of them.

---

## The painter's sort needs a quad store, and it does not fit in M10K

**2026-08-30**, from `sort_quads` and `quad_t::compare` (model1_v.cpp:535-560).

Model 1 has no Z-buffer. `draw_quads` paints in sorted order — **z descending,
ties broken by submission order** — so every quad of a viewport has to be
collected before any of it can be drawn. VR uses a single viewport for the whole
list (measured: one `viewport 248,231 0,39 495,422` across 1,200 frames), so
"every quad of a viewport" is every quad of the frame: **up to 5,831**.

That store is the problem, and it is worth stating before more of M3 is built on
the assumption it is free.

A quad needs four screen vertices, a colour and a sort key — about 184 bits packed,
so 5,831 of them is **1.07 Mbit, roughly 105 M10K blocks**. The current build
leaves 170 free (383 of 553 used), and the band buffer wants 62 of those single-
buffered. 105 + 62 = 167 of 170, with the binning structures and everything else
in M3 still to come. It does not fit.

**So the quad store belongs in SDRAM, not M10K.** 5,831 quads is 134 KB a frame to
write; with a 64-row band buffer the picture is six bands, and a quad is read once
per band it touches — call it 1.5 on average, so ~335 KB a frame, **19 MB/s**.
That is nothing for the controller, and the polygon ROM traffic measured earlier
(233 KB a frame, 13 MB/s) sits alongside it comfortably. SDRAM has ~6.5 MB spare
after the 25.4 MB ROM image.

The sort itself is affordable: 5,831 elements is ~76,000 comparisons at log2 n,
against 397,515 cycles in a frame. It is the STORAGE that forced the decision, not
the comparisons.

The comparator is exact and must stay exact — descending z with ties resolved by
submission order. `qsort` is not stable, so MAME makes the order total by falling
back on the address; an approximate bucket sort by z would reorder coincident
quads and is not a shortcut available here.

---

## One multiplier and one adder serve the whole geometry stage — measured, 446 ALM a copy

**2026-08-30.** The stages were first built with private arithmetic: a multiplier
and an adder each in `m1_geo_xform` and `m1_geo_det`, both plus a divider in
`m1_geo_project`. Three of each. Counting what a polygon record needs:

    transform    3 points     27 mul   24 add
    determinant               9 mul   11 add
    projection   2 points      8 mul    8 add   2 div
                             ---------------------------
                              44 mul   43 add   2 div

against 68 cycles a record. `fp_mul` and `fp_add` retire one result per cycle, so
**one of each runs at 65% and 63%.** Three of each was convenience, not necessity.

Measured on the same module, Quartus 17.0, before and after moving its units to a
shared pool:

    m1_geo_xform   private mul+add   1,444 ALM
    m1_geo_xform   pooled              998 ALM      -446
    m1_fp_pool     mul + add + div + arbitration  1,264 ALM

So a private multiplier-and-adder pair is ~446 ALM, and the whole pool — including
the divider that could never be shared away because there was only ever one — costs
less than three of those pairs. Round robin rather than fixed priority: at 65%
utilisation priority is *almost* always fine, and "almost always" is how a stage
starved on the busiest frames gets shipped.

The refactor is behaviour-preserving: all three benches report identical numbers
and identical throughput afterwards.

**The one thing sharing forces on every client**: an issue must advance only on a
GRANT. With a private unit each issue was accepted, so a schedule counter could
run free; shared, a cycle lost to arbitration silently drops an operand and leaves
a result short forever.

---

## Virtua Racing needs the whole lighting path, and it does not fit one divider

**2026-08-30**, `tools/mame_light_census.lua`, 100 samples over 1,200 frames.

Measured before building the colour unit, on the theory that the cheapest unit is
the one that is not built. Nothing could be dropped:

    command 7   spec_enable=1 on 294 of 294 mode words   specular is ALWAYS on
    command 6   banks with s=255 p=7, and banks with s=0 p=0
    command 4   mode 0 155,876   mode 1 (blinking) 5,832
                mode 2   6,336   mode 3 (unlit)  40,852

So the specular term, the alternate-frame channel rotation and the unlit flag are
all live for this game. 22% of colour words set the unlit bit and 2.8% blink.

**And that creates a budget problem.** `glm::normalize` on the polygon normal is a
reciprocal square root, once per record, on top of the two reciprocals projection
already needs. Three expensive operations a record, and `fp_div` is 29 cycles
unpipelined: **87 cycles against a budget of 68.** The geometry stage as MAME
writes it does not fit behind one divider.

Three ways out, in the order they should be considered:

1. **The precision requirement is low and worth measuring.** The normalize feeds
   `dif`, which feeds `lumval = 255*min(1,ln)` and is then shifted right by two —
   a **6-bit** output. A relative error of ~1.6% is invisible in it. Specular
   squares its argument up to three times, so that path needs ~8x better, but even
   then a ten-bit reciprocal square root suffices. This wants the same treatment
   the projection reciprocal got: measure the pixel-level difference, then decide.
2. **A second `fp_div`**, which brings 87 cycles to ~44. Exact, and the pool
   already has the arbitration for it.
3. **The hardware's own tables.** `other_data` — `opr-14744`/`14745` are a 1/x
   table and `opr-14746`/`14747` a 1/sqrt(x) table, 256 KB each, 64K entries of 32
   bits. They are in the ROM set and **deliberately absent from our MRA** because
   `fp_div` computes what the coprocessor needed. This is the second time that
   decision has come up against a stage that would rather have the table; the
   reversal condition is a measurement showing the table's precision is enough.

Not yet decided. Recorded so the decision is made on the measurement rather than
on whichever is easiest to write.

---

## The normalize needs 16 bits, not a divider — and the budget is per QUAD, not per record

**2026-08-30.** Two measurements that between them removed the geometry stage's
budget problem entirely.

**How accurate does the reciprocal square root have to be?** It feeds a dot
product, a specular term, and then `lumval = (255*min(1,ln)) >> 2` — **six bits**.
Over 400,000 random normals against the light parameter banks measured from the
real display list, truncating the rsqrt mantissa changes that six-bit luminance:

    10 bits   0.776% of polygons, by up to 2 levels
    12 bits   0.190%, by at most 1
    16 bits   0.013%, by at most 1
    23 bits   never

Specular squares its argument up to three times and so amplifies error eightfold;
it is that path, not the diffuse one, that sets the requirement. An 8-bit seed
table plus **one** Newton-Raphson step reaches ~16 bits, and `m1_geo_rsqrt`
measures a worst relative error of **5.7e-06** across the full exponent range —
in 23 cycles using four operations on the shared pool, against 29 blocking cycles
for a divide that does not exist anyway. **No second `fp_div`, and no reason to
load the 1/sqrt ROM tables.**

**And the per-record budget was the wrong budget for half the stage.**
`tools/mame_poly_budget.lua`, extended: of 5,831 records in a peak frame, only
**4,798 can emit a quad at all** — `push_object` jumps straight to `next` when the
record's link field is zero — and the backface test discards more of those still
(14.9% of them skip the test entirely via flag 0x4000). So the colour, clipping,
sort and fill stages run at most 4,798 times, which is **83 cycles each**, not 68.
`m1_geo_color` measures 77. Held to the transform's 68 it would have been
"25% over" and optimised against a budget it does not have.

---

## Five bugs in the colour unit, every one of which would have looked like a working picture

**2026-08-30.** `m1_geo_color` reproduces push_object's colour block. Its bench
found five faults before it passed, and the reason to write them down is that not
one of them would have produced an obviously broken screen:

1. **The light parameters were never divided by 255.** MAME stores them as
   `float(v)/255.0f` on upload; taking the raw byte makes `ln` ~255x too large, so
   every luminance saturates at 0x3f and the whole scene renders at full
   brightness. Fixed by dividing once at upload — where MAME does it — rather than
   per polygon, which would have put a divide inside the per-quad budget.
2. **`lumval >>= 2` came after the clamp instead of before.** Clamping the
   unshifted 0..255 value to 0x3f turns everything above 63 into full brightness,
   which is most of the range. Same symptom as (1), different cause.
3. **The palette base was 0x400, not 0x1000.** `pal_addr` is 13 bits so 0x1000 is
   the top bit: `{3'b100, ...}`, not `{3'b001, ...}`. The wrong bank is still full
   of colours.
4. **The colour-translation index was 13 bits in a 15-bit field.** MAME indexes
   `(c << 8) | lumval | bank`, so **bits 7:6 are zero** — packing `{bank, c, lum}`
   without that gap reads a completely different entry of a table that is
   plausible everywhere.
5. **The three lookups assumed combinational memory.** Reading `xlat_data` in the
   cycle the address is driven returns the previous lookup's word, so every
   channel got its neighbour's translation.

Each is a one-line fix and each produces a picture. That is the argument for
comparing against a transcribed reference rather than looking at output.

---

## The geometry stage draws Virtua Racing — a real frame, from real RTL

**2026-08-30.** `make render` puts one frame of the reference's own state through
`m1_geometry` and `m1_raster_fill` and writes an image.

Everything the stage reads is the reference's: `tools/mame_dump_frame.lua` writes
out the display list, the palette, the colour-translation table, the colour words
and the light banks at a chosen frame, and the models come from the polygon ROM in
the packed image. So a difference in the picture is the RTL's and not the input's.

    display list: 33 objects, 1 viewport
    viewport xc=248 yc=191  x 0..495  y 0..383  zoom 210,280  view 0,-30
    records 3604, culled 884, link-0 686, quads emitted 2001
    filled 2001 quads (168 were wireframes), 414,570 pixels painted

The picture is the attract-mode chase camera: a car, the red-and-white kerb, the
track surface, a second car up the road, and the SEGA logo. 99.8% of the frame is
painted.

**And it found a bug no unit test could have.** The first render came out entirely
black with the geometry perfect — every quad in the right place, every one the
same shade. `tex_data` read `0xffff` for every record, because
`m1_geo_walk` indexed `tgp_ram` with the RAW texture address where MAME indexes
`m_tgp_ram[tex_adr - 0x40000]`. Off by 0x40000 words, the read lands outside the
written region and returns 0xffff, which is a **valid-looking colour word with the
unlit bit set** - so nothing errored and nothing looked broken except the colour.

The per-stage benches cannot see this: they supply `tex_data` directly and never
exercise the address arithmetic. The integration bench cannot either, because it
uses the same synthetic memory for both sides. It took a real dump, where the
address means something, to expose it. **That is the argument for rendering a real
frame as a test and not only as a demonstration.**

Two pieces of the chain are still C++ rather than RTL, and both are named in the
bench: the display-list interpretation (`m1_listwalk` is verified separately and
decodes the same grammar) and the painter's sort (the quad store is an SDRAM
decision that is not built yet). Everything between an object address and a span
is RTL.

Still missing from the picture: the frustum clipper, so geometry crossing the
screen edge relies on the fill unit's 2D clamp; the band buffer, so this renders
to a full framebuffer rather than in 64-row bands; and the 2D tilemaps, so there
is no sky, no horizon and no HUD behind or over it.

---

## The sound section needs ~57 M10K, measured — and it decided the band height

**2026-08-30.** From Model 2's own fit report, `output_files/Model2.fit.rpt`:

    m2_sound_board    8,837 ALM    572,427 block memory bits   ~57 M10K

Read from the **Block Memory Bits** column, which is column 11 of the hierarchy
table. Column 14 is *Virtual Pins*, and reading that instead reports every block
as using zero memory - which is exactly the answer one wants to hear and is wrong.
Checked the header before quoting it.

This settled the 3D layer's band height. At 64 rows a band buffer is 53 M10K and
the pair 106, so the 3D layer took 145 of the 181 free and left **36** - twenty
short of what sound needs, and it would not have been discovered until the
rasterizer had been built around it. At 32 rows the pair is 54, the 3D layer is
93, and **88** remain.

The cost is twelve bands instead of six, and the quad store's band filter makes
that nearly free: a quad is replayed only for the bands its rows touch, so halving
the band height moves a typical quad from one or two bands to two or three, not
from six to twelve.

**The caveat is that Model 2's sound is an SCSP and Model 1's is a YM3438 with TWO
MultiPCMs.** 57 blocks is the closest measured analogue, not a guarantee, and the
~31 spare is thinner than it looks.

---

## clk_cpu to 23.529 MHz — and the CPI gap it does not close

**2026-08-30.** `clk_cpu` was 22.857 MHz, chosen when 23 was rejected as "not a
legal PLL output". The reason is now written down: with 80 MHz fixed on outclk0
the VCO is **800 MHz**, and every output is an integer division of it. 800/23 is
not an integer; **800/34 = 23.529** is the smallest step at or above 23.

    800/10 = 80.000    clk_sys, and the SDRAM pin at 180 degrees
    800/17 = 47.059    clk_3d
    800/34 = 23.529    clk_cpu, an exact half of clk_3d

Both halving relationships are exact, which is what keeps the 3D-to-CPU crossing a
clock enable rather than a handshake — the same arrangement Model 2 uses, where
`clk_i960` is an exact half of `clk_sys`.

Everything derived from the clock moved with it: the I/O board's deadline is a
**measured wall-clock time** (the reference answers the boot handshake in 38,577
us) and is now 907,694 cycles rather than 881,760, in the RTL, its bench and its
comment; `tb_m1_frame`'s clock period likewise.

**IT BUYS 2.9%, AND THE GAP IS 3.2x.** The measurement that matters here is
already in this file and it is worth restating next to the clock change, because
raising the clock is the intuitive fix and it is the wrong one:

    V60 core in isolation     6 CPI     the reference implies ~8 - ours is FASTER
    whole system          30.49 CPI     65% of cycles are bus stalls

The core is not the slow part. Two thirds of every cycle is spent waiting on
memory, and that is where a 3.2x lives. Clocking from 22.857 to 23.529 is 2.9% of
it. The clock change is still right — the CPU should not be below the target rate
— but it should not be mistaken for progress on throughput.

---

## The 3D block renders the reference frame: 100.0% agreement, four bugs on the way

**2026-08-31.** `make render3d` drives `m1_raster3d` alone - a frame pulse and
five memories in, a pixel out - and captures each band through the scanout port
the video path will use. Nothing orchestrated from C++: the list walk, the
per-object geometry, the sort, the band sequencing and the presentation are the
module's own.

    RTL block vs the C++-orchestrated render
      agree within RGB565 rounding   190,462 of 190,464   100.0%
      differ by more than 8                            2

**Four bugs stood between "it produces a picture" and that number, and every one
of them produced a picture.**

1. **The band geometry was three constants that disagreed.** Halving the band
   height to 32 for the sound budget left a 6-bit band mask, a 3-bit band select
   and a row-to-band index written as `y[8:6]` - a division by 64 that does not
   say so. A 3-bit counter compared against `3'(12-1)` truncates to 3, so the
   frame stopped dead after band 3, correct as far as it went.
2. **The viewport handler was an empty stub**, left that way because command 3
   emits `idx 0` for its 32-bit word AND for the first of its six 16-bit words.
   `xc`/`yc` stayed at zero and stretched the whole frame. Fixed at the source:
   the viewport's seven values now number 0..6.
3. **The zoom was missing its x4.** MAME's command 9 is
   `set_zoom(readf(+2) * 4, ...)`. Taking the word as written under-zooms the
   scene by exactly four - which looks like a stretched picture with objects
   wandering off the edges, and the quad count is identical either way. The
   multiply is free: add two to the exponent.
4. **The light vector was not normalized.** `set_light_direction` is
   `glm::normalize`, and the display list's vector is **1.0941** long - so every
   dot product came out 9.4% large and every polygon one luminance level too
   bright. A picture that looks right and is uniformly washed out.

Number 4 is the one worth remembering. It showed up as a *colour* difference
confined to one surface in the diff image, with the road and the HUD agreeing
exactly - and the quad count, the coverage and the geometry were all already
perfect. Diffing the render against a reference is what found it; no unit test
could, because the light vector is an input to the colour unit and both sides of
its bench used the same one.

The normalize is **borrowed rather than duplicated**: `m1_geometry` lends its
`m1_geo_norm` out while the stage is idle, which is exactly when the caller is
between objects. A second one would have cost ~450 ALM of multiplier and adder to
normalize one vector per frame.

---

## The 3D layer fits, and one unsynchronised register was 1,327 ns of negative slack

**2026-08-31.** The first build that fitted:

    ALM    36,582 / 41,910   87%
    M10K      518 / 553      94%
    DSP        53 / 112      47%
    worst setup slack  -5.934 ns, TNS -1,327 ns

**Five builds failed before it, each on a distinct defect that 53 passing test
suites and a pixel-exact frame render could not see:**

1. Quartus rejects a bit-select of a part-select. `att[q][AT_W-1:25][replay_band]`
   is legal to Verilator; 17.0 answers "range must be the final index in the
   indexed name". A synthesis error, not a simulation one.
2. **A four-ported array.** `vtx[NQ*4]` was written four vertices at a time and
   read four at a time. No RAM has four ports, so Quartus built all 8,192 x 32
   bits from flip-flops **and said nothing**: 166,497 combinational nodes against
   a device holding 83,820.
3. **Asynchronous reads.** `wire x = mem[addr];` is a read no block RAM can do, so
   `key`, `idx_a`/`idx_b` and `att` all stayed in flip-flops - 63,630 registers in
   one module. Registered reads cost a cycle each and changed the sort's schedule
   from three cycles an element to five.
4. **A histogram too wide.** Read-modify-written at a dynamic address, so it can
   only be registers plus a mux per entry. At 8 bits that missed fitting by 15
   LABs of 4,191 - 0.36%. At 4 bits the arrays are a sixteenth the size, at the
   cost of eight passes instead of four (21% of a frame to 41%).
5. **A reset loop still clearing 256 buckets** after the arrays became 16.
   Verilator clamps silently; Quartus refuses to elaborate.

**Ben's benchmark is what turned (2) and (3) from "3D is expensive" into "this
number is wrong".** VDP1 and the N64's RDP are 4,000-8,000 ALM, and the RDP is far
more capable. `m1_geometry` - transform, projection, cull, normalize, lighting -
measured 6,238 nodes and 5,778 registers, squarely in that range. It was the
STORE that was anomalous, and storage should cost almost no logic at all.

**Then the timing, which was one register.** Every one of the 40 worst paths began
at `m1_raster3d|wr_buf`:

    wr_buf -> ... -> m1_tdp_ram:u_pram|...|portb_address_reg   -5.934

`wr_buf` selects which band buffer the scanout reads. Unsynchronised, it fed
combinationally from a clk_3d register through `scan_hit` into the mixer's
`poly_won`, out to `pal_addr`, and onto the palette RAM's address register in the
clk_sys domain. `disp_band` and `disp_valid` were synchronised and this was not -
and it is the one that carries the data.

It changes in the same cycle as `disp_band`, so all three now cross together and
the buffer selected always matches the band advertised.

**M10K at 94% is the next problem.** 35 blocks free against the ~57 the sound
section measures on Model 2. The band-height change bought 52 and something has
since eaten them - `cxlat` rounding up to 32,768 words and the four vertex
memories are the candidates. It needs revisiting before M4.

---

## THE FRAME BUDGET WAS HALF THE REAL ONE — 397,515 against 818,133 — 2026-08-31

Every per-stage budget in this project was checked against **397,515 cycles a
frame**, in six benches and two RTL headers. That figure is a 22.9 MHz plan for
the 3D clock: 397,515 x 57.52 = 22.87 MHz.

`clk_3d` is **47.059 MHz** — its own PLL output, 800/17 — so a frame is
**818,133 cycles**. Every budget derived from the old number was half the real
one, and `tb_m1_geo_det`, `tb_m1_geo_xform` and `tb_m1_geo_project` all carry an
explicit `FAIL OVER BUDGET` test against it.

Corrected in all eight places. Nothing had failed against the wrong figure, so
the error only ever made the stages look tighter than they are — but a budget
test that is wrong by 2x is worse than none, because it drives design decisions.

---

## THE BENCH WAS TICKING BOTH CLOCKS TOGETHER, and understated the fill 3x — 2026-08-31

`tb_m1_raster3d` drove `clk` and `scan_clk` from one `tick()`. The 3D clock is
47.059 MHz and the pixel clock is 656 x 424 x 57.52 = **15.996 MHz**, so the fill
gets **2.94 cycles per pixel of raster** and the bench was handing it one.

Every throughput figure that bench printed understated the hardware by a factor
of three, including the "band fill 44,868-66,819 against a band-time of 61,741"
that drove the band-height decision. It carries the ratio as a fraction now.

It also cleared the framebuffer **once** and reported the union of eleven frames
as coverage — 93.9% for a renderer delivering a third of its bands per frame.
Per-frame now, which is what a screen shows.

**Both faults flattered the design.** A bench that is wrong in the safe direction
is still wrong, and this one hid the fact that the geometry, not the fill, was
the pole.

---

## WHERE THE GEOMETRY'S 444 CYCLES A QUAD WENT — and it was not the arithmetic — 2026-08-31

`m1_geo_walk`'s state sampled every cycle and bucketed (`tb_m1_geometry`, 20
objects, 340 quads):

    transform    32.7%      three points, one at a time
    project      38.4%      two points, one at a time
    normalize    11.7%
    colour       10.8%
    polygon ROM   3.4% at a one-cycle memory, 40% at a twelve-cycle one
    determinant   1.9%

against 44 multiplies and 43 adds a record through pipelines that retire one a
cycle — **a floor of about 68 cycles**. The stages were not slow. The walker was
issuing them one at a time and waiting for each.

`m1_geo_xform` carries a ping-pong product bank so the adds of point N-1 run
while the multiplies of point N are issued; `m1_geo_project` keeps the reciprocal
and the scale chain as separate stages for the same reason. **Both were built
that way deliberately and the walker used neither.**

The record path is a dataflow schedule now — each stage issued the moment its
operands exist — and the polygon ROM is prefetched a record ahead. **444 -> 226
cycles a quad**, and a twelve-cycle memory costs 1.0x rather than 1.4x. Exact
throughout: 3,357 quads, 0 vertices a pixel out, 0 colours different.

**A SPECULATIVE ISSUE HAS TO BE DRAINED.** Issuing the normalize before the cull
is known takes 40 cycles off the critical path — and leaving a culled record with
that normalize still in flight let its result land in the NEXT record. Measured:
**345 of 3,357 colours wrong, 10.3%, with every vertex exact.** A colour is
all-or-nothing (a luminance level selects a different translation entry), so this
looked like a lighting bug and was a scheduling one.

And **collect only what was issued**. `!collected` alone accepts any pulse the
stage happens to make, including one left over from the previous record: a link-0
record that asks for nothing ended up with a colour it could never match, and the
walk deadlocked at record 19 of iteration 19 with `cl 0/1`.

---

## THE DIVIDER IS THE FILL — radix-4, and the measurement it asked for — 2026-08-31

`m1_raster_div` was radix-2, 32 cycles, with a note that setup runs at most four
times per quad and never per pixel, and that the lever if it ever hurt was
"radix-4 or a reciprocal table, and that is a measurement to take rather than a
guess to build."

Taken. `tb_m1_raster3d` against a real raster: **FILLW 436,000 cycles a frame of
818,133**, and the quad count gives 275 cycles of fill per quad against at most
eight divides of 32.

Radix-4 is 16 cycles and the quotient is exact integer division either way, so
`tb_m1_raster_fill` is unchanged at 152,025 checks and 0 fails. **FILLW 436,000
-> 373,000.**

**Its `spans`, `lines` and `empty` totals MOVED, and that is not a regression.**
The bench's stall model draws from the same mt19937 as the quad generator, once
per cycle, so anything that changes how many cycles a quad takes reshuffles the
whole corpus: 31,637,915 spans became 31,658,020. `checks` and `fails` are the
invariants; the totals are not. This will happen again.

---

## THE SORT SPENT FIVE CYCLES AN ELEMENT WAITING FOR TWO BLOCK RAMS — 2026-08-31

`m1_quad_store`'s radix sort walked `key` and `idx` through five sequential
states per element, because both reads are registered and an asynchronous read
of `key` had cost 65,536 registers. That is 5 x 2 loops x 8 passes = **80 cycles
a quad**, and **812,776 cycles of the render bench, 7.1% of everything**, to sort
at most 2,048 items.

Pipelined to one element a cycle — the same shape the **replay path forty lines
below it in the same file** already had — it is **172,584**. 2,000 quads sort in
34,330 cycles.

The index that belongs with a digit has to be carried alongside: `cur_idx` has
already moved on two elements by the time its key comes back.

---

## BAND 0 WENT UP HALFWAY DOWN THE SCREEN — 2026-08-31

The pass is geometry, then sort, then 24 beam-locked band fills. The geometry is
367,000 cycles and the sort 21,000, so **band 0 was ready with the beam at band
11** — and `in_disp_band` then correctly refuses to draw rows 0..191 during rows
192..383. Sixteen of twenty-four bands presented, 257 of 384 rows painted, and
every band was on time by its own rule.

Band 0 now waits for a vblank the **band phase** sees: the one it is in if the
geometry finished inside it, otherwise the next.

**Clearing the arm on `frame_start` alone did nothing at all.** The blank flag
comes through two synchroniser stages, so it rises three cycles AFTER
`frame_start` and re-armed immediately — the run printed byte-identical numbers
twice, which is the only reason it was caught rather than believed.

Result: **95.9% of pixels, 369 of 384 rows, 23 of 24 bands**, every second frame.

---

## THE 3D LAYER IS 28.8 Hz, and the reason is the quad store — 2026-08-31

Work per pass, measured by state (`tb_m1_raster3d`, the reference's frame 900):

    geometry (OBJW)   367,000
    fill     (FILLW)  373,000
    sort     (SORTW)   21,000
    clear    (CLRW)    34,000
                      -------
                      796,000   against 818,133 in a frame

It fits — and it still takes two frames, because **the geometry cannot overlap
the fill**. Both use the quad store: the geometry writes it, the sort orders it,
and every one of the 24 band fills replays it. So a pass is
`geometry + one whole beam traversal`, about 1.2 M cycles.

The fill itself is idle for 445,000 of the 818,133 it is stretched across, so the
geometry would fit inside it exactly — with a **double-buffered quad store**.
That is `vtx0..3` (26 M10K), `key` (8), `att` (10) and `idx_a`/`idx_b` (5) again:
**+49 M10K**, against 100 free and ~57 wanted by the sound section.

So 28.8 Hz for the 3D over 57.5 Hz for the 2D is the shape of this design until
either the quad store shrinks or the geometry reaches ~77,000 cycles, which is
what fits in vblank. **Not a throughput problem any more.**

---

## 28.8 Hz IS THE BOARD'S OWN GEOMETRY RATE — measured, not a shortfall — 2026-08-31

Our 3D layer completes a render pass every second frame, and the entry above
calls that a consequence of the quad store. It is also **exactly what the
reference does**, which changes what it means.

`tools/mame_listctl_rate.lua`, 2,000 frames of `vr`:

    bit 2 (automatic double buffer) set on 4 frames
    buffer flipped 996 times
    frames between flips:  2 frames: 993 times
                           1 frame: 1,  3 frames: 1,  10 frames: 1
    register values:  00b2 on 1,001 frames,  00fa on 995
    => new geometry at 28.64 Hz of a 57.52 Hz refresh

**Virtua Racing presents a new display list every two frames.** 993 of 996 flips
are exactly two frames apart; the three exceptions are at the boot/attract
transition.

And it does it **by hand**, not through the hardware's automatic mode:
`model1_v.cpp:1351` toggles bit 6 on odd frames only when bit 2 is set, and bit 2
is set on 4 frames of 2,000. The game alternates `00b2` and `00fa` — bit 3, which
bit 6 mirrors on the `!(listctl[0] & 4)` path. `m1_listctl` already implements
both paths; the measurement says which one is used.

**So the 3D layer running at 28.8 Hz over a 57.5 Hz 2D layer is the hardware, not
a compromise.** A 3D layer that updated every frame would be rendering the same
display list twice. The band architecture's cadence and the game's happen to
agree, which is luck rather than design - but the number to hold it to is 28.64,
and it meets it.

---

## MAME CANNOT RUN `vr` IN THIS TREE WITHOUT A DEVICE-ROM OVERLAY — 2026-08-31

Every instrument in this project, and `make v60_trace` and `make tgp_trace` with
them, dies before the machine starts:

    epr-14869.25 NOT FOUND (tried in model1io vr)
    epr-15112.17 NOT FOUND (tried in m1comm vr)
    Fatal error: Required files are missing, the machine cannot be run.

These are **device** ROM sets, not part of `vr.zip`: the I/O board's own 68000
firmware and the comm board's. MAME 0.289 treats both as required and will not
start, and `-video none` means there is no warning screen to dismiss - the
documented "press a key once and autoboot proceeds" does not apply to a fatal
error.

Both are on this machine, in other sets:

    epr-14869.25   ~/roms/Model2/daytona93/
    epr-15624.17   ~/roms/vr/vformula/     (the OTHER m1comm bios)

`epr-15112.17` is on no disk here — not in `vr.zip`, not in `vr.7z`, not in the
decapped set. The overlay in `build/roms/` supplies `epr-15624.17` under that
name, which MAME accepts with a `WRONG CHECKSUMS` warning and runs. The comm
board is not linked in a standalone run and the V60 only touches it at
`0xb00000`-`0xb01002`, so the substitution is visible in the log and not in the
measurement — **but say so whenever a result comes from a run made this way.**

    mame vr -rompath "$HOME/roms;<project>/build/roms" \
            -skip_gameinfo -autoboot_delay 0 -video none -sound none -nothrottle \
            -autoboot_script <script>.lua

`build/roms/` is gitignored like everything else under `build/`, so hard rule 2
holds. `tools/mame_run.sh` wraps this so it is not re-derived a third time.

---

## THE 3D REWORK COSTS 369 ALM — the whole day's work, measured — 2026-08-31

`make rbf`, Quartus 17.0, 0 errors, and no negative TNS on any clock:

    36,979 ALM of 41,910   88%      4,931 free   (+369 on 36,610)
       504 M10K of 553     91%         49 free
        53 DSP  of 112     47%
    worst setup slack   +0.318 ns

    s32_v60:cpu        17,264 ALM   47% of the whole design
    m1_raster3d         6,977 ALM   922,912 bits
    m1_tgp              2,434 ALM
    m1_video              789 ALM
    m1_diag (overlay)     176 ALM

**+369 ALM for all of it** — three band buffers instead of two, a radix-4
divider, a sort pipelined to one element a cycle, and a geometry walker
restructured from a chain into a dataflow schedule with a ROM prefetch. The
throughput came from scheduling, and scheduling is cheap.

**M10K at 91% with 49 free is now the number to watch.** The sound section needs
84 as measured and about 20 once the 68000's work RAM moves to SDRAM, so it fits
- and a double-buffered quad store, the thing that would take the 3D layer to
57 Hz, wants 49 more and does not.

---

## THE SDRAM TAIL IS NOT ARBITRATION — a bounded CPU boost bought 0.01 cycles — 2026-08-31

The V60's data bus, measured on the current design with every master live
(`tb_m1_frame`, 400 M cycles):

    10,634,698 data accesses, mean 12.05 samples of the 80 MHz clock
    histogram   2:58%   8:9%   28:1%   31:7%   32:10%   35:4%   38:2%
    CPU         data stall 32.83%   fetch stall 0.61%   17.49 CPI

**The 9-cycle fixed handshake is gone.** `docs/findings.md`'s 2026-08-20 entry
had every page costing the same 36 fast cycles whether BRAM or SDRAM, which was
handshake overhead. That predates the V60 moving to its own clock domain, and it
no longer holds: **58% of accesses complete in two samples** — under a CPU cycle,
free.

**And fetch stall is 0.61%.** The instruction cache is doing its entire job.
There is nothing left to win on the fetch side.

What remains is bimodal: a quarter of accesses take 28-39 samples, about 9.2 CPU
cycles, and that is 33% of every cycle the CPU spends.

**The obvious explanation was queueing** — p0 waits behind six other masters and
the 3D layer added two of them the same day. So p0 was given a bounded
pre-emption: it may jump the rotation but not if it won the previous grant, which
caps its share at half and cannot starve the character fetch's hard deadline.

    before   mean 12.05, data stall 32.83%, 17.49 CPI
    after    mean 12.04, data stall 32.82%, 17.49 CPI

**Nothing. One hundredth of a cycle.** The tail is the SDRAM round trip itself -
the CDC out, the service, the CDC back - not the wait for a grant. Reverted
rather than kept: unproven logic on a design at 90% of its ALM is a cost with no
benefit.

**So the lever is not to serve the access sooner but to not make it.** A data
cache for the V60's work RAM turns that quarter into two-cycle hits, and 4-8 KB
of it needs about 5 M10K on a device with none free — which is what makes
right-sizing the display-list buffers (32,768 words each where the game's list
ends at word 0x2006, +64 blocks) a prerequisite rather than housekeeping.

---

## THE REFERENCE V60 RETIRES 2,015,165 INSTRUCTIONS A SECOND — measured — 2026-08-31

Assumed at "about 8 CPI at 16 MHz, so 2 M/s" for the whole speed budget and
never measured. Measured now, because the budget rests on it: a full MAME
instruction trace of `vr`, one emulated second, `noloop`, counting retired
instructions.

    2,015,165 instructions in 1 emulated second

The assumption was right to within 1%. Ours, from the same bench that gives the
CPI: 7,233,673 retires in 126,571,439 cycles at 23.529 MHz = 5.379 s, so
**1,345,000 a second — 67% of the reference, a gap of 1.50x.**

**THAT DOES NOT MATCH WHAT THE BOARD LOOKS LIKE.** Ben times the MiSTer against
real running time and reads about a third. Instruction throughput cannot explain
a factor of three, so something beyond it is costing us and counting
instructions will not find it. The end-to-end metric is the display-list swap
rate - one swap per completed game-logic frame - and the reference's is measured
at exactly 2 video frames (`tools/mame_listctl_rate.lua`, 993 of 996). Ours
against that number is the game-speed ratio with no modelling in it at all.

## 2026-10-28: the frame buffer's extra frame, accepted

Decision recorded from Ben after the board test of the DDR3 frame buffer build
(3d-overrun, seed 17, md5 903cf718): about 9.7% of lists in the full-system race
(26 of 101 render3d MAME frames) reach the screen one frame later than the band
display showed them, because a frame must be fully drawn by line 416. Ben
noticed nothing and accepts it for now, unless another game shows it. If one
does, the fix is a faster fill (about 2.5x, a fill-unit redesign), not the racing
publish, which would show unfinished frames. See HANDOFF.md.
