-- The Model 1 sound 68000's boot behaviour: where its PC goes, and what it
-- touches. Answers "is it waiting on the FM chip" with a measurement.
local cpu = manager.machine.devices[":m1audio:sndcpu"]
local sp  = cpu.spaces["program"]
pchist, regions, frames = {}, {}, 0
rtap = sp:install_read_tap(0x000000, 0xffffff, "sr", function(off, data, mask)
  local k = string.format("R %06x", off & 0xfff000)
  regions[k] = (regions[k] or 0) + 1
  return data
end)
wtap = sp:install_write_tap(0x000000, 0xffffff, "sw", function(off, data, mask)
  local k = string.format("W %06x", off & 0xfff000)
  regions[k] = (regions[k] or 0) + 1
  return data
end)
notif = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  local pc = cpu.state["PC"].value
  local b = pc & 0xffff00
  pchist[b] = (pchist[b] or 0) + 1
  if frames >= 240 then
    print("SNDPC  (frames at each PC page)")
    local t = {}
    for k,v in pairs(pchist) do t[#t+1] = {k,v} end
    table.sort(t, function(a,b) return a[2] > b[2] end)
    for i=1,math.min(6,#t) do print(string.format("   PC %06x  %d frames", t[i][1], t[i][2])) end
    print("SNDBUS (accesses by 4 KB region)")
    local u = {}
    for k,v in pairs(regions) do u[#u+1] = {k,v} end
    table.sort(u, function(a,b) return a[2] > b[2] end)
    for i=1,math.min(10,#u) do print(string.format("   %s  %d", u[i][1], u[i][2])) end
    manager.machine:exit()
  end
end)
