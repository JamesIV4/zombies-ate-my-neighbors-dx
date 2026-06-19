-- Identify how the in-level radar inset (underlay + flickering neighbor dots) is
-- rendered, so the widescreen HUD left-shift can be extended to it. Loads one
-- Mesen save slot (ZAMNDX_SLOT; 1=radar off, 2=radar on), dumps the full PPU
-- state table (so slot1 vs slot2 can be diffed) plus an OAM snapshot across a few
-- frames to catch the cycling dots.
local slot = tonumber(os.getenv("ZAMNDX_SLOT") or "2") or 2
local state_dir = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates"
local state_path = string.format(
	"%s/Zombies Ate My Neighbors DX Widescreen_%d.mss", state_dir, slot)
local out = io.open(string.format(
	"s:/Repos/zombies-ate-my-neighbors-dx/mesen-radar-probe-%d.txt", slot), "w")

local wram = emu.memType.snesWorkRam
local snes = emu.memType.snesMemory
local oam = emu.memType.snesSpriteRam
local vram = emu.memType.snesVideoRam

local loaded = false
local frame = 0

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read(a, wram) + emu.read(a + 1, wram) * 256 end
local function ob(a) return emu.read(a, oam) end

local function dump_full_state()
	local p = emu.getState()
	-- sort keys for a stable, diffable dump
	local keys = {}
	for k, _ in pairs(p) do keys[#keys + 1] = tostring(k) end
	table.sort(keys)
	out:write("=== getState keys ===\n")
	for _, k in ipairs(keys) do
		out:write(string.format("%s = %s\n", k, tostring(p[k])))
	end
	out:flush()
end

local function dump_oam(tag)
	out:write(string.format("--- OAM %s frame=%d ---\n", tag, frame))
	-- low table: 4 bytes/sprite at 0..511; high table: 32 bytes at 512..543
	for i = 0, 127 do
		local x = ob(i * 4 + 0)
		local y = ob(i * 4 + 1)
		local tile = ob(i * 4 + 2)
		local attr = ob(i * 4 + 3)
		local hi = ob(512 + (i >> 2))
		local sh = (i & 3) * 2
		local xhigh = (hi >> sh) & 1
		local big = (hi >> (sh + 1)) & 1
		-- only print sprites that are not parked off the bottom (y==0xF0/0xE0 is the
		-- engine's "hidden" park), to keep the dump focused
		if y ~= 0xF0 and y ~= 0xE0 then
			out:write(string.format(
				"  spr%03d x=%d(%+d) y=%d tile=%02X attr=%02X pal=%d pri=%d big=%d\n",
				i, x, (xhigh == 1 and x - 256 or x), y, tile, attr,
				(attr >> 1) & 7, (attr >> 4) & 3, big))
		end
	end
	out:flush()
end

local function dump_slot()
	out:write(string.format("=== slot %d  state=%02X active=%02X cam=(%04X,%04X) ===\n",
		slot, r8(0x000E), r8(0x0D25), r16(0x1B6A), r16(0x1B6C)))
	dump_full_state()
	dump_oam("snapshot")
end

local function load_state()
	if loaded then return end
	local f = io.open(state_path, "rb")
	if not f then out:write("missing " .. state_path .. "\n") out:close() emu.stop(2) return end
	local data = f:read("*a")
	f:close()
	local ok, res = pcall(function() return emu.loadSavestate(data) end)
	loaded = ok and res
	out:write(string.format("load slot %d ok=%s bytes=%d\n", slot, tostring(loaded), #data))
	if not loaded then out:close() emu.stop(2) end
	frame = 0
end

local function end_frame()
	if not loaded then return end
	frame = frame + 1
	if frame == 3 then dump_slot() end
	if frame >= 4 and frame <= 9 then dump_oam("cycle") end
	if frame >= 10 then out:close() emu.stop(0) end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE,
	emu.cpuType.snes, snes)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
