-- Verify off-map widescreen strip columns are filled with black instead of leaving
-- stale VRAM visible. Walks to the tuned left clamp; with NSTRIP=10 and left clamp
-- at 8 tiles, the two outer left strip columns are outside the level map.
local wram = emu.memType.snesWorkRam
local snes = emu.memType.snesMemory
local vram = emu.memType.snesVideoRam
local frame, gp = 0, nil
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-offmap-black.txt", "w")

local N = 10
local COLBUF = 0xF000
local BLACK_CELL = 0x227F   -- priority | palette 0 | tile $27F (gameplay-calibrated black)
local RIGHT_MARGIN = 0x0040
local phase = "left"
local phase_frame = nil
local total_checked, total_failures = 0, 0

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end
local function w8(a, v) emu.write(a & 0xFFFF, v & 0xFF, wram) end
local function w16(a, v)
	w8(a, v)
	w8(a + 1, math.floor(v / 0x100))
end
local function w7f(a) return emu.read(0x10000 + a, wram) end
local function w7f16(a) return w7f(a) + w7f(a + 1) * 256 end
local function vw(word) return emu.read(word * 2, vram) + emu.read(word * 2 + 1, vram) * 256 end

local function col_addr(col)
	if col < 32 then return col end
	return 0x0400 + (col - 32)
end

local function slot_offset(sidx)
	if sidx < N then return sidx - N end
	return sidx + (32 - N)
end

local function set_input()
	if r8(0x000E) == 2 and r8(0x0D25) ~= 0 then
		if not gp then gp = frame end
		if phase == "right" then
			w16(0x1B6A, r16(0x00B8) - RIGHT_MARGIN)
			w16(0x1CB0, 0x0600)
			emu.setInput({}, 0)
		else
			emu.setInput({ left = true }, 0)
		end
	else
		local mp = frame % 90
		emu.setInput({ start = frame >= 200 and mp < 10,
			a = frame >= 200 and mp >= 30 and mp < 40,
			b = frame >= 200 and mp >= 60 and mp < 70 }, 0)
	end
end

local function on_target_x()
	if phase == "right" then
		w16(0x1CB0, 0x0600)
	end
end

local function verify(side)
	local camcol = math.floor(r16(0x1B6A) / 8)
	local ringcol = r16(0x1B76)
	local ringrow = r16(0x1B7A)
	local bgbase = r16(0x1B7E)
	local rowstride = r16(0x00B2)
	local failures, checked = 0, 0
	out:write(string.format("%s camX=%04X camcol=%d ring=(%04X,%04X) bgbase=%04X rowstride=%04X\n",
		side, r16(0x1B6A), camcol, ringcol, ringrow, bgbase, rowstride))

	for sidx = 0, (2 * N) - 1 do
		local off = slot_offset(sidx)
		local mc = camcol + off
		local is_offmap = (side == "left" and mc < 0) or
			(side == "right" and (mc * 2) >= rowstride)
		if is_offmap then
			local bufoff = COLBUF + sidx * 64
			local tilecol = (ringcol + off) % 64
			local dest = bgbase + col_addr(tilecol)
			checked = checked + 1
			out:write(string.format("offmap slot=%d off=%d mc=%d tilecol=%d colbuf=%04X dest=%04X\n",
				sidx, off, mc, tilecol, bufoff, dest))
			for r = 0, 31 do
				local tilerow = (ringrow + r) % 32
				local got_buf = w7f16(bufoff + tilerow * 2)
				local got_vram = vw((dest + tilerow * 32) % 0x8000)
				if got_buf ~= BLACK_CELL or got_vram ~= BLACK_CELL then
					failures = failures + 1
					out:write(string.format(
						"  FAIL row=%d tilerow=%d colbuf=%04X vram=%04X\n",
						r, tilerow, got_buf, got_vram))
				end
			end
		end
	end

	out:write(string.format("%s checked=%d failures=%d\n", side, checked, failures))
	total_checked = total_checked + checked
	total_failures = total_failures + failures
	return checked, failures
end

local function end_frame()
	frame = frame + 1
	if gp then
		local t = frame - gp
		if phase == "left" and t >= 330 then
			local checked, failures = verify("left")
			if checked < 1 or failures ~= 0 then
				out:close()
				emu.stop(1)
				return
			end
			phase = "right"
			phase_frame = frame
			w16(0x1B6A, r16(0x00B8) - RIGHT_MARGIN)
		elseif phase == "right" and frame - phase_frame >= 60 then
			local checked, failures = verify("right")
			out:write(string.format("total_checked=%d total_failures=%d\n", total_checked, total_failures))
			out:close()
			if checked >= 1 and failures == 0 and total_failures == 0 then emu.stop(0) else emu.stop(1) end
		end
	elseif frame > 8000 then
		out:write("never reached gameplay\n")
		out:close()
		emu.stop(2)
	end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
emu.addMemoryCallback(on_target_x, emu.callbackType.exec, 0x80A993, 0x80A993,
	emu.cpuType.snes, snes)
