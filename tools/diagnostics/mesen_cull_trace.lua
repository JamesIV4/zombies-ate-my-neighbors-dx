-- For every world object the sprite engine sets up ($80:BD79 computes
-- screenX = objX - camX), record its type ($0E,X) and which screen region it's in.
-- Run on the PATCHED widescreen ROM: enemies now reach the strips, so if some object
-- types appear in the strips and others never do, the missing ones are culled upstream.
local wram = emu.memType.snesWorkRam
local frame, gp = 0, nil
local stats = {}   -- [type] = {on=, rs=, ls=, far=, ex=screenX sample in strip}
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-cull.txt", "w")

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local function on_setup()
	local c = emu.getCpuState(emu.cpuType.snes)
	local x = c.x % 0x10000
	local ty = r8(x + 0x0E)
	local sx = (r16(x + 0x02) - r16(0x1B6A)) % 0x10000
	local s = stats[ty]
	if not s then s = { on = 0, rs = 0, ls = 0, far = 0, ex = -1 }; stats[ty] = s end
	if sx <= 0x00FF then s.on = s.on + 1
	elseif sx >= 0x0100 and sx <= 0x01C0 then s.rs = s.rs + 1; s.ex = sx
	elseif sx >= 0xFE40 then s.ls = s.ls + 1; s.ex = sx
	else s.far = s.far + 1 end
end

local function set_input()
	if r8(0x000E) == 2 then
		if not gp then gp = frame end
		local t = frame - gp
		if t < 400 then emu.setInput({ right = true }, 0)
		elseif t < 750 then emu.setInput({ left = true }, 0)
		elseif t < 900 then emu.setInput({ right = true }, 0)
		else emu.setInput({ down = (t % 60 < 30), up = (t % 60 >= 30) }, 0) end
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
			emu.addMemoryCallback(on_setup, emu.callbackType.exec, 0x80BCEA, 0x80BCEA,
				emu.cpuType.snes, emu.memType.snesMemory)
		end)
		out:write("register ok=" .. tostring(ok) .. " err=" .. tostring(err) .. "\n"); out:flush()
	end
	if gp and frame - gp >= 1100 then
		out:write("type  onscreen  rightstrip  leftstrip  far   sampleStripX\n")
		local types = {}
		for t in pairs(stats) do types[#types + 1] = t end
		table.sort(types)
		for _, t in ipairs(types) do
			local s = stats[t]
			out:write(string.format("$%02X    %6d    %6d    %6d  %6d   %s\n",
				t, s.on, s.rs, s.ls, s.far, s.ex >= 0 and string.format("%04X", s.ex) or "-"))
		end
		out:close(); emu.stop(0)
	elseif frame > 8000 then out:write("no gameplay\n"); out:close(); emu.stop(2) end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
