# The I/O board, and what is known about its protocol

D9 chose an HLE over a Z80 core, for area: ~300 ALM against ~2,000, with the
~1,700 difference kept for the TGP and the rasterizer where the uncertainty
actually is. The cost of that choice is that the protocol has to be recovered
rather than obtained by running the real code.

This file is what has been recovered so far, all of it either from MAME (hard
rule 3) or from the boot trace. **Nothing here is inferred from what would be
convenient.**

---

## The hardware

`837-8950-01`, from MAME's `sega/model1io.cpp`:

- **Z80** at 4 MHz (32 MHz / 8), with `EPR-14869` — 64 KB, and **it is in
  `vr.zip`**, so the protocol is recoverable by disassembly if observation is
  not enough.
- **Sega 315-5338A** custom I/O controller.
- **MB8464** 8 KB SRAM, **93C45** EEPROM, **OKI M6253** ADC.
- Three 8-position DIP switch banks, test and service push buttons.

MAME's model is **LLE** — it runs the real Z80 — so MAME documents the
*hardware*, not the protocol. The protocol lives in the ROM.

### The Z80 cannot see the shared RAM

Its address map is ROM at `0x0000`, RAM at `0x4000`, the custom chip at
`0x8000-0x800f`, and the ADC at `0xc000-0xc003`. **There is no dual-port RAM in
it.** Everything reaching the V60 goes through the 315-5338A, which is why D9
records that an LLE needs the custom chip too and is not "wire a core and load a
ROM".

---

## The 315-5338A, from `sega/315_5338a.cpp`

Register file at `0x8000-0x800f` from the Z80's side:

| Reg | Access | Effect |
|---|---|---|
| `0x00`-`0x06` | r/w | Ports 0-6. Direction from `0x08`; reading an input port calls out to the pins |
| `0x08` | r/w | Port direction, 1 = input |
| `0x09` | w | **Command** — see below |
| `0x0a` | r/w | Serial data byte, staged for the command |
| `0x0b` | r | Command readback |
| `0x0c` | r | **Read DPRAM[address]** |
| `0x0d` | r | Status. Bit 3 transfer finished, bit 0 command acknowledged; MAME returns a constant `0x08` |

Commands written to `0x09`:

| Value | Effect |
|---|---|
| `0x00` | DPRAM address low byte = serial data |
| `0x01` | DPRAM address high byte = serial data |
| `0x07` | **Write** serial data to DPRAM[address] |
| `0x70`-`0x77` | **Fast write** serial data to DPRAM[cmd & 7] — i.e. bytes 0-7 |
| `0x87` | Sent after setting an address, when about to receive |

The fast-write path existing at all is a hint worth keeping: bytes `0x00`-`0x07`
of the shared RAM are the ones the board updates often enough to be worth a
single-command path.

---

## What the V60 actually does, from the boot trace

`make m1_boot BOOT_CYCLES=150000000 WATCH_PAGE=0xC0`, run to the service menu
(`pc=fe1435`, 68 handshake replies). The V60 side maps one DPRAM byte per *even*
address, so V60 `0xc00200` is DPRAM byte `0x100`.

**Writes, in order:**

| V60 | DPRAM | Data |
|---|---|---|
| `c00034`-`c0003a` | `0x1a`-`0x1d` | `53 45 47 41` = `"SEGA"` |
| `c00040` | `0x20` | `01` — the request flag |
| `c00200`-`c00224` | `0x100`-`0x112` | `"SEGA"` then `1c 82 01 00 3e 9d ff 00 00 00 00 00 00 01 01` |

**Reads:** `c00040` 74 times — the flag, which `m1_ioboard` already answers — and
`c00200`-`c00234` (DPRAM `0x100`-`0x11a`), **27 bytes, three times each**.

### What that tells us, and what it does not

The V60 writes a `"SEGA"`-tagged command block at `0x100` with a payload, raises
the flag at `0x20`, and then reads back a 27-byte window at the same place. So
`0x100`-`0x11a` is a **command/response buffer**, and the response is where
input state has to appear.

What it does **not** show is any polling loop. The window is read three times
across the whole run, not repeatedly — so the service menu is not spinning on an
input byte. That is the opposite of what a simple "inputs live at a fixed
offset" model predicts, and it is the main reason the layout cannot be guessed
from here.

Note also that `m1_ioboard` currently writes nothing, so those reads return what
the V60 itself wrote. The boot survives because it is reading its own bytes back
— which is worth remembering before treating "boot works" as evidence about the
response format.

