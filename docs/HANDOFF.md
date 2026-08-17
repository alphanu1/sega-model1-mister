# Handoff — 2026-08-16

State of the Sega Model 1 core at the end of the M1 memory/CPU/video work.
Everything below is committed and pushed; the tree is clean and the full suite
is green.

`README.md` was brought back into agreement with this document on 2026-08-15 — it
still described M0 as the current milestone. If the two ever disagree again, this
file is where the measurements are.

## On hardware, as of 2026-08-16

**The core loads and runs on a real DE10-Nano.** `.rbf` built, MRA loads, the
ROM streams in complete and the video path drives HDMI. Four separate faults
were found and fixed getting there, every one of them invisible to simulation
until simulation was changed to model what hardware does:

| Fault | Symptom on the board |
|---|---|
| `ioctl_wait` ungated, holding `HPS_BUS[37]` | core never appears to load at all |
| memory subsystem inside the game reset | "Assembling ROM" frozen partway |
| core clocks in no clock group (−87 ns slack) | clean build, nothing runs |
| one port meaning both "SDRAM ready" and "ROM loaded" | "Assembling ROM" frozen at zero bytes |

Plus one that reported success and corrupted data: the loader **silently
dropped** every word the HPS sent more than 15 cycles after `ioctl_wait` rose.
Its test swept host latency 0..6 — exactly the margin the parameter was set to,
so it confirmed the setting rather than testing it. Buffer now 512/256, sweep to
64, and `overflow` is brought out to the debug overlay.

**`docs/mister-integration.md` is the full write-up**, framework-generic rather
than Model 1 specific, for reuse on any future MiSTer core.
**`docs/debug-overlay.md`** documents the on-screen instrument: what every row
means, and its measured cost of 307 ALM / 553 registers / zero M10K.

### The fifth fault: every SDRAM burst came back one word late

The V60 read `FE104E` as its reset vector where the ROM holds `4EF3D6`. Both are
the same burst `FFFF00FE104EF3D6`, simulation taking bits `[23:0]` and the board
`[39:16]`: the controller was calling the burst's word 1 its word 0, on every
read. The CPU therefore got a corrupt jump operand, computed a target of ~0,
landed in on-chip work RAM full of zeros, executed opcode `0x00` and halted —
generating no further SDRAM fetches, which is why the fetch count froze at six.

**It survived a session of looking straight at it.** The first fetch is at word
0, where the ROM is `000d 000d 000d 000d` — every word identical, the one
address in the image where a one-word shift cannot show. That fetch was checked
against the ROM, matched, and reads were declared correct; the wrong conclusion
then cost three long detours into the clock-domain crossings, the PLL dividers
and the clock ratio, all of which were fine. **Verify against data that can
distinguish the fault.**

`RD_LAT = CL + 3` is derived term by term in `m1_sdram` and derived entirely
against `sdram_model`, which samples commands and presents data on the same edge
the controller uses. The board does not: `SDRAM_CLK` is the inverse of
`clk_sys`, so the device answers half a period away, and the model's own header
says that forwarded-clock phase is "deliberately not modelled here". Every term
is right and the total is a simulation figure.

The capture depth is now selectable at run time, CL+2 through CL+5, from the
OSD; simulation ties it to CL+3 so no harness was rebaselined. **Hardware wants
CL+2**, and with it the core boots: Virtua Racing's TEST MODE menu renders from
real ROM, the V60 runs at `fe1435`, the I/O board has answered 1,398 times, and
every value the overlay reports matches simulation exactly.

## The wobble — resolved

The picture was unstable on hardware, flashing white and jumping vertically. It
was the scaler, not the core: `vsync_adjust` fixed it and the picture has been
steady since. The diagnosis cost a day and two of the three theories died on
contact with a measurement.

**The reading that wasted the most time**: 6,849 fetch deadline misses over 103
frames, read as a rate — "one line in six" — when the counter is cumulative and
every miss happened before frame 31. Seventy-two consecutive frames were clean.
A cumulative counter is not a rate, and this file said so afterwards and the
mistake was still repeated later in the same week.

The engine work done chasing it was worth keeping anyway — cost per dense layer
went 1,614 -> 1,182 cycles, text layers ~700 -> 267 — and the current build
reports **zero** deadline misses on real content.

## The open M1 defect: most of the 2D does not draw — 2026-08-16

**This is where to start.** MAME's attract frame shows a ranking table,
`INSERT COIN(S)`, `CREDIT 0` and the SEGA logo over the road. Ours shows the sky
and sea and nothing else, and neither scrolls.

### Ruled out, by measurement

Do not re-derive these.

