-- WHAT DOES THE PCM DO IN GAMEPLAY, not in attract?
--
-- Every comparison so far used the attract loop, where the car is not running
-- and MAME's own PCM makes only a quiet drone -- which ours matches. The sound
-- EFFECTS are PCM (engine, tyres, voice) and they only happen in a race. Ben's
-- hardware test was a race start at 0 km/h, where the engine should be audible.
--
-- Insert a coin, press start, then report PCM vs YM write rates per two seconds
-- so the two states can be told apart.
local snd = manager.machine.devices[":m1audio:sndcpu"]
if snd == nil then print("no sndcpu"); return end
local sp = snd.spaces["program"]
pcmn = 0; ymn = 0; frames = 0; lp = 0; ly = 0
tp = sp:install_write_tap(0xc40000, 0xc7ffff, "p", function(o,d,m) pcmn = pcmn + 1; return d end)
ty = sp:install_write_tap(0xd00000, 0xd00007, "y", function(o,d,m) ymn = ymn + 1; return d end)

local ports = manager.machine.ioport.ports
local function press(potag, fname, on)
  for tag, port in pairs(ports) do
    for fn, f in pairs(port.fields) do
      if fn:lower():find(fname) then f:set_value(on and 1 or 0) end
    end
  end
end

notif = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if frames == 300  then press(nil, "coin", true)  end
  if frames == 310  then press(nil, "coin", false) end
  if frames == 360  then press(nil, "start", true) end
  if frames == 372  then press(nil, "start", false) end
  if frames % 120 == 0 then
    print(string.format("f%4d  PCM/2s %6d   YM/2s %5d", frames, pcmn - lp, ymn - ly))
    lp = pcmn; ly = ymn; io.flush()
  end
  if frames == 2100 then manager.machine:exit() end
end)
print("PLAYPCM: installed")
