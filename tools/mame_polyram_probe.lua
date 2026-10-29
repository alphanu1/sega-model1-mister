-- Polygon RAM probe (Wing War's sky). Every frame it applies command-5
-- uploads to a shadow polygon RAM; at DUMP it prints the bit-23 objects, the
-- direct polygons and the shadow; with KILL=1 it NOPs every bit-23 object in
-- both lists from KILL_FROM on, which is how the sky was shown to be that
-- object. SNAP_FRAMES for snapshots, LAST to exit. Headless:
--   mame wingwar -video none -sound none -nothrottle -skip_gameinfo
--     -autoboot_delay 0 -nvram_directory <empty> -autoboot_script <this>
local sp = manager.machine.devices[":maincpu"].spaces["program"]
SNAPS = {}
for n in string.gmatch(os.getenv("SNAP_FRAMES") or "600", "%d+") do SNAPS[tonumber(n)] = 1 end
KILL = tonumber(os.getenv("KILL") or "0")
KILL_FROM = tonumber(os.getenv("KILL_FROM") or "590")
DUMP = tonumber(os.getenv("DUMP") or "600")
LAST = tonumber(os.getenv("LAST") or "601")
pram = {}
uploads = {}
local function f32(u) return string.unpack("<f", string.pack("<I4", u)) end
local function walk(base, kill, verbose)
    local function rd(a) return sp:read_u16(base + 2*(a & 0x7fff)) end
    local function ri(a) return rd(a) | (rd(a+1) << 16) end
    local off, guard = 0, 0
    while guard < 40000 do
        guard = guard + 1
        if off >= 0x8000 then break end
        local t = ri(off)
        if t == 0 then off = off + 2
        elseif t == 1 or t == 0x41 then
            local tex, poly, size = ri(off+2), ri(off+4), ri(off+6)
            if (poly & 0x800000) ~= 0 then
                if verbose then print(string.format("B23 obj @%04x type %x tex=%08x poly=%08x size=%x", off, t, tex, poly, size)) end
                if kill then for i=0,7 do sp:write_u16(base + 2*((off+i)&0x7fff), 0) end end
            end
            off = off + 8
        elseif t == 2 then
            if verbose then print(string.format("DIRECT @%04x tex=%08x", off, ri(off+2))) end
            off = off + 18
            while true do
                local st = ri(off+2) & 3
                if st == 0 then break end
                if verbose then
                    local s = {}
                    for i=0,(st==2 and 5 or 9) do s[#s+1] = string.format("%08x", ri(off+2+2*i)) end
                    print("  sub " .. table.concat(s, " "))
                end
                off = off + ((st == 2) and 12 or 20)
            end
            off = off + 4
        elseif t == 3 then off = off + 16
        elseif t == 4 then off = off + 6 + ((ri(off+4) + 1) & 0xffff) * 2
        elseif t == 5 then
            local adr, len = ri(off+2), ri(off+4)
            uploads[#uploads+1] = string.format("%x+%x", adr, len)
            for i = 0, (len & 0xffff) - 1 do pram[(adr - 0x800000 + i)] = ri(off + 6 + 2*i) end
            off = off + 6 + (len & 0xffff) * 2
        elseif t == 6 then off = off + 6 + (ri(off+4) & 0xffff) * 2
        elseif t == 7 or t == 8 then off = off + 4
        elseif t == 9 or t == 0xc then off = off + 6
        elseif t == 0xa then off = off + 8
        elseif t == 0xb then off = off + 26
        else break end
    end
end
frames = 0
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    local kill = (KILL == 1 and frames >= KILL_FROM)
    walk(0x600000, kill, frames == DUMP)
    walk(0x610000, kill, false)
    if frames == DUMP then
        print("uploads so far: " .. table.concat(uploads, " ", math.max(1, #uploads-30)))
        local keys = {}
        for k in pairs(pram) do keys[#keys+1] = k end
        table.sort(keys)
        print(string.format("pram words %d, lo %x hi %x", #keys, keys[1] or 0, keys[#keys] or 0))
        for _, k in ipairs(keys) do
            local v = pram[k]
            print(string.format("PRAM %04x %08x %g", k, v, f32(v)))
        end
    end
    if SNAPS[frames] then manager.machine.video:snapshot() end
    if frames >= LAST then manager.machine:exit() end
end)