---

## Locating the protocol code, without a disassembler

Ghidra was the obvious tool and turned out not to be needed. Nothing was
installed; the code was found by searching the ROM for the byte patterns of the
instructions that must be there.

**None of what follows is committed.** The ROM is extracted to a scratch
directory and analysed there; hard rule 2 means no ROM bytes and no disassembly
listing enter the repository. What is recorded here is the *interface* — which
is the thing an HLE has to reproduce and is not itself the ROM.

Findings, in the order they fell out:

- **Only the first 16 KB is real.** MAME maps `0x0000-0x3fff` as ROM, and bytes
  `0x4000` upward in the 64 KB image are all `0xFF`.
- **There are no absolute stores to the chip.** Searching for `LD (0x8009),A`
  and friends found nothing, because the Z80 reaches the chip through a pointer:
  the only loads of a constant in `0x8000-0x800f` are at ROM `0x0006`/`0x0007`,
  setting `IY = 0x8000` at reset. Every access is `(IY+d)` indexed.
- **The whole DPRAM access block is about 60 bytes**, around `0x74c-0x7b4`, and
  the only chip registers it touches are the direction register `+8`, the
  command register `+9`, and port 0.
- The command values written are exactly the ones MAME's device implements:
  `0x00`/`0x01` to set the address low and high, `0x07` to write a byte, `0x87`
  to prepare to receive. Nothing undocumented appears.

### The primitives, and how much of the ROM uses them

| Routine | Call sites | What it does |
|---|---|---|
| `0x74c` | 8 | |
| `0x768` | 13 | writes a byte (`cmd 0x07`) |
| `0x776` | 12 | writes then receives (`0x07`, `0x87`) |
| `0x787` | 3 | shared address setter (`0x00`, `0x01`, `0x87`), called by the two above |
| `0x7a6`, `0x7b4` | 2 each | port 0 access |

So the entire board-to-V60 protocol funnels through a handful of primitives with
roughly 35 call sites in 16 KB. That is a small enough surface to read.

### What is left to establish

**Which DPRAM addresses the callers pass.** The address is set up in a register
pair before calling `0x787`, so the layout falls out of reading the ~25 call
sites of the two write routines. That is the remaining work, and it is bounded:
25 sites, not 16 KB.

Ghidra remains available if the caller analysis needs real decompilation — Arch
has it, though it wants a JDK and about a gigabyte — but the targeted approach
has not run out of road yet.

---

## The other route, if reading the callers stalls

**Run it.** A small Z80 interpreter plus a model of the 315-5338A above,
fed the exact command block the trace captured, would show what the board writes
back without anyone reading assembly. That is the same "extend by observation"
method that found the missing on-chip RAMs and the single-cycle ack, and it
answers the question directly — at the cost of writing an interpreter that has
to be right.

Whichever is used, **hard rule 2 still applies**: the protocol may be
implemented from what is learned, but no ROM-derived table gets committed.

---

## Experiment 1: publishing input bytes — the mechanism is wrong

**Result: negative, and the negative is about this code rather than about the
hardware.**

`m1_ioboard` gained an input publisher — eight bytes refreshed round-robin into
the shared RAM at a parameterised base — on the reasoning that the 315-5338A's
single-command fast write to bytes 0-7 implies those bytes are refreshed often,
and that an M10K coming up zeroed presents every active-low control as held.

Enabling it regresses the machine:

| | publisher off | publisher on |
|---|---|---|
| V60 PC | `fe143d` | `fe022c` |
| handshake replies | 62 | **1** |
| screen | TEST MODE menu | one flat colour, RGB(16,66,255) |

**The control run is what makes this conclusive.** Publishing to `0x400` — an
address nothing reads — gives *byte-identical* results to publishing at
`0x000`: same PC, same reply count, same pixel count. The data location is
irrelevant, so the fault is the refresh starving the handshake for the single
shared write port, not anything about where the bytes land.

Beware the metric that nearly hid it: "non-black pixels" rose from 4.99 M to
15.7 M, which reads like more being drawn. It was one flat blue field. A
brightness count is not a liveness check.

The unit test does not catch this, and it is worth understanding why before
trusting the next one: there the write port always acknowledges, while in the
system `io_ack` is denied whenever the V60 is writing. The round-robin has to
yield the port properly, not merely take it when it happens to be free.

