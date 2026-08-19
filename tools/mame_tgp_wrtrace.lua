-- VALUE-LEVEL trace of the reference TGP: every data-memory write, in order.
--
-- The PC-stream lockstep (make tgp_trace) can only catch a wrong value when it
-- changes control flow, which is why it stops at `0731 brif ged` — the error is
-- upstream in the FP chain at 06EE-070C and invisible to a PC diff.
--
-- Getting per-instruction REGISTERS out of MAME failed three ways: program-space taps
-- never fire, `trace`'s {tracelog} action emits nothing, and bpset actions never fired.
-- Data-space WRITE taps do work, and the microcode stores its results to data memory
-- (`mov d, $0x43` and friends), so the write stream is the value trace that matters.
--
-- Output is one line per write, deliberately in the same shape our side emits so the
-- two can be diffed directly.
local tgp = manager.machine.devices[":tgp_copro"]
local dsp = tgp.spaces["data"]

frames, n = 0, 0
local out = {}

-- Resolve the PC accessor once. Prefer GENPC; fall back to PC; if neither exists,
-- report zero rather than throwing inside a tap where the error is invisible.
local pcreg
do
    local st = tgp.state
    if st["GENPC"] then      pcreg = function() return st["GENPC"].value end
    elseif st["PC"] then     pcreg = function() return st["PC"].value end
    else                     pcreg = function() return 0 end
    end
end

-- x0 rides along for the same reason. After the lab fix the streams agreed on every
-- VALUE up to write 41 and then differed on data[0x66], which is a plain `mov x0, $0x66`
-- - the fault is in an address register that no write can show directly. Resolved the
-- same defensive way as the PC: a bad state key throws INSIDE the tap, where MAME
-- swallows the error and the trace simply stops with no message.
local function reg(names)
    local st = tgp.state
    for _, n in ipairs(names) do
        if st[n] then return function() return st[n].value end end
    end
    return function() return 0 end
end
local x0reg = reg{"X0", "x0"}
local areg  = reg{"A", "a"}
local dreg  = reg{"D", "d"}

-- The PC is recorded with every write. Without it, a divergence in the write stream
-- says only THAT the streams differ, not which instruction differs — and on
-- 2026-08-19 that cost several hours: write 22 looked like a corrupted value and was
-- actually an extra store from a different instruction, with the correct store
-- arriving at write 27.
tap = dsp:install_write_tap(0, 0x3ff, "wr", function(offset, data, mask)
    n = n + 1
    if n <= 60000 then
        -- STATE KEY, CAREFULLY. mb86233.cpp registers STATE_GENPCBASE as "PC" with
        -- .noshow(), and STATE_GENPC as "GENPC". Asking for the wrong one throws
        -- INSIDE the tap callback, which MAME swallows silently: the write counter
        -- still incremented to 32,474 while not one line was produced, so the
        -- failure looked like "no writes" rather than "bad key". Resolved once,
        -- outside the callback, with a fallback.
        out[#out+1] = string.format("TW %04x %08x pc=%04x x0=%04x a=%08x d=%08x",
                                    offset, data, pcreg(), x0reg(), areg(), dreg())
    end
    return data
end)

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames >= 900 or n >= 60000 then
        print(string.format("=== %d data writes in %d frames ===", n, frames))
        for _, v in ipairs(out) do print(v) end
        manager.machine:exit()
    end
end)
