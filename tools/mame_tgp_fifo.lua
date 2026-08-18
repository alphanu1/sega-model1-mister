-- What does the reference's TGP actually read out of its input FIFO?
--
-- tgp_trace has our coprocessor spinning in the command-dispatch loop:
--     0043: ldi #0x100, x1      ; the input FIFO in data space
--     0044: mov (x1), b
--     0045..0048: mask 0x3f, subtract $0xb
--     0049: brif !zrd #0x44     ; loop until it matches
-- The reference falls through after ONE iteration; we go round 41 times, so the
-- word we read is not the word it reads. Log its side.
local tgp = manager.machine.devices[":tgp_copro"]
local dsp = tgp.spaces["data"]

n, frames = 0, 0
log = {}
rtap = dsp:install_read_tap(0x100, 0x100, "fin", function(offset, data, mask)
    n = n + 1
    if #log < 20 then
        log[#log+1] = string.format("  %2d  f=%-4d data 0x100 -> %08x   (&0x3f = %02x)",
                                    n, frames, data, data & 0x3f)
    end
    return data
end)
-- and what it writes back out, since ours has never written anything
wtap = dsp:install_write_tap(0x400, 0x400, "fout", function(offset, data, mask)
    if #log < 20 then
        log[#log+1] = string.format("      f=%-4d data 0x400 <- %08x   (OUTPUT)", frames, data)
    end
    return data
end)

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames >= 60 then
        print(string.format("=== TGP input-FIFO reads: %d in %d frames ===", n, frames))
        for _, v in ipairs(log) do print(v) end
        manager.machine:exit()
    end
end)