| Suspect | Evidence it is not the cause |
|---|---|
| fetch bandwidth | overlay row `0C` reads **zero** deadline misses; an overrun repeats a scanline anyway, which is not the symptom |
| the ROM | 26 of 29 parts match MAME 0.289, **no CRC mismatches**, all twelve the MRA loads among them |
| the row mask alone | implemented, verified, on the board — **changed nothing on screen** |

### The row mask: a real gap that was not the whole bug

segas24 masks each tilemap in 8-pixel columns from a table at tile RAM `0x6000`
(tilemaps 0/1) or `0x6800` (2/3), four words per scanline. MAME draws every
tilemap twice, once per tile category, and inverts the mask for the second pass
— so a column shows whichever category matches its mask bit. Ignoring the table
is equivalent to `m = 0`, which MAME's own fast path treats as "draw all 128
pixels", so a layer was painted solid across windows that should have been
transparent.

It was measured in use: table `0x6000` holds 72 non-zero words at the attract
frame, pattern `007f ffff e000` repeating from scanline 88, and `vscr & 0x1ff`
is 88 for that tilemap. Two independent numbers agreeing.

It is now implemented — gated in the mixer rather than folded into
`lb_transparent`, because tilemaps 2/3 draw their category-0 pass opaque and an
opaque pass ignores transparency. Cost **+204 ALM, zero M10K**, timing +0.401 ns.
`test_video` agrees with the updated reference over 380,929 checks;
`test_tile_mixer` went exhaustive 8,192 -> 131,072 states.

**And the picture did not change.** Record that plainly: the mask was a real
defect, correctly fixed, and something else is also wrong.

### Full analysis

**`docs/2d-gap-analysis.md`** is the investigation: what is ruled out by
measurement, what segas24 does that we do not, a per-tilemap content census from
the running reference, three ranked hypotheses with the cheapest decisive test
first, and the MAME harness notes. Read it before touching the video path.

The headline from it: **the four tilemaps are two pairs, not four peers.** Odd
maps are *window* maps and in `ctrl` mode are drawn only through their even
partner. At the attract frame MAME draws tilemap 3 **not at all** — and we draw
it. That is a confirmed divergence; whether it is *the* cause is the first thing
to test.

### The remaining suspect

**`ctrl & 0x6000` window/split-scroll mode**, unimplemented, and confirmed
active in the reference — `ctrl` = `tile_ram[0x5004 + ((layer>>1) & 2)]` reads
**`0x2058`**, so `ctrl & 0x6000` = `0x2000`, mode 1. In that path MAME:

- returns early for the odd tilemap, drawing only the even one
- pushes `vscr & 0x1ff` to both the even and odd tilemap
- takes per-line H-scroll from a table at `0x4000 + 0x200*layer` when
  `hscr & 0x8000`

We implement none of it, which is also the likeliest home of the missing
scrolling. `segaic24.cpp` `draw_common` is the reference; read it alongside
`draw_rect`.

### How to measure, next session

The tooling is built and in the scratchpad pattern — run MAME from a scratch
directory, it drops `cfg/`, `nvram/` and `snap/` wherever it starts:

    mame vr -rompath ~/roms -window -skip_gameinfo -autoboot_delay 0 \
            -autoboot_script <script>.lua

`-skip_gameinfo` is required or the warning screen blocks autoboot and the
script silently never loads. `-autoboot_delay 0` or the tap installs after the
exchange it is meant to capture. Assign every notifier and tap to a global or
the subscription is collected and the callback stops with no error.

The scripts written today: log every change to a memory range, install a
read/write tap with run-length compression, snapshot at frame intervals, and
dump a named region. `manager.machine.video:snapshot()` gives a reference frame
to diff against a photograph of the board.

## Where it is

**Real Virtua Racing code boots and executes.** The V60 takes the architectural
reset vector, fetches through the packed ROM mapping, clears and tests NVRAM,
work RAM, both display lists and tile RAM, passes the ROM checksum, completes
the I/O board handshake, and runs game code out of work RAM, with zero SDRAM
protocol violations and `dbg_fp_trap` never asserted.

**Always quote the run length with a boot figure.** Every count from this test
scales with `BOOT_CYCLES`, and the numbers in commit 9577ab3 (5,304,880 fetch
lines, 19.90 CPI) came from a run roughly ten times the committed default with
its length unrecorded — which is why they do not reproduce from `make m1_boot`
and read as a regression when they are not. Reproducible, 2026-08-15:

| `BOOT_CYCLES` | instructions | fetch line fills | CPI | busiest page |
|---|---|---|---|---|
| 20,000,000 (default) | 236,367 | 116,359 | 28.20 | tile RAM |
| 100,000,000 | 1,619,871 | 2,422,369 | 20.57 | work RAM, 504,334 |

