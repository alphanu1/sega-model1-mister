-- Does the V60 talk to the coprocessor through its I/O SPACE?
--
-- model1.cpp maps the whole copro interface into AS_IO, not program space:
--   0xd00000 copro RAM address   0xd20000 copro RAM data
--   0xd80000 FIFO (read+write)   0xdc0000 FIFO-in status
--
-- CLAUDE.md records "does the V60 read the coprocessor back — measurement said
-- NEVER, in 2,500 accesses". That census was of the PROGRAM space, which cannot
-- see an `in.w`. v60_trace diverges into a block ending in `in.w [R23], R2`, so
-- the question is open again and this is the space to ask it in.
local cpu = manager.machine.devices[":maincpu"]
local iosp = cpu.spaces["io"]
if not iosp then
    print("NO IO SPACE on :maincpu — spaces present:")
    for k in pairs(cpu.spaces) do print("  "..k) end
    return
end

frames, nr, nw = 0, 0, 0
rd_by_addr, wr_by_addr, rd_by_pc, wr_by_pc = {}, {}, {}, {}
first_rd = {}

local function bump(t, k) t[k] = (t[k] or 0) + 1 end

rtap = iosp:install_read_tap(0, 0xffffff, "ior", function(offset, data, mask)
    nr = nr + 1
    bump(rd_by_addr, offset & 0xfffffc)
    bump(rd_by_pc, cpu.state["PC"].value)
    if #first_rd < 14 then
        first_rd[#first_rd+1] = string.format("  f=%-4d pc=%06x  IN  %06x -> %08x",
                                              frames, cpu.state["PC"].value, offset, data)
    end
    return data
end)

wtap = iosp:install_write_tap(0, 0xffffff, "iow", function(offset, data, mask)
    nw = nw + 1
    bump(wr_by_addr, offset & 0xfffffc)
    bump(wr_by_pc, cpu.state["PC"].value)
    return data
end)

local function top(t, label)
    local ks = {}
    for k in pairs(t) do ks[#ks+1] = k end
    table.sort(ks, function(a,b) return t[a] > t[b] end)
    print(label)
    for i = 1, math.min(#ks, 8) do
        print(string.format("    %06x  %d", ks[i], t[ks[i]]))
    end
    if #ks == 0 then print("    (none)") end
end

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames >= 600 then
        print(string.format("=== V60 I/O SPACE over %d frames: %d reads, %d writes ===",
              frames, nr, nw))
        top(rd_by_addr, "  reads by address:")
        top(wr_by_addr, "  writes by address:")
        top(rd_by_pc,   "  reads by PC:")
        top(wr_by_pc,   "  writes by PC:")
        print("\n  first reads:")
        for _, v in ipairs(first_rd) do print(v) end
        manager.machine:exit()
    end
end)
