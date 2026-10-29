-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- STAR WARS' DIGITAL SOUND BOARD, ITS WHOLE CONVERSATION, HEADLESS.
--
-- Logs, with emulated time in seconds:
--   V60 xx      bytes the V60 sends the sound board (0xc40000)
--   TX xx       bytes the sound 68000 transmits (0xc20000) -- the DSB's ONLY input
--   TXC xx      the 68000's UART control writes
--   ZW pp xx    the DSB Z80's port writes (0xe0-0xf1)
--   ZR pp xx    its port reads, except the status port 0xf1
-- and at the end the Z80 RAM footprint (it clears all 32 KB at boot).
--
-- Run HEADLESS, never with a window:
--   DSBCAP_SECS=300 DSBCAP_COIN=150 DSBCAP_OUT=cap.txt \
--   mame swa -rompath ~/roms -video none -sound none -nothrottle \
--        -skip_gameinfo -autoboot_delay 0 -autoboot_script tools/mame_dsb_cap.lua
local OUT = os.getenv("DSBCAP_OUT") or "dsbcap.txt"
local SECS = tonumber(os.getenv("DSBCAP_SECS") or "240")
local f = io.open(OUT, "w")
local m = manager.machine
local function t() return m.time:as_double() end
local v60 = m.devices[":maincpu"].spaces["program"]
local snd = m.devices[":m1audio:sndcpu"].spaces["program"]
local zio = m.devices[":dsbz80:mpegcpu"].spaces["io"]
local zpg = m.devices[":dsbz80:mpegcpu"].spaces["program"]
local wrote = {}
local ramw, ramr_unw = 0, 0
local unw = {}
local minw, maxw = 0xffff, 0
taps = {}
taps[#taps+1] = v60:install_write_tap(0xc40000, 0xc40001, "v60snd", function(o, d, mk)
  f:write(string.format("%.9f V60 %02x\n", t(), d & 0xff)); return d end)
taps[#taps+1] = snd:install_write_tap(0xc20000, 0xc20003, "68ktx", function(o, d, mk)
  if o == 0xc20000 then f:write(string.format("%.9f TX %02x\n", t(), d & 0xff))
  else f:write(string.format("%.9f TXC %02x\n", t(), d & 0xff)) end
  return d end)
taps[#taps+1] = zio:install_write_tap(0xe0, 0xf1, "zw", function(o, d, mk)
  f:write(string.format("%.9f ZW %02x %02x\n", t(), o & 0xff, d & 0xff)); return d end)
taps[#taps+1] = zio:install_read_tap(0xe0, 0xf1, "zr", function(o, d, mk)
  if (o & 0xff) ~= 0xf1 then f:write(string.format("%.9f ZR %02x %02x\n", t(), o & 0xff, d & 0xff)) end
  return d end)
taps[#taps+1] = zpg:install_write_tap(0x8000, 0xffff, "zram_w", function(o, d, mk)
  wrote[o] = true; ramw = ramw + 1
  if o < minw then minw = o end
  if o > maxw then maxw = o end
  return d end)
taps[#taps+1] = zpg:install_read_tap(0x8000, 0xffff, "zram_r", function(o, d, mk)
  if not wrote[o] then ramr_unw = ramr_unw + 1; unw[o] = true end
  return d end)
local ports = m.ioport.ports
local function press(fname, on)
  for tag, port in pairs(ports) do
    for fn, fld in pairs(port.fields) do
      if fn:lower():find(fname) then fld:set_value(on and 1 or 0) end
    end
  end
end
local frames = 0
notif = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  local s = t()
  local cs = tonumber(os.getenv("DSBCAP_COIN") or "120")
  if s > cs and s < cs + 0.2 then press("coin 1", true) else press("coin 1", false) end
  if s > cs + 2 and s < cs + 2.2 then press("1 player start", true) else press("1 player start", false) end
  if s > SECS then
    local n = 0; local blocks = {}
    for a, _ in pairs(wrote) do n = n + 1; blocks[a >> 8] = true end
    local bl = {}
    for b, _ in pairs(blocks) do bl[#bl+1] = string.format("%02x", b) end
    table.sort(bl)
    local un = {}; for a,_ in pairs(unw) do un[#un+1] = a end; table.sort(un)
    local us = {}; for i=1,math.min(#un,64) do us[#us+1]=string.format("%04x",un[i]) end
    f:write(string.format("# RAM writes=%d distinct=%d min=%04x max=%04x pages=%s\n", ramw, n, minw, maxw, table.concat(bl, ",")))
    f:write(string.format("# RAM reads of unwritten=%d distinct=%d first=%s\n", ramr_unw, #un, table.concat(us, ",")))
    f:close()
    m:exit()
  end
end)
