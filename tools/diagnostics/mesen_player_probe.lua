local wram = emu.memType.snesWorkRam
local frame = 0
local gameplay_frame = nil
local previous_snapshot = nil

local stages = {
	{ name = "neutral", duration = 60, buttons = {} },
	{ name = "right", duration = 60, buttons = { right = true } },
	{ name = "neutral_after_right", duration = 30, buttons = {} },
	{ name = "up", duration = 60, buttons = { up = true } },
	{ name = "neutral_after_up", duration = 30, buttons = {} },
	{ name = "shoot_facing_up", duration = 30, buttons = { y = true } },
	{ name = "left_and_shoot", duration = 60, buttons = { left = true, y = true } },
	{ name = "up_right", duration = 60, buttons = { up = true, right = true } },
	{ name = "down", duration = 60, buttons = { down = true } },
}

local function read8(address)
	return emu.read(address, wram)
end

local function read16(address)
	return emu.read16(address, wram)
end

local function snapshot()
	local result = {}
	for address = 0x00C0, 0x017F do
		result[address] = read8(address)
	end
	return result
end

local function log_snapshot(name)
	local current = snapshot()
	print(string.format(
		"stage=%s frame=%d sprite=%04X entity=%04X x=%04X y=%04X xb=%04X yb=%04X",
		name,
		frame,
		read16(0x00D2),
		read16(read16(0x00D2) + 0x000C),
		read16(0x0130),
		read16(0x0132),
		read16(0x0134),
		read16(0x0136)
	))

	if previous_snapshot then
		local changes = {}
		for address = 0x00C0, 0x017F do
			if current[address] ~= previous_snapshot[address] then
				table.insert(changes, string.format(
					"%04X:%02X>%02X",
					address,
					previous_snapshot[address],
					current[address]
				))
			end
		end
		print("changes " .. table.concat(changes, " "))
	end

	previous_snapshot = current
end

local function get_stage(local_frame)
	local cursor = 0
	for index, stage in ipairs(stages) do
		if local_frame < cursor + stage.duration then
			return index, stage, local_frame - cursor
		end
		cursor = cursor + stage.duration
	end
	return nil, nil, nil
end

local function set_input()
	local game_state = read8(0x000E)
	local player_active = read8(0x0D25)

	if game_state == 2 and player_active ~= 0 then
		if not gameplay_frame then
			gameplay_frame = frame
		end
		local _, stage = get_stage(frame - gameplay_frame)
		emu.setInput(stage and stage.buttons or {}, 0)
	else
		local menu_phase = (frame - 760) % 180
		emu.setInput({
			start = frame >= 760 and menu_phase < 24,
			a = frame >= 760 and menu_phase >= 60 and menu_phase < 84,
			b = frame >= 760 and menu_phase >= 120 and menu_phase < 144
		}, 0)
	end
end

local function end_frame()
	frame = frame + 1

	if gameplay_frame then
		local local_frame = frame - gameplay_frame
		local _, stage, stage_frame = get_stage(local_frame)
		if stage and stage_frame == stage.duration - 1 then
			log_snapshot(stage.name)
		elseif not stage then
			print("player probe complete")
			emu.stop(0)
		end
	end

	if frame > 4000 then
		print("player probe timed out")
		emu.stop(2)
	end
end

print("Mesen player probe started")
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
