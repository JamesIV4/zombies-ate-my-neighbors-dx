-- Confirm the sprite X-cull relax actually draws strip sprites. The opened ranges
-- (9-bit OAM X in [$100,$150] right strip, [$1B0,$1F0] extended left) are exactly
-- what stock ZAMN culls to zero, so on the patched ROM these should become non-zero
-- when an active actor is in a strip. Walks around to expose edge actors and reports
-- the peak strip-sprite count. Run on BOTH stock DX and the widescreen ROM to compare.
local oam = emu.memType.snesSpriteRam
local wram = emu.memType.snesWorkRam
local frame, gp = 0, nil
local peak_right, peak_left, peak_frame = 0, 0, 0
local out = io.open("s:/Repos/zombies-ate-my-neighbors-dx/mesen-sprite.txt", "w")

local function r8(a) return emu.read(a, wram) end

local function sprite_x9(i)
	local lo = emu.read(i * 4, oam)
	local hbyte = emu.read(512 + math.floor(i / 4), oam)
	local xhigh = math.floor(hbyte / 2 ^ ((i % 4) * 2)) % 2
	return lo + xhigh * 256
end

local function count_strips()
	local right, left = 0, 0
	for i = 0, 127 do
		local y = emu.read(i * 4 + 1, oam)
		if y < 0xE0 then                       -- not parked off-screen vertically
			local x = sprite_x9(i)
			if x >= 0x100 and x <= 0x150 then right = right + 1
			elseif x >= 0x1B0 and x <= 0x1F0 then left = left + 1 end
		end
	end
	return right, left
end

local function set_input()
	if r8(0x000E) == 2 then
		if not gp then gp = frame end
		local t = frame - gp
		-- first push deep into the level (off the left edge), then reverse so actors
		-- fall into BOTH strips: leftward motion exposes right-edge actors and vice versa
		if t < 400 then emu.setInput({ right = true }, 0)
		elseif t < 750 then emu.setInput({ left = true }, 0)
		elseif t < 900 then emu.setInput({ right = true }, 0)
		elseif t < 1050 then emu.setInput({ up = true }, 0)
		else emu.setInput({ down = true }, 0) end
	else
		local mp = frame % 90
		emu.setInput({ start = frame >= 200 and mp < 10,
			a = frame >= 200 and mp >= 30 and mp < 40,
			b = frame >= 200 and mp >= 60 and mp < 70 }, 0)
	end
end

local function end_frame()
	frame = frame + 1
	if gp then
		local t = frame - gp
		local r, l = count_strips()
		if r > peak_right then peak_right = r end
		if l > peak_left then peak_left = l end
		if r + l > 0 then peak_frame = t end
		if t >= 1200 then
			out:write(string.format("peak strip sprites: right(X $100-$150)=%d left(X $1B0-$1F0)=%d at t=%d\n",
				peak_right, peak_left, peak_frame))
			out:write("(stock DX culls both ranges -> expect 0/0; patched -> expect >0 when an actor is in a strip)\n")
			out:close() emu.stop(0)
		end
	elseif frame > 8000 then out:write("no gameplay\n") out:close() emu.stop(2) end
end

emu.addEventCallback(set_input, emu.eventType.inputPolled)
emu.addEventCallback(end_frame, emu.eventType.endFrame)
