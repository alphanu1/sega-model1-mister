-- How long does the REAL I/O board take to answer, and does it keep answering?
--
-- m1_ioboard clears the flag at 0xc00040 after LATENCY = 64 cycles, a figure its
-- own comment admits is a guess. MAME runs the actual Z80 (4 MHz, EPR-14869)
-- behind an mb8421 dual-port RAM, so it can be asked instead of assumed.
--
-- Measures, per handshake: the V60's write, how many times it polls, and the
-- wall time until the poll first reads back a cleared flag. Also counts
-- handshakes per frame, which answers whether this is a boot-only exchange or a
-- keep-alive the game runs forever.
--
-- V60 is 32_MHz_XTAL/2 = 16 MHz, so 1 us = 16 V60 cycles.

local FLAG = 0xc00040        -- 16-bit bus: taps must be word-aligned, so the range is FLAG..FLAG+1
local FLAG_HI = 0xc00041   -- the DPRAM byte is umask16(0x00ff), the low lane
local cpu  = manager.machine.devices[":maincpu"]
local sp   = cpu.spaces["program"]

frames, nhs, polls, pending, t_write, cmd_at_write = 0, 0, 0, false, 0, 0
lat_us, poll_n, hs_frame, samples = {}, {}, {}, {}
first_frame_of_hs = 0

local function now() return manager.machine.time:as_double() end

wtap = sp:install_write_tap(FLAG, FLAG_HI, "iohs_w", function(offset, data, mask)
    if (data & 0xff) ~= 0 then
        pending, t_write, polls, first_frame_of_hs = true, now(), 0, frames
        cmd_at_write = data & 0xff
    end
    return data
end)

rtap = sp:install_read_tap(FLAG, FLAG_HI, "iohs_r", function(offset, data, mask)
    if not pending then return data end
    polls = polls + 1
    if (data & 0xff) == 0 then
        local us = (now() - t_write) * 1e6
        nhs = nhs + 1
        lat_us[#lat_us+1] = us
        poll_n[#poll_n+1] = polls
        hs_frame[#hs_frame+1] = first_frame_of_hs
        if #samples < 12 then
            samples[#samples+1] = string.format(
                "  hs %-3d frame %-5d cmd=%02x  %8.1f us = %7.0f V60 cycles  polls=%d",
                nhs, first_frame_of_hs, cmd_at_write, us, us*16, polls)
        end
        pending = false
    end
    return data
end)

local function stats(t)
    if #t == 0 then return 0,0,0 end
    local lo, hi, sum = t[1], t[1], 0
    for _,v in ipairs(t) do
        if v < lo then lo = v end
        if v > hi then hi = v end
        sum = sum + v
    end
    return lo, sum/#t, hi
end

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames % 300 == 0 then
        local lo, av, hi = stats(lat_us)
        local plo, pav, phi = stats(poll_n)
        -- how many of the last 300 frames contained a handshake
        local recent = 0
        for _,f in ipairs(hs_frame) do if f > frames - 300 then recent = recent + 1 end end
        print(string.format(
          "f=%d handshakes=%d (%d in last 300 frames)  latency us min/avg/max %.1f/%.1f/%.1f (V60 cycles %.0f/%.0f/%.0f)  polls %d/%.1f/%d",
          frames, nhs, recent, lo, av, hi, lo*16, av*16, hi*16, plo, pav, phi))
    end
    if frames >= 1800 then
        print("")
        print("=== first handshakes ===")
        for _,v in ipairs(samples) do print(v) end
        print("")
        print("=== last 8 handshakes ===")
        for i = math.max(1, nhs-7), nhs do
            print(string.format("  hs %-4d frame %-5d %8.1f us = %7.0f V60 cycles  polls=%d",
                  i, hs_frame[i], lat_us[i], lat_us[i]*16, poll_n[i]))
        end
        manager.machine:exit()
    end
end)
