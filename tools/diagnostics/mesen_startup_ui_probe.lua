-- Dump startup/menu PPU state and the VRAM tilemaps involved in the widescreen
-- UI glitches reported from Mesen save slots 1..7.
local slot_arg = tonumber(os.getenv("ZAMNDX_UI_SLOT") or "1") or 1
local state_dir = (os.getenv("ZAMNDX_UI_STATE_DIR")
	or "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates"):gsub("\\", "/"):gsub("/$", "")
local out_dir = (os.getenv("ZAMNDX_UI_OUT_DIR")
	or "s:/Repos/zombies-ate-my-neighbors-dx"):gsub("\\", "/"):gsub("/$", "")
local state_path = string.format(
	"%s/Zombies Ate My Neighbors DX Widescreen_%d.mss", state_dir, slot_arg)

local out = io.open(string.format(
	"%s/mesen-startup-ui-probe-%d.txt", out_dir, slot_arg), "w")
local wram = emu.memType.snesWorkRam
local vram = emu.memType.snesVideoRam
local snes = emu.memType.snesMemory
local cgram = emu.memType.snesCgRam or emu.memType.snesCgram or emu.memType.snesPaletteRam

local slot = slot_arg
local frame = 0
local loaded = false
local pending_dump = false

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read(a, wram) + emu.read(a + 1, wram) * 256 end
local function vb(a) return emu.read(a & 0xFFFF, vram) end
local function vw(word) return vb(word * 2) + vb(word * 2 + 1) * 256 end
local function cg(i)
	if not cgram then return 0 end
	return emu.read(i * 2, cgram) + emu.read(i * 2 + 1, cgram) * 256
end

local function tilemap_word(base, col, row)
	local page = 0
	local c = col
	local r = row
	if col >= 32 then page = page + 0x400; c = col - 32 end
	if row >= 32 then page = page + 0x800; r = row - 32 end
	return (base + page + r * 32 + c) & 0x7FFF
end

local function write_row(label, base, row)
	out:write(string.format("%s row %02d:", label, row))
	for col = 0, 63 do
		out:write(string.format(" %04X", vw(tilemap_word(base, col, row))))
	end
	out:write("\n")
end

local function write_tile_bytes(label, base_word, tile)
	out:write(string.format("%s tile %03X @%04X:", label, tile, (base_word + tile * 16) & 0x7FFF))
	for i = 0, 31 do
		out:write(string.format(" %02X", vb(((base_word + tile * 16) * 2 + i) & 0xFFFF)))
	end
	out:write("\n")
end

local function write_layer_state(p, index)
	out:write(string.format(
		"  L%d en=%s main=%s sub=%s tm=%s chr=%s h=%s v=%s pri=%s bpp=%s size=%s\n",
		index + 1,
		tostring(p[string.format("ppu.layers[%d].enabled", index)]),
		tostring(p[string.format("ppu.layers[%d].mainScreen", index)]),
		tostring(p[string.format("ppu.layers[%d].subScreen", index)]),
		tostring(p[string.format("ppu.layers[%d].tilemapAddress", index)]),
		tostring(p[string.format("ppu.layers[%d].chrAddress", index)]),
		tostring(p[string.format("ppu.layers[%d].hScroll", index)]),
		tostring(p[string.format("ppu.layers[%d].vScroll", index)]),
		tostring(p[string.format("ppu.layers[%d].priority", index)]),
		tostring(p[string.format("ppu.layers[%d].bpp", index)]),
		tostring(p[string.format("ppu.layers[%d].size", index)])))
end

local function dump_slot()
	local p = emu.getState()
	out:write(string.format("\n=== slot %d ===\n", slot))
	out:write(string.format("state=%02X active=%02X frame=%d forcedBlank=%s brightness=%s bgMode=%s backdrop=%04X\n",
		r8(0x000E), r8(0x0D25), frame, tostring(p["ppu.forcedBlank"]),
		tostring(p["ppu.screenBrightness"]), tostring(p["ppu.bgMode"]), cg(0)))
	out:write(string.format("scroll cam=(%04X,%04X) bgRing=(%04X,%04X) bg1base=%04X stride=%04X CE=%04X\n",
		r16(0x1B6A), r16(0x1B6C), r16(0x1B76), r16(0x1B7A), r16(0x1B7E), r16(0x00B2), r16(0x00CE)))
	for i = 0, 3 do write_layer_state(p, i) end
	out:write("cgram:")
	for i = 0, 63 do
		out:write(string.format(" %02X=%04X", i, cg(i)))
		if i % 16 == 15 then out:write("\n      ") end
	end
	out:write("\n")

	write_row("$4000", 0x4000, 0)
	write_row("$4000", 0x4000, 1)
	write_row("$4000", 0x4000, 2)
	write_row("$6000", 0x6000, 0)
	write_row("$6000", 0x6000, 1)
	write_row("$6000", 0x6000, 2)
	write_row("$6400", 0x6400, 0)
	write_row("$6400", 0x6400, 1)
	write_row("$6400", 0x6400, 2)
	write_row("$6800", 0x6800, 0)
	write_row("$6800", 0x6800, 1)
	write_row("$6800", 0x6800, 2)
	write_row("$7000", 0x7000, 0)
	write_row("$7000", 0x7000, 1)
	write_row("$7000", 0x7000, 2)
	write_tile_bytes("$0000", 0x0000, 0x006)
	write_tile_bytes("$0000", 0x0000, 0x005)
	write_tile_bytes("$0000", 0x0000, 0x007)
	out:flush()
end

local function load_next()
	local f = io.open(state_path, "rb")
	if not f then
		out:write(string.format("missing slot %d: %s\n", slot, state_path))
		out:close()
		emu.stop(2)
		return
	end
	local data = f:read("*a")
	f:close()
	local ok, result = pcall(function() return emu.loadSavestate(data) end)
	loaded = ok and result
	out:write(string.format("load slot %d ok=%s bytes=%d\n", slot, tostring(loaded), #data))
	out:flush()
	if not loaded then
		out:close()
		emu.stop(2)
		return
	end
	pending_dump = true
	frame = 0
end

local function boot_load()
	if not loaded then
		load_next()
	end
end

local function end_frame()
	frame = frame + 1
	if pending_dump and frame >= 3 then
		pending_dump = false
		dump_slot()
		out:close()
		emu.stop(0)
	end
	if frame > 120 then
		out:write(string.format("timeout slot %d\n", slot))
		out:close()
		emu.stop(2)
	end
end

emu.addMemoryCallback(boot_load, emu.callbackType.exec, 0x0080AE, 0x0080AE,
	emu.cpuType.snes, snes)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