`PUBLISH_INPUTS` therefore defaults to **0**.

### What was actually wrong with it — corrected after reading the ROM

At the time this failed I concluded the shape was wrong: that the trace showed
request/response, so a background refresh was the wrong model and its
arbitration should not be fixed. **The ROM says otherwise.** The board does
exactly what the publisher was trying to do — a periodic sweep writing input
ports into low DPRAM. The model was right.

Two things were actually broken:

1. **It conflates which write finished.** `if (io_we && io_ack)` treats any
   completed write as the handshake reply whenever `pending` is set, so a
   routine refresh completing mid-handshake clears `pending` and bumps the
   reply counter *without the flag byte ever being written*. The V60 then waits
   for a flag nobody cleared.
2. **It refreshes every cycle it can take the port.** The real Z80 sweeps once
   per loop at 4 MHz — thousands of times slower. That is what turns a
   collision that is rare on hardware into a constant one here.

The single shared write port is itself a workaround, not the hardware: the real
board has an MB8421 true dual-port RAM and no arbitration at all. Ours shares
one port because Quartus 17.0 will not infer a two-write-port M10K — measured in
`rtl/m1_mainram.sv` at 192 ALM becoming 16,059 when tried. Sweeping at the
board's rate makes that workaround stop mattering rather than papering over it.

---

## Experiment 2: the sweep works, and the game does not read it

With the completion-tracking and rate faults fixed, the publisher no longer
regresses anything: `pc=fe143d`, 62 handshake replies, the TEST MODE menu
rendering identically to baseline. Holding a control changes **zero pixels**.

Re-running the boot trace with the sweep enabled says why. Over 150 M cycles the
V60 touches 32 DPRAM addresses and **none of them are `0x08`-`0x0f`**:

| Addresses | Accesses |
|---|---|
| `0x1a`-`0x1d` | the `"SEGA"` block, written once |
| `0x20` | the flag, **74 accesses** |
| `0x100`-`0x11a` | the window, **3 reads each** |

**The mistake was conflating two questions.** The disassembly says what the Z80
*writes*; it does not say what this V60 code *reads*. The sweep into low DPRAM
is real and the layout is probably right for some code path — but it is not the
path Virtua Racing's service menu uses, and the trace said so before the
disassembly started.

### The number worth noticing

Three reads of the window against seventy-four of the flag. That is not a
program ignoring its inputs; it is a program **waiting to be told they are
ready**. `m1_ioboard` only ever clears the flag — it never raises one. If the
board is meant to set it to signal "new data in the window", the V60 would poll,
see nothing, and never re-read, which is the exact shape of these counts.

Untested hypothesis, recorded because it is the cheapest next experiment: have
the responder write the window and then raise the flag, and see whether the read
count climbs. If it does, the input path is the `0x100` window and the flag is a
doorbell in both directions.

The sweep stays enabled. It costs nothing, it is what the board does, and
attract mode may yet read it.

## Experiment 3: it is a mailbox, and we never answer it

Instrumenting the V60's reads — data and PC, with the byte lane the bus actually
used — makes the exchange legible. `v60_bus.sv` is the thing to read first here:
the address is valid at the request edge and the data only at the acknowledge,
and qualifying both on the same instant logs nothing at all, which is what the
first two versions of this probe did.

    cyc 38203089   c00040 -> 00  be=01  pc=fe022c     poll the flag
    cyc 38205425   c00200 -> 00  be=11  pc=fe08f2     block-read the window
    ...            (64+ bytes, every one from that same PC)
    cyc 38347601   c00200 <- 53                       write "SEGA" + payload

Three things this settles:

- **The window read is one instruction.** Every read carries the same PC, so it
  is a block move sweeping 64+ bytes, not a poll. "Three reads each" in the
  address histogram is three *passes*.
- **Reading zeros is correct, not a fault.** The read at cyc 38.2 M precedes the
  write at cyc 38.3 M by 142,000 cycles. The V60 checks the window for an answer
  *before* leaving its request. There is no DPRAM bug.
- **Accesses are 16-bit, `be=11`.** Not the byte lanes a 2k x 8 MB8421 would
  suggest, which is worth knowing before assuming a layout.

So the shape is a **mailbox**: the V60 leaves a request in the window, raises the
flag at `0x20`, and expects an answer left in the same place. `m1_ioboard` clears
the doorbell and writes no answer, which is exactly why 74 flag polls yield only
three sweeps.

### The board's own side of it

