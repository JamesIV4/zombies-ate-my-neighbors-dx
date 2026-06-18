-- Controlled verification for the widescreen horizontal camera clamp hooks.
-- Forces the dispatcher target rightward, then checks that right-scroll advances
-- from max-margin-1 to max-margin and blocks at max-margin.
local wram = emu.memType.snesWorkRam
local snes = emu.memType.snesMemory
local frame, gp = 0, nil
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-camera-clamp.txt", "w")
local RIGHT_MARGIN = 0x0040

local attempts = 0
local phase = "boot"
local allow_continues, block_continues = 0, 0

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end
local function w8(a, v) emu.write(a & 0xFFFF, v & 0xFF, wram) end
local function w16(a, v)
	w8(a, v)
	w8(a + 1, math.floor(v / 0x100))
end

local function set_input()
	if r8(0x000E) == 2 and r8(0x0D25) ~= 0 then
		if not gp then gp = frame end
		emu.setInput({}, 0)
	else
		local mp = frame % 90
		emu.setInput({ start = frame >= 200 and mp < 10,
			a = frame >= 200 and mp >= 30 and mp < 40,
			b = frame >= 200 and mp >= 60 and mp < 70 }, 0)
	end
end

local function on_target_x()
	if not gp then return end
	-- Make $80:A993 choose the right-scroll routine regardless of player position.
	w16(0x1CB0, 0x0600)
end

local function on_right_entry()
	if not gp or attempts >= 2 then return end
	attempts = attempts + 1
	local max_x = r16(0x00B8)
	if attempts == 1 then
		phase = "allow"
		w16(0x1B6A, max_x - RIGHT_MARGIN - 1)
	elseif attempts == 2 then
		phase = "block"
		w16(0x1B6A, max_x - RIGHT_MARGIN)
	end
	out:write(string.format("right-entry attempt=%d phase=%s camX=%04X maxX=%04X\n",
		attempts, phase, r16(0x1B6A), r16(0x00B8)))
	out:flush()
end

local function on_right_continue()
	if phase == "allow" then allow_continues = allow_continues + 1 end
	if phase == "block" then block_continues = block_continues + 1 end
	out:write(string.format("right-continue phase=%s camX(before inc)=%04X\n",
		phase, r16(0x1B6A)))
	out:flush()
end

local function end_frame()
	frame = frame + 1
	if gp and attempts >= 2 and frame - gp > 6 then
		out:write(string.format(
			"result camX=%04X maxX=%04X allow_continues=%d block_continues=%d\n",
			r16(0x1B6A), r16(0x00B8), allow_continues, block_continues))
		out:close()
		if allow_continues >= 1 and block_continues == 0 and r16(0x1B6A) == r16(0x00B8) - RIGHT_MARGIN then
			emu.stop(0)
		else
			emu.stop(1)
		end
	elseif frame > 8000 then
		out:write("never reached gameplay\n")
		out:close()
		emu.stop(2)
	end
end

emu.addMemoryCallback(on_target_x, emu.callbackType.exec, 0x80A993, 0x80A993,
	emu.cpuType.snes, snes)
emu.addMemoryCallback(on_right_entry, emu.callbackType.exec, 0x80A70A, 0x80A70A,
	emu.cpuType.snes, snes)
emu.addMemoryCallback(on_right_continue, emu.callbackType.exec, 0x80A712, 0x80A712,
	emu.cpuType.snes, snes)

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
