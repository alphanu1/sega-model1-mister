-- What does the V60 actually do with the I/O board's dual-port RAM, over time?
--
-- Two questions the handshake instrument left open:
--   1. Is there a SECOND handshake? Our boot trace recorded the V60 raising the
--      flag a second time with a different code; MAME's first instrument saw one
--      completion in 1800 frames, which is consistent either with "no second
--      handshake" or with "a second one that never completes".
--   2. Which DPRAM offsets does the game read once the handshake is done?
--
-- Logs every write to the flag with its PC and time, and censuses reads/writes
-- per DPRAM byte offset across three windows: boot, early attract, late attract.

local BASE, TOP = 0xc00000, 0xc00fff
local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]

frames = 0
rd, wr = {}, {}          -- [byte offset] = count, whole run
rd_w, wr_w = {}, {}      -- same, current window
flagwrites = {}
window = 1

local function now() return manager.machine.time:as_double() end
local function pc() return cpu.state["PC"].value end
local function bump(t, k) t[k] = (t[k] or 0) + 1 end

rtap = sp:install_read_tap(BASE, TOP, "dp_r", function(offset, data, mask)
    local off = (offset - BASE) >> 1          -- 16-bit bus, umask16(0x00ff)
    bump(rd, off); bump(rd_w, off)
    return data
end)

wtap = sp:install_write_tap(BASE, TOP, "dp_w", function(offset, data, mask)
    local off = (offset - BASE) >> 1
    bump(wr, off); bump(wr_w, off)
    if off == 0x20 and #flagwrites < 40 then
        flagwrites[#flagwrites+1] = string.format(
            "  f=%-5d t=%9.3f ms  pc=%06x  wrote %02x", frames, now()*1000, pc(), data & 0xff)
    end
    return data
end)

local function dump(label, t, tag)
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end
    table.sort(keys, function(a,b) return t[a] > t[b] end)
    local line, n = {}, 0
    for _,k in ipairs(keys) do
        n = n + 1
        if n > 14 then break end
        line[#line+1] = string.format("%02x:%d", k, t[k])
    end
    print(string.format("  %-22s %s %s", label, tag, table.concat(line, " ")))
end

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames == 120 or frames == 600 or frames == 1800 then
        print(string.format("--- window %d, through frame %d ---", window, frames))
        dump("reads this window",  rd_w, "R")
        dump("writes this window", wr_w, "W")
        rd_w, wr_w = {}, {}
        window = window + 1
    end
    if frames >= 1800 then
        print("")
        print("=== every write to the flag at DPRAM 0x20 (V60 0xc00040) ===")
        for _,v in ipairs(flagwrites) do print(v) end
        print(string.format("  (%d flag writes total in 1800 frames)", wr[0x20] or 0))
        print("")
        print("=== whole run ===")
        dump("reads", rd, "R")
        dump("writes", wr, "W")
        manager.machine:exit()
    end
end)
