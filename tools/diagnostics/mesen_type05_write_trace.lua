-- Trace writes that create/retag object slots as type $05 (items/survivors).
-- This pins the upstream spawn/render-management gate by logging the writer PC and
-- the object's camera-relative position at the moment it becomes type $05.
local wram = emu.memType.snesWorkRam
local frame, gp = 0, nil
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-type05-write.txt", "w")

local SLOT_FIRST = 0x185E
local SLOT_LAST = 0x1ACA
local SLOT_SIZE = 0x14
local sample_writes = 0

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local function signed16(v)
	if v >= 0x8000 then return v - 0x10000 end
	return v
end

local function trace_type_write(address, value)
	local off = address % 0x20000
	if off >= 0x10000 then off = off - 0x10000 end
	if sample_writes < 20 then
		sample_writes = sample_writes + 1
		out:write(string.format("sample write raw=%06X off=%04X value=%04X\n", address, off, value % 0x10000))
		out:flush()
	end
	local rel = (off - SLOT_FIRST) % SLOT_SIZE
	if rel ~= 0x0E then return end
	value = value % 0x100
	if value ~= 0x05 then return end
	local slot = off - rel
	local c = emu.getCpuState(emu.cpuType.snes)
	local x = r16(slot + 0x02)
	local y = r16(slot + 0x06)
	local sx = signed16((x - r16(0x1B6A)) % 0x10000)
	local sy = signed16((y - r16(0x1B6C)) % 0x10000)
	out:write(string.format(
		"t=%04d pc=%06X slot=%04X type=05 obj=(%04X,%04X) screen=(%d,%d) cam=(%04X,%04X) flags=%04X spr=%04X:%04X subtype=%04X\n",
		gp and (frame - gp) or -1,
		c.pc or 0,
		slot,
		x,
		y,
		sx,
		sy,
		r16(0x1B6A),
		r16(0x1B6C),
		r16(slot),
		r16(slot + 0x08),
		r16(slot + 0x0A),
		r16(slot + 0x0C)
	))
	out:flush()
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

local ok, err = pcall(function()
	emu.addMemoryCallback(trace_type_write, emu.callbackType.write,
		SLOT_FIRST, SLOT_LAST + SLOT_SIZE - 1, emu.cpuType.snes, wram)
end)
out:write("registered writes=" .. tostring(ok) .. " err=" .. tostring(err) .. "\n")
out:flush()

local function end_frame()
	frame = frame + 1
	if gp and frame - gp >= 1500 then
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
