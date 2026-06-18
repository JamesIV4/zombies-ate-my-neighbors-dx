-- Probe item/survivor (object type $05) visibility for the widescreen patch.
-- Counts active type-$05 object slots near the widened viewport, then separately
-- counts type-$05 objects that reach the final render-array loop at $80:BD42.
local wram = emu.memType.snesWorkRam
local frame, gp = 0, nil
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-type05.txt", "w")

local SPRITE_MARGIN = 0x50
local SLOT_FIRST = 0x185E
local SLOT_LAST = 0x1ACA
local SLOT_SIZE = 0x14

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local slot_stats = { on = 0, rs = 0, ls = 0, far = 0, sample = -1 }
local render_stats = { on = 0, rs = 0, ls = 0, far = 0, sample = -1 }

local function classify(stats, sx)
	if sx <= 0x00FF then
		stats.on = stats.on + 1
	elseif sx >= 0x0100 and sx <= 0x00FF + SPRITE_MARGIN then
		stats.rs = stats.rs + 1
		stats.sample = sx
	elseif sx >= 0x10000 - SPRITE_MARGIN then
		stats.ls = stats.ls + 1
		stats.sample = sx
	else
		stats.far = stats.far + 1
	end
end

local function scan_slots()
	local camx = r16(0x1B6A)
	for slot = SLOT_FIRST, SLOT_LAST, SLOT_SIZE do
		if r16(slot) >= 0x8000 and r8(slot + 0x0E) == 0x05 then
			classify(slot_stats, (r16(slot + 0x02) - camx) % 0x10000)
		end
	end
end

local function on_render_entry()
	local c = emu.getCpuState(emu.cpuType.snes)
	local x = c.x % 0x10000
	if r8(x + 0x0E) == 0x05 then
		classify(render_stats, (r16(x + 0x02) - r16(0x1B6A)) % 0x10000)
	end
end

local function set_input()
	if r8(0x000E) == 2 then
		if not gp then gp = frame end
		local t = frame - gp
		if t < 700 then emu.setInput({ up = true }, 0)
		elseif t < 1200 then emu.setInput({ left = true }, 0)
		elseif t < 1450 then emu.setInput({ right = true }, 0)
		else emu.setInput({ down = true }, 0) end
	else
		local mp = frame % 90
		emu.setInput({ start = frame >= 200 and mp < 10,
			a = frame >= 200 and mp >= 30 and mp < 40,
			b = frame >= 200 and mp >= 60 and mp < 70 }, 0)
	end
end

local registered = false
local function end_frame()
	frame = frame + 1
	if r8(0x000E) == 2 and not registered then
		registered = true
		local ok, err = pcall(function()
			emu.addMemoryCallback(on_render_entry, emu.callbackType.exec, 0x80BD42, 0x80BD42,
				emu.cpuType.snes, emu.memType.snesMemory)
		end)
		out:write("registered render=" .. tostring(ok) .. " err=" .. tostring(err) .. "\n")
		out:flush()
	end
	if gp then
		scan_slots()
		if frame - gp >= 1200 then
			out:write(string.format("type05 slots  onscreen=%d rightstrip=%d leftstrip=%d far=%d sampleStripX=%s\n",
				slot_stats.on, slot_stats.rs, slot_stats.ls, slot_stats.far,
				slot_stats.sample >= 0 and string.format("%04X", slot_stats.sample) or "-"))
			out:write(string.format("type05 render onscreen=%d rightstrip=%d leftstrip=%d far=%d sampleStripX=%s\n",
				render_stats.on, render_stats.rs, render_stats.ls, render_stats.far,
				render_stats.sample >= 0 and string.format("%04X", render_stats.sample) or "-"))
			out:close()
			emu.stop(0)
		end
	elseif frame > 8000 then
		out:write("no gameplay\n")
		out:close()
		emu.stop(2)
	end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
