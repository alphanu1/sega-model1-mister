# Scripted inputs for tb_m1_frame

A fresh simulation always boots into the game's settings menu, because the
backup RAM starts blank. Nothing could get past it until 2026-09-09, so no bench
run had ever reached gameplay — and a captured frame of that menu was once
mistaken for a broken renderer.

    make m1_frame GAME=vr FRAME_CYCLES=1100000000 FRAME_PPM=25

`INPUTSCRIPT` defaults to `build/input_script.txt`; copy one of these over it.
`FRAME_PPM=N` writes a PPM every N frames into `build/frames/`, which `ffmpeg`
will assemble.

Format, one step per line, `#` comments and blank lines ignored:

    <cycle> <IN.0> <IN.1> <IN.2> [accel]

All ACTIVE LOW except `accel`, which is `01` released to `ff` full — MAME's
`PORT_MINMAX(1,0xff)`. Each line takes effect at `<cycle>` and holds until the
next. Cycles are **80 MHz `clk_sys`**, not CPU cycles: one video frame is about
1.39 M.

**Hold a press for longer than the capture interval.** A first sweep used
presses shorter than it and could not have detected a working button at all.

| file | reaches |
|---|---|
| `vr_race.txt` | Virtua Racing's pit start, crew animating, HUD live |
| `vf_match.txt` | Virtua Fighter, AKIRA vs JACKY, ROUND 1 — and reproduces the tiny-arena bug |

`VR1` (IN.0 bit 5) works Virtua Racing's settings menu. It was found by sweeping
every candidate with frame capture running and seeing which press changed the
screen, not by guessing.
