-- Tilemap 0's 4096 words at frame 900, for diffing against tb_m1_boot's dump.
-- Tilemap N lives at tile_ram[N*0x1000]; the text on screen is category-1 tiles
-- (bit 15) in one of them.
local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]
frames = 0
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames == 900 then
        for m = 0, 3 do
            for i = 0, 4095, 16 do
                local t = {}
                for j = 0, 15 do
                    t[#t+1] = string.format("%04x", sp:read_u16(0x700000 + (m*0x1000 + i + j)*2))
                end
                print(string.format("TM%d %04x %s", m, i, table.concat(t, " ")))
            end
        end
        print("=== tilemaps dumped at frame 900 ===")
        frames = -100000
    end
end)
