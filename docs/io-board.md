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

## Two ways to finish this, neither started

**Disassemble `EPR-14869`.** The ROM is in `vr.zip`. No Z80 disassembler is
installed; a table-driven one is a few hundred lines and would live in `tools/`.
The code that matters is whatever writes through registers `0x09`/`0x0a`, which
is findable without reading all 64 KB. This is what D9 costed as "the more work
of the two".

**Or run it.** A small Z80 interpreter plus a model of the 315-5338A above,
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

### Do not fix the arbitration yet — the shape is probably wrong

The obvious follow-up is to make the round-robin yield the port properly. That
is likely work on a mechanism this board does not want.

Continuous refresh was inferred from the 315-5338A's fast write to bytes 0-7.
But that path is the **Z80's** convenience for reaching the shared RAM through
the custom chip; it says something about how the Z80 talks to the chip, not
about how the V60 reads inputs. Those bytes may be status or DIP state.

What the trace shows points elsewhere. The V60 writes a command block, raises
the flag, and reads a 27-byte window **three times across an entire run, with no
polling loop**. That is request/response, not a mailbox somebody refreshes in
the background. If that is the shape, the responder should:

1. see the flag raised
2. read the command block
3. write a response — input state included — into the window
4. clear the flag

which is a burst triggered by the handshake, at a moment when the V60 is sitting
in a polling loop rather than driving the bus. **It would not contend for the
port at all**, and the starvation this experiment hit would not exist to fix.

So the mechanism and its 23 checks stay as scaffolding, off by default, and the
next move is to establish the protocol shape rather than to polish a refresh
loop that may be answering the wrong question.

What was NOT learned: where the inputs live. That question is untouched by this
result.

---

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