From the ROM, the Z80's reads of the shared RAM are at `0x14`, `0x15`, and
`0x1a`-`0x1c`. `0x1a`-`0x1d` is where the V60 writes `"SEGA"`, so the board is
polling for the V60's signature — the handshake seen from the other end. The
exchange therefore lives around `0x14`-`0x20` as well as the `0x100` window, and
the low-DPRAM sweep is a third, separate thing.

## The transport, recovered in full

The flag at `0x20` is a **command code**, not a doorbell. The board's main loop
reads it and branches:

| Flag | Board's action |
|---|---|
| `1` | write `0` back — acknowledge, nothing else |
| `2` | copy 128 bytes from DPRAM `0x100`-`0x17f` into its own RAM at `0x4000`-`0x407f`, clear the state byte at `0x4080`, then clear the flag |
| `3` | clear the flag and restart the exchange |

And independently of any command, the board **pushes** the same 128 bytes the
other way: it walks its RAM `0x4000`-`0x407f` and writes each byte out to DPRAM
`0x100`-`0x17f`, having set the state byte at `0x4080` to `0x40` first. It also
maintains a status byte at DPRAM `0x21` from that same state byte.

So the window is **bidirectional**, and is the same 128-byte block in both
directions. That resolves what did not add up: the V60's block-read of `0x100`
is not reading back its own leftovers, it is reading **the board's uploaded
block**, which is empty here because nothing pushes one.

It also explains why the V60 never touches `0x08`-`0x0e`, where the low-DPRAM
sweep writes. It is still in this setup exchange; the sweep matters later.

### What m1_ioboard has to do

All of this is evidence-backed rather than inferred:

1. hold a 128-byte block mirroring the board's `0x4000`-`0x407f`
2. push it continuously to DPRAM `0x100`-`0x17f`
3. on flag `= 2`, copy the window in to that block, clear the state byte, clear
   the flag
4. on flag `= 3`, clear the flag and restart
5. keep the `0x08`-`0x0e` sweep for when the game starts reading controls
6. maintain the status byte at `0x21`

Today's responder does one thing — clear the flag on any non-zero write. That is
correct for command 1, which is why boot gets as far as it does, and silently
wrong for 2 and 3, and it never pushes a block at all. Hence an inert service
menu.

### The remaining unknown, and why MAME cannot answer it

What the 128 bytes should *contain*. The board fills that RAM from its own
state, and where it does so has not been traced yet.

**MAME cannot supply this.** `model1io.cpp` is LLE — it instantiates a real Z80
and runs `EPR-14869`, so it reproduces the behaviour by executing it and its
source never describes the protocol. Hard rule 3 is intact; this is simply a
device whose oracle answers by running rather than by telling. The two routes
are therefore unchanged: keep reading the ROM, or run it.

### What is owed

Decode the request payload the trace captured — `1c 82 01 00 3e 9d ff 00 ...` at
`0x100` — and the response the Z80 builds for it, then write that response from
`m1_ioboard`. The primitives are known, the addressing convention is known
(BC holds the DPRAM address, B low and C high), and the call sites are
enumerated. What is not known is the *content*.

### The trace is definitive about where the inputs come from

Worth stating without hedging, because an earlier draft of this file did hedge
and it obscured the conclusion. Over 150 M cycles the V60 reads exactly two
things in this region: the flag at `0x20`, and the window at `0x100`-`0x12x`.
Nothing else. **So the inputs must arrive through that window**, because it is
the only place the CPU looks.

That is conclusive for the goal — making the service menu respond — and the only
caveat is scope rather than certainty: it is definitive about *this run*, to the
service menu. Attract mode or gameplay may read elsewhere.

It also settles what the low-DPRAM sweep is worth. It is faithful to the board
and costs nothing, but it is **not** a route to working inputs and should not be
counted as partial progress toward them.

The remaining unknown is therefore narrow: what the response in that window has
to contain. Reading the ROM says what the Z80 writes; the trace says what the
V60 reads; the answer needs both. Prefer the experiment that can falsify the
next guess over the one that would confirm it — three have each disproved a
plausible layout already.

## Experiment 4: MAME settles it — the layout is confirmed by measurement

Three static readings had each been plausible and each been wrong. Running the
real Z80 against the real ROM under MAME settled it in minutes.

### Setup

MAME 0.289 from the distribution's own packages, driven headless or windowed
with an autoboot Lua script that logs **every change** to the shared RAM, so a
key press names its own byte:

    mame vr -rompath ~/roms -window -autoboot_script watch.lua

