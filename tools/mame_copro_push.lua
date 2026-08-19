-- The V60 -> TGP command stream, one line per 32-bit word, for diffing against
-- tb_m1_boot's "COPRO PUSH" lines.
--
-- The V60 writes the FIFO through PROGRAM space, not IO. That is the opposite of
-- the reads, which use in.w and only appear in AS_IO - so a tap has to go on the
-- space that matches the DIRECTION, and tapping io for writes returns nothing at
-- all while looking like a working instrument.
--
-- Each 32-bit command is two 16-bit writes, low half first: the assembled word is
-- (second << 16) | first.
local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]
local lo, have = 0, false
n = 0
out = {}
tap = sp:install_write_tap(0xd80000, 0xd80003, "push", function(offset, data, mask)
    local v = data & 0xffff
    if not have then lo, have = v, true
    else
        have = false
        n = n + 1
        if n <= 60000 then
            out[#out+1] = string.format("CP %d %08x", n, ((v << 16) | lo) & 0xffffffff)
        end
    end
    return data
end)
frames = 0
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames >= 900 or n >= 60000 then
        print(string.format("=== %d commands in %d frames ===", n, frames))
        for _, s in ipairs(out) do print(s) end
        out = {}
        n = -1
    end
end)
