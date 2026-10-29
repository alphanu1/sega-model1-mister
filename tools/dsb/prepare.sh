#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Inputs for the Star Wars Digital Sound Board benches, into build/rom/dsb/
# (gitignored -- ROM-derived, never committed):
#
#   epr-16471.2    the DSB Z80 program (tb_dsb_board)
#   epr-16471.hex  its first 32 KB as hex (tb_dsb_z80, which also runs tv80s)
#   mpeg.bin       mpr-16514.57 + mpr-16515.58, 4 MB (tb_dsb_mpeg, tb_dsb_board)
#   cap300.txt     MAME's own 300 s of the board's traffic (tools/mame_dsb_cap.lua),
#   z80.asm        and MAME's disassembly of the Z80 program (for
#                  tools/dsb/z80_census.py), only when MAME=1 -- headless,
#                  about three minutes
#
#   tools/dsb/prepare.sh ~/roms/swa.zip [MAME=1]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
zip="${1:?usage: prepare.sh <swa.zip>}"
out="$here/build/rom/dsb"
mkdir -p "$out"
tmp="$(mktemp -d "$here/build/tmp/dsb.XXXXXX")"
unzip -q -o "$zip" epr-16471.2 mpr-16514.57 mpr-16515.58 -d "$tmp"
cp "$tmp/epr-16471.2" "$out/"
cat "$tmp/mpr-16514.57" "$tmp/mpr-16515.58" > "$out/mpeg.bin"
python3 -I -c "import sys; d=open(sys.argv[1],'rb').read()[:32768]; open(sys.argv[2],'w').write('\n'.join('%02x'%b for b in d)+'\n')" \
  "$out/epr-16471.2" "$out/epr-16471.hex"
rm -rf "$tmp"
md5sum "$out/epr-16471.2" "$out/mpeg.bin"
if [ "${MAME:-0}" = 1 ]; then
  ( cd "$here/build/tmp" && DSBCAP_SECS=300 DSBCAP_COIN=150 DSBCAP_OUT="$out/cap300.txt" \
    mame swa -rompath "$(dirname "$zip")" -video none -sound none -nothrottle \
      -skip_gameinfo -autoboot_delay 0 -autoboot_script "$here/tools/mame_dsb_cap.lua" >/dev/null )
  wc -l "$out/cap300.txt"
  printf 'local d=false\nemu.register_frame_done(function() if d then return end d=true\n manager.machine.debugger:command("dasm %s,0,8000,1,:dsbz80:mpegcpu")\n manager.machine:exit() end)\n' \
    "$out/z80.asm" > "$here/build/tmp/dsb_dasm.lua"
  ( cd "$here/build/tmp" && mame swa -rompath "$(dirname "$zip")" -video none -sound none -nothrottle \
      -skip_gameinfo -debug -debugger none -autoboot_delay 0 -seconds_to_run 2 \
      -autoboot_script "$here/build/tmp/dsb_dasm.lua" >/dev/null )
  python3 -I "$here/tools/dsb/z80_census.py" "$out/z80.asm" | tail -1
fi
