-- WHEN IS A DISPLAY LIST COMPLETE, relative to the game's buffer flip?
--
-- Our geometry pass is going to START on the list-select flip instead of on the
-- frame pulse, because a pass that runs longer than a frame otherwise loses a
-- whole frame between the band-buffer swap and the next frame_start (three
-- frames a pass against the game's two - the board's ~20 passes a second
-- against ~29 list swaps). That is only safe if the buffer the game flips TO
-- is finished when it flips, and stays untouched until the next flip.
--
-- The reference does not answer this from source: MAME latches the render list
-- once per frame (set_current_render_list) and draws it at screen update, so a
-- game that flipped first and finished writing afterwards would still render
-- correctly in MAME - and would break a design that starts at the flip.
--
-- So measure it. Tap every V60 write into the two display-list buffers
-- (0x600000 / 0x610000, 32 K words each) and to listctl (0x680000). For each
-- flip record where in the frame it landed and, in the frames that follow, how
-- many writes hit the NEWLY SELECTED buffer - before the next vblank, and over
-- the whole interval until the next flip - against how many hit the other one.
--
-- Manual mode (bit 2 clear) is what vr uses, so the select is bit 3 of the
-- written value; bit 6 is a mirror of it.
local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]
-- The screen's tag is not assumed: a nil here aborted the flip callback
-- silently on the first run, after the flip count and before the counters
-- were reset, and the result read as cumulative nonsense.
local scr = nil
for tag, s in pairs(manager.machine.screens) do
    print("screen: " .. tag)
    if scr == nil then scr = s end
end
local function vpos()
    if scr == nil then return -1 end
    local ok, v = pcall(function() return vpos() end)
    return ok and v or -2
end

frames      = 0
flips       = 0
cur_sel     = -1          -- buffer the game has selected (bit 3)
w_sel       = 0           -- writes into the SELECTED buffer since the flip
w_sel_pre   = 0           -- ...of which before the first vblank after the flip
w_other     = 0           -- writes into the other buffer since the flip
seen_vbl    = false
flip_vpos   = {}
sel_pre_h   = {}          -- histogram: writes to the selected buffer before vblank
sel_tot_h   = {}
other_h     = {}
first_other_vpos = {}     -- when the game starts filling the next list
first_other_seen = false
frame_of_flip = 0

local function bump(h, k) h[k] = (h[k] or 0) + 1 end

tap_dl = sp:install_write_tap(0x600000, 0x61ffff, "dl", function(offset, data, mask)
    if cur_sel < 0 then return end
    local buf = (offset >= 0x610000) and 1 or 0
    if buf == cur_sel then
        w_sel = w_sel + 1
        if not seen_vbl then w_sel_pre = w_sel_pre + 1 end
    else
        w_other = w_other + 1
        if not first_other_seen then
            first_other_seen = true
            bump(first_other_vpos, string.format("f+%d v%03d", frames - frame_of_flip, vpos()))
        end
    end
end)

tap_lc = sp:install_write_tap(0x680000, 0x680003, "lc", function(offset, data, mask)
    if offset ~= 0x680000 then return end
    local sel = ((data & 8) ~= 0) and 1 or 0
    if cur_sel >= 0 and sel ~= cur_sel then
        -- a flip: close the books on the previous interval
        bump(sel_pre_h, w_sel_pre)
        bump(sel_tot_h, w_sel)
        bump(other_h, w_other)
        flips = flips + 1
        bump(flip_vpos, vpos())
        w_sel = 0; w_sel_pre = 0; w_other = 0
        seen_vbl = false; first_other_seen = false
        frame_of_flip = frames
    end
    cur_sel = sel
end)

local function dump(name, h, n)
    print("  " .. name)
    local ks = {}
    for k in pairs(h) do ks[#ks+1] = k end
    table.sort(ks, function(a, b)
        if type(a) == type(b) then return a < b end
        return tostring(a) < tostring(b)
    end)
    local shown = 0
    for _, k in ipairs(ks) do
        print(string.format("    %-12s %d", tostring(k), h[k]))
        shown = shown + 1
        if shown >= n then break end
    end
end

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    seen_vbl = true
    if frames >= 2000 then
        print(string.format("=== %d frames, %d flips ===", frames, flips))
        dump("flip scanline (vpos at the listctl write):", flip_vpos, 40)
        dump("writes to the NEWLY SELECTED buffer between the flip and the next vblank:", sel_pre_h, 20)
        dump("writes to the SELECTED buffer over the whole interval to the next flip:", sel_tot_h, 20)
        dump("writes to the OTHER buffer over the interval (the next list being built):", other_h, 20)
        dump("first write to the other buffer, frames after the flip and scanline:", first_other_vpos, 20)
        manager.machine:exit()
    end
end)
