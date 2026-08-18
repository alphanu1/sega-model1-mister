-- Who writes a given byte, and what with?
--
-- v60_trace's divergence at instruction 25,682 is `cmp.b #1, 40DC8B` / `bne`:
-- the reference finds 1 there and falls into a block that writes a float to a
-- port and reads back with `in.w` — the coprocessor path — while we find not-1
-- and branch past it. So the byte is the decision and its writer is the cause.
--
-- ADDR is a BYTE address in the V60's program space. A 16-bit bus means the tap
-- range must be word-aligned, so it covers the containing word and the callback
-- picks the lane.
-- tonumber("0x40dc8b", 16) is NIL: an explicit base rejects the 0x prefix. No base.
local ADDR = tonumber(os.getenv("WATCH_ADDR") or "0x40dc8b")
local WORD = ADDR & ~1
local LANE = ADDR & 1

local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]

frames, nw = 0, 0
writers, first, last = {}, {}, {}

wtap = sp:install_write_tap(WORD, WORD + 1, "wb", function(offset, data, mask)
    -- Only count it when the lane we care about is actually being driven.
    local hit = (LANE == 0) and (mask & 0x00ff) ~= 0 or (LANE == 1) and (mask & 0xff00) ~= 0
    if not hit then return data end
    local byte = (LANE == 1) and ((data >> 8) & 0xff) or (data & 0xff)
    local pc = cpu.state["PC"].value
    nw = nw + 1
    writers[pc] = (writers[pc] or 0) + 1
    local line = string.format("  f=%-5d pc=%06x  <- %02x", frames, pc, byte)
    if #first < 12 then first[#first+1] = line end
    last[(nw % 8) + 1] = line
    return data
end)

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames >= 900 then
        print(string.format("=== byte %06x (word %06x lane %d): %d writes over %d frames ===",
              ADDR, WORD, LANE, nw, frames))
        local ks = {}
        for k in pairs(writers) do ks[#ks+1] = k end
        table.sort(ks, function(a,b) return writers[a] > writers[b] end)
        for i = 1, math.min(#ks, 8) do
            print(string.format("  pc=%06x  %d writes", ks[i], writers[ks[i]]))
        end
        print(string.format("\n  value now: %02x", (LANE == 1)
              and ((sp:read_u16(WORD) >> 8) & 0xff) or (sp:read_u16(WORD) & 0xff)))
        print("\nfirst writes:")
        for _, v in ipairs(first) do print(v) end
        print("\nmost recent:")
        for i = 1, 8 do if last[i] then print(last[i]) end end
        manager.machine:exit()
    end
end)
