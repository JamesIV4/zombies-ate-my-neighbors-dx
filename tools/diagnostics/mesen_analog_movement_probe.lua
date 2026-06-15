local wram = emu.memType.snesWorkRam
local frame = 0
local gameplay_frame = nil
local x_accumulator = 0
local y_accumulator = 0
local previous_x_velocity = 0
local previous_y_velocity = 0
local current_stage = "boot"
local current_dx = 0
local current_dy = 0
local output = io.open("mesen-analog-movement.csv", "w")

local stages = {
	{ name = "neutral_0", duration = 20, x = 0, y = 0, buttons = {} },
	{ name = "left", duration = 36, x = -2, y = 0, buttons = { left = true } },
	{ name = "right_return", duration = 36, x = 2, y = 0, buttons = { right = true } },
	{ name = "neutral_1", duration = 12, x = 0, y = 0, buttons = {} },
	{
		name = "down_left_more_down",
		duration = 30,
		x = -1.1094003925,
		y = 1.6641005887,
		buttons = { down = true, left = true },
	},
	{
		name = "up_right_return_1",
		duration = 30,
		x = 1.1094003925,
		y = -1.6641005887,
		buttons = { up = true, right = true },
	},
	{ name = "neutral_2", duration = 12, x = 0, y = 0, buttons = {} },
	{
		name = "down_left_more_left",
		duration = 30,
		x = -1.6641005887,
		y = 1.1094003925,
		buttons = { down = true, left = true },
	},
	{
		name = "up_right_return_2",
		duration = 30,
		x = 1.6641005887,
		y = -1.1094003925,
		buttons = { up = true, right = true },
	},
	{ name = "neutral_3", duration = 20, x = 0, y = 0, buttons = {} },
}

local function read8(address)
	return emu.read(address, wram)
end

local function read16(address)
	return emu.read16(address, wram)
end

local function write16(address, value)
	emu.write16(address, value % 0x10000, wram)
end

local function get_stage(local_frame)
	local cursor = 0
	for _, stage in ipairs(stages) do
		if local_frame < cursor + stage.duration then
			return stage
		end
		cursor = cursor + stage.duration
	end
	return nil
end

local function quantize_axis(accumulator, velocity)
	accumulator = accumulator + velocity
	local delta
	if accumulator >= 0 then
		delta = math.floor(accumulator + 0.000000001)
	else
		delta = math.ceil(accumulator - 0.000000001)
	end
	return delta, accumulator - delta
end

local function adjust_delta(delta, accumulator, replacement)
	return replacement, accumulator + delta - replacement
end

local function stabilize_vector(x_delta, y_delta, x_velocity, y_velocity)
	if math.abs(x_delta) >= 2 and math.abs(y_delta) >= 2 then
		if math.abs(x_velocity) < math.abs(y_velocity) then
			x_delta, x_accumulator = adjust_delta(
				x_delta, x_accumulator, x_delta > 0 and x_delta - 1 or x_delta + 1)
		else
			y_delta, y_accumulator = adjust_delta(
				y_delta, y_accumulator, y_delta > 0 and y_delta - 1 or y_delta + 1)
		end
	end
	return x_delta, y_delta
end

local function set_input()
	if read8(0x000E) == 2 and read8(0x0D25) ~= 0 then
		if not gameplay_frame then
			gameplay_frame = frame
		end

		local stage = get_stage(frame - gameplay_frame)
		if stage then
			current_stage = stage.name
			if stage.x == 0 and stage.y == 0 then
				x_accumulator = 0
				y_accumulator = 0
				previous_x_velocity = 0
				previous_y_velocity = 0
				current_dx = 0
				current_dy = 0
				write16(0x1FFF4, 0)
			else
				if previous_x_velocity * stage.x + previous_y_velocity * stage.y < 0 then
					x_accumulator = 0
					y_accumulator = 0
				end
				previous_x_velocity = stage.x
				previous_y_velocity = stage.y
				current_dx, x_accumulator = quantize_axis(x_accumulator, stage.x)
				current_dy, y_accumulator = quantize_axis(y_accumulator, stage.y)
				current_dx, current_dy = stabilize_vector(
					current_dx, current_dy, stage.x, stage.y)
				write16(0x1FFF4, 0x5844)
			end
			write16(0x1FFF6, current_dx)
			write16(0x1FFF8, current_dy)
			emu.setInput(stage.buttons, 0)
		else
			write16(0x1FFF4, 0)
			emu.setInput({}, 0)
		end
	else
		write16(0x1FFF4, 0)
		local menu_phase = (frame - 760) % 180
		emu.setInput({
			start = frame >= 760 and menu_phase < 24,
			a = frame >= 760 and menu_phase >= 60 and menu_phase < 84,
			b = frame >= 760 and menu_phase >= 120 and menu_phase < 144,
		}, 0)
	end
end

local function screen_checksum()
	local buffer = emu.getScreenBuffer()
	local checksum = 0
	for index = 1, #buffer, 97 do
		checksum = (checksum + buffer[index] * index) % 0x100000000
	end
	return checksum
end

local function end_frame()
	frame = frame + 1
	if gameplay_frame then
		local local_frame = frame - gameplay_frame
		local stage = get_stage(local_frame)
		if stage then
			output:write(string.format(
				"%d,%d,%s,%d,%d,%04X,%04X,%04X,%04X,%04X,%04X,%08X\n",
				frame,
				local_frame,
				current_stage,
				current_dx,
				current_dy,
				read16(0x0130),
				read16(0x0132),
				read16(0x0134),
				read16(0x0136),
				read16(0x1360),
				read16(0x1362),
				screen_checksum()
			))
			output:flush()
		else
			output:close()
			emu.stop(0)
		end
	elseif frame > 5000 then
		output:close()
		emu.stop(2)
	end
end

output:write("frame,local_frame,stage,mailbox_dx,mailbox_dy,player_x,player_y,temp_x,temp_y,bg1_x,bg1_y,screen_checksum\n")
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
