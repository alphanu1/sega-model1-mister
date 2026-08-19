-- The reference TGP's A/D/ST at a chosen PC, so an FP comparison can be diffed
-- operand by operand instead of guessed at.
--
-- tgp_trace diverges at `0730 fadd` / `0731 brif ged #0x73a`: the reference falls
-- through, we branch. Operands are d = mem[0x43] and a = mem[3]. Either the operands
-- differ — both come from coprocessor RAM and the data ROM, which only just started
-- flowing — or fadd's flags are wrong. This says which.
local WATCH = tonumber(os.getenv("WATCH_TPC") or "0x0730")
local tgp = manager.machine.devices[":tgp_copro"]

frames, n = 0, 0
log = {}

-- Sampling on a frame notifier would miss it, so hook the program space: every
-- instruction fetch passes through, and the PC is the address.
local psp = tgp.spaces["program"]
tap = psp:install_read_tap(0, 0x7ff, "tpc", function(offset, data, mask)
    if offset == WATCH and #log < 10 then
        n = n + 1
        log[#log+1] = string.format("  hit %d  pc=%04x  A=%08x  B=%08x  D=%08x  ST=%08x",
            n, offset,
            tgp.state["A"].value, tgp.state["B"].value,
            tgp.state["D"].value, tgp.state["ST"].value)
    end
    return data
end)

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames >= 120 or #log >= 10 then
        print(string.format("=== reference TGP at pc %04x, %d hits in %d frames ===",
              WATCH, n, frames))
        for _, v in ipairs(log) do print(v) end
        manager.machine:exit()
    end
end)
