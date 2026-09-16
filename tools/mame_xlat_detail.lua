-- ORDERING AND DATA for the colour-table accesses, which the count alone
-- cannot give. If the boot code writes a pattern and reads it back, the table
-- cannot be narrowed; if the reads are of data the program itself wrote and
-- only the low byte matters, it can.
local n = 0
local log = {}
function tap()
  local cpu = manager.machine.devices[":maincpu"]
  local prog = cpu.spaces["program"]
  _G.t_rd = prog:install_read_tap(0x910000, 0x91bfff, "rd", function(offset, data, mask)
      if n < 40 then
        n = n + 1
        log[#log+1] = string.format("R %06x data=%04x mask=%04x PC=%08x  (writes so far=%d)", offset, data, mask, cpu.state["PC"].value, _G.wrcount)
      end
      return data
    end)
  _G.wrcount = 0
  _G.t_wr = prog:install_write_tap(0x910000, 0x91bfff, "wr", function(offset, data, mask)
      _G.wrcount = _G.wrcount + 1
      return data
    end)
end
local f = 0
function fr()
  f = f + 1
  if f == 120 then
    for _,l in ipairs(log) do print("XD "..l) end
    print("XD -- first 40 accesses above")
  end
end
tap()
_G.notifier = emu.add_machine_frame_notifier(fr)
