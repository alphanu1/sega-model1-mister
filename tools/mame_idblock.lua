-- The I/O board's identity block, as the reference actually holds it, over time.
--
-- m1_ioboard pushes 128 bytes into DPRAM 0x100-0x17f because the V60 block-reads
-- the window and will not proceed without it. The table was transcribed from one
-- dump taken just after the handshake. But the V60 then COPIES the window into
-- work RAM at 0x40DC80 (FE08DD..FE08F5, 128 bytes) and uses it as configuration —
-- and v60_trace diverges on `cmp.b #1, 40DC8B`, which is block offset 0x0B, where
-- our table pushes 0x00 because it has no entry for it.
--
-- So: dump the window at several points and see whether it is what we push, and
-- whether the Z80 changes it after the first read.
local sp = manager.machine.devices[":maincpu"].spaces["program"]

-- DPRAM byte offset N is at V60 byte 0xc00000 + 2N (umask16(0x00ff), low lane).
local function db(n) return sp:read_u16(0xc00000 + 2*n) & 0xff end

frames = 0
snapshots = {}

local function dump(tag)
    local out = {tag}
    for row = 0, 7 do
        local line = {string.format("  0x%03x:", 0x100 + row*16)}
        for col = 0, 15 do
            line[#line+1] = string.format("%02x", db(0x100 + row*16 + col))
        end
        out[#out+1] = table.concat(line, " ")
    end
    return table.concat(out, "\n")
end

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames == 10 or frames == 120 or frames == 900 then
        snapshots[#snapshots+1] = dump(string.format("=== frame %d ===", frames))
    end
    if frames >= 900 then
        for _, s in ipairs(snapshots) do print(s); print("") end
        print(string.format("offset 0x0b = %02x   (the byte cmp.b #1, 40DC8B tests)", db(0x10b)))
        print("non-zero offsets:")
        local line = {}
        for n = 0, 0x7f do
            local v = db(0x100 + n)
            if v ~= 0 then
                line[#line+1] = string.format("%02x:%02x", n, v)
                if #line == 10 then print("  "..table.concat(line, " ")); line = {} end
            end
        end
        if #line > 0 then print("  "..table.concat(line, " ")) end
        manager.machine:exit()
    end
end)
