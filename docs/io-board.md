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

### What is owed

Decode the request payload the trace captured — `1c 82 01 00 3e 9d ff 00 ...` at
`0x100` — and the response the Z80 builds for it, then write that response from
`m1_ioboard`. The primitives are known, the addressing convention is known
(BC holds the DPRAM address, B low and C high), and the call sites are
enumerated. What is not known is the *content*.

**Three experiments have now each disproved a plausible layout.** The pattern is
that reading the ROM says what the Z80 does, and the trace says what the V60
does, and only where they agree is anything established. Prefer the experiment
that can falsify the next guess over the one that would confirm it.

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

They are wired and unused until the response format above is known. That is
deliberate: the signals existing costs nothing and removes a step from whatever
comes next.
