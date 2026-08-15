# M3 rasterizer — what the hardware does, read out of MAME

Written 2026-08-15, ahead of the sizing spike that is handoff item 1. Every rule
below is transcribed from `third_party/mame/src/mame/sega/model1_v.cpp` with line
references, per hard rule 3. Where MAME's own comments show it deviating from
silicon deliberately, that is called out rather than smoothed over.

This is a specification, not an implementation plan for correctness bring-up. The
plan's discipline rule stands (`docs/m1-m4-plan.md`): the rasterizer is not
debugged against real content until the M2 geometry diff is clean, because
rasterizer bugs chased before that turn out to be geometry bugs in disguise. What
this document enables is the *measurement* — build the real datapath, synthesise
it, and close the ±3,000 ALM uncertainty in the budget.

---

## The primitive is a quad, and it is always four vertices

`quad_t` (`model1.h:80`) is four `point_t*`, a `float z` and an `int col`. The
rasterizer sees only the projected screen coordinates `p->s.x`, `p->s.y`
(`spoint_t`, two `int32_t`, `model1.h:68`), already integer: projection happens
upstream in `project_point` (`model1_v.cpp:79`), which divides by z and applies
zoom, viewport centre and translation.

**There is no triangle path.** The frustum clipper emits quads in every case; a
clipped triangle is a quad with the last vertex repeated —
`fclip_push_quad_next(level, q, pi1, pt[3], pi2, pi2)` at `model1_v.cpp:758`. So
the fill unit can assume four vertices with no primitive-type input, and
degeneracy is data rather than a mode.

That is a convenient invariant for RTL: one datapath, no primitive decode.

## Ordering: painter's algorithm, and the sort is in this stage

`draw_objects` (`model1_v.cpp:1306`) calls `sort_quads()` and then
`draw_quads()`. The sort is a full `qsort` over every quad accumulated since the
last flush (`model1_v.cpp:550`), with the comparator at `model1_v.cpp:535`:

- primary key **z descending** — far quads paint first, near ones over the top;
- tie-break on **submission order ascending**, via the pointer difference. So the
  order is total and deterministic, not merely "whatever qsort did".

No Z-buffer anywhere. Model 1 paints back to front, and that omission is what
makes the whole design fit.

Two flush paths, and they differ:

| path | order | code |
|---|---|---|
| 3D objects | sorted, as above | `draw_objects`, `model1_v.cpp:1306` |
| direct (2D-projected) polys | **unsorted**, submission order | `draw_direct` → `unsort_quads`, `model1_v.cpp:1320` |

`draw_direct` flushes the pending sorted batch first, then pushes and draws the
direct polys unsorted. Both then reset the quad pointer. So the frame is a
sequence of batches, each internally either sorted or not, and batch boundaries
come from the display-list walker.

Per-quad z is not a computed depth. `push_object` selects it from bits 11:10 of
the polygon flags (`model1_v.cpp:1028`): keep the previous quad's z, the minimum
of the four vertex z values, the maximum, or zero.

**This contradicts D3.** That entry's premise is "the TGP already depth-sorts the
polygon list. Binning that sorted list into horizontal bands is close to free."
MAME shows the sort happening *after* the display list is walked, in the
rasterizer stage, over quads the list walker built — and MAME allocates a
1,000,000-entry quad database (`model1_v.cpp:1729`), so there is no small fixed
cap to design against. Which physical chip does this on the real board is not
identified: the video board's customs (315-5422/5423/5424/5425, 315-5483/5484,
315-5485/5486) are unlabelled in the driver header and MAME models none of them.

A band renderer needs the frame's quads in final paint order before it can bin
them, so the cost of producing that order is now part of the rasterizer's budget
rather than assumed away. **Measure the quad count per frame from the M2 capture
before committing to a sorting structure** — that number decides between an
insertion into per-band lists, a hardware merge sort, and a bucketed
approximation. It is also the number that tells us whether D3's reversal
condition has been met.

## The fill rule, exactly

`fill_quad` at `model1_v.cpp:282`.

**Coordinates.** x is carried in 16.16 fixed point (`FRAC_SHIFT = 16`,
`model1_v.cpp:20`): `p[i].x = q.p[i]->s.x << 16`. y stays an integer scanline
index. Vertices are loaded into an eight-entry array with `p[i] = p[i+4]`
(`model1_v.cpp:330`) so the two edge chains can walk in opposite directions from
the top vertex without wraparound logic.

**Setup.** Find `pmin` (lowest y) and `pmax` (highest y) over the four vertices.
Start both chains at `pmin`: `ps1 = pmin+4` walking down through decreasing
index, `ps2 = pmin` walking up through increasing index. At every vertex event,
skip any further vertices sharing the current y, then compute that edge's slope
(`model1_v.cpp:415`):

    sl = (x_here - x_next) / (y_here - y_next)

That is C integer division of a 16.16 numerator by a scanline count —
**truncating toward zero, not floor**. Getting that wrong is a one-LSB drift per
scanline, which is exactly the kind of thing a frame diff catches late and
expensively.

**Walking.** `fill_slope` (`model1_v.cpp:118`) covers `[y1, y2)` — top inclusive,
bottom exclusive — emitting one span per scanline and then `x1 += sl1; x2 +=
sl2`. The final scanline at `limy` is drawn separately by `fill_line`
(`model1_v.cpp:451`). Spans are inclusive at both ends: `while(x1 <= x2)`
(`model1_v.cpp:98`).

**Left/right.** Per `fill_slope` call, if `x1 > x2`, or x is equal and `sl1 >
sl2`, the two edges swap — x, slope and output pointer together
(`model1_v.cpp:146`). This is per segment, not once per quad.

