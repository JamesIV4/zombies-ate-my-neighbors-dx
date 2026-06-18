-- Per-frame lifecycle log for type-$05 objects (items/survivors).
-- Shows whether each slot is in the $1B5E linked list and/or final $137E render
-- array while the camera sweeps up-left.
local wram = emu.memType.snesWorkRam
local frame, gp = 0, nil
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-type05-life.txt", "w")

local SLOT_FIRST = 0x185E
local SLOT_LAST = 0x1ACA
local SLOT_SIZE = 0x14

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local function signed16(v)
	if v >= 0x8000 then return v - 0x10000 end
	return v
end

local function in_list(slot)
	local x = r16(0x1B5E)
	local guard = 0
	while x ~= 0 and guard < 40 do
		if x == slot then return true end
		x = r16(x + 0x12)
		guard = guard + 1
	end
	return false
end

local function in_render(slot)
	local n = r16(0x009C)
	local y = 0
	while y < n do
		if r16(0x137E + y) == slot then return true end
		y = y + 2
	end
	return false
end

local function log_slots()
	local camx, camy = r16(0x1B6A), r16(0x1B6C)
	local any = false
	for slot = SLOT_FIRST, SLOT_LAST, SLOT_SIZE do
		if r8(slot + 0x0E) == 0x05 then
			if not any then
				out:write(string.format("t=%04d cam=(%04X,%04X) head=%04X rcount=%04X\n",
					frame - gp, camx, camy, r16(0x1B5E), r16(0x009C)))
				any = true
			end
			local x, y = r16(slot + 0x02), r16(slot + 0x06)
			out:write(string.format(
				"  slot=%04X flags=%04X xy=(%04X,%04X) screen=(%d,%d) next=%04X inList=%s inRender=%s spr=%04X:%04X subtype=%04X\n",
				slot, r16(slot), x, y, signed16((x - camx) % 0x10000), signed16((y - camy) % 0x10000),
				r16(slot + 0x12), tostring(in_list(slot)), tostring(in_render(slot)),
				r16(slot + 0x08), r16(slot + 0x0A), r16(slot + 0x0C)))
		end
	end
	if any then out:flush() end
end

local function set_input()
	if r8(0x000E) == 2 then
		if not gp then gp = frame end
		local t = frame - gp
		if t < 520 then emu.setInput({ up = true, left = true }, 0)
		elseif t < 720 then emu.setInput({ right = true }, 0)
		elseif t < 980 then emu.setInput({ down = true, right = true }, 0)
		elseif t < 1180 then emu.setInput({ left = true }, 0)
		else emu.setInput({ up = true }, 0) end
	else
		local mp = frame % 90
		emu.setInput({ start = frame >= 200 and mp < 10,
			a = frame >= 200 and mp >= 30 and mp < 40,
			b = frame >= 200 and mp >= 60 and mp < 70 }, 0)
	end
end

local function end_frame()
	frame = frame + 1
	if gp and (frame - gp) % 20 == 0 then
		log_slots()
	end
	if gp and frame - gp >= 800 then
		out:close()
		emu.stop(0)
	elseif frame > 8000 then
		out:write("no gameplay\n")
		out:close()
		emu.stop(2)
	end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
