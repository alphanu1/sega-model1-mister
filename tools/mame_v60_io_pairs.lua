-- WHICH ADDRESS does each polling PC read? PC and address recorded TOGETHER.
--
-- mame_v60_iospace.lua reported reads by address and reads by PC in two separate
-- columns, and pairing them by eye gave "fed5a4 polls copro RAM at 0xd20000". That
-- is a join across two tables, not a measurement — the same shape of inference that
-- produced two withdrawn findings tonight. This records the pair.
local cpu = manager.machine.devices[":maincpu"]
local iosp = cpu.spaces["io"]

frames = 0
pairs_seen = {}

rtap = iosp:install_read_tap(0, 0xffffff, "iopair", function(offset, data, mask)
    local k = string.format("%06x %06x", cpu.state["PC"].value, offset & 0xfffffc)
    pairs_seen[k] = (pairs_seen[k] or 0) + 1
    return data
end)

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames >= 600 then
        local ks = {}
        for k in pairs(pairs_seen) do ks[#ks+1] = k end
        table.sort(ks, function(a,b) return pairs_seen[a] > pairs_seen[b] end)
        print(string.format("=== V60 io reads over %d frames, PC and ADDRESS together ===", frames))
        print("      PC      address    count")
        for i = 1, math.min(#ks, 12) do
            local pc, ad = ks[i]:match("(%S+) (%S+)")
            print(string.format("  %s  %s  %d", pc, ad, pairs_seen[ks[i]]))
        end
        manager.machine:exit()
    end
end)
