-- One-shot HUD-state survey for a save slot (ZAMNDX_SLOT). Dumps the signals the
-- bsnes-hd gameplay-HUD detector could key on, so the pool-dive transition
-- ($0E==2, $0D25==0, but real gameplay) can be told apart from a level-load
-- ($0E==2, $0D25==0, loading screen). Compare slot 3 (dive) vs slot 11 (load).
local slot = tonumber(os.getenv("ZAMNDX_SLOT") or "3") or 3
local state_path = string.format(
	"C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_%d.mss", slot)
local out = io.open(string.format(
	"s:/Repos/zombies-ate-my-neighbors-dx/mesen-hud-survey-%d.txt", slot), "w")

local wram = emu.memType.snesWorkRam
local snes = emu.memType.snesMemory
local vram = emu.memType.snesVideoRam
local loaded, frame = false, 0

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read(a, wram) + emu.read(a + 1, wram) * 256 end
local function vw(word) return emu.read((word * 2) & 0xFFFF, vram) + emu.read((word * 2 + 1) & 0xFFFF, vram) * 256 end

local function row(label, base)
	out:write(label)
	for c = 0, 31 do out:write(string.format(" %04X", vw(base + c))) end
	out:write("\n")
end

local function dump()
	local p = emu.getState()
	out:write(string.format("=== slot %d ===\n", slot))
	out:write(string.format("$0E=%02X $0D25=%02X bgMode=%s forcedBlank=%s brightness=%s\n",
		r8(0x000E), r8(0x0D25), tostring(p["ppu.bgMode"]),
		tostring(p["ppu.forcedBlank"]), tostring(p["ppu.screenBrightness"])))
	out:write(string.format("cam=(%04X,%04X) mapW($B2)=%04X $0D00..$0D2F:\n", r16(0x1B6A), r16(0x1B6C), r16(0x00B2)))
	out:write(" ")
	for a = 0x0D00, 0x0D2F do out:write(string.format(" %02X", r8(a))) end
	out:write("\n $00..$1F: ")
	for a = 0x00, 0x1F do out:write(string.format(" %02X", r8(a))) end
	out:write("\n")
	for i = 0, 3 do
		out:write(string.format("L%d tilemap=%s char=%s en=%s main=%s\n", i + 1,
			tostring(p[string.format("ppu.layers[%d].tilemapAddress", i)]),
			tostring(p[string.format("ppu.layers[%d].chrAddress", i)]),
			tostring(p[string.format("ppu.layers[%d].enabled", i)]),
			tostring(p[string.format("ppu.layers[%d].mainScreen", i)])))
	end
	row("BG3 row0:", 0x6400)
	row("BG3 row1:", 0x6420)
	row("BG3 row2:", 0x6440)
	out:flush()
end

local function load_state()
	if loaded then return end
	local f = io.open(state_path, "rb")
	if not f then out:write("missing " .. state_path .. "\n") out:close() emu.stop(2) return end
	local data = f:read("*a"); f:close()
	local ok, res = pcall(function() return emu.loadSavestate(data) end)
	loaded = ok and res
	if not loaded then out:write("load failed\n") out:close() emu.stop(2) end
	frame = 0
end

local function end_frame()
	if not loaded then return end
	frame = frame + 1
	if frame == 3 then dump() out:close() emu.stop(0) end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE, emu.cpuType.snes, snes)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
