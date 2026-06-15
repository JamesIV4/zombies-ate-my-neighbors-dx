-- Zombies Ate My Neighbors DX controller runtime for BizHawk 2.11+.
-- Controller configuration is handled by the desktop launcher.

local AXIS_MAX = 10000
local AIM_ACTIVE_ADDRESS = 0x1FFF0
local AIM_DIRECTION_ADDRESS = 0x1FFF2
local PLAYER = 1

local script_source = debug.getinfo(1, "S").source
if string.sub(script_source, 1, 1) == "@" then
	script_source = string.sub(script_source, 2)
end
local script_directory = string.match(script_source, "^(.*[\\/])") or ""
local config_path = script_directory .. "zamndx-controller-config.lua"

local button_order = {
	"Up", "Down", "Left", "Right", "Start", "Select",
	"Y", "B", "A", "X", "L", "R",
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

local function default_settings()
	return {
		device = "X1",
		deadzone = 0.18,
		invert_left_y = true,
		invert_right_y = true,
		enabled = true,
		buttons = {
			Up = "X1 DpadUp",
			Down = "X1 DpadDown",
			Left = "X1 DpadLeft",
			Right = "X1 DpadRight",
			Start = "X1 Start",
			Select = "X1 Back",
			Y = "X1 X",
			B = "X1 A",
			A = "X1 B",
			X = "X1 Y",
			L = "X1 LeftShoulder",
			R = "X1 RightShoulder",
		},
		axes = {
			left_x = "X1 LeftThumbX Axis",
			left_y = "X1 LeftThumbY Axis",
			right_x = "X1 RightThumbX Axis",
			right_y = "X1 RightThumbY Axis",
		},
	}
end

local function merge_settings(base, loaded)
	if type(loaded) ~= "table" then
		return base
	end
	for key, value in pairs(loaded) do
		if type(value) == "table" and type(base[key]) == "table" then
			for nested_key, nested_value in pairs(value) do
				base[key][nested_key] = nested_value
			end
		else
			base[key] = value
		end
	end
	return base
end

local function load_settings()
	local defaults = default_settings()
	local chunk = loadfile(config_path)
	if not chunk then
		return defaults
	end
	local ok, loaded = pcall(chunk)
	if not ok then
		console.log("ZAMN DX: could not load controller config: " .. tostring(loaded))
		return defaults
	end
	return merge_settings(defaults, loaded)
end

local settings = load_settings()
local movement_angle_accumulator = 0
local movement_speed_accumulator = 0

local function release_overrides()
	pcall(function()
		joypad.set({}, PLAYER)
		mainmemory.write_u16_le(AIM_ACTIVE_ADDRESS, 0)
	end)
end

local function read_axis(name, axes)
	local binding = settings.axes[name]
	if not binding or binding == "" then
		return 0
	end
	return math.max(-AXIS_MAX, math.min(AXIS_MAX, axes[binding] or 0)) / AXIS_MAX
end

local function apply_deadzone(x, y)
	local magnitude = math.sqrt(x * x + y * y)
	if magnitude <= settings.deadzone then
		return 0, 0, 0
	end
	local scaled_magnitude = math.min(1, (magnitude - settings.deadzone) / (1 - settings.deadzone))
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
	return math.floor(direction_position(x, y) + 0.5) % 8
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

local function set_direction(overrides, direction_index)
	overrides.Up = false
	overrides.Down = false
	overrides.Left = false
	overrides.Right = false
	for _, name in ipairs(directions[direction_index + 1].buttons) do
		overrides[name] = true
	end
end

local function apply_analog_movement(overrides, x, y, magnitude)
	if magnitude == 0 then
		movement_angle_accumulator = 0
		movement_speed_accumulator = 0
		return
	end

	overrides.Up = false
	overrides.Down = false
	overrides.Left = false
	overrides.Right = false
	movement_speed_accumulator = movement_speed_accumulator + magnitude
	if movement_speed_accumulator < 1 then
		return
	end
	movement_speed_accumulator = movement_speed_accumulator - 1
	set_direction(overrides, dithered_direction(x, y))
end

local function mapped_button_overrides(host_buttons)
	local overrides = {}
	for _, snes_name in ipairs(button_order) do
		local host_name = settings.buttons[snes_name]
		if host_name and host_name ~= "" and host_buttons[host_name] then
			overrides[snes_name] = true
		end
	end
	return overrides
end

local function cleanup()
	release_overrides()
end

release_overrides()
event.onexit(cleanup, "ZAMN DX controller cleanup")
console.log("ZAMN DX: controller runtime loaded for " .. settings.device)

while true do
	local host_buttons = input.get()
	local axes = input.get_pressed_axes()
	local overrides = {}
	local aim_active = false

	if settings.enabled then
		overrides = mapped_button_overrides(host_buttons)

		local left_x = read_axis("left_x", axes)
		local left_y = read_axis("left_y", axes)
		local right_x = read_axis("right_x", axes)
		local right_y = read_axis("right_y", axes)
		if settings.invert_left_y then
			left_y = -left_y
		end
		if settings.invert_right_y then
			right_y = -right_y
		end

		local move_x, move_y, move_magnitude = apply_deadzone(left_x, left_y)
		apply_analog_movement(overrides, move_x, move_y, move_magnitude)

		local aim_x, aim_y, aim_magnitude = apply_deadzone(right_x, right_y)
		aim_active = aim_magnitude > 0
		if aim_active then
			local aim_direction = directions[nearest_direction(aim_x, aim_y) + 1].code
			overrides.Y = true
			mainmemory.write_u16_le(AIM_DIRECTION_ADDRESS, aim_direction)
		end
	end

	mainmemory.write_u16_le(AIM_ACTIVE_ADDRESS, aim_active and 1 or 0)
	joypad.set(overrides, PLAYER)
	emu.frameadvance()
end
