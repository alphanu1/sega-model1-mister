-- The reference's fadd operands, taken from the DATA-space reads that load them.
--
-- tgp_trace diverges at `0730 fadd` / `0731 brif ged`: the reference falls through,
-- we branch. The microcode is
--     072D: mov $0x43, d      d = data[0x43]
--     072E: mov $0x42, a
--     072F: orad : mov $3, a  a = data[3]   (the transfer beats orad)
--     0730: fadd              d = d + a
-- Program fetches bypass install_read_tap in MAME, but DATA reads do not — so read
-- the operands where they are loaded rather than sampling registers.
local tgp = manager.machine.devices[":tgp_copro"]
local dsp = tgp.spaces["data"]

frames, n = 0, 0
log = {}

tap = dsp:install_read_tap(0, 0x3ff, "ops", function(offset, data, mask)
    if (offset == 0x43 or offset == 0x42 or offset == 0x03) and #log < 18 then
        n = n + 1
        log[#log+1] = string.format("  data[%02x] -> %08x", offset, data)
    end
    return data
end)

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames >= 200 or #log >= 18 then
        print(string.format("=== reference fadd operands, %d reads in %d frames ===", n, frames))
        for _, v in ipairs(log) do print(v) end
        manager.machine:exit()
    end
end)
