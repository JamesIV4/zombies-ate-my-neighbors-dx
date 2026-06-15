-- Zombies Ate My Neighbors DX controller layer for BizHawk 2.11+
--
-- This script reads the host controller directly. It does not require the
-- controller to be mapped in BizHawk, although normal BizHawk mappings can
-- remain enabled.

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

local button_suffixes = {
	Up = "DpadUp",
	Down = "DpadDown",
	Left = "DpadLeft",
	Right = "DpadRight",
	Start = "Start",
	Select = "Back",
	Y = "X",
	B = "A",
	A = "B",
	X = "Y",
	L = "LeftShoulder",
	R = "RightShoulder",
}

local axis_order = { "left_x", "left_y", "right_x", "right_y" }

local axis_labels = {
	left_x = "Left stick X",
	left_y = "Left stick Y",
	right_x = "Right stick X",
	right_y = "Right stick Y",
}

local axis_suffixes = {
	left_x = "LeftThumbX Axis",
	left_y = "LeftThumbY Axis",
	right_x = "RightThumbX Axis",
	right_y = "RightThumbY Axis",
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

local function device_defaults(device)
	local prefix = device ~= "" and device or "X1"
	local result = {
		device = prefix,
		deadzone = 0.18,
		invert_left_y = true,
		invert_right_y = true,
		enabled = true,
		show_overlay = true,
		buttons = {},
		axes = {},
	}
	for _, name in ipairs(button_order) do
		result.buttons[name] = prefix .. " " .. button_suffixes[name]
	end
	for _, name in ipairs(axis_order) do
		result.axes[name] = prefix .. " " .. axis_suffixes[name]
	end
	return result
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
	local defaults = device_defaults("X1")
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
local ui = {
	open = false,
	button_text = {},
	axis_text = {},
}
local capture = nil
local previous_host_buttons = {}
local previous_axes = {}
local movement_angle_accumulator = 0
local movement_speed_accumulator = 0

local function sorted_keys(source, predicate)
	local result = {}
	for key, value in pairs(source or {}) do
		if not predicate or predicate(key, value) then
			table.insert(result, key)
		end
	end
	table.sort(result)
	return result
end

local function table_copy(source)
	local result = {}
	for key, value in pairs(source or {}) do
		result[key] = value
	end
	return result
end

local function device_of(name)
	return string.match(name or "", "^([^ ]+) ")
end

local function matches_selected_device(name)
	return settings.device == "Auto" or device_of(name) == settings.device
end

local function detected_devices(host_buttons, axes)
	local found = { Auto = true, X1 = true, X2 = true, X3 = true, X4 = true }
	for name, _ in pairs(host_buttons or {}) do
		local device = device_of(name)
		if device then
			found[device] = true
		end
	end
	for name, _ in pairs(axes or {}) do
		local device = device_of(name)
		if device then
			found[device] = true
		end
	end
	local result = sorted_keys(found)
	for index, value in ipairs(result) do
		if value == "Auto" then
			table.remove(result, index)
			break
		end
	end
	table.insert(result, 1, "Auto")
	return result
end

local function release_overrides()
	pcall(function()
		joypad.set({}, PLAYER)
		mainmemory.write_u16_le(AIM_ACTIVE_ADDRESS, 0)
	end)
end

local function escape_lua(value)
	return string.format("%q", tostring(value or ""))
end

local function save_settings()
	local file, error_message = io.open(config_path, "w")
	if not file then
		console.log("ZAMN DX: could not save controller config: " .. tostring(error_message))
		return false, error_message
	end
	file:write("return {\n")
	file:write("\tdevice = ", escape_lua(settings.device), ",\n")
	file:write("\tdeadzone = ", tostring(settings.deadzone), ",\n")
	file:write("\tinvert_left_y = ", tostring(settings.invert_left_y), ",\n")
	file:write("\tinvert_right_y = ", tostring(settings.invert_right_y), ",\n")
	file:write("\tenabled = ", tostring(settings.enabled), ",\n")
	file:write("\tshow_overlay = ", tostring(settings.show_overlay), ",\n")
	file:write("\tbuttons = {\n")
	for _, name in ipairs(button_order) do
		file:write("\t\t", name, " = ", escape_lua(settings.buttons[name]), ",\n")
	end
	file:write("\t},\n\taxes = {\n")
	for _, name in ipairs(axis_order) do
		file:write("\t\t", name, " = ", escape_lua(settings.axes[name]), ",\n")
	end
	file:write("\t},\n}\n")
	file:close()
	console.log("ZAMN DX: controller settings saved to " .. config_path)
	return true
end

local function set_checkbox(handle, value)
	forms.setproperty(handle, "Checked", value and true or false)
end

local function update_form_from_settings()
	if not ui.open then
		return
	end
	forms.settext(ui.device, settings.device)
	forms.settext(ui.deadzone, string.format("%.2f", settings.deadzone))
	set_checkbox(ui.enabled, settings.enabled)
	set_checkbox(ui.show_overlay, settings.show_overlay)
	set_checkbox(ui.invert_left_y, settings.invert_left_y)
	set_checkbox(ui.invert_right_y, settings.invert_right_y)
	for _, name in ipairs(button_order) do
		forms.settext(ui.button_text[name], settings.buttons[name] or "")
	end
	for _, name in ipairs(axis_order) do
		forms.settext(ui.axis_text[name], settings.axes[name] or "")
	end
end

local function sync_settings_from_form()
	if not ui.open then
		return
	end
	local ok = pcall(function()
		settings.device = forms.gettext(ui.device)
		settings.deadzone = tonumber(forms.gettext(ui.deadzone)) or settings.deadzone
		settings.deadzone = math.max(0, math.min(0.95, settings.deadzone))
		settings.enabled = forms.ischecked(ui.enabled)
		settings.show_overlay = forms.ischecked(ui.show_overlay)
		settings.invert_left_y = forms.ischecked(ui.invert_left_y)
		settings.invert_right_y = forms.ischecked(ui.invert_right_y)
		for _, name in ipairs(button_order) do
			settings.buttons[name] = forms.gettext(ui.button_text[name])
		end
		for _, name in ipairs(axis_order) do
			settings.axes[name] = forms.gettext(ui.axis_text[name])
		end
	end)
	if not ok then
		ui.open = false
	end
end

local function set_capture(kind, target)
	capture = { kind = kind, target = target }
	if ui.open then
		forms.settext(
			ui.capture_status,
			kind == "axis"
				and ("Move " .. axis_labels[target] .. " fully")
				or ("Press the host button for SNES " .. target)
		)
	end
end

local function cancel_capture()
	capture = nil
	if ui.open then
		forms.settext(ui.capture_status, "Capture: idle")
	end
end

local function finish_capture(message)
	capture = nil
	if ui.open then
		forms.settext(ui.capture_status, message)
	end
end

local function apply_device_defaults()
	sync_settings_from_form()
	local device = settings.device
	if device == "Auto" or device == "" then
		device = "X1"
	end
	local defaults = device_defaults(device)
	settings.device = device
	settings.buttons = defaults.buttons
	settings.axes = defaults.axes
	settings.invert_left_y = defaults.invert_left_y
	settings.invert_right_y = defaults.invert_right_y
	update_form_from_settings()
	forms.settext(ui.capture_status, "Defaults applied for " .. device .. "; click Save to keep them")
end

local function reset_defaults()
	settings = device_defaults("X1")
	update_form_from_settings()
	release_overrides()
	forms.settext(ui.capture_status, "X1 defaults restored and inputs released; click Save to keep them")
end

local function refresh_devices()
	if not ui.open then
		return
	end
	local devices = detected_devices(input.get(), input.get_pressed_axes())
	forms.setdropdownitems(ui.device, devices, false)
	forms.settext(ui.device, settings.device)
end

local function build_ui()
	if ui.open then
		return
	end

	ui.open = true
	ui.form = forms.newform(780, 690, "ZAMN DX Controller Setup", function()
		ui.open = false
	end)

	forms.label(ui.form, "Host device", 12, 12, 82, 22)
	ui.device = forms.dropdown(ui.form, detected_devices({}, {}), 96, 10, 95, 24)
	forms.button(ui.form, "Refresh", refresh_devices, 198, 9, 72, 25)
	forms.button(ui.form, "Apply defaults", apply_device_defaults, 276, 9, 100, 25)
	forms.button(ui.form, "Save", function()
		sync_settings_from_form()
		local saved, error_message = save_settings()
		if saved then
			forms.settext(ui.capture_status, "Saved. These settings will be reused on the next launch")
		else
			forms.settext(ui.capture_status, "Save failed: " .. tostring(error_message))
		end
	end, 382, 9, 64, 25)
	forms.button(ui.form, "Reset X1", reset_defaults, 452, 9, 76, 25)
	forms.button(ui.form, "Release inputs", function()
		release_overrides()
		forms.settext(ui.capture_status, "All Lua input overrides released")
	end, 534, 9, 100, 25)
	forms.button(ui.form, "Cancel capture", cancel_capture, 640, 9, 108, 25)

	ui.enabled = forms.checkbox(ui.form, "Enable controller layer", 12, 42)
	ui.show_overlay = forms.checkbox(ui.form, "Show in-game status", 174, 42)
	forms.label(ui.form, "Deadzone", 338, 44, 62, 20)
	ui.deadzone = forms.textbox(ui.form, "", 42, 20, nil, 402, 40, false, false)
	ui.invert_left_y = forms.checkbox(ui.form, "Invert left Y", 468, 42)
	ui.invert_right_y = forms.checkbox(ui.form, "Invert right Y", 584, 42)

	forms.label(ui.form, "Analog axes", 12, 75, 120, 20)
	for index, name in ipairs(axis_order) do
		local y = 98 + (index - 1) * 29
		forms.label(ui.form, axis_labels[name], 12, y + 3, 98, 20)
		ui.axis_text[name] = forms.textbox(ui.form, "", 244, 20, nil, 112, y, false, false)
		local target = name
		forms.button(ui.form, "Capture", function()
			set_capture("axis", target)
		end, 364, y - 1, 70, 25)
	end

	forms.label(ui.form, "SNES button mappings", 12, 225, 160, 20)
	for index, name in ipairs(button_order) do
		local column = math.floor((index - 1) / 6)
		local row = (index - 1) % 6
		local x = 12 + column * 382
		local y = 250 + row * 30
		forms.label(ui.form, "SNES " .. name, x, y + 3, 78, 20)
		ui.button_text[name] = forms.textbox(ui.form, "", 210, 20, nil, x + 82, y, false, false)
		local target = name
		forms.button(ui.form, "Capture", function()
			set_capture("button", target)
		end, x + 298, y - 1, 70, 25)
	end

	ui.capture_status = forms.label(ui.form, "Capture: idle", 12, 435, 736, 22, true)
	forms.label(ui.form, "Live controller test", 12, 466, 160, 20)
	ui.live_buttons = forms.label(ui.form, "Host buttons: none", 12, 490, 736, 42, true)
	ui.live_axes = forms.label(ui.form, "Axes: move both sticks", 12, 535, 736, 62, true)
	ui.live_output = forms.label(ui.form, "Mapped SNES: none", 12, 602, 736, 42, true)
	forms.label(
		ui.form,
		"Tip: button and axis captures use the selected Host device. Right stick aims and fires.",
		12,
		648,
		736,
		20
	)

	update_form_from_settings()
	refresh_devices()
end

local function process_capture(host_buttons, axes)
	if not capture then
		return
	end

	if capture.kind == "button" then
		for _, name in ipairs(sorted_keys(host_buttons, function(key, value)
			return value and matches_selected_device(key)
		end)) do
			if not previous_host_buttons[name] and not string.find(name, "Stick", 1, true) then
			settings.buttons[capture.target] = name
				if ui.open then
					forms.settext(ui.button_text[capture.target], name)
				end
				finish_capture("Captured SNES " .. capture.target .. " = " .. name .. "; click Save to keep it")
				return
			end
		end
	else
		local best_name = nil
		local best_value = 0
		for name, value in pairs(axes) do
			local previous = previous_axes[name] or 0
			if matches_selected_device(name)
				and math.abs(value) > 5000
				and math.abs(value - previous) > 1500
				and math.abs(value) > math.abs(best_value)
			then
				best_name = name
				best_value = value
			end
		end
		if best_name then
			settings.axes[capture.target] = best_name
			if ui.open then
				forms.settext(ui.axis_text[capture.target], best_name)
			end
			finish_capture("Captured " .. axis_labels[capture.target] .. " = " .. best_name .. "; click Save to keep it")
		end
	end
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
	local scaled_magnitude = math.min(
		1,
		(magnitude - settings.deadzone) / (1 - settings.deadzone)
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

local function format_live_buttons(host_buttons)
	local names = sorted_keys(host_buttons, function(name, value)
		return value and matches_selected_device(name)
	end)
	if #names == 0 then
		return "Host buttons: none"
	end
	return "Host buttons: " .. table.concat(names, ", ")
end

local function format_live_axes(axes)
	local names = sorted_keys(axes, function(name, _)
		return matches_selected_device(name) and not string.find(name, "WMouse", 1, true)
	end)
	if #names == 0 then
		return "Axes: move both sticks once so BizHawk reports them"
	end
	local parts = {}
	for _, name in ipairs(names) do
		table.insert(parts, string.format("%s=%d", name, axes[name]))
	end
	return "Axes: " .. table.concat(parts, " | ")
end

local function format_live_output(overrides)
	local names = sorted_keys(overrides, function(_, value)
		return value == true
	end)
	if #names == 0 then
		return "Mapped SNES: none"
	end
	return "Mapped SNES: " .. table.concat(names, ", ")
end

local function update_live_ui(host_buttons, axes, overrides)
	if not ui.open then
		return
	end
	pcall(function()
		forms.settext(ui.live_buttons, format_live_buttons(host_buttons))
		forms.settext(ui.live_axes, format_live_axes(axes))
		forms.settext(ui.live_output, format_live_output(overrides))
	end)
end

local function cleanup()
	release_overrides()
	if ui.open and ui.form then
		pcall(forms.destroy, ui.form)
	end
end

release_overrides()
build_ui()
event.onexit(cleanup, "ZAMN DX controller cleanup")
console.log("ZAMN DX: controller layer loaded; setup UI opened; default device " .. settings.device)

while true do
	sync_settings_from_form()
	local host_buttons = input.get()
	local axes = input.get_pressed_axes()
	process_capture(host_buttons, axes)

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
	update_live_ui(host_buttons, axes, overrides)

	if settings.show_overlay then
		local device_text = settings.device == "Auto" and "auto" or settings.device
		local setup_text = ui.open and "setup open" or "setup closed"
		gui.text(2, 2, "ZAMN DX | device " .. device_text .. " | " .. setup_text)
	end

	previous_host_buttons = table_copy(host_buttons)
	previous_axes = table_copy(axes)
	emu.frameadvance()
end
