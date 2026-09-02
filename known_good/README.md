# KNOWN GOOD — confirmed working on the board

**Commit:** `61e383e` — "SEED 5 closes the clipper build: -0.142 to +0.061 on the same RTL"
**Built:** 2026-09-02 01:35, Quartus 17.0, `M1_SEED=5`
**Confirmed on hardware by Ben, 2026-09-02.**

    Model1.rbf      md5 54ea8d51f3047b55982480e1e6813518
    ALM             41,391 / 41,910 (99%)
    setup slack     +0.061 ns
    errors          0

## What it contains

Everything up to and including the frustum clipper: the V60, SDRAM controller,
the whole 2D path, the TGP, the geometry pipeline and the band rasterizer.

It does **not** contain the 2026-09-01 work — the data cache, posted writes, the
FP pipelining or the display-list cap. Those are committed (`1af3a77..7418cfd`,
pushed to origin) but none of them has yet been confirmed working on hardware.

## Flash it

    scp known_good/Model1.rbf root@192.168.1.105:/media/fat/_Arcade/cores/Model1.rbf
    ssh root@192.168.1.105 'md5sum /media/fat/_Arcade/cores/Model1.rbf'   # must match the .md5 file

Then reboot the board, wait for `/tmp/CORENAME` to read `MENU`, and issue exactly
one load — see the reboot-before-load rule in the session notes.

## Rebuild it from scratch

    git worktree add -f build/wt61 61e383e
    ln -sfn "$PWD/third_party" build/wt61/third_party
    cd build/wt61 && M1_SEED=5 make rbf

`third_party/` is gitignored, so the worktree needs the symlink or nothing will
elaborate.

## Read the board's own speed

    ssh root@192.168.1.105 "stty -F /dev/ttyS1 115200 raw -echo; cat /dev/ttyS1"

ttyS1, NOT ttyS0 — ttyS0 is the physical USB header and nothing is plugged into
it. Capture for at least five minutes: the game takes about four to reach steady
state, and `S` is only meaningful while `P` is non-zero (3D actually drawing).
