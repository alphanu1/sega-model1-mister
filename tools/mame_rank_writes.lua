-- Who writes the attract ranking text? Tile RAM word 0x910 is byte 0x701220, and
-- the reference holds a0xx there while we hold 0020.
local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]
n = 0
pcs = {}
tap = sp:install_write_tap(0x701200, 0x70127f, "rank", function(offset, data, mask)
    local pc = cpu.state["GENPC"].value
    pcs[pc] = (pcs[pc] or 0) + 1
    n = n + 1
    if n <= 20 then
        print(string.format("RW %3d %06x <- %04x  pc=%06x", n, offset, data & 0xffff, pc))
    end
    return data
end)
frames = 0
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames == 900 then
        print(string.format("=== %d writes ===", n))
        for pc, c in pairs(pcs) do print(string.format("PC %06x  x%d", pc, c)) end
        frames = -100000
    end
end)
