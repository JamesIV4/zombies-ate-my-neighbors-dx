-- Trace why the gameplay HUD loses its widescreen left-anchor during the pool-dive
-- transition (HUD snaps right for a few frames before the bubble UI loads). Loads
-- save slot 3 (the captured moment) and logs, per frame, the exact inputs the
-- bsnes-hd renderer keys on: the $0E/$0D25 guards and BG3's tilemap/char base.
local slot = tonumber(os.getenv("ZAMNDX_SLOT") or "3") or 3
local state_path = string.format(
	"C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_%d.mss", slot)
local out = io.open(string.format(
	"s:/Repos/zombies-ate-my-neighbors-dx/mesen-pool-hud-probe-%d.txt", slot), "w")

local wram = emu.memType.snesWorkRam
local snes = emu.memType.snesMemory
local vram = emu.memType.snesVideoRam
local loaded, frame = false, 0
local last = nil

local function r8(a) return emu.read(a, wram) end
local function vw(word) return emu.read((word * 2) & 0xFFFF, vram) + emu.read((word * 2 + 1) & 0xFFFF, vram) * 256 end

local function load_state()
	if loaded then return end
	local f = io.open(state_path, "rb")
	if not f then out:write("missing " .. state_path .. "\n") out:close() emu.stop(2) return end
	local data = f:read("*a"); f:close()
	local ok, res = pcall(function() return emu.loadSavestate(data) end)
	loaded = ok and res
	out:write(string.format("load slot %d ok=%s\n", slot, tostring(loaded)))
	out:write("frame  $0E $0D25 mode | BG3 en  tilemap  char  | zamnHud | bg3row0[0..3]\n")
	if not loaded then out:close() emu.stop(2) end
	frame = 0
end

local function log()
	local p = emu.getState()
	local state = r8(0x000E)
	local active = r8(0x0D25)
	local mode = p["ppu.bgMode"]
	local en = p["ppu.layers[2].enabled"]
	local tm = p["ppu.layers[2].tilemapAddress"]
	local ch = p["ppu.layers[2].chrAddress"]
	local mapw = emu.read(0x00B2, wram) + emu.read(0x00B3, wram) * 256
	-- OLD guard (player-active) vs NEW guard (map loaded). The dive drops $0D25 to 0
	-- for a few frames while $B2 stays set, so NEW stays YES across the whole dive.
	local old = (mode == 1 and tm == 25600 and ch == 16384 and state == 2 and active ~= 0)
	local new = (mode == 1 and tm == 25600 and ch == 16384 and state == 2 and mapw ~= 0)
	local line = string.format(
		"%5d  %3d  %3d   %s | tm=%s ch=%s mapW=%04X | old=%s new=%s",
		frame, state, active, tostring(mode), tostring(tm), tostring(ch), mapw,
		old and "YES" or "no ", new and "YES" or "no ")
	-- print every frame for the first stretch, then only on change, to keep it readable
	if frame <= 40 or line:sub(8) ~= (last or "") then
		out:write(line .. "\n")
	end
	last = line:sub(8)
	out:flush()
end

local function end_frame()
	if not loaded then return end
	frame = frame + 1
	log()
	if frame >= 120 then out:close() emu.stop(0) end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE, emu.cpuType.snes, snes)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
