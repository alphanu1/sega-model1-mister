-- What does the finished colour translation table actually HOLD?
--
-- m1_geo_color consumes only xlat_data[7:3], but the V60 can read the table
-- back (m1_main.sv: rdata_r <= cxlat_q) and does - a read-modify-write pass at
-- PC fe0195. So narrowing the RAM is only safe if no word ever carries bits
-- above 7; otherwise the readback would hand the program values it did not
-- write.
local f = 0
function fr()
  f = f + 1
  if f ~= 1800 then return end
  local prog = manager.machine.devices[":maincpu"].spaces["program"]
  local hi_set, nonzero, maxv = 0, 0, 0
  local worst = nil
  for a = 0x910000, 0x91bffe, 2 do
    local v = prog:read_u16(a)
    if v ~= 0 then nonzero = nonzero + 1 end
    if v > maxv then maxv = v end
    if (v & 0xff00) ~= 0 then
      hi_set = hi_set + 1
      if not worst then worst = string.format("%06x=%04x", a, v) end
    end
  end
  print(string.format("XDUMP words=12288 nonzero=%d  upper-byte-set=%d  max=%04x  firstHigh=%s",
        nonzero, hi_set, maxv, worst or "none"))
  -- Also: are bits 2:0 ever set? geometry reads [7:3] only.
  local lo_set = 0
  for a = 0x910000, 0x91bffe, 2 do
    local v = prog:read_u16(a)
    if (v & 0x0007) ~= 0 then lo_set = lo_set + 1 end
  end
  print(string.format("XDUMP bits2:0 set in %d words", lo_set))
end
_G.notifier = emu.add_machine_frame_notifier(fr)
