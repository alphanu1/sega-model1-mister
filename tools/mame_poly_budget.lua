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
-- Also counts how many records can emit a quad at all: `link` zero means
-- push_object jumps straight to `next` without building one, so the colour,
-- clipping, sort and fill stages never see it. That changes their budget, which
-- is not the transform's budget.
local function count_polys(poly_adr, size)
    if (poly_adr & 0x800000) ~= 0 then return 0, "polyram" end  -- not in ROM
    poly_adr = poly_adr & 0x7fffff
    if size == 0 or size > 0x100000 then size = 0x100000 end
    local a = poly_adr + 6
    local n, linked, nocull = 0, 0, 0
    while n < size and n < 4000 do
        if a + 9 >= PROM_FLOATS then return n, "overrun", linked, nocull end
        local flags = prom:read_u32(a * 4)
        if (flags & 3) == 0 then break end
        n = n + 1
        if ((flags >> 8) & 3) ~= 0 then linked = linked + 1 end
        if (flags & 0x4000) ~= 0 then nocull = nocull + 1 end
        a = a + 10
    end
    return n, "ok", linked, nocull
end

local function walk_list(base)
    local function rd(x) return sp:read_u16(base + 2*(x & 0x7fff)) end
    local function ri(x) return rd(x) | (rd(x+1) << 16) end
    local polys, objs, oob, linked, nocull = 0, 0, 0, 0, 0
    local off, guard = 0, 0
    while guard < 40000 do
        guard = guard + 1
        if off >= 0x8000 then break end
        local t = ri(off)
        if t == 0 then off = off + 2
        elseif t == 1 or t == 0x41 then
            local n, how, lk, nc = count_polys(ri(off+4), ri(off+6))
            polys  = polys + n
            linked = linked + (lk or 0)
            nocull = nocull + (nc or 0)
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
    return polys, objs, oob, linked, nocull
end

frames, sampled = 0, 0
SAMPLE_EVERY = tonumber(os.getenv("SAMPLE_EVERY") or "20")
SAMPLE_UNTIL = tonumber(os.getenv("SAMPLE_UNTIL") or "1600")
NSAMPLES = math.floor(SAMPLE_UNTIL / SAMPLE_EVERY)
peak_polys, peak_objs, sum_polys, sum_objs, tot_oob = 0, 0, 0, 0, 0

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    -- SAMPLE_EVERY / SAMPLE_UNTIL widen the window: the first 1,600 frames
    -- never reach the attract pit stop, where the stadium is and where the
    -- board shows its heaviest bands.
    if frames % SAMPLE_EVERY ~= 0 or frames > SAMPLE_UNTIL then return end

    -- The busier of the two buffers: one is being displayed while the other is
    -- filled, and which is which is not reliable from outside.
    local best_p, best_o, oob, best_lk, best_nc = 0, 0, 0, 0, 0
    for _, base in ipairs({0x600000, 0x610000}) do
        local p, o, b, lk, nc = walk_list(base)
        if p > best_p then best_p, best_o, oob, best_lk, best_nc = p, o, b, lk, nc end
    end
    sum_linked = (sum_linked or 0) + best_lk
    sum_nocull = (sum_nocull or 0) + best_nc
    if best_lk > (peak_linked or 0) then peak_linked = best_lk end
    sampled   = sampled + 1
    sum_polys = sum_polys + best_p
    sum_objs  = sum_objs + best_o
    tot_oob   = tot_oob + oob
    if best_p > peak_polys then peak_polys, peak_objs, peak_frame = best_p, best_o, frames end
    if best_o > (peak_o_objs or 0) then peak_o_objs, peak_o_polys, peak_o_frame = best_o, best_p, frames end

    if sampled == NSAMPLES then
        print("=== polygon budget, " .. sampled .. " frames sampled")
        print(string.format("  polygon ROM        %d bytes, %d floats", prom.size, PROM_FLOATS))
        print(string.format("  peak frame         %d polygons in %d objects (frame %d - DUMP_FRAME for tools/mame_dump_frame.lua)", peak_polys, peak_objs, peak_frame))
        print(string.format("  most objects       %d objects, %d polygons (frame %d)", peak_o_objs, peak_o_polys, peak_o_frame))
        print(string.format("  mean frame         %.0f polygons in %.0f objects",
              sum_polys / sampled, sum_objs / sampled))
        print(string.format("  bad/absent objects %d", tot_oob))
        -- What that costs: two points and a normal per record, transformed.
        print(string.format("  peak points/frame  %d  (2 per polygon)", peak_polys * 2))
        print(string.format("  cycles per point available at 22.86 MHz, 57.5 Hz: %.1f",
              (22857143 / 57.5) / math.max(1, peak_polys * 2)))
        print(string.format("  records that can emit a quad (link != 0): peak %d, mean %.0f",
              peak_linked or 0, (sum_linked or 0) / sampled))
        print(string.format("  of those, %.1f%% skip the backface test (flag 0x4000)",
              100.0 * (sum_nocull or 0) / math.max(1, sum_linked or 1)))
        print(string.format("  budget per EMITTED quad: %.0f cycles",
              (22857143 / 57.5) / math.max(1, peak_linked or 1)))
        manager.machine:exit()
    end
end)
