-- WHICH CHIP MAKES THE ATTRACT BURST?
-- MAME's vr peaks at 16,330 around frame 2074 (34.6 s) and is near-silent
-- otherwise. We stub the YM3438, so if the burst is FM our PCM-only path can
-- never produce it and jt12 is mandatory rather than optional.
local snd = manager.machine.devices[":m1audio:sndcpu"]
if snd == nil then print("no sndcpu"); return end
local sp = snd.spaces["program"]
pcmn = 0; ymn = 0; frames = 0; last = {}
tp = sp:install_write_tap(0xc40000, 0xc7ffff, "p", function(o,d,m) pcmn = pcmn + 1; return d end)
ty = sp:install_write_tap(0xd00000, 0xd00007, "y", function(o,d,m) ymn  = ymn  + 1; return d end)
notif = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if frames % 120 == 0 then
    print(string.format("f%4d  PCM %6d  YM %6d   (last 2 s: PCM %5d  YM %5d)",
          frames, pcmn, ymn, pcmn - (last.p or 0), ymn - (last.y or 0)))
    last.p = pcmn; last.y = ymn; io.flush()
  end
  if frames == 2400 then manager.machine:exit() end
end)
print("BURSTWHO: installed")