Both end at `fe143d` with `replies=3`. CPI falls with run length because the
early phase is dominated by block instructions sweeping memory; it is
converging on the ~19.9 the longer run recorded, not disagreeing with it.

Note `ifetch lines` counts **8-byte wide-port line fills, not instructions** —
this document called them "instruction fetches" until 2026-08-15.

Two boot phases get cited and they are not the same run. The **post-handshake**
one above executes out of work RAM at `fe143d`. The **pre-handshake** one
stopped at `fe095a` polling the I/O board, and is where the 7.8 M-instruction
CPI and FP-trap figures come from — that one was mostly `MOVC` sweeping memory,
so it is the weaker evidence of the two about what game code does.

**Boot initialises the whole 2D path**, which matters for the top level: with no
TGP and no rasterizer, a core built today still has content to display. Accesses
over the default run — character RAM 168,288 across six pages, tile RAM 53,673,
colour translation tables 40,960, display lists 0 and 1 at 16,420 each, palette
8,433. The palette writes are real xBGR-555 entries (`8010 8200 c000 e318 801f
83e0 83ff fc00 fc1f ffe0`), not a clear.

Built, tested and area-measured:

| block | ALM | verification |
|---|---|---|
| `s32_v60` (imported, cast-fixed) | 20,000 | 29/29 unit tests |
| `m1_sdram` + `sdram_model` | 937 | 80,009 checks, 0 protocol violations |
| `m1_main` + `m1_mainram` + `m1_glue` | ~700 | boot + 25 glue checks |
| `m1_video` (whole 2D path) | 287 | 380,929 checks vs MAME |
| `m1_rom_loader` / `m1_decode` | 319 | 1,675 / 466,714 checks |
| `bw_monitor` | 381 | 2M checks, mutation-tested |
| `mb86233_core` (TGP, not yet wired) | 2,554 | ~16.7M fuzz + lockstep |
| `m1_raster_fill` + `m1_raster_div` | 2,113 | 152,025 quads / 31.6M spans vs MAME |

**Integrated** (`make quartus MOD=m1_integrated`): 21,796 ALM, 332/553 M10K,
24.62 MHz — Fmax is the V60's, which is the critical path in context too.

The table is per-block standalone measurements, and several of those blocks are
already inside the integrated figure. The budget total is composed differently
and does not double-count: **21,796 (integrated) + 2,554 (TGP) + 937 (m1_sdram)
= 25,287 ALM.**

## How to run things

On a fresh clone, first:

    chmod +x tools/bootstrap.sh quartus/report.sh   # zip transport drops exec bits
    ./tools/bootstrap.sh                            # populates third_party/

`third_party/` is gitignored, so without that there is no MAME reference source,
no V60 upstream and no `sys/`, and nothing below works.

    make test                  # full Verilator suite, must be all fails=0
    make lint                  # must be clean
    bash tools/run_v60_tests.sh    # V60 unit suite, 29/29
    make m1_main               # CPU+memory integration, 4 configurations
    make m1_boot               # boots real ROM; needs the image below
    make m1_boot WATCH_PAGE=0xC0   # ...with one page traced address by address
    make v60_cpi               # CPI vs memory latency sweep
    make area                  # yosys proxy area, for tracking between edits
    make quartus MOD=<module>  # real ALM/Fmax; defaults to Quartus 17.0
    make quartus_list          # which Quartus installs were found, and which won
    make quartus_paths         # worst timing paths of the last build

    python3 tools/build_rom_image.py vr ~/roms/vr.zip -o build/rom

ROM images and anything derived from them never enter the repository.

`make test` prints a fixed set of counts — the harnesses seed mt19937 with a
constant, so they do not drift with host or toolchain. The build instructions carry the
expected block; when a change legitimately moves a count, update it in the same
commit.

## What to do next

**M1 is complete and running on hardware.** The core boots, loads its ROM,
executes real Virtua Racing code and renders correctly on a DE10-Nano: zero
fetch deadline misses, 57.52 Hz measured from the core's own vsync, and the
picture pixel-identical to the reference. Two of the four items that used to be in this section are done — the top level
and MRA exist, and the tilemap fetch is pipelined.

**The controls work; the picture does not.** The whole DPRAM map is measured
rather than guessed, and the V60 polls all fourteen control bytes every frame on
real hardware. What blocks playability is that most of the 2D never draws — see
"The open M1 defect" above, which is the one thing to start on.

Resource state after all of it, Quartus 17.0 on 5CSEBA6U23I7:

