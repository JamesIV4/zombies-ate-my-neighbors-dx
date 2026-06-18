-- Load the current widescreen savestate, hold left, and dump final OAM entries
-- near the left/right strips. This checks whether cull-helper calls survive into
-- actual 9-bit sprite positions.
local wram = emu.memType.snesWorkRam
local oam = emu.memType.snesSpriteRam
local state_path = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_1.mss"
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-savestate-final-oam.txt", "w")

local loaded = false
local frame = 0
local state_file = io.open(state_path, "rb")
local state_data = state_file and state_file:read("*a") or nil
if state_file then state_file:close() end

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local function sprite_x9(i)
	local lo = emu.read(i * 4, oam)
	local hbyte = emu.read(512 + math.floor(i / 4), oam)
	local xhigh = math.floor(hbyte / 2 ^ ((i % 4) * 2)) % 2
	return lo + xhigh * 256
end

local function signed9(x)
	if x >= 256 then return x - 512 end
	return x
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
	out:write("load=" .. tostring(loaded) .. " pcall=" .. tostring(ok) ..
		" bytes=" .. tostring(#state_data) .. "\n")
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
	out:write(string.format("f=%03d cam=(%04X,%04X) player=(%04X,%04X) rcount=%04X\n",
		frame, camx, camy, r16(0x0130), r16(0x0132), r16(0x009C)))
	local y = 0
	while y < r16(0x009C) do
		local slot = r16(0x137E + y)
		local sx = (r16(slot + 0x02) - camx) % 0x10000
		if sx >= 0x8000 then sx = sx - 0x10000 end
		local sy = (r16(slot + 0x06) - camy) % 0x10000
		if sy >= 0x8000 then sy = sy - 0x10000 end
		out:write(string.format("  render idx=%02d slot=%04X type=%02X screen=(%d,%d) spr=%04X:%04X sub=%04X\n",
			y / 2, slot, r8(slot + 0x0E), sx, sy, r16(slot + 0x08), r16(slot + 0x0A), r16(slot + 0x0C)))
		y = y + 2
	end
	local left, right, near_neighbor = 0, 0, 0
	out:write("  final OAM strip/neighbor-y entries:\n")
	for i = 0, 127 do
		local sy = emu.read(i * 4 + 1, oam)
		if sy < 0xE0 then
			local x = sprite_x9(i)
			local tile = emu.read(i * 4 + 2, oam)
			local attr = emu.read(i * 4 + 3, oam)
			local is_left = x >= 0x1B0 and x <= 0x1FF
			local is_right = x >= 0x100 and x <= 0x150
			local is_neighbor_y = sy >= 0x40 and sy <= 0x70
			if is_left then left = left + 1 end
			if is_right then right = right + 1 end
			if is_neighbor_y then near_neighbor = near_neighbor + 1 end
			if is_left or is_right or is_neighbor_y then
				out:write(string.format("    i=%03d x9=%03X sx=%d y=%03d tile=%02X attr=%02X%s%s%s\n",
					i, x, signed9(x), sy, tile, attr,
					is_left and " left" or "", is_right and " right" or "",
					is_neighbor_y and " neighborY" or ""))
			end
		end
	end
	out:write(string.format("  counts left=%d right=%d neighborY=%d\n", left, right, near_neighbor))
	out:flush()
end

local function end_frame()
	if not loaded then return end
	frame = frame + 1
	if frame == 1 or frame == 10 or frame == 20 or frame == 27 or frame == 30 or frame == 35 or frame == 40 or frame == 50 then
		dump_frame()
	end
	if frame >= 55 then
		out:close()
		emu.stop(0)
	end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE,
	emu.cpuType.snes, emu.memType.snesMemory)
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
