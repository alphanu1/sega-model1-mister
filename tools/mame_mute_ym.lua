-- IS THE ATTRACT BURST FM OR PCM?
--
-- MAME's vr output is near-silent for ~35 s and then peaks at 16,330. Our core
-- stubs the YM3438 (m1_ym_timer has no audio path) and only the two MULTIPCMs
-- contribute. If that burst is the FM, then our PCM-only output is CORRECT and
-- no amount of work on the sample path will produce it -- jt12 is required.
--
-- Mute the YM's routes and record: if the burst survives it is PCM, if it
-- vanishes it is FM.
local dev = nil
for tag, d in pairs(manager.machine.sound.speakers) do end
notif = emu.add_machine_frame_notifier(function() end)

-- Route muting differs across MAME versions; the robust way is the mixer.
for tag, s in pairs(manager.machine.devices) do
  if tag:find("ym") or tag:find("3438") then print("YM device: " .. tag) end
end
