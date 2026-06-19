-- Zombies Ate My Neighbors DX controller runtime for BizHawk 2.11+.
-- Controller configuration is handled by the desktop launcher.

local AXIS_MAX = 10000
local AIM_ACTIVE_ADDRESS = 0x1FFF0
local AIM_DIRECTION_ADDRESS = 0x1FFF2
local MOVEMENT_ACTIVE_ADDRESS = 0x1FFF4
local MOVEMENT_X_ADDRESS = 0x1FFF6
local MOVEMENT_Y_ADDRESS = 0x1FFF8
local MOVEMENT_SIGNATURE = 0x5844
local MOVEMENT_SPEED = 2
local PLAYER = 1

local script_source = debug.getinfo(1, "S").source
if string.sub(script_source, 1, 1) == "@" then
	script_source = string.sub(script_source, 2)
end
local script_directory = string.match(script_source, "^(.*[\\/])") or ""
local config_path = script_directory .. "zamndx-controller-config.lua"

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
		-- All SNES buttons are mapped through BizHawk's own controller config by
		-- the launcher. This runtime only owns analog movement and right-stick
		-- aiming, which BizHawk cannot express natively.
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
local movement_x_accumulator = 0
local movement_y_accumulator = 0
local previous_movement_x = 0
local previous_movement_y = 0

local function write_signed16(address, value)
	mainmemory.write_u16_le(address, value % 0x10000)
end

local function release_overrides()
	pcall(function()
		joypad.set({})
		mainmemory.write_u16_le(AIM_ACTIVE_ADDRESS, 0)
		mainmemory.write_u16_le(MOVEMENT_ACTIVE_ADDRESS, 0)
		write_signed16(MOVEMENT_X_ADDRESS, 0)
		write_signed16(MOVEMENT_Y_ADDRESS, 0)
	end)
end

local function apply_overrides(overrides)
	local mapped = {}
	for name, state in pairs(overrides) do
		mapped["P" .. PLAYER .. " " .. name] = state
		mapped["P" .. PLAYER .. " RetroPad " .. name] = state
	end
	joypad.set(mapped)
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
	-- Do not let both axes spend their extra pixel on the same frame. This
	-- keeps odd-angle full-stick motion from alternating between short and
	-- conspicuously long diagonal steps.
	if math.abs(x_delta) >= 2 and math.abs(y_delta) >= 2 then
		if math.abs(x_velocity) < math.abs(y_velocity) then
			x_delta, movement_x_accumulator = adjust_delta(
				x_delta,
				movement_x_accumulator,
				x_delta > 0 and x_delta - 1 or x_delta + 1)
		else
			y_delta, movement_y_accumulator = adjust_delta(
				y_delta,
				movement_y_accumulator,
				y_delta > 0 and y_delta - 1 or y_delta + 1)
		end
	end

	return x_delta, y_delta
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
		movement_x_accumulator = 0
		movement_y_accumulator = 0
		previous_movement_x = 0
		previous_movement_y = 0
		return false, 0, 0
	end

	-- Keep one stable native direction for animation and facing. The ROM hook
	-- uses the independently quantized vector for actual movement.
	set_direction(overrides, nearest_direction(x, y))

	local x_velocity = x * magnitude * MOVEMENT_SPEED
	local y_velocity = y * -1 * magnitude * MOVEMENT_SPEED
	if previous_movement_x * x_velocity + previous_movement_y * y_velocity < 0 then
		movement_x_accumulator = 0
		movement_y_accumulator = 0
	end
	previous_movement_x = x_velocity
	previous_movement_y = y_velocity
	local x_delta
	local y_delta
	x_delta, movement_x_accumulator = quantize_axis(
		movement_x_accumulator,
		x_velocity)
	y_delta, movement_y_accumulator = quantize_axis(
		movement_y_accumulator,
		y_velocity)
	x_delta, y_delta = stabilize_vector(
		x_delta,
		y_delta,
		x_velocity,
		y_velocity)
	return true, x_delta, y_delta
end

local function cleanup()
	release_overrides()
end

release_overrides()
event.onexit(cleanup, "ZAMN DX controller cleanup")
console.log("ZAMN DX: controller runtime loaded for " .. settings.device)

while true do
	local axes = input.get_pressed_axes()
	-- Only the movement direction (for facing/animation) and the aim/fire button
	-- are overridden here; BizHawk applies every other button from its own config.
	local overrides = {}
	local aim_active = false
	local movement_active = false
	local movement_x = 0
	local movement_y = 0

	if settings.enabled then
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
		movement_active, movement_x, movement_y =
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
	mainmemory.write_u16_le(
		MOVEMENT_ACTIVE_ADDRESS,
		movement_active and MOVEMENT_SIGNATURE or 0)
	write_signed16(MOVEMENT_X_ADDRESS, movement_x)
	write_signed16(MOVEMENT_Y_ADDRESS, movement_y)
	apply_overrides(overrides)
	emu.frameadvance()
end
