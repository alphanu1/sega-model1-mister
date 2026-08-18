-- Does the REFERENCE toggle pair 2/3's ctrl the way our board does, and what does
-- it have set when ctrl is zero that would stop tilemap 2 painting the screen?
--
-- tile_ram word W is at V60 byte 0x700000 + 2W.
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local function tw(w) return sp:read_u16(0x700000 + 2*w) end

frames, n_zero, n_win, n_other = 0, 0, 0, 0
samples = {}
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    local ctrl = tw(0x5006)
    local mode = (ctrl >> 13) & 3
    if mode == 0 then n_zero = n_zero + 1 else n_win = n_win + 1 end

    -- On a ctrl==0 frame, record what else is set: map 2's own registers, map 3's,
    -- and the first row-mask words for the 2/3 pair at 0x6800.
    if mode == 0 and #samples < 6 and frames > 300 then
        local content = 0
        for i = 0, 0xfff, 4 do
            local v = tw(0x2000 + i)
            if v ~= 0 and (v & 0x3fff) ~= 0x20 then content = content + 1 end
        end
        samples[#samples+1] = string.format(
          "f=%d ctrl=%04x hscr2=%04x vscr3=%04x hscr3=%04x mask6800=%04x %04x %04x %04x map2content=%d/1024",
          frames, ctrl, tw(0x5002), tw(0x5007), tw(0x5003),
          tw(0x6800), tw(0x6801), tw(0x6802), tw(0x6803), content)
    end
    if frames % 600 == 0 then
        print(string.format("f=%d ctrl==0 on %d frames, window mode on %d (%.1f%% zero)",
              frames, n_zero, n_win, 100*n_zero/frames))
        if frames >= 2400 then
            for _,v in ipairs(samples) do print("  "..v) end
            manager.machine:exit()
        end
    end
end)
