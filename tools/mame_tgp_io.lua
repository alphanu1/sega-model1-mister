-- What does the REFERENCE's TGP read from its own I/O space, in order?
--
-- tb_m1_boot expects the first two coprocessor data-ROM reads to be
-- "00000030 00012e00" and reports ours as "3f800000 00012e00", flagging word 0 as
-- wrong. But the actual ROM files byte-interleaved per ROM_LOAD32_BYTE give
-- 0x3f800000 at word 0 — so either MAME is not reading word 0 there, or the
-- expectation is a bad measurement. copro_data_r ORs in m_copro_data_base:
--
--     index = (m_copro_data_base & ~0x7fff) | offset;
--
-- so a non-zero base moves the window and offset 0 is not word 0. Log the TGP's
-- io accesses in order and settle it.
local tgp = manager.machine.devices[":tgp_copro"]
if not tgp then
    print("no :tgp_copro — devices containing 'copro':")
    for tag in pairs(manager.machine.devices) do
        if tag:find("copro") then print("  "..tag) end
    end
    return
end
local iosp = tgp.spaces["io"]
if not iosp then
    print("no io space on :tgp_copro — spaces:")
    for k in pairs(tgp.spaces) do print("  "..k) end
    return
end

n, frames = 0, 0
log = {}

rtap = iosp:install_read_tap(0, 0xffff, "tgpio_r", function(offset, data, mask)
    n = n + 1
    if #log < 30 then
        log[#log+1] = string.format("  %2d  R io %04x -> %08x", n, offset, data)
    end
    return data
end)
wtap = iosp:install_write_tap(0, 0xffff, "tgpio_w", function(offset, data, mask)
    n = n + 1
    if #log < 30 then
        log[#log+1] = string.format("  %2d  W io %04x <- %08x", n, offset, data)
    end
    return data
end)

notif = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames >= 30 then
        print(string.format("=== first TGP I/O accesses (%d total in %d frames) ===", n, frames))
        for _, v in ipairs(log) do print(v) end
        manager.machine:exit()
    end
end)
