-- Dump the reference's tile RAM and palette, for a word-for-word diff against
-- what our CPU builds.
--
-- WHY: every measurement on the Model 1 core so far has been an aggregate -
-- pixels won per layer, character writes, non-zero mask writes - and none of
-- them can say WHICH WORD is wrong. The Model 2 core had the same symptom and
-- named it in one step by diffing contents: "tile RAM differs in 13 words of
-- 32768 ... pal[1] <= 0000 at instruction 1713595".
--
-- Tile RAM is 0x700000 (32768 16-bit words) and the palette 0x900000..0x903fff
-- (8192 words) - model1.cpp:1007 maps the latter with .share(m_paletteram16).
--
-- Two flags are not optional: -skip_gameinfo, or the warning screen blocks
-- autoboot and this never loads, and -autoboot_delay 0. The notifier is a
-- GLOBAL or the subscription is collected and the callback silently stops.
--
--   mame vr -rompath ~/roms -skip_gameinfo -autoboot_delay 0 -video none \
--           -sound none -nothrottle -seconds_to_run 16 -autoboot_script this.lua
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local FRAME = tonumber(os.getenv("M1_DUMP_FRAME") or "900")
nf = 0

notif = emu.add_machine_frame_notifier(function()
    nf = nf + 1
    if nf ~= FRAME then return end

    local f = io.open("mame_tram.hex", "w")
    for i = 0, 32767 do
        f:write(string.format("%04x\n", sp:read_u16(0x700000 + i*2)))
    end
    f:close()

    f = io.open("mame_pal.hex", "w")
    for i = 0, 8191 do
        f:write(string.format("%04x\n", sp:read_u16(0x900000 + i*2)))
    end
    f:close()

    print(string.format("dumped tile RAM and palette at frame %d", nf))
end)
