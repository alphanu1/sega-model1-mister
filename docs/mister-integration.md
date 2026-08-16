# Putting a core on MiSTer: what actually bites

Everything here was paid for once, on hardware, with a board that showed a
blank screen or a frozen loading bar and no other output. None of it is
Model 1 specific — it is the framework, the toolchain and the SDRAM. Read it
before wiring up the next core.

The rule that generated most of this list: **a MiSTer core has exactly one
output channel, and it is the screen.** Everything else — no serial console, no
printf, no debugger — is absent. Plan for that on day one rather than after the
fifth twenty-five minute Quartus build that comes back "still white".

---

## The framework will deadlock you three different ways

### 1. `ioctl_wait` is wired straight to the HPS bus

`hps_io.sv` does `assign HPS_BUS[37] = ioctl_wait;`. It is not a private signal
between your loader and `hps_io` — it stalls the HPS itself.

So it must be gated on `ioctl_download`:

```systemverilog
assign ioctl_wait = ioctl_download & (~mem_ready | <buffer nearly full>);
```

Ungated, a `~mem_ready` term holds it from the instant the FPGA is configured
until SDRAM finishes JEDEC bring-up — about 125 µs at 80 MHz. MiSTer reads the
core's `CONF_STR` immediately after enabling the bridge, which lands inside that
window. It gets nothing, the core reports no name, and **the core never appears
to load at all**. The FPGA is running the whole time, which is what makes it
look like a dead bitstream rather than a handshake held low.

### 2. MiSTer holds the core in reset while it streams a ROM

If your SDRAM controller and ROM loader sit inside the game reset, then: the
loader asserts `ioctl_wait` until SDRAM is ready, SDRAM is never ready because
it is held in reset, and the HPS waits forever for a signal only the HPS can
release. On screen that is **"Assembling ROM" frozen partway with no error**.

Split the resets. The memory subsystem comes out of reset on PLL lock and stays
out:

```systemverilog
wire mem_rst_n = pll_locked;
wire rst_n     = pll_locked & ~(RESET | status[0] | buttons[1]);
```

### 3. One signal must not mean two things

