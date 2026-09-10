-- HOW OFTEN DOES THE SOUND USART'S INTERRUPT ACTUALLY FIRE?
--
-- Level 3 is raised by the uPD71051C's TxRDY (model1.cpp's sound_ready_w), and
-- vf's level 3 handler at 0xfe3f5c pumps the game's sound queue out through it.
-- Our core had no USART at all until 2026-09-10, so that interrupt never
-- existed here and the queue could never drain.
--
-- The rate was then quoted as "once in two seconds" from the v60_trace window -
-- which is BOOT, where the game is silent. That is a measurement of the wrong
-- interval: a fighting game makes noise continuously once it is running, so the
-- gameplay rate is the one that matters and it was never measured.
--
-- Counts every byte the queue pump writes to the USART's data register, and
-- every write to the irq mask, so the unmask/mask cycle around a burst of sound
-- is visible too. One byte is approximately one level 3 interrupt: the handler
-- writes one and returns, and TxRDY re-raises when the character has gone.
local cpu  = manager.machine.devices[":maincpu"]
local prog = cpu.spaces["program"]

frames, bytes, mask_wr = 0, 0, 0
first, per_frame, mask_hist = {}, {}, {}
unmasked_frames = 0
last_mask = nil

local function bump(t, k) t[k] = (t[k] or 0) + 1 end

-- 0xc40000 data, 0xc40002 command; .umask16(0x00ff) so the low byte of each.
utap = prog:install_write_tap(0xc40000, 0xc40003, "usart", function(offset, data, mask)
    if (offset & 2) == 0 then
        bytes = bytes + 1
        bump(per_frame, frames)
        if #first < 12 then
            first[#first+1] = string.format("  f=%-5d pc=%06x  data <- %02x",
                                            frames, cpu.state["PC"].value, data & 0xff)
        end
    end
    return data
end)

-- 0xe00002 is the per-level irq mask, active low: a SET bit blocks that level.
mtap = prog:install_write_tap(0xe00002, 0xe00003, "irqmask", function(offset, data, mask)
    local v = data & 0xff
    mask_wr = mask_wr + 1
    if v ~= last_mask then bump(mask_hist, v); last_mask = v end
    return data
end)

notifier = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if last_mask and (last_mask & 8) == 0 then
        unmasked_frames = unmasked_frames + 1
    end
    if frames >= (tonumber(os.getenv("FRAMES") or "1800")) then
        print("")
        print(string.format("sound_irq: frames=%d  usart data bytes=%d  (%.2f a frame)",
                            frames, bytes, bytes / frames))
        print(string.format("           irq_mask writes=%d, level 3 UNMASKED on %d of %d frames (%.1f%%)",
                            mask_wr, unmasked_frames, frames,
                            100.0 * unmasked_frames / frames))
        print("  first bytes:")
        for _, l in ipairs(first) do print(l) end
        -- Which frames carried traffic, so a burst is distinguishable from a
        -- steady trickle.
        local busy, maxb = 0, 0
        for _, n in pairs(per_frame) do
            busy = busy + 1
            if n > maxb then maxb = n end
        end
        print(string.format("  frames with at least one byte: %d of %d; busiest frame sent %d",
                            busy, frames, maxb))
        local ks = {}
        for k in pairs(mask_hist) do ks[#ks+1] = k end
        table.sort(ks)
        local parts = {}
        for _, k in ipairs(ks) do
            parts[#parts+1] = string.format("%02x x%d%s", k, mask_hist[k],
                                            (k & 8) == 0 and " (L3 on)" or "")
        end
        print("  mask values written: " .. table.concat(parts, ", "))
        manager.machine:exit()
    end
end)
