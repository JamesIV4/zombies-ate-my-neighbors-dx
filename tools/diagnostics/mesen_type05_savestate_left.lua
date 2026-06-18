-- Load the user-made widescreen savestate, hold left, and trace type-$05
-- items/survivors as they enter the left widescreen strip.
local wram = emu.memType.snesWorkRam
local oam = emu.memType.snesSpriteRam
local state_path = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_1.mss"
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-type05-left-state.txt", "w")
out:write("script-start\n")
out:flush()

local SLOT_FIRST = 0x185E
local SLOT_LAST = 0x1ACA
local SLOT_SIZE = 0x14
local SPRITE_MARGIN = 0x50

local loaded = false
local frame = 0
local peak_active_left, peak_render_left, peak_oam_left = 0, 0, 0
local first_render_left = nil

local state_file = io.open(state_path, "rb")
local state_data = state_file and state_file:read("*a") or nil
if state_file then state_file:close() end
out:write("state-bytes=" .. tostring(state_data and #state_data or 0) .. "\n")
out:flush()

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local function signed16(v)
	if v >= 0x8000 then return v - 0x10000 end
	return v
end

local function is_left_strip_sx(sx)
	return sx >= 0x10000 - SPRITE_MARGIN
end

local function is_rendered(slot)
	local n = r16(0x009C)
	local y = 0
	while y < n do
		if r16(0x137E + y) == slot then return true end
		y = y + 2
	end
	return false
end

local function sprite_x9(i)
	local lo = emu.read(i * 4, oam)
	local hbyte = emu.read(512 + math.floor(i / 4), oam)
	local xhigh = math.floor(hbyte / 2 ^ ((i % 4) * 2)) % 2
	return lo + xhigh * 256
end

local function count_left_oam()
	local left = 0
	for i = 0, 127 do
		local y = emu.read(i * 4 + 1, oam)
		if y < 0xE0 then
			local x = sprite_x9(i)
			if x >= 0x1B0 and x <= 0x1FF then left = left + 1 end
		end
	end
	return left
end

local function set_input()
	if loaded then
		emu.setInput({ left = true }, 0)
	end
end

local function load_state()
	if loaded then return end
	if not state_data then
		out:write("load=false missing-state\n")
		out:close()
		emu.stop(2)
		return
	end
	local ok, result = pcall(function() return emu.loadSavestate(state_data) end)
	loaded = ok and result
	out:write("load=" .. tostring(loaded) .. " pcall=" .. tostring(ok) .. "\n")
	out:flush()
	if not loaded then
		out:close()
		emu.stop(2)
	end
end

local function scan()
	local camx, camy = r16(0x1B6A), r16(0x1B6C)
	local active_left, render_left = 0, 0
	local lines = {}
	for slot = SLOT_FIRST, SLOT_LAST, SLOT_SIZE do
		if r8(slot + 0x0E) == 0x05 and r16(slot) >= 0x8000 then
			local sx = (r16(slot + 0x02) - camx) % 0x10000
			local sy = signed16((r16(slot + 0x06) - camy) % 0x10000)
			local rendered = is_rendered(slot)
			if is_left_strip_sx(sx) and sy >= -128 and sy < 384 then
				active_left = active_left + 1
				if rendered then render_left = render_left + 1 end
				lines[#lines + 1] = string.format(
					"slot=%04X flags=%04X screen=(%d,%d) render=%s spr=%04X:%04X subtype=%04X",
					slot, r16(slot), signed16(sx), sy, tostring(rendered),
					r16(slot + 0x08), r16(slot + 0x0A), r16(slot + 0x0C))
			end
		end
	end
	local oam_left = count_left_oam()
	if active_left > peak_active_left then peak_active_left = active_left end
	if render_left > peak_render_left then peak_render_left = render_left end
	if oam_left > peak_oam_left then peak_oam_left = oam_left end
	if render_left > 0 and not first_render_left then first_render_left = frame end
	if active_left > 0 or render_left > 0 or frame % 20 == 0 then
		out:write(string.format(
			"f=%03d cam=(%04X,%04X) player=(%04X,%04X) active_left=%d render_left=%d oam_left=%d rcount=%04X\n",
			frame, camx, camy, r16(0x0130), r16(0x0132),
			active_left, render_left, oam_left, r16(0x009C)))
		for _, line in ipairs(lines) do out:write("  " .. line .. "\n") end
		out:flush()
	end
end

local function end_frame()
	if not loaded then
		return
	end

	frame = frame + 1
	scan()
	if frame >= 260 then
		out:write(string.format(
			"summary peak_active_left=%d peak_render_left=%d peak_oam_left=%d first_render_left=%s\n",
			peak_active_left, peak_render_left, peak_oam_left,
			first_render_left and tostring(first_render_left) or "nil"))
		out:close()
		emu.stop((peak_active_left > 0 and peak_render_left > 0 and peak_oam_left > 0) and 0 or 1)
	end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE,
	emu.cpuType.snes, emu.memType.snesMemory)
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