| | used | of | |
|---|---|---|---|
| ALM | 26,469 | 41,910 | 63% |
| M10K | 409 | 553 | 74% |
| DSP | 49 | 112 | 44% |

**M10K is now the binding resource, not ALM.** 144 blocks remain and D3's band
buffer wants about 51 of them.

---

### 1. M2 — put the TGP in the design

**`docs/m2-tgp-integration.md` is the interface spec** — the four V60-side
registers with their exact commit and post-increment rules, the TGP's four
address spaces, the four table-driven math units, what has to be built with
sizes, and the order to build it in. Read that first.

**The core is done; the integration has not started.** Worth stating precisely,
because "the TGP is not done" reads as though the files are missing and they are
not. `rtl/tgp/` holds twelve modules — ALU, AGU, sequencer, register file,
memory, decoder, transfer unit and three FP units — fuzz-verified against MAME at
millions of cases per unit and area-measured at 2,554 ALM / 72 MHz.

**The four interfaces it has to present**, read off `model1.cpp`'s memory map —
the V60 already drives all of them:

| V60 address | Function |
|---|---|
| `0xd00000` | copro RAM address latch (mirrored to `0x1fffe`) |
| `0xd20000` | copro RAM data port |
| `0xd80000` | command FIFO into the TGP |
| `0xdc0000` | FIFO input status — what a waiting V60 polls |

**The microcode is `315-5573.bin`, 8 KB, and is NOT in the current ROM set.**
MAME loads it into `tgp_copro` and executes it; zero-filling it hangs the
machine, which is how its role was established. The board has three MB86233s —
`315-5571`/`315-5572` are the geometrizers and MAME never executes those (D4) —
so `315-5573` is the one that matters. It is also exactly what M0 exit criterion
2 needs: lockstep against real microcode rather than generated instructions.

Also owed for M2: `copro_data` (2 MB, `mpr-14898`-`14901`) and the polygon ROMs
(**16 MB**, `mpr-14890`-`14897`), which roughly quadruples the SDRAM footprint
and is another argument for putting sound samples on DDR3. Note `mpr-14897.33`
is present in the local set under the transposed name `mpr-14879.33`, CRC
`74873195` — renaming completes the polygon set.

**A stub will not do.** The TGP does the transform *and* the maths the game
logic consumes, so a block that merely acknowledges the FIFO would let the V60
proceed on garbage. That is why the real microcode matters.

What is missing is everything around it: `grep` finds `mb86233_core` referenced
only by its own file. No mailboxes, no copro glue, no command or result FIFOs, no
microcode load, no polygon capture. The engine is built and on the bench, never
bolted into the car.

Note also that M0's exit criterion 2 is still owed: the lockstep that exists runs
*generated* instructions against a reference, not real microcode.

The MB86233 is built, fuzz-verified against MAME and area-measured, and it is
**instantiated nowhere**. Nothing renders in 3D until it is, and the rasterizer
has nothing to draw until geometry exists.

This is the next milestone and the largest single piece of work left. It needs
the TGP wired to the main board, its program and data ROMs added to the MRA
(`tools/gen_mra.py` already documents where they go and deliberately omits them
while the blocks do not exist), and the polygon list captured off the output
FIFO to diff against MAME frame by frame, which is the geometry oracle: bit-exact
agreement with the reference, checked in volume.

### 2. The I/O board — DONE, and how it was found

**Status, 2026-08-16: complete.** The control map is measured, wired and
verified on hardware — the V60 polls all fourteen control bytes every frame at
the reference's own cadence. What blocks playability now is the 2D defect above,
not the I/O board. `docs/io-board.md` carries the full trail.

#### The map, measured

Three static readings had each been plausible and each been wrong. Running the
real Z80 against the real ROM under MAME, with a Lua script logging every change
to the shared RAM and one control held at a time, settled it in minutes:

| DPRAM | Contents |
|---|---|
| `0x00` | steering, centre `0x80`, full `00`-`ff` |
| `0x01` | accelerator, released `0x01`, floored `0xff` |
| `0x02` | brake, same shape |
| `0x03`-`0x07` | set to `0xff` at startup, contents unknown |
| `0x08` | IN.0 — coin 1, coin 2, test, service, start, VR1-3 |
| `0x09` | IN.1 — VR4 at bit 0, shift down/up at bits 4/5 |
| `0x0a` | IN.2 — drive-board RX, unused here |
| `0x0b`-`0x0d` | DSW1-3 |
| `0x0e` | chip port 6 |
| `0x0f` | toggles on its own period — a board output, do not write it |

