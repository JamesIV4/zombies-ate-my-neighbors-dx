-- Trace the sprite render-list insert ($80:BE28) and remove ($80:BE51). For each
-- call, capture the object's type ($0E,Y), its screenX (objX-camX), and the caller's
-- return address (from the stack). This reveals which code adds/removes type-$05
-- (items/survivors) from rendering and at what 256px threshold -> the cull to relax.
local wram = emu.memType.snesWorkRam
local frame, gp = 0, nil
local rec = {}          -- key "ins$05" / "rem$05" -> {n, minsx, maxsx, callers={}}
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-reglist.txt", "w")

local function r8(a) return emu.read(a, wram) end
local function r16(a) return emu.read16(a, wram) end

local function note(kind)
	local c = emu.getCpuState(emu.cpuType.snes)
	local y = c.y % 0x10000
	local ty = r8(y + 0x0E)
	local sx = (r16(y + 0x02) - r16(0x1B6A)) % 0x10000
	-- JSL return on stack: SP+1=PCL, +2=PCH, +3=PBR
	local sp = c.sp % 0x10000
	local pcl = r8(0x0100 + ((sp + 1) % 0x100))
	local pch = r8(0x0100 + ((sp + 2) % 0x100))
	local pbr = r8(0x0100 + ((sp + 3) % 0x100))
	local caller = pbr * 0x10000 + pch * 0x100 + pcl
	local key = kind .. string.format("$%02X", ty)
	local r = rec[key]
	if not r then r = { n = 0, minsx = 0x10000, maxsx = -1, callers = {} }; rec[key] = r end
	r.n = r.n + 1
	local ssx = sx
	if ssx >= 0x8000 then ssx = ssx - 0x10000 end
	if ssx < r.minsx then r.minsx = ssx end
	if ssx > r.maxsx then r.maxsx = ssx end
	r.callers[caller] = (r.callers[caller] or 0) + 1
end

local function set_input()
	if r8(0x000E) == 2 then
		if not gp then gp = frame end
		local t = frame - gp
		if t < 400 then emu.setInput({ right = true }, 0)
		elseif t < 800 then emu.setInput({ left = true }, 0)
		else emu.setInput({ right = (t % 80 < 40), down = (t % 80 >= 40) }, 0) end
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
		local ok1 = pcall(function()
			emu.addMemoryCallback(function() note("ins") end, emu.callbackType.exec,
				0x80BE28, 0x80BE28, emu.cpuType.snes, emu.memType.snesMemory)
		end)
		local ok2 = pcall(function()
			emu.addMemoryCallback(function() note("rem") end, emu.callbackType.exec,
				0x80BE51, 0x80BE51, emu.cpuType.snes, emu.memType.snesMemory)
		end)
		out:write("registered ins=" .. tostring(ok1) .. " rem=" .. tostring(ok2) .. "\n"); out:flush()
	end
	if gp and frame - gp >= 1100 then
		local keys = {}
		for k in pairs(rec) do keys[#keys + 1] = k end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local r = rec[k]
			out:write(string.format("%s  n=%d  screenX=[%d..%d]  callers:\n", k, r.n, r.minsx, r.maxsx))
			local cs = {}
			for c, n in pairs(r.callers) do cs[#cs + 1] = { c, n } end
			table.sort(cs, function(a, b) return a[2] > b[2] end)
			for i = 1, math.min(#cs, 6) do
				out:write(string.format("     %06X x%d\n", cs[i][1], cs[i][2]))
			end
		end
		out:close(); emu.stop(0)
	elseif frame > 8000 then out:write("no gameplay\n"); out:close(); emu.stop(2) end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
