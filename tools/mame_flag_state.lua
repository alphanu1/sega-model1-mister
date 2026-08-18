-- Does the real Z80 keep CLEARING the doorbell after boot?
--
-- The V60 writes 1 to DPRAM 0x20 once a frame and never reads it back, so its
-- own bus traffic cannot say whether the I/O board still answers. Sample the
-- byte directly instead, several times a frame.
--
-- This decides what LATENCY should be in m1_ioboard: if the Z80 clears the
-- doorbell every frame then a long latency is wrong for the steady state, and if
-- it leaves it set then the 38.6 ms boot figure is the whole truth.
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local scr = manager.machine.screens[":screen"]

frames, samples, n_set, n_clear = 0, 0, 0, 0
per_frame = {}          -- histogram: how many of 8 samples in a frame read set
for i = 0, 8 do per_frame[i] = 0 end
trail = {}

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    -- eight samples spread across the frame, taken as the frame runs out
    local set_this_frame = 0
    for i = 1, 8 do
        local v = sp:read_u8(0xc00040) & 0xff
        samples = samples + 1
        if v ~= 0 then n_set = n_set + 1; set_this_frame = set_this_frame + 1
        else n_clear = n_clear + 1 end
    end
    per_frame[set_this_frame] = per_frame[set_this_frame] + 1
    if frames > 400 and #trail < 20 then
        trail[#trail+1] = string.format("f=%d set_in_8_samples=%d", frames, set_this_frame)
    end
    if frames % 300 == 0 then
        print(string.format("f=%d samples=%d set=%d (%.1f%%) clear=%d (%.1f%%)",
              frames, samples, n_set, 100*n_set/samples, n_clear, 100*n_clear/samples))
    end
    if frames >= 1200 then
        print("")
        print("per-frame histogram (samples reading NON-ZERO out of 8):")
        for i = 0, 8 do
            if per_frame[i] > 0 then
                print(string.format("  %d set: %d frames", i, per_frame[i]))
            end
        end
        print("")
        for _,v in ipairs(trail) do print("  "..v) end
        manager.machine:exit()
    end
end)
