-- HOW OFTEN DOES THE REFERENCE PRODUCE NEW GEOMETRY?
--
-- Our 3D layer completes a render pass every second frame - 28.8 Hz over a
-- 57.52 Hz 2D layer - because the geometry cannot overlap the band fills. That
-- is either a limitation of our design or the rate the board itself runs at, and
-- the difference matters: one is a defect to chase and the other is the hardware.
--
-- model1_v.cpp:1351 says the second:
--
--     void model1_state::end_frame()
--     {
--         if((m_listctl[0] & 4) && (m_screen->frame_number() & 1))
--             m_listctl[0] ^= 0x40;
--     }
--
-- Bit 6 is the display-list buffer select and it only flips on ODD frames - so
-- when bit 2 is set, a new list is presented every SECOND frame and the geometry
-- rate is half the refresh rate by construction.
--
-- What is NOT in the source is whether Virtua Racing sets bit 2. If it does not,
-- bit 6 mirrors bit 3 and the game swaps by hand, at whatever rate it likes.
-- That is what this measures.
--
-- Reports: how bit 2 is set over the run, how many frames pass between buffer
-- flips, and the distribution of those gaps.
local sp = manager.machine.devices[":maincpu"].spaces["program"]

frames = 0
mode_auto = 0            -- frames with listctl bit 2 set
last_sel = -1
last_flip = 0
gaps = {}
flips = 0
writes = {}

-- The register is write-only from the bus's point of view for our purposes; read
-- it back through the CPU's program space, which is where model1.cpp maps it.
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    local v = sp:read_u16(0x680000)
    if (v & 4) ~= 0 then mode_auto = mode_auto + 1 end
    writes[string.format("%04x", v)] = (writes[string.format("%04x", v)] or 0) + 1

    local sel = (v & 0x40) ~= 0 and 1 or 0
    if last_sel >= 0 and sel ~= last_sel then
        local g = frames - last_flip
        gaps[g] = (gaps[g] or 0) + 1
        last_flip = frames
        flips = flips + 1
    end
    last_sel = sel

    if frames >= 2000 then
        print(string.format("=== listctl over %d frames ===", frames))
        print(string.format("  bit 2 (automatic double buffer) set on %d frames", mode_auto))
        print(string.format("  buffer flipped %d times", flips))
        print("  frames between flips:")
        local ks = {}
        for k in pairs(gaps) do ks[#ks+1] = k end
        table.sort(ks)
        for _,k in ipairs(ks) do
            print(string.format("    %d frames: %d times", k, gaps[k]))
        end
        print("  register values seen:")
        for k,v2 in pairs(writes) do print(string.format("    %s on %d frames", k, v2)) end
        print(string.format("\n  => new geometry at %.2f Hz of a 57.52 Hz refresh",
              57.52 * flips / frames))
        manager.machine:exit()
    end
end)