Every digital bit matches MAME's `INPUT_PORTS( vr )` and what `Model1.sv`
already wired, so the layout recovered from the Z80 disassembly was right; what
was missing was any way to know it. The analog channels are new information —
nothing before this said where the MSM6253 landed.

**Note the idle values are not uniform.** Digital bytes rest at `0xff` because
every control is active low, but a released pedal reads `0x01`. A blanket
`0xff` idle is both pedals floored.

#### What is built

- `m1_ioboard` sweeps `0x00`-`0x0e` — fifteen bytes, `SWEEP_BYTES` — at roughly
  the board's own rate, stopping short of the `0x0f` output byte.
- All fourteen controls come off `hps_io`, steering on the left stick with the
  d-pad at full lock, pedals on buttons, test and service also on OSD switches.
- Both driving-cabinet MRAs name the real panel in the RTL's bit order.
- `make test_ioboard`: 21 + 68 checks, covering that each byte lands at its own
  address, that the sweep wraps at `0x0e` rather than at the counter's natural
  16, and that the boot handshake still wins the shared write port.

#### What is owed

**A hardware test.** The input path is complete in simulation: with the identity
block pushed, the V60 leaves the setup exchange and polls `0x00`-`0x0e` every
frame, at the reference's own cadence. What has not happened yet is a button
press on the board changing something on screen.

After that, the open questions are small and named: `0x03`-`0x07` are published
as `0xff` because that is what the board sets them to and their contents are not
known, and the twenty-three undecoded bytes of the identity block are reproduced
because the V60 requires them rather than because they are understood.

#### The finding that unblocked it

This game does **not** read the low-DPRAM sweep during setup — and that led to
three sessions of wrong conclusions. Our V60 polled the flag at `0x20`,
block-read `0x100`, and never touched `0x08`, which read as "the inputs arrive
through a mailbox at `0x100`". It does not. The V60 was **stuck in the setup
exchange**, and every conclusion drawn from that trace was a conclusion about
the phase it was stuck in.

What was missing is a **128-byte identity block at DPRAM `0x100`-`0x17f`**. The
V60 block-reads all of it once, immediately after its first handshake is
answered, and will not go on to poll its controls until it has. Nothing writes
that window beforehand, so the board supplies it. `docs/io-board.md` has the
bytes and the hard-rule-2 reasoning for reproducing them.

#### Two lessons worth keeping

**The MRA and the RTL must be edited together.** They disagreed — the MRA named
joystick bit 4 `Start` while `Model1.sv` read it as Coin, and the generic
`names="Start,Coin,Service,Test,-,-"` covered four controls where the game has
twelve. That is invisible until someone presses a button, and then it presents
as a protocol fault.

**Read the emulator's own key bindings rather than assuming them.** A whole
measurement round was recorded as "these controls produce nothing" because Z and
X were guessed as the shifters; they are VR3 and VR4, and the shifters are C and
V. The presses had worked perfectly and the interpretation was wrong.

**An instrument that saturates silently is worse than none.** The boot trace's
watch-page tables held 32 addresses and filled without saying so, so "the V60
touches 32 DPRAM addresses and none is `0x08`" was a table limit reported as a
measurement — and it was used to reject the correct answer. They hold 256 now
and the same run reports 90. Anything that can fill must report that it did.

**A negative result is a result, and must be written down as one.** The row
mask was measured in use, correctly implemented, verified against MAME over
380,929 checks, and changed nothing on screen. Without that recorded, the next
session re-derives the same fix.

**A read tap is a different instrument from a memory watch.** Watching memory
change finds where values are *written*; it cannot find where they are *read*,
because a read leaves no trace. Both ends of this protocol are available as
oracles — MAME's Lua `install_read_tap` on one side, our own boot trace on the
other — and the question was settled in minutes once the right one was pointed
at it. Two setup notes that each cost a run: `-skip_gameinfo`, or the warning
screen blocks autoboot and the script silently never loads, and
`-autoboot_delay 0`, or the tap installs after the exchange it is meant to
capture.

#### This is per-game, but barely

The DPRAM addresses are board hardware and do not vary — same 315-5338A, same
`EPR-14869` in every cabinet. MAME carries six input maps across the ten Model 1
entries, and the system half of IN.0 (coin 1, coin 2, test, service, start) is
bit-identical in all of them. Only the game buttons move, IN.1 is fully
game-specific, and the analog count runs from two (`netmerc`) to five (`swa`).
That makes the per-game part a mux on the bit packing, selectable from the MRA,
rather than an RTL change per title — not worth building until there is a second
game, and the others need M2 and M3 first anyway.

Sound does **not** depend on any of this. MAME reaches the sound board through an
i8251 UART (`m1uart` -> `segam1audio`), not through the I/O board — see item 5.


