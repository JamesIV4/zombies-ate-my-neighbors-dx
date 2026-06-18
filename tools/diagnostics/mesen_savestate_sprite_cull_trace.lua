-- Load the user savestate, hold left, and summarize calls to ws_sprite_cull.
-- This verifies which object types actually generate sprite tiles in the strip.
local wram = emu.memType.snesWorkRam
local state_path = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_1.mss"
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-savestate-sprite-cull.txt", "w")

local WS_SPRITE_CULL = 0x8FD004
local SPRITE_MARGIN = 0x50

local loaded = false
local frame = 0
local state_file = io.open(state_path, "rb")
local state_data = state_file and state_file:read("*a") or nil
if state_file then state_file:close() end

local stats = {}
local samples = {}

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local function signed16(v)
	if v >= 0x8000 then return v - 0x10000 end
	return v
end

local function bucket(x)
	if x <= 0x00FF then return "on" end
	if x >= 0x0100 and x <= 0x00FF + SPRITE_MARGIN then return "right" end
	if x >= 0x10000 - SPRITE_MARGIN then return "left" end
	return "far"
end

local function get_type_stats(ty)
	local s = stats[ty]
	if not s then
		s = { on = 0, left = 0, right = 0, far = 0 }
		stats[ty] = s
	end
	return s
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

local function on_cull()
	if not loaded then return end
	local c = emu.getCpuState(emu.cpuType.snes)
	local sx = c.a % 0x10000
	local ri = r16(0x009A)
	local slot = r16(0x137E + ri)
	local ty = r8(slot + 0x0E)
	local b = bucket(sx)
	local s = get_type_stats(ty)
	s[b] = s[b] + 1
	if b == "left" and #samples < 80 then
		samples[#samples + 1] = string.format(
			"f=%03d type=%02X slot=%04X objScreen=(%d,%d) tileX=%d spr=%04X:%04X subtype=%04X",
			frame, ty, slot,
			signed16((r16(slot + 0x02) - r16(0x1B6A)) % 0x10000),
			signed16((r16(slot + 0x06) - r16(0x1B6C)) % 0x10000),
			signed16(sx), r16(slot + 0x08), r16(slot + 0x0A), r16(slot + 0x0C))
	end
end

local function end_frame()
	if not loaded then return end
	frame = frame + 1
	if frame >= 160 then
		out:write("type  on  left  right  far\n")
		local types = {}
		for ty in pairs(stats) do types[#types + 1] = ty end
		table.sort(types)
		for _, ty in ipairs(types) do
			local s = stats[ty]
			out:write(string.format("$%02X %5d %5d %5d %5d\n", ty, s.on, s.left, s.right, s.far))
		end
		out:write("left samples:\n")
		for _, line in ipairs(samples) do out:write("  " .. line .. "\n") end
		out:close()
		emu.stop(0)
	end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE,
	emu.cpuType.snes, emu.memType.snesMemory)
emu.addMemoryCallback(on_cull, emu.callbackType.exec, WS_SPRITE_CULL, WS_SPRITE_CULL,
	emu.cpuType.snes, emu.memType.snesMemory)
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
