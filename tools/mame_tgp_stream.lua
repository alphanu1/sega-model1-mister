-- Capture EVERYTHING the V60 says to the coprocessor and everything it hears
-- back, in order, from reset - so the stream can be replayed into our TGP
-- alone (sim/tgp/tb_tgp_replay.cpp) and every answer checked against MAME's.
--
-- The coprocessor's inputs are the command FIFO, the copro RAM the V60 writes
-- through 0xd00000/0xd20000, and its ROMs. Nothing else. So with the same
-- stream in, the answers must be identical, and the first answer that is not
-- names the handler at fault without any V60 timing in the way.
--
-- The interface is mapped into BOTH address spaces (model1.cpp's program map
-- and io map): the game reaches it with in.w as well as with plain loads, and
-- a census of one space returns half the traffic and looks like an answer.
--
-- Raw accesses are logged; tools/tgp_stream_cook.py applies MAME's latch and
-- auto-increment rules (model1_m.cpp) to turn them into events.
--
--   S <space> R|W <byte addr> <data16> <mask16>
--   F <frame>
--
-- Environment: TS_FRAMES (stop after), TS_OUT (file), PRESS / HOLD as in
-- mame_geo_census.lua.

local cpu = manager.machine.devices[":maincpu"]
local out = io.open(os.getenv("TS_OUT") or "tgp_stream.txt", "w")
TS_FRAMES = tonumber(os.getenv("TS_FRAMES") or "1300")

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
    print("tgp_stream: no input field named '" .. name .. "'")
end

taps = {}
local function tap(spname, sp, lo, hi)
    taps[#taps+1] = sp:install_write_tap(lo, hi, "tsw" .. spname .. lo, function(offset, data, mask)
        out:write(string.format("%s W %06x %04x %04x\n", spname, offset, data & 0xffff, mask & 0xffff))
        return data
    end)
    taps[#taps+1] = sp:install_read_tap(lo, hi, "tsr" .. spname .. lo, function(offset, data, mask)
        out:write(string.format("%s R %06x %04x %04x\n", spname, offset, data & 0xffff, mask & 0xffff))
        return data
    end)
end
for _, spn in ipairs({"program", "io"}) do
    local sp = cpu.spaces[spn]
    if sp then
        local s = (spn == "program") and "P" or "I"
        tap(s, sp, 0xd00000, 0xd1ffff)
        tap(s, sp, 0xd20000, 0xd3ffff)
        tap(s, sp, 0xd80000, 0xd9ffff)
    end
end

-- THE COPROCESSOR'S OWN PUSHES into the output FIFO, at data 0x400. These are
-- the answers, and they are clean: a push never fails (MAME queues the
-- overflow and halts the TGP after it), where a V60 pop of an EMPTY FIFO
-- stalls the V60, returns 0 and is retried - so the V60's reads carry
-- phantom zeros and cannot be the reference.
local tsp = manager.machine.devices[":tgp_copro"].spaces["data"]
taps[#taps+1] = tsp:install_write_tap(0x400, 0x400, "tsans", function(offset, data, mask)
    out:write(string.format("T %08x\n", data & 0xffffffff))
    return data
end)

frames = 0
notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    out:write(string.format("F %d\n", frames))
    for _, p in ipairs(presses) do
        if frames == p.at then local fl = field(p.name); if fl then fl:set_value(1) end end
        if frames == p.at + p.len then local fl = field(p.name); if fl then fl:clear_value() end end
    end
    for _, h in ipairs(holds) do
        if frames >= h.at then local fl = field(h.name); if fl then fl:set_value(1) end end
    end
    if frames >= TS_FRAMES then
        out:close()
        manager.machine:exit()
    end
end)
