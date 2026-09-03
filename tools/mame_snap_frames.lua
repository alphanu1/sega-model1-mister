-- Snapshot the reference at a set of frame numbers, so a simulated frame can be
-- put beside the frame the board would be showing at the same moment.
--
-- Our full-system bench counts video frames from reset, and so does MAME's
-- frame_number(), so the two are directly comparable as long as both start from
-- a cold nvram. Snapshots land in the MAME working directory's snap/.
-- SNAP_FRAMES="2270 2272" overrides the list, and the run ends after the last.
local WANT = { [200]=1, [400]=1, [500]=1, [600]=1, [670]=1, [700]=1, [900]=1 }
local LAST = 950
if os.getenv("SNAP_FRAMES") then
    WANT = {}; LAST = 0
    for n in string.gmatch(os.getenv("SNAP_FRAMES"), "%d+") do
        WANT[tonumber(n)] = 1
        if tonumber(n) > LAST then LAST = tonumber(n) end
    end
    LAST = LAST + 5
end
frames = 0
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if WANT[frames] then
        manager.machine.video:snapshot()
        print(string.format("snapshot at frame %d", frames))
    end
    if frames >= LAST then
        print("done")
        manager.machine:exit()
    end
end)
