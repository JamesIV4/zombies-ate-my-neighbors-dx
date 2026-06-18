-- Load the user-made widescreen savestate, hold left, and dump active object slots
-- plus final render-list entries near the horizontal edges. This is used when a
-- visual object does not match the expected type bucket.
local wram = emu.memType.snesWorkRam
local state_path = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_1.mss"
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-savestate-objects.txt", "w")

local SLOT_FIRST = 0x185E
local SLOT_LAST = 0x1ACA
local SLOT_SIZE = 0x14

local loaded = false
local frame = 0
local state_file = io.open(state_path, "rb")
local state_data = state_file and state_file:read("*a") or nil
if state_file then state_file:close() end

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local function signed16(v)
	if v >= 0x8000 then return v - 0x10000 end
	return v
end

local function render_index(slot)
	local n = r16(0x009C)
	local y = 0
	while y < n do
		if r16(0x137E + y) == slot then return y / 2 end
		y = y + 2
	end
	return nil
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
	out:write("load=" .. tostring(loaded) .. " pcall=" .. tostring(ok) .. " bytes=" .. tostring(#state_data) .. "\n")
	out:flush()
	if not loaded then
		out:close()
		emu.stop(2)
	end
end

local function set_input()
	if loaded then emu.setInput({ left = true }, 0) end
end

local function dump_frame()
	local camx, camy = r16(0x1B6A), r16(0x1B6C)
	out:write(string.format("f=%03d cam=(%04X,%04X) player=(%04X,%04X) head=%04X rcount=%04X\n",
		frame, camx, camy, r16(0x0130), r16(0x0132), r16(0x1B5E), r16(0x009C)))

	out:write("  active slots near viewport:\n")
	for slot = SLOT_FIRST, SLOT_LAST, SLOT_SIZE do
		if r16(slot) >= 0x8000 then
			local sx = signed16((r16(slot + 0x02) - camx) % 0x10000)
			local sy = signed16((r16(slot + 0x06) - camy) % 0x10000)
			if sx >= -160 and sx <= 420 and sy >= -180 and sy <= 420 then
				local ri = render_index(slot)
				out:write(string.format(
					"    slot=%04X type=%02X flags=%04X screen=(%d,%d) render=%s next=%04X spr=%04X:%04X subtype=%04X\n",
					slot, r8(slot + 0x0E), r16(slot), sx, sy, ri and tostring(ri) or "-",
					r16(slot + 0x12), r16(slot + 0x08), r16(slot + 0x0A), r16(slot + 0x0C)))
			end
		end
	end

	out:write("  render entries:\n")
	local n = r16(0x009C)
	local y = 0
	while y < n do
		local slot = r16(0x137E + y)
		local sx = signed16((r16(slot + 0x02) - camx) % 0x10000)
		local sy = signed16((r16(slot + 0x06) - camy) % 0x10000)
		out:write(string.format(
			"    idx=%02d slot=%04X type=%02X flags=%04X screen=(%d,%d) spr=%04X:%04X subtype=%04X\n",
			y / 2, slot, r8(slot + 0x0E), r16(slot), sx, sy,
			r16(slot + 0x08), r16(slot + 0x0A), r16(slot + 0x0C)))
		y = y + 2
	end
	out:flush()
end

local function end_frame()
	if not loaded then return end
	frame = frame + 1
	if frame == 1 or frame == 20 or frame == 40 or frame == 60 or frame == 80 or
		frame == 100 or frame == 120 or frame == 140 then
		dump_frame()
	end
	if frame >= 150 then
		out:close()
		emu.stop(0)
	end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE,
	emu.cpuType.snes, emu.memType.snesMemory)
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
