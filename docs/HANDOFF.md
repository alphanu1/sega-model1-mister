# Handoff — 2026-08-15

State of the Sega Model 1 core at the end of the M1 memory/CPU/video work.
Everything below is committed and pushed; the tree is clean and the full suite
is green.

`CLAUDE.md` and `README.md` were brought back into agreement with this document
on 2026-08-15 — both still described M0 as the current milestone, and CLAUDE.md's
"expected output, exactly" block predated eight harnesses. If those three ever
disagree again, this file is where the measurements are.

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

## The wobble: what it is NOT, and where that leaves it — 2026-08-16

The picture on hardware is unstable — flashing white, jumping vertically —
and it became unstable only once the game had real tile data to draw.

**The fetch engine is not the cause, and the evidence that said it was, was
misread.** The deadline-miss counter is cumulative, and 6,849 misses over 103
frames was read as a rate — "one line in six" — when it is not:

```
20 M cycles: frames=31  misses=6849
40 M cycles: frames=46  misses=6849
...
120 M cycles: frames=103 misses=6849
```

Every miss happens before frame 31 and the count never moves again. Seventy-two
consecutive frames are clean. The misses are a boot transient: while the V60
sweeps memory in its power-on tests it saturates the SDRAM controller, every
line overruns, and once the game settles the engine keeps up with room to
spare. That was already true before any of the work below.

### What the engine work bought anyway

Both changes are verified and worth keeping — they are the difference between
"keeps up" and "keeps up with margin", and the margin is what four dense layers
will need — but neither addressed the symptom:

| | before | after |
|---|---|---|
| cost per layer, distinct tiles | 1,614 | 1,182 |
| cost per layer, text | ~700 | **267** |
| four text layers against 3,280 available | ~2,800 | **1,068** |
| character fetch wait | 240 cycles | 103 |
| deadline misses | 6,858 | 6,849 |

1. **Fetch pipelined**: fetch and emit are separate state machines a column
   apart, so a column's memory latency is paid under the emission already
   happening. Bought nine misses, because the unit test models a 14-cycle
   char_ack and the real figure under CPU contention was 240 — pipelining hides
   eight cycles.
2. **Four pixels a cycle into the line buffer**: `char_data` always delivered
   eight 4bpp pixels at once and the emit side wrote them one at a time. The
   line buffers are now four lanes of 128 entries, so four consecutive screen
   positions touch each lane once and land in one write even when the tile
   boundary is unaligned — the only form Quartus will infer, since a per-lane
   byte enable infers nothing at all (see `rtl/m1_mainram.sv`).

37,202 fetch checks and 380,929 video-against-MAME checks pass throughout.

### So what is left

In simulation, steady state is clean: zero deadline misses over 72 frames and a
correct picture. On hardware it is unstable. That is the same shape of problem
as every other fault this month — something simulation does not model — and the
candidates have not been narrowed yet:

- **Video mode.** The core emits MAME's `set_raw(16 MHz, 656, 0, 496, 424, 0,
  384)` = 57.52 Hz. The sync POSITIONS inside blanking are "chosen, not
  derived" — `m1_video_timing`'s header says so — and MiSTer's scaler measures
  the frame from those edges. A jumping image is characteristic of a scaler
  that cannot lock. **Read the OSD's reported timings first; it costs nothing.**
- **Read-phase margin.** CL+2 is correct for the fetches checked, but it was
  chosen from a one-word shift, not from a timing analysis, and nothing
  constrains the SDRAM I/O.
- **The 103-cycle character wait** is still unexplained. It is far more than a
  round-robin turn between three ports should cost, and worth understanding on
  its own merits even though it is not the symptom.
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
constant, so they do not drift with host or toolchain. `CLAUDE.md` carries the
expected block; when a change legitimately moves a count, update it in the same
commit.

## What to do next

**M1 is complete and running on hardware.** The core boots, loads its ROM,
executes real Virtua Racing code and renders correctly on a DE10-Nano: zero
fetch deadline misses, 57.52 Hz measured from the core's own vsync, and the
picture pixel-identical to the reference. Two of the four items that used to be in this section are done — the top level
and MRA exist, and the tilemap fetch is pipelined.

**The game is not yet playable, and that is the shortest gap to close.** No
controller input reaches the core at all: `hps_io` in `Model1.sv` is
instantiated with no joystick connections, and `m1_ioboard` is a boot-handshake
stub whose own header says so — it answers the SEGA handshake and reads no
input data. See item 2.

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

The MB86233 is built, fuzz-verified against MAME and area-measured, and it is
**instantiated nowhere**. Nothing renders in 3D until it is, and the rasterizer
has nothing to draw until geometry exists.

This is the next milestone and the largest single piece of work left. It needs
the TGP wired to the main board, its program and data ROMs added to the MRA
(`tools/gen_mra.py` already documents where they go and deliberately omits them
while the blocks do not exist), and the polygon list captured off the output
FIFO to diff against MAME frame by frame — the verification model in `CLAUDE.md`
names that as the geometry oracle.

### 2. The I/O board — make it playable

**Nothing the player does reaches the core.** Two separate gaps, and the first
is trivial:

- `hps_io` is instantiated in `Model1.sv` with **no joystick or analog
  connections at all**. Start, coin, service and test are listed in every MRA's
  `<buttons>` element and go nowhere.
- `m1_ioboard` answers the boot handshake and nothing else. Its header is honest
  about this: on the real board a Z80 (315-5338A) reads controls, coin, service
  and the DIP switches into the shared RAM at 0xc00000, and this is not that
  chip. Across a full boot run the V60 read exactly one address in that region
  more than twice — the status flag — and **no input data**, because attract
  mode and the service menu had not been reached.

**Done, 2026-08-16: the controls are wired**, and the trace has been run.
`docs/io-board.md` has the full findings; the short version is that the V60
writes a `"SEGA"`-tagged command block at DPRAM `0x100` and reads back a 27-byte
window at the same place, so that is a command/response buffer and the response
is where input state must appear. It does **not** poll a fixed input offset,
which is why the layout cannot be guessed from the trace alone.

D9 has since settled tv80 versus HLE in favour of the HLE, so what remains is
recovering the response format — either by disassembling `EPR-14869` (it is in
`vr.zip`) or by running it against a model of the 315-5338A, whose register
interface is now decoded in `docs/io-board.md`. Both routes are described there.

Sound does **not** depend on this. MAME reaches the sound board through an i8251
UART (`m1uart` -> `segam1audio`), not through the I/O board — see item 5.

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

27,400 ALM built of 41,910 — 25,287 plus the 2,113 of fill path measured on
2026-08-15. **14,510 left.**

Still to build: MiSTer `sys/` 3,000-4,000, sound 5,000-7,000, I/O board
2,500-3,000, and the rest of the rasterizer. That last number is the one that
moved: the estimate was 3,000-6,000 for the whole thing and the fill path alone
took 2,113, so what remains of it — binning, band buffer, writeback, scanout —
is now the widest uncertainty in the budget rather than a comfortable margin.

M10K is now a constraint too: 332 of 553 before the band buffer, sound or
sprites.

One lever is measured and unspent: **V60 without the FP group, -1,987 ALM and
Fmax 24.62 -> 45.54**.

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

## Method note

Every significant finding this session came from measuring rather than
reasoning, and several came after an assertion turned out to be wrong: the V60
CPI figure was stale, the budget did not justify what I claimed, the I/O board
did not need per-variant work, the handshake reply was not a signature. Where
an estimate has a wide spread, measure it — it has consistently been cheaper
than the argument about it.
