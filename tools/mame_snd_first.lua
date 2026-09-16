-- WHEN does the V60 first write the sound USART, and how often after that?
--
-- Our full-RTL sim shows the sound 68000 booting and idling with zero commands
-- received, and the V60 still in the I/O-board handshake loop at 0.75 s. Before
-- running a longer simulation we need to know how long "long enough" is -- and
-- whether the game writes the USART at all during attract.
--
-- 0xC40000 is the uPD71051C on the MAIN board (model1.cpp:1014). Both the
-- program and IO spaces are tapped: a census of the wrong space once returned
-- "never" for the coprocessor and was wrong for two months.
local n, first_frame, first_pc = 0, nil, nil
local bytes = {}
function tap()
  local cpu = manager.machine.devices[":maincpu"]
  for _, sp in ipairs({"program", "io"}) do
    local s = cpu.spaces[sp]
    if s then
      _G["tap_"..sp] = s:install_write_tap(0xc40000, 0xc40007, "snd"..sp,
        function(offset, data, mask)
          n = n + 1
          if not first_frame then first_pc = cpu.state["PC"].value end
          if #bytes < 24 then bytes[#bytes+1] = string.format("%06x=%02x", offset, data & 0xff) end
          return data
        end)
    end
  end
end
local f = 0
function fr()
  f = f + 1
  if n > 0 and not first_frame then first_frame = f end
  if f % 120 == 0 then
    print(string.format("SNDCMD frame %d (%.2f s): writes=%d  first at frame %s (PC %s)",
      f, f/57.5, n, tostring(first_frame), first_pc and string.format("%08x", first_pc) or "-"))
    if #bytes > 0 then print("   first bytes: "..table.concat(bytes, " ")) end
  end
end
tap()
_G.notifier = emu.add_machine_frame_notifier(fr)
