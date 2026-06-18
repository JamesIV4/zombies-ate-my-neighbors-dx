-- Log camera/player movement for the up-then-left neighbor route.
local wram = emu.memType.snesWorkRam
local frame, gp = 0, nil
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-route.txt", "w")

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local function input_for(t)
	if t < 700 then return { up = true }, "up"
	elseif t < 1200 then return { left = true }, "left"
	elseif t < 1450 then return { right = true }, "right"
	else return { down = true }, "down" end
end

local current = "boot"
local function set_input()
	if r8(0x000E) == 2 then
		if not gp then gp = frame end
		local inp
		inp, current = input_for(frame - gp)
		emu.setInput(inp, 0)
	else
		current = "menu"
		local mp = frame % 90
		emu.setInput({ start = frame >= 200 and mp < 10,
			a = frame >= 200 and mp >= 30 and mp < 40,
			b = frame >= 200 and mp >= 60 and mp < 70 }, 0)
	end
end

local function end_frame()
	frame = frame + 1
	if gp and (frame - gp) % 20 == 0 then
		out:write(string.format("t=%04d input=%s cam=(%04X,%04X) player=(%04X,%04X) bg=(%04X,%04X)\n",
			frame - gp, current, r16(0x1B6A), r16(0x1B6C), r16(0x0130), r16(0x0132),
			r16(0x1360), r16(0x1362)))
		out:flush()
	end
	if gp and frame - gp >= 1600 then
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
