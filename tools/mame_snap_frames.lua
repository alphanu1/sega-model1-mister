-- Snapshot the reference at a set of frame numbers, so a simulated frame can be
-- put beside the frame the board would be showing at the same moment.
--
-- Our full-system bench counts video frames from reset, and so does MAME's
-- frame_number(), so the two are directly comparable as long as both start from
-- a cold nvram. Snapshots land in the MAME working directory's snap/.
local WANT = { [200]=1, [400]=1, [500]=1, [600]=1, [670]=1, [700]=1, [900]=1 }
frames = 0
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if WANT[frames] then
        manager.machine.video:snapshot()
        print(string.format("snapshot at frame %d", frames))
    end
    if frames >= 950 then
        print("done")
        manager.machine:exit()
    end
end)
