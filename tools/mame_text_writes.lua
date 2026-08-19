-- The text routine at FF8AC3 copies a NUL-terminated string out as 16-bit tile
-- codes. Capture what it writes and where, so the two machines' strings can be
-- put side by side.
--
--   FF8AC3: mov.b  [R0+], R2
--   FF8AC6: test.b R2
--   FF8AC8: be     FF8ACF
--   FF8ACA: mov.h  R2, [R1+]     <- the write
--   FF8ACD: br     FF8AC3
local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]
n = 0
out = {}
tap = sp:install_write_tap(0x700000, 0x73ffff, "text", function(offset, data, mask)
    local pc = cpu.state["GENPC"].value
    -- GENPC is the NEXT pc, so the store at FF8ACA reports FF8ACD.
    if pc == 0xff8acd or pc == 0xff8aca then
        n = n + 1
        if n <= 4000 then
            out[#out+1] = string.format("TX %d %06x %04x", n, offset, data & 0xffff)
        end
    end
    return data
end)
frames = 0
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames >= 900 then
        print(string.format("=== %d text writes in %d frames ===", n, frames))
        for _, s in ipairs(out) do print(s) end
        out = {}; frames = -100000
    end
end)
