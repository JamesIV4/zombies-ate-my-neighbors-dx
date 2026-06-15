local frame = 0
local wram = emu.memType.snesWorkRam
local output = io.open("mesen-boot-probe.txt", "w")

local function log(message)
	print(message)
	emu.log(message)
	output:write(message .. "\n")
	output:flush()
end

local function read16(address)
	return emu.read16(address, wram)
end

local function set_scheduled_input()
	local menu_phase = (frame - 760) % 180
	local buttons = {
		start = frame >= 760 and menu_phase < 24,
		a = frame >= 760 and menu_phase >= 60 and menu_phase < 84,
		b = frame >= 760 and menu_phase >= 120 and menu_phase < 144
	}
	for port = 0, 4 do
		emu.setInput(buttons, port)
	end
end

local function end_frame()
	frame = frame + 1

	if frame % 60 == 0 then
		log(string.format(
			"frame=%d game_state=%02X player_active=%02X x=%04X y=%04X input=%04X",
			frame,
			emu.read(0x000E, wram),
			emu.read(0x0D25, wram),
			read16(0x0130),
			read16(0x0132),
			read16(0x006E)
		))
	end

	if frame == 3000 then
		output:close()
		emu.stop(0)
	end
end

log("Mesen boot probe started")
for port = 0, 4 do
	for name, value in pairs(emu.getInput(port)) do
		log(string.format("input port=%d %s=%s", port, name, tostring(value)))
	end
end
emu.addEventCallback(set_scheduled_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
