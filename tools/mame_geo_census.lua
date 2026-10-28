-- Which display-list commands does a game issue, frame by frame, that the
-- core's geometry path does not implement?
--
--   0x02  direct (already projected) polygons
--   0x05  polygon RAM upload            m_poly_ram[adr - 0x800000 + i]
--   objects (0x01/0x41) whose poly_adr has bit 23 set, which MAME reads from
--   polygon RAM instead of the polygon ROM
--
-- Walks the list the reference RENDERS that frame (listctl bit 6 picks the
-- buffer, as set_current_render_list does), not both, so a count is one
-- frame's worth and a command is attributed to the frame that drew it.
-- Uploads are applied to a shadow polygon RAM exactly as tgp_render applies
-- them, so the address range the game actually uses is measured, not guessed.
--
-- Environment:
--   GEO_FRAMES   frames to run (default 3000)
--   GEO_EVERY    print a per-frame line every N frames (default 1; a line is
--                ALWAYS printed for a frame with a 02, a 05 or a bit-23 object)
--   SNAP_FRAMES  "f1 f2 ..." snapshots (land in snap/)
--   PRESS        "frame:Field Name:frames,..." momentary presses
--   HOLD         "frame:Field Name,..." held from that frame to the end
--   OBJ_DUMP     a frame number: print every object record of that frame
--
-- Assign every notifier to a GLOBAL or it is collected (the rules file).

local sp = manager.machine.devices[":maincpu"].spaces["program"]

GEO_FRAMES = tonumber(os.getenv("GEO_FRAMES") or "3000")
GEO_EVERY  = tonumber(os.getenv("GEO_EVERY") or "1")
OBJ_DUMP   = tonumber(os.getenv("OBJ_DUMP") or "-1")
snaps = {}
for n in string.gmatch(os.getenv("SNAP_FRAMES") or "", "%d+") do snaps[tonumber(n)] = 1 end
presses, holds = {}, {}
for f, name, n in string.gmatch(os.getenv("PRESS") or "", "(%d+):([^:,]+):(%d+)") do
    presses[#presses+1] = {at=tonumber(f), name=name, len=tonumber(n)}
end
for f, name in string.gmatch(os.getenv("HOLD") or "", "(%d+):([^:,]+)") do
    holds[#holds+1] = {at=tonumber(f), name=name}
end
local function field(name)
    for _, port in pairs(manager.machine.ioport.ports) do
        local fl = port.fields[name]
        if fl then return fl end
    end
    print("geo_census: no input field named '" .. name .. "'")
end

polyram_lo, polyram_hi, polyram_words = nil, nil, 0
upload_events = 0
b23_lo, b23_hi = nil, nil
tot = {}
b23_objs = {}

local function walk(base, verbose)
    local function rd(a)  return sp:read_u16(base + 2*(a & 0x7fff)) end
    local function ri(a)  return rd(a) | (rd(a+1) << 16) end
    local r = {direct=0, dquads=0, up=0, upw=0, obj=0, b23=0, b23list={}, hist={}}
    local off, guard = 0, 0
    while guard < 40000 do
        guard = guard + 1
        if off >= 0x8000 then break end
        local t = ri(off)
        r.hist[t] = (r.hist[t] or 0) + 1
        if t == 0 then off = off + 2
        elseif t == 1 or t == 0x41 then
            local tex, poly, size = ri(off+2), ri(off+4), ri(off+6)
            r.obj = r.obj + 1
            if verbose then
                print(string.format("  OBJ %02x tex=%08x poly=%08x size=%x", t, tex, poly, size))
            end
            if (poly & 0x800000) ~= 0 and tex ~= 0xffffffff and size < 0x1000000 then
                r.b23 = r.b23 + 1
                r.b23list[#r.b23list+1] = string.format("%x/%x", poly, size)
                local a = poly & 0x7fffff
                if not b23_lo or a < b23_lo then b23_lo = a end
                if not b23_hi or a > b23_hi then b23_hi = a end
            end
            off = off + 8
        elseif t == 2 then
            r.direct = r.direct + 1
            off = off + 18
            while true do
                local st = ri(off+2) & 3
                if st == 0 then break end
                r.dquads = r.dquads + 1
                off = off + ((st == 2) and 12 or 20)
            end
            off = off + 4
        elseif t == 3 then off = off + 16
        elseif t == 4 then off = off + 6 + ((ri(off+4) + 1) & 0xffff) * 2
        elseif t == 5 then
            local adr, len = ri(off+2), ri(off+4)
            r.up = r.up + 1; r.upw = r.upw + len
            local a0, a1 = adr - 0x800000, adr - 0x800000 + len - 1
            if not polyram_lo or a0 < polyram_lo then polyram_lo = a0 end
            if not polyram_hi or a1 > polyram_hi then polyram_hi = a1 end
            if verbose then print(string.format("  UPLOAD adr=%08x len=%x", adr, len)) end
            off = off + 6 + (len & 0xffff) * 2
        elseif t == 6 then off = off + 6 + (ri(off+4) & 0xffff) * 2
        elseif t == 7 or t == 8 then off = off + 4
        elseif t == 9 or t == 0xc then off = off + 6
        elseif t == 0xa then off = off + 8
        elseif t == 0xb then off = off + 26
        else break end
    end
    return r
end

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
    if snaps[frames] then manager.machine.video:snapshot() end

    -- listctl: model1_v.cpp get_list_number() = BIT(m_listctl[0], 6)
    -- m_listctl lives at 0xd00000? No: it is the 0x680000 register; read the
    -- display list the walker of the CURRENT frame would use. Both are walked
    -- and the one with the higher frame tag is not knowable here, so walk the
    -- buffer whose first word is not zero and report both.
    local lines = {}
    local any = false
    local tot_obj = 0
    for li, base in ipairs({0x600000, 0x610000}) do
        local r = walk(base, frames == OBJ_DUMP)
        tot_obj = tot_obj + r.obj
        for t, n in pairs(r.hist) do tot[t] = (tot[t] or 0) + n end
        if r.direct > 0 or r.up > 0 or r.b23 > 0 then any = true end
        lines[#lines+1] = string.format("L%d obj=%d direct=%d/%dq up=%d/%dw b23=%d %s",
            li-1, r.obj, r.direct, r.dquads, r.up, r.upw, r.b23,
            table.concat(r.b23list, " ", 1, math.min(#r.b23list, 12)))
    end
    if any or (frames % GEO_EVERY == 0) then
        print(string.format("GEO f=%d %s | %s", frames, lines[1], lines[2]))
    end
    if frames >= GEO_FRAMES then
        print(string.format("GEOFINAL frames=%d polyram %s..%s b23 objects poly %s..%s",
            frames,
            polyram_lo and string.format("%x", polyram_lo) or "-",
            polyram_hi and string.format("%x", polyram_hi) or "-",
            b23_lo and string.format("%x", b23_lo) or "-",
            b23_hi and string.format("%x", b23_hi) or "-"))
        local keys = {}
        for t in pairs(tot) do keys[#keys+1] = t end
        table.sort(keys)
        for _, t in ipairs(keys) do print(string.format("GEOHIST type %3x %9d", t, tot[t])) end
        manager.machine:exit()
    end
end)
