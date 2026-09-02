-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 1 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
--
-- HOW MUCH OF THE TGP DISPLAY-LIST BUFFERS DOES THE GAME ACTUALLY USE?
--
-- rtl/m1_mainram.sv gives each of the two buffers the architectural 32,768
-- words (0x600000-0x60ffff and 0x610000-0x61ffff), which is 104 M10K of the
-- 553 on the device - and M10K is 100% spent, so it is the one place a data
-- cache could come from. Truncating them blind would ALIAS real writes, so
-- the question is what the program touches, not what the map allows.
--
-- Taps writes to both buffers and reports the highest word offset seen.
local mac = manager.machine
local cpu = mac.devices[":maincpu"]
local sp  = cpu.spaces["program"]

hi0, hi1, n0, n1 = -1, -1, 0, 0     -- GLOBAL: a local is collected and the tap dies

tap = sp:install_write_tap(0x600000, 0x61ffff, "dlext", function(offset, data, mask)
  local off = offset - 0x600000
  if off < 0x10000 then
    local w = off >> 1
    n0 = n0 + 1; if w > hi0 then hi0 = w end
  else
    local w = (off - 0x10000) >> 1
    n1 = n1 + 1; if w > hi1 then hi1 = w end
  end
  return data
end)

frames = 0
sub = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if frames % 600 == 0 then
    print(string.format("frame %d: dl0 max word 0x%04x (%d writes), dl1 max word 0x%04x (%d writes)",
                        frames, hi0, n0, hi1, n1))
    io.stdout:flush()
  end
end)
