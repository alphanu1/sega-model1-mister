-- The row mask for tilemaps 0/1, tile_ram 0x6000-0x67ff, four words a scanline.
-- A category-1 tile (the text) is visible only where its mask bit is 1, so this
-- table decides whether the TEST MODE menu appears at all.
local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]
frames = 0
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames == 900 then
        local nz = 0
        for i = 0, 2047 do
            local v = sp:read_u16(0x700000 + (0x6000 + i)*2)
            if v ~= 0 then nz = nz + 1; print(string.format("RM %04x %04x", i, v)) end
        end
        print(string.format("=== row mask 0x6000: %d/2048 non-zero at frame %d ===", nz, frames))
        frames = -100000
    end
end)