Two things about the setup that cost time and are worth writing down:

- **Run it from a scratch directory.** MAME creates `cfg/`, `nvram/` and `snap/`
  wherever it is launched, and launching from the repository root drops them in
  the tree.
- **A Lua frame notifier stops firing if its subscription is collected.** Assign
  the result of `emu.add_machine_frame_notifier` to a variable that outlives the
  call, or the callback runs a few frames and then goes silent with no error at
  all. Two scripts produced empty logs that way before this was understood.
- Errors inside a frame notifier vanish. Wrap the body in `pcall` and log the
  message, or a wrong field name reads as "nothing happened".

An older ROM set will not run: MAME 0.289 wants the decapped copro microcode
(`315-557x`) and an EEPROM default (`93c45`). Zero-filled placeholders let the
machine start but **hang it** — `315-5573` is Virtua Racing's copro microcode
and it really is executed, so the V60 waits forever on a coprocessor running
nothing. The other two placeholders are harmless, per D4's finding that MAME
never executes the geometrizer ROMs.

### The result — the complete map

Holding one control at a time, every press appears as a single bit dropping from
an idle `ff` — active low, one bit per control. Three sweeps were needed to cover
all fourteen; this is the union, and every row is a measurement:

| DPRAM | bit | control | observed |
|---|---|---|---|
| `0x08` | 0 | Coin 1 | `fe` |
| | 1 | Coin 2 | `fd` |
| | 2 | Test / Service Mode | `fb` |
| | 3 | Service 1 | `f7` |
| | 4 | 1P Start | `ef` |
| | 5 | VR1 Red | `df` |
| | 6 | VR2 Blue | `bf` |
| | 7 | VR3 Yellow | `7f` |
| `0x09` | 0 | VR4 Green | `fe` |
| | 4 | Shift Down | `ef` |
| | 5 | Shift Up | `df` |

**This is exactly MAME's `INPUT_PORTS( vr )` bit order**, and exactly what
`Model1.sv` already wires and what `m1_ioboard`'s `INPUT_BASE = 0x008` already
targets. Both were right; what was missing was any way to know it.

One row carries its own check. The operator reported pressing F2 twice by
accident, and `0x08 -> fb` appears exactly twice in the log. A capture that
reproduces an unprompted detail of how it was produced is measuring the machine
rather than the expectation.

### The analog channels

`0x00`-`0x02` are the three MSM6253 channels, and holding an axis identifies each
one outright — the value ramps rather than snapping, so it cannot be confused
with a stray write:

| DPRAM | channel | rest | travel |
|---|---|---|---|
| `0x00` | steering | `0x80` centre | full `00`-`ff` |
| `0x01` | accelerator (pedal 1) | `0x01` | up to `0xff` |
| `0x02` | brake (pedal 2) | `0x01` | up to `0xff` |

Steering moved in steps of 3 per frame over 173 changes, which is the keyboard
ramp rate rather than anything about the hardware — a MiSTer analog stick will
present the absolute position directly.

**Note the pedal rest value is `0x01`, not `0x00`.** Publishing zero is a
released pedal only by luck; publish the measured idle.

### Getting the keys right matters more than it sounds

Two controls were recorded as "unmeasured" for a whole round because the guessed
keybindings were wrong — Z and X are VR3 and VR4, not the shifters, which are C
and V. The presses had worked perfectly; the interpretation was wrong. **Read
Tab -> Input Assignments and use what it says**, rather than assuming the
conventional layout. The wasted round looked exactly like a protocol fault.

### What else the capture shows

- At frame 9 the board sets `0x03`-`0x0e` to `ff` in one go — the input region
  initialising to idle-high, which is why publishing zeros presents every
  control as held.
- `0x0f` toggles between `80`/`40`/`20`/`60` on a regular period. It looks like a
  lamp or blink output, not a control.
- `0x11` free-runs. Ignore it when reading a diff.
- The window at `0x100` contains `53 45 47 41 1c 82 01 00 3e 9d ff 00 ...` —
  **byte for byte what our own V60 writes there**, from the boot trace. Two
  independent implementations producing the identical block is the strongest
  confirmation yet that the V60, the bus and the DPRAM are correct.
- Holding a control changes **nothing** in that window, which finally disproves
  the reading that the controls arrive through it.

### The correction this forces