### 3. Finish the rasterizer — the band buffer and binning

The fill path is done and measured: 2,113 ALM, 2 DSP, 0 M10K, 63.67 MHz, checked
against a C transcription of MAME's `fill_quad` over 152,025 quads and 31.6 M
spans with zero mismatches.

What is left is **the band buffer, the binning pass, writeback and scanout** —
which is where D3 actually gets tested and where the M10K goes. See
`docs/m3-rasterizer-spec.md` for the rules and the two unspent levers. Note the
read that preceded it found MAME performs the depth sort in the rasterizer
rather than receiving a sorted list, which is D3's premise; that is not a
measurement meeting D3's reversal condition, and the quad count per frame from
the M2 capture is what settles it.

### 4. Close the SDRAM interface properly

**This works but is unverified, and it is the one part of the design nothing has
ever constrained.** `SDRAM_CLK` is a fabric inversion of `clk_sys`; there is no
`create_generated_clock`, no `set_input_delay`, no `set_output_delay`. The
fitter is free to skew the clock pin against data and address, and it may do so
differently on every build.

The read capture phase that makes the board work — CL+2, selectable from the OSD
— was found **empirically, from observing every burst return one 16-bit word
late**. It was not derived from a timing analysis, and it is one cycle away from
the value the simulation model needs. That is a working core resting on a number
nobody has closed.

Do this before trusting the design on a second board or a different SDRAM
module. It is also the honest explanation for why the derivation in
`m1_sdram`'s header is correct term by term and still gives the wrong total.

### 5. M4 — sound, over a UART rather than the I/O board

Entirely unbuilt, and worth recording how it attaches because it is not
obvious: the main board talks to the sound board through an **i8251 UART**, not
through the I/O board or a shared latch. `model1.cpp` wires `m1uart`'s txd to
`segam1audio`'s rxd and back, with `rxrdy`/`txrdy` driving `sound_ready_w`.

The sound board itself is a 68000, a YM3438 and two MultiPCMs, with its own ROM
regions (`M1AUDIO_CPU_REGION`, `M1AUDIO_MPCM1/2_REGION`). `tools/gen_mra.py`
already documents where they belong in the stream and deliberately omits them
while the blocks do not exist.

### 6. Understand the 103-cycle character fetch wait

Measured in the whole system, a character fetch waits an average of 103 cycles
(240 before the line-buffer work reduced the request rate). That is far more
than a round-robin turn between three active ports should cost, and it is not
understood.

It is **not** currently a problem — the engine keeps up with room to spare and
misses no deadlines — so this is an efficiency question, not a bug. It will
matter when the rasterizer joins the same controller. Find out where the time
goes before changing `m1_sdram`, which is verified at 80,009 checks.

## What is owed

Neither of these blocks the three tasks above, and neither is visible in a green
`make test`. Both are recorded here so they are not quietly lost.

**Microcode-driven lockstep for the TGP — M0 exit criterion 2, not met.** What
exists is `sim/tgp/mb86233_ref.cpp`, a whole-CPU `execute_run` reference running
in lockstep with the core over 8,000 retires of *generated* instructions across
every decoded ALU op. It has already caught two real core bugs. The criterion
asks for real microcode, and the suite line says so: `mb86233_core: checks=23
fails=0 lockstep_regs=8000 diverged=0 (microcode-driven lockstep still owed)`.

**Denormal and NaN-payload semantics.** The FP harnesses skip denormal inputs,
denormal results and NaN results, and the gap reaches the flags too — `fcpd`
against a negative NaN sets SGD in MAME and not in the RTL, because the units
emit a canonical quiet NaN. MAME evaluates with host C floats; silicon of this
era commonly flushes to zero. `README.md` states both questions in full.
Resolve against real microcode traces, not against the host, and do not widen
the harness coverage before that is settled.

## Budget

**Measured on the real core** (`make rbf`, Quartus 17.0, 5CSEBA6U23I7), not on
`m1_integrated` — earlier versions of this section quoted the measurement
vehicle, which excludes the whole MiSTer framework:

| | used | of | |
|---|---|---|---|
| ALM | 26,663 | 41,910 | 64% |
| M10K | 409 | 553 | **74%** |
| DSP | 49 | 112 | 44% |

**The V60 is 17,691 ALM — 67% of the entire design.** Everything written for
this project totals under 1,000; `ascal` takes 1,984 and the rest of the
framework about 1,600. That single fact decides where optimisation is worth any
effort, and it is the V60 or nothing.

Still to build, against **15,247 free ALM**: TGP 2,554 (measured), rasterizer
3,000-6,000, sound ~7,000. Total 12,554-15,554 — it fits, with the pessimistic
end exactly at the wall.

