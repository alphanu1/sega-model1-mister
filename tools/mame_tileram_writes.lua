-- What does the reference WRITE into tile RAM, per frame, and where?
--
-- Every 2D rendering rule is now either implemented here or measured irrelevant,
-- so the remaining difference is program state: which values our V60 puts in tile
-- RAM. This is the reference half of that comparison.
--
-- Our side, for the same question:
--   make m1_boot BOOT_CYCLES=150000000   -> "row mask 0x6000: 0/2048 nonzero"
--                                        -> "scroll/ctrl: [5000]..[5007] all 0000"
--   overlay row 1B                       -> tile words written per frame
--
-- tile_ram word W is at V60 byte 0x700000 + 2W, so the write tap covers
-- 0x700000-0x70dfff for words 0x0000-0x6fff.
local sp = manager.machine.devices[":maincpu"].spaces["program"]

frames = 0
-- per-region write counts, whole run and current frame
regions = {"maps 0000-3fff", "perline 4000-4fff", "scroll 5000-5007",
           "other 5008-5fff", "mask 6000-67ff", "mask 6800-6fff"}
tot, cur = {}, {}
for i = 1, #regions do tot[i] = 0; cur[i] = 0 end
scroll_words = {}      -- which of 0x5000-0x5007 get written, and how often
mask_words = 0
per_frame_samples = {}

local function region(w)
    if w < 0x4000 then return 1
    elseif w < 0x5000 then return 2
    elseif w < 0x5008 then return 3
    elseif w < 0x6000 then return 4
    elseif w < 0x6800 then return 5
    else return 6 end
end

wtap = sp:install_write_tap(0x700000, 0x70dfff, "tw", function(offset, data, mask)
    local w = (offset - 0x700000) >> 1
    local r = region(w)
    tot[r] = tot[r] + 1; cur[r] = cur[r] + 1
    if r == 3 then scroll_words[w] = (scroll_words[w] or 0) + 1 end
    if r == 5 or r == 6 then mask_words = mask_words + 1 end
    return data
end)

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames % 400 == 0 then
        local parts = {}
        for i = 1, #regions do parts[#parts+1] = string.format("%s=%d", regions[i], cur[i]) end
        per_frame_samples[#per_frame_samples+1] =
            string.format("f=%-5d this frame: %s", frames, table.concat(parts, "  "))
    end
    for i = 1, #regions do cur[i] = 0 end
    if frames >= 1600 then
        print("=== tile RAM writes over 1600 frames ===")
        for i = 1, #regions do
            print(string.format("  %-20s %8d total  %7.2f per frame", regions[i], tot[i], tot[i]/frames))
        end
        print("")
        print("=== which scroll/ctrl words are written ===")
        for w = 0x5000, 0x5007 do
            print(string.format("  %04x  %d writes  (%.2f/frame)  now=%04x",
                  w, scroll_words[w] or 0, (scroll_words[w] or 0)/frames,
                  sp:read_u16(0x700000 + 2*w)))
        end
        print(string.format("\n  row-mask writes total: %d", mask_words))
        print("")
        for _,v in ipairs(per_frame_samples) do print("  "..v) end
        manager.machine:exit()
    end
end)