An earlier section of this file said the trace was "definitive" that inputs must
arrive through the `0x100` window, because that is the only place the V60 reads.
The premise was true and the conclusion wrong: the V60 does read that window,
but what it reads there is the block exchange, not controls. Being definitive
about *where a CPU reads* is not the same as being definitive about *what it
reads for*.

## Revisit the LLE when the resource count is final

D9 chose the HLE against a budget that is still estimates — sound at 5,000-7,000
ALM and the rasterizer at 3,000-6,000 are ranges. **When M2, M3 and M4 are built
and the number is real, if there is ALM room the LLE should be reconsidered on
its merits**, because a Z80 running `EPR-14869` behind the 315-5338A is the real
board by construction, including whatever the HLE ended up approximating.

The swap is cheap by design: the V60 only ever sees the shared RAM, so both
implementations sit behind the same `m1_ioboard` interface, and the ROM is
already in `vr.zip`. Whatever is learned recovering the protocol for the HLE is
not wasted either — it is what says whether the LLE is behaving.

---

## What is already wired

`Model1.sv` now takes controls from `hps_io` — it previously took none at all,
so every MRA's `<buttons names="Start,Coin,Service,Test,-,-">` went nowhere:

- start, coin, service, test from `joystick_0` bits 4-7
- steering and two pedals from the analog sticks, converted from MiSTer's signed
  axes to the unsigned range the board's MSM6253 presents

The measurement exposed two gaps, both since closed:

1. **Coin 2 was tied to a constant** — `io_in0` bit 1 was `1'b0`, reading as
   never pressed despite having a real bit.
2. **The sweep did not reach the analog channels.** `INPUT_BASE = 0x008` over
   eight bytes covers `0x08`-`0x0f`, so `0x00`-`0x02` were never published: the
   wheel and both pedals were carried into the core and dropped.

Neither was visible before the measurement, because nothing said the analog
channels were at `0x00`-`0x02` in the first place.

### What it looks like now

The sweep runs `0x00`-`0x0e`, fifteen bytes, `SWEEP_BYTES` on `m1_ioboard`. It
stops one short of `0x0f` on purpose — that byte toggles on its own period in
the capture, so the board drives it outward and publishing control state over it
would model the wrong direction.

Idle is **not** uniformly `0xff`. The digital bytes are, because every control
is active low, but the ADC channels rest at `0x80` (steering centred) and `0x01`
per pedal. A blanket `0xff` idle reads as both pedals floored.

Steering takes the left analog stick, with the d-pad slamming to full lock —
which is what a digital steering input does on the cabinet. The pedals are
buttons: `hps_io`'s analog ports are two-axis sticks, so there is no pedal
travel to read, and a button giving full press is honest about that rather than
pretending to be analog.

### The MRA and the RTL have to be edited together

They disagreed. The MRA named joystick bit 4 `Start` while `Model1.sv` read it
as Coin, and the generic `names="Start,Coin,Service,Test,-,-"` covered four
controls where the game has twelve. A mismatch there is invisible until someone
presses a button, and then it looks like a protocol fault rather than a naming
one.

Both driving-cabinet MRAs now name the real panel, in the bit order the RTL
reads, following the System 32 core's convention of game buttons first and the
system ones after:

    Accel, Brake, Shift Up, Shift Down, VR1..VR4, Start, Coin, Service, Test

Coin 2 is wired to a bit but left off that list — a single-seat cabinet, and the
pad has run out of buttons. Test and service are OSD switches as well, since
they are things you set before boot rather than press during play.

### This is per-game, but barely

The DPRAM addresses are board hardware: IN.0/IN.1/IN.2 at `0x08`-`0x0a` and the
ADC at `0x00` upward, the same in every cabinet, because it is the same
315-5338A and the same `EPR-14869`. MAME carries six input maps across the ten
Model 1 game entries — `vf`, `vr`, `swa`, `wingwar`, `wingwar360`, `netmerc` —
and the *system* half of IN.0 is bit-identical in all of them:

| bit | 0 | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| | Coin 1 | Coin 2 | Test | Service 1 | Start 1 |

So coin, test, service and start — everything needed to reach a service menu —
are universal. Only the game buttons move, IN.1 is fully game-specific, and the
analog channel count varies from two (`netmerc`) to five (`swa`). That makes the
per-game part a mux on the bit packing, selectable from the MRA, rather than an
RTL change per title. Not worth building until there is a second game, and the
others need the TGP and the rasterizer first regardless.
