-- Verify the widescreen pipeline produced correct data: after scrolling, each
-- gathered colbuf must match the level map, target the game's BG1 ring-buffer
-- column/row, and match VRAM after DMA.
local wram = emu.memType.snesWorkRam
local vram = emu.memType.snesVideoRam
local frame, gp = 0, nil
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-ws-verify.txt", "w")

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end
local function w7f(a) return emu.read(0x10000 + a, wram) end          -- $7F byte
local function w7f16(a) return w7f(a) + w7f(a + 1) * 256 end
local function vw(word) return emu.read(word * 2, vram) + emu.read(word * 2 + 1, vram) * 256 end

local function band(a, b)
	local r, bit = 0, 1
	while a > 0 or b > 0 do
		if (a % 2) == 1 and (b % 2) == 1 then r = r + bit end
		a = math.floor(a / 2)
		b = math.floor(b / 2)
		bit = bit * 2
	end
	return r
end

local function bor(a, b)
	local r, bit = 0, 1
	while a > 0 or b > 0 do
		if (a % 2) == 1 or (b % 2) == 1 then r = r + bit end
		a = math.floor(a / 2)
		b = math.floor(b / 2)
		bit = bit * 2
	end
	return r
end

local function col_addr(col)
	if col < 32 then return col end
	return 0x0400 + (col - 32)
end

local function slot_offset(sidx)
	if sidx < 4 then return sidx - 4 end
	return sidx + 28
end

local function priority_cell(cell)
	if band(cell, 0x01FF) < r16(0x00DC) then return bor(cell, 0x2000) end
	return cell
end

local function set_input()
	if r8(0x000E) == 2 then
		if not gp then gp = frame end
		emu.setInput({ down = (frame % 60 < 30), right = (frame % 60 >= 30) }, 0)
	else
		local mp = frame % 90
		emu.setInput({ start = frame >= 200 and mp < 10,
			a = frame >= 200 and mp >= 30 and mp < 40,
			b = frame >= 200 and mp >= 60 and mp < 70 }, 0)
	end
end

local function dump()
	local camcol = math.floor(r16(0x1B6A) / 8)
	local camrow = math.floor(r16(0x1B6C) / 8)
	local ringcol = r16(0x1B76)
	local ringrow = r16(0x1B7A)
	local bgbase = r16(0x1B7E)
	local rowstride = r16(0x00B2)
	local failures = 0

	out:write(string.format(
		"camcol=%d camrow=%d ringcol=%d ringrow=%d bgbase=%04X rowstride=%04X lasttick=%04X\n",
		camcol, camrow, ringcol, ringrow, bgbase, rowstride, w7f16(0xFFE0)))
	out:write("VRAMDEST[0..7]:")
	for i = 0, 7 do out:write(string.format(" %04X", w7f16(0xFFD0 + i * 2))) end
	out:write("\n")

	for sidx = 0, 7 do
		local off = slot_offset(sidx)
		local mc = camcol + off
		local dest = w7f16(0xFFD0 + sidx * 2)
		local bufoff = 0xFDC0 + sidx * 64
		local tilecol = (ringcol + off) % 64
		local expected_dest = bgbase + col_addr(tilecol)
		local skip = mc < 0 or (mc * 2) >= rowstride

		out:write(string.format(
			"\nslot %d off=%d mc=%d tilecol=%d colbuf=$%04X dest=$%04X expected=$%04X\n",
			sidx, off, mc, tilecol, bufoff, dest, expected_dest))

		if skip then
			if dest ~= 0xFFFF then
				failures = failures + 1
				out:write("  FAIL: edge slot was not skipped\n")
			end
		else
			if dest ~= expected_dest then
				failures = failures + 1
				out:write("  FAIL: wrong VRAM destination\n")
			end

			for r = 0, 31 do
				local worldrow = camrow + r
				local tilerow = (ringrow + r) % 32
				local rowbase = r8(0x4328 + worldrow * 2) + r8(0x4328 + worldrow * 2 + 1) * 256
				local expected = priority_cell(w7f16((rowbase + mc * 2) % 0x10000))
				local got_buf = w7f16(bufoff + tilerow * 2)
				local got_vram = vw((dest + tilerow * 32) % 0x8000)

				if got_buf ~= expected or got_vram ~= expected then
					failures = failures + 1
					out:write(string.format(
						"  FAIL row=%d tilerow=%d expected=%04X colbuf=%04X vram=%04X\n",
						worldrow, tilerow, expected, got_buf, got_vram))
				end
			end
		end
	end
	out:write(string.format("\nfailures=%d\n", failures))
	out:flush()
	if failures == 0 then out:close() emu.stop(0) else out:close() emu.stop(1) end
end

local function end_frame()
	frame = frame + 1
	if gp and (frame - gp) >= 400 then dump()
	elseif frame > 8000 then out:write("no gameplay\n") out:close() emu.stop(2) end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
