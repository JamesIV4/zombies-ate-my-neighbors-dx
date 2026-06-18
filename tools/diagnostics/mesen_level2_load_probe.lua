-- Load the user's level-2 loading savestate and dump camera/tilemap state around
-- the widescreen off-map regions.
local state_path = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_1.mss"
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-level2-load.txt", "w")
local wram = emu.memType.snesWorkRam
local vram = emu.memType.snesVideoRam
local snes = emu.memType.snesMemory

local state_file = io.open(state_path, "rb")
local state_data = state_file and state_file:read("*a") or nil
if state_file then state_file:close() end

local loaded = false
local frame = 0
local drain_count = 0
local BLACK_CELL = 0x2BFF
local BLACK_TILE_WORD = 0x4FF0
local expected_tile = {}
for i = 0, 31 do
	expected_tile[i] = (i % 2 == 0) and 0x00 or 0xFF
end
local checked_offmap = 0
local failures = 0

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end
local function w7f(a) return emu.read(0x10000 + a, wram) end
local function w7f16(a) return w7f(a) + w7f(a + 1) * 256 end
local function vw(word) return emu.read(word * 2, vram) + emu.read(word * 2 + 1, vram) * 256 end

local function col_addr(col)
	if col < 32 then return col end
	return 0x0400 + (col - 32)
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
end

local function dump(label)
	local p = emu.getState()
	local camx, camy = r16(0x1B6A), r16(0x1B6C)
	local camcol = math.floor(camx / 8)
	local ringcol, ringrow = r16(0x1B76), r16(0x1B7A)
	local bgbase = r16(0x1B7E)
	local rowstride = r16(0x00B2)
	out:write(string.format(
		"%s frame=%d state=%02X active=%02X cam=(%04X,%04X) camcol=%d ring=(%04X,%04X) bgbase=%04X rowstride=%04X maxX=%04X CE=%04X tick=%04X lasttick=%04X drains=%d chr=%s map=%s forcedBlank=%s brightness=%s\n",
		label, frame, r8(0x000E), r8(0x0D25), camx, camy, camcol, ringcol, ringrow,
		bgbase, rowstride, r16(0x00B8), r16(0x00CE), r16(0x0020), w7f16(0xF52E), drain_count,
		tostring(p["ppu.layers[0].chrAddress"]), tostring(p["ppu.layers[0].tilemapAddress"]),
		tostring(p["ppu.forcedBlank"]), tostring(p["ppu.screenBrightness"])))

	for i = 0, 31 do
		local got = emu.read(BLACK_TILE_WORD * 2 + i, vram)
		if got ~= expected_tile[i] then
			failures = failures + 1
			out:write(string.format("  FAIL black-tile byte=%02d got=%02X expected=%02X\n",
				i, got, expected_tile[i]))
			break
		end
	end

	for sidx = 0, 19 do
		local off = (sidx < 10) and (sidx - 10) or (sidx + 22)
		local mc = camcol + off
		local tilecol = (ringcol + off) % 64
		local dest = bgbase + col_addr(tilecol)
		local cell0 = vw((dest + ringrow * 32) % 0x8000)
		local buf0 = w7f16(0xF000 + sidx * 64 + ((ringrow % 32) * 2))
		local offmap = mc < 0 or (mc * 2) >= rowstride
		out:write(string.format(
			"  slot=%02d off=%3d mc=%4d offmap=%s tilecol=%02d dest=%04X vram0=%04X colbuf0=%04X vdest=%04X\n",
			sidx, off, mc, tostring(offmap), tilecol, dest, cell0, buf0, w7f16(0xF540 + sidx * 2)))
		if offmap then
			checked_offmap = checked_offmap + 1
			for r = 0, 31 do
				local tilerow = (ringrow + r) % 32
				local got = vw((dest + tilerow * 32) % 0x8000)
				if got ~= BLACK_CELL then
					failures = failures + 1
					out:write(string.format(
						"    FAIL offmap row=%d tilerow=%d got=%04X expected=%04X\n",
						r, tilerow, got, BLACK_CELL))
					break
				end
			end
		end
	end
	out:write(string.format("  checked_offmap=%d failures=%d\n", checked_offmap, failures))
	out:flush()
end

local function on_drain()
	drain_count = drain_count + 1
end

local function end_frame()
	frame = frame + 1
	if loaded and (frame == 1 or frame == 2 or frame == 4 or frame == 8 or frame == 16 or frame == 32) then
		dump("dump")
	end
	if loaded and frame >= 32 then
		out:close()
		if checked_offmap > 0 and failures == 0 then emu.stop(0) else emu.stop(1) end
	elseif frame > 1200 then
		out:write("timeout\n")
		out:close()
		emu.stop(2)
	end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE,
	emu.cpuType.snes, snes)
emu.addMemoryCallback(on_drain, emu.callbackType.exec, 0x809E7B, 0x809E7B,
	emu.cpuType.snes, snes)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
