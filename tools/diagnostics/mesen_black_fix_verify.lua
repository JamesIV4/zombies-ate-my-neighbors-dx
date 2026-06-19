-- Verify the level-2 off-map black fix:
--   (1) LOADING TEXT INTACT: during any non-gameplay state ($0E != 2), the black-fill must
--       never queue a VRAM DMA. Our black tile is the only DMA whose source bank is $8F, so
--       at every drain we scan the VRAM-DMA queue ($1B84 src / $1BB4 bank, $CE bytes) and
--       flag any bank-$8F entry seen while $0E != 2. (The old build uploaded a black tile to
--       the loading font + queued black columns over the loading text -> this catches that.)
--   (2) GAMEPLAY OFF-MAP BLACK: play forward to level-2 gameplay, walk to the left edge, then
--       confirm CGRAM $08 == 0000 (black), the off-map tilemap cells == $227F, and the black
--       tile graphics (solid color index 8) are present at VRAM word $77F0.
local state_path = "C:/Users/james/OneDrive/Documents/MesenCE/SaveStates/Zombies Ate My Neighbors DX Widescreen_1.mss"
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-black-fix.txt", "w")
local wram = emu.memType.snesWorkRam
local vram = emu.memType.snesVideoRam
local snes = emu.memType.snesMemory
local cgram = emu.memType.snesCgRam or emu.memType.snesCgram or emu.memType.snesPaletteRam

local BLACK_CELL = 0x227F
local BLACK_TILE_VRAM = 0x77F0
local f = io.open(state_path, "rb"); local state_data = f and f:read("*a") or nil; if f then f:close() end

local loaded, frame, gp, done = false, 0, nil, false
local loaddrains, loadviol = 0, 0     -- drains seen while non-gameplay, and bank-$8F violations

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end
local function vb(a) return emu.read(a & 0xFFFF, vram) end
local function cg(i) return emu.read(i * 2, cgram) + emu.read(i * 2 + 1, cgram) * 256 end

-- at every drain, while non-gameplay, scan the populated queue for our black-fill (bank $8F)
local function on_drain()
	if not loaded then return end
	if r8(0x000E) == 2 then return end          -- gameplay; black-fill is allowed here
	loaddrains = loaddrains + 1
	local ce = r16(0x00CE)
	for x = 0, ce - 2, 2 do
		if r8(0x1BB4 + x) == 0x8F then
			loadviol = loadviol + 1
			if loadviol <= 8 then
				out:write(string.format("  LOAD VIOLATION state=%02X x=%d src=%04X bank=8F vram=%04X\n",
					r8(0x000E), x, r16(0x1B84 + x), r16(0x1BE4 + x)))
			end
		end
	end
end

local function verify_gameplay()
	local p = emu.getState()
	local chrWord = p["ppu.layers[0].chrAddress"] or 0
	local camcol = math.floor(r16(0x1B6A) / 8)
	local ringcol, ringrow = r16(0x1B76), r16(0x1B7A)
	local bgbase, stride = r16(0x1B7E), r16(0x00B2)
	local function col_addr(c) if c < 32 then return c else return 0x0400 + (c - 32) end end

	out:write(string.format("\nGAMEPLAY t=%d stride=%04X BG1charWord=%04X cam=(%04X,%04X)\n",
		frame - gp, stride, chrWord, r16(0x1B6A), r16(0x1B6C)))

	-- (a) palette 0 color 8 black?
	local p0c8 = cg(0x08)
	out:write(string.format("  CGRAM $08 = %04X  %s\n", p0c8, p0c8 == 0 and "BLACK ok" or "NOT BLACK <<"))

	-- (b) black tile graphics present at $77F0? expect 00*16 then (00 FF)*8
	local tile_ok, tilebytes = true, {}
	for i = 0, 31 do
		local got = vb(BLACK_TILE_VRAM * 2 + i)
		tilebytes[i] = got
		local want = (i < 16) and 0x00 or ((i % 2 == 0) and 0x00 or 0xFF)
		if got ~= want then tile_ok = false end
	end
	out:write(string.format("  black tile @%04X solid-color8 = %s (bytes %02X %02X .. %02X %02X)\n",
		BLACK_TILE_VRAM, tile_ok and "ok" or "MISMATCH <<", tilebytes[0], tilebytes[1], tilebytes[30], tilebytes[31]))

	-- (c) off-map left strip cells == BLACK_CELL ($227F)?
	local offmap_checked, offmap_bad = 0, 0
	for sidx = 0, 9 do
		local off = sidx - 10
		local mc = camcol + off
		if mc < 0 or (mc * 2) >= stride then         -- off-map
			local tilecol = (ringcol + off) % 64
			local dest = bgbase + col_addr(tilecol)
			for r = 0, 31 do
				local cell = vb((dest + ((ringrow + r) % 32) * 32) % 0x8000 * 2) +
					vb(((dest + ((ringrow + r) % 32) * 32) % 0x8000) * 2 + 1) * 256
				offmap_checked = offmap_checked + 1
				if cell ~= BLACK_CELL then
					offmap_bad = offmap_bad + 1
					if offmap_bad <= 4 then
						out:write(string.format("    offmap MISMATCH sidx=%d r=%d cell=%04X want=%04X\n",
							sidx, r, cell, BLACK_CELL))
					end
				end
			end
		end
	end
	out:write(string.format("  off-map cells checked=%d bad=%d  %s\n",
		offmap_checked, offmap_bad, (offmap_checked > 0 and offmap_bad == 0) and "BLACK ok" or "<<"))

	out:write(string.format("\nLOADING-PHASE: non-gameplay drains=%d  black-fill violations=%d  %s\n",
		loaddrains, loadviol, loadviol == 0 and "CLEAN ok" or "CORRUPTION <<"))

	local pass = (p0c8 == 0) and tile_ok and (offmap_checked > 0 and offmap_bad == 0) and (loadviol == 0)
	out:write("RESULT: " .. (pass and "PASS" or "FAIL") .. "\n")
	out:close()
	emu.stop(pass and 0 or 1)
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
			done = true; verify_gameplay()
		elseif (frame - gp) >= 800 then
			done = true; out:write("never settled; verifying anyway\n"); verify_gameplay()
		end
	elseif frame > 4000 then
		out:write("never reached gameplay\n"); out:close(); emu.stop(2)
	end
end

emu.addMemoryCallback(load_state, emu.callbackType.exec, 0x0080AE, 0x0080AE, emu.cpuType.snes, snes)
emu.addMemoryCallback(on_drain, emu.callbackType.exec, 0x809E7F, 0x809E7F, emu.cpuType.snes, snes)
emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
