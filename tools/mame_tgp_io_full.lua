-- EVERY io access the reference's TGP makes, with values, over a long window.
--
-- Our TGP writes 0xffffffff into coprocessor RAM word 0 and the V60 then waits at
-- FED5A4 for that word to read zero, forever. Three guesses at where the 0xffffffff
-- came from — uninitialised RAM, uninitialised registers, unimplemented math units —
-- were all wrong or unproven. MAME can be asked what the reference actually writes.
--
-- The earlier tap ran 30 frames and saw three accesses. This one runs long enough to
-- reach the copro RAM traffic, and records the VALUE of every access so ours can be
-- diffed against it rather than reasoned about.
local tgp  = manager.machine.devices[":tgp_copro"]
local iosp = tgp.spaces["io"]

frames, n = 0, 0
log = {}
by_addr = {}

local function note(kind, offset, data)
    n = n + 1
    local k = string.format("%s %04x", kind, offset)
    by_addr[k] = (by_addr[k] or 0) + 1
    if #log < 40 then
        log[#log+1] = string.format("  %3d  %s io %04x  %08x", n, kind, offset, data)
    end
end

rtap = iosp:install_read_tap(0, 0xffff, "tio_r", function(offset, data, mask)
    note("R", offset, data); return data
end)
wtap = iosp:install_write_tap(0, 0xffff, "tio_w", function(offset, data, mask)
    note("W", offset, data); return data
end)

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames >= 400 then
        print(string.format("=== reference TGP io: %d accesses over %d frames ===", n, frames))
        for _, v in ipairs(log) do print(v) end
        print("")
        print("=== by kind and address ===")
        local ks = {}
        for k in pairs(by_addr) do ks[#ks+1] = k end
        table.sort(ks, function(a,b) return by_addr[a] > by_addr[b] end)
        for i = 1, math.min(#ks, 14) do
            print(string.format("  %-10s %d", ks[i], by_addr[ks[i]]))
        end
        manager.machine:exit()
    end
end)
