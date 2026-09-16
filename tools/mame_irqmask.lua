-- WHEN does the game unmask the sound interrupt?
--
-- 0xe00002 is the IRQ mask (model1.cpp irq_mask_w). A SET bit SUPPRESSES that
-- source, and bit 3 is the sound USART's TxRDY. Both MAME and our m1_glue reset
-- it to 0xff -- everything masked -- so the game has to clear bit 3 before any
-- sound byte can be sent. Our full-RTL sim still reads irq_mask[3]=1 at 0.75 s
-- with txrdy=1, so it never gets unmasked and the sound handler never runs.
local n, first = 0, nil
local seq = {}
function tap()
  local cpu = manager.machine.devices[":maincpu"]
  for _, sp in ipairs({"program", "io"}) do
    local s = cpu.spaces[sp]
    if s then
      _G["t_"..sp] = s:install_write_tap(0xe00000, 0xe00005, "irq"..sp,
        function(offset, data, mask)
          n = n + 1
          if #seq < 16 then
            seq[#seq+1] = string.format("%06x=%02x", offset, data & 0xff)
          end
          if not first then first = manager.machine.screens[":screen"]:frame_number() end
          return data
        end)
    end
  end
end
local f = 0
function fr()
  f = f + 1
  if f % 180 == 0 then
    print(string.format("IRQMASK frame %d: writes=%d first=%s", f, n, tostring(first)))
    print("   "..table.concat(seq, " "))
  end
end
tap(); _G.notifier = emu.add_machine_frame_notifier(fr)