**Unspent lever, re-measured:** V60 without the FP group is **-2,984 ALM** on
the full core. An earlier -1,987 is recorded in `00-decisions.md` from a smaller
design; both are kept rather than one silently overwritten, and they get
reconciled when the lever is actually spent. `dbg_fp_trap` has never fired but
is **inert by construction in a build that has FP**, so that is not evidence
yet — `tb_m1_boot` prints a warning if an FP opcode executes, and a long run
under the define settles it off-hardware.

### M10K is the binding resource, and where it goes

| memory | M10K | note |
|---|---|---|
| tile RAM (`tram_c` + `tram_v`) | 128 | **held twice** |
| display lists (`dl0`, `dl1`) | 128 | consumer not built |
| colour translation (`cxlat`) | 48 | |
| palette (`pram_c` + `pram_v`) | 32 | **held twice** |
| video line buffers | 12 | 1,792 bits in a 10,240-bit block |
| `ascal` (framework) | 54 | not ours |
| loader, DPRAM | 7 | |

144 blocks free and D3's band buffer wants ~51, so M3 fits without any of the
below. These are the reserve, in order of value:

- **Deduplication is the biggest lever and it is ours.** Tile RAM and palette
  are each stored twice, a CPU-side copy and a video-side copy, because an M10K
  has two ports and we need one write plus two reads. That is **80 M10K of pure
  redundancy**. The video side reads at 16 MHz effective against an 80 MHz
  `clk_sys`, so there is 5:1 slack to interleave the CPU read behind an arbiter.
  No SDRAM bandwidth cost.
- **Display lists to SDRAM: 128 M10K.** Sequential streaming access, and the
  consumer does not exist yet, so there is no working code to break.
- **Line buffers to MLAB: 12 M10K for ~480 ALM.** They use 17% of each block.
  The only good MLAB candidate — MLAB is 32 words deep, so everything else is
  too deep to qualify.
- Tile RAM to SDRAM is the wrong candidate: read every scanline, on a bus that
  already has an unexplained 103-cycle character-fetch wait.

### Sound, sized from MAME rather than guessed

`model1.cpp`: 68000 with 768 KB of code, YM3438 at 8 MHz, **two MultiPCMs with
4 MB of samples each**, over an i8251 UART at 31.25 kHz.

- fx68k and Jotego's JT12 are both GPLv3, and every file here is
  `GPL-3.0-or-later`, so both are usable. That removes the two largest pieces.
- **The MultiPCM is the real unknown** — a 28-channel wavetable engine with
  envelopes, interpolation and panning, times two instances, and no open core I
  know of. MAME's device is BSD-3-Clause so it can drive per-channel fuzzing the
  way the TGP was verified.
- **Put the 8 MB of samples on DDR3, not SDRAM.** 56 channels each fetching from
  a different place is random access, not bursts; it would row-thrash a bus that
  already carries V60 fetch, CPU data and character fetch. `DDRAM_*` is
  available and `ascal` already uses it.

Worth spiking one MultiPCM channel through Quartus early — it converts the
~7,000 estimate into a number, and that number decides whether all four
milestones fit on this device.

## Open decisions

**tv80 vs HLE for the I/O board — deferred, not settled.** The evidence is that
nothing has needed a Z80 *yet*: the V60 reads only the status byte, never input
data. But attract mode and the service menu have not run, and that is where
controls, coin, service and DIP switches get read. Licensing is clear either
way — tv80 is MIT and Verilog (simulatable), T80 is BSD-3 but VHDL (Quartus
only), MAME's 315-5338A is BSD-3 and not yet in the sparse checkout. See
`THIRD-PARTY.md`.

**`NO_FP`.** `dbg_fp_trap` never asserted on either boot run — 7.8 M
instructions pre-handshake, and 5.3 M fetches of real game code after it — and
the ROMs of 2 of 8 sets show no excess of FP-shaped byte pairs. The
post-handshake run is the evidence that matters, since the earlier one was
largely `MOVC` sweeping memory. Good evidence, not conclusive: attract mode and
gameplay have not run. `make m1_main` runs a configuration with an FP opcode
injected, which must trap, so the detector is known live.

## Things that bite, learned the hard way

**Everything MiSTer-specific now lives in `docs/mister-integration.md`** — the
framework deadlocks, the PLL naming requirement, the block-RAM inference table,
how to make the screen an instrument, and how to test against a board. Written
framework-generic so it carries to the next core.

