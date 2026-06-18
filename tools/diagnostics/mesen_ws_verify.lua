-- Verify the widescreen pipeline produces correct data. The gather is incremental
-- (leading column + round-robin trickle), so we scroll to exercise it, then HOLD
-- STILL for a while: with a static camera every strip column gets trickle-refreshed
-- and uploaded within a few frames, so VRAM must then match the level map exactly.
-- The enqueue consumes VRAMDEST (-> $FFFF) after upload, so we compute each column's
-- VRAM destination here instead of reading it from scratch.
local wram = emu.memType.snesWorkRam
local vram = emu.memType.snesVideoRam
-- Layout must match tools/build_widescreen.py (NSTRIP and the $7F scratch map).
local N = 10
local NSLOT = 2 * N
local COLBUF = 0xF000
local LASTTICK = 0xF52E
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
	if sidx < N then return sidx - N end
	return sidx + (32 - N)
end

local function priority_cell(cell)
	if band(cell, 0x01FF) < r16(0x00DC) then return bor(cell, 0x2000) end
	return cell
end

-- scroll for a while to exercise the incremental gather, then hold still so every
-- column catches up before we snapshot.
local function set_input()
	if r8(0x000E) == 2 then
		if not gp then gp = frame end
		local t = frame - gp
		if t < 250 then
			emu.setInput({ down = (t % 60 < 30), right = (t % 60 >= 30) }, 0)
		else
			emu.setInput({}, 0)          -- hold still: let trickle refresh all columns
		end
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
	local failures, checked = 0, 0

	out:write(string.format(
		"camcol=%d camrow=%d ringcol=%d ringrow=%d bgbase=%04X rowstride=%04X lasttick=%04X\n",
		camcol, camrow, ringcol, ringrow, bgbase, rowstride, w7f16(LASTTICK)))

	for sidx = 0, NSLOT - 1 do
		local off = slot_offset(sidx)
		local mc = camcol + off
		local bufoff = COLBUF + sidx * 64
		local tilecol = (ringcol + off) % 64
		local dest = bgbase + col_addr(tilecol)
		local skip = mc < 0 or (mc * 2) >= rowstride

		out:write(string.format("slot %d off=%d mc=%d tilecol=%d colbuf=$%04X dest=$%04X%s\n",
			sidx, off, mc, tilecol, bufoff, dest, skip and "  (off-map, skipped)" or ""))

		if not skip then
			checked = checked + 1
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
	out:write(string.format("\ncolumns_checked=%d failures=%d\n", checked, failures))
	out:flush()
	if failures == 0 then out:close() emu.stop(0) else out:close() emu.stop(1) end
end

local function end_frame()
	frame = frame + 1
	if gp and (frame - gp) >= 390 then dump()      -- ~140 still frames after scrolling
	elseif frame > 8000 then out:write("no gameplay\n") out:close() emu.stop(2) end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
