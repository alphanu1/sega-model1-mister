-- Where does the real V60 execute? Buckets fetches by region, to compare against
-- the board's rows 06/07. Globals, or the subscriptions are collected silently.
rom0, romx, bank, other, total = 0, 0, 0, 0, 0
frames = 0
local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]
tap = sp:install_read_tap(0, 0xffffff, "pcdist", function(offset, data, mask)
    total = total + 1
    if     offset >= 0xf80000 then rom0  = rom0  + 1
    elseif offset >= 0x200000 and offset < 0x300000 then romx = romx + 1
    elseif offset >= 0x100000 and offset < 0x200000 then bank = bank + 1
    else                            other = other + 1 end
    return data
end)
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames % 120 == 0 then
        print(string.format("f=%d total=%d rom0=%.1f%% romx=%.1f%% bank=%.1f%% other=%.1f%%",
            frames, total, 100*rom0/total, 100*romx/total, 100*bank/total, 100*other/total))
        if frames >= 1800 then manager.machine:exit() end
    end
end)
