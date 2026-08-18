-- The PC ITSELF, not memory accesses. Row 06/07 on the board counts cycles with
-- the PC in ROM0 against everywhere else, and the earlier tap counted data reads
-- too — so it is not the same quantity and cannot be compared with it.
rom0, other, n = 0, 0, 0
seen = {}
local cpu = manager.machine.devices[":maincpu"]
notif = emu.add_machine_frame_notifier(function()
    local pc = cpu.state["PC"].value
    n = n + 1
    if pc >= 0xf80000 then rom0 = rom0 + 1 else
        other = other + 1
        local k = string.format("%06x", pc)
        seen[k] = (seen[k] or 0) + 1
    end
    if n % 600 == 0 then
        print(string.format("samples=%d rom0=%d other=%d (%.2f%% outside ROM0)",
              n, rom0, other, 100*other/n))
        if n >= 3600 then
            for k,v in pairs(seen) do print("  outside:", k, v) end
            manager.machine:exit()
        end
    end
end)
