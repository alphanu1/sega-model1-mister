-- WHICH PCs push words into the coprocessor's input FIFO, and what do they push?
--
-- Our V60 pushes four words where the reference pushes five; every word we do push
-- matches in order, and the missing one is 00000000, second in the sequence. The
-- pushes happen around ff97xx, BEFORE v60_trace's divergence at 26,945 — so either
-- our V60 executes the same instructions and a write is not becoming a push, or the
-- trace is masking a divergence. This says which, by naming the PC of every push.
--
-- The FIFO is written through PROGRAM space at 0xd80000 (v60_copro_fifo_w): offset 0
-- latches the low half, offset 1 pushes the assembled 32-bit word. So the pushes are
-- the writes to 0xd80002, and the value is that write's data in the high half.
local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]

n, frames, lo = 0, 0, 0
log = {}

wtap = sp:install_write_tap(0xd80000, 0xd80003, "cpush", function(offset, data, mask)
    local off1 = (offset & 2) ~= 0
    if not off1 then
        lo = data & 0xffff
    else
        n = n + 1
        if #log < 24 then
            log[#log+1] = string.format("  push %2d  pc=%06x  %04x_%04x",
                                        n, cpu.state["PC"].value, data & 0xffff, lo)
        end
    end
    return data
end)

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames >= 30 then
        print(string.format("=== %d pushes into the copro input FIFO, %d frames ===", n, frames))
        for _, v in ipairs(log) do print(v) end
        manager.machine:exit()
    end
end)
