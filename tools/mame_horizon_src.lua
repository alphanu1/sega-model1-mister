-- [5006] = mode | (((prev + [0x50141A]) >> 1) & 0x3ff), from FFE44B-FFE466.
-- The mode half matches; the scroll half does not. Who writes 0x50141A, and what
-- does it hold?
local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]
n = 0
pcs = {}
tap = sp:install_write_tap(0x501418, 0x50141b, "hz", function(offset, data, mask)
    if offset == 0x50141a or offset == 0x50141b then
        local pc = cpu.state["GENPC"].value
        pcs[pc] = (pcs[pc] or 0) + 1
        n = n + 1
        if n <= 12 then
            print(string.format("HZ %2d %06x <- %04x pc=%06x", n, offset, data & 0xffff, pc))
        end
    end
    return data
end)
frames = 0
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames % 120 == 0 and frames <= 900 then
        print(string.format("frame %4d  50141a=%04x  5006=%04x", frames,
              sp:read_u16(0x50141a), sp:read_u16(0x700000 + 0x5006*2)))
    end
    if frames == 900 then
        for pc, c in pairs(pcs) do print(string.format("PC %06x x%d", pc, c)) end
        frames = -100000
    end
end)
