-- WHICH CODE writes the row mask, and what does it write?
--
-- The reference writes 48 words per frame into tile RAM 0x6000 and our V60 writes
-- NONE (m1_boot: "row mask 0x6000: 0/2048 nonzero"). A zero mask hides category-1
-- content and our tilemap 0 holds 370 category-1 tiles, so this is a live
-- candidate for the missing text rather than a curiosity.
--
-- Knowing the PCs that write it turns "why don't we write it" into a question the
-- boot trace can answer directly: does our V60 ever reach them?
-- WORD 0x6000 IS BYTE 0x70C000. Tapping 0x706000 taps WORD 0x3000 — tilemap 3 —
-- and the first run of this script did exactly that, reporting 2048 words of a
-- uniform 0x3e12 which is tilemap 3's flat fill. The factor of two is the easiest
-- slip to make here and it produces a confident, wrong answer.
local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]

frames, total = 0, 0
pcs = {}          -- writing PC -> count
addrs = {}        -- tile word -> last value
first = {}

wtap = sp:install_write_tap(0x70c000, 0x70dfff, "mw", function(offset, data, mask)
    local w = (offset - 0x700000) >> 1
    local pc = cpu.state["PC"].value
    total = total + 1
    pcs[pc] = (pcs[pc] or 0) + 1
    addrs[w] = data
    -- THE FIRST NON-ZERO WRITES ARE THE INTERESTING ONES. Most of the 28,432
    -- writes are zeros, so a log of "the first writes" is a log of clearing.
    -- Which frame the mask first gains content bounds how long a simulation has
    -- to run before its absence means anything.
    if data ~= 0 and #first < 20 then
        first[#first+1] = string.format("  f=%-4d pc=%06x  word %04x (line %d) <- %04x",
                                        frames, pc, w, (w & 0x7ff) >> 2, data)
    end
    return data
end)

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames >= 900 then
        print(string.format("=== %d row-mask writes over %d frames ===", total, frames))
        local ks = {}
        for k in pairs(pcs) do ks[#ks+1] = k end
        table.sort(ks, function(a,b) return pcs[a] > pcs[b] end)
        print("writing PCs, busiest first:")
        for i = 1, math.min(#ks, 10) do
            print(string.format("  pc=%06x  %d writes", ks[i], pcs[ks[i]]))
        end
        -- ONLY THE NON-ZERO WORDS. Printing all 4096 buries the answer: most of
        -- the reference's 28,432 writes are ZEROS, so the write count and the
        -- end state say different things and it is the end state our tile RAM
        -- census compares against.
        local nz_lo, nz_hi, words = 0, 0, {}
        for w, v in pairs(addrs) do
            if v ~= 0 then
                words[#words+1] = w
                if w < 0x6800 then nz_lo = nz_lo + 1 else nz_hi = nz_hi + 1 end
            end
        end
        table.sort(words)
        print(string.format("\nnon-zero: %d in 0x6000-0x67ff (pair 0/1), %d in 0x6800-0x6fff (pair 2/3)",
              nz_lo, nz_hi))
        print("the non-zero words:")
        local line = {}
        for _, w in ipairs(words) do
            line[#line+1] = string.format("%04x:%04x", w, addrs[w])
            if #line == 8 then print("  "..table.concat(line, " ")); line = {} end
        end
        if #line > 0 then print("  "..table.concat(line, " ")) end
        print("\nfirst NON-ZERO writes:")
        for _, v in ipairs(first) do print(v) end
        manager.machine:exit()
    end
end)
