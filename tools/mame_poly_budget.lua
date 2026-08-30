-- How many polygons does a frame actually contain, and how many points must the
-- geometry engine transform to draw it?
--
-- This is a FEASIBILITY measurement, taken before building the geometry stage
-- rather than after. Every polygon record costs a 3x3 transform of two points and
-- a normal, a projection divide per point, and a lighting dot product; a frame is
-- about 380,000 cycles of the 22.86 MHz domain. If a frame holds 30,000 polygons
-- there is no budget and the design has to change shape. If it holds 2,000 there
-- is room to share one FP pipeline across the whole stage.
--
-- Walks the display list for object commands, then walks each object in the
-- polygon ROM the way push_object does: a 6-float header, then 10-float records
-- until one has type 0 in its flags or `size` records have been read
-- (model1_v.cpp:929, :1096).
--
-- Reports per frame, not totalled: the peak frame is what has to fit, not the
-- average.

local sp   = manager.machine.devices[":maincpu"].spaces["program"]
local prom = manager.machine.memory.regions[":polygons"]
local PROM_FLOATS = prom.size // 4

-- One object's polygon count. Bounded twice - by `size` and by a hard cap -
-- because a bad address walks random data and would otherwise never stop.
local function count_polys(poly_adr, size)
    if (poly_adr & 0x800000) ~= 0 then return 0, "polyram" end  -- not in ROM
    poly_adr = poly_adr & 0x7fffff
    if size == 0 or size > 0x100000 then size = 0x100000 end
    local a = poly_adr + 6
    local n = 0
    while n < size and n < 4000 do
        if a + 9 >= PROM_FLOATS then return n, "overrun" end
        local flags = prom:read_u32(a * 4)
        if (flags & 3) == 0 then break end
        n = n + 1
        a = a + 10
    end
    return n, "ok"
end

local function walk_list(base)
    local function rd(x) return sp:read_u16(base + 2*(x & 0x7fff)) end
    local function ri(x) return rd(x) | (rd(x+1) << 16) end
    local polys, objs, oob = 0, 0, 0
    local off, guard = 0, 0
    while guard < 40000 do
        guard = guard + 1
        if off >= 0x8000 then break end
        local t = ri(off)
        if t == 0 then off = off + 2
        elseif t == 1 or t == 0x41 then
            local n, how = count_polys(ri(off+4), ri(off+6))
            polys = polys + n
            objs  = objs + 1
            if how ~= "ok" then oob = oob + 1 end
            off = off + 8
        elseif t == 2 then
            off = off + 18
            while true do
                local st = ri(off+2) & 3
                if st == 0 then break end
                off = off + ((st == 2) and 12 or 20)
            end
            off = off + 4
        elseif t == 3 then off = off + 16
        elseif t == 4 then off = off + 6 + ((ri(off+4) + 1) & 0xffff) * 2
        elseif t == 5 or t == 6 then off = off + 6 + (ri(off+4) & 0xffff) * 2
        elseif t == 7 or t == 8 then off = off + 4
        elseif t == 9 or t == 0xc then off = off + 6
        elseif t == 0xa then off = off + 8
        elseif t == 0xb then off = off + 26
        else break end
    end
    return polys, objs, oob
end

frames, sampled = 0, 0
peak_polys, peak_objs, sum_polys, sum_objs, tot_oob = 0, 0, 0, 0, 0

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames % 20 ~= 0 or frames > 1600 then return end

    -- The busier of the two buffers: one is being displayed while the other is
    -- filled, and which is which is not reliable from outside.
    local best_p, best_o, oob = 0, 0, 0
    for _, base in ipairs({0x600000, 0x610000}) do
        local p, o, b = walk_list(base)
        if p > best_p then best_p, best_o, oob = p, o, b end
    end
    sampled   = sampled + 1
    sum_polys = sum_polys + best_p
    sum_objs  = sum_objs + best_o
    tot_oob   = tot_oob + oob
    if best_p > peak_polys then peak_polys, peak_objs = best_p, best_o end

    if sampled == 60 then
        print("=== polygon budget, " .. sampled .. " frames sampled")
        print(string.format("  polygon ROM        %d bytes, %d floats", prom.size, PROM_FLOATS))
        print(string.format("  peak frame         %d polygons in %d objects", peak_polys, peak_objs))
        print(string.format("  mean frame         %.0f polygons in %.0f objects",
              sum_polys / sampled, sum_objs / sampled))
        print(string.format("  bad/absent objects %d", tot_oob))
        -- What that costs: two points and a normal per record, transformed.
        print(string.format("  peak points/frame  %d  (2 per polygon)", peak_polys * 2))
        print(string.format("  cycles per point available at 22.86 MHz, 57.5 Hz: %.1f",
              (22857143 / 57.5) / math.max(1, peak_polys * 2)))
        manager.machine:exit()
    end
end)
