-- Final calibration. Pick a black-tile index that is safe across levels:
--   * VRAM graphics slot all-zero (uploading overwrites nothing), and
--   * never referenced by the level's map data (so no on-screen cell turns black).
-- Confirms BG1 char base ($5000 words, gameplay $210B=$25) and color-index-8 black (CGRAM
-- $08). Set MODE: "level2" loads the savestate; "level1" boots from power-on to stage 1.
local MODE = "level1"
local state_path = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_1.mss"
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-gameplay-black-" .. MODE .. ".txt", "w")
local wram = emu.memType.snesWorkRam
local vram = emu.memType.snesVideoRam
local snes = emu.memType.snesMemory
local cgram = emu.memType.snesCgRam or emu.memType.snesCgram or emu.memType.snesPaletteRam

local state_data = nil
if MODE == "level2" then
	local f = io.open(state_path, "rb"); state_data = f and f:read("*a") or nil; if f then f:close() end
end

local loaded = (MODE ~= "level2"), nil
local frame, gp, done = 0, nil, false

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end
local function vb(a) return emu.read(a & 0xFFFF, vram) end
local function cg(i) return emu.read(i * 2, cgram) + emu.read(i * 2 + 1, cgram) * 256 end
local function tile_zero(chrWord, tile)
	local w0 = (chrWord + tile * 16) & 0x7FFF
	for i = 0, 31 do if vb(w0 * 2 + i) ~= 0 then return false end end
	return true
end

local function dump()
	local p = emu.getState()
	local chrWord = p["ppu.layers[0].chrAddress"] or 0
	out:write(string.format("\n%s GAMEPLAY t=%d state=%02X stride=%04X bgMode=%s BG1charWord=%04X tilemap=%s\n",
		MODE, frame - gp, r8(0x000E), r16(0x00B2), tostring(p["ppu.bgMode"]), chrWord,
		tostring(p["ppu.layers[0].tilemapAddress"])))
	out:write(string.format("  CGRAM p0c8=%04X(%s) backdrop p0c0=%04X\n",
		cg(0x08), cg(0x08) == 0 and "BLACK" or "non", cg(0x00)))

	-- Used tile-index set from the whole level map in bank $7F (over-estimate = safe).
	-- Map cells are 16-bit; tile index = cell & $3FF. Scan $7F:0000..$8EFF.
	local used = {}
	for a = 0x10000, 0x18EFE, 2 do
		local cell = emu.read(a, wram) + emu.read(a + 1, wram) * 256
		used[cell & 0x3FF] = true
	end
	-- also union with the live VRAM tilemap (ring buffer) at $1B7E
	local bgbase = r16(0x1B7E)
	for i = 0, 0x7FF do
		local cell = vb((bgbase + i) * 2) + vb((bgbase + i) * 2 + 1) * 256
		used[cell & 0x3FF] = true
	end

	out:write("  free non-wrap tiles (VRAM all-zero AND not in map/tilemap used-set), $2FF..$200:")
	local best = nil
	for t = 0x2FF, 0x200, -1 do
		if tile_zero(chrWord, t) and not used[t] then
			out:write(string.format(" %03X", t))
			if not best then best = t end
		end
	end
	out:write(string.format("\n  --> highest safe black-tile index = %s (VRAM word %s)\n",
		best and string.format("$%03X", best) or "NONE",
		best and string.format("$%04X", (chrWord + best * 16) & 0x7FFF) or "-"))
	out:write(string.format("  (is $27F used? %s ; is $2FF used? %s)\n",
		tostring(used[0x27F] == true), tostring(used[0x2FF] == true)))
	out:flush()
end

local function set_input()
	if r8(0x000E) == 2 and r8(0x0D25) ~= 0 then
		if not gp then gp = frame end
		emu.setInput({ left = true }, 0)
	else
		local mp = frame % 30
		emu.setInput({ start = (mp < 6), a = (mp >= 12 and mp < 18), b = (mp >= 22 and mp < 27) }, 0)
	end
end

local function load_state()
	if loaded then return end
	if not state_data then out:write("missing-state\n"); out:close(); emu.stop(2); return end
	loaded = select(2, pcall(function() return emu.loadSavestate(state_data) end))
	out:write(string.format("load=%s bytes=%d\n", tostring(loaded), #state_data)); out:flush()
end

local function end_frame()
	frame = frame + 1
	if gp and not done and r8(0x000E) == 2 then
		local p = emu.getState()
		if p["ppu.forcedBlank"] == false and (frame - gp) >= 60 then
			done = true; dump(); out:close(); emu.stop(0)
		elseif (frame - gp) >= 800 then
			done = true; out:write("never settled\n"); dump(); out:close(); emu.stop(0)
		end
	elseif frame > 6000 then
		out:write("never reached gameplay\n"); out:close(); emu.stop(2)
	end
end

if MODE == "level2" then
	emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE, emu.cpuType.snes, snes)
end
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