**Block RAM inference is silent when it fails.** Quartus builds memories out of
flip-flops and keeps going. Two separate incidents: the video line buffers cost
28,816 ALM before being fixed, and the main-board memories consumed 15 GB and
never finished synthesising. Quartus 17.0 does **not** infer RAM from
`mem[a][7:0] <= d[7:0]` byte-enables — use two byte-wide arrays with plain
write enables, and put an explicit `ramstyle` on anything that matters.
Simulation cannot see any of this; only `make quartus` can.

**Test the idiom small.** The RAM question was settled in 30 seconds by
synthesising both forms at 1024 entries, after hours of full-size builds
answered nothing.

**Acknowledges must be held, not pulsed.** Anything talking to a `ce`-gated
requester must hold `ack` until the request drops. A one-cycle pulse is missed
and the CPU waits forever. This bit twice — `m1_main`'s bus and the fetch
bridge — and both times looked like a dead CPU rather than a handshake fault.

**The boot trace is the best debugging tool here.** A histogram of bus accesses
by page, plus per-address counts and write data for one watched page, has found
five blockers in a row. The watched page is a make variable: `make m1_boot
WATCH_PAGE=0xC0`, defaulting to the I/O board. `BOOT_CYCLES` shortens the run.

**Watch the machine.** Quartus with un-inferrable RAM will eat all system
memory; `make quartus` now runs under a timeout. Do not use `ulimit -v` —
Quartus reserves far more virtual address space than it uses. Also: `/tmp` here
is a 16 GB tmpfs, so build artefacts must not go there.

**Quartus parses `// synthesis <word>` as a pragma** — do not start a comment
sentence with it.

**A file list outside `make test` rots silently.** `m1_boot` kept its own
verilator source list and lost `rtl/m1_mainram.sv` when the on-chip memories
were split out of `m1_main.sv`; `run_m1_main.sh` and `SRCS_m1_integrated` were
updated and it was not. Because it is not in `make test`, nine commits went by
green while the target would not elaborate — including the two that quote its
output. Anything with a hand-maintained
source list needs running after a file moves — or its list needs to stop being
hand-maintained.

## When something is unknown, run MAME. Do not reason about it.

The single most useful rule this project has. MAME is not only the correctness
oracle for finished work — it is the cheapest way to answer a question about the
hardware, it is available at every moment, and instrumenting it takes minutes.

Reasoning about what the hardware "must" do has been wrong five times, and in
every case the measurement was available the whole time:

| Question | Reasoning said | Measurement said |
|---|---|---|
| where do the inputs live | a mailbox at DPRAM `0x100` | `0x00`-`0x0e`, polled every frame |
| why is most of the 2D missing | the row mask, then the window mode | neither — the V60 never gets that far |
| does the V60 read the coprocessor back | it must, to collect results | **never**, in 2,500 accesses |
| what blocks the coprocessor | the math units returning zero | the **data ROM**, read before any math unit |
| how deep are the coprocessor FIFOs | 64 seemed like sensible slack | **16**, and full halts the CPU |

Three of those cost a session or more. The pattern is identical every time: a
plausible mechanism, reasoned from partial evidence, that a five-minute
instrument would have refuted.

### Which instrument answers which question

- **`install_read_tap` / `install_write_tap`** on a device's address space —
  what does it actually *touch*. A memory watch cannot answer this: **a read
  leaves no trace in memory**, and not knowing that cost a day.
- **A frame notifier polling a region** — what does it *contain*.
- **`manager.machine.video:snapshot()`** — a reference frame to diff against a
  photograph of the board.
- **Any CPU can be tapped, not just the main one.** Tapping `:tgp_copro`'s IO
  space is what named the data ROM as the coprocessor's first blocker, after the
  math units had been assumed.

Three setup details, each of which cost a run: **`-skip_gameinfo`** or the
warning screen blocks autoboot and the script silently never loads;
**`-autoboot_delay 0`** or the tap installs after the exchange it was meant to
capture; and **assign every notifier and tap to a global** or the subscription is
collected and the callback stops with no error. Run from a scratch directory —
MAME drops `cfg/`, `nvram/` and `snap/` wherever it starts.

### And measure before building

A Quartus build is 25 minutes and a hardware test needs someone watching a
screen. The boot trace and the board have been shown to reach the same state — the
same PC, `fed5a4` — so a question simulation can answer should never be sent to
hardware. Build when simulation says the thing being tested has changed.

## Method note

Every significant finding this session came from measuring rather than
reasoning, and several came after an assertion turned out to be wrong: the V60
CPI figure was stale, the budget did not justify what I claimed, the I/O board
did not need per-variant work, the handshake reply was not a signature. Where
an estimate has a wide spread, measure it — it has consistently been cheaper
than the argument about it.
