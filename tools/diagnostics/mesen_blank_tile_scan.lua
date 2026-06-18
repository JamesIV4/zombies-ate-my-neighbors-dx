-- Scan current BG1 character data for all-zero tile graphics that can be used as
-- a real black/blank tilemap cell.
local state_path = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_1.mss"
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-blank-tile-scan.txt", "w")
local vram = emu.memType.snesVideoRam
local snes = emu.memType.snesMemory

local state_file = io.open(state_path, "rb")
local state_data = state_file and state_file:read("*a") or nil
if state_file then state_file:close() end

local loaded = false
local frame = 0

local function vb(a) return emu.read(a, vram) end
local function vw(word) return vb(word * 2) + vb(word * 2 + 1) * 256 end

local function load_state()
	if loaded then return end
	if not state_data then
		out:write("missing state\n")
		out:close()
		emu.stop(2)
		return
	end
	local ok, result = pcall(function() return emu.loadSavestate(state_data) end)
	loaded = ok and result
	out:write("load=" .. tostring(loaded) .. " bytes=" .. tostring(#state_data) .. "\n")
	out:flush()
end

local function tile_zero(base_word, tile)
	local start = (base_word + tile * 16) * 2
	for i = 0, 31 do
		if vb(start + i) ~= 0 then return false end
	end
	return true
end

local function scan()
	local p = emu.getState()
	local chr_bytes = p["ppu.layers[0].chrAddress"] or 0
	local chr_word = math.floor(chr_bytes / 2)
	out:write("memTypes:")
	for k, v in pairs(emu.memType) do
		out:write(" " .. tostring(k) .. "=" .. tostring(v))
	end
	out:write("\n")
	local cgram = emu.memType.snesCgRam or emu.memType.snesCgram or emu.memType.snesPaletteRam
	if cgram then
		out:write("cgram:")
		for i = 0, 255 do
			local lo = emu.read(i * 2, cgram)
			local hi = emu.read(i * 2 + 1, cgram)
			out:write(string.format(" %02X=%04X", i, lo + hi * 256))
			if i % 32 == 31 then out:write("\n      ") end
		end
		out:write("\n")
	else
		out:write("cgram: unavailable\n")
	end
	out:write(string.format("chr_bytes=%04X chr_word=%04X tilemap_state=%s\n",
		chr_bytes, chr_word, tostring(p["ppu.layers[0].tilemapAddress"])))
	out:write(string.format("tile0 words:"))
	for i = 0, 15 do out:write(string.format(" %04X", vw(chr_word + i))) end
	out:write("\n")
	local count = 0
	for tile = 0, 0x3FF do
		if tile_zero(chr_word, tile) then
			out:write(string.format("zero tile %03X cell=%04X\n", tile, tile))
			count = count + 1
			if count >= 40 then break end
		end
	end
	out:write("zero_count_sample=" .. tostring(count) .. "\n")
	out:close()
	emu.stop(count > 0 and 0 or 1)
end

local function end_frame()
	frame = frame + 1
	if loaded and frame >= 2 then scan()
	elseif frame > 1200 then
		out:write("timeout\n")
		out:close()
		emu.stop(2)
	end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE,
	emu.cpuType.snes, snes)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
