local wram = emu.memType.snesWorkRam
local snes_memory = emu.memType.snesMemory
local snes_cpu = emu.cpuType.snes
local frame = 0
local gameplay_frame = nil
local angle_accumulator = 0
local output = io.open("mesen-position-write-trace.csv", "w")
local frames_output = io.open("mesen-position-frame-trace.csv", "w")
local current_stage = "boot"
local current_direction = "neutral"

local function read8(address)
	return emu.read(address, wram)
end

local function read16(address)
	return emu.read16(address, wram)
end

local stages = {
	{ name = "neutral_0", duration = 20 },
	{ name = "down", duration = 48 },
	{ name = "neutral_1", duration = 12 },
	{ name = "up_return", duration = 48 },
	{ name = "neutral_2", duration = 12 },
	{ name = "left", duration = 48 },
	{ name = "neutral_3", duration = 12 },
	{ name = "right_return", duration = 48 },
	{ name = "neutral_4", duration = 12 },
	{ name = "down_left", duration = 48 },
	{ name = "neutral_5", duration = 12 },
	{ name = "up_right_return", duration = 48 },
	{ name = "neutral_6", duration = 12 },
	{ name = "dither_down_down_left", duration = 120 },
}

local function get_stage(local_frame)
	local cursor = 0
	for _, stage in ipairs(stages) do
		if local_frame < cursor + stage.duration then
			return stage, local_frame - cursor
		end
		cursor = cursor + stage.duration
	end
	return nil
end

local function stage_input(stage)
	if stage.name == "down" then
		current_direction = "down"
		return { down = true }
	elseif stage.name == "up_return" then
		current_direction = "up"
		return { up = true }
	elseif stage.name == "left" then
		current_direction = "left"
		return { left = true }
	elseif stage.name == "right_return" then
		current_direction = "right"
		return { right = true }
	elseif stage.name == "down_left" then
		current_direction = "down_left"
		return { down = true, left = true }
	elseif stage.name == "up_right_return" then
		current_direction = "up_right"
		return { up = true, right = true }
	elseif stage.name == "dither_down_down_left" then
		angle_accumulator = angle_accumulator + 0.4096655294
		if angle_accumulator >= 1 then
			angle_accumulator = angle_accumulator - 1
			current_direction = "down"
			return { down = true }
		end
		current_direction = "down_left"
		return { down = true, left = true }
	end
	current_direction = "neutral"
	return {}
end

local function set_input()
	if read8(0x000E) == 2 and read8(0x0D25) ~= 0 then
		if not gameplay_frame then
			gameplay_frame = frame
		end
		local stage = get_stage(frame - gameplay_frame)
		current_stage = stage and stage.name or "done"
		emu.setInput(stage and stage_input(stage) or {}, 0)
	else
		local menu_phase = (frame - 760) % 180
		emu.setInput({
			start = frame >= 760 and menu_phase < 24,
			a = frame >= 760 and menu_phase >= 60 and menu_phase < 84,
			b = frame >= 760 and menu_phase >= 120 and menu_phase < 144,
		}, 0)
	end
end

local function trace_write(address, value)
	if not gameplay_frame then
		return
	end
	local local_frame = frame - gameplay_frame
	if not get_stage(local_frame) then
		return
	end
	local state = emu.getState()
	output:write(string.format(
		"%d,%d,%s,%s,%06X,%04X,%06X,%04X,%04X,%04X,%04X,%02X\n",
		frame,
		local_frame,
		current_stage,
		current_direction,
		address,
		value,
		state["cpu.pc"] or 0,
		state["cpu.d"] or 0,
		state["cpu.a"] or 0,
		state["cpu.x"] or 0,
		state["cpu.y"] or 0,
		state["cpu.ps"] or 0
	))
end

local function end_frame()
	frame = frame + 1
	if gameplay_frame then
		local local_frame = frame - gameplay_frame
		local stage = get_stage(local_frame)
		if stage then
			frames_output:write(string.format(
				"%d,%d,%s,%s,%04X,%04X,%04X,%04X,%04X,%04X,%04X,%04X,%04X,%04X,%04X,%04X\n",
				frame,
				local_frame,
				current_stage,
				current_direction,
				read16(0x0130),
				read16(0x0132),
				read16(0x0134),
				read16(0x0136),
				read16(0x0124),
				read16(0x0126),
				read16(0x0154),
				read16(0x0176),
				read16(0x006E),
				read16(0x1360),
				read16(0x1362),
				read16(0x1B6A)
			))
			frames_output:flush()
		else
			output:close()
			frames_output:close()
			emu.stop(0)
		end
	elseif frame > 5000 then
		output:close()
		frames_output:close()
		emu.stop(2)
	end
end

output:write("frame,local_frame,stage,direction,address,value,pc,d,a,x,y,ps\n")
frames_output:write("frame,local_frame,stage,direction,player_x,player_y,temp_x,temp_y,move_direction,facing,field_54,field_76,input,bg1_x,bg1_y,map_x\n")
for address = 0x0130, 0x0137 do
	emu.addMemoryCallback(
		trace_write,
		emu.callbackType.write,
		address,
		address,
		snes_cpu,
		wram
	)
end
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
