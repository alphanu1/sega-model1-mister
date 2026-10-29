-- EVERY REGISTER WRITE THE SOUND 68000 MAKES, timestamped, for the MultiPCM
-- replay bench (make multipcm_replay / sim/sound/tb_multipcm_replay.cpp).
--
-- Lines are "<emulated seconds> <address> <byte>": C40000-C40007 MultiPCM 1,
-- C50000 its bank, C60000-C60007 MultiPCM 2, C70000 its bank, D00000-D00007
-- the YM3438. The bench replays one chip's writes in sample time through the
-- RTL and through a transcription of MAME's gew.cpp, so the two outputs line
-- up sample for sample.
--
-- Inserts a coin at frame 600, presses start at 660 and then every button,
-- trigger, punch and kick on a 45-frame cycle, because the sound effects are
-- what a game in play makes and the attract loop of several games is silent.
--
-- OUTF names the log (default mpcm_regs.txt), FRAMES how long (default 3600).
-- Headless, from a scratch directory - MAME drops cfg/ and nvram/ where it
-- starts:
--   OUTF=netmerc_regs.txt mame netmerc -rompath ... -skip_gameinfo \
--     -autoboot_delay 0 -video none -sound none -nothrottle \
--     -autoboot_script tools/mame_mpcm_regs.lua
local snd = manager.machine.devices[":m1audio:sndcpu"]
if snd == nil then print("MPCMREGS: no :m1audio:sndcpu"); return end
local ssp = snd.spaces["program"]
out = io.open(os.getenv("OUTF") or "mpcm_regs.txt", "w")
-- Global, or the tap is collected and stops with no error.
tap = ssp:install_write_tap(0xc40000, 0xd00007, "mpcmregs", function(offset, data, mask)
  out:write(string.format("%.7f %06x %02x\n", manager.machine.time:as_double(), offset, data & 0xff))
  return data
end)
local function press(pat, on)
  for tag, port in pairs(manager.machine.ioport.ports) do
    for fn, f in pairs(port.fields) do
      if fn:lower():find(pat) then f:set_value(on and 1 or 0) end
    end
  end
end
frames = 0
local last = tonumber(os.getenv("FRAMES") or "3600")
notif = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if frames == 600 then press("coin 1", true) end
  if frames == 610 then press("coin 1", false) end
  if frames == 660 then press("1 player start", true); press("start 1", true); press("p1 start", true) end
  if frames == 672 then press("1 player start", false); press("start 1", false); press("p1 start", false) end
  if frames > 700 and frames % 45 == 0 then press("button", true); press("trigger", true); press("punch", true); press("kick", true) end
  if frames > 700 and frames % 45 == 10 then press("button", false); press("trigger", false); press("punch", false); press("kick", false) end
  if frames == last then out:close(); manager.machine:exit() end
end)
print("MPCMREGS: installed")
