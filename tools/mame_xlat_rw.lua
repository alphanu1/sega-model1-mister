-- Does the V60 ever READ the colour translation table?
--
-- 0x910000-0x91bfff is m_color_xlat (model1.cpp:1008): 24,576 words of R/G/B
-- translation. Our m1_mainram stores all 16 bits of every word and spends 48
-- M10K doing it, but m1_geo_color only ever consumes xlat_data[7:3]. If the
-- program never reads the table back, the RAM can be narrowed and the blocks
-- recovered.
--
-- A READ LEAVES NO TRACE IN MEMORY, so a memory watch cannot answer this - it
-- needs a read tap on the address space. And it must be the RIGHT space: a
-- census of the V60's PROGRAM space once returned "never" for the coprocessor
-- and was wrong for two months, because the game reaches it with in.w and the
-- traffic is in the I/O space. Both are tapped here for that reason.
local reads, writes = 0, 0
local io_reads = 0
local first_read_pc = nil
local rd_lo, rd_hi = nil, nil

function tap()
  local cpu = manager.machine.devices[":maincpu"]
  local prog = cpu.spaces["program"]
  _G.t_rd = prog:install_read_tap(0x910000, 0x91bfff, "xlat_rd", function(offset, data, mask)
      reads = reads + 1
      if not first_read_pc then first_read_pc = cpu.state["PC"].value end
      if not rd_lo or offset < rd_lo then rd_lo = offset end
      if not rd_hi or offset > rd_hi then rd_hi = offset end
      return data
    end)
  _G.t_wr = prog:install_write_tap(0x910000, 0x91bfff, "xlat_wr", function(offset, data, mask)
      writes = writes + 1
      return data
    end)
  local io = cpu.spaces["io"]
  if io then
    _G.t_io = io:install_read_tap(0x910000, 0x91bfff, "xlat_io", function(offset, data, mask)
        io_reads = io_reads + 1
        return data
      end)
  end
end

local frames = 0
function fr()
  frames = frames + 1
  if frames % 200 == 0 then
    print(string.format("XLAT frame %d: program reads=%d io reads=%d writes=%d range=%s..%s firstPC=%s",
      frames, reads, io_reads, writes,
      rd_lo and string.format("%06x", rd_lo) or "-",
      rd_hi and string.format("%06x", rd_hi) or "-",
      first_read_pc and string.format("%08x", first_read_pc) or "-"))
  end
end

tap()
-- ASSIGN TO A GLOBAL or the subscription is collected and the callback stops
-- with no error at all.
_G.notifier = emu.add_machine_frame_notifier(fr)
