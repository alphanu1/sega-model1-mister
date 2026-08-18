-- Is the per-line H-scroll table actually reached, and where does scrolling come
-- from at all?
--
-- m1_video implements everything in segaic24's draw_common EXCEPT item 3: the
-- per-line H-scroll table at tile RAM 0x4000 + 0x200*layer, taken when
-- hscr & 0x8000. Its comment claims "nothing measured reaches it" and "the game
-- keeps hscr below 0x0200". CLAUDE.md names it as the likeliest home of the
-- missing scrolling, so those two claims are in direct conflict and only the
-- reference can settle it.
--
-- Reports, per frame: all eight scroll/ctrl words, whether any hscr has bit 15
-- set, and how much content sits in the 0x4000 per-line table.
--
-- tile_ram word W is at V60 byte 0x700000 + 2W.
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local function tw(w) return sp:read_u16(0x700000 + 2*w) end

frames = 0
bit15 = {0,0,0,0}          -- per layer: frames with hscr bit 15 set
moved = {0,0,0,0}          -- per layer: frames where hscr changed from the last
prev  = {-1,-1,-1,-1}
table_nonzero_max = 0
ctrl_seen = {}
samples = {}

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    for L = 0, 3 do
        local h = tw(0x5000 + L)
        if (h & 0x8000) ~= 0 then bit15[L+1] = bit15[L+1] + 1 end
        if prev[L+1] >= 0 and h ~= prev[L+1] then moved[L+1] = moved[L+1] + 1 end
        prev[L+1] = h
    end
    local c0, c2 = tw(0x5004), tw(0x5006)
    local key = string.format("%04x/%04x", c0, c2)
    ctrl_seen[key] = (ctrl_seen[key] or 0) + 1

    -- how many words of the per-line tables hold anything
    local nz = 0
    for i = 0, 0x7ff do if tw(0x4000 + i) ~= 0 then nz = nz + 1 end end
    if nz > table_nonzero_max then table_nonzero_max = nz end

    if frames % 400 == 0 then
        samples[#samples+1] = string.format(
          "f=%-5d hscr %04x %04x %04x %04x  vscr %04x %04x %04x %04x  0x4000 nonzero=%d",
          frames, tw(0x5000), tw(0x5001), tw(0x5002), tw(0x5003),
          tw(0x5004), tw(0x5005), tw(0x5006), tw(0x5007), nz)
    end
    if frames >= 2000 then
        print("=== per-layer hscr over 2000 frames ===")
        for L = 0, 3 do
            print(string.format("  layer %d: bit15 set on %d frames, hscr CHANGED on %d frames",
                  L, bit15[L+1], moved[L+1]))
        end
        print(string.format("\n0x4000 per-line table: max %d of 2048 words non-zero", table_nonzero_max))
        print("\n=== ctrl pairs (even vscr of 0/1 and 2/3) seen ===")
        for k,v in pairs(ctrl_seen) do print(string.format("  %s on %d frames", k, v)) end
        print("")
        for _,v in ipairs(samples) do print("  "..v) end
        manager.machine:exit()
    end
end)
