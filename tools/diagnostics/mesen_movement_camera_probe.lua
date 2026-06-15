local wram = emu.memType.snesWorkRam
local frame = 0
local gameplay_frame = nil
local output = io.open("mesen-movement-camera.csv", "w")

local stages = {
	{ name = "neutral", duration = 60 },
	{ name = "right", duration = 120 },
	{ name = "neutral_1", duration = 30 },
	{ name = "up_right", duration = 120 },
	{ name = "neutral_2", duration = 30 },
	{ name = "alternate_right_up_right", duration = 120 },
	{ name = "neutral_3", duration = 30 },
	{ name = "grouped_right_up_right", duration = 120 },
}

local function read8(address)
	return emu.read(address, wram)
end

local function read16(address)
	return emu.read16(address, wram)
end

local function get_stage(local_frame)
	local cursor = 0
	for _, stage in ipairs(stages) do
		if local_frame < cursor + stage.duration then
			return stage, local_frame - cursor
		end
		cursor = cursor + stage.duration
	end
	return nil, nil
end

local function gameplay_input(stage, stage_frame)
	if stage.name == "right" then
		return { right = true }
	elseif stage.name == "up_right" then
		return { up = true, right = true }
	elseif stage.name == "alternate_right_up_right" then
		return stage_frame % 2 == 0
			and { right = true }
			or { up = true, right = true }
	elseif stage.name == "grouped_right_up_right" then
		return stage_frame % 8 < 4
			and { right = true }
			or { up = true, right = true }
	end
	return {}
end

local function set_input()
	local game_state = read8(0x000E)
	local player_active = read8(0x0D25)

	if game_state == 2 and player_active ~= 0 then
		if not gameplay_frame then
			gameplay_frame = frame
		end
		local stage, stage_frame = get_stage(frame - gameplay_frame)
		emu.setInput(stage and gameplay_input(stage, stage_frame) or {}, 0)
	else
		local menu_phase = (frame - 760) % 180
		emu.setInput({
			start = frame >= 760 and menu_phase < 24,
			a = frame >= 760 and menu_phase >= 60 and menu_phase < 84,
			b = frame >= 760 and menu_phase >= 120 and menu_phase < 144,
		}, 0)
	end
end

local function end_frame()
	frame = frame + 1

	if gameplay_frame then
		local local_frame = frame - gameplay_frame
		local stage, stage_frame = get_stage(local_frame)
		if stage then
			output:write(string.format(
				"%d,%s,%d,%04X,%04X,%04X,%04X,%04X,%04X,%04X,%04X,%04X,%04X,%04X,%04X\n",
				frame,
				stage.name,
				stage_frame,
				read16(0x0130),
				read16(0x0132),
				read16(0x0134),
				read16(0x0136),
				read16(0x1360),
				read16(0x1362),
				read16(0x1364),
				read16(0x1366),
				read16(0x006E),
				read16(0x00D2),
				read16(0x1B6A),
				read16(0x1B6C)
			))
			output:flush()
		else
			output:close()
			emu.exit(0)
		end
	elseif frame > 5000 then
		output:close()
		emu.exit(2)
	end
end

output:write("frame,stage,stage_frame,player_x,player_y,x_0134,y_0136,bg1_x,bg1_y,bg2_x,bg2_y,input,player_dp,map_x,map_y\n")
output:flush()
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