**Clipping.** Against the viewport rect, all inclusive:

- `y2 <= view->y1`: advance both x by `delta * sl` and emit nothing
  (`model1_v.cpp:125`);
- `y1 < view->y1`: skip forward the same way, then start at `view->y1`;
- `y2 > view->y2`: clamp to `view->y2 + 1`;
- x: clamp `xx1`/`xx2` into `[view->x1, view->x2]`. The guard at
  `model1_v.cpp:167` is an `||` where `&&` was clearly meant, but it is harmless
  — a fully off-screen span clamps to `xx1 > xx2` and the inclusive loop then
  emits nothing. Reproduce the *behaviour*, not the expression.

**Flat quads.** If all four vertices share one y (`cury == limy`,
`model1_v.cpp:352`), the whole primitive is one `fill_line` from the minimum to
the maximum x of the four vertices, and nothing else runs.

## Degenerate primitives

**Wireframe.** A quad with exactly two distinct screen vertices is a wire, and
MAME rasterizes it as a clipped Bresenham line instead of filling it
(`model1_v.cpp:297`, `draw_wireframe_line` at `model1_v.cpp:227`), with a
Liang-Barsky clip in doubles before the walk.

MAME's own comment says why: through the scanline filler a near-horizontal wire
collapses to one pixel per row (the Star Wars Arcade target box), and an
unclipped degenerate projection produced a ~2^31-pixel walk that hung Wing War
during boot. **This is MAME improving on what the filler does, not a description
of silicon.** Real hardware plausibly does collapse those wires. The M3 exit
criterion is a frame diff against MAME, so match MAME to pass it — but record
that this specific behaviour is unverified against a board, and do not treat the
line unit as proven hardware.

## Colour, and the moiré flag

`col` is a finished 24-bit RGB888 value by the time the rasterizer sees it
(`model1_v.cpp:1087`), not a palette index. Everything that produces it —
diffuse and specular lighting from the vertex normal, the luma index, the
`m_color_xlat` translation tables, the per-frame channel rotation for blinking UI
elements, the unlit flat-UI mode from bit 10 of the tile word — happens upstream
in `push_object` and belongs to M2.

Bit 24 is `MOIRE` (`model1_v.cpp:21`). A span drawn with it set writes only
pixels where `((x ^ y) & 1) == 0` (`model1_v.cpp:105`) — a checkerboard stipple
standing in for transparency. In RTL that is a write mask on the span, near free.
It is set from bit 13 of the polygon flags (`model1_v.cpp:1090`).

A negative `col` only selects a debug logging path (`model1_v.cpp:287`); there is
nothing to implement.

`scale_color` and `draw_line` are both inside `#if 0`. Dead code — do not port.

## What the RTL therefore is

    quad in  ->  vertex y-sort (4 entries)
             ->  edge-event FSM (two chains from the top vertex)
             ->  integer divider, one slope per edge event
             ->  two 16.16 DDA accumulators, +sl per scanline
             ->  span emit [x1>>16, x2>>16] inclusive, moiré mask
             ->  band buffer write port

No per-pixel arithmetic at all, which is the headline: the cost is in the
dividers and in the band buffer, not in a fill ALU. Setup runs once per edge
event — at most four per quad — so a **sequential** divider is probably
sufficient, and that is the first thing the spike should measure rather than
assume.

Sizes at 496x384: screen x needs 10 bits, y 9 bits, and the 16.16 accumulator 32.
D3's band buffer is 496 x 64 x 16bpp, about 51 M10K against 553 total with 332
already spent — so the pixel format is a resource decision, not just a colour
one. The existing 2D path carries RGB888 out of `m1_palette`, and the source
palette entries are xBGR-555, so 16bpp in the band buffer costs nothing in
fidelity.

## What the spike measures

1. ALM and Fmax for setup + span walk, with the divider structure varied.
2. M10K for the band buffer at the chosen pixel format, on top of the 332 spent.
3. Whether the `S32_V60_NO_FP` lever has to be spent — the budget question this
   whole exercise exists to answer.

Ship the testbench in the same change (hard rule 5): drive quads, compare emitted
spans against a C model transcribed from `fill_quad`, in the shape of
`sim/video/tb_m1_video.cpp`.

## Open questions this document does not settle

- **Where the depth sort lives on real silicon**, and how many quads a frame
  actually carries. Both need the M2 capture. D3 rests on the answer.
- **Whether wireframe primitives really get a line unit**, or collapse. Needs a
  board, or a game whose output MAME itself gets wrong.
- **Whether a quad spanning several bands is re-walked per band** or has its edge
  state saved and resumed. Re-walking is simpler and costs setup twice; saving
  costs storage per in-flight quad. Cheap to decide once the quad count is known.
- **Sub-pixel origin.** MAME shifts an already-integer screen coordinate up by 16,
  so the fractional part is always zero at the vertices and accumulates only
  through the slopes. If real hardware projects to sub-pixel precision, edges
  would land differently — invisible in a MAME diff, visible against a board.

## Corrections this makes to existing documents

- `docs/HANDOFF.md` item 1 describes "a flat-shaded triangle path — setup, edge
  functions, span fill". The primitive is a quad, and the filler is an
  edge-walking DDA, not an edge-function rasterizer. Those size differently:
  edge functions put multipliers in setup and adders in every pixel, this puts
  dividers in setup and nothing in the pixel.
- `docs/00-decisions.md` D3 assumes the polygon list arrives depth-sorted. See
  above.
- `docs/m1-m4-plan.md` M2 work list still says to instantiate the 315-5571 and
  315-5572 geometrizers alongside the copro. D4 was reversed on 2026-08-15 —
  one instance.
