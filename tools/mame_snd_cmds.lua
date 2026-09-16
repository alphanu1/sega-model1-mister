-- WHAT THE V60 SENDS THE SOUND BOARD, captured from the reference.
--
-- Our standalone sound bench has no V60, so the 68000 sits in its idle loop and
-- the board makes only the low-level drone. MAME shows the real audio arriving
-- in bursts at ~35 s and ~65 s, which must be COMMANDED. Without the command
-- stream the bench cannot reproduce a burst, and every measurement taken from
-- it describes silence.
--
-- The V60 reaches the sound board through a uPD71051C at 0xC40000 on the MAIN
-- board (model1.cpp:1014). Tap the writes, print the bytes with timestamps, and
-- they can be replayed into tb_m1_sndboard's rx port.

local cpu = manager.machine.devices[":maincpu"]
if cpu == nil then print("SNDCMD: no maincpu"); return end
local sp = cpu.spaces["program"]

cmds  = {}
frames = 0

tap = sp:install_write_tap(0xc40000, 0xc40003, "sndcmd", function(offset, data, mask)
  -- The data register is the even address; the odd one is the control port.
  cmds[#cmds + 1] = string.format("%d:%02x", frames, data & 0xff)
  return data
end)

local ports = manager.machine.ioport.ports
local function press(fname, on)
  for tag, port in pairs(ports) do
    for fn, f in pairs(port.fields) do
      if fn:lower():find(fname) then f:set_value(on and 1 or 0) end
    end
  end
end

notif = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  -- INTO A RACE. The attract loop's commands produce only the drone; the sound
  -- EFFECTS are what a running car makes, and that is the state Ben tested.
  if frames == 300 then press("coin", true)  end
  if frames == 310 then press("coin", false) end
  if frames == 360 then press("start", true) end
  if frames == 372 then press("start", false) end
  if frames % 600 == 0 then
    print(string.format("SNDCMD: frame %d, %d bytes so far", frames, #cmds))
    io.flush()
  end
  if frames == 1150 then     -- ~45 s, past the first burst at ~35 s
    print("== SNDCMD bytes (frame:byte) ==")
    local line = {}
    for i = 1, #cmds do
      line[#line + 1] = cmds[i]
      if #line == 16 then print(table.concat(line, " ")); line = {} end
    end
    if #line > 0 then print(table.concat(line, " ")) end
    print(string.format("SNDCMD: %d bytes total in %d frames", #cmds, frames))
    manager.machine:exit()
  end
end)
print("SNDCMD: installed")
