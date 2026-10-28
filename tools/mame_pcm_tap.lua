-- Sega Model 1: what does the sound driver actually write to the MULTIPCMs?
--
-- The rules file's rule, applied to the sound board: when something is unknown, run
-- MAME. The core produces a constant rumble instead of sound effects, and every
-- static check -- banking, byte order, loader split, MRA layout, sample rate --
-- has come back correct. So the question is no longer "is our path right" but
-- "what is the reference DOING", and nothing has asked it.
--
-- segam1audio maps, in the sound 68000's space:
--   0xc40000-0xc40007  MULTIPCM 1 registers (umask 0x00ff, odd byte)
--   0xc50000           MULTIPCM 1 bank select
--   0xc60000-0xc60007  MULTIPCM 2 registers
--   0xc70000           MULTIPCM 2 bank select
--   0xd00000-0xd00007  YM3438
--
-- Assign every tap and notifier to a GLOBAL or the subscription is collected
-- and the callback stops with no error -- the rules file, learned the hard way.

local snd = manager.machine.devices[":m1audio:sndcpu"]
if snd == nil then
  for tag, dev in pairs(manager.machine.devices) do
    if tag:find("sndcpu") then snd = dev; print("audiocpu at " .. tag) end
  end
end
if snd == nil then print("PCMTAP: no sound CPU found"); return end

local sp = snd.spaces["program"]

pcm_w   = {}        -- [addr] = count
pcm_seq = {}        -- first N writes in order
bank_w  = {}
ym_w    = 0
nseq    = 0
frames  = 0

tap_pcm = sp:install_write_tap(0xc40000, 0xc7ffff, "pcmtap", function(offset, data, mask)
  local a = offset
  pcm_w[a] = (pcm_w[a] or 0) + 1
  if a == 0xc50000 or a == 0xc50001 or a == 0xc70000 or a == 0xc70001 then
    bank_w[#bank_w + 1] = string.format("%06x=%04x", a, data)
  end
  if nseq < 64 then
    nseq = nseq + 1
    pcm_seq[nseq] = string.format("%06x=%04x", a, data)
  end
  return data
end)

tap_ym = sp:install_write_tap(0xd00000, 0xd00007, "ymtap", function(offset, data, mask)
  ym_w = ym_w + 1
  return data
end)

notif = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if frames == 180 then
    print("== PCMTAP after 600 frames ==")
    local tot = 0
    local keys = {}
    for a, n in pairs(pcm_w) do tot = tot + n; keys[#keys+1] = a end
    table.sort(keys)
    print(string.format("MULTIPCM register writes: %d total, %d distinct addresses",
                        tot, #keys))
    for _, a in ipairs(keys) do
      print(string.format("   %06x : %d", a, pcm_w[a]))
    end
    print(string.format("YM3438 writes: %d", ym_w))
    print("bank selects: " .. (#bank_w > 0 and table.concat(bank_w, " ", 1, math.min(#bank_w, 12)) or "NONE"))
    print("first writes in order:")
    for i = 1, math.min(nseq, 32) do io.write(" " .. pcm_seq[i]) end
    print("")
    manager.machine:exit()
  end
end)
print("PCMTAP: installed")
