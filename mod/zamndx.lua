-- Zombies Ate My Neighbors DX controller layer for BizHawk 2.11+
--
-- Left stick: analog speed and 360-degree direction selection
-- Right stick: aim in the game's eight native directions and fire

local CONFIG = {
	controller = 1,
	deadzone = 0.18,
	show_status = true,
	invert_left_y = true,
	invert_right_y = true,

	-- Set any value below to an exact BizHawk axis name to override detection.
	left_x_axis = nil,
	left_y_axis = nil,
	right_x_axis = nil,
	right_y_axis = nil,
}

local AXIS_MAX = 10000
local AIM_ACTIVE_ADDRESS = 0x1FFF0
local AIM_DIRECTION_ADDRESS = 0x1FFF2

local axis_names = {
	left_x = CONFIG.left_x_axis,
	left_y = CONFIG.left_y_axis,
	right_x = CONFIG.right_x_axis,
	right_y = CONFIG.right_y_axis,
}

local axis_candidates = {
	left_x = { "X1 LeftThumbX Axis", "X1 Left Stick X Axis" },
	left_y = { "X1 LeftThumbY Axis", "X1 Left Stick Y Axis" },
	right_x = { "X1 RightThumbX Axis", "X1 Right Stick X Axis" },
	right_y = { "X1 RightThumbY Axis", "X1 Right Stick Y Axis" },
}

local axis_tokens = {
	left_x = { "left", "x", "axis" },
	left_y = { "left", "y", "axis" },
	right_x = { "right", "x", "axis" },
	right_y = { "right", "y", "axis" },
}

local directions = {
	{ code = 0x06, buttons = { "Right" } },
	{ code = 0x04, buttons = { "Right", "Up" } },
	{ code = 0x02, buttons = { "Up" } },
	{ code = 0x10, buttons = { "Left", "Up" } },
	{ code = 0x0E, buttons = { "Left" } },
	{ code = 0x0C, buttons = { "Left", "Down" } },
	{ code = 0x0A, buttons = { "Down" } },
	{ code = 0x08, buttons = { "Right", "Down" } },
}

local movement_angle_accumulator = 0
local movement_speed_accumulator = 0
local aim_active = false
local aim_direction = 0x06

local function copy_table(source)
	local result = {}
	for key, value in pairs(source or {}) do
		result[key] = value
	end
	return result
end

local function contains_all(value, tokens)
	local lower = string.lower(value)
	for _, token in ipairs(tokens) do
		if not string.find(lower, token, 1, true) then
			return false
		end
	end
	return true
end

local function detect_axis(kind, axes)
	if axis_names[kind] then
		return
	end

	for _, candidate in ipairs(axis_candidates[kind]) do
		if axes[candidate] ~= nil then
			axis_names[kind] = candidate
			return
		end
	end

	for name, _ in pairs(axes) do
		if contains_all(name, axis_tokens[kind]) then
			axis_names[kind] = name
			return
		end
	end
end

local function read_axis(kind, axes)
	detect_axis(kind, axes)
	local name = axis_names[kind]
	if not name then
		return 0
	end
	return math.max(-AXIS_MAX, math.min(AXIS_MAX, axes[name] or 0)) / AXIS_MAX
end

local function apply_deadzone(x, y)
	local magnitude = math.sqrt(x * x + y * y)
	if magnitude <= CONFIG.deadzone then
		return 0, 0, 0
	end

	local scaled_magnitude = math.min(
		1,
		(magnitude - CONFIG.deadzone) / (1 - CONFIG.deadzone)
	)
	return x / magnitude, y / magnitude, scaled_magnitude
end

local function direction_position(x, y)
	local angle = math.atan(y, x)
	if angle < 0 then
		angle = angle + math.pi * 2
	end
	return angle / (math.pi / 4)
end

local function nearest_direction(x, y)
	local position = direction_position(x, y)
	return math.floor(position + 0.5) % 8
end

local function dithered_direction(x, y)
	local position = direction_position(x, y)
	local lower = math.floor(position)
	local fraction = position - lower

	movement_angle_accumulator = movement_angle_accumulator + fraction
	if movement_angle_accumulator >= 1 then
		movement_angle_accumulator = movement_angle_accumulator - 1
		return (lower + 1) % 8
	end
	return lower % 8
end

local function apply_direction(buttons, direction_index)
	buttons.Up = false
	buttons.Down = false
	buttons.Left = false
	buttons.Right = false
	for _, name in ipairs(directions[direction_index + 1].buttons) do
		buttons[name] = true
	end
end

local function apply_analog_movement(buttons, x, y, magnitude)
	if magnitude == 0 then
		movement_angle_accumulator = 0
		movement_speed_accumulator = 0
		return
	end

	buttons.Up = false
	buttons.Down = false
	buttons.Left = false
	buttons.Right = false

	movement_speed_accumulator = movement_speed_accumulator + magnitude
	if movement_speed_accumulator < 1 then
		return
	end

	movement_speed_accumulator = movement_speed_accumulator - 1
	apply_direction(buttons, dithered_direction(x, y))
end

local function status_text()
	if not axis_names.left_x or not axis_names.right_x then
		return "ZAMN DX: move both sticks once to detect controller axes"
	end
	return "ZAMN DX: left stick move | right stick aim + fire"
end

local function clear_aim_mailbox()
	pcall(function()
		mainmemory.write_u16_le(AIM_ACTIVE_ADDRESS, 0)
	end)
end

clear_aim_mailbox()
event.onexit(clear_aim_mailbox, "ZAMN DX aim cleanup")
console.log("ZAMN DX controller layer loaded")

while true do
	local axes = input.get_pressed_axes()
	local buttons = copy_table(joypad.getimmediate(CONFIG.controller))

	local left_x = read_axis("left_x", axes)
	local left_y = read_axis("left_y", axes)
	local right_x = read_axis("right_x", axes)
	local right_y = read_axis("right_y", axes)

	if CONFIG.invert_left_y then
		left_y = -left_y
	end
	if CONFIG.invert_right_y then
		right_y = -right_y
	end

	local move_x, move_y, move_magnitude = apply_deadzone(left_x, left_y)
	apply_analog_movement(buttons, move_x, move_y, move_magnitude)

	local aim_x, aim_y, aim_magnitude = apply_deadzone(right_x, right_y)
	aim_active = aim_magnitude > 0
	if aim_active then
		aim_direction = directions[nearest_direction(aim_x, aim_y) + 1].code
		buttons.Y = true
		mainmemory.write_u16_le(AIM_DIRECTION_ADDRESS, aim_direction)
	end
	mainmemory.write_u16_le(AIM_ACTIVE_ADDRESS, aim_active and 1 or 0)

	joypad.set(buttons, CONFIG.controller)
	if CONFIG.show_status then
		gui.text(2, 2, status_text())
	end
	emu.frameadvance()
end
