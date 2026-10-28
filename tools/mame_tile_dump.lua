-- Dump the 2D layer's whole input - tile RAM, character RAM and palette - at a
-- run of frames, for tb_m1_video2d to replay through the real m1_video.
--
-- The full-system bench can only reach the scenes our own V60 reaches, slowly,
-- and diverges from the reference in timing. This takes the scenes from the
-- reference instead, from every title, cheaply: the 2D path's cost per line is
-- a function of tile RAM and character RAM alone, so a snapshot of those three
-- regions is the complete input to the question "does this line fit".
--
-- Note the notifier fires after the frame's vblank processing, so a snapshot is
-- a vblank newer than the picture MAME drew for that frame (see m1_video's
-- config-latch note). That does not matter here: it is a real frame's content.
--
-- Environment:
--   DUMP_DIR    output directory (must exist)
--   DUMP_FROM   first frame dumped (default 300)
--   DUMP_TO     last frame, then exit (default 3000)
--   DUMP_STEP   frames between dumps (default 10)
--   PRESS       "frame:Field Name:frames,..." momentary presses, e.g.
--               "400:Coin 1:10,440:1 Player Start:10"
--   HOLD        "frame:Field Name,..." pressed from that frame to the end
--
-- Output: tram_<frame>.bin (32768 words), pal_<frame>.bin (4096 words), and
-- char_<n>.bin (262144 words) written only when character RAM changed;
-- manifest.txt lists "<frame> <tram> <char> <pal>". Little-endian words.
-- Everything stays under build/: it is ROM-derived (hard rule 2).

local sp   = manager.machine.devices[":maincpu"].spaces["program"]
local OUT  = os.getenv("DUMP_DIR") or "tiledump"
local F0   = tonumber(os.getenv("DUMP_FROM") or "300")
local F1   = tonumber(os.getenv("DUMP_TO") or "3000")
local STEP = tonumber(os.getenv("DUMP_STEP") or "10")

local presses, holds = {}, {}
for f, name, n in string.gmatch(os.getenv("PRESS") or "", "(%d+):([^:,]+):(%d+)") do
    presses[#presses+1] = { at = tonumber(f), name = name, len = tonumber(n) }
end
for f, name in string.gmatch(os.getenv("HOLD") or "", "(%d+):([^:,]+)") do
    holds[#holds+1] = { at = tonumber(f), name = name }
end

local function field(name)
    for _, port in pairs(manager.machine.ioport.ports) do
        local fl = port.fields[name]
        if fl then return fl end
    end
    print("mame_tile_dump: no input field named '" .. name .. "'")
    return nil
end

local function dump(path, base, nwords)
    local t = {}
    local sum = 0
    for i = 0, nwords - 1 do
        local w = sp:read_u16(base + 2 * i)
        t[#t+1] = string.char(w & 0xff, (w >> 8) & 0xff)
        sum = (sum * 31 + w) & 0xffffffff
    end
    local s = table.concat(t)
    return s, sum
end

local function write(path, s)
    local f = assert(io.open(path, "wb")); f:write(s); f:close()
end

local man = assert(io.open(OUT .. "/manifest.txt", "w"))
local last_sum, last_char, nchar = nil, nil, 0
frames = 0
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    for _, p in ipairs(presses) do
        if frames == p.at then local fl = field(p.name); if fl then fl:set_value(1) end end
        if frames == p.at + p.len then local fl = field(p.name); if fl then fl:clear_value() end end
    end
    for _, h in ipairs(holds) do
        if frames >= h.at then local fl = field(h.name); if fl then fl:set_value(1) end end
    end
    if frames >= F0 and (frames - F0) % STEP == 0 then
        local tram = dump(nil, 0x700000, 32768)
        local pal  = dump(nil, 0x900000, 4096)
        local chr, sum = dump(nil, 0x780000, 262144)
        if sum ~= last_sum then
            nchar = nchar + 1
            last_char = string.format("char_%05d.bin", frames)
            write(OUT .. "/" .. last_char, chr)
            last_sum = sum
        end
        local tn = string.format("tram_%05d.bin", frames)
        local pn = string.format("pal_%05d.bin", frames)
        write(OUT .. "/" .. tn, tram)
        write(OUT .. "/" .. pn, pal)
        man:write(string.format("%d %s %s %s\n", frames, tn, last_char, pn))
        man:flush()
    end
    if frames >= F1 then
        man:close()
        print(string.format("mame_tile_dump: done at frame %d, %d character RAM images", frames, nchar))
        manager.machine:exit()
    end
end)