This one cost a whole evening. A core port named `rom_loaded` fed both the
loader's `mem_ready` ("SDRAM can accept a write") and the CPU's release ("a ROM
has arrived"). Those are different facts. Gating the CPU by feeding that port
`mem_ready & <the loader's own done flag>` closes a loop:

- the loader holds `ioctl_wait` while `~mem_ready`
- `mem_ready` is now false until the loader finishes
- the loader cannot finish, because the HPS is stalled on `ioctl_wait`

Zero bytes transferred, forever, and the same frozen loading bar as fault 2 —
which is what made it look like a regression of something already fixed.

**Derive the CPU's release inside the core from the loader's own output.** Never
route it out to the top level and back in.

### `ioctl_wait` does not stop the host — it asks it to

Everything already in flight still arrives. `FIFO_DEPTH - WAIT_MARGIN` is
exactly how many of those you can absorb before words start being discarded,
silently.

At depth 8 with margin 6 the buffer tolerated **15 cycles** of host reaction and
dropped words at 16 — 200 ns at 80 MHz, well inside a single HPS bus round trip.
A dropped word is a ROM with holes in it, reported as a *successful* load, that
crashes the CPU much later looking like a core bug.

Two lessons, and the second is the bigger one:

- Size the buffer for microseconds of host latency, not cycles. 512/256 gives
  about 3.2 µs and costs two M10K.
- **The test swept host latency 0..6, which was the margin the parameter was set
  to.** It confirmed the setting instead of testing it. Sweep an order of
  magnitude past what you believe, or the test is decoration.

---

## Clocking

### Use the generated PLL IP, and name it `pll`

`sys_top.sdc` puts every core PLL output into one clock group by matching a
hierarchy pattern:

```tcl
-group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
```

A hand-instantiated `altera_pll` does not produce the `altera_pll_i` level, so
the clocks match nothing, fall outside every group, and get timed against the
audio PLL. Result: **−87 ns of setup slack, a build that reports success, and
nothing running on hardware.**

An empty `get_clocks` makes `set_clock_groups` a silent no-op, so check it:

```tcl
set sys_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]
if {[llength $sys_clk] == 0} { post_message -type error "clocks not found" }
```

The IP also brings `PLL_AUTO_RESET ON` and direct compensation mode. Without
auto-reset, a PLL with `rst` tied low that misses lock once never locks again.

### Multiple core clocks land in the same group

Being in one group means they are timed *against each other*, which is wrong if
they are asynchronous by construction. Cut them explicitly, by their real names.

### The framework does not constrain SDRAM at all

`sys_top.sdc` has nothing about SDRAM. `sys/sys.tcl` provides the pin locations
and the I/O settings that matter — `FAST_OUTPUT_REGISTER`,
`FAST_INPUT_REGISTER`, `CURRENT_STRENGTH_NEW "MAXIMUM CURRENT"` — but no timing.
`assign SDRAM_CLK = ~clk_sys;` is the common idiom and works, but nothing in the
tool checks it. Know that this is unconstrained before you spend a day
suspecting it.

---

## Quartus 17.0 will silently build memory out of flip-flops

This is the single most expensive failure mode on this device. Inference fails
*quietly* — the fitter reports success and you lose the device.

Measured, not assumed:

| Idiom | Result |
|---|---|
| `mem[a][7:0] <= d[7:0]` byte enables | zero M10K, built from registers |
| two byte-wide arrays, plain write enables | infers immediately |
| two write ports (true dual port) | zero M10K — 192 ALM became 16,059 |
| same, with `no_rw_check` | still zero M10K |
| reset loop clearing the array | forces registers — it is a second write port |
| dual clock, one write one read | fine: 32768×8 → 32 M10K, 37 ALM |

Rules that follow:

- Split every memory into byte lanes with plain write enables.
- Put an explicit `(* ramstyle = "M10K" *)` on anything that matters, so a
  regression is a build error instead of a resource catastrophe.
- **Never clear an array in reset.** Pointers make the contents unreachable.
- Test a memory idiom at 1024 entries. It answers in thirty seconds what hours
  of full-size builds will not.
- Simulation cannot see any of this. Verilator has no opinion about whether
  storage lands in RAM.

Also: Quartus 17.0 rejects `for (genvar i = ...)` in the loop header, which is
legal SystemVerilog. Declare the genvar outside.

And: when testing a Quartus change, re-run `quartus_map`, not just `quartus_fit`
— a fit-only rerun reuses the previous netlist and will happily report success
for a setting that actually breaks the build.

---

## Make the screen an instrument

**`docs/debug-overlay.md` is this core's implementation**, with what every row
means and what it costs. Measured, on a 5CSEBA6U23I7: **307 ALM, 553 registers,
zero M10K** — under a third of a percent of what the core uses, and it did not
cost timing. Cheap enough to keep in every build, behind a compile-time switch
for the one that ships.

Since the screen is the only channel, put data on it deliberately. `m1_diag`
paints 32-bit words as eight hex digits in a 5x7 font at 2x, which a phone
camera resolves without argument.

It did not start that way. The first version drew 32 blocks per word with a
green rule every four bits, and it worked — but reading it means locating a cell
boundary to a few pixels in a photograph of an LCD, and a camera against a
screen produces moire on exactly an 8-pixel pitch. Three values were misread
that way in one session, twice sending the next experiment after the wrong
subsystem. **An instrument that is hard to read is a source of wrong answers,
not a defence against them.** Render digits.

It works, and it paid for itself immediately: a photo showed `ioctl_wait`
asserted with the buffer empty, nothing pending and the controller reporting
ready, which leaves exactly one term in that expression that can be true. That
is what found deadlock 3 above.

What to show, roughly in order of value:

1. CPU program counter — parked or moving, and where.
2. Words the host sent, against words that reached memory. Equal means the ROM
   arrived intact; a shortfall names a dropped-word bug directly.
3. The first instruction fetch: its address and the word that came back.
   Separates "memory returns nothing" from "the fetch went to the wrong place",
   which are the two ways to end up executing garbage.
4. Status flags: halted, trap, ROM-ready, memory-ready, overflow.
5. Free-running counters for each memory port — whichever one stops moving is
   the subsystem that died.

Lessons on the instrument itself:

- **Tag every row with its own index.** Tagging only some rows made the row
  numbering ambiguous in a photograph and cost a round trip.
- Cells changing during the camera exposure show as stripes rather than solid
  colour. That is free information: it tells you which counters are live.
- Keep it out of the game reset. An overlay held in reset leaves `VGA_DE` low
  and draws nothing during exactly the part of startup worth watching.
- Verify it exhaustively — 761,856 checks here, every cell against the bit it
  claims to show. An instrument that lies sends the next session after the wrong
  subsystem.

---

## Testing against the board

- **Reboot before every load test.** A core that fails to load leaves the MiSTer
  stalled, and any load attempted after that reports whatever the stalled state
  holds. A control experiment run that way proves nothing.
- `/tmp/CORENAME` is the reliable indicator of what is running.
  `/sys/class/fpga_manager/fpga0/state` reads `operating` regardless, and the
  per-core file in `/media/fat/config/` is not written on load, so neither
  distinguishes success from failure.
- Load with `echo "load_core /media/fat/_Arcade/<name>.mra" > /dev/MiSTer_cmd`.
- MiSTer drives the FPGA manager through `/dev/mem`, so the **absence of a
  `dmesg` entry means nothing** about whether configuration was attempted.
- The `screenshot` command produced no file on this build; do not plan on it.

---

## Simulate what hardware actually does

The largest single lesson of the whole exercise.

The frame test poked the ROM image straight into the SDRAM model before the run.
That is fast and it isolates the CPU, but it means memory is **already correct
at the instant the CPU is released** — a condition hardware never provides. A
reset-sequencing fault sat in the top level while every simulation passed.

Fixes that made simulation able to find real bugs:

- Stream the ROM through `ioctl` into the real loader, through the real
  controller, with the video path fetching concurrently.
- Make unwritten memory read `0xFFFF`, not zero. Zero is a legal instruction, a
  legal tile number and a black palette entry, so a core let loose on empty
  memory looks far healthier in simulation than on a board.
- Use the board's real clock frequencies, not round numbers. Asynchronous domain
  cuts mean nothing between domains is ever timed, so a ratio-sensitive crossing
  passes at 4.000 and fails at 4.167.
- **Add a stall detector.** A hang that never returns says only "something is
  wrong". One that prints every signal capable of holding the handshake, then
  fails loudly, is a diagnosis. Make it `$fatal` — a stalled run exiting zero is
  a test reporting success for a core that cannot load a ROM.
- Flush progress output. `$display` to a redirected file is block buffered, so a
  hung run prints nothing and is indistinguishable from a slow one.

---

## Debugging discipline that worked

- **Control experiments split build-flow faults from design faults.** Building
  the stock template and loading it, then the template plus our PLL, localised a
  failure that neither reasoning nor staring at code had.
- **Reproduce off-hardware before fixing.** Every fix in this list that stuck was
  first made to fail in simulation. Every theory that died — refresh deadlock,
  arbiter starvation, double acknowledge, SDRAM read timing — died on contact
  with the code or with a measurement, and would have cost a build each to test
  on the board.
- **Acknowledges must be held, not pulsed**, for anything talking to a `ce`-gated
  requester. A one-cycle pulse is missed and the requester waits forever. This
  bit twice, and both times it looked like a dead CPU rather than a handshake
  fault.
- Check the obvious cheap thing first. Two hypotheses were disproved for free by
  reading `sys.tcl` and `hps_io.sv`, and one by noticing a `grep` had run in the
  wrong directory.
