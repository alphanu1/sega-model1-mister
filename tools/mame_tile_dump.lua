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
--   DUMP_LIST   "f1,f2,..." dump exactly these frames instead of FROM/STEP
--               (the run still ends at DUMP_TO, or at the last listed frame)
--   SNAP=1      also write MAME's own picture of what that dump draws,
--               snap_<frame>.bin: 496 x 384 x RGB, one byte a channel, top
--               row first. It is the screen as it stands at the NEXT
--               notifier, not this one: MEASURED, VR attract 296-306 dumped
--               every frame and each rendered through tb_m1_video2d, the
--               render of dump k matched MAME's picture at notifier k+1 to
--               0 pixels on all nine frames and its picture at k by 52 to
--               88,827 pixels (the sea scrolls). Pairing them the same
--               notifier compares a frame against its predecessor.
--   NO3D=1      the picture is MAME's 2D ALONE: a write tap turns every word
--               the game writes to either display list into 0x000f, so each
--               list reads as type 0x000f000f from its first word - not 0x0f,
--               so it is tgp_render's `default:` - and ends there. Nothing
--               3D is drawn; screen_update's fill and its eight tilemap
--               draws are untouched. The lists are the 3D's input only: tile
--               RAM checksums with and without this agree (see findings).
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
local SNAP = os.getenv("SNAP") == "1"
local NO3D = os.getenv("NO3D") == "1"
local LIST = nil
if os.getenv("DUMP_LIST") then
    LIST = {}
    local last = 0
    for f in string.gmatch(os.getenv("DUMP_LIST"), "%d+") do
        LIST[tonumber(f)] = true
        if tonumber(f) > last then last = tonumber(f) end
    end
    if not os.getenv("DUMP_TO") then F1 = last end
end
if NO3D then
    no3d_tap = sp:install_write_tap(0x600000, 0x61ffff, "no3d",
        function(offset, data, mask) return 0x000f end)
end

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

local function screen_rgb()
    local px, w, h = manager.machine.screens[":screen"]:pixels()
    local o = {}
    for i = 0, w * h - 1 do
        local b, g, r = string.byte(px, 4 * i + 1, 4 * i + 3)
        o[#o+1] = string.char(r, g, b)
    end
    return table.concat(o)
end
local snap_pending = nil

local man = assert(io.open(OUT .. "/manifest.txt", "w"))
local last_sum, last_char, nchar = nil, nil, 0
frames = 0
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if snap_pending then
        write(OUT .. "/" .. snap_pending, screen_rgb())
        snap_pending = nil
    end
    for _, p in ipairs(presses) do
        if frames == p.at then local fl = field(p.name); if fl then fl:set_value(1) end end
        if frames == p.at + p.len then local fl = field(p.name); if fl then fl:clear_value() end end
    end
    for _, h in ipairs(holds) do
        if frames >= h.at then local fl = field(h.name); if fl then fl:set_value(1) end end
    end
    local want
    if LIST then want = LIST[frames] else want = frames >= F0 and (frames - F0) % STEP == 0 end
    if want then
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
        local sn = ""
        if SNAP then
            sn = string.format(" snap_%05d.bin", frames)
            snap_pending = string.sub(sn, 2)
        end
        man:write(string.format("%d %s %s %s%s\n", frames, tn, last_char, pn, sn))
        man:flush()
    end
    if frames >= F1 and not snap_pending then
        man:close()
        print(string.format("mame_tile_dump: done at frame %d, %d character RAM images", frames, nchar))
        manager.machine:exit()
    end
end)
