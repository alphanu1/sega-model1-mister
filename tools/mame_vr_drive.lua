-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- DRIVE Virtua Racing round Big Forest and dump frames for render3d.
--
-- The 3D bands run late on the board on track 1's second and third corners,
-- and nothing reaches there without steering: a held accelerator puts the car
-- in the grass at the first bend. So this steers - toward the grey road it
-- sees just above the car, read off MAME's own screen - which is enough to
-- lap the beginner course. Every DUMP_EVERY frames from DUMP_FROM to DUMP_TO it
-- writes what mame_dump_frame.lua writes, into framedump/f<frame>/, plus a
-- snapshot, so render3d can be run on each of them.
--
--   SNAP_EVERY  snapshot period with no dump (0 = off)
--   LAST        frame to stop at
--   AUTO_AT     frame the autopilot takes over (the pedal goes down at 500)

local sp = manager.machine.devices[":maincpu"].spaces["program"]
local tgp   = {}      -- sparse: index (adr - 0x40000) -> word
local lparm = {}      -- index -> packed 32-bit

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


local function dump_frame(n)
    local OUT = string.format("framedump/f%05d", n)
    os.execute("mkdir -p " .. OUT)
    local base = active_base()
    local f = io.open(OUT .. "/dlist.bin", "wb")
    for i = 0, 0x7fff do w16(f, sp:read_u16(base + 2*i)) end
    f:close()
    f = io.open(OUT .. "/palette.bin", "wb")
    for i = 0, 0x1fff do w16(f, sp:read_u16(0x900000 + 2*i)) end
    f:close()
    f = io.open(OUT .. "/xlat.bin", "wb")
    for i = 0, 0x5fff do w16(f, sp:read_u16(0x910000 + 2*i)) end
    f:close()
    local cnt = 0
    for _ in pairs(tgp) do cnt = cnt + 1 end
    f = io.open(OUT .. "/tgpram.bin", "wb")
    f:write(string.char(cnt & 0xff, (cnt>>8)&0xff, (cnt>>16)&0xff, (cnt>>24)&0xff))
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
    manager.machine.video:snapshot()
    print(string.format("dumped frame %d (list at %06x)", n, base))
end
local function field(port, name) return manager.machine.ioport.ports[port].fields[name] end
F = { coin=field(":IN.0","Coin 1"), start=field(":IN.0","1 Player Start"),
      acc=field(":ACCEL","P1 Pedal 1"), brk=field(":BRAKE","P1 Pedal 2"),
      wheel=field(":WHEEL","Paddle") }
SNAP_EVERY = tonumber(os.getenv("SNAP_EVERY") or "100")
LAST  = tonumber(os.getenv("LAST") or "4000")
DUMP_FROM  = tonumber(os.getenv("DUMP_FROM") or "0")
DUMP_TO    = tonumber(os.getenv("DUMP_TO") or "-1")
DUMP_EVERY = tonumber(os.getenv("DUMP_EVERY") or "10")
GAIN  = tonumber(os.getenv("GAIN") or "1.0")
SIGN  = tonumber(os.getenv("SIGN") or "1")
ROWS  = {}
for r in string.gmatch(os.getenv("ROWS") or "196 206 216", "%d+") do ROWS[#ROWS+1]=tonumber(r) end
AUTO_AT = tonumber(os.getenv("AUTO_AT") or "500")
scr = manager.machine.screens[":screen"]
frames = 0
cen = 248
local function grey(px, w, x, y)
  local o = (y*w + x)*4 + 1
  local b, g, r = px:byte(o, o+2)
  return math.abs(r-g) < 10 and math.abs(g-b) < 10 and r >= 0x28
end
local function rowcentre(px, w, y, guess)
  -- grey run nearest the guess
  local best, bestd = nil, 1e9
  local x = 0
  while x < w do
    if grey(px, w, x, y) then
      local s = x
      while x < w and grey(px, w, x, y) do x = x + 1 end
      local e = x - 1
      if e - s >= 6 then
        local c = (s + e) / 2
        local d = (guess >= s and guess <= e) and 0 or math.min(math.abs(guess-s), math.abs(guess-e))
        if d < bestd then bestd, best = d, c end
      end
    else x = x + 1 end
  end
  return best
end
notif = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  walk_apply(0x600000)
  walk_apply(0x610000)
  if frames >= DUMP_FROM and frames <= DUMP_TO and (frames - DUMP_FROM) % DUMP_EVERY == 0 then dump_frame(frames) end
  if frames == 300 then F.coin:set_value(1) end
  if frames == 310 then F.coin:set_value(0) end
  if frames == 400 then F.start:set_value(1) end
  if frames == 410 then F.start:set_value(0) end
  if frames == 500 then F.acc:set_value(255) end
  if frames >= AUTO_AT then
    local px, w, h = scr:pixels()
    local sum, n = 0, 0
    for _, y in ipairs(ROWS) do
      local c = rowcentre(px, w, y, 248)
      if c then sum = sum + c; n = n + 1 end
    end
    if n > 0 then cen = 0.5*cen + 0.5*(sum/n) end
    local err = cen - 248
    local s = 0x80 + SIGN*GAIN*err
    if s < 0 then s = 0 elseif s > 255 then s = 255 end
    F.wheel:set_value(math.floor(s))
    local a = 0xff
    if math.abs(err) > (tonumber(os.getenv("LIFT") or "60")) then a = 0x60 end
    F.acc:set_value(a)
    if frames % 25 == 0 then print(string.format("f %d cen %.0f err %.0f wheel %02x n %d", frames, cen, err, math.floor(s), n)) end
  end
  if SNAP_EVERY > 0 and frames % SNAP_EVERY == 0 then manager.machine.video:snapshot() end
  if frames >= LAST then manager.machine:exit() end
end)
