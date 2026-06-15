local PLAYER = 1
local frame = 0
local gameplay_frame = nil

local script_source = debug.getinfo(1, "S").source
if string.sub(script_source, 1, 1) == "@" then
	script_source = string.sub(script_source, 2)
end
local script_directory = string.match(script_source, "^(.*[\\/])") or ""
local output = io.open(script_directory .. "bizhawk-movement-camera.csv", "w")

local stages = {
	{ name = "neutral", duration = 60 },
	{ name = "left", duration = 120 },
	{ name = "neutral_1", duration = 30 },
	{ name = "down_left", duration = 120 },
	{ name = "neutral_2", duration = 30 },
	{ name = "alternate_left_down_left", duration = 120 },
	{ name = "neutral_3", duration = 30 },
	{ name = "grouped_left_down_left", duration = 120 },
}

local function read8(address)
	return mainmemory.read_u8(address)
end

local function read16(address)
	return mainmemory.read_u16_le(address)
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
	if stage.name == "left" then
		return { Left = true }
	elseif stage.name == "down_left" then
		return { Down = true, Left = true }
	elseif stage.name == "alternate_left_down_left" then
		return stage_frame % 2 == 0
			and { Left = true }
			or { Down = true, Left = true }
	elseif stage.name == "grouped_left_down_left" then
		return stage_frame % 8 < 4
			and { Left = true }
			or { Down = true, Left = true }
	end
	return {}
end

local function menu_input()
	local menu_phase = (frame - 760) % 180
	if frame < 760 then
		return {}
	elseif menu_phase < 24 then
		return { Start = true }
	elseif menu_phase >= 60 and menu_phase < 84 then
		return { A = true }
	elseif menu_phase >= 120 and menu_phase < 144 then
		return { B = true }
	end
	return {}
end

local function write_sample(stage, stage_frame)
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
end

output:write("frame,stage,stage_frame,player_x,player_y,x_0134,y_0136,bg1_x,bg1_y,bg2_x,bg2_y,input,player_dp,map_x,map_y\n")
output:flush()

while true do
	frame = frame + 1

	local game_state = read8(0x000E)
	local player_active = read8(0x0D25)
	if game_state == 2 and player_active ~= 0 then
		if not gameplay_frame then
			gameplay_frame = frame
		end

		local stage, stage_frame = get_stage(frame - gameplay_frame)
		if not stage then
			joypad.set({}, PLAYER)
			output:close()
			client.exitCode(0)
			return
		end

		joypad.set(gameplay_input(stage, stage_frame), PLAYER)
		write_sample(stage, stage_frame)
	else
		joypad.set(menu_input(), PLAYER)
	end

	if frame > 5000 then
		output:close()
		client.exitCode(2)
		return
	end

	emu.frameadvance()
end
