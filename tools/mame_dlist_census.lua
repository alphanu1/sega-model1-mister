-- What is actually IN the display list, and which of it needs a geometry engine?
--
-- The 3D path has two kinds of drawing command and they cost very different
-- amounts to build:
--
--   command 1 / 0x41  draw object: an ADDRESS into the polygon ROM. The hardware
--                     reads the model, transforms it by the current matrix,
--                     projects, lights and clips it. Everything.
--   command 2         direct: quads already in SCREEN SPACE, in the list itself.
--                     No transform, no projection, no clipping - a fill and a
--                     sort is the whole of it.
--
-- So if the attract mode is mostly command 2, a rasterizer with no geometry
-- engine draws it, and that is worth knowing BEFORE building the geometry engine.
-- If it is mostly command 1, it is not, and no amount of fill work will show
-- anything. This measures which, rather than assuming.
--
-- Walks both list buffers with tgp_render's grammar (model1_v.cpp:1451-1601) and
-- reports a per-type histogram, the object addresses, and the viewports.
--
-- The lists are plain RAM: 0x600000 and 0x610000 in the V60's program space.

local sp = manager.machine.devices[":maincpu"].spaces["program"]

local function walk(base)
    local function rd(a)  return sp:read_u16(base + 2*(a & 0x7fff)) end
    local function ri(a)  return rd(a) | (rd(a+1) << 16) end

    local hist, objs, vps, quads = {}, {}, {}, 0
    local off, guard = 0, 0
    while guard < 40000 do
        guard = guard + 1
        if off >= 0x8000 then break end
        local t = ri(off)
        hist[t] = (hist[t] or 0) + 1
        if t == 0 then off = off + 2
        elseif t == 1 or t == 0x41 then
            objs[#objs+1] = string.format("%x:%x:%x", ri(off+2), ri(off+4), ri(off+6))
            off = off + 8
        elseif t == 2 then
            off = off + 18
            while true do
                local f = ri(off+2)
                local st = f & 3
                if st == 0 then break end
                quads = quads + 1
                off = off + ((st == 2) and 12 or 20)
            end
            off = off + 4
        elseif t == 3 then
            local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
            vps[#vps+1] = string.format("%d,%d %d,%d %d,%d",
                s16(rd(off+4)), s16(rd(off+6)), s16(rd(off+8)),
                s16(rd(off+10)), s16(rd(off+12)), s16(rd(off+14)))
            off = off + 16
        elseif t == 4 then off = off + 6 + ((ri(off+4) + 1) & 0xffff) * 2
        elseif t == 5 or t == 6 then off = off + 6 + (ri(off+4) & 0xffff) * 2
        elseif t == 7 or t == 8 then off = off + 4
        elseif t == 9 or t == 0xc then off = off + 6
        elseif t == 0xa then off = off + 8
        elseif t == 0xb then off = off + 26
        else break end
    end
    return hist, objs, vps, quads, off
end

frames = 0
tot   = {}          -- type -> total count across sampled frames
obj_adr = {}        -- poly address -> times drawn
vp_seen = {}
tot_quads = 0
tot_objs  = 0
sampled   = 0

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    -- Sample rather than walk every frame: the walk is ~thousands of reads and
    -- the list only changes at the game's own rate.
    if frames % 10 ~= 0 then return end
    if frames > 1200 then return end
    sampled = sampled + 1

    -- The active buffer is listctl bit 6; walk BOTH, since a buffer the game is
    -- filling and one it is displaying are both interesting and neither is
    -- reliably the one a snapshot catches.
    for _, base in ipairs({0x600000, 0x610000}) do
        local hist, objs, vps, quads = walk(base)
        for t, n in pairs(hist) do tot[t] = (tot[t] or 0) + n end
        for _, o in ipairs(objs) do
            obj_adr[o] = (obj_adr[o] or 0) + 1
            tot_objs = tot_objs + 1
        end
        for _, v in ipairs(vps) do vp_seen[v] = (vp_seen[v] or 0) + 1 end
        tot_quads = tot_quads + quads
    end

    if sampled == 120 then
        print("=== display list census, " .. sampled .. " samples over " .. frames .. " frames")
        local names = {[0]="nop", [1]="OBJECT", [2]="DIRECT", [3]="viewport",
                       [4]="colour", [5]="polyram", [6]="lightparam", [7]="mode",
                       [8]="select", [9]="zoom", [0xa]="lightvec", [0xb]="matrix",
                       [0xc]="trans", [0xf]="end", [0x41]="OBJECT-hud"}
        local keys = {}
        for t in pairs(tot) do keys[#keys+1] = t end
        table.sort(keys)
        for _, t in ipairs(keys) do
            print(string.format("  type %3x %-12s %8d", t, names[t] or "?", tot[t]))
        end
        print(string.format("  objects drawn      %d", tot_objs))
        print(string.format("  direct sub-quads   %d", tot_quads))
        local n = 0
        for _ in pairs(obj_adr) do n = n + 1 end
        print(string.format("  distinct objects   %d", n))
        local shown = 0
        for a, c in pairs(obj_adr) do
            if shown < 12 then print("    tex:poly:size " .. a .. " x" .. c); shown = shown + 1 end
        end
        for v, c in pairs(vp_seen) do print("  viewport " .. v .. " x" .. c) end
        manager.machine:exit()
    end
end)
