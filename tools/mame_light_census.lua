-- What does the lighting path actually need for THIS game?
--
-- push_object's colour block is the most expensive part of the geometry stage
-- that is not the transform: a normalize (reciprocal square root), a dot product,
-- a specular term with three conditional squarings, and three colour-translation
-- lookups. Some of it may be dead for Virtua Racing, and the cheapest unit is the
-- one that is not built.
--
-- Measured here, from the display list:
--
--   command 7 bit 0   spec_enable. MAME's comment says netmerc toggles it and
--                     "the other games never set the bit" - which is a claim
--                     about the games, so it is checkable.
--   command 6         the light parameter banks: ambient, diffuse, specular,
--                     power. A specular scale of zero, or a power of zero, makes
--                     compute_specular return early whatever the mode word says.
--   command 4         the colour words. Bit 0x400 is the unlit flat-UI flag and
--                     bits 11:10 == 1 is the blinking mode; both change what the
--                     colour unit has to do.
--   command 0x0a      the light direction.

local sp = manager.machine.devices[":maincpu"].spaces["program"]

frames, sampled = 0, 0
spec_words  = {}
lightparams = {}
colour_bits = {}
lightvecs   = {}
nobj        = 0

local function walk(base)
    local function rd(a) return sp:read_u16(base + 2*(a & 0x7fff)) end
    local function ri(a) return rd(a) | (rd(a+1) << 16) end
    local off, guard = 0, 0
    while guard < 40000 do
        guard = guard + 1
        if off >= 0x8000 then break end
        local t = ri(off)
        if t == 0 then off = off + 2
        elseif t == 1 or t == 0x41 then nobj = nobj + 1; off = off + 8
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
            local len = (ri(off+4) + 1) & 0xffff
            for i = 0, len-1 do
                local w = rd(off + 6 + 2*i)
                local key = string.format("mode=%d unlit=%d", (w >> 10) & 3, (w >> 10) & 1)
                colour_bits[key] = (colour_bits[key] or 0) + 1
            end
            off = off + 6 + len * 2
        elseif t == 5 then off = off + 6 + (ri(off+4) & 0xffff) * 2
        elseif t == 6 then
            local len = ri(off+4) & 0xffff
            for i = 0, len-1 do
                local v = ri(off + 6 + i*2)
                local key = string.format("d=%d a=%d s=%d p=%d",
                    v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff)
                lightparams[key] = (lightparams[key] or 0) + 1
            end
            off = off + 6 + len * 2
        elseif t == 7 then
            local v = ri(off+2)
            local key = string.format("%08x  spec_enable=%d", v, v & 1)
            spec_words[key] = (spec_words[key] or 0) + 1
            off = off + 4
        elseif t == 8 then off = off + 4
        elseif t == 9 or t == 0xc then off = off + 6
        elseif t == 0xa then
            local key = string.format("%08x %08x %08x", ri(off+2), ri(off+4), ri(off+6))
            lightvecs[key] = (lightvecs[key] or 0) + 1
            off = off + 8
        elseif t == 0xb then off = off + 26
        else break end
    end
end

local function dump(name, tbl, limit)
    print("  " .. name .. ":")
    local n = 0
    for k, v in pairs(tbl) do
        if n < limit then print(string.format("    %-40s x%d", k, v)); n = n + 1 end
    end
    if n == 0 then print("    (none seen)") end
end

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames % 10 ~= 0 or frames > 1200 then return end
    sampled = sampled + 1
    walk(0x600000)
    walk(0x610000)
    if sampled == 100 then
        print("=== lighting census, " .. sampled .. " samples, " .. nobj .. " objects")
        dump("command 7 mode words", spec_words, 10)
        dump("command 6 light parameters", lightparams, 12)
        dump("command 4 colour word modes", colour_bits, 8)
        dump("command 0x0a light directions", lightvecs, 6)
        manager.machine:exit()
    end
end)
