# M1 — M4

M0 is specified separately in `m0-mb86233-spike.md`. Nothing below starts until the M0
resource gate reports.

---

### M1 baseline, measured 2026-08-14

Reproduced before writing anything, per the plan's own warning not to assume an
imported core is a solved problem.

**Unit suite** (`third_party/s32/verif/v60/run_v60_verilator.sh`):
**22 passed, 6 build-failed.** All six failures are the Icarus white-box tests,
and none is a core fault — Icarus 13.0 refuses to compile `s32_v60.sv` at all:

```
rtl/cpu/v60/s32_v60.sv:1317: error: This assignment requires an explicit cast.
  ea_len <= 5'd1 + disp_len(modtop[1:0]);
```

21 sites, all the same shape: a function result used in arithmetic without an
explicit width cast. Verilator accepts it; Icarus 13 does not. This is the same
class of problem as the yosys strictness issues found in M0 — code that passes
one toolchain and not another — and it wants the same fix, an explicit cast at
each site. It belongs in **our** copy once the V60 is imported into `rtl/`,
because `third_party/` is gitignored and re-cloned by `bootstrap.sh`, so a
patch there would not survive.

**The real M1 risk is timing, not correctness.** s32's own baseline records:

| | s32 V60 | MAME |
|---|---|---|
| CPI, attract gameplay | **22.70** | flat 8 |
| work vs idle, char select | 42% work | 15% work |
| FSM state distribution | **S_FILLW 40%, S_FILL 16%** | — |

56% of all cycles sit in fetch. A prefetch redesign was in progress upstream
targeting CPI ~10-12, but `docs/v60-prefetch-plan.md` is **not present** in the
vendored tree — only the baseline that references it. So that work either did
not land or is not published, and M1 should budget for doing it rather than
inheriting it.


## M1 — V60, bus, 2D subsystem, boot

**Work**

- Import the V60 from meathax's System 32 core (`third_party/s32/rtl/cpu/v60/`, 4.5k
  lines). Strip the System 32 profile down to what Model 1 uses: no MMU paging, no FP
  group.
- **Do not write a V60 test suite from scratch.** s32 already ships one:
  `verif/v60/` holds ~35 directed testbenches with a documented pass baseline
  (26 passed / 0 failed as of 2026-07-23), `verif/cosim/` has a differential harness
  against a Python reference plus a MAME trace instrumentation patch, and
  `verif/quartus_v60/area/` is a standalone Cyclone V area project targeting the same
  5CSEBA6U23I7 part. Read `verif/v60/BASELINE.md` first and re-baseline against it.
- The author's own note is that the V60 still needs work for correct timing, and
  BASELINE.md quantifies it: ~22.7 cycles/instruction against MAME's flat 8, with 56%
  of all cycles sitting in fetch states. A prefetch redesign was in progress. Budget for
  that work landing, or for doing it. Do not assume an imported core is a solved problem.
- MiSTer framework skeleton, MRA ROM loader, SDRAM controller with a per-master
  arbiter.
- 315-5465 address decode and interrupt logic. 315-5338A input block.
- Tilemap/text layer, palette RAM, priority mixer. No 3D path at all in this milestone.
- **Instrument the arbiter now.** Per-master cycle counters dumped to the HPS. This is
  how D2 and D3 get validated with numbers instead of arithmetic, and it costs almost
  nothing to add at this stage versus retrofitting during M3.

**Exit**

- ROM checksum self-test passes
- Text layer renders
- Service/test menu navigable via real inputs
- Bandwidth telemetry reporting sane per-master figures against the M1 traffic mix

---

## M2 — Geometry pipeline

**Work**

- Instantiate 315-5571 and 315-5572 geometrizers plus the game copro, starting with
  315-5573 (Virtua Racing). Load the decapped microcode.
- MB8421 dual-port mailboxes. 315-5464 copro/TGP glue. Command and result FIFOs,
  including the output FIFO at 0x400 that the +0x200 EA adder reaches.
- Terminate the output FIFO into a capture stub that DMAs polygon lists to the HPS.

**Exit**

- Captured polygon list stream matches MAME's, frame for frame, across a Virtua Racing
  cold boot into attract.

**Discipline:** do not start the rasterizer until that diff is clean. Every rasterizer
bug chased before this point will turn out to be a geometry bug wearing a disguise.

---

## M3 — Rasterizer and video

**Work**

- Band binning pass over the TGP's already-sorted polygon list.
- Edge-walking span filler, flat shaded, into a 64-line M10K band buffer.
  No Z-buffer: Model 1 depth-sorts in the TGP and paints back to front. That omission
  is what makes the fit possible at all.
- Band writeback and scanout. Framebuffer in SDRAM per D3; f2h DDR3 is the documented
  fallback.
- 496x384 at 24 kHz out the analog path, plus the scaler chain for HDMI.

**Exit**

- Virtua Racing attract renders correctly
- Frame image diffs against MAME within tolerance on a fixed input script
- **Profile Virtua Fighter worst-case overdraw against the M1 telemetry.** This is the
  specific case that could still force D2 to reverse. Measure it before declaring
  single-module support.

---

## M4 — Sound, inputs, full set

**Work**

- Sound board: 68000 at 10 MHz, YM3438 (ikaOPN2), 2x MultiPCM 315-5560.
- **MultiPCM is the open risk in this milestone.** It is an OPL4 derivative with the FM
  side removed, 28 PCM channels, and there is no proven MiSTer implementation to lift.
  Treat it as a mini-M0: build it standalone, verify against MAME, gate on resources
  before integrating.
- Analog input paths: wheel and pedals for Virtua Racing and Virtua Formula, flight
  stick for Star Wars Arcade and Wing War.
- Per-game copro ROM switching across 315-5573, 315-5711 and 315-5724. MRA set for all
  six titles.

**Exit**

- Virtua Racing, Virtua Formula, Virtua Fighter, Wing War, Star Wars Arcade and NetMerc
  all playable with sound.

---

## Standing risks

| Risk | Milestone | Mitigation |
|---|---|---|
| TGP area overrun | M0 | Context-multiplexed datapath fallback; kill criteria defined |
| Denormal semantics unknown | M0 | Resolve against real microcode traces, not host floats |
| V60 timing accuracy | M1 | Directed tests before integration, not after |
| Rasterizer customs undocumented | M3 | Geometry diff must be clean first so bugs localise |
| VF overdraw exceeds bandwidth | M3 | f2h DDR3 framebuffer before demanding dual SDRAM |
| MultiPCM has no prior art | M4 | Standalone spike with its own gate |
| Stale ROM definitions | all | Pull current MAME sets; 315-5711 carried two bit corruptions until recently |
