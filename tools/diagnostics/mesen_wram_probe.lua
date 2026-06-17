-- Dump live WRAM during gameplay to find where the level map ends in $7F and
-- whether the widescreen scratch region ($7F:FDC0-$FFEF) is free.
-- Run headless:  Mesen.exe --testRunner mesen_wram_probe.lua <DX rom>.sfc
local wram = emu.memType.snesWorkRam
local frame = 0
local gameplay_frame = nil
local dumped = false
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-wram.txt", "w")

local function read8(a) return emu.read(a, wram) end
local function read16(a) return emu.read16(a, wram) end          -- $7E:a
local function read7F(a) return emu.read(0x10000 + a, wram) end   -- $7F:a byte
local function read7F16(a)
	return read7F(a) + read7F(a + 1) * 256
end

local function set_input()
	local gs = read8(0x000E)
	local pa = read8(0x0D25)
	if gs == 2 and pa ~= 0 then
		if not gameplay_frame then gameplay_frame = frame end
		emu.setInput({}, 0)
	else
		-- brute-force through title / menus
		local mp = frame % 90
		emu.setInput({
			start = frame >= 200 and mp < 10,
			a = frame >= 200 and mp >= 30 and mp < 40,
			b = frame >= 200 and mp >= 60 and mp < 70,
		}, 0)
	end
end

local function dump()
	out:write(string.format("reached gameplay at frame %d\n", gameplay_frame))
	out:write(string.format(
		"state=%02X player_active=%02X camX=%04X camY=%04X bg1base(1B7E)=%04X "
		.. "rowstride(B2)=%04X thresh(DC)=%04X qlen(CE)=%04X\n",
		read8(0x000E), read8(0x0D25), read16(0x1B6A), read16(0x1B6C),
		read16(0x1B7E), read16(0x00B2), read16(0x00DC), read16(0x00CE)))

	-- map row-base table at $7E:4328; find the highest $7F address it points to
	out:write("rowbase[0..15]:")
	for i = 0, 15 do out:write(string.format(" %04X", read16(0x4328 + i * 2))) end
	out:write("\n")
	local maxrb, minrb = 0, 0xFFFF
	for i = 0, 511 do
		local rb = read16(0x4328 + i * 2)
		if rb ~= 0 and rb < 0xFFFF then
			if rb > maxrb then maxrb = rb end
			if rb < minrb then minrb = rb end
		end
	end
	local stride = read16(0x00B2)
	out:write(string.format(
		"row-base range first512: min=%04X max=%04X  map top ~= max+stride = %04X\n",
		minrb, maxrb, (maxrb + stride) % 0x10000))

	-- hex dump of $7F:F000-$FFFF (covers old scratch $FC00 + new $FDC0 + mailbox)
	out:write("--- $7F:F000-$FFFF ---\n")
	for base = 0xF000, 0xFFF0, 16 do
		local line = string.format("7F:%04X:", base)
		for j = 0, 15 do line = line .. string.format(" %02X", read7F(base + j)) end
		out:write(line .. "\n")
	end
	out:flush()
end

local function end_frame()
	frame = frame + 1
	if gameplay_frame and (frame - gameplay_frame) >= 120 and not dumped then
		dumped = true
		dump()
		out:close()
		emu.stop(0)
	elseif frame > 8000 then
		out:write("never reached gameplay\n")
		out:close()
		emu.stop(2)
	end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
