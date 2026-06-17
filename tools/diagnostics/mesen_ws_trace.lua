-- Force scrolling on the widescreen ROM and confirm it stays stable; log the
-- player + camera so we can see the camera actually scroll (strips exercised).
-- Run:  Mesen.exe --testRunner mesen_ws_trace.lua <rom>
local wram = emu.memType.snesWorkRam
local frame = 0
local gp = nil
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-ws-trace.txt", "w")

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local function set_input()
	local gs = r8(0x000E)
	if gs == 2 then
		if not gp then gp = frame end
		local t = frame - gp
		-- sweep directions to find open space and push the camera around
		local phase = math.floor(t / 240) % 4
		if phase == 0 then emu.setInput({ right = true }, 0)
		elseif phase == 1 then emu.setInput({ down = true }, 0)
		elseif phase == 2 then emu.setInput({ left = true }, 0)
		else emu.setInput({ up = true }, 0) end
	else
		local mp = frame % 90
		emu.setInput({
			start = frame >= 200 and mp < 10,
			a = frame >= 200 and mp >= 30 and mp < 40,
			b = frame >= 200 and mp >= 60 and mp < 70,
		}, 0)
	end
end

local function end_frame()
	frame = frame + 1
	if gp then
		local t = frame - gp
		if t % 30 == 0 then
			out:write(string.format(
				"t=%d state=%02X plX=%04X plY=%04X camX=%04X camY=%04X CE=%04X\n",
				t, r8(0x000E), r16(0x0130), r16(0x0132),
				r16(0x1B6A), r16(0x1B6C), r16(0x00CE)))
			out:flush()
		end
		if t >= 1500 then out:close() emu.stop(0) end
	elseif frame > 8000 then
		out:write("never reached gameplay\n") out:close() emu.stop(2)
	end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
