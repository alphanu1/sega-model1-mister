-- Dump everything the geometry stage needs to render ONE real frame.
--
-- This is what makes a screen capture from simulation possible: the RTL is fed
-- the reference's own display list, palette, colour-translation table, colour
-- words and light banks, so any difference in the picture is the RTL's and not
-- the input's.
--
-- Four of the five come straight out of memory. The fifth, tgp_ram, is NOT
-- memory-mapped - it exists only as the accumulated effect of display-list
-- command 4 - so it is rebuilt here exactly as MAME rebuilds it, by walking every
-- frame's list and applying the colour writes. Same for the light banks, from
-- command 6.
--
-- Written to build/framedump/ as raw little-endian, plus a text file of the
-- display-list-derived state the walker cannot infer.

local sp = manager.machine.devices[":maincpu"].spaces["program"]
local OUT = "framedump"

local tgp   = {}      -- sparse: index (adr - 0x40000) -> word
local lparm = {}      -- index -> packed 32-bit
frames = 0
DUMP_AT = tonumber(os.getenv("DUMP_FRAME") or "900")

local function walk_apply(base)
    local function rd(a) return sp:read_u16(base + 2*(a & 0x7fff)) end
    local function ri(a) return rd(a) | (rd(a+1) << 16) end
    local off, guard = 0, 0
    while guard < 40000 do
        guard = guard + 1
        if off >= 0x8000 then break end
        local t = ri(off)
        if t == 0 then off = off + 2
        elseif t == 1 or t == 0x41 then off = off + 8
        elseif t == 2 then
            off = off + 18
            while true do
                local st = ri(off+2) & 3
                if st == 0 then break end
                off = off + ((st == 2) and 12 or 20)
            end
            off = off + 4
        elseif t == 3 then off = off + 16
        elseif t == 4 then
            local adr = ri(off+2)
            local len = (ri(off+4) + 1) & 0xffff
            for i = 0, len-1 do tgp[(adr - 0x40000 + i) & 0xfffff] = rd(off + 6 + 2*i) end
            off = off + 6 + len * 2
        elseif t == 5 then off = off + 6 + (ri(off+4) & 0xffff) * 2
        elseif t == 6 then
            local adr = ri(off+2)
            local len = ri(off+4) & 0xffff
            for i = 0, len-1 do lparm[(adr + i) & 0xff] = ri(off + 6 + i*2) end
            off = off + 6 + len * 2
        elseif t == 7 or t == 8 then off = off + 4
        elseif t == 9 or t == 0xc then off = off + 6
        elseif t == 0xa then off = off + 8
        elseif t == 0xb then off = off + 26
        else break end
    end
end

-- Which buffer is being rendered: listctl bit 6, read back the way the game does.
-- Bit 6 as read back is only recomputed when MAME renders (set_current_render_list),
-- so between renders it can lag the game's own bit 3 by a frame in manual mode
-- and this dumped the buffer the game was WRITING: frame 2270 came out with 3
-- objects where MAME's own walk found 161. Resolve it the way MAME does.
local function active_base()
    local c = sp:read_u16(0x680000)
    local sel
    if (c & 4) ~= 0 then sel = (c & 0x40) ~= 0 else sel = (c & 8) ~= 0 end
    return sel and 0x610000 or 0x600000
end

local function w16(f, v) f:write(string.char(v & 0xff, (v >> 8) & 0xff)) end

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    -- Apply both buffers every frame, as tgp_scan does for the one not rendered.
    walk_apply(0x600000)
    walk_apply(0x610000)
    if frames ~= DUMP_AT then return end

    local base = active_base()
    print(string.format("dumping frame %d, active list at %06x", frames, base))

    local f = io.open(OUT .. "/dlist.bin", "wb")
    for i = 0, 0x7fff do w16(f, sp:read_u16(base + 2*i)) end
    f:close()

    f = io.open(OUT .. "/palette.bin", "wb")
    for i = 0, 0x1fff do w16(f, sp:read_u16(0x900000 + 2*i)) end
    f:close()

    f = io.open(OUT .. "/xlat.bin", "wb")
    for i = 0, 0x5fff do w16(f, sp:read_u16(0x910000 + 2*i)) end
    f:close()

    -- tgp_ram, sparse: count then (index, value) pairs.
    local n = 0
    for _ in pairs(tgp) do n = n + 1 end
    f = io.open(OUT .. "/tgpram.bin", "wb")
    f:write(string.char(n & 0xff, (n>>8)&0xff, (n>>16)&0xff, (n>>24)&0xff))
    for k, v in pairs(tgp) do
        f:write(string.char(k & 0xff, (k>>8)&0xff, (k>>16)&0xff, (k>>24)&0xff))
        w16(f, v)
    end
    f:close()

    f = io.open(OUT .. "/lightparams.txt", "w")
    for i = 0, 255 do
        local v = lparm[i] or 0
        f:write(string.format("%d %d %d %d %d\n", i,
            v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff))
    end
    f:close()

    print(string.format("  tgp_ram entries %d, palette 8192, xlat 24576", n))

    -- And the reference's own picture, to compare against.
    manager.machine.video:snapshot()
    manager.machine:exit()
end)
