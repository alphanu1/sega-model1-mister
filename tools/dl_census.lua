-- V60 writes to the display lists, per frame.
-- 0x600000 (list 0) and 0x610000 (list 1), 64 KB each per m1_decode.sv:141-144.
-- Assigned to GLOBALS: a tap or notifier held only in a local is collected and
-- stops firing with no error (the rules file).
local cpu   = manager.machine.devices[":maincpu"]
local sp    = cpu.spaces["program"]
w0, w1, frames, peak0, peak1 = 0, 0, 0, 0, 0
r0, r1, rpeak = 0, 0, 0
local fr = 0
local f0, f1 = 0, 0
tap = sp:install_write_tap(0x600000, 0x61ffff, "dlcensus", function(offset, data, mask)
  if offset < 0x610000 then w0 = w0 + 1; f0 = f0 + 1
  else                      w1 = w1 + 1; f1 = f1 + 1 end
  return data
end)
rtap = sp:install_read_tap(0x600000, 0x61ffff, "dlread", function(offset, data, mask)
  if offset < 0x610000 then r0 = r0 + 1 else r1 = r1 + 1 end
  fr = fr + 1
  return data
end)
notif = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if f0 > peak0 then peak0 = f0 end
  if f1 > peak1 then peak1 = f1 end
  if fr > rpeak then rpeak = fr end
  f0, f1 = 0, 0
  fr = 0
  if frames % 100 == 0 then
    print(string.format("DLCENSUS frames=%d  list0=%d (%.1f/frame, peak %d)  list1=%d (%.1f/frame, peak %d)",
      frames, w0, w0/frames, peak0, w1, w1/frames, peak1))
  end
  if frames >= 400 then
    print(string.format("DLFINAL frames=%d WRITES list0=%d list1=%d mean %.1f/frame peak %d | READS list0=%d list1=%d mean %.1f/frame peak %d",
      frames, w0, w1, (w0+w1)/frames, math.max(peak0,peak1), r0, r1, (r0+r1)/frames, rpeak))
    manager.machine:exit()
  end
end)
