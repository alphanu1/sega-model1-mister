-- Enumerate a machine's input ports and fields.
--
-- Needed because a game on FREE PLAY never enters attract: it waits at the
-- start screen forever, so any census that just runs for longer measures the
-- same idle frame a hundred thousand times. Driving Start is the only way in,
-- and that needs the exact port/field names.
notif = emu.add_machine_frame_notifier(function()
    if frames == nil then frames = 0 end
    frames = frames + 1
    if frames ~= 5 then return end
    for tag, port in pairs(manager.machine.ioport.ports) do
        print("PORT " .. tag)
        for name, field in pairs(port.fields) do
            print(string.format("   %-28s type=%s", name, tostring(field.type)))
        end
    end
    manager.machine:exit()
end)
