-- Dump live camera bound variables and a short movement trace.
local wram = emu.memType.snesWorkRam
local frame, gp = 0, nil
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-camera-bounds.txt", "w")

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local function set_input()
	if r8(0x000E) == 2 and r8(0x0D25) ~= 0 then
		if not gp then gp = frame end
		local t = frame - gp
		if t < 240 then emu.setInput({ left = true }, 0)
		elseif t < 720 then emu.setInput({ right = true }, 0)
		else emu.setInput({}, 0) end
	else
		local mp = frame % 90
		emu.setInput({ start = frame >= 200 and mp < 10,
			a = frame >= 200 and mp >= 30 and mp < 40,
			b = frame >= 200 and mp >= 60 and mp < 70 }, 0)
	end
end

local function dump(t)
	out:write(string.format(
		"t=%04d cam=(%04X,%04X) ring=(%04X,%04X) vis=(%04X-%04X,%04X-%04X) B2=%04X B4=%04X B6=%04X B8=%04X player=(%04X,%04X)\n",
		t, r16(0x1B6A), r16(0x1B6C), r16(0x1B76), r16(0x1B7A),
		r16(0x1B6E), r16(0x1B70), r16(0x1B72), r16(0x1B74),
		r16(0x00B2), r16(0x00B4), r16(0x00B6), r16(0x00B8),
		r16(0x0130), r16(0x0132)))
	out:flush()
end

local function end_frame()
	frame = frame + 1
	if gp then
		local t = frame - gp
		if t == 1 or t % 30 == 0 then dump(t) end
		if t >= 780 then
			out:close()
			emu.stop(0)
		end
	elseif frame > 8000 then
		out:write("never reached gameplay\n")
		out:close()
		emu.stop(2)
	end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
